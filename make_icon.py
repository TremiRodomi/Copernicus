#!/usr/bin/env python3
"""The game icon: a cake, from either a pixel-art PNG (any whole-number upscale, transparent background; the 1.0 icon)
or Ptolemy's cake (metasprite $eb) dumped by the port from the player's own game files.

    python3 -I make_icon.py <icon.png> dragonruby-linux-amd64/fairyland/metadata [--bg]
    cd dragonruby-linux-amd64 && ./dragonruby fairyland --dump_meta eb      (-> fairyland/meta_dump.txt)
    python3 -I make_icon.py dragonruby-linux-amd64/fairyland/meta_dump.txt dragonruby-linux-amd64/fairyland/metadata

Writes icon.png (72x72), icon_ios.png (1024x1024) and icon_large.png (1800x1800): the sprite cropped to its pixels,
scaled by the largest whole factor that leaves a margin, centred on a transparent background (--bg: the old solid navy,
RGB without alpha).
The icons are game graphics: they ship inside the release builds (user's decision) but are never committed (*.png).
"""
import sys
from math import gcd

from PIL import Image

BG = (24, 24, 72)  # dark navy, near the game's night sky
SIZES = {'icon.png': 72, 'icon_ios.png': 1024, 'icon_large.png': 1800}
MARGIN = 0.9  # the sprite fills at most this share of the icon (72 px: x4)


def from_png(path):
    """A pixel-art PNG back to 1 px per pixel: the scale is the gcd of every colour run's start (rows and columns)."""
    im = Image.open(path).convert('RGBA')
    im = im.crop(im.getbbox())
    px, (w, h), k = im.load(), im.size, 0
    for y in range(h):
        k = gcd(k, *[x for x in range(1, w) if px[x, y] != px[x - 1, y]], w)
    for x in range(w):
        k = gcd(k, *[y for y in range(1, h) if px[x, y] != px[x, y - 1]], h)
    return im.resize((w // k, h // k), Image.NEAREST)


def from_dump(path):
    rows = open(path).read().split('\n')
    w, h = map(int, rows[0].split())
    spr = Image.new('RGBA', (w, h))
    for y in range(h):
        for x, v in enumerate(rows[1 + y].split()):
            v = int(v, 16)  # ABGR
            if v:
                spr.putpixel((x, y), (v & 255, (v >> 8) & 255, (v >> 16) & 255, 255))
    return spr


src, outdir = sys.argv[1:3]
solid = '--bg' in sys.argv[3:]
spr = from_png(src) if src.lower().endswith('.png') else from_dump(src)
spr = spr.crop(spr.getbbox())
for name, size in SIZES.items():
    k = max(1, int(size * MARGIN) // max(spr.size))
    big = spr.resize((spr.width * k, spr.height * k), Image.NEAREST)
    icon = Image.new('RGBA', (size, size), BG + (255 if solid else 0,))
    icon.alpha_composite(big, ((size - big.width) // 2, (size - big.height) // 2))
    (icon.convert('RGB') if solid else icon).save(f'{outdir}/{name}')
    print(f'{name}: {size}x{size}, sprite {spr.width}x{spr.height} x{k}')
