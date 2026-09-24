"""What presets.py decides per frame after the sensor has been read, and what it
leaves alone.

    .venv/bin/python -m pytest tests/test_presets.py -q

Everything here runs on plain dicts and text: no RAW, no model, no PhotoLab.
The frames are the shape frame_tones hands on, and the sidecars the shape
PhotoLab writes.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import presets  # noqa: E402


@pytest.fixture(autouse=True)
def _learned_elsewhere(tmp_path, monkeypatch):
    """Learned state goes to a folder of the test's own, never the app's."""
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))


# ------------------------------------------------------------ levelling a burst

def _frame(ev_raw: float, bias: float = 0.0, mode: str = "Manual", masks: list | None = None, burst: str = "7") -> dict:
    """A frame whose subject's face sits ev_raw stops from L* 55 in the raw,
    with whatever decide_exposure already wrote for it."""
    per = {"_face_L": presets.Lstar(presets.Y(55.0) * 2 ** ev_raw), "_burst": burst, "_note": "decided",
           "ExposureAutoMode": mode}
    if mode == "Manual":
        per.update(ExposureActive=bias != 0.0, ExposureBias=bias)
    else:
        per.update(ExposureActive=True)
    if masks:
        per["_masks"] = masks
    return per


def test_a_frame_under_highlight_recovery_is_never_switched_or_biased():
    """decide_exposure routes a clipped frame to DxO's own recovery. The
    levelling used to rewrite it to Manual with a bias of its own while its
    note still said Strong highlight recovery."""
    out = {f"F{i}": _frame(ev) for i, ev in enumerate((0.0, 0.1, -0.1, 0.05))}
    out["F9"] = _frame(0.9, mode="StrongHighlightRecovery")
    presets.level_frames(out, quiet=True)
    assert out["F9"]["ExposureAutoMode"] == "StrongHighlightRecovery"
    assert "ExposureBias" not in out["F9"]
    assert out["F9"]["_note"] == "decided"


def test_the_frame_that_is_out_does_not_set_its_own_clamp():
    """A burst of four at LEVEL_MIN_FRAMES: over the whole burst, p95 of |ev|
    is the outlier's own |ev|, and it was pulled almost all the way to the
    median. Against the other three it moves no further than they spread."""
    out = {f"F{i}": _frame(ev) for i, ev in enumerate((0.0, 0.2, -0.2, 1.2))}
    presets.level_frames(out, quiet=True)
    assert -0.35 <= out["F3"]["ExposureBias"] < 0.0        # the whole-burst clamp let it go to -1.0
    # and the three that agree are not dragged toward the one that does not
    assert all(abs(out[f"F{i}"].get("ExposureBias", 0.0)) < 0.2 for i in range(3))


def test_the_levelling_writes_no_positive_lift_and_says_what_it_did_not_do():
    """decide_exposure refuses a positive global bias: a face under the band
    goes to its mask, and a frame dark all over is the photographer's call.
    The levelling used to write one anyway."""
    out = {f"F{i}": _frame(ev) for i, ev in enumerate((0.0, 0.3, 0.35, -0.3, 0.32))}
    presets.level_frames(out, quiet=True)
    assert all(float(p.get("ExposureBias") or 0.0) <= 0.0 for p in out.values())
    assert "positive global lift is yours to make" in out["F3"]["_note"]


def test_a_levelled_bias_stays_inside_what_one_exposure_move_writes():
    """The global bias is clamped to BIAS_FLOOR where it is decided, and the
    levelling added to it afterwards with no bound at all."""
    out = {f"F{i}": _frame(ev, bias=-1.9) for i, ev in enumerate((1.0, 0.0, 0.5, -0.5, 0.2, -0.3))}
    presets.level_frames(out, quiet=True)
    assert out["F0"]["ExposureBias"] == presets.BIAS_FLOOR
    assert "as far as one exposure move goes here" in out["F0"]["_note"]
    assert min(float(p["ExposureBias"]) for p in out.values()) >= presets.BIAS_FLOOR


def test_a_frame_already_corrected_is_not_corrected_twice():
    """Measured off the raw face alone, a frame decide_exposure had already
    pulled 0.5 EV down to the band's edge was pulled again by its whole raw
    difference from the burst, and a face its own mask had lifted was
    lowered by the global move under it. Measured as decided, both already
    sit with their burst."""
    out = {f"F{i}": _frame(ev) for i, ev in enumerate((0.0, 0.02, -0.02, 0.01))}
    out["F4"] = _frame(0.5, bias=-0.5)
    out["F5"] = _frame(-0.6, masks=[{"name": "Face 1", "x": 0.5, "y": 0.4, "ExposureBias": 0.6, "short": 0.0}])
    presets.level_frames(out, quiet=True)
    assert out["F4"]["ExposureBias"] == -0.5
    assert float(out["F5"].get("ExposureBias") or 0.0) == 0.0
    assert out["F4"]["_note"] == out["F5"]["_note"] == "decided"


def test_a_still_light_moves_nothing():
    out = {f"F{i}": _frame(ev) for i, ev in enumerate((0.0, 0.03, -0.03, 0.02, -0.01))}
    presets.level_frames(out, quiet=True)
    assert all(p["_note"] == "decided" and not p["ExposureActive"] for p in out.values())


# ------------------------------------------------------------ the scene preset

def test_a_clipped_flat_scene_is_reported_and_not_set():
    """Step 4 of decide() wrote a highlights slider of -(20 + 4000 x the
    clipped share), a white point of -6 and fine contrast +15, all chosen by
    eye, and on the learned path the scene preset's Base goes into every
    sidecar. Exposure was already only reported there; these are now too."""
    ms = [{"clip": 0.03, "black": 0.01, "range": 22.0, "frame_L": 60.0, "subject_L": 61.0} for _ in range(4)]
    s, notes = presets.decide(ms, [], [], "landscape", "overcast")
    for k in ("LightingV3Highlights", "LightingV3WhitePoint", "ContrastEnhancementActive",
              "ContrastEnhancementGlobalIntensity"):
        assert k not in s, k
    said = " ".join(notes)
    assert "3.0% of the camera JPEG's pixels clipped" in said
    assert "flat tonal range (L* spread 22)" in said


def test_a_look_with_nothing_in_it_to_write_says_nothing():
    """legal_look keeps the underscore keys, and _not_a_target is one of them:
    it is what had a majority and was not taken as a target, and it is
    printed on its own line above. A look holding only that printed 'from
    your own corrections on this shoot:' and then stopped."""
    assert presets.look_line({"_not_a_target": {"LightingV3BlackPoint": {"n": 176}}}, True, "") is None
    assert presets.look_line({}, True, "") is None
    assert presets.look_line({"NoiseRemovalMethod": "deepPRIME"}, True, "").startswith("from your own corrections")
    said = presets.look_line({"_hsl": {"Yellow": {}}, "_not_a_target": {}}, False, "a lounge")
    assert said.startswith("the look of a finished venue this shoot measures like (a lounge): ")
    assert said.endswith("HSL ['Yellow']")


