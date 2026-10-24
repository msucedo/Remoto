// WebSocket session with the Mac: handshake, heartbeat, reconnection and the
// send rules of the protocol. UI-free so it can be tested with fake sockets.
import { decode, encode, out } from '../protocol/codec';
import { audioFrame } from '../protocol/binary';
import type { Auth, AuthMethod, ClientMessage, DeviceInfo, ScrollPhase, ServerMessage } from '../protocol/types';
import { BinaryBatcher } from './batcher';
import type { Timers } from './timers';

export type ConnState = 'idle' | 'connecting' | 'reconnecting' | 'connected' | 'pending' | 'denied';

export type IdleReason =
  | 'none'
  | 'unreachable'
  | 'lostWaitingApproval'
  | 'unknownDevice'
  | 'bye'
  | 'disconnected'
  | 'forgotten'
  | 'cancelled';

export interface DeniedInfo {
  reason: string;
  retryAfter?: number;
  method: AuthMethod;
  /** Monotonic time the denial arrived (for countdowns). */
  at: number;
}

export interface ConnStatus {
  state: ConnState;
  method: AuthMethod | null;
  denied: DeniedInfo | null;
  idleReason: IdleReason;
  byeMessage: string;
  everConnected: boolean;
  latency: number | null;
}

export const OPEN_TIMEOUT_MS = 5000;
export const PING_INTERVAL_MS = 2000;
export const MAX_PENDING_PINGS = 8;
export const SILENCE_TIMEOUT_MS = 6000;
export const TOKEN_BACKOFF_MS = [250, 500, 1000, 2000, 3500, 5000] as const;
export const PAIR_RETRIES = 3;
export const PAIR_RETRY_MS = 1000;
const TICK_MS = 500;
const FRESH_SOCKET_MS = 5000;

/** Delay before the n-th token reconnection attempt (0-based). */
export function tokenBackoff(attempt: number, rand: number): number {
  const i = Math.min(Math.max(0, attempt), TOKEN_BACKOFF_MS.length - 1);
  return (TOKEN_BACKOFF_MS[i] ?? 5000) * (0.8 + 0.4 * rand);
}

export const WS_OPEN = 1;

export interface SocketLike {
  readonly readyState: number;
  readonly bufferedAmount: number;
  binaryType: string;
  send(data: string | ArrayBuffer): void;
  close(code?: number, reason?: string): void;
  onopen: ((ev: unknown) => void) | null;
  onmessage: ((ev: { data: unknown }) => void) | null;
  onclose: ((ev: unknown) => void) | null;
  onerror: ((ev: unknown) => void) | null;
}

export interface TokenStore {
  get(): string | null;
  set(token: string): void;
  clear(): void;
}

export interface ConnectionDeps {
  url: string;
  createSocket(url: string): SocketLike;
  timers: Timers;
  random(): number;
  device(): DeviceInfo;
  remember(): boolean;
  tokens: TokenStore;
}

type Listener<T> = (v: T) => void;

export class Connection {
  private socket: SocketLike | null = null;
  private auth: Auth | null = null;
  private status: ConnStatus = {
    state: 'idle',
    method: null,
    denied: null,
    idleReason: 'none',
    byeMessage: '',
    everConnected: false,
    latency: null,
  };
  private attempts = 0;
  private pairRetries = 0;
  private gotMessage = false;
  private stopReconnect = false;
  private openTimer: number | null = null;
  private retryTimer: number | null = null;
  private tickTimer: number | null = null;
  private openedAt = 0;
  private lastMessageAt = 0;
  private lastPingAt = 0;
  private pingSeq = 0;
  private readonly pings = new Map<number, number>();
  private readonly statusListeners = new Set<Listener<ConnStatus>>();
  private readonly messageListeners = new Set<Listener<ServerMessage>>();
  readonly batcher: BinaryBatcher;

  constructor(private readonly deps: ConnectionDeps) {
    this.batcher = new BinaryBatcher(
      {
        send: (buf) => {
          if (this.canSendBinary()) this.socket?.send(buf);
        },
        bufferedAmount: () => this.socket?.bufferedAmount ?? 0,
      },
      deps.timers,
    );
  }

  get state(): ConnState {
    return this.status.state;
  }

  getStatus(): ConnStatus {
    return this.status;
  }

  onStatus(fn: Listener<ConnStatus>): () => void {
    this.statusListeners.add(fn);
    return () => this.statusListeners.delete(fn);
  }

  onMessage(fn: Listener<ServerMessage>): () => void {
    this.messageListeners.add(fn);
    return () => this.messageListeners.delete(fn);
  }

