#!/usr/bin/env bash
# visual-qa/screenshot.sh — replaces screenshot.mjs, uses Pinchtab instead of puppeteer-core
# Usage:  ./screenshot.sh <port> <repo_key> <out_dir> [email] [password]
# Output: SCREENSHOT:/path/to/file  (one per screenshot taken)
#         TOTAL:N                   (at end)
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
WS="$(cd "$(dirname "$0")/../.." && pwd)"
source "$WS/scripts/lib/pinchtab.sh"

PORT="${1:-5173}"
REPO="${2:-unknown}"
OUT_DIR="${3:-/tmp/visual-qa}"
EMAIL="${4:-}"
PASSWORD="${5:-}"
BASE="http://localhost:${PORT}"

mkdir -p "$OUT_DIR"

ROUTE_MAP_qms_guard="/ /nc /report /activity"
ROUTE_MAP_chrome_auto_care="/ /bookings /services"
ROUTE_MAP_favorite_flow="/ /dashboard /orders"
ROUTE_MAP_favorite_flow_9637aff2="/ /dashboard"
ROUTE_MAP_metal_solutions="/"
ROUTE_MAP_default="/"

# Lookup routes for repo (replace - with _ for var name)
REPO_VAR="ROUTE_MAP_$(echo "$REPO" | tr '-' '_')"
ROUTES="${!REPO_VAR:-$ROUTE_MAP_default}"

if ! pt_wait_ready 15; then
  echo "WARN: Pinchtab not ready — skipping screenshots" >&2
  echo "TOTAL:0"
  exit 0
fi

OWNER="vqa-$$"
TAB=$(pt_new_tab "${BASE}/")

if [[ -z "$TAB" ]]; then
  echo "WARN: Failed to open tab" >&2
  echo "TOTAL:0"
  exit 0
fi

pt_lock_tab "$TAB" "$OWNER" 180

cleanup() {
  pt_unlock_tab "$TAB" "$OWNER" 2>/dev/null || true
  pt_close_tab "$TAB" 2>/dev/null || true
}
trap cleanup EXIT

TAKEN=0

# ── Login ──────────────────────────────────────────────────────────────────────
if [[ -n "$EMAIL" && -n "$PASSWORD" ]]; then
  pt_nav "${BASE}/auth" "$TAB" > /dev/null 2>&1 || true
  sleep 3

  # Screenshot login page
  LOGIN_FILE="$OUT_DIR/login.jpg"
  pt_screenshot "$LOGIN_FILE" "$TAB" > /dev/null 2>&1 && {
    echo "SCREENSHOT:$LOGIN_FILE"
    TAKEN=$((TAKEN + 1))
  } || true

  # Fill credentials using fill action (handles React controlled inputs)
  pt_fill 'input[type="email"], input[name="email"]' "$EMAIL" "$TAB" > /dev/null 2>&1 || \
  pt_fill 'input[placeholder*="email"]' "$EMAIL" "$TAB" > /dev/null 2>&1 || true
  sleep 0.5

  pt_fill 'input[type="password"], input[name="password"]' "$PASSWORD" "$TAB" > /dev/null 2>&1 || true
  sleep 0.5

  # Submit — click button[type=submit] or press Enter
  SNAP=$(pt_snapshot "$TAB" "format=compact&filter=interactive" 2>/dev/null || echo "")
  SUBMIT_REF=$(echo "$SNAP" | python3 -c "
import sys, json
nodes = json.load(sys.stdin) if sys.stdin.read().strip().startswith('[') else []
" 2>/dev/null || echo "")

  # Try clicking submit button
  pt_actions_json '[{"kind":"press","key":"Enter"}]' "$TAB" > /dev/null 2>&1 || true
  sleep 1

  # Wait up to 15s for redirect away from /auth
  for i in $(seq 1 15); do
    CURRENT=$(pt_eval "window.location.pathname" "$TAB" 2>/dev/null || echo "/auth")
    if [[ "$CURRENT" != *"/auth"* ]]; then
      break
    fi
    sleep 1
  done
  sleep 2
fi

# ── Screenshot each route ──────────────────────────────────────────────────────
for ROUTE in $ROUTES; do
  URL="${BASE}${ROUTE}"
  pt_nav "$URL" "$TAB" > /dev/null 2>&1 || true
  sleep 3

  SLUG=$(echo "$ROUTE" | tr '/' '_' | sed 's/^_//' || echo "home")
  [[ -z "$SLUG" ]] && SLUG="home"
  FILE="$OUT_DIR/${SLUG}.jpg"

  if pt_screenshot "$FILE" "$TAB" > /dev/null 2>&1; then
    echo "SCREENSHOT:$FILE"
    TAKEN=$((TAKEN + 1))
  else
    echo "FAILED:${ROUTE}:screenshot error" >&2
  fi
done

echo "TOTAL:$TAKEN"
