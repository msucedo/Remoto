// Trackpad tab: modifier row, surface with scroll rail, and click buttons.
import type { App } from '../app';
import { t } from '../i18n';
import { h, Scope, type View } from '../ui/dom';
import { modifierRow, bindPress } from '../ui/modrow';
import { openSheet } from '../ui/sheet';
import { createPad, createStrip } from './pad';

async function openComposeSheet(app: App): Promise<void> {
  const { createComposer } = await import('./composer');
  const sheet = openSheet(t('compose.title'), { wide: true });
  const row = modifierRow(app);
  const composer = createComposer(app, { inSheet: true });
  sheet.body.append(row.el, composer.el);
  sheet.onClose(() => {
    row.dispose();
    composer.dispose();
  });
  composer.focus();
}

export function renderTrackpadView(app: App): View {
  const scope = new Scope();
  const mods = modifierRow(app, { onKeyboard: () => void openComposeSheet(app) });
  scope.add(() => mods.dispose());
  const pad = createPad(app, { hint: true });
  const strip = createStrip(app);
  scope.add(() => pad.dispose());
  scope.add(() => strip.dispose());
  const area = h('div', { class: 'pad-area' }, pad.el, strip.el);

  const mk = (label: string, button: 'left' | 'right') => {
    const b = h('button', { class: 'click-btn', type: 'button', text: label });
    scope.add(
      bindPress(
        b,
        () => {
          app.haptic('select');
          app.button(button, 'down');
        },
        () => app.button(button, 'up'),
      ),
    );
    return b;
  };
  const clickBar = h('div', { class: 'click-bar' }, mk(t('pad.click'), 'left'), mk(t('pad.rightClick'), 'right'));

  const refresh = () => {
    clickBar.hidden = !app.settings.clickButtons;
    area.classList.toggle('strip-left', app.settings.scrollStripSide === 'left');
  };
  refresh();
  scope.add(app.events.on('settings', refresh));

  const el = h('section', { class: 'view' }, mods.el, area, clickBar);
  return {
    el,
    hidden() {
      pad.cancel();
      strip.cancel();
    },
    dispose: () => scope.dispose(),
  };
}
