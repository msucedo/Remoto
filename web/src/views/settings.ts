// Settings sheet, multi-finger gesture editor and "copy settings" sheet.
import { CLIENT_VERSION, type App } from '../app';
import type { Action, SettingsDevice } from '../protocol/types';
import { ago, t } from '../i18n';
import { h } from '../ui/dom';
import { icon } from '../ui/icons';
import { button, group, linkRow, selectRow, sliderRow, switchRow, textField, textRow, infoRow } from '../ui/controls';
import { confirmSheet, openSheet } from '../ui/sheet';
import { toast } from '../ui/toast';
import { DIRECTIONS, RANGES, resetSettings, type Direction, type Settings } from '../store/settings';
import { actionSummary, createActionEditor } from '../deck/actioneditor';
import { deviceKind } from '../device';

type Opt<T extends string> = { value: T; label: string };

function gestureRows(app: App, which: 'threeFinger' | 'fourFinger', repaint: () => void): HTMLElement[] {
  const dirLabel: Record<Direction, string> = {
    up: t('gesture.up'),
    down: t('gesture.down'),
    left: t('gesture.left'),
    right: t('gesture.right'),
    tap: t('gesture.tap'),
  };
  return DIRECTIONS.map((d) =>
    linkRow(dirLabel[d], actionSummary(app, app.settings[which][d]), () => {
      const title = `${which === 'threeFinger' ? t('gesture.three') : t('gesture.four')} · ${dirLabel[d]}`;
      const sheet = openSheet(title, { wide: true });
      const editor = createActionEditor(app, app.settings[which][d], { allowNone: true });
      sheet.body.appendChild(editor.el);
      sheet.footer.appendChild(
        button(t('common.save'), () => {
          if (editor.error()) return;
          const map = { ...app.settings[which], [d]: editor.value() as Action | null };
          app.updateSettings({ [which]: map } as Partial<Settings>);
          sheet.close();
          repaint();
        }, { variant: 'primary' }),
      );
    }),
  );
}

export function openCopySettings(app: App): void {
  const sheet = openSheet(t('copy.title'));
  const body = h('div', { class: 'stack', attrs: { 'aria-live': 'polite' } });
  sheet.body.appendChild(body);
  const load = () => {
    body.replaceChildren(h('div', { class: 'progress-line' }, h('span', { class: 'spinner small' }), h('span', { text: t('copy.asking') })));
    app
      .listOtherDevices()
      .then((devices) => {
        if (sheet.closed) return;
        body.replaceChildren();
        if (!devices.length) {
          body.appendChild(h('p', { class: 'muted', text: t('copy.none') }));
          return;
        }
        for (const d of devices) body.appendChild(deviceRow(d));
      })
      .catch((e: Error) => {
        if (sheet.closed || e.message === 'replaced') return;
        body.replaceChildren(h('p', { class: 'error-line', text: e.message }), button(t('copy.retry'), load));
      });
  };
  const deviceRow = (d: SettingsDevice) => {
    const row = h(
      'button',
      { class: 'device-row', type: 'button' },
      icon(deviceKind(d.model), 24),
      h('span', { class: 'meta' }, h('strong', { text: d.name || d.model }), h('small', { text: `${d.model} · ${t('copy.updated', { when: ago(d.updatedAt) })}` })),
    );
    row.addEventListener('click', () => {
      void confirmSheet({
        title: t('copy.confirmTitle'),
        message: t('copy.confirmText', { name: d.name || d.model }),
        confirm: t('copy.confirm'),
        danger: false,
      }).then((yes) => {
        if (!yes) return;
        app
          .copySettingsFrom(d.id)
          .then(() => {
            toast(t('copy.done'), 'info', 'settings');
            sheet.close();
          })
          .catch((e: Error) => {
            if (e.message !== 'replaced') toast(e.message, 'warning', 'settings');
          });
      });
    });
    return row;
  };
  load();
}

