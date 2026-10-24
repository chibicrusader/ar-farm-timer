// End-to-end test against `wrangler dev` (local D1, no Cloudflare account):
// a mock push service receives, verifies (VAPID JWT) and decrypts pushes.
//   npm run test:e2e
import { spawn, execSync } from 'node:child_process';
import http from 'node:http';
import nodeCrypto from 'node:crypto';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import ece from 'http_ece';

const PORT = 8787;
const MOCK = 9911;
const BASE = `http://127.0.0.1:${PORT}`;
const devVars = fs.readFileSync(new URL('../.dev.vars', import.meta.url), 'utf8');
const vapidPublic = /VAPID_PUBLIC_KEY="([^"]+)"/.exec(devVars)[1];

// --- mock push service -----------------------------------------------------
const received = [];
const subs = {};
const mock = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', async () => {
    const key = req.url.split('/').pop();
    if (key === 'gone') { res.writeHead(410); res.end(); return; }
    const s = subs[key];
    const auth = req.headers.authorization || '';
    const m = /^vapid t=([^,]+), k=(.+)$/.exec(auth);
    try {
      assert.ok(m, 'vapid header');
      assert.equal(m[2], vapidPublic);
      const [h, c, sig] = m[1].split('.');
      const pub = await crypto.subtle.importKey('raw', Buffer.from(vapidPublic, 'base64url'), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
      assert.ok(await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, pub, Buffer.from(sig, 'base64url'), new TextEncoder().encode(`${h}.${c}`)), 'jwt signature');
      assert.equal(JSON.parse(Buffer.from(c, 'base64url')).aud, `http://127.0.0.1:${MOCK}`);
      assert.equal(req.headers['content-encoding'], 'aes128gcm');
      const plain = ece.decrypt(Buffer.concat(chunks), { version: 'aes128gcm', privateKey: s.ecdh, authSecret: s.auth });
      received.push({ key, payload: JSON.parse(plain.toString('utf8')), ttl: req.headers.ttl, urgency: req.headers.urgency, at: Date.now() });
      res.writeHead(201); res.end();
    } catch (e) {
      console.error('mock push rejected:', e.message);
      res.writeHead(400); res.end();
    }
  });
});
await new Promise((r) => mock.listen(MOCK, '127.0.0.1', r));

function newSub(key) {
  const ecdh = nodeCrypto.createECDH('prime256v1');
  ecdh.generateKeys();
  const auth = nodeCrypto.randomBytes(16);
  subs[key] = { ecdh, auth };
  return { endpoint: `http://127.0.0.1:${MOCK}/push/${key}`, keys: { p256dh: ecdh.getPublicKey().toString('base64url'), auth: auth.toString('base64url') } };
}

