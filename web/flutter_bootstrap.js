{{flutter_js}}
{{flutter_build_config}}

// Flutter's own service worker is deprecated (and self-unregistering), so it
// is NOT loaded here. Offline caching is done by our sw.js (see pwa.js).
// Fallback fonts (emoji, CJK, symbols, ...) and Roboto come from this site,
// not fonts.gstatic.com: no visitor IP goes to Google. web/fonts/fallback
// mirrors gstatic's paths (tool/fetch_fallback_fonts.py). The engine reads
// the config given to initializeEngine(), so it is passed there too.
const arEngineConfig = {
  fontFallbackBaseUrl: new URL('fonts/fallback/', document.baseURI).href,
};
_flutter.loader.load({
  config: arEngineConfig,
  onEntrypointLoaded: async function (engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine(arEngineConfig);
    // First launch: the app starts only after Agree on the "Before you use"
    // notice (web/consent.js). The engine is already loaded meanwhile.
    // Fail closed: without the notice script the app does not start.
    if (!window.arConsent || !window.arConsent.ready) {
      arShowLoadError();
      return;
    }
    await window.arConsent.ready;
    await appRunner.runApp();
  },
});
// Shown instead of the app when part of it (web/consent.js) didn't load.
function arShowLoadError() {
  const box = document.getElementById('ar-loading') || document.body;
  const bar = box.querySelector && box.querySelector('.bar');
  if (bar) bar.remove();
  const msg = document.createElement('div');
  msg.id = 'ar-load-error';
  msg.setAttribute('role', 'alert');
  msg.style.cssText = 'max-width:280px;text-align:center;letter-spacing:0;font-weight:400;line-height:1.4;color:#E8E2D4';
  msg.textContent = "Part of the app didn't load. Check your connection, then reload.";
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.textContent = 'Reload';
  btn.style.cssText = 'font:600 15px -apple-system,system-ui,sans-serif;padding:10px 22px;border:0;border-radius:8px;background:#C9A45C;color:#12161C';
  btn.addEventListener('click', function () { window.location.reload(); });
  box.appendChild(msg);
  box.appendChild(btn);
}
window.addEventListener('flutter-first-frame', function () {
  const el = document.getElementById('ar-loading');
  if (el) { el.style.opacity = '0'; setTimeout(function () { el.remove(); }, 350); }
});
