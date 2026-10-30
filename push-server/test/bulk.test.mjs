// Bulk scheduling tests against a real local D1 (Miniflare via wrangler's
// getPlatformProxy, in memory) — no Cloudflare account needed.
//   npm test
import test, { before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import nodeCrypto from 'node:crypto';
import { getPlatformProxy } from 'wrangler';
import worker, { sendDue, AlertScheduler, clientKey, pruneSubscriptions, touchStatements, resetCapPruneThrottle } from '../src/index.js';

const MOCK = 9922;
let proxy;
let env;
let queries; // D1 statements executed (prepare().run/first/all + each batch statement)
let pushes;
let mock;

function countingDb(db) {
  return {
    prepare(sql) {
      const stmt = db.prepare(sql);
      const wrap = (s) => ({
        bind: (...a) => wrap(s.bind(...a)),
        first: (...a) => { queries++; return s.first(...a); },
        run: (...a) => { queries++; return s.run(...a); },
        all: (...a) => { queries++; return s.all(...a); },
        raw: s,
      });
      return wrap(stmt);
    },
    batch(stmts) { queries += stmts.length; return db.batch(stmts.map((s) => s.raw)); },
    exec: (sql) => db.exec(sql),
  };
}

const sqlStatements = (text) => text.split('\n').map((l) => l.replace(/--.*$/, '')).join(' ')
  .split(';').map((x) => x.trim()).filter(Boolean);
// migrations/*.sql in order, as `wrangler d1 migrations apply` runs them.
function migrationStatements() {
  const dir = new URL('../migrations/', import.meta.url);
  return fs.readdirSync(dir).filter((f) => f.endsWith('.sql')).sort()
    .flatMap((f) => sqlStatements(fs.readFileSync(new URL(f, dir), 'utf8')));
}

before(async () => {
  proxy = await getPlatformProxy({ persist: false });
  const schema = fs.readFileSync(new URL('../schema.sql', import.meta.url), 'utf8')
    .split('\n').map((l) => l.replace(/--.*$/, '')).join(' ')
    .split(';').map((s) => s.trim()).filter(Boolean);
  for (const s of schema) await proxy.env.DB.prepare(s).run();
  for (const s of migrationStatements()) await proxy.env.DB.prepare(s).run();
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const pub = Buffer.from(await crypto.subtle.exportKey('raw', pair.publicKey)).toString('base64url');
  env = {
    DB: countingDb(proxy.env.DB),
    VAPID_PUBLIC_KEY: pub,
    VAPID_PRIVATE_JWK: JSON.stringify(await crypto.subtle.exportKey('jwk', pair.privateKey)),
    EXTRA_PUSH_HOSTS: `127.0.0.1:${MOCK}`,
    ALLOWED_ORIGINS: 'https://archerage-farm-timer.pages.dev,https://artimer.win,https://www.artimer.win',
    // no SCHEDULER binding: rearm() is a no-op here (tested separately below)
  };
  mock = http.createServer((req, res) => {
    req.resume();
    req.on('end', () => { pushes.push(req.url); res.writeHead(req.url.endsWith('/gone') ? 410 : req.url.endsWith('/fail') ? 500 : 201); res.end(); });
  });
  await new Promise((r) => mock.listen(MOCK, '127.0.0.1', r));
});

after(async () => {
  mock.close();
  await proxy.dispose();
});

beforeEach(async () => {
  queries = 0;
  pushes = [];
  await proxy.env.DB.prepare('DELETE FROM alerts').run();
  await proxy.env.DB.prepare('DELETE FROM subscriptions').run();
  await proxy.env.DB.prepare('DELETE FROM deliveries').run();
});

const ctx = { waitUntil() {} };
async function call(path, body, origin = 'https://artimer.win') {
  const req = new Request(`https://push.test${path}`, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { 'Content-Type': 'application/json', Origin: origin },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const res = await worker.fetch(req, env, ctx);
  return { status: res.status, body: await res.json(), cors: res.headers.get('access-control-allow-origin') };
}

async function subscribe(key = 'alice') {
  const ecdh = nodeCrypto.createECDH('prime256v1');
  ecdh.generateKeys();
  const r = await call('/subscribe', { subscription: {
    endpoint: `http://127.0.0.1:${MOCK}/push/${key}`,
    keys: { p256dh: ecdh.getPublicKey().toString('base64url'), auth: nodeCrypto.randomBytes(16).toString('base64url') },
  } });
  assert.equal(r.status, 200);
  queries = 0;
  return r.body.subscriptionId;
}

const inMin = (m) => new Date(Date.now() + m * 60_000).toISOString();
const alertsFor = (n, prefix = 't', fireAt = inMin(60)) => Array.from({ length: n }, (_, i) => [
  { id: `${prefix}${i}:1`, fireAt, title: `Item ${i} is ready!`, body: 'Harvest', url: 'https://artimer.win/' },
  { id: `${prefix}${i}:1:wither`, fireAt: inMin(120), title: `Item ${i} will wither soon!`, body: '' },
]).flat();
const count = async (sub) => (await proxy.env.DB.prepare('SELECT COUNT(*) AS n FROM alerts WHERE sub_id = ?').bind(sub).first('n'));

test('CORS allows pages.dev and the artimer.win custom domains', async () => {
  for (const o of ['https://archerage-farm-timer.pages.dev', 'https://artimer.win', 'https://www.artimer.win']) {
    assert.equal((await call('/health', undefined, o)).cors, o);
  }
  // Other sites get no Access-Control-Allow-Origin (and are refused, see below).
  assert.equal((await call('/health', undefined, 'https://evil.example')).cors, null);
});

test('50 timers (100 alerts) in ONE /schedule request with a constant number of D1 queries', async () => {
  const sub = await subscribe();
  const r = await call('/schedule', { subscriptionId: sub, alerts: alertsFor(50) });
  assert.equal(r.status, 200);
  assert.equal(r.body.scheduled, 100);
  assert.equal(await count(sub), 100);
  // requireSub + count + one bulk upsert (+ the first last_seen write),
  // independent of the number of alerts (free-plan D1 allows 50 queries per invocation).
  assert.equal(queries, 4);
  const row = await proxy.env.DB.prepare('SELECT * FROM alerts WHERE sub_id = ? AND id = ?').bind(sub, 't7:1').first();
  assert.equal(row.title, 'Item 7 is ready!');
  assert.equal(row.url, 'https://artimer.win/');
  assert.equal(row.attempts, 0);
  const w = await proxy.env.DB.prepare('SELECT url FROM alerts WHERE sub_id = ? AND id = ?').bind(sub, 't7:1:wither').first();
  assert.equal(w.url, null);
});

test('re-scheduling the same ids upserts (also duplicates inside one request)', async () => {
  const sub = await subscribe();
  await call('/schedule', { subscriptionId: sub, alerts: alertsFor(3) });
  const moved = { id: 't1:1', fireAt: inMin(5), title: 'moved', body: '' };
  const r = await call('/schedule', { subscriptionId: sub, alerts: [{ ...moved, title: 'first' }, moved] });
  assert.equal(r.status, 200);
  assert.equal(await count(sub), 6);
  const row = await proxy.env.DB.prepare('SELECT title FROM alerts WHERE sub_id = ? AND id = ?').bind(sub, 't1:1').first();
  assert.equal(row.title, 'moved');
});

test('/schedule with cancel replaces a harvested cycle in one request', async () => {
  const sub = await subscribe();
  await call('/schedule', { subscriptionId: sub, alerts: alertsFor(2) });
  const r = await call('/schedule', {
    subscriptionId: sub,
    cancel: ['t0:1', 't0:1:wither'],
    alerts: [{ id: 't0:2', fireAt: inMin(90), title: 'cycle 2', body: '' }],
  });
  assert.deepEqual(r.body, { scheduled: 1, cancelled: 2 });
  const ids = (await proxy.env.DB.prepare('SELECT id FROM alerts WHERE sub_id = ? ORDER BY id').bind(sub).all()).results.map((x) => x.id);
  assert.deepEqual(ids, ['t0:2', 't1:1', 't1:1:wither']);
});

test('old clients: /schedule without cancel and /cancel with ids still work; bulk cancel is one statement', async () => {
  const sub = await subscribe();
  await call('/schedule', { subscriptionId: sub, alerts: alertsFor(40) });
  queries = 0;
  const ids = alertsFor(40).map((a) => a.id);
  const r = await call('/cancel', { subscriptionId: sub, ids });
  assert.equal(r.body.cancelled, 80);
  assert.equal(queries, 2); // requireSub + one DELETE
  assert.equal(await count(sub), 0);
});

test('validation: bad alerts, too many per request, per-subscription cap', async () => {
  const sub = await subscribe();
  assert.equal((await call('/schedule', { subscriptionId: sub, alerts: 'nope' })).status, 400);
  assert.equal((await call('/schedule', { subscriptionId: sub, alerts: [{ id: 'x', title: 'x', fireAt: 'garbage' }] })).status, 400);
  assert.equal((await call('/schedule', { subscriptionId: sub, alerts: [], cancel: 'x' })).status, 400);
  assert.equal((await call('/schedule', { subscriptionId: sub, alerts: alertsFor(151) })).status, 400); // 302 alerts
  assert.equal((await call('/cancel', { subscriptionId: sub, ids: Array.from({ length: 301 }, (_, i) => `i${i}`) })).status, 400);
  assert.equal((await call('/schedule', { subscriptionId: 'x'.repeat(20), alerts: alertsFor(1) })).status, 404);
  assert.equal(await count(sub), 0); // nothing half-written

  // fill to the 300 cap in two bulk requests
  assert.equal((await call('/schedule', { subscriptionId: sub, alerts: alertsFor(100, 'a') })).status, 200);
  assert.equal((await call('/schedule', { subscriptionId: sub, alerts: alertsFor(50, 'b') })).status, 200);
  assert.equal(await count(sub), 300);
  assert.equal((await call('/schedule', { subscriptionId: sub, alerts: [{ id: 'new', fireAt: inMin(1), title: 'x' }] })).status, 400);
  // updating existing ids at the cap is fine, and so is replacing a cancelled one
  assert.equal((await call('/schedule', { subscriptionId: sub, alerts: alertsFor(5, 'a') })).status, 200);
  assert.equal((await call('/schedule', { subscriptionId: sub, cancel: ['a0:1'], alerts: [{ id: 'new', fireAt: inMin(1), title: 'x' }] })).status, 200);
  assert.equal(await count(sub), 300);
});

test('/sync with 300 alerts is a constant number of statements', async () => {
  const sub = await subscribe();
  await call('/schedule', { subscriptionId: sub, alerts: alertsFor(10, 'old') });
  queries = 0;
  const r = await call('/sync', { subscriptionId: sub, alerts: alertsFor(150) });
  assert.equal(r.body.scheduled, 300);
  assert.equal(queries, 3); // requireSub + DELETE + one bulk upsert
  assert.equal(await count(sub), 300);
});

test('/sync writes only what changed: a repeated identical /sync writes no alert rows', async () => {
  const sub = await subscribe();
  const alerts = alertsFor(100);
  assert.equal((await call('/sync', { subscriptionId: sub, alerts })).status, 200);
  const changes = [];
  const e = { ...env, DB: { ...env.DB, batch: async (stmts) => {
    const res = await env.DB.batch(stmts);
    changes.push(...res.map((r) => r.meta.changes));
    return res;
  } } };
  const again = await raw('/sync', { headers: jsonHeaders, body: JSON.stringify({ subscriptionId: sub, alerts }) }, e);
  assert.equal(again.status, 200);
  assert.deepEqual(changes, [0, 0]); // DELETE of dropped ids + upsert of changed rows
  // One alert moved and one dropped: exactly those rows change.
  changes.length = 0;
  const next = alerts.slice(1).map((a, i) => (i === 0 ? { ...a, fireAt: inMin(90) } : a));
  await raw('/sync', { headers: jsonHeaders, body: JSON.stringify({ subscriptionId: sub, alerts: next }) }, e);
  assert.deepEqual(changes, [1, 1]);
  assert.equal(await count(sub), 199);
  const moved = await proxy.env.DB.prepare('SELECT fire_at FROM alerts WHERE sub_id = ? AND id = ?').bind(sub, next[0].id).first('fire_at');
  assert.equal(moved, Date.parse(next[0].fireAt));
});

test('sendDue: many alerts due at once are sent with a few D1 statements, in runs of 40', async () => {
  const sub = await subscribe('bob');
  const due = new Date(Date.now() - 1000).toISOString();
  await call('/schedule', { subscriptionId: sub, alerts: alertsFor(45, 'd', due).filter((a) => !a.id.endsWith('wither')) });
  queries = 0;
  const s1 = await sendDue(env, Date.now(), 'alarm');
  assert.equal(s1.sent, 40);
  assert.equal(pushes.length, 40);
  assert.ok(queries <= 3, `queries ${queries}`); // select + delete batch + delivery log
  assert.equal(await count(sub), 5);
  const s2 = await sendDue(env, Date.now(), 'alarm');
  assert.equal(s2.sent, 5);
  assert.equal(await count(sub), 0);
  const logged = await proxy.env.DB.prepare('SELECT COUNT(*) AS n FROM deliveries WHERE via = ?').bind('alarm').first('n');
  assert.equal(logged, 45);
});

test('sendDue: an expired subscription (410) is deleted with its alerts', async () => {
  const sub = await subscribe('gone');
  const due = new Date(Date.now() - 1000).toISOString();
  await call('/schedule', { subscriptionId: sub, alerts: alertsFor(3, 'g', due) });
  const s = await sendDue(env, Date.now(), 'cron');
  assert.equal(s.expired, 1);
  assert.equal(pushes.length, 1); // stops after the first 410
  assert.equal(await count(sub), 3 - 3);
  assert.equal((await call('/schedule', { subscriptionId: sub, alerts: [] })).status, 404);
});

test('scheduler armEarlier only moves the alarm earlier, without D1', async () => {
  let alarm = null;
  const storage = { getAlarm: async () => alarm, setAlarm: async (t) => { alarm = t; }, deleteAlarm: async () => { alarm = null; } };
  const noDb = { prepare() { throw new Error('no D1 expected'); } };
  const s = new AlertScheduler({ storage }, { DB: noDb });
  const t = Date.now() + 3600_000;
  await s.armEarlier(t);
  assert.equal(alarm, t - 1000);
  await s.armEarlier(t + 60_000); // later: unchanged
  assert.equal(alarm, t - 1000);
  await s.armEarlier(t - 60_000); // earlier: moved
  assert.equal(alarm, t - 61_000);
  const r = await s.fetch(new Request(`https://scheduler/rearm?earliest=${t - 120_000}`, { method: 'POST' }));
  assert.equal(r.status, 200);
  assert.equal(alarm, t - 121_000);
});

// ---- Security hardening ---------------------------------------------------

// POSTs carry the app's Origin unless the test passes its own (or origin: null).
async function raw(path, { method = 'POST', body, headers = {}, origin = 'https://artimer.win' } = {}, e = env) {
  const h = origin && method === 'POST' && !('Origin' in headers) ? { Origin: origin, ...headers } : headers;
  const req = new Request(`https://push.test${path}`, { method, headers: h, body });
  const res = await worker.fetch(req, e, ctx);
  return { status: res.status, body: await res.json().catch(() => null), headers: res.headers };
}
const jsonHeaders = { 'Content-Type': 'application/json' };
function keyPair() {
  const ecdh = nodeCrypto.createECDH('prime256v1');
  ecdh.generateKeys();
  return { p256dh: ecdh.getPublicKey().toString('base64url'), auth: nodeCrypto.randomBytes(16).toString('base64url') };
}

test('security: other origins are refused (403); a POST without Origin is refused too', async () => {
  const sub = await subscribe();
  const evil = await call('/schedule', { subscriptionId: sub, alerts: alertsFor(1) }, 'https://evil.example');
  assert.equal(evil.status, 403);
  assert.equal(evil.cors, null);
  assert.equal(await count(sub), 0);
  assert.equal((await call('/health', undefined, 'null')).status, 403);
  // Browsers always send Origin on a cross-origin POST; a bare script does not.
  const body = JSON.stringify({ subscriptionId: sub, alerts: alertsFor(1) });
  const cli = await raw('/schedule', { headers: jsonHeaders, body, origin: null });
  assert.equal(cli.status, 403);
  assert.equal(await count(sub), 0);
  // GETs (health check, VAPID key) still work without Origin.
  assert.equal((await raw('/health', { method: 'GET', origin: null })).status, 200);
  // ALLOWED_ORIGINS = "*" (local dev) accepts anything.
  const open = await raw('/schedule', { headers: jsonHeaders, body, origin: null }, { ...env, ALLOWED_ORIGINS: '*' });
  assert.equal(open.status, 200);
  // preflight from another origin gets no allow-origin
  const pre = await raw('/schedule', { method: 'OPTIONS', headers: { Origin: 'https://evil.example' } });
  assert.equal(pre.headers.get('access-control-allow-origin'), null);
});

test('security: POST must be a JSON object with a JSON content type, size-capped', async () => {
  const sub = await subscribe();
  const body = JSON.stringify({ subscriptionId: sub, alerts: alertsFor(1) });
  // text/plain is a CORS "simple request" (no preflight): refused.
  assert.equal((await raw('/schedule', { headers: { 'Content-Type': 'text/plain' }, body })).status, 415);
  assert.equal((await raw('/schedule', { body })).status, 415);
  for (const b of ['null', '[]', '"x"', '42']) {
    const r = await raw('/schedule', { headers: jsonHeaders, body: b });
    assert.equal(r.status, 400, b);
  }
  const big = JSON.stringify({ subscriptionId: sub, pad: 'x'.repeat(600 * 1024) });
  assert.equal((await raw('/schedule', { headers: jsonHeaders, body: big })).status, 413);
  assert.equal(await count(sub), 0);
});

test('security: malformed alerts are 400s, never 500s', async () => {
  const sub = await subscribe();
  for (const alerts of [[null], [42], ['x'], [[1]], [{ id: {}, title: 'x', fireAt: inMin(5) }],
    [{ id: 'a', title: { x: 1 }, fireAt: inMin(5) }], [{ id: 'a', title: 'x', fireAt: 1e15 }],
    [{ id: 'a', title: 'x', fireAt: new Date(Date.now() - 2 * 86400_000).toISOString() }]]) {
    const r = await call('/schedule', { subscriptionId: sub, alerts });
    assert.equal(r.status, 400, JSON.stringify(alerts));
  }
  assert.equal((await call('/schedule', { subscriptionId: 42, alerts: [] })).status, 400);
  assert.equal(await count(sub), 0);
});

test('security: malformed subscription ids are 404 without a D1 query', async () => {
  queries = 0;
  for (const id of ['x'.repeat(48), "' OR 1=1 --", 'A'.repeat(48), '0'.repeat(47)]) {
    assert.equal((await call('/cancel', { subscriptionId: id, ids: ['a'] })).status, 404);
  }
  assert.equal(queries, 0);
});

test('security: SQL metacharacters in ids and text are stored as plain data', async () => {
  const sub = await subscribe();
  const id = "x'); DROP TABLE alerts; --";
  const r = await call('/schedule', { subscriptionId: sub, alerts: [{ id, fireAt: inMin(5), title: "a' OR '1'='1", body: '"; --' }] });
  assert.equal(r.status, 200);
  const row = await proxy.env.DB.prepare('SELECT * FROM alerts WHERE sub_id = ? AND id = ?').bind(sub, id).first();
  assert.equal(row.title, "a' OR '1'='1");
  assert.equal((await call('/cancel', { subscriptionId: sub, ids: [id] })).body.cancelled, 1);
  assert.equal(await count(sub), 0);
});

test('security: notification click URLs are limited to the app origins', async () => {
  const sub = await subscribe();
  const urls = {
    js: 'javascript:alert(document.cookie)', data: 'data:text/html,<script>alert(1)</script>',
    evil: 'https://evil.example/phish', userinfo: 'https://artimer.win@evil.example/', http: 'http://artimer.win/',
    ok: 'https://artimer.win/', ok2: 'https://archerage-farm-timer.pages.dev/', num: 12,
  };
  const alerts = Object.entries(urls).map(([k, url]) => ({ id: k, fireAt: inMin(5), title: 't', url }));
  assert.equal((await call('/schedule', { subscriptionId: sub, alerts })).status, 200);
  const rows = Object.fromEntries((await proxy.env.DB.prepare('SELECT id, url FROM alerts WHERE sub_id = ?').bind(sub).all())
    .results.map((x) => [x.id, x.url]));
  assert.deepEqual(rows, { js: null, data: null, evil: null, userinfo: null, http: null, num: null,
    ok: 'https://artimer.win/', ok2: 'https://archerage-farm-timer.pages.dev/' });
});

test('security: knowing a push endpoint is not enough to take over its subscription', async () => {
  const endpoint = `http://127.0.0.1:${MOCK}/push/victim`;
  const victimKeys = keyPair();
  const a = await call('/subscribe', { subscription: { endpoint, keys: victimKeys } });
  assert.equal(a.status, 200);
  await call('/schedule', { subscriptionId: a.body.subscriptionId, alerts: alertsFor(2) });
  // Same endpoint + same keys (reinstalled app): same id.
  const again = await call('/subscribe', { subscription: { endpoint, keys: victimKeys } });
  assert.equal(again.body.subscriptionId, a.body.subscriptionId);
  // Same endpoint, other keys: a NEW id; the attacker never learns the old one.
  const b = await call('/subscribe', { subscription: { endpoint, keys: keyPair() } });
  assert.equal(b.status, 200);
  assert.notEqual(b.body.subscriptionId, a.body.subscriptionId);
  const row = await proxy.env.DB.prepare('SELECT p256dh FROM subscriptions WHERE endpoint = ?').bind(endpoint).first();
  assert.notEqual(row.p256dh, victimKeys.p256dh); // victim's keys are not silently re-bound to the old id
  assert.equal((await call('/cancel', { subscriptionId: a.body.subscriptionId, ids: [] })).status, 404);
});

function offCurve(p256dh) {
  const b = Buffer.from(p256dh, 'base64url');
  b[64] ^= 1; // y no longer matches x
  return b.toString('base64url');
}

test('security: /subscribe validates endpoint and keys', async () => {
  const k = keyPair();
  const bad = [
    { endpoint: 'https://evil.example/push', keys: k },
    { endpoint: 'https://fcm.googleapis.com:8443/fcm/send/x', keys: k },
    { endpoint: 'https://u:p@fcm.googleapis.com/fcm/send/x', keys: k },
    { endpoint: `https://fcm.googleapis.com/fcm/send/${'x'.repeat(2000)}`, keys: k },
    { endpoint: `http://127.0.0.1:${MOCK}/push/k1`, keys: { p256dh: 'AAAA', auth: k.auth } },
    { endpoint: `http://127.0.0.1:${MOCK}/push/k2`, keys: { p256dh: k.p256dh, auth: 'AAAA' } },
    { endpoint: `http://127.0.0.1:${MOCK}/push/k3`, keys: { p256dh: offCurve(k.p256dh), auth: k.auth } },
    { endpoint: `http://127.0.0.1:${MOCK}/push/k4`, keys: { p256dh: k.p256dh, auth: { x: 1 } } },
    { endpoint: ['x'], keys: k },
    null,
  ];
  for (const subscription of bad) {
    const r = await call('/subscribe', { subscription });
    assert.equal(r.status, 400, JSON.stringify(subscription).slice(0, 80));
  }
  assert.equal(await proxy.env.DB.prepare('SELECT COUNT(*) AS n FROM subscriptions').first('n'), 0);
});

test('security: MAX_SUBSCRIPTIONS caps new subscriptions', async () => {
  const e = { ...env, MAX_SUBSCRIPTIONS: '2' };
  const sub = (key, keys = keyPair()) => raw('/subscribe', { headers: jsonHeaders,
    body: JSON.stringify({ subscription: { endpoint: `http://127.0.0.1:${MOCK}/push/${key}`, keys } }) }, e);
  const keep = keyPair();
  assert.equal((await sub('c1', keep)).status, 200);
  assert.equal((await sub('c2')).status, 200);
  assert.equal((await sub('c3')).status, 503);
  assert.equal((await sub('c1', keep)).status, 200); // existing subscriber still fine
});

test('security: rate limiter binding returns 429 when exhausted', async () => {
  const keys = [];
  const deny = (name) => ({ limit: async ({ key }) => { keys.push(`${name}:${key}`); return { success: false }; } });
  const allow = { limit: async () => ({ success: true }) };
  const e1 = { ...env, RL_API: deny('api'), RL_STRICT: allow };
  const r1 = await raw('/schedule', { headers: { ...jsonHeaders, 'CF-Connecting-IP': '203.0.113.9' }, body: '{}' }, e1);
  assert.equal(r1.status, 429);
  assert.deepEqual(keys, ['api:ip:203.0.113.9']);
  const e2 = { ...env, RL_API: allow, RL_STRICT: deny('strict') };
  const r2 = await raw('/subscribe', { headers: { ...jsonHeaders, 'CF-Connecting-IP': '203.0.113.9' }, body: '{}' }, e2);
  assert.equal(r2.status, 429);
});

test('security: internal errors are not leaked to clients', async () => {
  const broken = { ...env, DB: { prepare() { throw new Error('D1_ERROR: no such table: subscriptions SQLITE_ERROR'); } } };
  const r = await raw('/cancel', { headers: jsonHeaders, body: JSON.stringify({ subscriptionId: 'a'.repeat(48), ids: [] }) }, broken);
  assert.equal(r.status, 500);
  assert.deepEqual(r.body, { error: 'internal error' });
  assert.equal(r.headers.get('cache-control'), 'no-store');
  assert.equal(r.headers.get('x-content-type-options'), 'nosniff');
});

test('security: a stored legacy javascript: url is not sent at push time', async () => {
  const sub = await subscribe('legacy');
  await proxy.env.DB.prepare('INSERT INTO alerts (sub_id, id, fire_at, title, body, url, attempts) VALUES (?, ?, ?, ?, ?, ?, 0)')
    .bind(sub, 'old', Date.now() - 1000, 't', '', 'javascript:alert(1)').run();
  let sent;
  const origFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => { sent = init; return new Response(null, { status: 201 }); };
  try {
    const s = await sendDue({ ...env, APP_URL: 'https://artimer.win/' }, Date.now(), 'cron');
    assert.equal(s.sent, 1);
  } finally {
    globalThis.fetch = origFetch;
  }
  assert.equal(sent.redirect, 'manual');
});

// ---- Second review --------------------------------------------------------

test('rate-limit key: IPv4 per address, IPv6 per /64 (one customer can\'t rotate addresses)', () => {
  assert.equal(clientKey('203.0.113.9'), '203.0.113.9');
  assert.equal(clientKey('::ffff:203.0.113.9'), '203.0.113.9');
  const a = clientKey('2001:db8:1:2:aaaa:bbbb:cccc:dddd');
  assert.equal(a, '2001:db8:1:2::/64');
  assert.equal(clientKey('2001:0db8:0001:0002::1'), a);
  assert.equal(clientKey('2001:db8:1:2::'), a);
  assert.notEqual(clientKey('2001:db8:1:3::1'), a);
  assert.equal(clientKey('::1'), '0:0:0:0::/64');
  assert.equal(clientKey(null), 'unknown');
  assert.equal(clientKey(''), 'unknown');
});

test('rate limiter is keyed by the IPv6 /64', async () => {
  const keys = [];
  const rec = { limit: async ({ key }) => { keys.push(key); return { success: true }; } };
  const e = { ...env, RL_API: rec, RL_STRICT: rec };
  for (const ip of ['2001:db8:1:2::1', '2001:db8:1:2:ffff::9']) {
    await raw('/cancel', { headers: { ...jsonHeaders, 'CF-Connecting-IP': ip }, body: '{}' }, e);
  }
  assert.deepEqual(keys, ['ip:2001:db8:1:2::/64', 'ip:2001:db8:1:2::/64']);
});

test('body cap holds without Content-Length (streamed body) and bad UTF-8 is a 400', async () => {
  const chunk = new TextEncoder().encode('x'.repeat(64 * 1024));
  let sent = 0;
  const stream = new ReadableStream({
    pull(c) { if (sent++ < 64) c.enqueue(chunk); else c.close(); }, // 4 MB if read whole
  });
  const appJson = { ...jsonHeaders, Origin: 'https://artimer.win' };
  const req = new Request('https://push.test/cancel', { method: 'POST', headers: appJson, body: stream, duplex: 'half' });
  const res = await worker.fetch(req, env, ctx);
  assert.equal(res.status, 413);
  assert.ok(sent < 64, `read ${sent} chunks`);
  const bad = new Request('https://push.test/cancel', { method: 'POST', headers: appJson, body: new Uint8Array([0x7b, 0xff, 0x7d]) });
  assert.equal((await worker.fetch(bad, env, ctx)).status, 400);
});

test('sendDue: round-robin, so one subscription with many due alerts can\'t delay others', async () => {
  const big = await subscribe('big');
  const small = await subscribe('small');
  const early = new Date(Date.now() - 5000).toISOString();
  const later = new Date(Date.now() - 1000).toISOString();
  await call('/schedule', { subscriptionId: big, alerts: alertsFor(60, 'b', early).filter((a) => !a.id.endsWith('wither')) });
  await call('/schedule', { subscriptionId: small, alerts: [{ id: 's', fireAt: later, title: 'mine', body: '' }] });
  const s = await sendDue(env, Date.now(), 'alarm');
  assert.equal(s.sent, 40);
  assert.ok(pushes.some((u) => u.endsWith('/small')), 'small subscription served in the first run');
  assert.equal(await count(small), 0);
});

test('sendDue: a failing subscription gets one request per run; the rest count as failed tries', async () => {
  const sub = await subscribe('fail');
  const due = new Date(Date.now() - 1000).toISOString();
  await call('/schedule', { subscriptionId: sub, alerts: alertsFor(5, 'f', due).filter((a) => !a.id.endsWith('wither')) });
  const s = await sendDue(env, Date.now(), 'alarm');
  assert.equal(pushes.length, 1);
  assert.equal(s.failed, 5);
  const { results } = await proxy.env.DB.prepare('SELECT attempts FROM alerts WHERE sub_id = ?').bind(sub).all();
  assert.deepEqual(results.map((r) => r.attempts), [1, 1, 1, 1, 1]);
  for (let i = 0; i < 4; i++) await sendDue(env, Date.now(), 'alarm');
  assert.equal(await count(sub), 0); // given up after 5 tries
});

test('sendDue: an alert re-scheduled while its push is in flight is kept', async () => {
  const sub = await subscribe('race');
  const due = Date.now() - 1000;
  await call('/schedule', { subscriptionId: sub, alerts: [{ id: 'r', fireAt: due, title: 't', body: '' }] });
  const later = Date.now() + 3600_000;
  const origFetch = globalThis.fetch;
  globalThis.fetch = async () => {
    // The app moves the alert while the push is being delivered.
    await call('/schedule', { subscriptionId: sub, alerts: [{ id: 'r', fireAt: later, title: 't2', body: '' }] });
    return new Response(null, { status: 201 });
  };
  try {
    assert.equal((await sendDue(env, Date.now(), 'alarm')).sent, 1);
  } finally {
    globalThis.fetch = origFetch;
  }
  const row = await proxy.env.DB.prepare('SELECT fire_at, title FROM alerts WHERE sub_id = ? AND id = ?').bind(sub, 'r').first();
  assert.equal(row.fire_at, later);
  assert.equal(row.title, 't2');
});

test('scheduler: a /rearm that arrives while arm() queries D1 is not overwritten', async () => {
  let alarm = null;
  const storage = { getAlarm: async () => alarm, setAlarm: async (t) => { alarm = t; }, deleteAlarm: async () => { alarm = null; } };
  let release;
  const gate = new Promise((r) => { release = r; });
  // D1 answers "no pending alerts" (its read happened before the new insert).
  const db = { prepare: () => ({ first: async () => { await gate; return { t: null }; } }) };
  const s = new AlertScheduler({ storage }, { DB: db });
  const armed = s.arm();
  const t = Date.now() + 600_000;
  await s.armEarlier(t); // the Worker inserted an alert and asked for t
  assert.equal(alarm, t - 1000);
  release();
  await armed;
  assert.equal(alarm, t - 1000, 'alarm kept for the new alert');
});

// ---- Idle-subscription expiry ---------------------------------------------

const H = 3600_000;
const D = 24 * H;
const DB = () => proxy.env.DB;
async function rawSub(id, { created, seen, alerts = 0 }) {
  await DB().prepare('INSERT INTO subscriptions (id, endpoint, p256dh, auth, created_at, last_seen) VALUES (?, ?, ?, ?, ?, ?)')
    .bind(id, `https://fcm.googleapis.com/fcm/send/${id}`, 'k', 'a', created, seen).run();
  for (let i = 0; i < alerts; i++) {
    await DB().prepare('INSERT INTO alerts (sub_id, id, fire_at, title) VALUES (?, ?, ?, ?)').bind(id, `a${i}`, Date.now() + 30 * D, 't').run();
  }
}
const ids = async () => (await DB().prepare('SELECT id FROM subscriptions ORDER BY id').all()).results.map((r) => r.id);
const subRow = (id) => DB().prepare('SELECT * FROM subscriptions WHERE id = ?').bind(id).first();

test('migration 0001: adds last_seen, keeps every row, backfills to now (as active)', async () => {
  await DB().prepare('DROP TABLE subscriptions').run();
  await DB().prepare(`CREATE TABLE subscriptions (id TEXT PRIMARY KEY, endpoint TEXT NOT NULL UNIQUE,
    p256dh TEXT NOT NULL, auth TEXT NOT NULL, created_at INTEGER NOT NULL)`).run(); // v1 table
  const old = Date.now() - 100 * D;
  await DB().prepare('INSERT INTO subscriptions VALUES (?, ?, ?, ?, ?)').bind('old', 'https://x/1', 'k', 'a', old).run();
  await DB().prepare('INSERT INTO subscriptions VALUES (?, ?, ?, ?, ?)').bind('new', 'https://x/2', 'k', 'a', Date.now()).run();
  const t0 = Date.now();
  for (const st of migrationStatements()) await DB().prepare(st).run();
  const rows = (await DB().prepare('SELECT * FROM subscriptions ORDER BY id').all()).results;
  assert.equal(rows.length, 2);
  for (const r of rows) {
    assert.ok(r.last_seen >= t0 - 1000 && r.last_seen <= Date.now() + 1000, `last_seen ${r.last_seen}`);
    assert.ok(r.last_seen > r.created_at, 'counts as active');
  }
  // Nothing is pruned right after the upgrade, not even the 100-day-old one.
  assert.equal(await pruneSubscriptions(env, Date.now()), 0);
  assert.deepEqual(await ids(), ['new', 'old']);
  // A second run fails (wrangler records applied migrations so it never re-runs one).
  await assert.rejects(DB().prepare(migrationStatements()[0]).run());
});

test('pruning rules: 24 h unactivated, 3 days idle without alerts, 40 days regardless', async () => {
  const now = Date.now();
  await rawSub('fresh-unactivated', { created: now - 23 * H, seen: now - 23 * H });
  await rawSub('stale-unactivated', { created: now - 25 * H, seen: now - 25 * H });
  await rawSub('active-idle-2d', { created: now - 10 * D, seen: now - 2 * D });
  await rawSub('active-idle-4d', { created: now - 10 * D, seen: now - 4 * D });
  await rawSub('idle-4d-with-alerts', { created: now - 10 * D, seen: now - 4 * D, alerts: 2 });
  await rawSub('idle-39d-with-alerts', { created: now - 50 * D, seen: now - 39 * D, alerts: 1 });
  await rawSub('idle-41d-with-alerts', { created: now - 50 * D, seen: now - 41 * D, alerts: 3 });
  await rawSub('legacy-zero-seen', { created: now - 2 * H, seen: 0 }); // row written by pre-migration code
  const removed = await pruneSubscriptions(env, now);
  assert.equal(removed, 3);
  assert.deepEqual(await ids(), ['active-idle-2d', 'fresh-unactivated', 'idle-39d-with-alerts', 'idle-4d-with-alerts', 'legacy-zero-seen']);
  // The 41-day subscription's alerts went with it.
  assert.equal(await count('idle-41d-with-alerts'), 0);
  assert.equal(await count('idle-4d-with-alerts'), 2);
});

test('activity: last_seen is written on first alert and then at most hourly; never-used subs stay unactivated', async () => {
  const id = await subscribe('touch');
  const r0 = await subRow(id);
  assert.equal(r0.last_seen, r0.created_at); // brand new = unactivated
  // Calls without alerts don't activate it.
  assert.equal((await call('/sync', { subscriptionId: id, alerts: [] })).status, 200);
  assert.equal((await call('/cancel', { subscriptionId: id, ids: ['x'] })).status, 200);
  assert.equal((await subRow(id)).last_seen, r0.created_at);
  // Storing an alert activates it (in the same batch).
  assert.equal((await call('/schedule', { subscriptionId: id, alerts: alertsFor(1) })).status, 200);
  const r1 = await subRow(id);
  assert.ok(r1.last_seen > r1.created_at);
  // Within the hour: no extra write.
  queries = 0;
  await call('/cancel', { subscriptionId: id, ids: ['t0:1'] });
  assert.equal((await subRow(id)).last_seen, r1.last_seen);
  assert.equal(queries, 2); // requireSub + delete, no touch
  // An hour later any call refreshes it.
  await DB().prepare('UPDATE subscriptions SET created_at = ?, last_seen = ? WHERE id = ?').bind(Date.now() - 3 * H, Date.now() - 2 * H, id).run();
  await call('/cancel', { subscriptionId: id, ids: ['nothing'] });
  assert.ok((await subRow(id)).last_seen > Date.now() - 60_000);
  // Unit: the touch rules.
  const t = (sub, now, act) => touchStatements(env, { id: 'x', ...sub }, now, act).length;
  assert.equal(t({ created_at: 100, last_seen: 100 }, 5000, false), 0);
  assert.equal(t({ created_at: 100, last_seen: 100 }, 5000, true), 1);
  assert.equal(t({ created_at: 100, last_seen: 200 }, 200 + H - 1, true), 0);
  assert.equal(t({ created_at: 100, last_seen: 200 }, 200 + H, false), 1);
});

test('cap: a full server prunes idle subscriptions before answering 503', async () => {
  resetCapPruneThrottle();
  const e = { ...env, MAX_SUBSCRIPTIONS: '2' };
  const sub = (key) => raw('/subscribe', { headers: jsonHeaders,
    body: JSON.stringify({ subscription: { endpoint: `http://127.0.0.1:${MOCK}/push/${key}`, keys: keyPair() } }) }, e);
  const now = Date.now();
  await rawSub('junk1', { created: now - 2 * D, seen: now - 2 * D }); // never stored an alert
  await rawSub('real', { created: now - 9 * D, seen: now - 5 * H, alerts: 1 });
  const r = await sub('newcomer');
  assert.equal(r.status, 200);
  assert.deepEqual((await ids()).filter((i) => !/^[0-9a-f]{48}$/.test(i)), ['real']);
  // Still full with only live subscriptions: 503 (and no second prune within a minute).
  assert.equal((await sub('another')).status, 503);
  resetCapPruneThrottle();
});

test('a pruned subscription answers 404 and re-subscribing with the same browser subscription works', async () => {
  const ecdh = nodeCrypto.createECDH('prime256v1');
  ecdh.generateKeys();
  const subscription = { endpoint: `http://127.0.0.1:${MOCK}/push/again`,
    keys: { p256dh: ecdh.getPublicKey().toString('base64url'), auth: nodeCrypto.randomBytes(16).toString('base64url') } };
  const id1 = (await call('/subscribe', { subscription })).body.subscriptionId;
  await DB().prepare('UPDATE subscriptions SET created_at = ?1, last_seen = ?1 WHERE id = ?2').bind(Date.now() - 2 * D, id1).run();
  assert.equal(await pruneSubscriptions(env), 1);
  assert.equal((await call('/schedule', { subscriptionId: id1, alerts: alertsFor(1) })).status, 404);
  const id2 = (await call('/subscribe', { subscription })).body.subscriptionId;
  assert.notEqual(id2, id1);
  assert.equal((await call('/schedule', { subscriptionId: id2, alerts: alertsFor(1) })).status, 200);
  assert.equal(await count(id2), 2);
});

test('scheduler: hourly maintenance survives eviction; orphaned alerts never keep the alarm busy', async () => {
  const store = new Map();
  let alarm = null;
  const storage = { get: async (k) => store.get(k), put: async (k, v) => { store.set(k, v); },
    getAlarm: async () => alarm, setAlarm: async (t) => { alarm = t; }, deleteAlarm: async () => { alarm = null; } };
  const now = Date.now();
  await rawSub('stale', { created: now - 2 * D, seen: now - 2 * D });
  const s1 = new AlertScheduler({ storage }, env);
  assert.equal(await s1.maintain(now), true);
  assert.deepEqual(await ids(), []);
  assert.equal(await s1.maintain(now + 10 * 60_000), false);
  const s2 = new AlertScheduler({ storage }, env); // after eviction
  assert.equal(await s2.maintain(now + 30 * 60_000), false);
  assert.equal(await s2.maintain(now + H + 1), true);
  // An alert whose subscription is gone: not sent, cleaned up, no alarm loop.
  await DB().prepare('INSERT INTO alerts (sub_id, id, fire_at, title) VALUES (?, ?, ?, ?)').bind('gone', 'o', now - 1000, 't').run();
  await s2.arm();
  assert.equal(alarm, null);
  await pruneSubscriptions(env, now);
  assert.equal(await count('gone'), 0);
});

// ---- Write limits ---------------------------------------------------------

function recorder(deny = () => false) {
  const keys = [];
  const rl = (name) => ({ limit: async ({ key }) => { keys.push(`${name}:${key}`); return { success: !deny(`${name}:${key}`) }; } });
  return { keys, bindings: { RL_API: rl('api'), RL_STRICT: rl('strict'), RL_WRITE: rl('write') } };
}

test('write limits: /schedule, /sync and /cancel count per IP and per subscription id', async () => {
  const sub = await subscribe();
  const ip = { ...jsonHeaders, 'CF-Connecting-IP': '203.0.113.9' };
  for (const [path, extra] of [['/schedule', { alerts: alertsFor(1) }], ['/sync', { alerts: [] }], ['/cancel', { ids: ['x'] }]]) {
    const { keys, bindings } = recorder();
    const r = await raw(path, { headers: ip, body: JSON.stringify({ subscriptionId: sub, ...extra }) }, { ...env, ...bindings });
    assert.equal(r.status, 200, path);
    assert.deepEqual(keys, ['api:ip:203.0.113.9', 'write:wip:203.0.113.9', `write:wsub:${sub}`], path);
  }
  // Routes that don't write alerts don't use RL_WRITE.
  const { keys, bindings } = recorder();
  await raw('/unsubscribe', { headers: ip, body: JSON.stringify({ subscriptionId: sub }) }, { ...env, ...bindings });
  assert.deepEqual(keys, ['api:ip:203.0.113.9']);
});

test('write limits: an exhausted IP or subscription gets 429 before any D1 query', async () => {
  const sub = await subscribe();
  const ip = { ...jsonHeaders, 'CF-Connecting-IP': '198.51.100.7' };
  const body = JSON.stringify({ subscriptionId: sub, alerts: alertsFor(1) });
  for (const denied of ['write:wip:198.51.100.7', `write:wsub:${sub}`]) {
    const { bindings } = recorder((k) => k === denied);
    queries = 0;
    for (const path of ['/schedule', '/sync', '/cancel']) {
      const r = await raw(path, { headers: ip, body }, { ...env, ...bindings });
      assert.equal(r.status, 429, `${path} ${denied}`);
    }
    assert.equal(queries, 0, denied);
  }
  assert.equal(await count(sub), 0);
  // Another subscription from another IP is unaffected.
  const other = await subscribe('bob');
  const { bindings } = recorder((k) => k === `write:wsub:${sub}` || k === 'write:wip:198.51.100.7');
  const ok = await raw('/schedule', { headers: { ...jsonHeaders, 'CF-Connecting-IP': '192.0.2.1' },
    body: JSON.stringify({ subscriptionId: other, alerts: alertsFor(1) }) }, { ...env, ...bindings });
  assert.equal(ok.status, 200);
});

test('write limits: a malformed subscription id is not used as a limiter key', async () => {
  const { keys, bindings } = recorder();
  const r = await raw('/schedule', { headers: { ...jsonHeaders, 'CF-Connecting-IP': '192.0.2.5' },
    body: JSON.stringify({ subscriptionId: 'x'.repeat(5000), alerts: [] }) }, { ...env, ...bindings });
  assert.equal(r.status, 404);
  assert.deepEqual(keys, ['api:ip:192.0.2.5', 'write:wip:192.0.2.5']);
});

test('unknown POST paths are 404 after the per-IP limit, without reading the body', async () => {
  const { keys, bindings } = recorder();
  const r = await raw('/nope', { headers: { 'CF-Connecting-IP': '192.0.2.6' }, body: 'not json' }, { ...env, ...bindings });
  assert.equal(r.status, 404);
  assert.deepEqual(keys, ['api:ip:192.0.2.6']);
});

test('wrangler.toml declares the three rate-limit bindings with distinct namespaces', () => {
  const toml = fs.readFileSync(new URL('../wrangler.toml', import.meta.url), 'utf8');
  const blocks = [...toml.matchAll(/\[\[ratelimits\]\]\s*name = "(\w+)"\s*namespace_id = "(\d+)"[^\n]*\s*\[ratelimits\.simple\]\s*limit = (\d+)\s*period = (\d+)/g)]
    .map((m) => ({ name: m[1], ns: m[2], limit: Number(m[3]), period: Number(m[4]) }));
  assert.deepEqual(blocks.map((b) => b.name), ['RL_API', 'RL_STRICT', 'RL_WRITE']);
  assert.equal(new Set(blocks.map((b) => b.ns)).size, 3);
  for (const b of blocks) assert.ok(b.period === 10 || b.period === 60, b.name);
  const write = blocks.find((b) => b.name === 'RL_WRITE');
  assert.ok(write.limit >= 20 && write.limit <= 30);
  // The custom domain is attached (since the 2026-10-29 reopen), and workers.dev stays on.
  assert.match(toml, /^workers_dev = true$/m);
  assert.match(toml, /^routes\s*=\s*\[\s*\{ pattern = "push\.artimer\.win", custom_domain = true \},\s*\]/m);
});
