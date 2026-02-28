#!/usr/bin/env bash
# composite-data-anims.sh — Overlay Blender data animations onto the main video.
# Uses ffmpeg with WebM alpha overlays at correct timestamps.
#
# Usage: composite-data-anims.sh <input.mp4> <manifest.json> <output.mp4>

INPUT_VIDEO="$1"
MANIFEST="$2"
OUTPUT="$3"

if [ -z "$INPUT_VIDEO" ] || [ -z "$MANIFEST" ] || [ -z "$OUTPUT" ]; then
  echo "Usage: $0 <input.mp4> <manifest.json> <output.mp4>"
  exit 1
fi

echo "[composite-data] Video:    $INPUT_VIDEO"
echo "[composite-data] Manifest: $MANIFEST"
echo "[composite-data] Output:   $OUTPUT"

export _CD_INPUT="$INPUT_VIDEO"
export _CD_MANIFEST="$MANIFEST"
export _CD_OUTPUT="$OUTPUT"

python3 - <<'PY'
import json, subprocess, os, sys, shutil

input_video   = os.environ['_CD_INPUT']
manifest_path = os.environ['_CD_MANIFEST']
output        = os.environ['_CD_OUTPUT']

manifest   = json.load(open(manifest_path))
animations = manifest.get('animations', [])

if not animations:
    print("[composite-data] No animations — copying input to output")
    shutil.copy2(input_video, output)
    sys.exit(0)

probe = subprocess.run(
    ['ffprobe', '-v', 'error', '-select_streams', 'v:0',
     '-show_entries', 'stream=width,height', '-of', 'json', input_video],
    capture_output=True, text=True
)
probe_data = json.loads(probe.stdout)
vw = probe_data['streams'][0]['width']
vh = probe_data['streams'][0]['height']
is_vertical = vh > vw

ZONE_POSITIONS = {
    'lower_right':  lambda w, h, aw, ah: (w - aw - int(w*0.03), h - ah - int(h*0.03)),
    'lower_left':   lambda w, h, aw, ah: (int(w*0.03), h - ah - int(h*0.03)),
    'lower_center': lambda w, h, aw, ah: ((w - aw) // 2, h - ah - int(h*0.02)),
    'center_right': lambda w, h, aw, ah: (w - aw - int(w*0.03), (h - ah) // 2),
    'upper_right':  lambda w, h, aw, ah: (w - aw - int(w*0.03), int(h*0.03)),
}

# Use PNG sequences directly (native RGBA alpha, no WebM re-encode quality loss)
# Supports both old format (webm key) and new format (png_pattern key)
valid_anims = []
for anim in animations:
    png_pattern = anim.get('png_pattern', '')
    frames_dir  = anim.get('frames_dir', '')
    webm        = anim.get('webm', '')
    # Determine source: prefer png_pattern, fallback to webm
    if png_pattern and os.path.exists(os.path.dirname(png_pattern)):
        anim['_src_type'] = 'png'
        anim['_src']      = png_pattern
        anim['_fps']      = anim.get('fps', 30)
        valid_anims.append(anim)
    elif webm and os.path.exists(webm):
        anim['_src_type'] = 'webm'
        anim['_src']      = webm
        valid_anims.append(anim)

if not valid_anims:
    shutil.copy2(input_video, output)
    sys.exit(0)

# Build ffmpeg inputs list
# -itsoffset {t_start} before each PNG input shifts frame timestamps so that
# frame 1 of the animation has PTS=t_start, aligning with the enable window.
# Without this the animation plays from t=0 and is already finished by the time
# the overlay is enabled, resulting in a frozen final frame.
inputs  = ['-i', input_video]
filters = []
prev    = '[0:v]'
anim_idx = 1

for anim in valid_anims:
    t_start = anim['timestamp']
    if anim['_src_type'] == 'png':
        inputs += ['-itsoffset', str(t_start), '-framerate', str(anim['_fps']), '-i', anim['_src']]
    else:
        inputs += ['-itsoffset', str(t_start), '-i', anim['_src']]

for i, anim in enumerate(valid_anims):
    t_start  = anim['timestamp']
    duration = anim['duration']
    t_end    = t_start + duration
    position = anim.get('position', 'lower_right')

    # Get overlay dimensions from manifest
    aw = anim.get('width', vw // 3)   # these are SOURCE video dims, not overlay dims
    ah = anim.get('height', vh // 5)
    # Get actual frame size from first PNG
    frames_dir = anim.get('frames_dir', '')
    if frames_dir and os.path.isdir(frames_dir):
        first_frame = sorted(f for f in os.listdir(frames_dir) if f.endswith('.png'))
        if first_frame:
            probe_f = subprocess.run(
                ['ffprobe', '-v', 'error', '-select_streams', 'v:0',
                 '-show_entries', 'stream=width,height', '-of', 'json',
                 os.path.join(frames_dir, first_frame[0])],
                capture_output=True, text=True
            )
            try:
                fd = json.loads(probe_f.stdout)
                aw = fd['streams'][0]['width']
                ah = fd['streams'][0]['height']
            except Exception:
                pass

    max_w = int(vw * (0.40 if is_vertical else 0.30))
    if aw > max_w:
        sf = max_w / aw
        aw = max_w
        ah = int(ah * sf)

    pos_fn = ZONE_POSITIONS.get(position, ZONE_POSITIONS['lower_right'])
    ox, oy = pos_fn(vw, vh, aw, ah)
    ox = max(0, min(ox, vw - aw))
    oy = max(0, min(oy, vh - ah))

    s_lbl = f'sc{i}'
    v_lbl = f'v{i}'

    # Scale only — no setpts reset (itsoffset on input handles the timing offset)
    filters.append(f'[{anim_idx}:v]scale={aw}:{ah}[{s_lbl}]')
    filters.append(
        f"{prev}[{s_lbl}]overlay={ox}:{oy}:enable='between(t,{t_start},{t_end})'"
        f":format=auto[{v_lbl}]"
    )
    prev = f'[{v_lbl}]'
    anim_idx += 1

# Rename last filter output to [vout]
filters[-1] = filters[-1][:-len(f'[{prev[1:-1]}]')] + '[vout]'

cmd = (['ffmpeg', '-y'] + inputs +
       ['-filter_complex', ';'.join(filters),
        '-map', '[vout]', '-map', '0:a?',
        '-c:v', 'libx264', '-preset', 'fast', '-crf', '18', '-pix_fmt', 'yuv420p',
        '-c:a', 'copy', output])

print(f"[composite-data] Compositing {len(valid_anims)} overlay(s) (PNG native alpha)...", flush=True)
r = subprocess.run(cmd, capture_output=True, text=True)
if r.returncode != 0:
    print(f"[composite-data] ffmpeg error:\n{r.stderr[-800:]}", file=sys.stderr)
    shutil.copy2(input_video, output)
    sys.exit(1)

size = os.path.getsize(output) / (1024*1024)
print(f"[composite-data] Done: {output}  ({size:.1f}MB)")
PY
