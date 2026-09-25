"""
pop.py - how much a photograph "pops", in numbers with a source behind them.

The rest of the pipeline holds a frame to targets for being RIGHT: skin at the
published preferred hue, neutrals within a proof's grey-balance tolerance, a
face inside the published lightness band (presets.PUBLISHED). None of that
says whether a frame is pleasing, and a frame can pass every one of them and
still look flat. This module measures the other half -- what the preferred-
reproduction literature says people like, as opposed to what is accurate --
and it measures only: nothing in this module writes a sidecar. The numbers
become a decision in grade.py, which solves each frame's colour grade from
them (grade.solve) against the published targets below.

What the literature actually supports, and what it does not:

  Preferred is more colourful than accurate, but only a little, and the curve
  turns over. Image quality is an inverted U in chroma scaling with its peak
  above the original: about x1.1 to x1.15 in de Ridder et al. (SPIE 2411,
  1995, doi:10.1117/12.207555) and Fedorovskaya, de Ridder & Blommaert (Color
  Res. Appl. 22(2):96-110, 1997). CHROMA_PREFERRED is that range, and it is a
  CAP to stop at as much as a direction to go in.

  Memory colours are preferred a little away from where they are: about +2
  C*ab and +1 L* from the "natural" centre across 24 objects and 106
  observers (Cao & Luo, Color Res. Appl. 48(2):178-200, 2023). Preferred sky
  is purer than real sky; preferred grass is as pure as real and slightly
  yellower (Hunt, Pitt & Winter, J. Photogr. Sci. 22:144-150, 1974). The
  centres below are CIELAB under D65 computed from the spectral reflectances
  of Luo's Preferred Memory Colour chart (Color Res. Appl. 2024,
  doi:10.1002/col.22940), 2 degree observer, because measure() reads sRGB
  Lab, which is D65/2 degree. Its skins land at h 46.9-48.2, C* 25.3-28.2 --
  on top of PUBLISHED.SKIN_HUE and SKIN_C from a different paper, which is the
  check that the computation is reading the chart correctly.

  Colourfulness has one metric that tracks observers well: Hasler &
  Susstrunk's M3 (SPIE 5007, HVEI VIII, 2003; r ~0.95 against 20 observers
  over 84 images), and Amati, Mitra & Weyrich (CAe 2014) found it the best of
  the metrics they tested against perceived colourfulness. It is computed on
  red-green and yellow-blue differences with their sign kept; versions that
  take |R - G| are not the published metric and read low on any frame with
  both reds and greens.

  Saturation is changed along a hue-linear axis or it changes the hue too:
  at constant CIELAB hue angle blues visibly drift toward purple (Hung &
  Berns, Color Res. Appl. 20(5), 1995). Oklab (Ottosson 2020) is fitted to
  the hue-linearity data that exposes this, so chroma here is read in Oklab.

  NOT supported, and so not here: a general preference for warm white balance
  in portraits (Cao & Luo, Vision Research 2022, found observers preferring
  skin captured under 6500-8000 K on mobile displays), and teal-and-orange
  grading, which has no preference study behind it at all. The absence is
  the finding.

Usage, for a look at one frame:
    python pipeline/pop.py some.jpg [more.jpg ...]
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np

# ------------------------------------------------------------ published numbers

# Hasler & Susstrunk 2003, the words their observers used and the M3 each
# sat at. Reported as the nearest word; a band to hold a frame to is not
# published and is not invented here.
M3_ANCHORS = ((0.0, "not colorful"), (15.0, "slightly colorful"), (33.0, "moderately colorful"),
              (45.0, "averagely colorful"), (59.0, "quite colorful"), (82.0, "highly colorful"),
              (109.0, "extremely colorful"))

# de Ridder 1995 / Fedorovskaya 1997: where perceived quality peaks when the
# chroma of a rendering is scaled, as a factor on the rendering's own chroma.
CHROMA_PREFERRED = (1.10, 1.15)

# Cao & Luo 2023: how far preferred sits from natural, in CIELAB units. A
# move toward a memory centre bigger than this is a different colour, not a
# preferred one.
MEMORY_SHIFT_C = 2.0
MEMORY_SHIFT_L = 1.0


class MEMORY:
    """Preferred memory-colour centres, CIELAB D65 / 2 degree, computed from
    the reflectances of Luo's PMC chart (2024). (L*, C*ab, h_ab degrees).

    The hue WINDOW each is looked for in is not a published figure: it is
    the centre +/- 35 degrees, wide enough that a real sky or lawn a camera
    has rendered a few degrees off still falls in it, and narrow enough that
    sky does not collect cyan walls or foliage collect yellow ones. The
    chroma floor keeps grey cloud and grey concrete out. Both are the
    selection, not the target, and the report says which pixels it read."""
    SKY = (52.7, 39.7, 276.5)
    FOLIAGE = (48.0, 42.5, 137.4)
    WINDOW = 35.0
    MIN_C = 8.0
    # A region smaller than this share of the frame is not the frame's sky
    # or its foliage, it is a shirt.
    MIN_FRAC = 0.02


# ------------------------------------------------------------ colour spaces

def srgb_to_linear(v: np.ndarray) -> np.ndarray:
    """IEC 61966-2-1 decoding, v in 0..1."""
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


def oklab(rgb_lin: np.ndarray) -> np.ndarray:
    """Linear sRGB (..., 3) to Oklab (..., 3), Ottosson's published matrices."""
    m1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
                   [0.2119034982, 0.6806995451, 0.1073969566],
                   [0.0883024619, 0.2817188376, 0.6299787005]])
    m2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                   [1.9779984951, -2.4285922050, 0.4505937099],
                   [0.0259040371, 0.7827717662, -0.8086757660]])
    lms = np.cbrt(rgb_lin @ m1.T)
    return lms @ m2.T


