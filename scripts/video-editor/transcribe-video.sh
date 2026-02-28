#!/usr/bin/env bash
# transcribe-video.sh — Word-level transcription via Deepgram nova-2
# Usage: transcribe-video.sh <input_video.mp4> <output_words.json>
set -euo pipefail

INPUT="$1"
WORDS_JSON="$2"

WORKSPACE="$(cd "$(dirname "$0")/../.." && pwd)"
source "$WORKSPACE/.env.scheduler" 2>/dev/null || true

if [[ -z "${DEEPGRAM_API_KEY:-}" ]]; then
  echo "[transcribe] ERROR: DEEPGRAM_API_KEY not set" >&2
  exit 1
fi

echo "[transcribe] Extracting audio from: $INPUT"

# macOS mktemp requires X's at end — generate name then add extension
_AUDIO_BASE=$(mktemp /tmp/audio-XXXXXX)
AUDIO_TMP="${_AUDIO_BASE}.wav"
mv "$_AUDIO_BASE" "$AUDIO_TMP"
ffmpeg -y -i "$INPUT" -vn -ar 16000 -ac 1 -f wav "$AUDIO_TMP" -loglevel error

echo "[transcribe] Sending to Deepgram nova-2..."

_DG_BASE=$(mktemp /tmp/deepgram-XXXXXX)
RESPONSE_TMP="${_DG_BASE}.json"
mv "$_DG_BASE" "$RESPONSE_TMP"

# keywords boosts recognition of AI brand names and tech jargon (nova-2 syntax)
# Format: keywords=Word:boost (boost 1-10)
KEYWORDS="keywords=ChatGPT:5&keywords=GPT-4:5&keywords=GPT-5:5&keywords=Claude:5&keywords=Anthropic:5&keywords=OpenAI:5&keywords=Gemini:5&keywords=Copilot:5&keywords=Midjourney:5&keywords=Amalfi:5&keywords=LLM:5&keywords=API:3&keywords=prompt:2"

HTTP_CODE=$(curl -s -o "$RESPONSE_TMP" -w "%{http_code}" \
  "https://api.deepgram.com/v1/listen?model=nova-2&punctuate=true&utterances=false&smart_format=true&words=true&${KEYWORDS}" \
  -H "Authorization: Token ${DEEPGRAM_API_KEY}" \
  -H "Content-Type: audio/wav" \
  --data-binary "@${AUDIO_TMP}")

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "[transcribe] Deepgram error (HTTP $HTTP_CODE):" >&2
  cat "$RESPONSE_TMP" >&2
  rm -f "$AUDIO_TMP" "$RESPONSE_TMP"
  exit 1
fi

echo "[transcribe] Parsing word timestamps..."

export _TRANS_RESPONSE="$RESPONSE_TMP"
export _TRANS_OUTPUT="$WORDS_JSON"

python3 <<'PY'
import os, json, sys

response_file = os.environ['_TRANS_RESPONSE']
output_file   = os.environ['_TRANS_OUTPUT']

with open(response_file, 'r') as f:
    data = json.load(f)

try:
    raw_words = data['results']['channels'][0]['alternatives'][0]['words']
except (KeyError, IndexError) as e:
    print(f'[transcribe] ERROR: unexpected Deepgram response structure: {e}', file=sys.stderr)
    print(json.dumps(data, indent=2)[:1000], file=sys.stderr)
    sys.exit(1)

words = [
    {
        'word':  w.get('punctuated_word', w.get('word', '')),
        'start': round(float(w['start']), 3),
        'end':   round(float(w['end']),   3),
    }
    for w in raw_words
    if w.get('word', '').strip()
]

with open(output_file, 'w') as f:
    json.dump(words, f, indent=2)

total_secs = words[-1]['end'] if words else 0
print(f'[transcribe] {len(words)} words, {total_secs:.1f}s total → {output_file}')
PY

rm -f "$AUDIO_TMP" "$RESPONSE_TMP"
echo "[transcribe] Complete"
