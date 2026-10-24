// AR Farm Timer push server (Cloudflare Worker + D1).
//
// The app schedules "ready" alerts here. A Durable Object alarm (AlertScheduler)
// fires at the exact time of the next due alert, so delivery is second-precise.
// The once-a-minute cron is a watchdog that re-arms the alarm and catches
// anything missed. See README.md for endpoints and deployment.

import { sendWebPush, validateSubscriptionKeys } from './webpush.js';

const MAX_ALERTS_PER_SUB = 300;
// Most ids one /schedule or /cancel request may touch (alerts + cancels).
// The app sends at most 50 timers (100 alerts) per batch.
const MAX_IDS_PER_REQUEST = 300;
// Send this much before fire_at so the notification lands on time after
// push-service latency (APNs/FCM typically 0.2-2 s).
const EARLY_MS = 1000;
const LOG_RETENTION_MS = 7 * 24 * 3600 * 1000;
const MAX_FUTURE_MS = 35 * 24 * 3600 * 1000;
// Alerts older than this are rejected (the app only sends future alerts).
const MAX_PAST_MS = 24 * 3600 * 1000;
// Request body cap: 300 alerts at the field limits below are ~350 KB.
const MAX_BODY_BYTES = 512 * 1024;
// Real push endpoints are ~150-400 chars; anything longer is junk/abuse.
const MAX_ENDPOINT_LEN = 1024;
const MAX_URL_LEN = 500;
// Server-generated subscription ids: 24 random bytes as hex.
const SUB_ID_RE = /^[0-9a-f]{48}$/;
// Hard cap on stored subscriptions (bounds D1 storage if /subscribe is
// abused with fabricated endpoints). Override with the MAX_SUBSCRIPTIONS var.
const DEFAULT_MAX_SUBSCRIPTIONS = 5000;
// Subscription retention (see pruneSubscriptions). "Seen" = the later of
// last_seen and created_at; "activated" = it has stored an alert at least once.
const HOUR_MS = 3600 * 1000;
const DAY_MS = 24 * HOUR_MS;
const RETAIN_UNACTIVATED_MS = DAY_MS; // never stored an alert: kept 24 h after creation
const RETAIN_IDLE_MS = 3 * DAY_MS; // no pending alerts: kept 3 days after last seen
const RETAIN_MAX_MS = 40 * DAY_MS; // anything: kept 40 days after last seen (alerts are <= 35 days ahead)
// last_seen is written at most this often per subscription (D1 writes are metered).
const TOUCH_EVERY_MS = HOUR_MS;
// When the cap is hit, prune at most this often (per isolate) before answering 503.
const CAP_PRUNE_EVERY_MS = 60 * 1000;
let lastCapPrune = 0;
/** Tests only: forget when the cap last triggered a prune. */
export function resetCapPruneThrottle() { lastCapPrune = 0; }
const DEFAULT_PUSH_HOSTS = [
  'web.push.apple.com', // iOS / Safari
  'fcm.googleapis.com', // Chrome / Android
  'updates.push.services.mozilla.com', // Firefox
  'notify.windows.com', // Edge (suffix match)
];

function allowedOrigins(env) {
  return (env.ALLOWED_ORIGINS || '*').split(',').map((s) => s.trim()).filter(Boolean);
}

/**
 * Whether a request's Origin may call the API. GETs (health, VAPID key) may
 * come without an Origin; a POST must carry an allowed one, because the only
 * client is the web app and browsers always send Origin on a cross-origin
 * POST. (A script can fake the header, so this only turns away casual
 * non-browser traffic; the rate limits are the real protection.) With
 * ALLOWED_ORIGINS = "*" anything goes, including no Origin.
 */
export function originAllowed(origin, env, method = 'GET') {
  const allowed = allowedOrigins(env);
  if (allowed.includes('*')) return true;
  if (!origin) return method !== 'POST';
  return allowed.includes(origin);
}

function corsHeaders(request, env) {
  const origin = request.headers.get('Origin') || '';
  const allowed = allowedOrigins(env);
  const headers = {
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Max-Age': '86400',
    Vary: 'Origin',
  };
  // A disallowed origin gets no Access-Control-Allow-Origin at all.
  if (allowed.includes('*')) headers['Access-Control-Allow-Origin'] = '*';
  else if (origin && allowed.includes(origin)) headers['Access-Control-Allow-Origin'] = origin;
  return headers;
}

function json(data, status, cors) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', ...cors },
  });
}

class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

function vapidConfig(env) {
  if (!env.VAPID_PUBLIC_KEY || !env.VAPID_PRIVATE_JWK) throw new HttpError(500, 'VAPID keys not configured');
  return {
    publicKey: env.VAPID_PUBLIC_KEY,
    privateJwk: typeof env.VAPID_PRIVATE_JWK === 'string' ? JSON.parse(env.VAPID_PRIVATE_JWK) : env.VAPID_PRIVATE_JWK,
    subject: env.VAPID_SUBJECT || 'mailto:admin@example.com',
  };
}

