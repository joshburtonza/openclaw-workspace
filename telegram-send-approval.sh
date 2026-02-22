#!/bin/bash
# telegram-send-approval.sh
# Send a Telegram approval card with inline buttons (Approve / Adjust / Reject)
# Usage:
#   telegram-send-approval.sh EMAIL_ID CLIENT SUBJECT FROM_EMAIL INBOUND_BODY DRAFT_RESPONSE
#   telegram-send-approval.sh fyi EMAIL_ID CLIENT SUBJECT FROM_EMAIL DRAFT_RESPONSE SCHEDULED_AT

set -euo pipefail

# ── FYI card mode (auto_pending) ──────────────────────────────────────────────
if [[ "${1:-}" == "fyi" ]]; then
  FYI_EMAIL_ID="${2:-}"
  FYI_CLIENT="${3:-}"
  FYI_SUBJECT="${4:-}"
  FYI_FROM_EMAIL="${5:-}"
  FYI_DRAFT="${6:-}"
  FYI_SCHEDULED_AT="${7:-}"

  if [[ -z "$FYI_EMAIL_ID" || -z "$FYI_SUBJECT" || -z "$FYI_FROM_EMAIL" ]]; then
    echo "Usage: $0 fyi EMAIL_ID CLIENT SUBJECT FROM_EMAIL DRAFT_RESPONSE SCHEDULED_AT" >&2
    exit 1
  fi

  # Load secrets from env file
  _ENV_FILE="/Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler"
  if [[ -f "$_ENV_FILE" ]]; then source "$_ENV_FILE"; fi
  BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
  _CHAT_ID_FILE="/Users/henryburton/.openclaw/workspace-anthropic/tmp/josh_private_chat_id"
  CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-$(cat "$_CHAT_ID_FILE" 2>/dev/null || echo "1140320036")}"
  SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
  ANON_KEY="${SUPABASE_ANON_KEY:-}"

  case "$FYI_CLIENT" in
    ascend_lc) FYI_CLIENT_LABEL="Ascend LC" ;;
    favorite_logistics) FYI_CLIENT_LABEL="Favorite Logistics" ;;
    race_technik) FYI_CLIENT_LABEL="Race Technik" ;;
    *) FYI_CLIENT_LABEL="$FYI_CLIENT" ;;
  esac

  # Compute minutes remaining from scheduled_send_at
  MINS_LEFT=$(python3 - <<PY
import sys
from datetime import datetime, timezone
try:
    sched = datetime.fromisoformat('${FYI_SCHEDULED_AT}'.replace('Z','+00:00'))
    now   = datetime.now(timezone.utc)
    mins  = max(0, int((sched - now).total_seconds() / 60))
    print(mins)
except Exception:
    print(30)
PY
)

  DRAFT_TRIM=$(python3 - <<PY
s = '''${FYI_DRAFT}'''.replace('\r','').strip()
if len(s) > 700:
    s = s[:700].rstrip() + '…'
print(s)
PY
)

  FYI_MESSAGE=$(cat <<EOF
⚡ AUTO-SEND in ${MINS_LEFT}min — ${FYI_CLIENT_LABEL}

From: ${FYI_FROM_EMAIL}
Subject: ${FYI_SUBJECT}

Sophia draft:
${DRAFT_TRIM}
EOF
)

  RESP=$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{
      \"chat_id\": \"${CHAT_ID}\",
      \"text\": $(echo "$FYI_MESSAGE" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
      \"reply_markup\": {
        \"inline_keyboard\": [[
          {\"text\": \"🚫 Hold\", \"callback_data\": \"hold:${FYI_EMAIL_ID}\"}
        ]]
      }
    }")

  TG_MSG_ID=$(echo "$RESP" | python3 -c 'import sys,json; d=json.load(sys.stdin); print((d.get("result") or {}).get("message_id") or "")' 2>/dev/null || true)
  if [[ -n "$TG_MSG_ID" ]]; then
    curl -s -X PATCH "${SUPABASE_URL}/rest/v1/email_queue?id=eq.${FYI_EMAIL_ID}" \
      -H "Content-Type: application/json" \
      -H "apikey: ${ANON_KEY}" \
      -H "Authorization: Bearer ${ANON_KEY}" \
      -d "{\"approval_telegram_message_id\": \"${TG_MSG_ID}\", \"approval_telegram_sent_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
      >/dev/null 2>&1 || true
  fi

  echo "Sent FYI card for email_id=$FYI_EMAIL_ID"
  exit 0
