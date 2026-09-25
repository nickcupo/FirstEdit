"""grade.py: a grade per frame, solved from the frame and from gains DxO's own
exports measured; nothing moves without a measured gain behind it.

    .venv/bin/python -m pytest tests/test_grade.py -q
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import grade  # noqa: E402
import pop  # noqa: E402
import presets  # noqa: E402
import taste  # noqa: E402


@pytest.fixture(autouse=True)
def _learned_elsewhere(tmp_path, monkeypatch):
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))


def _sidecar(base: dict) -> str:
    head = presets.DOP_HEAD
    for k, v in dict(date="d", software="DxO PhotoLab 10.0.0.23", cafid="C52941d", keywords="", name="X.ARW",
                     orientation=1, rating=3, preset_display="1 - DxO Style - Natural").items():
        head = head.replace("{" + k + "}", str(v))
    tail = presets.DOP_TAIL.replace("{shot}", "x").replace("{item_uuid}", "u").replace("{source_uuid}", "v")
    return head + presets.partial_base(base) + tail


GAINS = {"rendering": "DxOPortraitV3", "sliders": {
    "VibrancyIntensity": {"chroma_log": {"per_unit": 0.004, "mad": 0, "n": 10}, "skin_dC": {"per_unit": 0.05, "mad": 0, "n": 8}},
    "HSL.Blue.Saturation": {"sky_dC": {"per_unit": 0.3, "mad": 0, "n": 6}},
    "HSL.Green.Saturation": {"foliage_dC": {"per_unit": 0.25, "mad": 0, "n": 6}},
    "HSL.Green.Hue": {"foliage_dh": {"per_unit": 0.2, "mad": 0, "n": 6}}}}


def test_a_partial_base_gets_a_whole_hsl_table_and_the_file_still_passes():
    """DxO's camera-rendering Base carries no HSL table; a slice written into
    one that is not there used to be dropped in silence."""
    text = _sidecar({"ExposureBias": 0.3})
    out = grade.apply(text, {"VibrancyIntensity": 25, "HSL.Blue.Saturation": 18})
    assert taste.check_dop(out) == []
    base = taste._block(out, "Base")
    assert "VibrancyIntensity = 25" in base and base.count('Label = "') == 8
    assert grade.current(out, "HSL.Blue.Saturation") == 18 and grade.current(out, "HSL.Green.Saturation") == 0
    assert grade.current(out, "VibrancyIntensity") == 25
    again = grade.apply(out, {"HSL.Green.Hue": -6})                 # a table already there is edited, not doubled
    assert taste._block(again, "Base").count("HSLHueSlices") == 1 and grade.current(again, "HSL.Blue.Saturation") == 18


def test_a_flat_frame_is_lifted_and_a_vivid_one_is_not():
    flat = {"pop_m3": 30.0, "pop_sat_clip": 0.0}
    vals, why = grade.solve(flat, GAINS)
    v = vals["VibrancyIntensity"]
    assert math.exp(0.004 * (v - grade.NATURAL_VIBRANCY)) == pytest.approx(1.15, abs=0.01)
    lively = grade.solve({"pop_m3": 65.0}, GAINS)[0]["VibrancyIntensity"]
    assert grade.NATURAL_VIBRANCY < lively < v                        # a livelier frame gets less
    assert grade.target(20) == 1.15 and grade.target(59) == pytest.approx(1.10) and grade.target(90) == 1.0
    assert grade.solve({"pop_m3": 90.0}, GAINS)[0] == {}
    assert grade.solve({"pop_m3": 30.0, "pop_sat_clip": 0.05}, GAINS)[0] == {}
    assert grade.solve(flat, {"sliders": {}})[0] == {}                # no measured gain: nothing moves


def test_skin_caps_the_lift_and_is_never_cut():
    face = {"pop_m3": 30.0, "face_b_big": 15.0, "face_conf_big": 0.95, "face_C_big": 24.0}
    vals, why = grade.solve(face, GAINS)
    assert 24.0 + 0.05 * (vals.get("VibrancyIntensity", 5) - 5) <= 25.0 + 1e-6
    assert any("skin" in w for w in why)
    assert all(not k.startswith("HSL.Orange") and not k.startswith("HSL.Red") for k in vals)


def test_sky_and_foliage_go_toward_the_preferred_centres_and_not_past():
    m = {"pop_m3": 90.0, "pop_sky_C": 25.0, "pop_foliage_C": 50.0, "pop_foliage_h": 120.0}
    vals, why = grade.solve(m, GAINS)
    sky = pop.MEMORY.SKY[1]
    assert 25.0 + 0.3 * vals["HSL.Blue.Saturation"] == pytest.approx(min(sky, 25.0 + 0.3 * 40), abs=0.5)
    assert "HSL.Green.Saturation" not in vals                          # already past the preferred foliage chroma
    assert 0.2 * vals["HSL.Green.Hue"] == pytest.approx(grade.MAX_HUE_MOVE, abs=0.2)


def test_with_no_measured_scale_the_estimate_is_used():
    """No calibration exists any more: the estimated scale plans the grade,
    and a flat frame still gets its lift."""
    vals, why = grade.solve({"pop_m3": 30.0, "pop_sat_clip": 0.0})
    g = grade.PRIOR["sliders"]["VibrancyIntensity"]["chroma_log"]["per_unit"]
    assert math.exp(g * (vals["VibrancyIntensity"] - grade.NATURAL_VIBRANCY)) == pytest.approx(1.15, abs=0.01)


def test_presets_grades_every_frame(tmp_path, monkeypatch):
    """No choice to make: a flat frame gets its own lift in the sidecar values,
    a vivid one none, and each says so."""
    monkeypatch.setattr(presets, "measure_frames", lambda jobs, progress=None: {
        "A.ARW": {"m": {"frame_L": 40.0, "pop_m3": 25.0, "pop_sky_C": 25.0}, "lin": None},
        "B.ARW": {"m": {"frame_L": 40.0, "pop_m3": 95.0}, "lin": None}})
    monkeypatch.setattr(presets, "level_frames", lambda out, quiet=False: None)
    out = presets.frame_tones(tmp_path, tmp_path / "cull", [{"file": "A.ARW"}, {"file": "B.ARW"}], {}, "",
                              None, None, quiet=True, learned=False)
    assert out["A.ARW"]["VibrancyIntensity"] > grade.NATURAL_VIBRANCY
    assert out["A.ARW"]["_grade_hsl"]["HSL.Blue.Saturation"] > 0
    assert "color: vibrancy" in out["A.ARW"]["_note"] and "estimated" in out["A.ARW"]["_note"]
    assert "VibrancyIntensity" not in out["B.ARW"] and "no lift" in out["B.ARW"]["_note"]


def test_a_face_mask_only_nudges():
    """A face well under the band gets a mask of at most half a stop; one only
    a little short gets none."""
    lin = {"faces": [{"frac": 0.1, "Y": 0.004, "cx": 0.5, "cy": 0.4},
                     {"frac": 0.1, "Y": 0.03, "cx": 0.2, "cy": 0.4}], "flip": 0}
    masks = presets.face_masks(lin, 50.0, 0.0)
    assert masks and all(abs(m["ExposureBias"]) <= presets.MASK_MAX_EV for m in masks)
    assert all(abs(m["ExposureBias"] + m["short"]) >= presets.MASK_MIN_EV for m in masks)
