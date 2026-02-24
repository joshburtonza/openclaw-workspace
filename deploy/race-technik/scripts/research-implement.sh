#!/usr/bin/env bash
# rt-research-implement.sh
# Race Technik Mac Mini autonomous task worker.
# Picks up todo tasks assigned to "claude@race-technik" or "Claude" and implements them.
# Rescues stuck in_progress tasks (>20 min). Processes up to 3 tasks per run.
# Designed to run every 10 min via launchd on the Mac Mini.
#
# Deploy to Mac Mini at: ~/.amalfiai/scripts/rt-research-implement.sh
# LaunchAgent plist: load with a StartInterval of 600.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WORKSPACE="${HOME}/.amalfiai/workspace"
CLIENTS="${HOME}/.amalfiai/workspace/clients"
ENV_FILE="${HOME}/.amalfiai/workspace/.env.scheduler"
LOG_DIR="${HOME}/.amalfiai/logs"

mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/rt-research-implement.log"

# ── Load env ──────────────────────────────────────────────────────────────────

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[$(date '+%H:%M:%S')] ERROR: $ENV_FILE not found" | tee -a "$LOG"
  exit 1
fi
set -a
source "$ENV_FILE"
set +a

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"

# Primary Telegram chat: Farhaan's chat (from .env.scheduler TELEGRAM_CHAT_ID)
PRIMARY_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Secondary copy notification to Josh (optional — set JOSH_NOTIFY_CHAT_ID in .env.scheduler)
JOSH_NOTIFY_CHAT_ID="${JOSH_NOTIFY_CHAT_ID:-}"

# Machine identity (optional — set MACHINE_ID in .env.scheduler, e.g. "race-technik-macmini")
MACHINE_ID="${MACHINE_ID:-race-technik-macmini}"

MODEL="claude-sonnet-4-6"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
log "=== RT research implement run ($MACHINE_ID) ==="

# ── Validate creds ────────────────────────────────────────────────────────────

if [[ -z "$SUPABASE_KEY" ]]; then
  log "ERROR: SUPABASE_SERVICE_ROLE_KEY not set in $ENV_FILE"
  exit 1
fi

if [[ -z "$PRIMARY_CHAT_ID" ]]; then
  log "WARNING: TELEGRAM_CHAT_ID not set — Telegram notifications disabled"
fi

export SUPABASE_URL SUPABASE_KEY BOT_TOKEN PRIMARY_CHAT_ID JOSH_NOTIFY_CHAT_ID MACHINE_ID MODEL WORKSPACE CLIENTS

# ── Repo map for Race Technik ─────────────────────────────────────────────────
# Only chrome-auto-care entries are active on this machine.

REPO_MAP_JSON='{"chrome-auto-care": "chrome-auto-care", "race-technik": "chrome-auto-care"}'
export REPO_MAP_JSON

# ── Telegram helper ───────────────────────────────────────────────────────────
# Sends to PRIMARY_CHAT_ID and optionally a copy to JOSH_NOTIFY_CHAT_ID.

send_telegram() {
  local message="$1"
  export _TG_MESSAGE="$message"
  python3 - <<'PY'
import os, json, urllib.request

BOT_TOKEN         = os.environ.get('BOT_TOKEN', '')
PRIMARY_CHAT_ID   = os.environ.get('PRIMARY_CHAT_ID', '')
JOSH_CHAT_ID      = os.environ.get('JOSH_NOTIFY_CHAT_ID', '')
text              = os.environ.get('_TG_MESSAGE', '')

if not BOT_TOKEN or not text:
    raise SystemExit(0)

def send(chat_id, msg):
    if not chat_id:
        return
    data = json.dumps({"chat_id": chat_id, "text": msg, "parse_mode": "HTML"}).encode()
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

send(PRIMARY_CHAT_ID, text)
if JOSH_CHAT_ID and JOSH_CHAT_ID != PRIMARY_CHAT_ID:
    send(JOSH_CHAT_ID, f"[RT Mac Mini copy] {text}")
PY
}
export -f send_telegram 2>/dev/null || true

# ── Rescue stuck in_progress tasks (>20 min) ─────────────────────────────────

python3 - <<'PY'
import os, json, urllib.request, datetime

