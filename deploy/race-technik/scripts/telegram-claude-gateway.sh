#!/bin/bash
# telegram-claude-gateway.sh — Race Technik Mac Mini
# Routes a Telegram message to Claude Code and returns the response.
# Usage: telegram-claude-gateway.sh <chat_id> <message_text> [username]

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

CHAT_ID="${1:-}"
USER_MSG="${2:-}"
USERNAME="${3:-User}"

if [[ -z "$CHAT_ID" || -z "$USER_MSG" ]]; then
  echo "Usage: $0 <chat_id> <message> [username]" >&2
  exit 1
fi

WS="${HOME}/.amalfiai/workspace"
ENV_FILE="${WS}/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
FARHAAN_CHAT_ID="${TELEGRAM_CHAT_ID:-1173308443}"

# Resolve display name from chat_id
if [[ "$CHAT_ID" == "$FARHAAN_CHAT_ID" ]]; then
  DISPLAY_NAME="Farhaan"
else
  DISPLAY_NAME="${USERNAME}"
fi

HISTORY_FILE="${WS}/tmp/telegram-chat-history-${CHAT_ID}.jsonl"
SYSTEM_PROMPT_FILE="${WS}/prompts/telegram-claude-system.md"
mkdir -p "${WS}/tmp"

# ── Show typing indicator ─────────────────────────────────────────────────────
curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendChatAction" \
  -H "Content-Type: application/json" \
  -d "{\"chat_id\":\"${CHAT_ID}\",\"action\":\"typing\"}" >/dev/null 2>&1 || true

# ── Build conversation history ────────────────────────────────────────────────
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

# ── Load system prompt and context ───────────────────────────────────────────
DEFAULT_SYSTEM_PROMPT="You are the AI assistant for Race Technik, a premium automotive care business in South Africa.

You help Farhaan and Yaseen (the Race Technik team) with:
- Business operations and customer management
- The Race Technik booking platform (chrome-auto-care)
- Scheduling, services, and pricing
- General questions and tasks

Be direct, helpful, and concise. You have access to the workspace tools.
No hyphens in your responses — use em dashes (—) or just rephrase instead."

SYSTEM_PROMPT=$(cat "$SYSTEM_PROMPT_FILE" 2>/dev/null || echo "$DEFAULT_SYSTEM_PROMPT")
TODAY=$(date '+%A, %d %B %Y %H:%M SAST')

MEMORY_CONTEXT=$(cat "${WS}/memory/MEMORY.md" 2>/dev/null || echo "")
CURRENT_STATE=$(cat "${WS}/CURRENT_STATE.md" 2>/dev/null || echo "")

MEMORY_BLOCK=""
if [[ -n "$MEMORY_CONTEXT" ]]; then
  MEMORY_BLOCK="
=== RACE TECHNIK CONTEXT ===
${MEMORY_CONTEXT}

=== CURRENT STATE ===
${CURRENT_STATE}
"
fi

if [[ -n "$HISTORY" ]]; then
  FULL_PROMPT="${SYSTEM_PROMPT}
Today: ${TODAY}
${MEMORY_BLOCK}
=== RECENT CONVERSATION ===
${HISTORY}

${DISPLAY_NAME}: ${USER_MSG}"
else
  FULL_PROMPT="${SYSTEM_PROMPT}
Today: ${TODAY}
${MEMORY_BLOCK}
${DISPLAY_NAME}: ${USER_MSG}"
fi

# ── Store user message ────────────────────────────────────────────────────────
echo "{\"role\":\"${DISPLAY_NAME}\",\"message\":$(echo "$USER_MSG" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')}" >> "$HISTORY_FILE"

# ── Run Claude ────────────────────────────────────────────────────────────────
unset CLAUDECODE
PROMPT_TMP=$(mktemp /tmp/rt-tg-prompt-XXXXXX)
echo "$FULL_PROMPT" > "$PROMPT_TMP"

RESPONSE=$(claude --print \
  --dangerously-skip-permissions \
  --model claude-sonnet-4-6 \
  --add-dir "$WS" \
  < "$PROMPT_TMP" 2>/dev/null || echo "")

rm -f "$PROMPT_TMP"

# ── Store Claude's response ───────────────────────────────────────────────────
if [[ -n "$RESPONSE" ]]; then
  echo "{\"role\":\"RaceTechnikAI\",\"message\":$(echo "$RESPONSE" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')}" >> "$HISTORY_FILE"
  echo "$RESPONSE"
fi
