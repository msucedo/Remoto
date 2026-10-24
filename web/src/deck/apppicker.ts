// Sheet that lists the Mac's apps for picking one.
import type { App } from '../app';
import type { AppInfo } from '../protocol/types';
import { t } from '../i18n';
import { h } from '../ui/dom';
import { textField } from '../ui/controls';
import { openSheet } from '../ui/sheet';
import { appIcon } from '../ui/appicon';

export function sortApps(apps: readonly AppInfo[]): AppInfo[] {
  return [...apps].sort((a, b) => Number(b.running) - Number(a.running) || a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }));
}

export function openAppPicker(app: App): Promise<AppInfo | null> {
  return new Promise((resolve) => {
    let done = false;
    const sheet = openSheet(t('apppick.title'));
    let query = '';
    const list = h('div', { class: 'app-list', role: 'listbox', attrs: { 'aria-label': t('apppick.title') } });
    const search = textField('', (v) => {
      query = v.trim().toLowerCase();
      paint();
    }, { placeholder: t('apps.search'), type: 'search', label: t('apps.search') });
    sheet.body.append(search, list);

    const paint = () => {
      list.replaceChildren();
      if (!app.apps) {
        list.appendChild(h('p', { class: 'muted', text: t('apps.loading') }));
        return;
      }
      const items = sortApps(app.apps).filter((a) => !query || a.name.toLowerCase().includes(query) || a.id.toLowerCase().includes(query));
      if (!items.length) list.appendChild(h('p', { class: 'muted', text: t('apps.none') }));
      for (const a of items) {
        const row = h(
          'button',
          { class: 'app-row', type: 'button', role: 'option' },
          appIcon(app, a.id, 32),
          h('span', { class: 'name', text: a.name }),
          a.running ? h('span', { class: 'running-dot', attrs: { 'aria-label': t('apps.running') } }) : null,
        );
        row.addEventListener('click', () => {
          done = true;
          sheet.close();
          resolve(a);
        });
        list.appendChild(row);
      }
    };
    const off = app.events.on('apps', paint);
    sheet.onClose(() => {
      off();
      if (!done) resolve(null);
    });
    app.requestApps();
    paint();
  });
}
