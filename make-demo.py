#!/usr/bin/env python3
"""Builds the demo loop for the README and the landing page.

Composited, not screen-recorded, for the same reason docs/index.html composites its
hero: the popover is the real 2x capture (docs/panel.png), the menu bar is drawn to
the app's own geometry, and nothing personal from a real menu bar ships with it.

The status item animation is AppState.swapFrame ported frame for frame — two 9.2x6.9
plates trading places over 0.3s on a smoothstep, alphas crossing 1.0<->0.4, the old
code knocked out by the midpoint and the new one knocked in after it. If the mark
changes in AppState.swift, it changes here too.

The loop types a sentence on each of the three keyboards the popover lists — U.S.,
German, 2-Set Korean — then switches back to the first, so it seams cleanly and shows
the mark animating between every pair.

Everything is laid out in points (the 1x sizes the app and the site use) and rendered
at 2x. Vector shapes go through supersampled masks because ImageDraw doesn't
antialias; text comes off FreeType, which does.

    python3 make-demo.py                # every variant
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
# "og" wraps the plain scene in the 1200x630 share card, laid out like og.html — the
# animated companion to og.png. It starts on the payoff frame rather than the empty
# field, because most platforms (Facebook, LinkedIn, Slack, iMessage, Mastodon) show a
# still of a link preview; only Discord and Telegram animate one. It also stands alone
# as the image to attach to a post, where GIFs do play.
VARIANTS = {
    "demo": {"callout": True},
    "demo-no-loupe": {"callout": False},
    "og": {"callout": True, "card": True},
}

# ---------------------------------------------------------------- palette (docs/style.css)
DESK = (228, 225, 219)
PANEL = (251, 251, 252)
INK = (29, 29, 31)
BODY = (87, 83, 76)             # --body
FOOTER = (79, 75, 69)           # --footer
HAIRLINE_A = 0.10
SHADOW_A = 0.12

SFNS = "/System/Library/Fonts/SFNS.ttf"
SFMONO = "/System/Library/Fonts/SFNSMono.ttf"    # the page's body voice
# SF Pro has no Hangul — it renders tofu — and PIL does no font fallback, so the
# Korean leg of the typing needs the font macOS itself falls back to.
SFKOREAN = "/System/Library/Fonts/AppleSDGothicNeo.ttc"

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
# Three of them now, so the air between comes down a little to keep the row inside
# the narrower canvas; still enough that they don't clump without surfaces.
CHIP_H, CHIP_GAP, CHIP_LABEL_GAP = 46, 30, 13

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
# How much of the bar's height the lens covers. Riding the bar's bottom edge rather
# than sitting clear of it is most of what makes it read as a glass held over the bar;
# it can only do that where the bar is empty, which is everywhere left of the clock.
LENS_BAR_OVERLAP = 0.5

# All three keyboards the popover lists, in its row order. `name` is abbreviated the
# way the popover itself truncates the internal keyboard; `code` is what AppState puts
# in the menu bar (the input source's first language, uppercased); `source` is spelled
# the way the picker and macOS spell it.
DEVICES = [
    {"name": "Apple Internal", "row": 0, "code": "DE", "source": "German"},
    {"name": "Keychron K2", "row": 1, "code": "EN", "source": "U.S."},
    {"name": "MX Keys", "row": 2, "code": "KO", "source": "2-Set Korean"},
]

# ---------------------------------------------------------------- script
# One text field, three keyboards, one sentence per layout. Each leg is the payoff for
# the one before it: a U.S. layout cannot produce ü or ß, and neither can produce 안녕.
# ponytail: the Korean leg reveals finished syllables. 2-Set Korean really composes
# them from jamo across several keystrokes, which is a beat this loop does not have
# room for. Model it properly if the demo ever slows down enough to show it.
LEGS = [
    (1, "Hello "),              # Keychron K2 — U.S.
    (0, "Grüße! "),             # Apple Internal — German
    (2, "안녕!"),                # MX Keys — 2-Set Korean
]
FULL_TEXT = "".join(part for _, part in LEGS)

CHAR_S = 0.105                  # seconds per keystroke
SWITCH_S = 0.30                 # AppState.animateIcon runs ~0.3s
HAND_LEAD, HAND_S = 0.17, 0.14  # the hand moves this far ahead of the app reacting
HOLD_IN = 0.50                  # beat before the first keystroke
HOLD_SETTLE = 0.25              # after a switch, before typing resumes
HOLD_BEFORE = 0.35              # after typing, before the hand moves on
HOLD_OUT = 1.20                 # time to read the finished sentence
TAIL = 0.15


def build_schedule():
    """Absolute times for the loop: when each leg starts typing, and every switch —
    including the closing one back to the first keyboard, which is what makes the loop
    seam. Derived rather than written out, so adding a fourth leg costs one line."""
    legs, switches, t = [], [], HOLD_IN
    for i, (device, part) in enumerate(LEGS):
        if i:
            switches.append((t, LEGS[i - 1][0], device))
            t += SWITCH_S + HOLD_SETTLE
        legs.append((t, device, part))
        t += len(part) * CHAR_S
        if i < len(LEGS) - 1:
            t += HOLD_BEFORE
    t_typed = t
    t_return = t + HOLD_OUT
    switches.append((t_return, LEGS[-1][0], LEGS[0][0]))
    return legs, switches, t_typed, t_return


LEG_TIMES, SWITCHES, T_TYPED, T_RETURN = build_schedule()
DURATION = T_RETURN + SWITCH_S + TAIL

# ---------------------------------------------------------------- the share card
# og.html's layout and type, redrawn here so the animated card is a sibling of the
# static one rather than a lookalike: same padding, mark, sizes and leading. The scene
# replaces og.png's little menu bar strip and keeps its true size, so the popover is a
# real 344pt surface here too.
OG_W, OG_H = 1200, 630
OG_PAD = 76
OG_MARK, OG_MARK_GAP = 108, 20
OG_BRAND, OG_BRAND_BELOW = 30, 34
OG_TITLE, OG_TITLE_LEAD, OG_TITLE_BELOW = 68, 1.04, 22
OG_SLOGAN, OG_SLOGAN_LEAD, OG_SLOGAN_BELOW = 20, 1.5, 30
OG_META = 15
OG_TEXT_GAP = 40               # least air between the copy and the scene
OG_TITLE_LINES = ["One layout", "per keyboard."]
OG_SLOGAN_LINES = ["Assign an input source to each of",
                   "your keyboards. Keychange switches",
                   "the moment your hands do."]
OG_META_LINE = "Free · MIT · macOS 14+"
# Far enough past T_TYPED that the still shows the finished sentence and the DE mark.
OG_START = T_TYPED + 0.15


def smoothstep(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def jitter(i):
    """Deterministic per-keystroke wobble, so the typing isn't metronomic."""
    return (((i * 2654435761) % 1000) / 1000 - 0.5) * 0.055


