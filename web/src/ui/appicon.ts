// App icons served by the Mac, with a generic fallback.
import type { App } from '../app';
import { h } from './dom';
import { icon } from './icons';

export function iconUrl(app: App, id: string, cssSize: number): string {
  const dpr = Math.min(globalThis.devicePixelRatio || 2, 3);
  const size = Math.round(cssSize * dpr);
  return `/api/icon?id=${encodeURIComponent(id)}&size=${size}&k=${encodeURIComponent(app.sessionKey)}`;
}

export function appIcon(app: App, id: string, cssSize: number): HTMLElement {
  const fallback = () =>
    h('span', { class: 'app-fallback', attrs: { 'aria-hidden': 'true' } }, icon('app-window', Math.round(cssSize * 0.6)));
  if (!app.sessionKey || !id) return fallback();
  const img = h('img', {
    attrs: { src: iconUrl(app, id, cssSize), alt: '', width: cssSize, height: cssSize, loading: 'lazy', decoding: 'async', draggable: 'false' },
  });
  img.addEventListener('error', () => img.replaceWith(fallback()), { once: true });
  return img;
}
