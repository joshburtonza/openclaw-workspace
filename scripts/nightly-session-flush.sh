#!/usr/bin/env bash
# nightly-session-flush.sh
# Writes a daily ops log to memory/YYYY-MM-DD.md from live system data.
# Runs nightly at 22:00 SAST (20:00 UTC) via LaunchAgent.
set -euo pipefail

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WORKSPACE/.env.scheduler"
source "$ENV_FILE"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
unset CLAUDECODE

KEY="${SUPABASE_SERVICE_ROLE_KEY}"
SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
DATE=$(TZ=Africa/Johannesburg date '+%Y-%m-%d')
DOW=$(TZ=Africa/Johannesburg date '+%A, %B %-d, %Y')
OUT_FILE="$WORKSPACE/memory/${DATE}.md"

echo "[nightly-flush] Starting for $DATE"

# ── Email activity today ──────────────────────────────────────────────────────
EMAIL_STATS=$(curl -s "${SUPABASE_URL}/rest/v1/email_queue?select=status,created_at&order=created_at.desc&limit=100" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" | python3 -c "
import json, sys, time, calendar
from datetime import datetime
rows = json.loads(sys.stdin.read()) or []
today = datetime.now().strftime('%Y-%m-%d')
counts = {}
for r in rows:
    if r.get('created_at','')[:10] == today:
        s = r.get('status','?')
        counts[s] = counts.get(s,0) + 1
if not counts:
    print('No email activity today.')
else:
    print(', '.join(str(v)+' '+k for k,v in sorted(counts.items())))
" 2>/dev/null || echo "unavailable")

# ── Agents status ─────────────────────────────────────────────────────────────
AGENT_STATUS=$(launchctl list | grep com.amalfiai | while IFS=$'\t' read -r pid code label; do
  name="${label#com.amalfiai.}"
  icon="✅"
  [[ "$code" != "0" && "$code" != "-" ]] && icon="⚠️ (exit $code)"
  echo "- $icon $name"
done | sort)

# ── Repo changes today ────────────────────────────────────────────────────────
REPO_LOG=""
for ENTRY in "qms-guard:Ascend LC" "favorite-flow-9637aff2:Favorite Logistics"; do
  DIR="${ENTRY%%:*}"
  NAME="${ENTRY#*:}"
  COMMITS=$(git -C "$WORKSPACE/$DIR" log --oneline --since="24 hours ago" 2>/dev/null | head -5)
  if [[ -n "$COMMITS" ]]; then
    REPO_LOG="${REPO_LOG}**${NAME}:**
$COMMITS

"
  fi
done
[[ -z "$REPO_LOG" ]] && REPO_LOG="No commits in any client repo today."

# ── Write daily log ───────────────────────────────────────────────────────────
if [[ -f "$OUT_FILE" ]]; then
  echo "[nightly-flush] Log already exists for $DATE — appending system summary"
  cat >> "$OUT_FILE" << SECTION

## Nightly System Summary
- Email activity: ${EMAIL_STATS}
- All agents: $(launchctl list | grep -c com.amalfiai) running

### Repo activity
${REPO_LOG}
SECTION
else
  cat > "$OUT_FILE" << LOG
# Daily Log — ${DOW}

## Email Activity
${EMAIL_STATS}

## Agent Health
${AGENT_STATUS}

## Repo Activity
${REPO_LOG}
LOG
fi

echo "[nightly-flush] Written: $OUT_FILE"
