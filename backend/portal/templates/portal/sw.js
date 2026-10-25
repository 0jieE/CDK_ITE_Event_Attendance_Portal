{% load static %}/* ITE Attendance portal - service worker (served at /portal/sw.js, scope /portal/).
 *
 *  1. App files (our CSS/JS/icons and the CDN libraries) are saved so the portal opens with no connection.
 *  2. Pages are NETWORK-FIRST: online you always get fresh data; offline you get the last saved copy of
 *     that page (with a marker so the page can say "saved copy from ..."). Only GET pages are saved.
 *  3. Never saved: sign-in/out, the credentials page (plaintext passwords), downloads (?format=), forms.
 *  4. Changes made offline are NOT handled here: the page keeps them in a queue (offline.js) and replays
 *     them when the connection is back.
 *  The saved pages belong to the signed-in user: the page asks this worker to clear them on logout or when
 *  a different user signs in.
 */
const VERSION = 'v4';
const STATIC = 'ite-static-' + VERSION;
const PAGES = 'ite-pages-v1';
const MAX_PAGES = 700;
const NAV_TIMEOUT_MS = 9000;

const LOCAL_ASSETS = [
  '{% static "portal/css/mobile.css" %}', '{% static "portal/css/offline.css" %}',
  '{% static "portal/js/mobile.js" %}', '{% static "portal/js/pwa.js" %}', '{% static "portal/js/offline.js" %}',
  '{% static "portal/img/ite-logo.png" %}', '{% static "portal/pwa/icon-192.png" %}', '{% static "portal/pwa/favicon-48.png" %}',
];
const CDN_ASSETS = [{% for url in cdn_assets %}'{{ url|escapejs }}'{% if not forloop.last %}, {% endif %}{% endfor %}];

