// Custom keyboards: user grids of keys, modifiers, media keys and mouse buttons.
import type { App } from '../app';
import { MEDIA_KEYS, type MediaKey } from '../protocol/types';
import { t } from '../i18n';
import { h, Scope } from '../ui/dom';
import { button, errorLine, fieldBlock, select, switchRow, textField } from '../ui/controls';
import { confirmSheet, openSheet } from '../ui/sheet';
import { toast } from '../ui/toast';
import { bindPress } from '../ui/modrow';
import { createKeyPicker, comboLabel } from '../deck/keypicker';
import { MODIFIERS } from '../input/modifiers';
import {
  BOARD_LIMITS,
  boardFromTemplate,
  emptyBoard,
  freeCell,
  MOD_NAMES,
  placementError,
  shortId,
  TEMPLATE_IDS,
  type Board,
  type BoardKey,
  type KeyAction,
  type ModName,
  type TemplateId,
} from '../store/keyboards';
import { createPad } from './pad';

const TEMPLATE_LABEL: Record<TemplateId, 'tpl.presentation' | 'tpl.gamepad' | 'tpl.editing'> = {
  presentation: 'tpl.presentation',
  gamepad: 'tpl.gamepad',
  editing: 'tpl.editing',
};

export function keyLabel(app: App, k: BoardKey): string {
  if (k.label) return k.label;
  const a = k.action;
  switch (a.kind) {
    case 'key':
      return comboLabel(app, { code: a.code, mods: a.mods });
    case 'mod':
      return MODIFIERS[a.mod].symbol;
    case 'media':
      return t(`media.${a.key}`);
    case 'mouse':
      return t(`mouse.${a.button}`);
  }
}

