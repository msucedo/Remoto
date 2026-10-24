// Application controller: owns the connection, the session state received
// from the Mac, local settings and their sync. Views talk to this object.
import { out } from './protocol/codec';
import type {
  Action,
  AppInfo,
  AppOp,
  Deck,
  Features,
  HostInfo,
  KeyboardLayout,
  MediaKey,
  MouseButton,
  PressOp,
  ServerMessage,
  SettingsDevice,
  TextMode,
  VolumeState,
  WelcomeMessage,
} from './protocol/types';
import { Connection, type ConnStatus } from './net/connection';
import { realTimers } from './net/timers';
import { ModifierMachine, MODIFIERS, type Modifier } from './input/modifiers';
import { Emitter } from './emitter';
import { charMap, type KeyStroke, US_LAYOUT } from './keyboard/layout';
import {
  applyBlob,
  blobHash,
  makeBlob,
  nextUpdatedAt,
  SETTINGS_MAX_BYTES,
  validateSettings,
  type Settings,
} from './store/settings';
import { validateKeyboards, type Board, type KeyboardsState } from './store/keyboards';
import { debounce, deviceId, getItem, keys, readJSON, removeItem, session, setItem } from './store/storage';
import { currentModel } from './device';
import { haptic, setHapticsEnabled, type HapticKind } from './ui/haptics';
import { toast } from './ui/toast';
import { t } from './i18n';
import { cloneDeck, validateDeck } from './deck/validate';
import { isObj } from './protocol/codec';

export const CLIENT_VERSION = __APP_VERSION__;
const ACTION_TIMEOUT_MS = 15000;
const LIST_TIMEOUT_MS = 8000;
const APPS_THROTTLE_MS = 3000;
const SYNC_DEBOUNCE_MS = 1500;

export interface ActionOutcome {
  ok: boolean;
  message?: string;
}

export interface AppEvents extends Record<string, unknown> {
  status: ConnStatus;
  host: HostInfo | null;
  features: Features;
  deck: Deck | null;
  layout: KeyboardLayout;
  volume: VolumeState | null;
  paused: boolean;
  apps: AppInfo[] | null;
  settings: Settings;
  keyboards: KeyboardsState;
  voice: Extract<ServerMessage, { t: 'voice' }>;
  clipboard: string | null;
  info: { name: string; secure: boolean } | null;
  /** Page hidden: views drop pressed keys, gestures, repeaters, dictation. */
  suspend: undefined;
  welcome: WelcomeMessage;
}

interface SyncMeta {
  updatedAt: number;
  hash: string;
}

const DEFAULT_FEATURES: Features = { voice: false, shell: false, secure: false, permission: true };

export class App {
  readonly events = new Emitter<AppEvents>();
  readonly conn: Connection;
  readonly mods: ModifierMachine;
  readonly deviceId = deviceId();
  readonly model = currentModel();

  settings: Settings;
  keyboards: KeyboardsState;
  host: HostInfo | null = null;
  info: { name: string; secure: boolean } | null = null;
  features: Features = { ...DEFAULT_FEATURES };
  deck: Deck | null = null;
  private confirmedDeck: Deck | null = null;
  layout: KeyboardLayout = US_LAYOUT;
  private chars = charMap(US_LAYOUT);
  volume: VolumeState | null = null;
  volumeKnown = false;
  paused = false;
  sessionKey = '';
  apps: AppInfo[] | null = null;
  private appsWanted = false;
  private appsAt = -Infinity;

  private actionSeq = 0;
  private readonly actions = new Map<number, { resolve: (o: ActionOutcome) => void; timer: ReturnType<typeof setTimeout> }>();
  private listWaiter: { resolve: (d: SettingsDevice[]) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout> } | null = null;
  private copyWaiter: { resolve: (s: unknown) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout> } | null = null;

  private syncMeta: SyncMeta;
  private lastSent = 0;
  private readonly saveSettingsSoon = debounce(() => setItem(keys.settings, JSON.stringify(this.settings)), 150);
  private readonly saveKeyboardsSoon = debounce(() => setItem(keys.keyboards, JSON.stringify(this.keyboards)), 200);
  private readonly syncSoon = debounce(() => this.syncNow(), SYNC_DEBOUNCE_MS);

