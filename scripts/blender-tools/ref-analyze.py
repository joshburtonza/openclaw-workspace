#!/usr/bin/env python3
"""
ref-analyze.py — Reference image analyzer for Blender work
Extracts proportions, colors, and blob measurements from a reference image.
Output: JSON + visual annotated image

Usage:
  python3 ref-analyze.py <image_path> [--out /tmp/ref_analysis.json] [--vis]

Example:
  python3 ref-analyze.py ~/Desktop/clawbot.jpg --vis
"""
import sys, json, argparse, math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import numpy as np

def dominant_colors(arr, n=6):
    """K-means dominant colors from pixel array."""
    pixels = arr.reshape(-1, 3).astype(float)
    # Simple k-means
    np.random.seed(42)
    idx = np.random.choice(len(pixels), n, replace=False)
    centers = pixels[idx]
    for _ in range(20):
        dists = np.linalg.norm(pixels[:, None] - centers[None], axis=2)
        labels = dists.argmin(axis=1)
        new_centers = np.array([pixels[labels == k].mean(axis=0) if (labels == k).any() else centers[k] for k in range(n)])
        if np.allclose(centers, new_centers, atol=1): break
        centers = new_centers
    counts = [(labels == k).sum() for k in range(n)]
    sorted_colors = sorted(zip(counts, centers.tolist()), reverse=True)
    return [{'rgb': [int(c) for c in col], 'hex': '#{:02x}{:02x}{:02x}'.format(*[int(c) for c in col]), 'pct': round(cnt / len(pixels) * 100, 1)} for cnt, col in sorted_colors]

