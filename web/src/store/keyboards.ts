// Custom keyboards: model, validation and the built-in templates.
import { isObj } from '../protocol/codec';
import { MEDIA_KEYS, type MediaKey } from '../protocol/types';

export const MOD_NAMES = ['ctrl', 'opt', 'shift', 'cmd', 'fn'] as const;
export type ModName = (typeof MOD_NAMES)[number];

export type KeyAction =
  | { kind: 'key'; code: number; mods: number }
  | { kind: 'mod'; mod: ModName }
  | { kind: 'media'; key: MediaKey }
  | { kind: 'mouse'; button: 'left' | 'right' | 'middle' };

export interface BoardKey {
  id: string;
  x: number;
  y: number;
  w: number;
  h: number;
  action: KeyAction;
  label?: string;
}

export interface Board {
  id: string;
  name: string;
  cols: number;
  rows: number;
  trackpad: boolean;
  keys: BoardKey[];
}

export interface KeyboardsState {
  active: string;
  boards: Board[];
}

export const BOARD_LIMITS = { boards: 24, name: 32, id: 32, label: 12, cols: [2, 12], rows: [1, 8] } as const;

const int = (v: unknown, lo: number, hi: number): v is number =>
  typeof v === 'number' && Number.isInteger(v) && v >= lo && v <= hi;
const chars = (s: string) => Array.from(s).length;

export function validKeyAction(a: unknown): a is KeyAction {
  if (!isObj(a)) return false;
  switch (a['kind']) {
    case 'key':
      return int(a['code'], 0, 127) && int(a['mods'], 0, 31);
    case 'mod':
      return (MOD_NAMES as readonly unknown[]).includes(a['mod']);
    case 'media':
      return (MEDIA_KEYS as readonly unknown[]).includes(a['key']);
    case 'mouse':
      return a['button'] === 'left' || a['button'] === 'right' || a['button'] === 'middle';
    default:
      return false;
  }
}

export type KeyPlacementError = 'outside' | 'overlap' | null;

/** Checks that `key` fits the grid and does not overlap the others. */
export function placementError(board: Pick<Board, 'cols' | 'rows' | 'keys'>, key: BoardKey): KeyPlacementError {
  if (key.w < 1 || key.h < 1 || key.x < 0 || key.y < 0) return 'outside';
  if (key.x + key.w > board.cols || key.y + key.h > board.rows) return 'outside';
  for (const k of board.keys) {
    if (k.id === key.id) continue;
    const overlap = key.x < k.x + k.w && k.x < key.x + key.w && key.y < k.y + k.h && k.y < key.y + key.h;
    if (overlap) return 'overlap';
  }
  return null;
}

export function validBoard(b: unknown): b is Board {
  if (!isObj(b)) return false;
  if (typeof b['id'] !== 'string' || b['id'].length === 0 || chars(b['id']) > BOARD_LIMITS.id) return false;
  if (typeof b['name'] !== 'string' || chars(b['name']) > BOARD_LIMITS.name) return false;
  if (!int(b['cols'], 2, 12) || !int(b['rows'], 1, 8)) return false;
  if (typeof b['trackpad'] !== 'boolean' || !Array.isArray(b['keys'])) return false;
  const placed: BoardKey[] = [];
  const ids = new Set<string>();
  for (const k of b['keys']) {
    if (!isObj(k)) return false;
    if (typeof k['id'] !== 'string' || k['id'].length === 0 || chars(k['id']) > BOARD_LIMITS.id || ids.has(k['id'])) {
      return false;
    }
    if (![k['x'], k['y'], k['w'], k['h']].every((n) => int(n, 0, 12))) return false;
    if (!validKeyAction(k['action'])) return false;
    if (k['label'] !== undefined && (typeof k['label'] !== 'string' || chars(k['label']) > BOARD_LIMITS.label)) {
      return false;
    }
    const key = k as unknown as BoardKey;
    if (placementError({ cols: b['cols'], rows: b['rows'], keys: placed }, key)) return false;
    ids.add(key.id);
    placed.push(key);
  }
  return true;
}

export function validateKeyboards(v: unknown): KeyboardsState {
  const boards: Board[] = [];
  if (isObj(v) && Array.isArray(v['boards'])) {
    for (const b of v['boards']) {
      if (boards.length >= BOARD_LIMITS.boards) break;
      if (validBoard(b) && !boards.some((x) => x.id === b.id)) boards.push(structuredClone(b));
    }
  }
  const active = isObj(v) && typeof v['active'] === 'string' && boards.some((b) => b.id === v['active']) ? v['active'] : boards[0]?.id ?? '';
  return { active, boards };
}

