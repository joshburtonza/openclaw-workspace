#!/usr/bin/env bash
# morning-brief.sh — generates a daily voice note brief and sends via Telegram
# Runs at 05:30 UTC (07:30 SAST) via LaunchAgent
set -euo pipefail

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WORKSPACE/.env.scheduler"
source "$ENV_FILE"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
unset CLAUDECODE

BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
CHAT_ID="7584896900"
KEY="${SUPABASE_SERVICE_ROLE_KEY}"
SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
AUDIO_OUT="/Users/henryburton/.openclaw/media/outbound/morning-brief.opus"

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Morning brief starting"

# ── Gather live context ───────────────────────────────────────────────────────

# Pending approvals
PENDING_JSON=$(curl -s "${SUPABASE_URL}/rest/v1/email_queue?status=eq.awaiting_approval&select=client,subject,created_at&order=created_at.asc&limit=10" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY")

PENDING_TEXT=$(echo "$PENDING_JSON" | python3 -c "
import json, sys, time, calendar
from datetime import datetime
rows = json.loads(sys.stdin.read()) or []
if not rows:
    print('No pending approvals.')
else:
    now_ts = time.time()
    for r in rows:
        created = r['created_at'].replace('Z','').replace('+00:00','')[:19]
        try:
            ts = datetime.strptime(created, '%Y-%m-%dT%H:%M:%S')
            age_h = int((now_ts - calendar.timegm(ts.timetuple())) / 3600)
        except Exception:
            age_h = 0
        print(r['client'].replace('_',' ') + ': ' + r['subject'][:50] + ' (' + str(age_h) + 'h old)')
" 2>/dev/null || echo "Unable to fetch pending.")

# Repo changes (last 24h)
REPO_CHANGES=""
for ENTRY in "chrome-auto-care:Race Technik" "qms-guard:Ascend LC" "favorite-flow-9637aff2:Favorite Logistics"; do
  DIR="${ENTRY%%:*}"
  NAME="${ENTRY#*:}"
  COMMITS=$(git -C "$WORKSPACE/$DIR" log --oneline --since="24 hours ago" 2>/dev/null | wc -l | tr -d ' ')
  [[ "$COMMITS" -gt 0 ]] && REPO_CHANGES="${REPO_CHANGES}${NAME}: ${COMMITS} commit(s). "
done
[[ -z "$REPO_CHANGES" ]] && REPO_CHANGES="No repo changes in last 24h."

# Active reminders due today
REMINDERS=$(curl -s "${SUPABASE_URL}/rest/v1/notifications?type=eq.reminder&status=eq.unread&select=title,metadata&limit=5" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" | python3 -c "
import json, sys
from datetime import datetime, timezone
rows = json.loads(sys.stdin.read()) or []
today = datetime.now(timezone.utc).strftime('%Y-%m-%d')
due_today = []
for r in rows:
    meta = r.get('metadata') or {}
    due = meta.get('due','')
    if due.startswith(today):
        due_today.append(r['title'])
if due_today:
    print('Reminders today: ' + ', '.join(due_today) + '.')
else:
    print('')
" 2>/dev/null || echo "")

# OOO status
OOO_STATUS=""
if [[ -f "$WORKSPACE/tmp/sophia-ooo-cache" ]]; then
  OOO_VAL=$(cat "$WORKSPACE/tmp/sophia-ooo-cache" 2>/dev/null || echo "false")
  [[ "$OOO_VAL" != "false" ]] && OOO_STATUS="Note: Josh is currently OOO — $OOO_VAL."
fi

DOW=$(date +%A)
DATE_STR=$(date +"%B %-d")

# ── Generate brief text via Claude ───────────────────────────────────────────

PROMPT_TMP=$(mktemp /tmp/morning-brief-XXXXXX)
cat > "$PROMPT_TMP" << PROMPT
Write a short morning voice brief for Josh. Today is ${DOW}, ${DATE_STR}.

Live data:
- Pending approvals: ${PENDING_TEXT}
- Dev activity (24h): ${REPO_CHANGES}
- ${REMINDERS}
- ${OOO_STATUS}

Style rules:
- Casual, direct, no corporate speak — like a smart colleague giving a morning rundown
- Conversational openers: "So listen", "Quick one", "Morning" — vary it
- 2-3 points max — only what actually matters
- If there are pending approvals, mention them clearly (Josh needs to act)
- End with ONE clear question or action item for Josh
- Keep it under 100 words — this will be read aloud as a voice note
- No bullet points, no headings — flowing speech

Reply with ONLY the brief text. Nothing else. No quotes.
PROMPT

BRIEF_TEXT=$(claude --print --model claude-haiku-4-5-20251001 < "$PROMPT_TMP" 2>/dev/null)
rm -f "$PROMPT_TMP"

if [[ -z "$BRIEF_TEXT" ]]; then
  BRIEF_TEXT="Morning Josh. Quick heads up — you've got ${PENDING_TEXT} sitting in the approval queue. ${REPO_CHANGES} What's your priority today?"
fi

echo "  Brief: $BRIEF_TEXT"

# ── TTS via ElevenLabs ────────────────────────────────────────────────────────

mkdir -p "$(dirname "$AUDIO_OUT")"

TTS_OK=false
if echo "$BRIEF_TEXT" | bash "$WORKSPACE/scripts/tts/elevenlabs-tts-to-opus.sh" --out "$AUDIO_OUT" 2>/dev/null; then
  TTS_OK=true
  echo "  TTS: audio generated"
else
  echo "  TTS: failed, will send text fallback" >&2
fi

# ── Send via Telegram ─────────────────────────────────────────────────────────

if [[ "$TTS_OK" == "true" && -f "$AUDIO_OUT" ]]; then
  # Send as voice note
  RESP=$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendVoice" \
    -F "chat_id=${CHAT_ID}" \
    -F "voice=@${AUDIO_OUT}" \
    -F "caption=📋 Morning Brief — ${DOW} ${DATE_STR}")
  MSG_ID=$(echo "$RESP" | python3 -c "
import json,sys
try:
    r=json.loads(sys.stdin.read())
    print(r.get('result',{}).get('message_id','sent'))
except:
    print('sent')
" 2>/dev/null || echo "sent")
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Voice brief sent (msg $MSG_ID)"
else
  # Text fallback
  TEXT_MSG="🌅 *Morning Brief — ${DOW} ${DATE_STR}*

${BRIEF_TEXT}"
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$TEXT_MSG"),\"parse_mode\":\"Markdown\"}" > /dev/null
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Text brief sent (TTS fallback)"
fi
