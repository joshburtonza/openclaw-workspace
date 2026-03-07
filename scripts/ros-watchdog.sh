#!/usr/bin/env bash
# ros-watchdog.sh — monitors Race Technik Mac Mini (ROS) every 5 min
# SSHes in, checks critical services, alerts Josh on Telegram if anything is down

WS="/Users/henryburton/.openclaw/workspace-anthropic"
LOG="$WS/out/ros-watchdog.log"
STATE_FILE="$WS/tmp/ros-watchdog-state.json"
SSH_KEY="$HOME/.ssh/race_technik"
ROS_HOST="raceai@100.114.191.52"
JOSH_CHAT="1140320036"

source "$WS/.env.scheduler"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# Load previous state to suppress repeated alerts
prev_state() {
  python3 -c "import json; d=json.load(open('$STATE_FILE')) if __import__('os').path.exists('$STATE_FILE') else {}; print(d.get('$1','ok'))" 2>/dev/null || echo "ok"
}

save_state() {
  python3 -c "
import json, os
f='$STATE_FILE'
d=json.load(open(f)) if os.path.exists(f) else {}
d['$1']='$2'
json.dump(d, open(f,'w'))
" 2>/dev/null
}

send_telegram() {
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"$JOSH_CHAT\",\"text\":\"$1\"}" > /dev/null
}

# Check if ROS is reachable at all
if ! ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$ROS_HOST" "echo ok" &>/dev/null; then
  if [[ "$(prev_state ssh)" != "down" ]]; then
    log "ALERT: ROS unreachable via SSH"
    send_telegram "⚠️ ROS ALERT: Race Technik Mac Mini is unreachable via SSH. Tailscale may be down."
    save_state ssh down
  fi
  exit 0
fi

# ROS is up — reset SSH state
if [[ "$(prev_state ssh)" == "down" ]]; then
  log "ROS SSH recovered"
  send_telegram "✅ ROS RECOVERED: Race Technik Mac Mini is back online."
  save_state ssh ok
fi

# Run checks on ROS
CHECKS=$(ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$ROS_HOST" bash << 'REMOTE'
# Check Telegram poller process
POLLER_PID=$(pgrep -f "rt-poller.py" 2>/dev/null || echo "")
echo "poller:${POLLER_PID:+running}"
echo "poller:${POLLER_PID:-down}"

# Check healthcheck log — last entry timestamp
LAST_HEALTH=$(tail -1 /Users/raceai/.amalfiai/workspace/out/bot-healthcheck.log 2>/dev/null | awk '{print $1}')
echo "healthcheck:$LAST_HEALTH"

# Check if healthcheck is stale (more than 15 min old)
if [[ -n "$LAST_HEALTH" ]]; then
  LAST_TS=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_HEALTH" "+%s" 2>/dev/null || echo 0)
  NOW_TS=$(date +%s)
  AGO=$(( (NOW_TS - LAST_TS) / 60 ))
  echo "health_age_min:$AGO"
fi

# Check load
LOAD=$(uptime | awk -F'load averages:' '{print $2}' | awk '{print $1}')
echo "load:$LOAD"

# Check disk (alert if over 85%)
DISK=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')
echo "disk:$DISK"
REMOTE
)

log "ROS checks: $CHECKS"

# Parse results
POLLER=$(echo "$CHECKS" | grep "^poller:" | tail -1 | cut -d: -f2)
HEALTH_AGE=$(echo "$CHECKS" | grep "^health_age_min:" | cut -d: -f2)
LOAD=$(echo "$CHECKS" | grep "^load:" | cut -d: -f2 | tr -d ' ,')
DISK=$(echo "$CHECKS" | grep "^disk:" | cut -d: -f2)

ALERTS=()

# Poller down?
if [[ "$POLLER" == "down" ]]; then
  if [[ "$(prev_state poller)" != "down" ]]; then
    ALERTS+=("Telegram poller (rt-poller.py) is NOT running")
    save_state poller down
  fi
else
  [[ "$(prev_state poller)" == "down" ]] && { ALERTS+=("Telegram poller recovered"); save_state poller ok; }
fi

# Healthcheck stale?
if [[ -n "$HEALTH_AGE" ]] && (( HEALTH_AGE > 15 )); then
  # Auto-remediate: kickstart the healthcheck LaunchAgent on ROS
  ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$ROS_HOST"     "launchctl kickstart gui/\$(id -u)/com.raceai.bot-healthcheck" &>/dev/null &&     log "Auto-kickstarted com.raceai.bot-healthcheck on ROS"
  if [[ "$(prev_state health)" != "stale" ]]; then
    ALERTS+=("Bot healthcheck was stale (${HEALTH_AGE}m) — auto-kickstarted LaunchAgent")
    save_state health stale
  fi
else
  if [[ "$(prev_state health)" == "stale" ]]; then
    log "Healthcheck recovered"
    send_telegram "✅ ROS: Bot healthcheck recovered and passing normally."
  fi
  save_state health ok
fi

# High load?
LOAD_INT=$(echo "$LOAD" | awk -F. '{print $1}')
if [[ -n "$LOAD_INT" ]] && (( LOAD_INT > 8 )); then
  if [[ "$(prev_state load)" != "high" ]]; then
    ALERTS+=("High CPU load: $LOAD")
    save_state load high
  fi
else
  save_state load ok
fi

# Disk full?
if [[ -n "$DISK" ]] && (( DISK > 85 )); then
  if [[ "$(prev_state disk)" != "full" ]]; then
    ALERTS+=("Disk at ${DISK}% — getting full")
    save_state disk full
  fi
else
  save_state disk ok
fi

if [[ ${#ALERTS[@]} -gt 0 ]]; then
  MSG="⚠️ ROS ALERT (Race Technik Mac Mini):"$'\n'
  for a in "${ALERTS[@]}"; do MSG+="• $a"$'\n'; done
  log "Sending alert: $MSG"
  send_telegram "$MSG"
else
  log "All checks green — poller=$POLLER load=$LOAD disk=${DISK}%"
fi
