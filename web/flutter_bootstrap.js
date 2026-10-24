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
    await appRunner.runApp();
  },
});
window.addEventListener('flutter-first-frame', function () {
  const el = document.getElementById('ar-loading');
  if (el) { el.style.opacity = '0'; setTimeout(function () { el.remove(); }, 350); }
});
