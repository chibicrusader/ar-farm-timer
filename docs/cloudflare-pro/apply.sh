#!/usr/bin/env bash
# Applies the Cloudflare Pro-plan settings in this folder to the artimer.win zone.
# See ../CLOUDFLARE_PRO.md. Only for a zone on the Pro plan.
# Default is a DRY RUN: it prints the requests and sends nothing.
#
#   CF_API_TOKEN=... CF_ZONE_ID=... bash docs/cloudflare-pro/apply.sh [--dry-run] <step...>
#   CF_API_TOKEN=... CF_ZONE_ID=... bash docs/cloudflare-pro/apply.sh --apply <step...>
#
# Steps (run in this order; one at a time is fine):
#   custom         WAF custom rules            (http_request_firewall_custom; keeps existing non-[pro] rules)
#   managed-log    Managed + OWASP, Log only   (http_request_firewall_managed)
#   managed-block  Managed default actions, OWASP still Log
#   ratelimit      2 rate limiting rules       (http_ratelimit; replaces the Free-plan rule)
#   cache          Cache Rules                 (http_request_cache_settings)
#   bots           Super Bot Fight Mode        (PUT bot_management, merged into current config)
#   settings       Polish lossless, WebP, Browser Cache TTL = respect headers
#   restore <phase|bots> <backup.json>         put a backup from an earlier --apply back
#
# Options:
#   --dry-run   (default) print method, path and body; no network, no token needed
#   --apply     really send (asks for confirmation unless --yes)
#   --yes       skip the confirmation prompt
# Env: CF_API_TOKEN, CF_ZONE_ID (read from the environment only; never printed),
#      BACKUP_DIR (default: /tmp/cf-pro-backup-<time>; keep it OUT of the repo,
#      backups contain zone-specific ruleset IDs), SBFM_ACTION (managed_challenge|block).
set -euo pipefail
cd "$(dirname "$0")"
API=https://api.cloudflare.com/client/v4
MODE=dry; YES=0; STEPS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE=dry ;;
    --apply) MODE=apply ;;
    --yes) YES=1 ;;
    -h|--help) sed -n 2,26p "$0"; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) STEPS+=("$1") ;;
  esac
  shift
