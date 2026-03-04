#!/usr/bin/env bash
# scripts/lib/pinchtab.sh
# ─────────────────────────────────────────────────────────────────────────────
# Shared Pinchtab browser automation helpers.
# Source this in any agent that needs browser control.
#
# Requires: pinchtab daemon running (com.amalfiai.pinchtab LaunchAgent)
# Port:     9867 (default) — local only, never exposed externally
#
# Usage:
#   source "$WS/scripts/lib/pinchtab.sh"
#   pt_wait_ready
#   TAB=$(pt_new_tab "https://example.com")
#   sleep 3
#   pt_text "$TAB"
#   pt_screenshot "$TAB" /tmp/shot.jpg
#   pt_close_tab "$TAB"
# ─────────────────────────────────────────────────────────────────────────────

PT_BASE="${PT_BASE:-http://localhost:9867}"

# ── Health & readiness ────────────────────────────────────────────────────────

pt_health() {
  curl -sf "$PT_BASE/health" > /dev/null 2>&1
}

# Wait up to N seconds for pinchtab to be ready (default 20s)
pt_wait_ready() {
  local max="${1:-20}"
  local i=0
  while ! pt_health; do
    [[ $i -ge $max ]] && echo "[pinchtab] Not ready after ${max}s — is com.amalfiai.pinchtab loaded?" >&2 && return 1
    sleep 1; ((i++))
  done
  return 0
}

# ── Navigation ────────────────────────────────────────────────────────────────

# pt_nav URL [tabId]
pt_nav() {
  local url="$1"
  local tab="${2:-}"
  local body
  if [[ -n "$tab" ]]; then
    body="{\"url\":\"$url\",\"tabId\":\"$tab\"}"
  else
    body="{\"url\":\"$url\"}"
  fi
  curl -sf -X POST "$PT_BASE/navigate" -H 'Content-Type: application/json' -d "$body"
}

# pt_nav_blocking URL [tabId] — navigate and block images (faster for text-only tasks)
pt_nav_blocking() {
  local url="$1"
  local tab="${2:-}"
  local body
  if [[ -n "$tab" ]]; then
    body="{\"url\":\"$url\",\"tabId\":\"$tab\",\"blockImages\":true}"
  else
    body="{\"url\":\"$url\",\"blockImages\":true}"
  fi
  curl -sf -X POST "$PT_BASE/navigate" -H 'Content-Type: application/json' -d "$body"
}

# ── Snapshot (accessibility tree) ─────────────────────────────────────────────

# pt_snapshot [tabId] [params]
# Default: compact + interactive-only (~75% fewer tokens than full snapshot)
pt_snapshot() {
  local tab="${1:-}"
  local params="${2:-format=compact&filter=interactive}"
  local tab_param=""
  [[ -n "$tab" ]] && tab_param="&tabId=$tab"
  curl -sf "$PT_BASE/snapshot?${params}${tab_param}"
}

# pt_snapshot_full [tabId] — full accessibility tree (expensive, use sparingly)
pt_snapshot_full() {
  local tab="${1:-}"
  local tab_param=""
  [[ -n "$tab" ]] && tab_param="?tabId=$tab"
  curl -sf "$PT_BASE/snapshot${tab_param}"
}

# pt_snapshot_diff [tabId] — only changes since last snapshot (cheapest for multi-step)
pt_snapshot_diff() {
  local tab="${1:-}"
  local tab_param=""
  [[ -n "$tab" ]] && tab_param="&tabId=$tab"
  curl -sf "$PT_BASE/snapshot?format=compact&diff=true${tab_param}"
}

# ── Text extraction ───────────────────────────────────────────────────────────

# pt_text [tabId] — returns readability-mode plain text (~1K tokens, best for reading)
pt_text() {
  local tab="${1:-}"
  local tab_param=""
  [[ -n "$tab" ]] && tab_param="?tabId=$tab"
  curl -sf "$PT_BASE/text${tab_param}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('text',''))" 2>/dev/null
}