  /** True while an attempt is open or scheduled. */
  get busy(): boolean {
    return this.socket !== null || this.retryTimer !== null;
  }

  /**
   * Starts a connection. Without `auth`, uses the stored token (or goes idle).
   * A token connect is ignored while an attempt with another method runs.
   */
  connect(auth?: Auth): void {
    if (!auth) {
      if (this.busy && this.auth && this.auth.method !== 'token') return;
      const token = this.deps.tokens.get();
      if (!token) {
        this.teardown();
        this.update({ state: 'idle', method: null });
        return;
      }
      auth = { method: 'token', token };
    } else {
      this.attempts = 0;
    }
    if (auth.method !== 'token') this.pairRetries = 0;
    this.stopReconnect = false;
    this.auth = auth;
    this.open();
  }

  /** Closes and stays idle, keeping the token. */
  disconnect(reason: IdleReason = 'disconnected'): void {
    this.stopReconnect = true;
    this.teardown();
    this.auth = null;
    this.update({ state: 'idle', method: null, denied: null, idleReason: reason });
  }

  /** Drops the token and closes. The Mac is not told. */
  forget(): void {
    this.deps.tokens.clear();
    this.disconnect('forgotten');
  }

  /**
   * Called when the page becomes visible, goes online or is restored from the
   * back/forward cache: reconnect now if the link is down or stale.
   */
  wake(): void {
    const now = this.deps.timers.now();
    const stale = now - this.lastMessageAt > SILENCE_TIMEOUT_MS;
    const { state } = this.status;
    const usingToken = !this.auth || this.auth.method === 'token';
    if (!usingToken) return;
    if (state === 'reconnecting' || (state === 'connecting' && this.deps.tokens.get())) {
      if (this.socket && now - this.openedAt < FRESH_SOCKET_MS && !stale) return;
      this.connect();
    } else if (state === 'connected' && stale) {
      if (this.socket && now - this.openedAt < FRESH_SOCKET_MS) return;
      this.connect();
    }
  }

  /** Sends a JSON message following the protocol send rules. */
  send(msg: ClientMessage): boolean {
    const s = this.socket;
    if (!s || s.readyState !== WS_OPEN) return false;
    const control = msg.t === 'hello' || msg.t === 'ping';
    if (!control) {
      if (this.status.state !== 'connected') return false;
      this.batcher.flush(true);
    }
    s.send(encode(msg));
    return true;
  }

  canSendBinary(): boolean {
    return this.status.state === 'connected' && this.socket?.readyState === WS_OPEN;
  }

  move(dx: number, dy: number): void {
    if (this.canSendBinary()) this.batcher.move(dx, dy);
  }

  scroll(phase: ScrollPhase, dx: number, dy: number): void {
    if (this.canSendBinary()) this.batcher.scroll(phase, dx, dy);
  }

  fling(vx: number, vy: number): void {
    if (this.canSendBinary()) this.batcher.fling(vx, vy);
  }

  touch(): void {
    if (this.canSendBinary()) this.batcher.touch();
  }

  audio(pcm: Int16Array): void {
    if (this.canSendBinary()) this.socket?.send(audioFrame(pcm));
  }

  // ---- internals ------------------------------------------------------------

  private update(patch: Partial<ConnStatus>): void {
    this.status = { ...this.status, ...patch };
    for (const fn of this.statusListeners) fn(this.status);
  }

  private clearTimer(name: 'openTimer' | 'retryTimer' | 'tickTimer'): void {
    const id = this[name];
    if (id !== null) this.deps.timers.clearTimeout(id);
    this[name] = null;
  }

  private teardown(): void {
    this.clearTimer('openTimer');
    this.clearTimer('retryTimer');
    this.clearTimer('tickTimer');
    this.batcher.reset();
    this.pings.clear();
    const s = this.socket;
    this.socket = null;
    if (s) {
      s.onopen = s.onmessage = s.onclose = s.onerror = null;
      try {
        s.close();
      } catch {
        // already closed
      }
    }
  }

  private open(): void {
    this.teardown();
    const auth = this.auth;
    if (!auth) return;
    this.gotMessage = false;
    const state: ConnState = auth.method === 'token' && this.status.everConnected ? 'reconnecting' : 'connecting';
    this.update({ state, method: auth.method, denied: null, idleReason: 'none', byeMessage: '' });

    let socket: SocketLike;
    try {
      socket = this.deps.createSocket(this.deps.url);
    } catch {
      this.failed();
      return;
    }
    this.socket = socket;
    socket.binaryType = 'arraybuffer';
    const t = this.deps.timers;
    this.openTimer = t.setTimeout(() => {
      this.openTimer = null;
      this.failed();
    }, OPEN_TIMEOUT_MS);

    socket.onopen = () => {
      this.clearTimer('openTimer');
      const now = t.now();
      this.openedAt = now;
      this.lastMessageAt = now;
      this.lastPingAt = now;
      this.startTick();
      this.send(out.hello(this.deps.device(), auth, this.deps.remember()));
    };
    socket.onmessage = (ev) => this.received(ev.data);
    socket.onclose = () => this.closed();
    socket.onerror = () => this.closed();
  }

