#!/usr/bin/env bash
# tg-analyse-video.sh — Watch a video, analyse editing techniques, report back
# Usage: tg-analyse-video.sh <chat_id> <video_path> [caption]
#
# Extracts frames + audio transcript, sends to Claude for analysis,
# replies with a structured breakdown of editing techniques.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

CHAT_ID="$1"
VIDEO_PATH="$2"
CAPTION="${3:-}"

WORKSPACE="$(cd "$(dirname "$0")/../.." && pwd)"
source "$WORKSPACE/.env.scheduler" 2>/dev/null || true

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
DEEPGRAM_KEY="${DEEPGRAM_API_KEY:-}"
ANTHROPIC_KEY="${ANTHROPIC_API_KEY:-}"

tg_send() {
  local text="$1"
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(echo "$text" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),\"parse_mode\":\"HTML\"}" \
    >/dev/null 2>&1 || true
}

tg_typing() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendChatAction" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"action\":\"typing\"}" >/dev/null 2>&1 || true
}

echo "[analyse-video] Starting analysis of: $VIDEO_PATH"
tg_send "👁 Watching... extracting frames + transcribing audio."
tg_typing

# ── Probe video ───────────────────────────────────────────────────────────────
DURATION=$(ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 "$VIDEO_PATH" 2>/dev/null || echo "0")
DURATION_INT=$(python3 -c "print(int(float('${DURATION}')))")
WIDTH=$(ffprobe -v error -select_streams v:0 -show_entries stream=width \
  -of csv=p=0 "$VIDEO_PATH" 2>/dev/null || echo "0")
HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height \
  -of csv=p=0 "$VIDEO_PATH" 2>/dev/null || echo "0")
FPS_RAW=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
  -of csv=p=0 "$VIDEO_PATH" 2>/dev/null || echo "30/1")

echo "[analyse-video] ${DURATION_INT}s, ${WIDTH}x${HEIGHT}"

# ── Extract frames ────────────────────────────────────────────────────────────
# Target ~16 frames max, spaced evenly across the video
FRAME_DIR=$(mktemp -d /tmp/analyse-frames-XXXXXX)
MAX_FRAMES=16

if [[ "$DURATION_INT" -le 0 ]]; then
  DURATION_INT=30
fi

