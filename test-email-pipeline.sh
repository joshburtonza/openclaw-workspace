#!/bin/bash
# test-email-pipeline.sh
# Automated health check for the Sophia email approval pipeline.
# Sends a real test email to josh@amalfiai.com — run to verify end-to-end.
#
# Usage: bash test-email-pipeline.sh
# Exit 0 = all checks passed. Exit 1 = something is broken.

set -euo pipefail

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
# Load service role key from env file
ENV_FILE="/Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi
SERVICE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
SCHEDULER="/Users/henryburton/.openclaw/workspace-anthropic/email-response-scheduler.sh"
TS_PROCESS="mission-control-integration.ts"
PASS=0
FAIL=0

ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
info() { echo "  ℹ️  $1"; }

echo ""
echo "=== Sophia Email Pipeline Health Check ==="
echo ""

# ── 1. Service role key can read approved rows ──────────────────────────────
echo "1. Service role key + RLS"

# Insert a canary row
CANARY=$(curl -s -X POST "${SUPABASE_URL}/rest/v1/email_queue" \
  -H "apikey: ${SERVICE_KEY}" \
  -H "Authorization: Bearer ${SERVICE_KEY}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d '{
    "from_email": "josh@amalfiai.com",
    "to_email": "josh@amalfiai.com",
    "subject": "Pipeline health check",
    "status": "approved",
    "analysis": {
      "draft_subject": "Pipeline health check",
      "draft_body": "Automated pipeline health check. The Sophia approval pipeline is working correctly."
    }
  }')

CANARY_ID=$(echo "$CANARY" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])' 2>/dev/null || echo "")
if [[ -z "$CANARY_ID" ]]; then
  fail "Could not insert test row — check service role key or Supabase connection"
  echo ""; echo "Result: 0 passed, 1+ failed. Pipeline broken."; exit 1
fi
info "Inserted test row: $CANARY_ID"

# Can the key read it back via status filter?
VISIBLE=$(curl -s "${SUPABASE_URL}/rest/v1/email_queue?status=eq.approved&select=id&id=eq.${CANARY_ID}" \
  -H "apikey: ${SERVICE_KEY}" \
  -H "Authorization: Bearer ${SERVICE_KEY}")
VISIBLE_COUNT=$(echo "$VISIBLE" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo "0")
if [[ "$VISIBLE_COUNT" == "1" ]]; then
  ok "Service role key can read status=approved rows (RLS bypassed)"
else
  fail "Service role key cannot read status=approved rows — RLS still blocking"
fi

# ── 2. mission-control-integration.ts does NOT consume approved rows ─────────
echo ""
echo "2. mission-control-integration.ts ownership check"

# Check the TS file doesn't have the approved-row send loop
if grep -q "eq('status', 'approved')" "${SCHEDULER%/*}/mission-control-integration.ts" 2>/dev/null; then
  # It queries approved — check it's just a comment, not live code
  LIVE_SEND=$(grep -A5 "eq('status', 'approved')" "${SCHEDULER%/*}/mission-control-integration.ts" | grep -v "^[[:space:]]*//" | grep -c "sendApproved" || true)
  if [[ "$LIVE_SEND" -gt 0 ]]; then
    fail "mission-control-integration.ts has a live sendApprovedEmail loop — it will steal rows"
  else
    ok "mission-control-integration.ts has no live approved-row send loop"
  fi
else
  ok "mission-control-integration.ts has no approved-row query at all"
fi

# Check the TS process is running (it should be — it handles analysis)
if pgrep -f "mission-control-integration.ts" > /dev/null 2>&1; then
  ok "mission-control-integration.ts process is running (handles Sophia analysis)"
else
  fail "mission-control-integration.ts is NOT running — Sophia analysis will stop working"
fi

# ── 3. .env.scheduler exists and has the service role key ───────────────────
echo ""
echo "3. Scheduler credentials"

