// Tiny i18n: English and Spanish, picked from navigator.language unless forced.
import { en, type MessageKey } from './en';
import { es } from './es';

export type { MessageKey };
export type Lang = 'en' | 'es';

export const DICTIONARIES: Record<Lang, Record<MessageKey, string>> = { en, es };

let current: Lang = 'en';

export function detectLanguage(langs: readonly string[] = globalThis.navigator?.languages ?? []): Lang {
  const list = langs.length ? langs : [globalThis.navigator?.language ?? 'en'];
  for (const l of list) {
    const base = l.toLowerCase().split('-')[0];
    if (base === 'es') return 'es';
    if (base === 'en') return 'en';
  }
  return 'en';
}

export function setLanguage(choice: 'auto' | Lang): Lang {
  current = choice === 'auto' ? detectLanguage() : choice;
  if (typeof document !== 'undefined') document.documentElement.lang = current;
  return current;
}

export function language(): Lang {
  return current;
}

export type Params = Record<string, string | number>;

export function format(template: string, params?: Params): string {
  if (!params) return template;
  return template.replace(/\{(\w+)\}/g, (m, k: string) => (k in params ? String(params[k]) : m));
}

export function t(key: MessageKey, params?: Params): string {
  return format(DICTIONARIES[current][key] ?? en[key], params);
}

/** Relative "updated 5 min ago" text. */
export function ago(ms: number, now = Date.now()): string {
  const s = Math.max(0, Math.round((now - ms) / 1000));
  if (s < 60) return t('time.justNow');
  const m = Math.round(s / 60);
  if (m < 60) return t('time.minutes', { n: m });
  const h = Math.round(m / 60);
  if (h < 48) return t('time.hours', { n: h });
  return t('time.days', { n: Math.round(h / 24) });
}
