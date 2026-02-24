#!/usr/bin/env bash
# sophia-outbound-poller.sh — Race Technik Mac Mini
# Checks Supabase email_queue for pending outbound emails and processes them.
# Sends via gog gmail on behalf of Race Technik.
# Runs every 5 minutes via LaunchAgent.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

WORKSPACE="${HOME}/.amalfiai/workspace"
ENV_FILE="${WORKSPACE}/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
API_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"

if [[ -z "$API_KEY" ]]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") ERROR: SUPABASE_SERVICE_ROLE_KEY not set" >&2
  exit 1
fi

# Check for pending outbound emails assigned to race-technik machine
TASK_RAW=$(curl -s \
  "${SUPABASE_URL}/rest/v1/email_queue?status=eq.pending&machine_id=eq.race-technik&select=*&order=created_at.asc&limit=1" \
  -H "apikey: ${API_KEY}" -H "Authorization: Bearer ${API_KEY}" 2>/dev/null || echo "[]")

TASK_DATA=$(echo "$TASK_RAW" | python3 -c "
import json, os, sys
rows = json.loads(sys.stdin.read())
if not rows:
    print('')
    sys.exit(0)
r = rows[0]
print(r['id'] + '|' + r.get('to_email','') + '|' + r.get('subject','') + '|' + (r.get('body') or r.get('analysis',{}).get('draft_body',''))[:2000])
" 2>/dev/null || echo "")

if [[ -z "$TASK_DATA" ]]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") No pending emails"
  exit 0
fi

TASK_ID=$(echo "$TASK_DATA" | cut -d'|' -f1)
TO_EMAIL=$(echo "$TASK_DATA" | cut -d'|' -f2)
SUBJECT=$(echo "$TASK_DATA" | cut -d'|' -f3)
BODY=$(echo "$TASK_DATA" | cut -d'|' -f4-)

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Processing email $TASK_ID → $TO_EMAIL"

if [[ -z "$TO_EMAIL" || -z "$SUBJECT" || -z "$BODY" ]]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") ERROR: Missing email fields" >&2
  exit 1
fi

# Mark as in_progress
curl -s -X PATCH \
  "${SUPABASE_URL}/rest/v1/email_queue?id=eq.${TASK_ID}" \
  -H "apikey: ${API_KEY}" -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" -H "Prefer: return=minimal" \
  -d "{\"status\":\"in_progress\"}" >/dev/null 2>&1 || true

# Send email using gog gmail
if command -v gog >/dev/null 2>&1; then
  SEND_RESULT=$(gog gmail send \
    --account "josh@amalfiai.com" \
    --to "$TO_EMAIL" \
    --subject "$SUBJECT" \
    --body "$BODY" 2>&1 || echo "FAILED")

  if echo "$SEND_RESULT" | grep -qi "FAILED\|error"; then
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Email send failed: $SEND_RESULT" >&2
    curl -s -X PATCH \
      "${SUPABASE_URL}/rest/v1/email_queue?id=eq.${TASK_ID}" \
      -H "apikey: ${API_KEY}" -H "Authorization: Bearer ${API_KEY}" \
      -H "Content-Type: application/json" -H "Prefer: return=minimal" \
      -d "{\"status\":\"failed\"}" >/dev/null 2>&1 || true
    exit 1
  fi
fi

# Mark as sent
curl -s -X PATCH \
  "${SUPABASE_URL}/rest/v1/email_queue?id=eq.${TASK_ID}" \
  -H "apikey: ${API_KEY}" -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" -H "Prefer: return=minimal" \
  -d "{\"status\":\"sent\"}" >/dev/null 2>&1 || true

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Email sent to $TO_EMAIL"
