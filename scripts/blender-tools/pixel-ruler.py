#!/usr/bin/env python3
"""
pixel-ruler.py — Measure pixel distances in a reference image and convert to
                 Blender units based on a known anchor (body sphere radius).

Usage:
  python3 pixel-ruler.py <image> --anchor x1 y1 x2 y2 --anchor-bu 3.4
  python3 pixel-ruler.py <image> --measure x1 y1 x2 y2
  python3 pixel-ruler.py <image> --interactive

Examples:
  # Set body height as anchor (top of body to bottom = 3.4 BU diameter)
  python3 pixel-ruler.py ref.jpg --anchor 380 120 380 560 --anchor-bu 3.4

  # Measure arm width after setting anchor
  python3 pixel-ruler.py ref.jpg --anchor 380 120 380 560 --anchor-bu 3.4 \\
    --measure 80 320 240 320

  # Interactive mode: click to measure (opens image with PIL)
  python3 pixel-ruler.py ref.jpg --interactive
"""
import argparse, json, math, sys
from pathlib import Path
from PIL import Image, ImageDraw
import numpy as np

def px_dist(x1, y1, x2, y2):
    return math.sqrt((x2-x1)**2 + (y2-y1)**2)

def measure(image_path, measurements, anchor_px=None, anchor_bu=None, out_path=None):
    img = Image.open(image_path).convert('RGB')
    W, H = img.size
    arr = np.array(img)
    draw_img = img.copy()
    draw = ImageDraw.Draw(draw_img)

    px_per_bu = None
    if anchor_px and anchor_bu:
        ax1, ay1, ax2, ay2 = anchor_px
        anchor_dist_px = px_dist(ax1, ay1, ax2, ay2)
        px_per_bu = anchor_dist_px / anchor_bu
        draw.line([ax1, ay1, ax2, ay2], fill='yellow', width=3)
        draw.text((ax1+5, ay1+5), f'ANCHOR={anchor_bu:.2f}BU ({anchor_dist_px:.0f}px)', fill='yellow')
        print(f"\nAnchor: {anchor_dist_px:.1f}px = {anchor_bu:.2f} BU")
        print(f"Scale:  {px_per_bu:.2f} px/BU  ({1/px_per_bu:.4f} BU/px)")

    print(f"\nImage: {image_path}  ({W}x{H})")
    print(f"{'─'*55}")

    results = []
    colors = ['lime', 'cyan', 'magenta', 'orange', 'white']
    for i, (x1, y1, x2, y2, label) in enumerate(measurements):
        col = colors[i % len(colors)]
        dist_px = px_dist(x1, y1, x2, y2)
        dist_bu = dist_px / px_per_bu if px_per_bu else None

        draw.line([x1, y1, x2, y2], fill=col, width=2)
        draw.ellipse([x1-4, y1-4, x1+4, y1+4], fill=col)
        draw.ellipse([x2-4, y2-4, x2+4, y2+4], fill=col)
        mid_x, mid_y = (x1+x2)//2, (y1+y2)//2
        label_text = label or f'M{i+1}'
        if dist_bu:
            draw.text((mid_x+5, mid_y-10), f'{label_text}: {dist_bu:.3f}BU', fill=col)
        draw.text((mid_x+5, mid_y+4), f'{dist_px:.0f}px', fill=col)

        # Sample colors at endpoints and midpoint
        c_start = arr[min(y1,H-1), min(x1,W-1)]
        c_end   = arr[min(y2,H-1), min(x2,W-1)]
        c_mid   = arr[min(mid_y,H-1), min(mid_x,W-1)]

        result = {
            'label': label_text,
            'from': [x1, y1], 'to': [x2, y2],
            'dist_px': round(dist_px, 1),
            'dist_bu': round(dist_bu, 4) if dist_bu else None,
            'pct_of_width':  round(dist_px / W * 100, 1),
            'pct_of_height': round(dist_px / H * 100, 1),
            'color_at_start': '#{:02x}{:02x}{:02x}'.format(*c_start),
            'color_at_mid':   '#{:02x}{:02x}{:02x}'.format(*c_mid),
            'color_at_end':   '#{:02x}{:02x}{:02x}'.format(*c_end),
        }
        results.append(result)

        print(f"{label_text:15} {dist_px:7.1f}px", end='')
        if dist_bu:
            print(f"  {dist_bu:6.3f} BU", end='')
        print(f"  ({result['pct_of_width']:.1f}%W, {result['pct_of_height']:.1f}%H)", end='')
        print(f"  color@mid={result['color_at_mid']}")

    print(f"{'─'*55}")

    # ── Blender hints ──────────────────────────────────────────────────────────
    if px_per_bu and results:
        print(f"\nBlender unit hints:")
        for r in results:
            if r['dist_bu']:
                # Common interpretations
                bu = r['dist_bu']
                print(f"  {r['label']:15}: {bu:.3f} BU  →  radius={bu/2:.3f}  or  scale_z={bu:.3f}")

    vis_path = out_path or str(Path(image_path).with_suffix('')) + '_measured.png'
    draw_img.save(vis_path)
    print(f"\nAnnotated image: {vis_path}")

    return results

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('image', help='Reference image path')
    parser.add_argument('--anchor', nargs=4, type=int, metavar=('X1','Y1','X2','Y2'),
                        help='Known-length line in pixels (X1 Y1 X2 Y2)')
    parser.add_argument('--anchor-bu', type=float,
                        help='Length of anchor line in Blender units')
    parser.add_argument('--measure', nargs='+',
                        help='Measurements: X1 Y1 X2 Y2 LABEL  (repeat multiple times)')
    parser.add_argument('--out', help='Output annotated image path')
    args = parser.parse_args()

    anchor_px = args.anchor
    measurements = []
    if args.measure:
        tokens = args.measure
        i = 0
        while i < len(tokens):
            if i+4 <= len(tokens):
                try:
                    x1, y1, x2, y2 = int(tokens[i]), int(tokens[i+1]), int(tokens[i+2]), int(tokens[i+3])
                    label = tokens[i+4] if i+4 < len(tokens) and not tokens[i+4].lstrip('-').isdigit() else f'M{len(measurements)+1}'
                    measurements.append((x1, y1, x2, y2, label))
                    i += 5 if label != f'M{len(measurements)}' else 4
                except (ValueError, IndexError):
                    i += 1
            else:
                break

    if not measurements:
        # Default: measure center height and width of image
        W, H = Image.open(args.image).size
        measurements = [
            (W//2, 0, W//2, H, 'full_height'),
            (0, H//2, W, H//2, 'full_width'),
            (W//4, H//4, 3*W//4, 3*H//4, 'body_diag'),
        ]

    measure(args.image, measurements, anchor_px, args.anchor_bu, args.out)
