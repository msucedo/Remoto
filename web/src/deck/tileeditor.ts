// Tile editor and page settings sheets.
import type { App } from '../app';
import type { Deck, Tile, TileIcon } from '../protocol/types';
import { t } from '../i18n';
import { h } from '../ui/dom';
import { icon, TILE_SYMBOLS } from '../ui/icons';
import { button, errorLine, fieldBlock, segmented, select, textField } from '../ui/controls';
import { confirmSheet, openSheet } from '../ui/sheet';
import { toast } from '../ui/toast';
import { charLength, cleanTile, cloneDeck, DECK_LIMITS, newId, validateTile } from './validate';
import { createActionEditor } from './actioneditor';
import { openAppPicker } from './apppicker';
import { graphemes } from '../text/graphemes';

export const TILE_COLORS = ['#e4572e', '#f3a712', '#a8c256', '#29bf9e', '#3aa7e0', '#5b6cf0', '#9b5de5', '#e05297', '#7a8591'] as const;

function mutate(app: App, fn: (d: Deck) => void): boolean {
  if (!app.deck) return false;
  const next = cloneDeck(app.deck);
  fn(next);
  return app.saveDeck(next);
}

type IconMode = 'auto' | 'symbol' | 'emoji' | 'app';

export function openTileEditor(app: App, pageId: string, index: number | null): void {
  const page = app.deck?.pages.find((p) => p.id === pageId);
  if (!page) return;
  const existing = index === null ? undefined : page.tiles[index];
  const sheet = openSheet(existing ? t('tile.editTitle') : t('tile.newTitle'), { wide: true });

  let label = existing?.label ?? '';
  let color = existing?.color;
  let iconValue: TileIcon | undefined = existing?.icon;
  let mode: IconMode = iconValue?.kind ?? 'auto';

  const labelErr = errorLine();
  const labelField = textField(label, (v) => {
    label = v;
    labelErr.set(charLength(v) > DECK_LIMITS.label ? t('err.labelTooLong') : null);
  }, { label: t('tile.label'), maxLength: 80 });
  const actionEditor = createActionEditor(app, existing?.action ?? null);

  // Icon.
  const iconBody = h('div', { class: 'editor' });
  const symbolName = () => (iconValue?.kind === 'symbol' ? iconValue.name : '');
  const renderIcon = () => {
    iconBody.replaceChildren();
    if (mode === 'symbol') {
      const gridEl = h('div', { class: 'symbol-grid', role: 'group', attrs: { 'aria-label': t('tile.symbol') } });
      for (const name of TILE_SYMBOLS) {
        const cell = h(
          'button',
          { class: 'symbol-cell', type: 'button', title: name, attrs: { 'aria-label': name, 'aria-pressed': String(symbolName() === name) } },
          icon(name, 22),
        );
        cell.addEventListener('click', () => {
          iconValue = { kind: 'symbol', name };
          for (const c of gridEl.children) c.setAttribute('aria-pressed', String(c === cell));
        });
        gridEl.appendChild(cell);
      }
      iconBody.appendChild(gridEl);
    } else if (mode === 'emoji') {
      const f = textField(iconValue?.kind === 'emoji' ? iconValue.text : '', (v) => {
        const segs = graphemes(v);
        const last = segs[segs.length - 1] ?? '';
        f.value = last;
        iconValue = last ? { kind: 'emoji', text: last } : undefined;
      }, { label: t('tile.emoji'), placeholder: '🙂' });
      f.classList.add('char-field');
      iconBody.appendChild(fieldBlock(t('tile.emoji'), f));
    } else if (mode === 'app') {
      const idText = h('span', { class: 'mono note', text: iconValue?.kind === 'app' ? iconValue.id : t('tile.noApp') });
      const pick = button(t('action.chooseApp'), () => {
        void openAppPicker(app).then((a) => {
          if (!a) return;
          iconValue = { kind: 'app', id: a.id };
          idText.textContent = a.id;
        });
      }, { icon: 'app-window' });
      iconBody.append(pick, idText);
    }
  };
  const iconSeg = segmented<IconMode>(
    [
      { value: 'auto', label: t('tile.iconAuto') },
      { value: 'symbol', label: t('tile.iconSymbol') },
      { value: 'emoji', label: t('tile.iconEmoji') },
      { value: 'app', label: t('tile.iconApp') },
    ],
    mode,
    (v) => {
      mode = v;
      if (v === 'auto') iconValue = undefined;
      else if (iconValue?.kind !== v) iconValue = undefined;
      renderIcon();
    },
    t('tile.icon'),
  );
  renderIcon();

  // Color.
  const swatches = h('div', { class: 'swatches', role: 'group', attrs: { 'aria-label': t('tile.color') } });
  const paintSwatches = () => {
    swatches.replaceChildren();
    const none = h('button', { class: 'swatch none', type: 'button', title: t('tile.noColor'), attrs: { 'aria-label': t('tile.noColor'), 'aria-pressed': String(!color) } });
    none.addEventListener('click', () => {
      color = undefined;
      paintSwatches();
    });
    swatches.appendChild(none);
    for (const c of TILE_COLORS) {
      const s = h('button', { class: 'swatch', type: 'button', title: c, attrs: { 'aria-label': c, 'aria-pressed': String(color === c) } });
      s.style.setProperty('--swatch', c);
      s.addEventListener('click', () => {
        color = c;
        paintSwatches();
      });
      swatches.appendChild(s);
    }
  };
  paintSwatches();

  const formErr = errorLine();
  const build = (): Tile | null => {
    const action = actionEditor.value();
    const e = actionEditor.error();
    if (!action || e) {
      formErr.set(e ?? t('err.kind'));
      return null;
    }
    const tile: Tile = { id: existing?.id ?? newId('t'), label: label.trim(), action };
    if (color) tile.color = color;
    if (mode !== 'auto' && iconValue) tile.icon = iconValue;
    const v = validateTile(tile);
    if (v) {
      formErr.set(t(`err.${v}`));
      return null;
    }
    formErr.set(null);
    return cleanTile(tile);
  };

  sheet.body.append(
    fieldBlock(t('tile.label'), labelField, labelErr),
    actionEditor.el,
    fieldBlock(t('tile.icon'), iconSeg.el),
    iconBody,
    h('div', { class: 'field-block' }, h('span', { class: 'field-label', text: t('tile.color') }), swatches),
    formErr,
  );

  if (existing && index !== null) {
    sheet.footer.append(
      button(t('common.delete'), () => {
        if (mutate(app, (d) => d.pages.find((p) => p.id === pageId)?.tiles.splice(index, 1))) sheet.close();
      }, { variant: 'danger' }),
      button(t('tile.duplicate'), () => {
        const tile = build();
        if (!tile) return;
        if (page.tiles.length >= DECK_LIMITS.tiles) return toast(t('deck.limitTiles'), 'warning', 'deck');
        const copy = { ...tile, id: newId('t') };
        if (mutate(app, (d) => d.pages.find((p) => p.id === pageId)?.tiles.splice(index + 1, 0, copy))) sheet.close();
      }),
    );
  }
  sheet.footer.append(
    button(t('common.save'), () => {
      const tile = build();
      if (!tile) return;
      const ok = mutate(app, (d) => {
        const p = d.pages.find((x) => x.id === pageId);
        if (!p) return;
        if (index === null) p.tiles.push(tile);
        else p.tiles[index] = tile;
      });
      if (ok) sheet.close();
    }, { variant: 'primary' }),
  );
}

