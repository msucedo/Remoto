// Minimal DOM helpers. No innerHTML with dynamic content anywhere.

type Child = Node | string | number | null | undefined | false;
type Handler = (ev: Event) => void;

export interface Props {
  class?: string;
  id?: string;
  text?: string;
  title?: string;
  role?: string;
  type?: string;
  style?: string;
  hidden?: boolean;
  disabled?: boolean;
  tabIndex?: number;
  dataset?: Record<string, string>;
  attrs?: Record<string, string | number | boolean | null | undefined>;
  on?: Partial<Record<string, Handler>>;
}

export function h<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  props: Props = {},
  ...children: Child[]
): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  if (props.class) el.className = props.class;
  if (props.id) el.id = props.id;
  if (props.text !== undefined) el.textContent = props.text;
  if (props.title) el.title = props.title;
  if (props.role) el.setAttribute('role', props.role);
  if (props.type) el.setAttribute('type', props.type);
  if (props.style) el.setAttribute('style', props.style);
  if (props.hidden) el.hidden = true;
  if (props.disabled) (el as HTMLButtonElement).disabled = true;
  if (props.tabIndex !== undefined) el.tabIndex = props.tabIndex;
  if (props.dataset) for (const [k, v] of Object.entries(props.dataset)) el.dataset[k] = v;
  if (props.attrs) {
    for (const [k, v] of Object.entries(props.attrs)) {
      if (v === null || v === undefined || v === false) continue;
      el.setAttribute(k, v === true ? '' : String(v));
    }
  }
  if (props.on) for (const [ev, fn] of Object.entries(props.on)) if (fn) el.addEventListener(ev, fn);
  append(el, ...children);
  return el;
}

export function append(parent: Node, ...children: Child[]): void {
  for (const c of children) {
    if (c === null || c === undefined || c === false) continue;
    parent.appendChild(typeof c === 'string' || typeof c === 'number' ? document.createTextNode(String(c)) : c);
  }
}

export function clear(el: Element): void {
  while (el.firstChild) el.removeChild(el.firstChild);
}

export function replaceChildren(el: Element, ...children: Child[]): void {
  clear(el);
  append(el, ...children);
}

/** Collects teardown functions for a view. */
export class Scope {
  private readonly fns: (() => void)[] = [];

  add(fn: () => void): void {
    this.fns.push(fn);
  }

  listen<T extends EventTarget>(target: T, type: string, fn: (ev: Event) => void, opts?: AddEventListenerOptions): void {
    target.addEventListener(type, fn, opts);
    this.fns.push(() => target.removeEventListener(type, fn, opts));
  }

  dispose(): void {
    while (this.fns.length) {
      try {
        this.fns.pop()?.();
      } catch (err) {
        console.warn(err);
      }
    }
  }
}

export interface View {
  el: HTMLElement;
  dispose(): void;
  /** The view became visible again (tab switch). */
  shown?(): void;
  hidden?(): void;
}

export const prefersReducedMotion = (): boolean =>
  typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;

/** Long-press helper: fires `onLong` after `ms` unless the pointer moves more than `slop`. */
export function longPress(
  el: HTMLElement,
  ms: number,
  onLong: (ev: PointerEvent) => void,
  slop = 8,
): () => void {
  let timer: ReturnType<typeof setTimeout> | null = null;
  let sx = 0;
  let sy = 0;
  let fired = false;
  const cancel = () => {
    if (timer !== null) clearTimeout(timer);
    timer = null;
  };
  const down = (e: PointerEvent) => {
    fired = false;
    sx = e.clientX;
    sy = e.clientY;
    cancel();
    timer = setTimeout(() => {
      timer = null;
      fired = true;
      onLong(e);
    }, ms);
  };
  const move = (e: PointerEvent) => {
    if (timer !== null && Math.hypot(e.clientX - sx, e.clientY - sy) > slop) cancel();
  };
  const click = (e: Event) => {
    if (fired) {
      e.preventDefault();
      e.stopImmediatePropagation();
      fired = false;
    }
  };
  const ctx = (e: Event) => e.preventDefault();
  el.addEventListener('pointerdown', down);
  el.addEventListener('pointermove', move);
  el.addEventListener('pointerup', cancel);
  el.addEventListener('pointercancel', cancel);
  el.addEventListener('pointerleave', cancel);
  el.addEventListener('click', click, true);
  el.addEventListener('contextmenu', ctx);
  return () => {
    cancel();
    el.removeEventListener('pointerdown', down);
    el.removeEventListener('pointermove', move);
    el.removeEventListener('pointerup', cancel);
    el.removeEventListener('pointercancel', cancel);
    el.removeEventListener('pointerleave', cancel);
    el.removeEventListener('click', click, true);
    el.removeEventListener('contextmenu', ctx);
  };
}
