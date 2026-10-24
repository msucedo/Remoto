import { describe, expect, it } from 'vitest';
import { actionDepth, validateAction, validateDeck, validColor, newId } from '../src/deck/validate';
import type { Action, Deck } from '../src/protocol/types';
import { deckColumns } from '../src/views/deck-columns';

const deck = (over: Partial<Deck['pages'][number]> = {}): Deck => ({
  version: 1,
  pages: [{ id: 'p', name: 'Page', columns: 4, tiles: [{ id: 't', label: 'Copy', action: { kind: 'system', name: 'copy' } }], ...over }],
});

const nest = (levels: number): Action => {
  let a: Action = { kind: 'delay', ms: 10 };
  for (let i = 0; i < levels; i++) a = { kind: 'sequence', steps: [a] };
  return a;
};

describe('deck validation', () => {
  it('accepts a valid deck', () => expect(validateDeck(deck())).toBeNull());
  it('version must be 1', () => expect(validateDeck({ ...deck(), version: 2 })).toBe('version'));
  it('needs 1 to 24 pages', () => {
    expect(validateDeck({ version: 1, pages: [] })).toBe('tooMany');
    const pages = Array.from({ length: 25 }, (_, i) => ({ id: `p${i}`, name: '', columns: 4, tiles: [] }));
    expect(validateDeck({ version: 1, pages })).toBe('tooMany');
  });
  it('columns between 1 and 8', () => {
    expect(validateDeck(deck({ columns: 9 }))).toBe('columns');
    expect(validateDeck(deck({ columns: 0 }))).toBe('columns');
  });
  it('64 tiles at most', () => {
    const tiles = Array.from({ length: 65 }, (_, i) => ({ id: `t${i}`, label: '', action: { kind: 'media', key: 'mute' } as Action }));
    expect(validateDeck(deck({ tiles }))).toBe('tooMany');
  });
  it('labels of 80 characters (not bytes)', () => {
    expect(validateDeck(deck({ name: 'ñ'.repeat(80) }))).toBeNull();
    expect(validateDeck(deck({ name: 'x'.repeat(81) }))).toBe('labelTooLong');
  });
  it('ids of 128 bytes', () => expect(validateDeck(deck({ id: 'x'.repeat(129) }))).toBe('idTooLong'));
  it('colors', () => {
    expect(validColor('#12')).toBe(false);
    expect(validColor('#1234')).toBe(true);
    expect(validColor('#abc')).toBe(true);
    expect(validColor('#a1b2c3d4')).toBe(true);
    expect(validColor('#xyz')).toBe(false);
    expect(validateDeck(deck({ tiles: [{ id: 't', label: '', color: '#12', action: { kind: 'media', key: 'mute' } }] }))).toBe('color');
  });
  it('icons', () => {
    expect(validateDeck(deck({ tiles: [{ id: 't', label: '', icon: { kind: 'emoji', text: 'x'.repeat(65) }, action: { kind: 'media', key: 'mute' } }] }))).toBe('icon');
  });
});

describe('action validation', () => {
  it('keys', () => {
    expect(validateAction({ kind: 'keys', code: 8, mods: 1, char: 'c' })).toBeNull();
    expect(validateAction({ kind: 'keys', code: 0x100 })).toBe('invalidKey');
    expect(validateAction({ kind: 'keys', code: 1, mods: 0x100 })).toBe('invalidKey');
    expect(validateAction({ kind: 'keys', code: 1, mods: 0x20 })).toBe('invalidKey');
    expect(validateAction({ kind: 'keys', code: 1, char: 'x'.repeat(17) })).toBe('invalidKey');
  });
  it('text and url', () => {
    expect(validateAction({ kind: 'text', text: 'a'.repeat(4096) })).toBeNull();
    expect(validateAction({ kind: 'text', text: 'é'.repeat(2049) })).toBe('textTooLong');
    expect(validateAction({ kind: 'url', url: 'https://example.com' })).toBeNull();
    expect(validateAction({ kind: 'url', url: 'example.com' })).toBe('url');
    expect(validateAction({ kind: 'url', url: 'Mailto:a@b.c' })).toBeNull();
  });
  it('app, system, media, shortcut, shell', () => {
    expect(validateAction({ kind: 'app', id: '' })).toBe('appId');
    expect(validateAction({ kind: 'app', id: 'com.apple.Safari', op: 'quit' })).toBeNull();
    expect(validateAction({ kind: 'app', id: 'x', op: 'explode' })).toBe('appId');
    expect(validateAction({ kind: 'system', name: 'missionControl' })).toBeNull();
    expect(validateAction({ kind: 'system', name: 'nope' })).toBe('system');
    expect(validateAction({ kind: 'media', key: 'illuminationToggle' })).toBeNull();
    expect(validateAction({ kind: 'shortcut', name: ' ' })).toBe('shortcut');
    expect(validateAction({ kind: 'shell', command: 'ls' })).toBeNull();
  });
  it('mouse and delay', () => {
    expect(validateAction({ kind: 'mouse', button: 'left', clicks: 3 })).toBeNull();
    expect(validateAction({ kind: 'mouse', button: 'left', clicks: 4 })).toBe('mouse');
    expect(validateAction({ kind: 'delay', ms: 10000 })).toBeNull();
    expect(validateAction({ kind: 'delay', ms: 10001 })).toBe('delay');
  });
  it('sequences allow three levels and 64 steps', () => {
    expect(validateAction(nest(3))).toBeNull();
    expect(validateAction(nest(4))).toBe('depth');
    expect(actionDepth(nest(3))).toBe(3);
    const steps = Array.from({ length: 65 }, () => ({ kind: 'delay', ms: 1 }) as Action);
    expect(validateAction({ kind: 'sequence', steps })).toBe('steps');
    expect(validateAction({ kind: 'sequence', steps: steps.slice(0, 64) })).toBeNull();
    expect(validateAction({ kind: 'sequence', steps: [{ kind: 'bogus' }] })).toBe('kind');
  });
  it('unknown kinds', () => expect(validateAction({ kind: 'teleport' })).toBe('kind'));
});

describe('deck helpers', () => {
  it('new ids use the prefix and 10 base36 characters', () => {
    expect(newId('t')).toMatch(/^t-[0-9a-z]{10}$/);
    expect(newId('p')).toMatch(/^p-[0-9a-z]{10}$/);
  });
  it('displayed columns scale with width and button size', () => {
    expect(deckColumns(4, 360, 1)).toBe(4);
    expect(deckColumns(4, 732, 1)).toBe(8);
    expect(deckColumns(4, 360, 1.6)).toBe(3);
    expect(deckColumns(8, 2000, 0.7)).toBe(12);
    expect(deckColumns(1, 100, 1.6)).toBe(1);
  });
});
