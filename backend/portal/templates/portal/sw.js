{% load static %}/* ITE Attendance portal - minimal service worker (served at /portal/sw.js, scope /portal/).
 *
 * What it does: lets browsers treat the portal as an installable app and shows a friendly page when the
 * network is down. What it deliberately does NOT do: cache anything. Logged-in pages carry personal data
 * (students, fines, credentials), so nothing is ever stored by this worker and nothing stale can be shown.
 */
const OFFLINE_HTML = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#0f2a14"><title>Offline · ITE Attendance</title>
<style>
  *{box-sizing:border-box} body{margin:0;min-height:100vh;min-height:100dvh;display:grid;place-items:center;padding:1.5rem;
  font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:#0f2a14;color:#e9f7e5;text-align:center}
  main{max-width:22rem} img{width:84px;height:84px;border-radius:50%;background:#fff;padding:4px}
  h1{font-size:1.4rem;margin:1.1rem 0 .4rem} p{margin:0 0 1.4rem;line-height:1.5;color:#b9d4b3}
  button{border:0;border-radius:12px;padding:.85rem 1.6rem;font-size:1rem;font-weight:700;background:#41b422;color:#08210b;min-height:48px}
</style></head><body><main>
<img src="{% static 'portal/pwa/icon-192.png' %}" alt="">
<h1>You're offline</h1>
<p>The portal needs an internet connection to show up-to-date attendance and fines. Check your connection and try again.</p>
<button onclick="location.reload()">Try again</button>
</main></body></html>`;

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => {
  // remove anything an older version might have stored, then take control of open pages
  event.waitUntil(caches.keys().then((keys) => Promise.all(keys.map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.mode !== 'navigate') return;                       // only page loads; everything else goes straight to the network
  event.respondWith(
    fetch(req).catch(() => new Response(OFFLINE_HTML, { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8' } }))
  );
});
