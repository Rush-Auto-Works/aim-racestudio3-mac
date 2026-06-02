#!/usr/bin/env python3
"""Compose the drag-to-Applications DMG background: Rush Auto Works logo on top, a big arrow
pointing from the app slot to the Applications slot, and a one-line instruction.

Usage: compose-dmg-bg.py <logo.png> <out.png>
The canvas + icon-slot coordinates here MUST match the Finder layout in build-apps.sh.
"""
import sys
from PIL import Image, ImageDraw, ImageFont

W, H = 640, 420
LEFT_SLOT = (160, 215)   # center of the app icon
RIGHT_SLOT = (480, 215)  # center of the Applications alias
DARK = (18, 20, 24, 255)
FG = (235, 238, 242, 255)
ACCENT = (255, 122, 0, 255)  # Rush orange


def load_font(size, bold=False):
    for path in [
        "/System/Library/Fonts/SFNSDisplay.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/Library/Fonts/Arial.ttf",
    ]:
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            continue
    return ImageFont.load_default()


def main():
    logo_path, out_path = sys.argv[1], sys.argv[2]
    img = Image.new("RGBA", (W, H), DARK)
    d = ImageDraw.Draw(img)

    # logo, scaled to ~260px wide, centered near the top
    try:
        logo = Image.open(logo_path).convert("RGBA")
        scale = 260 / logo.width
        logo = logo.resize((260, max(1, int(logo.height * scale))), Image.LANCZOS)
        img.paste(logo, ((W - logo.width) // 2, 28), logo)
    except Exception as e:
        d.text((W // 2, 50), "Rush Auto Works", fill=FG, anchor="mm", font=load_font(28, True))

    # arrow from just right of the app slot to just left of the Applications slot
    y = LEFT_SLOT[1]
    x0, x1 = LEFT_SLOT[0] + 78, RIGHT_SLOT[0] - 78
    d.line([(x0, y), (x1 - 14, y)], fill=ACCENT, width=8)
    d.polygon([(x1, y), (x1 - 20, y - 14), (x1 - 20, y + 14)], fill=ACCENT)  # arrowhead

    # instruction line under the slots
    d.text((W // 2, 340), "Drag  RaceStudio 3  into  Applications",
           fill=FG, anchor="mm", font=load_font(20, True))
    d.text((W // 2, 372), "then open it from Applications — the first launch sets everything up",
           fill=(150, 156, 164, 255), anchor="mm", font=load_font(13))

    img.convert("RGB").save(out_path, "PNG")
    print("wrote", out_path)


if __name__ == "__main__":
    main()
