#!/bin/bash
# rt-monitor.sh
# AOS client system monitor for Race Technik Mac Mini.
# Runs every 5 minutes from the MacBook (the manager).
# - Checks all raceai LaunchAgent statuses
# - Detects stuck pollers via log stagnation
# - Attempts auto-heal (restart) on failures
# - Creates Supabase tasks for persistent or unfixable failures
# - Alerts Josh on Telegram (state transitions only — no spam)
# - Logs everything locally

set -eo pipefail

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
LOG="$WORKSPACE/out/rt-monitor.log"
STATE_FILE="$WORKSPACE/tmp/rt-monitor-state.json"
ENV_FILE="$WORKSPACE/.env.scheduler"

mkdir -p "$(dirname "$LOG")" "$(dirname "$STATE_FILE")"

log() { echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") $*" >> "$LOG"; }

source "$ENV_FILE" 2>/dev/null || true

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-1140320036}"
SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
RT_SSH="ssh -i /Users/henryburton/.ssh/race_technik -o ConnectTimeout=10 -o StrictHostKeyChecking=no raceai@100.114.191.52"

# ── Helpers ───────────────────────────────────────────────────────────────────

send_alert() {
  local text="$1"
  [[ -z "$BOT_TOKEN" ]] && return
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(printf '%s' "$text" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),\"parse_mode\":\"HTML\"}" \
    > /dev/null 2>&1 || true
}

create_task() {
  local title="$1" description="$2"
  [[ -z "$SUPABASE_KEY" ]] && return
  curl -s -X POST "${SUPABASE_URL}/rest/v1/tasks" \
    -H "apikey: $SUPABASE_KEY" \
    -H "Authorization: Bearer $SUPABASE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"title\":$(printf '%s' "$title" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),\"description\":$(printf '%s' "$description" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),\"status\":\"todo\",\"assigned_to\":\"Claude\",\"priority\":\"high\",\"created_by\":\"rt-monitor\",\"metadata\":{\"client\":\"race_technik\",\"source\":\"rt-monitor\"}}" \
    > /dev/null 2>&1 || true
}

# Load or initialise state
load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE"
  else
    echo '{}'
  fi
}

get_field() {
  local state="$1" key="$2" default="$3"
  echo "$state" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('$key', '$default'))
" 2>/dev/null || echo "$default"
}

# ── SSH check ─────────────────────────────────────────────────────────────────

log "--- RT Monitor run starting ---"

RT_DATA=$($RT_SSH "
  echo '===AGENTS==='
  launchctl list | grep raceai || true
  echo '===DNS==='
  curl -s --max-time 5 https://api.telegram.org > /dev/null 2>&1 && echo 'ok' || echo 'fail'
  echo '===POLLER_LOG_TAIL==='
  tail -3 /Users/raceai/.amalfiai/workspace/out/telegram-poller.log 2>/dev/null || echo 'no_log'
  echo '===DISK==='
  df -h / | awk 'NR==2{print \$5}'
" 2>&1) || {
  log "SSH_FAIL: Cannot reach RT Mac Mini"
  PREV=$(load_state)
  PREV_SSH=$(get_field "$PREV" "ssh" "ok")
  if [[ "$PREV_SSH" != "fail" ]]; then
    send_alert "🔴 <b>Race Technik Mac Mini — OFFLINE</b>

AOS cannot reach the Mac Mini via SSH. Telegram poller and all agents are unverifiable.

Check: Farhaan's internet / Tailscale / machine power."
    create_task "RT Mac Mini SSH unreachable" "AOS rt-monitor cannot SSH into the Race Technik Mac Mini at 100.114.191.52. All agent status is unknown. Investigate connectivity: Tailscale, router, machine power. Auto-detected at $(date -u +"%Y-%m-%dT%H:%M:%SZ")."
  fi
  python3 -c "import json; d=$(cat "$STATE_FILE" 2>/dev/null || echo '{}'); d['ssh']='fail'; d['last_check']='$(date -u +"%Y-%m-%dT%H:%M:%SZ")'; print(json.dumps(d))" > "$STATE_FILE" 2>/dev/null || echo '{"ssh":"fail"}' > "$STATE_FILE"
  exit 0
}

# Parse results
AGENTS_BLOCK=$(echo "$RT_DATA" | awk '/===AGENTS===/,/===DNS===/' | grep -v '===')
DNS_STATUS=$(echo "$RT_DATA" | awk '/===DNS===/,/===POLLER_LOG_TAIL===/' | grep -v '===')
POLLER_TAIL=$(echo "$RT_DATA" | awk '/===POLLER_LOG_TAIL===/,/===DISK===/' | grep -v '===')
DISK_USAGE=$(echo "$RT_DATA" | awk '/===DISK===/{getline; print}' | tr -d '%' | tr -d ' ')

log "SSH OK | DNS: $DNS_STATUS | Disk: ${DISK_USAGE}%"

# ── Load previous state ───────────────────────────────────────────────────────

PREV_STATE=$(load_state)
PREV_SSH=$(get_field "$PREV_STATE" "ssh" "ok")

# SSH recovered alert
if [[ "$PREV_SSH" == "fail" ]]; then
  send_alert "✅ <b>Race Technik Mac Mini</b> — SSH connection restored. Resuming agent monitoring."
fi

# ── Analyse agent statuses ────────────────────────────────────────────────────