export function isAllowedEndpoint(endpoint, env) {
  if (typeof endpoint !== 'string' || endpoint.length > MAX_ENDPOINT_LEN) return false;
  let url;
  try { url = new URL(endpoint); } catch { return false; }
  if (url.username || url.password) return false;
  const extra = (env.EXTRA_PUSH_HOSTS || '').split(',').map((s) => s.trim()).filter(Boolean);
  const host = url.hostname;
  if (extra.includes(url.host) || extra.includes(host)) return true; // local testing only
  // Only the browser vendors' push services, over https on the default port
  // (no SSRF to other hosts or ports).
  if (url.protocol !== 'https:' || url.port !== '') return false;
  return DEFAULT_PUSH_HOSTS.some((h) => host === h || host.endsWith('.' + h));
}

/** Origins a notification tap may open: APP_URL's and the allowed web app origins. */
function notificationOrigins(env) {
  const out = new Set(allowedOrigins(env).filter((o) => o !== '*'));
  try { if (env.APP_URL) out.add(new URL(env.APP_URL).origin); } catch { /* ignore */ }
  return out;
}

/**
 * Click URL for a notification: only an https (or local http) URL on the
 * app's own origins; anything else (javascript:, data:, other sites) is
 * dropped and the notification opens APP_URL instead. Exported for tests.
 */
export function safeAppUrl(v, env) {
  if (typeof v !== 'string' || !v || v.length > MAX_URL_LEN) return null;
  let u;
  try { u = new URL(v); } catch { return null; }
  if (u.username || u.password) return null;
  const local = u.hostname === 'localhost' || u.hostname === '127.0.0.1';
  if (!(u.protocol === 'https:' || (u.protocol === 'http:' && local))) return null;
  if (!notificationOrigins(env).has(u.origin)) return null;
  return u.href.length > MAX_URL_LEN ? null : u.href;
}

/** Length-independent string compare (for stored push keys). */
function sameString(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  return diff === 0;
}

function randomId() {
  const b = crypto.getRandomValues(new Uint8Array(24));
  return [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
}

/** A string (numbers are accepted as text) cut to [max] chars, else null. */
function str(v, max) {
  if (typeof v === 'number' && Number.isFinite(v)) v = String(v);
  if (typeof v !== 'string') return null;
  let s = v.slice(0, max);
  // Don't leave half a surrogate pair at the cut.
  if (s.length && /[\uD800-\uDBFF]$/.test(s)) s = s.slice(0, -1);
  return s;
}

/** Validates and normalises alerts from the app. */
export function parseAlerts(list, now, env = {}) {
  if (!Array.isArray(list)) throw new HttpError(400, 'alerts must be an array');
  if (list.length > MAX_ALERTS_PER_SUB) throw new HttpError(400, 'too many alerts');
  return list.map((a) => {
    if (a == null || typeof a !== 'object' || Array.isArray(a)) throw new HttpError(400, 'alert needs id, title, fireAt');
    const id = str(a.id, 128);
    // ISO string or epoch ms.
    const fireAt = typeof a.fireAt === 'number' ? a.fireAt
      : typeof a.fireAt === 'string' && a.fireAt.length <= 64 ? Date.parse(a.fireAt) : NaN;
    const title = str(a.title, 120);
    if (!id || !title || !Number.isFinite(fireAt)) throw new HttpError(400, 'alert needs id, title, fireAt');
    if (fireAt > now + MAX_FUTURE_MS) throw new HttpError(400, 'fireAt too far in the future');
    if (fireAt < now - MAX_PAST_MS) throw new HttpError(400, 'fireAt too far in the past');
    return { id, fireAt: Math.round(fireAt), title, body: str(a.body, 300) || '', url: safeAppUrl(a.url, env) };
  });
}

/** Parses a JSON object body (size-capped; must be a JSON content type). */
async function readJson(request) {
  const type = (request.headers.get('Content-Type') || '').toLowerCase();
  if (!type.startsWith('application/json')) throw new HttpError(415, 'Content-Type must be application/json');
  const declared = Number(request.headers.get('Content-Length'));
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) throw new HttpError(413, 'request too large');
  // Read at most MAX_BODY_BYTES even without (or with a false) Content-Length.
  const chunks = [];
  let size = 0;
  if (request.body) {
    const reader = request.body.getReader();
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > MAX_BODY_BYTES) {
          reader.cancel().catch(() => {});
          throw new HttpError(413, 'request too large');
        }
        chunks.push(value);
      }
    } catch (e) {
      if (e instanceof HttpError) throw e;
      throw new HttpError(400, 'invalid body');
    }
  }
  const buf = new Uint8Array(size);
  let o = 0;
  for (const c of chunks) { buf.set(c, o); o += c.byteLength; }
  let text;
  try { text = new TextDecoder('utf-8', { fatal: true }).decode(buf); } catch { throw new HttpError(400, 'invalid body'); }
  let body;
  try { body = JSON.parse(text); } catch { throw new HttpError(400, 'invalid JSON'); }
  if (body == null || typeof body !== 'object' || Array.isArray(body)) throw new HttpError(400, 'body must be a JSON object');
  return body;
}