  constructor() {
    this.settings = validateSettings(readJSON(keys.settings));
    this.keyboards = validateKeyboards(readJSON(keys.keyboards));
    const meta = readJSON(keys.settingsSync);
    this.syncMeta =
      isObj(meta) && typeof meta['updatedAt'] === 'number' && typeof meta['hash'] === 'string'
        ? { updatedAt: meta['updatedAt'], hash: meta['hash'] }
        : { updatedAt: 0, hash: blobHash(makeBlob(this.settings, this.keyboards.boards)) };
    setHapticsEnabled(this.settings.haptics);

    const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
    this.conn = new Connection({
      url: `${scheme}://${location.host}/ws`,
      createSocket: (url) => new WebSocket(url) as unknown as import('./net/connection').SocketLike,
      timers: realTimers,
      random: Math.random,
      device: () => ({
        id: this.deviceId,
        name: this.settings.deviceName.trim() || this.model,
        model: this.model,
      }),
      remember: () => this.settings.rememberDevice,
      tokens: {
        get: () => getItem(keys.token),
        set: (tk) => setItem(keys.token, tk),
        clear: () => removeItem(keys.token),
      },
    });
    this.mods = new ModifierMachine({ key: (code, down) => this.send(out.key(code, down)) }, realTimers);
    this.conn.onStatus((s) => this.statusChanged(s));
    this.conn.onMessage((m) => this.handle(m));
  }

  get hasToken(): boolean {
    return getItem(keys.token) !== null;
  }

  get connected(): boolean {
    return this.conn.state === 'connected';
  }

  get macName(): string {
    return this.host?.name || this.info?.name || '';
  }

  get secureContext(): boolean {
    return globalThis.isSecureContext === true;
  }

  haptic(kind: HapticKind): void {
    if (this.settings.haptics) haptic(kind);
  }

  async fetchInfo(): Promise<void> {
    try {
      const res = await fetch('/api/info', { cache: 'no-store' });
      if (!res.ok) return;
      const j: unknown = await res.json();
      if (isObj(j) && typeof j['name'] === 'string') {
        this.info = { name: j['name'], secure: j['secure'] === true };
        this.events.emit('info', this.info);
      }
    } catch {
      // offline or not served by the Mac
    }
  }

  // ---- sending ------------------------------------------------------------------

  send(msg: Parameters<Connection['send']>[0]): boolean {
    return this.conn.send(msg);
  }

  /** Virtual key down with sticky modifiers applied. */
  keyDown(code: number, extraMods = 0): void {
    const mods = this.mods.take() | extraMods;
    this.send(out.key(code, true, mods, this.settings.keyRepeat));
  }

  keyUp(code: number): void {
    this.send(out.key(code, false));
  }

  tap(code: number, extraMods = 0): void {
    const mods = this.mods.take() | extraMods;
    this.send(out.tap(code, mods));
  }

  /** Mouse click honoring latched modifiers (pressed around the click). */
  click(button: MouseButton): void {
    const mask = this.mods.take();
    const codes = this.maskToCodes(mask);
    for (const c of codes) this.send(out.key(c, true));
    this.send(out.button(button, 'click'));
    for (const c of [...codes].reverse()) this.send(out.key(c, false));
  }

  button(button: MouseButton, op: PressOp): void {
    if (op === 'down') this.mods.commitHeld();
    this.send(out.button(button, op));
  }

  media(key: MediaKey, op: PressOp = 'click'): void {
    this.send(out.media(key, op));
  }

  text(text: string, mode: TextMode = this.settings.textMode): boolean {
    return this.send(out.text(text, mode));
  }

  releaseAll(): void {
    this.mods.releaseAll();
    this.send(out.release());
  }

  stroke(ch: string): KeyStroke | null {
    const direct = this.chars.get(ch);
    if (direct) return direct;
    const lower = ch.toLowerCase();
    const l = lower !== ch ? this.chars.get(lower) : undefined;
    return l && l.mods === 0 ? { code: l.code, mods: 2 } : null;
  }

