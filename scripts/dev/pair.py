#!/usr/bin/env python3
"""Figma frame above, capture below, scaled to the same width — for comparing by eye.

    scripts/dev/pair.py FIGMA.png CAPTURE.png OUT.png

Figma exports are 1x, captures are 2x Retina; both are scaled to the wider of the two.
A magenta bar separates them so neither edge can be mistaken for the other's.
"""
import sys
from PIL import Image

top_path, bottom_path, out_path = sys.argv[1:4]
top = Image.open(top_path).convert("RGBA")
bottom = Image.open(bottom_path).convert("RGBA")
width = max(top.width, bottom.width)
top = top.resize((width, round(top.height * width / top.width)), Image.LANCZOS)
bottom = bottom.resize((width, round(bottom.height * width / bottom.width)), Image.LANCZOS)
out = Image.new("RGBA", (width, top.height + bottom.height + 8), (255, 0, 255, 255))
out.paste(top, (0, 0))
out.paste(bottom, (0, top.height + 8))
out.save(out_path)
print(out_path)
