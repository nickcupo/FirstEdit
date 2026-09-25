"""The instrument the colour side reads skin and neutrals with.

    .venv/bin/python -m pytest tests/test_colour_instrument.py -q

The colour side writes nothing it chose by eye; it measures, reports, and
makes the gated decisions it has learned. So the one thing it cannot afford
is an instrument coarser than the tolerances it reports against. Lab came
back from OpenCV's 8-bit conversion rounded to whole units, and one unit at
skin chroma is 2.3-2.9 degrees of hue, about the width of
PUBLISHED.SKIN_HUE_TOL.

These pin down: presets.cielab reads Lab to the textbook, not to OpenCV's
8-bit or float lookup tables; a face's hue comes out to a tenth of the
tolerance, where the rounded reading missed it by half a degree or more
whichever way it rounded; the camera JPEG's largest face (measure's face_*_big) and
his delivered skin (taste._read_export_skin) are read by one patch and one
guard, so frame_tones compares a statistic with itself; and the pooled face
readings the fitted models take stay on the patch they were stored on.

No model, no RAW, no PhotoLab: synthetic pixels and a stand-in face.
"""
from __future__ import annotations

import math
import sys
from pathlib import Path
from types import SimpleNamespace

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import presets  # noqa: E402
import taste  # noqa: E402


def _textbook_lab(bgr) -> np.ndarray:
    """sRGB (IEC 61966-2-1) -> XYZ (D65) -> CIELAB, in float64, by hand:
    the reference nothing in OpenCV has touched."""
    rgb = np.asarray(bgr, np.float64)[..., ::-1] / 255.0
    lin = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    m = np.array([[0.4124564, 0.3575761, 0.1804375],
                  [0.2126729, 0.7151522, 0.0721750],
                  [0.0193339, 0.1191920, 0.9503041]])
    t = (lin @ m.T) / np.array([0.95047, 1.0, 1.08883])
    d = 6 / 29
    f = np.where(t > d ** 3, np.cbrt(t), t / (3 * d * d) + 4 / 29)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


def _eight_bit_lab(bgr: np.ndarray):
    """What measure() and the export reader used to read: OpenCV's 8-bit
    Lab, unscaled and unshifted, each value a whole unit."""
    x = cv2.cvtColor(bgr, cv2.COLOR_BGR2LAB).astype(np.float32)
    return x[..., 0] * (100 / 255), x[..., 1] - 128, x[..., 2] - 128


def _hue(a: float, b: float) -> float:
    return math.degrees(math.atan2(b, a))


def test_the_lab_it_reads_is_the_textbook_one():
    """Every fifth 8-bit value on every channel, 140,608 colours, against
    sRGB -> XYZ -> Lab done by hand. Over all 16.7 million 8-bit colours
    OpenCV's float conversion is off by up to 0.47 in a* and reads L* 0.09
    low on average (it interpolates a table), and its 8-bit one by up to
    2.7; cielab is within 0.003, the difference between OpenCV's six-figure
    constants and the textbook's seven. The ends: white is L* 100 and black
    L* 0, with a* and b* signed and centred on zero, not offset by 128."""
    g = np.arange(0, 256, 5, dtype=np.uint8)
    b, gg, r = np.meshgrid(g, g, g, indexing="ij")
    img = np.stack([b, gg, r], -1).reshape(-1, 1, 3)      # an image one pixel wide
    L, A, B = presets.cielab(img)
    got = np.stack([L, A, B], -1).astype(np.float64)
    assert np.abs(got - _textbook_lab(img)).max() < 0.01
    ends = np.array([[[255, 255, 255], [0, 0, 0], [0, 0, 255]]], np.uint8)
    L, A, B = presets.cielab(ends)
    assert abs(L[0, 0] - 100) < 0.01 and abs(A[0, 0]) < 0.01 and abs(B[0, 0]) < 0.01
    assert abs(L[0, 1]) < 0.01
    assert A[0, 2] > 70 and B[0, 2] > 60        # sRGB red: a* about 80, b* about 67
    assert L.dtype == np.float32


def test_a_face_hue_is_read_to_a_tenth_of_the_tolerance_and_the_rounded_reading_was_not():
    """The reason cielab exists. sRGB 182, 138, 122 (BGR 122, 138, 182, as
    OpenCV holds it) is a face at hue 46.1, Peng's preferred skin hue
    (PUBLISHED.SKIN_HUE), and C*ab 20.9, an ordinary skin chroma, with a*
    14.49 and b* 15.07, both well off a whole unit. Read as a face patch
    with a code value of noise per channel, the float reading's median hue
    lands within 0.3 degrees of the truth (within 0.1 over 200 draws of the
    noise); the 8-bit one reads a* 15, b* 15, hue 45.0, and misses by 1.1 --
    over a third of SKIN_HUE_TOL on a single face that has no error in it
    at all.

    Chosen so the demonstration does not depend on which way OpenCV
    happens to round: every whole-unit (a*, b*) pair within two units of
    the true one sits at least half a degree of hue from it, which the
    first assertion checks rather than trusts. The patch is an odd number
    of pixels, so a median of whole units is a whole unit and never splits
    the difference."""
    bgr = (122, 138, 182)
    true_L, true_a, true_b = _textbook_lab(np.array(bgr))
    true_hue = _hue(true_a, true_b)
    assert 45.5 < true_hue < 46.5 and 20 < math.hypot(true_a, true_b) < 22
    near = [abs(_hue(i, j) - true_hue) for i in range(int(true_a) - 2, int(true_a) + 4)
            for j in range(int(true_b) - 2, int(true_b) + 4)]
    assert min(near) > 0.5

    rng = np.random.default_rng(7)
    face = np.clip(np.array(bgr, np.int16) + rng.integers(-1, 2, (41, 41, 3)), 0, 255).astype(np.uint8)
    L, A, B = presets.cielab(face)
    now = _hue(float(np.median(A)), float(np.median(B)))
    assert abs(now - true_hue) < 0.3
    assert abs(float(np.median(L)) - true_L) < 0.3

    _, oa, ob = _eight_bit_lab(face)
    oa, ob = float(np.median(oa)), float(np.median(ob))
    assert oa == round(oa) and ob == round(ob)     # whole units, which is the defect
    was = _hue(oa, ob)
    assert abs(was - true_hue) > 0.3
    assert abs(was - true_hue) > 5 * abs(now - true_hue)