def find_color_blobs(img_arr, target_rgb, tolerance=60):
    """Find bounding box of pixels near a target color."""
    diff = np.abs(img_arr.astype(float) - np.array(target_rgb))
    mask = diff.max(axis=2) < tolerance
    rows = np.any(mask, axis=1)
    cols = np.any(mask, axis=0)
    if not rows.any():
        return None
    rmin, rmax = np.where(rows)[0][[0, -1]]
    cmin, cmax = np.where(cols)[0][[0, -1]]
    area = mask.sum()
    return {
        'x_min': int(cmin), 'x_max': int(cmax),
        'y_min': int(rmin), 'y_max': int(rmax),
        'width_px': int(cmax - cmin),
        'height_px': int(rmax - rmin),
        'center_x_px': int((cmin + cmax) // 2),
        'center_y_px': int((rmin + rmax) // 2),
        'area_px': int(area),
    }

def pixel_to_ratio(val, img_size):
    return round(val / img_size, 4)

def analyze(image_path, visualize=False, out_path=None):
    img = Image.open(image_path).convert('RGB')
    W, H = img.size
    arr = np.array(img)

    result = {
        'image': str(image_path),
        'size': {'width': W, 'height': H},
        'dominant_colors': dominant_colors(arr),
        'blobs': {},
        'proportions': {},
        'sample_points': {},
    }

    # ── Sample pixels at grid positions (useful for color picking) ────────────
    grid = {}
    for name, (rx, ry) in {
        'center':       (0.50, 0.50),
        'top_center':   (0.50, 0.15),
        'bottom_center':(0.50, 0.85),
        'left_center':  (0.15, 0.50),
        'right_center': (0.85, 0.50),
        'eye_left':     (0.35, 0.38),
        'eye_right':    (0.65, 0.38),
        'arm_left':     (0.12, 0.52),
        'arm_right':    (0.88, 0.52),
        'leg_left':     (0.38, 0.82),
        'leg_right':    (0.62, 0.82),
        'antenna_left': (0.35, 0.08),
        'antenna_right':(0.65, 0.08),
    }.items():
        px, py = int(rx * W), int(ry * H)
        r, g, b = arr[py, px]
        grid[name] = {
            'pixel': [px, py],
            'rgb': [int(r), int(g), int(b)],
            'hex': '#{:02x}{:02x}{:02x}'.format(r, g, b),
            'ratio': [round(rx, 3), round(ry, 3)],
        }
    result['sample_points'] = grid

    # ── Auto-detect main blob by dominant color ───────────────────────────────
    top_color = result['dominant_colors'][0]['rgb']
    # Skip near-black/near-white backgrounds
    for col in result['dominant_colors']:
        r, g, b = col['rgb']
        brightness = (r + g + b) / 3
        if 30 < brightness < 220:
            top_color = col['rgb']
            break

    main_blob = find_color_blobs(arr, top_color, tolerance=55)
    if main_blob:
        mb = main_blob
        result['blobs']['main_body'] = {
            **mb,
            'width_ratio':  pixel_to_ratio(mb['width_px'], W),
            'height_ratio': pixel_to_ratio(mb['height_px'], H),
            'center_x_ratio': pixel_to_ratio(mb['center_x_px'], W),
            'center_y_ratio': pixel_to_ratio(mb['center_y_px'], H),
        }

    # ── Proportions ───────────────────────────────────────────────────────────
    if main_blob:
        bw = main_blob['width_px']
        bh = main_blob['height_px']
        result['proportions'] = {
            'body_width_pct':  round(bw / W * 100, 1),
            'body_height_pct': round(bh / H * 100, 1),
            'body_aspect':     round(bw / bh, 3) if bh else 0,
            'body_center_x_pct': round(main_blob['center_x_px'] / W * 100, 1),
            'body_center_y_pct': round(main_blob['center_y_px'] / H * 100, 1),
        }

    # ── Blender coordinate hints ──────────────────────────────────────────────
    # Assume body sphere radius ~ 1.7 Blender units (standard)
    # Scale all other measurements relative to body blob size
    BODY_RADIUS_BU = 1.7
    if main_blob:
        px_per_bu = main_blob['height_px'] / (BODY_RADIUS_BU * 2)
        result['blender_hints'] = {
            'note': f'Assuming body = r{BODY_RADIUS_BU} BU. px_per_BU={round(px_per_bu, 2)}',
            'px_per_blender_unit': round(px_per_bu, 2),
            'arm_radius_estimate_bu': round(0.45 * BODY_RADIUS_BU, 2),  # rough default
            'leg_height_estimate_bu': round(0.7 * BODY_RADIUS_BU, 2),
            'tip': 'Measure specific parts using --point X Y to get BU estimate',
        }

    # ── Print report ──────────────────────────────────────────────────────────
    print(f"\n{'='*60}")
    print(f"REF ANALYSIS: {Path(image_path).name}  ({W}x{H})")
    print(f"{'='*60}")
    print(f"\nDominant colors:")
    for i, c in enumerate(result['dominant_colors'][:4]):
        bar = '█' * int(c['pct'] / 2)
        print(f"  {i+1}. {c['hex']}  {c['pct']:5.1f}%  {bar}")
    if main_blob:
        p = result['proportions']
        print(f"\nMain body blob:")
        print(f"  Bounding box: ({main_blob['x_min']},{main_blob['y_min']}) → ({main_blob['x_max']},{main_blob['y_max']})")
        print(f"  Size: {main_blob['width_px']}x{main_blob['height_px']} px")
        print(f"  Body fills {p['body_width_pct']}% width, {p['body_height_pct']}% height")
        print(f"  Center at ({p['body_center_x_pct']}%, {p['body_center_y_pct']}%)")
    print(f"\nSample points (key locations):")
    for name, sp in grid.items():
        print(f"  {name:<18} {sp['hex']}  @ pixel ({sp['pixel'][0]:4d},{sp['pixel'][1]:4d})")
    if 'blender_hints' in result:
        print(f"\nBlender hints:")
        bh = result['blender_hints']
        print(f"  {bh['note']}")
        print(f"  Arm radius estimate:  ~{bh['arm_radius_estimate_bu']} BU")
        print(f"  Leg height estimate:  ~{bh['leg_height_estimate_bu']} BU")

    # ── Visual annotation ─────────────────────────────────────────────────────
    if visualize:
        vis = img.copy()
        draw = ImageDraw.Draw(vis)
        # Draw sample point dots
        for name, sp in grid.items():
            px, py = sp['pixel']
            draw.ellipse([px-6, py-6, px+6, py+6], outline='lime', width=2)
            draw.text((px+8, py-6), name, fill='lime')
        # Draw body bounding box
        if main_blob:
            mb = main_blob
            draw.rectangle([mb['x_min'], mb['y_min'], mb['x_max'], mb['y_max']], outline='yellow', width=2)
        vis_path = str(Path(image_path).with_suffix('')) + '_analyzed.png'
        vis.save(vis_path)
        print(f"\nAnnotated image saved: {vis_path}")
        result['visualization'] = vis_path

    # ── Save JSON ─────────────────────────────────────────────────────────────
    out = out_path or str(Path(image_path).with_suffix('')) + '_analysis.json'
    with open(out, 'w') as f:
        json.dump(result, f, indent=2)
    print(f"\nJSON saved: {out}\n")
    return result

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Analyze reference image for Blender work')
    parser.add_argument('image', help='Reference image path')
    parser.add_argument('--out', help='Output JSON path')
    parser.add_argument('--vis', action='store_true', help='Save annotated visualization')
    parser.add_argument('--point', nargs=2, type=int, metavar=('X', 'Y'),
                        help='Sample color at specific pixel coordinates')
    args = parser.parse_args()

    if args.point:
        img = Image.open(args.image).convert('RGB')
        arr = np.array(img)
        x, y = args.point
        r, g, b = arr[y, x]
        print(f"Pixel ({x},{y}): RGB=({r},{g},{b})  hex=#{r:02x}{g:02x}{b:02x}")
    else:
        analyze(args.image, visualize=args.vis, out_path=args.out)
