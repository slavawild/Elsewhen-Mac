#!/usr/bin/env python3
"""Draws Support/AppIcon.png, the app icon: the hero globe on a night-blue tile.

    python3 scripts/make-icon.py

The globe is drawn the way the app draws its own (orthographic, Natural Earth
coastlines clipped to the visible hemisphere along the limb, leaning by the
Earth's axial tilt), with a day side, a night side and a gold terminator.
Needs Pillow and numpy. build-app.sh turns the PNG into AppIcon.icns.
"""

import json
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORLD = os.path.join(ROOT, "Sources/ElsewhenCore/Resources/world.json")
OUT = os.path.join(ROOT, "Support/AppIcon.png")

S = 2048                      # drawn at twice the size, then reduced, for clean edges
SPIN, VIEW_LAT = 18.0, 22.0   # Europe and Africa facing
AXIAL_TILT = 23.44
DEG = math.pi / 180


def project(lat, lon, r):
    phi, lam, p0 = lat * DEG, (lon - SPIN) * DEG, VIEW_LAT * DEG
    cosc = math.sin(p0) * math.sin(phi) + math.cos(p0) * math.cos(phi) * math.cos(lam)
    x = r * math.cos(phi) * math.sin(lam)
    y = -r * (math.cos(p0) * math.sin(phi) - math.sin(p0) * math.cos(phi) * math.cos(lam))
    return x, y, cosc > 0


def limb(a, b, r):
    if abs(b[1] - a[1]) > 180:
        return None
    lo, hi = 0.0, 1.0
    for _ in range(12):
        m = (lo + hi) / 2
        if project(a[0] + (b[0] - a[0]) * m, a[1] + (b[1] - a[1]) * m, r)[2]:
            lo = m
        else:
            hi = m
    x, y, _ = project(a[0] + (b[0] - a[0]) * lo, a[1] + (b[1] - a[1]) * lo, r)
    return (x, y)


def clip_ring(ring, r):
    """GlobeModel.clipRingToDisc: one polygon per ring, walking the limb between exit and entry."""
    pts = [(ring[k + 1], ring[k]) for k in range(0, len(ring) - 1, 2)]
    out = []
    for i, a in enumerate(pts):
        b = pts[(i + 1) % len(pts)]
        pa, pb = project(*a, r), project(*b, r)
        if pa[2] and pb[2]:
            out.append(((pb[0], pb[1]), False))
        elif pa[2]:
            e = limb(a, b, r)
            if e:
                out.append((e, True))
        elif pb[2]:
            e = limb(b, a, r)
            if e:
                out.append((e, True))
            out.append(((pb[0], pb[1]), False))
    if len(out) < 3:
        return []
    res = []
    for j, (p, is_limb) in enumerate(out):
        res.append(p)
        nxt = out[(j + 1) % len(out)]
        if not (is_limb and nxt[1]):
            continue
        a0, a1 = math.atan2(p[1], p[0]), math.atan2(nxt[0][1], nxt[0][0])
        d = a1 - a0
        while d > math.pi:
            d -= 2 * math.pi
        while d < -math.pi:
            d += 2 * math.pi
        steps = max(1, round(abs(d) / 0.05))
        for t in range(1, steps):
            a = a0 + d * t / steps
            res.append((r * math.cos(a), r * math.sin(a)))
    return res


def visible_runs(points, r):
    runs, run = [], []
    for lat, lon in points:
        x, y, vis = project(lat, lon, r)
        if vis:
            run.append((x, y))
        else:
            if len(run) > 1:
                runs.append(run)
            run = []
    if len(run) > 1:
        runs.append(run)
    return runs


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))


def tile():
    """The macOS icon grid: an 824-point rounded tile on a 1024 canvas, night blue, lit from above."""
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    inset, radius = int(S * 100 / 1024), int(S * 185 / 1024)
    top, bottom = (40, 62, 112), (10, 16, 38)
    grad = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        gd.line([(0, y), (S, y)], fill=lerp(top, bottom, y / S) + (255,))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([inset, inset, S - inset, S - inset], radius, fill=255)
    img.paste(grad, (0, 0), mask)

    # A few stars, faint, away from the globe.
    rng = np.random.default_rng(7)
    sd = ImageDraw.Draw(img)
    for _ in range(46):
        x, y = rng.uniform(inset + 60, S - inset - 60), rng.uniform(inset + 60, S - inset - 60)
        if math.hypot(x - S / 2, y - S * 0.5) < S * 0.36:
            continue
        rr = rng.uniform(2, 5)
        a = int(rng.uniform(60, 170))
        sd.ellipse([x - rr, y - rr, x + rr, y + rr], fill=(255, 255, 255, a))
    return img, mask


