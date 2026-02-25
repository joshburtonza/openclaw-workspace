#!/usr/bin/env bash
# telegram-health-check.sh
# Daily verification that Telegram is working and all agents are healthy.
# Sends a summary to Josh every morning at 08:00 SAST.
# Runs via com.amalfiai.telegram-health-check LaunchAgent.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WORKSPACE/.env.scheduler"

if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
fi

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-1140320036}"
SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"

if [[ -z "$BOT_TOKEN" ]]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") ERROR: No TELEGRAM_BOT_TOKEN set" >&2
  exit 1
fi

send_telegram() {
  local text="$1"
  local result
  result=$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(printf '%s' "$text" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),\"parse_mode\":\"HTML\"}" 2>&1)
  if echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
    return 0
  else
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") WARNING: Telegram send may have failed: $result" >&2
    return 1
  fi
}

# ── 1. Audit all com.amalfiai.* LaunchAgents ─────────────────────────────────

AGENT_STATUS=$(launchctl list 2>/dev/null | grep "com.amalfiai\." || echo "")

RUNNING=0
HEALTHY=0
UNHEALTHY=0
UNHEALTHY_LIST=""
KEEPALIVE_LIST=""

while IFS=$'\t' read -r PID EXIT_CODE LABEL; do
  [[ -z "$LABEL" ]] && continue
  AGENT="${LABEL#com.amalfiai.}"
  TOTAL=$((RUNNING + 1))
  RUNNING=$TOTAL

  # KeepAlive bots: check if running (PID is a number)
  if [[ "$LABEL" == "com.amalfiai.discord-community-bot" ]] || \
     [[ "$LABEL" == "com.amalfiai.telegram-poller" ]]; then
    if [[ "$PID" =~ ^[0-9]+$ ]]; then
      KEEPALIVE_LIST="${KEEPALIVE_LIST}✅ ${AGENT} (pid ${PID})\n"
      HEALTHY=$((HEALTHY + 1))
    else
      KEEPALIVE_LIST="${KEEPALIVE_LIST}❌ ${AGENT} (not running — exit ${EXIT_CODE})\n"
      UNHEALTHY=$((UNHEALTHY + 1))
    fi
    continue
  fi

  # Scheduled agents: healthy if exit 0 or currently running or clean SIGTERM
  if [[ "$EXIT_CODE" == "0" || "$EXIT_CODE" == "-" || "$EXIT_CODE" == "-15" ]] || \
     [[ "$PID" =~ ^[0-9]+$ ]]; then
    HEALTHY=$((HEALTHY + 1))
  else
    UNHEALTHY=$((UNHEALTHY + 1))
    UNHEALTHY_LIST="${UNHEALTHY_LIST}⚠️ ${AGENT} (exit ${EXIT_CODE})\n"
  fi
done <<< "$AGENT_STATUS"

# ── 2. Check recent error logs for issues ─────────────────────────────────────

ERROR_SUMMARY=""
CUTOFF=$(( $(date +%s) - 86400 ))  # last 24 hours

