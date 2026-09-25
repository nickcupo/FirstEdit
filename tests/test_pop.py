"""pop.py: the pop measurements are the published ones, computed the
published way, and they measure without acting.

    .venv/bin/python -m pytest tests/test_pop.py -q

Synthetic pixels only: no model, no RAW, no PhotoLab.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import pop as colour  # noqa: E402


def _to_srgb8(lab_value) -> np.ndarray:
    """One CIELAB D65 colour to 8-bit sRGB (R, G, B), by inverting colour.lab."""
    L, a, b = lab_value
    fy = (L + 16) / 116
    fx, fz = fy + a / 500, fy - b / 200
    d = 6 / 29
    inv = lambda f: f ** 3 if f > d else 3 * d * d * (f - 4 / 29)  # noqa: E731
    xyz = np.array([inv(fx) * 0.95047, inv(fy), inv(fz) * 1.08883])
    m = np.array([[3.2404542, -1.5371385, -0.4985314], [-0.9692660, 1.8760108, 0.0415560], [0.0556434, -0.2040259, 1.0572252]])
    lin = np.clip(m @ xyz, 0, 1)
    enc = np.where(lin <= 0.0031308, 12.92 * lin, 1.055 * lin ** (1 / 2.4) - 0.055)
    return np.round(enc * 255).astype(np.uint8)


def test_the_colour_spaces_are_the_published_ones():
    """sRGB red is L* 53.24, a* 80.09, b* 67.20 in every reference, and white
    is Oklab (1, 0, 0) by Ottosson's construction."""
    red = colour.lab(colour.srgb_to_linear(np.array([[1.0, 0.0, 0.0]])))[0]
    assert np.allclose(red, [53.24, 80.09, 67.20], atol=0.05)
    white = colour.oklab(np.array([[1.0, 1.0, 1.0]]))[0]
    assert np.allclose(white, [1.0, 0.0, 0.0], atol=1e-3)


def test_colourfulness_is_the_signed_metric():
    """A grey frame is not colourful at all, and M3 on signed opponents tells
    a frame of reds and greens from a flat one, which |R - G| cannot: the
    absolute value folds red and green onto one side and loses most of the
    spread the metric is made of."""
    grey = np.full((40, 40, 3), 128, np.uint8)
    assert colour.colourfulness(grey) == pytest.approx(0.0)
    half = np.zeros((40, 40, 3), np.uint8)
    half[:, :20] = (200, 60, 60)
    half[:, 20:] = (60, 200, 60)
    m3 = colour.colourfulness(half)
    px = half.reshape(-1, 3).astype(float)
    absrg = np.abs(px[:, 0] - px[:, 1])
    yb = 0.5 * (px[:, 0] + px[:, 1]) - px[:, 2]
    folded = np.hypot(absrg.std(), yb.std()) + 0.3 * np.hypot(absrg.mean(), yb.mean())
    assert m3 > folded + 50
    assert colour.colourfulness_words(m3) in ("highly colorful", "extremely colorful")


def test_faces_are_left_out_of_the_non_skin_reading():
    """A frame that is mostly a face reads its colourfulness off skin unless
    the face is taken out; skin has its own targets."""
    img = np.full((100, 100, 3), 128, np.uint8)
    img[20:80, 20:80] = (90, 140, 200)          # BGR: a warm, skin-ish block

    class F:
        box = (20, 20, 60, 60)

    p = colour.pop(img, [F()])
    assert p["m3"] > 5
    assert p["m3_not_faces"] == pytest.approx(0.0)


def test_a_sky_at_the_preferred_centre_reads_as_there():
    """A patch rendered at the PMC chart's sky reads back within a degree and
    a unit of it: the selection finds it and the statistic is unbiased."""
    img = np.full((60, 60, 3), 128, np.uint8)
    L, C, h = colour.MEMORY.SKY
    rgb = _to_srgb8((L, C * np.cos(np.radians(h)), C * np.sin(np.radians(h))))
    img[:30] = rgb[::-1]
    p = colour.pop(img)
    assert "sky" in p and "foliage" not in p
    assert abs(p["sky"]["dh"]) < 1.0 and abs(p["sky"]["dC"]) < 1.0
    assert p["sky"]["frac"] == pytest.approx(0.5, abs=0.01)
    assert any("sky" in s for s in colour.pop_words(p))


def test_nothing_here_can_reach_a_sidecar():
    """Measurement only: the module names no DxO key, so nothing it computes
    can be pasted into a Base by accident."""
    src = (Path(colour.__file__)).read_text()
    for key in ("VibrancyIntensity", "HSLHueSlices", "ColorGradingParams", "WhiteBalanceRaw", "ColorModeContrast"):
        assert key not in src


def test_the_grey_is_read_without_the_faces():
    """presets.measure reads the room's grey twice: cast_a/cast_b as the
    models were fitted on (faces in), and grey_a/grey_b for the notes, with
    every face and a margin round it left out, so skin in the C* < 18 window
    stops passing for a cast."""
    import presets
    img = np.full((200, 200, 3), 128, np.uint8)      # a neutral room
    img[40:160, 40:160] = (150, 160, 190)            # BGR: a big, pale, warm face

    class F:
        box = (40, 40, 120, 120)
        main = True
        conf = 0.9

    m = presets.measure(img, [F()], None)
    assert m["cast_b"] > 2                           # the face pulls the old reading warm
    assert abs(m["grey_a"]) < 0.5 and abs(m["grey_b"]) < 0.5
