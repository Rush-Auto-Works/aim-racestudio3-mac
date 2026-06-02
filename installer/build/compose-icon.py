#!/usr/bin/env python3
"""Build a 1024x1024 app-icon PNG: a clean white rounded tile with the (colored) RaceStudio 3
logo centered. Usage: compose-icon.py <rs3-logo.png> <out.png>
"""
import sys
from PIL import Image, ImageDraw

S = 1024
if len(sys.argv) != 3:
    raise SystemExit(f"Usage: {sys.argv[0]} <rs3-logo.png> <out.png>")
logo_path, out_path = sys.argv[1], sys.argv[2]

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
# white rounded tile with a faint border
d.rounded_rectangle([24, 24, S - 24, S - 24], radius=200, fill=(255, 255, 255, 255))
d.rounded_rectangle([24, 24, S - 24, S - 24], radius=200, outline=(214, 218, 224, 255), width=6)

try:
    logo = Image.open(logo_path).convert("RGBA")
except (OSError, ValueError) as exc:
    raise SystemExit(f"failed to load logo '{logo_path}': {exc}")
if logo.width == 0 or logo.height == 0:
    raise SystemExit(f"logo '{logo_path}' has zero dimensions: {logo.width}x{logo.height}")
bbox = logo.getbbox()                      # trim transparent margins so it sits centered + sized right
if bbox:
    logo = logo.crop(bbox)
target = int(S * 0.80)                      # fit within ~80% of the tile (fuller, small margin)
scale = min(target / logo.width, target / logo.height)
logo = logo.resize((max(1, int(logo.width * scale)), max(1, int(logo.height * scale))), Image.LANCZOS)
img.paste(logo, ((S - logo.width) // 2, (S - logo.height) // 2), logo)

img.save(out_path, "PNG")
print("wrote", out_path)