/**
 * Per-key rate limit via an optional Workers Rate Limiting binding (see
 * wrangler.toml). Without the binding (tests, local dev) it is a no-op.
 */
async function rateLimit(env, binding, key) {
  const rl = env[binding];
  if (!rl || typeof rl.limit !== 'function') return;
  let ok = true;
  try { ok = (await rl.limit({ key })).success; } catch (e) { console.error('rate limiter error', e); }
  if (!ok) throw new HttpError(429, 'too many requests; try again in a minute');
}

/**
 * Rate-limit key for a client IP. IPv6 users usually control a whole /64
 * (2^64 addresses), so IPv6 is keyed by its /64 prefix; IPv4 by address.
 * Exported for tests.
 */
export function clientKey(ip) {
  if (typeof ip !== 'string' || !ip || ip.length > 64) return 'unknown';
  if (!ip.includes(':')) return ip; // IPv4
  const v4 = /^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/i.exec(ip);
  if (v4) return v4[1];
  const halves = ip.toLowerCase().split('::');
  if (halves.length > 2) return ip;
  const head = halves[0] ? halves[0].split(':') : [];
  const tail = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
  const fill = halves.length === 2 ? 8 - head.length - tail.length : 0;
  if (fill < 0) return ip;
  const groups = [...head, ...Array(fill).fill('0'), ...tail];
  if (groups.length !== 8 || !groups.every((g) => /^[0-9a-f]{1,4}$/.test(g))) return ip;
  return `${groups.slice(0, 4).map((g) => parseInt(g, 16).toString(16)).join(':')}::/64`;
}

async function requireSub(env, subscriptionId) {
  if (typeof subscriptionId !== 'string' || !subscriptionId) throw new HttpError(400, 'subscriptionId required');
  // Malformed ids can't exist: answer like an unknown one (the app then
  // asks the user to enable alerts again) without touching D1.
  if (!SUB_ID_RE.test(subscriptionId)) throw new HttpError(404, 'unknown subscription (enable alerts again)');
  const sub = await env.DB.prepare('SELECT * FROM subscriptions WHERE id = ?').bind(subscriptionId).first();
  if (!sub) throw new HttpError(404, 'unknown subscription (enable alerts again)');
  return sub;
}

// Bulk writes use ONE statement over json_each() instead of one statement
// per alert: D1 on the free plan allows 50 queries per Worker invocation and
// 100 bound parameters per query, and every statement in a batch counts.

/**
 * Statement recording activity on [sub] (or none: last_seen is written at
 * most once per TOUCH_EVERY_MS). [activates] = this request stores alerts.
 * A subscription that never stored an alert keeps last_seen <= created_at,
 * so the 24 h rule can recognise it. Exported for tests.
 */
export function touchStatements(env, sub, now, activates) {
  const created = Number(sub.created_at) || 0;
  const seen = Number(sub.last_seen) || 0;
  const activated = seen > created;
  let at = null;
  if (activates && !activated) at = Math.max(now, created + 1);
  else if (activated && now - seen >= TOUCH_EVERY_MS) at = now;
  if (at == null) return [];
  return [env.DB.prepare('UPDATE subscriptions SET last_seen = ?1 WHERE id = ?2').bind(at, sub.id)];
}

/**
 * Deletes subscriptions nobody uses any more (with their alerts):
 *  - never stored an alert and created more than 24 h ago;
 *  - no pending alerts and not seen for 3 days;
 *  - not seen for 40 days, whatever it has pending.
 * Also drops due alerts whose subscription is gone. The app re-subscribes
 * by itself when the server answers 404. Exported for tests.
 */
