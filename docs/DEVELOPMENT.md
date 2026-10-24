# AR Farm Timer

A cross-platform Flutter app (Android, iOS, Windows, macOS, Linux, web) for
tracking crops, trees, livestock and other farm items on **ArcheRage** (an
ArcheAge private server).

## Features

- **Catalog** of 288 items from `assets/farm_items.json`, grouped into
  Crops / Trees / Livestock / Other, with search (name, category,
  subcategory, climate). Raw data categories are folded in:
  - Crops: `crop`, `seed_bundle`, `greenhouse`, `mushroom`
  - Trees: `tree`, `fruit_tree`, `woodlot`
  - Livestock: `livestock`, `livestock_pen`
  - Other: `aquafarm`, `special`, anything unknown
  Items with `archerageConfirmed: false` get an **"unverified on ArcheRage"** badge.
- **Start a timer**: optional label (farm/plot), quantity, an optional
  "planted N minutes ago" offset, an optional custom grow time, and a
  **"preferred climate (~30% faster, unverified)"** toggle. The toggle only
  appears for items with a real climate (not `Any`, `None` or `Zone-locked: …`).
- **Watered / Farmhand** checkboxes. Both are off by default and saved with each timer, and each shows as a tag on the timer card:

  | Kind (how items are classified) | Watered | Farmhand |
  |---|---|---|
  | Single plant: `crop` and `mushroom` items, plus special-category items whose name contains "Seed" | −10% | +20% |
  | Bundle: `seed_bundle`, plus any `crop`, `mushroom` or special item whose name contains "Bundle" | −20% | +10% |
  | Sapling/tree: `tree`, `fruit_tree`, `woodlot`, plus special items named "Sapling" or "Tree" | −10% | no effect (shown disabled) |
  | Livestock: `livestock`, `livestock_pen`, Cornucopia Cow | hidden | no effect (shown disabled) |
  | Unknown: `greenhouse`, `aquafarm`, Experia patches | hidden | hidden |

  Watering values are official ArcheAge figures and are unverified on
  ArcheRage. Farmhand values are confirmed for ArcheRage (7.0 and 7.5 patch
  notes). Both come from `data/RESEARCH.md`. The research has nothing on
  greenhouses or aquafarm items, and aquafarm items can only be placed at
  Aquafarms or Marine Houses, so both checkboxes are hidden for those.
  Treating woodlots as saplings is my assumption.
- **How the modifiers combine:** all of them multiply, and they only affect
  the *first* growth. Repeat-harvest intervals are never changed.
  `first growth = growTimeMinutes × 0.7 (preferred climate) × 0.9|0.8 (watered) × 1.2|1.1|1.0 (farmhand)`.
  Example: a watered seed bundle in its preferred climate takes ×0.56.
  A custom grow time in the Advanced section replaces all of these.
  Watering comes off the base time, and growTimeMinutes is base × 0.5, so
  multiplying by 0.9 or 0.8 gives the same result. The start sheet shows
  the adjusted grow time and ready time.
- **Active timers** are sorted soonest-ready first and show live
  countdowns, a progress bar, and Growing / Ready / Withered states. When
  `witherOrDeathMinutes` is known, the card shows the wither deadline. Most
  items have no wither data, and those stay "Ready" until you act.
- **Harvest**: single-harvest items are removed. Repeating items restart
  using `harvestIntervalMinutes` (or the grow time if there is no interval)
  until `harvestCycles` runs out. `harvestCycles: null` with an interval
  means unlimited harvests, shown as `n/∞`.
- **Persistence**: timers are saved in `shared_preferences` as absolute UTC
  timestamps, so they survive restarts and timezone changes.
- **Notifications**:

  | Platform | Behaviour |
  |---|---|
  | Android, iOS, macOS | OS-scheduled local notification at ready time, which fires even if the app is closed |
  | Linux | Desktop notification (D-Bus) when a timer hits ready while the app is running. With no D-Bus session bus it falls back to in-app alerts. |
  | Windows, web | In-app alert (snackbar) while the app is open |

  An in-app alert also appears on every platform whenever the app is open.
