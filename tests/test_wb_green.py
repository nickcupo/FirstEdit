"""The camera's green reading of the light, and the one model that may use it.

    .venv/bin/python -m pytest tests/test_wb_green.py -q

Fluo is the one colour decision he makes per frame (92 of his 205 edits),
and what tells a fluorescent tube from a bulb of the same colour
temperature is green, not warmth: the red/blue ratio kelvin is read from
cannot see it. presets.camera_wb_from_raw reads it off the same as-shot
multipliers, and taste.learn_wb uses it only where every frame it fits on
carries it, because which stored frames lack it is a fact about which
shoots were measured before it existed - which is to say about venues,
which is very nearly to say about the answer.

What these pin down: the arithmetic, on multipliers stubbed in for rawpy;
that kelvin did not move by so much as a bit; that a model stored before
any of this scores every frame exactly as it did; and that the green joins
a fit only on its every frame. No RAW, no face model, no PhotoLab.
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import presets  # noqa: E402
import taste  # noqa: E402

DAYLIGHT = [2.2, 1.0, 1.4, 0.0]          # libraw's daylight: normalised to green, no second green


class _Raw:
    """What rawpy.imread hands back, as far as the white balance reads it:
    a context manager carrying the two sets of multipliers and the names of
    the channels."""

    def __init__(self, cw, dw=DAYLIGHT, desc=b"RGBG"):
        self.camera_whitebalance, self.daylight_whitebalance, self.color_desc = list(cw), list(dw), desc

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _stub(monkeypatch, cw, dw=DAYLIGHT, desc=b"RGBG"):
    import rawpy
    monkeypatch.setattr(rawpy, "imread", lambda path: _Raw(cw, dw, desc))


def _kelvin_by_hand(cw, dw) -> float:
    """kelvin_from_raw as it was written before the green existed, typed out
    again here so the test does not lean on the code it is checking."""
    k = (cw[0] / cw[2]) / (dw[0] / dw[2])
    return 1e6 / (182.0 * (1.0 / k) ** 0.567)


# ------------------------------------------------------------ the arithmetic

def test_the_daylight_balance_itself_reads_zero(monkeypatch):
    """A camera whose as-shot multipliers ARE its daylight ones assumed
    daylight: exactly 0 stops, and the kelvin of that daylight."""
    _stub(monkeypatch, DAYLIGHT)
    k, g = presets.camera_wb_from_raw(Path("TSC00001.ARW"))
    assert g == 0.0
    assert k == _kelvin_by_hand(DAYLIGHT, DAYLIGHT)


def test_a_camera_that_took_green_out_reads_positive_and_its_kelvin_does_not_move(monkeypatch):
    """Green's multiplier turned down against daylight, red and blue left
    where they were: the camera took the light for greener than daylight.
    log2(1 / 0.8) = +0.32 stop. Turned up instead, it read the light as
    magenta, and the sign says so.

    And the kelvin is the red/blue ratio and nothing else, so moving green
    alone cannot move it: every stored measurement, venue centre and model
    in use was made with kelvin_from_raw, which has to read exactly what it
    always read."""
    greener = [2.2, 0.8, 1.4, 0.8]
    _stub(monkeypatch, greener)
    k, g = presets.camera_wb_from_raw(Path("TSC00002.ARW"))
    assert g == pytest.approx(math.log2(1 / 0.8)) and g > 0
    assert k == presets.kelvin_from_raw(Path("TSC00002.ARW")) == _kelvin_by_hand(greener, DAYLIGHT)

    magenta = [2.2, 1.25, 1.4, 1.25]
    _stub(monkeypatch, magenta)
    k2, g2 = presets.camera_wb_from_raw(Path("TSC00003.ARW"))
    assert g2 == pytest.approx(-math.log2(1.25)) and g2 < 0
    assert k2 == k, "green alone moved the kelvin"


def test_the_green_is_green_against_red_and_blue_together(monkeypatch):
    """rel = daylight / as-shot per channel, and the green is green's share
    against the geometric mean of red and blue, so a warm light (red down,
    blue up, by the same factor) is 0 however warm, and the reading does not
    care what units either set of multipliers came in: libraw gives as-shot
    in the camera's own and daylight normalised to green."""
    warm = [2.2 / 1.6, 1.0, 1.4 * 1.6, 1.0]
    _stub(monkeypatch, warm)
    k, g = presets.camera_wb_from_raw(Path("TSC00004.ARW"))
    assert g == pytest.approx(0.0, abs=1e-12)
    assert k < _kelvin_by_hand(DAYLIGHT, DAYLIGHT), "red turned down is a warmer light"

    # And the full formula on multipliers that differ everywhere, in raw units.
    cw, dw = [2150.0, 1024.0, 1710.0, 1024.0], [2.31, 1.0, 1.52, 0.0]
    _stub(monkeypatch, cw, dw)
    rel = [dw[i] / cw[i] for i in range(3)]
    k, g = presets.camera_wb_from_raw(Path("TSC00005.ARW"))
    assert g == pytest.approx(math.log2(rel[1] / math.sqrt(rel[0] * rel[2])))
    assert k == presets.kelvin_from_raw(Path("TSC00005.ARW")) == _kelvin_by_hand(cw, dw)


