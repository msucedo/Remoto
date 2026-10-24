// localStorage wrapper that never throws (private mode, quota, disabled storage).
export const APP_KEY = 'remoto';

export const keys = {
  deviceId: `${APP_KEY}.deviceId`,
  token: `${APP_KEY}.token`,
  settings: `${APP_KEY}.settings`,
  keyboards: `${APP_KEY}.keyboards`,
  settingsSync: `${APP_KEY}.settingsSync`,
  reloadedFor: `${APP_KEY}.reloadedFor`,
  reloadedAt: `${APP_KEY}.reloadedAt`,
  chunkReload: `${APP_KEY}.chunkReload`,
} as const;

const memory = new Map<string, string>();

function local(): Storage | null {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

export function getItem(key: string): string | null {
  try {
    const v = local()?.getItem(key);
    if (v !== null && v !== undefined) return v;
  } catch {
    // fall through to memory
  }
  return memory.get(key) ?? null;
}

export function setItem(key: string, value: string): void {
  memory.set(key, value);
  try {
    local()?.setItem(key, value);
  } catch {
    // memory copy only
  }
}

export function removeItem(key: string): void {
  memory.delete(key);
  try {
    local()?.removeItem(key);
  } catch {
    // ignore
  }
}

export function readJSON(key: string): unknown {
  const raw = getItem(key);
  if (raw === null) return undefined;
  try {
    return JSON.parse(raw) as unknown;
  } catch {
    return undefined;
  }
}

export function session(): Storage | null {
  try {
    return globalThis.sessionStorage ?? null;
  } catch {
    return null;
  }
}

function randomHex(bytes: number): string {
  const a = new Uint8Array(bytes);
  globalThis.crypto.getRandomValues(a);
  return Array.from(a, (b) => b.toString(16).padStart(2, '0')).join('');
}

/** Stable per-browser device id (UUID, or 32 hex when randomUUID is missing). */
export function deviceId(): string {
  const existing = getItem(keys.deviceId);
  if (existing && /^[\x21-\x7e]{1,128}$/.test(existing)) return existing;
  const id = typeof globalThis.crypto?.randomUUID === 'function' ? globalThis.crypto.randomUUID() : randomHex(16);
  setItem(keys.deviceId, id);
  return id;
}

/** Calls `fn` once `ms` have passed without another call; `flush` runs it now. */
export function debounce(fn: () => void, ms: number): { (): void; flush(): void; cancel(): void } {
  let timer: ReturnType<typeof setTimeout> | null = null;
  const run = () => {
    if (timer !== null) clearTimeout(timer);
    timer = setTimeout(() => {
      timer = null;
      fn();
    }, ms);
  };
  run.flush = () => {
    if (timer === null) return;
    clearTimeout(timer);
    timer = null;
    fn();
  };
  run.cancel = () => {
    if (timer !== null) clearTimeout(timer);
    timer = null;
  };
  return run;
}