ISSUES=()
FIXED=()
ALERT_LINES=()

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  EXIT_CODE=$(echo "$line" | awk '{print $2}')
  AGENT=$(echo "$line" | awk '{print $3}')
  PID=$(echo "$line" | awk '{print $1}')

  # Skip non-agents and agents that run on schedule (- means not running = normal)
  # Critical always-on agents that should have a PID
  CRITICAL_AGENTS="com.raceai.telegram-poller com.raceai.dashboard com.raceai.watchdog com.raceai.keepawake"

  if echo "$CRITICAL_AGENTS" | grep -q "$AGENT"; then
    if [[ "$PID" == "-" && "$EXIT_CODE" != "0" ]]; then
      ISSUES+=("$AGENT (exited: $EXIT_CODE)")
      log "ISSUE: $AGENT not running (exit $EXIT_CODE)"

      # Attempt auto-restart
      RESTART_RESULT=$($RT_SSH "launchctl start $AGENT 2>&1 && echo 'restarted' || echo 'restart_failed'" 2>/dev/null || echo "ssh_fail")
      if [[ "$RESTART_RESULT" == "restarted" ]]; then
        FIXED+=("$AGENT")
        log "AUTO-FIXED: $AGENT restarted"
      else
        log "RESTART_FAILED: $AGENT could not be restarted"
      fi
    fi
  fi

  # Detect persistent error exit codes (not -/0)
  if [[ "$EXIT_CODE" != "0" && "$EXIT_CODE" != "-" && "$PID" == "-" ]]; then
    ISSUES+=("$AGENT (exit $EXIT_CODE)")
    log "ISSUE: $AGENT exit code $EXIT_CODE"
  fi
done <<< "$AGENTS_BLOCK"

# ── Poller stuck detection ────────────────────────────────────────────────────
# If all recent log lines say "Network down" but DNS is ok, poller is stuck

if [[ "$DNS_STATUS" == "ok" ]]; then
  STUCK=$(echo "$POLLER_TAIL" | grep -c "Network down" || true)
  if [[ "$STUCK" -ge "2" ]]; then
    log "ISSUE: Telegram poller stuck in network retry loop despite DNS being ok"
    ISSUES+=("telegram-poller (stuck)")
    RESTART_RESULT=$($RT_SSH "
      launchctl stop com.raceai.telegram-poller 2>/dev/null
      sleep 2
      launchctl start com.raceai.telegram-poller 2>/dev/null
      echo 'restarted'
    " 2>/dev/null || echo "ssh_fail")
    if [[ "$RESTART_RESULT" == *"restarted"* ]]; then
      FIXED+=("telegram-poller (unstuck)")
      log "AUTO-FIXED: Telegram poller restarted to clear stuck state"
    fi
  fi
fi

# ── Disk usage alert ──────────────────────────────────────────────────────────

if [[ -n "$DISK_USAGE" ]] && [[ "$DISK_USAGE" -gt 85 ]] 2>/dev/null; then
  ISSUES+=("disk ${DISK_USAGE}% used")
  log "ISSUE: Disk usage critical at ${DISK_USAGE}%"
fi

# ── Build alert and task if needed ───────────────────────────────────────────

PREV_ISSUES=$(get_field "$PREV_STATE" "issues" "none")
CURR_ISSUES_STR=$(printf '%s,' "${ISSUES[@]}" 2>/dev/null | sed 's/,$//') || CURR_ISSUES_STR=""
[[ -z "$CURR_ISSUES_STR" ]] && CURR_ISSUES_STR="none"

if [[ "${#ISSUES[@]}" -gt 0 ]]; then
  log "Total issues: ${#ISSUES[@]}"

  # Alert on new issues (not same as last run)
  if [[ "$CURR_ISSUES_STR" != "$PREV_ISSUES" ]]; then
    MSG="⚠️ <b>Race Technik Mac Mini — Issues Detected</b>\n\n"
    for issue in "${ISSUES[@]}"; do
      MSG="${MSG}• $issue\n"
    done
    if [[ "${#FIXED[@]}" -gt 0 ]]; then
      MSG="${MSG}\n<b>Auto-fixed:</b>\n"
      for fix in "${FIXED[@]}"; do
        MSG="${MSG}• $fix\n"
      done
    fi
    send_alert "$MSG"

    # Create task for unfixed issues
    UNFIXED_COUNT=$(( ${#ISSUES[@]} - ${#FIXED[@]} ))
    if [[ "$UNFIXED_COUNT" -gt 0 ]]; then
      TASK_DESC="RT Monitor detected ${#ISSUES[@]} issue(s) on the Race Technik Mac Mini at $(date -u +"%Y-%m-%dT%H:%M:%SZ"). Issues: ${CURR_ISSUES_STR}. Auto-fix attempted but ${UNFIXED_COUNT} remain unresolved. Investigate and resolve."
      create_task "RT Mac Mini: ${UNFIXED_COUNT} agent issue(s) need attention" "$TASK_DESC"
      log "Supabase task created for unresolved issues"
    fi
  fi
elif [[ "$PREV_ISSUES" != "none" && "$PREV_ISSUES" != "" ]]; then
  # Was failing, now recovered
  send_alert "✅ <b>Race Technik Mac Mini</b> — All systems recovered. No active issues."
  log "All issues resolved — recovery alert sent"
fi

# ── Save state ────────────────────────────────────────────────────────────────

python3 -c "
import json
d = {
    'ssh': 'ok',
    'issues': '$CURR_ISSUES_STR',
    'last_check': '$(date -u +"%Y-%m-%dT%H:%M:%SZ")',
    'dns': '$DNS_STATUS',
    'disk': '${DISK_USAGE:-unknown}'
}
print(json.dumps(d))
" > "$STATE_FILE" 2>/dev/null

log "--- RT Monitor run complete. Issues: ${CURR_ISSUES_STR} ---"
