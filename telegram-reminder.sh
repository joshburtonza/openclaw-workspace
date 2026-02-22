#!/bin/bash
# telegram-reminder.sh
# Sends a Telegram notification for a reminder or calendar event
# Usage: ./telegram-reminder.sh "TITLE" "BODY" "DUE_TIME"

TITLE="${1}"
BODY="${2}"
DUE="${3}"

# Load secrets from env file
ENV_FILE="/Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="1140320036"

# Build message
if [ -n "$DUE" ]; then
  MESSAGE="🔔 REMINDER

${TITLE}

${BODY}

Due: ${DUE}"
else
  MESSAGE="🔔 REMINDER

${TITLE}

${BODY}"
fi

curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "{
    \"chat_id\": \"${CHAT_ID}\",
    \"text\": $(echo "$MESSAGE" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
    \"parse_mode\": \"HTML\"
  }" > /dev/null

echo "[telegram-reminder] Sent: $TITLE"
