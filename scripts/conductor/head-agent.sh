#!/usr/bin/env bash
# scripts/conductor/head-agent.sh
# ─────────────────────────────────────────────────────────────────────────────
# HEAD OF SNAKE — Master Orchestrator
# Runs every 5 minutes. Reads full system state, sends to Claude Opus,
# gets back decisions: commands for supervisors, optional Telegram alert.
#
# Tier:       head
# Model:      claude-opus-4-6
# Schedule:   Every 5 minutes (StartInterval 300)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
WS="$(cd "$(dirname "$0")/../.." && pwd)"
source "$WS/.env.scheduler"
source "$WS/scripts/lib/agent-registry.sh"

LOG="$WS/out/head-agent.log"
mkdir -p "$WS/out"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

AGENT_ID="head-agent"
START_MS=$(python3 -c "import time; print(int(time.time()*1000))")

log "=== Head of Snake run ==="

# ── Check for commands (pause/resume from any upstream signal) ────────────────
CMD=$(agent_command_check "$AGENT_ID")
if [[ "$CMD" == "pause" ]]; then
    log "Paused by command — skipping run"
    agent_checkout "$AGENT_ID" "idle" "Paused by command"
    exit 0
fi

# ── Register as running ───────────────────────────────────────────────────────
agent_checkin "$AGENT_ID" "head" ""

SUPABASE_URL="${SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
TG_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TG_CHAT="${TELEGRAM_CHAT_ID:-1140320036}"
PROMPT_FILE="$WS/prompts/conductor/head-agent.md"

# ── Gather system state ───────────────────────────────────────────────────────
export SUPABASE_URL SUPABASE_KEY

