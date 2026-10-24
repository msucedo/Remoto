// Action editor used by deck tiles, sequence steps and multi-finger gestures.
import type { App } from '../app';
import {
  APP_OPS,
  MEDIA_KEYS,
  MOUSE_BUTTONS,
  SYSTEM_ACTIONS,
  type Action,
  type ActionKind,
  type AppOp,
  type MediaKey,
  type MouseButton,
  type SystemAction,
} from '../protocol/types';
import { t, type MessageKey } from '../i18n';
import { h } from '../ui/dom';
import { button, errorLine, fieldBlock, iconButton, select, textArea, textField, toggleSwitch } from '../ui/controls';
import { DECK_LIMITS, DEFAULT_KEYS_ACTION, validateAction } from './validate';
import { comboLabel, createKeyPicker } from './keypicker';
import { openAppPicker } from './apppicker';

const ADVANCED: readonly ActionKind[] = ['shortcut', 'mouse', 'sequence', 'delay', 'shell'];
const KIND_ORDER: readonly ActionKind[] = ['keys', 'system', 'media', 'app', 'text', 'url', 'shortcut', 'mouse', 'sequence', 'delay', 'shell'];
export const MAX_EDITOR_DEPTH = DECK_LIMITS.depth;

export function defaultAction(kind: ActionKind): Action {
  switch (kind) {
    case 'keys':
      return { ...DEFAULT_KEYS_ACTION };
    case 'system':
      return { kind: 'system', name: 'missionControl' };
    case 'media':
      return { kind: 'media', key: 'playPause' };
    case 'app':
      return { kind: 'app', id: '', op: 'toggle' };
    case 'text':
      return { kind: 'text', text: '' };
    case 'url':
      return { kind: 'url', url: 'https://' };
    case 'shortcut':
      return { kind: 'shortcut', name: '' };
    case 'shell':
      return { kind: 'shell', command: '' };
    case 'mouse':
      return { kind: 'mouse', button: 'left', clicks: 1 };
    case 'delay':
      return { kind: 'delay', ms: 250 };
    case 'sequence':
      return { kind: 'sequence', steps: [] };
  }
}

export function actionSummary(app: App | null, a: Action | null): string {
  if (!a) return t('action.none');
  switch (a.kind) {
    case 'keys':
      return comboLabel(app, { code: a.code, mods: a.mods ?? 0, ...(a.char ? { char: a.char } : {}) });
    case 'system':
      return t(`system.${a.name}`);
    case 'media':
      return t(`media.${a.key}`);
    case 'app': {
      const name = app?.apps?.find((x) => x.id === a.id)?.name ?? a.id;
      return `${t(`appop.${a.op ?? 'toggle'}`)}: ${name}`;
    }
    case 'text':
      return `${t('kind.text')}: ${a.text.slice(0, 40)}`;
    case 'url':
      return a.url;
    case 'shortcut':
      return `${t('kind.shortcut')}: ${a.name}`;
    case 'shell':
      return `$ ${a.command.slice(0, 40)}`;
    case 'mouse':
      return `${t(`mouse.${a.button}`)} ×${a.clicks ?? 1}`;
    case 'delay':
      return t('action.delaySummary', { ms: a.ms });
    case 'sequence':
      return t('action.sequenceSummary', { n: a.steps.length });
  }
}

export interface ActionEditor {
  el: HTMLElement;
  /** Current value; null means "Nothing" (gestures only). */
  value(): Action | null;
  /** Error message key for the current value, or null if valid. */
  error(): string | null;
}

