#!/usr/bin/env bash
set -euo pipefail

# ElevenLabs TTS → Opus (Telegram voice-note friendly)
# Requires:
#   ~/.openclaw/secrets/elevenlabs.env with ELEVENLABS_API_KEY
# Usage:
#   echo "text" | elevenlabs-tts-to-opus.sh --out /Users/henryburton/.openclaw/media/outbound/brief.opus

VOICE_ID="CwhRBWXzGAHq8TQ4Fs17"           # Roger (male)
MODEL_ID="eleven_turbo_v2_5"             # best overall
OUTPUT_FORMAT="mp3_22050_32"

OUT_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_PATH="$2"; shift 2;;
    --voiceId) VOICE_ID="$2"; shift 2;;
    --modelId) MODEL_ID="$2"; shift 2;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

if [[ -z "$OUT_PATH" ]]; then
  echo "Missing --out <path>" >&2
  exit 2
fi

# Load secret
set -a
source "/Users/henryburton/.openclaw/secrets/elevenlabs.env"
set +a

if [[ -z "${ELEVENLABS_API_KEY:-}" ]]; then
  echo "Missing ELEVENLABS_API_KEY" >&2
  exit 2
fi

TEXT="$(cat)"
if [[ -z "$TEXT" ]]; then
  echo "No input text on stdin" >&2
  exit 2
fi

TMP_MP3="/tmp/elevenlabs-$$.mp3"

# JSON encode text safely (use -c flag so stdin is available for sys.stdin.read())
JSON_TEXT=$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$TEXT")

curl -sS -X POST "https://api.elevenlabs.io/v1/text-to-speech/${VOICE_ID}?output_format=${OUTPUT_FORMAT}" \
  -H "xi-api-key: ${ELEVENLABS_API_KEY}" \
  -H 'Content-Type: application/json' \
  -H 'accept: audio/mpeg' \
  -d "{\"text\":${JSON_TEXT},\"model_id\":\"${MODEL_ID}\",\"voice_settings\":{\"stability\":0.35,\"similarity_boost\":0.85,\"style\":0.55,\"use_speaker_boost\":true}}" \
  --output "$TMP_MP3"

mkdir -p "$(dirname "$OUT_PATH")"
ffmpeg -y -i "$TMP_MP3" -c:a libopus -b:a 48k -vbr on "$OUT_PATH" >/dev/null 2>&1
rm -f "$TMP_MP3"
