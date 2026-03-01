#!/usr/bin/env bash
# telegram-watchdog.sh
# Runs every 5 minutes. Checks if telegram-poller is alive (has a real PID).
# If dead, kickstarts it and sends a Telegram alert to Josh.
# Exists because macOS jetsam (SIGKILL / exit -9) bypasses KeepAlive restarts.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WORKSPACE/.env.scheduler"
LABEL="com.amalfiai.telegram-poller"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-1140320036}"

send_telegram() {
  local text="$1"
  [[ -z "$BOT_TOKEN" ]] && return 0
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(printf '%s' "$text" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),\"parse_mode\":\"HTML\"}" \
    > /dev/null 2>&1 || true
}

# Read current state from launchctl
STATUS_LINE=$(launchctl list 2>/dev/null | grep "$LABEL" || true)

if [[ -z "$STATUS_LINE" ]]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") WARN: $LABEL not found in launchctl — loading plist"
  launchctl load "$PLIST" 2>/dev/null || true
  send_telegram "⚠️ <b>telegram-poller</b> was missing from launchctl — reloaded."
  exit 0
fi

PID=$(echo "$STATUS_LINE" | awk '{print $1}')

if [[ "$PID" =~ ^[0-9]+$ ]]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") OK: $LABEL running (pid $PID)"
  exit 0
fi

# PID is '-' or '0' — process is dead
EXIT_CODE=$(echo "$STATUS_LINE" | awk '{print $2}')
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") WARN: $LABEL is dead (exit $EXIT_CODE) — kickstarting"

launchctl kickstart -k "system/$LABEL" 2>/dev/null || \
  launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || \
  launchctl start "$LABEL" 2>/dev/null || true

sleep 2

# Verify it came back up
NEW_LINE=$(launchctl list 2>/dev/null | grep "$LABEL" || true)
NEW_PID=$(echo "$NEW_LINE" | awk '{print $1}')

if [[ "$NEW_PID" =~ ^[0-9]+$ ]]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") OK: $LABEL restarted (pid $NEW_PID)"
  send_telegram "🔄 <b>telegram-poller</b> was dead (exit ${EXIT_CODE}) — watchdog restarted it. Now pid ${NEW_PID}."
else
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") ERROR: $LABEL failed to restart"
  send_telegram "🚨 <b>telegram-poller</b> is down and watchdog could not restart it. Manual intervention needed."
fi
