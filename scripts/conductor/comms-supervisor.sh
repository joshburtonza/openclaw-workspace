#!/usr/bin/env bash
# scripts/conductor/comms-supervisor.sh
# ─────────────────────────────────────────────────────────────────────────────
# COMMS SUPERVISOR
# Manages: telegram-josh, telegram-salah, discord-bot, pending-nudge, telegram-watchdog
# Schedule: Every 5 minutes — Telegram health is critical
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
WS="$(cd "$(dirname "$0")/../.." && pwd)"
source "$WS/.env.scheduler"
source "$WS/scripts/lib/agent-registry.sh"

LOG="$WS/out/comms-supervisor.log"
mkdir -p "$WS/out"
log() { echo "[$(date '+%H:%M:%S')] [comms-sup] $*" | tee -a "$LOG"; }

AGENT_ID="comms-supervisor"
START_MS=$(python3 -c "import time; print(int(time.time()*1000))")

CMD=$(agent_command_check "$AGENT_ID")
if [[ "$CMD" == "pause" ]]; then
    agent_checkout "$AGENT_ID" "idle" "Paused"; exit 0
fi

agent_checkin "$AGENT_ID" "supervisor" "head-agent"

export SUPABASE_URL="${SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
export SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
TG_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TG_CHAT="${TELEGRAM_CHAT_ID:-1140320036}"

DOMAIN_STATE=$(python3 - <<'PY'
import os, json, urllib.request
from datetime import datetime, timezone, timedelta

URL = os.environ['SUPABASE_URL']
KEY = os.environ['SUPABASE_KEY']
now = datetime.now(timezone.utc)

def supa_get(path):
    req = urllib.request.Request(f"{URL}/rest/v1/{path}",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"})
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return json.loads(r.read())
    except Exception:
        return []

workers = supa_get(
    "agent_registry?supervisor_id=eq.comms-supervisor&select=agent_id,status,last_run_at,error_count_today"
)

workers_dict = {}
for w in (workers if isinstance(workers, list) else []):
    wid = w['agent_id']
    last_run = w.get('last_run_at')
    minutes_since = None
    alive = None  # None = never run (seeded but not started yet)
    if last_run:
        try:
            lr = datetime.fromisoformat(last_run.replace('Z','+00:00'))
            minutes_since = round((now - lr).total_seconds() / 60)
            # Watchdog runs every 5 min — alert if >12 min since last checkin
            # Gateway/poller checks in at startup — alive means watchdog is alive
            if wid == 'worker-telegram-watchdog':
                alive = minutes_since < 12
            else:
                alive = True  # non-watchdog workers don't drive the alive flag
        except Exception:
            pass
    workers_dict[wid] = {
        'status': w.get('status','unknown'),
        'last_run_minutes_ago': minutes_since,
        'alive': alive,
        'errors_today': w.get('error_count_today', 0),
    }

# Telegram is alive if the watchdog has checked in recently
# None means the watchdog has never run (newly deployed) — don't alarm yet
watchdog_alive = workers_dict.get('worker-telegram-watchdog', {}).get('alive')
state = {
    "workers": workers_dict,
    "telegram_josh_alive": watchdog_alive is not False,  # True or None → alive
    "telegram_salah_alive": workers_dict.get('worker-telegram-salah', {}).get('alive', True),
    "discord_alive": workers_dict.get('worker-discord-bot', {}).get('alive', True),
    "watchdog_minutes_ago": workers_dict.get('worker-telegram-watchdog', {}).get('last_run_minutes_ago'),
}

print(json.dumps(state, indent=2))
PY
)

# Fast-path: check if Telegram is down without burning a full Claude call
TGJOSH_ALIVE=$(echo "$DOMAIN_STATE" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if d.get('telegram_josh_alive') else 'no')" 2>/dev/null || echo "no")

if [[ "$TGJOSH_ALIVE" == "no" ]]; then
    log "CRITICAL: Telegram watchdog stale — poller may be down"
    # Alert via Telegram watchdog endpoint
    if [[ -n "$TG_TOKEN" ]]; then
        python3 - <<PY2 2>/dev/null || true
import urllib.request, json, os
token = os.environ.get('TG_TOKEN') or '${TG_TOKEN}'
chat  = os.environ.get('TG_CHAT') or '${TG_CHAT}'
body  = json.dumps({"chat_id": int(chat), "text": "📡 ALERT: Telegram watchdog not checked in >12 min — poller may be down. Check: launchctl list | grep telegram"}).encode()
req   = urllib.request.Request(f"https://api.telegram.org/bot{token}/sendMessage",
    data=body, headers={"Content-Type": "application/json"}, method="POST")
try:
    urllib.request.urlopen(req, timeout=10)
except Exception:
    pass
PY2
    fi
fi

# Full Claude evaluation (lighter model — just health checks)
PROMPT_FILE="$WS/prompts/conductor/comms-supervisor.md"
TMPFILE=$(mktemp /tmp/comms-sup-XXXXXX)
cat > "$TMPFILE" <<EOF
$(cat "$PROMPT_FILE")

---

## Current Comms Domain State

\`\`\`json
${DOMAIN_STATE}
\`\`\`

Respond with valid JSON only.
EOF

unset CLAUDECODE
RESPONSE=$(/Users/henryburton/.openclaw/bin/claude-gated --print --model claude-haiku-4-5-20251001 < "$TMPFILE" 2>/dev/null || echo '{"status":"healthy","summary":"Comms supervisor run complete","commands":[],"metrics":{}}')
rm -f "$TMPFILE"

export _RESP="$RESPONSE" _AR_KEY="$SUPABASE_KEY" _AR_URL="$SUPABASE_URL"

python3 - <<'PY' 2>/dev/null || true
import os, json, urllib.request, re
KEY=os.environ['_AR_KEY']; URL=os.environ['_AR_URL']; resp=os.environ['_RESP']
m=re.search(r'\{[\s\S]*\}', resp)
data = {}
if m:
    try: data = json.loads(m.group(0))
    except Exception: pass
print(f"[comms-sup] {data.get('status')} — {data.get('summary','')}")
for cmd in data.get('commands', []):
    to_id=cmd.get('to_agent_id',''); command=cmd.get('command','run_now'); payload=cmd.get('payload',{})
    if not to_id: continue
    body=json.dumps({"from_agent_id":"comms-supervisor","to_agent_id":to_id,"command":command,"payload":payload,"status":"pending"}).encode()
    req=urllib.request.Request(f"{URL}/rest/v1/agent_commands",data=body,
        headers={"apikey":KEY,"Authorization":f"Bearer {KEY}","Content-Type":"application/json","Prefer":"return=minimal"},method="POST")
    try: urllib.request.urlopen(req, timeout=5); print(f"[comms-sup] → {command} → {to_id}")
    except Exception as e: print(f"[comms-sup] cmd failed: {e}")
PY

END_MS=$(python3 -c "import time; print(int(time.time()*1000))")
SUMMARY=$(echo "$RESPONSE" | python3 -c "import sys,json,re; m=re.search(r'\{[\s\S]*\}',sys.stdin.read()); print(json.loads(m.group(0)).get('summary','Done') if m else 'Done')" 2>/dev/null || echo "Done")
agent_checkout "$AGENT_ID" "idle" "$SUMMARY" "$((END_MS - START_MS))"
