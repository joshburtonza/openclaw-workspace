#!/bin/bash
# telegram-callback-poller.sh — Race Technik Mac Mini
# Long-polls RaceTechnikAiBot for messages from Farhaan and Yaseen.
# Forwards text messages to Claude and sends the response back.
# Voice notes are transcribed via Deepgram first.
# KeepAlive LaunchAgent — loops internally via long-polling (timeout=25s).

set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

WORKSPACE="${HOME}/.amalfiai/workspace"
ENV_FILE="${WORKSPACE}/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
DEEPGRAM_API_KEY="${DEEPGRAM_API_KEY:-}"
TG_API="https://api.telegram.org/bot${BOT_TOKEN}"

OFFSET_FILE="${WORKSPACE}/tmp/telegram_updates_offset"
PIDFILE="${WORKSPACE}/tmp/telegram-poller.pid"
GATEWAY="${WORKSPACE}/scripts/telegram-claude-gateway.sh"

mkdir -p "${WORKSPACE}/tmp" "${WORKSPACE}/out"

# ── Pidfile guard ─────────────────────────────────────────────────────────────
if [[ -f "$PIDFILE" ]]; then
  OLD_PID=$(cat "$PIDFILE" 2>/dev/null || true)
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Poller already running (pid $OLD_PID), exiting." >&2
    exit 0
  fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"; exit 0' EXIT INT TERM

if [[ -z "$BOT_TOKEN" ]]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") ERROR: TELEGRAM_BOT_TOKEN not set" >&2
  exit 1
fi

# ── Authorized users from env ─────────────────────────────────────────────────
FARHAAN_CHAT_ID="${TELEGRAM_CHAT_ID:-1173308443}"
YASEEN_CHAT_ID="${TELEGRAM_YACINE_CHAT_ID:-520957631}"

# ── Helpers ───────────────────────────────────────────────────────────────────

send_telegram() {
  local chat_id="$1"
  local text="$2"
  export _SEND_CHAT="$chat_id"
  export _SEND_TEXT="$text"
  python3 - <<'PY'
import os, json, urllib.request
token = os.environ.get('BOT_TOKEN', '')
chat  = os.environ.get('_SEND_CHAT', '')
text  = os.environ.get('_SEND_TEXT', '')
if not (token and chat and text):
    raise SystemExit(0)
data = json.dumps({"chat_id": chat, "text": text, "parse_mode": "HTML"}).encode()
req = urllib.request.Request(
    f"https://api.telegram.org/bot{token}/sendMessage",
    data=data, headers={"Content-Type": "application/json"}, method="POST"
)
try:
    urllib.request.urlopen(req, timeout=15)
except Exception as e:
    print(f"send_telegram error: {e}", flush=True)
PY
}

send_voice_response() {
  local chat_id="$1"
  local text="$2"
  # For voice responses: just send as text (TTS optional later)
  send_telegram "$chat_id" "$text"
}

is_authorized() {
  local chat_id="$1"
  [[ "$chat_id" == "$FARHAAN_CHAT_ID" || "$chat_id" == "$YASEEN_CHAT_ID" ]]
}

# ── Transcribe voice note via Deepgram ────────────────────────────────────────

