// Client-side validation of decks and actions. Mirrors the limits the Mac
// enforces so problems are reported before saving.
import {
  APP_OPS,
  MEDIA_KEYS,
  MOUSE_BUTTONS,
  SYSTEM_ACTIONS,
  type Action,
  type Deck,
  type DeckPage,
  type Tile,
  type TileIcon,
} from '../protocol/types';
import { isObj } from '../protocol/codec';

export const DECK_LIMITS = {
  pages: 24,
  tiles: 64,
  label: 80,
  id: 128,
  columns: [1, 8] as const,
  text: 4096,
  url: 4096,
  command: 4096,
  name: 512,
  char: 16,
  steps: 64,
  depth: 2,
  delay: 10000,
  iconApp: 512,
  iconSymbol: 128,
  iconEmoji: 64,
} as const;

/** Error codes; the UI turns them into sentences (i18n `err.*`). */
export type DeckError =
  | 'version'
  | 'tooMany'
  | 'idTooLong'
  | 'labelTooLong'
  | 'columns'
  | 'color'
  | 'icon'
  | 'invalidKey'
  | 'textTooLong'
  | 'mediaKey'
  | 'appId'
  | 'url'
  | 'system'
  | 'shortcut'
  | 'command'
  | 'mouse'
  | 'delay'
  | 'steps'
  | 'depth'
  | 'kind';

const encoder = new TextEncoder();
export const byteLength = (s: string): number => encoder.encode(s).length;
export const charLength = (s: string): number => Array.from(s).length;

const URL_RE = /^[a-z][\w+.-]*:\S+/i;
const COLOR_RE = /^#[0-9a-f]+$/i;

function u(v: unknown, max: number): v is number {
  return typeof v === 'number' && Number.isInteger(v) && v >= 0 && v <= max;
}

export function validateAction(a: unknown, depth = 0): DeckError | null {
  if (!isObj(a) || typeof a['kind'] !== 'string') return 'kind';
  switch (a['kind']) {
    case 'keys': {
      if (!u(a['code'], 0xff)) return 'invalidKey';
      if (a['mods'] !== undefined && !u(a['mods'], 0x1f)) return 'invalidKey';
      if (a['char'] !== undefined && (typeof a['char'] !== 'string' || byteLength(a['char']) > DECK_LIMITS.char)) {
        return 'invalidKey';
      }
      return null;
    }
    case 'text':
      if (typeof a['text'] !== 'string' || byteLength(a['text']) > DECK_LIMITS.text) return 'textTooLong';
      if (a['enter'] !== undefined && typeof a['enter'] !== 'boolean') return 'kind';
      return null;
    case 'media':
      return (MEDIA_KEYS as readonly unknown[]).includes(a['key']) ? null : 'mediaKey';
    case 'app': {
      const id = a['id'];
      if (typeof id !== 'string' || id.length === 0 || byteLength(id) > DECK_LIMITS.name) return 'appId';
      if (a['op'] !== undefined && !(APP_OPS as readonly unknown[]).includes(a['op'])) return 'appId';
      return null;
    }
    case 'url': {
      const url = a['url'];
      if (typeof url !== 'string' || byteLength(url) > DECK_LIMITS.url || !URL_RE.test(url)) return 'url';
      return null;
    }
    case 'system':
      return (SYSTEM_ACTIONS as readonly unknown[]).includes(a['name']) ? null : 'system';
    case 'shortcut': {
      const n = a['name'];
      if (typeof n !== 'string' || n.trim().length === 0 || byteLength(n) > DECK_LIMITS.name) return 'shortcut';
      return null;
    }
    case 'shell': {
      const c = a['command'];
      if (typeof c !== 'string' || c.trim().length === 0 || byteLength(c) > DECK_LIMITS.command) return 'command';
      return null;
    }
    case 'mouse': {
      if (!(MOUSE_BUTTONS as readonly unknown[]).includes(a['button'])) return 'mouse';
      const c = a['clicks'];
      if (c !== undefined && !(typeof c === 'number' && Number.isInteger(c) && c >= 1 && c <= 3)) return 'mouse';
      return null;
    }
    case 'delay':
      return u(a['ms'], DECK_LIMITS.delay) ? null : 'delay';
    case 'sequence': {
      const steps = a['steps'];
      if (!Array.isArray(steps) || steps.length > DECK_LIMITS.steps) return 'steps';
      if (depth > DECK_LIMITS.depth) return 'depth';
      for (const s of steps) {
        const e = validateAction(s, depth + 1);
        if (e) return e;
      }
      return null;
    }
    default:
      return 'kind';
  }
}

