#!/usr/bin/env python3
"""Build a 1024x1024 app-icon PNG: a clean white rounded tile with the RaceStudio 3 wordmark
(gray RS + red 3 / RACESTUDIO) centered. The RS3 logo is colored on transparency, so a white
tile suits it best.
Usage: compose-icon.py <rs3-logo.png> <out.png>
"""
import sys
from PIL import Image, ImageDraw

S = 1024
logo_path, out_path = sys.argv[1], sys.argv[2]

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
# white rounded tile with a faint border
d.rounded_rectangle([24, 24, S - 24, S - 24], radius=200, fill=(255, 255, 255, 255))
d.rounded_rectangle([24, 24, S - 24, S - 24], radius=200, outline=(210, 214, 220, 255), width=6)

logo = Image.open(logo_path).convert("RGBA")
# the wordmark is wide (≈280x84) — scale to ~72% of the tile width
target_w = int(S * 0.72)
scale = target_w / logo.width
logo = logo.resize((target_w, max(1, int(logo.height * scale))), Image.LANCZOS)
img.paste(logo, ((S - logo.width) // 2, (S - logo.height) // 2), logo)

img.save(out_path, "PNG")
print("wrote", out_path)
