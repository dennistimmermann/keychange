#!/usr/bin/env python3
"""Builds the demo loop for the README and the landing page.

Composited, not screen-recorded, for the same reason docs/index.html composites its
hero: the popover is the real 2x capture (docs/panel.png), the menu bar is drawn to
the app's own geometry, and nothing personal from a real menu bar ships with it.

The status item animation is AppState.swapFrame ported frame for frame — two 9.2x6.9
plates trading places over 0.3s on a smoothstep, alphas crossing 1.0<->0.4, the old
code knocked out by the midpoint and the new one knocked in after it. If the mark
changes in AppState.swift, it changes here too.

The loop switches keyboard and back again, so it seams cleanly and shows the mark
animating in both directions.

Everything is laid out in points (the 1x sizes the app and the site use) and rendered
at 2x. Vector shapes go through supersampled masks because ImageDraw doesn't
antialias; text comes off FreeType, which does.

    python3 make-demo.py                # both variants
    python3 make-demo.py demo-no-loupe  # just one
    python3 make-demo.py --check        # self-check, renders nothing
"""

import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).parent
DOCS = ROOT / "docs"
S = 2          # render scale: points -> pixels
SS = 4         # supersampling for vector masks
FPS = 20

# The loupe magnifies the patch of menu bar around the status item and names the input
# source under it — the real mark is 23pt wide and the switch it shows is the whole
# point of the loop. Without it the canvas is narrower, since it needs the room.
VARIANTS = {
    "demo": {"callout": True},
    "demo-no-loupe": {"callout": False},
}

# ---------------------------------------------------------------- palette (docs/style.css)
DESK = (228, 225, 219)
PANEL = (251, 251, 252)
INK = (29, 29, 31)
HAIRLINE_A = 0.10
SHADOW_A = 0.12

SFNS = "/System/Library/Fonts/SFNS.ttf"

# ---------------------------------------------------------------- geometry (points)
M = 30                          # page margin
BAR_H = 40                      # the real menu bar's height
BAR_RADIUS = 11
CLOCK_INSET = 18                # menu bar items sit 18pt off the right edge
ITEM_GAP = 20

PANEL_W, PANEL_H = 344, 142     # the popover's true size
PANEL_GAP = 6                   # macOS hangs it this far under the bar
PANEL_Y = M + BAR_H + PANEL_GAP

# The text field is deliberately the menu bar's opposite: the bar is a raised card
# on the desk, the field is recessed into it — plain white, tighter corners, a bezel
# and an inner shadow instead of a drop shadow.
# It also must not span the bar's width or exceed its height, or the two read as a
# pair of bars however they are shaded.
FIELD_H, FIELD_RADIUS = 38, 7
FIELD_INSET = 34                # pulled in from the page margin the bar sits on
FIELD_FILL = (255, 255, 255)
FIELD_BORDER_A = 0.22
FIELD_BEVEL, FIELD_BEVEL_A = 3, 0.15
FIELD_TEXT = 17                 # smaller than a headline; it is a single-line input
CARET_H = 20

# The keyboards carry no surface of their own — ink versus grey and the typing
# animation say which one is live — so they need air between them instead.
CHIP_H, CHIP_GAP, CHIP_LABEL_GAP = 46, 36, 13

FIELD_TOP_GAP = 78              # the popover belongs up by the bar, not by the field
CHIP_TOP_GAP = 22               # tighter than the gap above: these type into it

# panel.png is a 2x capture carrying transparent shadow margin around the panel body.
SHOT_INSET_X, SHOT_INSET_Y = 23, 12.5

# The accent rail marking the active device, in capture pixels: 6x40 at x 58,
# row 2 at y 173, rows 64px apart.
RAIL_X, RAIL_W, RAIL_H, RAIL_R = 58, 6, 40, 4
RAIL_ROW_Y = [109, 173, 237]

# Status item mark, from AppState: two plates at 80% overlap, the front one lower
# left, scaled 18/8.68 out of construction units into points.
K = 18 / 8.68
BADGE_W, BADGE_H = 23, 18
PLATE_W, PLATE_H = 9.2 * K, 6.9 * K
PLATE_FRONT = (0.0, 3.69)       # (x, y-from-top)
PLATE_BACK = (1.84 * K, 0.83)
PLATE_R = 2 * K
PLATE_PUNCH = 0.4 * K           # rim gap the front plate knocks out of the back
GLYPH_SIZE = 4.8 * K

