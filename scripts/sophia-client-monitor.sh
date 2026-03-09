#!/usr/bin/env bash
# sophia-client-monitor.sh
# Runs every 3 hours. Checks client_activity table in AOS Supabase.
# When clients have been active, Sophia sends a warm proactive nudge to their WA group.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
OPENAI_KEY="${OPENAI_API_KEY:-}"
WA_API="http://127.0.0.1:3001"
CLIENT_GROUPS="$WS/memory/client-groups.json"
QUEUE_FILE="$WS/tmp/proactive-queue.json"
LOG="$WS/out/sophia-client-monitor.log"
STATE_FILE="$WS/tmp/client-monitor-state.json"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
mkdir -p "$WS/out" "$WS/tmp"

log "Client activity monitor starting"

if [[ -z "$SUPABASE_KEY" ]]; then
  log "No SUPABASE_KEY — exiting"
  exit 0
fi

# Check for activity in the last 3 hours per client
SINCE=$(date -u -v-3H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u --date='3 hours ago' '+%Y-%m-%dT%H:%M:%SZ')

export _SUPABASE_URL="$SUPABASE_URL"
export _SUPABASE_KEY="$SUPABASE_KEY"
export _OPENAI_KEY="$OPENAI_KEY"
export _WA_API="$WA_API"
export _CLIENT_GROUPS="$CLIENT_GROUPS"
export _QUEUE_FILE="$QUEUE_FILE"
export _STATE_FILE="$STATE_FILE"
export _SINCE="$SINCE"

python3 - <<'PYMONITOR'
import json, os, sys, datetime, urllib.request, urllib.parse

supabase_url = os.environ['_SUPABASE_URL']
supabase_key = os.environ['_SUPABASE_KEY']
openai_key   = os.environ.get('_OPENAI_KEY', '')
wa_api       = os.environ['_WA_API']
groups_file  = os.environ['_CLIENT_GROUPS']
queue_file   = os.environ['_QUEUE_FILE']
state_file   = os.environ['_STATE_FILE']
since        = os.environ['_SINCE']

# Load client group JIDs
try:
    groups = json.loads(open(groups_file).read())
except:
    groups = {}

# Load state (tracks last alert per client to avoid spam)
try:
    state = json.loads(open(state_file).read())
except:
    state = {}

def supabase_get(path):
    url = f"{supabase_url}/rest/v1/{path}"
    req = urllib.request.Request(url, headers={
        'apikey': supabase_key,
        'Authorization': f'Bearer {supabase_key}',
    })
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except Exception as e:
        print(f"Supabase error ({path}): {e}")
        return []

def call_gpt(system, user):
    if not openai_key:
        return None
    payload = json.dumps({
        'model': 'gpt-4o',
        'messages': [
            {'role': 'system', 'content': system},
            {'role': 'user',   'content': user},
        ],
        'max_tokens': 180,
        'temperature': 0.7,
    }).encode()
    req = urllib.request.Request(
        'https://api.openai.com/v1/chat/completions',
        data=payload,
        headers={'Authorization': f'Bearer {openai_key}', 'Content-Type': 'application/json'},
        method='POST')
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read())['choices'][0]['message']['content'].strip()
    except Exception as e:
        print(f"GPT error: {e}")
        return None

# Client friendly names for messages
CLIENT_NAMES = {
    'ascend-lc':          'Ascend LC',
    'race-technik':       'Race Technik',
    'vanta-studios':      'Vanta Studios',
    'favorite-logistics': 'Favlog',
    'ambassadex':         'Ambassadex',
}

# Fetch activity per client since the lookback window
since_encoded = urllib.parse.quote(since)
activity = supabase_get(
    f"client_activity?created_at=gte.{since_encoded}&order=client_slug.asc,created_at.desc&select=client_slug,event_type,user_name,metadata,created_at"
)

if not isinstance(activity, list):
    print("No activity data")
    sys.exit(0)

# Group by client
from collections import defaultdict
by_client = defaultdict(list)
for row in activity:
    by_client[row['client_slug']].append(row)

now = datetime.datetime.utcnow()
queue = []
try:
    queue = json.loads(open(queue_file).read())
except:
    queue = []

new_state = dict(state)
nudges_sent = 0

for slug, events in by_client.items():
    group_jid = groups.get(slug)
    if not group_jid:
        print(f"  {slug}: no group JID yet — skipping")
        continue

    # Rate limit: only one nudge per client per 4 hours
    last_alert = state.get(slug, {}).get('last_alert')
    if last_alert:
        last_dt = datetime.datetime.fromisoformat(last_alert.replace('Z', '+00:00')).replace(tzinfo=None)
        if (now - last_dt).total_seconds() < 4 * 3600:
            print(f"  {slug}: alerted recently — skipping")
            continue

    client_name = CLIENT_NAMES.get(slug, slug)
    n = len(events)
    event_types = list({e['event_type'] for e in events})
    users = list({e['user_name'] for e in events if e.get('user_name')})

    # Build a summary for GPT
    event_summary = f"{n} event(s): {', '.join(event_types)}"
    user_summary = f"Users active: {', '.join(users)}" if users else "Users active: unknown"
    sample = events[0]
    meta = sample.get('metadata') or {}

    nudge = call_gpt(
        'You are Sophia, Amalfi AI client success manager. Write a short, warm, proactive WhatsApp group message to a client. '
        'Max 3 sentences. No hyphens. No markdown. Sound genuinely engaged, not automated. '
        'Acknowledge their activity naturally. Offer help or ask if everything is going smoothly.',
        f"Client: {client_name}\n"
        f"Activity in the last 3 hours: {event_summary}\n"
        f"{user_summary}\n"
        f"Example event details: {json.dumps(meta)}\n\n"
        "Write the proactive group message. Don't mention 'activity logs' or 'monitoring' — just reference what they're doing naturally."
    )

    if nudge:
        queue.append({'to': group_jid, 'message': nudge, 'sendAt': None})
        new_state[slug] = {'last_alert': now.strftime('%Y-%m-%dT%H:%M:%SZ'), 'event_count': n}
        nudges_sent += 1
        print(f"  {slug}: nudge queued for {group_jid} ({n} events)")
    else:
        print(f"  {slug}: GPT returned nothing")

if nudges_sent:
    with open(queue_file, 'w') as f:
        json.dump(queue, f, indent=2)
    with open(state_file, 'w') as f:
        json.dump(new_state, f, indent=2)

print(f"Done: {nudges_sent} nudge(s) queued across {len(by_client)} active client(s)")
PYMONITOR

log "Client monitor complete"
