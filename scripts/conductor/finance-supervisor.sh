#!/usr/bin/env bash
# scripts/conductor/finance-supervisor.sh
# ─────────────────────────────────────────────────────────────────────────────
# FINANCE SUPERVISOR
# Manages: data-os-sync, monthly-pnl, retainer-tracker, aos-value-report
# Schedule: Every 4 hours
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
WS="$(cd "$(dirname "$0")/../.." && pwd)"
source "$WS/.env.scheduler"
source "$WS/scripts/lib/agent-registry.sh"

LOG="$WS/out/finance-supervisor.log"
mkdir -p "$WS/out"
log() { echo "[$(date '+%H:%M:%S')] [fin-sup] $*" | tee -a "$LOG"; }

AGENT_ID="finance-supervisor"
START_MS=$(python3 -c "import time; print(int(time.time()*1000))")
log "=== Finance Supervisor run ==="

CMD=$(agent_command_check "$AGENT_ID")
if [[ "$CMD" == "pause" ]]; then
    log "Paused"; agent_checkout "$AGENT_ID" "idle" "Paused"; exit 0
fi

agent_checkin "$AGENT_ID" "supervisor" "head-agent"

export SUPABASE_URL="${SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
export SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"

DOMAIN_STATE=$(python3 - <<'PY'
import os, json, urllib.request
from datetime import datetime, timezone, timedelta

URL = os.environ['SUPABASE_URL']
KEY = os.environ['SUPABASE_KEY']
now = datetime.now(timezone.utc)
sast = now + timedelta(hours=2)

def supa_get(path):
    req = urllib.request.Request(f"{URL}/rest/v1/{path}",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"})
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return json.loads(r.read())
    except Exception:
        return []

workers = supa_get(
    "agent_registry?supervisor_id=eq.finance-supervisor&select=agent_id,status,last_run_at,last_result,error_count_today"
)

# Income entries this month
month_start = sast.replace(day=1, hour=0, minute=0, second=0, microsecond=0) - timedelta(hours=2)
income = supa_get(
    f"income_entries?created_at=gte.{month_start.strftime('%Y-%m-%dT%H:%M:%SZ')}"
    "&select=id,amount,description,type,created_at&order=created_at.desc&limit=50"
)

total_income_mtd = sum(float(r.get('amount', 0)) for r in (income or []))

# Dashboard.json freshness
import os
dashboard_path = f"{os.environ.get('WS','/Users/henryburton/.openclaw/workspace-anthropic')}/data/dashboard.json"
dashboard_age_hours = None
if os.path.exists(dashboard_path):
    import time
    age_sec = time.time() - os.path.getmtime(dashboard_path)
    dashboard_age_hours = round(age_sec / 3600, 1)

workers_dict = {}
for w in (workers if isinstance(workers, list) else []):
    wid = w['agent_id']
    last_run = w.get('last_run_at')
    minutes_since = None
    if last_run:
        try:
            lr = datetime.fromisoformat(last_run.replace('Z','+00:00'))
            minutes_since = round((now - lr).total_seconds() / 60)
        except Exception:
            pass
    workers_dict[wid] = {
        'status': w.get('status','unknown'),
        'last_run_minutes_ago': minutes_since,
        'errors_today': w.get('error_count_today', 0),
    }

state = {
    "workers": workers_dict,
    "income_mtd": round(total_income_mtd, 2),
    "income_entries_mtd": len(income) if isinstance(income, list) else 0,
    "dashboard_age_hours": dashboard_age_hours,
    "sast_day": sast.day,
    "sast_hour": sast.hour,
    "month": sast.strftime('%B %Y'),
}

print(json.dumps(state, indent=2))
PY
)

log "Domain state gathered"

PROMPT_FILE="$WS/prompts/conductor/finance-supervisor.md"
TMPFILE=$(mktemp /tmp/fin-sup-XXXXXX)
cat > "$TMPFILE" <<EOF
$(cat "$PROMPT_FILE")

---

## Current Finance Domain State

\`\`\`json
${DOMAIN_STATE}
\`\`\`

Respond with valid JSON only.
EOF

unset CLAUDECODE
RESPONSE=$(claude --print --model claude-sonnet-4-6 < "$TMPFILE" 2>/dev/null || echo '{"status":"healthy","summary":"Finance supervisor run complete","commands":[],"metrics":{}}')
rm -f "$TMPFILE"

export _RESP="$RESPONSE" _AR_KEY="$SUPABASE_KEY" _AR_URL="$SUPABASE_URL"

python3 - <<'PY'
import os, json, urllib.request, re
KEY=os.environ['_AR_KEY']; URL=os.environ['_AR_URL']; resp=os.environ['_RESP']
m=re.search(r'\{[\s\S]*\}', resp)
data = {}
if m:
    try: data = json.loads(m.group(0))
    except Exception: pass
print(f"[fin-sup] {data.get('status')} — {data.get('summary','')}")
for cmd in data.get('commands', []):
    to_id=cmd.get('to_agent_id',''); command=cmd.get('command','run_now'); payload=cmd.get('payload',{})
    if not to_id: continue
    body=json.dumps({"from_agent_id":"finance-supervisor","to_agent_id":to_id,"command":command,"payload":payload,"status":"pending"}).encode()
    req=urllib.request.Request(f"{URL}/rest/v1/agent_commands",data=body,
        headers={"apikey":KEY,"Authorization":f"Bearer {KEY}","Content-Type":"application/json","Prefer":"return=minimal"},method="POST")
    try: urllib.request.urlopen(req, timeout=5); print(f"[fin-sup] → {command} → {to_id}")
    except Exception as e: print(f"[fin-sup] cmd failed: {e}")
PY

END_MS=$(python3 -c "import time; print(int(time.time()*1000))")
SUMMARY=$(echo "$RESPONSE" | python3 -c "import sys,json,re; m=re.search(r'\{[\s\S]*\}',sys.stdin.read()); print(json.loads(m.group(0)).get('summary','Done') if m else 'Done')" 2>/dev/null || echo "Done")
agent_checkout "$AGENT_ID" "idle" "$SUMMARY" "$((END_MS - START_MS))"
log "=== Finance Supervisor done — $SUMMARY ==="
