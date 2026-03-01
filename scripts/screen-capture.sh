#!/usr/bin/env bash
# screen-capture.sh — take a screenshot and save to a known path for Claude to read
# Usage: bash screen-capture.sh [optional-label]
# Output: /tmp/screen-latest.png (and timestamped copy)

set -uo pipefail

LABEL="${1:-screen}"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
OUT_LATEST="/tmp/screen-latest.png"
OUT_STAMPED="/tmp/screen-${LABEL}-${TIMESTAMP}.png"

# -x = no sound, -C = capture cursor, -o = no shadow
screencapture -x -C "$OUT_LATEST"
cp "$OUT_LATEST" "$OUT_STAMPED"

echo "$OUT_LATEST"