def lab(rgb_lin: np.ndarray) -> np.ndarray:
    """Linear sRGB (..., 3) to CIELAB D65 / 2 degree (..., 3), at float
    precision. The memory centres above are CIELAB, so they are compared in
    CIELAB; OpenCV's 8-bit Lab rounds a* and b* to whole units, which at
    C* 40 is more than a degree of hue."""
    m = np.array([[0.4124564, 0.3575761, 0.1804375],
                  [0.2126729, 0.7151522, 0.0721750],
                  [0.0193339, 0.1191920, 0.9503041]])
    xyz = rgb_lin @ m.T / np.array([0.95047, 1.0, 1.08883])
    d = 6.0 / 29.0
    f = np.where(xyz > d ** 3, np.cbrt(xyz), xyz / (3 * d * d) + 4.0 / 29.0)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], axis=-1)


# ------------------------------------------------------------ measurements

def colourfulness(rgb8: np.ndarray, keep: np.ndarray | None = None) -> float | None:
    """Hasler & Susstrunk's M3 on 8-bit sRGB (..., 3) in R, G, B order:
    sigma_rgyb + 0.3 mu_rgyb over rg = R - G and yb = (R + G)/2 - B, SIGNED,
    on the encoded 0-255 values the metric was fitted on. keep, when given,
    is a boolean mask of the pixels to read."""
    px = rgb8.reshape(-1, 3).astype(np.float64)
    if keep is not None:
        px = px[keep.reshape(-1)]
    if len(px) < 100:
        return None
    r, g, b = px[:, 0], px[:, 1], px[:, 2]
    rg, yb = r - g, 0.5 * (r + g) - b
    return float(math.hypot(rg.std(), yb.std()) + 0.3 * math.hypot(rg.mean(), yb.mean()))


def colourfulness_words(m3: float) -> str:
    """The nearest of Hasler & Susstrunk's observer categories."""
    return min(M3_ANCHORS, key=lambda a: abs(a[0] - m3))[1]


def _hue_dist(h: np.ndarray, centre: float) -> np.ndarray:
    return np.abs((h - centre + 180.0) % 360.0 - 180.0)


def memory_mask(labpx: np.ndarray, centre: tuple[float, float, float]) -> np.ndarray | None:
    """The pixels (a boolean over labpx's rows) that read as this memory
    colour, or None when they are too few to be the frame's sky or foliage."""
    L, a, b = labpx[:, 0], labpx[:, 1], labpx[:, 2]
    C = np.hypot(a, b)
    h = np.degrees(np.arctan2(b, a)) % 360.0
    sel = (C >= MEMORY.MIN_C) & (_hue_dist(h, centre[2]) <= MEMORY.WINDOW) & (L > 15) & (L < 95)
    if not len(sel) or float(sel.mean()) < MEMORY.MIN_FRAC:
        return None
    return sel


def memory_reading(labpx: np.ndarray, centre: tuple[float, float, float]) -> dict | None:
    """Where the pixels that read as this memory colour sit, against the
    preferred centre. labpx is (N, 3) CIELAB. None when too few pixels."""
    sel = memory_mask(labpx, centre)
    if sel is None:
        return None
    L, a, b = labpx[:, 0], labpx[:, 1], labpx[:, 2]
    C = np.hypot(a, b)
    frac = float(sel.mean())
    # The hue of the median a*, b*, not the median of hues: robust, and
    # never wraps.
    am, bm = float(np.median(a[sel])), float(np.median(b[sel]))
    hue = math.degrees(math.atan2(bm, am)) % 360.0
    chroma = float(np.median(C[sel]))
    return {"frac": round(frac, 4), "L": round(float(np.median(L[sel])), 2), "C": round(chroma, 2),
            "h": round(hue, 2),
            "dh": round(float((hue - centre[2] + 180.0) % 360.0 - 180.0), 2),
            "dC": round(chroma - centre[1], 2)}


