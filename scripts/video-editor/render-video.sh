#!/usr/bin/env bash
# render-video.sh — Render TalkingHead composition via Remotion
# Usage: render-video.sh <props_json_file> <output_mp4>
set -euo pipefail

PROPS_FILE="$1"
OUTPUT="$2"

WORKSPACE="$(cd "$(dirname "$0")/../.." && pwd)"
REMOTION_DIR="$WORKSPACE/remotion-pipeline"
PUBLIC_DIR="$REMOTION_DIR/public"

mkdir -p "$PUBLIC_DIR"

if [[ ! -d "$REMOTION_DIR/node_modules" ]]; then
  echo "[render] Installing Remotion dependencies..."
  cd "$REMOTION_DIR" && npm install --silent
fi

# Remotion cannot serve arbitrary filesystem paths — copy trimmed video into public/
# so it's accessible as a static asset during render.
VIDEO_SRC=$(python3 -c "import json; p=json.load(open('$PROPS_FILE')); print(p.get('videoSrc',''))")
RENDER_TIMESTAMP=$(date +%s)
PUBLIC_VIDEO="$PUBLIC_DIR/video-${RENDER_TIMESTAMP}.mp4"

if [[ -n "$VIDEO_SRC" ]] && [[ -f "$VIDEO_SRC" ]]; then
  echo "[render] Copying video to public/: $(basename "$PUBLIC_VIDEO")"
  cp "$VIDEO_SRC" "$PUBLIC_VIDEO"
  # Update props JSON to use just the filename (Remotion serves public/ at root)
  UPDATED_PROPS=$(python3 -c "
import json, os
p = json.load(open('$PROPS_FILE'))
p['videoSrc'] = 'video-${RENDER_TIMESTAMP}.mp4'
print(json.dumps(p))
")
  PROPS_TMP_BASE=$(mktemp /tmp/remotion-props-XXXXXX)
  PROPS_TMP="${PROPS_TMP_BASE}.json"
  mv "$PROPS_TMP_BASE" "$PROPS_TMP"
  echo "$UPDATED_PROPS" > "$PROPS_TMP"
else
  echo "[render] No videoSrc or file not found, rendering with original props"
  PROPS_TMP="$PROPS_FILE"
fi

echo "[render] Rendering TalkingHead composition..."
echo "[render] Output: $OUTPUT"

cd "$REMOTION_DIR"
npx remotion render src/index.ts TalkingHead \
  --props="$PROPS_TMP" \
  --output="$OUTPUT" \
  --codec=h264 \
  --jpeg-quality=95 \
  --log=verbose \
  --concurrency=4

RENDER_EXIT=$?

# Clean up public video copy
rm -f "$PUBLIC_VIDEO"
[[ "$PROPS_TMP" != "$PROPS_FILE" ]] && rm -f "$PROPS_TMP"

if [[ $RENDER_EXIT -ne 0 ]]; then
  echo "[render] Remotion render failed" >&2
  exit 1
fi

echo "[render] Complete: $OUTPUT"
