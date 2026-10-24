// Unit tests: our WebCrypto Web Push encryption is decrypted by the
// independent `http_ece` library (used by the popular `web-push` package),
// and the VAPID JWT verifies against the public key.
import test from 'node:test';
import assert from 'node:assert/strict';
import nodeCrypto from 'node:crypto';
import ece from 'http_ece';
import { encryptPayload, vapidJwt, b64urlEncode, b64urlDecode, validateSubscriptionKeys, MAX_PLAINTEXT } from '../src/webpush.js';
import { parseAlerts, isAllowedEndpoint, buildPayload, safeAppUrl, originAllowed } from '../src/index.js';

function subscriber() {
  const ecdh = nodeCrypto.createECDH('prime256v1');
  ecdh.generateKeys();
  const auth = nodeCrypto.randomBytes(16);
  return { ecdh, p256dh: ecdh.getPublicKey().toString('base64url'), auth: auth.toString('base64url'), authBuf: auth };
}

test('aes128gcm payload decrypts with http_ece', async () => {
  const s = subscriber();
  const payload = JSON.stringify({ web_push: 8030, notification: { title: 'Rice is ready!', body: 'Harvest' } });
  const body = await encryptPayload(payload, s.p256dh, s.auth);
  const plain = ece.decrypt(Buffer.from(body), { version: 'aes128gcm', privateKey: s.ecdh, authSecret: s.authBuf });
  assert.equal(plain.toString('utf8'), payload);
  // header: salt(16) rs(4)=4096 idlen(1)=65
  assert.equal(new DataView(body.buffer, body.byteOffset).getUint32(16), 4096);
  assert.equal(body[20], 65);
});

test('VAPID JWT is ES256-signed with the expected claims', async () => {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const jwk = await crypto.subtle.exportKey('jwk', pair.privateKey);
  const jwt = await vapidJwt('https://web.push.apple.com', 'mailto:a@b.c', jwk, 1999999999);
  const [h, c, sig] = jwt.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(h, 'base64url')), { typ: 'JWT', alg: 'ES256' });
  assert.deepEqual(JSON.parse(Buffer.from(c, 'base64url')), { aud: 'https://web.push.apple.com', exp: 1999999999, sub: 'mailto:a@b.c' });
  const ok = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, pair.publicKey, b64urlDecode(sig), new TextEncoder().encode(`${h}.${c}`));
  assert.ok(ok);
});

test('base64url round trip', () => {
  const b = new Uint8Array([0, 251, 255, 1, 2, 3]);
  assert.deepEqual(b64urlDecode(b64urlEncode(b)), b);
});

test('endpoint allow-list blocks arbitrary hosts', () => {
  const env = {};
  assert.ok(isAllowedEndpoint('https://web.push.apple.com/abc', env));
  assert.ok(isAllowedEndpoint('https://fcm.googleapis.com/fcm/send/x', env));
  assert.ok(isAllowedEndpoint('https://wns2-par02p.notify.windows.com/w/?token=x', env));
  assert.ok(!isAllowedEndpoint('https://evil.example.com/push', env));
  assert.ok(!isAllowedEndpoint('http://web.push.apple.com/abc', env));
  assert.ok(!isAllowedEndpoint('not a url', env));
  assert.ok(isAllowedEndpoint('http://127.0.0.1:9911/p', { EXTRA_PUSH_HOSTS: '127.0.0.1:9911' }));
});

test('parseAlerts validates input', () => {
  const now = Date.parse('2026-10-17T00:00:00Z');
  const ok = parseAlerts([{ id: 't1:5', fireAt: '2026-10-17T01:00:00Z', title: 'x', body: 'y' }], now);
  assert.equal(ok[0].fireAt, Date.parse('2026-10-17T01:00:00Z'));
  assert.throws(() => parseAlerts('nope', now));
  assert.throws(() => parseAlerts([{ id: 'a', title: 'x', fireAt: 'garbage' }], now));
  assert.throws(() => parseAlerts([{ id: 'a', title: 'x', fireAt: '2027-06-01T00:00:00Z' }], now));
  assert.equal(parseAlerts([{ id: 'a', title: 'T'.repeat(500), fireAt: '2026-10-17T01:00:00Z' }], now)[0].title.length, 120);
});

test('payload uses declarative web push format', () => {
  const p = JSON.parse(buildPayload({ id: 'a', title: 'T', body: 'B', url: null }, { APP_URL: 'https://x.test/app/' }));
  assert.equal(p.web_push, 8030);
  assert.equal(p.notification.navigate, 'https://x.test/app/');
  assert.equal(p.notification.title, 'T');
});

test('endpoint allow-list: no other ports, userinfo, look-alike hosts or huge endpoints', () => {
  const env = {};
  assert.ok(!isAllowedEndpoint('https://fcm.googleapis.com:8443/x', env));
  assert.ok(!isAllowedEndpoint('https://user:pw@fcm.googleapis.com/x', env));
  assert.ok(!isAllowedEndpoint('https://fcm.googleapis.com.evil.example/x', env));
  assert.ok(!isAllowedEndpoint('https://evilfcm.googleapis.com.example/x', env));
  assert.ok(!isAllowedEndpoint('https://notnotify.windows.com.evil/x', env));
  assert.ok(!isAllowedEndpoint('https://localhost/x', env));
  assert.ok(!isAllowedEndpoint('https://169.254.169.254/latest', env));
  assert.ok(!isAllowedEndpoint(`https://fcm.googleapis.com/${'a'.repeat(1100)}`, env));
  assert.ok(!isAllowedEndpoint({ toString: () => 'https://fcm.googleapis.com/x' }, env));
});

