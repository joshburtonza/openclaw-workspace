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
REPLY_MODE="${4:-text}"       # "audio" → send MiniMax TTS voice note; "text" → plain text

if [[ -z "$CHAT_ID" || -z "$USER_MSG" ]]; then
  echo "Usage: $0 <chat_id> <message> [group_history_file]" >&2
  exit 1
fi

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"

# ── /reply wa [contact] [message] command ─────────────────────────────────────
# Sends a WhatsApp message via the Business Cloud API.
# Usage: /reply wa ascend_lc Invoice sent — please confirm receipt.
#        /reply wa +27761234567 Hey, just following up.

if echo "$USER_MSG" | grep -qi '^\s*/reply wa '; then
  WA_ARGS=$(echo "$USER_MSG" | sed 's|^\s*/reply wa ||i')
  CONTACT_RAW=$(echo "$WA_ARGS" | awk '{print $1}')
  WA_TEXT=$(echo "$WA_ARGS" | cut -d' ' -f2-)

  # Resolve contact slug or raw number from contacts.json
  TO_NUMBER=""
  CONTACT_DISPLAY=""
  if echo "$CONTACT_RAW" | grep -qE '^\+?[0-9]{7,}$'; then
    # Raw number provided
    TO_NUMBER="$CONTACT_RAW"
    CONTACT_DISPLAY="$CONTACT_RAW"
  else
    # Look up slug in contacts.json
    CONTACTS_JSON="$WS/data/contacts.json"
    if [[ -f "$CONTACTS_JSON" ]]; then
      LOOKUP=$(python3 -c "
import json, sys
slug = '${CONTACT_RAW}'.lower()
data = json.load(open('${CONTACTS_JSON}'))
for c in data.get('clients', []):
    if c.get('slug','').lower() == slug or c.get('name','').lower().replace(' ','_') == slug:
        print(c.get('number','') + '|' + c.get('name',''))
        sys.exit(0)
print('|')
" 2>/dev/null || echo "|")
      TO_NUMBER="${LOOKUP%%|*}"
      CONTACT_DISPLAY="${LOOKUP##*|}"
    fi
  fi

  tg_send_cmd() {
    local text="$1"
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(echo "$text" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),\"parse_mode\":\"Markdown\"}" >/dev/null 2>&1 || true
  }

  if [[ -z "$TO_NUMBER" || -z "$WA_TEXT" || "$TO_NUMBER" == "|" ]]; then
    tg_send_cmd "⚠️ Usage: \`/reply wa [contact_slug_or_number] [message]\`

Known contacts: $(python3 -c "
import json
try:
    data = json.load(open('$WS/data/contacts.json'))
    for c in data.get('clients',[]): print('  •', c.get('slug',''), '—', c.get('name',''))
except: print('  (could not load contacts.json)')
" 2>/dev/null)"
    exit 0
  fi

  if [[ "${WHATSAPP_TOKEN:-REPLACE_WITH_WHATSAPP_ACCESS_TOKEN}" == "REPLACE_WITH_WHATSAPP_ACCESS_TOKEN" || -z "${WHATSAPP_TOKEN:-}" ]]; then
    tg_send_cmd "⚠️ WhatsApp not configured. Set WHATSAPP_TOKEN and WHATSAPP_PHONE_ID in .env.scheduler."
    exit 0
  fi

  WA_RESP=$(curl -s -X POST \
    "https://graph.facebook.com/v21.0/${WHATSAPP_PHONE_ID}/messages" \
    -H "Authorization: Bearer ${WHATSAPP_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"messaging_product\":\"whatsapp\",\"to\":\"${TO_NUMBER}\",\"type\":\"text\",\"text\":{\"body\":$(echo "$WA_TEXT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')}}")

  WA_OK=$(echo "$WA_RESP" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print('ok' if d.get('messages') else 'fail')" 2>/dev/null || echo "fail")

  if [[ "$WA_OK" == "ok" ]]; then
    tg_send_cmd "✅ WhatsApp sent to *${CONTACT_DISPLAY:-$TO_NUMBER}*: \"${WA_TEXT}\""
  else
    ERR=$(echo "$WA_RESP" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('error',{}).get('message','unknown error'))" 2>/dev/null || echo "unknown error")
    tg_send_cmd "❌ WhatsApp send failed: ${ERR}"
  fi
  exit 0
fi
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
RESEARCH_INTEL=$(cat "$WS/memory/research-intel.md" 2>/dev/null || echo "")

# Load Sophia identity context
SOPHIA_SOUL=$(cat "$WS/prompts/sophia/soul.md" 2>/dev/null || echo "")
SOPHIA_MEMORY=$(cat "$WS/memory/sophia/memory.md" 2>/dev/null || echo "")

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
=== SOPHIA — WHO SHE IS ===
${SOPHIA_SOUL}

=== SOPHIA — MEMORY ===
${SOPHIA_MEMORY}

=== LONG-TERM MEMORY ===
${LONG_TERM_MEMORY}

=== CURRENT SYSTEM STATE ===
${CURRENT_STATE}

=== STRATEGIC RESEARCH INTELLIGENCE ===
${RESEARCH_INTEL}
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

# ── Run Claude ────────────────────────────────────────────────────────────────
unset CLAUDECODE
PROMPT_TMP=$(mktemp /tmp/tg-prompt-XXXXXX)
printf '%s' "$FULL_PROMPT" > "$PROMPT_TMP"
RESPONSE=$(claude --print --model claude-sonnet-4-6 < "$PROMPT_TMP" 2>>"$WS/out/gateway-errors.log")
rm -f "$PROMPT_TMP"

# ── Send response back to Telegram ───────────────────────────────────────────
if [[ -n "$RESPONSE" ]]; then

  # ── Audio reply (voice note input → MiniMax TTS voice note output) ──────────
  if [[ "$REPLY_MODE" == "audio" ]]; then
    # Strip markdown so it doesn't get spoken as symbols
    # (use temp file — heredoc inside $() can't use || fallback in bash)
    export _TTS_RESPONSE="$RESPONSE"
    _STRIP_TMP=$(mktemp /tmp/tts-strip-XXXXXX)
    python3 - > "$_STRIP_TMP" 2>/dev/null <<'PYSTRIP'
import re, os
text = os.environ.get('_TTS_RESPONSE', '')
text = re.sub(r'\*\*(.+?)\*\*', r'\1', text, flags=re.DOTALL)
text = re.sub(r'\*(.+?)\*', r'\1', text)
text = re.sub(r'```.*?```', '', text, flags=re.DOTALL)
text = re.sub(r'`(.+?)`', r'\1', text)
text = re.sub(r'^#{1,6}\s*', '', text, flags=re.MULTILINE)
text = re.sub(r'^[-*\u2022]\s+', '', text, flags=re.MULTILINE)
text = re.sub(r'\[(.+?)\]\(.+?\)', r'\1', text)
text = re.sub(r'<[^>]+>', '', text)
text = re.sub(r'\n{3,}', '\n\n', text)
print(text.strip()[:4500])
PYSTRIP
    CLEAN_TEXT=$(cat "$_STRIP_TMP" 2>/dev/null || true)
    rm -f "$_STRIP_TMP"

    AUDIO_OUT="/tmp/tg-voice-${CHAT_ID}-$(date +%s).opus"
    TTS_OK=0

    if [[ -n "$CLEAN_TEXT" ]]; then
      # Show upload_voice action while TTS renders
      curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendChatAction" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\": \"${CHAT_ID}\", \"action\": \"upload_voice\"}" >/dev/null 2>&1 || true

      if echo "$CLEAN_TEXT" | bash "$WS/scripts/tts/minimax-tts-to-opus.sh" --out "$AUDIO_OUT" 2>>"$WS/out/gateway-errors.log"; then
        TTS_RESP=$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendVoice" \
          -F "chat_id=${CHAT_ID}" \
          -F "voice=@${AUDIO_OUT}" 2>/dev/null || echo "")
        TTS_OK=$(echo "$TTS_RESP" | python3 -c "import sys,json; print(1 if json.load(sys.stdin).get('ok') else 0)" 2>/dev/null || echo "0")
      fi
    fi

    rm -f "$AUDIO_OUT" 2>/dev/null || true

    if [[ "$TTS_OK" != "1" ]]; then
      # TTS failed — fall back to text so the response is never lost
      tg_send "$RESPONSE"
    fi

  # ── Text reply ───────────────────────────────────────────────────────────────
  else
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
  fi

  # Store response in history (same for both reply modes)
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
