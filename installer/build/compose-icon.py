#!/usr/bin/env python3
"""Build a 1024x1024 app-icon PNG: dark rounded square + centered Rush logo.
Usage: compose-icon.py <logo.png> <out.png>
"""
import sys
from PIL import Image, ImageDraw

S = 1024
logo_path, out_path = sys.argv[1], sys.argv[2]

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
# dark rounded square (macOS-ish squircle approximation), thin orange rim
d.rounded_rectangle([24, 24, S - 24, S - 24], radius=200, fill=(20, 22, 26, 255))
d.rounded_rectangle([24, 24, S - 24, S - 24], radius=200, outline=(255, 122, 0, 255), width=10)

logo = Image.open(logo_path).convert("RGBA")
scale = min((S * 0.60) / logo.width, (S * 0.60) / logo.height)
logo = logo.resize((int(logo.width * scale), int(logo.height * scale)), Image.LANCZOS)
img.paste(logo, ((S - logo.width) // 2, (S - logo.height) // 2), logo)

img.save(out_path, "PNG")
print("wrote", out_path)