- **Wither/death warning (v3)**: a second alert before the wither/death
  deadline. The lead time is set in Settings → Alerts (Off, 10m, 15m,
  **30m default**, 1h, 2h, 4h). It is capped at half the wither window, so a
  short window still gets its warning after "ready". The warning is only
  scheduled for timers with a known wither time: the 7 items with
  `witherOrDeathMinutes`, or a value you entered yourself in start sheet →
  Advanced → "Withers/dies N minutes after ready" (tagged *own wither
  time*). No wither data is invented. Native platforms get a second local
  notification (id `notificationId ^ 0x40000000`), the web gets a second
  push alert (`<id>:wither`), and Linux and in-app get the warning while
  running. Harvest and delete cancel both alerts, a repeat harvest
  reschedules both, and changing the lead time resyncs everything.
- **Zone picker (v3)**: the start sheet has a zone dropdown (41 zones, from
  `assets/zones.json`; sources in `data/RESEARCH.md`). The last zone used is
  remembered, and so is each farm's zone. Picking a zone sets the
  preferred-climate toggle when its climate matches the item's. Dual-climate
  Auroria zones count as both climates, and `Auroria` items match any
  Auroria zone. You can still flip the toggle yourself. Zones with an
  unknown climate leave the toggle alone, and zone-locked items warn when
  the zone is wrong.
- **Farms / plots (v3)**: the label is a reusable farm name. The start sheet
  shows chips for existing farms, or you can type a new one. The Timers
  list is **grouped by farm** by default. Each section collapses and shows
  `ready/total`, and the button in the top right switches to a flat
  soonest-first list. The farm menu has **Rename farm** (updates every timer
  and alert text) and **Delete farm** (keep its timers without a name, or
  delete them and cancel their alerts). Farm names, zones, grouping and
  collapsed sections are saved in `shared_preferences`.

- **Start several timers at once (v4)**: in the start sheet, **Add to list**
  queues the timer with all of its options (farm, zone, quantity, watered,
  farmhand, climate, planted-ago, custom grow time, own wither time) and
  leaves you in the Catalog to pick the next item. A bar under the Catalog
  and Timers tabs shows "N timers in list" with **Start N**. Tap it to
  review the list, edit an entry (it reopens the start sheet) or remove one
  with ✕. Then **Start N timers** starts them all, with times counted from
  that tap. Once the list has entries, the start sheet also offers **Add and
  start all**. **Start timer** still starts just that one timer with a single
  tap. The list holds up to 50 timers and is kept in memory only, so it is
  lost on reload. With push alerts on, the whole list is scheduled with
  **one** request to the push server (ready and wither alerts together).
  Other multi-timer actions are batched too: deleting a farm and its timers
  is one request, a repeat harvest (cancel the old cycle, schedule the next)
  is one request, and import-replace is one cancel plus one sync. Native
  platforms just schedule one local notification per timer.

## Abuse protection (push server)

The optional push server is a public API, so it is guarded in layers (details
in `push-server/README.md`):

- **Edge firewall** (once the custom domain `push.artimer.win` is attached): one
  Cloudflare rate-limiting rule blocks an IP for 10 s after 30 API requests in
  10 s, before the Worker runs.
- **Worker rate limits**: 120 requests/min per IP; 10 `/subscribe` per IP and
  10 test pushes per subscription per minute; 30 writes (`/schedule`, `/sync`,
  `/cancel`) per minute per IP and per subscription. Over a limit: HTTP 429,
  with nothing read from or written to the database.
- **Origin check**: POSTs must come from the app's own web origins.
- **Input limits**: 512 KB bodies, 300 alerts per subscription, 35 days ahead,
  only real push-service endpoints, at most 5,000 subscriptions, and unused
  subscriptions expire on their own (24 h / 3 days / 40 days).
