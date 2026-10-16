#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Polka's splash and library icon for the Kindle launcher.

    python3 kindle/make_images.py <fonts dir> <output dir>

<fonts dir> holds NotoSerif-Bold.ttf and NotoSans-Regular.ttf (KOReader ships
them in fonts/noto). The drawing follows the approved mockup (kindle-splash):
books on a shelf, «Полка», «Открываю библиотеку…», laid out on a 600-unit-wide
page and scaled to each screen. 8-bit grayscale PNGs, as eips wants them.
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

SIZES = [(600, 800), (758, 1024), (1072, 1448), (1236, 1648), (1264, 1680), (1860, 2480)]
SS = 4  # supersampling
INK, TEXT2 = 0x11, 0x33


def shelf(draw, x0, y0, k, stroke):
    """The sign: viewBox 148 x 112 at (x0, y0), k pixels per unit."""
    def P(x, y):
        return (x0 + x * k, y0 + y * k)

    def rect(x, y, w, h):
        draw.rounded_rectangle([P(x, y), P(x + w, y + h)], radius=2 * k, outline=INK, width=round(stroke))

    def rule(x1, y, x2):
        draw.line([P(x1, y), P(x2, y)], fill=INK, width=round(stroke))

    rect(14, 22, 22, 80)
    rule(14, 36, 36)
    rule(14, 88, 36)
    rect(40, 10, 18, 92)
    rule(40, 26, 58)
    rect(62, 30, 26, 72)
    rule(62, 44, 88)
    rule(62, 90, 88)
    # the leaning book: turned 14 degrees around (107, 104)
    a = math.radians(14)
    ca, sa = math.cos(a), math.sin(a)

    def rot(x, y):
        dx, dy = x - 107, y - 104
        return P(107 + dx * ca - dy * sa, 104 + dx * sa + dy * ca)
    corners = [rot(98, 24), rot(116, 24), rot(116, 104), rot(98, 104)]
    draw.line(corners + [corners[0]], fill=INK, width=round(stroke), joint="curve")
    # the shelf, with round ends
    w = 5 * k * stroke / (3.5 * k)
    ya = y0 + 104 * k
    draw.line([P(4, 104), P(144, 104)], fill=INK, width=round(w))
    for x in (4, 144):
        cx = x0 + x * k
        draw.ellipse([cx - w / 2, ya - w / 2, cx + w / 2, ya + w / 2], fill=INK)


def splash(W, H, fonts, line="Открываю библиотеку…"):
    s = W / 600.0 * SS
    img = Image.new("L", (W * SS, H * SS), 255)
    d = ImageDraw.Draw(img)
    serif = ImageFont.truetype(os.path.join(fonts, "NotoSerif-Bold.ttf"), round(76 * s))
    sans = ImageFont.truetype(os.path.join(fonts, "NotoSans-Regular.ttf"), round(16 * s))
    # the block (sign, 22 units, the word with line-height 1) in the middle
    block = (112 + 22 + 76) * s
    top = (H * SS - block) / 2
    shelf(d, (W * SS - 148 * s) / 2, top, s, 3.5 * s)
    baseline = top + (112 + 22) * s + 0.888 * 76 * s
    d.text((W * SS / 2, baseline), "Полка", font=serif, fill=INK, anchor="ms")
    # the line at the bottom, 64 units above the edge
    box_bottom = H * SS - 64 * s
    box_top = box_bottom - 1.362 * 16 * s
    d.text((W * SS / 2, box_top + 1.069 * 16 * s), line, font=sans, fill=TEXT2, anchor="ms")
    return img.resize((W, H), Image.LANCZOS)


def icon(fonts, W=600, H=900):
    """The «book» in the Kindle library: the sign and the name on white."""
    s = W / 600.0 * SS
    img = Image.new("L", (W * SS, H * SS), 255)
    d = ImageDraw.Draw(img)
    serif = ImageFont.truetype(os.path.join(fonts, "NotoSerif-Bold.ttf"), round(110 * s))
    k = 2.4 * s
    top = H * SS * 0.30
    shelf(d, (W * SS - 148 * k) / 2, top, k, 3.5 * k)
    d.text((W * SS / 2, top + (112 + 40) * k + 0.888 * 110 * s), "Полка", font=serif, fill=INK, anchor="ms")
    return img.resize((W, H), Image.LANCZOS)


def main():
    fonts, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    for W, H in SIZES:
        path = os.path.join(out, f"splash-{W}x{H}.png")
        splash(W, H, fonts).save(path, optimize=True)
        print(path, os.path.getsize(path))
    path = os.path.join(out, "icon.png")
    icon(fonts).save(path, optimize=True)
    print(path, os.path.getsize(path))


if __name__ == "__main__":
    main()