export function openPageSettings(app: App, pageId: string): void {
  const d = app.deck;
  const page = d?.pages.find((p) => p.id === pageId);
  if (!d || !page) return;
  const sheet = openSheet(t('page.title'));
  let name = page.name;
  let columns = page.columns;
  const err = errorLine();
  const nameField = textField(name, (v) => {
    name = v;
    err.set(charLength(v) > DECK_LIMITS.label ? t('err.labelTooLong') : null);
  }, { label: t('page.name'), maxLength: 80 });
  const cols = select(
    Array.from({ length: 8 }, (_, i) => ({ value: String(i + 1), label: String(i + 1) })),
    String(columns),
    (v) => {
      columns = Number(v);
    },
    t('page.columns'),
  );
  const index = d.pages.indexOf(page);
  const moveBy = (delta: number) => {
    const ok = mutate(app, (x) => {
      const i = x.pages.findIndex((p) => p.id === pageId);
      const j = i + delta;
      const a = x.pages[i];
      const b = x.pages[j];
      if (!a || !b) return;
      x.pages[i] = b;
      x.pages[j] = a;
    });
    if (ok) sheet.close();
  };
  const left = button(t('page.moveLeft'), () => moveBy(-1), { icon: 'chevron-left' });
  const right = button(t('page.moveRight'), () => moveBy(1), { icon: 'chevron-right' });
  left.disabled = index <= 0;
  right.disabled = index >= d.pages.length - 1;
  sheet.body.append(fieldBlock(t('page.name'), nameField, err), fieldBlock(t('page.columns'), cols), h('div', { class: 'connect-actions' }, left, right));

  const del = button(t('page.delete'), () => {
    if (d.pages.length <= 1) {
      toast(t('page.lastPage'), 'warning', 'deck');
      return;
    }
    void confirmSheet({ title: t('page.deleteTitle'), message: t('page.deleteText', { name: page.name }), confirm: t('common.delete') }).then((yes) => {
      if (!yes) return;
      if (mutate(app, (x) => (x.pages = x.pages.filter((p) => p.id !== pageId)))) {
        app.updateSettings({ deckPage: '' });
        sheet.close();
      }
    });
  }, { variant: 'danger' });
  del.disabled = d.pages.length <= 1;
  sheet.footer.append(
    del,
    button(t('common.save'), () => {
      if (charLength(name) > DECK_LIMITS.label) return;
      if (mutate(app, (x) => {
        const p = x.pages.find((q) => q.id === pageId);
        if (p) {
          p.name = name.trim();
          p.columns = columns;
        }
      })) sheet.close();
    }, { variant: 'primary' }),
  );
}
