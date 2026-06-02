#!/usr/bin/env python3
"""Build a 1024x1024 app-icon PNG: a dark rounded tile (Rush dark + orange rim) with the white
RaceStudio 3 wordmark centered. The RS3 wordmark we have is white, so it needs a dark tile to read.
Usage: compose-icon.py <rs3-white-logo.png> <out.png>
"""
import sys
from PIL import Image, ImageDraw

S = 1024
logo_path, out_path = sys.argv[1], sys.argv[2]

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
d.rounded_rectangle([24, 24, S - 24, S - 24], radius=200, fill=(22, 24, 28, 255))
d.rounded_rectangle([24, 24, S - 24, S - 24], radius=200, outline=(255, 122, 0, 255), width=10)

logo = Image.open(logo_path).convert("RGBA")
# wide wordmark (~280x84) — scale to ~70% of the tile width
target_w = int(S * 0.70)
scale = target_w / logo.width
logo = logo.resize((target_w, max(1, int(logo.height * scale))), Image.LANCZOS)
img.paste(logo, ((S - logo.width) // 2, (S - logo.height) // 2), logo)

img.save(out_path, "PNG")
print("wrote", out_path)