def test_what_cannot_be_read_is_none_and_takes_nothing_else_with_it(monkeypatch):
    """A zero multiplier is no reading, not a very large one: libraw reports
    zeros for a daylight balance it has no table for, and the second green
    is 0 on some bodies. The green reads index 1 and never the second green;
    a NaN, a zero or a sensor whose channels are not R, G and B gives None
    for the green, and the kelvin is whatever kelvin_from_raw always gave."""
    _stub(monkeypatch, [2.0, 1.0, 1.5, 0.0])                  # second green 0: read index 1, fine
    assert presets.camera_wb_from_raw(Path("a.ARW"))[1] == pytest.approx(
        math.log2((1.0 / 1.0) / math.sqrt((2.2 / 2.0) * (1.4 / 1.5))))

    _stub(monkeypatch, [2.0, 0.0, 1.5, 0.0])                  # no green multiplier at all
    k, g = presets.camera_wb_from_raw(Path("b.ARW"))
    assert g is None and k == _kelvin_by_hand([2.0, 0.0, 1.5], DAYLIGHT)

    _stub(monkeypatch, [2.0, float("nan"), 1.5, 1.0])
    assert presets.camera_wb_from_raw(Path("c.ARW"))[1] is None

    _stub(monkeypatch, [2.0, 1.0, 1.5, 1.0], [0.0, 0.0, 0.0, 0.0])   # no daylight table for this body
    assert presets.camera_wb_from_raw(Path("d.ARW")) == (None, None)
    assert presets.kelvin_from_raw(Path("d.ARW")) is None

    _stub(monkeypatch, [2.0, 1.0, 1.5, 1.0], desc=b"GMCY")    # the indices name other colours
    k, g = presets.camera_wb_from_raw(Path("e.ARW"))
    assert g is None and k == _kelvin_by_hand([2.0, 1.0, 1.5], DAYLIGHT)

    import rawpy

    def unreadable(path):
        raise rawpy.LibRawFileUnsupportedError("not a RAW")
    monkeypatch.setattr(rawpy, "imread", unreadable)
    assert presets.camera_wb_from_raw(Path("f.ARW")) == (None, None)
    assert presets.kelvin_from_raw(Path("f.ARW")) is None


