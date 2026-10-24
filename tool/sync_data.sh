#!/usr/bin/env bash
# Copies the researched farm data (data/farm_items.json) into the bundled
# app asset (assets/farm_items.json). Safe to run repeatedly.
set -euo pipefail
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$APP_DIR/data/farm_items.json"
DEST="$APP_DIR/assets/farm_items.json"

if [[ ! -f "$SRC" ]]; then
  echo "No data file at $SRC - keeping existing asset ($DEST)." >&2
  exit 0
fi

# Validate JSON (must be a top-level array) before replacing the asset.
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d,list), "farm_items.json must be a JSON array"; print(f"Valid: {len(d)} items")' "$SRC"
fi

cp "$SRC" "$DEST"
echo "Copied $SRC -> $DEST"
