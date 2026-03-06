#!/bin/bash
# rt-token-sync.sh
# Reads fresh Claude Code OAuth token from local keychain and pushes it
# to the Race Technik Mac Mini every 30 minutes.

set -euo pipefail

LOG="/Users/henryburton/.openclaw/workspace-anthropic/out/rt-token-sync.log"
mkdir -p "$(dirname "$LOG")"

log() { echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") $*" >> "$LOG"; }

# Extract token from keychain
RAW=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)
if [[ -z "$RAW" ]]; then
  log "ERROR: Could not read Claude Code credentials from keychain"
  exit 1
fi

TOKEN=$(echo "$RAW" | python3 -c "
import sys, json
raw = sys.stdin.read().strip()
try:
    d = json.loads(raw)
    cai = d.get('claudeAiOauth', {})
    print(cai.get('accessToken') or cai.get('access_token') or '')
except Exception as e:
    print('')
" 2>/dev/null)

if [[ -z "$TOKEN" ]]; then
  log "ERROR: Could not parse access token from keychain credentials"
  exit 1
fi

log "Token extracted (${TOKEN:0:20}...)"

# Push to Race Technik Mac Mini
ssh -i ~/.ssh/race_technik -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
  raceai@100.114.191.52 "python3 -c \"
import re
path = '/Users/raceai/.amalfiai/workspace/.env.scheduler'
content = open(path).read()
new = re.sub(r'CLAUDE_CODE_OAUTH_TOKEN=.*', 'CLAUDE_CODE_OAUTH_TOKEN=$TOKEN', content)
open(path, 'w').write(new)
print('updated')
\"" 2>/dev/null && log "Token pushed to Mac Mini" || { log "ERROR: SSH push failed"; exit 1; }

log "Done"

# ── Race Technik Mac Mini health check ───────────────────────────────────────
# Check Telegram poller status and DNS reachability from the Mac Mini.
# Alert Josh on state transition (OK→FAIL or FAIL→OK). Avoids repeated noise.

STATE_FILE="/Users/henryburton/.openclaw/workspace-anthropic/tmp/rt-poller-health.state"
mkdir -p "$(dirname "$STATE_FILE")"

source /Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler 2>/dev/null || true

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-1140320036}"

send_alert() {
  local text="$1"
  if [[ -n "$BOT_TOKEN" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(printf '%s' "$text" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),\"parse_mode\":\"HTML\"}" \
      > /dev/null
  fi
}

HEALTH_RESULT=$(ssh -i ~/.ssh/race_technik -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
  raceai@100.114.191.52 "
    poller_ok=0
    dns_ok=0
    launchctl list | grep -q 'com.raceai.telegram-poller' && poller_ok=1
    curl -s --max-time 5 https://api.telegram.org > /dev/null 2>&1 && dns_ok=1
    echo \"\${poller_ok}:\${dns_ok}\"
  " 2>/dev/null || echo "ssh_fail")

PREV_STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "unknown")

if [[ "$HEALTH_RESULT" == "ssh_fail" ]]; then
  NEW_STATE="ssh_fail"
  log "RT health check: SSH unreachable"
  if [[ "$PREV_STATE" != "ssh_fail" ]]; then
    send_alert "⚠️ <b>Race Technik Mac Mini</b> — SSH unreachable during health check. Cannot verify Telegram poller status."
  fi
else
  POLLER_OK=$(echo "$HEALTH_RESULT" | cut -d: -f1)
  DNS_OK=$(echo "$HEALTH_RESULT" | cut -d: -f2)
  log "RT health check: poller=${POLLER_OK} dns=${DNS_OK}"

  if [[ "$POLLER_OK" == "1" && "$DNS_OK" == "1" ]]; then
    NEW_STATE="ok"
    if [[ "$PREV_STATE" != "ok" && "$PREV_STATE" != "unknown" ]]; then
      send_alert "✅ <b>Race Technik Mac Mini</b> — Telegram poller recovered. All systems green."
    fi
  else
    NEW_STATE="fail"
    if [[ "$PREV_STATE" != "fail" ]]; then
      MSG="⚠️ <b>Race Technik Mac Mini</b> — Telegram poller issue detected."
      [[ "$POLLER_OK" != "1" ]] && MSG="${MSG}\n— Poller not running (launchctl)"
      [[ "$DNS_OK" != "1" ]] && MSG="${MSG}\n— DNS/network: api.telegram.org unreachable"
      MSG="${MSG}\n\nFarhaan may need to restart the router or the Mac Mini."
      send_alert "$MSG"
    fi
  fi
fi

echo "$NEW_STATE" > "$STATE_FILE"
