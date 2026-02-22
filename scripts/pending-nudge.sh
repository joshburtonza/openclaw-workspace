#!/usr/bin/env bash
# pending-nudge.sh — reminds Josh of items awaiting approval, twice daily
# Runs at 09:00 and 15:00 SAST (07:00 and 13:00 UTC) via LaunchAgent
# Uses a state file to avoid re-alerting the same items already sent today
set -euo pipefail

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WORKSPACE/.env.scheduler"
source "$ENV_FILE"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
CHAT_ID="7584896900"
KEY="${SUPABASE_SERVICE_ROLE_KEY}"
SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
STATE_FILE="$WORKSPACE/tmp/pending-nudge-alerted"

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Pending nudge check"

# Fetch all awaiting_approval items
ROWS=$(curl -s "${SUPABASE_URL}/rest/v1/email_queue?status=eq.awaiting_approval&select=id,client,subject,created_at&order=created_at.asc&limit=20" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY")

# Parse + filter to items older than 1 hour
ITEMS=$(echo "$ROWS" | python3 -c "
import json, sys, time
from datetime import datetime

rows = json.loads(sys.stdin.read()) or []
now_ts = time.time()
results = []
for r in rows:
    # Parse ISO timestamp manually — works across Python versions
    created = r['created_at'].replace('Z','').replace('+00:00','')
    try:
        ts = datetime.strptime(created[:19], '%Y-%m-%dT%H:%M:%S')
        import calendar
        epoch = calendar.timegm(ts.timetuple())
        age_h = (now_ts - epoch) / 3600
    except Exception:
        age_h = 99
    if age_h >= 1:
        results.append({
            'id': r['id'],
            'client': r['client'].replace('_',' ').title(),
            'subject': r['subject'][:60],
            'age_h': round(age_h, 1)
        })
print(json.dumps(results))
" 2>/dev/null || echo "[]")

COUNT=$(echo "$ITEMS" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))" 2>/dev/null || echo "0")

if [[ "$COUNT" -eq 0 ]]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") No pending items — nothing to nudge"
  exit 0
fi

# Check if we already alerted about these exact IDs today
TODAY=$(date -u +"%Y-%m-%d")
CURRENT_IDS=$(echo "$ITEMS" | python3 -c "import json,sys; rows=json.loads(sys.stdin.read()); print(','.join(sorted(r['id'] for r in rows)))" 2>/dev/null || echo "")

# Read last state
LAST_STATE=""
[[ -f "$STATE_FILE" ]] && LAST_STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "")
LAST_DATE=$(echo "$LAST_STATE" | cut -d'|' -f1)
LAST_IDS=$(echo "$LAST_STATE" | cut -d'|' -f2)

# If same IDs as last alert today, skip (unless it's been > 3h)
if [[ "$LAST_DATE" == "$TODAY" && "$LAST_IDS" == "$CURRENT_IDS" ]]; then
  LAST_TS=$(echo "$LAST_STATE" | cut -d'|' -f3)
  NOW_TS=$(date +%s)
  LAST_EPOCH=${LAST_TS:-0}
  DIFF=$(( NOW_TS - LAST_EPOCH ))
  if [[ "$DIFF" -lt 10800 ]]; then  # less than 3 hours
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Already nudged about these items recently — skipping"
    exit 0
  fi
fi

# Build message
MSG=$(echo "$ITEMS" | python3 -c "
import json, sys
rows = json.loads(sys.stdin.read())
count = len(rows)
lines = ['⏳ <b>' + str(count) + ' email' + ('s' if count > 1 else '') + ' waiting for your approval:</b>', '']
for r in rows:
    h = r['age_h']
    if h < 2:
        age = str(int(h*60)) + 'min'
    else:
        age = str(int(h)) + 'h'
    lines.append('• [' + r['client'] + '] ' + r['subject'] + ' (' + age + ' old)')
lines.append('')
lines.append('Open Mission Control or tap Approve in a previous card.')
print('\n'.join(lines))
" 2>/dev/null)

curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$MSG"),\"parse_mode\":\"HTML\"}" > /dev/null

# Save state
echo "${TODAY}|${CURRENT_IDS}|$(date +%s)" > "$STATE_FILE"

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Nudge sent for $COUNT item(s)"