for ERR_LOG in "$WORKSPACE/out"/*.err.log; do
  [[ -f "$ERR_LOG" ]] || continue
  FILE_MOD=$(stat -f "%m" "$ERR_LOG" 2>/dev/null || echo 0)
  [[ "$FILE_MOD" -le "$CUTOFF" ]] && continue

  AGENT_NAME=$(basename "$ERR_LOG" .err.log)
  RECENT=$(tail -5 "$ERR_LOG" 2>/dev/null | grep -v "^$" | \
    grep -v "No approved emails" | \
    grep -v "No reminders" | \
    grep -v "All agents healthy" | \
    head -3 || true)
  if [[ -n "$RECENT" ]]; then
    # Replace < > with [ ] so Telegram's HTML parser doesn't choke on traceback lines
    BRIEF=$(echo "$RECENT" | tr '\n' ' ' | tr '<>' '[]' | cut -c1-120)
    ERROR_SUMMARY="${ERROR_SUMMARY}• <b>${AGENT_NAME}</b>: ${BRIEF}\n"
  fi
done

# ── 3. Check Supabase task queue health ────────────────────────────────────────

export SUPABASE_KEY SUPABASE_URL

TASK_HEALTH=""
if [[ -n "$SUPABASE_KEY" ]]; then
  TASK_HEALTH=$(python3 - <<'PY' 2>/dev/null
import os, json, urllib.request

KEY = os.environ.get('SUPABASE_KEY', '')
URL = os.environ.get('SUPABASE_URL', '')
if not KEY:
    raise SystemExit(0)

for status, label in [('todo', 'Queued'), ('in_progress', 'In progress')]:
    req = urllib.request.Request(
        f"{URL}/rest/v1/tasks?status=eq.{status}&select=id&limit=1",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            rows = json.loads(r.read())
        # Use count header instead — just check if non-empty
        count_req = urllib.request.Request(
            f"{URL}/rest/v1/tasks?status=eq.{status}&select=count",
            headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
                     "Prefer": "count=exact"},
        )
        with urllib.request.urlopen(count_req, timeout=10) as cr:
            content_range = cr.getheader('Content-Range', '0/0')
            total = content_range.split('/')[-1] if '/' in content_range else '?'
        print(f"{label}: {total}")
    except Exception:
        pass
PY
  )
fi

export SUPABASE_KEY SUPABASE_URL

# ── 4. Check pending auto-healer tasks ────────────────────────────────────────

HEALER_TASKS=""
if [[ -n "$SUPABASE_KEY" ]]; then
  HEALER_COUNT=$(python3 - <<'PY' 2>/dev/null
import os, json, urllib.request, urllib.parse

KEY = os.environ.get('SUPABASE_KEY', '')
URL = os.environ.get('SUPABASE_URL', '')
if not KEY:
    raise SystemExit(0)

tag = urllib.parse.quote('auto-healer')
req = urllib.request.Request(
    f"{URL}/rest/v1/tasks?tags=cs.%7B{tag}%7D&status=in.(todo,in_progress)&select=title&limit=5",
    headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"},
)
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        rows = json.loads(r.read())
    for row in rows:
        print(row['title'])
except Exception:
    pass
PY
  )
  if [[ -n "$HEALER_COUNT" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && HEALER_TASKS="${HEALER_TASKS}• ${line}\n"
    done <<< "$HEALER_COUNT"
  fi
fi

# ── 5. Build and send health report ───────────────────────────────────────────

SAST_TIME=$(TZ="Africa/Johannesburg" date +"%H:%M SAST, %a %d %b")
DATE_UTC=$(date -u +"%Y-%m-%d")

if [[ $UNHEALTHY -eq 0 ]]; then
  HEADER="✅ <b>System healthy</b>"
else
  HEADER="⚠️ <b>System report — ${UNHEALTHY} agent(s) need attention</b>"
fi

MSG="${HEADER}
${SAST_TIME}

<b>Agents:</b> ${HEALTHY}/${RUNNING} healthy"

if [[ -n "$KEEPALIVE_LIST" ]]; then
  MSG="${MSG}

<b>Persistent bots:</b>
$(echo -e "$KEEPALIVE_LIST")"
fi

if [[ -n "$UNHEALTHY_LIST" ]]; then
  MSG="${MSG}

<b>Unhealthy agents:</b>
$(echo -e "$UNHEALTHY_LIST")"
fi

if [[ -n "$TASK_HEALTH" ]]; then
  MSG="${MSG}

<b>Task queue:</b>
${TASK_HEALTH}"
fi

if [[ -n "$HEALER_TASKS" ]]; then
  MSG="${MSG}

<b>Auto-healer tasks queued:</b>
$(echo -e "$HEALER_TASKS")"
fi

if [[ -n "$ERROR_SUMMARY" ]]; then
  MSG="${MSG}

<b>Recent log activity (24h):</b>
$(echo -e "$ERROR_SUMMARY")"
fi

# Send it — this itself IS the Telegram verification
if send_telegram "$MSG"; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Health check sent to Telegram"
else
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") ERROR: Failed to send health check — Telegram may be down" >&2
  exit 1
fi
