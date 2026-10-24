// Domain move: https://archerage-farm-timer.pages.dev -> https://artimer.win.
// Runs before Flutter (and before pwa.js) boots. Plain ES5, no dependencies.
//  - www.artimer.win: redirect to artimer.win (same path/query/hash).
//  - pages.dev with no saved app data: redirect immediately.
//  - pages.dev WITH saved timers/farms/alerts: keep the app here and let it
//    show the "moved" notice (window.arMoved), so nobody's timers are stranded.
//  - "#import=<base64url backup>" (one-tap transfer from the old address) is
//    taken out of the URL at once and kept in memory for the app (arImport).
(function () {
  'use strict';
  var NEW_ORIGIN = 'https://artimer.win';
  var OLD_HOSTS = ['archerage-farm-timer.pages.dev']; // preview deploys (*.archerage-farm-timer.pages.dev) stay
  var host = location.hostname;
  var rest = location.pathname + location.search + location.hash;

  if (host === 'www.artimer.win') {
    location.replace(NEW_ORIGIN + rest);
    return;
  }

  var m = /^#import=([A-Za-z0-9_-]+={0,2})$/.exec(location.hash || '');
  // The app parses and validates it (BackupService.decodeTransfer) and asks
  // before importing; this only bounds its size.
  if (m && m[1].length <= 64000) {
    window.arImport = m[1];
    try { history.replaceState(null, '', location.pathname + location.search); } catch { /* ignore */ }
  }

  if (OLD_HOSTS.indexOf(host) < 0) return;

  // Keys written by the app (shared_preferences on web: plain keys, JSON values).
  var DATA_KEYS = ['farm_timers_v1', 'farms_v1', 'push_subscription_id'];
  function hasData(key) {
    var v;
    try { v = localStorage.getItem(key) || localStorage.getItem('flutter.' + key); } catch { return false; }
    if (v == null) return false;
    var s = v;
    try { s = JSON.parse(v); } catch { /* raw value */ }
    if (s == null) return false;
    if (typeof s === 'string') {
      var t = s.trim();
      if (t === '' || t === '[]' || t === '{}' || t === 'null') return false;
      try { var inner = JSON.parse(t); if (Array.isArray(inner) && inner.length === 0) return false; } catch { /* not JSON */ }
      return true;
    }
    return !(Array.isArray(s) && s.length === 0);
  }
  var saved = DATA_KEYS.some(hasData);
  if (!saved) {
    location.replace(NEW_ORIGIN + location.pathname + location.search);
    return;
  }
  window.arMoved = NEW_ORIGIN + '/';
})();