# Interval: spread MAX_FRAMES across duration, minimum 1 frame every 2s
INTERVAL=$(python3 -c "
d = $DURATION_INT
n = min($MAX_FRAMES, max(1, d // 2))
print(max(1, d // n))
")

echo "[analyse-video] Extracting frames every ${INTERVAL}s..."
ffmpeg -y -i "$VIDEO_PATH" \
  -vf "fps=1/${INTERVAL},scale=480:-2" \
  -q:v 3 \
  "$FRAME_DIR/frame_%04d.jpg" \
  -loglevel error 2>/dev/null || true

FRAME_COUNT=$(ls "$FRAME_DIR"/frame_*.jpg 2>/dev/null | wc -l | tr -d ' ')
echo "[analyse-video] Extracted $FRAME_COUNT frames"

# ── Transcribe audio ──────────────────────────────────────────────────────────
TRANSCRIPT=""
if [[ -n "$DEEPGRAM_KEY" ]]; then
  echo "[analyse-video] Transcribing audio..."
  _AUDIO_BASE=$(mktemp /tmp/analyse-audio-XXXXXX)
  AUDIO_TMP="${_AUDIO_BASE}.wav"
  mv "$_AUDIO_BASE" "$AUDIO_TMP"

  ffmpeg -y -i "$VIDEO_PATH" -vn -ar 16000 -ac 1 -f wav "$AUDIO_TMP" \
    -loglevel error 2>/dev/null || true

  if [[ -f "$AUDIO_TMP" && -s "$AUDIO_TMP" ]]; then
    DG_RESP=$(curl -s -X POST \
      "https://api.deepgram.com/v1/listen?model=nova-2&punctuate=true&smart_format=true" \
      -H "Authorization: Token ${DEEPGRAM_KEY}" \
      -H "Content-Type: audio/wav" \
      --data-binary @"$AUDIO_TMP" 2>/dev/null || echo "{}")
    TRANSCRIPT=$(echo "$DG_RESP" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    t = d['results']['channels'][0]['alternatives'][0]['transcript']
    print(t[:3000])
except:
    print('')
" 2>/dev/null || true)
  fi
  rm -f "$AUDIO_TMP" 2>/dev/null || true
fi

echo "[analyse-video] Transcript: ${#TRANSCRIPT} chars"

# ── Build Claude API request with frames + transcript ─────────────────────────
export _AV_FRAME_DIR="$FRAME_DIR"
export _AV_TRANSCRIPT="$TRANSCRIPT"
export _AV_CAPTION="$CAPTION"
export _AV_DURATION="$DURATION_INT"
export _AV_WIDTH="$WIDTH"
export _AV_HEIGHT="$HEIGHT"
export _AV_ANTHROPIC_KEY="$ANTHROPIC_KEY"
export _AV_CHAT_ID="$CHAT_ID"
export _AV_BOT_TOKEN="$BOT_TOKEN"

python3 <<'PY'
import os, json, base64, glob, subprocess, sys

frame_dir     = os.environ['_AV_FRAME_DIR']
transcript    = os.environ['_AV_TRANSCRIPT']
caption       = os.environ['_AV_CAPTION']
duration      = int(os.environ['_AV_DURATION'])
width         = os.environ['_AV_WIDTH']
height        = os.environ['_AV_HEIGHT']
anthropic_key = os.environ.get('_AV_ANTHROPIC_KEY', '')
chat_id       = os.environ['_AV_CHAT_ID']
bot_token     = os.environ['_AV_BOT_TOKEN']

frame_files = sorted(glob.glob(f"{frame_dir}/frame_*.jpg"))

caption_note = f'\n\nJosh\'s note: "{caption}"' if caption else ""

analysis_prompt = f"""You are analysing {len(frame_files)} video frames from a {duration}s, {width}x{height} video, sampled evenly across the full duration. Each frame path is listed below in order.{caption_note}

FRAMES (in chronological order):
{chr(10).join(f'  ~{round(i * duration / max(len(frame_files),1))}s: {fp}' for i, fp in enumerate(frame_files))}

{f"AUDIO TRANSCRIPT:{chr(10)}{transcript}" if transcript else "No transcript available."}

Analyse this video and give me a detailed breakdown as a video editor and motion designer. Focus on:

1. **CAPTION / TEXT STYLE** — font weight, size, position on frame, animation style (pop, slide, fade?), highlight colour for active word, shadow/glow, max words per line
2. **TRANSITIONS** — how scenes cut or dissolve, any zoom/push/spin transitions
3. **B-ROLL USAGE** — what kinds of B-roll are shown, when, how long, position (left/right/overlay), scale vs main footage
4. **MOTION GRAPHICS** — any lower thirds, stat cards, charts, phone mockups, terminal windows, tweet cards — describe exact style
5. **PACING** — cuts per minute estimate, rhythm, energy level
6. **COLOUR GRADE** — overall look (warm/cool/neutral), contrast, cinematic grade
7. **AUDIO** — music presence, sound effects, voice quality, audio ducking
8. **HOOKS / OPENING** — how does the video open? Title card? Cut straight in? Jump cut?
9. **WHAT TO STEAL** — 3 specific techniques to implement in my own videos right away

Be specific and technical. Describe exact behaviours (spring entry, scale, timing). This analysis directly improves our Remotion B-roll system.
"""

import tempfile, urllib.request
tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.txt', prefix='/tmp/analyse-prompt-', delete=False)
tmp.write(analysis_prompt)
tmp.close()

env = os.environ.copy()
env.pop('CLAUDECODE', None)

# Use claude CLI which supports image file reading natively
result = subprocess.run(
    ['claude', '--print', '--model', 'claude-sonnet-4-6', '--dangerously-skip-permissions'],
    stdin=open(tmp.name),
    capture_output=True, text=True, env=env, timeout=120
)
os.unlink(tmp.name)

if result.returncode == 0 and result.stdout.strip():
    analysis = result.stdout.strip()
else:
    print(f"[analyse-video] claude CLI failed: {result.stderr[:300]}", file=sys.stderr)
    analysis = "Analysis failed. Check the logs."

# Send back to Telegram (split if needed)
def tg_send(text):
    payload = json.dumps({
        "chat_id": chat_id,
        "text": text,
        "parse_mode": "HTML",
    }).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{bot_token}/sendMessage",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    try:
        urllib.request.urlopen(req, timeout=15)
    except Exception:
        pass

# Format and chunk
intro = f"<b>Video Analysis</b> — {duration}s, {width}x{height}\n\n"
full = intro + analysis

# Split into 4000-char chunks on paragraph breaks
chunks = []
current = ""
for para in full.split("\n\n"):
    if len(current) + len(para) + 2 > 3800:
        if current:
            chunks.append(current.strip())
        current = para
    else:
        current += ("\n\n" if current else "") + para
if current:
    chunks.append(current.strip())

for chunk in chunks:
    tg_send(chunk)

print(f"[analyse-video] Sent {len(chunks)} message(s) to Telegram")
PY

# ── Save analysis to reference library ───────────────────────────────────────
# Future: save structured learnings to workspace/memory/video-references/
REF_DIR="$WORKSPACE/memory/video-references"
mkdir -p "$REF_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
echo "=== $TIMESTAMP ===" >> "$REF_DIR/analyses.log"
echo "File: $VIDEO_PATH" >> "$REF_DIR/analyses.log"
echo "Caption: $CAPTION" >> "$REF_DIR/analyses.log"
echo "" >> "$REF_DIR/analyses.log"

# Cleanup frames
rm -rf "$FRAME_DIR" 2>/dev/null || true

echo "[analyse-video] Done"
