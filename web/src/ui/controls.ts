// Form controls used by settings and editors.
import { h } from './dom';
import { icon } from './icons';

let uid = 0;
export const nextId = (p = 'c'): string => `${p}-${++uid}`;

export function button(
  label: string,
  onClick: () => void,
  opts: { variant?: 'primary' | 'danger' | 'link' | 'small' | 'small-primary'; icon?: string; disabled?: boolean } = {},
): HTMLButtonElement {
  const cls = ['btn'];
  if (opts.variant === 'primary') cls.push('btn-primary');
  if (opts.variant === 'danger') cls.push('btn-danger');
  if (opts.variant === 'link') cls.push('btn-link');
  if (opts.variant === 'small') cls.push('btn-small');
  if (opts.variant === 'small-primary') cls.push('btn-small', 'btn-primary');
  const b = h('button', { class: cls.join(' '), type: 'button', disabled: opts.disabled ?? false });
  if (opts.icon) b.appendChild(icon(opts.icon, 18));
  b.appendChild(document.createTextNode(label));
  b.addEventListener('click', onClick);
  return b;
}

export function iconButton(
  name: string,
  label: string,
  onClick: (ev: MouseEvent) => void,
  opts: { cls?: string; size?: number } = {},
): HTMLButtonElement {
  const b = h(
    'button',
    { class: `icon-btn${opts.cls ? ` ${opts.cls}` : ''}`, type: 'button', title: label, attrs: { 'aria-label': label } },
    icon(name, opts.size ?? 20),
  );
  b.addEventListener('click', onClick);
  return b;
}

export function toggleSwitch(checked: boolean, onChange: (v: boolean) => void, label?: string): HTMLButtonElement {
  const b = h('button', {
    class: 'switch',
    type: 'button',
    role: 'switch',
    attrs: { 'aria-checked': String(checked), 'aria-label': label },
  });
  b.appendChild(h('span', { class: 'switch-knob' }));
  b.addEventListener('click', () => {
    const v = b.getAttribute('aria-checked') !== 'true';
    b.setAttribute('aria-checked', String(v));
    onChange(v);
  });
  return b;
}

export interface Segmented<T extends string> {
  el: HTMLElement;
  set(v: T): void;
}

export function segmented<T extends string>(
  options: readonly { value: T; label: string }[],
  value: T,
  onChange: (v: T) => void,
  label: string,
): Segmented<T> {
  const el = h('div', { class: 'segmented', role: 'tablist', attrs: { 'aria-label': label } });
  const buttons = options.map((o) => {
    const b = h('button', {
      class: 'seg-opt',
      type: 'button',
      role: 'tab',
      text: o.label,
      attrs: { 'aria-selected': String(o.value === value) },
    });
    b.addEventListener('click', () => {
      set(o.value);
      onChange(o.value);
    });
    el.appendChild(b);
    return b;
  });
  const set = (v: T) => {
    options.forEach((o, i) => buttons[i]?.setAttribute('aria-selected', String(o.value === v)));
  };
  return { el, set };
}

export function chip(label: string, pressed: boolean, onToggle: (v: boolean) => void): HTMLButtonElement {
  const b = h('button', { class: 'chip', type: 'button', text: label, attrs: { 'aria-pressed': String(pressed) } });
  b.addEventListener('click', () => {
    const v = b.getAttribute('aria-pressed') !== 'true';
    b.setAttribute('aria-pressed', String(v));
    onToggle(v);
  });
  return b;
}

export function select<T extends string>(
  options: readonly { value: T; label: string }[],
  value: T,
  onChange: (v: T) => void,
  label?: string,
): HTMLSelectElement {
  const s = h('select', { class: 'select', attrs: { 'aria-label': label } });
  for (const o of options) {
    const opt = h('option', { text: o.label, attrs: { value: o.value } });
    if (o.value === value) opt.selected = true;
    s.appendChild(opt);
  }
  s.addEventListener('change', () => onChange(s.value as T));
  return s;
}

