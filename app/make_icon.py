#!/usr/bin/env python3
"""Draw the app icon as a layered icon document.

    app/make_icon.py <AppIcon.icon>

What the icon is a picture of: three prints, and the one he has chosen lifted
clear of the other two. The chosen one is the only one with a photograph in
it, because that is the app — sixteen hundred frames go in and the ones he
looked at and kept come out. Nothing in it needs colour to be understood, and
nothing in it is a camera: a camera is a picture of hardware.

Why a `.icon` and not an `.appiconset` of flat PNGs. Since macOS 26 an app
icon is layered art, and the system owns the rest of it: the rounded square,
the material, the specular edge along the top, the shadow under each group,
and the dark, clear and tinted appearances, which it derives. An icon that
draws its own ring, its own shadow or its own rounded corner is doing the
system's job a decade late, and looks it. `actool` here (Xcode 27) compiles a
`.icon` straight into `Assets.car` plus the loose `AppIcon.icns`, for a
deployment target as old as the one this app promises, so there is nothing to
give up by using it.

The six appearances the system derives can all be looked at from a script,
without opening Icon Composer or anything else with a window, because Icon
Composer ships a command-line renderer beside it:

    "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/\
Contents/Executables/ictool" AppIcon.icon --export-image \
        --output-file out.png --platform macOS --rendition Dark \
        --width 1024 --height 1024 --scale 1

with the rendition one of Default, Dark, TintedLight, TintedDark, ClearLight
or ClearDark. That is how this drawing was checked at every size in every
appearance. It is not wired into the build: it lives at a path inside Xcode
that no `xcrun` knows about, and a gate that depends on where an app happens
to be installed is a gate that fails on someone else's machine.

What that costs: the layered format has no per-size art. Every size is
rendered from this one drawing, the way the system's own icons are, so the
drawing is what has to survive 16 px — three shapes, three tones, one
photograph, no detail narrower than a sixteenth of the canvas. That is the
hinting, and it is done here in the geometry rather than in ten hand-drawn
PNGs that the format has nowhere to put.

The whole document is written from this file, every build: the JSON, the
layers, the colours. Nothing about the icon is committed as a picture, because
a generated file beside its generator goes stale the first time the generator
changes with nothing to say so.

The drawing space is 1024 units square and it maps exactly onto the plate the
system draws — 0,0 is the plate's top-left corner, not the canvas's. Measured
against Photos, Preview, Notes, Maps, Font Book and Xcode at 1024 px: the
plate is 824 px inside a 1024 px canvas, and a subject that sits on it (rather
than bleeding to its edges) fills 78-84% of it, with about a tenth of the
plate as margin on three sides and a little less underneath.
"""
import json
import shutil
import sys
from pathlib import Path

dest = Path(sys.argv[1]) if len(sys.argv) > 1 else None
if dest is None or dest.suffix != ".icon":
    sys.exit("usage: make_icon.py <AppIcon.icon>")

C = 1024                      # the drawing square, which is the plate

# Three tones and a warm white, and that is the whole palette. The app's own
# colour is the system's (DESIGN.md §2.2: system semantic colours, the user's
# accent, green reserved for his verdicts), so the icon borrows none of it:
# a static picture cannot follow an accent, and green here would claim a
# verdict the icon has not made.
PLATE = "#3E4046"             # graphite, the surround a person judges tone against
CARD = ("#FDFBF8", "#EFEBE4")  # the chosen print's stock, lit from the top left
BACK_NEAR = ("#D6D2CB", "#BFBAB2")   # the two he has not looked at yet
BACK_FAR = ("#A29E96", "#8C887F")


def sheen(ident, light, dark):
    """The light every one of these sits in: top left, the way the plate is lit."""
    return (f'<linearGradient id="{ident}" x1="0.1" y1="0" x2="0.7" y2="1">'
            f'<stop offset="0" stop-color="{light}"/>'
            f'<stop offset="1" stop-color="{dark}"/></linearGradient>')


def rect(x, y, w, h, r, fill, rot=None, cx=0.0, cy=0.0):
    t = f' transform="rotate({rot} {cx:.1f} {cy:.1f})"' if rot else ""
    return (f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" '
            f'rx="{r:.1f}" fill="{fill}"{t}/>')


def card(name, x, y, w, h, r, tones, rot=None, cx=0.0, cy=0.0):
    return (f'<defs>{sheen(name, *tones)}</defs>'
            + rect(x, y, w, h, r, f"url(#{name})", rot, cx, cy))


def svg(body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{C}" height="{C}" '
            f'viewBox="0 0 {C} {C}">\n{body}\n</svg>\n')


