// Trackpad surface and scroll rail bound to the gesture recognizers.
import type { App } from '../app';
import { out } from '../protocol/codec';
import { TrackpadGestures, type TrackpadSink } from '../input/gestures';
import { ScrollStrip } from '../input/strip';
import { realTimers } from '../net/timers';
import { t } from '../i18n';
import { h } from '../ui/dom';

let hintDismissed = false;

export function padSink(app: App): TrackpadSink {
  return {
    touch: () => app.conn.touch(),
    move: (dx, dy) => app.conn.move(dx, dy),
    scroll: (p, dx, dy) => app.conn.scroll(p, dx, dy),
    fling: (vx, vy) => app.conn.fling(vx, vy),
    button: (b, op) => app.button(b, op),
    click: (b) => {
      app.haptic('select');
      app.click(b);
    },
    zoom: (dir) => app.send(out.tap(dir > 0 ? 24 : 27, 1)),
    action: (a) => app.fireAction(a),
    haptic: (k) => app.haptic(k),
    commitMods: () => app.mods.commitHeld(),
  };
}

export interface Pad {
  el: HTMLElement;
  cancel(): void;
  dispose(): void;
}

export function createPad(app: App, opts: { hint?: boolean; cls?: string } = {}): Pad {
  const el = h('div', {
    class: `pad${opts.cls ? ` ${opts.cls}` : ''}`,
    role: 'application',
    attrs: { 'aria-label': t('pad.label'), 'aria-roledescription': t('pad.role') },
  });
  const hint = opts.hint ? h('div', { class: `pad-hint${hintDismissed ? ' gone' : ''}`, text: t('pad.hint') }) : null;
  if (hint) el.appendChild(hint);
  const gestures = new TrackpadGestures(padSink(app), () => app.settings, realTimers);
  const dots = new Map<number, HTMLElement>();

  const placeDot = (id: number, x: number, y: number) => {
    if (!app.settings.showTouches) return;
    const r = el.getBoundingClientRect();
    let d = dots.get(id);
    if (!d) {
      d = h('div', { class: 'touch-dot' });
      dots.set(id, d);
      el.appendChild(d);
    }
    d.style.transform = `translate(${x - r.left}px, ${y - r.top}px)`;
  };
  const dropDot = (id: number) => {
    dots.get(id)?.remove();
    dots.delete(id);
  };

  const down = (e: PointerEvent) => {
    if (e.pointerType === 'mouse' && e.button !== 0) return;
    e.preventDefault();
    try {
      el.setPointerCapture(e.pointerId);
    } catch {
      // ignore
    }
    if (hint && !hintDismissed) {
      hintDismissed = true;
      hint.classList.add('gone');
    }
    gestures.down(e.pointerId, e.clientX, e.clientY, e.timeStamp);
    placeDot(e.pointerId, e.clientX, e.clientY);
  };
  const move = (e: PointerEvent) => {
    const list = typeof e.getCoalescedEvents === 'function' ? e.getCoalescedEvents() : [];
    const events = list.length ? list : [e];
    for (const c of events) gestures.move(e.pointerId, c.clientX, c.clientY, c.timeStamp || e.timeStamp);
    if (dots.has(e.pointerId)) placeDot(e.pointerId, e.clientX, e.clientY);
  };
  const up = (e: PointerEvent) => {
    gestures.lift(e.pointerId, e.clientX, e.clientY, e.timeStamp);
    dropDot(e.pointerId);
  };
  const cancelPointer = (e: PointerEvent) => {
    dropDot(e.pointerId);
    gestures.cancel();
    for (const id of [...dots.keys()]) dropDot(id);
  };
  el.addEventListener('pointerdown', down);
  el.addEventListener('pointermove', move);
  el.addEventListener('pointerup', up);
  el.addEventListener('pointercancel', cancelPointer);
  el.addEventListener('contextmenu', (e) => e.preventDefault());

  const cancel = () => {
    gestures.cancel();
    for (const id of [...dots.keys()]) dropDot(id);
  };
  const offs = [
    app.events.on('suspend', cancel),
    app.events.on('status', (s) => {
      if (s.state !== 'connected') cancel();
    }),
  ];
  return {
    el,
    cancel,
    dispose() {
      cancel();
      for (const f of offs) f();
    },
  };
}

export function createStrip(app: App): Pad & { refresh(): void } {
  const thumb = h('div', { class: 'strip-thumb' });
  const el = h('div', { class: 'strip', role: 'scrollbar', attrs: { 'aria-label': t('pad.strip'), 'aria-orientation': 'vertical' } }, thumb);
  const strip = new ScrollStrip(
    { touch: () => app.conn.touch(), scroll: (p, dx, dy) => app.conn.scroll(p, dx, dy), fling: (vx, vy) => app.conn.fling(vx, vy) },
    () => app.settings,
    realTimers,
  );
  let pointer: number | null = null;

  const position = (y: number) => {
    const r = el.getBoundingClientRect();
    const top = Math.min(Math.max(y - r.top - 22, 0), Math.max(0, r.height - 44));
    thumb.style.top = `${top}px`;
    const short = app.settings.scrollStrip === 'short';
    let excess = 0;
    if (short && app.settings.scrollHold) {
      if (y < r.top) excess = y - r.top;
      else if (y > r.bottom) excess = y - r.bottom;
    }
    el.classList.toggle('overflow', excess !== 0);
    strip.setOverflow(excess);
  };
  const reset = () => {
    pointer = null;
    el.classList.remove('active', 'overflow');
    thumb.style.top = '';
  };
  el.addEventListener('pointerdown', (e) => {
    if (pointer !== null || (e.pointerType === 'mouse' && e.button !== 0)) return;
    e.preventDefault();
    pointer = e.pointerId;
    try {
      el.setPointerCapture(e.pointerId);
    } catch {
      // ignore
    }
    el.classList.add('active');
    strip.down(e.clientY);
    position(e.clientY);
  });
  el.addEventListener('pointermove', (e) => {
    if (e.pointerId !== pointer) return;
    strip.move(e.clientY, e.timeStamp);
    position(e.clientY);
  });
  el.addEventListener('pointerup', (e) => {
    if (e.pointerId !== pointer) return;
    strip.up(e.timeStamp);
    reset();
  });
  el.addEventListener('pointercancel', (e) => {
    if (e.pointerId !== pointer) return;
    strip.cancel();
    reset();
  });
  const cancel = () => {
    strip.cancel();
    reset();
  };
  const refresh = () => {
    const mode = app.settings.scrollStrip;
    el.hidden = mode === 'off';
    el.classList.toggle('long', mode === 'long');
  };
  refresh();
  const offs = [app.events.on('suspend', cancel), app.events.on('settings', refresh)];
  return {
    el,
    cancel,
    refresh,
    dispose() {
      cancel();
      for (const f of offs) f();
    },
  };
}
