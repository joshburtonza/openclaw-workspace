#!/usr/bin/env python3
"""
eevee-wrap.py — Inject EEVEE fast preview settings into any Blender script
Turns a 20s Cycles render into a 2-3s EEVEE preview.

Usage:
  python3 eevee-wrap.py <blender_script.py> [--frames /tmp/preview] [--open]

Example:
  python3 eevee-wrap.py /tmp/clawbot_v2.py --open
"""
import sys, os, subprocess, tempfile, argparse
from pathlib import Path

EEVEE_INJECT = '''
# ── EEVEE FAST PREVIEW (injected by eevee-wrap.py) ──────────────────────────
import bpy as _bpy
_s = _bpy.context.scene
_s.render.engine = 'BLENDER_EEVEE'
try:
    _s.eevee.taa_render_samples   = 16
    _s.eevee.use_gtao              = True
    _s.eevee.use_bloom             = True
    _s.eevee.use_ssr               = False
    _s.eevee.shadow_cube_size      = '512'
    _s.eevee.shadow_cascade_size   = '512'
except Exception:
    pass
_s.render.resolution_x = 600
_s.render.resolution_y = 600
# ── END EEVEE INJECT ──────────────────────────────────────────────────────────
'''

def wrap_and_run(script_path, frames_dir=None, open_result=False):
    src = Path(script_path).read_text()

    # Inject EEVEE block right after the engine line (or after imports)
    inject_after = 'scene.render.engine'
    if inject_after in src:
        lines = src.split('\n')
        out_lines = []
        injected = False
        for line in lines:
            out_lines.append(line)
            if not injected and inject_after in line:
                out_lines.append(EEVEE_INJECT)
                injected = True
        if not injected:
            out_lines.insert(5, EEVEE_INJECT)
        modified = '\n'.join(out_lines)
    else:
        modified = EEVEE_INJECT + '\n' + src

    # Override output dir if specified
    if frames_dir:
        os.makedirs(frames_dir, exist_ok=True)
        modified = modified.replace(
            "os.environ.get('_BL_FRAMES_DIR'",
            f"os.environ.get('_BL_FRAMES_DIR_OVERRIDE_IGNORE'"
        )
        modified = f"import os\nos.environ['_BL_FRAMES_DIR'] = '{frames_dir}'\n" + modified

    # Write to temp file
    tmp = tempfile.NamedTemporaryFile(suffix='_eevee_preview.py', delete=False, mode='w')
    tmp.write(modified)
    tmp.close()

    preview_dir = frames_dir or f'/tmp/eevee_preview_{Path(script_path).stem}'
    os.makedirs(preview_dir, exist_ok=True)

    env = os.environ.copy()
    env['_BL_FRAMES_DIR'] = preview_dir

    print(f"[eevee-wrap] Running EEVEE preview for: {script_path}")
    print(f"[eevee-wrap] Output dir: {preview_dir}")

    result = subprocess.run(
        ['/Applications/Blender.app/Contents/MacOS/Blender', '--background', '--python', tmp.name],
        env=env, capture_output=True, text=True
    )

    os.unlink(tmp.name)

    # Find rendered frames
    frames = sorted(Path(preview_dir).glob('frame_*.png'))
    if frames:
        print(f"[eevee-wrap] Rendered {len(frames)} frame(s)")
        print(f"[eevee-wrap] Latest: {frames[-1]}")
        if open_result:
            subprocess.Popen(['open', str(frames[-1])])
    else:
        print("[eevee-wrap] No frames found. stderr:")
        print(result.stderr[-2000:] if result.stderr else "(no stderr)")

    return frames

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('script', help='Blender Python script to preview')
    parser.add_argument('--frames', help='Output directory for preview frames')
    parser.add_argument('--open', action='store_true', help='Open result in Preview.app')
    args = parser.parse_args()
    wrap_and_run(args.script, args.frames, args.open)
