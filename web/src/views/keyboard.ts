// Keys tab: Mac keyboard, custom keyboards or the text composer.
import type { App } from '../app';
import { t } from '../i18n';
import { h, Scope, type View } from '../ui/dom';
import { segmented } from '../ui/controls';
import { modifierRow } from '../ui/modrow';
import { isTablet } from '../device';
import { createMacKeyboard } from './mackeyboard';
import { createComposer } from './composer';
import { createCustomKeyboards } from './customkb';
import { resolveKeyboardMode, type KeyboardMode } from './keyboard-mode';

type Mode = KeyboardMode;

export function renderKeyboardView(app: App): View {
  const scope = new Scope();
  let body: { el: HTMLElement; dispose(): void } | null = null;
  let mode: Mode = resolveKeyboardMode(app.settings.keyboard, isTablet(app.model), window.innerWidth);

  const seg = segmented<Mode>(
    [
      { value: 'mac', label: t('kb.mac') },
      { value: 'custom', label: t('kb.custom') },
      { value: 'phone', label: t('kb.type') },
    ],
    mode,
    (v) => app.updateSettings({ keyboard: v }),
    t('kb.mode'),
  );
  const host = h('div', { class: 'composer' });
  const el = h('section', { class: 'view' }, seg.el, host);

  const build = (m: Mode) => {
    body?.dispose();
    host.replaceChildren();
    if (m === 'mac') {
      const kb = createMacKeyboard(app);
      body = kb;
      host.appendChild(kb.el);
    } else if (m === 'custom') {
      const ck = createCustomKeyboards(app);
      body = ck;
      host.appendChild(ck.el);
    } else {
      const row = modifierRow(app);
      const comp = createComposer(app);
      body = {
        el: comp.el,
        dispose() {
          row.dispose();
          comp.dispose();
        },
      };
      host.append(row.el, comp.el);
    }
  };

  const refresh = () => {
    const next = resolveKeyboardMode(app.settings.keyboard, isTablet(app.model), window.innerWidth);
    if (next === mode && body) return;
    mode = next;
    seg.set(mode);
    build(mode);
  };
  build(mode);
  scope.add(app.events.on('settings', refresh));
  scope.listen(window, 'resize', refresh);
  scope.add(() => body?.dispose());
  return { el, dispose: () => scope.dispose() };
}
