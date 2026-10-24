#!/usr/bin/env bash
# Upload build/web to Cloudflare Pages (free). NOT run automatically.
# Live at https://artimer.win/ (Pages custom domain) and https://archerage-farm-timer.pages.dev/.
# Prereqs: free Cloudflare account, `npx --no-install wrangler login` (use the push-server's wrangler,
# pinned in push-server/package-lock.json and installed with npm ci below).
#   tool/build_web.sh --push-server https://push.artimer.win \
#     --push-server-fallback https://archerage-farm-timer-push.<you>.workers.dev
#   tool/deploy_web_cloudflare.sh [project-name]     # -> https://<project-name>.pages.dev/
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PROJECT="${1:-archerage-farm-timer}"
[[ "$PROJECT" =~ ^[a-z0-9][a-z0-9-]{0,57}$ ]] || { echo "Invalid Pages project name: $PROJECT" >&2; exit 2; }
[[ -f build/web/sw.js ]] || { echo "Run tool/build_web.sh first" >&2; exit 1; }
if grep -q '__PUSH_SERVER_ORIGIN__\|__PRECACHE__' build/web/_headers build/web/sw.js; then
  echo "build/web was not produced by tool/build_web.sh (placeholders left)" >&2; exit 1
fi
cd push-server
npm ci --no-fund
wrangler() { npx --no-install wrangler "$@"; }
wrangler pages project list 2>/dev/null | grep -qw -- "$PROJECT" || \
  wrangler pages project create "$PROJECT" --production-branch main
wrangler pages deploy ../build/web --project-name "$PROJECT" --branch main --commit-dirty=true
