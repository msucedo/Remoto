import { describe, expect, it } from 'vitest';
import { en } from '../src/i18n/en';
import { es } from '../src/i18n/es';
import { detectLanguage, format } from '../src/i18n';
import { DENY_REASONS, MEDIA_KEYS, MOUSE_BUTTONS, SYSTEM_ACTIONS, APP_OPS, ACTION_KINDS } from '../src/protocol/types';
import type { DeckError } from '../src/deck/validate';
import { DICTATION_ERROR_KEYS } from '../src/voice/dictation-keys';

const placeholders = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();

describe('i18n dictionaries', () => {
  const enKeys = Object.keys(en).sort();
  const esKeys = Object.keys(es).sort();

  it('have the same keys', () => expect(esKeys).toEqual(enKeys));

  it('have no empty strings', () => {
    for (const k of enKeys) {
      expect(en[k as keyof typeof en].trim(), `en ${k}`).not.toBe('');
      expect(es[k as keyof typeof es].trim(), `es ${k}`).not.toBe('');
    }
  });

  it('use the same placeholders in both languages', () => {
    for (const k of enKeys) {
      expect(placeholders(es[k as keyof typeof es]), k).toEqual(placeholders(en[k as keyof typeof en]));
    }
  });

  it('cover every enum shown in the UI', () => {
    const need = [
      ...SYSTEM_ACTIONS.map((x) => `system.${x}`),
      ...MEDIA_KEYS.map((x) => `media.${x}`),
      ...MOUSE_BUTTONS.map((x) => `mouse.${x}`),
      ...APP_OPS.map((x) => `appop.${x}`),
      ...ACTION_KINDS.map((x) => `kind.${x}`),
      ...DICTATION_ERROR_KEYS,
    ];
    const errors: DeckError[] = [
      'version', 'tooMany', 'idTooLong', 'labelTooLong', 'columns', 'color', 'icon', 'invalidKey', 'textTooLong',
      'mediaKey', 'appId', 'url', 'system', 'shortcut', 'command', 'mouse', 'delay', 'steps', 'depth', 'kind',
    ];
    need.push(...errors.map((e) => `err.${e}`));
    for (const k of need) expect(enKeys, k).toContain(k);
    for (const r of DENY_REASONS) {
      if (r === 'unknown' || r === 'rejected') continue;
      expect(enKeys.some((k) => k === `deny.${r}`), r).toBe(true);
    }
  });

  it('avoid exclamation marks and emojis in system text', () => {
    for (const dict of [en, es]) {
      for (const [k, v] of Object.entries(dict)) {
        expect(/[!¡]/.test(v), k).toBe(false);
        expect(/\p{Extended_Pictographic}/u.test(v), k).toBe(false);
      }
    }
  });
});

describe('language detection and formatting', () => {
  it('picks Spanish for any es-* locale', () => {
    expect(detectLanguage(['es-MX'])).toBe('es');
    expect(detectLanguage(['fr-FR', 'es'])).toBe('es');
    expect(detectLanguage(['en-GB'])).toBe('en');
    expect(detectLanguage(['de'])).toBe('en');
  });
  it('formats placeholders', () => {
    expect(format('Hola {name}, {n} s', { name: 'Ana', n: 3 })).toBe('Hola Ana, 3 s');
    expect(format('{missing}', {})).toBe('{missing}');
  });
});
