// Main interface: status bar, active view, tab bar and the pause overlay.
import type { App } from '../app';
import { t, type MessageKey } from '../i18n';
import { h, Scope, type View } from '../ui/dom';
import { icon } from '../ui/icons';
import { button, iconButton } from '../ui/controls';
import { toast } from '../ui/toast';
import { TABS, type Tab } from '../store/settings';
import { MODIFIERS } from '../input/modifiers';
import { renderTrackpadView } from '../views/trackpad';
import { reloadForChunk } from '../main-reload';
import { installPhysicalKeyboard } from '../input/physical';

type ViewFactory = (app: App) => View;

const TAB_META: Record<Tab, { icon: string; label: MessageKey }> = {
  trackpad: { icon: 'mouse-pointer-2', label: 'tab.trackpad' },
  keyboard: { icon: 'keyboard', label: 'tab.keyboard' },
  deck: { icon: 'layout-grid', label: 'tab.deck' },
  media: { icon: 'music', label: 'tab.media' },
  apps: { icon: 'app-window', label: 'tab.apps' },
};

const LOADERS: Record<Tab, () => Promise<ViewFactory>> = {
  trackpad: async () => renderTrackpadView,
  keyboard: async () => (await import('../views/keyboard')).renderKeyboardView,
  deck: async () => (await import('../views/deck')).renderDeckView,
  media: async () => (await import('../views/media')).renderMediaView,
  apps: async () => (await import('../views/apps')).renderAppsView,
};

export async function openSettings(app: App): Promise<void> {
  try {
    const mod = await import('../views/settings');
    mod.openSettingsSheet(app);
  } catch {
    reloadForChunk();
  }
}

export function renderShell(app: App): View {
  const scope = new Scope();

  // ---- Status bar ----
  const dot = h('span', { class: 'conn-dot', attrs: { 'aria-hidden': 'true' } });
  const name = h('span', { class: 'mac-name' });
  const latency = h('span', { class: 'latency' });
  const lock = h('span', { class: 'lock-icon' });
  const modPill = h('button', { class: 'mod-pill', type: 'button', hidden: true });
  modPill.addEventListener('click', () => {
    app.releaseAll();
    toast(t('mods.released'), 'info', 'mods');
  });
  const permBtn = iconButton('shield-alert', t('perm.short'), () => toast(t('perm.toast'), 'warning', 'permission'), { cls: 'warn' });
  const gear = iconButton('settings', t('settings.title'), () => void openSettings(app));
  const status = h('header', { class: 'statusbar' }, dot, name, latency, lock, h('span', { class: 'spacer' }), modPill, permBtn, gear);

  const band = h(
    'div',
    { class: 'perm-band', role: 'status', hidden: true },
    icon('shield-alert', 18),
    h('span', { text: t('perm.band') }),
  );

  // ---- Views ----
  const host = h('main', { class: 'view-host' });
  const views = new Map<Tab, View>();
  const loading = new Set<Tab>();
  let active: Tab = app.settings.tab;

  const tabbar = h('nav', { class: 'tabbar', role: 'tablist', attrs: { 'aria-label': t('tab.label') } });
  const tabButtons = new Map<Tab, HTMLButtonElement>();
  for (const tab of TABS) {
    const meta = TAB_META[tab];
    const b = h(
      'button',
      {
        class: 'tab',
        type: 'button',
        role: 'tab',
        attrs: { 'aria-selected': String(tab === active), 'aria-label': t(meta.label), id: `tab-${tab}`, 'aria-controls': `view-${tab}` },
      },
      icon(meta.icon, 22),
      h('span', { class: 'tab-label', text: t(meta.label) }),
    );
    b.addEventListener('click', () => select(tab));
    tabButtons.set(tab, b);
    tabbar.appendChild(b);
  }

  const show = (tab: Tab) => {
    for (const [k, v] of views) {
      const on = k === tab;
      if (v.el.hidden === on) {
        v.el.hidden = !on;
        if (on) v.shown?.();
        else v.hidden?.();
      }
    }
  };

  const ensure = async (tab: Tab) => {
    if (views.has(tab) || loading.has(tab)) return;
    loading.add(tab);
    try {
      const factory = await LOADERS[tab]();
      if (disposed) return;
      const v = factory(app);
      v.el.id = `view-${tab}`;
      v.el.setAttribute('role', 'tabpanel');
      v.el.setAttribute('aria-labelledby', `tab-${tab}`);
      v.el.hidden = tab !== active;
      views.set(tab, v);
      host.appendChild(v.el);
      if (tab === active) v.shown?.();
    } catch (err) {
      console.error(err);
      reloadForChunk();
    } finally {
      loading.delete(tab);
    }
  };

  const select = (tab: Tab) => {
    if (tab === active) return;
    active = tab;
    for (const [k, b] of tabButtons) b.setAttribute('aria-selected', String(k === tab));
    app.updateSettings({ tab });
    show(tab);
    void ensure(tab);
  };

  // ---- Pause overlay (keeps Settings and Disconnect reachable) ----
  const pause = h(
    'div',
    { class: 'pause-overlay', hidden: true, role: 'alertdialog', attrs: { 'aria-modal': 'false', 'aria-labelledby': 'pause-title' } },
    h(
      'div',
      { class: 'overlay-card' },
      icon('pause', 32),
      h('h2', { id: 'pause-title', text: t('pause.title') }),
      h('p', { class: 'muted', text: t('pause.text') }),
      h(
        'div',
        { class: 'connect-actions' },
        button(t('settings.title'), () => void openSettings(app)),
        button(t('settings.disconnect'), () => app.conn.disconnect()),
      ),
    ),
  );

  const el = h('div', { class: 'shell', dataset: { screen: 'shell' } }, status, band, host, tabbar, pause);
  let disposed = false;

  // ---- Updates ----
  const updateStatus = () => {
    const s = app.conn.getStatus();
    const reconnecting = s.state !== 'connected';
    dot.classList.toggle('reconnecting', reconnecting);
    name.textContent = reconnecting ? t('status.reconnecting') : app.macName || t('connect.yourMac');
    latency.hidden = reconnecting || s.latency === null;
    latency.textContent = s.latency === null ? '' : t('status.latency', { n: s.latency });
    const secure = app.features.secure || location.protocol === 'https:';
    lock.replaceChildren(icon(secure ? 'lock' : 'lock-open', 14));
    const lockLabel = secure ? t('status.secure') : t('status.insecure');
    lock.title = lockLabel;
    lock.setAttribute('aria-label', lockLabel);
    lock.setAttribute('role', 'img');
    const noPerm = !reconnecting && !app.features.permission;
    permBtn.hidden = !noPerm;
    band.hidden = !noPerm;
    pause.hidden = !app.paused || reconnecting;
  };
  const updateMods = () => {
    const act = app.mods.active();
    modPill.hidden = act.length === 0;
    modPill.textContent = act.map((m) => MODIFIERS[m].symbol).join('');
    modPill.classList.toggle('locked', app.mods.anyLocked());
    modPill.setAttribute('aria-label', t('mods.pill', { mods: modPill.textContent }));
  };

  scope.add(app.events.on('status', updateStatus));
  scope.add(app.events.on('features', updateStatus));
  scope.add(app.events.on('paused', updateStatus));
  scope.add(app.events.on('host', updateStatus));
  scope.add(app.mods.onChange(updateMods));
  scope.add(installPhysicalKeyboard(app));
  updateStatus();
  updateMods();
  void ensure(active);

  return {
    el,
    dispose() {
      disposed = true;
      for (const v of views.values()) v.dispose();
      scope.dispose();
    },
  };
}