# The loupe sits on the desk left of the popover and shows a real magnified patch of
# the scene: the bar's surface and bottom edge, the strip of desk beneath it, and the
# popover's top edge. That context is what identifies it as the menu bar rather than a
# logo on a disc. The patch is drawn at the magnification, not upscaled out of the
# finished frame, so it stays as crisp as the rest. Sizes derive from the two edges it
# has to contain, so the lens can't be set to a size that crops them out.
CALLOUT_SCALE = 3
BADGE_Y = M + (BAR_H - BADGE_H) / 2        # where the mark sits in the bar
VIEW_TOP = BADGE_Y - 6                     # a little air above the mark
VIEW = (PANEL_Y + 6) - VIEW_TOP            # down past the popover's top edge
LENS_D = VIEW * CALLOUT_SCALE
LENS_RIM, LENS_RIM_A = 2, 0.3
CALLOUT_LABEL = 26              # lens bottom to the source name's baseline
CALLOUT_TEXT = 15
CALLOUT_ROOM = 60               # extra canvas width the lens needs beside the popover

# The two keyboards being typed on, in panel row order. The panel lists a third
# (MX Keys) that is connected but idle — which is the honest picture.
# "source" is spelled the way the popover's picker and macOS itself spell it.
DEVICES = [
    {"name": "Apple Internal", "row": 0, "code": "DE", "source": "German"},
    {"name": "Keychron K2", "row": 1, "code": "EN", "source": "U.S."},
]
START, SWITCHED = 1, 0          # indices into DEVICES

# ---------------------------------------------------------------- script
# One text field, two keyboards. "Grüße" is the payoff: a U.S. layout cannot
# produce ü or ß, so the switch shows up in the output and not just in the UI.
TYPED = ["Hello ", "Grüße!"]
CHAR_S = 0.105                  # seconds per keystroke
SWITCH_S = 0.30                 # AppState.animateIcon runs ~0.3s
HAND_LEAD, HAND_S = 0.17, 0.14  # the hand moves this far ahead of the app reacting

T_TYPE1 = 0.50                                                  # opening beat
T_SWITCH = T_TYPE1 + len(TYPED[0]) * CHAR_S + 0.35
T_TYPE2 = T_SWITCH + SWITCH_S + 0.25
T_RETURN = T_TYPE2 + len(TYPED[1]) * CHAR_S + 1.20              # time to read it
DURATION = T_RETURN + SWITCH_S + 0.15


