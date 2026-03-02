#!/usr/bin/env bash
# scripts/lib/agent-registry.sh
# Shared helpers for the multi-tier agent orchestration system.
# Every agent should source this file and call agent_checkin/agent_checkout.
#
# Usage:
#   source "$WS/scripts/lib/agent-registry.sh"
#
#   agent_checkin "worker-email-opens" "worker" "sales-supervisor"
#   ... do work ...
#   agent_checkout "worker-email-opens" "idle" "Polled 3 emails, 1 newly opened"
#   agent_checkout "worker-email-opens" "error" "Supabase timeout"
#
#   # Check for commands from supervisor:
#   CMD=$(agent_command_check "worker-email-opens")
#   if [[ "$CMD" == "pause" ]]; then exit 0; fi
#
#   # Write a metric snapshot:
#   agent_metric "worker-email-opens" '{"opens_recorded": 3, "polled": 12}'

_AR_URL="${SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
_AR_KEY="${SUPABASE_SERVICE_ROLE_KEY:-${SUPABASE_KEY:-}}"

# ──────────────────────────────────────────────────────────────────────────────
# agent_checkin <agent_id> [tier] [supervisor_id]
# Sets status=running, increments run_count_today, records last_run_at.
# ──────────────────────────────────────────────────────────────────────────────
agent_checkin() {
    local agent_id="${1:-unknown}"
    local tier="${2:-worker}"
    local supervisor_id="${3:-}"

    [[ -z "$_AR_KEY" ]] && return 0

    export _AR_ID="$agent_id" _AR_TIER="$tier" _AR_SUP="$supervisor_id" \
           _AR_KEY _AR_URL

    python3 - <<'PY' 2>/dev/null
import urllib.request, urllib.parse, json, os
from datetime import datetime, timezone

KEY  = os.environ['_AR_KEY']
URL  = os.environ['_AR_URL']
aid  = os.environ['_AR_ID']
tier = os.environ['_AR_TIER']
sup  = os.environ['_AR_SUP']

now_str = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S+00:00')

# Step 1: get current run_count_today
try:
    req = urllib.request.Request(
        f"{URL}/rest/v1/agent_registry?agent_id=eq.{urllib.parse.quote(aid)}&select=run_count_today",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"},
    )
    with urllib.request.urlopen(req, timeout=5) as r:
        rows = json.loads(r.read())
    count = rows[0]['run_count_today'] if rows else 0
except Exception:
    count = 0

# Step 2: PATCH status=running + last_run_at + incremented run_count_today
patch_body = {
    "status":          "running",
    "last_run_at":     now_str,
    "run_count_today": count + 1,
    "updated_at":      now_str,
}
req = urllib.request.Request(
    f"{URL}/rest/v1/agent_registry?agent_id=eq.{urllib.parse.quote(aid)}",
    data=json.dumps(patch_body).encode(),
    headers={
        "apikey":        KEY,
        "Authorization": f"Bearer {KEY}",
        "Content-Type":  "application/json",
        "Prefer":        "return=minimal",
    },
    method="PATCH",
)
try:
    urllib.request.urlopen(req, timeout=5)
except Exception:
    pass
PY
}