def pop(bgr8: np.ndarray, faces: list | None = None) -> dict:
    """What this frame measures on the scales above. bgr8 is an OpenCV
    8-bit image; faces, when given, are objects with a .box (x, y, w, h)
    whose pixels are left out of the non-skin colourfulness, because a frame
    that is mostly face reads its colourfulness off skin, and skin has its
    own targets (presets.PUBLISHED)."""
    rgb8 = bgr8[..., ::-1]
    h, w = rgb8.shape[:2]
    out: dict = {}
    m3 = colourfulness(rgb8)
    if m3 is not None:
        out["m3"] = round(m3, 2)
        out["m3_words"] = colourfulness_words(m3)
    if faces:
        keep = np.ones((h, w), bool)
        for f in faces:
            x, y, fw, fh = [int(v) for v in f.box]
            keep[max(0, y):max(0, y + fh), max(0, x):max(0, x + fw)] = False
        m3n = colourfulness(rgb8, keep)
        if m3n is not None:
            out["m3_not_faces"] = round(m3n, 2)
    # Clipped in a colour rather than to white: a channel at the top of the
    # scale with another well below it. A more vivid rendering that buys its
    # colour by flattening a red jacket into one value is not more colourful
    # where it counts; the looks rule holds an arm to no more of this.
    hi, lo = rgb8.max(axis=2).astype(np.int16), rgb8.min(axis=2).astype(np.int16)
    out["sat_clip"] = round(float(((hi >= 254) & (hi - lo >= 60)).mean()), 5)
    lin = srgb_to_linear(rgb8.astype(np.float32) / 255.0)
    # Chroma in Oklab, the hue-linear space a saturation move would be made
    # in: the median and the 90th percentile, so a frame whose colour is all
    # in one sign is told apart from one that is colourful throughout.
    ok = oklab(lin.reshape(-1, 3))
    okC = np.hypot(ok[:, 1], ok[:, 2])
    out["oklab_C_median"] = round(float(np.median(okC)), 4)
    # And the mean, which is the one a chroma SCALING moves in proportion:
    # the preferred x1.10-1.15 is a factor on every pixel's chroma, and the
    # median of a frame that is mostly grey wall sits near zero whatever the
    # colours in it do.
    out["oklab_C_mean"] = round(float(okC.mean()), 5)
    out["oklab_C_p90"] = round(float(np.percentile(okC, 90)), 4)
    labpx = lab(lin.reshape(-1, 3))
    for name, centre in (("sky", MEMORY.SKY), ("foliage", MEMORY.FOLIAGE)):
        got = memory_reading(labpx, centre)
        if got:
            out[name] = got
    return out


def flat(p: dict) -> dict:
    """pop()'s readings as flat pop_* keys, the shape a frame's measurements
    are stored in (presets.measure_frame) and grade.solve reads."""
    out = {f"pop_{k}": v for k, v in p.items() if isinstance(v, (int, float)) and not isinstance(v, bool)}
    for mem in ("sky", "foliage"):
        for k, v in (p.get(mem) or {}).items():
            out[f"pop_{mem}_{k}"] = v
    return out


def pop_words(p: dict) -> list[str]:
    """The readings as the sentences a note carries. Reported, never acted on."""
    said = []
    if "m3" in p:
        s = f"colorfulness M3 {p['m3']:.0f} ({p['m3_words']}, Hasler & Susstrunk 2003)"
        if "m3_not_faces" in p:
            s += f", {p['m3_not_faces']:.0f} away from the faces"
        said.append(s)
    for name, centre in (("sky", MEMORY.SKY), ("foliage", MEMORY.FOLIAGE)):
        r = p.get(name)
        if r and all(k in r for k in ("frac", "h", "C", "dh", "dC")):
            said.append(f"{name} on {r['frac']:.0%} of the frame at h {r['h']:.0f}, C* {r['C']:.0f}: "
                        f"{r['dh']:+.0f} deg and {r['dC']:+.0f} C* from the preferred {name} "
                        f"(h {centre[2]:.0f}, C* {centre[1]:.0f}, PMC chart)")
    return said


def main() -> int:
    import cv2
    for arg in sys.argv[1:]:
        img = cv2.imread(arg)
        if img is None:
            print(f"{arg}: not an image")
            continue
        print(f"{Path(arg).name}:")
        for s in pop_words(pop(img)):
            print(f"  {s}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
