#!/usr/bin/env python3
"""Contact sheet for icon legibility: one row per icon (256 px preview, 64/32/16 px at 1:1 on dark and
light backgrounds, and 32/16 px magnified with nearest-neighbour so individual pixels are visible).

Each input is a 1024 px PNG (small sizes are downscaled here) or a mac AppIcon.appiconset directory
(its own icon_16x16 / icon_32x32 / icon_32x32@2x files are shown, i.e. exactly what ships).

Usage: python3 -I contact_sheet.py <out.png> <icon-1024.png | AppIcon.appiconset> [...]
Part of design/icon (see design/icon/README.md).
"""
import os
import sys

from PIL import Image, ImageDraw

DARK, LIGHT, PAD = (30, 30, 32), (236, 236, 238), 24
APPICONSET = {1024: "icon_512x512@2x.png", 64: "icon_32x32@2x.png", 32: "icon_32x32.png", 16: "icon_16x16.png"}


def loader(icon):
    if os.path.isdir(icon):
        files = {s: Image.open(os.path.join(icon, f)).convert("RGBA") for s, f in APPICONSET.items()}
        return lambda size: files[size] if size in files else files[1024].resize((size, size), Image.LANCZOS)
    im = Image.open(icon).convert("RGBA")
    return lambda size: im.resize((size, size), Image.LANCZOS)


def row(icon):
    shrink = loader(icon)
    preview = shrink(256)
    w = 256 + PAD + 2 * (64 + 32 + 16 + 4 * PAD) + 2 * (32 * 4 + 16 * 8 + 3 * PAD)
    out = Image.new("RGB", (w, 256), DARK)
    out.paste(preview, (0, 0), preview)
    x = 256 + PAD
    for bg in (DARK, LIGHT):
        block = Image.new("RGB", (64 + 32 + 16 + 4 * PAD, 256), bg)
        bx = PAD
        for s in (64, 32, 16):
            small = shrink(s)
            block.paste(small, (bx, 128 - s // 2), small)
            bx += s + PAD
        out.paste(block, (x, 0))
        x += block.width
    for bg in (DARK, LIGHT):
        block = Image.new("RGB", (32 * 4 + 16 * 8 + 3 * PAD, 256), bg)
        bx = PAD
        for s, zoom in ((32, 4), (16, 8)):
            small = shrink(s)
            canvas = Image.new("RGBA", (s, s), bg + (255,))
            canvas.alpha_composite(small)
            big = canvas.resize((s * zoom, s * zoom), Image.NEAREST)
            block.paste(big, (bx, 128 - big.height // 2))
            bx += big.width + PAD
        out.paste(block, (x, 0))
        x += block.width
    return out, os.path.basename(os.path.normpath(icon))


def main(dst, icons):
    rows = [row(p) for p in icons]
    width = max(r.width for r, _ in rows) + 2 * PAD
    height = sum(r.height + 2 * PAD for r, _ in rows) + PAD
    sheet = Image.new("RGB", (width, height), (18, 18, 20))
    draw = ImageDraw.Draw(sheet)
    y = PAD
    for r, name in rows:
        draw.text((PAD, y), name, fill=(200, 200, 200))
        sheet.paste(r, (PAD, y + PAD))
        y += r.height + 2 * PAD
    sheet.save(dst, "PNG")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2:])
