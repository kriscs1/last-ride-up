#!/usr/bin/env python3
"""Renders every map to docs/map_<id>.png (8 px per tile) with area names and a legend."""
import re, pathlib
from PIL import Image, ImageDraw, ImageFont

import glob, sys
root = pathlib.Path(__file__).resolve().parent.parent


def render(path):
    src = pathlib.Path(path).read_text()
    rows = re.search(r'"""(.*)"""', src, re.S).group(1).split('\n')
    areas = re.findall(r'\["([^"]*)", (\d+), (\d+), (\d+), (\d+), "([^"]*)", "([^"]*)", "([^"]*)"\]', src)
    decor = re.findall(r'\["(\w+)", (\d+), (\d+), (\d+)\]', src.split('const DECOR')[1].split('const THEME')[0])

    def area_at(x, y):
        for a in areas:
            if int(a[1]) <= x <= int(a[3]) and int(a[2]) <= y <= int(a[4]):
                return a
        return None
    map_name = re.search(r'const NAME := "([^"]+)"', src).group(1)
    map_id = re.search(r'const ID := "([^"]+)"', src).group(1)
    sky = re.search(r'"sky": \["([^"]+)", "([^"]+)"', src).group(2)
    S, H, W, SURF = 8, len(rows), len(rows[0]), 22
    img = Image.new('RGB', (W * S, H * S + 70), '#0b1a1c')
    d = ImageDraw.Draw(img)
    COL = {'#': None, '=': '#c08a50', '^': '#d9483b', 'H': '#e0c48a', 'B': '#c08a50', 't': '#9b6bff', 'F': '#56606e',
           '1': '#ff8a3a', '2': '#ff8a3a', '3': '#ff8a3a'}
    MARK = {'o': ('#ffb347', 1), 'O': ('#ffb347', 2), 'C': ('#c99a3c', 3), 'R': ('#ffe08a', 3), 'K': ('#7fe0d0', 3), 'I': ('#ff6a3a', 4),
            'X': ('#5fd0e8', 3), 'W': ('#5fd0e8', 4), 'v': ('#ff5d4a', 2), 'k': ('#f2c14e', 2), 'p': ('#7bdc6a', 3), 'q': ('#7bdc6a', 3),
            'r': ('#7bdc6a', 3), 'S': ('#ffffff', 3), 'V': ('#f2c14e', 4), 'E': ('#f2c14e', 3), 'Y': ('#9aa3ad', 2), 'G': ('#9aa3ad', 2), 'N': ('#9aa3ad', 2)}
    for y, r in enumerate(rows):
        for x, ch in enumerate(r):
            box = [x * S, y * S, x * S + S - 1, y * S + S - 1]
            if ch == '#':
                d.rectangle(box, fill='#3a3f44' if y >= SURF else '#4a5a4a')
            else:
                a = area_at(x, y)
                d.rectangle(box, fill=(a[6] if a and y >= SURF else ('#1b2124' if y >= SURF else sky)))
                if ch in COL and COL[ch]:
                    if ch in '=B':
                        d.rectangle([x * S, y * S, x * S + S - 1, y * S + 2], fill=COL[ch])
                    elif ch == 'H':
                        d.rectangle([x * S + 1, y * S, x * S + 2, y * S + S - 1], fill=COL[ch]); d.rectangle([x * S + 5, y * S, x * S + 6, y * S + S - 1], fill=COL[ch])
                    else:
                        d.rectangle(box, fill=COL[ch])
                if ch in MARK:
                    c, rad = MARK[ch]; cx, cy = x * S + S // 2, y * S + S // 2
                    d.ellipse([cx - rad, cy - rad, cx + rad, cy + rad], fill=c)
    try:
        font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', 14)
        small = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', 12)
    except OSError:
        font = small = ImageFont.load_default()
    GLOW = {'lantern', 'chandelier', 'candles', 'brazier', 'torch', 'mushroom', 'crystal', 'glowworm', 'window'}
    for kind, x, y, e in decor:
        x, y = int(x), int(y)
        if kind in ('water', 'rails'):
            d.rectangle([x * S, y * S + (4 if kind == 'water' else 6), int(e) * S + S, y * S + S - 1],
                        fill='#2a6a8a' if kind == 'water' else '#6a5a4a')
        else:
            cx, cy = x * S + S // 2, y * S + S // 2
            d.rectangle([cx - 1, cy - 1, cx + 1, cy + 1], fill='#ffe9a8' if kind in GLOW else '#8a7a66')
    for name, x0, y0, x1, y1, *_ in areas:
        if not name:
            continue
        x0, y0, x1, y1 = map(int, (x0, y0, x1, y1))
        big = y1 < SURF
        f = font if big else small
        cx, cy = (x0 + x1 + 1) / 2 * S, (y0 + 2) * S if big else (y0 + 1.3) * S
        tw = d.textlength(name, font=f)
        d.text((cx - tw / 2, cy), name, fill='#fff6df', font=f, stroke_width=3, stroke_fill='#000000')
    legend = [('#ffb347', 'Sunstone'), ('#5fd0e8', 'crystal vein (big = great vein)'), ('#e0c48a', 'ladder'), ('#ff8a3a', 'shortcut door'),
              ('#7bdc6a', 'door lever'), ('#d9483b', 'spikes'), ('#f2c14e', 'skyship / checkpoints'), ('#ff5d4a', 'valves')]
    x = 10
    for c, t in legend:
        d.ellipse([x, H * S + 22, x + 12, H * S + 34], fill=c); d.text((x + 18, H * S + 20), t, fill='#fff6df', font=small)
        x += 30 + d.textlength(t, font=small)
    d.text((10, H * S + 46), f'Last Ride Up: {map_name} (150 x 64 tiles). Rooms are tinted by theme; small dots are props.', fill='#c8d6c0', font=small)
    out = root / f'docs/map_{map_id}.png'
    img.save(out); print('wrote', out, img.size)


for pth in sorted(glob.glob(str(root / 'scripts/sim/maps/cf_map_*.gd'))):
    render(pth)
