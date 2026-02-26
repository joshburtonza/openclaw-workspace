#!/bin/bash
# claude-task-worker.sh
# Polls task_queue for status=queued, agent='Claude Code' tasks.
# Picks up one task, runs Claude with full context, writes result back.
# Runs every 60s via LaunchAgent.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID_FILE="$WS/tmp/josh_private_chat_id"
MODEL="claude-sonnet-4-6"

log() { echo "[$(date '+%H:%M:%S')] [task-worker] $*"; }

tg_send() {
  local text="$1"
  local chat_id
  chat_id=$(cat "$CHAT_ID_FILE" 2>/dev/null || echo "")
  [[ -z "$chat_id" ]] && return
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H 'Content-Type: application/json' \
    -d "{\"chat_id\":\"${chat_id}\",\"text\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$text"),\"parse_mode\":\"HTML\"}" \
    >/dev/null
}

supa_get() {
  curl -s "${SUPABASE_URL}/rest/v1/${1}" \
    -H "apikey: $KEY" \
    -H "Authorization: Bearer $KEY"
}

supa_patch() {
  curl -s -X PATCH "${SUPABASE_URL}/rest/v1/${1}" \
    -H "apikey: $KEY" \
    -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" \
    -d "$2"
}

# ── Fetch one queued Claude Code task ─────────────────────────────────────────
TASK_JSON=$(supa_get "task_queue?status=eq.queued&agent=eq.Claude%20Code&task_type=eq.task_execution&order=created_at.asc&limit=1")

TASK_COUNT=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
if [[ "$TASK_COUNT" -eq 0 ]]; then
  log "No queued tasks."
  exit 0
fi

TASK_ID=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['id'])")
TASK_TITLE=$(echo "$TASK_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin)[0]; print((d.get('payload') or {}).get('title','Untitled'))")
TASK_PROMPT=$(echo "$TASK_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin)[0]; p=d.get('payload') or {}; print(p.get('prompt') or p.get('title',''))")

log "Picked up: $TASK_TITLE ($TASK_ID)"

# ── Mark as executing ─────────────────────────────────────────────────────────
NOW=$(python3 -c "import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
supa_patch "task_queue?id=eq.${TASK_ID}" \
  "{\"status\":\"executing\",\"started_at\":\"${NOW}\"}"

# ── Build prompt with full memory context ─────────────────────────────────────
MEMORY=$(cat "$WS/memory/MEMORY.md" 2>/dev/null || echo "")
STATE=$(cat "$WS/CURRENT_STATE.md" 2>/dev/null || echo "")
TODAY=$(date '+%A, %d %B %Y %H:%M SAST')
SYSTEM_PROMPT=$(cat "$WS/prompts/telegram-claude-system.md" 2>/dev/null || echo "You are Claude, Amalfi AI's AI assistant.")

PROMPT_TMP=$(mktemp /tmp/task-worker-XXXXXX)
cat > "$PROMPT_TMP" <<PROMPT
${SYSTEM_PROMPT}

Today: ${TODAY}

=== LONG-TERM MEMORY ===
${MEMORY}

=== CURRENT SYSTEM STATE ===
${STATE}

=== AUTONOMOUS TASK ===
You have been assigned a task from Mission Control. Complete it fully and return your output.
The result will be stored in the task queue and shown in Mission Control, and you will notify Josh via Telegram.

Task: ${TASK_PROMPT}
PROMPT

# ── Run Claude ────────────────────────────────────────────────────────────────
log "Running Claude on task: $TASK_TITLE"
unset CLAUDECODE

RESPONSE=$(claude --print \
  --dangerously-skip-permissions \
  --model "$MODEL" \
  --add-dir "$WS" \
  < "$PROMPT_TMP" 2>/dev/null) || RESPONSE=""

rm -f "$PROMPT_TMP"

COMPLETED_AT=$(python3 -c "import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")

# ── Write result back to Supabase ─────────────────────────────────────────────
if [[ -n "$RESPONSE" ]]; then
  RESULT_JSON=$(python3 -c "
import json, os, sys
output = os.environ.get('RESPONSE','')
completed = os.environ.get('COMPLETED_AT','')
print(json.dumps({'output': output, 'completed_at': completed}))
" 2>/dev/null)

  export RESPONSE COMPLETED_AT
  supa_patch "task_queue?id=eq.${TASK_ID}" \
    "{\"status\":\"completed\",\"completed_at\":\"${COMPLETED_AT}\",\"result\":${RESULT_JSON}}"

  log "Task completed: $TASK_TITLE"

  # Notify Josh via Telegram
  PREVIEW="${RESPONSE:0:400}"
  tg_send "✅ <b>Task complete</b>
<b>${TASK_TITLE}</b>

${PREVIEW}$([ ${#RESPONSE} -gt 400 ] && echo '...' || echo '')"

else
  # Claude returned nothing — mark failed
  supa_patch "task_queue?id=eq.${TASK_ID}" \
    "{\"status\":\"failed\",\"completed_at\":\"${COMPLETED_AT}\",\"result\":{\"error\":\"Claude returned no output\"}}"

  log "Task failed (no output): $TASK_TITLE"
  tg_send "❌ <b>Task failed</b>: ${TASK_TITLE}
Claude returned no output. Check logs."
fi

# ── Log to daily memory file ───────────────────────────────────────────────────
TODAY_LOG="$WS/memory/$(date '+%Y-%m-%d').md"
{
  echo ""
  echo "### $(date '+%H:%M SAST') — Autonomous Task"
  echo "**Task:** $TASK_TITLE"
  echo "**Result:** $RESPONSE"
} >> "$TODAY_LOG"
