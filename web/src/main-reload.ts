// Reload once when a lazily loaded chunk is missing (the Mac has a newer client).
import { keys, session } from './store/storage';

export function reloadForChunk(): void {
  const ss = session();
  try {
    const at = Number(ss?.getItem(keys.chunkReload) ?? 0);
    if (Date.now() - at < 10000) return;
    ss?.setItem(keys.chunkReload, String(Date.now()));
  } catch {
    // ignore
  }
  location.reload();
}