def test_every_frame_the_presets_step_measures_carries_it(monkeypatch, tmp_path):
    """measure_frame is where the starting edit's measurements come from -
    the store taste.learn_edit keeps, and the frames predict_wb is asked
    about - so the green is stored there, beside the kelvin, off the same
    open of the RAW. A JPEG has neither."""
    import cv2

    class _Judge:
        def detect(self, img):
            return []

        def judge(self, *a, **k):
            return None

    monkeypatch.setattr(presets, "_WORKER", {"judge": _Judge(), "subj": None})
    monkeypatch.setattr(presets, "linear_measure", lambda *a, **k: None)
    preview = tmp_path / "TSC00006.jpg"
    cv2.imwrite(str(preview), np.full((60, 80, 3), 128, np.uint8))
    greener = [2.2, 0.8, 1.4, 0.8]
    _stub(monkeypatch, greener)

    _, got = presets.measure_frame(("TSC00006.ARW", str(preview), "", str(tmp_path / "TSC00006.ARW")))
    assert got["m"]["wb_green"] == pytest.approx(math.log2(1 / 0.8))
    assert got["m"]["kelvin"] == _kelvin_by_hand(greener, DAYLIGHT)

    _, jpeg = presets.measure_frame(("TSC00007.JPG", str(preview), "", str(tmp_path / "TSC00007.JPG")))
    assert jpeg["m"]["kelvin"] is None and jpeg["m"]["wb_green"] is None


def test_the_scene_notes_say_the_green_beside_the_kelvin_and_only_say_it():
    """decide() reports what the camera read and sets nothing from it. The
    green is said as a number, always, because no threshold for "enough
    green to matter" can be checked from here; and a shoot measured without
    it reads exactly as it did."""
    ms = [{"clip": 0.0, "black": 0.0, "range": 40.0, "frame_L": 55.0} for _ in range(3)]
    s, notes = presets.decide(ms, [3000.0, 3100.0, 3200.0], [], "person", "overcast", greens=[0.10, 0.18, 0.31])
    assert "camera as-shot about 3100 K, 0.18 stop greener than its own daylight balance; left as shot, " \
           "each frame switches to Fluo on its own evidence" in notes
    assert not any(k.startswith("WhiteBalance") for k in s), "a reading, never a setting"

    _, notes = presets.decide(ms, [3000.0, 3100.0, 3200.0], [], "person", "overcast", greens=[-0.05, -0.07])
    assert any("0.06 stop more magenta than its own daylight balance" in n for n in notes)

    _, before = presets.decide(ms, [3000.0, 3100.0, 3200.0], [], "person", "overcast")
    assert "camera as-shot about 3100 K; left as shot, each frame switches to Fluo on its own evidence" in before


# ------------------------------------------------------------ a model stored before it

# His live model's shape: the eight legacy names, ten weights (each face
# value followed by its missing-flag), a mean and spread per position.
_LEGACY = {"features": ["kelvin", "cast_a", "cast_b", "light_chroma", "frame_L", "range", "face_hue", "face_L"],
           "mu": [3300.0, 0.0, 4.0, 10.0, 45.0, 60.0, 45.0, 0.5, 50.0, 0.5],
           "sd": [200.0, 3.0, 5.0, 8.0, 10.0, 15.0, 10.0, 0.5, 12.0, 0.5],
           "w": [-1.2, -0.4, 0.3, 0.1, -0.2, 0.05, 0.5, 0.2, -0.3, 0.1], "b": -0.1}


def _p_by_hand(row: list[float], mod: dict) -> float:
    s = sum((x - mu) / sd * w for x, mu, sd, w in zip(row, mod["mu"], mod["sd"], mod["w"])) + mod["b"]
    return 1 / (1 + math.exp(-s))


