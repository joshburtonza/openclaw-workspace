#!/usr/bin/env bash
# discord-morning-nudge.sh — posts a morning nudge to Amalfi AI Discord #general-chat
# Runs at 07:00 SAST (05:00 UTC) via LaunchAgent
set -euo pipefail

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WORKSPACE/.env.scheduler"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
unset CLAUDECODE

source "$ENV_FILE"

DISCORD_TOKEN="${DISCORD_BOT_TOKEN:-}"
CHANNEL_ID="${DISCORD_CHANNEL_ID:-1445341780747878460}"
DOW=$(date +%A)  # Monday, Tuesday, etc.
DATE_STR=$(date +"%B %-d")

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Generating Discord nudge for $DOW $DATE_STR"

PROMPT_TMP=$(mktemp /tmp/discord-nudge-XXXXXX)
cat > "$PROMPT_TMP" << PROMPT
You are Alex Claww, the energetic mascot of Amalfi AI. Write ONE short morning Discord message to post in #general-chat.

Today is $DOW, $DATE_STR.

Rules:
- 1-2 sentences max
- Keep it punchy and genuine — not corporate
- Vary the vibe: sometimes a question, sometimes motivation, sometimes a challenge, sometimes just vibes
- South African team, casual tone
- Do NOT use "Goooood morning" or clichés like "rise and grind"
- No hashtags
- Emojis are fine but don't overdo it

Examples of good messages:
- "Morning 👋 What's everyone grinding on today?"
- "New day, new wins. What's the one thing you're shipping today?"
- "Quick check-in: what moved forward yesterday?"
- "Reminder: progress > perfection. What's on deck?"

Reply with ONLY the message text. No quotes, no preamble.
PROMPT

MSG=$(bash "$WORKSPACE/scripts/lib/openai-complete.sh" --model gpt-4o < "$PROMPT_TMP" 2>/dev/null | head -3)
rm -f "$PROMPT_TMP"

if [[ -z "$MSG" ]]; then
  MSG="Morning 👋 What's everyone working on today?"
fi

echo "  Message: $MSG"

# Post to Discord
RESPONSE=$(curl -s -X POST \
  "https://discord.com/api/v10/channels/${CHANNEL_ID}/messages" \
  -H "Authorization: Bot ${DISCORD_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"content\": $(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$MSG")}")

MSG_ID=$(echo "$RESPONSE" | python3 -c 'import json,sys; r=json.loads(sys.stdin.read()); print(r.get("id","?"))' 2>/dev/null || echo "?")

if [[ "$MSG_ID" == "?" ]]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") ERROR: Discord post failed: $RESPONSE" >&2
  exit 1
fi

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Discord nudge posted (msg $MSG_ID)"
