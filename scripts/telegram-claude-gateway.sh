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
GROUP_HISTORY_FILE="${3:-}"   # optional: path to group chat history jsonl

if [[ -z "$CHAT_ID" || -z "$USER_MSG" ]]; then
  echo "Usage: $0 <chat_id> <message> [group_history_file]" >&2
  exit 1
fi

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
HISTORY_FILE="$WS/tmp/telegram-chat-history.jsonl"
SYSTEM_PROMPT_FILE="$WS/prompts/telegram-claude-system.md"
mkdir -p "$WS/tmp"

# In group chats: small random delay to avoid responding simultaneously with other bots
if [[ -n "$GROUP_HISTORY_FILE" ]]; then
  sleep $(python3 -c "import random; print(round(random.uniform(1.0, 2.5), 1))")
fi

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

# ── Build conversation history ────────────────────────────────────────────────
HISTORY=""

if [[ -n "$GROUP_HISTORY_FILE" && -f "$GROUP_HISTORY_FILE" ]]; then
  # Group chat: use shared history (includes messages from all bots + humans)
  HISTORY=$(tail -40 "$GROUP_HISTORY_FILE" | python3 -c "
import sys, json
lines = [l.strip() for l in sys.stdin if l.strip()]
parts = []
for line in lines:
    try:
        obj = json.loads(line)
        role = obj.get('role','?')
        msg  = obj.get('message','')
        ts   = obj.get('ts','')
        prefix = f'[{ts}] ' if ts else ''
        parts.append(f'{prefix}{role}: {msg}')
    except:
        pass
print('\n'.join(parts))
" 2>/dev/null || true)
elif [[ -f "$HISTORY_FILE" ]]; then
  # Private chat: use personal history
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

# Load persistent memory context
LONG_TERM_MEMORY=$(cat "$WS/memory/MEMORY.md" 2>/dev/null || echo "")
CURRENT_STATE=$(cat "$WS/CURRENT_STATE.md" 2>/dev/null || echo "")

# Inject group chat context
if [[ -n "$GROUP_HISTORY_FILE" ]]; then
  GROUP_CONTEXT="
━━━ GROUP CHAT MODE ━━━

You are @JoshAmalfiBot in a group Telegram chat alongside other bots and humans.

Other bots in this group:
- @RaceTechnikAiBot — handles Race Technik operations (Mac mini, Supabase DB, bookings, Yoco payments, PWA dashboard, process templates). When it says something, listen and internalise it.

Rules for group chats:
- You were mentioned with @JoshAmalfiBot — respond to that specific request only
- READ the full conversation history above carefully — it includes messages from other bots and humans
- Do NOT re-introduce yourself or repeat what others just said
- Be concise — group chats, not essays
- If another bot gave an update and you're asked to act on it, reference it specifically: \"based on what RaceTechnikAiBot said about the Mac mini stack...\"
- Do NOT respond to messages not directed at you
- Tone: natural, human — like a colleague in a group chat
"
else
  GROUP_CONTEXT=""
fi

MEMORY_BLOCK=""
if [[ -n "$LONG_TERM_MEMORY" ]]; then
  MEMORY_BLOCK="
=== LONG-TERM MEMORY ===
${LONG_TERM_MEMORY}

=== CURRENT SYSTEM STATE ===
${CURRENT_STATE}
"
fi

if [[ -n "$HISTORY" ]]; then
  FULL_PROMPT="${SYSTEM_PROMPT}${GROUP_CONTEXT}
Today: ${TODAY}
${MEMORY_BLOCK}
=== RECENT CONVERSATION ===
${HISTORY}

Josh: ${USER_MSG}"
else
  FULL_PROMPT="${SYSTEM_PROMPT}${GROUP_CONTEXT}
Today: ${TODAY}
${MEMORY_BLOCK}
Josh: ${USER_MSG}"
fi

# ── Store the user message in history ────────────────────────────────────────
# In group chats, messages are already logged by the poller — skip to avoid duplicates
if [[ -z "$GROUP_HISTORY_FILE" ]]; then
  echo "{\"role\":\"Josh\",\"message\":$(echo "$USER_MSG" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')}" >> "$HISTORY_FILE"
fi

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
  if [[ -n "$GROUP_HISTORY_FILE" ]]; then
    # Write bot's own response to the shared group history
    TS=$(date '+%H:%M')
    echo "{\"ts\":\"${TS}\",\"role\":\"JoshAmalfiBot\",\"is_bot\":true,\"message\":$(echo "$RESPONSE" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')}" >> "$GROUP_HISTORY_FILE"
  else
    echo "{\"role\":\"Claude\",\"message\":$(echo "$RESPONSE" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')}" >> "$HISTORY_FILE"

    # Append to daily conversation log (feeds weekly-memory.sh distillation)
    TODAY_LOG="$WS/memory/$(date '+%Y-%m-%d').md"
    {
      echo ""
      echo "### $(date '+%H:%M SAST') — Telegram"
      echo "**Josh:** $USER_MSG"
      echo "**Claude:** $RESPONSE"
    } >> "$TODAY_LOG"
  fi
else
  tg_send "_(no response)_"
fi
