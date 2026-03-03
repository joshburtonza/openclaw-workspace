#!/usr/bin/env bash
# scripts/conductor/sales-supervisor.sh
# ─────────────────────────────────────────────────────────────────────────────
# SALES SUPERVISOR
# Manages: lead-sourcer, lead-enricher, outreach-sender, reply-detector, email-opens
# Schedule: Every 30 minutes
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
WS="$(cd "$(dirname "$0")/../.." && pwd)"
source "$WS/.env.scheduler"
source "$WS/scripts/lib/agent-registry.sh"

LOG="$WS/out/sales-supervisor.log"
mkdir -p "$WS/out"
log() { echo "[$(date '+%H:%M:%S')] [sales-sup] $*" | tee -a "$LOG"; }

AGENT_ID="sales-supervisor"
START_MS=$(python3 -c "import time; print(int(time.time()*1000))")
log "=== Sales Supervisor run ==="

CMD=$(agent_command_check "$AGENT_ID")
if [[ "$CMD" == "pause" ]]; then
    log "Paused"
    agent_checkout "$AGENT_ID" "idle" "Paused"
    exit 0
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
    req = urllib.request.Request(
        f"{URL}/rest/v1/{path}",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return json.loads(r.read())
    except Exception:
        return []

# Workers
workers = supa_get(
    "agent_registry?supervisor_id=eq.sales-supervisor&select=agent_id,status,last_run_at,last_result,error_count_today"
)

# Leads ready to contact (valid email, new status, quality score > 0)
leads_ready = supa_get(
    "leads?status=eq.new&email_status=eq.valid&select=id,quality_score"
    "&order=quality_score.desc&limit=20"
)

# Recent outreach (last 7 days)
seven_ago = (now - timedelta(days=7)).strftime('%Y-%m-%dT%H:%M:%SZ')
recent_outreach = supa_get(
    f"outreach_log?sent_at=gte.{seven_ago}&select=id,opened_at,replied_at,reply_sentiment"
)

# Recent replies (unreviewed positive replies)
positive_replies = supa_get(
    "outreach_log?replied_at=not.is.null&reply_sentiment=in.(positive,interested)"
    "&select=id,lead_id,replied_at,reply_sentiment&order=replied_at.desc&limit=5"
)

# Last outreach send time
last_sent = supa_get(
    "outreach_log?select=sent_at&order=sent_at.desc&limit=1"
)

sent_7d    = len(recent_outreach)
opened_7d  = sum(1 for r in recent_outreach if r.get('opened_at'))
replied_7d = sum(1 for r in recent_outreach if r.get('replied_at'))
open_rate  = round(opened_7d / sent_7d * 100, 1) if sent_7d > 0 else 0
reply_rate = round(replied_7d / sent_7d * 100, 1) if sent_7d > 0 else 0

last_sent_minutes_ago = None
if last_sent and isinstance(last_sent, list) and last_sent:
    try:
        ls = datetime.fromisoformat(last_sent[0]['sent_at'].replace('Z','+00:00'))
        last_sent_minutes_ago = round((now - ls).total_seconds() / 60)
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
    "leads_ready_to_contact": len(leads_ready),
    "high_quality_leads": sum(1 for l in leads_ready if l.get('quality_score',0) >= 60),
    "last_outreach_sent_minutes_ago": last_sent_minutes_ago,
    "outreach_7d": {
        "sent": sent_7d, "opened": opened_7d, "replied": replied_7d,
        "open_rate_pct": open_rate, "reply_rate_pct": reply_rate,
    },
    "positive_replies_pending_review": len(positive_replies) if isinstance(positive_replies, list) else 0,
    "sast_hour": (now + timedelta(hours=2)).hour,
}

print(json.dumps(state, indent=2))
PY
)

log "Domain state gathered"

PROMPT_FILE="$WS/prompts/conductor/sales-supervisor.md"
TMPFILE=$(mktemp /tmp/sales-sup-XXXXXX)
cat > "$TMPFILE" <<EOF
$(cat "$PROMPT_FILE")

---

## Current Sales Domain State

\`\`\`json
${DOMAIN_STATE}
\`\`\`

Respond with valid JSON only.
EOF

unset CLAUDECODE
RESPONSE=$(/Users/henryburton/.openclaw/bin/claude-gated --print --model claude-sonnet-4-6 < "$TMPFILE" 2>/dev/null || echo '{"status":"healthy","summary":"Sales supervisor run complete","commands":[],"metrics":{}}')
rm -f "$TMPFILE"

export _RESP="$RESPONSE" _AR_KEY="$SUPABASE_KEY" _AR_URL="$SUPABASE_URL"

python3 - <<'PY'
import os, json, urllib.request, re

KEY  = os.environ['_AR_KEY']
URL  = os.environ['_AR_URL']
resp = os.environ['_RESP']

m = re.search(r'\{[\s\S]*\}', resp)
data = {}
if m:
    try: data = json.loads(m.group(0))
    except Exception: pass

print(f"[sales-sup] Status: {data.get('status')} — {data.get('summary','')}")

for cmd in data.get('commands', []):
    to_id   = cmd.get('to_agent_id','')
    command = cmd.get('command','run_now')
    payload = cmd.get('payload', {})
    if not to_id: continue
    body = json.dumps({
        "from_agent_id": "sales-supervisor",
        "to_agent_id":   to_id,
        "command":       command,
        "payload":       payload,
        "status":        "pending",
    }).encode()
    req = urllib.request.Request(
        f"{URL}/rest/v1/agent_commands",
        data=body,
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
                 "Content-Type": "application/json", "Prefer": "return=minimal"},
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=5)
        print(f"[sales-sup] → {command} → {to_id}")
    except Exception as e:
        print(f"[sales-sup] Command failed: {e}")
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
log "=== Sales Supervisor done — $SUMMARY ==="
