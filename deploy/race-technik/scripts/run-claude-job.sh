#!/bin/bash
# run-claude-job.sh — Race Technik Mac Mini
# Generic runner for Claude Code cron jobs.
# Usage: run-claude-job.sh <prompt-file> [job-name]

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

PROMPT_FILE="${1:-}"
JOB_NAME="${2:-$(basename "${PROMPT_FILE%.md}" 2>/dev/null || echo "job")}"
WS="${HOME}/.amalfiai/workspace"

if [[ -z "$PROMPT_FILE" || ! -f "$PROMPT_FILE" ]]; then
  echo "Usage: $0 <prompt-file> [job-name]" >&2
  exit 1
fi

ENV_FILE="${WS}/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

LOG_DIR="${WS}/out"
mkdir -p "$LOG_DIR"
LOG="${LOG_DIR}/${JOB_NAME}.log"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting $JOB_NAME" >> "$LOG"

unset CLAUDECODE
RESPONSE=$(claude --print \
  --dangerously-skip-permissions \
  --model claude-sonnet-4-6 \
  --add-dir "$WS" \
  < "$PROMPT_FILE" 2>&1 || echo "")

echo "[$(date '+%Y-%m-%d %H:%M:%S')] $JOB_NAME complete" >> "$LOG"
echo "$RESPONSE" >> "$LOG"