# ──────────────────────────────────────────────────────────────────────────────
# agent_checkout <agent_id> <status> <result_summary> [duration_ms]
# Sets status=idle/error, records last_result and duration.
# ──────────────────────────────────────────────────────────────────────────────
agent_checkout() {
    local agent_id="${1:-unknown}"
    local ag_status="${2:-idle}"    # idle | error
    local result="${3:-}"
    local duration_ms="${4:-0}"

    [[ -z "$_AR_KEY" ]] && return 0

    export _AR_ID="$agent_id" _AR_STATUS="$ag_status" _AR_RESULT="$result" \
           _AR_DUR="$duration_ms" _AR_KEY _AR_URL

    python3 - <<'PY' 2>/dev/null
import urllib.request, urllib.parse, json, os
from datetime import datetime, timezone

KEY    = os.environ['_AR_KEY']
URL    = os.environ['_AR_URL']
aid    = os.environ['_AR_ID']
status = os.environ['_AR_STATUS']
result = os.environ['_AR_RESULT']
dur    = os.environ['_AR_DUR']

now_str = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S+00:00')

body = {
    "status":      status,
    "last_result": (result[:500] if result else None),
    "updated_at":  now_str,
}
if dur and dur != "0":
    try:
        body["last_run_duration_ms"] = int(dur)
    except ValueError:
        pass

# Increment error_count_today on error
if status == "error":
    try:
        req = urllib.request.Request(
            f"{URL}/rest/v1/agent_registry?agent_id=eq.{urllib.parse.quote(aid)}&select=error_count_today",
            headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"},
        )
        with urllib.request.urlopen(req, timeout=5) as r:
            rows = json.loads(r.read())
        body["error_count_today"] = (rows[0]['error_count_today'] if rows else 0) + 1
    except Exception:
        pass

req = urllib.request.Request(
    f"{URL}/rest/v1/agent_registry?agent_id=eq.{urllib.parse.quote(aid)}",
    data=json.dumps(body).encode(),
    headers={
        "apikey":        KEY,
        "Authorization": f"Bearer {KEY}",
        "Content-Type":  "application/json",
        "Prefer":        "return=minimal",
    },
    method="PATCH",
)
try:
    urllib.request.urlopen(req, timeout=5)
except Exception:
    pass
PY
}

# ──────────────────────────────────────────────────────────────────────────────
# agent_command_check <agent_id>
# Outputs the command string if a pending command exists, else empty.
# Also marks the command as ack'd.
# ──────────────────────────────────────────────────────────────────────────────
agent_command_check() {
    local agent_id="${1:-unknown}"
    [[ -z "$_AR_KEY" ]] && echo "" && return 0

    export _AR_ID="$agent_id" _AR_KEY _AR_URL

    python3 - <<'PY' 2>/dev/null
import urllib.request, urllib.parse, json, os
from datetime import datetime, timezone

KEY = os.environ['_AR_KEY']
URL = os.environ['_AR_URL']
aid = os.environ['_AR_ID']

req = urllib.request.Request(
    f"{URL}/rest/v1/agent_commands?to_agent_id=eq.{urllib.parse.quote(aid)}&status=eq.pending&order=created_at.asc&limit=1",
    headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"},
)
try:
    with urllib.request.urlopen(req, timeout=5) as r:
        rows = json.loads(r.read())
    if not rows:
        print("")
        raise SystemExit(0)
    cmd = rows[0]
    now_str = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S+00:00')
    ack = urllib.request.Request(
        f"{URL}/rest/v1/agent_commands?id=eq.{cmd['id']}",
        data=json.dumps({"status": "ack", "ack_at": now_str}).encode(),
        headers={
            "apikey":        KEY,
            "Authorization": f"Bearer {KEY}",
            "Content-Type":  "application/json",
            "Prefer":        "return=minimal",
        },
        method="PATCH",
    )
    urllib.request.urlopen(ack, timeout=5)
    print(cmd.get("command", ""))
except Exception:
    print("")
PY
}

# ──────────────────────────────────────────────────────────────────────────────
# agent_command_done <agent_id> [result]
# Marks the most recently ack'd command as done.
# ──────────────────────────────────────────────────────────────────────────────
agent_command_done() {
    local agent_id="${1:-unknown}"
    local result="${2:-done}"
    [[ -z "$_AR_KEY" ]] && return 0

    export _AR_ID="$agent_id" _AR_RES="$result" _AR_KEY _AR_URL

    python3 - <<'PY' 2>/dev/null
import urllib.request, urllib.parse, json, os
from datetime import datetime, timezone

KEY = os.environ['_AR_KEY']
URL = os.environ['_AR_URL']
aid = os.environ['_AR_ID']
res = os.environ['_AR_RES']

now_str = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S+00:00')

req = urllib.request.Request(
    f"{URL}/rest/v1/agent_commands?to_agent_id=eq.{urllib.parse.quote(aid)}&status=eq.ack&order=ack_at.desc&limit=1",
    data=json.dumps({"status": "done", "done_at": now_str, "result": res}).encode(),
    headers={
        "apikey":        KEY,
        "Authorization": f"Bearer {KEY}",
        "Content-Type":  "application/json",
        "Prefer":        "return=minimal",
    },
    method="PATCH",
)
try:
    urllib.request.urlopen(req, timeout=5)
except Exception:
    pass
PY
}

