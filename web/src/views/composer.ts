// Text composer ("Type"): live typing by grapheme diff, send-as-block mode,
// clipboard helpers and dictation.
import type { App } from '../app';
import { out } from '../protocol/codec';
import { t } from '../i18n';
import { h, Scope } from '../ui/dom';
import { icon } from '../ui/icons';
import { chip, iconButton } from '../ui/controls';
import { toast } from '../ui/toast';
import { bindKey } from '../ui/modrow';
import { KEY } from '../keyboard/layout';
import { appendWithSpace, diffGraphemes, graphemeCount, graphemes, LIVE_FIELD_MAX_GRAPHEMES } from '../text/graphemes';
import { Dictation, dictationSupported } from '../voice/dictation';

export interface Composer {
  el: HTMLElement;
  focus(): void;
  dispose(): void;
}

export function createComposer(app: App, opts: { inSheet?: boolean } = {}): Composer {
  const scope = new Scope();
  let lastSent = '';
  let composing = false;

  const ta = h('textarea', {
    class: 'field composer-text',
    attrs: {
      autocapitalize: 'sentences',
      autocomplete: 'off',
      spellcheck: 'true',
      'aria-label': t('compose.field'),
      enterkeyhint: 'send',
    },
  });

  const live = () => app.settings.liveTyping;

  const handleChange = () => {
    if (!live() || composing) return;
    const value = ta.value;
    const op = diffGraphemes(lastSent, value);
    if (!op) return;
    const latched = app.mods.peekLatched();
    if (latched && op.delete === 0 && graphemes(op.insert).length === 1) {
      const stroke = app.stroke(op.insert);
      if (stroke) {
        app.tap(stroke.code, stroke.mods);
        ta.value = lastSent;
        return;
      }
    }
    if (!app.send(out.edit(op.delete, op.insert))) return;
    lastSent = value;
    if (graphemeCount(value) > LIVE_FIELD_MAX_GRAPHEMES) {
      ta.value = '';
      lastSent = '';
    }
  };

  const sendBlock = () => {
    const text = ta.value;
    if (!text) return;
    if (app.text(text)) {
      ta.value = '';
      lastSent = '';
    } else {
      toast(t('toast.offline'), 'warning', 'offline');
    }
  };

  ta.addEventListener('input', handleChange);
  ta.addEventListener('compositionstart', () => {
    composing = true;
  });
  ta.addEventListener('compositionend', () => {
    composing = false;
    handleChange();
  });
  ta.addEventListener('keydown', (e) => {
    if (e.isComposing || composing) return;
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      if (live()) {
        handleChange();
        app.tap(KEY.Return);
        ta.value = '';
        lastSent = '';
      } else {
        sendBlock();
      }
    } else if (e.key === 'Backspace' && live() && ta.value === '') {
      e.preventDefault();
      app.tap(KEY.Delete);
    }
  });

  const placeholder = () => {
    ta.placeholder = live() ? t('compose.placeholderLive') : t('compose.placeholder');
  };

  // Toolbar.
  const liveChip = chip(t('compose.live'), live(), (v) => {
    app.updateSettings({ liveTyping: v });
    ta.value = '';
    lastSent = '';
  });
  const pastePhone = iconButton('clipboard-paste', t('compose.pastePhone'), () => {
    void (async () => {
      try {
        const text = await navigator.clipboard.readText();
        if (!text) return toast(t('compose.clipboardEmpty'), 'info', 'clip');
        if (app.send(out.text(text, 'paste'))) toast(t('compose.pasted'), 'info', 'clip');
      } catch {
        toast(t('compose.clipboardDenied'), 'warning', 'clip');
      }
    })();
  });
  const copyToMac = iconButton('clipboard-copy', t('compose.copyToMac'), () => {
    void (async () => {
      try {
        const text = await navigator.clipboard.readText();
        if (app.send(out.clipboardSet(text))) toast(t('compose.copiedToMac'), 'info', 'clip');
      } catch {
        toast(t('compose.clipboardDenied'), 'warning', 'clip');
      }
    })();
  });
  let wantClipboard = false;
  const fromMac = iconButton('clipboard', t('compose.fromMac'), () => {
    wantClipboard = app.send(out.clipboardGet());
  });
  scope.add(
    app.events.on('clipboard', (text) => {
      if (!wantClipboard) return;
      wantClipboard = false;
      if (text === null) return toast(t('compose.macClipboardEmpty'), 'info', 'clip');
      void navigator.clipboard
        .writeText(text)
        .then(() => toast(t('compose.copiedToPhone'), 'info', 'clip'))
        .catch(() => {
          ta.value = appendWithSpace(ta.value, text);
          handleChange();
          toast(t('compose.insertedInstead'), 'info', 'clip');
        });
    }),
  );
  const clearBtn = iconButton('eraser', t('compose.clear'), () => {
    ta.value = '';
    lastSent = '';
    ta.focus();
  });

  // Dictation.
  const line = h('div', { class: 'dictation-line', attrs: { 'aria-live': 'polite' } });
  const level = h('div', { class: 'level-bar', attrs: { 'aria-hidden': 'true' } });
  const mic = iconButton('mic', t('voice.start'), () => void dictation.toggle(), { cls: 'mic-btn' });
  const dictation = new Dictation(app, {
    state(active) {
      mic.classList.toggle('recording', active);
      mic.replaceChildren(icon(active ? 'mic-off' : 'mic', 20));
      const label = active ? t('voice.stop') : t('voice.start');
      mic.setAttribute('aria-label', label);
      mic.title = label;
      if (!active) level.style.width = '0';
    },
    level(peak) {
      level.style.width = `${Math.round(Math.min(1, peak * 1.6) * 100)}%`;
    },
    partial(text) {
      line.classList.remove('error');
      line.textContent = text;
    },
    final(text) {
      ta.value = appendWithSpace(ta.value, text);
      handleChange();
    },
    error(key, message) {
      line.classList.toggle('error', key !== null);
      line.textContent = key ? (message ?? t(key)) : '';
    },
  });
  scope.add(() => dictation.dispose());
  const refreshMic = () => {
    mic.hidden = !dictationSupported(app);
  };

  const tools = h('div', { class: 'composer-tools' }, liveChip, pastePhone, copyToMac, fromMac, clearBtn, h('span', { class: 'spacer' }), mic);

  // Key row.
  const keyEl = (name: string, label: string) =>
    h('div', { class: 'key', role: 'button', tabIndex: 0, attrs: { 'aria-label': label, title: label } }, icon(name, 18));
  const keys: [string, string, number][] = [
    ['arrow-left', t('key.left'), KEY.Left],
    ['arrow-down', t('key.down'), KEY.Down],
    ['arrow-up', t('key.up'), KEY.Up],
    ['arrow-right', t('key.right'), KEY.Right],
    ['delete', t('key.delete'), KEY.Delete],
    ['corner-down-left', t('key.return'), KEY.Return],
  ];
  const keyRow = h('div', { class: 'composer-keys' });
  for (const [name, label, code] of keys) {
    const k = keyEl(name, label);
    scope.add(bindKey(app, k, code));
    keyRow.appendChild(k);
  }
  const send = h('button', { class: 'key send-key', type: 'button' }, icon('send', 18), t('compose.send'));
  send.addEventListener('click', sendBlock);
  keyRow.appendChild(send);

  const refreshMode = () => {
    liveChip.setAttribute('aria-pressed', String(live()));
    send.hidden = live();
    placeholder();
    refreshMic();
  };
  refreshMode();
  scope.add(app.events.on('settings', refreshMode));
  scope.add(app.events.on('features', refreshMic));
  scope.add(
    app.events.on('welcome', () => {
      ta.value = '';
      lastSent = '';
    }),
  );

  const el = h('div', { class: `composer${opts.inSheet ? ' in-sheet' : ''}` }, tools, ta, line, level, keyRow);
  return {
    el,
    focus: () => ta.focus({ preventScroll: true }),
    dispose: () => scope.dispose(),
  };
}