SYSTEM_STATE=$(python3 - <<'PY'
import os, json, urllib.request, urllib.parse
from datetime import datetime, timezone, timedelta

URL = os.environ['SUPABASE_URL']
KEY = os.environ['SUPABASE_KEY']
now = datetime.now(timezone.utc)
now_str = now.strftime('%Y-%m-%dT%H:%M:%SZ')
today = now.strftime('%Y-%m-%d')

def supa_get(path):
    req = urllib.request.Request(
        f"{URL}/rest/v1/{path}",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except Exception as e:
        return {"error": str(e)}

# Agent registry — full snapshot
agents = supa_get("agent_registry?order=domain.asc,tier.asc")

# Summarise agent health by domain
by_domain = {}
total_running = 0
total_error = 0
total_idle = 0
stale_agents = []

for a in (agents if isinstance(agents, list) else []):
    dom = a.get('domain', 'unknown')
    status = a.get('status', 'unknown')
    if dom not in by_domain:
        by_domain[dom] = {'idle': 0, 'running': 0, 'error': 0, 'disabled': 0, 'paused': 0}
    by_domain[dom][status] = by_domain[dom].get(status, 0) + 1

    if status == 'running': total_running += 1
    elif status == 'error': total_error += 1
    elif status == 'idle': total_idle += 1

    # Detect stale agents (should have run in last 2x their interval but haven't)
    last_run = a.get('last_run_at')
    if last_run and status == 'idle' and a.get('tier') == 'worker':
        try:
            lr = datetime.fromisoformat(last_run.replace('Z', '+00:00'))
            age_min = (now - lr).total_seconds() / 60
            if age_min > 60:  # Not run in 60+ minutes
                stale_agents.append({
                    'agent_id': a['agent_id'],
                    'last_run_at': last_run,
                    'minutes_since_run': round(age_min)
                })
        except Exception:
            pass

# Task queue
tasks = supa_get("tasks?status=in.(todo,in_progress)&select=id,status,assigned_to,priority,title&limit=20")
task_summary = {
    'todo_count': 0, 'in_progress_count': 0,
    'claude_todo': 0, 'high_priority': 0,
    'samples': []
}
if isinstance(tasks, list):
    for t in tasks:
        if t.get('status') == 'todo':
            task_summary['todo_count'] += 1
            if t.get('assigned_to', '').lower() == 'claude':
                task_summary['claude_todo'] += 1
        elif t.get('status') == 'in_progress':
            task_summary['in_progress_count'] += 1
        if t.get('priority') in ('high', 'urgent'):
            task_summary['high_priority'] += 1
        task_summary['samples'].append(f"[{t.get('priority','?')}] {t.get('title','?')[:60]}")

# Research sources
research = supa_get("research_sources?status=eq.pending&select=id,type,created_at&limit=5")
research_pending = len(research) if isinstance(research, list) else 0

# Email queue
email_q = supa_get("email_queue?status=eq.pending&select=id,to_email,subject&limit=5")
email_pending = len(email_q) if isinstance(email_q, list) else 0

# Sales metrics (last 7 days)
seven_days_ago = (now - timedelta(days=7)).strftime('%Y-%m-%dT%H:%M:%SZ')
# outreach_log has: id, sent_at, opened_at — no replied_at (replies tracked on leads table)
sent_7d = supa_get(f"outreach_log?sent_at=gte.{seven_days_ago}&select=id,opened_at")
if isinstance(sent_7d, list):
    total_sent = len(sent_7d)
    total_opened = sum(1 for r in sent_7d if r.get('opened_at'))
else:
    total_sent = total_opened = 0
# Replies come from leads.reply_received_at
replied_7d = supa_get(f"leads?reply_received_at=gte.{seven_days_ago}&select=id")
total_replied = len(replied_7d) if isinstance(replied_7d, list) else 0
open_rate = round((total_opened / total_sent * 100), 1) if total_sent > 0 else 0
reply_rate = round((total_replied / total_sent * 100), 1) if total_sent > 0 else 0

# Leads needing contact
leads_ready = supa_get(
    "leads?status=eq.new&email_status=eq.valid&select=id,first_name,company,quality_score"
    "&order=quality_score.desc&limit=10"
)
leads_ready_count = len(leads_ready) if isinstance(leads_ready, list) else 0

# Recent errors (from agent_commands and registry)
erroring_agents = [
    {'agent_id': a['agent_id'], 'last_result': a.get('last_result',''), 'errors': a.get('error_count_today',0)}
    for a in (agents if isinstance(agents, list) else [])
    if a.get('status') == 'error'
]

# Client retainer health (days since last touchpoint)
clients = supa_get("clients?select=id,name,status&order=name.asc")
client_list = clients if isinstance(clients, list) else []

# Current time info
sast = now + timedelta(hours=2)
is_daily_report_time = (sast.hour == 7 and 20 <= sast.minute <= 30)

state = {
    "timestamp_utc": now_str,
    "timestamp_sast": sast.strftime('%Y-%m-%d %H:%M SAST'),
    "is_daily_report_time": is_daily_report_time,
    "agent_health": {
        "total": len(agents) if isinstance(agents, list) else 0,
        "by_status": {"idle": total_idle, "running": total_running, "error": total_error},
        "by_domain": by_domain,
        "erroring_agents": erroring_agents,
        "stale_agents": stale_agents[:10],
    },
    "tasks": task_summary,
    "research_pending": research_pending,
    "email_queue_pending": email_pending,
    "sales_7d": {
        "sent": total_sent,
        "opened": total_opened,
        "replied": total_replied,
        "open_rate_pct": open_rate,
        "reply_rate_pct": reply_rate,
        "leads_ready_to_contact": leads_ready_count,
    },
    "clients": [c.get('name','?') for c in client_list if c.get('status') in ('active', 'retained')],
}

print(json.dumps(state, indent=2))
PY
)

if [[ -z "$SYSTEM_STATE" || "$SYSTEM_STATE" == "null" ]]; then
    log "Failed to gather system state"
    agent_checkout "$AGENT_ID" "error" "Failed to gather system state"
    exit 1
fi

log "System state gathered ($(echo "$SYSTEM_STATE" | wc -c) bytes)"

# ── Send to Claude Opus ───────────────────────────────────────────────────────
HEAD_PROMPT=$(cat "$PROMPT_FILE")

TMPFILE=$(mktemp /tmp/head-agent-XXXXXX)
cat > "$TMPFILE" <<EOF
${HEAD_PROMPT}

---

## Current System State

\`\`\`json
${SYSTEM_STATE}
\`\`\`

Respond with valid JSON only as specified in your prompt.
EOF

unset CLAUDECODE
RESPONSE=$(claude --print --model claude-opus-4-6 < "$TMPFILE" 2>/dev/null || echo "")
rm -f "$TMPFILE"

if [[ -z "$RESPONSE" ]]; then
    log "Claude returned empty response"
    agent_checkout "$AGENT_ID" "error" "Claude returned empty response"
    exit 1
fi

log "Claude response received"

# ── Parse and act on response ─────────────────────────────────────────────────
export _HEAD_RESPONSE="$RESPONSE" _AR_KEY="$SUPABASE_KEY" _AR_URL="$SUPABASE_URL" \
       _TG_TOKEN="$TG_TOKEN" _TG_CHAT="$TG_CHAT" _AR_WS="$WS"

python3 - <<'PY'
import os, json, urllib.request, urllib.parse, re, hashlib, time
from datetime import datetime, timezone

response  = os.environ['_HEAD_RESPONSE']
KEY       = os.environ['_AR_KEY']
URL       = os.environ['_AR_URL']
TG_TOKEN  = os.environ.get('_TG_TOKEN', '')
TG_CHAT   = os.environ.get('_TG_CHAT', '1140320036')
WS        = os.environ.get('_AR_WS', '')

COOLDOWN_FILE = os.path.join(WS, 'tmp', 'head-agent-cooldown.json') if WS else ''
COOLDOWN_HOURS = 4  # suppress repeat alerts for this many hours

def load_cooldowns():
    if not COOLDOWN_FILE:
        return {}
    try:
        with open(COOLDOWN_FILE) as f:
            return json.load(f)
    except Exception:
        return {}

def save_cooldowns(data):
    if not COOLDOWN_FILE:
        return
    os.makedirs(os.path.dirname(COOLDOWN_FILE), exist_ok=True)
    with open(COOLDOWN_FILE, 'w') as f:
        json.dump(data, f)

def alert_key(text):
    # Use first 60 chars (normalised) as the dedup key
    return hashlib.md5(text[:60].lower().strip().encode()).hexdigest()[:12]

def should_suppress(key, cooldowns):
    if key not in cooldowns:
        return False
    last_sent = cooldowns[key]
    elapsed_h = (time.time() - last_sent) / 3600
    return elapsed_h < COOLDOWN_HOURS

# Extract JSON from response (strip any markdown fences)
json_match = re.search(r'\{[\s\S]*\}', response)
if not json_match:
    print(f"[head] Could not parse JSON from response: {response[:200]}")
    raise SystemExit(1)

try:
    data = json.loads(json_match.group(0))
except Exception as e:
    print(f"[head] JSON parse error: {e}")
    raise SystemExit(1)

health = data.get('health_summary', 'No summary')
urgent = data.get('urgent', False)
commands = data.get('commands', [])
notable = data.get('notable', [])
tg_alert = data.get('telegram_alert')
daily_report = data.get('daily_report')

print(f"[head] Health: {health}")
print(f"[head] Urgent: {urgent} | Commands: {len(commands)} | Notable: {len(notable)}")

# Issue commands to supervisors/workers
for cmd in commands:
    to_id   = cmd.get('to_agent_id', '')
    command = cmd.get('command', 'run_now')
    payload = cmd.get('payload', {})
    if not to_id:
        continue
    body = json.dumps({
        "from_agent_id": "head-agent",
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
        print(f"[head] → Command issued: {command} → {to_id}")
    except Exception as e:
        print(f"[head] Command failed ({to_id}): {e}")

# Send Telegram alert if urgent — with 4-hour cooldown to prevent spam
if urgent and tg_alert and TG_TOKEN:
    cooldowns = load_cooldowns()
    akey = alert_key(tg_alert)
    if should_suppress(akey, cooldowns):
        elapsed_h = (time.time() - cooldowns[akey]) / 3600
        print(f"[head] Alert suppressed (cooldown {elapsed_h:.1f}h / {COOLDOWN_HOURS}h): {tg_alert[:60]}")
        notable.append(f"[suppressed alert] {tg_alert[:80]}")
    else:
        tg_body = json.dumps({"chat_id": int(TG_CHAT), "text": tg_alert}).encode()
        tg_req = urllib.request.Request(
            f"https://api.telegram.org/bot{TG_TOKEN}/sendMessage",
            data=tg_body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            urllib.request.urlopen(tg_req, timeout=10)
            print(f"[head] Telegram alert sent: {tg_alert[:80]}")
            cooldowns[akey] = time.time()
            save_cooldowns(cooldowns)
        except Exception as e:
            print(f"[head] Telegram send failed: {e}")

# Also send daily report to both Josh and Salah if present
if daily_report and TG_TOKEN:
    for chat_id in [1140320036, 8597169435]:
        tg_body = json.dumps({"chat_id": chat_id, "text": daily_report}).encode()
        tg_req = urllib.request.Request(
            f"https://api.telegram.org/bot{TG_TOKEN}/sendMessage",
            data=tg_body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            urllib.request.urlopen(tg_req, timeout=10)
            print(f"[head] Daily report sent to {chat_id}")
        except Exception as e:
            print(f"[head] Daily report failed ({chat_id}): {e}")

# Log notable items
for note in notable:
    print(f"[head] Notable: {note}")

print(f"[head] Run complete.")
PY

# ── Duration + checkout ───────────────────────────────────────────────────────
END_MS=$(python3 -c "import time; print(int(time.time()*1000))")
DURATION=$((END_MS - START_MS))

RESULT=$(echo "$RESPONSE" | python3 -c "
import sys, json, re
r = sys.stdin.read()
m = re.search(r'\{[\s\S]*\}', r)
if m:
    try:
        d = json.loads(m.group(0))
        print(d.get('health_summary', 'Run complete'))
    except Exception:
        print('Run complete')
else:
    print('Run complete')
" 2>/dev/null || echo "Run complete")

agent_checkout "$AGENT_ID" "idle" "$RESULT" "$DURATION"
log "=== Head of Snake done (${DURATION}ms) — $RESULT ==="
