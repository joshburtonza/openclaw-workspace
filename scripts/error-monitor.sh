#!/usr/bin/env bash
# error-monitor.sh — watches *.err.log files AND launchctl exit codes
# Auto-restarts failing agents. Alerts Telegram only if still broken after restart.
# Runs every 10 minutes via LaunchAgent
set -euo pipefail

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WORKSPACE/.env.scheduler"
STATE_FILE="$WORKSPACE/tmp/error-monitor-last-check"
OUT_DIR="$WORKSPACE/out"

if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
fi

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
_CHAT_ID_FILE="/Users/henryburton/.openclaw/workspace-anthropic/tmp/josh_private_chat_id"
CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-$(cat "$_CHAT_ID_FILE" 2>/dev/null || echo "1140320036")}"

if [[ -z "$BOT_TOKEN" ]]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") ERROR: No TELEGRAM_BOT_TOKEN set" >&2
  exit 1
fi

send_telegram() {
  local text="$1"
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(printf '%s' "$text" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),\"parse_mode\":\"HTML\"}" \
    > /dev/null
}

# ── 1. Check launchctl exit codes — auto-restart failing agents ───────────────

RESTART_ALERTS=""
RESTART_FAILED=""
FAILED_AGENTS=""   # plain list for auto-healer — format: "agent|||reason\n"

while IFS=$'\t' read -r PID EXIT_CODE LABEL; do
  # Skip healthy states: running (-), clean exit (0), or SIGTERM (-15 = clean stop by launchd/user)
  [[ "$EXIT_CODE" == "0" || "$EXIT_CODE" == "-" || "$EXIT_CODE" == "-15" ]] && continue
  [[ "$LABEL" != com.amalfiai.* ]] && continue

  # Skip error-monitor itself (avoid self-restart loop)
  [[ "$LABEL" == "com.amalfiai.error-monitor" ]] && continue

  # Skip KeepAlive persistent bots — launchd handles their restart automatically
  [[ "$LABEL" == "com.amalfiai.discord-community-bot" ]] && continue
  [[ "$LABEL" == "com.amalfiai.telegram-poller" ]] && continue

  AGENT="${LABEL#com.amalfiai.}"
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Agent $AGENT exited $EXIT_CODE — attempting restart"

  # Restart
  launchctl stop "$LABEL" 2>/dev/null || true
  sleep 2
  launchctl start "$LABEL" 2>/dev/null || true
  sleep 5

  # Recheck — use tabular launchctl list (not single-label plist format)
  NEW_LINE=$(launchctl list 2>/dev/null | grep "$LABEL" || echo "")
  NEW_PID=$(echo "$NEW_LINE" | awk '{print $1}')
  NEW_EXIT=$(echo "$NEW_LINE" | awk '{print $2}')

  # Success if process is running (PID is a number) or exit was clean
  if [[ "$NEW_EXIT" == "0" || "$NEW_EXIT" == "-" || "$NEW_EXIT" == "-15" ]] || \
     [[ "$NEW_PID" =~ ^[0-9]+$ ]]; then
    RESTART_ALERTS="${RESTART_ALERTS}✅ <b>${AGENT}</b> restarted successfully (was exit ${EXIT_CODE})\n"
    echo "  $AGENT restart: OK"
  else
    RESTART_FAILED="${RESTART_FAILED}❌ <b>${AGENT}</b> still failing (exit ${NEW_EXIT} after restart)\n"
    FAILED_AGENTS="${FAILED_AGENTS}${AGENT}|||still failing after restart attempt (exit ${NEW_EXIT})"$'\n'
    echo "  $AGENT restart: FAILED (still exit $NEW_EXIT)" >&2
  fi
done < <(launchctl list | grep com.amalfiai)

# ── 2. Check *.err.log files for new content ──────────────────────────────────

if [[ -f "$STATE_FILE" ]]; then
  LAST_CHECK=$(cat "$STATE_FILE")
else
  LAST_CHECK=$(( $(date +%s) - 600 ))
fi

NOW=$(date +%s)
echo "$NOW" > "$STATE_FILE"

ERRORS_FOUND=""
RAW_ERROR_TASKS=""  # plain list for auto-healer — format: "agent|||error_excerpt\n"