  private maskToCodes(mask: number): number[] {
    const codes: number[] = [];
    for (const m of Object.keys(MODIFIERS) as Modifier[]) {
      if (mask & MODIFIERS[m].bit) codes.push(MODIFIERS[m].code);
    }
    return codes;
  }

  // ---- actions ---------------------------------------------------------------------

  runAction(action: Action): Promise<ActionOutcome> {
    const id = ++this.actionSeq;
    if (!this.send(out.action(action, id))) return Promise.resolve({ ok: false, message: t('toast.offline') });
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.actions.delete(id);
        resolve({ ok: true });
      }, ACTION_TIMEOUT_MS);
      this.actions.set(id, { resolve, timer });
    });
  }

  /** Fire-and-forget action (gestures); errors still come back as toasts. */
  fireAction(action: Action): void {
    void this.runAction(action).then((r) => {
      if (!r.ok && r.message) toast(r.message, 'error', 'action');
    });
  }

  // ---- deck -------------------------------------------------------------------------

  /** Optimistic save. Returns false (and reverts) if it could not be sent. */
  saveDeck(next: Deck): boolean {
    const err = validateDeck(next);
    if (err) {
      toast(t(`err.${err}`), 'warning', 'deck');
      return false;
    }
    this.deck = next;
    this.events.emit('deck', this.deck);
    if (!this.send(out.deckSave(next))) {
      this.deck = this.confirmedDeck ? cloneDeck(this.confirmedDeck) : null;
      this.events.emit('deck', this.deck);
      toast(t('deck.offlineReverted'), 'warning', 'deck');
      return false;
    }
    return true;
  }

  // ---- apps ---------------------------------------------------------------------------

  requestApps(force = false): void {
    this.appsWanted = true;
    const now = performance.now();
    if (!force && now - this.appsAt < APPS_THROTTLE_MS) return;
    if (this.send(out.apps())) this.appsAt = now;
  }

  appAction(id: string, op: AppOp): void {
    this.send(out.appAction(id, op));
  }

  setVolume(state: { value?: number; muted?: boolean }): void {
    this.send(out.volume(state));
  }

  // ---- settings -------------------------------------------------------------------------

  updateSettings(patch: Partial<Settings>): void {
    this.settings = validateSettings({ ...this.settings, ...patch }, this.settings);
    setHapticsEnabled(this.settings.haptics);
    this.saveSettingsSoon();
    this.events.emit('settings', this.settings);
    this.syncableChanged();
  }

  replaceSettings(next: Settings): void {
    this.settings = next;
    setHapticsEnabled(next.haptics);
    this.saveSettingsSoon();
    this.events.emit('settings', this.settings);
    this.syncableChanged();
  }

  updateKeyboards(fn: (k: KeyboardsState) => KeyboardsState): void {
    this.keyboards = validateKeyboards(fn(structuredClone(this.keyboards)));
    this.saveKeyboardsSoon();
    this.events.emit('keyboards', this.keyboards);
    this.syncableChanged();
  }

  /** Writes pending local saves now (page hidden). */
  flushSaves(): void {
    this.saveSettingsSoon.flush();
    this.saveKeyboardsSoon.flush();
    this.syncSoon.flush();
  }

  private syncableChanged(): void {
    const hash = blobHash(makeBlob(this.settings, this.keyboards.boards));
    if (hash === this.syncMeta.hash) return;
    this.syncMeta = { updatedAt: nextUpdatedAt(this.syncMeta.updatedAt), hash };
    setItem(keys.settingsSync, JSON.stringify(this.syncMeta));
    this.syncSoon();
  }

  private syncNow(): void {
    if (!this.hasToken || !this.connected) return;
    if (this.syncMeta.updatedAt <= this.lastSent) return;
    const blob = makeBlob(this.settings, this.keyboards.boards);
    const json = JSON.stringify(blob);
    if (new TextEncoder().encode(json).length > SETTINGS_MAX_BYTES) {
      toast(t('settings.tooBig'), 'warning', 'settings');
      return;
    }
    if (this.send(out.settingsSave(blob, this.syncMeta.updatedAt))) this.lastSent = this.syncMeta.updatedAt;
  }

  /** Applies a settings blob from the Mac or another device. */
  private applyRemote(blob: unknown, updatedAt: number): boolean {
    const r = applyBlob(blob, this.settings);
    if (!r) return false;
    this.settings = r.settings;
    setHapticsEnabled(r.settings.haptics);
    if (r.keyboards) {
      const active = r.keyboards.some((b) => b.id === this.keyboards.active) ? this.keyboards.active : (r.keyboards[0]?.id ?? '');
      this.keyboards = { active, boards: r.keyboards };
    }
    this.saveSettingsSoon();
    this.saveKeyboardsSoon();
    this.syncMeta = { updatedAt, hash: blobHash(makeBlob(this.settings, this.keyboards.boards)) };
    setItem(keys.settingsSync, JSON.stringify(this.syncMeta));
    this.events.emit('settings', this.settings);
    this.events.emit('keyboards', this.keyboards);
    return true;
  }

  listOtherDevices(): Promise<SettingsDevice[]> {
    this.listWaiter?.reject(new Error('replaced'));
    return new Promise((resolve, reject) => {
      if (!this.send(out.settingsList())) {
        reject(new Error(t('toast.offline')));
        return;
      }
      const timer = setTimeout(() => {
        this.listWaiter = null;
        reject(new Error(t('copy.timeout')));
      }, LIST_TIMEOUT_MS);
      this.listWaiter = { resolve, reject, timer };
    });
  }

  copySettingsFrom(id: string): Promise<void> {
    this.copyWaiter?.reject(new Error('replaced'));
    return new Promise<unknown>((resolve, reject) => {
      if (!this.send(out.settingsCopy(id))) {
        reject(new Error(t('toast.offline')));
        return;
      }
      const timer = setTimeout(() => {
        this.copyWaiter = null;
        reject(new Error(t('copy.timeout')));
      }, LIST_TIMEOUT_MS);
      this.copyWaiter = { resolve, reject, timer };
    }).then((blob) => {
      const updatedAt = nextUpdatedAt(this.syncMeta.updatedAt);
      if (!this.applyRemote(blob, updatedAt)) throw new Error(t('copy.invalid'));
      this.lastSent = 0;
      this.syncNow();
    });
  }

  // ---- incoming ------------------------------------------------------------------------

  private statusChanged(s: ConnStatus): void {
    if (s.state !== 'connected') {
      this.mods.forgetRemote();
      for (const [id, a] of this.actions) {
        clearTimeout(a.timer);
        a.resolve({ ok: false, message: t('toast.offline') });
        this.actions.delete(id);
      }
    }
    this.events.emit('status', s);
  }

  private handle(m: ServerMessage): void {
    switch (m.t) {
      case 'welcome':
        this.welcome(m);
        break;
      case 'deck':
        this.deck = m.deck;
        this.confirmedDeck = cloneDeck(m.deck);
        this.events.emit('deck', this.deck);
        break;
      case 'layout':
        this.setLayout(m.layout);
        break;
      case 'features':
        this.features = m.features;
        this.events.emit('features', this.features);
        break;
      case 'paused':
        this.paused = m.paused;
        if (!m.paused) this.mods.restoreLocked();
        this.events.emit('paused', this.paused);
        break;
      case 'volume':
        this.volume = { value: m.value, muted: m.muted };
        this.volumeKnown = true;
        this.events.emit('volume', this.volume);
        break;
      case 'volumeUnavailable':
        this.volume = null;
        this.volumeKnown = true;
        this.events.emit('volume', null);
        break;
      case 'apps':
        this.apps = m.apps;
        this.events.emit('apps', this.apps);
        break;
      case 'appsChanged':
        if (this.apps) this.requestApps(true);
        break;
      case 'notice':
        this.notice(m);
        break;
      case 'actionResult': {
        const id = typeof m.id === 'number' ? m.id : NaN;
        const waiter = this.actions.get(id);
        const outcome: ActionOutcome = m.message === undefined ? { ok: m.ok } : { ok: m.ok, message: m.message };
        if (waiter) {
          clearTimeout(waiter.timer);
          this.actions.delete(id);
          waiter.resolve(outcome);
        } else if (!m.ok && m.message) {
          toast(m.message, 'error', 'action');
        }
        break;
      }
      case 'clipboard':
        this.events.emit('clipboard', m.text);
        break;
      case 'voice':
        this.events.emit('voice', m);
        break;
      case 'settings': {
        const w = this.copyWaiter;
        if (w) {
          clearTimeout(w.timer);
          this.copyWaiter = null;
          w.resolve(m.settings);
        }
        break;
      }
      case 'settingsList': {
        const w = this.listWaiter;
        if (w) {
          clearTimeout(w.timer);
          this.listWaiter = null;
          w.resolve(m.devices);
        }
        break;
      }
      default:
        break;
    }
  }

  private notice(m: Extract<ServerMessage, { t: 'notice' }>): void {
    const text = m.message || (m.code ? t('notice.generic') : '');
    toast(text, m.level, m.code);
    if (m.code === 'deck' && this.confirmedDeck) {
      this.deck = cloneDeck(this.confirmedDeck);
      this.events.emit('deck', this.deck);
    }
    if (m.code === 'settings') {
      const err = new Error(m.message || t('copy.failed'));
      if (this.listWaiter) {
        clearTimeout(this.listWaiter.timer);
        this.listWaiter.reject(err);
        this.listWaiter = null;
      }
      if (this.copyWaiter) {
        clearTimeout(this.copyWaiter.timer);
        this.copyWaiter.reject(err);
        this.copyWaiter = null;
      }
    }
  }

  private setLayout(layout: KeyboardLayout): void {
    this.layout = layout.keys.length ? layout : US_LAYOUT;
    this.chars = charMap(this.layout);
    this.events.emit('layout', this.layout);
  }

  private welcome(m: WelcomeMessage): void {
    if (this.maybeReloadForVersion(m.host.version)) return;
    this.host = m.host;
    this.sessionKey = m.sessionKey;
    this.features = m.features;
    this.deck = m.deck;
    this.confirmedDeck = cloneDeck(m.deck);
    this.paused = m.paused;
    if (m.volume) {
      this.volume = m.volume;
      this.volumeKnown = true;
    } else {
      this.volume = null;
      this.volumeKnown = false;
    }
    this.setLayout(m.layout ?? US_LAYOUT);
    this.events.emit('host', this.host);
    this.events.emit('features', this.features);
    this.events.emit('deck', this.deck);
    this.events.emit('volume', this.volume);
    this.events.emit('paused', this.paused);
    this.events.emit('welcome', m);

    // Settings sync.
    const remote = m.settings;
    this.lastSent = remote?.updatedAt ?? 0;
    if (remote && remote.updatedAt > this.syncMeta.updatedAt) {
      this.applyRemote(remote.settings, remote.updatedAt);
    } else if (this.syncMeta.updatedAt > (remote?.updatedAt ?? 0)) {
      this.syncNow();
    }

    if (this.appsWanted) this.requestApps(true);
    if (!this.paused) this.mods.restoreLocked();
  }

  /** Reloads once per Mac version when the client is out of date. */
  private maybeReloadForVersion(version: string): boolean {
    if (!version || version === CLIENT_VERSION) return false;
    const ss = session();
    try {
      const forVersion = ss?.getItem(keys.reloadedFor);
      const at = Number(ss?.getItem(keys.reloadedAt) ?? 0);
      if (forVersion === version || Date.now() - at < 10000) return false;
      ss?.setItem(keys.reloadedFor, version);
      ss?.setItem(keys.reloadedAt, String(Date.now()));
    } catch {
      return false;
    }
    location.reload();
    return true;
  }

  // ---- lifecycle ------------------------------------------------------------------------

  /** Page hidden: release everything on the Mac and save now. */
  suspend(): void {
    if (this.connected) this.send(out.release());
    this.mods.suspend();
    this.events.emit('suspend', undefined);
    this.flushSaves();
  }

  resume(): void {
    this.conn.wake();
    if (this.connected && !this.paused) this.mods.restoreLocked();
  }

  boards(): Board[] {
    return this.keyboards.boards;
  }
}
