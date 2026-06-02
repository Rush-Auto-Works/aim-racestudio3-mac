#!/usr/bin/env python3
"""Build a 1024x1024 app-icon PNG: a white rounded tile with the (colored) RaceStudio 3 logo.

With an optional badge the helper apps are made visually distinct from the main app: a smaller
logo plus a bottom-left corner badge. "import" = orange, a document and an arrow pointing right
into the RS3 logo (a file going into RS3); "uninstall" = red, a trash can.

Usage: compose-icon.py <rs3-logo.png> <out.png> [badge: none|import|uninstall]
"""
import sys
from PIL import Image, ImageDraw

S = 1024
if not (3 <= len(sys.argv) <= 4):
    raise SystemExit(f"Usage: {sys.argv[0]} <rs3-logo.png> <out.png> [none|import|uninstall]")
logo_path, out_path = sys.argv[1], sys.argv[2]
badge = sys.argv[3] if len(sys.argv) > 3 else "none"
if badge not in ("none", "import", "uninstall"):
    raise SystemExit(f"badge must be none|import|uninstall, got {badge!r}")

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
bbox = logo.getbbox()                      # trim transparent margins
if bbox:
    logo = logo.crop(bbox)

# Badged icons use a smaller logo nudged toward the top, leaving the lower-right for the badge.
frac = 0.80 if badge == "none" else 0.56
target = int(S * frac)
scale = min(target / logo.width, target / logo.height)
logo = logo.resize((max(1, int(logo.width * scale)), max(1, int(logo.height * scale))), Image.LANCZOS)
cy = (S - logo.height) // 2 if badge == "none" else int(S * 0.36) - logo.height // 2
img.paste(logo, ((S - logo.width) // 2, cy), logo)


def draw_badge(kind):
    # Both badges sit bottom-LEFT for consistency (import's arrow points right, into RS3).
    bx, by, r = int(S * 0.30), int(S * 0.70), int(S * 0.195)
    white = (255, 255, 255, 255)
    d.ellipse([bx - r - 16, by - r - 16, bx + r + 16, by + r + 16], fill=white)   # halo
    color = (255, 122, 0, 255) if kind == "import" else (211, 47, 47, 255)        # orange / red
    d.ellipse([bx - r, by - r, bx + r, by + r], fill=color)
    w = max(10, int(r * 0.16))
    if kind == "import":   # a document with an arrow pointing right into RS3 (file -> rs3)
        dx0, dy0 = bx - int(r * 0.55), by - int(r * 0.40)
        dw, dh = int(r * 0.42), int(r * 0.80)
        d.rounded_rectangle([dx0, dy0, dx0 + dw, dy0 + dh], radius=int(r * 0.06), fill=white)  # doc
        d.polygon([(dx0 + dw - int(r * 0.16), dy0), (dx0 + dw, dy0),
                   (dx0 + dw, dy0 + int(r * 0.16))], fill=color)                                # folded corner
        d.line([(bx - int(r * 0.02), by), (bx + int(r * 0.42), by)], fill=white, width=w)       # arrow shaft
        d.polygon([(bx + int(r * 0.30), by - int(r * 0.22)),
                   (bx + int(r * 0.30), by + int(r * 0.22)),
                   (bx + int(r * 0.58), by)], fill=white)                                        # arrowhead
    else:                  # uninstall: trash can
        d.rectangle([bx - int(r * 0.15), by - int(r * 0.54), bx + int(r * 0.15), by - int(r * 0.44)], fill=white)  # handle
        d.rectangle([bx - int(r * 0.50), by - int(r * 0.44), bx + int(r * 0.50), by - int(r * 0.32)], fill=white)  # lid
        d.polygon([(bx - int(r * 0.40), by - int(r * 0.26)), (bx + int(r * 0.40), by - int(r * 0.26)),
                   (bx + int(r * 0.32), by + int(r * 0.54)), (bx - int(r * 0.32), by + int(r * 0.54))], fill=white)  # body
        rib = max(6, int(r * 0.07))
        for dx in (-0.16, 0.0, 0.16):
            d.line([(bx + int(r * dx), by - int(r * 0.14)), (bx + int(r * dx * 0.82), by + int(r * 0.44))], fill=color, width=rib)


if badge != "none":
    draw_badge(badge)

img.save(out_path, "PNG")
print("wrote", out_path, "badge=" + badge)