- **Minimal writes**: unchanged alerts are not rewritten, so restarts and
  repeat syncs cost almost nothing.

What this does not cover: a large distributed attack can still use up the
Cloudflare free plan's daily quotas (100k Worker requests, 100k D1 rows
written). Alerts then pause until the daily reset; the app itself and its
timers keep working. The Workers Paid plan raises those quotas.

## Data

`assets/farm_items.json` is the bundled catalog. To refresh it from the
research output (`data/farm_items.json`), run:

```bash
./tool/sync_data.sh   # validates the JSON is an array, then copies it in
```

The parser is lenient. It ignores unknown fields, accepts numbers given as
strings, accepts `source` as a string or a list, and skips rows that have no
name or grow time. `growTimeMinutes` is the ArcheRage effective value (non-native
climate, unwatered). The 0.7 preferred-climate multiplier is an ArcheAge
community figure and has not been verified on ArcheRage
(`FarmItem.preferredClimateMultiplier`). The bonus applies only to the first
growth, not to repeat-harvest intervals.

Test fixture with example data: `test/fixtures/example_farm_items.json`.

## Project layout

```
lib/
  main.dart                  bootstrap (notifications, controller)
  app.dart                   MaterialApp, catalog loading
  models/                    FarmItem (+ category mapping), FarmTimer (JSON)
  services/
    timer_math.dart          pure timer math (ready/wither/status/harvest/format)
    timer_controller.dart    state, ticking, alerts, persistence glue
    timer_repository.dart    shared_preferences storage
    catalog_service.dart     asset loading, parsing, search, grouping
    notification_service.dart  per-platform notification strategy (+ composite)
    push_service.dart        Web Push alerts via the optional push server
    backup_service.dart      export/import JSON format
    platform_env*.dart       D-Bus availability check (conditional import)
  platform/pwa_bridge*.dart  JS interop to web/pwa.js (persist, push, share/download, updates)
  screens/                   home (nav + install/update banners), timers, catalog, settings
    settings/                one widget per Settings section (install, alerts, storage, backup)
  widgets/                   timer card, start-timer sheet (+ start_timer/ parts), chips
  util/log.dart              debug-only logging (silent in release, no error details)
  theme/                     dark gold/parchment theme
test/                        timer math, catalog parsing, persistence/controller, widget flow
tool/sync_data.sh, build_web.sh, gen_sw.py, make_icons.py, deploy_web_cloudflare.sh
web/                         index.html (iOS meta), sw.js, pwa.js, flutter_bootstrap.js, icons, splash
push-server/                 Cloudflare Worker + D1 push backend (see its README)
```

## Development

```bash
flutter pub get --enforce-lockfile   # exactly the versions in pubspec.lock
flutter analyze
flutter test
```

## Running and building per platform

### Linux
Install the dependencies: `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev`.
```bash
flutter run -d linux
flutter build linux --release   # -> build/linux/x64/release/bundle/
```
Desktop notifications need a D-Bus session bus and a notification daemon,
which any normal desktop session (GNOME, KDE, etc.) provides.

### Web / iPhone (Home Screen web app)
This is the iPhone route that needs no Mac and no Apple developer account.
```bash
tool/build_web.sh [--base-href /repo-name/] [--push-server https://push.example.com] [--push-server-fallback https://...workers.dev]
cd build/web && python3 -m http.server 8080      # local test: http://127.0.0.1:8080
```
`build_web.sh` does the following:
- Runs `flutter build web --release --no-web-resources-cdn`, so CanvasKit and
  fonts are served from your own host and the app works offline.
- Deletes Flutter's deprecated `flutter_service_worker.js`.
- Runs `tool/gen_sw.py`, which writes the content-hashed cache version and
  precache list into `build/web/sw.js`.

What the PWA layer does (`web/`, `lib/platform/`, `lib/screens/settings_screen.dart`):
- **Offline.** `web/sw.js` precaches the app shell and serves navigations from
  the cache. The runtime cache is cache-first. A new deploy installs in the
  background. The app then shows "A new version of the app is ready" with a
  **Reload** button (SKIP_WAITING, then reload), and old caches are deleted.
