// Key picker: type a character (resolved with the Mac's layout) or pick a
// special key, plus modifier chips and a preview.
import type { App } from '../app';
import { t } from '../i18n';
import { h } from '../ui/dom';
import { chip, errorLine, fieldBlock, nextId } from '../ui/controls';
import { capFor, F_KEYS, F_KEYS_EXTRA, KEY } from '../keyboard/layout';

export interface KeyValue {
  code: number;
  mods: number;
  char?: string;
}

const SPECIALS: { code: number; label: string }[] = [
  { code: KEY.Return, label: '⏎ Return' },
  { code: KEY.Tab, label: '⇥ Tab' },
  { code: KEY.Space, label: '␣ Space' },
  { code: KEY.Delete, label: '⌫ Delete' },
  { code: KEY.ForwardDelete, label: '⌦ Forward Delete' },
  { code: KEY.Escape, label: 'esc Escape' },
  { code: KEY.Left, label: '← Left' },
  { code: KEY.Right, label: '→ Right' },
  { code: KEY.Up, label: '↑ Up' },
  { code: KEY.Down, label: '↓ Down' },
  { code: KEY.Home, label: '↖ Home' },
  { code: KEY.End, label: '↘ End' },
  { code: KEY.PageUp, label: '⇞ Page Up' },
  { code: KEY.PageDown, label: '⇟ Page Down' },
  ...F_KEYS.map((code, i) => ({ code, label: `F${i + 1}` })),
  ...F_KEYS_EXTRA.map((code, i) => ({ code, label: `F${i + 13}` })),
];

export const MOD_CHIPS: { bit: number; symbol: string }[] = [
  { bit: 0x08, symbol: '⌃' },
  { bit: 0x04, symbol: '⌥' },
  { bit: 0x02, symbol: '⇧' },
  { bit: 0x01, symbol: '⌘' },
  { bit: 0x10, symbol: 'fn' },
];

export function modsLabel(mods: number): string {
  return MOD_CHIPS.filter((m) => mods & m.bit)
    .map((m) => m.symbol)
    .join('');
}

export function keyName(app: App | null, code: number, char?: string): string {
  if (char) return char.toUpperCase();
  const sp = SPECIALS.find((s) => s.code === code);
  if (sp) return sp.label.split(' ')[0] ?? sp.label;
  const cap = app ? capFor(app.layout, code) : undefined;
  return cap?.base ? cap.base.toUpperCase() : `#${code}`;
}

export function comboLabel(app: App | null, v: KeyValue): string {
  return `${modsLabel(v.mods)}${keyName(app, v.code, v.char)}`;
}

export function createKeyPicker(
  app: App,
  initial: KeyValue,
  onChange: (v: KeyValue) => void,
): { el: HTMLElement; valid(): boolean } {
  let value: KeyValue = { ...initial };
  let ok = true;
  const err = errorLine();
  const preview = h('div', { class: 'key-preview', attrs: { 'aria-live': 'polite' } });

  const charInput = h('input', {
    class: 'field char-field',
    type: 'text',
    attrs: { autocomplete: 'off', autocapitalize: 'off', spellcheck: 'false', 'aria-label': t('keypick.char') },
  });
  charInput.value = initial.char ?? '';
  const special = h('select', { class: 'select', attrs: { 'aria-label': t('keypick.special') } });
  special.appendChild(h('option', { text: t('keypick.specialNone'), attrs: { value: '' } }));
  for (const s of SPECIALS) {
    const o = h('option', { text: s.label, attrs: { value: String(s.code) } });
    if (!initial.char && s.code === initial.code) o.selected = true;
    special.appendChild(o);
  }
  if (!initial.char && !SPECIALS.some((s) => s.code === initial.code)) {
    // A plain key stored without its character: show it from the layout.
    const cap = capFor(app.layout, initial.code);
    if (cap?.base) charInput.value = cap.base;
  }

  const chips = h('div', { class: 'mod-chips', role: 'group', attrs: { 'aria-label': t('keypick.mods') } });
  const chipEls = MOD_CHIPS.map((m) => {
    const c = chip(m.symbol, (value.mods & m.bit) !== 0, (on) => {
      value = { ...value, mods: on ? value.mods | m.bit : value.mods & ~m.bit };
      emit();
    });
    chips.appendChild(c);
    return { c, m };
  });

  const emit = () => {
    preview.textContent = comboLabel(app, value);
    for (const { c, m } of chipEls) c.setAttribute('aria-pressed', String((value.mods & m.bit) !== 0));
    err.set(ok ? null : t('keypick.noKey'));
    if (ok) onChange({ ...value });
  };

  charInput.addEventListener('input', () => {
    const chars = Array.from(charInput.value);
    const ch = chars[chars.length - 1] ?? '';
    charInput.value = ch;
    if (!ch) return;
    special.value = '';
    const stroke = app.stroke(ch);
    if (!stroke) {
      ok = false;
      emit();
      return;
    }
    ok = true;
    const shift = stroke.mods & 0x02;
    const opt = stroke.mods & 0x04;
    const plain = (value.mods & ~0x06) | shift | opt;
    value = { code: stroke.code, mods: plain };
    const lower = ch.toLowerCase();
    if (/\p{L}/u.test(ch) && Array.from(ch).length === 1) value.char = lower;
    emit();
  });
  special.addEventListener('change', () => {
    if (!special.value) return;
    charInput.value = '';
    ok = true;
    value = { code: Number(special.value), mods: value.mods };
    emit();
  });

  const charId = nextId('kc');
  charInput.id = charId;
  const top = h(
    'div',
    { class: 'key-picker-top' },
    h('div', { class: 'field-block' }, h('label', { class: 'field-label', text: t('keypick.char'), attrs: { for: charId } }), charInput),
    fieldBlock(t('keypick.special'), special),
  );
  emit();
  const el = h('div', { class: 'editor' }, top, err, fieldBlock(t('keypick.mods'), chips), preview);
  return { el, valid: () => ok };
}
