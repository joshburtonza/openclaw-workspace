#!/usr/bin/env bash
# tg-blender-from-image.sh <chat_id> <image_path> <caption>
# Sends an image to Claude vision, generates a Blender 5.0 Python scene,
# renders it headless, and returns the result to Telegram.

set -euo pipefail

CHAT_ID="${1:?Usage: tg-blender-from-image.sh <chat_id> <image_path> <caption>}"
IMAGE_PATH="${2:?Usage: tg-blender-from-image.sh <chat_id> <image_path> <caption>}"
CAPTION="${3:-}"

# ── Load environment ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$WS_ROOT/.env.scheduler"

if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN not set in .env.scheduler}"

TIMESTAMP="$(date +%s)"
LOG="$WS_ROOT/out/blender-from-image.log"
ERR_LOG="$WS_ROOT/out/blender-from-image.err.log"

mkdir -p "$WS_ROOT/out"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }
log "Starting tg-blender-from-image for chat_id=$CHAT_ID image=$IMAGE_PATH caption=$CAPTION"

# ── Helper: send Telegram text message ───────────────────────────────────────
tg_send() {
    local text="$1"
    local payload
    payload="$(python3 -c "import json,sys; print(json.dumps({'chat_id': int(sys.argv[1]), 'text': sys.argv[2], 'parse_mode': 'HTML'}))" "$CHAT_ID" "$text")"
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$payload" >> "$LOG" 2>&1 || true
}

# ── Helper: send Telegram photo ───────────────────────────────────────────────
tg_send_photo() {
    local photo_path="$1"
    local cap="$2"
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendPhoto" \
        -F "chat_id=$CHAT_ID" \
        -F "photo=@${photo_path}" \
        -F "caption=${cap}" >> "$LOG" 2>&1 || true
}

# ── Announce ──────────────────────────────────────────────────────────────────
tg_send "Got it! Analysing image and generating 3D scene..."

BLENDER_SCRIPT_PATH="/tmp/bl-from-image-${TIMESTAMP}.py"

# ── Write the interpretation extractor Python script to a temp file ───────────
INTERPRET_PY="/tmp/bl-interpret-${TIMESTAMP}.py"
cat > "$INTERPRET_PY" << 'PYEOF'
import sys

with open(sys.argv[1]) as fh:
    lines = fh.read().split('\n')

comments = []
for line in lines[:10]:
    stripped = line.strip()
    if stripped.startswith('#'):
        comments.append(stripped.lstrip('#').strip())
    elif comments:
        break

if comments:
    print(' '.join(comments[:3]))
else:
    print('A 3D Blender scene based on your image.')
PYEOF

# ── Call Claude vision via claude CLI ────────────────────────────────────────
log "Calling Claude vision..."

PROMPT_FILE="/tmp/bl-prompt-${TIMESTAMP}.txt"
export _BL_IMAGE_PATH="$IMAGE_PATH"
export _BL_CAPTION="$CAPTION"
export _BL_PROMPT_FILE="$PROMPT_FILE"

# Build prompt — use @filepath so claude CLI actually reads the image
cat > "$PROMPT_FILE" << PROMPTEOF
Look at this image: @${IMAGE_PATH}

The user's request: "${CAPTION}"

You are a Blender 3D artist. Write a complete Blender 5.0 Python script that creates a 3D scene faithfully recreating or inspired by what you see in the image above.

Requirements (follow exactly):
- import bpy, math, mathutils, os
- bpy.ops.wm.read_factory_settings(use_empty=True)
- scene = bpy.context.scene; scene.frame_start=1; scene.frame_end=1
- scene.render.engine = 'CYCLES'; scene.cycles.samples=16; scene.cycles.use_denoising=False
- Metal GPU in try/except: prefs=bpy.context.preferences.addons['cycles'].preferences; prefs.compute_device_type='METAL'; prefs.get_devices(); [setattr(d,'use',True) for d in prefs.devices]; scene.cycles.device='GPU'
- scene.render.film_transparent=True; scene.render.resolution_x=756; scene.render.resolution_y=756
- scene.render.image_settings.file_format='PNG'; scene.render.image_settings.color_mode='RGBA'
- frames_dir=os.environ.get('_BL_FRAMES_DIR','/tmp/blender-from-image'); scene.render.filepath=os.path.join(frames_dir,'frame_')
- Emission materials only: create mat, use mat.node_tree.nodes/links, add ShaderNodeEmission + ShaderNodeOutputMaterial, do NOT assign mat.use_nodes
- Add perspective camera with 50mm lens pointing at scene center
- Build detailed 3D objects representing what you see
- End with: bpy.ops.render.render(animation=True)

