// Bottom sheets (centered dialogs on wide screens) and confirmation sheets.
import { t } from '../i18n';
import { h } from './dom';
import { icon } from './icons';

export interface Sheet {
  root: HTMLElement;
  body: HTMLElement;
  footer: HTMLElement;
  close(): void;
  onClose(fn: () => void): void;
  readonly closed: boolean;
}

let seq = 0;
const open: Sheet[] = [];

export function sheetOpen(): boolean {
  return open.length > 0;
}

export function closeAllSheets(): void {
  for (const s of [...open]) s.close();
}

export function openSheet(title: string, opts: { wide?: boolean } = {}): Sheet {
  const titleId = `sheet-title-${++seq}`;
  const previousFocus = document.activeElement as HTMLElement | null;
  const closeFns: (() => void)[] = [];
  let closed = false;

  const body = h('div', { class: 'sheet-body' });
  const footer = h('div', { class: 'sheet-footer', hidden: true });
  const closeBtn = h(
    'button',
    { class: 'icon-btn', type: 'button', title: t('common.close'), attrs: { 'aria-label': t('common.close') } },
    icon('x'),
  );
  const panel = h(
    'div',
    {
      class: `sheet${opts.wide ? ' sheet-wide' : ''}`,
      role: 'dialog',
      attrs: { 'aria-modal': 'true', 'aria-labelledby': titleId },
    },
    h('div', { class: 'sheet-head' }, h('h2', { id: titleId, class: 'sheet-title', text: title }), closeBtn),
    body,
    footer,
  );
  const backdrop = h('div', { class: 'backdrop' });
  const root = h('div', { class: 'sheet-layer' }, backdrop, panel);

  const onKey = (e: KeyboardEvent) => {
    if (e.key === 'Escape' && open[open.length - 1] === sheet) {
      e.preventDefault();
      sheet.close();
    } else if (e.key === 'Tab') {
      trapFocus(panel, e);
    }
  };

  const sheet: Sheet = {
    root,
    body,
    footer,
    get closed() {
      return closed;
    },
    close() {
      if (closed) return;
      closed = true;
      const i = open.indexOf(sheet);
      if (i >= 0) open.splice(i, 1);
      document.removeEventListener('keydown', onKey, true);
      root.classList.add('leaving');
      setTimeout(() => root.remove(), 180);
      for (const fn of closeFns) fn();
      if (previousFocus && previousFocus.isConnected) previousFocus.focus({ preventScroll: true });
    },
    onClose(fn) {
      closeFns.push(fn);
    },
  };

  closeBtn.addEventListener('click', () => sheet.close());
  backdrop.addEventListener('click', () => sheet.close());
  document.addEventListener('keydown', onKey, true);
  const observer = new MutationObserver(() => {
    footer.hidden = footer.childElementCount === 0;
  });
  observer.observe(footer, { childList: true });
  closeFns.push(() => observer.disconnect());

  document.body.appendChild(root);
  open.push(sheet);
  requestAnimationFrame(() => panel.focus({ preventScroll: true }));
  panel.tabIndex = -1;
  return sheet;
}

function trapFocus(panel: HTMLElement, e: KeyboardEvent): void {
  const items = Array.from(
    panel.querySelectorAll<HTMLElement>('button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'),
  ).filter((el) => !el.hasAttribute('disabled') && el.offsetParent !== null);
  const first = items[0];
  const last = items[items.length - 1];
  if (!first || !last) return;
  if (e.shiftKey && document.activeElement === first) {
    e.preventDefault();
    last.focus();
  } else if (!e.shiftKey && document.activeElement === last) {
    e.preventDefault();
    first.focus();
  }
}

/** Own confirmation sheet instead of the browser's confirm(). */
export function confirmSheet(opts: { title: string; message: string; confirm: string; danger?: boolean }): Promise<boolean> {
  return new Promise((resolve) => {
    let answered = false;
    const s = openSheet(opts.title);
    s.body.appendChild(h('p', { class: 'muted', text: opts.message }));
    const cancel = h('button', { class: 'btn', type: 'button', text: t('common.cancel') });
    const ok = h('button', {
      class: opts.danger === false ? 'btn btn-primary' : 'btn btn-danger-fill',
      type: 'button',
      text: opts.confirm,
    });
    cancel.addEventListener('click', () => s.close());
    ok.addEventListener('click', () => {
      answered = true;
      s.close();
      resolve(true);
    });
    s.footer.append(cancel, ok);
    s.onClose(() => {
      if (!answered) resolve(false);
    });
  });
}
