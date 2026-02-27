#!/usr/bin/env bash
# rt-task.sh
# Queues a task for the Race Technik Mac Mini's Claude instance via Supabase.
# The Mac Mini's rt-research-implement.sh picks it up automatically.
#
# Usage: rt-task.sh "Task title" "Task description" [priority]
#   priority: normal (default), high, urgent

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

AOS_ROOT="${AOS_ROOT:-/Users/henryburton/.openclaw/workspace-anthropic}"
WS="$AOS_ROOT"
ENV_FILE="$WS/.env.scheduler"

# ── Load env ──────────────────────────────────────────────────────────────────

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found" >&2
  exit 1
fi
set -a
source "$ENV_FILE"
set +a

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
JOSH_CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-1140320036}"

if [[ -z "$SUPABASE_KEY" ]]; then
  echo "ERROR: SUPABASE_SERVICE_ROLE_KEY not set in $ENV_FILE" >&2
  exit 1
fi

# ── Parse args ────────────────────────────────────────────────────────────────

if [[ $# -lt 2 ]]; then
  echo "Usage: rt-task.sh \"Task title\" \"Task description\" [priority]" >&2
  echo "  priority: normal (default), high, urgent" >&2
  exit 1
fi

TASK_TITLE="$1"
TASK_DESC="$2"
TASK_PRIORITY="${3:-normal}"

case "$TASK_PRIORITY" in
  normal|high|urgent) ;;
  *)
    echo "ERROR: Invalid priority '$TASK_PRIORITY'. Must be: normal, high, urgent" >&2
    exit 1
    ;;
esac

# ── Insert task via Supabase REST API ─────────────────────────────────────────

export _RT_TITLE="$TASK_TITLE"
export _RT_DESC="$TASK_DESC"
export _RT_PRIORITY="$TASK_PRIORITY"
export _RT_SUPABASE_URL="$SUPABASE_URL"
export _RT_SUPABASE_KEY="$SUPABASE_KEY"

TASK_ID=$(python3 - <<'PY'
import os, json, urllib.request, sys

URL      = os.environ['_RT_SUPABASE_URL']
KEY      = os.environ['_RT_SUPABASE_KEY']
title    = os.environ['_RT_TITLE']
desc     = os.environ['_RT_DESC']
priority = os.environ['_RT_PRIORITY']

payload = json.dumps({
    "title":       title,
    "description": desc,
    "status":      "todo",
    "priority":    priority,
    "assigned_to": "claude@race-technik",
    "metadata":    {"repo": "chrome-auto-care", "source": "josh-macbook"},
}).encode()

req = urllib.request.Request(
    f"{URL}/rest/v1/tasks",
    data=payload,
    headers={
        "apikey":        KEY,
        "Authorization": f"Bearer {KEY}",
        "Content-Type":  "application/json",
        "Prefer":        "return=representation",
    },
    method="POST",
)

try:
    with urllib.request.urlopen(req, timeout=15) as r:
        rows = json.loads(r.read())
        if rows:
            print(rows[0]['id'])
        else:
            print("ERROR: empty response from Supabase", file=sys.stderr)
            sys.exit(1)
except urllib.error.HTTPError as e:
    body = e.read().decode()
    print(f"ERROR: HTTP {e.code}: {body}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PY
)

EXIT_CODE=$?
if [[ $EXIT_CODE -ne 0 || -z "$TASK_ID" ]]; then
  echo "ERROR: Failed to insert task into Supabase" >&2
  exit 1
fi

echo "Task queued: $TASK_ID"

# ── Telegram notification to Josh ─────────────────────────────────────────────

if [[ -n "$BOT_TOKEN" ]]; then
  export _RT_BOT_TOKEN="$BOT_TOKEN"
  export _RT_JOSH_CHAT_ID="$JOSH_CHAT_ID"
  export _RT_QUEUED_ID="$TASK_ID"
  python3 - <<'PY'
import os, json, urllib.request

BOT_TOKEN    = os.environ['_RT_BOT_TOKEN']
JOSH_CHAT_ID = os.environ['_RT_JOSH_CHAT_ID']
title        = os.environ['_RT_TITLE']
task_id      = os.environ['_RT_QUEUED_ID']
priority     = os.environ['_RT_PRIORITY']

text = (
    f"Task queued for Race Technik Mac Mini: {title}\n"
    f"Priority: {priority} | Repo: chrome-auto-care\n"
    f"ID: {task_id}\n"
    f"Assigned to: claude@race-technik"
)

data = json.dumps({
    "chat_id":    JOSH_CHAT_ID,
    "text":       text,
    "parse_mode": "HTML",
}).encode()

req = urllib.request.Request(
    f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
    data=data,
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    urllib.request.urlopen(req, timeout=10)
except Exception:
    pass
PY
fi