export async function pruneSubscriptions(env, now = Date.now()) {
  const seen = 'MAX(last_seen, created_at)';
  const res = await env.DB.batch([
    env.DB.prepare(`DELETE FROM alerts WHERE sub_id IN (SELECT id FROM subscriptions WHERE ${seen} < ?1)`)
      .bind(now - RETAIN_MAX_MS),
    env.DB.prepare(
      `DELETE FROM subscriptions WHERE ${seen} < ?1
         OR (NOT EXISTS (SELECT 1 FROM alerts a WHERE a.sub_id = subscriptions.id)
             AND (${seen} < ?2 OR (last_seen <= created_at AND created_at < ?3)))`,
    ).bind(now - RETAIN_MAX_MS, now - RETAIN_IDLE_MS, now - RETAIN_UNACTIVATED_MS),
    env.DB.prepare('DELETE FROM alerts WHERE fire_at <= ?1 AND NOT EXISTS (SELECT 1 FROM subscriptions s WHERE s.id = alerts.sub_id)')
      .bind(now),
  ]);
  const removed = res[1]?.meta?.changes ?? 0;
  if (removed) console.log('pruned subscriptions', removed);
  return removed;
}

function upsertStatements(env, subId, alerts) {
  if (!alerts.length) return [];
  const rows = alerts.map((a) => ({ id: a.id, f: a.fireAt, t: a.title, b: a.body, u: a.url }));
  return [env.DB.prepare(
    `INSERT INTO alerts (sub_id, id, fire_at, title, body, url, attempts)
     SELECT ?1, json_extract(value, '$.id'), json_extract(value, '$.f'), json_extract(value, '$.t'),
       json_extract(value, '$.b'), json_extract(value, '$.u'), 0
     FROM json_each(?2) WHERE EXISTS (SELECT 1 FROM subscriptions WHERE id = ?1)
     ON CONFLICT (sub_id, id) DO UPDATE SET fire_at = excluded.fire_at, title = excluded.title,
       body = excluded.body, url = excluded.url, attempts = 0
     WHERE alerts.fire_at IS NOT excluded.fire_at OR alerts.title IS NOT excluded.title
       OR alerts.body IS NOT excluded.body OR alerts.url IS NOT excluded.url OR alerts.attempts <> 0`,
  ).bind(subId, JSON.stringify(rows))];
}

function deleteStatements(env, subId, ids) {
  if (!ids.length) return [];
  return [env.DB.prepare('DELETE FROM alerts WHERE sub_id = ?1 AND id IN (SELECT value FROM json_each(?2))')
    .bind(subId, JSON.stringify(ids))];
}

/** Validates a list of alert ids to cancel (strings, max 128 chars). */
export function parseIds(list) {
  if (list == null) return [];
  if (!Array.isArray(list)) throw new HttpError(400, 'ids must be an array');
  if (list.length > MAX_IDS_PER_REQUEST) throw new HttpError(400, 'too many ids');
  return [...new Set(list.map((i) => str(i, 128)).filter(Boolean))];
}

export function buildPayload(alert, env) {
  // Re-checked at send time too, for rows stored before URL validation.
  const navigate = safeAppUrl(alert.url, env) || env.APP_URL || 'https://example.com/';
  // Declarative Web Push (iOS 18.4+ shows it natively); our service worker
  // reads the same structure on older iOS / other browsers.
  return JSON.stringify({
    web_push: 8030,
    notification: { title: alert.title, body: alert.body || '', navigate, tag: String(alert.id).slice(0, 64) },
  });
}

