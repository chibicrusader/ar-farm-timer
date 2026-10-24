# AR Farm Timer push server (Cloudflare Worker + D1)

This is an optional backend. It sends "X is ready!" Web Push notifications to the
iPhone Home Screen app (and to desktop or Android browsers) while the app is
closed. The app works without it: you then get in-app alerts only while it's open.

- `src/index.js`: HTTP API, CORS, and delivery. A Durable Object (`AlertScheduler`, SQLite-backed, free plan)
  keeps one alarm set for the next pending alert's time minus `EARLY_MS` (1 s), so pushes go out within about a
  second of their time. /schedule, /cancel and /sync re-arm it. The every-minute cron (`* * * * *`) is only a
  watchdog: it asks the same DO to send anything overdue and re-arm. All sending runs in that one DO, so an alert
  is never sent twice.
- `src/webpush.js`: VAPID (ES256 JWT, RFC 8292) and `aes128gcm` payload encryption
  (RFC 8291) using WebCrypto only, so there are no runtime dependencies.
- `schema.sql`: the base tables `subscriptions` and `alerts` (`CREATE ... IF NOT EXISTS`, re-applied on every deploy).
- `migrations/`: additive D1 migrations on top of `schema.sql`, applied once each with
  `wrangler d1 migrations apply` (tracked in the `d1_migrations` table).
- Payloads use Apple's *Declarative Web Push* format (`{"web_push":8030,"notification":{...}}`).
  iOS 18.4+ shows these even if the service worker isn't running. Older iOS
  versions and other browsers are handled by the `push` handler in `web/sw.js`.

## API (JSON, all POSTs take `{"subscriptionId": ...}` except /subscribe)
| Route | Purpose |
|---|---|
| `GET /health` | liveness |
| `GET /vapid-public-key` | `{publicKey}`. The app fetches this before subscribing. |
| `POST /subscribe` | `{subscription: PushSubscription.toJSON()}`, returns `{subscriptionId}`. The same endpoint with the same keys gets its existing id back; the same endpoint with different keys gets a new id (the old one and its alerts are dropped). |
| `POST /schedule` | `{alerts:[{id, fireAt (ISO or ms), title, body, url?}], cancel?:[ids]}`. This is the **bulk** endpoint: it upserts any number of alerts (the app sends up to 50 timers, i.e. 100 alerts, at a time) and deletes the `cancel` ids in the same D1 batch. A repeat harvest is one request. Returns `{scheduled, cancelled}`. Older clients without `cancel` work unchanged. |
| `POST /cancel` | `{ids:[...]}`, deleted in one statement |
| `POST /sync` | `{alerts:[...]}`, replaces all of this subscription's alerts. The app calls it on start. |
| `POST /test` | sends a test push now and returns `{pushStatus}` |
| `POST /unsubscribe` | deletes the subscription and its alerts |

Limits: 300 alerts per subscription, at most 300 ids (alerts plus cancels) per
request, and at most 35 days ahead. A request that breaks a limit gets a 400
and nothing is written. Bulk writes are **one SQL statement** over
`json_each(?)`, not one statement per alert. Free-plan D1 allows 50 queries per
invocation and 100 bound parameters per query, and every statement in a batch
counts toward the 50. `/schedule`, `/cancel` and `/sync` therefore use 2–3
queries whatever the batch size. The send loop works the same way. It sends
at most 40 pushes per run, under the 50-subrequest limit, and if more are due
the alarm re-arms immediately. All of its deletes and updates go in one batch,
and the delivery log is one insert. Only endpoints on
known push services are accepted: Apple, FCM, Mozilla and Windows. If a push
returns 404 or 410, the subscription is deleted. Other failures are retried up
to 5 times within 6 h.

### Security model

- The random 48-hex `subscriptionId` is the only credential (a bearer token,
  192 bits). Every query is scoped to it, so one subscriber can't read,
  change or cancel another's alerts. Malformed ids get a 404 without a D1
  query.
- Requests from browser origins outside `ALLOWED_ORIGINS` get a 403 (CORS
  alone only hides responses). A POST **without** an `Origin` header also gets
  a 403: browsers always send one on these cross-origin POSTs, so only scripts
  omit it. (A script can fake the header, so this only turns away casual
  abuse; the rate limits below are the real protection.) GETs (`/health`,
  `/vapid-public-key`) work without one. `ALLOWED_ORIGINS="*"` turns the check
  off, e.g. for local tests. POST bodies must be `application/json`, a JSON
  object and at most 512 KB.
