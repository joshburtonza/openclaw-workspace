#!/usr/bin/env bash
# generate-weekly-client-reports.sh — Race Technik Mac Mini
# Generates a weekly summary report for Race Technik and sends to Farhaan.
# Runs every Tuesday at 09:30 SAST via LaunchAgent.
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
CLIENTS="${WORKSPACE}/clients"

TODAY=$(date '+%A, %d %B %Y')
WEEK_START=$(date -v-7d '+%Y-%m-%d' 2>/dev/null || date --date='7 days ago' '+%Y-%m-%d')

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Weekly report starting"

send_telegram() {
  local text="$1"
  export _WR_TEXT="$text"
  python3 - <<'PY'
import os, json, urllib.request
token = os.environ.get('BOT_TOKEN','')
chat  = os.environ.get('CHAT_ID','')
text  = os.environ.get('_WR_TEXT','')
if not (token and chat and text):
    raise SystemExit(0)
data = json.dumps({"chat_id": chat, "text": text}).encode()
req = urllib.request.Request(
    f"https://api.telegram.org/bot{token}/sendMessage",
    data=data, headers={"Content-Type":"application/json"}, method="POST"
)
try:
    urllib.request.urlopen(req, timeout=15)
except Exception as e:
    print(f"send error: {e}")
PY
}

# ── Get completed tasks this week ─────────────────────────────────────────────
DONE_TASKS=$(curl -s \
  "${SUPABASE_URL}/rest/v1/tasks?status=eq.done&created_at=gte.${WEEK_START}&select=title,priority,completed_at&order=completed_at.desc&limit=20" \
  -H "apikey: ${KEY}" -H "Authorization: Bearer ${KEY}" 2>/dev/null || echo "[]")

# ── Get recent git commits ────────────────────────────────────────────────────
COMMITS=""
if [[ -d "${CLIENTS}/chrome-auto-care/.git" ]]; then
  COMMITS=$(git -C "${CLIENTS}/chrome-auto-care" log \
    --since="${WEEK_START}" --oneline --no-merges 2>/dev/null | head -20 || echo "")
fi

# ── Build report prompt ───────────────────────────────────────────────────────
TASKS_JSON=$(echo "$DONE_TASKS" | python3 -c "
import sys, json
tasks = json.load(sys.stdin)
if not tasks:
    print('No tasks completed this week.')
else:
    lines = [f\"  - {t.get('title','?')[:70]}\" for t in tasks]
    print('\n'.join(lines))
" 2>/dev/null || echo "Could not load tasks.")

PROMPT_TMP=$(mktemp /tmp/rt-weekly-XXXXXX)
cat > "$PROMPT_TMP" << PROMPT
You are generating a weekly progress report for Race Technik, an automotive care business in South Africa.

Report period: Week ending ${TODAY}

Completed tasks:
${TASKS_JSON}

Recent code commits to chrome-auto-care (booking platform):
${COMMITS:-None this week}

Write a clear, professional weekly summary (200 to 300 words) that:
1. Summarises what was accomplished this week
2. Highlights any significant platform improvements
3. Notes what is in progress or planned for next week
4. Ends with a brief motivational note

Tone: direct, professional, positive. Written for Farhaan. No hyphens, use em dashes instead.
PROMPT

REPORT=$(claude --print --dangerously-skip-permissions --model claude-sonnet-4-6 < "$PROMPT_TMP" 2>/dev/null || echo "")
rm -f "$PROMPT_TMP"

if [[ -z "$REPORT" ]]; then
  REPORT="Weekly report could not be generated. Check the Race Technik Mac Mini logs."
fi

send_telegram "Race Technik — Weekly Report
${TODAY}

${REPORT}"

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Weekly report sent"
