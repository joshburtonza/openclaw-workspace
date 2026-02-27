#!/bin/bash
# openai-tts.sh — OpenAI TTS (gpt-4o-mini-tts, nova voice)
#
# Usage:
#   openai-tts.sh "Text to speak" /output/path.opus
#   echo "Text" | openai-tts.sh --out /output/path.opus

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ENV_FILE="/Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

OPENAI_KEY="${OPENAI_API_KEY:-}"

if [[ -z "$OPENAI_KEY" ]]; then
  echo "[openai-tts] OPENAI_API_KEY not set" >&2
  exit 1
fi

# Parse args: positional or --out flag (stdin mode)
TEXT=""
OUTPUT=""

if [[ "${1:-}" == "--out" ]]; then
  OUTPUT="${2:-/tmp/openai-tts.opus}"
  TEXT=$(cat)
else
  TEXT="${1:-}"
  OUTPUT="${2:-/tmp/openai-tts.opus}"
fi

if [[ -z "$TEXT" ]]; then
  echo "[openai-tts] no text provided" >&2
  exit 1
fi

# Optimize text for natural spoken delivery via Claude
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPTIMIZED=$(bash "$SCRIPT_DIR/tts-optimize.sh" "$TEXT" 2>/dev/null)
if [[ -n "$OPTIMIZED" ]]; then
  TEXT="$OPTIMIZED"
fi

# Request opus directly — no ffmpeg needed
HTTP_STATUS=$(curl -sf \
  "https://api.openai.com/v1/audio/speech" \
  -H "Authorization: Bearer $OPENAI_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"gpt-4o-mini-tts\",
    \"input\": $(echo "$TEXT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))'),
    \"voice\": \"nova\",
    \"response_format\": \"opus\"
  }" \
  -o "$OUTPUT" \
  -w "%{http_code}" 2>/dev/null)

if [[ "$HTTP_STATUS" != "200" ]]; then
  echo "[openai-tts] API error (HTTP $HTTP_STATUS)" >&2
  rm -f "$OUTPUT"
  exit 1
fi

echo "[openai-tts] saved to $OUTPUT"
