#!/usr/bin/env bash
# scripts/browse.sh — on-demand browser tool for Telegram gateway / task worker
# Usage:
#   browse.sh text    <url>              — return readable page text
#   browse.sh shot    <url> [outfile]    — screenshot to file (default /tmp/browse-shot.jpg)
#   browse.sh snap    <url> [params]     — accessibility tree snapshot
#   browse.sh fetch   <url> [outfile]    — download file via browser session
#   browse.sh eval    <url> <js_expr>    — run JS on page, return result
#
# All commands open a fresh tab, wait for page load, return result, then close the tab.
# Requires: com.amalfiai.pinchtab daemon running (health: http://localhost:9867/health)
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
WS="/Users/henryburton/.openclaw/workspace-anthropic"
source "$WS/scripts/lib/pinchtab.sh"

CMD="${1:-text}"
URL="${2:-}"
ARG3="${3:-}"

if [[ -z "$URL" ]]; then
  echo "Usage: browse.sh <text|shot|snap|fetch|eval> <url> [arg]" >&2
  exit 1
fi

# Ensure pinchtab is up
if ! pt_wait_ready 15; then
  echo "[browse] Pinchtab not available — is com.amalfiai.pinchtab loaded?" >&2
  exit 1
fi

OWNER="browse-$$"

_open_tab() {
  local url="$1"
  local TAB
  TAB=$(pt_new_tab "$url")
  if [[ -z "$TAB" ]]; then
    echo "[browse] Failed to open tab" >&2
    exit 1
  fi
  pt_lock_tab "$TAB" "$OWNER" 120
  echo "$TAB"
}

_close_tab() {
  local tab="$1"
  pt_unlock_tab "$tab" "$OWNER" 2>/dev/null || true
  pt_close_tab "$tab" 2>/dev/null || true
}

case "$CMD" in

  text)
    TAB=$(_open_tab "$URL")
    sleep 3
    pt_text "$TAB"
    _close_tab "$TAB"
    ;;

  shot|screenshot)
    OUTFILE="${ARG3:-/tmp/browse-shot.jpg}"
    TAB=$(_open_tab "$URL")
    sleep 3
    pt_screenshot "$OUTFILE" "$TAB"
    _close_tab "$TAB"
    echo "$OUTFILE"
    ;;

  snap|snapshot)
    PARAMS="${ARG3:-format=compact&filter=interactive}"
    TAB=$(_open_tab "$URL")
    sleep 3
    pt_snapshot "$TAB" "$PARAMS"
    _close_tab "$TAB"
    ;;

  fetch|download)
    OUTFILE="${ARG3:-/tmp/browse-download}"
    curl -sf "http://localhost:9867/download?url=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$URL")&output=file&path=$OUTFILE" > /dev/null
    echo "$OUTFILE"
    ;;

  eval|js)
    EXPR="$ARG3"
    if [[ -z "$EXPR" ]]; then
      echo "Usage: browse.sh eval <url> <js_expression>" >&2
      exit 1
    fi
    TAB=$(_open_tab "$URL")
    sleep 3
    pt_eval "$EXPR" "$TAB"
    _close_tab "$TAB"
    ;;

  *)
    echo "Unknown command: $CMD. Use: text | shot | snap | fetch | eval" >&2
    exit 1
    ;;
esac