Start with a # comment block describing what you see. Return ONLY the Python script, no markdown fences.
PROMPTEOF

CLAUDE_OUTPUT=$(env -u CLAUDECODE claude --print --model claude-sonnet-4-6 --dangerously-skip-permissions < "$PROMPT_FILE" 2>> "$ERR_LOG")

# Strip markdown fences if present
CLAUDE_OUTPUT=$(echo "$CLAUDE_OUTPUT" | python3 -c "
import sys
txt = sys.stdin.read().strip()
if txt.startswith('\`\`\`'):
    lines = txt.split('\n')
    txt = '\n'.join(lines[1:])
if txt.endswith('\`\`\`'):
    txt = txt[:-3].rstrip()
print(txt)
")

if [[ -z "$CLAUDE_OUTPUT" ]]; then
    log "ERROR: Claude returned empty output"
    tg_send "Failed to generate Blender script: Claude returned no output."
    exit 1
fi

log "Claude generated Blender script (${#CLAUDE_OUTPUT} chars). Saving to $BLENDER_SCRIPT_PATH"
printf '%s\n' "$CLAUDE_OUTPUT" > "$BLENDER_SCRIPT_PATH"

# ── Extract what Claude interpreted from comments at top of script ─────────────
INTERPRETATION="$(python3 "$INTERPRET_PY" "$BLENDER_SCRIPT_PATH" 2>/dev/null || echo "A 3D Blender scene based on your image.")"

# ── Set up output directory and run Blender headless ─────────────────────────
FRAMES_DIR="/tmp/blender-from-image-${TIMESTAMP}"
mkdir -p "$FRAMES_DIR"

export _BL_FRAMES_DIR="$FRAMES_DIR"
export _BL_TIMESTAMP="$TIMESTAMP"

log "Running Blender headless with script $BLENDER_SCRIPT_PATH..."
tg_send "Rendering 3D scene with Blender (this takes 1 to 2 minutes)..."

BLENDER_BIN="/Applications/Blender.app/Contents/MacOS/Blender"

if [[ ! -x "$BLENDER_BIN" ]]; then
    log "ERROR: Blender not found at $BLENDER_BIN"
    tg_send "Blender is not installed at /Applications/Blender.app. Cannot render."
    exit 1
fi

"$BLENDER_BIN" --background --python "$BLENDER_SCRIPT_PATH" \
    >> "$LOG" 2>> "$ERR_LOG" || {
    log "ERROR: Blender exited non-zero. Check $ERR_LOG"
    tg_send "Blender render failed. Check logs for details."
    exit 1
}

# ── Find rendered PNG ─────────────────────────────────────────────────────────
FRAME_PNG="${FRAMES_DIR}/frame_0001.png"

if [[ ! -f "$FRAME_PNG" ]]; then
    log "ERROR: Expected frame not found at $FRAME_PNG. Directory contents:"
    ls "$FRAMES_DIR" >> "$LOG" 2>&1 || true
    tg_send "Blender rendered but the output frame was not found. Check logs."
    exit 1
fi

log "Frame rendered: $FRAME_PNG"

# ── Convert PNG to JPEG for Telegram ─────────────────────────────────────────
RESULT_JPG="/tmp/bl-from-image-result-${TIMESTAMP}.jpg"

ffmpeg -y -i "$FRAME_PNG" -q:v 2 "$RESULT_JPG" >> "$LOG" 2>> "$ERR_LOG" || {
    log "ERROR: ffmpeg conversion failed"
    tg_send "Render succeeded but JPEG conversion failed. Check logs."
    exit 1
}

log "JPEG ready: $RESULT_JPG"

# ── Send result back to Telegram ──────────────────────────────────────────────
PHOTO_CAPTION="3D render complete.

$INTERPRETATION"

tg_send_photo "$RESULT_JPG" "$PHOTO_CAPTION"
log "Photo sent to chat_id=$CHAT_ID. Done."