# ──────────────────────────────────────────────────────────────────────────────
# agent_issue_command <from_agent_id> <to_agent_id> <command> [payload_json]
# Issues a command from one agent to another.
# ──────────────────────────────────────────────────────────────────────────────
agent_issue_command() {
    local from_id="${1:-unknown}"
    local to_id="${2:-unknown}"
    local command="${3:-run_now}"
    local payload="${4:-{}}"
    [[ -z "$_AR_KEY" ]] && return 0

    export _AR_FROM="$from_id" _AR_TO="$to_id" _AR_CMD="$command" \
           _AR_PAYLOAD="$payload" _AR_KEY _AR_URL

    python3 - <<'PY' 2>/dev/null
import urllib.request, json, os

KEY     = os.environ['_AR_KEY']
URL     = os.environ['_AR_URL']
from_id = os.environ['_AR_FROM']
to_id   = os.environ['_AR_TO']
command = os.environ['_AR_CMD']
payload = json.loads(os.environ.get('_AR_PAYLOAD', '{}'))

body = json.dumps({
    "from_agent_id": from_id,
    "to_agent_id":   to_id,
    "command":       command,
    "payload":       payload,
    "status":        "pending",
}).encode()

req = urllib.request.Request(
    f"{URL}/rest/v1/agent_commands",
    data=body,
    headers={
        "apikey":        KEY,
        "Authorization": f"Bearer {KEY}",
        "Content-Type":  "application/json",
        "Prefer":        "return=minimal",
    },
    method="POST",
)
try:
    urllib.request.urlopen(req, timeout=5)
except Exception:
    pass
PY
}

# ──────────────────────────────────────────────────────────────────────────────
# agent_metric <agent_id> <metrics_json>
# Writes a metric snapshot for today.
# ──────────────────────────────────────────────────────────────────────────────
agent_metric() {
    local agent_id="${1:-unknown}"
    local metrics="${2:-{}}"
    [[ -z "$_AR_KEY" ]] && return 0

    export _AR_ID="$agent_id" _AR_METRICS="$metrics" _AR_KEY _AR_URL

    python3 - <<'PY' 2>/dev/null
import urllib.request, json, os
from datetime import datetime, timezone

KEY     = os.environ['_AR_KEY']
URL     = os.environ['_AR_URL']
aid     = os.environ['_AR_ID']
metrics = json.loads(os.environ.get('_AR_METRICS', '{}'))
period  = datetime.now(timezone.utc).strftime('%Y-%m-%d')

body = json.dumps({"agent_id": aid, "period": period, "metrics": metrics}).encode()
req  = urllib.request.Request(
    f"{URL}/rest/v1/agent_metrics",
    data=body,
    headers={
        "apikey":        KEY,
        "Authorization": f"Bearer {KEY}",
        "Content-Type":  "application/json",
        "Prefer":        "return=minimal",
    },
    method="POST",
)
try:
    urllib.request.urlopen(req, timeout=5)
except Exception:
    pass
PY
}

# ──────────────────────────────────────────────────────────────────────────────
# agent_get_registry [domain] [tier]
# Returns JSON array of agent_registry rows, optionally filtered.
# Used by supervisors and the head agent to inspect their workers.
# ──────────────────────────────────────────────────────────────────────────────
agent_get_registry() {
    local domain="${1:-}"
    local tier="${2:-}"
    [[ -z "$_AR_KEY" ]] && echo "[]" && return 0

    export _AR_DOMAIN="$domain" _AR_TIER="$tier" _AR_KEY _AR_URL

    python3 - <<'PY' 2>/dev/null
import urllib.request, urllib.parse, json, os

KEY    = os.environ['_AR_KEY']
URL    = os.environ['_AR_URL']
domain = os.environ.get('_AR_DOMAIN', '')
tier   = os.environ.get('_AR_TIER', '')

params = []
if domain: params.append(f"domain=eq.{urllib.parse.quote(domain)}")
if tier:   params.append(f"tier=eq.{urllib.parse.quote(tier)}")
params.append("order=domain.asc,tier.asc,agent_id.asc")

qs  = "&".join(params)
url = f"{URL}/rest/v1/agent_registry?{qs}"

req = urllib.request.Request(
    url,
    headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"},
)
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        print(r.read().decode())
except Exception:
    print("[]")
PY
}
