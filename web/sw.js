// AR Farm Timer service worker: offline app shell + push alerts.
// The cache version and precache list placeholders below are filled in by tool/gen_sw.py after
// `flutter build web` (see tool/build_web.sh). Do not register Flutter's own
// flutter_service_worker.js alongside this one.
'use strict';

const CACHE_VERSION = '__CACHE_VERSION__';
const CACHE = 'arft-' + CACHE_VERSION;
const PRECACHE = __PRECACHE__;

// Copy a response that went through a redirect into a plain one, so the
// browser accepts it for any request mode.
async function cleanResponse(resp) {
  if (!resp.redirected) return resp;
  const body = await resp.blob();
  return new Response(body, { status: resp.status, statusText: resp.statusText, headers: resp.headers });
}

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) =>
      cache.addAll(PRECACHE.map((u) => new Request(u, { cache: 'reload' })))),
  );
  // No skipWaiting() here: an update waits until the page asks (update banner)
  // or every tab is closed, so a running app never mixes two versions.
  // Exception: the old pages.dev address takes the update at once (the page
  // reloads on controllerchange), so its users see the "moved" notice or
  // the redirect to artimer.win on their next visit, not a version later.
  if (self.location.hostname === 'archerage-farm-timer.pages.dev') self.skipWaiting();
});

self.addEventListener('message', (event) => {
  // Only pages of this origin can message their service worker; check anyway.
  if (event.origin && event.origin !== self.location.origin) return;
  if (event.data && event.data.type === 'SKIP_WAITING') self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter((k) => k.startsWith('arft-') && k !== CACHE).map((k) => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return; // push server etc. go to the network
  if (url.pathname.endsWith('/sw.js')) return;

  if (req.mode === 'navigate' && /\/privacy(\.html)?$/.test(url.pathname)) {
    // Static privacy page: its own document, never the app shell. Network
    // first (the text can change between app versions), precached copy offline.
    event.respondWith((async () => {
      try {
        return await fetch(req);
      } catch (e) {
        const cache = await caches.open(CACHE);
        const cached = await cache.match(new URL('privacy.html', self.registration.scope).href);
        if (cached) return cleanResponse(cached);
        throw e;
      }
    })());
    return;
  }

  if (req.mode === 'navigate') {
    // App shell: serve the cached index.html, fall back to network.
    event.respondWith((async () => {
      const cache = await caches.open(CACHE);
      // The shell is cached under the scope URL ("./"), not "index.html":
      // hosts like Cloudflare Pages 308-redirect /index.html -> /, and a
      // redirected response can't answer a navigation (net::ERR_FAILED).
      const cached = (await cache.match(self.registration.scope)) ||
        (await cache.match(new URL('index.html', self.registration.scope).href));
      if (cached) return cleanResponse(cached);
      return fetch(req);
    })());
    return;
  }

  // Cache-first; anything not precached (e.g. Chrome's CanvasKit variant,
  // splash images) is cached on first use.
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const cached = await cache.match(req, { ignoreSearch: true });
    if (cached) return cleanResponse(cached);
    const resp = await fetch(req);
    if (resp.ok && !url.pathname.endsWith('.symbols')) cache.put(req, resp.clone());
    return resp;
  })());
});

// ---- Push alerts --------------------------------------------------------
// Only open URLs inside this app (the push server checks too): a tap on a
// notification must never open javascript:, data: or another site.
function appUrl(raw) {
  try {
    const u = new URL(raw, self.registration.scope);
    if (u.origin === self.location.origin && (u.protocol === 'https:' || u.protocol === 'http:')) return u.href;
  } catch { /* fall through */ }
  return self.registration.scope;
}

// Payloads use the Declarative Web Push format ({"web_push": 8030,
// "notification": {...}}), which iOS 18.4+ can show by itself. This handler
// shows it on older iOS (16.4+) and other browsers.
self.addEventListener('push', (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch { data = { notification: { title: event.data && event.data.text() } }; }
  const n = data.notification || data;
  const text = (v, max) => (typeof v === 'string' ? v.slice(0, max) : '');
  const title = text(n.title, 200) || 'AR Farm Timer';
  event.waitUntil(self.registration.showNotification(title, {
    body: text(n.body, 500),
    tag: text(n.tag, 64) || undefined,
    icon: 'icons/Icon-192.png',
    badge: 'icons/Icon-192.png',
    data: { url: appUrl(n.navigate || self.registration.scope) },
  }));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const target = appUrl((event.notification.data && event.notification.data.url) || self.registration.scope);
  event.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of all) {
      if ('focus' in c) return c.focus();
    }
    return self.clients.openWindow(target);
  })());
});
