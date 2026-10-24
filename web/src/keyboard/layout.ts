// Keyboard layout helpers: a US fallback, the character map used to type a
// character with the Mac's active layout, and DOM `code` to Mac keycodes.
import type { KeyboardLayout, KeyCap } from '../protocol/types';

export const KEY = {
  Return: 36,
  Tab: 48,
  Space: 49,
  Delete: 51,
  Escape: 53,
  CapsLock: 57,
  ForwardDelete: 117,
  Home: 115,
  End: 119,
  PageUp: 116,
  PageDown: 121,
  Left: 123,
  Right: 124,
  Down: 125,
  Up: 126,
  Equal: 24,
  Minus: 27,
} as const;

export const F_KEYS = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111] as const;
/** F13-F20. */
export const F_KEYS_EXTRA = [105, 107, 113, 106, 64, 79, 80, 90] as const;

// base, shift for the 51 layout keycodes of a US ANSI keyboard.
const US: Record<number, [string, string]> = {
  0: ['a', 'A'], 1: ['s', 'S'], 2: ['d', 'D'], 3: ['f', 'F'], 4: ['h', 'H'], 5: ['g', 'G'],
  6: ['z', 'Z'], 7: ['x', 'X'], 8: ['c', 'C'], 9: ['v', 'V'], 10: ['§', '±'], 11: ['b', 'B'],
  12: ['q', 'Q'], 13: ['w', 'W'], 14: ['e', 'E'], 15: ['r', 'R'], 16: ['y', 'Y'], 17: ['t', 'T'],
  18: ['1', '!'], 19: ['2', '@'], 20: ['3', '#'], 21: ['4', '$'], 22: ['6', '^'], 23: ['5', '%'],
  24: ['=', '+'], 25: ['9', '('], 26: ['7', '&'], 27: ['-', '_'], 28: ['8', '*'], 29: ['0', ')'],
  30: [']', '}'], 31: ['o', 'O'], 32: ['u', 'U'], 33: ['[', '{'], 34: ['i', 'I'], 35: ['p', 'P'],
  37: ['l', 'L'], 38: ['j', 'J'], 39: ["'", '"'], 40: ['k', 'K'], 41: [';', ':'], 42: ['\\', '|'],
  43: [',', '<'], 44: ['/', '?'], 45: ['n', 'N'], 46: ['m', 'M'], 47: ['.', '>'], 50: ['`', '~'],
};

export const US_LAYOUT: KeyboardLayout = {
  id: 'com.apple.keylayout.US',
  name: 'U.S.',
  iso: false,
  keys: Object.entries(US).map(([code, [base, shift]]) => ({
    code: Number(code),
    base,
    shift,
    option: '',
    optionShift: '',
    dead: 0,
  })),
};

export function capFor(layout: KeyboardLayout, code: number): KeyCap | undefined {
  return layout.keys.find((k) => k.code === code) ?? US_LAYOUT.keys.find((k) => k.code === code);
}

export interface KeyStroke {
  code: number;
  mods: number;
}

const printable = (s: string): boolean => {
  const cps = Array.from(s);
  if (cps.length !== 1) return false;
  const c = cps[0]?.codePointAt(0) ?? 0;
  return c >= 0x20 && !(c >= 0x7f && c <= 0x9f);
};

const popcount = (n: number): number => {
  let c = 0;
  for (let x = n; x; x &= x - 1) c++;
  return c;
};

/**
 * Character to key map. Levels are visited optionShift, option, shift, base;
 * dead or non-printable levels are skipped; an existing entry is replaced
 * only by a combination with fewer modifier bits.
 */
export function charMap(layout: KeyboardLayout): Map<string, KeyStroke> {
  const map = new Map<string, KeyStroke>();
  const levels: [keyof Pick<KeyCap, 'optionShift' | 'option' | 'shift' | 'base'>, number, number][] = [
    ['optionShift', 6, 8],
    ['option', 4, 4],
    ['shift', 2, 2],
    ['base', 0, 1],
  ];
  for (const cap of layout.keys) {
    for (const [field, mods, deadBit] of levels) {
      if (cap.dead & deadBit) continue;
      const ch = cap[field];
      if (!printable(ch)) continue;
      const prev = map.get(ch);
      if (!prev || popcount(mods) < popcount(prev.mods)) map.set(ch, { code: cap.code, mods });
    }
  }
  return map;
}

/** Key for a character with the layout, also trying the lowercase form + Shift. */
export function strokeFor(map: Map<string, KeyStroke>, ch: string): KeyStroke | null {
  const direct = map.get(ch);
  if (direct) return direct;
  const lower = ch.toLowerCase();
  if (lower !== ch) {
    const l = map.get(lower);
    if (l && l.mods === 0) return { code: l.code, mods: 2 };
  }
  return null;
}

/** Label shown on a key for the active modifier mask. */
export function labelFor(cap: KeyCap | undefined, shift: boolean, option: boolean): string {
  if (!cap) return '';
  let s = cap.base;
  if (shift && option) s = cap.optionShift || cap.option || cap.shift || cap.base;
  else if (option) s = cap.option || cap.base;
  else if (shift) s = cap.shift || cap.base.toUpperCase();
  return s.trim() === '' ? '' : s;
}

/** KeyboardEvent.code to Mac virtual keycode. */
export const DOM_CODE_TO_MAC: Record<string, number> = {
  KeyA: 0, KeyS: 1, KeyD: 2, KeyF: 3, KeyH: 4, KeyG: 5, KeyZ: 6, KeyX: 7, KeyC: 8, KeyV: 9,
  IntlBackslash: 10, KeyB: 11, KeyQ: 12, KeyW: 13, KeyE: 14, KeyR: 15, KeyY: 16, KeyT: 17,
  Digit1: 18, Digit2: 19, Digit3: 20, Digit4: 21, Digit6: 22, Digit5: 23, Equal: 24, Digit9: 25,
  Digit7: 26, Minus: 27, Digit8: 28, Digit0: 29, BracketRight: 30, KeyO: 31, KeyU: 32,
  BracketLeft: 33, KeyI: 34, KeyP: 35, Enter: 36, KeyL: 37, KeyJ: 38, Quote: 39, KeyK: 40,
  Semicolon: 41, Backslash: 42, Comma: 43, Slash: 44, KeyN: 45, KeyM: 46, Period: 47, Tab: 48,
  Space: 49, Backquote: 50, Backspace: 51, Escape: 53, MetaRight: 54, MetaLeft: 55,
  ShiftLeft: 56, CapsLock: 57, AltLeft: 58, ControlLeft: 59, ShiftRight: 60, AltRight: 61,
  ControlRight: 62, Fn: 63, F1: 122, F2: 120, F3: 99, F4: 118, F5: 96, F6: 97, F7: 98, F8: 100,
  F9: 101, F10: 109, F11: 103, F12: 111, Home: 115, PageUp: 116, Delete: 117, End: 119,
  PageDown: 121, ArrowLeft: 123, ArrowRight: 124, ArrowDown: 125, ArrowUp: 126,
  NumpadEnter: 76, IntlYen: 93, IntlRo: 94,
};
