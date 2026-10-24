// Splash while reconnecting with a saved token; offers re-pairing after 6 s.
import type { App } from '../app';
import { t } from '../i18n';
import { h, Scope, type View } from '../ui/dom';
import { button } from '../ui/controls';

export const SPLASH_HELP_MS = 6000;

export function renderSplash(app: App): View {
  const scope = new Scope();
  const label = h('p', { class: 'muted', role: 'status' });
  const setLabel = () => {
    const name = app.macName;
    label.textContent = name ? t('splash.connectingTo', { name }) : t('connect.connecting');
  };
  setLabel();
  const help = h(
    'div',
    { class: 'splash-help', hidden: true },
    h('p', { class: 'muted', text: t('splash.help') }),
    button(t('splash.repair'), () => app.conn.disconnect('none'), { variant: 'primary' }),
  );
  const el = h('div', { class: 'screen splash', dataset: { screen: 'splash' } }, h('div', { class: 'spinner' }), label, help);
  const timer = setTimeout(() => {
    help.hidden = false;
  }, SPLASH_HELP_MS);
  scope.add(() => clearTimeout(timer));
  scope.add(app.events.on('info', setLabel));
  return { el, dispose: () => scope.dispose() };
}