- `/subscribe` accepts only https endpoints on the push services above (default
  port, no user info, at most 1024 chars) and valid P-256 / 16-byte keys. At
  most `MAX_SUBSCRIPTIONS` (default 5000) are stored.
- Notification click URLs must be on `APP_URL`'s origin or an
  `ALLOWED_ORIGINS` origin (https); anything else (`javascript:`, other sites)
  is replaced by `APP_URL`. The service worker checks this again.
- Rate limits (Workers Rate Limiting bindings in `wrangler.toml`), checked
  before the body is read or D1 is touched:
  - `RL_API` (namespace 7301): 120 POSTs/min per IP (all API calls; the two GETs are not limited).
  - `RL_STRICT` (7302): 10 `/subscribe` per IP and 10 `/test` per subscription per minute.
  - `RL_WRITE` (7303): 30 writes/min per IP **and** 30 per subscription id, for
    `/schedule`, `/sync`, `/cancel`, `/test` and `/unsubscribe` (checked before
    any D1 lookup, so random well-formed ids can't burn D1 at only RL_API pace).
    `/test` still also uses RL_STRICT per subscription. The subscription key is
    used only if the id is well-formed, so junk ids can't create counters.
    Normal use is a handful of writes per minute.

  Over a limit: 429, with no D1 query. The IP is `CF-Connecting-IP` (set by
  Cloudflare); IPv6 clients are counted per /64. Counters are per Cloudflare
  location and approximate. A 429 still counts as a Worker request (free plan:
  100k/day), which is why the zone firewall rule below matters once the custom
  domain is attached.
- Writes are minimal: an upsert of an unchanged alert writes nothing, and
  `/sync` deletes only alerts that are no longer in the list, so repeat syncs
  from app restarts cost (almost) no D1 rows written.
- Unknown paths get a 404 before the body is read.
- The request body is read at most 512 KB (also when no Content-Length is sent).
- Sending is round-robin across subscriptions, and a subscription whose push
  fails gets one request per run, so a flood of alerts on one subscription
  (or a junk endpoint) can't hold up everyone else's alerts.
- Subscriptions expire when unused (see **Retention** below), so the
  `MAX_SUBSCRIPTIONS` cap can't be filled permanently by junk subscriptions.
- All SQL is parameterised (`?` / `json_each(?)`); the only interpolated
  values are code constants. Unexpected errors return `internal error` only.

### Retention (auto-expiry of unused subscriptions)

"Last active" (`subscriptions.last_seen`, ms) is bumped by `/subscribe` (same
keys), `/schedule`, `/sync`, `/cancel` and `/test`, folded into the request's
existing D1 batch and written at most once an hour per subscription. A
subscription counts as *activated* once it has stored an alert (a `/schedule`
or `/sync` with at least one alert). A subscription is deleted, with all its
alerts:

| Rule | Deleted when |
|---|---|
| never stored an alert | 24 h after it was created |
| has no pending alerts | 3 days after it was last active |
| any subscription | 40 days after it was last active, pending alerts included |

Pruning runs hourly inside the scheduler DO (its alarm/cron run; the same
hourly pass also prunes the 7-day delivery log), and also right away when
`/subscribe` hits `MAX_SUBSCRIPTIONS` (at most once a minute per isolate)
before it answers 503. So a rule takes effect within about an hour of its
deadline, as long as the every-minute cron watchdog is on (without the cron
the hourly pass only happens when an alert alarm fires). Alerts are at most 35 days ahead and are deleted when
sent, so an active user never reaches the 40-day rule. When the app gets a 404
for its subscription from `/schedule`, `/sync`, `/cancel` or `/test`, it
re-registers its existing browser push subscription with `/subscribe` and
retries once, with no prompt or error shown.

### Migration for existing databases (must run BEFORE deploying this code)

`migrations/0001_subscription_last_seen.sql` adds `last_seen` (an additive
`ALTER TABLE ... ADD COLUMN` with a default) and back-fills every existing row
to "now", so nothing is pruned by the change itself. `scripts/deploy.sh` runs
it after `schema.sql` and before `wrangler deploy`. To run it by hand against
production (from `push-server/`):

```bash
npm ci                                            # the wrangler pinned in package-lock.json
npx --no-install wrangler d1 migrations list  DB --remote   # shows 0001 as pending
npx --no-install wrangler d1 migrations apply DB --remote
```

(`DB` is the binding; the database name `archerage-farm-timer-push` works
too.) Locally `npm run db:local` applies `schema.sql` and the migrations.

## Local development (no account needed)
Needs **Node.js 22 or newer** (wrangler 4.15x requires it). With an older
system Node, run each command through a temporary Node 22, e.g.
`npx -y -p node@22 npm test` (this is also how `scripts/deploy.sh` should be
run on such a machine). wrangler always comes from `package-lock.json`: install
with `npm ci` and call it as `npx --no-install wrangler ...` (or the npm
scripts), never `wrangler@latest`.
```bash
npm ci
npm run gen-vapid          # -> ../../secrets/vapid.json (gitignored, chmod 600) + .dev.vars
npm run db:local           # create local D1 tables
npm run dev                # http://127.0.0.1:8787 ; trigger cron: curl 127.0.0.1:8787/__scheduled
npm test                   # unit tests (encryption decrypts with http_ece, JWT verifies, ...)
npm run test:e2e           # wrangler dev + mock push service: subscribe/schedule/alarm precision/cron/cancel/sync/410
```
Build or run the app against it with `tool/build_web.sh --push-server http://127.0.0.1:8787`
(or `flutter run -d chrome --dart-define=PUSH_SERVER_URL=http://127.0.0.1:8787`), then open
Settings → Alerts and tap "Enable alerts". The URL can't be changed in the app. A desktop Chrome on localhost is enough for testing.

## Deploy (free Cloudflare plan)
1. Create a free Cloudflare account, then run `npm ci && npx --no-install wrangler login` (it opens a browser).
2. Run:
   ```bash
   APP_URL=https://artimer.win/ \
   ALLOWED_ORIGINS=https://archerage-farm-timer.pages.dev,https://artimer.win,https://www.artimer.win \
   VAPID_SUBJECT=mailto:you@example.com \
   bash scripts/deploy.sh
   ```
   The script creates the D1 database and writes its id into `wrangler.toml`.
   Then it applies `schema.sql` and any pending `migrations/` remotely, fills in the non-secret vars,
   deploys, and stores the private VAPID key with `wrangler secret put VAPID_PRIVATE_JWK`.
   The key comes from `../../secrets/vapid.json` and is never written to git.
   It prints `https://archerage-farm-timer-push.<your-subdomain>.workers.dev`.
3. Build the app with the push server address: `tool/build_web.sh --push-server <url>`
   (with a custom domain, see below: `--push-server https://push.artimer.win
   --push-server-fallback <workers.dev url>`).
   This is the only way to set it; the app has no URL setting.

## Custom domain (`push.artimer.win`) and the firewall rule

Zone firewall (WAF) rules only apply to hostnames on a Cloudflare zone, never
to `*.workers.dev`. Serving the API on `push.artimer.win` lets a WAF rate-limit
rule drop floods **before** they run the Worker, so they don't use up the free
plan's 100k Worker requests/day.

The route is prepared but commented out in `wrangler.toml` (not attached).
To attach it:

1. Uncomment the `routes = [{ pattern = "push.artimer.win", custom_domain = true }]`
   block and deploy (`scripts/deploy.sh`), or in the dashboard: Workers & Pages →
   `archerage-farm-timer-push` → Settings → Domains & Routes → Add → Custom
   domain → `push.artimer.win`. Cloudflare creates the DNS record and certificate.
   (The API token needs *Workers Routes Edit* on the zone for the wrangler way.)
2. Add the WAF rule below.
3. Build the app with `--push-server https://push.artimer.win --push-server-fallback
   https://archerage-farm-timer-push.<subdomain>.workers.dev`. Both addresses go
   into the CSP. The app uses the fallback only when the main address can't be
   reached (network error, not timeouts or HTTP errors) and then sticks to it
   for that session. It's the same Worker and database, so subscription ids are
   valid on both. Installed apps with an older build keep using the workers.dev
   address until they update; nothing for the user to do.
4. Keep `workers_dev = true` for now. Turn it off (`workers_dev = false`, never
   change the subdomain) about **2–4 weeks after reopening**, once `wrangler tail`
   shows almost no requests on the workers.dev host and old app builds have updated
   (the service worker updates on the next visit). Until then the workers.dev
   address is a way around the WAF rule; the Worker's own limits still apply.

### WAF rate-limiting rule (Free plan: 1 rule, path field only)

Security → WAF → Rate limiting rules → Create rule:

| Setting | Value |
|---|---|
| Name | `push API flood` |
| If incoming requests match (expression) | `(http.request.uri.path in {"/subscribe" "/schedule" "/cancel" "/sync" "/test" "/unsubscribe"})` |
| With the same characteristics | IP (fixed on Free; counted per data center) |
| When rate exceeds | 30 requests per 10 seconds |
| Then take action | Block |
| Duration | 10 seconds (fixed on Free) |

The Free plan only allows the path (not host or method) in the expression, so
the rule also covers these paths on `artimer.win` itself; the site has no such
pages, so that's harmless. 30 per 10 s per IP is above the Worker's own 120/min
`RL_API` limit, so a normal user (even several on one home IP) is only ever
limited by the Worker, and the firewall only catches floods. Via the API
(token permission *Zone → Zone WAF → Edit*):

```bash
curl -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets/phases/http_ratelimit/entrypoint" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" \
  --data '{"rules":[{"description":"push API flood","action":"block",
    "expression":"(http.request.uri.path in {\"/subscribe\" \"/schedule\" \"/cancel\" \"/sync\" \"/test\" \"/unsubscribe\"})",
    "ratelimit":{"characteristics":["ip.src","cf.colo.id"],"period":10,
      "requests_per_period":30,"mitigation_timeout":10}}]}'
```

(`PUT` replaces the phase's rules; on Free there's only one.)

## Dependencies

- Runtime: none (WebCrypto only). Dev only: `wrangler` and `http_ece` (used by
  the tests to decrypt), pinned to exact versions in `package.json` and
  `package-lock.json`. Tests use the built-in `node:test`.
- `.npmrc`: `engine-strict` (refuses Node < 22), `ignore-scripts` (no
  install scripts run; wrangler works without them), `save-exact`.
- Scripts run `npm ci` and `npx --no-install wrangler`, so nothing newer than
  the lock file is ever downloaded at deploy time. Update on purpose with
  `npm install -D wrangler@<version>`, then `npm audit` and the tests.

**Keep `secrets/vapid.json` backed up.** If the VAPID key changes, every
existing subscription becomes invalid and each device has to tap "Enable alerts" again.

Free-tier use (free limits: Workers 100k requests/day, Durable Objects 100k
requests/day including alarm invocations, D1 5M rows read and 100k rows written
per day):

| Source | Cost |
|---|---|
| Cron watchdog | 1,440 runs/day. Each run is 1 DO request plus 2 small D1 reads (due alerts, next fire time). |
| `/schedule` (1 timer or a batch of N) | 1 Worker request, 1 D1 read for the subscription, 1 count, 1 bulk upsert (N alerts ≈ 2N rows written with the index), and 1 DO request. The DO then sets the alarm only if it moves earlier, with no D1 query. |
| `/cancel` | 1 Worker request, 1 read, 1 bulk delete. No DO request: a stale alarm just wakes, finds nothing due and re-arms. |
| `/sync` (app start, lead-time change, rename) | 1 Worker request, 1 delete and 1 bulk upsert, plus 1 DO request that does a full re-arm |
| Each alarm run | 1 DO request, 1 read, 1 batch (sent and retry rows), 1 log insert, and re-arm |

Before v4 the app sent one `/schedule` per timer (N Worker requests and N DO
requests for N timers) and one `/cancel` per timer when a farm was deleted.
The worker also wrote one statement per alert, which could hit the 50-query
limit for large syncs or for many alerts due at once.

## Delivery latency log

Each send writes a row to `deliveries` (sub_id, alert_id, fire_at, sent_at, status, push_ms, via=alarm|cron).
Rows older than 7 days are pruned hourly. To inspect lag (negative = sent early, by design):

```
npx --no-install wrangler d1 execute DB --remote --command \
  "SELECT alert_id, sent_at - fire_at AS lag_ms, push_ms, status, via FROM deliveries ORDER BY sent_at DESC LIMIT 20"
```

`npx --no-install wrangler tail archerage-farm-timer-push` also shows `sent {...lagMs, pushMs, status}` per alarm run.
Headers: `Urgency: high`, `TTL: 21600` (6 h, so an alert still lands if the phone was offline for a while).
