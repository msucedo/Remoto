// Apps tab: running or all apps of the Mac; tap toggles, hold opens a menu.
import type { App } from '../app';
import type { AppInfo } from '../protocol/types';
import { t } from '../i18n';
import { h, longPress, Scope, type View } from '../ui/dom';
import { button, segmented, textField } from '../ui/controls';
import { openSheet } from '../ui/sheet';
import { toast } from '../ui/toast';
import { appIcon } from '../ui/appicon';
import { cloneDeck, DECK_LIMITS, newId } from '../deck/validate';

type Filter = 'open' | 'all';

export function filterApps(apps: readonly AppInfo[], filter: Filter, query: string): AppInfo[] {
  const q = query.trim().toLowerCase();
  const list = q
    ? apps.filter((a) => a.name.toLowerCase().includes(q) || a.id.toLowerCase().includes(q))
    : apps.filter((a) => filter === 'all' || a.running);
  return [...list].sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }));
}

function addToDeck(app: App, a: AppInfo): void {
  const d = app.deck;
  if (!d) return;
  const next = cloneDeck(d);
  const page = next.pages.find((p) => p.id === app.settings.deckPage) ?? next.pages[0];
  if (!page) return;
  if (page.tiles.length >= DECK_LIMITS.tiles) {
    toast(t('deck.limitTiles'), 'warning', 'deck');
    return;
  }
  page.tiles.push({
    id: newId('t'),
    label: a.name.slice(0, DECK_LIMITS.label),
    icon: { kind: 'app', id: a.id },
    action: { kind: 'app', id: a.id, op: 'toggle' },
  });
  if (app.saveDeck(next)) toast(t('apps.addedToDeck', { name: a.name, page: page.name }), 'info', 'deck');
}

function openAppSheet(app: App, a: AppInfo): void {
  app.haptic('medium');
  const sheet = openSheet(a.name);
  const act = (op: 'open' | 'hide' | 'quit') => () => {
    app.appAction(a.id, op);
    sheet.close();
  };
  sheet.body.append(
    h(
      'div',
      { class: 'app-sheet-head' },
      appIcon(app, a.id, 56),
      h('div', { class: 'stack' }, h('strong', { text: a.name }), h('small', { class: 'mono muted', text: a.id })),
    ),
    h(
      'div',
      { class: 'stack' },
      button(a.running ? t('apps.bringFront') : t('apps.open'), act('open')),
      button(t('apps.hide'), act('hide'), { disabled: !a.running }),
      button(t('apps.quit'), act('quit'), { variant: 'danger', disabled: !a.running }),
      button(t('apps.addToDeck'), () => {
        addToDeck(app, a);
        sheet.close();
      }, { icon: 'plus' }),
    ),
  );
}

export function renderAppsView(app: App): View {
  const scope = new Scope();
  let cellScope = new Scope();
  scope.add(() => cellScope.dispose());
  let filter: Filter = 'open';
  let query = '';
  const seg = segmented<Filter>(
    [
      { value: 'open', label: t('apps.filterOpen') },
      { value: 'all', label: t('apps.filterAll') },
    ],
    filter,
    (v) => {
      filter = v;
      paint();
    },
    t('apps.filter'),
  );
  const search = textField('', (v) => {
    query = v;
    paint();
  }, { type: 'search', placeholder: t('apps.search'), label: t('apps.search') });
  const grid = h('div', { class: 'apps-grid', role: 'list' });
  const status = h('div', { class: 'empty', hidden: true });
  const scroller = h('div', { class: 'deck-scroll' }, grid);
  const el = h('section', { class: 'view' }, h('div', { class: 'apps-head' }, seg.el, search), scroller, status);

  const paint = () => {
    cellScope.dispose();
    cellScope = new Scope();
    grid.replaceChildren();
    if (!app.apps) {
      status.hidden = false;
      status.textContent = t('apps.loading');
      return;
    }
    const list = filterApps(app.apps, filter, query);
    status.hidden = list.length > 0;
    status.textContent = list.length ? '' : t('apps.none');
    for (const a of list) {
      const cell = h(
        'button',
        {
          class: `app-cell${a.active ? ' active' : ''}${a.hidden ? ' hidden-app' : ''}`,
          type: 'button',
          role: 'listitem',
          attrs: { 'aria-label': [a.name, a.active ? t('apps.front') : a.running ? t('apps.running') : '', a.hidden ? t('apps.hidden') : ''].filter(Boolean).join(', ') },
        },
        appIcon(app, a.id, 48),
        a.running ? h('span', { class: 'app-open-dot', attrs: { 'aria-hidden': 'true' } }) : null,
        h('span', { class: 'app-name', text: a.name }),
        a.hidden ? h('span', { class: 'app-hidden-tag', text: t('apps.hidden') }) : null,
      );
      cell.addEventListener('click', () => {
        app.haptic('light');
        app.appAction(a.id, 'toggle');
      });
      cellScope.add(longPress(cell, 500, () => openAppSheet(app, a)));
      grid.appendChild(cell);
    }
  };

  scope.add(app.events.on('apps', paint));
  scope.add(
    app.events.on('status', (s) => {
      if (s.state === 'connected' && !el.hidden) app.requestApps();
    }),
  );
  paint();
  return {
    el,
    shown: () => app.requestApps(),
    dispose: () => scope.dispose(),
  };
}