test('subscription key validation', async () => {
  const s = subscriber();
  assert.ok(await validateSubscriptionKeys(s.p256dh, s.auth));
  assert.ok(!(await validateSubscriptionKeys(s.p256dh.slice(0, -2), s.auth)));
  assert.ok(!(await validateSubscriptionKeys(b64urlEncode(new Uint8Array(65).fill(4)), s.auth))); // not on the curve
  assert.ok(!(await validateSubscriptionKeys(s.p256dh, b64urlEncode(new Uint8Array(8)))));
  assert.ok(!(await validateSubscriptionKeys(s.p256dh, 'not base64!')));
  assert.ok(!(await validateSubscriptionKeys(null, s.auth)));
});

test('oversized push payloads are refused before encryption', async () => {
  const s = subscriber();
  await encryptPayload('x'.repeat(MAX_PLAINTEXT), s.p256dh, s.auth);
  await assert.rejects(encryptPayload('x'.repeat(MAX_PLAINTEXT + 1), s.p256dh, s.auth));
  // the largest alert the server accepts fits (3-byte UTF-8 chars everywhere)
  const env = { APP_URL: 'https://artimer.win/' };
  const p = buildPayload({ id: '\u4e00'.repeat(128), title: '\u4e00'.repeat(120), body: '\u4e00'.repeat(300), url: 'https://artimer.win/' + 'a'.repeat(470) }, env);
  assert.ok(new TextEncoder().encode(p).length <= MAX_PLAINTEXT);
});

test('safeAppUrl only allows the app origins', () => {
  const env = { APP_URL: 'https://artimer.win/', ALLOWED_ORIGINS: 'https://artimer.win,https://archerage-farm-timer.pages.dev' };
  assert.equal(safeAppUrl('https://artimer.win/', env), 'https://artimer.win/');
  assert.equal(safeAppUrl('https://archerage-farm-timer.pages.dev/x?y#z', env), 'https://archerage-farm-timer.pages.dev/x?y#z');
  for (const bad of ['javascript:alert(1)', 'JaVaScRiPt:alert(1)', 'data:text/html,x', 'https://evil.example/',
    'https://artimer.win.evil.example/', '//evil.example/', '/relative', 'http://artimer.win/', 'https://a@artimer.win/',
    'blob:https://artimer.win/x', '', null, 5, {}, 'https://artimer.win/' + 'a'.repeat(600)]) {
    assert.equal(safeAppUrl(bad, env), null, String(bad));
  }
  // ALLOWED_ORIGINS="*" still only allows APP_URL's origin
  assert.equal(safeAppUrl('https://evil.example/', { APP_URL: 'https://artimer.win/', ALLOWED_ORIGINS: '*' }), null);
  const p = JSON.parse(buildPayload({ id: 'a', title: 'T', body: '', url: 'javascript:alert(1)' }, env));
  assert.equal(p.notification.navigate, 'https://artimer.win/');
});

test('originAllowed', () => {
  const env = { ALLOWED_ORIGINS: 'https://artimer.win' };
  assert.ok(originAllowed(null, env)); // GET without Origin (health check)
  assert.ok(!originAllowed(null, env, 'POST')); // a POST must carry an Origin
  assert.ok(!originAllowed('', env, 'POST'));
  assert.ok(originAllowed('https://artimer.win', env, 'POST'));
  assert.ok(originAllowed(null, { ALLOWED_ORIGINS: '*' }, 'POST'));
  assert.ok(originAllowed('https://artimer.win', env));
  assert.ok(!originAllowed('https://artimer.win.evil.example', env));
  assert.ok(!originAllowed('null', env));
  assert.ok(originAllowed('https://x.example', { ALLOWED_ORIGINS: '*' }));
});

test('parseAlerts: past bound, object check, surrogate-safe cut', () => {
  const now = Date.parse('2026-10-17T00:00:00Z');
  assert.throws(() => parseAlerts([null], now));
  assert.throws(() => parseAlerts([{ id: 'a', title: 'x', fireAt: '2026-10-15T00:00:00Z' }], now));
  assert.ok(parseAlerts([{ id: 'a', title: 'x', fireAt: '2026-10-16T12:00:00Z' }], now)); // slight past is fine
  assert.equal(parseAlerts([{ id: 'a', title: 'x', fireAt: now + 5000 }], now)[0].fireAt, now + 5000); // epoch ms
  assert.throws(() => parseAlerts([{ id: 'a', title: 'x', fireAt: Infinity }], now));
  const t = parseAlerts([{ id: 'a', title: 'x'.repeat(119) + '\u{1F33E}', fireAt: '2026-10-17T01:00:00Z' }], now)[0].title;
  assert.equal(t.length, 119);
});