// --- worker ----------------------------------------------------------------
fs.rmSync(new URL('../.wrangler/state', import.meta.url), { recursive: true, force: true });
execSync('npx --no-install wrangler d1 execute DB --local --file schema.sql', { stdio: 'ignore', env: { ...process.env, WRANGLER_SEND_METRICS: 'false' } });
execSync('npx --no-install wrangler d1 migrations apply DB --local', { stdio: 'ignore', env: { ...process.env, WRANGLER_SEND_METRICS: 'false', CI: 'true' } });
const dev = spawn('npx', ['--no-install', 'wrangler', 'dev', '--local', '--test-scheduled', '--port', String(PORT), '--ip', '127.0.0.1',
  '--var', `EXTRA_PUSH_HOSTS:127.0.0.1:${MOCK}`, '--var', 'APP_URL:https://example.test/app/',
  '--var', 'ALLOWED_ORIGINS:https://example.test'],
{ env: { ...process.env, WRANGLER_SEND_METRICS: 'false' }, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
let log = '';
dev.stdout.on('data', (d) => { log += d; });
dev.stderr.on('data', (d) => { log += d; });

async function waitReady() {
  for (let i = 0; i < 120; i++) {
    try { const r = await fetch(`${BASE}/health`); if (r.ok) return; } catch { /* not yet */ }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error('wrangler dev did not start:\n' + log);
}
const post = async (path, body) => {
  const r = await fetch(BASE + path, { method: 'POST', headers: { 'Content-Type': 'application/json', Origin: 'https://example.test' }, body: JSON.stringify(body) });
  return { status: r.status, body: await r.json(), cors: r.headers.get('access-control-allow-origin') };
};
const cron = () => fetch(`${BASE}/__scheduled?cron=*+*+*+*+*`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let failed = false;
try {
  await waitReady();
  const health = await (await fetch(`${BASE}/health`)).json();
  assert.equal(health.ok, true);
  const key = await (await fetch(`${BASE}/vapid-public-key`)).json();
  assert.equal(key.publicKey, vapidPublic);

  // CORS preflight
  const pre = await fetch(`${BASE}/schedule`, { method: 'OPTIONS', headers: { Origin: 'https://example.test' } });
  assert.equal(pre.status, 204);

  // reject non-push hosts
  assert.equal((await post('/subscribe', { subscription: { endpoint: 'https://evil.example/x', keys: { p256dh: 'a', auth: 'b' } } })).status, 400);

  const sub = await post('/subscribe', { subscription: newSub('alice') });
  assert.equal(sub.status, 200);
  const id = sub.body.subscriptionId;
  assert.ok(id.length >= 32);
  // same endpoint -> same id
  assert.equal((await post('/subscribe', { subscription: { ...newSubKeepKeys('alice') } })).body.subscriptionId, id);

  // immediate test push
  const t = await post('/test', { subscriptionId: id });
  assert.equal(t.body.pushStatus, 201);
  assert.equal(received.at(-1).payload.notification.title, 'AR Farm Timer test alert');

  // schedule: one due, one future, one cancelled before its time.
  // Due alerts go out via the scheduler alarm, without waiting for cron.
  const past = new Date(Date.now() - 1000).toISOString();
  const future = new Date(Date.now() + 3600_000).toISOString();
  const soon = new Date(Date.now() + 4000).toISOString();
  const before = received.length;
  const sch = await post('/schedule', { subscriptionId: id, alerts: [
    { id: 'rice:1', fireAt: past, title: 'Rice is ready!', body: 'Harvest 40× Rice at Solzreed.' },
    { id: 'apple:2', fireAt: future, title: 'Apple is ready!', body: '' },
    { id: 'goat:3', fireAt: soon, title: 'Goat is ready!', body: '' },
  ] });
  assert.equal(sch.body.scheduled, 3);
  assert.equal((await post('/cancel', { subscriptionId: id, ids: ['goat:3'] })).body.cancelled, 1);
  await sleep(6000);
  const got = received.slice(before);
  assert.deepEqual(got.map((g) => g.payload.notification.title), ['Rice is ready!']);
  assert.equal(got[0].payload.web_push, 8030);
  assert.equal(got[0].payload.notification.navigate, 'https://example.test/app/');
  assert.equal(got[0].ttl, String(6 * 3600));
  assert.equal(got[0].urgency, 'high');
  // sent alerts are removed: a cron (watchdog) run sends nothing more
  await cron(); await sleep(1000);
  assert.equal(received.length, before + 1);

  // precision: an alert due in 3 s arrives within ~1.5 s of its time (no cron needed)
  const lags = [];
  for (const delay of [3000, 5000]) {
    const fireAt = Date.now() + delay;
    const n0 = received.length;
    await post('/schedule', { subscriptionId: id, alerts: [{ id: `p:${delay}`, fireAt: new Date(fireAt).toISOString(), title: `P${delay}` }] });
    for (let i = 0; i < 100 && received.length === n0; i++) await sleep(100);
    assert.equal(received.length, n0 + 1, 'precision alert received');
    lags.push(received.at(-1).at - fireAt);
  }
  console.log('alarm lag ms (received - fireAt):', lags.join(', '));
  for (const l of lags) assert.ok(l > -1500 && l < 1500, `lag ${l} ms`);

  // sync replaces everything (future apple alert dropped, new due one added)
  const beforeSync = received.length;
  await post('/sync', { subscriptionId: id, alerts: [{ id: 'rice:9', fireAt: new Date(Date.now() - 10).toISOString(), title: 'Rice again', body: '' }] });
  await sleep(2000);
  assert.deepEqual(received.slice(beforeSync).map((g) => g.payload.notification.title), ['Rice again']);

  // bulk: 12 timers in ONE /schedule request (with a cancel), all due together,
  // all delivered by the alarm (rearm hint path) without cron.
  const beforeBulk = received.length;
  const bulkAt = new Date(Date.now() + 3000).toISOString();
  const bulk = await post('/schedule', { subscriptionId: id, cancel: ['rice:9'], alerts: Array.from({ length: 12 }, (_, i) => (
    { id: `bulk${i}:1`, fireAt: bulkAt, title: `Bulk ${i}`, body: '' })) });
  assert.deepEqual(bulk.body, { scheduled: 12, cancelled: 1 });
  for (let i = 0; i < 100 && received.length < beforeBulk + 12; i++) await sleep(100);
  assert.equal(received.length - beforeBulk, 12, 'all bulk alerts delivered');

  // expired subscription (410) is deleted
  const gone = await post('/subscribe', { subscription: { endpoint: `http://127.0.0.1:${MOCK}/push/gone`, keys: newSub('tmp').keys } });
  await post('/schedule', { subscriptionId: gone.body.subscriptionId, alerts: [{ id: 'x', fireAt: past, title: 'x' }] });
  await sleep(2000);
  assert.equal((await post('/schedule', { subscriptionId: gone.body.subscriptionId, alerts: [] })).status, 404);

  // unknown / missing ids
  assert.equal((await post('/schedule', { subscriptionId: 'nope', alerts: [] })).status, 404); // malformed id = unknown
  assert.equal((await post('/schedule', { subscriptionId: 42, alerts: [] })).status, 400);
  // other sites' pages are refused outright
  const evil = await fetch(`${BASE}/schedule`, { method: 'POST', headers: { 'Content-Type': 'application/json', Origin: 'https://evil.example' }, body: JSON.stringify({ subscriptionId: id, alerts: [] }) });
  assert.equal(evil.status, 403);
  assert.equal((await post('/unsubscribe', { subscriptionId: id })).body.ok, true);
  assert.equal((await post('/test', { subscriptionId: id })).status, 404);
  console.log(`E2E OK: ${received.length} pushes received, verified and decrypted`);
} catch (e) {
  failed = true;
  console.error('E2E FAILED:', e);
  console.error(log.slice(-3000));
} finally {
  // Kill the whole group (npx -> wrangler -> workerd), or workerd lingers.
  try { process.kill(-dev.pid, 'SIGTERM'); } catch { dev.kill('SIGTERM'); }
  mock.close();
}
process.exit(failed ? 1 : 0);

function newSubKeepKeys(key) {
  const s = subs[key];
  return { endpoint: `http://127.0.0.1:${MOCK}/push/${key}`, keys: { p256dh: s.ecdh.getPublicKey().toString('base64url'), auth: s.auth.toString('base64url') } };
}