fi

# ── Standard approval card mode ───────────────────────────────────────────────
EMAIL_ID="${1:-}"
CLIENT="${2:-}"
SUBJECT="${3:-}"
FROM_EMAIL="${4:-}"
INBOUND_BODY="${5:-}"
DRAFT_RESPONSE="${6:-}"

if [[ -z "$EMAIL_ID" || -z "$SUBJECT" || -z "$FROM_EMAIL" ]]; then
  echo "Usage: $0 EMAIL_ID CLIENT SUBJECT FROM_EMAIL INBOUND_BODY DRAFT_RESPONSE" >&2
  exit 1
fi

# Load secrets from env file
ENV_FILE="/Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
_CHAT_ID_FILE="/Users/henryburton/.openclaw/workspace-anthropic/tmp/josh_private_chat_id"
CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-$(cat "$_CHAT_ID_FILE" 2>/dev/null || echo "1140320036")}"

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
ANON_KEY="${SUPABASE_ANON_KEY:-}"

case "$CLIENT" in
  ascend_lc) CLIENT_LABEL="Ascend LC" ;;
  favorite_logistics) CLIENT_LABEL="Favorite Logistics" ;;
  race_technik) CLIENT_LABEL="Race Technik" ;;
  *) CLIENT_LABEL="$CLIENT" ;;
esac

# Keep messages compact for mobile
# Also strip quoted thread history so you only see the latest inbound.
INBOUND_TRIM=$(python3 - <<PY
import re
s = '''${INBOUND_BODY}'''.replace('\r','').strip()

# Common reply separators (Outlook/Gmail)
seps = [
  r'^_{5,}$',                 # _________
  r'^From:\s',                # From:
  r'^On .*wrote:$',            # On ... wrote:
  r'^-----Original Message-----$',
]

lines = s.split('\n')
out=[]
for line in lines:
  if any(re.match(p, line.strip(), flags=re.IGNORECASE) for p in seps):
    break
  out.append(line)

s='\n'.join(out).strip()
# If still contains the user's previous email quoted below, do a second pass for a long underline block
s = re.split(r'\n_{10,}\n', s, maxsplit=1)[0].strip()

if len(s) > 700:
  s = s[:700].rstrip() + '…'
print(s)
PY
)

DRAFT_TRIM=$(python3 - <<PY
s = '''${DRAFT_RESPONSE}'''.replace('\r','').strip()
if len(s) > 900:
  s = s[:900].rstrip() + '…'
print(s)
PY
)

MESSAGE=$(cat <<EOF
🟠 APPROVAL NEEDED — ${CLIENT_LABEL}

From: ${FROM_EMAIL}
Subject: ${SUBJECT}

Latest inbound:
${INBOUND_TRIM}

Sophia draft:
${DRAFT_TRIM}
EOF
)

RESP=$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "{
    \"chat_id\": \"${CHAT_ID}\",
    \"text\": $(echo "$MESSAGE" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
    \"reply_markup\": {
      \"inline_keyboard\": [[
        {\"text\": \"✅ Approve\", \"callback_data\": \"approve:${EMAIL_ID}\"},
        {\"text\": \"✏️ Adjust\", \"callback_data\": \"adjust:${EMAIL_ID}\"},
        {\"text\": \"⏸ Hold\", \"callback_data\": \"hold:${EMAIL_ID}\"}
      ]]
    }
  }")

# If the DB has approval_telegram_message_id/approval_telegram_sent_at columns,
# store them so we can edit the same card later (prevents duplicates).
TG_MSG_ID=$(echo "$RESP" | python3 -c 'import sys,json; d=json.load(sys.stdin); print((d.get("result") or {}).get("message_id") or "")' 2>/dev/null || true)
if [[ -n "$TG_MSG_ID" ]]; then
  # best-effort patch; ignore failure if columns not present yet
  curl -s -X PATCH "${SUPABASE_URL}/rest/v1/email_queue?id=eq.${EMAIL_ID}" \
    -H "Content-Type: application/json" \
    -H "apikey: ${ANON_KEY}" \
    -H "Authorization: Bearer ${ANON_KEY}" \
    -d "{\"approval_telegram_message_id\": \"${TG_MSG_ID}\", \"approval_telegram_sent_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
    >/dev/null 2>&1 || true
fi

echo "Sent approval card for email_id=$EMAIL_ID"