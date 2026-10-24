// Media tab: transport, volume and brightness, with client-side repeat.
import type { App } from '../app';
import type { MediaKey } from '../protocol/types';
import { t } from '../i18n';
import { h, Scope, type View } from '../ui/dom';
import { icon } from '../ui/icons';
import { bindPress } from '../ui/modrow';

export const REPEAT_FIRST_MS = 420;
export const REPEAT_EVERY_MS = 110;
export const VOLUME_THROTTLE_MS = 60;

/** click on press, again at 420 ms, then every 110 ms while held. */
export function repeater(fire: () => void): { start(): void; stop(): void } {
  let first: ReturnType<typeof setTimeout> | null = null;
  let every: ReturnType<typeof setInterval> | null = null;
  const stop = () => {
    if (first !== null) clearTimeout(first);
    if (every !== null) clearInterval(every);
    first = every = null;
  };
  return {
    start() {
      stop();
      fire();
      first = setTimeout(() => {
        fire();
        every = setInterval(fire, REPEAT_EVERY_MS);
      }, REPEAT_FIRST_MS);
    },
    stop,
  };
}

export function renderMediaView(app: App): View {
  const scope = new Scope();
  const stops: (() => void)[] = [];

  const round = (name: string, label: string, size = 24, big = false) =>
    h('button', { class: `round-btn${big ? ' big' : ''}`, type: 'button', title: label, attrs: { 'aria-label': label } }, icon(name, size));

  const clickBtn = (el: HTMLElement, key: MediaKey) => {
    el.addEventListener('click', () => {
      app.haptic('light');
      app.media(key);
    });
    return el;
  };
  const holdBtn = (el: HTMLElement, key: MediaKey) => {
    scope.add(
      bindPress(
        el,
        () => {
          app.haptic('light');
          app.media(key, 'down');
        },
        () => app.media(key, 'up'),
      ),
    );
    return el;
  };
  const repeatBtn = (el: HTMLElement, key: MediaKey) => {
    const r = repeater(() => app.media(key));
    stops.push(r.stop);
    scope.add(
      bindPress(
        el,
        () => {
          app.haptic('light');
          r.start();
        },
        () => r.stop(),
      ),
    );
    return el;
  };

  const transport = h(
    'div',
    { class: 'transport', role: 'group', attrs: { 'aria-label': t('media.transport') } },
    clickBtn(round('skip-back', t('media.previous')), 'previous'),
    holdBtn(round('rewind', t('media.rewind')), 'rewind'),
    clickBtn(round('play', t('media.playPause'), 34, true), 'playPause'),
    holdBtn(round('fast-forward', t('media.fastForward')), 'fastForward'),
    clickBtn(round('skip-forward', t('media.next')), 'next'),
  );

  const keyBtn = (name: string, label: string, key: MediaKey, cls = '') =>
    repeatBtn(h('button', { class: `key ${cls}`, type: 'button', title: label, attrs: { 'aria-label': label } }, icon(name, 20)), key);

  // Volume card.
  const slider = h('input', { class: 'slider', type: 'range', attrs: { min: 0, max: 1, step: 0.01, 'aria-label': t('media.volume') } });
  const pct = h('span', { class: 'volume-pct' });
  const muteBtn = h('button', { class: 'icon-btn', type: 'button' });
  const extraMute = keyBtn('volume-x', t('media.mute'), 'mute');
  const note = h('p', { class: 'note', text: t('media.noVolume') });
  const controlRow = h('div', { class: 'card-row' }, muteBtn, slider, pct);
  const volCard = h(
    'section',
    { class: 'card', attrs: { 'aria-label': t('media.volume') } },
    h(
      'div',
      { class: 'card-row' },
      h('span', { class: 'label', text: t('media.volume') }),
      extraMute,
      keyBtn('volume-1', t('media.volumeDown'), 'volumeDown'),
      keyBtn('volume-2', t('media.volumeUp'), 'volumeUp'),
    ),
    controlRow,
    note,
  );

  let dragging = false;
  let lastSentAt = 0;
  let trailing: ReturnType<typeof setTimeout> | null = null;
  const sendValue = () => {
    lastSentAt = performance.now();
    app.setVolume({ value: Number(slider.value), muted: false });
  };
  slider.addEventListener('pointerdown', () => (dragging = true));
  slider.addEventListener('input', () => {
    dragging = true;
    pct.textContent = `${Math.round(Number(slider.value) * 100)}%`;
    const since = performance.now() - lastSentAt;
    if (trailing !== null) clearTimeout(trailing);
    trailing = null;
    if (since >= VOLUME_THROTTLE_MS) sendValue();
    else trailing = setTimeout(sendValue, VOLUME_THROTTLE_MS - since);
  });
  const endDrag = () => {
    if (!dragging) return;
    dragging = false;
    if (trailing !== null) clearTimeout(trailing);
    trailing = null;
    sendValue();
  };
  slider.addEventListener('change', endDrag);
  slider.addEventListener('pointerup', endDrag);
  muteBtn.addEventListener('click', () => {
    app.haptic('light');
    app.setVolume({ muted: !(app.volume?.muted ?? false) });
  });

  const paintVolume = () => {
    const v = app.volume;
    const available = v !== null;
    controlRow.hidden = !available;
    note.hidden = available || !app.volumeKnown;
    extraMute.hidden = available;
    if (!v) return;
    if (!dragging) slider.value = String(v.value);
    slider.classList.toggle('muted', v.muted);
    pct.textContent = `${Math.round((dragging ? Number(slider.value) : v.value) * 100)}%`;
    muteBtn.replaceChildren(icon(v.muted ? 'volume-x' : 'volume-2', 20));
    muteBtn.classList.toggle('danger', v.muted);
    const label = v.muted ? t('media.unmute') : t('media.mute');
    muteBtn.setAttribute('aria-label', label);
    muteBtn.title = label;
    muteBtn.setAttribute('aria-pressed', String(v.muted));
  };

  // Brightness card.
  const brightCard = h(
    'section',
    { class: 'card', attrs: { 'aria-label': t('media.brightness') } },
    h(
      'div',
      { class: 'card-row' },
      h('span', { class: 'label', text: t('media.display') }),
      keyBtn('sun-dim', t('media.brightnessDown'), 'brightnessDown'),
      keyBtn('sun', t('media.brightnessUp'), 'brightnessUp'),
    ),
    h(
      'div',
      { class: 'card-row' },
      h('span', { class: 'label', text: t('media.keyboardLight') }),
      keyBtn('lightbulb', t('media.illuminationDown'), 'illuminationDown'),
      keyBtn('lightbulb', t('media.illuminationToggle'), 'illuminationToggle', 'dim'),
      keyBtn('lightbulb', t('media.illuminationUp'), 'illuminationUp'),
    ),
  );

  scope.add(app.events.on('volume', paintVolume));
  const stopAll = () => {
    for (const s of stops) s();
  };
  scope.add(app.events.on('suspend', stopAll));
  scope.add(stopAll);
  paintVolume();

  const el = h('section', { class: 'view scroll media' }, transport, volCard, brightCard);
  return { el, hidden: stopAll, dispose: () => scope.dispose() };
}
