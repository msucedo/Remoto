// Toast stack: at most three, newest at the bottom, same key replaces.
import { h } from './dom';

export type ToastLevel = 'info' | 'warning' | 'error';

interface Live {
  el: HTMLElement;
  key: string | undefined;
  timer: ReturnType<typeof setTimeout>;
}

const MAX = 3;
const live: Live[] = [];
let host: HTMLElement | null = null;

function container(): HTMLElement {
  if (host && host.isConnected) return host;
  host = h('div', { class: 'toasts', attrs: { 'aria-live': 'polite', 'aria-relevant': 'additions' } });
  document.body.appendChild(host);
  return host;
}

function remove(item: Live): void {
  clearTimeout(item.timer);
  const i = live.indexOf(item);
  if (i >= 0) live.splice(i, 1);
  item.el.classList.add('leaving');
  setTimeout(() => item.el.remove(), 180);
}

export function toast(message: string, level: ToastLevel = 'info', key?: string): void {
  if (!message) return;
  const parent = container();
  if (key) {
    const same = live.find((x) => x.key === key);
    if (same) remove(same);
  }
  while (live.length >= MAX) {
    const oldest = live[0];
    if (!oldest) break;
    remove(oldest);
  }
  const el = h('div', {
    class: `toast toast-${level}`,
    role: level === 'error' ? 'alert' : 'status',
    text: message,
  });
  const item: Live = {
    el,
    key,
    timer: setTimeout(() => remove(item), level === 'error' ? 7000 : 4500),
  };
  el.addEventListener('click', () => remove(item));
  live.push(item);
  parent.appendChild(el);
}

export function clearToasts(): void {
  for (const item of [...live]) remove(item);
}
