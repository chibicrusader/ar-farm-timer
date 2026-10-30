// "Before you use" notice, shown once before the app starts (browser tab and
// installed Home Screen app). Plain ES5-style JS, no dependencies, loaded
// from web/index.html before flutter_bootstrap.js (the CSP forbids inline
// scripts). web/flutter_bootstrap.js waits for window.arConsent.ready before
// running the app, so nothing behind the notice can be used until Agree.
//
// Consent is kept ONLY in this browser's localStorage (key below). It is
// never sent to the push server and never stored as a cookie. Agree does
// not turn on push alerts (that stays the separate "Enable alerts" step) and
// nothing else (e.g. page statistics) waits for it.
//
// Settings -> Privacy -> "View the Before you use notice" calls
// window.arConsent.show() to show it again (review mode: Close / Esc).
(function () {
  'use strict';

  // ===================================================================
  // NOTICE WORDING: the ONLY place this text lives.
  // Version 2 (2026-10-29): Cloudflare bot-protection security cookie
  // sentence added to the body (Cloudflare Pro, Super Bot Fight Mode).
  // Version 1 agreements are asked again.
  // If the text changes what people agree to, bump
  // CONSENT_VERSION so everyone is asked again.
  // ===================================================================
  var CONSENT_VERSION = 2;
  var NOTICE = {
    heading: 'Before you use AR Farm Timer',
    body: "Your timers, farms, and settings are saved only on this device. If you turn on push alerts, " +
      "our server stores your browser's push subscription and the alerts you schedule, so Apple, Google, " +
      'or Mozilla can deliver them. The site is hosted on Cloudflare, which provides cookie-free page ' +
      'statistics and sets a short-lived security cookie to block automated traffic. We see only combined statistics, not who you are, and we never sell your data. By ' +
      "selecting Agree, you confirm you've read and accept the Privacy Notice.",
    privacyLink: 'Read the Privacy Notice',
    agree: 'Agree',
    close: 'Close', // review mode only (already agreed)
  };
  // Relative to <base href>; Cloudflare Pages serves the page at /privacy.
  var PRIVACY_HREF = 'privacy';
  // ===================================================================

  var STORAGE_KEY = 'privacyConsent';

  function readConsent() {
    try {
      var v = JSON.parse(localStorage.getItem(STORAGE_KEY) || 'null');
      return v && typeof v === 'object' ? v : null;
    } catch (e) { return null; }
  }

  function hasConsent() {
    var c = readConsent();
    return !!(c && c.version === CONSENT_VERSION && typeof c.agreedAt === 'string');
  }

  function saveConsent() {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify({ version: CONSENT_VERSION, agreedAt: new Date().toISOString() }));
    } catch (e) { /* storage blocked (e.g. private mode quota): asked again next launch */ }
  }

  var resolveReady;
  var ready = new Promise(function (resolve) { resolveReady = resolve; });
  var root = null;
  var lastFocus = null;
  var hidden = []; // siblings made inert while the notice is open

  function el(tag, attrs, text) {
    var e = document.createElement(tag);
    for (var k in attrs) if (Object.prototype.hasOwnProperty.call(attrs, k)) e.setAttribute(k, attrs[k]);
    if (text != null) e.textContent = text;
    return e;
  }

  function focusables() {
    return Array.prototype.slice.call(root.querySelectorAll('a[href], button:not([disabled])'));
  }

  function onKeyDown(ev) {
    if (!root) return;
    if (ev.key === 'Tab') {
      var f = focusables();
      if (!f.length) return;
      var first = f[0];
      var last = f[f.length - 1];
      var active = document.activeElement;
      var inside = root.contains(active);
      if (ev.shiftKey && (active === first || !inside)) { ev.preventDefault(); last.focus(); }
      else if (!ev.shiftKey && (active === last || !inside)) { ev.preventDefault(); first.focus(); }
    } else if (ev.key === 'Escape' && root.getAttribute('data-mode') === 'review') {
      ev.preventDefault();
      close();
    }
  }

  function onFocusIn(ev) {
    if (root && !root.contains(ev.target)) {
      var f = focusables();
      if (f.length) f[0].focus();
    }
  }

  function setBackgroundInert(on) {
    if (on) {
      hidden = [];
      Array.prototype.forEach.call(document.body.children, function (c) {
        if (c === root || c.tagName === 'SCRIPT') return;
        hidden.push([c, c.getAttribute('aria-hidden'), c.inert === true]);
        c.setAttribute('aria-hidden', 'true');
        c.inert = true;
      });
    } else {
      hidden.forEach(function (h) {
        if (h[1] == null) h[0].removeAttribute('aria-hidden'); else h[0].setAttribute('aria-hidden', h[1]);
        h[0].inert = h[2];
      });
      hidden = [];
    }
  }

  function build(review) {
    root = el('div', { id: 'ar-consent', 'data-mode': review ? 'review' : 'first' });
    var dialog = el('div', {
      class: 'ar-consent-dialog', role: 'dialog', 'aria-modal': 'true',
      'aria-labelledby': 'ar-consent-title', 'aria-describedby': 'ar-consent-body',
    });
    var h = el('h2', { id: 'ar-consent-title', tabindex: '-1' }, NOTICE.heading);
    var p = el('p', { id: 'ar-consent-body' }, NOTICE.body);
    var link = el('a', { class: 'ar-consent-link', href: PRIVACY_HREF, id: 'ar-consent-privacy' }, NOTICE.privacyLink);
    var btn = el('button', { type: 'button', class: 'ar-consent-agree', id: 'ar-consent-agree' },
      review ? NOTICE.close : NOTICE.agree);
    btn.addEventListener('click', function () {
      if (!review) saveConsent();
      close();
    });
    var actions = el('div', { class: 'ar-consent-actions' });
    actions.appendChild(btn);
    dialog.appendChild(h);
    dialog.appendChild(p);
    dialog.appendChild(link);
    dialog.appendChild(actions);
    root.appendChild(dialog);
    // Keep key presses inside the notice away from the app behind it
    // (bubble phase, so the link and button still get them first).
    root.addEventListener('keydown', function (ev) { ev.stopPropagation(); });
    return h;
  }

  function show(review) {
    if (root) return;
    lastFocus = document.activeElement;
    var h = build(!!review);
    document.body.appendChild(root);
    document.documentElement.classList.add('ar-consent-open');
    setBackgroundInert(true);
    document.addEventListener('keydown', onKeyDown, true);
    document.addEventListener('focusin', onFocusIn, true);
    // Screen readers start at the heading; Tab goes to the link, then Agree.
    h.focus();
  }

  function close() {
    if (!root) return;
    document.removeEventListener('keydown', onKeyDown, true);
    document.removeEventListener('focusin', onFocusIn, true);
    setBackgroundInert(false);
    root.remove();
    root = null;
    document.documentElement.classList.remove('ar-consent-open');
    if (lastFocus && lastFocus.focus && document.contains(lastFocus)) { try { lastFocus.focus(); } catch (e) { /* ignore */ } }
    lastFocus = null;
    resolveReady();
  }

  window.arConsent = {
    version: CONSENT_VERSION,
    ready: ready,
    hasConsent: hasConsent,
    // Settings -> Privacy: show the notice again (no new consent is recorded).
    show: function () { show(hasConsent()); },
  };

  // Not on the privacy page itself (it has no scripts anyway), and not while
  // moved.js is redirecting to the new address.
  if (window.arRedirecting || /\/privacy(\.html)?$/.test(location.pathname)) { resolveReady(); return; }
  if (hasConsent()) { resolveReady(); return; }
  if (document.body) show(false);
  else document.addEventListener('DOMContentLoaded', function () { show(false); });
})();
