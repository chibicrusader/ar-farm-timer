#!/usr/bin/env bash
# Offline-capable PWA build.
#   tool/build_web.sh [--base-href /repo/] [--push-server https://push.example.com]
#                     [--push-server-fallback https://x.workers.dev]
# The fallback is the same push server under its old address: the app uses it
# only when the main address can't be reached, and both go into the CSP.
# Output: build/web (static files; host anywhere over HTTPS).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
BASE_HREF="/"
PUSH_SERVER=""
PUSH_FALLBACK=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-href) BASE_HREF="$2"; shift 2 ;;
    --push-server) PUSH_SERVER="$2"; shift 2 ;;
    --push-server-fallback) PUSH_FALLBACK="$2"; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
done
# Validate inputs: they end up in the app and in the CSP header (_headers).
[[ "$BASE_HREF" =~ ^/([A-Za-z0-9._~-]+/)*$ ]] || { echo "--base-href must look like /path/ (got: $BASE_HREF)" >&2; exit 2; }
valid_origin() {
  [[ "$1" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ || "$1" =~ ^http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?$ ]]
}
PUSH_SERVER="${PUSH_SERVER%/}"
PUSH_FALLBACK="${PUSH_FALLBACK%/}"
PUSH_ORIGIN=""
if [[ -n "$PUSH_SERVER" ]]; then
  valid_origin "$PUSH_SERVER" \
    || { echo "--push-server must be an https:// origin without a path (got: $PUSH_SERVER)" >&2; exit 2; }
  PUSH_ORIGIN="$PUSH_SERVER"
fi
if [[ -n "$PUSH_FALLBACK" ]]; then
  [[ -n "$PUSH_SERVER" ]] || { echo "--push-server-fallback needs --push-server" >&2; exit 2; }
  valid_origin "$PUSH_FALLBACK" \
    || { echo "--push-server-fallback must be an https:// origin without a path (got: $PUSH_FALLBACK)" >&2; exit 2; }
  [[ "$PUSH_FALLBACK" == "$PUSH_SERVER" ]] || PUSH_ORIGIN="$PUSH_ORIGIN $PUSH_FALLBACK"
fi
# Self-hosted fallback fonts must match this Flutter SDK (see the script).
python3 tool/fetch_fallback_fonts.py --check
# Exactly the package versions in pubspec.lock (fails instead of re-resolving).
flutter pub get --enforce-lockfile
flutter build web --release --no-web-resources-cdn --base-href "$BASE_HREF" \
  --dart-define=PUSH_SERVER_URL="$PUSH_SERVER" \
  --dart-define=PUSH_SERVER_FALLBACK_URL="$PUSH_FALLBACK"
# Flutter's deprecated worker unregisters itself; make sure it is never used.
rm -f -- build/web/flutter_service_worker.js
# The CSP may connect to the push server (both addresses) and nothing else off-site (fallback
# fonts are self-hosted, see web/flutter_bootstrap.js).
python3 - build/web/_headers "$PUSH_ORIGIN" <<'PY'
import sys
path, origin = sys.argv[1], sys.argv[2]
src = open(path).read()
if '__PUSH_SERVER_ORIGIN__' not in src:
    sys.exit('_headers: __PUSH_SERVER_ORIGIN__ placeholder missing')
src = src.replace(' __PUSH_SERVER_ORIGIN__', (' ' + origin) if origin else '')
open(path, 'w').write(src)
PY
python3 tool/gen_sw.py build/web
