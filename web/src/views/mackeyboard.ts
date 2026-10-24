// Virtual Mac keyboard (ANSI or ISO) with labels from the Mac's layout.
import type { App } from '../app';
import type { Action, MediaKey } from '../protocol/types';
import { t } from '../i18n';
import { h, Scope } from '../ui/dom';
import { icon } from '../ui/icons';
import { capFor, F_KEYS, KEY, labelFor } from '../keyboard/layout';
import type { Modifier } from '../input/modifiers';

type KeyDef =
  | { kind: 'char'; code: number; w?: number }
  | { kind: 'special'; code: number; w?: number; label: string; aria?: string; iconName?: string }
  | { kind: 'mod'; mod: Modifier; w?: number; label: string; aria: string }
  | { kind: 'fn'; index: number }
  | { kind: 'arrows' };

const MEDIA_ROW: ({ media: MediaKey } | { action: Action })[] = [
  { media: 'brightnessDown' },
  { media: 'brightnessUp' },
  { action: { kind: 'system', name: 'missionControl' } },
  { action: { kind: 'system', name: 'spotlight' } },
  { media: 'illuminationDown' },
  { media: 'illuminationUp' },
  { media: 'previous' },
  { media: 'playPause' },
  { media: 'next' },
  { media: 'mute' },
  { media: 'volumeDown' },
  { media: 'volumeUp' },
];
const MEDIA_ICONS = ['sun-dim', 'sun', 'layout-grid', 'search', 'lightbulb', 'lightbulb', 'skip-back', 'play', 'skip-forward', 'volume-x', 'volume-1', 'volume-2'];

const chars = (codes: number[]): KeyDef[] => codes.map((code) => ({ kind: 'char', code }));

function rows(iso: boolean): KeyDef[][] {
  const fnRow: KeyDef[] = [
    { kind: 'special', code: KEY.Escape, w: 1.5, label: 'esc', aria: 'key.escape' },
    ...Array.from({ length: 12 }, (_, i): KeyDef => ({ kind: 'fn', index: i })),
  ];
  const numberRow: KeyDef[] = [
    ...chars([iso ? 10 : 50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24]),
    { kind: 'special', code: KEY.Delete, w: 1.5, label: '⌫', aria: 'key.delete' },
  ];
  const qRow: KeyDef[] = [
    { kind: 'special', code: KEY.Tab, w: 1.5, label: '⇥', aria: 'key.tab' },
    ...chars([12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30]),
    iso ? { kind: 'special', code: KEY.Return, w: 1, label: '⏎', aria: 'key.return' } : { kind: 'char', code: 42 },
  ];
  const aRow: KeyDef[] = [
    { kind: 'special', code: KEY.CapsLock, w: 1.8, label: '⇪', aria: 'key.capsLock' },
    ...chars([0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39]),
    ...(iso
      ? ([{ kind: 'char', code: 42 }, { kind: 'special', code: KEY.Return, w: 0.7, label: '', aria: 'key.return' }] as KeyDef[])
      : ([{ kind: 'special', code: KEY.Return, w: 1.7, label: '⏎', aria: 'key.return' }] as KeyDef[])),
  ];
  const zRow: KeyDef[] = [
    { kind: 'mod', mod: 'shift', w: iso ? 1.3 : 2.3, label: '⇧', aria: 'key.shift' },
    ...(iso ? chars([50]) : []),
    ...chars([6, 7, 8, 9, 11, 45, 46, 43, 47, 44]),
    { kind: 'mod', mod: 'rshift', w: 2.3, label: '⇧', aria: 'key.rightShift' },
  ];
  const bottom: KeyDef[] = [
    { kind: 'mod', mod: 'fn', label: 'fn', aria: 'key.fn' },
    { kind: 'mod', mod: 'ctrl', label: '⌃', aria: 'key.control' },
    { kind: 'mod', mod: 'opt', label: '⌥', aria: 'key.option' },
    { kind: 'mod', mod: 'cmd', w: 1.3, label: '⌘', aria: 'key.command' },
    { kind: 'special', code: KEY.Space, w: 5, label: '', aria: 'key.space' },
    { kind: 'mod', mod: 'rcmd', w: 1.3, label: '⌘', aria: 'key.rightCommand' },
    { kind: 'mod', mod: 'ropt', label: '⌥', aria: 'key.rightOption' },
    { kind: 'special', code: KEY.Left, label: '←', aria: 'key.left' },
    { kind: 'arrows' },
    { kind: 'special', code: KEY.Right, label: '→', aria: 'key.right' },
  ];
  return [fnRow, numberRow, qRow, aRow, zRow, bottom];
}

