#!/bin/bash
# run-parallel-ai.sh
# Runs a prompt through Claude AND GPT-4o simultaneously.
# A supervisor (gpt-4o-mini) picks the better response.
# Falls back gracefully to Claude if OpenAI is unavailable.
#
# Usage: run-parallel-ai.sh <prompt_file>
# Output: winning response on stdout

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

PROMPT_FILE="${1:-}"
if [[ -z "$PROMPT_FILE" || ! -f "$PROMPT_FILE" ]]; then
  echo "Usage: $0 <prompt_file>" >&2
  exit 1
fi

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

OPENAI_KEY="${OPENAI_API_KEY:-}"
MODEL="${OPENAI_MODEL:-gpt-4o}"
export OPENAI_API_KEY="$OPENAI_KEY"
export OPENAI_MODEL="$MODEL"

# Temp files for responses
TMP_A=$(mktemp /tmp/ai-response-a-XXXXXX)
TMP_B=$(mktemp /tmp/ai-response-b-XXXXXX)
TMP_ERR_A=$(mktemp /tmp/ai-err-a-XXXXXX)
TMP_ERR_B=$(mktemp /tmp/ai-err-b-XXXXXX)
trap 'rm -f "$TMP_A" "$TMP_B" "$TMP_ERR_A" "$TMP_ERR_B"' EXIT

unset CLAUDECODE

# ── Run both in parallel ──────────────────────────────────────────────────────

echo "[parallel-ai] Firing Claude + ${MODEL} simultaneously..." >&2

# Claude
(
  claude --print \
    --dangerously-skip-permissions \
    --model claude-sonnet-4-6 \
    --add-dir "$WS" \
    < "$PROMPT_FILE" > "$TMP_A" 2>"$TMP_ERR_A"
) &
PID_A=$!

# GPT
if [[ -n "$OPENAI_KEY" ]]; then
  (
    python3 "$WS/scripts/openai-call.py" "$PROMPT_FILE" > "$TMP_B" 2>"$TMP_ERR_B"
  ) &
  PID_B=$!
else
  echo "[parallel-ai] No OPENAI_API_KEY — running Claude only" >&2
  PID_B=""
fi

# Wait for both
wait $PID_A || echo "[parallel-ai] Claude exited non-zero" >&2
if [[ -n "$PID_B" ]]; then
  wait $PID_B || echo "[parallel-ai] GPT exited non-zero" >&2
fi

RESP_A=$(cat "$TMP_A" 2>/dev/null || echo "")
RESP_B=$(cat "$TMP_B" 2>/dev/null || echo "")

echo "[parallel-ai] Claude: ${#RESP_A} chars | GPT: ${#RESP_B} chars" >&2

# ── Supervisor picks winner ───────────────────────────────────────────────────

if [[ -z "$RESP_A" && -z "$RESP_B" ]]; then
  echo "[parallel-ai] Both responses empty — nothing to output" >&2
  exit 1
fi

if [[ -z "$RESP_B" || -z "$OPENAI_KEY" ]]; then
  # No GPT response — use Claude
  echo "[parallel-ai] Using Claude (GPT unavailable)" >&2
  echo "$RESP_A"
  exit 0
fi

if [[ -z "$RESP_A" ]]; then
  # No Claude response — use GPT
  echo "[parallel-ai] Using GPT (Claude unavailable)" >&2
  echo "$RESP_B"
  exit 0
fi

# Both responded — let supervisor decide
echo "[parallel-ai] Both responded — running supervisor..." >&2
echo "$RESP_A" > "$TMP_A"
echo "$RESP_B" > "$TMP_B"

python3 "$WS/scripts/ai-supervisor.py" "$PROMPT_FILE" "$TMP_A" "$TMP_B"