done
[ ${#STEPS[@]} -gt 0 ] || { echo "no step given (try --help)" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

if [ "$MODE" = apply ]; then
  [ -n "${CF_API_TOKEN:-}" ] || { echo "CF_API_TOKEN is not set" >&2; exit 2; }
  [ -n "${CF_ZONE_ID:-}" ] || { echo "CF_ZONE_ID is not set" >&2; exit 2; }
  [[ "$CF_ZONE_ID" =~ ^[0-9a-f]{32}$ ]] || { echo "CF_ZONE_ID doesn't look like a zone id" >&2; exit 2; }
  BACKUP_DIR=${BACKUP_DIR:-/tmp/cf-pro-backup-$(date +%Y%m%d-%H%M%S)}
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
fi

# Strips "_comment" keys.
clean() { jq 'walk(if type == "object" then with_entries(select(.key | startswith("_") | not)) else . end)' "$1"; }
# Only the fields a rule needs when re-sent (drops id, version, last_updated, ref...).
rule_fields='{description, expression, action, action_parameters, ratelimit, logging, enabled} | with_entries(select(.value != null))'

# cf METHOD PATH [BODY_FILE]  -> response JSON on stdout. Token goes via a header
# file descriptor, so it is never in argv, the terminal or the logs.
cf() {
  local method=$1 path=${2//<ZONE_ID>/$CF_ZONE_ID} body=${3:-}
  local args=(-sS -X "$method" "$API$path" -H "Content-Type: application/json")
  [ -n "$body" ] && args+=(--data-binary "@$body")
  # Process substitution inline: an fd created inside an array assignment is
  # already closed by the time curl runs.
  curl "${args[@]}" -H @<(printf 'Authorization: Bearer %s\n' "$CF_API_TOKEN")
}

show() { # METHOD PATH BODY_FILE
  echo "---- $1 $2"
  [ -n "${3:-}" ] && jq . "$3"
  return 0
}

confirm() {
  [ "$YES" = 1 ] && return 0
  read -r -p "Send $1? Type yes: " a
  [ "$a" = yes ] || { echo "skipped"; return 1; }
}

check_ok() { # response on stdin
  local r; r=$(cat)
  if [ "$(jq -r '.success' <<<"$r")" = true ]; then echo "ok"; else
    echo "FAILED:"; jq -c '.errors' <<<"$r" | sed -E 's/[0-9a-f]{32}/<id>/g'; return 1; fi
}

require_pro() {
  local r plan
  r=$(cf GET "/zones/<ZONE_ID>")
  plan=$(jq -r '.result.plan.legacy_id // empty' <<<"$r")
  [ "$plan" = pro ] || { echo "zone plan is '${plan:-unknown}', not pro: stopping" >&2; exit 1; }
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# put_phase PHASE PAYLOAD [merge]
put_phase() {
  local phase=$1 payload=$2 merge=${3:-}
  local path="/zones/<ZONE_ID>/rulesets/phases/$phase/entrypoint" body="$TMP/$phase.json"
  clean "$payload" | jq '{rules: .rules}' > "$body"
  if [ "$MODE" = dry ]; then
    show PUT "$path" "$body"
    [ -n "$merge" ] && echo "(with --apply: existing rules whose description doesn't start with '[pro]' are kept and appended after these)"
    return 0
  fi
  local cur="$BACKUP_DIR/$phase.json"
  cf GET "$path" > "$cur"
  if [ "$(jq -r '.success' "$cur")" != true ]; then echo '{"result":{"rules":[]}}' > "$cur"; fi
  echo "backup: $cur ($(jq '.result.rules | length' "$cur") current rules)"
  if [ -n "$merge" ]; then
    jq --slurpfile cur "$cur" "{rules: (.rules + [\$cur[0].result.rules[]? | select((.description // \"\") | startswith(\"[pro]\") | not) | $rule_fields])}" "$body" > "$body.m"
    mv "$body.m" "$body"
  fi
  echo "new rule list:"; jq -r '.rules[] | "  - [\(.action)] \(.description // "(no description)")"' "$body"
  confirm "PUT $phase" || return 0
  cf PUT "$path" "$body" | check_ok
}

do_bots() {
  local path="/zones/<ZONE_ID>/bot_management" body="$TMP/bots.json"
  clean bot-management.json | jq --arg a "${SBFM_ACTION:-managed_challenge}" '.sbfm_definitely_automated = $a' > "$body"
  case "${SBFM_ACTION:-managed_challenge}" in managed_challenge|block) ;; *) echo "SBFM_ACTION must be managed_challenge or block" >&2; exit 2 ;; esac
  if [ "$MODE" = dry ]; then show PUT "$path" "$body"; echo "(with --apply: merged into the current bot_management config)"; return 0; fi
  local cur="$BACKUP_DIR/bot_management.json"
  cf GET "$path" > "$cur"; echo "backup: $cur"
  jq -s '(.[0].result // {} | del(.using_latest_model, .stale_zone_configuration)) * .[1]' "$cur" "$body" > "$body.m"; mv "$body.m" "$body"
  jq . "$body"
  confirm "PUT bot_management" || return 0
  cf PUT "$path" "$body" | check_ok
}

do_settings() {
  local n i id
  n=$(jq '.settings | length' zone-settings.json)
  for ((i = 0; i < n; i++)); do
    id=$(jq -r ".settings[$i].id" zone-settings.json)
    jq "{value: .settings[$i].value}" zone-settings.json > "$TMP/s-$id.json"
    if [ "$MODE" = dry ]; then show PATCH "/zones/<ZONE_ID>/settings/$id" "$TMP/s-$id.json"; continue; fi
    cf GET "/zones/<ZONE_ID>/settings/$id" > "$BACKUP_DIR/setting-$id.json"
    echo "$id: now $(jq -c '.result.value' "$BACKUP_DIR/setting-$id.json") -> $(jq -c .value "$TMP/s-$id.json")"
    confirm "PATCH $id" || continue
    cf PATCH "/zones/<ZONE_ID>/settings/$id" "$TMP/s-$id.json" | check_ok
  done
}

do_restore() { # what file
  local what=$1 file=$2
  [ -f "$file" ] || { echo "no such backup $file" >&2; exit 2; }
  if [ "$what" = bots ]; then
    jq '.result | del(.using_latest_model, .stale_zone_configuration)' "$file" > "$TMP/r.json"
    [ "$MODE" = dry ] && { show PUT "/zones/<ZONE_ID>/bot_management" "$TMP/r.json"; return 0; }
    confirm "restore bot_management" && cf PUT "/zones/<ZONE_ID>/bot_management" "$TMP/r.json" | check_ok
  else
    jq "{rules: [.result.rules[]? | $rule_fields]}" "$file" > "$TMP/r.json"
    [ "$MODE" = dry ] && { show PUT "/zones/<ZONE_ID>/rulesets/phases/$what/entrypoint" "$TMP/r.json"; return 0; }
    confirm "restore $what" && cf PUT "/zones/<ZONE_ID>/rulesets/phases/$what/entrypoint" "$TMP/r.json" | check_ok
  fi
}

[ "$MODE" = apply ] && require_pro
[ "$MODE" = dry ] && echo "DRY RUN: nothing is sent. <ZONE_ID> is filled from CF_ZONE_ID only with --apply."

i=0
while [ $i -lt ${#STEPS[@]} ]; do
  s=${STEPS[$i]}
  echo "== $s"
  case "$s" in
    custom)        put_phase http_request_firewall_custom custom-rules.json merge ;;
    managed-log)   put_phase http_request_firewall_managed managed-rules.log.json ;;
    managed-block) put_phase http_request_firewall_managed managed-rules.block.json ;;
    ratelimit)     put_phase http_ratelimit ratelimit.json ;;
    cache)         put_phase http_request_cache_settings cache-rules.json ;;
    bots)          do_bots ;;
    settings)      do_settings ;;
    restore)       do_restore "${STEPS[$((i+1))]:?phase}" "${STEPS[$((i+2))]:?file}"; i=$((i+2)) ;;
    *) echo "unknown step $s" >&2; exit 2 ;;
  esac
  i=$((i+1))
done
