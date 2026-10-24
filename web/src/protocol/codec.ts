// JSON encoding of client messages and defensive decoding of server messages.
import {
  DENY_REASONS,
  NOTICE_LEVELS,
  PROTOCOL_VERSION,
  VOICE_STATES,
  type Action,
  type AppInfo,
  type AppOp,
  type Auth,
  type ClientMessage,
  type Deck,
  type DeviceInfo,
  type Features,
  type KeyboardLayout,
  type KeyCap,
  type MediaKey,
  type MouseButton,
  type NoticeLevel,
  type PressOp,
  type ServerMessage,
  type SettingsDevice,
  type TextMode,
  type VoiceState,
  type WelcomeMessage,
} from './types';

/** Serializes a client message. Optional fields left undefined are omitted. */
export function encode(msg: ClientMessage): string {
  return JSON.stringify(msg);
}

// ---- Builders (keep field order stable and drop defaults) --------------------

export const out = {
  hello(device: DeviceInfo, auth: Auth, remember: boolean): ClientMessage {
    return { t: 'hello', v: PROTOCOL_VERSION, device, auth, remember };
  },
  ping(id: number): ClientMessage {
    return { t: 'ping', id };
  },
  key(code: number, down: boolean, mods = 0, repeat = false): ClientMessage {
    const m: ClientMessage = { t: 'key', code, down };
    if (mods) m.mods = mods;
    if (repeat) m.repeat = true;
    return m;
  },
  tap(code: number, mods = 0): ClientMessage {
    return mods ? { t: 'tap', code, mods } : { t: 'tap', code };
  },
  button(button: MouseButton, op: PressOp): ClientMessage {
    return { t: 'button', button, op };
  },
  media(key: MediaKey, op: PressOp = 'click'): ClientMessage {
    return op === 'click' ? { t: 'media', key } : { t: 'media', key, op };
  },
  volume(state: { value?: number; muted?: boolean }): ClientMessage {
    const m: { t: 'volume'; value?: number; muted?: boolean } = { t: 'volume' };
    if (state.value !== undefined && Number.isFinite(state.value)) {
      m.value = Math.min(1, Math.max(0, state.value));
    }
    if (state.muted !== undefined) m.muted = state.muted;
    return m;
  },
  text(text: string, mode: TextMode = 'unicode'): ClientMessage {
    return mode === 'unicode' ? { t: 'text', text } : { t: 'text', text, mode };
  },
  edit(del: number, insert: string): ClientMessage {
    return { t: 'edit', delete: del, insert };
  },
  release(): ClientMessage {
    return { t: 'release' };
  },
  action(action: Action, id?: number): ClientMessage {
    return id === undefined ? { t: 'action', action } : { t: 'action', action, id };
  },
  apps(): ClientMessage {
    return { t: 'apps' };
  },
  appAction(id: string, op: AppOp = 'toggle'): ClientMessage {
    return { t: 'appAction', id, op };
  },
  deckSave(deck: Deck): ClientMessage {
    return { t: 'deckSave', deck };
  },
  voiceStart(locale?: string): ClientMessage {
    return locale ? { t: 'voiceStart', locale } : { t: 'voiceStart' };
  },
  voiceStop(cancel: boolean): ClientMessage {
    return { t: 'voiceStop', cancel };
  },
  clipboardSet(text: string): ClientMessage {
    return { t: 'clipboardSet', text };
  },
  clipboardGet(): ClientMessage {
    return { t: 'clipboardGet' };
  },
  settingsSave(settings: unknown, updatedAt: number): ClientMessage {
    return { t: 'settingsSave', settings, updatedAt };
  },
  settingsList(): ClientMessage {
    return { t: 'settingsList' };
  },
  settingsCopy(from: string): ClientMessage {
    return { t: 'settingsCopy', from };
  },
};

// ---- Decoding ----------------------------------------------------------------

type Obj = Record<string, unknown>;

export function isObj(v: unknown): v is Obj {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}
const str = (v: unknown): v is string => typeof v === 'string';
const bool = (v: unknown): v is boolean => typeof v === 'boolean';
const num = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v);

function oneOf<T extends string>(list: readonly T[], v: unknown): v is T {
  return typeof v === 'string' && (list as readonly string[]).includes(v);
}

function decodeFeatures(v: unknown): Features | null {
  if (!isObj(v)) return null;
  return {
    voice: v['voice'] === true,
    shell: v['shell'] === true,
    secure: v['secure'] === true,
    permission: v['permission'] !== false,
  };
}

export function decodeLayout(v: unknown): KeyboardLayout | null {
  if (!isObj(v) || !Array.isArray(v['keys'])) return null;
  const keys: KeyCap[] = [];
  for (const k of v['keys']) {
    if (!isObj(k) || !num(k['code'])) continue;
    keys.push({
      code: k['code'],
      base: str(k['base']) ? k['base'] : '',
      shift: str(k['shift']) ? k['shift'] : '',
      option: str(k['option']) ? k['option'] : '',
      optionShift: str(k['optionShift']) ? k['optionShift'] : '',
      dead: num(k['dead']) ? k['dead'] : 0,
    });
  }
  return {
    id: str(v['id']) ? v['id'] : '',
    name: str(v['name']) ? v['name'] : '',
    iso: v['iso'] === true,
    keys,
  };
}

/** Shallow structural check; the deck validator does the full job. */
export function looksLikeDeck(v: unknown): v is Deck {
  return isObj(v) && num(v['version']) && Array.isArray(v['pages']);
}