def test_a_model_stored_before_the_green_scores_every_frame_as_it_always_did():
    """A stored model is its weights against its row, and his live one was
    fitted on the ten-number row over the eight legacy names. So the row is
    built from the model's own "features", and over those eight it is the
    same ten numbers in the same order as before; a frame that now carries
    a green is scored without it by a model that never had it, and a model
    so old it names no features at all is read the same way.

    The expected answers are computed here from the numbers, not asked of
    the code: a face at a* 14, b* 18 is hue 52.1 degrees, flagged present."""
    face = {"kelvin": 3150.0, "cast_a": -2.0, "cast_b": 6.0, "light_chroma": 12.0, "frame_L": 41.0,
            "range": 63.0, "face_a": 14.0, "face_b": 18.0, "face_L": 47.0}
    hue = math.degrees(math.atan2(18.0, 14.0))
    row = [3150.0, -2.0, 6.0, 12.0, 41.0, 63.0, hue, 1.0, 47.0, 1.0]
    assert taste._wb_row(face) == row
    assert taste._wb_row(face, taste.WB_FEATS) == row
    p = _p_by_hand(row, _LEGACY)
    assert p == pytest.approx(0.8842, abs=1e-3)

    nobody = {"kelvin": 3500.0, "cast_a": 1.0, "cast_b": 3.0, "light_chroma": 10.0, "frame_L": 55.0, "range": 60.0}
    row2 = [3500.0, 1.0, 3.0, 10.0, 55.0, 60.0, 0.0, 0.0, 0.0, 0.0]
    assert taste._wb_row(nobody) == row2
    p2 = _p_by_hand(row2, _LEGACY)
    assert p2 == pytest.approx(0.0477, abs=1e-3)

    no_features = {k: v for k, v in _LEGACY.items() if k != "features"}
    for mod in (_LEGACY, no_features):
        for m, want in ((face, "Fluo"), (nobody, "AsShot")):
            assert taste.wb_call(mod, m) == want
            assert taste.wb_call(mod, dict(m, wb_green=0.4)) == want, "a legacy model read the green"


def test_a_model_fitted_with_the_green_says_nothing_about_a_frame_without_it():
    """Filled with 0 it would be a reading the camera never made - exactly
    daylight-green - and scored as if it had. None is what a model says when
    it has nothing to say, and presets then leaves the frame as the camera
    shot it. With the green, the row is the legacy ten and the green last."""
    green = dict(_LEGACY, features=taste.WB_FEATS + [taste.WB_GREEN], mu=_LEGACY["mu"] + [0.1],
                 sd=_LEGACY["sd"] + [0.1], w=[0.0] * 10 + [2.0], b=0.0)
    m = {"kelvin": 3300.0, "cast_a": 0.0, "cast_b": 4.0, "light_chroma": 10.0, "frame_L": 45.0, "range": 60.0}
    assert taste.wb_call(green, m) is None
    assert taste.wb_call(green, dict(m, wb_green=None)) is None
    assert taste.wb_call(green, dict(m, wb_green=0.3)) == "Fluo"          # z = +2, weight 2: p = 0.98
    assert taste.wb_call(green, dict(m, wb_green=-0.1)) == "AsShot"       # z = -2
    assert taste._wb_row(dict(m, wb_green=0.3), green["features"]) == \
        [3300.0, 0.0, 4.0, 10.0, 45.0, 60.0, 0.0, 0.0, 0.0, 0.0, 0.3]
    # And evidence this version cannot read is not guessed at either.
    assert taste.wb_call(dict(green, features=green["features"] + ["tomorrow"]), dict(m, wb_green=0.3)) is None


# ------------------------------------------------------------ fitting with it

def _shoots(seed: int = 3, groups: int = 8, per: int = 15) -> list[tuple[dict, dict]]:
    """Frames where he chose Fluo exactly where the camera read the light as
    green, and the kelvin says nothing: both classes shot at 3000-3400 K,
    the neutrals and the frame noise alike in both. Every scene holds both
    decisions, so each held-out scene is a real question."""
    rng = np.random.default_rng(seed)
    out = []
    for gi in range(groups):
        for j in range(per):
            fluo = (j + gi) % 2 == 0
            m = {"kelvin": float(rng.uniform(3000, 3400)), "cast_a": float(rng.normal(0, 2)),
                 "cast_b": float(rng.normal(5, 2)), "light_chroma": float(rng.uniform(5, 20)),
                 "frame_L": float(rng.uniform(30, 60)), "range": float(rng.uniform(40, 80)),
                 "wb_green": float(rng.normal(0.25 if fluo else 0.0, 0.05)), "_group": f"2026-09-21/{gi}"}
            out.append((m, {"WhiteBalanceRawPreset": '"Fluo"' if fluo else '"AsShot"'}))
    return out


