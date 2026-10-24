// Service worker: offline shell for the installed app. Registered only in a
// secure context. One cache; the Mac remains the source of truth.
/// <reference lib="webworker" />
export {};
declare const self: ServiceWorkerGlobalScope;

const CACHE = 'remoto-v1';
const NAV_RACE_MS = 3000;
const EXCLUDED = [/^\/api\//, /^\/ws$/, /^\/remoto\.crt$/];

self.addEventListener('install', () => {
  void self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      for (const key of await caches.keys()) if (key !== CACHE) await caches.delete(key);
      await self.clients.claim();
    })(),
  );
});

function assetRefs(html: string): Set<string> {
  const refs = new Set<string>();
  for (const m of html.matchAll(/\/assets\/[^"'\s)>]+/g)) refs.add(m[0]);
  return refs;
}

/** Drops cached /assets/* files the new HTML no longer references. */
async function purgeAssets(html: string): Promise<void> {
  const keep = assetRefs(html);
  const cache = await caches.open(CACHE);
  for (const req of await cache.keys()) {
    const path = new URL(req.url).pathname;
    // Lazy chunks are not referenced by the HTML either; they come back from
    // the network (network-first) the next time they are imported.
    if (path.startsWith('/assets/') && !keep.has(path)) await cache.delete(req);
  }
}

async function putNavigation(req: Request, res: Response): Promise<void> {
  if (!res.ok) return;
  const cache = await caches.open(CACHE);
  const html = await res.clone().text();
  const previous = await cache.match(req);
  await cache.put(req, res);
  if (previous && (await previous.text()) !== html) await purgeAssets(html);
}

async function navigate(event: FetchEvent): Promise<Response> {
  const req = event.request;
  const network = fetch(req);
  event.waitUntil(
    network.then((res) => putNavigation(req, res.clone())).catch(() => undefined),
  );
  const timeout = new Promise<null>((resolve) => setTimeout(() => resolve(null), NAV_RACE_MS));
  try {
    const first = await Promise.race([network, timeout]);
    if (first) return first;
  } catch {
    // offline: fall through to the cache
  }
  const cached = (await caches.match(req)) ?? (await caches.match('/'));
  if (cached) return cached;
  return network;
}

async function networkFirst(req: Request): Promise<Response> {
  const isAsset = new URL(req.url).pathname.startsWith('/assets/');
  try {
    const res = await fetch(req);
    if (res.ok) {
      const cache = await caches.open(CACHE);
      await cache.put(req, res.clone());
      return res;
    }
    if (isAsset) {
      const cached = await caches.match(req);
      if (cached) return cached;
    }
    return res;
  } catch (err) {
    const cached = await caches.match(req);
    if (cached) return cached;
    throw err;
  }
}

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (EXCLUDED.some((re) => re.test(url.pathname))) return;
  if (req.mode === 'navigate') {
    event.respondWith(navigate(event));
    return;
  }
  event.respondWith(networkFirst(req));
});
