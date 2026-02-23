#!/bin/bash
# tiktok-live-reminder.sh
# Fires on Mon/Wed/Fri at 19:30 SAST (30-min warning) and 20:00 SAST (go live).
# Checks current minute to decide which message to send.

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ENV_FILE="/Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID=$(cat /Users/henryburton/.openclaw/workspace-anthropic/tmp/josh_private_chat_id 2>/dev/null || echo "")
[[ -z "$CHAT_ID" ]] && exit 0

tg_send() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":\"$1\",\"parse_mode\":\"HTML\"}" \
    >/dev/null
}

MINUTE=$(date '+%M')

if [[ "$MINUTE" == "30" ]]; then
  tg_send "🔴 <b>TikTok Live in 30 minutes</b>

You're on at 8pm. Get set up — lighting, camera, topic ready."
else
  tg_send "🔴 <b>TikTok Live — GO NOW</b>

8pm. You're live tonight. Open TikTok and hit Go Live."
fi
