# Cloudflare Pro plan: security and efficiency plan for artimer.win

Status: **applied to artimer.win on 2026-10-29**, with the managed rules still
in log mode (stage 1) and Super Bot Fight Mode on managed challenge. Payloads
and the apply script are in [`docs/cloudflare-pro/`](cloudflare-pro/). Apply
one stage at a time, dry run first.

Facts checked against Cloudflare's docs on 2026-10-29. Re-check the limits on
the linked pages before applying, because Cloudflare changes them.

## Price

The Pro plan is **$20/month billed annually or $25/month billed monthly**, per
domain (https://www.cloudflare.com/plans/, read 2026-10-29). Upgrades take
effect immediately and are prorated. Downgrades take effect at the end of the
billing period, and the Pro features stay on until then
(https://developers.cloudflare.com/billing/understand/how-billing-works/).

## Starting point

The plan assumes a zone with at most one hand-made WAF custom rule (it is kept:
`apply.sh custom` keeps every existing rule whose description doesn't start
with `[pro]`), no rate-limiting, cache or managed-rules entry points yet, and
Bot Fight Mode **off** (it must stay off once Super Bot Fight Mode is on).

## Order of evaluation (why the rules look like this)

Custom rules → rate limiting → Super Bot Fight Mode → managed rules. A Skip in
custom rules can skip `http_ratelimit`, `http_request_sbfm` and
`http_request_firewall_managed`
(https://developers.cloudflare.com/waf/custom-rules/skip/options/,
https://developers.cloudflare.com/waf/feature-interoperability/).

---

## 1. Cloudflare Managed Ruleset (Pro)

- **What:** Cloudflare's signature rules for known attacks and new CVEs. They
  replace the Free Managed Ruleset.
- **Settings:** Stage 1 (`managed-rules.log.json`) deploys it for all traffic
  (`expression: true`) with a ruleset-level override `action: log`, so it only
  records matches. Leave it like this for **3–7 days** after enabling it, and
  review Security → Events. Stage 2 (`managed-rules.block.json`) removes the
  override, so each rule uses its default action (mostly Block).
- **Why:** This is the main thing Pro adds for the push API (JSON POST bodies)
  and for generic scanners.
- **Risk:** False positives on POST bodies to push.artimer.win (for example
  subscription endpoint URLs). Log mode shows them first. If one rule
  misfires, add a rule override that turns only that rule off (rule ID from
  Events), not the whole ruleset.
- **Roll back:** `apply.sh --apply managed-log` (back to log only), or
  `apply.sh --apply restore http_request_firewall_managed <backup>`. In the
  dashboard: Security rules → Managed rules → turn the deployment off.
- Docs: https://developers.cloudflare.com/waf/managed-rules/ (availability: Pro
  = yes). Ruleset ID `efb7b8c949ac4650a09736fc376e9aee` is Cloudflare's public
  ID (https://developers.cloudflare.com/waf/managed-rules/deploy-api/).
  The Log override action appears in the docs' list of ruleset-level actions
  with no plan restriction
  (https://developers.cloudflare.com/waf/managed-rules/reference/cloudflare-managed-ruleset/).

## 2. Cloudflare OWASP Core Ruleset (available on Pro: verified)

- **What:** CRS 3.3.0, score-based. Each rule that matches adds to a threat
  score, and the action fires when the score reaches the threshold.
- **Tunable:** paranoia level PL1–PL4 (tags `paranoia-level-1..4`) and score
  threshold Low = 60, Medium = 40 (default), High = 25.
- **Settings (conservative):** PL1 only (tag overrides disable PL2–PL4),
  threshold **60** (the fewest blocks), action **Log** in both stages, via a
  rule override on the final scoring rule `6179ae15870a4bb7b2d480d4843b323c`.
  Switch it to Block (edit `"action": "log"` → `"block"` in
  `managed-rules.block.json`) only after a clean week, or never. Cloudflare
  says it "is prone to false positives and offers only marginal benefits when
  added on top of Cloudflare Managed Ruleset". On a GET-only static site plus
  a 6-route JSON API, the Managed Ruleset is enough.
- **Risk / roll back:** Same as item 1. Deleting the second rule from the JSON
  and re-running the step removes it.
- Docs: https://developers.cloudflare.com/waf/managed-rules/reference/owasp-core-ruleset/,
  https://developers.cloudflare.com/waf/managed-rules/reference/owasp-core-ruleset/configure-api/,
  https://developers.cloudflare.com/waf/get-started/

## 3. Super Bot Fight Mode (Pro)

- **What:** Bot protection for the whole domain, with an action per category.
  On Pro the categories are **Definitely automated** (allow / block / managed
  challenge) and **Verified bots** (allow / block). "Likely automated" is
  **Business and up only**. It replaces Bot Fight Mode, which must be off.
- **Settings** (`bot-management.json`, `PUT /zones/<ZONE_ID>/bot_management`):
  - `fight_mode: false` (Bot Fight Mode off; it's already off today)
  - `sbfm_definitely_automated: managed_challenge` first; after a few clean
    days `block` (`SBFM_ACTION=block apply.sh --apply bots`)
  - `sbfm_verified_bots: allow` (search engines, uptime monitors)
  - `sbfm_static_resource_protection: false` (keeps `.js/.wasm/.png/.woff2` and
    the service worker's precache free of challenges)
  - `enable_js: false` (JavaScript detections OFF; see "Privacy and CSP" below)
  - `optimize_wordpress: false`
- **push.artimer.win (correcting an assumption in the brief):** on Pro, SBFM
  **can** be skipped per host or path. Custom rules run first and a Skip rule
  with phase `http_request_sbfm` exempts the matching requests. Bot Fight Mode
  (Free) can't be skipped; SBFM can
  (https://developers.cloudflare.com/bots/get-started/super-bot-fight-mode/#configure-exceptions-to-super-bot-fight-mode,
  https://developers.cloudflare.com/waf/custom-rules/skip/options/). You still
  can't set different bot thresholds per path; that needs Enterprise Bot
  Management. Custom rule 1 below skips SBFM for exactly the push API's real
  routes, so a challenge can never break a browser `fetch()` or CORS preflight
  from the app. (A `fetch()` can't solve a challenge.) Push services (Apple,
  Google, Mozilla) never call push.artimer.win: the Worker calls them, so they
  aren't affected either way.
- **Privacy and CSP (must decide before enabling):**
  - Cloudflare's bot products set the `__cf_bm` cookie (expires after 30 min of
    inactivity; doesn't track users across sites)
    (https://developers.cloudflare.com/fundamentals/reference/policies-compliances/cloudflare-cookies/).
    The cookie switch `bm_cookie_enabled` is only in the Enterprise Bot
    Management API schema, so on Pro assume it can't be turned off. Managed
    challenges also set `cf_clearance` on challenged clients. **The privacy
    page and the in-app text** therefore have a "Cookies" section that
    describes Cloudflare's security cookies (`web/privacy.html` and
    `lib/privacy/privacy_text.dart`, kept in sync by a test), and the "Before
    you use" notice in `web/consent.js` mentions them (`CONSENT_VERSION` 2,
    so everyone who agreed to v1 is asked again). **Before turning SBFM on:**
    publish that privacy text first (update "Last updated", run the tests,
    rebuild and deploy the site). Only then run `apply.sh --apply bots`.
  - JavaScript detections inject an inline script and set `cf_clearance`. Our
    CSP `script-src` has no nonce or `'unsafe-inline'`, so the injected script
    would be refused (console CSP errors). Cloudflare recommends nonces, not
    `'unsafe-inline'`
    (https://developers.cloudflare.com/cloudflare-challenges/challenge-types/javascript-detections/).
    It also strips ETags from HTML. So keep it **off**.
- **Risk:** Managed challenges on the HTML for people on shared or flagged IPs.
  Static resource protection off and verified bots allowed keep the risk low.
- **Roll back:** `apply.sh --apply restore bots <backup>/bot_management.json`, or
  the dashboard: Security → Settings → Bot traffic → Super Bot Fight Mode → set
  every group to Allow and the options off (that's how the docs say to disable it).
- Note: the docs say updating SBFM rules through the Rulesets API is no longer
  supported. Use the `bot_management` endpoint (the script does).

## 4. WAF custom rules (Pro: 20 rules, 2 custom rulesets, no regex)

Limit source: https://developers.cloudflare.com/waf/custom-rules/#availability
(Free 5 / **Pro 20** / Business 100; regex only on Business and up; the Log
action isn't available below Enterprise, so these can't run in log mode. Test
with `curl` right after applying). File: `custom-rules.json`, phase
`http_request_firewall_custom`. 4 new rules + the existing 1 = 5 of 20.

| # | Name | Expression (summary) | Action |
|---|------|----------------------|--------|
| 1 | `[pro] push API: known routes skip Super Bot Fight Mode` | host `push.artimer.win` and (`OPTIONS` any path, or `GET` `/`, `/health`, `/vapid-public-key`, or `POST` `/subscribe` `/schedule` `/cancel` `/sync` `/test` `/unsubscribe`) | Skip `http_request_sbfm` (logged) |
| 2 | `[pro] push API: block unknown methods/paths` | host `push.artimer.win` and **not** the list above | Block |
| 3 | `[pro] static site: only GET/HEAD` | host in `artimer.win`, `www.artimer.win`, method not GET/HEAD, path not under `/cdn-cgi/` | Block |
| 4 | `[pro] block exploit probe paths` | dot-paths except `/.well-known/`; `wp-`, `/wordpress`, `xmlrpc`, `phpmyadmin`, `/cgi-bin`, `/vendor/`, `/actuator`, `/server-status`, `/boaform`, `/hnap1` (lowercased); extension in `php php5 php7 phtml asp aspx jsp cgi pl env ini sql bak old swp yml yaml conf config log sh` | Block |
| 5 | Block secret-file scans (existing, kept) | as live today | Block |

- **Why:** The push Worker only answers those 9 method/route pairs
  (`push-server/src/index.js`: `GET_ROUTES`, `POST_ROUTES`, `OPTIONS` for
  CORS), so everything else is noise and stops at the edge without using a
  Worker request. The site is static, so non-GET is never legitimate. The
  `/cdn-cgi/` exception keeps Web Analytics' automatic-setup beacon
  (`POST /cdn-cgi/rum`) and challenge-platform posts working.
- **Checked:** Every file in `build/web` passes rule 4 (the only hit,
  `/.last_build_id`, is a build artefact the app never requests, and the
  existing live rule already blocks it). Field and function names
  (`http.host`, `http.request.method`, `http.request.uri.path`,
  `http.request.uri.path.extension` (lowercased by Cloudflare),
  `starts_with`, `lower`, `in {}`) are from
  https://developers.cloudflare.com/ruleset-engine/rules-language/fields/reference/
  and https://developers.cloudflare.com/ruleset-engine/rules-language/functions/.
  No `matches` (regex) is used.
- **Note:** The Worker trims trailing slashes, but rule 2 blocks `/health/` or
  `/sync/`. The app never sends those. Keep this in mind if a route is added:
  add it to rules 1 and 2 **and** to the rate-limit list.
- **Risk:** A new push route that isn't added here gets blocked (403 at the
  edge). Rule 3 would block a future form or POST on the site.
- **Roll back:** `apply.sh --apply restore http_request_firewall_custom <backup>`
  (the backup is written by every `--apply`), or turn single rules off in
  Security rules.
- Optional, not in the payload: on Pro you get 10 custom lists instead of 1
  (https://developers.cloudflare.com/learning-paths/application-security/lists/features/).
  Single-IP blocks in custom rules could move into an IP list.

## 5. Rate limiting rules (Pro: 2 rules)

Verified from https://developers.cloudflare.com/waf/rate-limiting-rules/#availability:

| Pro limit | Value |
|-----------|-------|
| Number of rules | **2** (Free 1, Business 5) |
| Expression fields | Host, URI, Path, Full URI, Query, Verified Bot (**no method, no headers**) |
| Counting characteristics | **IP only** (`ip.src` + the mandatory `cf.colo.id`, so counted per data center) |
| Counting periods | supported values up to **1 min** (10, 15, 20, 30, 40, 45, 60 s) |
| Mitigation timeout | up to **1 h** (API values 0, 10, 60, 120, 300, 600, 3600; 86400 is above the Pro limit) |
| Cache exclusion / custom counting expression / throttling | No (Business and up / Enterprise) |
| Challenge actions | need `mitigation_timeout: 0` on Free/Pro/Business (throttle) |

(Parameters: https://developers.cloudflare.com/waf/rate-limiting-rules/parameters/.)

File `ratelimit.json`, phase `http_ratelimit`:

1. `[pro] push API flood (write paths)`: host `push.artimer.win` and path in
   the 6 POST routes. **150 requests / 60 s per IP per data center → Block for
   600 s.** This replaces the single Free-plan rule (30 / 10 s,
   block 10 s). Why 150/60: the Worker's own `RL_API` limit is 120/min per IP,
   so well-behaved clients get the Worker's 429 (which the app handles) first.
   The edge rule only stops clients that ignore 429s, and stops them for 10
   minutes without using Worker requests. It counts all methods because Pro
   can't filter by method. Preflight `OPTIONS` count too, which is why it's
   generous.
2. `[pro] site-wide flood (static site)`: hosts `artimer.win`,
   `www.artimer.win`, path not under `/cdn-cgi/`, not a verified bot.
   **600 requests / 60 s per IP → Block 300 s.** A first visit with the
   service worker's precache, plus lazily loaded fallback fonts (725 small
   `woff2` files exist), is far below this, even for a few people behind one
   NAT. Cached hits count too (no cache exclusion on Pro).

- **Risk:** Many users behind one carrier-grade NAT IP. The numbers are set
  loose for that. The rules have no log mode, so after applying, watch
  Security → Events.
- **Roll back:** `apply.sh --apply restore http_ratelimit <backup>` (the backup
  holds the Free rule if it existed), or edit/disable in the dashboard.

## 6. Cache rules (Pro: 25 rules; Free already has 10)

Limit: https://developers.cloudflare.com/cache/how-to/cache-rules/#availability.
File `cache-rules.json`, phase `http_request_cache_settings`.

Important finding: **the Flutter build has no content-hashed file names**
(`main.dart.js`, `flutter.js`, `canvaskit/*`, `assets/*` keep the same names on
every build). Cloudflare Pages already caches its own assets and serves the
new ones after each deploy. Cloudflare warns that adding caching on the custom
domain "may lead to stale assets being served after a deployment"
(https://developers.cloudflare.com/pages/configuration/serving-pages/). The
service worker precaches with `cache: 'reload'`. That skips the browser cache
but **not** Cloudflare's edge, so a long edge TTL could put an old
`main.dart.js` into a new service worker version. So the only long TTL is for
the paths that really are versioned:

1. `[pro] push API: never cache`: host `push.artimer.win` → `cache: false`.
   (Worker responses aren't cached anyway, so this is a guard.)
2. `[pro] site: bypass zone cache for unversioned app files`: both site hosts,
   everything except `/fonts/fallback/` and images (`png jpg jpeg gif webp ico`)
   → `cache: false`. That covers `index.html`, `/`, `sw.js`,
   `flutter_bootstrap.js`, `flutter.js`, `main.dart.js`, `manifest.json`,
   `version.json`, `pwa.js`, `moved.js`, `consent.js`, `consent.css`,
   `privacy.html`, `/privacy`, `assets/*` and `canvaskit/*`. It costs almost
   nothing because Pages serves them from its own Cloudflare cache. Images
   stay out of the bypass so Polish (item 7) can work on them.
3. `[pro] site: versioned fallback fonts, 1 year at the edge`:
   `/fonts/fallback/*` → eligible, edge TTL override 31,536,000 s, browser TTL
   respect origin (`_headers` already sends `max-age=31536000, immutable`).

- `web/_headers` checked: `no-cache` for `/`, `/index.html`, `/sw.js`,
  `/manifest.json`, `/flutter_bootstrap.js`, `/pwa.js`, `/moved.js`,
  `/consent.js`, `/consent.css`, `/privacy.html`, `/privacy`; immutable for
  `/fonts/fallback/*`. It has no `no-transform`, so Web Analytics automatic
  injection and Polish still work. Not listed with `no-cache`: `flutter.js`,
  `main.dart.js`, `version.json`, `assets/*`, `canvaskit/*`. They get Pages'
  default and are covered by rule 2. Nothing in `_headers` needs to change.
- Related zone setting (works on Free too): **Browser Cache TTL is 14400 s**.
  Cloudflare overrides the origin's `Cache-Control` when it is shorter than
  that setting
  (https://developers.cloudflare.com/cache/how-to/edge-browser-cache-ttl/).
  `zone-settings.json` sets it to `0` ("Respect Existing Headers") so our
  `no-cache` headers reach browsers unchanged. After applying, check with
  `curl -sI https://artimer.win/main.dart.js | grep -i cache-control`.
- **Roll back:** `apply.sh --apply restore http_request_cache_settings <backup>`
  (the backup is empty today, so this means "no cache rules"). Then purge
  everything if anything looks stale.
- Optional later: if `tool/build_web.sh` ever adds content hashes (or a
  `?v=<build>` query) to `main.dart.js` and `canvaskit/`, add a long-TTL rule
  for those paths.

## 7. Polish (Pro) + WebP

- **What:** Re-compresses images in Cloudflare's cache and serves WebP to
  browsers that accept it. Not available on Free
  (https://developers.cloudflare.com/images/polish/).
- **Settings:** `polish: lossless`, `webp: on` (`zone-settings.json`). Use
  lossless because the images are icons, the splash and the apple-touch-icon,
  where lossy artefacts would show.
- **Why / honest value:** Small. The build has 22 PNGs (icons/splash). It's
  free with Pro and safe.
- **Unverified:** whether Polish applies to assets served by Cloudflare Pages.
  After applying, look for a `cf-polished` response header on
  `/icons/Icon-192.png`. If it's missing, Polish is doing nothing and can be
  turned off again.
- **Roll back:** `polish: off`, `webp: off` (Speed → Optimization → Image
  optimization, or the settings API).

## 8. Other Pro features that are genuinely useful here (verified)

- **Custom error pages:** Pro has 25 rules and 25 assets; Free has none
  (https://developers.cloudflare.com/rules/custom-errors/). A friendly
  "blocked / too many requests" page in the app's style, instead of
  Cloudflare's generic page. Nice to have, not prepared.
- **More configuration rules** (25 vs 10) and more lists (10 vs 1). Only
  useful if the rules above grow.
- **Under Attack Mode and the push API** (applies on Free too): the existing
  automation that turns on Under Attack Mode would also challenge
  `push.artimer.win` `fetch()` calls, so alerts stop syncing during an attack.
  A configuration rule (setting `security_level`, values `off`,
  `essentially_off`, `under_attack`;
  https://developers.cloudflare.com/rules/configuration-rules/settings/) for
  host `push.artimer.win` could keep the API usable, since it has its own
  origin check and rate limits. That's a policy decision, so it isn't
  in the payloads.
- Not worth it here: leaked-credentials detection (no logins), OWASP in block mode (see 2), and
  anything that needs Business or Enterprise (WAF attack score, Likely
  automated, regex, cache exclusion in rate limits).

---

## Token for `apply.sh` (scope: Zone → Specific zone → artimer.win only)

Dashboard names, from
https://developers.cloudflare.com/fundamentals/api/reference/permissions/ (the
API names, which end in "Write", are in brackets):

| Permission | Used for |
|------------|----------|
| Zone → **Zone** → Read (`Zone Read`) | `apply.sh` checks the plan is Pro before sending |
| Zone → **Zone WAF** → Edit (`Zone WAF Write`) | custom rules, rate limiting rules, managed rules (`http_request_firewall_custom`, `http_ratelimit`, `http_request_firewall_managed`) |
| Zone → **Cache Rules** → Edit (`Cache Settings Write`) | cache rules (`http_request_cache_settings`) |
| Zone → **Bot Management** → Edit (`Bot Management Write`) | Super Bot Fight Mode via `PUT /zones/{zone_id}/bot_management` |
| Zone → **Zone Settings** → Edit (`Zone Settings Write`) | Polish, WebP, Browser Cache TTL |

- The cache rules API page also lists *Account Rulesets Edit* and *Account
  Filter Lists Edit*
  (https://developers.cloudflare.com/cache/how-to/cache-rules/create-api/).
  Those are account-wide and can't be limited to one zone. Try without them
  first (the cache-rules phase also accepts *Cache Settings Write*, as the
  rulesets API docs show). Add them only if the `cache` step returns
  403/10000.
- Not needed: Workers, DNS, Cache Purge (unless you also purge from the
  script), Config Rules (only for the optional Under Attack exception).
- This can be **the same token** as the one the Free-plan rate-limit rule needs (*Zone WAF
  Edit*), with the extra rows added. Create it at My Profile → API Tokens →
  Create token → Custom token. Under Zone Resources choose Include → Specific
  zone → artimer.win. Set a TTL of a few days and delete it after the last
  stage.

## How to run

```bash
# Dry run (default): prints every request, sends nothing, needs no token.
bash docs/cloudflare-pro/apply.sh custom managed-log ratelimit cache settings bots

# Real run, one stage at a time:
export CF_ZONE_ID=...            # from the zone overview page; never commit it
read -rs CF_API_TOKEN && export CF_API_TOKEN
bash docs/cloudflare-pro/apply.sh --apply custom
```

`--apply` checks that the plan is Pro, saves the current config to
`$BACKUP_DIR` (default `/tmp/cf-pro-backup-<time>`, outside the repo), shows
the new rule list and asks you to type `yes` before each write. The token is
passed to curl through a file descriptor, so it never appears in arguments,
output or logs.
