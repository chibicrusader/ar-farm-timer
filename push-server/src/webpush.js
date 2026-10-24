// Minimal Web Push sender for Cloudflare Workers (WebCrypto only, no deps).
// Implements VAPID (RFC 8292) and aes128gcm payload encryption (RFC 8291).

const enc = new TextEncoder();

export function b64urlEncode(bytes) {
  const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let s = '';
  for (let i = 0; i < arr.length; i++) s += String.fromCharCode(arr[i]);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function b64urlDecode(str) {
  const pad = '='.repeat((4 - (str.length % 4)) % 4);
  const bin = atob((str + pad).replace(/-/g, '+').replace(/_/g, '/'));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/**
 * True if [p256dhB64] is an uncompressed P-256 public key (65 bytes, on the
 * curve) and [authB64] a 16-byte auth secret, both base64url (RFC 8291).
 */
export async function validateSubscriptionKeys(p256dhB64, authB64) {
  const b64url = /^[A-Za-z0-9_-]+={0,2}$/;
  if (typeof p256dhB64 !== 'string' || typeof authB64 !== 'string') return false;
  if (p256dhB64.length > 100 || authB64.length > 32 || !b64url.test(p256dhB64) || !b64url.test(authB64)) return false;
  try {
    const pub = b64urlDecode(p256dhB64);
    if (pub.length !== 65 || pub[0] !== 4 || b64urlDecode(authB64).length !== 16) return false;
    await crypto.subtle.importKey('raw', pub, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
    return true;
  } catch {
    return false;
  }
}

// One aes128gcm record of rs = 4096 bytes: 86-byte header aside, push
// services accept 4096 bytes of body; keep the plaintext well inside it.
export const MAX_PLAINTEXT = 4096 - 86 - 16 - 1;

function concat(...parts) {
  const len = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(len);
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

async function hmac(key, data) {
  const k = await crypto.subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', k, data));
}

/** Signed VAPID JWT for the push service origin. */
export async function vapidJwt(audience, subject, privateJwk, expSeconds) {
  const header = b64urlEncode(enc.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const exp = expSeconds ?? Math.floor(Date.now() / 1000) + 12 * 3600;
  const claims = b64urlEncode(enc.encode(JSON.stringify({ aud: audience, exp, sub: subject })));
  const key = await crypto.subtle.importKey('jwk', privateJwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, enc.encode(`${header}.${claims}`));
  return `${header}.${claims}.${b64urlEncode(sig)}`; // WebCrypto gives raw r||s = JOSE format
}

/**
 * Encrypts [payload] for a subscription (aes128gcm, single record).
 * Optional [_test] lets tests pin the ephemeral key and salt.
 */
export async function encryptPayload(payload, p256dhB64, authB64, _test = {}) {
  const uaPublic = b64urlDecode(p256dhB64);
  const authSecret = b64urlDecode(authB64);
  const asKeys = _test.keyPair ?? await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const asPublic = new Uint8Array(await crypto.subtle.exportKey('raw', asKeys.publicKey));
  const uaKey = await crypto.subtle.importKey('raw', uaPublic, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const ecdhSecret = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, asKeys.privateKey, 256));

  // RFC 8291 section 3.4
  const prkKey = await hmac(authSecret, ecdhSecret);
  const keyInfo = concat(enc.encode('WebPush: info\0'), uaPublic, asPublic);
  const ikm = await hmac(prkKey, concat(keyInfo, new Uint8Array([1])));
  const salt = _test.salt ?? crypto.getRandomValues(new Uint8Array(16));
  const prk = await hmac(salt, ikm);
  const cek = (await hmac(prk, concat(enc.encode('Content-Encoding: aes128gcm\0'), new Uint8Array([1])))).slice(0, 16);
  const nonce = (await hmac(prk, concat(enc.encode('Content-Encoding: nonce\0'), new Uint8Array([1])))).slice(0, 12);

  const data = typeof payload === 'string' ? enc.encode(payload) : payload;
  if (data.length > MAX_PLAINTEXT) throw new Error('push payload too large');
  const plaintext = concat(data, new Uint8Array([2])); // last-record delimiter
  const aesKey = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt']);
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, aesKey, plaintext));

  const rs = new Uint8Array(4);
  new DataView(rs.buffer).setUint32(0, 4096);
  return concat(salt, rs, new Uint8Array([asPublic.length]), asPublic, ciphertext);
}

/**
 * Sends one push. [vapid] = {publicKey (b64url raw), privateJwk, subject}.
 * Returns the fetch Response.
 */
export async function sendWebPush(subscription, payload, vapid, { ttl = 3600, urgency = 'high', topic } = {}) {
  const endpoint = new URL(subscription.endpoint);
  const jwt = await vapidJwt(endpoint.origin, vapid.subject, vapid.privateJwk);
  const body = await encryptPayload(payload, subscription.keys.p256dh, subscription.keys.auth);
  const headers = {
    'Content-Encoding': 'aes128gcm',
    'Content-Type': 'application/octet-stream',
    TTL: String(ttl),
    Urgency: urgency,
    Authorization: `vapid t=${jwt}, k=${vapid.publicKey}`,
  };
  if (topic) headers.Topic = topic;
  // Never follow redirects: the endpoint host was allow-listed, its redirect target was not.
  return fetch(subscription.endpoint, { method: 'POST', headers, body, redirect: 'manual' });
}