def smoothstep(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def jitter(i):
    """Deterministic per-keystroke wobble, so the typing isn't metronomic."""
    return (((i * 2654435761) % 1000) / 1000 - 0.5) * 0.055


def state(t):
    """Everything time-dependent, resolved once per frame.

    `swap` drives the mark and the rail together, since in the app they are one
    event: the typing device changed. `hand` runs slightly ahead of it.
    """
    out, struck = "", False
    for start, part in zip((T_TYPE1, T_TYPE2), TYPED):
        for i, ch in enumerate(part):
            at = start + i * CHAR_S + jitter(i + int(start * 100))
            if t >= at:
                out += ch
                struck = struck or (t - at) < 0.09

    if t < T_RETURN:                            # start keyboard -> switched
        when, frm, to = T_SWITCH, START, SWITCHED
    else:                                       # and back, to close the loop
        when, frm, to = T_RETURN, SWITCHED, START
    swap = smoothstep((t - when) / SWITCH_S)
    # The hand reaches the other keyboard just before the app can react to it, so
    # the GIF reads as cause and effect rather than the panel changing by itself.
    hand = smoothstep((t - (when - HAND_LEAD)) / HAND_S)

    return {
        "text": out,
        "struck": struck,
        "swap": swap,
        "codes": (DEVICES[frm]["code"], DEVICES[to]["code"]),
        "sources": (DEVICES[frm]["source"], DEVICES[to]["source"]),
        # Snaps, because the app's row rail is a plain boolean with no animation —
        # only the status item mark animates.
        "rail": RAIL_ROW_Y[DEVICES[to if swap > 0 else frm]["row"]],
        # How active each chip is, 0-1.
        "chips": [1 - hand if i == frm else hand if i == to else 0.0
                  for i in range(len(DEVICES))],
        # The field empties as the loop returns, so the seam isn't a hard cut.
        "text_alpha": 1 - (smoothstep((t - T_RETURN) / SWITCH_S) if t >= T_RETURN else 0),
    }


# ---------------------------------------------------------------- layout
def layout(callout, chip_w):
    """Where everything sits. All values in points."""
    # Narrow enough that the desk left of the popover stays a margin rather than a
    # hole, plus the room the lens needs when there is one.
    w = 560 + (CALLOUT_ROOM if callout else 0)
    field_top = PANEL_Y + PANEL_H + FIELD_TOP_GAP
    row = field_top + FIELD_H + CHIP_TOP_GAP
    x0 = M + ((w - 2 * M) - (2 * chip_w + CHIP_GAP)) / 2    # centred under the field

    spot = None
    if callout:
        # Centred in the desk the popover leaves free on its left (clear of the
        # capture's baked shadow), and vertically between the bar and the field.
        free = (w - M - PANEL_W - SHOT_INSET_X) - M
        spot = (M + (free - LENS_D) / 2, (M + BAR_H + field_top) / 2 - LENS_D / 2)

    return {
        "callout": spot,
        "size": (w, row + CHIP_H + M),
        "bar": (M, M, w - M, M + BAR_H),
        "panel": (w - M - PANEL_W, PANEL_Y),
        "field": (M + FIELD_INSET, field_top, w - M - FIELD_INSET, field_top + FIELD_H),
        "chips": [(x0 + i * (chip_w + CHIP_GAP), row) for i in range(2)],
    }


# ---------------------------------------------------------------- drawing helpers
def rrect(size, radius, width=0):
    """Antialiased rounded-rectangle mask, supersampled then reduced."""
    w, h = int(round(size[0] * S)), int(round(size[1] * S))
    m = Image.new("L", (w * SS, h * SS), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        [0, 0, w * SS - 1, h * SS - 1], radius=radius * S * SS,
        fill=255 if width == 0 else None,
        outline=255 if width else None, width=int(width * S * SS) or 1)
    return m.resize((w, h), Image.LANCZOS)


def dim(mask, alpha):
    return mask if alpha >= 1 else mask.point(lambda v: int(v * alpha))


def card(img, box, radius):
    """A raised surface in the page's family: panel fill, hairline, whisper shadow."""
    x0, y0, x1, y1 = box
    size = (x1 - x0, y1 - y0)
    blur = rrect(size, radius).filter(ImageFilter.GaussianBlur(1.5 * S))
    img.paste(INK, (int(x0 * S), int((y0 + 1) * S)), dim(blur, SHADOW_A))
    img.paste(PANEL, (int(x0 * S), int(y0 * S)), rrect(size, radius))
    img.paste(INK, (int(x0 * S), int(y0 * S)),
              dim(rrect(size, radius, width=0.5), HAIRLINE_A))


def input_field(img, box):
    """Recessed, so it can't be mistaken for a second menu bar: white fill, a bezel
    all round, and an inner shadow under the top edge instead of a shadow beneath."""
    x0, y0, x1, y1 = box
    size = (x1 - x0, y1 - y0)
    at = (int(x0 * S), int(y0 * S))
    shape = rrect(size, FIELD_RADIUS)
    img.paste(FIELD_FILL, at, shape)

    # Everything the shape covers that its own copy — dropped by the bevel depth and
    # softened — does not: a band hugging the inside of the top edge.
    d = int(FIELD_BEVEL * S)
    lowered = Image.new("L", shape.size, 0)
    lowered.paste(shape, (0, d))
    inner = ImageChops.multiply(shape, ImageChops.invert(
        lowered.filter(ImageFilter.GaussianBlur(d))))
    img.paste(INK, at, dim(inner, FIELD_BEVEL_A))

    img.paste(INK, at, dim(rrect(size, FIELD_RADIUS, width=0.75), FIELD_BORDER_A))


def text(img, xy, s, f, color, anchor="ls"):
    ImageDraw.Draw(img).text((xy[0] * S, xy[1] * S), s, font=f, fill=color, anchor=anchor)


def blend(fg, bg, a):
    return tuple(int(b + (f - b) * a) for f, b in zip(fg, bg))


def font(size, weight="Regular"):
    f = ImageFont.truetype(SFNS, int(size * S))
    f.set_variation_by_name(weight)
    return f


# ---------------------------------------------------------------- the status item mark
def plate(mask, x, y, alpha, code, glyph_fraction, glyph_font, u):
    """AppState.drawPlate: punch a wider footprint out of everything below, fill at
    `alpha`, then knock `glyph_fraction` of the code clean through. `u` is points to
    supersampled pixels, so the same mark draws at any size."""
    size = mask.size
    px = PLATE_PUNCH * u

    punch = Image.new("L", size, 255)
    ImageDraw.Draw(punch).rounded_rectangle(
        [x - px, y - px, x + PLATE_W * u + px, y + PLATE_H * u + px],
        radius=(PLATE_R + PLATE_PUNCH) * u, fill=0)
    mask.paste(ImageChops.multiply(mask, punch))

    fill = Image.new("L", size, 0)
    ImageDraw.Draw(fill).rounded_rectangle(
        [x, y, x + PLATE_W * u, y + PLATE_H * u],
        radius=PLATE_R * u, fill=int(round(alpha * 255)))
    mask.paste(ImageChops.lighter(mask, fill))

    if code and glyph_fraction > 0:
        # Centered on the ink, not on font metrics — those drift at this size.
        g = Image.new("L", size, 0)
        ImageDraw.Draw(g).text((x + PLATE_W * u / 2, y + PLATE_H * u / 2),
                               code, font=glyph_font, fill=255, anchor="mm")
        mask.paste(ImageChops.multiply(
            mask, g.point(lambda v: 255 - int(v * glyph_fraction))))


def badge_mask(t, old_code, new_code, glyph_font, scale=1):
    """AppState.swapFrame: t=0 old code in front, t=1 new code in front — which is
    also the static mark, so a held state is just t=0 or t=1."""
    u = S * SS * scale
    mask = Image.new("L", (int(BADGE_W * u), int(BADGE_H * u)), 0)

    def lerp(a, b):
        return (a[0] + (b[0] - a[0]) * t) * u, (a[1] + (b[1] - a[1]) * t) * u

    def old():
        plate(mask, *lerp(PLATE_FRONT, PLATE_BACK), 1 - 0.6 * t,
              old_code, max(0.0, 1 - 2 * t), glyph_font, u)

    def new():
        plate(mask, *lerp(PLATE_BACK, PLATE_FRONT), 0.4 + 0.6 * t,
              new_code, max(0.0, 2 * t - 1), glyph_font, u)

    # The plate headed for the front paints on top from the midpoint on.
    if t < 0.5:
        new(), old()
    else:
        old(), new()
    return mask.resize((int(BADGE_W * S * scale), int(BADGE_H * S * scale)), Image.LANCZOS)


# ---------------------------------------------------------------- the loupe
def loupe_view(st, shot, glyph_font, bx, panel_x):
    """The magnified patch of the scene around the status item, redrawn at the lens's
    own resolution: bar surface, the bar's bottom hairline and shadow, the strip of
    desk under it, the popover's top edge, and the mark itself."""
    u = S * CALLOUT_SCALE                       # points -> pixels inside the lens
    n = int(round(VIEW * u))
    ox = bx + BADGE_W / 2 - VIEW / 2            # scene x at the lens's left edge
    view = Image.new("RGB", (n, n), DESK)

    def to_px(x, y):
        return int(round((x - ox) * u)), int(round((y - VIEW_TOP) * u))

    bar_bottom = M + BAR_H

    # The bar's own drop shadow, then its surface over the top of it, then the
    # hairline along its bottom edge — card()'s recipe at this scale.
    shade = Image.new("L", (n, n), 0)
    ImageDraw.Draw(shade).rectangle([0, 0, n, to_px(0, bar_bottom + 1)[1]], fill=255)
    view.paste(INK, (0, 0),
               dim(shade.filter(ImageFilter.GaussianBlur(1.5 * u)), SHADOW_A))
    ImageDraw.Draw(view).rectangle([0, 0, n, to_px(0, bar_bottom)[1]], fill=PANEL)
    hair = Image.new("L", (n, n), 0)
    ImageDraw.Draw(hair).rectangle(
        [0, to_px(0, bar_bottom - 0.5)[1], n, to_px(0, bar_bottom)[1]], fill=255)
    view.paste(INK, (0, 0), dim(hair, HAIRLINE_A))

    # The popover's top edge, from the capture so its real window shadow comes with it
    # (crop is 2x; out-of-bounds pads transparent), then a crisp edge over the blur.
    origin_x, origin_y = panel_x - SHOT_INSET_X, PANEL_Y - SHOT_INSET_Y
    x0 = int(round((ox - origin_x) * 2))
    y0 = int(round((VIEW_TOP - origin_y) * 2))
    patch = shot.crop((x0, y0, x0 + int(VIEW * 2), y0 + int(VIEW * 2))) \
                .resize((n, n), Image.LANCZOS)
    view.paste(patch.convert("RGB"), (0, 0), patch.split()[3])
    ImageDraw.Draw(view).rectangle([0, to_px(0, PANEL_Y)[1], n, n], fill=PANEL)

    view.paste(INK, to_px(bx, BADGE_Y),
               badge_mask(st["swap"], *st["codes"], glyph_font, CALLOUT_SCALE))
    return view


# ---------------------------------------------------------------- keyboard glyph
KB_W, KB_H, KB_PAD, KB_GAP = 38, 25, 5, 2.4
KB_ROWS = [[1] * 6, [1] * 6, [1, 4, 1]]     # last row is the space bar
KB_KEYS = sum(len(r) for r in KB_ROWS)


def keyboard(img, x, y, color, lit):
    """A keyboard outline with keycaps; `lit` ones fill in, to read as typing."""
    img.paste(color, (int(x * S), int(y * S)), rrect((KB_W, KB_H), 4, width=1))
    row_h = (KB_H - 2 * KB_PAD - KB_GAP * (len(KB_ROWS) - 1)) / len(KB_ROWS)
    n = 0
    for r, widths in enumerate(KB_ROWS):
        ky = y + KB_PAD + r * (row_h + KB_GAP)
        unit = (KB_W - 2 * KB_PAD - KB_GAP * (len(widths) - 1)) / sum(widths)
        kx = x + KB_PAD
        for w in widths:
            kw = unit * w
            on = n in lit
            img.paste(color, (int(kx * S), int(ky * S)),
                      dim(rrect((kw, row_h), 1.2, width=0 if on else 0.75),
                          1.0 if on else 0.6))
            kx += kw + KB_GAP
            n += 1


# ---------------------------------------------------------------- the popover capture
def load_shot():
    """The real capture, with the accent rail painted out so it can be redrawn on any
    row."""
    shot = Image.open(DOCS / "panel.png").convert("RGBA")
    accent = shot.getpixel((RAIL_X + RAIL_W // 2, RAIL_ROW_Y[1] + RAIL_H // 2))[:3]
    bg = shot.getpixel((RAIL_X - 6, RAIL_ROW_Y[1] + RAIL_H // 2))
    # ponytail: the rail sits on flat panel background, so a solid fill erases it
    # invisibly. Re-measure the box above if the popover's row metrics ever change.
    ImageDraw.Draw(shot).rectangle(
        [RAIL_X - 3, RAIL_ROW_Y[1] - 3, RAIL_X + RAIL_W + 2, RAIL_ROW_Y[1] + RAIL_H + 2],
        fill=bg)
    return shot, accent


# ---------------------------------------------------------------- frame
def frame(t, shot, accent, fonts, L):
    st = state(t)
    w, h = L["size"]
    img = Image.new("RGB", (w * S, h * S), DESK)
    bar, field = L["bar"], L["field"]

    card(img, bar, BAR_RADIUS)
    input_field(img, field)

    # --- the popover, rail on the active row
    px, py = L["panel"]
    panel = shot.copy()
    panel.paste(accent, (RAIL_X, int(round(st["rail"]))),
                rrect((RAIL_W / S, RAIL_H / S), RAIL_R / S))   # capture px are 2x
    img.paste(panel, (int((px - SHOT_INSET_X) * S), int((py - SHOT_INSET_Y) * S)), panel)

    # --- menu bar items, right to left: clock, then the status item
    clock = "Thu 30. Jul   09:41"
    cw = fonts["bar"].getlength(clock) / S
    text(img, (bar[2] - CLOCK_INSET, bar[1] + 26), clock, fonts["bar"], INK, anchor="rs")
    bx = bar[2] - CLOCK_INSET - cw - ITEM_GAP - BADGE_W
    img.paste(INK, (int(bx * S), int(BADGE_Y * S)),
              badge_mask(st["swap"], *st["codes"], fonts["glyph"]))

    # --- the same patch of bar under a loupe, since 23pt is small for the whole point
    if L["callout"]:
        qx, qy = L["callout"]
        at = (int(qx * S), int(qy * S))
        lens = rrect((LENS_D, LENS_D), LENS_D / 2)          # radius = half: a circle
        img.paste(INK, (int(qx * S), int((qy + 1) * S)),
                  dim(lens.filter(ImageFilter.GaussianBlur(2 * S)), SHADOW_A))
        img.paste(loupe_view(st, shot, fonts["glyph_big"], bx, px), at, lens)
        img.paste(INK, at, dim(rrect((LENS_D, LENS_D), LENS_D / 2, width=LENS_RIM),
                               LENS_RIM_A))

        # The name crosses over on the mark's own timing: the outgoing one is gone by
        # the midpoint, the incoming one appears after it, exactly like the code.
        base = (qx + LENS_D / 2, qy + LENS_D + CALLOUT_LABEL)
        for name, shown in zip(st["sources"], (max(0.0, 1 - 2 * st["swap"]),
                                               max(0.0, 2 * st["swap"] - 1))):
            if shown > 0:
                text(img, base, name, fonts["source"],
                     blend(INK, DESK, shown), anchor="ms")

    # --- which keyboard you are typing on
    lit = {(len(st["text"]) * 5 + 3) % KB_KEYS,
           (len(st["text"]) * 7 + 8) % KB_KEYS} if st["struck"] else set()
    for i, (dev, (cx, cy)) in enumerate(zip(DEVICES, L["chips"])):
        active = st["chips"][i] > 0.5
        color = INK if active else blend(INK, DESK, 0.42)
        keyboard(img, cx, cy + (CHIP_H - KB_H) / 2, color, lit if active else set())
        text(img, (cx + KB_W + CHIP_LABEL_GAP, cy + CHIP_H / 2 + 5),
             dev["name"], fonts["chip"], color)

    # --- one text field, two keyboards
    tx, a = field[0] + 14, st["text_alpha"]
    # Cap height is a little under 3/4 of the size, which is close enough to centre it.
    text(img, (tx, field[1] + (FIELD_H + FIELD_TEXT * 0.72) / 2), st["text"],
         fonts["field"], blend(INK, FIELD_FILL, a))
    if a > 0.5 and (st["struck"] or (t % 1.0) < 0.55):
        cx = tx + fonts["field"].getlength(st["text"]) / S + 2
        img.paste(INK, (int(cx * S), int((field[1] + (FIELD_H - CARET_H) / 2) * S)),
                  rrect((1.5, CARET_H), 0.75))
    return img


# ---------------------------------------------------------------- build
def chip_width(chip_font):
    """Both keyboards get the widest label's width, so the pair sits symmetrically."""
    return KB_W + CHIP_LABEL_GAP + max(
        chip_font.getlength(d["name"]) for d in DEVICES) / S


def build(name, spec, shot, accent, fonts):
    L = layout(spec["callout"], chip_width(fonts["chip"]))

    out = ROOT / "build" / f"frames-{name}"
    out.mkdir(parents=True, exist_ok=True)
    for f in out.glob("*.png"):
        f.unlink()

    n = int(round(DURATION * FPS))
    for i in range(n):
        frame(i / FPS, shot, accent, fonts, L).save(out / f"{i:04d}.png")
        print(f"\r  {name}: frame {i + 1}/{n}", end="", flush=True)

    gif, mp4 = DOCS / f"{name}.gif", DOCS / f"{name}.mp4"
    scale = f"scale={L['size'][0]}:-1:flags=lanczos"
    # Flat surfaces and soft shadows: a full palette with no dithering beats any
    # dither pattern here, and is smaller — the artwork has few colours to begin with.
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(FPS),
                    "-i", str(out / "%04d.png"), "-filter_complex",
                    f"{scale},split[a][b];[a]palettegen=max_colors=256[p];"
                    f"[b][p]paletteuse=dither=none",
                    "-loop", "0", str(gif)], check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(FPS),
                    "-i", str(out / "%04d.png"), "-vf", scale,
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20",
                    "-movflags", "+faststart", str(mp4)], check=True)
    print(f"\r  {name}: {L['size'][0]}x{L['size'][1]}, "
          f"gif {gif.stat().st_size / 1024:.0f} KB, mp4 {mp4.stat().st_size / 1024:.0f} KB")


def main(names):
    shot, accent = load_shot()

    def mark_glyph(scale):
        f = ImageFont.truetype(SFNS, int(GLYPH_SIZE * S * SS * scale))
        f.set_variation_by_name("Bold")
        return f

    fonts = {"bar": font(14), "chip": font(13, "Medium"),
             "field": font(FIELD_TEXT), "source": font(CALLOUT_TEXT, "Medium"),
             "glyph": mark_glyph(1), "glyph_big": mark_glyph(CALLOUT_SCALE)}
    for name in names or VARIANTS:
        build(name, VARIANTS[name], shot, accent, fonts)


def demo():
    """Self-check: the loop must start and end in the same visual state, or the GIF
    seams badly; the hand must lead the app; both layouts must fit their canvas."""
    a, b = state(0.0), state(DURATION - 1 / FPS)
    assert a["text"] == "" and a["text_alpha"] == 1, a
    assert b["text_alpha"] < 0.05, b["text_alpha"]
    assert abs(a["rail"] - b["rail"]) < 0.5, (a["rail"], b["rail"])
    assert a["chips"] == b["chips"], (a["chips"], b["chips"])

    mid = state((T_TYPE2 + T_RETURN) / 2)
    assert mid["text"] == "".join(TYPED), mid["text"]
    assert a["codes"][0] == "EN" and mid["codes"][1] == "DE", (a["codes"], mid["codes"])
    assert abs(mid["rail"] - RAIL_ROW_Y[0]) < 0.5, mid["rail"]

    # The chip must flip at least a frame before the app reacts, or the switch looks
    # like the panel deciding on its own.
    lead = state(T_SWITCH - 1.5 / FPS)
    assert lead["chips"][SWITCHED] > 0.5 and lead["swap"] == 0, lead["chips"]

    # The lens has to contain both edges that identify it as the menu bar.
    assert VIEW_TOP < BADGE_Y and VIEW_TOP + VIEW > PANEL_Y, (VIEW_TOP, VIEW)

    for name, spec in VARIANTS.items():
        L = layout(spec["callout"], 180)
        w, h = L["size"]
        assert L["field"][2] <= w - M and L["field"][3] <= h - M, name
        for cx, cy in L["chips"]:
            assert cx >= M and cy + CHIP_H <= h - M + 0.5, (name, cx, cy)
        assert L["panel"][0] >= M, name
        if L["callout"]:
            qx, qy = L["callout"]
            # The loupe must clear the popover's baked-in shadow, not just its body.
            assert qx >= M and qx + LENS_D <= L["panel"][0] - SHOT_INSET_X, name
            # And clear the bar above and the field below, label included.
            assert qy >= M + BAR_H, name
            assert qy + LENS_D + CALLOUT_LABEL <= L["field"][1], name
    print(f"demo: loop seams, hand leads the app, {len(VARIANTS)} layouts fit")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    sys.exit(demo() if "--check" in sys.argv else main(args))