/** Validates boards coming from another device or the Mac. Invalid ones are dropped. */
export function validateBoardList(v: unknown): Board[] | null {
  if (!Array.isArray(v)) return null;
  return validateKeyboards({ boards: v }).boards;
}

export function shortId(prefix: string): string {
  const a = new Uint8Array(8);
  globalThis.crypto.getRandomValues(a);
  return `${prefix}${Array.from(a, (b) => (b % 36).toString(36)).join('')}`;
}

/** First free cell for a 1x1 key, or null when the grid is full. */
export function freeCell(board: Board): { x: number; y: number } | null {
  for (let y = 0; y < board.rows; y++) {
    for (let x = 0; x < board.cols; x++) {
      const probe: BoardKey = { id: '\u0000probe', x, y, w: 1, h: 1, action: { kind: 'key', code: 0, mods: 0 } };
      if (!placementError(board, probe)) return { x, y };
    }
  }
  return null;
}

// ---- Templates ------------------------------------------------------------------

export type TemplateId = 'presentation' | 'gamepad' | 'editing';
export const TEMPLATE_IDS: readonly TemplateId[] = ['presentation', 'gamepad', 'editing'];

const k = (x: number, y: number, w: number, h: number, action: KeyAction, label?: string): Omit<BoardKey, 'id'> =>
  label === undefined ? { x, y, w, h, action } : { x, y, w, h, action, label };
const key = (code: number, mods = 0): KeyAction => ({ kind: 'key', code, mods });

const TEMPLATES: Record<TemplateId, { cols: number; rows: number; trackpad: boolean; keys: Omit<BoardKey, 'id'>[] }> = {
  presentation: {
    cols: 4,
    rows: 3,
    trackpad: false,
    keys: [
      k(0, 0, 2, 2, key(123), '◀'),
      k(2, 0, 2, 2, key(124), '▶'),
      k(0, 2, 1, 1, key(53), 'esc'),
      k(1, 2, 1, 1, key(11), 'B'),
      k(2, 2, 1, 1, key(36, 9), '⌘⌃⏎'),
      k(3, 2, 1, 1, key(17), 'T'),
    ],
  },
  gamepad: {
    cols: 6,
    rows: 3,
    trackpad: false,
    keys: [
      k(1, 0, 1, 1, key(126), '↑'),
      k(0, 1, 1, 1, key(123), '←'),
      k(2, 1, 1, 1, key(124), '→'),
      k(1, 2, 1, 1, key(125), '↓'),
      k(4, 0, 1, 1, key(13), 'W'),
      k(3, 1, 1, 1, key(0), 'A'),
      k(5, 1, 1, 1, key(2), 'D'),
      k(4, 2, 1, 1, key(1), 'S'),
      k(3, 2, 1, 1, key(49), '␣'),
      k(5, 2, 1, 1, { kind: 'mod', mod: 'shift' }),
      k(3, 0, 1, 1, key(53), 'esc'),
      k(5, 0, 1, 1, key(36), '⏎'),
    ],
  },
  editing: {
    cols: 4,
    rows: 3,
    trackpad: true,
    keys: [
      k(0, 0, 1, 1, key(6, 1), '⌘Z'),
      k(1, 0, 1, 1, key(6, 3), '⌘⇧Z'),
      k(2, 0, 1, 1, key(7, 1), '⌘X'),
      k(3, 0, 1, 1, key(8, 1), '⌘C'),
      k(0, 1, 1, 1, key(9, 1), '⌘V'),
      k(1, 1, 1, 1, key(0, 1), '⌘A'),
      k(2, 1, 1, 1, key(1, 1), '⌘S'),
      k(3, 1, 1, 1, key(3, 1), '⌘F'),
      k(0, 2, 1, 1, { kind: 'mod', mod: 'cmd' }),
      k(1, 2, 1, 1, { kind: 'mod', mod: 'shift' }),
      k(2, 2, 1, 1, key(51), '⌫'),
      k(3, 2, 1, 1, key(36), '⏎'),
    ],
  },
};

export function boardFromTemplate(id: TemplateId, name: string): Board {
  const t = TEMPLATES[id];
  return {
    id: shortId('b-'),
    name: name.slice(0, BOARD_LIMITS.name),
    cols: t.cols,
    rows: t.rows,
    trackpad: t.trackpad,
    keys: t.keys.map((kk) => ({ ...kk, id: shortId('k-') })),
  };
}

export function emptyBoard(name: string): Board {
  return { id: shortId('b-'), name: name.slice(0, BOARD_LIMITS.name), cols: 4, rows: 3, trackpad: false, keys: [] };
}
