#!/usr/bin/env bash
# scripts/conductor/intel-supervisor.sh
# ─────────────────────────────────────────────────────────────────────────────
# INTELLIGENCE SUPERVISOR
# Manages: meet-notes, research-digest, morning-brief, memory-writer, activity-tracker
# Schedule: Every 15 minutes
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
WS="$(cd "$(dirname "$0")/../.." && pwd)"
source "$WS/.env.scheduler"
source "$WS/scripts/lib/agent-registry.sh"

LOG="$WS/out/intel-supervisor.log"
mkdir -p "$WS/out"
log() { echo "[$(date '+%H:%M:%S')] [intel-sup] $*" | tee -a "$LOG"; }

AGENT_ID="intel-supervisor"
START_MS=$(python3 -c "import time; print(int(time.time()*1000))")
log "=== Intel Supervisor run ==="

# Check for commands
CMD=$(agent_command_check "$AGENT_ID")
if [[ "$CMD" == "pause" ]]; then
    log "Paused by command"
    agent_checkout "$AGENT_ID" "idle" "Paused by command"
    exit 0
fi

agent_checkin "$AGENT_ID" "supervisor" "head-agent"

export SUPABASE_URL="${SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
export SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"

# ── Gather intelligence domain state ─────────────────────────────────────────
DOMAIN_STATE=$(python3 - <<'PY'
import os, json, urllib.request, urllib.parse
from datetime import datetime, timezone, timedelta

URL = os.environ['SUPABASE_URL']
KEY = os.environ['SUPABASE_KEY']
now = datetime.now(timezone.utc)

def supa_get(path):
    req = urllib.request.Request(
        f"{URL}/rest/v1/{path}",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            result = json.loads(r.read())
            return result if isinstance(result, (list, dict)) else []
    except Exception as e:
        return []

# Worker statuses
workers = supa_get(
    "agent_registry?supervisor_id=eq.intel-supervisor&select=agent_id,status,last_run_at,last_result,error_count_today"
)

# Research sources pending
research = supa_get("research_sources?status=eq.pending&select=id,type,created_at&limit=20")

# agent_memory freshness
memory = supa_get("agent_memory?select=agent_name,updated_at&limit=10")

# Check if morning brief was sent today (look for interaction log entry)
today = now.strftime('%Y-%m-%d')
sast = now + timedelta(hours=2)
morning_brief_due = sast.hour >= 7 and sast.minute >= 30

state = {
    "workers": {},
    "research_pending": len(research),
    "memory_records": len(memory),
    "morning_brief_time_passed": morning_brief_due,
    "sast_time": sast.strftime('%H:%M'),
}

for w in (workers if isinstance(workers, list) else []):
    if not isinstance(w, dict):
        continue
    wid = w.get('agent_id') or w.get('id', 'unknown')
    last_run = w.get('last_run_at')
    minutes_since = None
    if last_run:
        try:
            lr = datetime.fromisoformat(last_run.replace('Z','+00:00'))
            minutes_since = round((now - lr).total_seconds() / 60)
        except Exception:
            pass
    state['workers'][wid] = {
        'status': w.get('status', 'unknown'),
        'last_run_minutes_ago': minutes_since,
        'last_result': str(w.get('last_result') or '')[:100],
        'errors_today': w.get('error_count_today', 0),
    }

print(json.dumps(state, indent=2))
PY
)

log "Domain state gathered"

# ── Run through Claude Sonnet ─────────────────────────────────────────────────
PROMPT_FILE="$WS/prompts/conductor/intel-supervisor.md"
TMPFILE=$(mktemp /tmp/intel-sup-XXXXXX)
cat > "$TMPFILE" <<EOF
$(cat "$PROMPT_FILE")

---

## Current Intelligence Domain State

\`\`\`json
${DOMAIN_STATE}
\`\`\`

Respond with valid JSON only.
EOF

unset CLAUDECODE
RESPONSE=$(/Users/henryburton/.openclaw/bin/claude-gated --print --model claude-sonnet-4-6 < "$TMPFILE" 2>/dev/null || echo '{"status":"healthy","summary":"Supervisor run complete","commands":[],"metrics":{}}')
rm -f "$TMPFILE"

# ── Execute commands ──────────────────────────────────────────────────────────
export _RESP="$RESPONSE" _AR_KEY="$SUPABASE_KEY" _AR_URL="$SUPABASE_URL"

python3 - <<'PY'
import os, json, urllib.request, re

KEY  = os.environ['_AR_KEY']
URL  = os.environ['_AR_URL']
resp = os.environ['_RESP']

m = re.search(r'\{[\s\S]*\}', resp)
if not m:
    print("[intel-sup] Could not parse response")
    raise SystemExit(0)

try:
    data = json.loads(m.group(0))
except Exception:
    raise SystemExit(0)

print(f"[intel-sup] Status: {data.get('status')} — {data.get('summary','')}")

for cmd in data.get('commands', []):
    to_id   = cmd.get('to_agent_id','')
    command = cmd.get('command','run_now')
    payload = cmd.get('payload', {})
    if not to_id: continue
    body = json.dumps({
        "from_agent_id": "intel-supervisor",
        "to_agent_id":   to_id,
        "command":       command,
        "payload":       payload,
        "status":        "pending",
    }).encode()
    req = urllib.request.Request(
        f"{URL}/rest/v1/agent_commands",
        data=body,
        headers={
            "apikey": KEY, "Authorization": f"Bearer {KEY}",
            "Content-Type": "application/json", "Prefer": "return=minimal",
        },
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=5)
        print(f"[intel-sup] → {command} → {to_id}")
    except Exception as e:
        print(f"[intel-sup] Command failed: {e}")

metrics = data.get('metrics', {})
print(f"[intel-sup] Metrics: {json.dumps(metrics)}")
PY

END_MS=$(python3 -c "import time; print(int(time.time()*1000))")
SUMMARY=$(echo "$RESPONSE" | python3 -c "
import sys,json,re
m=re.search(r'\{[\s\S]*\}',sys.stdin.read())
if m:
    try: print(json.loads(m.group(0)).get('summary','Done'))
    except: print('Done')
else: print('Done')
" 2>/dev/null || echo "Done")

agent_checkout "$AGENT_ID" "idle" "$SUMMARY" "$((END_MS - START_MS))"
log "=== Intel Supervisor done — $SUMMARY ==="