export function validateIcon(icon: unknown): DeckError | null {
  if (!isObj(icon)) return 'icon';
  const i = icon as Partial<Record<string, unknown>>;
  switch (i['kind']) {
    case 'app':
      return typeof i['id'] === 'string' && byteLength(i['id']) <= DECK_LIMITS.iconApp ? null : 'icon';
    case 'symbol':
      return typeof i['name'] === 'string' && byteLength(i['name']) <= DECK_LIMITS.iconSymbol ? null : 'icon';
    case 'emoji':
      return typeof i['text'] === 'string' && byteLength(i['text']) <= DECK_LIMITS.iconEmoji ? null : 'icon';
    default:
      return 'icon';
  }
}

export function validColor(c: string): boolean {
  return COLOR_RE.test(c) && [4, 5, 7, 9].includes(c.length);
}

export function validateTile(t: unknown): DeckError | null {
  if (!isObj(t)) return 'kind';
  if (typeof t['id'] !== 'string' || byteLength(t['id']) > DECK_LIMITS.id) return 'idTooLong';
  if (typeof t['label'] !== 'string' || charLength(t['label']) > DECK_LIMITS.label) return 'labelTooLong';
  if (t['color'] !== undefined && (typeof t['color'] !== 'string' || !validColor(t['color']))) return 'color';
  if (t['icon'] !== undefined) {
    const e = validateIcon(t['icon']);
    if (e) return e;
  }
  return validateAction(t['action'], 0);
}

export function validatePage(p: unknown): DeckError | null {
  if (!isObj(p)) return 'kind';
  if (typeof p['id'] !== 'string' || byteLength(p['id']) > DECK_LIMITS.id) return 'idTooLong';
  if (typeof p['name'] !== 'string' || charLength(p['name']) > DECK_LIMITS.label) return 'labelTooLong';
  const c = p['columns'];
  if (!(typeof c === 'number' && Number.isInteger(c) && c >= 1 && c <= 8)) return 'columns';
  if (!Array.isArray(p['tiles']) || p['tiles'].length > DECK_LIMITS.tiles) return 'tooMany';
  for (const t of p['tiles']) {
    const e = validateTile(t);
    if (e) return e;
  }
  return null;
}

export function validateDeck(d: unknown): DeckError | null {
  if (!isObj(d)) return 'version';
  if (d['version'] !== 1) return 'version';
  const pages = d['pages'];
  if (!Array.isArray(pages) || pages.length < 1 || pages.length > DECK_LIMITS.pages) return 'tooMany';
  for (const p of pages) {
    const e = validatePage(p);
    if (e) return e;
  }
  return null;
}

// ---- Helpers for editing ----------------------------------------------------------

export function newId(prefix: 'p' | 't'): string {
  const a = new Uint8Array(10);
  globalThis.crypto.getRandomValues(a);
  return `${prefix}-${Array.from(a, (b) => (b % 36).toString(36)).join('')}`;
}

export function cloneDeck(d: Deck): Deck {
  return structuredClone(d);
}

/** Removes undefined optional fields so the deck serializes cleanly. */
export function cleanTile(t: Tile): Tile {
  const out: Tile = { id: t.id, label: t.label, action: t.action };
  if (t.color) out.color = t.color;
  if (t.icon) out.icon = t.icon as TileIcon;
  return out;
}

export function emptyPage(name: string): DeckPage {
  return { id: newId('p'), name, columns: 4, tiles: [] };
}

export const DEFAULT_KEYS_ACTION: Action = { kind: 'keys', code: 8, mods: 1, char: 'c' };

export function actionDepth(a: Action): number {
  if (a.kind !== 'sequence') return 0;
  let d = 0;
  for (const s of a.steps) d = Math.max(d, actionDepth(s));
  return d + 1;
}