function decodeApps(v: unknown): AppInfo[] | null {
  if (!Array.isArray(v)) return null;
  const apps: AppInfo[] = [];
  for (const a of v) {
    if (!isObj(a) || !str(a['id'])) continue;
    apps.push({
      id: a['id'],
      name: str(a['name']) ? a['name'] : a['id'],
      running: a['running'] === true,
      active: a['active'] === true,
      hidden: a['hidden'] === true,
    });
  }
  return apps;
}

function decodeWelcome(o: Obj): WelcomeMessage | null {
  const host = o['host'];
  const features = decodeFeatures(o['features']);
  if (!isObj(host) || !features || !looksLikeDeck(o['deck'])) return null;
  const msg: WelcomeMessage = {
    t: 'welcome',
    v: num(o['v']) ? o['v'] : 0,
    host: {
      name: str(host['name']) ? host['name'] : '',
      version: str(host['version']) ? host['version'] : '',
      os: str(host['os']) ? host['os'] : '',
    },
    sessionKey: str(o['sessionKey']) ? o['sessionKey'] : '',
    token: str(o['token']) ? o['token'] : null,
    features,
    deck: o['deck'],
    paused: o['paused'] === true,
  };
  const layout = o['layout'] === undefined ? null : decodeLayout(o['layout']);
  if (layout) msg.layout = layout;
  const vol = o['volume'];
  if (isObj(vol) && num(vol['value'])) msg.volume = { value: vol['value'], muted: vol['muted'] === true };
  const s = o['settings'];
  if (isObj(s) && num(s['updatedAt'])) msg.settings = { settings: s['settings'], updatedAt: s['updatedAt'] };
  return msg;
}

/** Parses one text frame. Returns null for invalid JSON or unknown types. */
export function decode(text: string): ServerMessage | null {
  let o: unknown;
  try {
    o = JSON.parse(text);
  } catch {
    return null;
  }
  return decodeValue(o);
}

export function decodeValue(o: unknown): ServerMessage | null {
  if (!isObj(o) || !str(o['t'])) return null;
  switch (o['t']) {
    case 'welcome':
      return decodeWelcome(o);
    case 'pending':
      return { t: 'pending' };
    case 'denied': {
      const reason = str(o['reason']) ? o['reason'] : 'rejected';
      const ra = o['retryAfter'];
      return num(ra) && ra >= 1
        ? { t: 'denied', reason, retryAfter: Math.ceil(ra) }
        : { t: 'denied', reason };
    }
    case 'pong':
      return { t: 'pong', id: o['id'] };
    case 'apps': {
      const apps = decodeApps(o['apps']);
      return apps ? { t: 'apps', apps } : null;
    }
    case 'appsChanged':
      return { t: 'appsChanged' };
    case 'deck':
      return looksLikeDeck(o['deck']) ? { t: 'deck', deck: o['deck'] } : null;
    case 'layout': {
      const layout = decodeLayout(o['layout']);
      return layout ? { t: 'layout', layout } : null;
    }
    case 'volume':
      return num(o['value']) ? { t: 'volume', value: o['value'], muted: o['muted'] === true } : null;
    case 'volumeUnavailable':
      return { t: 'volumeUnavailable' };
    case 'paused':
      return bool(o['paused']) ? { t: 'paused', paused: o['paused'] } : null;
    case 'features': {
      const features = decodeFeatures(o['features']);
      return features ? { t: 'features', features } : null;
    }
    case 'notice': {
      const level: NoticeLevel = oneOf(NOTICE_LEVELS, o['level']) ? o['level'] : 'info';
      const message = str(o['message']) ? o['message'] : '';
      return str(o['code'])
        ? { t: 'notice', level, code: o['code'], message }
        : { t: 'notice', level, message };
    }
    case 'actionResult': {
      if (!bool(o['ok'])) return null;
      const m: { t: 'actionResult'; id?: unknown; ok: boolean; message?: string } = { t: 'actionResult', ok: o['ok'] };
      if (o['id'] !== undefined && o['id'] !== null) m.id = o['id'];
      if (str(o['message'])) m.message = o['message'];
      return m;
    }
    case 'clipboard':
      return { t: 'clipboard', text: str(o['text']) ? o['text'] : null };
    case 'bye':
      return { t: 'bye', reason: str(o['reason']) ? o['reason'] : '', reconnect: o['reconnect'] === true };
    case 'voice': {
      if (!oneOf(VOICE_STATES, o['state'])) return null;
      const m: { t: 'voice'; state: VoiceState; text?: string; final: boolean; message?: string } = {
        t: 'voice',
        state: o['state'],
        final: o['final'] === true,
      };
      if (str(o['text'])) m.text = o['text'];
      if (str(o['message'])) m.message = o['message'];
      return m;
    }
    case 'settings':
      return num(o['updatedAt']) ? { t: 'settings', settings: o['settings'], updatedAt: o['updatedAt'] } : null;
    case 'settingsList': {
      if (!Array.isArray(o['devices'])) return null;
      const devices: SettingsDevice[] = [];
      for (const d of o['devices']) {
        if (!isObj(d) || !str(d['id'])) continue;
        devices.push({
          id: d['id'],
          name: str(d['name']) ? d['name'] : '',
          model: str(d['model']) ? d['model'] : '',
          updatedAt: num(d['updatedAt']) ? d['updatedAt'] : 0,
        });
      }
      return { t: 'settingsList', devices };
    }
    default:
      return null;
  }
}

export function isKnownDenyReason(r: string): r is (typeof DENY_REASONS)[number] {
  return (DENY_REASONS as readonly string[]).includes(r);
}
