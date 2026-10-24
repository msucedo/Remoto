// Local settings: defaults, validation, and the blob synced with the Mac.
import type { Action, SystemAction } from '../protocol/types';
import { isObj } from '../protocol/codec';
import { validateAction } from '../deck/validate';
import type { Board } from './keyboards';
import { validateBoardList } from './keyboards';

export const TABS = ['trackpad', 'keyboard', 'deck', 'media', 'apps'] as const;
export type Tab = (typeof TABS)[number];

export type Direction = 'up' | 'down' | 'left' | 'right' | 'tap';
export const DIRECTIONS: readonly Direction[] = ['up', 'down', 'left', 'right', 'tap'];
export type GestureMap = Record<Direction, Action | null>;

export interface Settings {
  version: 1;
  pointerSpeed: number;
  pointerAcceleration: number;
  tapToClick: boolean;
  twoFingerTapRightClick: boolean;
  longPress: 'drag' | 'rightClick' | 'off';
  tapAndDrag: boolean;
  dragLock: boolean;
  clickButtons: boolean;
  scrollSpeed: number;
  naturalScroll: boolean;
  momentum: boolean;
  scrollStrip: 'short' | 'long' | 'off';
  scrollStripSide: 'right' | 'left';
  scrollHold: boolean;
  showAdvanced: boolean;
  pinchToZoom: boolean;
  threeFinger: GestureMap;
  fourFinger: GestureMap;
  keyboard: 'auto' | 'mac' | 'custom' | 'phone';
  functionRow: 'media' | 'function';
  keyRepeat: boolean;
  textMode: 'unicode' | 'keystrokes' | 'paste';
  liveTyping: boolean;
  deckButtonSize: number;
  haptics: boolean;
  theme: 'system' | 'dark' | 'light';
  language: 'auto' | 'en' | 'es';
  keepAwake: boolean;
  showTouches: boolean;
  rememberDevice: boolean;
  deviceName: string;
  tab: Tab;
  deckPage: string;
}

const sys = (name: SystemAction): Action => ({ kind: 'system', name });

export function defaultThreeFinger(): GestureMap {
  return {
    up: sys('missionControl'),
    down: sys('appExpose'),
    left: sys('spaceRight'),
    right: sys('spaceLeft'),
    tap: { kind: 'mouse', button: 'middle' },
  };
}

export function defaultFourFinger(): GestureMap {
  return {
    up: sys('launchpad'),
    down: sys('showDesktop'),
    left: sys('nextTab'),
    right: sys('previousTab'),
    tap: null,
  };
}

export function defaultSettings(): Settings {
  return {
    version: 1,
    pointerSpeed: 1.2,
    pointerAcceleration: 0.6,
    tapToClick: true,
    twoFingerTapRightClick: true,
    longPress: 'drag',
    tapAndDrag: true,
    dragLock: false,
    clickButtons: true,
    scrollSpeed: 1,
    naturalScroll: true,
    momentum: true,
    scrollStrip: 'short',
    scrollStripSide: 'right',
    scrollHold: true,
    showAdvanced: false,
    pinchToZoom: true,
    threeFinger: defaultThreeFinger(),
    fourFinger: defaultFourFinger(),
    keyboard: 'auto',
    functionRow: 'media',
    keyRepeat: true,
    textMode: 'unicode',
    liveTyping: true,
    deckButtonSize: 1,
    haptics: true,
    theme: 'system',
    language: 'auto',
    keepAwake: true,
    showTouches: true,
    rememberDevice: true,
    deviceName: '',
    tab: 'trackpad',
    deckPage: '',
  };
}

export const RANGES = {
  pointerSpeed: [0.2, 4],
  pointerAcceleration: [0, 1],
  scrollSpeed: [0.2, 4],
  deckButtonSize: [0.7, 1.6],
} as const;

const ENUMS = {
  longPress: ['drag', 'rightClick', 'off'],
  scrollStrip: ['short', 'long', 'off'],
  scrollStripSide: ['right', 'left'],
  keyboard: ['auto', 'mac', 'custom', 'phone'],
  functionRow: ['media', 'function'],
  textMode: ['unicode', 'keystrokes', 'paste'],
  theme: ['system', 'dark', 'light'],
  language: ['auto', 'en', 'es'],
  tab: TABS,
} as const;

const BOOLS = [
  'tapToClick',
  'twoFingerTapRightClick',
  'tapAndDrag',
  'dragLock',
  'clickButtons',
  'naturalScroll',
  'momentum',
  'scrollHold',
  'showAdvanced',
  'pinchToZoom',
  'keyRepeat',
  'liveTyping',
  'haptics',
  'keepAwake',
  'showTouches',
  'rememberDevice',
] as const satisfies readonly (keyof Settings)[];