# ── Actions ───────────────────────────────────────────────────────────────────

# pt_click REF [tabId]
pt_click() {
  local ref="$1"
  local tab="${2:-}"
  local body="{\"kind\":\"click\",\"ref\":\"$ref\""
  [[ -n "$tab" ]] && body="${body},\"tabId\":\"$tab\""
  body="${body}}"
  curl -sf -X POST "$PT_BASE/action" -H 'Content-Type: application/json' -d "$body"
}

# pt_type REF TEXT [tabId]
pt_type() {
  local ref="$1"
  local text="$2"
  local tab="${3:-}"
  local text_json
  text_json=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$text")
  local body="{\"kind\":\"type\",\"ref\":\"$ref\",\"text\":$text_json"
  [[ -n "$tab" ]] && body="${body},\"tabId\":\"$tab\""
  body="${body}}"
  curl -sf -X POST "$PT_BASE/action" -H 'Content-Type: application/json' -d "$body"
}

# pt_fill SELECTOR TEXT [tabId] — set value directly (good for React controlled inputs)
pt_fill() {
  local selector="$1"
  local text="$2"
  local tab="${3:-}"
  local text_json
  text_json=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$text")
  local sel_json
  sel_json=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$selector")
  local body="{\"kind\":\"fill\",\"selector\":$sel_json,\"text\":$text_json"
  [[ -n "$tab" ]] && body="${body},\"tabId\":\"$tab\""
  body="${body}}"
  curl -sf -X POST "$PT_BASE/action" -H 'Content-Type: application/json' -d "$body"
}

# pt_press KEY [tabId]
pt_press() {
  local key="$1"
  local tab="${2:-}"
  local body="{\"kind\":\"press\",\"key\":\"$key\""
  [[ -n "$tab" ]] && body="${body},\"tabId\":\"$tab\""
  body="${body}}"
  curl -sf -X POST "$PT_BASE/action" -H 'Content-Type: application/json' -d "$body"
}

# pt_scroll [tabId] — scroll down 800px (for infinite-scroll pages)
pt_scroll() {
  local tab="${1:-}"
  local pixels="${2:-800}"
  local body="{\"kind\":\"scroll\",\"scrollY\":$pixels"
  [[ -n "$tab" ]] && body="${body},\"tabId\":\"$tab\""
  body="${body}}"
  curl -sf -X POST "$PT_BASE/action" -H 'Content-Type: application/json' -d "$body"
}

# pt_actions_json JSON [tabId] — batch actions (raw JSON array)
pt_actions_json() {
  local actions_json="$1"
  local tab="${2:-}"
  local body="{\"actions\":$actions_json"
  [[ -n "$tab" ]] && body="${body},\"tabId\":\"$tab\""
  body="${body}}"
  curl -sf -X POST "$PT_BASE/actions" -H 'Content-Type: application/json' -d "$body"
}

# ── Screenshot ────────────────────────────────────────────────────────────────

# pt_screenshot OUTFILE [tabId] [quality]
pt_screenshot() {
  local outfile="${1:-/tmp/screenshot.jpg}"
  local tab="${2:-}"
  local quality="${3:-85}"
  local tab_param=""
  [[ -n "$tab" ]] && tab_param="&tabId=$tab"
  curl -sf "$PT_BASE/screenshot?raw=true&quality=${quality}${tab_param}" -o "$outfile"
}

# ── JavaScript eval ───────────────────────────────────────────────────────────

# pt_eval EXPRESSION [tabId]
pt_eval() {
  local expr="$1"
  local tab="${2:-}"
  local expr_json
  expr_json=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$expr")
  local body="{\"expression\":$expr_json"
  [[ -n "$tab" ]] && body="${body},\"tabId\":\"$tab\""
  body="${body}}"
  curl -sf -X POST "$PT_BASE/evaluate" -H 'Content-Type: application/json' -d "$body" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('result',''))" 2>/dev/null
}

