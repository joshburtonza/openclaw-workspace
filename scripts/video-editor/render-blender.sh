#!/usr/bin/env bash
# render-blender.sh — Render a blender_3d B-roll clip via Blender headless
# Usage: render-blender.sh <clip_spec_json> <output_file>
#   clip_spec_json : JSON object {type, props, durationFrames, fps, width, height}
#   output_file    : path ending in .webm (VP9 with alpha transparency)
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

CLIP_SPEC_JSON="$1"
OUTPUT_FILE="$2"

WORKSPACE="$(cd "$(dirname "$0")/../.." && pwd)"
SCENES_DIR="$WORKSPACE/scripts/video-editor/blender_scenes"
BLENDER="/Applications/Blender.app/Contents/MacOS/Blender"

if [[ ! -x "$BLENDER" ]]; then
  echo "[render-blender] Blender not found at $BLENDER" >&2
  exit 1
fi

export _BL_SPEC_FILE="$CLIP_SPEC_JSON"
export _BL_OUTPUT="$OUTPUT_FILE"
export _BL_SCENES_DIR="$SCENES_DIR"
export _BL_BLENDER="$BLENDER"

python3 <<'PY'
import os, json, subprocess, sys, tempfile, glob, shutil

spec_file  = os.environ['_BL_SPEC_FILE']
output_mp4 = os.environ['_BL_OUTPUT']
scenes_dir = os.environ['_BL_SCENES_DIR']
blender    = os.environ['_BL_BLENDER']

with open(spec_file) as f:
    spec = json.load(f)

# blender_3d clips carry a sub-type in props.blender_type (or fall back to "text_3d")
props           = spec.get('props', {})
blender_type    = props.get('blender_type', 'text_3d')
duration_frames = spec.get('durationFrames', 90)
fps             = spec.get('fps', 30)
width           = spec.get('width', 1080)
height          = spec.get('height', 1920)

SCENE_SCRIPTS = {
    'text_3d':        'text_3d.py',
    'particle_burst': 'particle_burst.py',
}

scene_script = os.path.join(scenes_dir, SCENE_SCRIPTS.get(blender_type, 'text_3d.py'))
if not os.path.exists(scene_script):
    print(f'[render-blender] Scene script not found: {scene_script}', file=sys.stderr)
    sys.exit(1)

# Temp dir for PNG frames
frames_dir = tempfile.mkdtemp(prefix='/tmp/blender-frames-')

# Env vars passed into the Blender Python scene
blender_env = os.environ.copy()
blender_env['_BL_PROPS']            = json.dumps(props)
blender_env['_BL_DURATION_FRAMES']  = str(duration_frames)
blender_env['_BL_FPS']              = str(fps)
blender_env['_BL_WIDTH']            = str(width)
blender_env['_BL_HEIGHT']           = str(height)
blender_env['_BL_FRAMES_DIR']       = frames_dir

print(f'[render-blender] {blender_type}: {duration_frames} frames @ {fps}fps ({width}x{height})')
print(f'[render-blender] Frames dir: {frames_dir}')

# Run Blender headless
result = subprocess.run(
    [blender, '--background', '--python', scene_script],
    env=blender_env,
    capture_output=True, text=True, timeout=600
)

if result.returncode != 0:
    print(f'[render-blender] Blender failed (rc={result.returncode}):', file=sys.stderr)
    # Show last 30 lines of stderr (Blender is very verbose)
    stderr_lines = result.stderr.strip().splitlines()
    print('\n'.join(stderr_lines[-30:]), file=sys.stderr)
    shutil.rmtree(frames_dir, ignore_errors=True)
    sys.exit(1)

# Verify frames were produced
frames = sorted(glob.glob(os.path.join(frames_dir, 'frame_*.png')))
print(f'[render-blender] {len(frames)} PNG frames produced')
if not frames:
    print('[render-blender] No frames found! Check Blender render path.', file=sys.stderr)
    shutil.rmtree(frames_dir, ignore_errors=True)
    sys.exit(1)

# ── Convert PNG sequence → WebM (VP9 with alpha) ─────────────────────────────
# VP9 WebM is the only widely-supported format with transparency that FFmpeg
# can use as an overlay input while preserving alpha channel.
# Use ProRes 4444 for alpha-preserving output — widely supported by FFmpeg overlay
# Frame files are named frame_0001.png ... frame_NNNN.png (Blender starts at 1)
output_mov = output_mp4.replace('.mp4', '.mov') if output_mp4.endswith('.mp4') else output_mp4 + '.mov'

ffmpeg_cmd = [
    'ffmpeg', '-y',
    '-framerate', str(fps),
    '-start_number', '1',
    '-i', os.path.join(frames_dir, 'frame_%04d.png'),
    '-c:v', 'prores_ks',
    '-profile:v', '4444',
    '-pix_fmt', 'yuva444p10le',
    output_mov,
    '-loglevel', 'error',
]

ff = subprocess.run(ffmpeg_cmd, capture_output=True, text=True)
if ff.returncode != 0:
    print(f'[render-blender] FFmpeg ProRes failed: {ff.stderr}', file=sys.stderr)
    shutil.rmtree(frames_dir, ignore_errors=True)
    sys.exit(1)

shutil.rmtree(frames_dir, ignore_errors=True)
print(f'[render-blender] Done → {output_mov}')

# Write the actual output path so render-broll.sh can read it
with open(output_mp4 + '.blpath', 'w') as fp:
    fp.write(output_mov)
PY

echo "[render-blender] Complete"
