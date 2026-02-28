#!/usr/bin/env bash
# render-broll.sh — Render individual B-roll clips from broll-specs.json
# Usage: render-broll.sh <broll_specs.json> <video_width> <video_height> <output_dir>
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

BROLL_JSON="$1"
VIDEO_WIDTH="$2"
VIDEO_HEIGHT="$3"
OUTPUT_DIR="$4"

WORKSPACE="$(cd "$(dirname "$0")/../.." && pwd)"
REMOTION_DIR="$WORKSPACE/remotion-pipeline"
PUBLIC_DIR="$REMOTION_DIR/public"
RENDER_BLENDER="$WORKSPACE/scripts/video-editor/render-blender.sh"

mkdir -p "$OUTPUT_DIR"

echo "[render-broll] Reading specs from $BROLL_JSON"

export _RB_BROLL_JSON="$BROLL_JSON"
export _RB_VIDEO_WIDTH="$VIDEO_WIDTH"
export _RB_VIDEO_HEIGHT="$VIDEO_HEIGHT"
export _RB_OUTPUT_DIR="$OUTPUT_DIR"
export _RB_REMOTION_DIR="$REMOTION_DIR"
export _RB_PUBLIC_DIR="$PUBLIC_DIR"
export _RB_RENDER_BLENDER="$RENDER_BLENDER"

python3 <<'PY'
import os, json, subprocess, sys, tempfile

broll_json      = os.environ['_RB_BROLL_JSON']
video_width     = int(os.environ['_RB_VIDEO_WIDTH'])
video_height    = int(os.environ['_RB_VIDEO_HEIGHT'])
output_dir      = os.environ['_RB_OUTPUT_DIR']
remotion_dir    = os.environ['_RB_REMOTION_DIR']
public_dir      = os.environ['_RB_PUBLIC_DIR']
render_blender  = os.environ['_RB_RENDER_BLENDER']

with open(broll_json) as f:
    specs = json.load(f)

clips = specs.get('clips', [])
if not clips:
    print('[render-broll] No clips to render.')
    sys.exit(0)

print(f'[render-broll] Rendering {len(clips)} B-roll clip(s)...')

rendered = []

for i, clip in enumerate(clips):
    clip_type  = clip['type']
    clip_props = clip.get('props', {})
    start      = clip['start']
    end        = clip['end']
    duration   = end - start
    fps        = 30
    duration_frames = max(1, round(duration * fps))

    # Determine clip canvas dimensions
    # Remotion clips: render at full video size (compositing script scales/positions)
    # Blender clips: render at actual display size (avoids expensive full-res render)
    scale_frac  = float(clip.get('scale', 0.55))
    if clip_type == 'blender_3d':
        # Render at the display size so Blender doesn't waste time on off-screen pixels
        clip_width  = max(320, round(video_width * scale_frac))
        clip_height = round(clip_width * video_height / video_width)
    else:
        clip_width  = video_width
        clip_height = video_height

    # Build the full props object for BrollComposition / render-blender
    full_props = {
        'type': clip_type,
        'props': clip_props,
        'width': clip_width,
        'height': clip_height,
        'durationFrames': duration_frames,
        'fps': fps,
    }

    output_clip = os.path.join(output_dir, f'broll-{i:02d}.mp4')

    # Write clip spec to temp file
    _tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.json',
                                       prefix='/tmp/broll-props-', delete=False)
    json.dump(full_props, _tmp)
    _tmp.close()

    print(f'[render-broll] Clip {i}: {clip_type} ({duration:.1f}s, {duration_frames} frames)')

    # ── Route: blender_3d → Blender; everything else → Remotion ──────────────
    if clip_type == 'blender_3d':
        print(f'[render-broll]   → Blender render: {clip_props.get("blender_type","text_3d")}')
        result = subprocess.run(
            ['bash', render_blender, _tmp.name, output_clip],
            capture_output=True, text=True, timeout=600
        )
        os.unlink(_tmp.name)
        if result.returncode != 0:
            print(f'[render-broll] Blender render failed for clip {i}:\n{result.stderr[-2000:]}', file=sys.stderr)
            sys.exit(1)
        # render-blender.sh writes the actual output path (may be .webm) to a .blpath file
        blpath_file = output_clip + '.blpath'
        if os.path.exists(blpath_file):
            with open(blpath_file) as fp:
                actual_output = fp.read().strip()
            os.unlink(blpath_file)
        else:
            actual_output = output_clip.replace('.mp4', '.webm')
        print(f'[render-broll]   → {actual_output}')
    else:
        # Remotion render
        cmd = [
            'npx', 'remotion', 'render',
            'src/broll/BrollRoot.tsx',
            'BrollClip',
            f'--props={_tmp.name}',
            f'--output={output_clip}',
            '--codec=h264',
            '--jpeg-quality=92',
            '--concurrency=2',
            '--log=error',
        ]
        result = subprocess.run(cmd, cwd=remotion_dir, capture_output=True, text=True)
        os.unlink(_tmp.name)
        if result.returncode != 0:
            print(f'[render-broll] Remotion failed for clip {i}:\n{result.stderr[-2000:]}', file=sys.stderr)
            sys.exit(1)
        actual_output = output_clip
        print(f'[render-broll]   → {actual_output}')

    rendered.append({
        'index': i,
        'file': actual_output,
        'start': start,
        'end': end,
        'position': clip.get('position', 'right'),
        'scale': clip.get('scale', 0.55),
        'type': clip_type,
        # blender_3d clips are already at display size — skip rescaling in composite step
        'native_size': clip_type == 'blender_3d',
        'clip_width': clip_width,
        'clip_height': clip_height,
    })

# Write manifest for composite step
manifest_path = os.path.join(output_dir, 'broll-manifest.json')
with open(manifest_path, 'w') as f:
    json.dump(rendered, f, indent=2)

print(f'[render-broll] Done — manifest: {manifest_path}')
PY

echo "[render-broll] All clips rendered → $OUTPUT_DIR"
