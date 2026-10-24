// Wire types for the Remoto protocol, version 1. Identifiers here are
// normative: tags, field names and enum values go on the wire as written.

export const PROTOCOL_VERSION = 1;

export const DENY_REASONS = [
  'unknown',
  'wrongPin',
  'pinClosed',
  'expiredCode',
  'rejected',
  'blocked',
  'busy',
  'incompatible',
] as const;
export type DenyReason = (typeof DENY_REASONS)[number];

export const MOUSE_BUTTONS = ['left', 'right', 'middle', 'back', 'forward'] as const;
export type MouseButton = (typeof MOUSE_BUTTONS)[number];

export const PRESS_OPS = ['click', 'down', 'up'] as const;
export type PressOp = (typeof PRESS_OPS)[number];

export const APP_OPS = ['open', 'toggle', 'hide', 'quit'] as const;
export type AppOp = (typeof APP_OPS)[number];

export const TEXT_MODES = ['unicode', 'keystrokes', 'paste'] as const;
export type TextMode = (typeof TEXT_MODES)[number];

export const MEDIA_KEYS = [
  'volumeUp',
  'volumeDown',
  'mute',
  'brightnessUp',
  'brightnessDown',
  'playPause',
  'next',
  'previous',
  'fastForward',
  'rewind',
  'illuminationUp',
  'illuminationDown',
  'illuminationToggle',
] as const;
export type MediaKey = (typeof MEDIA_KEYS)[number];

export const SYSTEM_ACTIONS = [
  'missionControl',
  'appExpose',
  'showDesktop',
  'launchpad',
  'spotlight',
  'spaceLeft',
  'spaceRight',
  'appSwitcher',
  'lockScreen',
  'sleepDisplay',
  'sleep',
  'screenshot',
  'screenshotArea',
  'screenshotTool',
  'forceQuit',
  'emojiPicker',
  'closeWindow',
  'quitApp',
  'minimize',
  'undo',
  'redo',
  'copy',
  'cut',
  'paste',
  'selectAll',
  'find',
  'newTab',
  'closeTab',
  'nextTab',
  'previousTab',
  'back',
  'forward',
  'reload',
  'zoomIn',
  'zoomOut',
  'actualSize',
  'fullscreen',
  'hideApp',
] as const;
export type SystemAction = (typeof SYSTEM_ACTIONS)[number];

export const NOTICE_LEVELS = ['info', 'warning', 'error'] as const;
export type NoticeLevel = (typeof NOTICE_LEVELS)[number];

export const VOICE_STATES = ['listening', 'stopped', 'unavailable', 'error'] as const;
export type VoiceState = (typeof VOICE_STATES)[number];

/** Scroll phases carried by binary Scroll frames. */
export const ScrollPhase = {
  None: 0,
  Began: 1,
  Changed: 2,
  Ended: 4,
  Cancelled: 8,
} as const;
export type ScrollPhase = (typeof ScrollPhase)[keyof typeof ScrollPhase];

/** Modifier mask bits (`mods`). */
export const Mod = {
  Command: 0x0001,
  Shift: 0x0002,
  Option: 0x0004,
  Control: 0x0008,
  Fn: 0x0010,
  RightCommand: 0x0100,
  RightShift: 0x0200,
  RightOption: 0x0400,
  RightControl: 0x0800,
} as const;

// ---- Actions and deck -------------------------------------------------------

export type Action =
  | { kind: 'keys'; code: number; mods?: number; char?: string }
  | { kind: 'text'; text: string; enter?: boolean }
  | { kind: 'media'; key: MediaKey }
  | { kind: 'app'; id: string; op?: AppOp }
  | { kind: 'url'; url: string }
  | { kind: 'system'; name: SystemAction }
  | { kind: 'shortcut'; name: string }
  | { kind: 'shell'; command: string }
  | { kind: 'mouse'; button: MouseButton; clicks?: number }
  | { kind: 'delay'; ms: number }
  | { kind: 'sequence'; steps: Action[] };
export type ActionKind = Action['kind'];
export const ACTION_KINDS: readonly ActionKind[] = [
  'keys',
  'system',
  'media',
  'app',
  'text',
  'url',
  'shortcut',
  'mouse',
  'sequence',
  'delay',
  'shell',
];

export type TileIcon =
  | { kind: 'symbol'; name: string }
  | { kind: 'emoji'; text: string }
  | { kind: 'app'; id: string };

