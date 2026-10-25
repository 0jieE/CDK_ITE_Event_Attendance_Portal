/* ITE Attendance portal - mobile behaviour (progressive enhancement; the portal works without it).
 *
 *  - Drawer: edge-swipe to open, drag to close, focus trap, inert page behind, focus returns to the button
 *  - Bottom navigation: "More" opens the drawer; the bar + top bar hide on scroll down, return on scroll up
 *  - Tables: every cell gets data-label so the CSS can stack rows into cards on phones
 *  - Filters: long filter forms collapse behind a "Filters (n)" button on phones
 */
(function () {
  'use strict';

  var root = document.documentElement;
  var phone = window.matchMedia('(max-width: 767.98px)');
  var drawerMode = window.matchMedia('(max-width: 991.98px)');
  var sidebar = document.getElementById('sidebar');
  var toggle = document.getElementById('sidebarToggle');
  var backdrop = document.getElementById('sidebarBackdrop');

  function isOpen() { return root.hasAttribute('data-sidebar-open'); }
  function setOpen(open) {
    if (open) root.setAttribute('data-sidebar-open', ''); else root.removeAttribute('data-sidebar-open');
    if (toggle) toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
  }

  /* ------------------------------------------------------------------ 1. Drawer */
  if (sidebar && backdrop) {
    var FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]), select, textarea, [tabindex]:not([tabindex="-1"])';
    var pageEls = function () { return [document.querySelector('.content'), document.querySelector('.bottom-nav')].filter(Boolean); };

    // react to every open/close (button, backdrop, Escape, gesture): inert page, dialog semantics, focus
    new MutationObserver(function () {
      var open = isOpen() && drawerMode.matches;
      pageEls().forEach(function (el) { if (open) el.setAttribute('inert', ''); else el.removeAttribute('inert'); });
      if (drawerMode.matches) {
        sidebar.setAttribute('role', open ? 'dialog' : 'navigation');
        if (open) sidebar.setAttribute('aria-modal', 'true'); else sidebar.removeAttribute('aria-modal');
      }
      if (open) {
        var first = sidebar.querySelector('.nav-link.active') || sidebar.querySelector(FOCUSABLE);
        if (first) setTimeout(function () { first.focus({ preventScroll: true }); }, 60);
      } else if (document.activeElement && sidebar.contains(document.activeElement)) {
        (toggle || document.body).focus({ preventScroll: true });
      }
    }).observe(root, { attributes: true, attributeFilter: ['data-sidebar-open'] });

    // keep Tab inside the open drawer
    document.addEventListener('keydown', function (e) {
      if (e.key !== 'Tab' || !isOpen() || !drawerMode.matches) return;
      var items = Array.prototype.filter.call(sidebar.querySelectorAll(FOCUSABLE), function (el) { return el.offsetParent !== null; });
      if (!items.length) return;
      var first = items[0], last = items[items.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    });

    var closeBtn = sidebar.querySelector('.drawer-close');
    if (closeBtn) closeBtn.addEventListener('click', function () { setOpen(false); });

    // ---- swipe: open from the left edge, close by dragging the drawer / backdrop to the left
    var g = null;            // gesture state
    var EDGE = 22;           // px from the left edge that starts an "open" swipe
    function width() { return sidebar.getBoundingClientRect().width || 280; }
    function reset() {
      sidebar.classList.remove('is-dragging');
      sidebar.style.transform = '';
      backdrop.style.opacity = ''; backdrop.style.visibility = '';
    }
    document.addEventListener('touchstart', function (e) {
      if (!drawerMode.matches || e.touches.length !== 1) { g = null; return; }
      var t = e.touches[0];
      var open = isOpen();
      var inDrawer = open && (sidebar.contains(e.target) || e.target === backdrop);
      if (!open && t.clientX <= EDGE) g = { mode: 'open', x: t.clientX, y: t.clientY, t0: Date.now(), locked: false };
      else if (inDrawer) g = { mode: 'close', x: t.clientX, y: t.clientY, t0: Date.now(), locked: false };
      else g = null;
    }, { passive: true });
    document.addEventListener('touchmove', function (e) {
      if (!g) return;
      var t = e.touches[0], dx = t.clientX - g.x, dy = t.clientY - g.y, w = width();
      if (!g.locked) {
        if (Math.abs(dx) < 8 && Math.abs(dy) < 8) return;
        if (Math.abs(dy) > Math.abs(dx)) { g = null; return; }               // vertical scroll wins
        if ((g.mode === 'open' && dx <= 0) || (g.mode === 'close' && dx >= 0)) { g = null; return; }
        g.locked = true; sidebar.classList.add('is-dragging');
      }
      var x = g.mode === 'open' ? Math.min(0, -w + dx) : Math.max(-w, Math.min(0, dx));
      sidebar.style.transform = 'translateX(' + x + 'px)';
      backdrop.style.visibility = 'visible';
      backdrop.style.opacity = String(Math.max(0, Math.min(1, 1 + x / w)));
      g.dx = dx;
    }, { passive: true });
    function endGesture() {
      if (!g) return;
      var s = g; g = null;
      if (!s.locked) return;
      var w = width(), dt = Math.max(1, Date.now() - s.t0), v = Math.abs(s.dx) / dt;   // px per ms
      var commit = Math.abs(s.dx) > w * 0.33 || v > 0.45;
      reset();
      if (s.mode === 'open') setOpen(commit); else setOpen(!commit);
    }
    document.addEventListener('touchend', endGesture, { passive: true });
    document.addEventListener('touchcancel', function () { if (g && g.locked) reset(); g = null; }, { passive: true });
  }

  /* ------------------------------------------------- 2. Bottom bar + hide on scroll */
  var more = document.getElementById('bottomMore');
  if (more && toggle) more.addEventListener('click', function () { setOpen(true); });

  var lastY = window.scrollY, ticking = false;
  function onScroll() {
    ticking = false;
    var y = window.scrollY, d = y - lastY;
    if (!phone.matches || isOpen() || document.body.classList.contains('modal-open')) { root.classList.remove('chrome-hidden'); lastY = y; return; }
    var typing = document.activeElement && /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName);
    var atBottom = window.innerHeight + y >= document.documentElement.scrollHeight - 4;
    if (y < 70 || atBottom || typing) { root.classList.remove('chrome-hidden'); lastY = y; return; }
    if (Math.abs(d) < 8) return;                                              // ignore jitter
    root.classList.toggle('chrome-hidden', d > 0);
    lastY = y;
  }
  window.addEventListener('scroll', function () { if (!ticking) { ticking = true; requestAnimationFrame(onScroll); } }, { passive: true });
  phone.addEventListener('change', function () { root.classList.remove('chrome-hidden'); });

  /* ----------------------------------------------------------- 3a. Table labels */
  window.labelTables = function (scope) {
    (scope || document).querySelectorAll('table.table:not(.no-stack)').forEach(function (table) {
      var headRow = table.querySelector('thead tr:last-child');
      var labels = headRow ? Array.prototype.map.call(headRow.children, function (th) { return th.textContent.replace(/\s+/g, ' ').trim(); }) : [];
      table.querySelectorAll('tbody tr, tfoot tr').forEach(function (tr) {
        var col = 0;
        Array.prototype.forEach.call(tr.children, function (cell, i) {
          var span = parseInt(cell.getAttribute('colspan') || '1', 10);
          if (!cell.hasAttribute('data-label')) cell.setAttribute('data-label', span > 1 ? '' : (labels[col] || ''));
          var text = cell.textContent.replace(/\s+/g, '').trim();
          var bare = cell.children.length === 0 || !cell.querySelector('button, a, input, .badge, img, svg');
          // nothing to show ("–", "—", blank): hide the row in card mode (not the card title)
          cell.classList.toggle('is-empty', i > 0 && span === 1 && bare && (text === '' || text === '–' || text === '—' || text === '-'));
          col += span;
        });
      });
    });
  };

  /* --------------------------------------------------------------- 3b. Filters */
  var filtersOpen = false;
  function activeCount(form) {
    var n = 0;
    form.querySelectorAll('select[name], input[name]:not([type=hidden])').forEach(function (el) {
      if ((el.value || '') !== '') n++;
    });
    return n;
  }
  window.enhanceFilters = function (scope) {
    (scope || document).querySelectorAll('form.filters-form:not(.filters-collapsible)').forEach(function (form) {
      form.classList.add('filters-collapsible');
      var btn = document.createElement('button');
      btn.type = 'button'; btn.className = 'filters-toggle no-print';
      btn.setAttribute('aria-expanded', 'false');
      btn.innerHTML = '<span><i class="bi bi-funnel"></i> Filters <span class="count"></span></span><i class="bi bi-chevron-down"></i>';
      form.parentNode.insertBefore(btn, form);
      function paint() {
        var c = activeCount(form), badge = btn.querySelector('.count');
        badge.textContent = c; badge.style.display = c ? '' : 'none';
      }
      function open(v) {
        form.classList.toggle('is-open', v); btn.setAttribute('aria-expanded', v ? 'true' : 'false'); filtersOpen = v;
      }
      btn.addEventListener('click', function () { open(!form.classList.contains('is-open')); });
      form.addEventListener('change', paint);
      paint();
      if (filtersOpen) open(true);          // the page was just refreshed by a filter change: stay open
    });
  };

  /* --------------------------------------------------------------- wiring */
  function enhance(scope) { window.labelTables(scope); window.enhanceFilters(scope); }
  document.addEventListener('DOMContentLoaded', function () { enhance(document); });
  document.body && document.body.addEventListener('htmx:afterSwap', function () { enhance(document); });
  if (window.jQuery) window.jQuery(document).on('draw.dt init.dt', function () { window.labelTables(document); });
  window.addEventListener('pageshow', function () { setOpen(false); root.classList.remove('chrome-hidden'); });
})();