class _Judge:
    """Finds the faces it was handed and nothing else."""

    def __init__(self, faces):
        self.faces = faces

    def detect(self, img):
        return list(self.faces)


def _portrait() -> tuple[np.ndarray, tuple]:
    """A 320 x 240 frame with one face box in it: skin on a gentle gradient
    with a little noise, dark hair across the top quarter of the box, and a
    grey wall either side of its middle half. The old camera-JPEG patch
    (20-85% of the height, 20-80% of the width) takes in some hair and some
    wall; the export's (25-80%, 25-75%) takes in neither, so a reading that
    is not on one patch cannot agree by accident."""
    h, w = 240, 320
    x0, y0, fw, fh = 80, 40, 120, 160
    rows = np.arange(h, dtype=np.float64)[:, None]
    cols = np.arange(w, dtype=np.float64)[None, :]
    img = np.stack([100 + 0.15 * rows + 0.05 * cols,
                    120 + 0.12 * rows + 0.08 * cols,
                    175 + 0.05 * rows + 0.04 * cols], -1)
    img[:y0 + fh // 4, :] = (40, 45, 60)
    img[:, :x0 + fw // 4] = (150, 150, 150)
    img[:, x0 + 3 * fw // 4:] = (150, 150, 150)
    img += np.random.default_rng(3).integers(-2, 3, img.shape)
    return np.clip(np.round(img), 0, 255).astype(np.uint8), (x0, y0, fw, fh)


def test_the_camera_face_and_the_delivered_face_are_read_by_one_patch(tmp_path):
    """frame_tones prints the camera JPEG's largest face hue against his
    delivered skin_hue, so the two have to be the same statistic: the same
    patch of the face box, the same guard, the same median. Given the same
    pixels and the same box, measure() and the export reader now agree to
    the last place the export row keeps. Before, they read different
    patches, and on this frame the one face read hue 53.1 on the camera
    side and 54.8 on the export side: 1.7 degrees of difference with no
    difference in the face.

    And the guard is shared too: a face too small for the export side to
    read (a 12 px box is 36 pixels of patch, under its 100) is too small for
    the camera side, whose guard was 34 pixels, so it read that face and
    printed a hue for one his skin reading would never have counted."""
    img, box = _portrait()
    face = SimpleNamespace(box=box, main=True, conf=0.95)
    f = tmp_path / "TSC00001_DxO.png"            # lossless, so the file holds exactly these pixels
    assert cv2.imwrite(str(f), img)

    m = presets.measure(img, [face], None)
    out = taste._read_export_skin(str(f), _Judge([face]))
    assert out["skin"] == [[round(m["face_L_big"], 4), round(m["face_a_big"], 4), round(m["face_b_big"], 4)]]
    _, a, b = out["skin"][0]
    assert abs(m["face_hue_big"] - _hue(a, b)) < 1e-3
    assert 12 <= m["face_L_big"] <= 85 and m["face_C_big"] > 10
    assert taste.sure_face(m)

    small = SimpleNamespace(box=(130, 110, 12, 12), main=True, conf=0.95)
    m = presets.measure(img, [small], None)
    assert "face_hue_big" not in m and not taste.sure_face(m)
    assert taste._read_export_skin(str(f), _Judge([small]))["skin"] == []


def test_the_pooled_face_readings_keep_the_patch_they_were_stored_on():
    """face_L, face_a and face_b feed fitted models (taste.FEATS, and
    WB_FEATS through their hue), and every finished frame he has is kept
    measured on the 20-85% / 20-80% patch. Moving them to the skin patch
    would change what a stored number means without taste.MEASURE_SCHEMA
    knowing, so they stay where they were and only read more finely. On
    this frame the two patches really do read differently, which is what
    makes that a choice and not a coincidence."""
    img, box = _portrait()
    face = SimpleNamespace(box=box, main=True, conf=0.95)
    m = presets.measure(img, [face], None)
    L, A, B = presets.cielab(img)
    x, y, fw, fh = box
    rows, cols = slice(y + int(0.2 * fh), y + int(0.85 * fh)), slice(x + int(0.2 * fw), x + int(0.8 * fw))
    assert m["face_L"] == float(np.median(L[rows, cols]))
    assert m["face_a"] == float(np.median(A[rows, cols]))
    assert m["face_b"] == float(np.median(B[rows, cols]))
    assert (m["face_L"], m["face_a"], m["face_b"]) != (m["face_L_big"], m["face_a_big"], m["face_b_big"])
