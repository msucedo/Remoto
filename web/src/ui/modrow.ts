// Row of sticky modifiers (esc, tab, ctrl, opt, shift, cmd) and helpers to
// bind keys to pointer presses.
import type { App } from '../app';
import { t } from '../i18n';
import type { Modifier } from '../input/modifiers';
import { KEY } from '../keyboard/layout';
import { h } from './dom';
import { icon } from './icons';

/** Calls down/up for a pointer press on `el` (multi-touch safe). */
export function bindPress(el: HTMLElement, down: () => void, up: () => void): () => void {
  let pointer: number | null = null;
  const onDown = (e: PointerEvent) => {
    if (e.pointerType === 'mouse' && e.button !== 0) return;
    if (pointer !== null) return;
    e.preventDefault();
    pointer = e.pointerId;
    try {
      el.setPointerCapture(e.pointerId);
    } catch {
      // ignore
    }
    el.classList.add('pressed');
    down();
  };
  const onUp = (e: PointerEvent) => {
    if (e.pointerId !== pointer) return;
    pointer = null;
    el.classList.remove('pressed');
    up();
  };
  const onKey = (e: KeyboardEvent) => {
    if (e.key !== 'Enter' && e.key !== ' ') return;
    e.preventDefault();
    e.stopPropagation();
    if (e.type === 'keydown' && !e.repeat) down();
    if (e.type === 'keyup') up();
  };
  const ctx = (e: Event) => e.preventDefault();
  el.addEventListener('pointerdown', onDown);
  el.addEventListener('pointerup', onUp);
  el.addEventListener('pointercancel', onUp);
  el.addEventListener('lostpointercapture', onUp);
  el.addEventListener('keydown', onKey);
  el.addEventListener('keyup', onKey);
  el.addEventListener('contextmenu', ctx);
  return () => {
    if (pointer !== null) {
      pointer = null;
      el.classList.remove('pressed');
      up();
    }
    el.removeEventListener('pointerdown', onDown);
    el.removeEventListener('pointerup', onUp);
    el.removeEventListener('pointercancel', onUp);
    el.removeEventListener('lostpointercapture', onUp);
    el.removeEventListener('keydown', onKey);
    el.removeEventListener('keyup', onKey);
    el.removeEventListener('contextmenu', ctx);
  };
}

/** Binds a modifier key element to the shared machine and reflects its state. */
export function bindModifier(app: App, el: HTMLElement, mod: Modifier): () => void {
  const off1 = bindPress(
    el,
    () => {
      app.haptic('select');
      app.mods.press(mod);
    },
    () => app.mods.release(mod),
  );
  const paint = () => {
    const st = app.mods.state(mod);
    el.dataset['mod'] = st;
    el.setAttribute('aria-pressed', String(st !== 'off'));
  };
  const off2 = app.mods.onChange(paint);
  paint();
  return () => {
    off1();
    off2();
  };
}

/** Binds a plain key (sent with the sticky modifiers). */
export function bindKey(app: App, el: HTMLElement, code: number): () => void {
  return bindPress(
    el,
    () => {
      app.haptic('select');
      app.keyDown(code);
    },
    () => app.keyUp(code),
  );
}

export function modifierRow(app: App, opts: { onKeyboard?: () => void } = {}): { el: HTMLElement; dispose(): void } {
  const offs: (() => void)[] = [];
  const el = h('div', { class: 'mod-row', role: 'group', attrs: { 'aria-label': t('mods.row') } });
  const mk = (label: string, aria: string) =>
    h('div', { class: 'key', role: 'button', tabIndex: 0, text: label, attrs: { 'aria-label': aria } });

  const esc = mk('esc', t('key.escape'));
  const tab = mk('⇥', t('key.tab'));
  offs.push(bindKey(app, esc, KEY.Escape), bindKey(app, tab, KEY.Tab));
  el.append(esc, tab);
  const mods: [Modifier, string, string][] = [
    ['ctrl', '⌃', t('key.control')],
    ['opt', '⌥', t('key.option')],
    ['shift', '⇧', t('key.shift')],
    ['cmd', '⌘', t('key.command')],
  ];
  for (const [m, sym, aria] of mods) {
    const k = mk(sym, aria);
    offs.push(bindModifier(app, k, m));
    el.appendChild(k);
  }
  if (opts.onKeyboard) {
    const open = opts.onKeyboard;
    const kb = h(
      'button',
      { class: 'key kb-open', type: 'button', title: t('compose.open'), attrs: { 'aria-label': t('compose.open') } },
      icon('keyboard', 20),
    );
    kb.addEventListener('click', open);
    el.appendChild(kb);
  }
  return {
    el,
    dispose() {
      for (const f of offs) f();
    },
  };
}
