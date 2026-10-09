#!/bin/bash
# Usage: scripts/make-dmg.sh <path/to/NiceStats.app> [output.dmg]
# Needs: brew install create-dmg
set -euo pipefail

APP="$1"
OUT="${2:-NiceStats.dmg}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"

create-dmg \
  --volname "NiceStats" \
  --eula "$ROOT/LICENSE" \
  --window-size 540 380 \
  --icon-size 110 \
  --icon "NiceStats.app" 140 180 \
  --app-drop-link 400 180 \
  --overwrite \
  "$OUT" \
  "$STAGE"
