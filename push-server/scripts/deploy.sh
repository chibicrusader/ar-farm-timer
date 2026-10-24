#!/usr/bin/env bash
# One-time + repeat deploy of the push server to Cloudflare (free plan is enough).
# Prereqs: a Cloudflare account, `npm ci && npx --no-install wrangler login` done once in a browser.
#   APP_URL=https://you.github.io/archerage-farm-timer/ \
#   VAPID_SUBJECT=mailto:you@example.com \
#   bash scripts/deploy.sh
# NOT run by the build; nothing is deployed until you run this yourself.
# wrangler is the exact version in package-lock.json (npm ci), never a
# freshly downloaded one.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
node -e 'process.exit(+process.versions.node.split(".")[0] >= 22 ? 0 : 1)' \
  || { echo "Node.js 22+ is needed (wrangler). Run: npx -y -p node@22 bash scripts/deploy.sh" >&2; exit 1; }
: "${APP_URL:?set APP_URL to your hosted web app URL (ending with /)}"
: "${VAPID_SUBJECT:?set VAPID_SUBJECT, e.g. mailto:you@example.com}"
# Values below are written into wrangler.toml with sed: allow only plain
# URL/e-mail characters so nothing can break out of the sed expression.
[[ "$APP_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]] \
  || { echo "APP_URL must be a plain https:// URL" >&2; exit 2; }
[[ "$VAPID_SUBJECT" =~ ^(mailto:[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+|https://[A-Za-z0-9._~/-]+)$ ]] \
  || { echo "VAPID_SUBJECT must be mailto:you@example.com or an https:// URL" >&2; exit 2; }
ORIGIN=$(node -e 'const u=new URL(process.argv[1]);console.log(u.origin)' "$APP_URL")
ALLOWED_ORIGINS="${ALLOWED_ORIGINS:-$ORIGIN}"
O='https://[A-Za-z0-9.-]+(:[0-9]{1,5})?'
[[ "$ALLOWED_ORIGINS" =~ ^(\*|$O(,$O)*)$ ]] \
  || { echo "ALLOWED_ORIGINS must be * or comma-separated https:// origins" >&2; exit 2; }
SECRETS="${SECRETS_DIR:-../../secrets}/vapid.json"

# Pinned toolchain: install exactly what package-lock.json lists (fails if the
# lock file and package.json disagree), and never let npx fetch anything.
npm ci --no-fund
wrangler() { npx --no-install wrangler "$@"; }

wrangler whoami >/dev/null || { echo "Run: npx --no-install wrangler login" >&2; exit 1; }
[[ -f "$SECRETS" ]] || VAPID_SUBJECT="$VAPID_SUBJECT" node scripts/gen-vapid.mjs
PUB=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).publicKey)' "$SECRETS")
[[ "$PUB" =~ ^[A-Za-z0-9_-]{80,100}$ ]] || { echo "Unexpected VAPID public key format in $SECRETS" >&2; exit 1; }

# Create the D1 database once and record its id in wrangler.toml.
if grep -q '00000000-0000-0000-0000-000000000000' wrangler.toml; then
  OUT=$(wrangler d1 create archerage-farm-timer-push)
  echo "$OUT"
  DBID=$(echo "$OUT" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
  [[ -n "$DBID" ]] || { echo "Could not parse database_id; paste it into wrangler.toml" >&2; exit 1; }
  sed -i.bak "s/00000000-0000-0000-0000-000000000000/$DBID/" wrangler.toml && rm -f wrangler.toml.bak
fi
wrangler d1 execute DB --remote --file schema.sql
# Schema changes after v1 (migrations/), each applied once; before the deploy,
# because the new code needs them.
wrangler d1 migrations apply DB --remote

# Non-secret vars.
sed -i.bak -e "s|^VAPID_PUBLIC_KEY = .*|VAPID_PUBLIC_KEY = \"$PUB\"|" \
  -e "s|^VAPID_SUBJECT = .*|VAPID_SUBJECT = \"$VAPID_SUBJECT\"|" \
  -e "s|^ALLOWED_ORIGINS = .*|ALLOWED_ORIGINS = \"$ALLOWED_ORIGINS\"|" \
  -e "s|^APP_URL = .*|APP_URL = \"$APP_URL\"|" wrangler.toml && rm -f wrangler.toml.bak

wrangler deploy

# Secret: the private key never goes into wrangler.toml or git. Set after the
# first deploy so the Worker already exists; this rolls out a new version.
node -e 'process.stdout.write(JSON.stringify(JSON.parse(require("fs").readFileSync(process.argv[1])).privateJwk))' "$SECRETS" \
  | wrangler secret put VAPID_PRIVATE_JWK

echo "Deployed. Build the app with the push server's custom domain (if attached, see wrangler.toml)"
echo "and the *.workers.dev URL as fallback: tool/build_web.sh --push-server https://<domain> --push-server-fallback https://<x>.workers.dev"