def globe(r):
    size = int(2 * r + 40)
    c = size / 2
    land = json.load(open(WORLD))

    # Per-pixel normals on the visible hemisphere, for the day and night sides.
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float64)
    nx, ny = (xx - c) / r, (yy - c) / r
    rho2 = nx * nx + ny * ny
    inside = rho2 <= 1
    nz = np.sqrt(np.clip(1 - rho2, 0, 1))
    sun = np.array([-0.62, -0.42, 0.66])
    sun /= np.linalg.norm(sun)
    light = nx * sun[0] + ny * sun[1] + nz * sun[2]   # >0 is day
    day = np.clip((light + 0.07) / 0.14, 0, 1)

    # Ocean: deep blue, brighter towards the sunlit limb; land: warm white like the app's bright continents.
    ocean_day, ocean_night = np.array([46, 112, 182]), np.array([14, 30, 62])
    land_day, land_night = np.array([246, 239, 222]), np.array([60, 66, 86])

    land_mask = Image.new("L", (size, size), 0)
    ld = ImageDraw.Draw(land_mask)
    for ring in land:
        poly = clip_ring(ring, r)
        if len(poly) >= 3:
            ld.polygon([(c + x, c + y) for x, y in poly], fill=255)
    lm = np.asarray(land_mask, dtype=np.float64)[..., None] / 255

    d = day[..., None]
    rgb = (ocean_night + (ocean_day - ocean_night) * d) * (1 - lm) + (land_night + (land_day - land_night) * d) * lm
    # A little sphere shading so it reads round.
    shade = 0.78 + 0.22 * nz[..., None]
    rgb = rgb * shade

    # The terminator, in the app's daylight gold.
    gold = np.array([229, 199, 54])
    edge = np.clip(1 - np.abs(light) / 0.018, 0, 1)[..., None] * 0.85
    rgb = rgb * (1 - edge) + gold * edge

    alpha = np.where(inside, 255, 0).astype(np.uint8)
    img = Image.fromarray(np.dstack([np.clip(rgb, 0, 255).astype(np.uint8), alpha]), "RGBA")
    # Soften the disc edge.
    soft = Image.new("L", (size, size), 0)
    ImageDraw.Draw(soft).ellipse([c - r, c - r, c + r, c + r], fill=255)
    img.putalpha(soft)

    # Translucent strokes go on their own layer: drawing straight onto the
    # globe would replace its pixels' alpha rather than blend over them.
    overlay = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    dr = ImageDraw.Draw(overlay)
    # Graticule, faint, on top of everything but the marker and rim.
    for lon in range(-180, 180, 30):
        for run in visible_runs([(lat, lon) for lat in range(-90, 91, 2)], r):
            dr.line([(c + x, c + y) for x, y in run], fill=(255, 255, 255, 60), width=4)
    for lat in range(-60, 61, 30):
        for run in visible_runs([(lat, lon) for lon in range(-180, 181, 2)], r):
            dr.line([(c + x, c + y) for x, y in run], fill=(255, 255, 255, 60), width=4)

    # "You are here", in the system accent blue, edged like the app's marker.
    x, y, vis = project(50.45, 30.52, r)
    if vis:
        px, py, mr = c + x, c + y, r * 0.055
        dr.ellipse([px - mr * 2, py - mr * 2, px + mr * 2, py + mr * 2], outline=(10, 132, 255, 170), width=8)
        dr.ellipse([px - mr, py - mr, px + mr, py + mr], fill=(10, 132, 255, 255), outline=(255, 255, 255, 230), width=6)

    # The rim last, so nothing spills over it.
    w = int(r * 0.045)
    dr.ellipse([c - r, c - r, c + r, c + r], outline=(236, 240, 248, 255), width=w)
    clip = Image.new("L", (size, size), 0)
    ImageDraw.Draw(clip).ellipse([c - r - w, c - r - w, c + r + w, c + r + w], fill=255)
    img.alpha_composite(Image.composite(overlay, Image.new("RGBA", (size, size), (0, 0, 0, 0)), clip))
    return img


def main():
    img, mask = tile()
    r = S * 0.315
    g = globe(r)
    # The globe leans with the Earth.
    g = g.rotate(-AXIAL_TILT, resample=Image.BICUBIC, expand=False)

    # A soft shadow under it.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    cx, cy = S / 2, S * 0.505
    ImageDraw.Draw(shadow).ellipse([cx - r, cy - r + S * 0.02, cx + r, cy + r + S * 0.02], fill=(0, 0, 0, 120))
    shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.02))
    img.alpha_composite(Image.composite(shadow, Image.new("RGBA", (S, S), (0, 0, 0, 0)), mask))
    img.alpha_composite(g, (int(cx - g.width / 2), int(cy - g.height / 2)))

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    img.resize((1024, 1024), Image.LANCZOS).save(OUT)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