KEY = os.environ['SUPABASE_KEY']
URL = os.environ['SUPABASE_URL']

cutoff = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=20)).strftime('%Y-%m-%dT%H:%M:%SZ')

# Match both assigned_to values via two separate requests
stuck_all = []
for assignee in ['claude@race-technik', 'Claude']:
    req = urllib.request.Request(
        f"{URL}/rest/v1/tasks"
        f"?status=eq.in_progress"
        f"&assigned_to=eq.{urllib.request.quote(assignee)}"
        f"&updated_at=lt.{cutoff}"
        f"&select=id,title",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            stuck_all.extend(json.loads(r.read()))
    except Exception:
        pass

if not stuck_all:
    raise SystemExit(0)

for t in stuck_all:
    data = json.dumps({"status": "todo"}).encode()
    req2 = urllib.request.Request(
        f"{URL}/rest/v1/tasks?id=eq.{t['id']}",
        data=data,
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
                 "Content-Type": "application/json", "Prefer": "return=minimal"},
        method="PATCH",
    )
    try:
        urllib.request.urlopen(req2, timeout=10)
        print(f"[rescue] Reset stuck task: {t['title'][:60]}")
    except Exception as e:
        print(f"[rescue] Failed to reset {t['id']}: {e}")
PY

# ── Process up to 3 tasks ─────────────────────────────────────────────────────

RUN_START=$(date +%s)
TASKS_DONE=0
MAX_TASKS=3

while [[ $TASKS_DONE -lt $MAX_TASKS ]]; do

  # Time guard: stop before starting a new task if >8 min elapsed
  NOW=$(date +%s)
  ELAPSED=$((NOW - RUN_START))
  if [[ $ELAPSED -gt 480 ]]; then
    log "Time guard: ${ELAPSED}s elapsed — stopping after ${TASKS_DONE} task(s)"
    break
  fi

  # ── Fetch one pending task (claude@race-technik OR Claude) ─────────────────
  # Run two queries and take the oldest result across both.

  TASK_JSON=$(python3 - <<'PY'
import os, json, urllib.request, sys
from urllib.request import quote

KEY = os.environ['SUPABASE_KEY']
URL = os.environ['SUPABASE_URL']

candidates = []
for assignee in ['claude@race-technik', 'Claude']:
    req = urllib.request.Request(
        f"{URL}/rest/v1/tasks"
        f"?status=eq.todo"
        f"&assigned_to=eq.{quote(assignee)}"
        f"&order=created_at.asc"
        f"&limit=1"
        f"&select=*",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            rows = json.loads(r.read())
            if rows:
                candidates.append(rows[0])
    except Exception as e:
        print(f"", file=sys.stderr)

if not candidates:
    print("")
    raise SystemExit(0)

# Pick the oldest created_at
oldest = min(candidates, key=lambda t: t.get('created_at', ''))
print(json.dumps(oldest))
PY
  )

  if [[ -z "$TASK_JSON" ]]; then
    log "No todo tasks assigned to claude@race-technik or Claude."
    break
  fi

  # ── Parse task fields ──────────────────────────────────────────────────────

  TASK_ID=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
  TASK_TITLE=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])")
  TASK_DESC=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['description'] or '')")
  TASK_PRIORITY=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('priority','normal'))")

  REPO_KEY=$(echo "$TASK_JSON" | python3 - <<'PY'
import sys, json
t = json.load(sys.stdin)
meta = t.get('metadata') or {}
print(meta.get('repo', ''))
PY
  )

  # ── Resolve repo path ────────────────────────────────────────────────────────

  REPO_PATH=$(python3 - <<PY
import os, json

CLIENTS = os.environ['CLIENTS']
REPO_MAP = json.loads(os.environ['REPO_MAP_JSON'])
key = """${REPO_KEY}"""

dirname = REPO_MAP.get(key, '')
if not dirname:
    print('')
    raise SystemExit(0)

path = os.path.join(CLIENTS, dirname)
if os.path.isdir(path):
    print(path)
else:
    print('')
PY
  )

  if [[ -n "$REPO_KEY" && -z "$REPO_PATH" ]]; then
    log "WARNING: Repo key '$REPO_KEY' not found at $CLIENTS — falling back to workspace context only"
  fi

  log "Task $((TASKS_DONE + 1))/$MAX_TASKS: $TASK_TITLE (id: $TASK_ID, repo: ${REPO_KEY:-internal})"

  # ── Mark in_progress ────────────────────────────────────────────────────────

  export _TASK_ID="$TASK_ID"
  python3 - <<'PY'
