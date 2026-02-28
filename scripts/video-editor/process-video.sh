#!/usr/bin/env bash
# process-video.sh — Full talking head pipeline orchestrator
# Usage: process-video.sh <input.mp4> <title>
set -euo pipefail

VIDEO_PATH="$1"
TITLE="${2:-Untitled Video}"

WORKSPACE="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS_DIR="$WORKSPACE/scripts/video-editor"
OUT_DIR="$WORKSPACE/out/videos"
TMP_DIR="$WORKSPACE/tmp/video-queue"

source "$WORKSPACE/.env.scheduler" 2>/dev/null || true

mkdir -p "$OUT_DIR" "$TMP_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BASENAME=$(basename "$VIDEO_PATH" .mp4)
WORK_DIR="$TMP_DIR/${TIMESTAMP}-${BASENAME}"
mkdir -p "$WORK_DIR"

TRIMMED="$WORK_DIR/trimmed.mp4"
SEGMENTS_JSON="$WORK_DIR/segments.json"
WORDS_JSON="$WORK_DIR/words.json"
PROPS_JSON="$WORK_DIR/props.json"
RENDERED="$WORK_DIR/rendered.mp4"
BROLL_JSON="$WORK_DIR/broll-specs.json"
BROLL_DIR="$WORK_DIR/broll-clips"
BROLL_MANIFEST="$BROLL_DIR/broll-manifest.json"
COMPOSITED="$WORK_DIR/composited.mp4"
DATA_MENTIONS_JSON="$WORK_DIR/data-mentions.json"
DATA_ANIMS_DIR="$WORK_DIR/data-anims"
DATA_ANIMS_MANIFEST="$DATA_ANIMS_DIR/data-anim-manifest.json"
DATA_COMPOSITED="$WORK_DIR/data-composited.mp4"
FINAL="$OUT_DIR/${TIMESTAMP}-$(echo "$TITLE" | tr ' ' '-' | tr '[:upper:]' '[:lower:]').mp4"

echo "[process-video] ============================================"
echo "[process-video] Title: $TITLE"
echo "[process-video] Input: $VIDEO_PATH"
echo "[process-video] Work dir: $WORK_DIR"

# ── Step 1: Detect dimensions ────────────────────────────────────────────────
echo "[process-video] Step 1: Detecting dimensions..."

WIDTH=$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=width -of csv=p=0 "$VIDEO_PATH")
HEIGHT=$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=height -of csv=p=0 "$VIDEO_PATH")
FPS_RAW=$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=r_frame_rate -of csv=p=0 "$VIDEO_PATH")

