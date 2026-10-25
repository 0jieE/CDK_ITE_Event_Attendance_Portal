/* ITE Attendance portal - "Install app" support.
 *
 *  - registers the (cache-free) service worker so browsers consider the portal installable
 *  - Chrome / Edge / Android: the "Install app" buttons trigger the browser's native install prompt
 *  - iPhone / iPad / other browsers: the same buttons open a short how-to for that platform
 *  - buttons stay hidden once the portal runs as an installed app
 */
(function () {
  'use strict';

  /* ------------------------------------------------ service worker */
  var swUrl = (document.querySelector('meta[name="sw-url"]') || {}).content;
  var swScope = (document.querySelector('meta[name="sw-scope"]') || {}).content || '/portal/';
  if ('serviceWorker' in navigator && swUrl) {
    window.addEventListener('load', function () {
      navigator.serviceWorker.register(swUrl, { scope: swScope }).catch(function () { /* unsupported / blocked: install help still works */ });
    });
  }

  /* ------------------------------------------------ install buttons */
  var buttons = function () { return document.querySelectorAll('[data-install-app]'); };
  var deferred = null;

  function standalone() {
    return window.matchMedia('(display-mode: standalone)').matches ||
           window.matchMedia('(display-mode: minimal-ui)').matches ||
           window.navigator.standalone === true;
  }
  function platform() {
    var ua = navigator.userAgent || '';
    if (/iPad|iPhone|iPod/.test(ua) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)) return 'ios';
    if (/Android/.test(ua)) return 'android';
    return 'desktop';
  }
  function paint() {
    var show = !standalone();
    buttons().forEach(function (b) { b.hidden = !show; });
  }

  window.addEventListener('beforeinstallprompt', function (e) {
    e.preventDefault();             // keep the event so our own button can trigger it
    deferred = e;
    paint();
  });
  window.addEventListener('appinstalled', function () {
    deferred = null;
    buttons().forEach(function (b) { b.hidden = true; });
    if (typeof showToast === 'function') showToast('App installed. Open it from your home screen.', 'success');
  });

  function openHelp() {
    var modal = document.getElementById('installHelp');
    if (!modal || !window.bootstrap) return;
    var current = platform();
    modal.querySelectorAll('details[data-platform]').forEach(function (d) { d.open = d.getAttribute('data-platform') === current; });
    window.bootstrap.Modal.getOrCreateInstance(modal).show();
  }

  document.addEventListener('click', function (e) {
    var btn = e.target.closest('[data-install-app]');
    if (!btn) return;
    e.preventDefault();
    var drawer = document.getElementById('sidebarBackdrop');
    if (deferred) {
      var ev = deferred;
      ev.prompt();
      ev.userChoice.then(function (choice) {
        deferred = null;
        if (choice && choice.outcome === 'accepted') buttons().forEach(function (b) { b.hidden = true; });
      });
    } else {
      if (drawer && document.documentElement.hasAttribute('data-sidebar-open')) drawer.click();   // close the drawer first
      openHelp();
    }
  });

  window.matchMedia('(display-mode: standalone)').addEventListener('change', paint);
  document.addEventListener('DOMContentLoaded', paint);
})();
