#!/usr/bin/env bash
# make-video.sh — Convert PNG frame sequence to MP4 and GIF
# Usage: ./make-video.sh <frames_dir> [fps] [output_base]
#
# Examples:
#   ./make-video.sh /tmp/clawbot2-anim 24
#   ./make-video.sh /tmp/clawbot2-anim 24 /tmp/clawbot_final

FRAMES_DIR="$1"
FPS="${2:-24}"
OUT_BASE="${3:-${FRAMES_DIR}/output}"

if [ -z "$FRAMES_DIR" ] || [ ! -d "$FRAMES_DIR" ]; then
  echo "Usage: $0 <frames_dir> [fps] [output_base]"
  exit 1
fi

# Count frames
N=$(ls "$FRAMES_DIR"/frame_*.png 2>/dev/null | wc -l | tr -d ' ')
echo "[make-video] Frames: $N  FPS: $FPS  Dir: $FRAMES_DIR"

# ── MP4 (H264, high quality) ──────────────────────────────────────────────────
MP4="${OUT_BASE}.mp4"
ffmpeg -y -framerate "$FPS" -i "${FRAMES_DIR}/frame_%04d.png" \
  -c:v libx264 -pix_fmt yuv420p -crf 16 -movflags +faststart \
  -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
  "$MP4" 2>&1 | grep -E "frame=|fps=|size=|time=|^ffmpeg" | tail -5
echo "[make-video] MP4: $MP4 ($(du -sh "$MP4" 2>/dev/null | cut -f1))"

# ── WebM (VP9, for web) ───────────────────────────────────────────────────────
WEBM="${OUT_BASE}.webm"
ffmpeg -y -framerate "$FPS" -i "${FRAMES_DIR}/frame_%04d.png" \
  -c:v libvpx-vp9 -crf 30 -b:v 0 -pix_fmt yuva420p \
  "$WEBM" 2>&1 | tail -2
echo "[make-video] WebM: $WEBM ($(du -sh "$WEBM" 2>/dev/null | cut -f1))"

# ── GIF (palette-optimized) ───────────────────────────────────────────────────
GIF="${OUT_BASE}.gif"
PALETTE="/tmp/palette_$$.png"
# Generate optimal palette
ffmpeg -y -framerate "$FPS" -i "${FRAMES_DIR}/frame_%04d.png" \
  -vf "fps=$FPS,scale=400:-1:flags=lanczos,palettegen=stats_mode=diff" \
  "$PALETTE" 2>/dev/null
# Apply palette
ffmpeg -y -framerate "$FPS" -i "${FRAMES_DIR}/frame_%04d.png" \
  -i "$PALETTE" \
  -filter_complex "fps=$FPS,scale=400:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
  "$GIF" 2>/dev/null
rm -f "$PALETTE"
echo "[make-video] GIF:  $GIF  ($(du -sh "$GIF" 2>/dev/null | cut -f1))"

# ── Telegram-optimized (640px, AAC if audio) ──────────────────────────────────
TG_MP4="${OUT_BASE}_telegram.mp4"
ffmpeg -y -framerate "$FPS" -i "${FRAMES_DIR}/frame_%04d.png" \
  -c:v libx264 -pix_fmt yuv420p -crf 18 -movflags +faststart \
  -vf "scale=min(640\,iw):-2" \
  "$TG_MP4" 2>&1 | tail -2
echo "[make-video] TG:   $TG_MP4 ($(du -sh "$TG_MP4" 2>/dev/null | cut -f1))"

echo ""
echo "[make-video] Done. Duration: $(python3 -c "print(f'{$N/$FPS:.1f}s  ({$N} frames @ {$FPS}fps)')")"
