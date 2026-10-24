// Short vibrations. Android uses navigator.vibrate; iOS Safari has no vibrate,
// so a hidden native switch is toggled to get the system tick.
export type HapticKind = 'select' | 'light' | 'medium' | 'heavy' | 'error';

const PATTERNS: Record<HapticKind, number | number[]> = {
  select: 10,
  light: 15,
  medium: 25,
  heavy: 38,
  error: [28, 45, 28],
};

let enabled = true;
let iosLabel: HTMLLabelElement | null = null;

export function setHapticsEnabled(on: boolean): void {
  enabled = on;
}

function iosTick(): void {
  if (!iosLabel) {
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.setAttribute('switch', '');
    input.id = 'haptic-switch';
    input.tabIndex = -1;
    input.setAttribute('aria-hidden', 'true');
    const label = document.createElement('label');
    label.htmlFor = input.id;
    label.className = 'haptic-switch';
    label.setAttribute('aria-hidden', 'true');
    label.appendChild(input);
    document.body.appendChild(label);
    iosLabel = label;
  }
  iosLabel.click();
}

export function haptic(kind: HapticKind): void {
  if (!enabled) return;
  const nav = globalThis.navigator as Navigator & { vibrate?: (p: number | number[]) => boolean };
  if (typeof nav?.vibrate === 'function') {
    try {
      nav.vibrate(PATTERNS[kind]);
    } catch {
      // ignore
    }
    return;
  }
  if (!/iP(hone|ad|od)|Macintosh/.test(nav?.userAgent ?? '') || !('ontouchend' in document)) return;
  iosTick();
  if (kind === 'error') setTimeout(iosTick, 80);
}