interface Bound {
  el: HTMLElement;
  press(): void;
  release(): void;
}

export function createMacKeyboard(app: App): { el: HTMLElement; releaseAll(): void; dispose(): void } {
  const scope = new Scope();
  const el = h('div', { class: 'mac-kb', role: 'group', attrs: { 'aria-label': t('kb.mac') } });
  const bound = new Map<HTMLElement, Bound>();
  const codeCount = new Map<number, number>();
  const pointers = new Map<number, Bound>();
  const charKeys: { el: HTMLElement; code: number }[] = [];
  const fnKeys: { el: HTMLElement; index: number }[] = [];
  const modKeys: { el: HTMLElement; mod: Modifier }[] = [];

  const codeDown = (code: number) => {
    const n = codeCount.get(code) ?? 0;
    codeCount.set(code, n + 1);
    if (n === 0) app.keyDown(code);
  };
  const codeUp = (code: number) => {
    const n = codeCount.get(code) ?? 0;
    if (n <= 0) return;
    codeCount.set(code, n - 1);
    if (n === 1) app.keyUp(code);
  };

  const mediaMode = () => (app.settings.functionRow === 'media') !== (app.mods.state('fn') !== 'off');

  const makeKey = (def: KeyDef): HTMLElement => {
    if (def.kind === 'arrows') {
      const up = makeKey({ kind: 'special', code: KEY.Up, label: '↑', aria: 'key.up' });
      const down = makeKey({ kind: 'special', code: KEY.Down, label: '↓', aria: 'key.down' });
      return h('div', { class: 'kb-arrows', style: 'flex-grow:1' }, up, down);
    }
    const w = def.kind === 'fn' ? 1.0833 : (def.w ?? 1);
    const k = h('div', { class: 'key', role: 'button', style: `flex-grow:${w}` });
    let b: Bound;
    if (def.kind === 'char' || def.kind === 'special') {
      const code = def.code;
      if (def.kind === 'special') {
        k.textContent = def.label;
        k.setAttribute('aria-label', t(def.aria as Parameters<typeof t>[0]));
      } else {
        charKeys.push({ el: k, code });
      }
      b = {
        el: k,
        press: () => {
          app.haptic('select');
          codeDown(code);
        },
        release: () => codeUp(code),
      };
    } else if (def.kind === 'mod') {
      k.textContent = def.label;
      k.setAttribute('aria-label', t(def.aria as Parameters<typeof t>[0]));
      modKeys.push({ el: k, mod: def.mod });
      const mod = def.mod;
      b = {
        el: k,
        press: () => {
          app.haptic('select');
          app.mods.press(mod);
        },
        release: () => app.mods.release(mod),
      };
    } else {
      const index = def.index;
      fnKeys.push({ el: k, index });
      let sentCode: number | null = null;
      b = {
        el: k,
        press: () => {
          app.haptic('select');
          if (mediaMode()) {
            const m = MEDIA_ROW[index];
            if (m && 'media' in m) app.media(m.media);
            else if (m) app.fireAction(m.action);
          } else {
            sentCode = F_KEYS[index] ?? null;
            if (sentCode !== null) codeDown(sentCode);
          }
        },
        release: () => {
          if (sentCode !== null) codeUp(sentCode);
          sentCode = null;
        },
      };
    }
    bound.set(k, b);
    return k;
  };

  const layoutRows = () => {
    releaseAll();
    el.replaceChildren();
    bound.clear();
    charKeys.length = 0;
    fnKeys.length = 0;
    modKeys.length = 0;
    rows(app.layout.iso).forEach((r, i) => {
      const row = h('div', { class: `kb-row${i === 0 ? ' fn-row' : ''}` });
      for (const def of r) row.appendChild(makeKey(def));
      el.appendChild(row);
    });
    paint();
  };

  const paint = () => {
    const shift = app.mods.state('shift') !== 'off' || app.mods.state('rshift') !== 'off';
    const opt = app.mods.state('opt') !== 'off' || app.mods.state('ropt') !== 'off';
    for (const { el: k, code } of charKeys) {
      const cap = capFor(app.layout, code);
      const label = labelFor(cap, shift, opt);
      k.textContent = label;
      k.setAttribute('aria-label', label || t('key.unnamed'));
    }
    const media = mediaMode();
    for (const { el: k, index } of fnKeys) {
      if (media) {
        k.replaceChildren(icon(MEDIA_ICONS[index] ?? 'square', 16));
        const m = MEDIA_ROW[index];
        k.setAttribute('aria-label', m && 'media' in m ? t(`media.${m.media}`) : t(index === 2 ? 'system.missionControl' : 'system.spotlight'));
      } else {
        k.textContent = `F${index + 1}`;
        k.setAttribute('aria-label', `F${index + 1}`);
      }
    }
    for (const { el: k, mod } of modKeys) k.dataset['mod'] = app.mods.state(mod);
  };

  const keyAt = (x: number, y: number): Bound | null => {
    const hit = document.elementFromPoint(x, y);
    const direct = hit instanceof HTMLElement ? hit.closest('.key') : null;
    if (direct instanceof HTMLElement && bound.has(direct)) return bound.get(direct) ?? null;
    let best: Bound | null = null;
    let bestD = 24;
    for (const [k, b] of bound) {
      const r = k.getBoundingClientRect();
      const dx = Math.max(r.left - x, 0, x - r.right);
      const dy = Math.max(r.top - y, 0, y - r.bottom);
      const d = Math.hypot(dx, dy);
      if (d <= bestD) {
        bestD = d;
        best = b;
      }
    }
    return best;
  };

  scope.listen(el, 'pointerdown', (ev) => {
    const e = ev as PointerEvent;
    if (e.pointerType === 'mouse' && e.button !== 0) return;
    const b = keyAt(e.clientX, e.clientY);
    if (!b) return;
    e.preventDefault();
    try {
      el.setPointerCapture(e.pointerId);
    } catch {
      // ignore
    }
    pointers.set(e.pointerId, b);
    b.el.classList.add('pressed');
    b.press();
  });
  const end = (ev: Event) => {
    const e = ev as PointerEvent;
    const b = pointers.get(e.pointerId);
    if (!b) return;
    pointers.delete(e.pointerId);
    if (![...pointers.values()].includes(b)) b.el.classList.remove('pressed');
    b.release();
  };
  scope.listen(el, 'pointerup', end);
  scope.listen(el, 'pointercancel', end);
  scope.listen(el, 'contextmenu', (e) => e.preventDefault());

  const releaseAll = () => {
    for (const b of pointers.values()) {
      b.el.classList.remove('pressed');
      b.release();
    }
    pointers.clear();
    for (const [code, n] of codeCount) if (n > 0) app.keyUp(code);
    codeCount.clear();
  };

  scope.add(app.mods.onChange(paint));
  scope.add(app.events.on('layout', layoutRows));
  scope.add(app.events.on('settings', paint));
  scope.add(app.events.on('suspend', releaseAll));
  layoutRows();

  return { el, releaseAll, dispose: () => { releaseAll(); scope.dispose(); } };
}
