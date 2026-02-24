#!/usr/bin/env bash
set -euo pipefail

# MiniMax TTS → Opus (Telegram voice-note friendly)
# Requires:
#   MINIMAX_API_KEY in .env.scheduler
# Usage:
#   echo "text" | minimax-tts-to-opus.sh --out /path/to/output.opus

VOICE_ID="English_BossyLeader"
MODEL_ID="speech-2.8-hd"
OUT_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)     OUT_PATH="$2"; shift 2;;
    --voiceId) VOICE_ID="$2"; shift 2;;
    --modelId) MODEL_ID="$2"; shift 2;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

if [[ -z "$OUT_PATH" ]]; then
  echo "Missing --out <path>" >&2
  exit 2
fi

source "/Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler"

if [[ -z "${MINIMAX_API_KEY:-}" ]]; then
  echo "Missing MINIMAX_API_KEY" >&2
  exit 2
fi

TEXT="$(cat)"
if [[ -z "$TEXT" ]]; then
  echo "No input text on stdin" >&2
  exit 2
fi

TMP_MP3="/tmp/minimax-$$.mp3"

# Pass vars via env so special characters in text don't break the heredoc
export _MM_API_KEY="$MINIMAX_API_KEY"
export _MM_GROUP_ID="$MINIMAX_GROUP_ID"
export _MM_TEXT="$TEXT"
export _MM_VOICE="$VOICE_ID"
export _MM_MODEL="$MODEL_ID"
export _MM_OUT="$TMP_MP3"

python3 - <<'PYEOF'
import json, urllib.request, os, sys

api_key  = os.environ['_MM_API_KEY']
group_id = os.environ['_MM_GROUP_ID']
text     = os.environ['_MM_TEXT']
voice_id = os.environ['_MM_VOICE']
model_id = os.environ['_MM_MODEL']
out_path = os.environ['_MM_OUT']

payload = {
    "model": model_id,
    "text": text,
    "stream": False,
    "voice_setting": {
        "voice_id": voice_id,
        "speed": 1.0,
        "vol": 1.0,
        "pitch": 0
    },
    "audio_setting": {
        "sample_rate": 32000,
        "bitrate": 128000,
        "format": "mp3",
        "channel": 1
    }
}

req = urllib.request.Request(
    "https://api.minimax.io/v1/t2a_v2?GroupId=" + group_id,
    data=json.dumps(payload).encode(),
    headers={
        "Authorization": "Bearer " + api_key,
        "Content-Type": "application/json"
    },
    method="POST"
)

with urllib.request.urlopen(req, timeout=30) as resp:
    result = json.loads(resp.read())

status = result.get("base_resp", {}).get("status_code", -1)
if status != 0:
    msg = result.get("base_resp", {}).get("status_msg", "unknown error")
    print("MiniMax API error: " + str(status) + " " + msg, file=sys.stderr)
    sys.exit(1)

audio_hex = result.get("data", {}).get("audio", "")
if not audio_hex:
    print("MiniMax returned empty audio", file=sys.stderr)
    sys.exit(1)

with open(out_path, "wb") as f:
    f.write(bytes.fromhex(audio_hex))
PYEOF

mkdir -p "$(dirname "$OUT_PATH")"
ffmpeg -y -i "$TMP_MP3" -c:a libopus -b:a 48k -vbr on "$OUT_PATH" >/dev/null 2>&1
rm -f "$TMP_MP3"
