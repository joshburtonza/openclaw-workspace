#!/usr/bin/env python3
"""
compare-renders.py — Side-by-side and overlay comparison of reference vs render
Outputs: side-by-side PNG, overlay PNG, diff heatmap PNG

Usage:
  python3 compare-renders.py <reference> <render> [--out /tmp/compare.png]

Example:
  python3 compare-renders.py ~/ref.jpg /tmp/clawbot2/frame_0001.png --out /tmp/compare.png
"""
import sys, argparse
from pathlib import Path
from PIL import Image, ImageDraw, ImageChops, ImageEnhance
import numpy as np

def add_label(img, text, position='top', color=(255,255,255), bg=(0,0,0,160)):
    """Add a text label to an image."""
    from PIL import ImageFont
    out = img.convert('RGBA')
    overlay = Image.new('RGBA', out.size, (0,0,0,0))
    draw = ImageDraw.Draw(overlay)
    font_size = max(14, out.width // 25)
    try:
        font = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', font_size)
    except Exception:
        font = ImageFont.load_default()
    bbox = draw.textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    pad = 8
    if position == 'top':
        box = (0, 0, out.width, th + pad * 2)
        tx, ty = (out.width - tw) // 2, pad
    else:
        box = (0, out.height - th - pad * 2, out.width, out.height)
        tx, ty = (out.width - tw) // 2, out.height - th - pad
    draw.rectangle(box, fill=bg)
    draw.text((tx, ty), text, fill=color, font=font)
    return Image.alpha_composite(out, overlay).convert('RGB')

def make_comparison(ref_path, render_path, out_path=None):
    ref    = Image.open(ref_path).convert('RGB')
    render = Image.open(render_path).convert('RGB')

    # Resize render to match reference height (keep aspect)
    target_h = ref.height
    rw = int(render.width * target_h / render.height)
    render_r = render.resize((rw, target_h), Image.LANCZOS)

    # Resize ref to same width as render for fair comparison
    target_w = min(ref.width, rw)
    ref_r = ref.resize((target_w, target_h), Image.LANCZOS)
    render_r = render_r.resize((target_w, target_h), Image.LANCZOS)

    out_base = out_path or f'/tmp/compare_{Path(ref_path).stem}_vs_{Path(render_path).stem}'

    # ── 1. Side-by-side ──────────────────────────────────────────────────────
    gap = 4
    side = Image.new('RGB', (target_w * 2 + gap, target_h), (40, 40, 40))
    side.paste(ref_r, (0, 0))
    side.paste(render_r, (target_w + gap, 0))
    side = add_label(side, f'REFERENCE: {Path(ref_path).name}', 'top', color=(255,220,50))
    # label right side
    right_half = side.crop((target_w + gap, 0, target_w * 2 + gap, target_h))
    right_half = add_label(right_half, f'RENDER: {Path(render_path).name}', 'top', color=(100,200,255))
    side.paste(right_half, (target_w + gap, 0))
    side_path = out_base + '_sidebyside.png'
    side.save(side_path)

    # ── 2. Overlay (50% blend) ────────────────────────────────────────────────
    overlay = Image.blend(ref_r, render_r, alpha=0.5)
    overlay = add_label(overlay, f'OVERLAY 50/50 — {Path(ref_path).name} vs {Path(render_path).name}', 'top')
    overlay_path = out_base + '_overlay.png'
    overlay.save(overlay_path)

    # ── 3. Difference heatmap ────────────────────────────────────────────────
    ref_arr = np.array(ref_r).astype(float)
    ren_arr = np.array(render_r).astype(float)
    diff = np.abs(ref_arr - ren_arr).mean(axis=2)  # mean channel diff
    # Normalize and colorize
    diff_norm = (diff / diff.max() * 255).astype(np.uint8)
    # Red = high diff, blue = low diff
    heatmap = np.stack([diff_norm, np.zeros_like(diff_norm), 255 - diff_norm], axis=2)
    heatmap_img = Image.fromarray(heatmap.astype(np.uint8))
    heatmap_img = add_label(heatmap_img, f'DIFF HEATMAP (red=large diff, blue=match)', 'top')
    diff_path = out_base + '_diff.png'
    heatmap_img.save(diff_path)

    # ── 4. Summary stats ─────────────────────────────────────────────────────
    mean_diff = diff.mean()
    max_diff  = diff.max()
    match_pct = round((1 - mean_diff / 255) * 100, 1)

    print(f"\n{'='*55}")
    print(f"COMPARISON: {Path(ref_path).name} vs {Path(render_path).name}")
    print(f"{'='*55}")
    print(f"  Image size:    {target_w}x{target_h}")
    print(f"  Mean diff:     {mean_diff:.1f}/255  ({100 - match_pct:.1f}% different)")
    print(f"  Max diff:      {max_diff:.0f}/255")
    print(f"  Similarity:    {match_pct}%")
    print(f"\nOutputs:")
    print(f"  Side-by-side:  {side_path}")
    print(f"  Overlay 50/50: {overlay_path}")
    print(f"  Diff heatmap:  {diff_path}")

    return {'side_by_side': side_path, 'overlay': overlay_path, 'diff': diff_path,
            'similarity_pct': match_pct, 'mean_diff': mean_diff}

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('reference', help='Reference image path')
    parser.add_argument('render', help='Render image path')
    parser.add_argument('--out', help='Output path prefix (no extension)')
    args = parser.parse_args()
    make_comparison(args.reference, args.render, args.out)