- **Install.** It has an iOS meta set (`apple-mobile-web-app-*`, `viewport-fit=cover`),
  apple-touch-icons 120/152/167/180, any and maskable manifest icons, 11
  `apple-touch-startup-image` splash screens, and a `#12161C` theme. Icons are
  generated by `tool/make_icons.py`.
- **Install hint.** In Safari (not standalone), a banner explains Share → *Add to
  Home Screen*. It also warns that **the Safari tab and the Home Screen app have
  separate storage**.
- **Install guide.** The install icon in the Home app bar, the Install tile at the top of Settings and the banner's
  "Show me how" open `lib/screens/install_guide_screen.dart`: numbered steps for iPhone/iPad (Safari) and Android
  (Chrome), the live URL with a copy button, and an "already installed" note in standalone mode. The tab that matches
  the user agent opens first.
- **Storage.** The Home Screen app calls `navigator.storage.persist()` on start.
  Settings → Storage shows the status. Settings → Backup can **Export**
  (iOS share sheet or download), **Import file**, and **Paste backup**, with a
  choice to merge or replace. Timers are stored in localStorage as UTC timestamps.
- **Push alerts** (optional, iOS 16.4+ and only in the Home Screen app).
  The server URL is fixed at build time (`tool/build_web.sh --push-server <url>`,
  i.e. `--dart-define=PUSH_SERVER_URL`). It can't be edited and isn't shown
  anywhere in the UI, and connection errors just say "Couldn't reach the alert
  server." An optional `--push-server-fallback <url>` is the same server under
  a second address (the old workers.dev one after a move to a custom domain):
  used only when the main address can't be reached, and a subscription made
  on either address stays valid. Old builds let users save a custom URL (`push_server_url` in storage).
  The app now deletes that key on start, and drops a subscription that was made
  on a different server (not the fallback), so "Enable alerts" appears again.
  "Enable alerts" asks for notification
  permission inside the tap, subscribes, and syncs every timer. Starting a timer
  schedules its alert, harvesting or deleting cancels it, and repeat harvests
  reschedule. Starting a list of timers is one request for all of them.
  See `push-server/README.md`.
  Built without `--push-server`, the app falls back to in-app alerts and
  Settings → Alerts says push alerts aren't available in this version.

Hosting (static HTTPS, free), pick one:
- **Cloudflare Pages.** Use the same free account as the push server:
  `tool/deploy_web_cloudflare.sh` gives `https://archerage-farm-timer.pages.dev/`.
  The app now lives at **https://artimer.win/** (a Pages custom domain). The
  install guide shows that URL, and the push server allows all three origins
  (and `www.artimer.win`) in `ALLOWED_ORIGINS`.
- **Privacy (v4.2)**: Settings → Privacy shows a short summary and opens the full
  notice (`lib/screens/privacy_screen.dart`, text in `lib/privacy/privacy_text.dart`).
  The same notice is a standalone page at **https://artimer.win/privacy.html**
  (`web/privacy.html`: no scripts, no cookies, links back to `/`). A test checks that
  the HTML and the in-app text match, so edit both together. The service worker sends
  navigations to `/privacy(.html)` to the network first, with the precached copy as
  the offline fallback, so the app shell never takes over that URL. Settings → Alerts
  notes that alert text stays on the push server until it's sent.
