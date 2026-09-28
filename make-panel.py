#!/usr/bin/env python3
"""Builds docs/assets/panel-ink.png, the popover the landing page's hero shows.

docs/assets/panel.png is the real 2x capture, soft shadow and accent rail included. The hero
prints it in the page's two inks instead, the way the launch video does: cropped to
the panel itself (its shadow is drawn by the page, in dots), the rail painted out
(the page draws it live, on whichever row is being typed on), and every pixel mapped
by luminance onto navy ink or white.

    python3 make-panel.py
"""

from pathlib import Path

from PIL import Image, ImageDraw

DOCS = Path(__file__).parent / "docs"

INK, PAPER = (35, 43, 74), (255, 255, 255)      # --ink, --panel in docs/assets/style.css

# In capture pixels. The panel body inside the shadow margin, and the rail on row 1:
# 6x40 at x 58, y 173.
BODY = (46, 25, 734, 309)                       # 688x284: 344x142pt at 2x
RAIL = (58 - 3, 173 - 3, 58 + 6 + 2, 173 + 40 + 2)


def smoothstep(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def main():
    shot = Image.open(DOCS / "assets" / "panel.png").convert("RGBA")

    # ponytail: the rail sits on flat panel background, so a solid fill erases it.
    # Re-measure RAIL if the popover's row metrics ever change.
    bg = shot.getpixel((RAIL[0] - 3, RAIL[1] + 23))
    ImageDraw.Draw(shot).rectangle(RAIL, fill=bg)
    shot = shot.crop(BODY)

    # The video's curve: anything darker than a quarter is solid ink, and the panel's
    # own near-white fill lands on paper. Alpha keeps only the body, so the corners
    # stay round and the baked-in shadow drops out.
    luma = shot.convert("L")
    k = lambda v: max(0.0, min(1.0, (v / 255 - 0.25) / 0.72))
    inks = [luma.point(lambda v, i=i, p=p: round(i + (p - i) * k(v))) for i, p in zip(INK, PAPER)]
    alpha = shot.getchannel("A").point(lambda v: round(255 * smoothstep((v / 255 - 0.8) / 0.2)))
    Image.merge("RGBA", (*inks, alpha)).save(DOCS / "assets" / "panel-ink.png", optimize=True)
    print(f"panel-ink.png: {shot.width}x{shot.height}")


if __name__ == "__main__":
    main()