export function createCustomKeyboards(app: App): { el: HTMLElement; dispose(): void } {
  const scope = new Scope();
  let inner = new Scope();
  scope.add(() => inner.dispose());
  let editing = false;
  const el = h('div', { class: 'composer' });

  const active = (): Board | undefined => app.keyboards.boards.find((b) => b.id === app.keyboards.active) ?? app.keyboards.boards[0];

  const addBoard = (b: Board) => {
    if (app.keyboards.boards.length >= BOARD_LIMITS.boards) {
      toast(t('ckb.limit'), 'warning', 'ckb');
      return;
    }
    app.updateKeyboards((k) => ({ active: b.id, boards: [...k.boards, b] }));
  };
  const templateSelect = () =>
    select(
      [{ value: '', label: t('ckb.fromTemplate') }, ...TEMPLATE_IDS.map((id) => ({ value: id, label: t(TEMPLATE_LABEL[id]) }))],
      '',
      (v) => {
        if (v) addBoard(boardFromTemplate(v as TemplateId, t(TEMPLATE_LABEL[v as TemplateId])));
      },
      t('ckb.fromTemplate'),
    );

  const paint = () => {
    inner.dispose();
    inner = new Scope();
    el.replaceChildren();
    const board = active();
    if (!board) {
      editing = false;
      el.appendChild(
        h(
          'div',
          { class: 'empty' },
          h('p', { text: t('ckb.empty') }),
          button(t('ckb.new'), () => addBoard(emptyBoard(t('ckb.defaultName'))), { variant: 'primary' }),
          ...TEMPLATE_IDS.map((id) => button(t('ckb.fromTemplateNamed', { name: t(TEMPLATE_LABEL[id]) }), () => addBoard(boardFromTemplate(id, t(TEMPLATE_LABEL[id]))))),
        ),
      );
      return;
    }

    const picker = select(
      app.keyboards.boards.map((b) => ({ value: b.id, label: b.name || t('ckb.defaultName') })),
      board.id,
      (v) => app.updateKeyboards((k) => ({ ...k, active: v })),
      t('ckb.active'),
    );
    const editBtn = button(editing ? t('deck.done') : t('ckb.edit'), () => {
      editing = !editing;
      paint();
    }, { variant: editing ? 'small-primary' : 'small' });
    el.appendChild(h('div', { class: 'kb-head' }, picker, h('span', { class: 'spacer' }), editBtn));

    const grid = h('div', { class: `custom-grid${editing ? ' editing' : ''}`, role: 'group', attrs: { 'aria-label': board.name } });
    grid.style.gridTemplateColumns = `repeat(${board.cols}, minmax(0, 1fr))`;
    grid.style.gridTemplateRows = `repeat(${board.rows}, minmax(0, 1fr))`;
    for (const k of board.keys) grid.appendChild(keyElement(board, k, grid));
    el.appendChild(grid);

    if (board.trackpad) {
      const pad = createPad(app, { cls: 'mini-pad' });
      inner.add(() => pad.dispose());
      el.appendChild(pad.el);
    } else {
      grid.style.flex = '1';
    }

    if (editing) {
      el.appendChild(
        h(
          'div',
          { class: 'edit-bar' },
          button(t('ckb.addKey'), () => {
            const cell = freeCell(board);
            if (!cell) return toast(t('ckb.full'), 'warning', 'ckb');
            openKeySheet(board, null, cell);
          }, { variant: 'small', icon: 'plus' }),
          button(t('ckb.editBoard'), () => openBoardSheet(board), { variant: 'small' }),
          button(t('ckb.new'), () => addBoard(emptyBoard(t('ckb.defaultName'))), { variant: 'small' }),
          templateSelect(),
        ),
      );
    }
  };

  const fire = (a: KeyAction, down: boolean) => {
    switch (a.kind) {
      case 'key':
        if (down) app.keyDown(a.code, a.mods);
        else app.keyUp(a.code);
        break;
      case 'mod':
        if (down) app.mods.press(a.mod);
        else app.mods.release(a.mod);
        break;
      case 'media':
        if (down) app.media(a.key);
        break;
      case 'mouse':
        app.button(a.button, down ? 'down' : 'up');
        break;
    }
  };

  const keyElement = (board: Board, k: BoardKey, grid: HTMLElement): HTMLElement => {
    const label = keyLabel(app, k);
    const elx = h('div', { class: 'key', role: 'button', tabIndex: 0, text: label, attrs: { 'aria-label': label } });
    elx.style.gridColumn = `${k.x + 1} / span ${k.w}`;
    elx.style.gridRow = `${k.y + 1} / span ${k.h}`;
    if (!editing) {
      inner.add(
        bindPress(
          elx,
          () => {
            app.haptic('select');
            fire(k.action, true);
          },
          () => fire(k.action, false),
        ),
      );
      if (k.action.kind === 'mod') {
        const mod = k.action.mod;
        const paintMod = () => {
          elx.dataset['mod'] = app.mods.state(mod);
        };
        paintMod();
        inner.add(app.mods.onChange(paintMod));
      }
      return elx;
    }
    // Editing: drag to move, corner handle to resize, tap to edit.
    const handle = h('span', { class: 'resize-handle', attrs: { 'aria-hidden': 'true' } });
    elx.appendChild(handle);
    let start: { x: number; y: number; id: number; resize: boolean } | null = null;
    let moved = false;
    let preview: BoardKey = { ...k };
    const cellSize = () => {
      const r = grid.getBoundingClientRect();
      return { w: r.width / board.cols, h: r.height / board.rows };
    };
    elx.addEventListener('pointerdown', (e) => {
      start = { x: e.clientX, y: e.clientY, id: e.pointerId, resize: e.target === handle };
      moved = false;
      preview = { ...k };
      try {
        elx.setPointerCapture(e.pointerId);
      } catch {
        // ignore
      }
    });
    elx.addEventListener('pointermove', (e) => {
      if (!start || e.pointerId !== start.id) return;
      const dx = e.clientX - start.x;
      const dy = e.clientY - start.y;
      if (!moved && Math.hypot(dx, dy) < 8) return;
      moved = true;
      const c = cellSize();
      const cx = Math.round(dx / c.w);
      const cy = Math.round(dy / c.h);
      const next = start.resize
        ? { ...k, w: Math.max(1, k.w + cx), h: Math.max(1, k.h + cy) }
        : { ...k, x: k.x + cx, y: k.y + cy };
      if (!placementError(board, next)) {
        preview = next;
        elx.style.gridColumn = `${next.x + 1} / span ${next.w}`;
        elx.style.gridRow = `${next.y + 1} / span ${next.h}`;
      }
    });
    elx.addEventListener('pointerup', (e) => {
      if (!start || e.pointerId !== start.id) return;
      start = null;
      if (!moved) {
        openKeySheet(board, k, null);
        return;
      }
      const final = preview;
      app.haptic('light');
      app.updateKeyboards((s) => ({
        ...s,
        boards: s.boards.map((b) => (b.id === board.id ? { ...b, keys: b.keys.map((x) => (x.id === k.id ? final : x)) } : b)),
      }));
    });
    elx.addEventListener('pointercancel', () => {
      start = null;
      paint();
    });
    elx.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') openKeySheet(board, k, null);
    });
    return elx;
  };

  const openKeySheet = (board: Board, existing: BoardKey | null, cell: { x: number; y: number } | null) => {
    const sheet = openSheet(existing ? t('ckb.keyTitle') : t('ckb.addKey'));
    const draft: BoardKey = existing
      ? structuredClone(existing)
      : { id: shortId('k-'), x: cell?.x ?? 0, y: cell?.y ?? 0, w: 1, h: 1, action: { kind: 'key', code: 0, mods: 0 } };
    const err = errorLine();
    const labelField = textField(draft.label ?? '', (v) => {
      const s = Array.from(v).slice(0, BOARD_LIMITS.label).join('');
      if (s) draft.label = s;
      else delete draft.label;
    }, { maxLength: 12, label: t('ckb.keyLabel') });
    const fields = h('div', { class: 'editor' });
    const kindSel = select(
      [
        { value: 'key', label: t('ckb.kindKey') },
        { value: 'mod', label: t('ckb.kindMod') },
        { value: 'media', label: t('ckb.kindMedia') },
        { value: 'mouse', label: t('ckb.kindMouse') },
      ],
      draft.action.kind,
      (v) => {
        draft.action =
          v === 'key'
            ? { kind: 'key', code: 0, mods: 0 }
            : v === 'mod'
              ? { kind: 'mod', mod: 'shift' }
              : v === 'media'
                ? { kind: 'media', key: 'playPause' }
                : { kind: 'mouse', button: 'left' };
        renderFields();
      },
      t('ckb.kind'),
    );
    const renderFields = () => {
      fields.replaceChildren();
      const a = draft.action;
      if (a.kind === 'key') {
        const p = createKeyPicker(app, { code: a.code, mods: a.mods }, (v) => {
          draft.action = { kind: 'key', code: v.code, mods: v.mods & 0x1f };
        });
        fields.appendChild(p.el);
      } else if (a.kind === 'mod') {
        fields.appendChild(
          fieldBlock(
            t('ckb.kindMod'),
            select(MOD_NAMES.map((m) => ({ value: m, label: `${MODIFIERS[m].symbol} ${t(`mod.${m}`)}` })), a.mod, (v) => {
              draft.action = { kind: 'mod', mod: v as ModName };
            }),
          ),
        );
      } else if (a.kind === 'media') {
        fields.appendChild(
          fieldBlock(
            t('ckb.kindMedia'),
            select(MEDIA_KEYS.map((m) => ({ value: m, label: t(`media.${m}`) })), a.key, (v) => {
              draft.action = { kind: 'media', key: v as MediaKey };
            }),
          ),
        );
      } else {
        fields.appendChild(
          fieldBlock(
            t('ckb.kindMouse'),
            select((['left', 'right', 'middle'] as const).map((b) => ({ value: b, label: t(`mouse.${b}`) })), a.button, (v) => {
              draft.action = { kind: 'mouse', button: v as 'left' | 'right' | 'middle' };
            }),
          ),
        );
      }
    };
    renderFields();

    const num = (key: 'x' | 'y' | 'w' | 'h', label: string) => {
      const f = textField(String(draft[key]), (v) => {
        const n = Number.parseInt(v, 10);
        if (Number.isFinite(n)) draft[key] = key === 'x' || key === 'y' ? n - 1 : n;
      }, { type: 'number', label });
      if (key === 'x' || key === 'y') f.value = String(draft[key] + 1);
      f.inputMode = 'numeric';
      return fieldBlock(label, f);
    };
    const position = h(
      'details',
      {},
      h('summary', { text: t('ckb.position') }),
      h('div', { class: 'key-picker-top' }, num('x', t('ckb.col')), num('y', t('ckb.row')), num('w', t('ckb.width')), num('h', t('ckb.height'))),
    );

    sheet.body.append(fieldBlock(t('ckb.keyLabel'), labelField), fieldBlock(t('ckb.kind'), kindSel), fields, position, h('p', { class: 'note', text: t('ckb.dragHint') }), err);
    if (existing) {
      sheet.footer.appendChild(
        button(t('common.delete'), () => {
          app.updateKeyboards((s) => ({
            ...s,
            boards: s.boards.map((b) => (b.id === board.id ? { ...b, keys: b.keys.filter((x) => x.id !== existing.id) } : b)),
          }));
          sheet.close();
        }, { variant: 'danger' }),
      );
    }
    sheet.footer.appendChild(
      button(t('common.save'), () => {
        const pe = placementError(board, draft);
        if (pe) {
          err.set(pe === 'overlap' ? t('ckb.overlap') : t('ckb.outside'));
          return;
        }
        app.updateKeyboards((s) => ({
          ...s,
          boards: s.boards.map((b) =>
            b.id === board.id ? { ...b, keys: existing ? b.keys.map((x) => (x.id === draft.id ? draft : x)) : [...b.keys, draft] } : b,
          ),
        }));
        sheet.close();
      }, { variant: 'primary' }),
    );
  };

  const openBoardSheet = (board: Board) => {
    const sheet = openSheet(t('ckb.editBoard'));
    const draft = { name: board.name, cols: board.cols, rows: board.rows, trackpad: board.trackpad };
    const err = errorLine();
    sheet.body.append(
      fieldBlock(t('ckb.name'), textField(draft.name, (v) => (draft.name = Array.from(v).slice(0, 32).join('')), { maxLength: 32, label: t('ckb.name') })),
      fieldBlock(
        t('ckb.cols'),
        select(Array.from({ length: 11 }, (_, i) => ({ value: String(i + 2), label: String(i + 2) })), String(draft.cols), (v) => (draft.cols = Number(v))),
      ),
      fieldBlock(
        t('ckb.rows'),
        select(Array.from({ length: 8 }, (_, i) => ({ value: String(i + 1), label: String(i + 1) })), String(draft.rows), (v) => (draft.rows = Number(v))),
      ),
      h('div', { class: 'group-body' }, switchRow(t('ckb.trackpad'), draft.trackpad, (v) => (draft.trackpad = v))),
      err,
    );
    sheet.footer.append(
      button(t('ckb.deleteBoard'), () => {
        void confirmSheet({ title: t('ckb.deleteTitle'), message: t('ckb.deleteText', { name: board.name }), confirm: t('common.delete') }).then((yes) => {
          if (!yes) return;
          app.updateKeyboards((s) => {
            const boards = s.boards.filter((b) => b.id !== board.id);
            return { active: boards[0]?.id ?? '', boards };
          });
          sheet.close();
        });
      }, { variant: 'danger' }),
      button(t('common.save'), () => {
        const resized = { ...board, ...draft };
        if (board.keys.some((k) => placementError({ ...resized, keys: [] }, k))) {
          err.set(t('ckb.shrinkError'));
          return;
        }
        app.updateKeyboards((s) => ({ ...s, boards: s.boards.map((b) => (b.id === board.id ? resized : b)) }));
        sheet.close();
      }, { variant: 'primary' }),
    );
  };

  scope.add(app.events.on('keyboards', paint));
  scope.add(app.events.on('layout', paint));
  paint();
  return { el, dispose: () => scope.dispose() };
}
