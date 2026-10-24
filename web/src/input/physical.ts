// Hardware keyboard attached to the phone: forward keys to the Mac unless a
// text field is focused, an IME is composing or a sheet is open.
import type { App } from '../app';
import { out } from '../protocol/codec';
import { DOM_CODE_TO_MAC } from '../keyboard/layout';
import { sheetOpen } from '../ui/sheet';

function typingTarget(el: Element | null): boolean {
  if (!el) return false;
  if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement) return true;
  return (el as HTMLElement).isContentEditable === true;
}

export function installPhysicalKeyboard(app: App): () => void {
  const down = new Set<number>();
  const releaseAll = () => {
    for (const code of down) app.send(out.key(code, false));
    down.clear();
  };
  const onDown = (e: KeyboardEvent) => {
    if (!app.connected || e.isComposing || typingTarget(document.activeElement) || sheetOpen()) return;
    const code = DOM_CODE_TO_MAC[e.code];
    if (code === undefined) return;
    e.preventDefault();
    if (down.has(code)) return;
    down.add(code);
    app.send(out.key(code, true, 0, true));
  };
  const onUp = (e: KeyboardEvent) => {
    const code = DOM_CODE_TO_MAC[e.code];
    if (code === undefined || !down.has(code)) return;
    e.preventDefault();
    down.delete(code);
    app.send(out.key(code, false));
  };
  window.addEventListener('keydown', onDown);
  window.addEventListener('keyup', onUp);
  window.addEventListener('blur', releaseAll);
  const off = app.events.on('suspend', releaseAll);
  return () => {
    releaseAll();
    window.removeEventListener('keydown', onDown);
    window.removeEventListener('keyup', onUp);
    window.removeEventListener('blur', releaseAll);
    off();
  };
}