import os, json, urllib.request

KEY = os.environ['SUPABASE_KEY']
URL = os.environ['SUPABASE_URL']
task_id = os.environ['_TASK_ID']

data = json.dumps({"status": "in_progress"}).encode()
req = urllib.request.Request(
    f"{URL}/rest/v1/tasks?id=eq.{task_id}",
    data=data,
    headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
             "Content-Type": "application/json", "Prefer": "return=minimal"},
    method="PATCH",
)
try:
    urllib.request.urlopen(req, timeout=10)
except Exception as e:
    print(f"Warning: could not mark in_progress: {e}")
PY

  # ── Build prompt ──────────────────────────────────────────────────────────────

  PROMPT_TMP=$(mktemp /tmp/rt-implement-XXXXXX)

  if [[ -n "$REPO_PATH" ]]; then
    CLIENT_CONTEXT=""
    if [[ -f "$REPO_PATH/CONTEXT.md" ]]; then
      CLIENT_CONTEXT=$(cat "$REPO_PATH/CONTEXT.md")
    fi
    export CLIENT_CONTEXT

    cat > "$PROMPT_TMP" << PROMPT
You are an autonomous implementation agent running on the Race Technik Mac Mini. You are working on the chrome-auto-care client repository.

## TASK
**Title:** ${TASK_TITLE}
**Priority:** ${TASK_PRIORITY}
**Repository:** ${REPO_KEY} at ${REPO_PATH}

**Description:**
${TASK_DESC}

## CLIENT CONTEXT
${CLIENT_CONTEXT}

## YOUR WORKING DIRECTORY
The client repo is at: ${REPO_PATH}

## STEPS TO FOLLOW
1. cd into ${REPO_PATH} and run: git pull origin main (or master, check which branch exists)
2. Read relevant files to understand the current implementation before making changes
3. Implement the change described precisely and surgically
4. If there is a package.json: check if a build script exists and run npm run build if so
5. Stage and commit: git add -A && git commit -m "<concise description of change>"
6. Push: git push
7. Output a concise summary of exactly what you changed (file paths, line numbers where relevant)

## IMPORTANT
- Do not ask questions, implement it directly
- No placeholder TODOs, write actual working code
- Follow the existing code patterns in the repo (inspect how similar components are built first)
- Keep commits clean and descriptive
- Sign off with: Implementation complete
PROMPT

  else
    cat > "$PROMPT_TMP" << PROMPT
You are an autonomous implementation agent running on the Race Technik Mac Mini.

## TASK
**Title:** ${TASK_TITLE}
**Priority:** ${TASK_PRIORITY}

**Description:**
${TASK_DESC}

## WORKSPACE
Files are in: ${WORKSPACE}/

Key directories:
- scripts/     — automation scripts
- clients/     — client repos (chrome-auto-care)

## STEPS TO FOLLOW
1. Read the relevant files mentioned in the task
2. Implement the specific improvement surgically
3. If creating new scripts: chmod +x
4. Output a concise summary of exactly what you changed

## IMPORTANT
- Do not ask questions, implement it directly
- No placeholder TODOs, write actual working code
- Sign off with: Implementation complete
PROMPT
  fi

  # ── Run Claude Code ────────────────────────────────────────────────────────────

  log "Running Claude Code (repo: ${REPO_KEY:-internal})..."
  unset CLAUDECODE

  RESPONSE=""
  if [[ -n "$REPO_PATH" ]]; then
    RESPONSE=$(claude --print \
      --dangerously-skip-permissions \
      --model "$MODEL" \
      --add-dir "$WORKSPACE" \
      --add-dir "$REPO_PATH" \
      < "$PROMPT_TMP" 2>/dev/null || echo "")
  else
    RESPONSE=$(claude --print \
      --dangerously-skip-permissions \
      --model "$MODEL" \
      --add-dir "$WORKSPACE" \
      < "$PROMPT_TMP" 2>/dev/null || echo "")
  fi

  rm -f "$PROMPT_TMP"

  if [[ -z "$RESPONSE" ]]; then
    log "ERROR: Empty response for task $TASK_ID — resetting to todo"
    python3 - <<PY
