#!/usr/bin/env bash
# research-implement.sh
# Picks up todo tasks assigned to Claude and autonomously implements them.
# Rescues stuck in_progress tasks (>20 min). Processes up to 3 tasks per run.
# Runs every 10 min via LaunchAgent.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
CLIENTS="$WS/clients"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a

source "$WS/scripts/lib/task-helpers.sh"

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-1140320036}"
MODEL="claude-sonnet-4-6"
LOG="$WS/out/research-implement.log"

mkdir -p "$WS/out"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
log "=== Research implement run ==="

if [[ -z "$SUPABASE_KEY" ]]; then
  log "ERROR: SUPABASE_SERVICE_ROLE_KEY not set"
  exit 1
fi

export SUPABASE_URL SUPABASE_KEY BOT_TOKEN CHAT_ID MODEL WS CLIENTS

# ── Rescue stuck in_progress tasks (>20 min) ──────────────────────────────────

python3 - <<'PY'
import os, json, urllib.request, datetime

KEY = os.environ['SUPABASE_KEY']
URL = os.environ['SUPABASE_URL']

cutoff = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=20)).strftime('%Y-%m-%dT%H:%M:%SZ')

req = urllib.request.Request(
    f"{URL}/rest/v1/tasks?status=eq.in_progress&assigned_to=eq.Claude&updated_at=lt.{cutoff}&select=id,title",
    headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"},
)
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        raw = r.read()
        stuck = json.loads(raw) if raw and raw.strip() else []
except Exception:
    stuck = []

if not stuck:
    raise SystemExit(0)

for t in stuck:
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

  # ── Fetch one pending task ─────────────────────────────────────────────────

  TASK_JSON=$(python3 - <<'PY'
import os, json, urllib.request

KEY = os.environ['SUPABASE_KEY']
URL = os.environ['SUPABASE_URL']

req = urllib.request.Request(
    f"{URL}/rest/v1/tasks"
    "?status=eq.todo"
    "&assigned_to=eq.Claude"
    "&order=created_at.asc"
    "&limit=1"
    "&select=*",
    headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"},
)
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        raw = r.read()
        rows = json.loads(raw) if raw and raw.strip() else []
        print(json.dumps(rows[0]) if rows else "")
except Exception as e:
    import sys; print("", file=sys.stderr)
PY
  )

  if [[ -z "$TASK_JSON" ]]; then
    log "No todo tasks assigned to Claude."
    break
  fi

  # ── Parse task fields ────────────────────────────────────────────────────────

  TASK_ID=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
  TASK_TITLE=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])")
  TASK_DESC=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['description'] or '')")
  TASK_PRIORITY=$(echo "$TASK_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('priority','normal'))")

  # Extract repo key from metadata (e.g. metadata.repo = "qms-guard")
  REPO_KEY=$(echo "$TASK_JSON" | python3 - <<'PY'
import sys, json
t = json.load(sys.stdin)
meta = t.get('metadata') or {}
print(meta.get('repo', ''))
PY
  )

  # ── Resolve repo path ──────────────────────────────────────────────────────

  REPO_PATH=$(python3 - <<PY
import os

CLIENTS = os.environ['CLIENTS']
key = """${REPO_KEY}"""

REPO_MAP = {
    'qms-guard':       f"{CLIENTS}/qms-guard",
    'favorite-flow':   f"{CLIENTS}/favorite-flow-9637aff2",
    'favlog':          f"{CLIENTS}/favorite-flow-9637aff2",
    'metal-solutions': f"{CLIENTS}/metal-solutions-elegance-site",
    'rt-metal':        f"{CLIENTS}/metal-solutions-elegance-site",
}

path = REPO_MAP.get(key, '')
if path and not os.path.isdir(path):
    path = ''
print(path)
PY
  )

  if [[ -n "$REPO_KEY" && -z "$REPO_PATH" ]]; then
    log "WARNING: Unknown repo key '$REPO_KEY' — falling back to workspace"
  fi

  log "Task $((TASKS_DONE + 1))/$MAX_TASKS: $TASK_TITLE (id: $TASK_ID, repo: ${REPO_KEY:-internal})"

  # ── Mark in_progress ──────────────────────────────────────────────────────

  python3 - <<PY
import os, json, urllib.request

KEY = os.environ['SUPABASE_KEY']
URL = os.environ['SUPABASE_URL']