for ERR_LOG in "$OUT_DIR"/*.err.log; do
  [[ -f "$ERR_LOG" ]] || continue

  FILE_MOD=$(stat -f "%m" "$ERR_LOG" 2>/dev/null || stat -c "%Y" "$ERR_LOG" 2>/dev/null || echo 0)
  [[ "$FILE_MOD" -le "$LAST_CHECK" ]] && continue

  AGENT_NAME=$(basename "$ERR_LOG" .err.log)

  # Skip self-monitoring — restart failures already alerted via Telegram; monitoring own log creates self-triggering loops
  [[ "$AGENT_NAME" == "error-monitor" ]] && continue
  NEW_LINES=$(tail -20 "$ERR_LOG" 2>/dev/null)
  [[ -z "$NEW_LINES" ]] && continue

  FILTERED=$(echo "$NEW_LINES" | grep -v "^$" | \
    grep -v "No approved emails" | \
    grep -v "No reminders" | \
    grep -v "scripts already present" | \
    grep -v "No new errors found" | \
    grep -v "^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$" | \
    grep -v "^Starting" | \
    grep -v "^Done" | \
    head -10 || true)

  if [[ -n "$FILTERED" ]]; then
    ERRORS_FOUND="${ERRORS_FOUND}
<b>${AGENT_NAME}</b>:
<code>${FILTERED}</code>
"
    # Track for auto-healer task creation (one line, truncated)
    FILTERED_BRIEF=$(echo "$FILTERED" | tr '\n' ' ' | cut -c1-300)
    RAW_ERROR_TASKS="${RAW_ERROR_TASKS}${AGENT_NAME}|||${FILTERED_BRIEF}"$'\n'
  fi
done

# ── 3. Send alerts ────────────────────────────────────────────────────────────

if [[ -n "$RESTART_FAILED" || -n "$ERRORS_FOUND" ]]; then
  MSG="🚨 <b>Error Monitor</b>"

  if [[ -n "$RESTART_FAILED" ]]; then
    MSG="${MSG}

<b>Agents still failing after restart:</b>
$(echo -e "$RESTART_FAILED")"
  fi

  if [[ -n "$ERRORS_FOUND" ]]; then
    MSG="${MSG}

<b>New errors in logs:</b>
${ERRORS_FOUND}"
  fi

  MSG="${MSG}
$(date -u +"%Y-%m-%d %H:%M UTC")"

  send_telegram "$MSG"
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Alert sent"
elif [[ -n "$RESTART_ALERTS" ]]; then
  # Quiet restarts — just log, don't Telegram unless you want to know about it
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Auto-restarted agents: $(echo -e "$RESTART_ALERTS" | grep -o 'b>.*</b' | tr -d 'b></' | tr '\n' ' ')"
else
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") All agents healthy"
fi

# ── 4. Auto-healer — create tasks for persistent errors ──────────────────────

SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
if [[ -n "$SUPABASE_KEY" ]] && [[ -n "$FAILED_AGENTS" || -n "$RAW_ERROR_TASKS" ]]; then
  export _EM_KEY="$SUPABASE_KEY" \
         _EM_URL="https://afmpbtynucpbglwtbfuz.supabase.co" \
         _EM_FAILED="$FAILED_AGENTS" \
         _EM_ERRORS="$RAW_ERROR_TASKS"

  python3 - <<'PYEOF'
import os, json, urllib.request, urllib.parse

KEY = os.environ['_EM_KEY']
URL = os.environ['_EM_URL']

def task_exists(title):
    """Return True if a todo/in_progress task with this title already exists."""
    encoded = urllib.parse.quote(title)
    req = urllib.request.Request(
        f"{URL}/rest/v1/tasks?title=eq.{encoded}&status=in.(todo,in_progress)&select=id&limit=1",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            rows = json.loads(r.read())
            return len(rows) > 0
    except Exception:
        return False

def create_task(title, description):
    if task_exists(title):
        print(f"[auto-healer] Already queued: {title}")
        return
    data = json.dumps({
        "title":       title,
        "description": description,
        "assigned_to": "Claude",
        "created_by":  "error-monitor",
        "priority":    "high",
        "status":      "todo",
        "tags":        ["auto-healer"],
    }).encode()
    req = urllib.request.Request(
        f"{URL}/rest/v1/tasks",
        data=data,
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
                 "Content-Type": "application/json", "Prefer": "return=minimal"},
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=10)
        print(f"[auto-healer] Task created: {title}")
    except Exception as e:
        print(f"[auto-healer] Failed to create task '{title}': {e}")

# Process restart failures
for line in os.environ.get('_EM_FAILED', '').strip().split('\n'):
    line = line.strip()
    if not line or '|||' not in line:
        continue
    agent, reason = line.split('|||', 1)
    agent = agent.strip()
    title = f"Fix crashed agent: {agent}"
    desc  = (
        f"The LaunchAgent '{agent}' (com.amalfiai.{agent}) failed to restart and is still exiting with an error.\n\n"
        f"Reason: {reason.strip()}\n\n"
        f"Steps to investigate:\n"
        f"1. Check logs: tail -50 /Users/henryburton/.openclaw/workspace-anthropic/out/{agent}.err.log\n"
        f"2. Read the script: cat /Users/henryburton/.openclaw/workspace-anthropic/scripts/{agent}.sh\n"
        f"3. Test manually: bash /Users/henryburton/.openclaw/workspace-anthropic/scripts/{agent}.sh\n"
        f"4. Fix root cause and reload: launchctl unload ~/Library/LaunchAgents/com.amalfiai.{agent}.plist "
        f"&& launchctl load ~/Library/LaunchAgents/com.amalfiai.{agent}.plist"
    )
    create_task(title, desc)

# Process log errors
for line in os.environ.get('_EM_ERRORS', '').strip().split('\n'):
    line = line.strip()
    if not line or '|||' not in line:
        continue
    agent, error_excerpt = line.split('|||', 1)
    agent = agent.strip()
    title = f"Fix log errors: {agent}"
    desc  = (
        f"New errors were detected in {agent}.err.log.\n\n"
        f"Error excerpt:\n{error_excerpt.strip()}\n\n"
        f"Steps to investigate:\n"
        f"1. Review full log: tail -50 /Users/henryburton/.openclaw/workspace-anthropic/out/{agent}.err.log\n"
        f"2. Read the script to understand the error: cat /Users/henryburton/.openclaw/workspace-anthropic/scripts/{agent}.sh\n"
        f"3. Identify and fix the root cause\n"
        f"4. Test manually if possible, then reload the LaunchAgent if the script was modified"
    )
    create_task(title, desc)
PYEOF
fi
