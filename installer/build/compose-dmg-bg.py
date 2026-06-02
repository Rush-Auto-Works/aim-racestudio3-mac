#!/usr/bin/env python3
"""Compose the drag-to-Applications DMG background: WHITE background (so any window area beyond
the image blends in seamlessly), black Rush Auto Works logo on top, an orange arrow from the app
slot to the Applications slot, and a black caption.

Usage: compose-dmg-bg.py <black-logo.png> <out.png>
The canvas + icon-slot coordinates here MUST match the Finder layout in build-apps.sh.
"""
import sys
from PIL import Image, ImageDraw, ImageFont

W, H = 640, 520
LEFT_SLOT = (160, 235)    # center of the app icon
RIGHT_SLOT = (480, 235)   # center of the Applications alias
WHITE = (255, 255, 255, 255)
BLACK = (20, 22, 26, 255)
GRAY = (130, 136, 144, 255)
ACCENT = (255, 122, 0, 255)  # Rush orange


def load_font(size, bold=False):
    names = (["SFNSDisplay-Bold.otf", "HelveticaNeue-Bold.ttf"] if bold else
             ["SFNSDisplay.ttf", "HelveticaNeue.ttf"])
    paths = [f"/System/Library/Fonts/{n}" for n in names] + [
        "/System/Library/Fonts/Helvetica.ttc",
        "/Library/Fonts/Arial.ttf",
    ]
    for p in paths:
        try:
            return ImageFont.truetype(p, size)
        except Exception:
            continue
    return ImageFont.load_default()


def main():
    logo_path, out_path = sys.argv[1], sys.argv[2]
    img = Image.new("RGBA", (W, H), WHITE)
    d = ImageDraw.Draw(img)

    # black logo, ~240px wide, centered near the top
    try:
        logo = Image.open(logo_path).convert("RGBA")
        scale = 240 / logo.width
        logo = logo.resize((240, max(1, int(logo.height * scale))), Image.LANCZOS)
        img.paste(logo, ((W - logo.width) // 2, 48), logo)
    except Exception:
        d.text((W // 2, 60), "RUSH AUTO WORKS", fill=BLACK, anchor="mm", font=load_font(30, True))

    # orange arrow between the two icon slots
    y = LEFT_SLOT[1]
    x0, x1 = LEFT_SLOT[0] + 82, RIGHT_SLOT[0] - 82
    d.line([(x0, y), (x1 - 16, y)], fill=ACCENT, width=9)
    d.polygon([(x1, y), (x1 - 22, y - 15), (x1 - 22, y + 15)], fill=ACCENT)

    # caption, below the icon name labels (which sit ~y=310 under 128px icons)
    d.text((W // 2, 410), "Drag  RaceStudio 3  into  Applications",
           fill=BLACK, anchor="mm", font=load_font(21, True))
    d.text((W // 2, 444), "then open it from Applications — the first launch sets everything up",
           fill=GRAY, anchor="mm", font=load_font(13))

    img.convert("RGB").save(out_path, "PNG")
    print("wrote", out_path)


if __name__ == "__main__":
    main()