export function createActionEditor(
  app: App,
  initial: Action | null,
  opts: { allowNone?: boolean; depth?: number; onChange?: () => void } = {},
): ActionEditor {
  const depth = opts.depth ?? 0;
  let value: Action | null = initial ? structuredClone(initial) : opts.allowNone ? null : defaultAction('keys');
  let fieldError: string | null = null;
  const children: ActionEditor[] = [];

  const kinds = KIND_ORDER.filter((k) => {
    if (value?.kind === k) return true;
    if (k === 'shell' && !app.features.shell) return false;
    if (k === 'sequence' && depth > MAX_EDITOR_DEPTH) return false;
    return !ADVANCED.includes(k) || app.settings.showAdvanced;
  });
  const options = [
    ...(opts.allowNone ? [{ value: 'none', label: t('action.none') }] : []),
    ...kinds.map((k) => ({ value: k, label: t(`kind.${k}`) })),
  ];
  const typeSelect = select(options, value?.kind ?? 'none', (v) => {
    value = v === 'none' ? null : defaultAction(v as ActionKind);
    renderFields();
    changed();
  }, t('action.type'));

  const fields = h('div', { class: 'editor' });
  const err = errorLine();
  const el = h('div', { class: 'editor' }, fieldBlock(t('action.type'), typeSelect), fields, err);

  const changed = () => {
    err.set(currentError());
    opts.onChange?.();
  };

  const currentError = (): string | null => {
    if (fieldError) return fieldError;
    if (!value) return null;
    if (value.kind === 'app' && !value.id) return t('err.appId');
    for (const c of children) {
      const e = c.error();
      if (e) return e;
    }
    const e = validateAction(value, depth);
    return e ? t(`err.${e}`) : null;
  };

  const renderFields = () => {
    fields.replaceChildren();
    children.length = 0;
    fieldError = null;
    const a = value;
    if (!a) return;
    switch (a.kind) {
      case 'keys': {
        const picker = createKeyPicker(app, { code: a.code, mods: a.mods ?? 0, ...(a.char ? { char: a.char } : {}) }, (v) => {
          const next: Action = { kind: 'keys', code: v.code };
          if (v.mods) next.mods = v.mods;
          if (v.char) next.char = v.char;
          value = next;
          fieldError = null;
          changed();
        });
        const check = () => {
          fieldError = picker.valid() ? null : t('keypick.noKey');
        };
        picker.el.addEventListener('input', () => {
          check();
          changed();
        });
        fields.appendChild(picker.el);
        break;
      }
      case 'system': {
        const opts2 = SYSTEM_ACTIONS.map((n) => ({ value: n, label: t(`system.${n}`) }));
        fields.appendChild(
          fieldBlock(
            t('kind.system'),
            select(opts2, a.name, (v) => {
              value = { kind: 'system', name: v as SystemAction };
              changed();
            }),
          ),
        );
        break;
      }
      case 'media': {
        const opts2 = MEDIA_KEYS.map((n) => ({ value: n, label: t(`media.${n}`) }));
        fields.appendChild(
          fieldBlock(
            t('kind.media'),
            select(opts2, a.key, (v) => {
              value = { kind: 'media', key: v as MediaKey };
              changed();
            }),
          ),
        );
        break;
      }
      case 'app': {
        const cur = { id: a.id, op: a.op ?? 'toggle' };
        const idField = textField(cur.id, (v) => {
          cur.id = v.trim();
          value = { kind: 'app', id: cur.id, op: cur.op };
          changed();
        }, { mono: true, label: t('action.appId'), placeholder: 'com.apple.Safari' });
        const pick = button(t('action.chooseApp'), () => {
          void openAppPicker(app).then((picked) => {
            if (!picked) return;
            idField.value = picked.id;
            cur.id = picked.id;
            value = { kind: 'app', id: cur.id, op: cur.op };
            changed();
          });
        }, { icon: 'app-window' });
        const opSel = select(APP_OPS.map((o) => ({ value: o, label: t(`appop.${o}`) })), cur.op, (v) => {
          cur.op = v as AppOp;
          value = { kind: 'app', id: cur.id, op: cur.op };
          changed();
        });
        fields.append(pick, fieldBlock(t('action.appId'), idField), fieldBlock(t('action.onTap'), opSel));
        break;
      }
      case 'text': {
        const cur = { text: a.text, enter: a.enter ?? false };
        const sync = () => {
          value = cur.enter ? { kind: 'text', text: cur.text, enter: true } : { kind: 'text', text: cur.text };
          changed();
        };
        const ta = textArea(cur.text, (v) => {
          cur.text = v;
          sync();
        }, { label: t('kind.text'), rows: 3 });
        const sw = toggleSwitch(cur.enter, (v) => {
          cur.enter = v;
          sync();
        }, t('action.enter'));
        fields.append(fieldBlock(t('kind.text'), ta), h('div', { class: 'row' }, h('span', { class: 'row-label', text: t('action.enter') }), sw));
        break;
      }
      case 'url':
        fields.appendChild(
          fieldBlock(
            t('kind.url'),
            textField(a.url, (v) => {
              value = { kind: 'url', url: v.trim() };
              changed();
            }, { type: 'url', placeholder: 'https://example.com', label: t('kind.url') }),
          ),
        );
        break;
      case 'shortcut':
        fields.appendChild(
          fieldBlock(
            t('action.shortcutName'),
            textField(a.name, (v) => {
              value = { kind: 'shortcut', name: v };
              changed();
            }, { label: t('action.shortcutName') }),
          ),
        );
        break;
      case 'shell':
        fields.append(
          h('p', { class: 'note', text: t('action.shellWarning') }),
          fieldBlock(
            t('kind.shell'),
            textArea(a.command, (v) => {
              value = { kind: 'shell', command: v };
              changed();
            }, { mono: true, rows: 3, label: t('kind.shell') }),
          ),
        );
        break;
      case 'mouse': {
        const cur = { button: a.button, clicks: a.clicks ?? 1 };
        const sync = () => {
          value = { kind: 'mouse', button: cur.button, clicks: cur.clicks };
          changed();
        };
        fields.append(
          fieldBlock(
            t('action.mouseButton'),
            select(MOUSE_BUTTONS.map((b) => ({ value: b, label: t(`mouse.${b}`) })), cur.button, (v) => {
              cur.button = v as MouseButton;
              sync();
            }),
          ),
          fieldBlock(
            t('action.clicks'),
            select(['1', '2', '3'].map((n) => ({ value: n, label: n })), String(cur.clicks), (v) => {
              cur.clicks = Number(v);
              sync();
            }),
          ),
        );
        break;
      }
      case 'delay': {
        const outEl = h('output', { class: 'row-value', text: t('action.delaySummary', { ms: a.ms }) });
        const range = h('input', { class: 'slider', type: 'range', attrs: { min: 50, max: 5000, step: 50, 'aria-label': t('kind.delay') } });
        range.value = String(Math.min(5000, Math.max(50, a.ms)));
        range.addEventListener('input', () => {
          const ms = Number(range.value);
          outEl.textContent = t('action.delaySummary', { ms });
          value = { kind: 'delay', ms };
          changed();
        });
        fields.append(h('div', { class: 'row-top' }, h('span', { class: 'row-label', text: t('kind.delay') }), outEl), range);
        break;
      }
      case 'sequence':
        renderSequence(a.steps);
        break;
    }
  };

  const renderSequence = (initialSteps: Action[]) => {
    const steps: { editor: ActionEditor }[] = [];
    const list = h('ol', { class: 'steps' });
    const sync = () => {
      const s: Action[] = [];
      for (const st of steps) {
        const v = st.editor.value();
        if (v) s.push(v);
      }
      value = { kind: 'sequence', steps: s };
      children.length = 0;
      children.push(...steps.map((x) => x.editor));
    };
    const paint = () => {
      list.replaceChildren();
      steps.forEach((st, i) => {
        const summary = h('span', { class: 'step-summary', text: `${i + 1}. ${actionSummary(app, st.editor.value())}` });
        const up = iconButton('chevron-up', t('action.stepUp'), () => move(i, -1));
        const down = iconButton('chevron-down', t('action.stepDown'), () => move(i, 1));
        const del = iconButton('trash-2', t('action.stepDelete'), () => {
          steps.splice(i, 1);
          sync();
          paint();
          changed();
        });
        up.disabled = i === 0;
        down.disabled = i === steps.length - 1;
        st.editor.el.addEventListener('input', () => {
          summary.textContent = `${i + 1}. ${actionSummary(app, st.editor.value())}`;
        });
        list.appendChild(h('li', { class: 'stack' }, h('div', { class: 'step-head' }, summary, up, down, del), st.editor.el));
      });
    };
    const move = (i: number, d: number) => {
      const j = i + d;
      const a = steps[i];
      const b = steps[j];
      if (!a || !b) return;
      steps[i] = b;
      steps[j] = a;
      sync();
      paint();
      changed();
    };
    const add = (a: Action) => {
      const editor = createActionEditor(app, a, {
        depth: depth + 1,
        onChange: () => {
          sync();
          changed();
        },
      });
      steps.push({ editor });
    };
    for (const s of initialSteps) add(s);
    sync();
    paint();
    const addBtn = button(t('action.addStep'), () => {
      if (steps.length >= DECK_LIMITS.steps) return;
      add({ kind: 'delay', ms: 250 });
      sync();
      paint();
      changed();
    }, { icon: 'plus', variant: 'small' });
    fields.append(list, addBtn);
  };

  renderFields();
  err.set(currentError());
  return {
    el,
    value: () => (value ? structuredClone(value) : null),
    error: currentError,
  };
}

export function kindLabelKey(k: ActionKind): MessageKey {
  return `kind.${k}`;
}