function validGestureMap(v: unknown, fallback: GestureMap): GestureMap {
  const out: GestureMap = { ...fallback };
  if (!isObj(v)) return out;
  for (const d of ['up', 'down', 'left', 'right', 'tap'] as const) {
    const a = v[d];
    if (a === null) out[d] = null;
    else if (a !== undefined && validateAction(a) === null) out[d] = a as Action;
  }
  return out;
}

/** Validates types and enums, clamps numbers; unknown keys are dropped. */
export function validateSettings(raw: unknown, base: Settings = defaultSettings()): Settings {
  const s: Settings = structuredClone(base);
  if (!isObj(raw)) return s;
  for (const [key, [lo, hi]] of Object.entries(RANGES) as [keyof typeof RANGES, readonly [number, number]][]) {
    const v = raw[key];
    if (typeof v === 'number' && Number.isFinite(v)) s[key] = Math.min(hi, Math.max(lo, v));
  }
  for (const key of BOOLS) {
    const v = raw[key];
    if (typeof v === 'boolean') s[key] = v;
  }
  for (const [key, values] of Object.entries(ENUMS) as [keyof typeof ENUMS, readonly string[]][]) {
    const v = raw[key];
    if (typeof v === 'string' && values.includes(v)) (s as unknown as Record<string, unknown>)[key] = v;
  }
  if (typeof raw['deviceName'] === 'string') s.deviceName = Array.from(raw['deviceName']).slice(0, 40).join('');
  if (typeof raw['deckPage'] === 'string') s.deckPage = raw['deckPage'].slice(0, 128);
  if ('threeFinger' in raw) s.threeFinger = validGestureMap(raw['threeFinger'], defaultThreeFinger());
  if ('fourFinger' in raw) s.fourFinger = validGestureMap(raw['fourFinger'], defaultFourFinger());
  return s;
}

/** "Reset" keeps the device name, the tab and the deck page. */
export function resetSettings(current: Settings): Settings {
  const d = defaultSettings();
  d.deviceName = current.deviceName;
  d.tab = current.tab;
  d.deckPage = current.deckPage;
  return d;
}

// ---- Sync blob ---------------------------------------------------------------

/** Keys that stay on this device. `language` is a local UI choice too. */
const LOCAL_ONLY = new Set<string>(['version', 'deviceName', 'rememberDevice', 'tab', 'deckPage', 'language']);

export interface SyncBlob {
  version: 1;
  settings: Record<string, unknown>;
  keyboards: Board[];
}

export function syncableSettings(s: Settings): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(s)) if (!LOCAL_ONLY.has(k)) out[k] = v;
  return out;
}

export function makeBlob(s: Settings, boards: Board[]): SyncBlob {
  return { version: 1, settings: syncableSettings(s), keyboards: boards };
}

/** Applies a blob from the Mac; returns null if it is not a usable blob. */
export function applyBlob(
  blob: unknown,
  current: Settings,
): { settings: Settings; keyboards: Board[] | null } | null {
  if (!isObj(blob) || !isObj(blob['settings'])) return null;
  const incoming: Record<string, unknown> = { ...blob['settings'] };
  for (const k of LOCAL_ONLY) delete incoming[k];
  const merged = validateSettings({ ...current, ...incoming }, current);
  // Invalid 3/4-finger actions fall back to the defaults rather than the current values.
  if ('threeFinger' in incoming) merged.threeFinger = validGestureMap(incoming['threeFinger'], defaultThreeFinger());
  if ('fourFinger' in incoming) merged.fourFinger = validGestureMap(incoming['fourFinger'], defaultFourFinger());
  for (const k of LOCAL_ONLY) (merged as unknown as Record<string, unknown>)[k] = (current as unknown as Record<string, unknown>)[k];
  return { settings: merged, keyboards: validateBoardList(blob['keyboards']) };
}

/** FNV-1a, 32 bits, over the UTF-8 bytes of `text`. */
export function fnv1a(text: string): number {
  let h = 0x811c9dc5;
  const bytes = new TextEncoder().encode(text);
  for (const b of bytes) {
    h ^= b;
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

function stripIds(boards: Board[]): unknown[] {
  return boards.map(({ id: _id, keys, ...rest }) => ({
    ...rest,
    keys: keys.map(({ id: _kid, ...k }) => k),
  }));
}

export function blobHash(blob: SyncBlob): string {
  return fnv1a(JSON.stringify(blob.settings) + JSON.stringify(stripIds(blob.keyboards))).toString(16).padStart(8, '0');
}

/** Strictly increasing timestamp in ms. */
export function nextUpdatedAt(prev: number, now: number = Date.now()): number {
  return Math.max(Math.floor(now), prev + 1);
}

export const SETTINGS_MAX_BYTES = 131072;
