// Entry point: theme, viewport, lifecycle hooks and top-level screen routing.
import './styles.css';
import { App } from './app';
import { setLanguage } from './i18n';
import { reloadForChunk } from './main-reload';
import type { View } from './ui/dom';
import { replaceChildren } from './ui/dom';
import { renderConnect } from './screens/connect';
import { renderSplash } from './screens/splash';
import { renderShell } from './screens/shell';

type ScreenName = 'connect' | 'splash' | 'shell';

const app = new App();
setLanguage(app.settings.language);
const root = document.getElementById('root') as HTMLElement;

// ---- Theme ---------------------------------------------------------------------
const darkQuery = matchMedia('(prefers-color-scheme: dark)');
function applyTheme(): void {
  const choice = app.settings.theme;
  const dark = choice === 'dark' || (choice === 'system' && darkQuery.matches);
  document.documentElement.dataset['theme'] = dark ? 'dark' : 'light';
  document.querySelector('meta[name="theme-color"]')?.setAttribute('content', dark ? '#0e1116' : '#f2f4f7');
}
darkQuery.addEventListener('change', applyTheme);
applyTheme();

// ---- Viewport and zoom ------------------------------------------------------------
function applyHeight(): void {
  const h = window.visualViewport?.height ?? window.innerHeight;
  document.documentElement.style.setProperty('--app-h', `${Math.round(h)}px`);
}
window.visualViewport?.addEventListener('resize', applyHeight);
window.addEventListener('resize', applyHeight);
applyHeight();
for (const ev of ['gesturestart', 'gesturechange', 'gestureend']) {
  document.addEventListener(ev, (e) => e.preventDefault(), { passive: false });
}
document.addEventListener(
  'touchmove',
  (e) => {
    if (e.touches.length > 1) e.preventDefault();
  },
  { passive: false },
);
let lastTouchEnd = 0;
document.addEventListener(
  'touchend',
  (e) => {
    const now = Date.now();
    const target = e.target as HTMLElement | null;
    const editable = target?.closest('input, textarea, select, [contenteditable]');
    if (!editable && now - lastTouchEnd < 300) e.preventDefault();
    lastTouchEnd = now;
  },
  { passive: false },
);

// ---- Screens ------------------------------------------------------------------------
let current: { name: ScreenName; view: View; lang: string } | null = null;

function wantedScreen(): ScreenName {
  const s = app.conn.getStatus();
  if (s.state === 'connected') return 'shell';
  if ((s.state === 'reconnecting' || s.state === 'connecting') && s.method === 'token') {
    return s.everConnected ? 'shell' : 'splash';
  }
  return 'connect';
}

function render(force = false): void {
  const name = wantedScreen();
  const lang = document.documentElement.lang;
  if (!force && current && current.name === name && current.lang === lang) return;
  current?.view.dispose();
  const view = name === 'shell' ? renderShell(app) : name === 'splash' ? renderSplash(app) : renderConnect(app);
  current = { name, view, lang };
  replaceChildren(root, view.el);
}

app.events.on('status', () => render());
app.events.on('settings', (s) => {
  applyTheme();
  if (setLanguage(s.language) !== current?.lang) render(true);
});

// ---- Lifecycle ----------------------------------------------------------------------------
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'hidden') app.suspend();
  else app.resume();
});
window.addEventListener('online', () => app.resume());
window.addEventListener('pageshow', (e) => {
  if (e.persisted) app.resume();
});
window.addEventListener('pagehide', () => app.flushSaves());

// Wake lock while connected and visible.
type Sentinel = { release(): Promise<void>; released: boolean };
let wake: Sentinel | null = null;
async function updateWakeLock(): Promise<void> {
  const want = app.settings.keepAwake && app.connected && document.visibilityState === 'visible';
  const nav = navigator as Navigator & { wakeLock?: { request(type: 'screen'): Promise<Sentinel> } };
  if (want && (!wake || wake.released) && nav.wakeLock) {
    try {
      wake = await nav.wakeLock.request('screen');
    } catch {
      wake = null;
    }
  } else if (!want && wake) {
    const w = wake;
    wake = null;
    await w.release().catch(() => undefined);
  }
}
app.events.on('status', () => void updateWakeLock());
app.events.on('settings', () => void updateWakeLock());
document.addEventListener('visibilitychange', () => void updateWakeLock());

// A lazily loaded chunk failed (new version on the Mac): reload once.
window.addEventListener('vite:preloadError', (e) => {
  e.preventDefault();
  reloadForChunk();
});
// ---- Start ----------------------------------------------------------------------------------
function readPairCode(): string | null {
  const hash = location.hash.replace(/^#/, '');
  const params = new URLSearchParams(hash);
  const code = params.get('pair');
  if (code === null) return null;
  params.delete('pair');
  const rest = params.toString();
  history.replaceState(null, '', location.pathname + location.search + (rest ? `#${rest}` : ''));
  return code.trim();
}

// A QR scanned while the page is already open only changes the hash.
window.addEventListener('hashchange', () => {
  const c = readPairCode();
  if (c) app.conn.connect({ method: 'pair', code: c });
});

const code = readPairCode();
render(true);
void app.fetchInfo();
if (code) app.conn.connect({ method: 'pair', code });
else app.conn.connect();

if ('serviceWorker' in navigator && window.isSecureContext && import.meta.env.PROD) {
  navigator.serviceWorker.register('/sw.js', { scope: '/' }).catch(() => undefined);
}
