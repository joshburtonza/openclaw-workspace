#!/bin/bash
# alex-status.sh — Update Alex Claww's live status in Mission Control
#
# Usage:
#   ./alex-status.sh start "Building Content page + video scripts"
#   ./alex-status.sh done "Content page deployed"
#   ./alex-status.sh idle
#   ./alex-status.sh error "Something broke in cron"
#
# Also logs to tasks table as in_progress / done

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ"
AGENT_NAME="Alex Claww"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

ACTION="${1:-idle}"
TASK="${2:-}"

update_agent() {
  local status="$1"
  local task="$2"
  curl -s -X PATCH \
    "${SUPABASE_URL}/rest/v1/agents?name=eq.${AGENT_NAME// /%20}" \
    -H "apikey: ${ANON_KEY}" \
    -H "Authorization: Bearer ${ANON_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"status\":\"${status}\",\"current_task\":\"${task}\",\"last_activity\":\"${NOW}\"}" \
    -o /dev/null
}

log_task() {
  local title="$1"
  local status="$2"
  local priority="${3:-normal}"
  local completed=""
  if [[ "$status" == "done" ]]; then
    completed="\"completed_at\":\"${NOW}\","
  fi
  curl -s -X POST "${SUPABASE_URL}/rest/v1/tasks" \
    -H "apikey: ${ANON_KEY}" \
    -H "Authorization: Bearer ${ANON_KEY}" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=minimal" \
    -d "{\"title\":\"${title}\",\"status\":\"${status}\",${completed}\"priority\":\"${priority}\",\"assigned_to\":\"Alex Claww\",\"created_by\":\"Alex Claww\"}" \
    -o /dev/null
}

case "$ACTION" in
  start)
    if [[ -z "$TASK" ]]; then echo "Usage: $0 start 'task description'"; exit 1; fi
    update_agent "online" "$TASK"
    log_task "$TASK" "in_progress"
    echo "[alex-status] ▶ Started: $TASK"
    ;;

  done)
    MSG="${TASK:-Task complete}"
    update_agent "online" "Monitoring + chat"
    log_task "$MSG" "done"
    echo "[alex-status] ✓ Done: $MSG"
    ;;

  idle)
    update_agent "idle" "Waiting for next task"
    echo "[alex-status] ⏸ Idle"
    ;;

  error)
    MSG="${TASK:-Unknown error}"
    update_agent "error" "ERROR: $MSG"
    log_task "ERROR: $MSG" "in_progress" "urgent"
    echo "[alex-status] ✗ Error: $MSG"
    ;;

  *)
    echo "Usage: $0 [start|done|idle|error] [description]"
    exit 1
    ;;
esac
