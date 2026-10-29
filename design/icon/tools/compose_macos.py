#!/usr/bin/env python3
"""Composite a full-bleed 1024x1024 artwork into a macOS app icon (Apple macOS icon grid).

The artwork is scaled into the 824x824 rounded-rect body (continuous "squircle" corners,
corner radius 185.4 px) centred on a transparent 1024x1024 canvas, with a soft drop shadow
and a faint inner rim so the dark body stays visible on dark backgrounds.

Usage: python3 -I compose_macos.py <full-bleed.png> <out-macos-1024.png>
Part of design/icon (see design/icon/README.md).
"""
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

CANVAS = 1024
BODY = 824                      # Apple macOS grid: 824x824 body, 100 px margin
RADIUS = 185.4                  # corner radius of the 824 body
SS = 4                          # supersampling factor for anti-aliased masks

# Continuous-corner (iOS 7+/macOS 11+) rounded-rect corner, in units of the radius, measured
# from the corner along the two edges (PaintCode's reverse-engineered Apple path).
CORNER = [
    ("M", (1.52866483, 0.0)),
    ("C", (1.08849323, 0.0), (0.86840689, 0.0), (0.66993427, 0.06549600)),
    ("L", (0.63149399, 0.07491100)),
    ("C", (0.37282392, 0.16905899), (0.16906013, 0.37282401), (0.07491100, 0.63149399)),
    ("L", (0.06549600, 0.66993427)),
    ("C", (0.0, 0.86840689), (0.0, 1.08849323), (0.0, 1.52866483)),
]


def _bezier(p0, p1, p2, p3, steps=48):
    pts = []
    for i in range(1, steps + 1):
        t = i / steps
        u = 1 - t
        pts.append((u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0],
                    u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1]))
    return pts


def _corner_points():
    """One corner as a polyline in corner-local units (x from the vertical edge, y from the horizontal one)."""
    pts = [CORNER[0][1]]
    for seg in CORNER[1:]:
        if seg[0] == "L":
            pts.append(seg[1])
        else:
            pts.extend(_bezier(pts[-1], seg[1], seg[2], seg[3]))
    return pts


def squircle_polygon(x0, y0, size, radius):
    corner = _corner_points()
    x1, y1 = x0 + size, y0 + size
    poly = []
    # Clockwise: top-right, bottom-right, bottom-left, top-left, each mirrored from the template.
    poly += [(x1 - cx * radius, y0 + cy * radius) for cx, cy in corner]
    poly += [(x1 - cy * radius, y1 - cx * radius) for cx, cy in corner]
    poly += [(x0 + cx * radius, y1 - cy * radius) for cx, cy in corner]
    poly += [(x0 + cy * radius, y0 + cx * radius) for cx, cy in corner]
    return poly


def body_mask(size, radius, inset=0.0):
    big = Image.new("L", (size * SS, size * SS), 0)
    ImageDraw.Draw(big).polygon(
        squircle_polygon(inset * SS, inset * SS, (size - 2 * inset) * SS, (radius - inset) * SS), fill=255)
    return big.resize((size, size), Image.LANCZOS)


def main(src, dst):
    art = Image.open(src).convert("RGB")
    if art.size != (CANVAS, CANVAS):
        art = art.resize((CANVAS, CANVAS), Image.LANCZOS)
    body = art.resize((BODY, BODY), Image.LANCZOS).convert("RGBA")
    mask = body_mask(BODY, RADIUS)

    # Faint light rim just inside the edge so the dark body reads on dark backgrounds.
    rim = ImageChops.subtract(mask, body_mask(BODY, RADIUS, inset=2.0))
    rim_layer = Image.new("RGBA", (BODY, BODY), (255, 255, 255, 0))
    rim_layer.putalpha(rim.point(lambda v: v * 30 // 255))
    body = Image.alpha_composite(body, rim_layer)
    body.putalpha(mask)

    off = (CANVAS - BODY) // 2
    full_mask = Image.new("L", (CANVAS, CANVAS), 0)
    full_mask.paste(mask, (off, off))

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    # Two-layer drop shadow: soft ambient + tight contact shadow.
    for dy, sigma, alpha in ((10, 14, 0.30), (3, 3, 0.22)):
        sh = Image.new("L", (CANVAS, CANVAS), 0)
        sh.paste(full_mask, (0, dy))
        sh = sh.filter(ImageFilter.GaussianBlur(sigma)).point(lambda v, a=alpha: int(v * a))
        layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
        layer.putalpha(sh)
        canvas = Image.alpha_composite(canvas, layer)

    canvas.alpha_composite(body, (off, off))
    canvas.save(dst, "PNG")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
