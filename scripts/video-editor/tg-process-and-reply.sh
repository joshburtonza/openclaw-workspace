#!/usr/bin/env bash
# tg-process-and-reply.sh — Process a video through the pipeline and send result back to Telegram
# Usage: tg-process-and-reply.sh <chat_id> <video_path> <title>
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

CHAT_ID="$1"
VIDEO_PATH="$2"
TITLE="$3"

WORKSPACE="$(cd "$(dirname "$0")/../.." && pwd)"
source "$WORKSPACE/.env.scheduler" 2>/dev/null || true

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
OUTPUT_FOLDER="${VIDEO_OUTPUT_FOLDER_ID:-}"
OUT_DIR="$WORKSPACE/out/videos"

tg_msg() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" <<< "$1"),\"parse_mode\":\"HTML\"}" \
    >/dev/null 2>&1 || true
}

tg_action() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendChatAction" \
    -d "chat_id=${CHAT_ID}" -d "action=upload_video" >/dev/null 2>&1 || true
}

# ── Acknowledge immediately ───────────────────────────────────────────────────
VIDEO_DURATION=$(ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 "$VIDEO_PATH" 2>/dev/null || echo "?")
if [[ "$VIDEO_DURATION" != "?" ]]; then
  DUR_FMT=$(python3 -c "s=int(float('${VIDEO_DURATION}')); print(f'{s//60}:{s%60:02d}')")
else
  DUR_FMT="?"
fi

tg_msg "Processing: <b>${TITLE}</b> (${DUR_FMT})

Trimming silence, generating captions, rendering...

<i>Usually 2 to 4 minutes.</i>"

# ── Run the full pipeline ─────────────────────────────────────────────────────
BEFORE_COUNT=$(ls "$OUT_DIR"/*.mp4 2>/dev/null | wc -l || echo "0")
PIPELINE_START=$(date +%s)

if ! bash "$WORKSPACE/scripts/video-editor/process-video.sh" "$VIDEO_PATH" "$TITLE"; then
  tg_msg "Pipeline failed for <b>${TITLE}</b>. Check <code>out/video-poller.err.log</code>."
  exit 1
fi

# Find the newest output file
FINAL=$(ls -t "$OUT_DIR"/*.mp4 2>/dev/null | head -1 || true)
if [[ -z "$FINAL" ]]; then
  tg_msg "Pipeline completed but no output file found in <code>out/videos/</code>."
  exit 1
fi

PIPELINE_SECS=$(( $(date +%s) - PIPELINE_START ))
PIPELINE_FMT=$(python3 -c "s=${PIPELINE_SECS}; print(f'{s//60}m {s%60}s')")

# Get final video stats
FINAL_DURATION=$(ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 "$FINAL" 2>/dev/null || echo "0")
FINAL_DUR_FMT=$(python3 -c "s=int(float('${FINAL_DURATION}')); print(f'{s//60}:{s%60:02d}')")
FINAL_SIZE=$(stat -f%z "$FINAL" 2>/dev/null || stat -c%s "$FINAL" 2>/dev/null || echo "0")
FINAL_MB=$(python3 -c "print(f'{${FINAL_SIZE}/1024/1024:.1f}')")

echo "[tg-process-reply] Pipeline done in ${PIPELINE_FMT}: $(basename "$FINAL") (${FINAL_MB}MB)"

# ── Send video back to Telegram ───────────────────────────────────────────────
tg_action
BOT_LIMIT=$((50 * 1024 * 1024))

if (( FINAL_SIZE <= BOT_LIMIT )); then
  echo "[tg-process-reply] Sending video to Telegram..."
  SEND_RESP=$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendVideo" \
    -F "chat_id=${CHAT_ID}" \
    -F "video=@${FINAL}" \
    -F "caption=<b>${TITLE}</b> (${FINAL_DUR_FMT})

Rendered in ${PIPELINE_FMT}" \
    -F "parse_mode=HTML" \
    -F "supports_streaming=true")
  if echo "$SEND_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
    echo "[tg-process-reply] Video sent to Telegram OK"
  else
    echo "[tg-process-reply] Telegram sendVideo failed, sending link instead"
    tg_msg "Video ready: <b>${TITLE}</b> (${FINAL_DUR_FMT})\n\nFile too large for inline send (${FINAL_MB}MB). Check Drive output folder."
  fi
else
  tg_msg "Video ready: <b>${TITLE}</b> (${FINAL_DUR_FMT})\n\nFile is ${FINAL_MB}MB (over 50MB Telegram limit). Uploading to Drive..."
fi

# ── Upload to Drive output folder ─────────────────────────────────────────────
if [[ -n "$OUTPUT_FOLDER" ]]; then
  echo "[tg-process-reply] Uploading to Drive..."
  gog drive upload "$FINAL" --parent "$OUTPUT_FOLDER" >/dev/null 2>&1 && \
    echo "[tg-process-reply] Drive upload OK" || \
    echo "[tg-process-reply] Drive upload failed (non-fatal)"
fi

# Clean up local video download (keep pipeline output in out/videos)
rm -f "$VIDEO_PATH"
echo "[tg-process-reply] Done"