# ── Tab management ────────────────────────────────────────────────────────────

pt_tabs() {
  curl -sf "$PT_BASE/tabs"
}

# pt_new_tab [URL] — opens tab, returns tabId
pt_new_tab() {
  local url="${1:-about:blank}"
  curl -sf -X POST "$PT_BASE/tab" \
    -H 'Content-Type: application/json' \
    -d "{\"action\":\"new\",\"url\":\"$url\"}" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tabId',''))" 2>/dev/null
}

# pt_close_tab TABID
pt_close_tab() {
  local tab="$1"
  curl -sf -X POST "$PT_BASE/tab" \
    -H 'Content-Type: application/json' \
    -d "{\"action\":\"close\",\"tabId\":\"$tab\"}" > /dev/null
}

# pt_lock_tab TABID [OWNER] [TIMEOUT_SEC]
pt_lock_tab() {
  local tab="$1"
  local owner="${2:-agent-$$}"
  local timeout="${3:-120}"
  curl -sf -X POST "$PT_BASE/tab/lock" \
    -H 'Content-Type: application/json' \
    -d "{\"tabId\":\"$tab\",\"owner\":\"$owner\",\"timeoutSec\":$timeout}" > /dev/null
}

# pt_unlock_tab TABID [OWNER]
pt_unlock_tab() {
  local tab="$1"
  local owner="${2:-agent-$$}"
  curl -sf -X POST "$PT_BASE/tab/unlock" \
    -H 'Content-Type: application/json' \
    -d "{\"tabId\":\"$tab\",\"owner\":\"$owner\"}" > /dev/null
}

# ── PDF export ────────────────────────────────────────────────────────────────

# pt_pdf TABID OUTFILE
pt_pdf() {
  local tab="$1"
  local outfile="${2:-/tmp/page.pdf}"
  curl -sf "$PT_BASE/tabs/$tab/pdf?raw=true" -o "$outfile"
}

# ── Stealth ───────────────────────────────────────────────────────────────────

pt_stealth_check() {
  curl -sf "$PT_BASE/stealth/status"
}

pt_rotate_fingerprint() {
  local os="${1:-mac}"  # mac, windows, or omit for random
  curl -sf -X POST "$PT_BASE/fingerprint/rotate" \
    -H 'Content-Type: application/json' \
    -d "{\"os\":\"$os\"}" > /dev/null
}

# ── High-level helpers ────────────────────────────────────────────────────────

# pt_fetch_text URL — navigate to URL, wait 3s, return page text. Closes tab when done.
# Best for read-only research tasks.
pt_fetch_text() {
  local url="$1"
  local text=""

  pt_wait_ready 10 || return 1

  local TAB
  TAB=$(pt_new_tab "$url")
  [[ -z "$TAB" ]] && echo "[pinchtab] Failed to open tab" >&2 && return 1

  pt_lock_tab "$TAB" "fetch-$$" 60

  sleep 3  # let page render

  text=$(pt_text "$TAB")

  pt_unlock_tab "$TAB" "fetch-$$"
  pt_close_tab "$TAB"

  echo "$text"
}

# pt_screenshot_url URL OUTFILE — navigate, wait, screenshot, close
pt_screenshot_url() {
  local url="$1"
  local outfile="${2:-/tmp/screenshot.jpg}"

  pt_wait_ready 10 || return 1

  local TAB
  TAB=$(pt_new_tab "$url")
  [[ -z "$TAB" ]] && echo "[pinchtab] Failed to open tab" >&2 && return 1

  pt_lock_tab "$TAB" "ss-$$" 60
  sleep 3
  pt_screenshot "$outfile" "$TAB"
  pt_unlock_tab "$TAB" "ss-$$"
  pt_close_tab "$TAB"
}