export interface Tile {
  id: string;
  label: string;
  color?: string;
  icon?: TileIcon;
  action: Action;
}

export interface DeckPage {
  id: string;
  name: string;
  columns: number;
  tiles: Tile[];
}

export interface Deck {
  version: number;
  pages: DeckPage[];
}

// ---- Keyboard layout ---------------------------------------------------------

export interface KeyCap {
  code: number;
  base: string;
  shift: string;
  option: string;
  optionShift: string;
  /** Bit mask of dead levels: 1 base, 2 shift, 4 option, 8 optionShift. */
  dead: number;
}

export interface KeyboardLayout {
  id: string;
  name: string;
  iso: boolean;
  keys: KeyCap[];
}

// ---- Session data -------------------------------------------------------------

export interface Features {
  voice: boolean;
  shell: boolean;
  secure: boolean;
  permission: boolean;
}

export interface HostInfo {
  name: string;
  version: string;
  os: string;
}

export interface VolumeState {
  value: number;
  muted: boolean;
}

export interface AppInfo {
  id: string;
  name: string;
  running: boolean;
  active: boolean;
  hidden: boolean;
}

export interface SettingsEnvelope {
  settings: unknown;
  updatedAt: number;
}

export interface SettingsDevice {
  id: string;
  name: string;
  model: string;
  updatedAt: number;
}

export interface DeviceInfo {
  id: string;
  name: string;
  model: string;
}

export type Auth =
  | { method: 'token'; token: string }
  | { method: 'pair'; code: string }
  | { method: 'pin'; pin: string }
  | { method: 'approve' };
export type AuthMethod = Auth['method'];

// ---- Client to server --------------------------------------------------------

export type ClientMessage =
  | { t: 'hello'; v: number; device: DeviceInfo; auth: Auth; remember: boolean }
  | { t: 'ping'; id: number }
  | { t: 'key'; code: number; down: boolean; mods?: number; repeat?: boolean }
  | { t: 'tap'; code: number; mods?: number }
  | { t: 'button'; button: MouseButton; op: PressOp }
  | { t: 'media'; key: MediaKey; op?: PressOp }
  | { t: 'volume'; value?: number; muted?: boolean }
  | { t: 'text'; text: string; mode?: TextMode }
  | { t: 'edit'; delete: number; insert: string }
  | { t: 'release' }
  | { t: 'action'; action: Action; id?: number }
  | { t: 'apps' }
  | { t: 'appAction'; id: string; op?: AppOp }
  | { t: 'deckSave'; deck: Deck }
  | { t: 'voiceStart'; locale?: string }
  | { t: 'voiceStop'; cancel: boolean }
  | { t: 'clipboardSet'; text: string }
  | { t: 'clipboardGet' }
  | { t: 'settingsSave'; settings: unknown; updatedAt: number }
  | { t: 'settingsList' }
  | { t: 'settingsCopy'; from: string };

// ---- Server to client --------------------------------------------------------

export interface WelcomeMessage {
  t: 'welcome';
  v: number;
  host: HostInfo;
  sessionKey: string;
  token: string | null;
  features: Features;
  deck: Deck;
  layout?: KeyboardLayout;
  volume?: VolumeState;
  paused: boolean;
  settings?: SettingsEnvelope;
}

export type ServerMessage =
  | WelcomeMessage
  | { t: 'pending' }
  | { t: 'denied'; reason: DenyReason | string; retryAfter?: number }
  | { t: 'pong'; id: unknown }
  | { t: 'apps'; apps: AppInfo[] }
  | { t: 'appsChanged' }
  | { t: 'deck'; deck: Deck }
  | { t: 'layout'; layout: KeyboardLayout }
  | { t: 'volume'; value: number; muted: boolean }
  | { t: 'volumeUnavailable' }
  | { t: 'paused'; paused: boolean }
  | { t: 'features'; features: Features }
  | { t: 'notice'; level: NoticeLevel; code?: string; message: string }
  | { t: 'actionResult'; id?: unknown; ok: boolean; message?: string }
  | { t: 'clipboard'; text: string | null }
  | { t: 'bye'; reason: string; reconnect: boolean }
  | { t: 'voice'; state: VoiceState; text?: string; final: boolean; message?: string }
  | { t: 'settings'; settings: unknown; updatedAt: number }
  | { t: 'settingsList'; devices: SettingsDevice[] };

export type ServerMessageType = ServerMessage['t'];
