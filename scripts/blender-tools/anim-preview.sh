#!/usr/bin/env bash
# anim-preview.sh — Render only key frames of an animation + stitch contact sheet
# Usage: ./anim-preview.sh <blender_script.py> [frames "1 12 24 36 48"] [--open]
#
# Example:
#   ./anim-preview.sh /tmp/clawbot_v2_anim.py
#   ./anim-preview.sh /tmp/clawbot_v2_anim.py "1 10 20 30 40 48"

SCRIPT="$1"
FRAMES="${2:-1 12 24 36 48}"
OPEN_FLAG="${3:-}"

if [ -z "$SCRIPT" ]; then
  echo "Usage: $0 <blender_script.py> [\"1 12 24 36 48\"] [--open]"
  exit 1
fi

PREVIEW_DIR="/tmp/anim_preview_$(basename ${SCRIPT%.py})"
mkdir -p "$PREVIEW_DIR"

BLENDER=/Applications/Blender.app/Contents/MacOS/Blender
BT_DIR="$(dirname "$0")"

echo "[anim-preview] Script:  $SCRIPT"
echo "[anim-preview] Frames:  $FRAMES"
echo "[anim-preview] Out dir: $PREVIEW_DIR"

# Render each specified frame
for F in $FRAMES; do
  echo "[anim-preview] Rendering frame $F..."
  export _BL_FRAMES_DIR="$PREVIEW_DIR"

  # Use EEVEE for speed
  python3 "$BT_DIR/eevee-wrap.py" "$SCRIPT" --frames "$PREVIEW_DIR" 2>/dev/null

  # Only render the first frame for the preview pass (we override frame range)
  # Actually just render full EEVEE pass but only check the frames we want
  break
done

# If we have full EEVEE render, build contact sheet from the key frames
CONTACT="/tmp/anim_contact_$(basename ${SCRIPT%.py}).png"
FRAME_FILES=""
for F in $FRAMES; do
  PADDED=$(printf "%04d" $F)
  FP="$PREVIEW_DIR/frame_${PADDED}.png"
  if [ -f "$FP" ]; then
    FRAME_FILES="$FRAME_FILES $FP"
  fi
done

if [ -n "$FRAME_FILES" ]; then
  # Use Python/PIL to stitch contact sheet
  python3 - <<PYEOF
from PIL import Image
import sys

files = "$FRAME_FILES".split()
images = [Image.open(f) for f in files]
w, h = images[0].size
pad = 4
total_w = w * len(images) + pad * (len(images) - 1)
sheet = Image.new('RGB', (total_w, h), (20, 20, 20))
for i, im in enumerate(images):
    sheet.paste(im, (i * (w + pad), 0))
sheet.save("$CONTACT")
print(f"Contact sheet: $CONTACT ({len(images)} frames)")
PYEOF
fi

echo "[anim-preview] Done."
[ "$OPEN_FLAG" = "--open" ] && open "$CONTACT" 2>/dev/null || true
