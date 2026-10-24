// Generates a VAPID key pair OUTSIDE the repo (../../../secrets/vapid.json by
// default) and writes .dev.vars for `wrangler dev`. Refuses to overwrite
// existing keys unless --force (changing keys invalidates all subscriptions).
import { webcrypto as crypto } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const secretsDir = process.env.SECRETS_DIR || path.resolve(here, '../../../secrets');
const out = path.join(secretsDir, 'vapid.json');
const force = process.argv.includes('--force');
const subject = process.env.VAPID_SUBJECT || 'mailto:you@example.com';

const b64url = (buf) => Buffer.from(buf).toString('base64url');

let keys;
if (fs.existsSync(out) && !force) {
  keys = JSON.parse(fs.readFileSync(out, 'utf8'));
  console.log(`Using existing keys in ${out} (pass --force to regenerate).`);
} else {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const publicKey = b64url(await crypto.subtle.exportKey('raw', pair.publicKey));
  const privateJwk = await crypto.subtle.exportKey('jwk', pair.privateKey);
  keys = { publicKey, privateJwk, subject, createdAt: new Date().toISOString() };
  fs.mkdirSync(secretsDir, { recursive: true, mode: 0o700 });
  fs.writeFileSync(out, JSON.stringify(keys, null, 2) + '\n', { mode: 0o600 });
  console.log(`Wrote new VAPID keys to ${out}`);
}

const devVars = path.resolve(here, '../.dev.vars');
fs.writeFileSync(devVars,
  `VAPID_PUBLIC_KEY="${keys.publicKey}"\nVAPID_PRIVATE_JWK='${JSON.stringify(keys.privateJwk)}'\n`, { mode: 0o600 });
console.log(`Wrote ${devVars} (gitignored) for wrangler dev`);
console.log(`Public key: ${keys.publicKey}`);
