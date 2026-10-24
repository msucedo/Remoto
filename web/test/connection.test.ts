import { beforeEach, describe, expect, it } from 'vitest';
import { Connection, tokenBackoff, WS_OPEN, type SocketLike } from '../src/net/connection';
import { FakeTimers } from '../src/net/timers';
import { decodeFrame } from '../src/protocol/binary';
import { out } from '../src/protocol/codec';
import { ScrollPhase } from '../src/protocol/types';

class FakeSocket implements SocketLike {
  readyState = 0;
  bufferedAmount = 0;
  binaryType = 'blob';
  sent: (string | ArrayBuffer)[] = [];
  closed = false;
  onopen: ((ev: unknown) => void) | null = null;
  onmessage: ((ev: { data: unknown }) => void) | null = null;
  onclose: ((ev: unknown) => void) | null = null;
  onerror: ((ev: unknown) => void) | null = null;
  send(d: string | ArrayBuffer) {
    this.sent.push(d);
  }
  close() {
    this.closed = true;
    this.readyState = 3;
  }
  open() {
    this.readyState = WS_OPEN;
    this.onopen?.({});
  }
  receive(msg: object) {
    this.onmessage?.({ data: JSON.stringify(msg) });
  }
  drop() {
    this.readyState = 3;
    this.onclose?.({});
  }
  json(): Record<string, unknown>[] {
    return this.sent.filter((x): x is string => typeof x === 'string').map((x) => JSON.parse(x) as Record<string, unknown>);
  }
  binary(): ArrayBuffer[] {
    return this.sent.filter((x): x is ArrayBuffer => typeof x !== 'string');
  }
}

const WELCOME = {
  t: 'welcome',
  v: 1,
  host: { name: 'Mac', version: '0.1.0', os: 'macOS' },
  sessionKey: 'k',
  token: 'tok-1',
  features: { voice: false, shell: false, secure: false, permission: true },
  deck: { version: 1, pages: [] },
  paused: false,
};

let timers: FakeTimers;
let sockets: FakeSocket[];
let token: string | null;
let conn: Connection;

function make() {
  conn = new Connection({
    url: 'ws://mac/ws',
    createSocket: () => {
      const s = new FakeSocket();
      sockets.push(s);
      return s;
    },
    timers,
    random: () => 0.5,
    device: () => ({ id: 'dev', name: 'Phone', model: 'iPhone' }),
    remember: () => true,
    tokens: {
      get: () => token,
      set: (t) => {
        token = t;
      },
      clear: () => {
        token = null;
      },
    },
  });
}

const last = () => sockets[sockets.length - 1] as FakeSocket;

beforeEach(() => {
  timers = new FakeTimers();
  sockets = [];
  token = null;
  make();
});

describe('backoff', () => {
  it('follows the table with jitter and caps at 5000', () => {
    expect(tokenBackoff(0, 0.5)).toBe(250);
    expect(tokenBackoff(1, 0)).toBe(400);
    expect(tokenBackoff(4, 1)).toBeCloseTo(4200);
    expect(tokenBackoff(99, 0.5)).toBe(5000);
  });
});

