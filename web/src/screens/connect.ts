// Connect screen: pairing by QR link, PIN or approval, and every error state.
import type { App } from '../app';
import type { ConnStatus } from '../net/connection';
import { t, type MessageKey } from '../i18n';
import { h, Scope, type View } from '../ui/dom';
import { icon } from '../ui/icons';
import { button, toggleSwitch } from '../ui/controls';

const DENY_KEYS: Record<string, MessageKey> = {
  wrongPin: 'deny.wrongPin',
  expiredCode: 'deny.expiredCode',
  pinClosed: 'deny.pinClosed',
  busy: 'deny.busy',
  incompatible: 'deny.incompatible',
};

/** Message for a denial; `blocked` gets its countdown from `secondsLeft`. */
export function deniedMessage(reason: string, method: string, secondsLeft: number): string {
  if (reason === 'blocked') return t('deny.blocked', { n: Math.max(1, secondsLeft) });
  if (reason === 'rejected') return t(method === 'pin' ? 'deny.rejectedPin' : 'deny.rejected');
  const key = DENY_KEYS[reason];
  return key ? t(key) : t('deny.other');
}

export function renderConnect(app: App): View {
  const scope = new Scope();
  const el = h('div', { class: 'screen', dataset: { screen: 'connect' } });
  const card = h('div', { class: 'connect-card' });
  el.appendChild(card);

  const brand = h('div', { class: 'brand', attrs: { 'aria-hidden': 'true' } }, icon('mouse-pointer-2', 28));
  const title = h('h1', { class: 'connect-title' });
  const hint = h('p', { class: 'connect-hint', text: t('connect.hint') });
  const progressText = h('span');
  const progress = h('div', { class: 'progress-line', hidden: true }, h('span', { class: 'spinner small' }), progressText);
  const message = h('div', { class: 'message-box', role: 'status', attrs: { 'aria-live': 'polite' }, hidden: true });
  const actions = h('div', { class: 'connect-actions' });

  // PIN form.
  const pinId = 'pin-input';
  const pin = h('input', {
    id: pinId,
    class: 'field pin-input',
    type: 'text',
    attrs: {
      inputmode: 'numeric',
      autocomplete: 'one-time-code',
      maxlength: 6,
      placeholder: '••••••',
      'aria-describedby': 'pin-help',
    },
  });
  const remember = toggleSwitch(app.settings.rememberDevice, (v) => app.updateSettings({ rememberDevice: v }), t('connect.remember'));
  const approveLink = button(t('connect.approve'), () => app.conn.connect({ method: 'approve' }), { variant: 'link' });
  const form = h(
    'div',
    { class: 'pin-form' },
    h('label', { class: 'field-label', text: t('connect.pinLabel'), attrs: { for: pinId } }),
    pin,
    h('small', { id: 'pin-help', class: 'sr-only', text: t('connect.pinHelp') }),
    h('div', { class: 'row' }, h('span', { class: 'row-label', text: t('connect.remember') }), remember),
    approveLink,
  );

  pin.addEventListener('input', () => {
    const digits = pin.value.replace(/\D/g, '').slice(0, 6);
    if (digits !== pin.value) pin.value = digits;
    if (digits.length === 6) {
      app.conn.connect({ method: 'pin', pin: digits });
      pin.blur();
    }
  });

  // Waiting for approval.
  const waitingText = h('p', { class: 'muted' });
  const waiting = h(
    'div',
    { class: 'connect-card', hidden: true },
    h('div', { class: 'spinner', style: 'margin:0 auto' }),
    h('h2', { class: 'waiting-title', text: t('connect.waitingTitle') }),
    waitingText,
    h('div', { class: 'connect-actions' }, button(t('common.cancel'), () => app.conn.disconnect('cancelled'))),
  );

  card.append(brand, title, hint, progress, message, actions, form);
  el.appendChild(waiting);

  let countdown: ReturnType<typeof setInterval> | null = null;
  const stopCountdown = () => {
    if (countdown !== null) clearInterval(countdown);
    countdown = null;
  };
  scope.add(stopCountdown);

  const setMessage = (text: string, error: boolean) => {
    message.hidden = !text;
    message.textContent = text;
    message.classList.toggle('error', error);
  };

  const update = (s: ConnStatus) => {
    const name = app.macName;
    title.textContent = name ? t('connect.titleNamed', { name }) : t('connect.title');
    stopCountdown();
    actions.replaceChildren();

    const pending = s.state === 'pending';
    card.hidden = pending;
    waiting.hidden = !pending;
    waitingText.textContent = t('connect.waitingText', { model: app.model, name: name || t('connect.yourMac') });

    const busy = s.state === 'connecting' || s.state === 'reconnecting';
    progress.hidden = !busy;
    progressText.textContent = s.method && s.method !== 'token' ? t('connect.pairing') : t('connect.connecting');
    pin.disabled = busy;
    hint.hidden = false;

    if (s.state === 'denied' && s.denied) {
      const d = s.denied;
      if (d.reason === 'wrongPin') pin.value = '';
      const render = () => {
        const left = Math.ceil((d.retryAfter ?? 30) - (performance.now() - d.at) / 1000);
        setMessage(deniedMessage(d.reason, d.method, left), true);
        if (d.reason === 'blocked' && left <= 0) {
          stopCountdown();
          setMessage(t('deny.blockedOver'), false);
        }
      };
      render();
      if (d.reason === 'blocked') countdown = setInterval(render, 1000);
      if (d.reason === 'incompatible') {
        actions.append(button(t('connect.reload'), () => location.reload(), { variant: 'primary' }));
      }
    } else if (s.state === 'idle') {
      const idleKey: Partial<Record<string, MessageKey>> = {
        unreachable: 'idle.unreachable',
        lostWaitingApproval: 'idle.lostWaitingApproval',
        unknownDevice: 'idle.unknownDevice',
        forgotten: 'idle.forgotten',
      };
      if (s.idleReason === 'bye') setMessage(s.byeMessage || t('idle.bye'), true);
      else {
        const k = idleKey[s.idleReason];
        setMessage(k ? t(k) : '', s.idleReason === 'unreachable' || s.idleReason === 'unknownDevice');
      }
      if (app.hasToken && s.idleReason !== 'unknownDevice') {
        actions.append(button(t('connect.reconnect'), () => app.conn.connect(), { variant: 'primary' }));
      }
    } else {
      setMessage('', false);
    }
  };

  scope.add(app.events.on('status', update));
  scope.add(app.events.on('info', () => update(app.conn.getStatus())));
  update(app.conn.getStatus());

  return { el, dispose: () => scope.dispose() };
}