def test_with_the_green_on_every_frame_the_fit_uses_it_and_beats_always_asshot():
    """Kelvin cannot tell these frames apart and the green can, so the fit
    that may read the green learns his decision, held out by scene, and the
    one that may not learns nothing it can keep."""
    samples = _shoots()
    assert all(taste._has_green(m) for m, _ in samples)
    wb = taste.learn_wb(samples)
    assert wb["n"] == 120 and wb["n_fluo"] >= taste.WB_MIN_CLASS and wb["n"] - wb["n_fluo"] >= taste.WB_MIN_CLASS
    assert wb["scenes"] == 8
    assert wb["features"] == taste.WB_FEATS + [taste.WB_GREEN]
    assert "w" in wb and len(wb["w"]) == len(wb["mu"]) == 11
    assert wb["auc"] >= taste.WB_MIN_AUC and wb["accuracy"] > wb["always_asshot"]
    assert taste.wb_call(wb, {"kelvin": 3200.0, "wb_green": 0.27}) == "Fluo"
    assert taste.wb_call(wb, {"kelvin": 3200.0, "wb_green": 0.01}) == "AsShot"
    assert taste.wb_call(wb, {"kelvin": 3200.0}) is None

    blind = taste.learn_wb([({k: v for k, v in m.items() if k != taste.WB_GREEN}, s) for m, s in samples])
    assert blind["features"] == taste.WB_FEATS
    assert "w" not in blind, "kelvin alone could not have learned this; the green is what did"


def test_the_green_missing_on_some_frames_is_left_out_of_the_fit_entirely():
    """The leak it exists to refuse. His stored frames lack the green where
    they were measured before it was kept, and the shoots that were are
    venues, and a venue is very nearly its white balance. Here the frames
    that lack it are the Fluo frames of three scenes - an older shoot - and
    a fit that flagged or filled the gap would be handed "which shoot" as a
    column. Instead it fits exactly as if the green did not exist: the same
    model, number for number, as the fit with it stripped from every frame."""
    samples = _shoots()
    old = {f"2026-09-21/{gi}" for gi in (0, 1, 2)}
    patchy = [({k: v for k, v in m.items() if not (k == taste.WB_GREEN and m["_group"] in old and s["WhiteBalanceRawPreset"] == '"Fluo"')}, s)
              for m, s in samples]
    assert 0 < sum(not taste._has_green(m) for m, _ in patchy) < len(patchy)
    wb = taste.learn_wb(patchy)
    assert wb["features"] == taste.WB_FEATS
    assert len(wb.get("mu") or [0] * 10) == 10
    stripped = taste.learn_wb([({k: v for k, v in m.items() if k != taste.WB_GREEN}, s) for m, s in samples])
    assert json.dumps(wb, sort_keys=True) == json.dumps(stripped, sort_keys=True)


def test_only_the_frames_a_fit_is_made_on_decide_whether_it_reads_the_green():
    """A JPEG (no kelvin) or a Cloudy frame is not a decision the fit learns
    from, so its missing green is no reason to leave the green out. And the
    gate's comparison builds its one matrix by the same rule, so both of its
    arms see the same columns as the candidate did."""
    samples = _shoots()
    samples += [({"kelvin": None, "frame_L": 40.0, "_group": "2026-09-21/0"}, {"WhiteBalanceRawPreset": "AsShot"}),
                ({"kelvin": 3300.0, "frame_L": 40.0, "_group": "2026-09-21/1"}, {"WhiteBalanceRawPreset": "Cloudy"})]
    assert taste.learn_wb(samples)["features"] == taste.WB_FEATS + [taste.WB_GREEN]
    X, y, groups, at = taste._wb_labelled(samples)
    assert X.shape == (120, 11) and len(at) == 120

    samples[0][0].pop(taste.WB_GREEN)
    assert taste.learn_wb(samples)["features"] == taste.WB_FEATS
    X, *_ = taste._wb_labelled(samples)
    assert X.shape == (120, 10)