  private startTick(): void {
    this.clearTimer('tickTimer');
    const t = this.deps.timers;
    const tick = () => {
      this.tickTimer = null;
      const now = t.now();
      if (now - this.lastMessageAt > SILENCE_TIMEOUT_MS) {
        this.failed();
        return;
      }
      if (now - this.lastPingAt >= PING_INTERVAL_MS) {
        this.lastPingAt = now;
        if (this.pings.size < MAX_PENDING_PINGS) {
          const id = ++this.pingSeq;
          this.pings.set(id, now);
          this.send(out.ping(id));
        }
      }
      this.tickTimer = t.setTimeout(tick, TICK_MS);
    };
    this.tickTimer = t.setTimeout(tick, TICK_MS);
  }

  private received(data: unknown): void {
    const now = this.deps.timers.now();
    this.lastMessageAt = now;
    this.gotMessage = true;
    if (typeof data !== 'string') return;
    const msg = decode(data);
    if (!msg) return;
    switch (msg.t) {
      case 'welcome': {
        this.attempts = 0;
        this.pairRetries = 0;
        if (msg.token) this.deps.tokens.set(msg.token);
        if (this.auth && this.auth.method !== 'token') {
          const token = this.deps.tokens.get();
          this.auth = token ? { method: 'token', token } : null;
        }
        this.update({ state: 'connected', everConnected: true, denied: null, idleReason: 'none' });
        break;
      }
      case 'pending':
        this.update({ state: 'pending' });
        break;
      case 'denied': {
        const method = this.auth?.method ?? 'token';
        this.stopReconnect = true;
        this.teardown();
        if (msg.reason === 'unknown') {
          if (method === 'token') this.deps.tokens.clear();
          this.auth = null;
          this.update({ state: 'idle', method: null, denied: null, idleReason: 'unknownDevice' });
        } else {
          const denied: DeniedInfo = { reason: msg.reason, method, at: now };
          if (msg.retryAfter !== undefined) denied.retryAfter = msg.retryAfter;
          this.update({ state: 'denied', denied });
        }
        break;
      }
      case 'pong': {
        const id = typeof msg.id === 'number' ? msg.id : NaN;
        const sent = this.pings.get(id);
        if (sent !== undefined) {
          this.pings.delete(id);
          for (const k of this.pings.keys()) if (k < id) this.pings.delete(k);
          const rtt = now - sent;
          const prev = this.status.latency;
          this.update({ latency: prev === null ? Math.round(rtt) : Math.round(0.7 * prev + 0.3 * rtt) });
        }
        return;
      }
      case 'bye':
        if (!msg.reconnect) {
          this.stopReconnect = true;
          this.teardown();
          this.auth = null;
          this.update({ state: 'idle', method: null, idleReason: 'bye', byeMessage: msg.reason });
        }
        // reconnect: true -> wait for the close and reconnect as usual.
        break;
      default:
        break;
    }
    for (const fn of this.messageListeners) fn(msg);
  }

  private closed(): void {
    if (!this.socket) return;
    this.failed();
  }

  /** The attempt or the session ended without a terminal answer. */
  private failed(): void {
    this.teardown();
    if (this.stopReconnect) return;
    const auth = this.auth;
    if (!auth) {
      this.update({ state: 'idle', method: null });
      return;
    }
    const t = this.deps.timers;
    if (auth.method === 'token') {
      const delay = tokenBackoff(this.attempts, this.deps.random());
      this.attempts++;
      const state: ConnState = this.status.everConnected ? 'reconnecting' : 'connecting';
      this.update({ state });
      this.retryTimer = t.setTimeout(() => {
        this.retryTimer = null;
        this.open();
      }, delay);
      return;
    }
    if (!this.gotMessage && this.pairRetries < PAIR_RETRIES) {
      this.pairRetries++;
      this.retryTimer = t.setTimeout(() => {
        this.retryTimer = null;
        this.open();
      }, PAIR_RETRY_MS);
      return;
    }
    const reason: IdleReason = this.gotMessage ? 'lostWaitingApproval' : 'unreachable';
    // Fall back to the stored token (if any) the next time, not the spent method.
    this.auth = null;
    this.update({ state: 'idle', method: null, idleReason: reason });
  }
}
