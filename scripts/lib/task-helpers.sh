#!/usr/bin/env bash
# scripts/lib/task-helpers.sh
# Shared helpers for creating/updating/completing tasks in Supabase.
# Source this file from any agent script:
#   source "$WS/scripts/lib/task-helpers.sh"
#
# Usage:
#   TASK_ID=$(task_create "Title" "Description" "AgentName" "high")
#   task_update "$TASK_ID" "Updated description..."
#   task_complete "$TASK_ID"
#   task_fail "$TASK_ID" "Error message"

_TASK_SUPABASE_URL="${SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
_TASK_KEY="${SUPABASE_SERVICE_ROLE_KEY:-${SUPABASE_KEY:-}}"

# Create a task — returns the UUID on stdout.
# Deduplicates: if an in_progress task with the same title+agent already exists, returns its ID.
task_create() {
    local title="${1:-Unnamed task}"
    local description="${2:-}"
    local agent="${3:-System}"
    local priority="${4:-normal}"

    [[ -z "$_TASK_KEY" ]] && return 0

    export _TH_KEY="${_TASK_KEY}" _TH_URL="${_TASK_SUPABASE_URL}" \
           _TH_TITLE="${title}" _TH_DESC="${description}" \
           _TH_AGENT="${agent}" _TH_PRI="${priority}"

    python3 - <<'PYEOF' 2>/dev/null
import urllib.request, json, os, urllib.parse

KEY   = os.environ['_TH_KEY']
URL   = os.environ['_TH_URL']
title = os.environ['_TH_TITLE']
desc  = os.environ['_TH_DESC']
agent = os.environ['_TH_AGENT']
pri   = os.environ['_TH_PRI']

# Check for existing in_progress task with same title+agent (dedup)
check = urllib.request.Request(
    f"{URL}/rest/v1/tasks?title=eq.{urllib.parse.quote(title)}&assigned_to=eq.{urllib.parse.quote(agent)}&status=eq.in_progress&select=id&limit=1",
    headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"},
)
try:
    with urllib.request.urlopen(check, timeout=10) as r:
        existing = json.loads(r.read())
    if existing:
        print(existing[0]['id'])
        raise SystemExit(0)
except SystemExit:
    raise
except Exception:
    pass

# No duplicate — create new
data = json.dumps({
    'title':       title,
    'description': desc,
    'assigned_to': agent,
    'created_by':  agent,
    'priority':    pri,
    'status':      'in_progress',
    'tags':        ['agent-run'],
}).encode()
req = urllib.request.Request(
    f"{URL}/rest/v1/tasks",
    data=data,
    headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
             "Content-Type": "application/json", "Prefer": "return=representation"},
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        rows = json.loads(r.read())
        print(rows[0]['id'])
except Exception:
    print("")
PYEOF
}

# Update a task's description (progress note)
task_update() {
    local task_id="${1:-}"
    local description="${2:-}"

    [[ -z "$_TASK_KEY" || -z "$task_id" ]] && return 0

    export _TH_KEY="${_TASK_KEY}" _TH_URL="${_TASK_SUPABASE_URL}" _TH_TID="${task_id}" _TH_DESC="${description}"
    python3 - <<PYEOF 2>/dev/null
import urllib.request, json, os

KEY  = os.environ['_TH_KEY']
URL  = os.environ['_TH_URL']
tid  = os.environ['_TH_TID']
desc = os.environ.get('_TH_DESC', '')

data = json.dumps({"description": desc}).encode()
req = urllib.request.Request(
    f"{URL}/rest/v1/tasks?id=eq.{tid}",
    data=data,
    headers={
        "apikey": KEY, "Authorization": f"Bearer {KEY}",
        "Content-Type": "application/json", "Prefer": "return=minimal",
    },
    method="PATCH",
)
try:
    urllib.request.urlopen(req, timeout=10)
except Exception:
    pass
PYEOF
}

# Mark a task complete
task_complete() {
    local task_id="${1:-}"
    local note="${2:-}"

    [[ -z "$_TASK_KEY" || -z "$task_id" ]] && return 0

    export _TH_KEY="${_TASK_KEY}" _TH_URL="${_TASK_SUPABASE_URL}" _TH_TID="${task_id}" _TH_NOTE="${note}"
    python3 - <<PYEOF 2>/dev/null
import urllib.request, json, datetime, os

KEY  = os.environ['_TH_KEY']
URL  = os.environ['_TH_URL']
tid  = os.environ['_TH_TID']
note = os.environ.get('_TH_NOTE', '')

body = {
    "status":       "done",
    "completed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
if note:
    body["description"] = note

data = json.dumps(body).encode()
req = urllib.request.Request(
    f"{URL}/rest/v1/tasks?id=eq.{tid}",
    data=data,
    headers={
        "apikey": KEY, "Authorization": f"Bearer {KEY}",
        "Content-Type": "application/json", "Prefer": "return=minimal",
    },
    method="PATCH",
)
try:
    urllib.request.urlopen(req, timeout=10)
except Exception:
    pass
PYEOF
}

# Mark a task failed
task_fail() {
    local task_id="${1:-}"
    local error="${2:-Unknown error}"

    [[ -z "$_TASK_KEY" || -z "$task_id" ]] && return 0

    export _TH_KEY="${_TASK_KEY}" _TH_URL="${_TASK_SUPABASE_URL}" _TH_TID="${task_id}" _TH_ERROR="${error}"
    python3 - <<PYEOF 2>/dev/null
import urllib.request, json, os

KEY   = os.environ['_TH_KEY']
URL   = os.environ['_TH_URL']
tid   = os.environ['_TH_TID']
error = os.environ.get('_TH_ERROR', 'Unknown error')

data = json.dumps({"status": "done", "description": f"FAILED: {error}"}).encode()
req = urllib.request.Request(
    f"{URL}/rest/v1/tasks?id=eq.{tid}",
    data=data,
    headers={
        "apikey": KEY, "Authorization": f"Bearer {KEY}",
        "Content-Type": "application/json", "Prefer": "return=minimal",
    },
    method="PATCH",
)
try:
    urllib.request.urlopen(req, timeout=10)
except Exception:
    pass
PYEOF
}