- **Move from pages.dev (v4.1)**: `web/moved.js` runs before Flutter boots.
  - `www.artimer.win` redirects to `artimer.win`.
  - On `archerage-farm-timer.pages.dev` with no saved app data
    (`farm_timers_v1`, `farms_v1`, `push_subscription_id` empty or missing),
    it does `location.replace` to the same path and query on artimer.win.
  - With saved data it doesn't redirect. The app shows a blocking **"The app
    has moved to artimer.win"** screen (`lib/screens/moved_screen.dart`) with
    steps, **Export backup** (share sheet or download), **Copy backup** (for
    Settings → Backup → Paste backup), **Open artimer.win**, and **Continue here
    for now** (not asked again that session). Nothing is deleted on pages.dev.
  - **One-tap transfer:** if the backup is under 32,000 characters (about 60
    timers), **Open artimer.win with my timers** opens
    `https://artimer.win/#import=<base64url backup>`. moved.js takes the hash
    out of the URL at once, and the app asks "Import N timers?" and then
    **merges**; nothing is replaced. The hash is never sent to a server. This
    button is hidden in an installed iPhone app: Home Screen apps keep their own
    storage, so the file or clipboard backup must be imported inside the new
    Home Screen app.
  - Preview deploys (`<hash>.archerage-farm-timer.pages.dev`) don't redirect.
  - `sw.js` calls `skipWaiting()` on pages.dev only, so existing installs take
    the new version (and the notice) on their next launch instead of waiting
    for every tab to close.
- **GitHub Pages.** Push `build/web` to a `gh-pages` branch of a public repo,
  built with `--base-href /<repo>/`.

### Android
Requires **Android Studio** or the Android SDK command-line tools, plus a
JDK 17. Run `flutter doctor --android-licenses`.
```bash
flutter run -d <device>
flutter build apk --release      # or: flutter build appbundle
```
Already configured:
- `POST_NOTIFICATIONS` (requested at runtime on Android 13+),
  `RECEIVE_BOOT_COMPLETED` and `VIBRATE` permissions, plus the plugin's
  `ScheduledNotificationReceiver` and `ScheduledNotificationBootReceiver`
  in `android/app/src/main/AndroidManifest.xml`.
- Core library desugaring in `android/app/build.gradle.kts`, which
  `flutter_local_notifications` requires.
- Notifications use `inexactAllowWhileIdle`, which avoids the restricted
  `SCHEDULE_EXACT_ALARM` permission but can fire a few minutes late under
  Doze. For exact alarms, add `SCHEDULE_EXACT_ALARM` and switch to
  `AndroidScheduleMode.exactAllowWhileIdle` in `notification_service.dart`.
- Before publishing, set up a release signing config. It currently uses
  debug keys.

### iOS and macOS
Both require **a Mac with Xcode** and CocoaPods or Swift Package Manager.
iOS builds also need an Apple developer team for signing.
```bash
flutter run -d ios        # or: flutter build ipa
flutter run -d macos      # or: flutter build macos
```
Notification setup:
- iOS: `ios/Runner/AppDelegate.swift` sets
  `UNUserNotificationCenter.current().delegate` so notifications show while
  the app is in the foreground. The system prompts for permission at the
  first launch (`DarwinInitializationSettings` defaults).
- macOS: the system prompts for permission at the first launch. No extra
  entitlements are needed for local notifications. If you sandbox network
  access later, edit `macos/Runner/*.entitlements`.
- In Xcode, set the signing team and bundle id (`com.glitch.archeragefarmtimer`).

### Windows
Requires **a Windows PC with Visual Studio 2022** and the "Desktop
development with C++" workload.
```bash
flutter run -d windows
flutter build windows --release   # -> build\windows\x64\runner\Release\
```
On Windows, alerts are in-app only (while the app is open).
`flutter_local_notifications` does support Windows toasts, but they need app
identity (MSIX packaging, AUMID, GUID). That is a candidate for later.

## Known limitations / ideas
- Linux and Windows don't get notifications while the app is closed.
- Wither warnings exist only for the few items with known wither data, or
  when you enter your own wither time (start sheet → Advanced).
- Fertilizer and other growth modifiers besides watering, farmhand and
  climate are not modelled. Use "custom grow time" in the Advanced section
  instead.
- Push alerts are verified locally and with a real FCM endpoint (Chrome).
  Apple's push service can only be tested on a real iPhone after deploying.
