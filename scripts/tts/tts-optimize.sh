#!/bin/bash
# tts-optimize.sh — Rewrite text for natural spoken delivery using Claude.
#
# Usage:
#   echo "text" | tts-optimize.sh
#   tts-optimize.sh "text"

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
PROMPT_FILE="$WS/prompts/tts-optimize.md"

if [[ ! -f "$PROMPT_FILE" ]]; then
  # No prompt file — pass through unchanged
  if [[ -n "${1:-}" ]]; then echo "$1"; else cat; fi
  exit 0
fi

# Read text from arg or stdin
if [[ -n "${1:-}" ]]; then
  INPUT_TEXT="$1"
else
  INPUT_TEXT=$(cat)
fi

if [[ -z "$INPUT_TEXT" ]]; then
  exit 0
fi

SYSTEM_PROMPT=$(cat "$PROMPT_FILE")

FULL_PROMPT=$(printf '%s\n\n---\n\n%s' "$SYSTEM_PROMPT" "$INPUT_TEXT")

PROMPT_TMP=$(mktemp /tmp/tts-opt-XXXXXX)
printf '%s' "$FULL_PROMPT" > "$PROMPT_TMP"

unset CLAUDECODE
RESULT=$(claude --print --model claude-haiku-4-5-20251001 --dangerously-skip-permissions < "$PROMPT_TMP" 2>/dev/null)
rm -f "$PROMPT_TMP"

if [[ -n "$RESULT" ]]; then
  echo "$RESULT"
else
  # Claude failed — pass through original
  echo "$INPUT_TEXT"
fi