data = json.dumps({"status": "in_progress"}).encode()
req = urllib.request.Request(
    f"{URL}/rest/v1/tasks?id=eq.${TASK_ID}",
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

  # ── Build prompt ────────────────────────────────────────────────────────────

  CURRENT_STATE=$(cat "$WS/CURRENT_STATE.md" 2>/dev/null | head -80 || echo "")
  RESEARCH_INTEL=$(cat "$WS/memory/research-intel.md" 2>/dev/null | head -60 || echo "")

  PROMPT_TMP=$(mktemp /tmp/implement-prompt-XXXXXX)

  if [[ -n "$REPO_PATH" ]]; then
    CLIENT_CONTEXT=""
    if [[ -f "$REPO_PATH/CONTEXT.md" ]]; then
      CLIENT_CONTEXT=$(cat "$REPO_PATH/CONTEXT.md")
    fi
    export CLIENT_CONTEXT

    cat > "$PROMPT_TMP" << PROMPT
You are an autonomous implementation agent for Amalfi AI. You are working on a CLIENT repository.

## TASK
**Title:** ${TASK_TITLE}
**Priority:** ${TASK_PRIORITY}
**Repository:** ${REPO_KEY} → ${REPO_PATH}

**Description:**
${TASK_DESC}

## CLIENT CONTEXT
${CLIENT_CONTEXT}

## YOUR WORKING DIRECTORY
The client repo is at: ${REPO_PATH}

## STEPS TO FOLLOW
1. cd into ${REPO_PATH} and run: git pull origin main (or master — check which branch)
2. Read relevant files to understand the current implementation
3. Implement the change described — surgical, only what's needed
4. Build/lint if there's a package.json: npm run build (check if build script exists first)
5. Stage and commit: git add -A && git commit -m "<concise description of what you did>"
6. Push: git push
7. Output a concise summary of exactly what you changed (file paths, what changed)

## IMPORTANT
- Do not ask questions — implement it
- No placeholder TODOs — actually implement it
- Follow existing code patterns in the repo (check how other components/pages are structured first)
- Keep commits clean and descriptive
- Sign off with: ✅ Implementation complete
PROMPT

  else
    cat > "$PROMPT_TMP" << PROMPT
You are an autonomous implementation agent for Amalfi AI's internal systems. Your job is to implement the following task.

## TASK
**Title:** ${TASK_TITLE}
**Priority:** ${TASK_PRIORITY}

**Description:**
${TASK_DESC}

## WORKSPACE
All files are in: ${WS}/

Key directories:
- scripts/              — all automation scripts (bash + python)
- prompts/              — Claude system prompts
- launchagents/         — LaunchAgent plists
- memory/               — MEMORY.md, research-intel.md
- mission-control-hub/  — React dashboard (TypeScript)
- clients/              — client repos (qms-guard, favorite-flow-9637aff2, metal-solutions-elegance-site)

## CURRENT SYSTEM STATE
${CURRENT_STATE}

## RESEARCH INTEL CONTEXT
${RESEARCH_INTEL}

## STEPS TO FOLLOW
1. Read the relevant files mentioned in the task
2. Implement the specific improvement — be surgical
3. If creating new scripts: chmod +x
4. If creating a new LaunchAgent: write plist to launchagents/, cp to ~/Library/LaunchAgents/, launchctl load
5. If modifying the dashboard: cd mission-control-hub && npm run build && vercel --prod
6. Output a concise summary of exactly what you changed

## IMPORTANT
- Do not ask questions — implement it
- No placeholder TODOs — actually implement it
- Be precise and targeted
- Sign off with: ✅ Implementation complete
PROMPT
  fi

  # ── Run Claude Code ──────────────────────────────────────────────────────────

  log "Running Claude Code (repo: ${REPO_KEY:-internal})..."
  unset CLAUDECODE

  RESPONSE=""
  if [[ -n "$REPO_PATH" ]]; then
    RESPONSE=$(claude --print \
      --dangerously-skip-permissions \
      --model "$MODEL" \
      --add-dir "$WS" \
      --add-dir "$REPO_PATH" \
      < "$PROMPT_TMP" 2>/dev/null || echo "")
  else
    RESPONSE=$(claude --print \
      --dangerously-skip-permissions \
      --model "$MODEL" \
      --add-dir "$WS" \
      < "$PROMPT_TMP" 2>/dev/null || echo "")
  fi

  rm -f "$PROMPT_TMP"

  if [[ -z "$RESPONSE" ]]; then
    log "ERROR: Empty response for task $TASK_ID — resetting to todo"
    python3 - <<PY
import os, json, urllib.request

KEY = os.environ['SUPABASE_KEY']
URL = os.environ['SUPABASE_URL']

data = json.dumps({"status": "todo", "description": "Implementation failed: empty Claude response. Will retry."}).encode()
req = urllib.request.Request(
    f"{URL}/rest/v1/tasks?id=eq.${TASK_ID}",
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

  # ── Mark done ────────────────────────────────────────────────────────────────

  export _IMPL_TASK_ID="$TASK_ID" _IMPL_RESPONSE="$RESPONSE"
  python3 - <<'PY'
import os, json, urllib.request, datetime

KEY      = os.environ['SUPABASE_KEY']
URL      = os.environ['SUPABASE_URL']
task_id  = os.environ.get('_IMPL_TASK_ID', '')
response = os.environ.get('_IMPL_RESPONSE', '')[:2000]

data = json.dumps({
    "status":       "done",
    "description":  response,
    "completed_at": datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
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

  # ── Telegram notification ────────────────────────────────────────────────────

  if [[ -n "$BOT_TOKEN" ]]; then
    SUMMARY=$(echo "$RESPONSE" | python3 -c "
import sys
lines = sys.stdin.read().strip().split('\n')
summary = '\n'.join(lines[-5:]) if len(lines) > 5 else '\n'.join(lines)
print(summary[:600])
" 2>/dev/null || echo "")

    export _IMPL_TITLE="$TASK_TITLE" _IMPL_REPO="$REPO_KEY" _IMPL_SUMMARY="$SUMMARY"
    python3 - <<'PY'
import os, json, urllib.request

BOT_TOKEN = os.environ['BOT_TOKEN']
CHAT_ID   = os.environ['CHAT_ID']
title     = os.environ.get('_IMPL_TITLE', '')
repo      = os.environ.get('_IMPL_REPO', '')
summary   = os.environ.get('_IMPL_SUMMARY', '')

repo_tag = f" [{repo}]" if repo else ""
text = f"✅ <b>Task done{repo_tag}</b>\n<b>{title}</b>\n\n{summary}"

data = json.dumps({"chat_id": CHAT_ID, "text": text, "parse_mode": "HTML"}).encode()
req = urllib.request.Request(
    f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
    data=data, headers={"Content-Type": "application/json"}, method="POST",
)
try:
    urllib.request.urlopen(req, timeout=10)
except Exception:
    pass
PY
  fi

  log "Done: $TASK_TITLE"
  TASKS_DONE=$((TASKS_DONE + 1))

done

log "Run complete: ${TASKS_DONE} task(s) processed."
