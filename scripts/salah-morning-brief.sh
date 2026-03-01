#!/usr/bin/env bash
# salah-morning-brief.sh — daily morning brief for Salah, sent via Telegram
# Runs at Salah's preferred time (configured in plist)
set -euo pipefail

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WORKSPACE/.env.scheduler"
source "$ENV_FILE"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
unset CLAUDECODE

BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
CHAT_ID="${TELEGRAM_SALAH_CHAT_ID:-8597169435}"
KEY="${SUPABASE_SERVICE_ROLE_KEY}"
SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"

LOG="$WORKSPACE/out/salah-morning-brief.log"
mkdir -p "$WORKSPACE/out"

log() { echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") $*" | tee -a "$LOG"; }
tg_send() {
  local text="$1"
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' <<< "$text"),\"parse_mode\":\"HTML\"}" \
    > /dev/null 2>&1 || true
}

log "Salah morning brief starting"

# ── Live business data ────────────────────────────────────────────────────────
export KEY SUPABASE_URL

BRIEF=$(python3 << 'PYEOF'
import json, urllib.request, os, datetime

KEY = os.environ['KEY']
SUPABASE_URL = os.environ['SUPABASE_URL']
headers = {'apikey': KEY, 'Authorization': 'Bearer ' + KEY}

today = datetime.date.today()
dow   = today.strftime('%A')

def get(path):
    try:
        req = urllib.request.Request(SUPABASE_URL + '/rest/v1/' + path, headers=headers)
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except Exception:
        return []

# Pipeline stats
leads = get('leads?select=status,email_status,ai_score&limit=1000')
total      = len(leads)
contacted  = sum(1 for l in leads if l.get('status') in ('contacted','step_2','step_3','replied'))
replied    = sum(1 for l in leads if l.get('status') == 'replied')
won        = sum(1 for l in leads if l.get('status') == 'won')
reply_rate = round(replied / contacted * 100, 1) if contacted > 0 else 0

# Top scored leads
top_leads = sorted([l for l in leads if l.get('ai_score')], key=lambda x: x.get('ai_score',0), reverse=True)[:3]

# Pending tasks for the business (Salah-visible)
tasks = get("tasks?status=in.(todo,in_progress)&order=created_at.desc&limit=20")
open_tasks = len(tasks)

# Active clients
clients = get("clients?status=eq.active&select=name,status")
active_clients = len(clients)

# Email queue
emails = get("email_queue?status=in.(awaiting_approval,auto_pending)&select=id")
pending_emails = len(emails)

# Build brief text
lines = [
    f"<b>Good morning, Salah</b> — {dow}, {today.strftime('%d %b %Y')}\n",
    "<b>Business Snapshot</b>",
    f"  Active clients: {active_clients}",
    f"  Open tasks: {open_tasks}",
    f"  Emails awaiting approval: {pending_emails}",
    "",
    "<b>Lead Pipeline</b>",
    f"  Total leads: {total}",
    f"  Contacted: {contacted}  |  Replied: {replied}  |  Won: {won}",
    f"  Reply rate: {reply_rate}%",
]

if top_leads:
    lines.append("")
    lines.append("<b>Top Scored Leads</b>")
    for l in top_leads:
        score = l.get('ai_score','?')
        lines.append(f"  Score {score}/100")

if pending_emails > 0:
    lines.append("")
    lines.append(f"<i>{pending_emails} email(s) waiting for Josh to approve</i>")

lines.append("")
lines.append("Reply anytime — I'm your assistant too. /remind, calendar, research, or just ask.")

print('\n'.join(lines))
PYEOF
)

log "Brief generated, sending to Salah"
tg_send "$BRIEF"
log "Salah morning brief sent"
