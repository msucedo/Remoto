// Deck tab: pages of tiles that run actions on the Mac, with in-place editing.
import type { App } from '../app';
import type { Deck, DeckPage, Tile } from '../protocol/types';
import { t } from '../i18n';
import { h, longPress, Scope, type View } from '../ui/dom';
import { icon } from '../ui/icons';
import { button, iconButton } from '../ui/controls';
import { toast } from '../ui/toast';
import { cloneDeck, DECK_LIMITS, emptyPage } from '../deck/validate';
import { tileVisual } from '../deck/tileicon';
import { openPageSettings, openTileEditor } from '../deck/tileeditor';
import { deckColumns } from './deck-columns';

export function renderDeckView(app: App): View {
  const scope = new Scope();
  let paintScope = new Scope();
  scope.add(() => paintScope.dispose());
  let editing = false;
  let width = 360;

  const chips = h('div', { class: 'page-chips', role: 'tablist', attrs: { 'aria-label': t('deck.pages') } });
  const editBtn = iconButton('pencil', t('deck.edit'), () => setEditing(true));
  const pageGear = iconButton('settings', t('deck.pageSettings'), () => {
    const p = currentPage();
    if (p) openPageSettings(app, p.id);
  });
  const done = button(t('deck.done'), () => setEditing(false), { variant: 'small-primary' });
  const head = h('div', { class: 'deck-head' }, chips, editBtn, pageGear, done);
  const grid = h('div', { class: 'deck-grid', role: 'grid' });
  const scroller = h('div', { class: 'deck-scroll' }, grid);
  const empty = h('div', { class: 'empty', hidden: true });
  const el = h('section', { class: 'view' }, head, scroller, empty);

  const ro = new ResizeObserver((entries) => {
    const w = entries[0]?.contentRect.width;
    if (w && Math.abs(w - width) > 1) {
      width = w;
      applyColumns();
    }
  });
  ro.observe(scroller);
  scope.add(() => ro.disconnect());

  const deck = (): Deck | null => app.deck;
  const currentPage = (): DeckPage | undefined => {
    const d = deck();
    if (!d) return undefined;
    return d.pages.find((p) => p.id === app.settings.deckPage) ?? d.pages[0];
  };

  const setEditing = (on: boolean) => {
    editing = on;
    if (on) app.haptic('medium');
    paint();
  };

  const applyColumns = () => {
    const p = currentPage();
    const cols = deckColumns(p?.columns ?? 4, width, app.settings.deckButtonSize);
    grid.style.gridTemplateColumns = `repeat(${cols}, minmax(0, 1fr))`;
  };

  const save = (mutate: (d: Deck) => void): boolean => {
    const d = deck();
    if (!d) return false;
    const next = cloneDeck(d);
    mutate(next);
    return app.saveDeck(next);
  };

  const runTile = (tile: Tile, el: HTMLElement) => {
    app.haptic('light');
    const slow = setTimeout(() => el.classList.add('running'), 250);
    void app.runAction(tile.action).then((r) => {
      clearTimeout(slow);
      el.classList.remove('running');
      if (!r.ok) {
        el.classList.add('failed');
        app.haptic('error');
        setTimeout(() => el.classList.remove('failed'), 600);
        toast(r.message || t('deck.failed'), 'error', 'action');
      }
    });
  };

  const tileEl = (tile: Tile, index: number, page: DeckPage): HTMLElement => {
    const b = h(
      'button',
      {
        class: `tile${tile.color ? ' colored' : ''}`,
        type: 'button',
        role: 'gridcell',
        dataset: { index: String(index) },
        attrs: { 'aria-label': tile.label || t('deck.untitled') },
      },
      tileVisual(app, tile),
      tile.label ? h('span', { class: 'tile-label', text: tile.label }) : null,
    );
    if (tile.color) b.style.setProperty('--tile-color', tile.color);
    if (editing) {
      b.appendChild(h('span', { class: 'tile-grip', attrs: { 'aria-hidden': 'true' } }, icon('grip-vertical', 14)));
      bindDrag(b, index, page);
    } else {
      b.addEventListener('click', () => runTile(tile, b));
      paintScope.add(longPress(b, 550, () => setEditing(true)));
    }
    return b;
  };

  const bindDrag = (b: HTMLElement, index: number, page: DeckPage) => {
    let start: { x: number; y: number; id: number } | null = null;
    let lifted = false;
    b.addEventListener('pointerdown', (e) => {
      if (e.pointerType === 'mouse' && e.button !== 0) return;
      start = { x: e.clientX, y: e.clientY, id: e.pointerId };
      lifted = false;
      try {
        b.setPointerCapture(e.pointerId);
      } catch {
        // ignore
      }
    });
    b.addEventListener('pointermove', (e) => {
      if (!start || e.pointerId !== start.id) return;
      const dx = e.clientX - start.x;
      const dy = e.clientY - start.y;
      if (!lifted && Math.hypot(dx, dy) > 8) {
        lifted = true;
        b.classList.add('lifted');
      }
      if (lifted) b.style.transform = `translate(${dx}px, ${dy}px)`;
    });
    const finish = (e: PointerEvent, cancelled: boolean) => {
      if (!start || e.pointerId !== start.id) return;
      start = null;
      b.classList.remove('lifted');
      b.style.transform = '';
      if (cancelled) return;
      if (lifted) {
        const target = document.elementFromPoint(e.clientX, e.clientY)?.closest<HTMLElement>('.tile');
        const to = target?.dataset['index'];
        if (to !== undefined && Number(to) !== index) {
          const toIndex = Number(to);
          save((d) => {
            const p = d.pages.find((x) => x.id === page.id);
            if (!p) return;
            const [moved] = p.tiles.splice(index, 1);
            if (moved) p.tiles.splice(toIndex, 0, moved);
          });
          app.haptic('light');
        }
      } else {
        openTileEditor(app, page.id, index);
      }
    };
    b.addEventListener('pointerup', (e) => finish(e, false));
    b.addEventListener('pointercancel', (e) => finish(e, true));
  };

  const paint = () => {
    paintScope.dispose();
    paintScope = new Scope();
    const d = deck();
    const page = currentPage();
    editBtn.hidden = editing || !d;
    pageGear.hidden = !editing;
    done.hidden = !editing;
    grid.classList.toggle('editing', editing);
    chips.replaceChildren();
    grid.replaceChildren();

    if (!d || d.pages.length === 0) {
      scroller.hidden = true;
      empty.hidden = false;
      empty.replaceChildren(h('p', { text: t('deck.emptyDeck') }));
      if (app.connected && d) {
        empty.appendChild(button(t('deck.addPage'), () => addPage(), { variant: 'primary' }));
      }
      return;
    }
    for (const p of d.pages) {
      const selected = p.id === page?.id;
      const c = h('button', {
        class: 'page-chip',
        type: 'button',
        role: 'tab',
        text: p.name || t('deck.untitledPage'),
        attrs: { 'aria-selected': String(selected) },
      });
      c.addEventListener('click', () => {
        if (selected && editing) openPageSettings(app, p.id);
        else {
          app.updateSettings({ deckPage: p.id });
          paint();
        }
      });
      chips.appendChild(c);
    }
    if (editing) {
      const add = h('button', { class: 'page-chip', type: 'button', title: t('deck.addPage'), attrs: { 'aria-label': t('deck.addPage') } }, icon('plus', 16));
      add.addEventListener('click', () => addPage());
      chips.appendChild(add);
    }
    if (!page) return;
    applyColumns();
    const empties = page.tiles.length === 0 && !editing;
    scroller.hidden = empties;
    empty.hidden = !empties;
    if (empties) {
      empty.replaceChildren(h('p', { text: t('deck.emptyPage') }), button(t('deck.edit'), () => setEditing(true)));
      return;
    }
    page.tiles.forEach((tile, i) => grid.appendChild(tileEl(tile, i, page)));
    if (editing) {
      const add = h('button', { class: 'tile-add', type: 'button', title: t('deck.addTile'), attrs: { 'aria-label': t('deck.addTile') } }, icon('plus', 28));
      add.addEventListener('click', () => {
        if (page.tiles.length >= DECK_LIMITS.tiles) {
          toast(t('deck.limitTiles'), 'warning', 'deck');
          return;
        }
        openTileEditor(app, page.id, null);
      });
      grid.appendChild(add);
    }
  };

  const addPage = () => {
    const d = deck();
    if (!d) return;
    if (d.pages.length >= DECK_LIMITS.pages) {
      toast(t('deck.limitPages'), 'warning', 'deck');
      return;
    }
    const p = emptyPage(t('deck.newPageName', { n: d.pages.length + 1 }));
    if (save((x) => x.pages.push(p))) {
      app.updateSettings({ deckPage: p.id });
      paint();
    }
  };

  scope.add(app.events.on('deck', paint));
  scope.add(
    app.events.on('settings', () => applyColumns()),
  );
  paint();

  return {
    el,
    hidden() {
      if (editing) setEditing(false);
    },
    dispose: () => scope.dispose(),
  };
}
