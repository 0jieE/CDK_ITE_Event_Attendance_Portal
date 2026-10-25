/* ITE Attendance portal - offline support (page side).
 *
 *  - detects the connection (events + a /healthz/ heartbeat, because navigator.onLine lies on captive Wi-Fi)
 *  - keeps changes made offline in an on-device queue (IndexedDB) and replays them, in order, when the
 *    connection is back: fine payments (pay a slot / undo / pay all), the event Active switch and
 *    "Set active semester". Everything else needs the server (validation) and says so.
 *  - shows what is going on: a status chip in the top bar, a "saved copy" banner, and a sync dialog
 *    where failed changes can be retried or discarded
 *  - asks the service worker to save the pages that matter for offline use, and to forget them on logout
 *
 * Queued changes belong to the signed-in user; they are only replayed under that same account.
 */
(function () {
  'use strict';

  var meta = function (name) { var m = document.querySelector('meta[name="' + name + '"]'); return m ? m.content : ''; };
  var USER = meta('portal-user');
  if (!USER) return;                                       // not a signed-in portal page (e.g. the login page)

  var QUEUEABLE = [
    { re: /^\/portal\/fines\/(\d+)\/pay-slot\/$/, kind: 'pay-slot', refresh: 'refresh-fines' },
    { re: /^\/portal\/fines\/(\d+)\/unpay-slot\/$/, kind: 'unpay-slot', refresh: 'refresh-fines' },
    { re: /^\/portal\/fines\/(\d+)\/mark-paid\/$/, kind: 'mark-paid', refresh: 'refresh-fines' },
    { re: /^\/portal\/events\/(\d+)\/toggle-active\/$/, kind: 'toggle-active', refresh: 'refresh-events' },
    { re: /^\/portal\/semesters\/(\d+)\/activate\/$/, kind: 'activate', refresh: 'refresh-semesters' }
  ];
  var SLOT_NAMES = { AM_IN: 'AM Time-In', AM_OUT: 'AM Time-Out', PM_IN: 'PM Time-In', PM_OUT: 'PM Time-Out' };
  var PREFETCH_EVERY_MS = 6 * 3600 * 1000;

  var root = document.documentElement;
  var state = { online: navigator.onLine !== false, syncing: false, queue: [], copyAt: meta('x-offline-copy'), prefetching: null };
  var $ = function (id) { return document.getElementById(id); };
  var store = {
    get: function (k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set: function (k, v) { try { localStorage.setItem(k, v); } catch (e) { /* private mode */ } },
    del: function (k) { try { localStorage.removeItem(k); } catch (e) { /* ignore */ } }
  };
  var fmt = function (iso) {
    if (!iso) return '';
    var d = new Date(iso);
    return isNaN(d) ? '' : d.toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
  };
  var toast = function (msg, level) { if (typeof window.showToast === 'function') window.showToast(msg, level || 'info'); };
  var lastOfflineToast = 0;
  function offlineToast() {
    if (Date.now() - lastOfflineToast < 2500) return;
    lastOfflineToast = Date.now();
    toast("You're offline. This action needs an internet connection.", 'warning');
  }

  /* ------------------------------------------------------------------ IndexedDB queue */
  var hasDb = !!window.indexedDB;
  function db() {
    return new Promise(function (resolve, reject) {
      var req = indexedDB.open('ite-portal', 1);
      req.onupgradeneeded = function () { req.result.createObjectStore('queue', { keyPath: 'id', autoIncrement: true }); };
      req.onsuccess = function () { resolve(req.result); };
      req.onerror = function () { reject(req.error); };
    });
  }
  function run(mode, fn) {
    return db().then(function (d) {
      return new Promise(function (resolve, reject) {
        var t = d.transaction('queue', mode), result;
        result = fn(t.objectStore('queue'));
        t.oncomplete = function () { resolve(result && 'result' in result ? result.result : undefined); d.close(); };
        t.onerror = t.onabort = function () { reject(t.error); d.close(); };
      });
    });
  }
  var qAll = function () { return hasDb ? run('readonly', function (s) { return s.getAll(); }).then(function (r) { return r || []; }) : Promise.resolve([]); };
  var qAdd = function (e) { return run('readwrite', function (s) { return s.add(e); }); };
  var qPut = function (e) { return run('readwrite', function (s) { return s.put(e); }); };
  var qDel = function (id) { return run('readwrite', function (s) { return s.delete(id); }); };
  function loadQueue() {
    return qAll().then(function (all) {
      state.queue = all.filter(function (e) { return String(e.user) === String(USER); }).sort(function (a, b) { return a.id - b.id; });
      render(); applyPending();
    }).catch(function () { state.queue = []; render(); });
  }
  var pending = function () { return state.queue.filter(function (e) { return e.status === 'pending'; }); };
  var failed = function () { return state.queue.filter(function (e) { return e.status === 'failed'; }); };

  /* ------------------------------------------------------------------ connectivity */
  function ping() {
    var ctl = new AbortController(), t = setTimeout(function () { ctl.abort(); }, 4000);
    return fetch('/healthz/?_=' + Date.now(), { cache: 'no-store', signal: ctl.signal })
      .then(function (r) { clearTimeout(t); return r.ok; }).catch(function () { clearTimeout(t); return false; });
  }
  function setOnline(v) {
    if (state.online === v) return;
    state.online = v;
    root.classList.toggle('is-offline', !v);
    render();
    if (v) { flush(); maybePrefetch(false); }
  }
  window.addEventListener('offline', function () { setOnline(false); });
  window.addEventListener('online', function () { ping().then(setOnline); });
  setInterval(function () { if (!state.online || pending().length) ping().then(setOnline); }, 15000);
  root.classList.toggle('is-offline', !state.online);

  /* ------------------------------------------------------------------ queueing offline changes */
  function matchQueueable(path) {
    for (var i = 0; i < QUEUEABLE.length; i++) if (QUEUEABLE[i].re.test(path)) return QUEUEABLE[i];
    return null;
  }
  function rowText(el) {
    var tr = el && el.closest && el.closest('tr');
    var td = tr && tr.querySelector('td');
    return td ? td.textContent.replace(/\s+/g, ' ').trim() : '';
  }
  function whoText() {
    var h = document.querySelector('#fines-page h5');
    return h ? h.textContent.replace(/\s+/g, ' ').trim() : '';
  }
  function labelFor(kind, params, el) {
    var who = whoText(), slot = (params.date || '') + ' ' + (SLOT_NAMES[params.slot] || params.slot || '');
    if (kind === 'pay-slot') return 'Paid ' + slot.trim() + (who ? ' · ' + who : '');
    if (kind === 'unpay-slot') return 'Undo payment ' + slot.trim() + (who ? ' · ' + who : '');
    if (kind === 'mark-paid') return 'Paid the remaining balance' + (who ? ' · ' + who : '');
    if (kind === 'toggle-active') return (params.value === 'on' ? 'Turn ON ' : 'Turn OFF ') + 'event ' + rowText(el);
    if (kind === 'activate') return 'Set active semester ' + rowText(el);
    return kind;
  }
  function canonical(json) {
    try { var o = JSON.parse(json || 'null'); return o ? JSON.stringify(Object.keys(o).sort().map(function (k) { return [k, o[k]]; })) : ''; } catch (e) { return ''; }
  }
  function findTrigger(entry) {
    var want = canonical(entry.vals), found = null;
    document.querySelectorAll('[hx-post]').forEach(function (el) {
      if (!found && el.getAttribute('hx-post') === entry.path && canonical(el.getAttribute('hx-vals')) === want && !el.dataset.pending) found = el;
    });
    return found;
  }
  function badge(text) {
    var s = document.createElement('span');
    s.className = 'badge text-bg-warning pending-badge';
    s.title = 'Saved on this device - waiting to sync';
    s.textContent = text;
    return s;
  }
  function optimistic(entry, el) {
    el = el || findTrigger(entry);
    if (!el || el.dataset.pending) return;
    if (entry.kind === 'toggle-active') {
      // a cancelled checkbox click is reverted by the browser right after the handlers finish: set the state afterwards
      el.dataset.pending = '1';
      setTimeout(function () { el.checked = entry.params.value === 'on'; el.disabled = true; }, 0);
      var label = el.parentNode && el.parentNode.querySelector('span'); if (label) label.textContent = 'Pending sync';
    } else {
      var text = entry.kind === 'unpay-slot' ? 'Undo pending' : entry.kind === 'activate' ? 'Active · pending' : 'Paid · pending';
      el.replaceWith(badge(text));
    }
  }
  function applyPending() { pending().forEach(function (e) { optimistic(e, null); }); }

  function enqueue(q, cfg, el) {
    if (!hasDb) { offlineToast(); return; }
    var params = {};
    Object.keys(cfg.parameters || {}).forEach(function (k) { params[k] = cfg.parameters[k]; });
    if (q.kind === 'toggle-active') {
      var box = el && el.matches && el.matches('input[type=checkbox]') ? el : null;
      // the state the user asked for, recorded when the click happened (idempotent replay)
      params.value = (box && box.dataset.wantOn ? box.dataset.wantOn === '1' : true) ? 'on' : 'off';
    }
    var entry = {
      user: USER, kind: q.kind, path: cfg.path, params: params, vals: el && el.getAttribute ? el.getAttribute('hx-vals') : null,
      created: new Date().toISOString(), status: 'pending', message: '', label: labelFor(q.kind, params, el)
    };
    qAdd(entry).then(function (id) {
      entry.id = id; state.queue.push(entry); optimistic(entry, el); render();
      toast("Saved on this device. It will sync when you're back online.", 'info');
    }).catch(function () { toast('Could not save this change on the device.', 'danger'); });
  }

  document.body.addEventListener('htmx:beforeRequest', function (e) {
    var cfg = e.detail && e.detail.requestConfig;
    // While a click is being handled the browser has already flipped the checkbox: that IS the requested state
    // (afterwards the cancelled click is reverted, so it has to be remembered now).
    if (cfg && e.detail.elt && e.detail.elt.matches && e.detail.elt.matches('input[type=checkbox]')) e.detail.elt.dataset.wantOn = e.detail.elt.checked ? '1' : '0';
    if (!cfg || state.online) return;
    if ((cfg.verb || '').toLowerCase() === 'post') {
      e.preventDefault();
      var q = matchQueueable(cfg.path);
      if (q) enqueue(q, cfg, e.detail.elt); else offlineToast();
    }
  });
  document.body.addEventListener('htmx:sendError', function (e) {         // we looked online, but the request died
    var cfg = e.detail && e.detail.requestConfig;
    if (!cfg) return;
    ping().then(function (ok) {
      if (ok) return;                                                       // server reachable: a genuine one-off failure
      setOnline(false);
      if ((cfg.verb || '').toLowerCase() === 'post') { var q = matchQueueable(cfg.path); if (q) enqueue(q, cfg, e.detail.elt); else offlineToast(); }
      else offlineToast();
    });
  });
  document.body.addEventListener('htmx:responseError', function (e) {
    var xhr = e.detail && e.detail.xhr;
    if (xhr && xhr.getResponseHeader && xhr.getResponseHeader('x-offline') === '1') offlineToast();
  });
  document.body.addEventListener('htmx:afterRequest', function (e) {      // a saved copy was served instead of fresh data
    var xhr = e.detail && e.detail.xhr, at = xhr && xhr.getResponseHeader ? xhr.getResponseHeader('x-offline-copy') : null;
    if (at) { state.copyAt = at; render(); ping().then(setOnline); }       // a saved copy usually means "no server": confirm
  });
  document.body.addEventListener('htmx:afterSwap', function () { applyPending(); markBlocked(); });

  // plain (non-htmx) forms and downloads cannot work offline either
  document.addEventListener('submit', function (e) {
    if (!state.online && String(e.target.method).toLowerCase() === 'post') { e.preventDefault(); offlineToast(); }
  }, true);
  document.addEventListener('click', function (e) {
    var a = e.target.closest && e.target.closest('a[href]');
    if (!a) return;
    if (/\/portal\/logout\/?$/.test(a.getAttribute('href'))) { e.preventDefault(); logout(a.href); return; }
    if (!state.online && /[?&]format=/.test(a.getAttribute('href'))) { e.preventDefault(); offlineToast(); }
  }, true);

  function markBlocked() {
    document.querySelectorAll('[hx-post], [hx-get*="/add/"], [hx-get*="/edit/"], [hx-get*="/calculate/"], a[href*="format="], form[method="post"], form[method="POST"]').forEach(function (el) {
      var path = el.getAttribute('hx-post') || '';
      var ok = path && matchQueueable(path);
      el.classList.toggle('offline-blocked', !ok);
    });
  }

  /* ------------------------------------------------------------------ replay */
  function csrf() {
    var m = document.cookie.match(/(?:^|;\s*)csrftoken=([^;]+)/);
    if (m) return decodeURIComponent(m[1]);
    try { return JSON.parse(document.body.getAttribute('hx-headers') || '{}')['X-CSRFToken'] || ''; } catch (e) { return ''; }
  }
  function replayOne(entry, retried) {
    return fetch(entry.path, {
      method: 'POST', credentials: 'same-origin', redirect: 'manual',
      headers: {
        'X-CSRFToken': csrf(), 'HX-Request': 'true', 'X-Offline-Replay': '1', 'X-Offline-Time': entry.created,
        'Content-Type': 'application/x-www-form-urlencoded'
      },
      body: new URLSearchParams(entry.params).toString()
    }).then(function (r) {
      if (r.type === 'opaqueredirect' || r.status === 302 || r.status === 401) return 'auth';
      if (r.status === 403 && !retried) {                                  // stale CSRF token: get a fresh cookie and try once more
        return fetch('/portal/', { credentials: 'same-origin' }).then(function () { return replayOne(entry, true); });
      }
      if (r.status >= 400) {
        entry.status = 'failed';
        entry.message = r.status === 403 ? 'Not allowed (403).' : r.status === 404 ? 'That record no longer exists.' : 'The server refused it (' + r.status + ').';
        return qPut(entry).then(function () { return 'failed'; });
      }
      var level = '', message = '';
      try { var t = JSON.parse(r.headers.get('HX-Trigger') || '{}').showToast; if (t) { level = t.level; message = t.message; } } catch (e) { /* no toast */ }
      if (level === 'error') {
        entry.status = 'failed'; entry.message = message || 'The server could not apply this change.';
        return qPut(entry).then(function () { return 'failed'; });
      }
      return qDel(entry.id).then(function () { return 'done'; });
    }).catch(function () { return 'network'; });
  }
  function flush() {
    if (state.syncing || !state.online || !pending().length) return Promise.resolve();
    var work = function () {
      state.syncing = true; render();
      var items = pending().slice(), ok = 0, bad = 0, authLost = false, refresh = {};
      return items.reduce(function (chain, entry) {
        return chain.then(function (stop) {
          if (stop) return stop;
          return replayOne(entry).then(function (res) {
            if (res === 'auth') { authLost = true; return 'stop'; }
            if (res === 'network') { setOnline(false); return 'stop'; }
            if (res === 'done') { ok++; var q = matchQueueable(entry.path); if (q) refresh[q.refresh] = true; } else bad++;
            return null;
          });
        });
      }, Promise.resolve(null)).then(function () {
        state.syncing = false;
        return loadQueue().then(function () {
          if (authLost) toast('Your session expired. Sign in again to sync your changes - they are safe on this device.', 'warning');
          else if (ok || bad) toast((ok ? 'Synced ' + ok + ' change' + (ok > 1 ? 's' : '') + '.' : '') + (bad ? ' ' + bad + ' need attention.' : ''), bad ? 'warning' : 'success');
          Object.keys(refresh).forEach(function (ev) { if (window.htmx) window.htmx.trigger(document.body, ev); });
          if (ok) maybePrefetch(true);                                       // refresh the saved copies with the new numbers
        });
      });
    };
    return navigator.locks ? navigator.locks.request('ite-sync', work) : work();
  }

  /* ------------------------------------------------------------------ offline copies of pages */
  function maybePrefetch(force) {
    if (!state.online || !('serviceWorker' in navigator) || !navigator.serviceWorker.controller) return;
    var last = parseInt(store.get('portal.offline.at') || '0', 10);
    if (!force && Date.now() - last < PREFETCH_EVERY_MS && store.get('portal.offline.user') === String(USER)) return;
    if (state.prefetching) return;
    state.prefetching = { done: 0, total: 0 };
    render();
    fetch('/portal/offline/manifest/', { credentials: 'same-origin', cache: 'no-store' })
      .then(function (r) { return r.json(); })
      .then(function (m) { state.prefetching.total = m.urls.length; navigator.serviceWorker.controller.postMessage({ type: 'prefetch', urls: m.urls }); })
      .catch(function () { state.prefetching = null; render(); });
  }
  function warmAssets() {
    if (!navigator.serviceWorker.controller || sessionStorage.getItem('portal.warmed')) return;
    var urls = performance.getEntriesByType('resource').map(function (r) { return r.name; }).filter(function (n) {
      return /^https?:/.test(n) && n.indexOf('/portal/') === -1 && n.indexOf('/healthz') === -1 && n.indexOf('/admin/') === -1;
    });
    try { sessionStorage.setItem('portal.warmed', '1'); } catch (e) { /* ignore */ }
    navigator.serviceWorker.controller.postMessage({ type: 'warm-assets', urls: urls });
  }
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.addEventListener('message', function (e) {
      var d = e.data || {};
      if (d.type === 'prefetch-progress' && state.prefetching) { state.prefetching.done = d.done; state.prefetching.total = d.total; render(); }
      if (d.type === 'prefetch-done') {
        state.prefetching = null;
        if (d.authLost) toast('Sign in again to save pages for offline use.', 'warning');
        else {
          store.set('portal.offline.at', String(Date.now())); store.set('portal.offline.user', String(USER)); store.set('portal.offline.count', String(d.saved));
          if (state.manualPrefetch) { toast('Saved ' + d.saved + ' pages for offline use.', 'success'); state.manualPrefetch = false; }
        }
        render();
      }
    });
    navigator.serviceWorker.ready.then(function () {
      warmAssets();
      setTimeout(function () { maybePrefetch(false); }, 2500);
    });
    navigator.serviceWorker.addEventListener('controllerchange', function () { setTimeout(function () { warmAssets(); maybePrefetch(false); }, 1500); });
  }

  // a different person signed in on this device: their saved pages must not be visible to the next user
  var prevUser = store.get('portal.user');
  if (prevUser && prevUser !== String(USER) && 'serviceWorker' in navigator && navigator.serviceWorker.controller) {
    navigator.serviceWorker.controller.postMessage({ type: 'clear-pages' });
    store.del('portal.offline.at'); store.del('portal.offline.count');
  }
  store.set('portal.user', String(USER));

  function clearSavedPages() {
    store.del('portal.offline.at'); store.del('portal.offline.count');
    if ('serviceWorker' in navigator && navigator.serviceWorker.controller) navigator.serviceWorker.controller.postMessage({ type: 'clear-pages' });
  }
  function logout(href) {
    var n = pending().length;
    if (!state.online) { toast(n ? 'You have ' + n + ' unsynced change' + (n > 1 ? 's' : '') + ' and no connection. Sign out after they sync.' : 'Signing out needs an internet connection. You stay signed in so you can keep working.', 'warning'); return; }
    var go = function () { clearSavedPages(); setTimeout(function () { window.location.href = href; }, 150); };
    flush().then(function () {
      var left = pending().length + failed().length;
      if (left && !window.confirm(left + ' change' + (left > 1 ? 's have' : ' has') + " not synced yet. They stay on this device and sync the next time you sign in. Sign out anyway?")) return;
      go();
    });
  }

  /* ------------------------------------------------------------------ UI */
  function render() {
    var chip = $('syncChip'), banner = $('offlineBanner');
    var p = pending().length, f = failed().length;
    if (chip) {
      var cls = '', text = '', icon = 'bi-cloud-check';
      if (!state.online) { cls = 'is-offline'; text = p ? 'Offline · ' + p : 'Offline'; icon = 'bi-wifi-off'; }
      else if (state.syncing) { cls = 'is-syncing'; text = 'Syncing…'; icon = 'bi-arrow-repeat'; }
      else if (f) { cls = 'is-failed'; text = f + ' need' + (f > 1 ? '' : 's') + ' attention'; icon = 'bi-exclamation-triangle'; }
      else if (p) { cls = 'is-pending'; text = p + ' pending'; icon = 'bi-cloud-upload'; }
      chip.hidden = !cls;
      chip.className = 'sync-chip ' + cls;
      chip.innerHTML = '<i class="bi ' + icon + '"></i><span></span>';
      chip.lastChild.textContent = text;
    }
    if (banner) {
      var show = !state.online || !!state.copyAt;
      banner.hidden = !show || banner.dataset.dismissed === '1';
      if (show) {
        banner.querySelector('.msg').textContent = !state.online
          ? "You're offline." + (state.copyAt ? ' Showing a saved copy from ' + fmt(state.copyAt) + '.' : '') + ' Payments and switches are saved on this device and sync later.'
          : "You're back online. This page is a saved copy from " + fmt(state.copyAt) + '.';
        banner.querySelector('[data-reload]').hidden = !state.online;      // offer the fresh version once we can get it
      }
    }
    renderDialog();
    markBlocked();
  }

  function renderDialog() {
    var dlg = $('syncDialog');
    if (!dlg || !dlg.classList.contains('show')) return;
    var status = dlg.querySelector('[data-sync-status]'), list = dlg.querySelector('[data-sync-list]');
    var p = pending().length, f = failed().length;
    status.textContent = !state.online ? "Offline. Changes are saved on this device." : state.syncing ? 'Syncing…' : (p || f) ? 'Online.' : 'Everything is synced.';
    list.innerHTML = '';
    if (!state.queue.length) {
      var empty = document.createElement('li'); empty.className = 'list-group-item text-muted'; empty.textContent = 'No changes waiting.'; list.appendChild(empty);
    }
    state.queue.forEach(function (e) {
      var li = document.createElement('li');
      li.className = 'list-group-item d-flex flex-column gap-1' + (e.status === 'failed' ? ' list-group-item-danger' : '');
      var top = document.createElement('div'); top.className = 'fw-semibold'; top.textContent = e.label; li.appendChild(top);
      var sub = document.createElement('div'); sub.className = 'small text-muted';
      sub.textContent = 'Made ' + fmt(e.created) + (e.status === 'failed' ? ' — ' + e.message : ' — waiting to sync'); li.appendChild(sub);
      if (e.status === 'failed') {
        var row = document.createElement('div'); row.className = 'd-flex gap-2 mt-1';
        var retry = document.createElement('button'); retry.type = 'button'; retry.className = 'btn btn-sm btn-outline-primary'; retry.textContent = 'Retry';
        retry.onclick = function () { e.status = 'pending'; e.message = ''; qPut(e).then(loadQueue).then(flush); };
        var drop = document.createElement('button'); drop.type = 'button'; drop.className = 'btn btn-sm btn-outline-danger'; drop.textContent = 'Discard';
        drop.onclick = function () { qDel(e.id).then(loadQueue); };
        row.appendChild(retry); row.appendChild(drop); li.appendChild(row);
      }
      list.appendChild(li);
    });
    var saved = dlg.querySelector('[data-saved-info]'), at = parseInt(store.get('portal.offline.at') || '0', 10);
    saved.textContent = state.prefetching ? 'Saving pages… ' + state.prefetching.done + '/' + (state.prefetching.total || '?')
      : at ? (store.get('portal.offline.count') || '0') + ' pages saved for offline use · updated ' + fmt(new Date(at).toISOString()) : 'No pages saved for offline use yet.';
    dlg.querySelector('[data-sync-now]').disabled = !state.online || state.syncing || !pending().length;
    dlg.querySelector('[data-refresh-offline]').disabled = !state.online || !!state.prefetching;
  }

  function wireUi() {
    var chip = $('syncChip'), dlg = $('syncDialog'), banner = $('offlineBanner');
    if (chip && dlg && window.bootstrap) {
      chip.addEventListener('click', function () { window.bootstrap.Modal.getOrCreateInstance(dlg).show(); });
      dlg.addEventListener('shown.bs.modal', renderDialog);
      dlg.querySelector('[data-sync-now]').addEventListener('click', function () { flush(); });
      dlg.querySelector('[data-refresh-offline]').addEventListener('click', function () { state.manualPrefetch = true; maybePrefetch(true); });
    }
    if (banner) {
      banner.querySelector('[data-dismiss]').addEventListener('click', function () { banner.dataset.dismissed = '1'; banner.hidden = true; });
      banner.querySelector('[data-reload]').addEventListener('click', function () { window.location.reload(); });
    }
    var more = document.querySelector('[data-open-sync]');
    if (more && dlg && window.bootstrap) more.addEventListener('click', function () { window.bootstrap.Modal.getOrCreateInstance(dlg).show(); });
  }

  window.ITE_OFFLINE = { state: state, flush: flush, loadQueue: loadQueue, ping: ping, render: render };
  // the dialog / banner markup sits after this script in the page: wire them once the DOM is complete
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', wireUi); else wireUi();
  markBlocked();
  if (state.copyAt) ping().then(setOnline);                                  // this page itself is a saved copy
  loadQueue().then(function () { if (state.online) flush(); });
})();