export function openSettingsSheet(app: App): void {
  const sheet = openSheet(t('settings.title'), { wide: true });
  const paint = () => {
    const s = app.settings;
    const set = (patch: Partial<Settings>) => app.updateSettings(patch);
    const opts = <const T extends string>(list: readonly (readonly [T, string])[]): Opt<T>[] => list.map(([value, label]) => ({ value, label }));

    // Connection.
    const status = app.conn.getStatus();
    const secure = app.features.secure || location.protocol === 'https:';
    const macLine = [app.macName || t('connect.yourMac'), secure ? t('status.secure') : t('status.insecure'), status.latency !== null ? t('status.latency', { n: status.latency }) : '']
      .filter(Boolean)
      .join(' · ');
    const nameField = textField(s.deviceName, (v) => set({ deviceName: v }), { maxLength: 40, placeholder: app.model, label: t('settings.deviceName') });
    nameField.autocapitalize = 'words';
    const connection = group(
      t('settings.connection'),
      infoRow(t('settings.mac'), macLine),
      textRow(t('settings.deviceName'), nameField),
      switchRow(t('connect.remember'), s.rememberDevice, (v) => set({ rememberDevice: v }), t('settings.rememberHint')),
      ...(!secure && app.connected ? [linkRow(t('settings.installCert'), '', () => window.open('/remoto.crt', '_blank', 'noopener'))] : []),
    );
    const connButtons = h(
      'div',
      { class: 'stack' },
      button(t('settings.releaseAll'), () => {
        app.releaseAll();
        toast(t('mods.released'), 'info', 'mods');
      }),
      button(t('settings.copyFrom'), () => openCopySettings(app), { disabled: !app.connected || !app.hasToken }),
      button(t('settings.disconnect'), () => {
        sheet.close();
        app.conn.disconnect();
      }),
      button(t('settings.forget'), () => {
        void confirmSheet({ title: t('settings.forgetTitle'), message: t('settings.forgetText'), confirm: t('settings.forget') }).then((yes) => {
          if (!yes) return;
          sheet.close();
          app.conn.forget();
        });
      }, { variant: 'danger' }),
    );

    const trackpad = group(
      t('settings.trackpad'),
      sliderRow(t('settings.pointerSpeed'), s.pointerSpeed, RANGES.pointerSpeed, 0.05, (v) => set({ pointerSpeed: v })),
      sliderRow(t('settings.acceleration'), s.pointerAcceleration, RANGES.pointerAcceleration, 0.05, (v) => set({ pointerAcceleration: v })),
      switchRow(t('settings.tapToClick'), s.tapToClick, (v) => set({ tapToClick: v })),
      switchRow(t('settings.twoFingerRight'), s.twoFingerTapRightClick, (v) => set({ twoFingerTapRightClick: v })),
      switchRow(t('settings.tapAndDrag'), s.tapAndDrag, (v) => set({ tapAndDrag: v })),
      switchRow(t('settings.dragLock'), s.dragLock, (v) => set({ dragLock: v })),
      selectRow(t('settings.longPress'), opts([['drag', t('settings.lpDrag')], ['rightClick', t('settings.lpRight')], ['off', t('settings.lpOff')]]), s.longPress, (v) => set({ longPress: v })),
      switchRow(t('settings.clickButtons'), s.clickButtons, (v) => set({ clickButtons: v })),
      sliderRow(t('settings.scrollSpeed'), s.scrollSpeed, RANGES.scrollSpeed, 0.05, (v) => set({ scrollSpeed: v })),
      switchRow(t('settings.naturalScroll'), s.naturalScroll, (v) => set({ naturalScroll: v })),
      switchRow(t('settings.momentum'), s.momentum, (v) => set({ momentum: v })),
      selectRow(t('settings.strip'), opts([['short', t('settings.stripShort')], ['long', t('settings.stripLong')], ['off', t('settings.stripOff')]]), s.scrollStrip, (v) => set({ scrollStrip: v })),
      selectRow(t('settings.stripSide'), opts([['right', t('settings.right')], ['left', t('settings.left')]]), s.scrollStripSide, (v) => set({ scrollStripSide: v })),
      switchRow(t('settings.scrollHold'), s.scrollHold, (v) => set({ scrollHold: v })),
      switchRow(t('settings.pinch'), s.pinchToZoom, (v) => set({ pinchToZoom: v })),
      switchRow(t('settings.showTouches'), s.showTouches, (v) => set({ showTouches: v })),
    );

    const gestures = group(
      t('settings.gestures'),
      h('h4', { class: 'group-sub', text: t('gesture.three') }),
      ...gestureRows(app, 'threeFinger', paint),
      h('h4', { class: 'group-sub', text: t('gesture.four') }),
      ...gestureRows(app, 'fourFinger', paint),
    );

    const keyboard = group(
      t('settings.keyboard'),
      selectRow(t('settings.kbMode'), opts([['auto', t('settings.kbAuto')], ['mac', t('kb.macLong')], ['custom', t('kb.custom')], ['phone', t('kb.phoneLong')]]), s.keyboard, (v) => set({ keyboard: v })),
      selectRow(t('settings.fnRow'), opts([['media', t('settings.fnMedia')], ['function', t('settings.fnKeys')]]), s.functionRow, (v) => set({ functionRow: v })),
      switchRow(t('settings.keyRepeat'), s.keyRepeat, (v) => set({ keyRepeat: v })),
      switchRow(t('settings.liveTyping'), s.liveTyping, (v) => set({ liveTyping: v })),
      selectRow(t('settings.textMode'), opts([['unicode', t('settings.tmUnicode')], ['keystrokes', t('settings.tmKeys')], ['paste', t('settings.tmPaste')]]), s.textMode, (v) => set({ textMode: v })),
    );

    const deck = group(
      t('settings.deck'),
      sliderRow(t('settings.buttonSize'), s.deckButtonSize, RANGES.deckButtonSize, 0.05, (v) => set({ deckButtonSize: v })),
      switchRow(t('settings.advanced'), s.showAdvanced, (v) => set({ showAdvanced: v })),
    );

    const general = group(
      t('settings.general'),
      selectRow(t('settings.theme'), opts([['system', t('settings.themeSystem')], ['dark', t('settings.themeDark')], ['light', t('settings.themeLight')]]), s.theme, (v) => set({ theme: v })),
      selectRow(t('settings.language'), opts([['auto', t('settings.langAuto')], ['en', 'English'], ['es', 'Español']]), s.language, (v) => {
        sheet.close();
        set({ language: v });
      }),
      switchRow(t('settings.haptics'), s.haptics, (v) => set({ haptics: v })),
      switchRow(t('settings.keepAwake'), s.keepAwake, (v) => set({ keepAwake: v })),
    );
    const reset = button(t('settings.reset'), () => {
      void confirmSheet({ title: t('settings.resetTitle'), message: t('settings.resetText'), confirm: t('settings.reset') }).then((yes) => {
        if (!yes) return;
        app.replaceSettings(resetSettings(app.settings));
        paint();
        toast(t('settings.resetDone'), 'info', 'settings');
      });
    }, { variant: 'danger' });
    const footer = h('p', {
      class: 'settings-footer',
      text: [t('settings.clientVersion', { v: CLIENT_VERSION }), app.host?.version ? t('settings.macVersion', { v: app.host.version }) : ''].filter(Boolean).join(' · '),
    });

    const scrollTop = sheet.body.scrollTop;
    sheet.body.replaceChildren(connection, connButtons, trackpad, gestures, keyboard, deck, general, reset, footer);
    sheet.body.scrollTop = scrollTop;
  };
  paint();
}
