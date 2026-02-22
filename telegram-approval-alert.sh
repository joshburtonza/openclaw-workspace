#!/bin/bash
# telegram-approval-alert.sh
# Sends Telegram message to Josh with Approve/Reject inline buttons when Sophia detects escalation
# Usage: ./telegram-approval-alert.sh "EMAIL_ID" "CLIENT" "SUBJECT" "FROM_EMAIL" "REASON"

EMAIL_ID="${1}"
CLIENT="${2}"
SUBJECT="${3}"
FROM_EMAIL="${4}"
REASON="${5}"

# Load secrets from env file
ENV_FILE="$(dirname "$0")/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="1140320036"

# Format client name nicely
case "$CLIENT" in
  ascend_lc) CLIENT_LABEL="Ascend LC" ;;
  favorite_logistics) CLIENT_LABEL="Favorite Logistics" ;;
  race_technik) CLIENT_LABEL="Race Technik" ;;
  *) CLIENT_LABEL="$CLIENT" ;;
esac

MESSAGE="🚨 ESCALATION — ${CLIENT_LABEL}

From: ${FROM_EMAIL}
Subject: ${SUBJECT}

Reason: ${REASON}

Sophia is holding the response until you decide."

# Send with inline keyboard
curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "{
    \"chat_id\": \"${CHAT_ID}\",
    \"text\": $(echo "$MESSAGE" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
    \"parse_mode\": \"HTML\",
    \"reply_markup\": {
      \"inline_keyboard\": [[
        {\"text\": \"✅ Approve — Send Response\", \"callback_data\": \"approve:${EMAIL_ID}\"},
        {\"text\": \"❌ Reject — Hold\", \"callback_data\": \"reject:${EMAIL_ID}\"}
      ]]
    }
  }"

echo ""
echo "Telegram escalation alert sent for email ID: ${EMAIL_ID}"