def latest(items, ok):
    """The last item satisfying `ok`; SWITCHES is in time order, so that's the current
    one. None before the first."""
    found = None
    for item in items:
        if ok(item):
            found = item
    return found


def state(t):
    """Everything time-dependent, resolved once per frame.

    `swap` drives the mark and the rail together, since in the app they are one
    event: the typing device changed. `hand` runs slightly ahead of it, so around a
    switch the two are looking at different events.
    """
    out, struck = "", False
    for start, _, part in LEG_TIMES:
        for i, ch in enumerate(part):
            at = start + i * CHAR_S + jitter(i + int(start * 100))
            if t >= at:
                out += ch
                struck = struck or (t - at) < 0.09

    # Before the first switch there is nothing to animate from, so the opening state is
    # the first keyboard already settled — which is also where the loop closes.
    first = LEGS[0][0]
    mark = latest(SWITCHES, lambda s: s[0] <= t)
    at, frm, to = mark if mark else (t, first, first)
    swap = smoothstep((t - at) / SWITCH_S) if mark else 1.0

    # The hand reaches the other keyboard just before the app can react to it, so
    # the GIF reads as cause and effect rather than the panel changing by itself.
    reach = latest(SWITCHES, lambda s: s[0] - HAND_LEAD <= t)
    h_at, h_frm, h_to = reach if reach else (t, first, first)
    hand = smoothstep((t - (h_at - HAND_LEAD)) / HAND_S) if reach else 1.0

    return {
        "text": out,
        "struck": struck,
        "swap": swap,
        "codes": (DEVICES[frm]["code"], DEVICES[to]["code"]),
        "sources": (DEVICES[frm]["source"], DEVICES[to]["source"]),
        # Snaps, because the app's row rail is a plain boolean with no animation —
        # only the status item mark animates.
        "rail": RAIL_ROW_Y[DEVICES[to if swap > 0 else frm]["row"]],
        # How active each chip is, 0-1. `h_to` is tested first so that the opening
        # state, where from and to are the same keyboard, reads as fully arrived.
        "chips": [hand if i == h_to else 1 - hand if i == h_frm else 0.0
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
    n = len(DEVICES)
    row_w = n * chip_w + (n - 1) * CHIP_GAP
    x0 = M + ((w - 2 * M) - row_w) / 2                      # centred under the field

    spot = None
    if callout:
        # Centred in the desk the popover leaves free on its left (clear of the
        # capture's baked shadow), and hung over the bar's bottom edge.
        free = (w - M - PANEL_W - SHOT_INSET_X) - M
        spot = (M + (free - LENS_D) / 2, M + BAR_H * (1 - LENS_BAR_OVERLAP))

    return {
        "callout": spot,
        "size": (w, row + CHIP_H + M),
        "bar": (M, M, w - M, M + BAR_H),
        "panel": (w - M - PANEL_W, PANEL_Y),
        "field": (M + FIELD_INSET, field_top, w - M - FIELD_INSET, field_top + FIELD_H),
        "chips": [(x0 + i * (chip_w + CHIP_GAP), row) for i in range(n)],
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


def mono(size):
    return ImageFont.truetype(SFMONO, int(size * S))


def korean(size):
    return ImageFont.truetype(SFKOREAN, int(size * S), index=0)


def is_korean(ch):
    """Hangul syllables and jamo. Latin-1 (ü, ß) and punctuation stay with SF Pro."""
    return 0xAC00 <= ord(ch) <= 0xD7A3 or 0x1100 <= ord(ch) <= 0x11FF


def rich_text(img, xy, s, latin, cjk, color):
    """Draws `s` run by run, switching font where SF Pro has no glyph. Returns the x it
    ended at, which is where the caret goes."""
    runs = []
    for ch in s:
        f = cjk if is_korean(ch) else latin
        if runs and runs[-1][1] is f:
            runs[-1][0] += ch
        else:
            runs.append([ch, f])

    x = xy[0]
    for run, f in runs:
        text(img, (x, xy[1]), run, f, color)
        x += f.getlength(run) / S
    return x


def og_scene_left(scene_w):
    """Where the scene's content starts, once its right edge is on the card's padding."""
    return OG_W - OG_PAD - scene_w + 2 * M


def og_text_width(scene_w):
    return og_scene_left(scene_w) - OG_TEXT_GAP - OG_PAD


def og_card(scene, fonts, mark):
    """Wraps one scene frame in the 1200x630 share card. The scene keeps its own size
    and its own desk background, which is this card's background too, so it drops in
    seamlessly — only its 30pt of built-in margin has to be allowed for."""
    card = Image.new("RGB", (OG_W * S, OG_H * S), DESK)

    # Align the scene's content with the card's padding, not its margin-padded edges.
    sw, sh = scene.size[0] / S, scene.size[1] / S
    sx = og_scene_left(sw) - M
    sy = (OG_H - (sh - 2 * M)) / 2 - M
    card.paste(scene, (int(sx * S), int(sy * S)))

    block = (OG_MARK + OG_BRAND_BELOW
             + len(OG_TITLE_LINES) * OG_TITLE * OG_TITLE_LEAD + OG_TITLE_BELOW
             + len(OG_SLOGAN_LINES) * OG_SLOGAN * OG_SLOGAN_LEAD + OG_SLOGAN_BELOW
             + OG_META)
    y = (OG_H - block) / 2

    card.paste(mark, (int(OG_PAD * S), int(y * S)), mark)
    text(card, (OG_PAD + OG_MARK + OG_MARK_GAP, y + OG_MARK / 2 + OG_BRAND * 0.36),
         "Keychange", fonts["og_brand"], INK)
    y += OG_MARK + OG_BRAND_BELOW

    for line in OG_TITLE_LINES:
        y += OG_TITLE * OG_TITLE_LEAD
        text(card, (OG_PAD, y - OG_TITLE * 0.22), line, fonts["og_title"], INK)
    y += OG_TITLE_BELOW

    for line in OG_SLOGAN_LINES:
        y += OG_SLOGAN * OG_SLOGAN_LEAD
        text(card, (OG_PAD, y - OG_SLOGAN * 0.35), line, fonts["og_slogan"], BODY)
    y += OG_SLOGAN_BELOW + OG_META

    text(card, (OG_PAD, y), OG_META_LINE, fonts["og_meta"], FOOTER)
    return card


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
    end = rich_text(img, (tx, field[1] + (FIELD_H + FIELD_TEXT * 0.72) / 2), st["text"],
                    fonts["field"], fonts["field_ko"], blend(INK, FIELD_FILL, a))
    if a > 0.5 and (st["struck"] or (t % 1.0) < 0.55):
        cx = end + 2
        img.paste(INK, (int(cx * S), int((field[1] + (FIELD_H - CARET_H) / 2) * S)),
                  rrect((1.5, CARET_H), 0.75))
    return img


# ---------------------------------------------------------------- build
def chip_width(chip_font):
    """Both keyboards get the widest label's width, so the pair sits symmetrically."""
    return KB_W + CHIP_LABEL_GAP + max(
        chip_font.getlength(d["name"]) for d in DEVICES) / S


def build(name, spec, shot, accent, fonts, mark):
    L = layout(spec["callout"], chip_width(fonts["chip"]))
    card = spec.get("card", False)
    # The loop seams, so rotating where it starts is free — the card uses that to open
    # on the payoff instead of on an empty text field.
    t0 = OG_START if card else 0

    out = ROOT / "build" / f"frames-{name}"
    out.mkdir(parents=True, exist_ok=True)
    for f in out.glob("*.png"):
        f.unlink()

    n = int(round(DURATION * FPS))
    for i in range(n):
        img = frame((t0 + i / FPS) % DURATION, shot, accent, fonts, L)
        if card:
            img = og_card(img, fonts, mark)
        img.save(out / f"{i:04d}.png")
        print(f"\r  {name}: frame {i + 1}/{n}", end="", flush=True)

    gif, mp4 = DOCS / f"{name}.gif", DOCS / f"{name}.mp4"
    scale = f"scale={OG_W if card else L['size'][0]}:-1:flags=lanczos"
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
    size = (OG_W, OG_H) if card else L["size"]
    print(f"\r  {name}: {size[0]}x{size[1]}, "
          f"gif {gif.stat().st_size / 1024:.0f} KB, mp4 {mp4.stat().st_size / 1024:.0f} KB")


def make_fonts():
    def mark_glyph(scale):
        f = ImageFont.truetype(SFNS, int(GLYPH_SIZE * S * SS * scale))
        f.set_variation_by_name("Bold")
        return f

    return {"bar": font(14), "chip": font(13, "Medium"),
            "field": font(FIELD_TEXT), "field_ko": korean(FIELD_TEXT),
            "source": font(CALLOUT_TEXT, "Medium"),
            "glyph": mark_glyph(1), "glyph_big": mark_glyph(CALLOUT_SCALE),
            "og_brand": font(OG_BRAND, "Semibold"), "og_title": font(OG_TITLE, "Semibold"),
            "og_slogan": mono(OG_SLOGAN), "og_meta": mono(OG_META)}


def main(names):
    shot, accent = load_shot()
    fonts = make_fonts()
    # favicon.png is 128px and the card draws the mark at 108, so this is a downscale.
    mark = Image.open(DOCS / "favicon.png").convert("RGBA").resize(
        (int(OG_MARK * S), int(OG_MARK * S)), Image.LANCZOS)

    for name in names or VARIANTS:
        build(name, VARIANTS[name], shot, accent, fonts, mark)


def demo():
    """Self-check: the loop must start and end in the same visual state, or the GIF
    seams badly; the hand must lead the app; both layouts must fit their canvas."""
    a, b = state(0.0), state(DURATION - 1 / FPS)
    assert a["text"] == "" and a["text_alpha"] == 1, a
    assert b["text_alpha"] < 0.05, b["text_alpha"]
    assert abs(a["rail"] - b["rail"]) < 0.5, (a["rail"], b["rail"])
    assert a["chips"] == b["chips"], (a["chips"], b["chips"])

    mid = state((T_TYPED + T_RETURN) / 2)
    assert mid["text"] == FULL_TEXT, mid["text"]

    # Every keyboard must actually get a turn: all three codes reached, all three rows
    # railed, and each leg typing on the device it claims.
    assert {DEVICES[to]["code"] for _, _, to in SWITCHES} == {d["code"] for d in DEVICES}
    for start, device, part in LEG_TIMES:
        mid_leg = state(start + len(part) * CHAR_S / 2)
        assert mid_leg["chips"][device] > 0.5, (device, mid_leg["chips"])
        assert abs(mid_leg["rail"] - RAIL_ROW_Y[DEVICES[device]["row"]]) < 0.5, device
        assert mid_leg["codes"][1] == DEVICES[device]["code"], device

    # The hand must reach each keyboard a frame or more before the app reacts: the chip
    # has arrived while the mark still shows the keyboard being left. (Not `swap == 0` —
    # before the first switch there is nothing to animate from, so it sits settled.)
    for at, frm, to in SWITCHES:
        lead = state(at - 1.5 / FPS)
        assert lead["chips"][to] > 0.5, (at, lead["chips"])
        assert lead["codes"][1] == DEVICES[frm]["code"], (at, lead["codes"])

    # Only the Korean leg needs the fallback font, and it must actually be reached.
    assert any(is_korean(c) for c in FULL_TEXT), "nothing trilingual about this"

    # The lens has to contain both edges that identify it as the menu bar.
    assert VIEW_TOP < BADGE_Y and VIEW_TOP + VIEW > PANEL_Y, (VIEW_TOP, VIEW)

    # The card's copy is hand-broken into lines, so measure them: silently running
    # under the scene is the one way this card can go out wrong.
    fonts = make_fonts()
    card_spec = next(s for s in VARIANTS.values() if s.get("card"))
    room = og_text_width(layout(card_spec["callout"],
                                chip_width(fonts["chip"]))["size"][0])
    for key, lines in (("og_brand", ["Keychange"]), ("og_title", OG_TITLE_LINES),
                       ("og_slogan", OG_SLOGAN_LINES), ("og_meta", [OG_META_LINE])):
        indent = OG_MARK + OG_MARK_GAP if key == "og_brand" else 0
        for line in lines:
            used = indent + fonts[key].getlength(line) / S
            assert used <= room, (key, line, round(used), round(room))
    block = (OG_MARK + OG_BRAND_BELOW
             + len(OG_TITLE_LINES) * OG_TITLE * OG_TITLE_LEAD + OG_TITLE_BELOW
             + len(OG_SLOGAN_LINES) * OG_SLOGAN * OG_SLOGAN_LEAD + OG_SLOGAN_BELOW
             + OG_META)
    assert block <= OG_H - 2 * 24, block
    assert state(OG_START)["text"] == FULL_TEXT, "card must open on the payoff"

    for name, spec in VARIANTS.items():
        # The real measured width, not a stand-in: with three keyboards the row is
        # close enough to the canvas that a guess would check the wrong thing.
        L = layout(spec["callout"], chip_width(fonts["chip"]))
        w, h = L["size"]
        assert L["field"][2] <= w - M and L["field"][3] <= h - M, name
        for cx, cy in L["chips"]:
            assert cx >= M and cy + CHIP_H <= h - M + 0.5, (name, cx, cy)
        assert L["panel"][0] >= M, name
        if L["callout"]:
            qx, qy = L["callout"]
            # The loupe must clear the popover's baked-in shadow, not just its body.
            assert qx >= M and qx + LENS_D <= L["panel"][0] - SHOT_INSET_X, name
            # It straddles the bar's bottom edge on purpose, but must stay on the
            # canvas, and its label must not reach the field.
            assert qy >= M, (name, qy)
            assert qy < M + BAR_H < qy + LENS_D, (name, qy)
            assert qy + LENS_D + CALLOUT_LABEL <= L["field"][1], name
            # It can only overlap the bar where the bar has nothing in it.
            assert qx + LENS_D < L["bar"][2] - CLOCK_INSET - BADGE_W - ITEM_GAP, name
    print(f"demo: loop seams, hand leads the app, {len(VARIANTS)} layouts fit")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    sys.exit(demo() if "--check" in sys.argv else main(args))