ENV_FILE="${SCHEDULER%/*}/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
  if [[ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" && "$SUPABASE_SERVICE_ROLE_KEY" != "PASTE_SERVICE_ROLE_KEY_HERE" ]]; then
    ok ".env.scheduler exists and service role key is set"
  else
    fail ".env.scheduler exists but SUPABASE_SERVICE_ROLE_KEY is not set"
  fi
else
  fail ".env.scheduler not found — scheduler will fall back to anon key (RLS will block it)"
fi

# ── 4. Run scheduler — it must pick up and send the canary row ──────────────
echo ""
echo "4. End-to-end send (real email to josh@amalfiai.com)"
info "Running scheduler now..."

# Sleep briefly to ensure TS process hasn't consumed the row
sleep 2

# Confirm row is still approved
ROW_STATUS=$(curl -s "${SUPABASE_URL}/rest/v1/email_queue?id=eq.${CANARY_ID}&select=status" \
  -H "apikey: ${SERVICE_KEY}" \
  -H "Authorization: Bearer ${SERVICE_KEY}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["status"] if d else "gone")' 2>/dev/null || echo "error")

if [[ "$ROW_STATUS" == "error_send_failed" ]]; then
  LAST_ERR2=$(curl -s "${SUPABASE_URL}/rest/v1/email_queue?id=eq.${CANARY_ID}&select=last_error" \
    -H "apikey: ${SERVICE_KEY}" \
    -H "Authorization: Bearer ${SERVICE_KEY}" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0].get("last_error",""))' 2>/dev/null)
  fail "Row pre-failed before scheduler ran: ${LAST_ERR2}"
elif [[ "$ROW_STATUS" != "approved" ]]; then
  fail "Test row was consumed before scheduler ran (status=${ROW_STATUS}) — TS process may have a send loop again"
else
  # Run the scheduler
  bash "$SCHEDULER" 2>/dev/null || true

  # Give it a moment
  sleep 3

  # Check result
  RESULT=$(curl -s "${SUPABASE_URL}/rest/v1/email_queue?id=eq.${CANARY_ID}&select=status,sent_at,analysis" \
    -H "apikey: ${SERVICE_KEY}" \
    -H "Authorization: Bearer ${SERVICE_KEY}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
if not d: print("gone"); exit()
r=d[0]
print(r["status"],"|",r.get("sent_at","null"),"|",(r.get("analysis") or {}).get("gmail_message_id","null"))
' 2>/dev/null || echo "error")

  STATUS=$(echo "$RESULT" | cut -d'|' -f1 | tr -d ' ')
  SENT_AT=$(echo "$RESULT" | cut -d'|' -f2 | tr -d ' ')
  MSG_ID=$(echo "$RESULT" | cut -d'|' -f3 | tr -d ' ')

  if [[ "$STATUS" == "sent" && "$SENT_AT" != "null" && "$MSG_ID" != "null" ]]; then
    ok "Email sent successfully (gmail_message_id: ${MSG_ID})"
    ok "sent_at recorded: ${SENT_AT}"
  elif [[ "$STATUS" == "sent" && "$SENT_AT" == "null" ]]; then
    fail "Row marked sent but sent_at is null — scheduler didn't actually send it (stub behaviour?)"
  elif [[ "$STATUS" == "sending" ]]; then
    fail "Row stuck in 'sending' — gog send likely failed"
  elif [[ "$STATUS" == "error_send_failed" ]]; then
    LAST_ERR=$(curl -s "${SUPABASE_URL}/rest/v1/email_queue?id=eq.${CANARY_ID}&select=last_error" \
      -H "apikey: ${SERVICE_KEY}" \
      -H "Authorization: Bearer ${SERVICE_KEY}" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0].get("last_error",""))' 2>/dev/null)
    fail "Send failed: ${LAST_ERR}"
  elif [[ "$STATUS" == "approved" ]]; then
    fail "Row still approved after running scheduler — scheduler couldn't see or process it"
  else
    fail "Unexpected state: $RESULT"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  echo "Pipeline has issues. Check sophia-email-pipeline.md for architecture reference."
  exit 1
else
  echo "Pipeline is healthy. Check josh@amalfiai.com for the test email."
  exit 0
fi
