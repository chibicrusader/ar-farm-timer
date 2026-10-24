// PWA glue for AR Farm Timer (plain JS, called from Dart via
// dart:js_interop as `window.arPwa`). Keep the permission / share / file
// picker calls synchronous at the start of each function: iOS Safari only
// allows them inside the user's tap.
(function () {
  'use strict';
  let registration = null;
  let updateReady = false;
  const updateListeners = [];

  function setUpdateReady() {
    if (updateReady) return;
    updateReady = true;
    updateListeners.forEach(function (fn) { try { fn(); } catch (e) { console.warn(e); } });
  }

  function isStandalone() {
    return window.navigator.standalone === true ||
      (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches) ||
      (window.matchMedia && window.matchMedia('(display-mode: fullscreen)').matches);
  }

  function isIos() {
    const ua = navigator.userAgent || '';
    return /iPad|iPhone|iPod/.test(ua) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  }

  function urlB64ToUint8Array(b64) {
    const padding = '='.repeat((4 - (b64.length % 4)) % 4);
    const raw = atob((b64 + padding).replace(/-/g, '+').replace(/_/g, '/'));
    const out = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
    return out;
  }

  function pushSupported() {
    return 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
  }

  if ('serviceWorker' in navigator) {
    window.addEventListener('load', function () {
      navigator.serviceWorker.register('sw.js').then(function (reg) {
        registration = reg;
        if (reg.waiting && navigator.serviceWorker.controller) setUpdateReady();
        reg.addEventListener('updatefound', function () {
          const sw = reg.installing;
          if (!sw) return;
          sw.addEventListener('statechange', function () {
            if (sw.state === 'installed' && navigator.serviceWorker.controller) setUpdateReady();
          });
        });
        // Check for a new version whenever the app comes back to the foreground.
        document.addEventListener('visibilitychange', function () {
          if (document.visibilityState === 'visible') reg.update().catch(function () {});
        });
      }).catch(function (e) { console.warn('Service worker registration failed', e); });
      let reloading = false;
      navigator.serviceWorker.addEventListener('controllerchange', function () {
        if (reloading || !updateReady) return;
        reloading = true;
        window.location.reload();
      });
    });
  }


  // Hosts openUrl may navigate to (plus the page's own origin, and
  // window.arMoved when the moved notice is showing). Privacy lives on
  // artimer.win; transfer links go there too. mailto: is handled separately.
  const APP_OPEN_HOSTS = {
    'artimer.win': true,
    'www.artimer.win': true,
    'archerage-farm-timer.pages.dev': true,
  };

  function isAllowedOpenUrl(parsed) {
    if (parsed.protocol === 'mailto:') return true;
    if (parsed.username || parsed.password) return false;
    const local = parsed.hostname === 'localhost' || parsed.hostname === '127.0.0.1';
    if (!(parsed.protocol === 'https:' || (parsed.protocol === 'http:' && local))) return false;
    try {
      if (parsed.origin === new URL(document.baseURI).origin) return true;
    } catch { /* ignore */ }
    if (window.arMoved) {
      try {
        if (parsed.origin === new URL(window.arMoved).origin) return true;
      } catch { /* ignore */ }
    }
    return !!APP_OPEN_HOSTS[parsed.hostname];
  }

  window.arPwa = {
    info: function () {
      return JSON.stringify({
        standalone: isStandalone(),
        ios: isIos(),
        android: /Android/i.test(navigator.userAgent || ''),
        pushSupported: pushSupported(),
        permission: ('Notification' in window) ? Notification.permission : 'unsupported',
        storageApi: !!(navigator.storage && navigator.storage.persist),
        appUrl: document.baseURI,
        movedTo: window.arMoved || null,
      });
    },

    // One-tap transfer payload from "#import=..." (see moved.js); returned once.
    takeImport: function () {
      const v = window.arImport || '';
      window.arImport = '';
      return v;
    },

    // "Continue here for now" on the old address: don't ask again this session.
    movedDismissed: function () {
      try { return sessionStorage.getItem('ar_moved_dismissed') === '1'; } catch { return false; }
    },
    dismissMoved: function () {
      try { sessionStorage.setItem('ar_moved_dismissed', '1'); } catch { /* ignore */ }
    },

    // Opens the new address / privacy page / mailto. An installed app
    // (standalone) opens it in the browser; a browser tab navigates there.
    openUrl: function (url) {
      // Only the app's own origins (and mailto:). Never javascript:, data:,
      // or arbitrary http(s) sites — callers are moved/privacy screens with
      // app-controlled URLs, but tighten anyway in case of a future bug/XSS.
      let parsed;
      try { parsed = new URL(url, document.baseURI); } catch { return; }
      if (!isAllowedOpenUrl(parsed)) return;
      url = parsed.href;
      if (isStandalone()) {
        const w = window.open(url, '_blank', 'noopener');
        if (w) return;
      }
      window.location.assign(url);
    },

    persisted: function () {
      if (!(navigator.storage && navigator.storage.persisted)) return Promise.resolve('unsupported');
      return navigator.storage.persisted().then(function (p) { return p ? 'granted' : 'not-granted'; });
    },

    requestPersist: function () {
      if (!(navigator.storage && navigator.storage.persist)) return Promise.resolve('unsupported');
      return navigator.storage.persist().then(function (p) { return p ? 'granted' : 'not-granted'; })
        .catch(function () { return 'not-granted'; });
    },

    // Must be called directly from a tap. Resolves to the subscription JSON.
    enablePush: function (vapidPublicKey) {
      if (!pushSupported()) return Promise.reject(new Error('Push is not supported here. On iPhone, open the app from the Home Screen (iOS 16.4+).'));
      const permission = Notification.requestPermission(); // synchronous call inside the gesture
      return Promise.resolve(permission).then(function (result) {
        if (result !== 'granted') throw new Error('Notification permission was ' + result + '.');
        return navigator.serviceWorker.ready;
      }).then(function (reg) {
        return reg.pushManager.getSubscription().then(function (existing) {
          if (existing) return existing;
          return reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: urlB64ToUint8Array(vapidPublicKey) });
        });
      }).then(function (sub) { return JSON.stringify(sub.toJSON()); });
    },

    currentSubscription: function () {
      if (!pushSupported()) return Promise.resolve('');
      return navigator.serviceWorker.ready.then(function (reg) { return reg.pushManager.getSubscription(); })
        .then(function (sub) { return sub ? JSON.stringify(sub.toJSON()) : ''; });
    },

    disablePush: function () {
      if (!pushSupported()) return Promise.resolve(true);
      return navigator.serviceWorker.ready.then(function (reg) { return reg.pushManager.getSubscription(); })
        .then(function (sub) { return sub ? sub.unsubscribe() : true; });
    },

    // Share sheet (iOS: "Save to Files") when available, else a download.
    saveFile: function (name, text) {
      const blob = new Blob([text], { type: 'application/json' });
      try {
        const file = new File([blob], name, { type: 'application/json' });
        if (navigator.canShare && navigator.canShare({ files: [file] })) {
          return navigator.share({ files: [file], title: name }).then(function () { return 'shared'; })
            .catch(function (e) { if (e && e.name === 'AbortError') return 'cancelled'; return download(); });
        }
      } catch { /* fall through */ }
      return Promise.resolve(download());
      function download() {
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url; a.download = name; document.body.appendChild(a); a.click(); a.remove();
        setTimeout(function () { URL.revokeObjectURL(url); }, 10000);
        return 'downloaded';
      }
    },

    // Opens a file picker; resolves to the file text ('' if cancelled).
    pickTextFile: function () {
      return new Promise(function (resolve) {
        const input = document.createElement('input');
        input.type = 'file';
        input.accept = '.json,application/json,text/plain';
        input.style.display = 'none';
        input.addEventListener('change', function () {
          const f = input.files && input.files[0];
          input.remove();
          if (!f) { resolve(''); return; }
          f.text().then(resolve, function () { resolve(''); });
        });
        input.addEventListener('cancel', function () { input.remove(); resolve(''); });
        document.body.appendChild(input);
        input.click();
      });
    },

    isUpdateReady: function () { return updateReady; },
    onUpdateReady: function (fn) { updateListeners.push(fn); if (updateReady) fn(); },
    applyUpdate: function () {
      if (registration && registration.waiting) registration.waiting.postMessage({ type: 'SKIP_WAITING' });
      else window.location.reload();
    },
  };
})();
