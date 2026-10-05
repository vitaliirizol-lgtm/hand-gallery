"""Generates the original Shadewalk app icon (1024x1024, RGB, no alpha) plus a 512 px preview.

Teal -> mint diagonal gradient tile, a white winding footpath that slips under a dark-green
leaf-shaped shadow, and a small warm sun disc top-right. Drawn at 4x and downsampled for clean edges.
"""
import math
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

FINAL = 1024
SCALE = 4
S = FINAL * SCALE

TEAL = np.array([8, 112, 112], dtype=np.float64)      # top-left
MINT = np.array([150, 232, 196], dtype=np.float64)    # bottom-right
LEAF_SHADOW = (6, 62, 46)
SUN_CORE = (255, 196, 92)
SUN_EDGE = (255, 150, 52)
PATH = (255, 255, 255)


def s(v):
    return v * SCALE


def gradient():
    t = np.linspace(0.0, 1.0, S)
    xx, yy = np.meshgrid(t, t)
    d = (xx + yy) / 2.0
    d = d ** 1.15  # keep a little more teal
    img = TEAL[None, None, :] * (1 - d[..., None]) + MINT[None, None, :] * d[..., None]
    return Image.fromarray(img.clip(0, 255).astype(np.uint8), "RGB")


def bezier(p0, p1, p2, p3, n=400):
    pts = []
    for i in range(n + 1):
        t = i / n
        a = (1 - t) ** 3
        b = 3 * (1 - t) ** 2 * t
        c = 3 * (1 - t) * t ** 2
        d = t ** 3
        pts.append((a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0],
                    a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]))
    return pts


def path_points():
    # A winding footpath entering at the bottom edge and heading up-right under the leaf shadow.
    seg1 = bezier((300, 1090), (250, 900), (760, 900), (690, 720))
    seg2 = bezier((690, 720), (630, 570), (330, 640), (400, 500))
    seg3 = bezier((400, 500), (440, 420), (520, 420), (600, 372))
    pts = seg1 + seg2[1:] + seg3[1:]
    return [(s(x), s(y)) for x, y in pts]


def draw_path(layer, width, fill, upto=None):
    """Stamps round brushes along the densely resampled curve: smooth, artifact-free thick stroke."""
    d = ImageDraw.Draw(layer)
    pts = path_points()
    if upto is not None:
        pts = pts[:upto]
    r = width / 2
    step = max(1.0, r / 12)
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        seg = math.hypot(x1 - x0, y1 - y0)
        n = max(1, int(seg / step))
        for i in range(n):
            t = i / n
            x = x0 + (x1 - x0) * t
            y = y0 + (y1 - y0) * t
            d.ellipse((x - r, y - r, x + r, y + r), fill=fill)
    x, y = pts[-1]
    d.ellipse((x - r, y - r, x + r, y + r), fill=fill)


LEAF = dict(cx=505, cy=440, length=470, width=250, angle=32)


def leaf_axis_point(u, length, angle_deg, cx, cy, lateral=0.0):
    """Point at axis parameter u in [-1, 1] (base -> tip) with a lateral offset, in final-pixel units."""
    a = math.radians(angle_deg)
    x = u * length / 2
    y = lateral
    rx = x * math.cos(a) + y * math.sin(a)
    ry = -x * math.sin(a) + y * math.cos(a)
    return cx + rx, cy + ry


def leaf_mask(cx, cy, length, width, angle):
    """Leaf silhouette: pointed tip, fuller base; base at the lower left, tip towards the sun."""
    n = 360
    upper, lower = [], []
    for i in range(n + 1):
        u = -1 + 2 * i / n
        half = width / 2 * math.sin(math.pi * (u + 1) / 2) ** 0.85 * (1 - 0.22 * u)
        upper.append(leaf_axis_point(u, length, angle, cx, cy, -half))
        lower.append(leaf_axis_point(u, length, angle, cx, cy, half))
    poly = [(s(x), s(y)) for x, y in upper + lower[::-1]]
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).polygon(poly, fill=255)
    # Stem: short tapered stroke continuing from the base.
    d = ImageDraw.Draw(mask)
    for i in range(60):
        u = -1 - 0.28 * i / 59
        x, y = leaf_axis_point(u, LEAF["length"], LEAF["angle"], cx, cy, 6 * (i / 59) ** 2)
        r = s(9 - 4 * i / 59)
        d.ellipse((s(x) - r, s(y) - r, s(x) + r, s(y) + r), fill=255)
    return mask, poly


def main(out_icon, out_preview):
    base = gradient().convert("RGBA")

    # Soft ambient shading under the path for depth.
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw_path(glow, s(96), (0, 60, 50, 70))
    glow = glow.filter(ImageFilter.GaussianBlur(s(10)))
    base = Image.alpha_composite(base, glow)

    path_layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw_path(path_layer, s(74), PATH + (255,))
    base = Image.alpha_composite(base, path_layer)

    # Leaf-shaped shadow lying across the end of the path: the path fades out underneath it.
    mask, _ = leaf_mask(LEAF["cx"], LEAF["cy"], LEAF["length"], LEAF["width"], LEAF["angle"])
    mask = mask.filter(ImageFilter.GaussianBlur(s(1.2)))
    shadow = Image.new("RGBA", (S, S), LEAF_SHADOW + (0,))
    shadow.putalpha(mask.point(lambda v: int(v * 0.88)))
    base = Image.alpha_composite(base, shadow)

    # Warm sun disc, top-right, with a faint halo.
    halo = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    hd = ImageDraw.Draw(halo)
    cx, cy, r = s(800), s(206), s(92)
    hd.ellipse((cx - r * 1.55, cy - r * 1.55, cx + r * 1.55, cy + r * 1.55), fill=(255, 214, 140, 70))
    halo = halo.filter(ImageFilter.GaussianBlur(s(18)))
    base = Image.alpha_composite(base, halo)

    sun = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sun)
    steps = 48
    for i in range(steps):
        t = i / (steps - 1)
        rr = r * (1 - t * 0.55)
        col = tuple(int(SUN_EDGE[k] + (SUN_CORE[k] - SUN_EDGE[k]) * t) for k in range(3))
        sd.ellipse((cx - rr, cy - rr, cx + rr, cy + rr), fill=col + (255,))
    base = Image.alpha_composite(base, sun)

    icon = base.convert("RGB").resize((FINAL, FINAL), Image.LANCZOS)
    icon.save(out_icon, "PNG", optimize=True)
    icon.resize((512, 512), Image.LANCZOS).save(out_preview, "PNG", optimize=True)


if __name__ == "__main__":
    # Usage (from Shadewalk/): python3 scripts/generate_app_icon.py \
    #   Shadewalk/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png docs/icon-preview.png
    # Requires Pillow and NumPy.
    main(sys.argv[1], sys.argv[2])