const OFFLINE_HTML = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#0f2a14"><title>Offline · ITE Attendance</title>
<style>
  *{box-sizing:border-box} body{margin:0;min-height:100vh;min-height:100dvh;display:grid;place-items:center;padding:1.5rem;
  font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:#0f2a14;color:#e9f7e5;text-align:center}
  main{max-width:24rem} img{width:84px;height:84px;border-radius:50%;background:#fff;padding:4px}
  h1{font-size:1.4rem;margin:1.1rem 0 .4rem} p{margin:0 0 1.2rem;line-height:1.5;color:#b9d4b3}
  a,button{display:inline-block;border:0;border-radius:12px;padding:.85rem 1.4rem;font-size:1rem;font-weight:700;background:#41b422;color:#08210b;
  min-height:48px;text-decoration:none;margin:.2rem;font-family:inherit;cursor:pointer}
  a.alt{background:transparent;color:#e9f7e5;border:1px solid #41b422}
</style></head><body><main>
<img src="{% static 'portal/pwa/icon-192.png' %}" alt="">
<h1>You're offline</h1>
<p>This page hasn't been saved for offline use yet. Pages you have opened (and the main lists) are available without a connection.</p>
<a href="/portal/">Go to the dashboard</a><button onclick="location.reload()">Try again</button>
</main></body></html>`;

/* ------------------------------------------------------------------ helpers */
function pageKey(input) {
  // same page = same path + the same non-empty query (order ignored; an empty "semester" means ALL semesters, so it counts)
  const u = new URL(typeof input === 'string' ? input : input.url, self.location.origin);
  const pairs = Array.from(u.searchParams.entries()).filter(function (kv) { return kv[1] !== '' || kv[0] === 'semester'; })
    .sort(function (a, b) { return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0; });
  const q = new URLSearchParams(pairs).toString();
  return u.origin + u.pathname + (q ? '?' + q : '');
}

const NEVER_SAVE = [
  /^\/portal\/(login|logout)\//, /^\/portal\/students\/credentials\//, /^\/portal\/students\/import\/template\//,
  /^\/portal\/sw\.js$/, /^\/portal\/manifest\.webmanifest$/, /^\/portal\/offline\//,
  /\/(add|edit|delete|calculate|mark-paid|pay-slot|unpay-slot|toggle-active|activate)\/$/,
];
function savable(url) {
  if (url.searchParams.has('format')) return false;                          // CSV downloads
  return !NEVER_SAVE.some(function (re) { return re.test(url.pathname); });
}
function isLoginPage(res) {
  try { return res.redirected && new URL(res.url).pathname.indexOf('/portal/login/') === 0; } catch (e) { return false; }
}

async function remember(key, res) {
  const cache = await caches.open(PAGES);
  const headers = new Headers(res.headers);
  headers.set('x-cached-at', new Date().toISOString());
  const copy = new Response(await res.clone().blob(), { status: res.status, statusText: res.statusText, headers: headers });
  await cache.put(key, copy);
  const keys = await cache.keys();                                            // keep the cache bounded (oldest first)
  if (keys.length > MAX_PAGES) await Promise.all(keys.slice(0, keys.length - MAX_PAGES).map(function (k) { return cache.delete(k); }));
}

async function fromCache(req, key) {
  const cache = await caches.open(PAGES);
  const hit = await cache.match(key);
  if (!hit) return null;
  const cachedAt = hit.headers.get('x-cached-at') || '';
  const type = hit.headers.get('content-type') || '';
  if (req.mode === 'navigate' && type.indexOf('text/html') === 0) {          // tell the page it is a saved copy
    const html = (await hit.text()).replace('</head>', '<meta name="x-offline-copy" content="' + cachedAt + '"></head>');
    return new Response(html, { status: 200, headers: { 'Content-Type': type, 'x-offline-copy': cachedAt } });
  }
  const headers = new Headers(hit.headers);
  headers.set('x-offline-copy', cachedAt);
  return new Response(await hit.blob(), { status: 200, headers: headers });
}

function withTimeout(promise, ms) {
  return new Promise(function (resolve, reject) {
    const t = setTimeout(function () { reject(new Error('timeout')); }, ms);
    promise.then(function (v) { clearTimeout(t); resolve(v); }, function (e) { clearTimeout(t); reject(e); });
  });
}

async function networkFirst(event) {
  const req = event.request;
  const url = new URL(req.url);
  const key = pageKey(req);
  const canSave = savable(url);
  const navigating = req.mode === 'navigate';
  try {
    let fetched = fetch(req);
    // a slow server (free hosting waking up) should not hold a page hostage when a saved copy exists
    if (navigating && canSave) {
      const saved = await (await caches.open(PAGES)).match(key);
      if (saved) fetched = withTimeout(fetched, NAV_TIMEOUT_MS);
    }
    const res = await fetched;
    if (canSave && res.status === 200 && res.type === 'basic' && !isLoginPage(res)) event.waitUntil(remember(key, res));
    return res;
  } catch (err) {
    if (canSave) {
      const hit = await fromCache(req, key);
      if (hit) return hit;
    }
    if (navigating) return new Response(OFFLINE_HTML, { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8' } });
    return new Response('', { status: 503, headers: { 'x-offline': '1' } });
  }
}

async function staleWhileRevalidate(event) {
  const req = event.request;
  const cache = await caches.open(STATIC);
  const hit = await cache.match(req);
  const refresh = fetch(req).then(function (res) {
    if (res && (res.ok || res.type === 'opaque')) cache.put(req, res.clone());
    return res;
  }).catch(function () { return null; });
  if (hit) { event.waitUntil(refresh); return hit; }
  const res = await refresh;
  return res || new Response('', { status: 504 });
}

/* ------------------------------------------------------------------ lifecycle */
self.addEventListener('install', function (event) {
  event.waitUntil((async function () {
    const cache = await caches.open(STATIC);
    await Promise.all(LOCAL_ASSETS.map(function (u) { return cache.add(u).catch(function () {}); }));
    // CDN libraries: opaque (no-cors) copies, best effort - a missing one must not block the install
    await Promise.all(CDN_ASSETS.map(function (u) {
      return fetch(u, { mode: 'no-cors' }).then(function (r) { return cache.put(u, r); }).catch(function () {});
    }));
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', function (event) {
  event.waitUntil((async function () {
    const keep = [STATIC, PAGES];
    const names = await caches.keys();
    await Promise.all(names.filter(function (n) { return keep.indexOf(n) === -1; }).map(function (n) { return caches.delete(n); }));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', function (event) {
  const req = event.request;
  if (req.method !== 'GET') return;                                          // writes are queued by the page, never here
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) {
    if (['style', 'script', 'font', 'image'].indexOf(req.destination) !== -1) event.respondWith(staleWhileRevalidate(event));
    return;
  }
  if (url.pathname.indexOf('/static/') === 0) { event.respondWith(staleWhileRevalidate(event)); return; }
  if (url.pathname.indexOf('/portal/') === 0 && url.pathname !== '/portal/sw.js' && !/^\/portal\/(manifest|offline\/manifest)/.test(url.pathname)) {
    event.respondWith(networkFirst(event));
  }
});

/* ------------------------------------------------------------------ messages from the page */
async function broadcast(message) {
  const all = await self.clients.matchAll({ includeUncontrolled: true });
  all.forEach(function (c) { c.postMessage(message); });
}

async function prefetch(urls) {
  const queue = urls.slice(), total = queue.length;
  let done = 0, saved = 0, failed = 0, authLost = false;
  async function worker() {
    while (queue.length && !authLost) {
      const u = queue.shift();
      try {
        const res = await fetch(u, { credentials: 'same-origin', headers: { 'X-Prefetch': '1' } });
        if (isLoginPage(res)) { authLost = true; }
        else if (res.status === 200 && res.type === 'basic') { await remember(pageKey(u), res); saved++; }
        else failed++;
      } catch (e) { failed++; }
      done++;
      if (done % 5 === 0 || done === total) broadcast({ type: 'prefetch-progress', done: done, total: total });
    }
  }
  await Promise.all([worker(), worker(), worker()]);
  broadcast({ type: 'prefetch-done', saved: saved, failed: failed, total: total, authLost: authLost, at: new Date().toISOString() });
}

self.addEventListener('message', function (event) {
  const data = event.data || {};
  if (data.type === 'prefetch' && Array.isArray(data.urls)) event.waitUntil(prefetch(data.urls));
  else if (data.type === 'clear-pages') event.waitUntil(caches.delete(PAGES).then(function () { return broadcast({ type: 'pages-cleared' }); }));
  else if (data.type === 'warm-assets' && Array.isArray(data.urls)) {
    event.waitUntil(caches.open(STATIC).then(function (cache) {
      return Promise.all(data.urls.map(function (u) {
        return cache.match(u).then(function (hit) {
          if (hit) return null;
          const same = new URL(u, self.location.origin).origin === self.location.origin;
          return fetch(u, same ? {} : { mode: 'no-cors' }).then(function (r) { return cache.put(u, r); }).catch(function () {});
        });
      }));
    }));
  } else if (data.type === 'count-pages') {
    event.waitUntil(caches.open(PAGES).then(function (c) { return c.keys(); }).then(function (k) { broadcast({ type: 'pages-count', count: k.length }); }));
  }
});
