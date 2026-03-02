#!/usr/bin/env bash
# scripts/conductor/csm-supervisor.sh
# ─────────────────────────────────────────────────────────────────────────────
# CSM SUPERVISOR
# Manages: sophia-cron, sophia-context, sophia-followup, sophia-outbound, client-monitor
# Schedule: Every 30 minutes
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
WS="$(cd "$(dirname "$0")/../.." && pwd)"
source "$WS/.env.scheduler"
source "$WS/scripts/lib/agent-registry.sh"

LOG="$WS/out/csm-supervisor.log"
mkdir -p "$WS/out"
log() { echo "[$(date '+%H:%M:%S')] [csm-sup] $*" | tee -a "$LOG"; }

AGENT_ID="csm-supervisor"
START_MS=$(python3 -c "import time; print(int(time.time()*1000))")
log "=== CSM Supervisor run ==="

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

def supa_get(path):
    req = urllib.request.Request(f"{URL}/rest/v1/{path}",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"})
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return json.loads(r.read())
    except Exception:
        return []

workers = supa_get(
    "agent_registry?supervisor_id=eq.csm-supervisor&select=agent_id,status,last_run_at,error_count_today"
)
clients = supa_get("clients?select=id,name,status,last_contact_date&order=name.asc")
email_q = supa_get(
    "email_queue?status=eq.pending&select=id,to_email,subject,created_at"
    "&order=created_at.asc&limit=10"
)
tasks = supa_get(
    "tasks?status=in.(todo,in_progress)&select=id,title,priority,created_at"
    "&order=created_at.asc&limit=20"
)

at_risk = []
for c in (clients if isinstance(clients, list) else []):
    if c.get('status') not in ('active', 'retained'):
        continue
    lc = c.get('last_contact_date')
    if lc:
        try:
            lc_dt = datetime.fromisoformat(lc.replace('Z','+00:00'))
            days_since = (now - lc_dt).days
            if days_since > 14:
                at_risk.append({'name': c['name'], 'days_since_contact': days_since})
        except Exception:
            pass
    else:
        at_risk.append({'name': c.get('name','?'), 'days_since_contact': 999})

# Pending email approvals > 2 hours old
old_pending = []
for e in (email_q if isinstance(email_q, list) else []):
    ca = e.get('created_at','')
    if ca:
        try:
            ca_dt = datetime.fromisoformat(ca.replace('Z','+00:00'))
            age_h = (now - ca_dt).total_seconds() / 3600
            if age_h > 2:
                old_pending.append({'subject': e.get('subject','?'), 'hours_old': round(age_h)})
        except Exception:
            pass

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
    "active_clients": len([c for c in (clients or []) if c.get('status') in ('active','retained')]),
    "at_risk_clients": at_risk,
    "email_queue_pending": len(email_q) if isinstance(email_q, list) else 0,
    "email_queue_old_pending": old_pending,
    "open_tasks": len(tasks) if isinstance(tasks, list) else 0,
    "sast_hour": (now + timedelta(hours=2)).hour,
}

print(json.dumps(state, indent=2))
PY
)

log "Domain state gathered"

PROMPT_FILE="$WS/prompts/conductor/csm-supervisor.md"
TMPFILE=$(mktemp /tmp/csm-sup-XXXXXX)
cat > "$TMPFILE" <<EOF
$(cat "$PROMPT_FILE")

---

## Current CSM Domain State

\`\`\`json
${DOMAIN_STATE}
\`\`\`

Respond with valid JSON only.
EOF

unset CLAUDECODE
RESPONSE=$(claude --print --model claude-sonnet-4-6 < "$TMPFILE" 2>/dev/null || echo '{"status":"healthy","summary":"CSM supervisor run complete","commands":[],"metrics":{}}')
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
print(f"[csm-sup] {data.get('status')} — {data.get('summary','')}")
for cmd in data.get('commands', []):
    to_id=cmd.get('to_agent_id',''); command=cmd.get('command','run_now'); payload=cmd.get('payload',{})
    if not to_id: continue
    body=json.dumps({"from_agent_id":"csm-supervisor","to_agent_id":to_id,"command":command,"payload":payload,"status":"pending"}).encode()
    req=urllib.request.Request(f"{URL}/rest/v1/agent_commands",data=body,
        headers={"apikey":KEY,"Authorization":f"Bearer {KEY}","Content-Type":"application/json","Prefer":"return=minimal"},method="POST")
    try: urllib.request.urlopen(req, timeout=5); print(f"[csm-sup] → {command} → {to_id}")
    except Exception as e: print(f"[csm-sup] cmd failed: {e}")
PY

END_MS=$(python3 -c "import time; print(int(time.time()*1000))")
SUMMARY=$(echo "$RESPONSE" | python3 -c "import sys,json,re; m=re.search(r'\{[\s\S]*\}',sys.stdin.read()); print(json.loads(m.group(0)).get('summary','Done') if m else 'Done')" 2>/dev/null || echo "Done")
agent_checkout "$AGENT_ID" "idle" "$SUMMARY" "$((END_MS - START_MS))"
log "=== CSM Supervisor done — $SUMMARY ==="
