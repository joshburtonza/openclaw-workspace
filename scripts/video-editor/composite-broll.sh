#!/usr/bin/env bash
# composite-broll.sh — Overlay B-roll clips onto the trimmed talking head video
# Usage: composite-broll.sh <trimmed.mp4> <broll_manifest.json> <output.mp4>
#
# Each clip is overlaid as a picture-in-picture at the correct timestamp.
# position "right"  → right side, vertically centred
# position "left"   → left side, vertically centred
# position "center" → centred overlay
# scale = fraction of video width the B-roll occupies (default 0.55)
# native_size = true → blender_3d clips already at display size (no rescaling)
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

INPUT="$1"
MANIFEST="$2"
OUTPUT="$3"

echo "[composite-broll] Input: $INPUT"
echo "[composite-broll] Manifest: $MANIFEST"

export _CB_INPUT="$INPUT"
export _CB_MANIFEST="$MANIFEST"
export _CB_OUTPUT="$OUTPUT"

python3 <<'PY'
import os, json, subprocess, sys

input_file  = os.environ['_CB_INPUT']
manifest    = os.environ['_CB_MANIFEST']
output_file = os.environ['_CB_OUTPUT']

with open(manifest) as f:
    clips = json.load(f)

if not clips:
    print('[composite-broll] No clips — copying input to output unchanged.')
    import shutil
    shutil.copy2(input_file, output_file)
    sys.exit(0)

# Get video dimensions
probe = subprocess.run(
    ['ffprobe', '-v', 'error', '-select_streams', 'v:0',
     '-show_entries', 'stream=width,height',
     '-of', 'csv=p=0', input_file],
    capture_output=True, text=True
)
dims = probe.stdout.strip().split(',')
vw, vh = int(dims[0]), int(dims[1])
print(f'[composite-broll] Video dimensions: {vw}x{vh}')

# Build FFmpeg filter_complex for all clips
filter_parts = []
current_label = "[0:v]"

for i, clip in enumerate(clips):
    clip_file  = clip['file']
    start      = float(clip['start'])
    end        = float(clip['end'])
    position   = clip.get('position', 'right')
    scale_frac = float(clip.get('scale', 0.55))
    has_alpha  = clip_file.endswith('.mov') or clip_file.endswith('.webm')
    native     = clip.get('native_size', False)

    if native:
        # Blender clips already rendered at display size
        broll_w = clip.get('clip_width',  round(vw * scale_frac))
        broll_h = clip.get('clip_height', round(broll_w * vh / vw))
    else:
        broll_w = round(vw * scale_frac)
        broll_h = round(broll_w * (vh / vw))

    # Positioning
    margin = round(vw * 0.03)
    if position == 'right':
        x = vw - broll_w - margin
        y = f"(main_h-{broll_h})/2"
    elif position == 'left':
        x = margin
        y = f"(main_h-{broll_h})/2"
    else:  # center
        x = f"(main_w-{broll_w})/2"
        y = f"(main_h-{broll_h})/2"

    input_label  = f"[{i+1}:v]"
    scaled_label = f"[broll{i}s]"
    out_label    = f"[v{i}]"

    if has_alpha:
        if native:
            # Already at correct size — just convert pix_fmt
            filter_parts.append(
                f"{input_label}format=yuva420p"
                f"{scaled_label}"
            )
        else:
            # Scale + convert pix_fmt (preserves alpha)
            filter_parts.append(
                f"{input_label}scale={broll_w}:{broll_h},"
                f"format=yuva420p"
                f"{scaled_label}"
            )
    else:
        # H.264 Remotion clip — opaque, add alpha channel (fully opaque)
        filter_parts.append(
            f"{input_label}scale={broll_w}:{broll_h},"
            f"format=yuva420p,"
            f"colorchannelmixer=aa=1"
            f"{scaled_label}"
        )

    # Overlay with enable window
    filter_parts.append(
        f"{current_label}{scaled_label}"
        f"overlay={x}:{y}:"
        f"enable='between(t,{start},{end})':"
        f"format=auto"
        f"{out_label}"
    )
    current_label = out_label

# H.264 requires even pixel dimensions — append final scale step
even_label = "[vfinal]"
filter_parts.append(
    f"{current_label}scale=trunc(iw/2)*2:trunc(ih/2)*2"
    f"{even_label}"
)
current_label = even_label

filter_complex = ";".join(filter_parts)

cmd = ['ffmpeg', '-y']
cmd += ['-i', input_file]
for clip in clips:
    cmd += ['-i', clip['file']]

cmd += [
    '-filter_complex', filter_complex,
    '-map', current_label,
    '-map', '0:a?',       # audio from main video (optional)
    '-c:v', 'libx264',
    '-preset', 'fast',
    '-crf', '18',
    '-c:a', 'copy',
    output_file,
]

print(f'[composite-broll] Compositing {len(clips)} clip(s) onto video...')
result = subprocess.run(cmd, capture_output=True, text=True)
if result.returncode != 0:
    print(f'[composite-broll] FFmpeg failed:\n{result.stderr[-3000:]}', file=sys.stderr)
    sys.exit(1)

print(f'[composite-broll] Done → {output_file}')
PY

echo "[composite-broll] Complete"
