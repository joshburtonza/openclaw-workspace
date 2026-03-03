#!/usr/bin/env bash
# scripts/conductor/ops-supervisor.sh
# ─────────────────────────────────────────────────────────────────────────────
# OPERATIONS SUPERVISOR
# Manages: task-implementer, error-monitor, daily-repo-sync, git-backup, agent-status
# Schedule: Every 10 minutes
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
WS="$(cd "$(dirname "$0")/../.." && pwd)"
source "$WS/.env.scheduler"
source "$WS/scripts/lib/agent-registry.sh"

LOG="$WS/out/ops-supervisor.log"
mkdir -p "$WS/out"
log() { echo "[$(date '+%H:%M:%S')] [ops-sup] $*" | tee -a "$LOG"; }

AGENT_ID="ops-supervisor"
START_MS=$(python3 -c "import time; print(int(time.time()*1000))")
log "=== Ops Supervisor run ==="

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
    "agent_registry?supervisor_id=eq.ops-supervisor&select=agent_id,status,last_run_at,last_result,error_count_today,run_count_today"
)

# Task queue
tasks_todo = supa_get(
    "tasks?status=eq.todo&select=id,title,priority,assigned_to,created_at&order=created_at.asc&limit=20"
)
tasks_inprog = supa_get(
    "tasks?status=eq.in_progress&select=id,title,assigned_to,created_at&limit=10"
)
tasks_done_today = supa_get(
    f"tasks?status=eq.done&updated_at=gte.{now.strftime('%Y-%m-%d')}T00:00:00Z&select=id&limit=100"
)

# Check recent error logs — only files modified in the last hour
import glob, os, time as _time
error_count = 0
error_samples = []
one_hour_ago_ts = _time.time() - 3600
for f in glob.glob(f"{os.environ.get('WS','/Users/henryburton/.openclaw/workspace-anthropic')}/out/*.err.log"):
    try:
        mtime = os.path.getmtime(f)
        if mtime < one_hour_ago_ts:
            continue  # File not touched in last hour — skip
        with open(f) as fh:
            lines = fh.readlines()
            recent = [l for l in lines[-20:] if l.strip()]
            if recent:
                error_count += len(recent)
                error_samples.append({'file': os.path.basename(f), 'count': len(recent), 'last': recent[-1].strip()[:100]})
    except Exception:
        pass

workers_dict = {}
for w in (workers if isinstance(workers, list) else []):
    if not isinstance(w, dict):
        continue
    wid = w.get('agent_id')
    if not wid:
        continue
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
        'runs_today': w.get('run_count_today', 0),
        'last_result': str(w.get('last_result') or '')[:80],
    }

state = {
    "workers": workers_dict,
    "tasks": {
        "todo": len(tasks_todo),
        "in_progress": len(tasks_inprog),
        "done_today": len(tasks_done_today) if isinstance(tasks_done_today, list) else 0,
        "claude_todo": sum(1 for t in (tasks_todo or []) if t.get('assigned_to','').lower() == 'claude'),
        "high_priority_todo": sum(1 for t in (tasks_todo or []) if t.get('priority') in ('high','urgent')),
        "samples": [(t.get('priority','?'), t.get('title','?')[:50]) for t in (tasks_todo or [])[:5]],
    },
    "error_logs": {
        "total_recent_errors": error_count,
        "files_with_errors": len(error_samples),
        "samples": error_samples[:3],
    },
    "sast_hour": (now + timedelta(hours=2)).hour,
}

print(json.dumps(state, indent=2))
PY
)

log "Domain state gathered"

PROMPT_FILE="$WS/prompts/conductor/ops-supervisor.md"
TMPFILE=$(mktemp /tmp/ops-sup-XXXXXX)
cat > "$TMPFILE" <<EOF
$(cat "$PROMPT_FILE")

---

## Current Operations Domain State

\`\`\`json
${DOMAIN_STATE}
\`\`\`

Respond with valid JSON only.
EOF

unset CLAUDECODE
RESPONSE=$(/Users/henryburton/.openclaw/bin/claude-gated --print --model claude-sonnet-4-6 < "$TMPFILE" 2>/dev/null || echo '{"status":"healthy","summary":"Ops supervisor run complete","commands":[],"metrics":{}}')
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
print(f"[ops-sup] {data.get('status')} — {data.get('summary','')}")
for cmd in data.get('commands', []):
    to_id=cmd.get('to_agent_id',''); command=cmd.get('command','run_now'); payload=cmd.get('payload',{})
    if not to_id: continue
    body=json.dumps({"from_agent_id":"ops-supervisor","to_agent_id":to_id,"command":command,"payload":payload,"status":"pending"}).encode()
    req=urllib.request.Request(f"{URL}/rest/v1/agent_commands",data=body,
        headers={"apikey":KEY,"Authorization":f"Bearer {KEY}","Content-Type":"application/json","Prefer":"return=minimal"},method="POST")
    try: urllib.request.urlopen(req, timeout=5); print(f"[ops-sup] → {command} → {to_id}")
    except Exception as e: print(f"[ops-sup] cmd failed: {e}")
PY

END_MS=$(python3 -c "import time; print(int(time.time()*1000))")
SUMMARY=$(echo "$RESPONSE" | python3 -c "import sys,json,re; m=re.search(r'\{[\s\S]*\}',sys.stdin.read()); print(json.loads(m.group(0)).get('summary','Done') if m else 'Done')" 2>/dev/null || echo "Done")
agent_checkout "$AGENT_ID" "idle" "$SUMMARY" "$((END_MS - START_MS))"
log "=== Ops Supervisor done — $SUMMARY ==="
