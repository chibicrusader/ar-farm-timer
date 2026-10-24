#!/usr/bin/env python3
"""Generates AR Farm Timer icons (web/PWA, favicon, iOS splash).

Usage: python3 tool/make_icons.py   (run from the app directory; needs Pillow)
"""
import math
import os
from PIL import Image, ImageDraw, ImageFilter

BG_INNER = (34, 48, 58)
BG_OUTER = (12, 15, 20)
GOLD = (201, 164, 92)
GOLD_BRIGHT = (236, 203, 128)
GOLD_DIM = (110, 90, 52)
LEAF = (124, 196, 122)
LEAF_DARK = (74, 140, 84)
SOIL = (120, 86, 52)

S = 1024  # master size


def bezier(p0, p1, p2, p3, n=60):
    pts = []
    for i in range(n + 1):
        t = i / n
        a = (1 - t) ** 3
        b = 3 * (1 - t) ** 2 * t
        c = 3 * (1 - t) * t ** 2
        d = t ** 3
        pts.append((a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]))
    return pts


def background(size):
    img = Image.new('RGB', (size, size), BG_OUTER)
    px = img.load()
    cx = cy = size / 2
    maxd = math.hypot(cx, cy)
    for y in range(size):
        for x in range(size):
            t = min(1.0, math.hypot(x - cx, y - cy * 0.9) / maxd * 1.25)
            px[x, y] = tuple(int(BG_INNER[i] * (1 - t) + BG_OUTER[i] * t) for i in range(3))
    return img


def artwork(scale=1.0):
    """Transparent RGBA artwork centred in an S x S canvas, scaled."""
    k = 4  # supersample
    W = S * k
    art = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(art)
    c = W / 2
    u = W * scale  # unit

    def P(x, y):  # coords in [-0.5, 0.5] around centre
        return (c + x * u, c + y * u)

    # clock ring
    r = 0.40 * u
    w = int(0.038 * u)
    d.ellipse([c - r, c - r, c + r, c + r], outline=GOLD_DIM + (255,), width=w)
    # progress arc (timer) ~ 300 degrees
    d.arc([c - r, c - r, c + r, c + r], start=-90, end=210, fill=GOLD + (255,), width=w)
    # bright cap at arc end
    a = math.radians(210)
    ex, ey = c + r * math.cos(a), c + r * math.sin(a)
    d.ellipse([ex - w * 0.9, ey - w * 0.9, ex + w * 0.9, ey + w * 0.9], fill=GOLD_BRIGHT + (255,))
    # ticks
    for i in range(12):
        ang = math.radians(i * 30 - 90)
        r1, r2 = r - w * 1.4, r - w * (2.6 if i % 3 == 0 else 2.0)
        d.line([(c + r1 * math.cos(ang), c + r1 * math.sin(ang)), (c + r2 * math.cos(ang), c + r2 * math.sin(ang))],
               fill=GOLD + (230,), width=int(w * (0.45 if i % 3 == 0 else 0.3)))

    # soil mound
    d.chord([*P(-0.20, 0.14), *P(0.20, 0.34)], start=180, end=360, fill=SOIL + (255,))
    d.arc([*P(-0.20, 0.14), *P(0.20, 0.34)], start=180, end=360, fill=GOLD + (255,), width=int(0.012 * u))

    # stem
    stem = bezier(P(0.0, 0.24), P(0.01, 0.12), P(-0.02, 0.02), P(0.0, -0.10))
    d.line(stem, fill=LEAF_DARK + (255,), width=int(0.032 * u), joint='curve')

    # leaves
    def leaf(base, tip, bulge, color, vein):
        bx, by = base
        tx, ty = tip
        nx, ny = -(ty - by), (tx - bx)
        ln = math.hypot(nx, ny)
        nx, ny = nx / ln * bulge * u, ny / ln * bulge * u
        m1 = (bx + (tx - bx) * 0.3 + nx, by + (ty - by) * 0.3 + ny)
        m2 = (bx + (tx - bx) * 0.75 + nx * 0.8, by + (ty - by) * 0.75 + ny * 0.8)
        m3 = (bx + (tx - bx) * 0.75 - nx * 0.8, by + (ty - by) * 0.75 - ny * 0.8)
        m4 = (bx + (tx - bx) * 0.3 - nx, by + (ty - by) * 0.3 - ny)
        pts = bezier(base, m1, m2, tip) + bezier(tip, m3, m4, base)
        d.polygon(pts, fill=color + (255,))
        d.line(bezier(base, (bx + (tx - bx) * 0.4, by + (ty - by) * 0.4), (bx + (tx - bx) * 0.7, by + (ty - by) * 0.7), tip, 20),
               fill=vein + (255,), width=int(0.008 * u))

    leaf(P(0.0, 0.0), P(-0.24, -0.16), 0.075, LEAF, LEAF_DARK)
    leaf(P(0.0, -0.06), P(0.22, -0.24), 0.07, LEAF, LEAF_DARK)
    # small top bud
    leaf(P(0.0, -0.09), P(0.02, -0.20), 0.03, LEAF, LEAF_DARK)

    art = art.resize((S, S), Image.LANCZOS)
    return art