describe('connection', () => {
  it('stays idle without a token', () => {
    conn.connect();
    expect(conn.state).toBe('idle');
    expect(sockets).toHaveLength(0);
  });

  it('pairs, stores the token and then uses it', () => {
    conn.connect({ method: 'pair', code: 'C' });
    expect(conn.state).toBe('connecting');
    last().open();
    expect(last().json()[0]).toMatchObject({ t: 'hello', v: 1, auth: { method: 'pair', code: 'C' }, remember: true });
    last().receive(WELCOME);
    expect(conn.state).toBe('connected');
    expect(token).toBe('tok-1');
    last().drop();
    expect(conn.state).toBe('reconnecting');
    timers.advance(300);
    last().open();
    expect(last().json()[0]).toMatchObject({ auth: { method: 'token', token: 'tok-1' } });
  });

  it('reconnects with growing backoff and resets after welcome', () => {
    token = 'T';
    conn.connect();
    last().drop();
    const delays: number[] = [];
    for (let i = 0; i < 7; i++) {
      const before = sockets.length;
      let waited = 0;
      while (sockets.length === before) {
        timers.advance(10);
        waited += 10;
      }
      delays.push(waited);
      last().drop();
    }
    expect(delays).toEqual([250, 500, 1000, 2000, 3500, 5000, 5000]);
    timers.advance(5000);
    last().open();
    last().receive(WELCOME);
    last().drop();
    let waited = 0;
    const before = sockets.length;
    while (sockets.length === before) {
      timers.advance(10);
      waited += 10;
    }
    expect(waited).toBe(250);
  });

  it('treats a 5 s open timeout as a failure', () => {
    token = 'T';
    conn.connect();
    timers.advance(5000);
    expect(last().closed).toBe(true);
    timers.advance(250);
    expect(sockets).toHaveLength(2);
  });

  it('retries pin up to 3 times when nothing arrived, then goes idle', () => {
    conn.connect({ method: 'pin', pin: '123456' });
    for (let i = 0; i < 3; i++) {
      last().drop();
      timers.advance(1000);
    }
    expect(sockets).toHaveLength(4);
    last().drop();
    expect(conn.state).toBe('idle');
    expect(conn.getStatus().idleReason).toBe('unreachable');
  });

  it('does not retry an approval that already got an answer', () => {
    conn.connect({ method: 'approve' });
    last().open();
    last().receive({ t: 'pending' });
    expect(conn.state).toBe('pending');
    last().drop();
    expect(conn.state).toBe('idle');
    expect(conn.getStatus().idleReason).toBe('lostWaitingApproval');
  });

  it('denied does not reconnect; unknown with token clears it', () => {
    token = 'T';
    conn.connect();
    last().open();
    last().receive({ t: 'denied', reason: 'unknown' });
    expect(conn.state).toBe('idle');
    expect(token).toBeNull();
    timers.advance(10000);
    expect(sockets).toHaveLength(1);

    conn.connect({ method: 'pin', pin: '000001' });
    last().open();
    last().receive({ t: 'denied', reason: 'blocked', retryAfter: 60 });
    expect(conn.state).toBe('denied');
    expect(conn.getStatus().denied).toMatchObject({ reason: 'blocked', retryAfter: 60, method: 'pin' });
  });

  it('bye without reconnect goes idle; with reconnect waits for close', () => {
    token = 'T';
    conn.connect();
    last().open();
    last().receive(WELCOME);
    last().receive({ t: 'bye', reason: 'Stopped', reconnect: true });
    expect(conn.state).toBe('connected');
    last().drop();
    expect(conn.state).toBe('reconnecting');
    timers.advance(300);
    last().open();
    last().receive(WELCOME);
    last().receive({ t: 'bye', reason: 'Removed', reconnect: false });
    expect(conn.state).toBe('idle');
    expect(conn.getStatus().byeMessage).toBe('Removed');
  });

  it('pings every 2 s and reconnects after 6 s of silence', () => {
    token = 'T';
    conn.connect();
    const s = last();
    s.open();
    s.receive(WELCOME);
    timers.advance(2000);
    expect(s.json().filter((m) => m['t'] === 'ping')).toHaveLength(1);
    const ping = s.json().find((m) => m['t'] === 'ping');
    timers.advance(30);
    s.receive({ t: 'pong', id: ping?.['id'] });
    expect(conn.getStatus().latency).toBe(30);
    timers.advance(6500);
    expect(s.closed).toBe(true);
    expect(conn.state).toBe('reconnecting');
  });

  it('only sends hello/ping before welcome; flushes motion before JSON', () => {
    token = 'T';
    conn.connect();
    const s = last();
    s.open();
    expect(conn.send(out.tap(1))).toBe(false);
    conn.move(1, 1);
    expect(s.binary()).toHaveLength(0);
    s.receive(WELCOME);
    conn.move(3, 4);
    conn.send(out.button('left', 'click'));
    const bin = s.binary();
    expect(bin).toHaveLength(1);
    expect(decodeFrame(bin[0] as ArrayBuffer)).toEqual({ type: 'move', dx: 3, dy: 4 });
    expect(s.sent[s.sent.length - 1]).toBe('{"t":"button","button":"left","op":"click"}');
  });

  it('batches scroll with the first phase and ends with a zero frame', () => {
    token = 'T';
    conn.connect();
    const s = last();
    s.open();
    s.receive(WELCOME);
    conn.scroll(ScrollPhase.Began, 0, 0);
    conn.scroll(ScrollPhase.Changed, 1, 2);
    conn.scroll(ScrollPhase.Changed, 1, 2);
    timers.advance(10);
    conn.scroll(ScrollPhase.Changed, 5, 5);
    conn.scroll(ScrollPhase.Ended, 0, 0);
    const frames = s.binary().map((b) => decodeFrame(b));
    expect(frames).toEqual([
      { type: 'scroll', phase: 1, dx: 2, dy: 4 },
      { type: 'scroll', phase: 2, dx: 5, dy: 5 },
      { type: 'scroll', phase: 4, dx: 0, dy: 0 },
    ]);
  });

  it('respects backpressure unless forced', () => {
    token = 'T';
    conn.connect();
    const s = last();
    s.open();
    s.receive(WELCOME);
    s.bufferedAmount = 70000;
    conn.move(1, 0);
    timers.advance(6);
    expect(s.binary()).toHaveLength(0);
    conn.move(1, 0);
    s.bufferedAmount = 0;
    timers.advance(8);
    expect(s.binary().map((b) => decodeFrame(b))).toEqual([{ type: 'move', dx: 2, dy: 0 }]);
  });

  it('wake reconnects at once while reconnecting', () => {
    token = 'T';
    conn.connect();
    last().open();
    last().receive(WELCOME);
    last().drop();
    expect(sockets).toHaveLength(1);
    conn.wake();
    expect(sockets).toHaveLength(2);
  });
});