# Convert fractional fps like 30000/1001 to integer
FPS=$(python3 -c "
from fractions import Fraction
fps = float(Fraction('${FPS_RAW}'))
print(int(round(fps)))
")

echo "[process-video] Dimensions: ${WIDTH}x${HEIGHT} @ ${FPS}fps"
if (( HEIGHT > WIDTH )); then
  echo "[process-video] Mode: vertical (9:16)"
else
  echo "[process-video] Mode: horizontal (16:9)"
fi

# ── Step 2: Silence trimming ────────────────────────────────────────────────
echo "[process-video] Step 2: Trimming silence..."
bash "$SCRIPTS_DIR/trim-silence.sh" "$VIDEO_PATH" "$TRIMMED" "$SEGMENTS_JSON"

# ── Step 3: Transcription ────────────────────────────────────────────────────
echo "[process-video] Step 3: Transcribing audio..."
bash "$SCRIPTS_DIR/transcribe-video.sh" "$TRIMMED" "$WORDS_JSON"

# ── Step 3b: B-roll spec generation ─────────────────────────────────────────
echo "[process-video] Step 3b: Generating B-roll specs..."
bash "$SCRIPTS_DIR/generate-broll-specs.sh" "$WORDS_JSON" "$TITLE" "$BROLL_JSON" || {
  echo "[process-video] B-roll spec generation failed — continuing without B-roll"
  echo '{"clips":[]}' > "$BROLL_JSON"
}

# ── Step 4: Build props JSON ─────────────────────────────────────────────────
echo "[process-video] Step 4: Building render props..."

export _PROC_TRIMMED="$TRIMMED"
export _PROC_SEGMENTS="$SEGMENTS_JSON"
export _PROC_WORDS="$WORDS_JSON"
export _PROC_TITLE="$TITLE"
export _PROC_FPS="$FPS"
export _PROC_WIDTH="$WIDTH"
export _PROC_HEIGHT="$HEIGHT"
export _PROC_PROPS="$PROPS_JSON"

python3 <<'PY'
import os, json

props = {
    'videoSrc':  os.environ['_PROC_TRIMMED'],
    'title':     os.environ['_PROC_TITLE'],
    'fps':       int(os.environ['_PROC_FPS']),
    'width':     int(os.environ['_PROC_WIDTH']),
    'height':    int(os.environ['_PROC_HEIGHT']),
    'segments':  json.load(open(os.environ['_PROC_SEGMENTS'])),
    'words':     json.load(open(os.environ['_PROC_WORDS'])),
}

with open(os.environ['_PROC_PROPS'], 'w') as f:
    json.dump(props, f, indent=2)

print(f"[process-video] Props: {len(props['segments'])} segments, {len(props['words'])} words")
PY

# ── Step 5: Remotion render ──────────────────────────────────────────────────
echo "[process-video] Step 5: Rendering with Remotion..."
bash "$SCRIPTS_DIR/render-video.sh" "$PROPS_JSON" "$RENDERED"

# ── Step 5b: Detect data mentions + render Blender animations ─────────────────
echo "[process-video] Step 5b: Detecting data mentions in transcript..."
bash "$SCRIPTS_DIR/detect-data-mentions.sh" "$WORDS_JSON" "$TITLE" "$DATA_MENTIONS_JSON" || {
  echo "[process-video] Data detection failed — skipping data animations"
  echo '{"mentions":[]}' > "$DATA_MENTIONS_JSON"
}

DATA_MENTION_COUNT=$(python3 -c "import json; d=json.load(open('$DATA_MENTIONS_JSON')); print(len(d.get('mentions',[])))")
echo "[process-video] Found $DATA_MENTION_COUNT data mention(s)"

if [[ "$DATA_MENTION_COUNT" -gt 0 ]]; then
  echo "[process-video] Step 5b.2: Rendering $DATA_MENTION_COUNT Blender data animation(s)..."
  bash "$SCRIPTS_DIR/render-data-anims.sh" "$DATA_MENTIONS_JSON" "$WIDTH" "$HEIGHT" "$DATA_ANIMS_DIR" || {
    echo "[process-video] Data anim render failed — skipping data overlays"
    DATA_MENTION_COUNT=0
  }
fi

# ── Step 5c: Render B-roll clips ─────────────────────────────────────────────
BROLL_CLIP_COUNT=$(python3 -c "import json; d=json.load(open('$BROLL_JSON')); print(len(d.get('clips',[])))")
if [[ "$BROLL_CLIP_COUNT" -gt 0 ]]; then
  echo "[process-video] Step 5b: Rendering $BROLL_CLIP_COUNT B-roll clip(s)..."
  bash "$SCRIPTS_DIR/render-broll.sh" "$BROLL_JSON" "$WIDTH" "$HEIGHT" "$BROLL_DIR" || {
    echo "[process-video] B-roll render failed — skipping B-roll compositing"
    BROLL_CLIP_COUNT=0
  }
fi

# ── Step 5c: Composite B-roll onto rendered video ────────────────────────────
if [[ "$BROLL_CLIP_COUNT" -gt 0 ]] && [[ -f "$BROLL_MANIFEST" ]]; then
  echo "[process-video] Step 5c: Compositing B-roll..."
  bash "$SCRIPTS_DIR/composite-broll.sh" "$RENDERED" "$BROLL_MANIFEST" "$COMPOSITED" || {
    echo "[process-video] Composite failed — using plain rendered video"
    cp "$RENDERED" "$COMPOSITED"
  }
else
  echo "[process-video] Step 5c: No B-roll — skipping composite"
  cp "$RENDERED" "$COMPOSITED"
fi

# ── Step 5e: Composite data animations onto video ─────────────────────────────
if [[ "$DATA_MENTION_COUNT" -gt 0 ]] && [[ -f "$DATA_ANIMS_MANIFEST" ]]; then
  echo "[process-video] Step 5e: Compositing data animations..."
  bash "$SCRIPTS_DIR/composite-data-anims.sh" "$COMPOSITED" "$DATA_ANIMS_MANIFEST" "$DATA_COMPOSITED" || {
    echo "[process-video] Data composite failed — using video without data overlays"
    cp "$COMPOSITED" "$DATA_COMPOSITED"
  }
else
  echo "[process-video] Step 5e: No data animations — skipping"
  cp "$COMPOSITED" "$DATA_COMPOSITED"
fi

# ── Step 6: Final encode (audio normalization) ───────────────────────────────
echo "[process-video] Step 6: Final encode with audio normalization..."
ffmpeg -y -i "$DATA_COMPOSITED" \
  -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p \
  -c:a aac -b:a 192k \
  -af "loudnorm=I=-14:LRA=11:TP=-1.5" \
  "$FINAL" \
  -loglevel error

echo "[process-video] Final output: $FINAL"

# ── Step 7: Get duration ─────────────────────────────────────────────────────
DURATION_SECS=$(ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 "$FINAL")
DURATION_FMT=$(python3 -c "
s = int(float('${DURATION_SECS}'))
print(f'{s//60}:{s%60:02d}')
")

# ── Step 8: Telegram notification ────────────────────────────────────────────
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  CHAT_ID="${TELEGRAM_CHAT_ID:-1140320036}"
  MSG="Video ready: ${TITLE} (${DURATION_FMT})"
  MSG+=$'\n\n'
  MSG+="$(basename "$FINAL")"
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${CHAT_ID}" \
    --data-urlencode "text=${MSG}" \
    -d "parse_mode=HTML" >/dev/null
  echo "[process-video] Telegram notification sent"
fi

# ── Step 9: Supabase audit log ───────────────────────────────────────────────
if [[ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
  SUPABASE_URL="${SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
  curl -s -X POST "${SUPABASE_URL}/rest/v1/audit_log" \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"event\":\"video_processed\",\"details\":{\"title\":\"${TITLE}\",\"file\":\"$(basename "$FINAL")\",\"duration\":\"${DURATION_FMT}\",\"width\":${WIDTH},\"height\":${HEIGHT}}}" \
    >/dev/null 2>&1 || true
fi

echo "[process-video] ============================================"
echo "[process-video] Done. Output: $FINAL"
