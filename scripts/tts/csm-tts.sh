#!/bin/bash
# csm-tts.sh — Sesame CSM-1B TTS via HF Space API
# Drop-in replacement for minimax-tts-to-opus.sh
#
# Usage: csm-tts.sh "Text to speak" /output/path.opus [conversational|read_speech]
#
# Falls back to minimax-tts-to-opus.sh if CSM fails.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ENV_FILE="/Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEXT="${1:-}"
OUTPUT="${2:-/tmp/csm-output.opus}"
VOICE="${3:-conversational}"

if [[ -z "$TEXT" ]]; then
  echo "Usage: csm-tts.sh <text> <output> [voice]" >&2
  exit 1
fi

python3 "$SCRIPT_DIR/csm-tts.py" "$TEXT" "$OUTPUT" "$VOICE"
STATUS=$?

if [[ $STATUS -ne 0 ]]; then
  echo "[csm-tts] CSM failed (exit $STATUS), falling back to MiniMax" >&2
  bash "$SCRIPT_DIR/minimax-tts-to-opus.sh" "$TEXT" "$OUTPUT"
fi