async function pushTo(sub, alert, env) {
  const res = await sendWebPush(
    { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
    buildPayload(alert, env),
    vapidConfig(env),
    // Urgency high = deliver immediately even on battery saver (RFC 8030);
    // TTL 6 h: a "ready" alert is still useful a few hours late.
    { ttl: 6 * 3600, urgency: 'high' },
  );
  return res.status;
}

/**
 * Asks the scheduler Durable Object to re-arm its alarm (after alerts change).
 * [earliest] (ms) is the soonest alert just added: the DO then only moves its
 * alarm earlier when needed, without a D1 query. Without it the DO looks up
 * the next alert itself (after /sync).
 */
function rearm(env, ctx, earliest) {
  if (!env.SCHEDULER) return; // tests / old deployments: cron-only
  const stub = env.SCHEDULER.get(env.SCHEDULER.idFromName('global'));
  const q = earliest == null ? '' : `?earliest=${earliest}`;
  const p = stub.fetch(`https://scheduler/rearm${q}`, { method: 'POST' }).catch((e) => console.error('rearm failed', e));
  if (ctx) ctx.waitUntil(p);
  return p;
}

// ---- Routes ----------------------------------------------------------------
// Each POST route gets a context { env, ctx, now, ip, body } and returns the
// JSON response body (or throws HttpError).

function health(c) {
  return { ok: true, service: 'archerage-farm-timer-push', time: new Date(c.now).toISOString() };
}

function vapidPublicKey(c) {
  return { publicKey: vapidConfig(c.env).publicKey };
}

/**
 * Write limits for routes that burn D1 (alert writes, unsubscribe deletes,
 * and /test's requireSub lookup): per client IP, then per subscription id.
 * The id is only used as a key once it is well-formed, before any D1 lookup.
 * Apply before requireSub so random well-formed ids cannot cheaply burn D1
 * at only RL_API pace.
 */
async function writeLimit(c) {
  await rateLimit(c.env, 'RL_WRITE', `wip:${c.ip}`);
  const id = c.body.subscriptionId;
  if (typeof id === 'string' && SUB_ID_RE.test(id)) await rateLimit(c.env, 'RL_WRITE', `wsub:${id}`);
}

async function subscribeRoute(c) {
  const { env, now, body } = c;
  await rateLimit(env, 'RL_STRICT', `subscribe:${c.ip}`);
  const s = body.subscription;
  const keys = s && typeof s === 'object' ? s.keys : null;
  if (!s || typeof s.endpoint !== 'string' || !keys || typeof keys !== 'object') throw new HttpError(400, 'invalid subscription');
  if (!isAllowedEndpoint(s.endpoint, env)) throw new HttpError(400, 'push endpoint host not allowed');
  if (!(await validateSubscriptionKeys(keys.p256dh, keys.auth))) throw new HttpError(400, 'invalid subscription keys');
  const existing = await env.DB.prepare('SELECT id, p256dh, auth, created_at, last_seen FROM subscriptions WHERE endpoint = ?').bind(s.endpoint).first();
  // Same browser subscription (same endpoint AND keys): same id, so a
  // reinstalled app finds its alerts. Knowing only the endpoint is not
  // enough to get (or re-key) someone's subscription.
  if (existing && sameString(existing.p256dh, keys.p256dh) && sameString(existing.auth, keys.auth)) {
    const touch = touchStatements(env, existing, now, false);
    if (touch.length) await touch[0].run();
    return { subscriptionId: existing.id };
  }
  if (existing) {
    // Different keys for a known endpoint: the old id and its alerts are
    // dropped; the caller gets a fresh id bound to the new keys.
    await deleteSub(env, existing.id);
  } else {
    await ensureCapacity(env, now);
  }
  const id = randomId();
  await env.DB.prepare('INSERT INTO subscriptions (id, endpoint, p256dh, auth, created_at, last_seen) VALUES (?, ?, ?, ?, ?, ?)')
    .bind(id, s.endpoint, keys.p256dh, keys.auth, now, now).run();
  return { subscriptionId: id };
}

/** 503 when MAX_SUBSCRIPTIONS are stored (after one throttled prune). */
async function ensureCapacity(env, now) {
  const max = Number(env.MAX_SUBSCRIPTIONS) > 0 ? Number(env.MAX_SUBSCRIPTIONS) : DEFAULT_MAX_SUBSCRIPTIONS;
  const count = () => env.DB.prepare('SELECT COUNT(*) AS n FROM subscriptions').first('n');
  let n = await count();
  if (n >= max && now - lastCapPrune >= CAP_PRUNE_EVERY_MS) {
    // Full: drop idle subscriptions first (normally done hourly).
    lastCapPrune = now;
    await pruneSubscriptions(env, now);
    n = await count();
  }
  if (n >= max) throw new HttpError(503, 'alert server is full; try again later');
}

async function scheduleRoute(c) {
  // Bulk: any number of timers' alerts in one request (one D1 batch).
  // Optional `cancel: [ids]` removes alerts in the same batch, so a
  // repeat harvest (cancel old cycle + schedule next) is one request.
  const { env, now, body } = c;
  await writeLimit(c);
  const sub = await requireSub(env, body.subscriptionId);
  const alerts = parseAlerts(body.alerts, now, env);
  const cancel = parseIds(body.cancel);
  if (alerts.length + cancel.length > MAX_IDS_PER_REQUEST) throw new HttpError(400, 'too many alerts');
  if (alerts.length) {
    // Alerts this request replaces or cancels don't count twice.
    const touched = JSON.stringify([...new Set([...alerts.map((a) => a.id), ...cancel])]);
    const others = await env.DB.prepare(
      'SELECT COUNT(*) AS n FROM alerts WHERE sub_id = ?1 AND id NOT IN (SELECT value FROM json_each(?2))',
    ).bind(sub.id, touched).first('n');
    if (others + new Set(alerts.map((a) => a.id)).size > MAX_ALERTS_PER_SUB) throw new HttpError(400, 'too many alerts');
  }
  const stmts = [...deleteStatements(env, sub.id, cancel), ...upsertStatements(env, sub.id, alerts),
    ...touchStatements(env, sub, now, alerts.length > 0)];
  if (stmts.length) await env.DB.batch(stmts);
  // Cancels never need an alarm change: a stale alarm just wakes, finds
  // nothing due and re-arms (same cost as re-arming now, often free).
  if (alerts.length) rearm(env, c.ctx, Math.min(...alerts.map((a) => a.fireAt)));
  return { scheduled: alerts.length, cancelled: cancel.length };
}

async function cancelRoute(c) {
  const { env, now, body } = c;
  await writeLimit(c);
  const sub = await requireSub(env, body.subscriptionId);
  const ids = parseIds(Array.isArray(body.ids) ? body.ids : []);
  const stmts = [...deleteStatements(env, sub.id, ids), ...touchStatements(env, sub, now, false)];
  if (stmts.length) await env.DB.batch(stmts);
  return { cancelled: ids.length };
}

async function syncRoute(c) {
  // Replaces every pending alert of this subscription (repairs missed cancels).
  // Only alerts that are not in the new list are deleted and only new or
  // changed ones are written, so a repeated identical /sync writes no rows.
  const { env, now, body } = c;
  await writeLimit(c);
  const sub = await requireSub(env, body.subscriptionId);
  const alerts = parseAlerts(body.alerts, now, env).filter((a) => a.fireAt > now - 60_000);
  await env.DB.batch([
    env.DB.prepare('DELETE FROM alerts WHERE sub_id = ?1 AND id NOT IN (SELECT value FROM json_each(?2))')
      .bind(sub.id, JSON.stringify(alerts.map((a) => a.id))),
    ...upsertStatements(env, sub.id, alerts),
    ...touchStatements(env, sub, now, alerts.length > 0),
  ]);
  rearm(env, c.ctx);
  return { scheduled: alerts.length };
}

async function testRoute(c) {
  const { env, now, body } = c;
  await writeLimit(c);
  const sub = await requireSub(env, body.subscriptionId);
  await rateLimit(env, 'RL_STRICT', `test:${sub.id}`);
  const touch = touchStatements(env, sub, now, false);
  if (touch.length) await touch[0].run();
  const t0 = Date.now();
  const status = await pushTo(sub, { id: 'test', title: 'AR Farm Timer test alert', body: 'Push alerts are working.', url: safeAppUrl(body.url, env) }, env);
  const pushMs = Date.now() - t0;
  console.log('test push', JSON.stringify({ host: new URL(sub.endpoint).host, status, pushMs }));
  if (status === 404 || status === 410) {
    await deleteSub(env, sub.id);
    throw new HttpError(410, 'subscription expired; enable alerts again');
  }
  return { pushStatus: status, pushMs };
}

async function unsubscribeRoute(c) {
  await writeLimit(c);
  const sub = await requireSub(c.env, c.body.subscriptionId);
  await deleteSub(c.env, sub.id);
  return { ok: true };
}

const GET_ROUTES = new Map([['/', health], ['/health', health], ['/vapid-public-key', vapidPublicKey]]);
const POST_ROUTES = new Map([
  ['/subscribe', subscribeRoute],
  ['/schedule', scheduleRoute],
  ['/cancel', cancelRoute],
  ['/sync', syncRoute],
  ['/test', testRoute],
  ['/unsubscribe', unsubscribeRoute],
]);

async function handle(request, env, ctx) {
  const url = new URL(request.url);
  const path = url.pathname.replace(/\/+$/, '') || '/';
  const now = Date.now();
  if (request.method === 'GET' && GET_ROUTES.has(path)) return GET_ROUTES.get(path)({ env, now });
  if (request.method !== 'POST') throw new HttpError(404, 'not found');
  // Set by Cloudflare's edge (a client can't override it).
  const ip = clientKey(request.headers.get('CF-Connecting-IP'));
  await rateLimit(env, 'RL_API', `ip:${ip}`);
  const route = POST_ROUTES.get(path);
  if (!route) throw new HttpError(404, 'not found');
  const body = await readJson(request);
  return route({ env, ctx, now, ip, body });
}

async function deleteSub(env, id) {
  await env.DB.batch([
    env.DB.prepare('DELETE FROM alerts WHERE sub_id = ?').bind(id),
    env.DB.prepare('DELETE FROM subscriptions WHERE id = ?').bind(id),
  ]);
}

// Pushes per run. Free-plan Workers may make 50 subrequests per invocation;
// if more are due, arm() sets the alarm to "now" and the next run continues.
const SEND_LIMIT = 40;

/** Sends every alert due by [now] (+EARLY_MS). Exported for tests. */
export async function sendDue(env, now = Date.now(), via = 'cron') {
  const t0 = Date.now();
  // Round-robin over subscriptions (every subscription's first due alert,
  // then every second one, ...): one subscription with many alerts due at
  // once can't fill whole runs and delay everyone else's alerts.
  const { results } = await env.DB.prepare(
    `SELECT a.sub_id, a.id, a.fire_at, a.title, a.body, a.url, a.attempts, s.endpoint, s.p256dh, s.auth
     FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY sub_id ORDER BY fire_at) AS rn
           FROM alerts WHERE fire_at <= ?1) a
     JOIN subscriptions s ON s.id = a.sub_id
     ORDER BY a.rn, a.fire_at LIMIT ${SEND_LIMIT}`,
  ).bind(now + EARLY_MS).all();
  const queryMs = Date.now() - t0;
  const stats = { due: results.length, sent: 0, expired: 0, failed: 0, queryMs, via };
  const deadSubs = new Set();
  // Subscriptions whose push just failed: their other due alerts this run
  // count as a failed try without another request to the push service.
  const failingSubs = new Set();
  const log = [];
  // Collected and written in one D1 batch at the end (a few statements in
  // total, however many alerts were due at the same time).
  const deliveries = [];
  const done = []; // sent, or given up
  const retry = [];
  for (const row of results) {
    if (deadSubs.has(row.sub_id)) continue;
    // Keyed by fire_at too: if the app re-schedules this alert id while the
    // push is in flight, the new row is neither deleted nor marked.
    const key = { s: row.sub_id, i: row.id, f: row.fire_at };
    const giveUp = row.attempts + 1 >= 5 || now - row.fire_at > 6 * 3600 * 1000;
    if (failingSubs.has(row.sub_id)) {
      stats.failed++;
      (giveUp ? done : retry).push(key);
      continue;
    }
    let status = 0;
    const p0 = Date.now();
    try { status = await pushTo(row, row, env); } catch (e) { console.error('push error', e); }
    const sentAt = Date.now();
    const pushMs = sentAt - p0;
    log.push({ sub: row.sub_id.slice(0, 8), host: hostOf(row.endpoint), lagMs: sentAt - row.fire_at, pushMs, status });
    deliveries.push({ s: row.sub_id, a: row.id, f: row.fire_at, t: sentAt, st: status, p: pushMs });
    if (status >= 200 && status < 300) {
      stats.sent++;
      done.push(key);
    } else if (status === 404 || status === 410) {
      stats.expired++;
      deadSubs.add(row.sub_id);
    } else {
      stats.failed++;
      // An HTTP error (not a network error / bad payload, status 0) applies
      // to the whole subscription: don't hammer the push service with its
      // other due alerts in this run.
      if (status) failingSubs.add(row.sub_id);
      // Retry on the next run; give up after 5 tries or 6 hours.
      (giveUp ? done : retry).push(key);
    }
  }
  const keys = "SELECT json_extract(value, '$.s'), json_extract(value, '$.i'), json_extract(value, '$.f') FROM json_each(?1)";
  const stmts = [];
  if (done.length) {
    stmts.push(env.DB.prepare(`DELETE FROM alerts WHERE (sub_id, id, fire_at) IN (${keys})`).bind(JSON.stringify(done)));
  }
  if (retry.length) {
    stmts.push(env.DB.prepare(`UPDATE alerts SET attempts = attempts + 1 WHERE (sub_id, id, fire_at) IN (${keys})`)
      .bind(JSON.stringify(retry)));
  }
  if (deadSubs.size) {
    const dead = JSON.stringify([...deadSubs]);
    stmts.push(env.DB.prepare('DELETE FROM alerts WHERE sub_id IN (SELECT value FROM json_each(?1))').bind(dead));
    stmts.push(env.DB.prepare('DELETE FROM subscriptions WHERE id IN (SELECT value FROM json_each(?1))').bind(dead));
  }
  if (stmts.length) await env.DB.batch(stmts);
  if (deliveries.length) {
    // Diagnostics only: kept out of the batch so a log failure can't undo the deletes.
    await env.DB.prepare(
      `INSERT INTO deliveries (sub_id, alert_id, fire_at, sent_at, status, push_ms, via)
       SELECT json_extract(value, '$.s'), json_extract(value, '$.a'), json_extract(value, '$.f'),
         json_extract(value, '$.t'), json_extract(value, '$.st'), json_extract(value, '$.p'), ?2 FROM json_each(?1)`,
    ).bind(JSON.stringify(deliveries), via).run().catch(() => {});
  }
  if (log.length) console.log('sent', JSON.stringify({ ...stats, log }));
  return stats;
}

function hostOf(endpoint) {
  try { return new URL(endpoint).host; } catch { return '?'; }
}

/** Earliest pending fire_at (ms) or null. */
async function nextFireAt(env) {
  // Alerts of a deleted subscription are never sent: ignore them here, or
  // the alarm would keep firing for an alert sendDue() can't pick up.
  const row = await env.DB.prepare(
    'SELECT MIN(a.fire_at) AS t FROM alerts a JOIN subscriptions s ON s.id = a.sub_id WHERE a.attempts < 5',
  ).first();
  return row && row.t != null ? Number(row.t) : null;
}

/**
 * Single global Durable Object that owns the send loop: its alarm fires at
 * the next alert's time (minus EARLY_MS). Failed sends retry after 30 s.
 * All sending runs inside this one object, so the alarm and the cron
 * watchdog can't send the same alert twice.
 */
export class AlertScheduler {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.running = null;
    this.lastPrune = null; // loaded from storage (survives eviction)
    // Earliest alarm time asked for by /rearm while arm() was waiting on D1
    // (its alert may have been committed after arm()'s query read the table).
    this.hint = null;
  }

  async fetch(request) {
    const path = new URL(request.url).pathname;
    if (path === '/rearm') {
      const hint = Number(new URL(request.url).searchParams.get('earliest'));
      await (Number.isFinite(hint) && hint > 0 ? this.armEarlier(hint) : this.arm());
      return new Response('ok');
    }
    if (path === '/tick') {
      const stats = await this.run('cron');
      return Response.json(stats);
    }
    return new Response('not found', { status: 404 });
  }

  async alarm() {
    await this.run('alarm');
  }

  /** Sends due alerts (serialised) and re-arms the alarm. */
  async run(via) {
    if (this.running) return this.running;
    this.running = (async () => {
      try {
        const stats = await sendDue(this.env, Date.now(), via);
        await this.arm(stats.failed > 0 ? Date.now() + 30_000 : null);
        await this.maintain();
        return stats;
      } finally {
        this.running = null;
      }
    })();
    return this.running;
  }

  /** Hourly: delivery-log retention and subscription pruning (cron or not). */
  async maintain(now = Date.now()) {
    if (this.lastPrune == null) this.lastPrune = (await this.state.storage.get('lastPrune')) || 0;
    if (now - this.lastPrune < HOUR_MS) return false;
    this.lastPrune = now;
    await this.state.storage.put('lastPrune', now);
    await pruneLog(this.env);
    try { await pruneSubscriptions(this.env, now); } catch (e) { console.error('prune failed', e); }
    return true;
  }

  /**
   * A new alert fires at [fireAt]: move the alarm earlier if needed. The
   * alarm always points at (or before) the earliest pending alert, so no
   * D1 query is needed here.
   */
  async armEarlier(fireAt) {
    const at = Math.max(fireAt - EARLY_MS, Date.now());
    if (this.hint == null || at < this.hint) this.hint = at;
    const current = await this.state.storage.getAlarm();
    if (current == null || at < current) await this.state.storage.setAlarm(at);
  }

  async arm(retryAt = null) {
    this.hint = null;
    const next = await nextFireAt(this.env);
    let at = next == null ? null : Math.max(next - EARLY_MS, Date.now());
    if (retryAt != null && next != null && next - EARLY_MS <= Date.now()) at = retryAt;
    // An alert added while we queried D1 may be missing from [next]: never
    // set the alarm later than what /rearm asked for meanwhile.
    if (this.hint != null && (at == null || this.hint < at)) at = this.hint;
    const current = await this.state.storage.getAlarm();
    if (at == null) {
      if (current != null) await this.state.storage.deleteAlarm();
      return;
    }
    if (current !== at) await this.state.storage.setAlarm(at);
  }
}