import os, json, urllib.request

KEY = os.environ['SUPABASE_KEY']
URL = os.environ['SUPABASE_URL']
task_id = os.environ['_TASK_ID']

data = json.dumps({
    "status": "todo",
    "description": "Implementation failed: empty Claude response on ${MACHINE_ID}. Will retry."
}).encode()
req = urllib.request.Request(
    f"{URL}/rest/v1/tasks?id=eq.{task_id}",
    data=data,
    headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
             "Content-Type": "application/json", "Prefer": "return=minimal"},
    method="PATCH",
)
try:
    urllib.request.urlopen(req, timeout=10)
except Exception:
    pass
PY
    TASKS_DONE=$((TASKS_DONE + 1))
    continue
  fi

  log "Implementation complete."

  # ── Mark done ──────────────────────────────────────────────────────────────────

  export _IMPL_RESPONSE="$RESPONSE"
  python3 - <<'PY'
import os, json, urllib.request, datetime

KEY      = os.environ['SUPABASE_KEY']
URL      = os.environ['SUPABASE_URL']
task_id  = os.environ['_TASK_ID']
response = os.environ.get('_IMPL_RESPONSE', '')[:2000]
machine  = os.environ.get('MACHINE_ID', 'race-technik-macmini')

data = json.dumps({
    "status":       "done",
    "description":  response,
    "completed_at": datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    "metadata":     {"completed_by": machine},
}).encode()
req = urllib.request.Request(
    f"{URL}/rest/v1/tasks?id=eq.{task_id}",
    data=data,
    headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
             "Content-Type": "application/json", "Prefer": "return=minimal"},
    method="PATCH",
)
try:
    urllib.request.urlopen(req, timeout=10)
except Exception as e:
    print(f"Warning: task update failed: {e}")
PY

  # ── Telegram notifications ─────────────────────────────────────────────────────

  SUMMARY=$(echo "$RESPONSE" | python3 -c "
import sys
lines = sys.stdin.read().strip().split('\n')
summary = '\n'.join(lines[-5:]) if len(lines) > 5 else '\n'.join(lines)
print(summary[:600])
" 2>/dev/null || echo "")

  export _NOTIF_TITLE="$TASK_TITLE"
  export _NOTIF_REPO="$REPO_KEY"
  export _NOTIF_SUMMARY="$SUMMARY"
  export _NOTIF_MACHINE="$MACHINE_ID"

  python3 - <<'PY'
import os, json, urllib.request

BOT_TOKEN       = os.environ.get('BOT_TOKEN', '')
PRIMARY_CHAT_ID = os.environ.get('PRIMARY_CHAT_ID', '')
JOSH_CHAT_ID    = os.environ.get('JOSH_NOTIFY_CHAT_ID', '')
title           = os.environ.get('_NOTIF_TITLE', '')
repo            = os.environ.get('_NOTIF_REPO', '')
summary         = os.environ.get('_NOTIF_SUMMARY', '')
machine         = os.environ.get('_NOTIF_MACHINE', 'race-technik-macmini')

if not BOT_TOKEN:
    raise SystemExit(0)

repo_tag = f" [{repo}]" if repo else ""
main_text = f"Task done{repo_tag} on {machine}\n<b>{title}</b>\n\n{summary}"
josh_text = f"[RT Mac Mini] Task done{repo_tag}\n<b>{title}</b>\n\n{summary}"

def send(chat_id, text):
    if not chat_id:
        return
    data = json.dumps({"chat_id": chat_id, "text": text, "parse_mode": "HTML"}).encode()
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

send(PRIMARY_CHAT_ID, main_text)
if JOSH_CHAT_ID and JOSH_CHAT_ID != PRIMARY_CHAT_ID:
    send(JOSH_CHAT_ID, josh_text)
PY

  log "Done: $TASK_TITLE"
  TASKS_DONE=$((TASKS_DONE + 1))

done

log "Run complete: ${TASKS_DONE} task(s) processed."