transcribe_voice() {
  local file_id="$1"
  local chat_id="$2"

  if [[ -z "$DEEPGRAM_API_KEY" ]]; then
    send_telegram "$chat_id" "Voice note received (transcription not configured — no DEEPGRAM_API_KEY)."
    echo ""
    return
  fi

  # Get file path
  FILE_INFO=$(curl -s "${TG_API}/getFile?file_id=${file_id}") || FILE_INFO=""
  FILE_PATH=$(echo "$FILE_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result',{}).get('file_path',''))" 2>/dev/null || echo "")

  if [[ -z "$FILE_PATH" ]]; then
    send_telegram "$chat_id" "Could not retrieve voice file."
    echo ""
    return
  fi

  FILE_URL="https://api.telegram.org/file/bot${BOT_TOKEN}/${FILE_PATH}"

  # Transcribe directly from URL via Deepgram
  TRANSCRIPT=$(curl -s \
    -X POST "https://api.deepgram.com/v1/listen?model=nova-2&detect_language=true&smart_format=true" \
    -H "Authorization: Token ${DEEPGRAM_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"url\":\"${FILE_URL}\"}" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
try:
    ch = d['results']['channels'][0]['alternatives'][0]
    text = ch.get('transcript','').strip()
    lang = d['results']['channels'][0].get('detected_language','')
    prefix = f'[{lang}] ' if lang and lang != 'en' else ''
    print(prefix + text)
except Exception:
    print('')
" 2>/dev/null || echo "")

  echo "$TRANSCRIPT"
}

# ── Process a single update ───────────────────────────────────────────────────

process_update() {
  export _UPDATE_JSON="$1"

  python3 - <<'PY'
import os, json, sys

upd = json.loads(os.environ['_UPDATE_JSON'])

# Handle message updates only
msg = upd.get('message') or upd.get('edited_message')
if not msg:
    raise SystemExit(0)

chat_id  = str(msg.get('chat',{}).get('id',''))
text     = (msg.get('text') or '').strip()
voice    = msg.get('voice') or msg.get('audio')
file_id  = (voice or {}).get('file_id', '')

print(f"CHAT_ID={chat_id}")
print(f"TEXT={text}")
print(f"VOICE_FILE_ID={file_id}")
PY
}

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Race Technik Telegram poller started (pid $$)"

# ── Main loop ─────────────────────────────────────────────────────────────────
while true; do

  OFFSET=""
  if [[ -f "$OFFSET_FILE" ]]; then
    OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || true)
  fi

  URL="${TG_API}/getUpdates?timeout=25&allowed_updates=message,callback_query"
  if [[ -n "$OFFSET" ]]; then
    URL+="&offset=${OFFSET}"
  fi

  RESP=$(curl -s --max-time 35 "$URL") || RESP=""

  if [[ -z "$RESP" ]]; then
    sleep 5
    continue
  fi

  # Skip malformed JSON
  if ! echo "$RESP" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    sleep 2
    continue
  fi

  # Check for API errors
  ERR_CODE=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error_code',0))" 2>/dev/null || echo "0")
  IS_OK=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if d.get('ok') else 'no')" 2>/dev/null || echo "no")

  if [[ "$IS_OK" != "yes" ]]; then
    if [[ "$ERR_CODE" == "409" ]]; then
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") 409 conflict — another instance running? Backing off 10s" >&2
      sleep 10
    else
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") getUpdates error ${ERR_CODE}" >&2
      sleep 5
    fi
    continue
  fi

  # Log raw updates
  echo "$RESP" >> "${WORKSPACE}/out/telegram-raw-updates.jsonl"

  # Process each update
  UPDATES=$(echo "$RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
updates = d.get('result', [])
for u in updates:
    print(json.dumps(u))
" 2>/dev/null || true)

  NEXT_OFFSET=""

  while IFS= read -r UPDATE_LINE; do
    [[ -z "$UPDATE_LINE" ]] && continue

    # Get update_id for offset
    UPDATE_ID=$(echo "$UPDATE_LINE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('update_id',0))" 2>/dev/null || echo "0")
    NEXT_OFFSET=$((UPDATE_ID + 1))

    # Extract fields
    PARSED=$(export _UPDATE_JSON="$UPDATE_LINE"; python3 - <<'PY'
import os, json
upd = json.loads(os.environ['_UPDATE_JSON'])
msg = upd.get('message') or upd.get('edited_message') or {}
chat_id  = str(msg.get('chat',{}).get('id',''))
text     = (msg.get('text') or '').strip()
voice    = msg.get('voice') or msg.get('audio') or {}
file_id  = voice.get('file_id','')
from_id  = str(msg.get('from',{}).get('id',''))
fname    = msg.get('from',{}).get('first_name','')
print(f"{chat_id}|{text}|{file_id}|{from_id}|{fname}")
PY
    2>/dev/null || echo "|||0|")

    CHAT_ID=$(echo "$PARSED" | cut -d'|' -f1)
    TEXT=$(echo "$PARSED" | cut -d'|' -f2)
    VOICE_FILE_ID=$(echo "$PARSED" | cut -d'|' -f3)
    FROM_ID=$(echo "$PARSED" | cut -d'|' -f4)
    FROM_NAME=$(echo "$PARSED" | cut -d'|' -f5)

    [[ -z "$CHAT_ID" ]] && continue

    # Authorization check
    if ! is_authorized "$CHAT_ID"; then
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Ignoring message from unauthorized chat $CHAT_ID"
      continue
    fi

    # ── Voice note ────────────────────────────────────────────────────────────
    if [[ -n "$VOICE_FILE_ID" ]]; then
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Voice note from $FROM_NAME ($CHAT_ID)"
      TRANSCRIPT=$(transcribe_voice "$VOICE_FILE_ID" "$CHAT_ID")
      if [[ -n "$TRANSCRIPT" ]]; then
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Transcript: ${TRANSCRIPT:0:100}..."
        # Pass transcript to Claude as text
        TEXT="[voice note] $TRANSCRIPT"
      else
        send_telegram "$CHAT_ID" "Could not transcribe voice note."
        continue
      fi
    fi

    # ── Text message → Claude gateway ─────────────────────────────────────────
    if [[ -n "$TEXT" ]]; then
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Message from $FROM_NAME ($CHAT_ID): ${TEXT:0:80}"

      if [[ -f "$GATEWAY" ]]; then
        RESPONSE=$(bash "$GATEWAY" "$CHAT_ID" "$TEXT" 2>/dev/null || echo "")
        if [[ -n "$RESPONSE" ]]; then
          send_telegram "$CHAT_ID" "$RESPONSE"
        fi
      else
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") WARNING: gateway not found at $GATEWAY" >&2
        send_telegram "$CHAT_ID" "Gateway not configured. Contact your AI administrator."
      fi
    fi

  done <<< "$UPDATES"

  # Advance offset
  if [[ -n "$NEXT_OFFSET" && "$NEXT_OFFSET" != "1" ]]; then
    echo "$NEXT_OFFSET" > "$OFFSET_FILE"
  fi

done