def compose(scale, size, rounded=False):
    bg = background(S)
    art = artwork(scale)
    # soft glow behind artwork
    glow = art.split()[3].filter(ImageFilter.GaussianBlur(S * 0.02))
    glow_img = Image.new('RGBA', (S, S), GOLD + (0,))
    glow_img.putalpha(glow.point(lambda v: int(v * 0.25)))
    out = bg.convert('RGBA')
    out.alpha_composite(glow_img)
    out.alpha_composite(art)
    if rounded:
        mask = Image.new('L', (S * 2, S * 2), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, S * 2 - 1, S * 2 - 1], radius=int(S * 2 * 0.22), fill=255)
        out.putalpha(mask.resize((S, S), Image.LANCZOS))
    return out.resize((size, size), Image.LANCZOS)


def splash(w, h, icon):
    img = Image.new('RGB', (w, h), BG_OUTER)
    s = int(min(w, h) * 0.38)
    ic = icon.resize((s, s), Image.LANCZOS)
    img.paste(ic, ((w - s) // 2, (h - s) // 2 - int(h * 0.04)), ic if ic.mode == 'RGBA' else None)
    return img


def main():
    os.makedirs('web/icons', exist_ok=True)
    os.makedirs('web/splash', exist_ok=True)
    full = compose(1.0, S)                 # "any" purpose, full-bleed
    maskable = compose(0.72, S)            # artwork inside 80% safe zone
    rounded = compose(1.0, S, rounded=True)
    full.convert('RGB').save('tool/icon_master_1024.png')
    for size in (192, 512):
        full.resize((size, size), Image.LANCZOS).convert('RGB').save(f'web/icons/Icon-{size}.png')
        maskable.resize((size, size), Image.LANCZOS).convert('RGB').save(f'web/icons/Icon-maskable-{size}.png')
    # iOS uses a full-bleed opaque square and applies its own rounding.
    for size in (180, 167, 152, 120):
        full.resize((size, size), Image.LANCZOS).convert('RGB').save(f'web/icons/apple-touch-icon-{size}.png')
    full.resize((180, 180), Image.LANCZOS).convert('RGB').save('web/apple-touch-icon.png')
    rounded.resize((64, 64), Image.LANCZOS).save('web/favicon.png')
    rounded.resize((32, 32), Image.LANCZOS).save('web/icons/favicon-32.png')
    # iOS splash screens (portrait, device pixels): name -> (w, h)
    icon_art = compose(1.0, 1024, rounded=True)
    for w, h in [(1320, 2868), (1206, 2622), (1290, 2796), (1179, 2556), (1284, 2778), (1170, 2532),
                 (1125, 2436), (1242, 2688), (828, 1792), (750, 1334), (640, 1136)]:
        splash(w, h, icon_art).save(f'web/splash/splash-{w}x{h}.png', optimize=True)
    print('icons written')


if __name__ == '__main__':
    main()
