#!/bin/bash
# wa-weekly-brief.sh
# Sends weekly WhatsApp updates to all active client groups.
# Replaces the email-based sophia-followup pipeline.
#
# Schedule: Fridays at 15:00 SAST
# Usage: bash wa-weekly-brief.sh

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"

# Safe env extraction — avoids sourcing lines with unquoted spaces (e.g. Puppeteer path)
_env_get() { grep "^${1}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true; }
export AOS_SUPABASE_URL="$(_env_get AOS_SUPABASE_URL)"
export SUPABASE_SERVICE_ROLE_KEY="$(_env_get SUPABASE_SERVICE_ROLE_KEY)"

SOPHIA_PROMPT="$WS/prompts/sophia-whatsapp-group.md"
CONTEXT_SCRIPT="$WS/scripts/sophia-context.sh"
WA_API="http://127.0.0.1:3001/send"
LOG="$WS/out/wa-weekly-brief.log"
KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# Kill switch check
if [[ -f "${HOME}/.openclaw/KILL_SWITCH" ]]; then
  log "KILL SWITCH active — wa-weekly-brief suppressed"
  exit 0
fi

TODAY=$(date '+%A, %d %B %Y, %H:%M SAST')
SOPHIA_IDENTITY=$(cat "$SOPHIA_PROMPT" 2>/dev/null || echo "You are Sophia, Amalfi AI's Client Success Manager.")

# ── Per-client brief function (bash 3.2 compat) ───────────────────────────────
send_brief() {
  local SLUG="$1"          # e.g. race_technik
  local GROUP="$2"         # exact/partial WA group name
  local CTX_SLUG="$3"      # sophia-context.sh slug
  local REPO_DIR="$4"      # relative path under clients/

  log "Processing $SLUG ($GROUP)..."

  # Billing gate
  if [[ -n "$KEY" ]]; then
    export _BG_SLUG="$SLUG"
    BILLING_STATUS=$(python3 - <<'PY'
import urllib.request, json, os
KEY  = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
URL  = os.environ.get('AOS_SUPABASE_URL', 'https://afmpbtynucpbglwtbfuz.supabase.co')
SLUG = os.environ['_BG_SLUG']
try:
    req = urllib.request.Request(
        f"{URL}/rest/v1/client_os_registry?slug=eq.{SLUG}&select=status",
        headers={'apikey': KEY, 'Authorization': f'Bearer {KEY}'},
    )
    with urllib.request.urlopen(req, timeout=8) as r:
        rows = json.loads(r.read())
    print(rows[0].get('status', 'active') if rows else 'active')
except Exception:
    print('active')
PY
    )
    if [[ "$BILLING_STATUS" == "paused" || "$BILLING_STATUS" == "stopped" ]]; then
      log "  $SLUG is $BILLING_STATUS — skipping"
      return 0
    fi
  fi

  # Build context
  log "  Building context..."
  CLIENT_CONTEXT=$(bash "$CONTEXT_SCRIPT" "$CTX_SLUG" 2>/dev/null || echo "(context unavailable)")

  STATIC_CONTEXT=""
  [[ -f "$WS/$REPO_DIR/CONTEXT.md" ]]    && STATIC_CONTEXT=$(cat "$WS/$REPO_DIR/CONTEXT.md")
  DEV_STATUS=""
  [[ -f "$WS/$REPO_DIR/DEV_STATUS.md" ]] && DEV_STATUS=$(cat "$WS/$REPO_DIR/DEV_STATUS.md")

  # Draft via Claude
  TMPFILE=$(mktemp /tmp/wa-brief-XXXXXX)
  trap 'rm -f "$TMPFILE"' EXIT

  cat > "$TMPFILE" <<PROMPT
${SOPHIA_IDENTITY}

Today: ${TODAY}

You are sending a proactive weekly update to the ${GROUP} WhatsApp group.

=== CLIENT CONTEXT ===
${STATIC_CONTEXT}

=== CURRENT DEV STATUS ===
${DEV_STATUS}

=== DETAILED CONTEXT (commits, meetings, notes) ===
${CLIENT_CONTEXT}

=== TASK ===
Draft a short, natural WhatsApp weekly update for the ${GROUP} group.

Cover:
- What was shipped or progressed this week (be specific, reference actual features or fixes)
- What is actively in progress or coming next
- Any action needed from the client (only if genuinely relevant)

Rules:
- Conversational WhatsApp tone, not a report
- 2 to 4 short paragraphs max
- No hyphens anywhere. No bullet-pointed walls of text
- Sophia voice: warm, intelligent, feminine, direct. She knows this business cold
- Do NOT start with "Hi team" or "Hope everyone is well" — start right in
- Do NOT reference email or previous emails
- If nothing notable to report, send a brief friendly check-in instead
- Output ONLY the message text, nothing else
PROMPT

  unset CLAUDECODE
  RESPONSE=$(claude --print --model claude-sonnet-4-6 --dangerously-skip-permissions < "$TMPFILE" 2>/dev/null || echo "")
  rm -f "$TMPFILE"

  if [[ -z "$RESPONSE" ]]; then
    log "  ERROR: no response from Claude for $SLUG"
    return 0
  fi

  log "  Draft ready (${#RESPONSE} chars)"

  # Send via gateway API
  export _WA_MSG="$RESPONSE" _WA_GROUP="$GROUP"
  SEND_RESULT=$(python3 - <<'PY'
import urllib.request, json, os, sys
try:
    payload = json.dumps({'to': os.environ['_WA_GROUP'], 'message': os.environ['_WA_MSG']}).encode()
    req = urllib.request.Request(
        'http://127.0.0.1:3001/send',
        data=payload,
        headers={'Content-Type': 'application/json'},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        print(json.loads(r.read()))
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PY
  )
  unset _WA_MSG _WA_GROUP
  log "  Sent to '$GROUP': $SEND_RESULT"
}

# ── Run all clients ───────────────────────────────────────────────────────────
send_brief "race_technik"       "Race Technik"     "race_technik"       "clients/chrome-auto-care"
send_brief "ascend_lc"          "Project - EDITH"  "ascend_lc"          "clients/qms-guard"
send_brief "favorite_logistics" "Logistics"        "favorite_logistics" "clients/favorite-flow-9637aff2"
send_brief "vanta_studios"      "Vanta Studios"    "vanta_studios"      "clients/vanta-studios"
send_brief "ambassadex"         "AMBASSADEX"       "ambassadex"         "clients/ambassadex"

log "wa-weekly-brief complete"