async function pruneLog(env) {
  await env.DB.prepare('DELETE FROM deliveries WHERE sent_at < ?').bind(Date.now() - LOG_RETENTION_MS).run().catch(() => {});
}

export default {
  async fetch(request, env, ctx) {
    const cors = corsHeaders(request, env);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
    // CORS only stops browsers from READING responses; refuse other sites'
    // pages outright so visitors' browsers can't be used to call the API.
    if (!originAllowed(request.headers.get('Origin'), env, request.method)) return json({ error: 'origin not allowed' }, 403, cors);
    try {
      return json(await handle(request, env, ctx), 200, cors);
    } catch (e) {
      const known = e instanceof HttpError;
      if (!known) console.error('internal error', e);
      // Unexpected errors (D1, crypto) never leak their message to clients.
      return json({ error: known ? e.message : 'internal error' }, known ? e.status : 500, cors);
    }
  },

  async scheduled(controller, env, ctx) {
    // Watchdog: run the send loop inside the scheduler (re-arms its alarm).
    // Without the Durable Object binding, send directly (old behaviour).
    const work = env.SCHEDULER
      ? env.SCHEDULER.get(env.SCHEDULER.idFromName('global')).fetch('https://scheduler/tick', { method: 'POST' })
          .then((r) => r.json())
      : sendDue(env, Date.now(), 'cron');
    ctx.waitUntil(
      work
        .then((s) => { if (s && s.due) console.log('cron', JSON.stringify(s)); })
        .catch((e) => console.error('cron failed', e))
        // With the scheduler, its run() does the hourly maintenance.
        .then(() => (!env.SCHEDULER && new Date().getUTCMinutes() === 0
          ? Promise.all([pruneLog(env), pruneSubscriptions(env)]) : null))
        .catch((e) => console.error('maintenance failed', e)),
    );
  },
};