def test_the_shipped_template_is_a_saved_preset_and_not_dxos_own():
    """What ships in a public repo has to be able to say where it came from.
    A factory preset declares IsSystem = true and carries a display name in
    seven languages; this one is a preset saved out of PhotoLab, and none of
    the values it holds reaches a sidecar -- build_preset overwrites every
    flat key from the preset DxO ships, read at run time."""
    text = presets.TEMPLATE.read_text()
    assert "IsSystem = false," in text
    assert text.count("DisplayName = ") == 1
    built = presets.preset_base_dict(presets.NATURAL, {})
    shipped = presets.shipped(presets.NATURAL)
    for k in ("LightingV3Highlights", "VibrancyIntensity", "ArtisticVignettingActive", "HazeRemovalActive"):
        assert built[k] == shipped[k], k


def test_a_grading_table_from_an_older_look_is_left_out_with_its_reason(monkeypatch):
    """check_dop refuses a _grading table, so a look that still carried one
    cost the shoot every sidecar. It is dropped here, said out loud, and the
    rest of the look goes on."""
    monkeypatch.setattr(presets.taste, "load", lambda: {})
    keep, dropped = presets.legal_look({"_grading": {"Shadows": {"Hue": 30}}, "_hsl": {"Yellow": {}}, "Contrast": 4})
    assert "_grading" not in keep and keep["_hsl"] == {"Yellow": {}} and keep["Contrast"] == 4
    assert any(d.startswith("_grading") for d in dropped)


def test_a_deliberate_lens_value_is_his_and_the_value_photolab_writes_on_open_is_not():
    taste = presets.taste
    opened = "\t\t\tDistortionActive = true,\n\t\t\tVignettingActive = false,\n"
    assert taste.hand_keys(opened) == set()
    assert taste.hand_keys("\t\t\tDistortionActive = false,\n") == {"DistortionActive"}
    # A float PhotoLab re-serialised is still the value it wrote.
    assert taste.hand_keys("\t\t\tUnsharpMaskRadius = 0.50000000000000011,\n") == set()


def test_the_writer_and_the_learner_find_the_same_copy_of_a_flat_shoots_sidecar(tmp_path):
    """A flat shoot keeps its sidecars beside the RAWs in the shoot folder.
    The learner looked only in raw/, so presets asking it would have written
    over every one of them."""
    shoot = tmp_path / "ducks"
    shoot.mkdir()
    (shoot / "TSC00001.ARW").write_bytes(b"RAW")
    dop = shoot / "TSC00001.ARW.dop"
    dop.write_text("Sources = {\n\t{\n\t\tOverrides = {\n\t\t\tExposureBias = -1.5,\n\t\t},\n\t},\n}\n")
    presets.taste._HANDS.clear()
    assert presets.newest_hand(shoot, "TSC00001.ARW") == dop