export function textField(
  value: string,
  onInput: (v: string) => void,
  opts: { placeholder?: string; maxLength?: number; mono?: boolean; type?: string; label?: string } = {},
): HTMLInputElement {
  const i = h('input', {
    class: `field${opts.mono ? ' mono' : ''}`,
    type: opts.type ?? 'text',
    attrs: {
      placeholder: opts.placeholder,
      maxlength: opts.maxLength,
      'aria-label': opts.label,
      autocomplete: 'off',
      autocapitalize: 'off',
      spellcheck: 'false',
    },
  });
  i.value = value;
  i.addEventListener('input', () => onInput(i.value));
  return i;
}

export function textArea(
  value: string,
  onInput: (v: string) => void,
  opts: { placeholder?: string; mono?: boolean; rows?: number; label?: string } = {},
): HTMLTextAreaElement {
  const ta = h('textarea', {
    class: `field textarea${opts.mono ? ' mono' : ''}`,
    attrs: { placeholder: opts.placeholder, rows: opts.rows ?? 3, 'aria-label': opts.label, spellcheck: opts.mono ? 'false' : undefined },
  });
  ta.value = value;
  ta.addEventListener('input', () => onInput(ta.value));
  return ta;
}

/** Labeled field block: label above control, optional error line. */
export function fieldBlock(label: string, control: HTMLElement, error?: HTMLElement): HTMLElement {
  const id = control.id || nextId('f');
  control.id = id;
  return h('div', { class: 'field-block' }, h('label', { class: 'field-label', text: label, attrs: { for: id } }), control, error);
}

export function errorLine(): HTMLElement & { set(msg: string | null): void } {
  const el = h('div', { class: 'error-line', attrs: { 'aria-live': 'polite' } }) as unknown as HTMLElement & {
    set(msg: string | null): void;
  };
  el.set = (msg) => {
    el.textContent = msg ?? '';
    el.hidden = !msg;
  };
  el.hidden = true;
  return el;
}

// ---- Settings rows ------------------------------------------------------------

export function group(title: string, ...rows: HTMLElement[]): HTMLElement {
  return h('section', { class: 'group' }, h('h3', { class: 'group-title', text: title }), h('div', { class: 'group-body' }, ...rows));
}

export function switchRow(label: string, checked: boolean, onChange: (v: boolean) => void, hint?: string): HTMLElement {
  const sw = toggleSwitch(checked, onChange, label);
  return h('div', { class: 'row' }, h('div', { class: 'row-label' }, h('span', { text: label }), hint ? h('small', { class: 'row-hint', text: hint }) : null), sw);
}

export function selectRow<T extends string>(
  label: string,
  options: readonly { value: T; label: string }[],
  value: T,
  onChange: (v: T) => void,
): HTMLElement {
  const s = select(options, value, onChange, label);
  return h('div', { class: 'row' }, h('span', { class: 'row-label', text: label }), s);
}

export function sliderRow(
  label: string,
  value: number,
  range: readonly [number, number],
  step: number,
  onChange: (v: number) => void,
): HTMLElement {
  const out = h('output', { class: 'row-value', text: value.toFixed(2) });
  const input = h('input', {
    class: 'slider',
    type: 'range',
    attrs: { min: range[0], max: range[1], step, 'aria-label': label },
  });
  input.value = String(value);
  input.addEventListener('input', () => {
    const v = Number(input.value);
    out.textContent = v.toFixed(2);
    onChange(v);
  });
  return h('div', { class: 'row row-stack' }, h('div', { class: 'row-top' }, h('span', { class: 'row-label', text: label }), out), input);
}

export function textRow(label: string, control: HTMLElement): HTMLElement {
  const id = control.id || nextId('t');
  control.id = id;
  return h('div', { class: 'row row-stack' }, h('label', { class: 'row-label', text: label, attrs: { for: id } }), control);
}

export function linkRow(label: string, value: string, onClick: () => void): HTMLElement {
  const b = h(
    'button',
    { class: 'row row-link', type: 'button' },
    h('span', { class: 'row-label', text: label }),
    h('span', { class: 'row-value-text', text: value }),
    icon('chevron-right', 16),
  );
  b.addEventListener('click', onClick);
  return b;
}

export function infoRow(label: string, value: string): HTMLElement {
  return h('div', { class: 'row' }, h('span', { class: 'row-label', text: label }), h('span', { class: 'row-value-text', text: value }));
}
