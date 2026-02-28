#!/usr/bin/env bash
# render-data-anims.sh — Render all Blender data animations from data_mentions.json
# Usage: render-data-anims.sh <data_mentions.json> <video_width> <video_height> <out_dir>

MENTIONS_JSON="$1"
WIDTH="${2:-1080}"
HEIGHT="${3:-1920}"
OUT_DIR="${4:-/tmp/data-anims}"

WORKSPACE="$(cd "$(dirname "$0")/../.." && pwd)"
BT_DIR="$WORKSPACE/scripts/blender-tools"
BLENDER="/Applications/Blender.app/Contents/MacOS/Blender"

mkdir -p "$OUT_DIR"

N=$(python3 -c "import json; d=json.load(open('$MENTIONS_JSON')); print(len(d.get('mentions',[])))")
echo "[render-data-anims] Rendering $N data animations → $OUT_DIR"

python3 - <<PY
import json, subprocess, os, sys

mentions_json  = "$MENTIONS_JSON"
out_dir        = "$OUT_DIR"
width          = int("$WIDTH")
height         = int("$HEIGHT")
bt_dir         = "$BT_DIR"
blender        = "$BLENDER"

mentions = json.load(open(mentions_json)).get("mentions", [])

manifest = []  # track output files for compositing

for i, mention in enumerate(mentions):
    t_start  = mention.get("overlay_start", 0)
    duration = mention.get("overlay_duration", 3.0)
    anim_type = mention.get("type", "counter")
    position  = mention.get("position", "lower_right")

    slug      = f"{i:02d}_{anim_type}_{int(t_start*10):04d}"
    frames_dir  = os.path.join(out_dir, f"frames_{slug}")
    script_path = os.path.join(out_dir, f"script_{slug}.py")
    webm_path   = os.path.join(out_dir, f"anim_{slug}.webm")

    os.makedirs(frames_dir, exist_ok=True)

    print(f"[{i+1}/{len(mentions)}] {anim_type} @ {t_start:.1f}s  →  {webm_path}", flush=True)

    # Generate Blender script
    gen_result = subprocess.run(
        ["python3", os.path.join(bt_dir, "gen-data-anim.py"),
         json.dumps(mention), str(width), str(height), script_path, frames_dir],
        capture_output=True, text=True
    )
    if gen_result.returncode != 0:
        print(f"  ERROR generating script: {gen_result.stderr[-300:]}", file=sys.stderr)
        continue
    print(f"  Script generated", flush=True)

    # Run Blender
    env = os.environ.copy()
    env["_BL_FRAMES_DIR"] = frames_dir
    bl_result = subprocess.run(
        [blender, "--background", "--python", script_path],
        capture_output=True, text=True, env=env
    )
    if "DONE" not in bl_result.stdout:
        print(f"  WARNING: Blender may have failed:\n{bl_result.stderr[-500:]}", file=sys.stderr)

    # Check frames
    frames = sorted([f for f in os.listdir(frames_dir) if f.endswith('.png')])
    if not frames:
        print(f"  ERROR: No frames rendered for {slug}", file=sys.stderr)
        continue
    print(f"  Rendered {len(frames)} frames", flush=True)

    # PNG sequence pattern for compositor (no WebM re-encode — preserves RGBA alpha natively)
    png_pattern = os.path.join(frames_dir, "frame_%04d.png")
    fps = 30

    manifest.append({
        "index":      i,
        "type":       anim_type,
        "position":   position,
        "timestamp":  t_start,
        "duration":   duration,
        "png_pattern": png_pattern,
        "fps":        fps,
        "frames_dir": frames_dir,
        "frames":     len(frames),
        "width":      width,
        "height":     height,
    })
    print(f"  PNG frames: {frames_dir}  ({len(frames)} frames @ {fps}fps)", flush=True)

manifest_path = os.path.join(out_dir, "data-anim-manifest.json")
with open(manifest_path, "w") as f:
    json.dump({"animations": manifest}, f, indent=2)
print(f"\n[render-data-anims] Manifest: {manifest_path}  ({len(manifest)} animations)")
PY
