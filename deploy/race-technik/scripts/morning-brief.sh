#!/usr/bin/env bash
# morning-brief.sh — Race Technik Mac Mini
# Generates a daily voice note brief for Farhaan and sends via Telegram.
# Runs at 07:30 SAST daily via LaunchAgent.
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
WORKSPACE="${HOME}/.amalfiai/workspace"
ENV_FILE="${WORKSPACE}/.env.scheduler"
source "$ENV_FILE"
unset CLAUDECODE

BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
CHAT_ID="${TELEGRAM_CHAT_ID}"
KEY="${SUPABASE_SERVICE_ROLE_KEY}"
SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"

TODAY=$(date '+%A, %d %B %Y')
SAST_DATE=$(date '+%Y-%m-%d')

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Morning brief starting for Race Technik"

# ── Fetch recent tasks from Supabase ─────────────────────────────────────────
RECENT_TASKS=$(curl -s \
  "${SUPABASE_URL}/rest/v1/tasks?select=title,status,priority,assigned_to&order=created_at.desc&limit=10" \
  -H "apikey: ${KEY}" -H "Authorization: Bearer ${KEY}" 2>/dev/null || echo "[]")

TASKS_SUMMARY=$(echo "$RECENT_TASKS" | python3 -c "
import sys, json
tasks = json.load(sys.stdin)
if not tasks:
    print('No recent tasks found.')
else:
    lines = []
    for t in tasks:
        status = t.get('status','?')
        title  = t.get('title','(no title)')[:60]
        p      = t.get('priority','')
        assignee = t.get('assigned_to','')
        pmark = ' [HIGH]' if p == 'high' else ' [URGENT]' if p == 'urgent' else ''
        lines.append(f'  {status.upper()}{pmark}: {title}')
    print('\n'.join(lines))
" 2>/dev/null || echo "Could not load tasks.")

# ── Build brief prompt ────────────────────────────────────────────────────────
MEMORY=$(cat "${WORKSPACE}/memory/MEMORY.md" 2>/dev/null || echo "")

PROMPT_TMP=$(mktemp /tmp/rt-brief-XXXXXX)
cat > "$PROMPT_TMP" << PROMPT
You are the Race Technik AI assistant. Generate a concise morning brief for Farhaan.

Today: ${TODAY}
Machine: Race Technik Mac Mini

Recent tasks:
${TASKS_SUMMARY}

Context:
${MEMORY}

Write a brief, practical morning update (150 to 200 words). Include:
1. Today's date and a quick operational status
2. Any pending or in-progress tasks the team should act on
3. Any immediate priorities or reminders

Tone: professional, direct, no fluff. Like a competent operations manager speaking to his boss.
No hyphens — use em dashes or rephrase instead.
PROMPT

BRIEF=$(claude --print --dangerously-skip-permissions --model claude-sonnet-4-6 < "$PROMPT_TMP" 2>/dev/null || echo "")
rm -f "$PROMPT_TMP"

if [[ -z "$BRIEF" ]]; then
  BRIEF="Good morning Farhaan. Morning brief could not be generated today — Claude did not respond. All systems are running on the Race Technik Mac Mini. Check Supabase for pending tasks."
fi

# ── Generate TTS voice note ───────────────────────────────────────────────────
AUDIO_OUT="${WORKSPACE}/out/morning-brief.opus"

TTS_OK=false
if command -v ffmpeg >/dev/null 2>&1; then
  # Use Telegram TTS via a text-to-speech API (fallback to text if not available)
  # Try edge-tts if available
  if command -v edge-tts >/dev/null 2>&1; then
    TMP_MP3=$(mktemp /tmp/rt-brief-XXXXXX.mp3)
    edge-tts --voice "en-ZA-LeahNeural" --text "$BRIEF" --write-media "$TMP_MP3" 2>/dev/null && \
    ffmpeg -y -i "$TMP_MP3" -c:a libopus -b:a 32k "$AUDIO_OUT" >/dev/null 2>&1 && \
    TTS_OK=true
    rm -f "$TMP_MP3"
  fi
fi

# ── Send to Telegram ──────────────────────────────────────────────────────────
if [[ "$TTS_OK" == "true" && -f "$AUDIO_OUT" ]]; then
  curl -s -X POST "${TG_API:-https://api.telegram.org/bot${BOT_TOKEN}}/sendVoice" \
    -F "chat_id=${CHAT_ID}" \
    -F "voice=@${AUDIO_OUT}" \
    -F "caption=Race Technik Morning Brief — ${TODAY}" >/dev/null 2>&1 || true
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Voice brief sent"
else
  # Send as text
  export _BRIEF_TEXT="Race Technik Morning Brief — ${TODAY}

${BRIEF}"
  python3 - <<'PY'
import os, json, urllib.request
token = os.environ.get('BOT_TOKEN','')
chat  = os.environ.get('TELEGRAM_CHAT_ID','')
text  = os.environ.get('_BRIEF_TEXT','')
data = json.dumps({"chat_id": chat, "text": text}).encode()
req = urllib.request.Request(
    f"https://api.telegram.org/bot{token}/sendMessage",
    data=data, headers={"Content-Type":"application/json"}, method="POST"
)
try:
    urllib.request.urlopen(req, timeout=15)
    print("Text brief sent")
except Exception as e:
    print(f"Failed to send: {e}")
PY
fi

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Morning brief complete"