def photograph(x, y, w, h):
    """The picture inside the chosen print: 3:2, the shape of his frames.

    A graded sky over a foreground that rises to the right. It is graded and
    off-centre so that it reads as a photograph of somewhere rather than as
    the symbol for one; at 16 px all that is left of it is a light half over a
    dark half, which is what a photograph looks like from across a room.
    """
    hy = y + h * 0.56
    return "\n".join([
        '<defs>',
        '<linearGradient id="sky" x1="0.08" y1="0" x2="0.62" y2="1">',
        '<stop offset="0" stop-color="#E4E9EF"/>',
        '<stop offset="1" stop-color="#A9B3BF"/>',
        '</linearGradient>',
        '<linearGradient id="ground" x1="0" y1="0" x2="0.35" y2="1">',
        '<stop offset="0" stop-color="#5A626D"/>',
        '<stop offset="1" stop-color="#3C4350"/>',
        '</linearGradient>',
        '</defs>',
        f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" fill="url(#sky)"/>',
        f'<path d="M{x:.1f},{y + h:.1f} L{x:.1f},{hy + h * 0.10:.1f} '
        f'C{x + w * 0.22:.1f},{hy - h * 0.10:.1f} {x + w * 0.40:.1f},{hy + h * 0.06:.1f} '
        f'{x + w * 0.58:.1f},{hy - h * 0.09:.1f} '
        f'C{x + w * 0.76:.1f},{hy - h * 0.24:.1f} {x + w * 0.88:.1f},{hy - h * 0.30:.1f} '
        f'{x + w:.1f},{hy - h * 0.38:.1f} L{x + w:.1f},{y + h:.1f} Z" fill="url(#ground)"/>',
    ])


def chosen_print(cx, cy, w, h, rot, border):
    """A print: card stock with the photograph held inside its margin."""
    x, y = cx - w / 2, cy - h / 2
    ix, iy, iw, ih = x + border, y + border, w - 2 * border, h - 2 * border
    t = f' transform="rotate({rot} {cx:.1f} {cy:.1f})"'
    return "\n".join([
        card("stock", x, y, w, h, 40, CARD, rot, cx, cy),
        f'<g{t}>',
        f'<clipPath id="picture"><rect x="{ix:.1f}" y="{iy:.1f}" '
        f'width="{iw:.1f}" height="{ih:.1f}" rx="10"/></clipPath>',
        '<g clip-path="url(#picture)">',
        photograph(ix, iy, iw, ih),
        '</g></g>',
    ])


# The composition. Each print is 3:2 inside its margin, the shape of what the
# camera writes. The chosen one is up and to the left, tilted the other way
# from the two behind it, and far enough off them that the shadow the system
# puts under it has somewhere to fall: that gap is the whole story, so it is
# the one measurement here that is not free to drift.
CHOSEN = dict(cx=410, cy=358, w=636, h=447, rot=-4, border=34)
NEAR = dict(cx=580, cy=616, w=604, h=424, rot=7)
FAR = dict(cx=622, cy=686, w=572, h=402, rot=15)

# Groups are listed front to back, the way a layer palette lists them, and
# each one casts its own shadow. Nothing is translucent: two prints seen
# through each other are not two prints.
GROUPS = [
    ("chosen", chosen_print(**CHOSEN), 0.66),
    ("near", card("near", NEAR["cx"] - NEAR["w"] / 2, NEAR["cy"] - NEAR["h"] / 2,
                  NEAR["w"], NEAR["h"], 36, BACK_NEAR,
                  rot=NEAR["rot"], cx=NEAR["cx"], cy=NEAR["cy"]), 0.32),
    ("far", card("far", FAR["cx"] - FAR["w"] / 2, FAR["cy"] - FAR["h"] / 2,
                 FAR["w"], FAR["h"], 34, BACK_FAR,
                 rot=FAR["rot"], cx=FAR["cx"], cy=FAR["cy"]), 0.26),
]


def srgb(hexstr, alpha=1.0):
    h = hexstr.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return f"extended-srgb:{r:.5f},{g:.5f},{b:.5f},{alpha:.5f}"


shutil.rmtree(dest, ignore_errors=True)
assets = dest / "Assets"
assets.mkdir(parents=True)

groups = []
for name, body, shadow in GROUPS:
    (assets / f"{name}.svg").write_text(svg(body))
    groups.append({
        "layers": [{"image-name": f"{name}.svg", "name": name}],
        "shadow": {"kind": "neutral", "opacity": shadow},
        "specular": True,
        "translucency": {"enabled": False, "value": 0.5},
    })

# The plate, and only the light one is ours. For the dark appearance actool
# substitutes a near-black gradient of its own — gray 0.192 to gray 0.078 —
# whatever the document asks for, and those same two stops are in Photos',
# Notes', Preview's and Maps' compiled catalogues, identical to the digit. So
# the dark plate is the platform's decision, like the corner and the specular,
# and not something to route around: a `fill-specializations` entry beside
# `fill` is accepted in silence and compiles to the same assets, digest for
# digest, which is why there is none here. What the dark appearance needs is
# art that still reads on near-black, and that is the whole reason the prints
# are near-white and carry the composition by themselves.
document = {
    "fill": {"automatic-gradient": srgb(PLATE)},
    "groups": groups,
    # This app is a Mac app, so it declares the one shape it is ever drawn in.
    "supported-platforms": {"squares": ["macOS"]},
}
(dest / "icon.json").write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
print(f"{len(groups)} layers in {dest}")
