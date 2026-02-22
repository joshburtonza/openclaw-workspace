#!/bin/bash
# telegram-claude-gateway.sh
# Routes a Telegram message to Claude Code and sends the response back.
#
# Usage: telegram-claude-gateway.sh <chat_id> <message_text>
#
# Called by telegram-callback-poller.sh for free-text messages.
# Maintains conversation history in tmp/telegram-chat-history.jsonl

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

CHAT_ID="${1:-}"
USER_MSG="${2:-}"

if [[ -z "$CHAT_ID" || -z "$USER_MSG" ]]; then
  echo "Usage: $0 <chat_id> <message>" >&2
  exit 1
fi

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
HISTORY_FILE="$WS/tmp/telegram-chat-history.jsonl"
SYSTEM_PROMPT_FILE="$WS/prompts/telegram-claude-system.md"
mkdir -p "$WS/tmp"

# ── Send a Telegram message ───────────────────────────────────────────────────
tg_send() {
  local text="$1"
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{
      \"chat_id\": \"${CHAT_ID}\",
      \"text\": $(echo "$text" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
      \"parse_mode\": \"Markdown\"
    }" >/dev/null 2>&1 || true
}

# ── Send typing indicator ─────────────────────────────────────────────────────
tg_typing() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendChatAction" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\": \"${CHAT_ID}\", \"action\": \"typing\"}" >/dev/null 2>&1 || true
}

# ── Build conversation history (last 10 exchanges) ───────────────────────────
HISTORY=""
if [[ -f "$HISTORY_FILE" ]]; then
  HISTORY=$(tail -20 "$HISTORY_FILE" | python3 -c "
import sys, json
lines = [l.strip() for l in sys.stdin if l.strip()]
parts = []
for line in lines:
    try:
        obj = json.loads(line)
        role = obj.get('role','?')
        msg  = obj.get('message','')
        parts.append(f'{role}: {msg}')
    except:
        pass
print('\n'.join(parts))
" 2>/dev/null || true)
fi

# ── Build the full prompt ─────────────────────────────────────────────────────
SYSTEM_PROMPT=$(cat "$SYSTEM_PROMPT_FILE" 2>/dev/null || echo "You are Claude, Amalfi AI's AI assistant.")
TODAY=$(date '+%A, %d %B %Y %H:%M SAST')

if [[ -n "$HISTORY" ]]; then
  FULL_PROMPT="${SYSTEM_PROMPT}

Today: ${TODAY}

Recent conversation:
${HISTORY}

Josh: ${USER_MSG}"
else
  FULL_PROMPT="${SYSTEM_PROMPT}

Today: ${TODAY}

Josh: ${USER_MSG}"
fi

# ── Store the user message in history ────────────────────────────────────────
echo "{\"role\":\"Josh\",\"message\":$(echo "$USER_MSG" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')}" >> "$HISTORY_FILE"

# ── Show typing indicator ─────────────────────────────────────────────────────
tg_typing

# ── Run Claude ───────────────────────────────────────────────────────────────
unset CLAUDECODE
PROMPT_TMP=$(mktemp /tmp/tg-prompt-XXXXXX.txt)
echo "$FULL_PROMPT" > "$PROMPT_TMP"
RESPONSE=$(claude --print \
  --dangerously-skip-permissions \
  --model claude-sonnet-4-6 \
  --add-dir "$WS" \
  < "$PROMPT_TMP" 2>/dev/null)
rm -f "$PROMPT_TMP"

# ── Send response back to Telegram ───────────────────────────────────────────
if [[ -n "$RESPONSE" ]]; then
  # Telegram has 4096 char limit — split if needed
  if [[ ${#RESPONSE} -le 4000 ]]; then
    tg_send "$RESPONSE"
  else
    # Split on double newlines
    echo "$RESPONSE" | python3 - <<PY
import os, subprocess, sys

BOT_TOKEN = os.environ.get('BOT_TOKEN','')
CHAT_ID   = '${CHAT_ID}'
text = sys.stdin.read()

chunks = []
current = ''
for para in text.split('\n\n'):
    if len(current) + len(para) + 2 > 3800:
        if current:
            chunks.append(current.strip())
        current = para
    else:
        current += ('\n\n' if current else '') + para
if current:
    chunks.append(current.strip())

for chunk in chunks:
    subprocess.run([
        'curl','-s','-X','POST',
        f'https://api.telegram.org/bot{BOT_TOKEN}/sendMessage',
        '-H','Content-Type: application/json',
        '-d', __import__('json').dumps({
            'chat_id': CHAT_ID,
            'text': chunk,
            'parse_mode': 'Markdown',
        })
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PY
  fi

  # Store response in history
  echo "{\"role\":\"Claude\",\"message\":$(echo "$RESPONSE" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')}" >> "$HISTORY_FILE"
else
  tg_send "_(no response)_"
fi
