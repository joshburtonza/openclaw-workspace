#!/bin/bash
# run-sophia-job.sh
# Sophia-specific job runner.
# Prepends soul.md + instructions.md + memory.md before the job prompt,
# then pipes the full assembled context to claude --print.
#
# Usage: run-sophia-job.sh <prompt-file> [job-name]

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

PROMPT_FILE="${1:-}"
JOB_NAME="${2:-$(basename "${PROMPT_FILE%.md}")}"
AOS_ROOT="${AOS_ROOT:-/Users/henryburton/.openclaw/workspace-anthropic}"
WS="$AOS_ROOT"

if [[ -z "$PROMPT_FILE" || ! -f "$PROMPT_FILE" ]]; then
  echo "Usage: $0 <prompt-file> [job-name]" >&2
  exit 1
fi

ENV_FILE="$WS/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

# ── Kill switch + OOO guard ───────────────────────────────────────────────────
SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
_API_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"

if [[ -f "${HOME}/.openclaw/KILL_SWITCH" ]]; then
  echo "[run-sophia-job] KILL SWITCH active — $JOB_NAME suppressed." >&2
  exit 0
fi

if [[ -n "$_API_KEY" ]]; then
  export _KS_RAW=$(curl -s \
    "${SUPABASE_URL}/rest/v1/kill_switch?id=eq.00000000-0000-0000-0000-000000000001&select=status" \
    -H "apikey: ${_API_KEY}" -H "Authorization: Bearer ${_API_KEY}")
  _KS=$(python3 -c "import json,os; rows=json.loads(os.environ['_KS_RAW']); print(rows[0]['status'] if rows else 'running')" 2>/dev/null || echo "running")
  if [[ "$_KS" != "running" ]]; then
    echo "[run-sophia-job] Kill switch is '$_KS' — $JOB_NAME suppressed." >&2
    exit 0
  fi

  export _OOO_RAW=$(curl -s \
    "${SUPABASE_URL}/rest/v1/system_config?key=eq.sophia_ooo&select=value" \
    -H "apikey: ${_API_KEY}" -H "Authorization: Bearer ${_API_KEY}")
  _OOO=$(python3 -c "
import json, os
rows = json.loads(os.environ['_OOO_RAW'])
if not rows: print('false')
else:
    v = rows[0].get('value','{}')
    obj = json.loads(v) if isinstance(v,str) else v
    print('true' if obj.get('enabled') else 'false')
" 2>/dev/null || echo "false")
  if [[ "$_OOO" == "true" ]]; then
    echo "[run-sophia-job] OOO mode active — $JOB_NAME suppressed." >&2
    exit 0
  fi
fi

LOG_DIR="$WS/out"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/${JOB_NAME}.log"

SOUL="$WS/prompts/sophia/soul.md"
INSTRUCT="$WS/prompts/sophia/instructions.md"
MEMORY="$WS/memory/sophia/memory.md"
TODAY=$(date '+%A, %d %B %Y %H:%M SAST')

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting $JOB_NAME" >> "$LOG"

# Build combined prompt in a temp file
COMBINED=$(mktemp /tmp/sophia-combined-XXXXXX)
trap 'rm -f "$COMBINED"' EXIT

# System prompt: Sophia identity + memory
SYSTEM_CONTENT=""
if [[ -f "$SOUL" ]];    then SYSTEM_CONTENT="${SYSTEM_CONTENT}$(cat "$SOUL")\n\n---\n\n"; fi
if [[ -f "$INSTRUCT" ]]; then SYSTEM_CONTENT="${SYSTEM_CONTENT}$(cat "$INSTRUCT")\n\n---\n\n"; fi
if [[ -f "$MEMORY" ]]; then
  SYSTEM_CONTENT="${SYSTEM_CONTENT}## YOUR CURRENT MEMORY\n\n$(cat "$MEMORY")\n\n---\n\n"
fi

# User message: date context + job instructions
{
  echo "Today: ${TODAY}"
  echo ""
  echo "---"
  echo ""
  cat "$PROMPT_FILE"
} > "$COMBINED"

bash "$WS/scripts/lib/openai-complete.sh" \
  --model gpt-4o \
  --system "$(printf '%b' "$SYSTEM_CONTENT")" \
  < "$COMBINED" \
  >> "$LOG" 2>&1

EXIT_CODE=$?
echo "[$(date '+%Y-%m-%d %H:%M:%S')] $JOB_NAME finished (exit $EXIT_CODE)" >> "$LOG"
exit $EXIT_CODE
