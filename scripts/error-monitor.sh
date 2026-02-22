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
CHAT_ID="7584896900"

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

while IFS=$'\t' read -r PID EXIT_CODE LABEL; do
  # Only care about non-zero exits (not "-" which means not running yet)
  [[ "$EXIT_CODE" == "0" || "$EXIT_CODE" == "-" ]] && continue
  [[ "$LABEL" != com.amalfiai.* ]] && continue

  # Skip error-monitor itself (avoid self-restart loop)
  [[ "$LABEL" == "com.amalfiai.error-monitor" ]] && continue

  AGENT="${LABEL#com.amalfiai.}"
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Agent $AGENT exited $EXIT_CODE — attempting restart"

  # Restart
  launchctl stop "$LABEL" 2>/dev/null || true
  sleep 2
  launchctl start "$LABEL" 2>/dev/null || true
  sleep 5

  # Recheck
  NEW_EXIT=$(launchctl list "$LABEL" 2>/dev/null | python3 -c "
import sys
for line in sys.stdin:
    parts = line.strip().split()
    if len(parts) >= 2:
        print(parts[1])
        break
print('?')
" 2>/dev/null | head -1 || echo "?")

  if [[ "$NEW_EXIT" == "0" || "$NEW_EXIT" == "-" ]]; then
    RESTART_ALERTS="${RESTART_ALERTS}✅ <b>${AGENT}</b> restarted successfully (was exit ${EXIT_CODE})\n"
    echo "  $AGENT restart: OK"
  else
    RESTART_FAILED="${RESTART_FAILED}❌ <b>${AGENT}</b> still failing (exit ${NEW_EXIT} after restart)\n"
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

for ERR_LOG in "$OUT_DIR"/*.err.log; do
  [[ -f "$ERR_LOG" ]] || continue

  FILE_MOD=$(stat -f "%m" "$ERR_LOG" 2>/dev/null || stat -c "%Y" "$ERR_LOG" 2>/dev/null || echo 0)
  [[ "$FILE_MOD" -le "$LAST_CHECK" ]] && continue

  AGENT_NAME=$(basename "$ERR_LOG" .err.log)
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
