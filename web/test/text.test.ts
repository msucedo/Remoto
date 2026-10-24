import { describe, expect, it } from 'vitest';
import { appendWithSpace, diffGraphemes, graphemeCount, graphemes } from '../src/text/graphemes';
import { charMap, strokeFor, US_LAYOUT, labelFor, capFor } from '../src/keyboard/layout';
import type { KeyboardLayout } from '../src/protocol/types';

describe('graphemes', () => {
  it('keeps clusters together', () => {
    expect(graphemes('éa')).toEqual(['é', 'a']);
    expect(graphemeCount('👨‍👩‍👧‍👦')).toBe(1);
    expect(graphemeCount('🇲🇽🇪🇸')).toBe(2);
    expect(graphemes('')).toEqual([]);
  });
});

describe('diffGraphemes', () => {
  it('appends', () => expect(diffGraphemes('hol', 'hola')).toEqual({ delete: 0, insert: 'a' }));
  it('deletes one grapheme for an emoji', () => expect(diffGraphemes('hi 👍🏽', 'hi ')).toEqual({ delete: 1, insert: '' }));
  it('replaces after the common prefix', () => expect(diffGraphemes('cafe', 'café!')).toEqual({ delete: 1, insert: 'é!' }));
  it('autocorrect rewrites the word', () => expect(diffGraphemes('teh ', 'the ')).toEqual({ delete: 3, insert: 'he ' }));
  it('nothing when equal', () => expect(diffGraphemes('x', 'x')).toBeNull());
  it('combining mark added to the last letter counts as a change of that grapheme', () =>
    expect(diffGraphemes('e', 'é')).toEqual({ delete: 1, insert: 'é' }));
  it('clearing', () => expect(diffGraphemes('ab', '')).toEqual({ delete: 2, insert: '' }));
});

describe('appendWithSpace', () => {
  it('adds a space only when needed', () => {
    expect(appendWithSpace('', 'hola')).toBe('hola');
    expect(appendWithSpace('hola', 'mundo')).toBe('hola mundo');
    expect(appendWithSpace('hola ', ' mundo ')).toBe('hola mundo');
  });
});

describe('layout character map', () => {
  it('maps US characters with the fewest modifiers', () => {
    const map = charMap(US_LAYOUT);
    expect(map.get('a')).toEqual({ code: 0, mods: 0 });
    expect(map.get('A')).toEqual({ code: 0, mods: 2 });
    expect(map.get('_')).toEqual({ code: 27, mods: 2 });
    expect(strokeFor(map, 'Z')).toEqual({ code: 6, mods: 2 });
    expect(strokeFor(map, '€')).toBeNull();
  });
  it('skips dead levels and prefers fewer bits', () => {
    const layout: KeyboardLayout = {
      id: 'x',
      name: 'x',
      iso: false,
      keys: [
        { code: 14, base: 'e', shift: 'E', option: '´', optionShift: '‰', dead: 4 },
        { code: 39, base: '´', shift: '¨', option: '', optionShift: '', dead: 1 },
        { code: 1, base: 's', shift: 'S', option: '´', optionShift: '', dead: 0 },
      ],
    };
    const map = charMap(layout);
    expect(map.get('´')).toEqual({ code: 1, mods: 4 });
    expect(map.get('‰')).toEqual({ code: 14, mods: 6 });
    expect(map.get('¨')).toEqual({ code: 39, mods: 2 });
  });
  it('labels follow shift and option', () => {
    const cap = capFor(US_LAYOUT, 18);
    expect(labelFor(cap, false, false)).toBe('1');
    expect(labelFor(cap, true, false)).toBe('!');
  });
});
