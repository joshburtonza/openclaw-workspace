#!/bin/bash
# run-claude-job.sh
# Generic runner for Claude Code cron jobs.
# Usage: run-claude-job.sh <prompt-file> [job-name]
#
# Runs `claude -p` with the given prompt file using full tool access.
# Logs output to out/<job-name>.log and out/<job-name>.err.log

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

PROMPT_FILE="${1:-}"
JOB_NAME="${2:-$(basename "${PROMPT_FILE%.md}")}"
WS="/Users/henryburton/.openclaw/workspace-anthropic"

if [[ -z "$PROMPT_FILE" || ! -f "$PROMPT_FILE" ]]; then
  echo "Usage: $0 <prompt-file> [job-name]" >&2
  exit 1
fi

# Load secrets
ENV_FILE="$WS/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

LOG_DIR="$WS/out"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/${JOB_NAME}.log"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting $JOB_NAME" >> "$LOG"

# Unset CLAUDECODE so this can run outside of an active Claude session
unset CLAUDECODE

# Run Claude with full tool access (Bash, Read, Write, Glob, Grep, WebFetch)
# --dangerously-skip-permissions: needed for unattended runs (no interactive prompts)
claude --print \
  --dangerously-skip-permissions \
  --model claude-sonnet-4-6 \
  --add-dir "$WS" \
  "$(cat "$PROMPT_FILE")" \
  >> "$LOG" 2>&1

EXIT_CODE=$?
echo "[$(date '+%Y-%m-%d %H:%M:%S')] $JOB_NAME finished (exit $EXIT_CODE)" >> "$LOG"
exit $EXIT_CODE
