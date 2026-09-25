"""Brightness, face lightness and contrast, per frame, from his exports.

"These need to be dynamic based on ML models not just hard constants." The
exposure and the tone curve aimed every frame at a constant (a midtone L* by
light level, a face at the band's middle, an S-curve by light); each is now a
small model of where his finished exports put it, used in place of the
constant only where it beats the constant on shoots it had not seen, by 10%
and by a sign test, and bounded by every limit the constant was.

These pin down: when his exports follow something the rule does not, the
model is used, predicts a shoot it never saw, and beats the rule; when his
exports ARE the rule plus noise, the model is not used and says why; with too
few shoots it is held out by scene and says so; presets aims at a prediction
where there is one and at the constant where there is not, and says which on
the frame; the limits still bound a learned target; the S-curve is solved for
the predicted spread; the store keeps the new readings and reads an export's
tones once; and the gate holds a tone model that has not earned its place.
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import learned  # noqa: E402
import presets  # noqa: E402
import taste  # noqa: E402

GAIN = presets.RENDER_GAIN


def _frame(rng, lv: float, face: bool) -> tuple[dict, dict]:
    """A camera frame's measure() and linear_measure() + EXIF, as presets has
    them before anything is written."""
    frame_L = float(rng.uniform(25, 62))
    spread = float(rng.uniform(40, 70))
    lo = max(2.0, frame_L - spread * rng.uniform(0.4, 0.6))
    m = {"frame_L": frame_L, "range": spread, "L_p5": lo, "L_p95": min(98.0, lo + spread), "clip": float(rng.uniform(0, 0.01))}
    lin = {"lv": lv, "iso": float(100 * 2 ** rng.integers(0, 6)), "frame_Y": presets.Y(frame_L) / 2 ** GAIN,
           "headroom_ev": float(rng.uniform(1.0, 3.0))}
    if face:
        fl = float(rng.uniform(34, 60))
        m["face_L_big"] = fl
        lin["face_Y"] = presets.Y(fl) / 2 ** GAIN
    return m, lin


def his_taste(m: dict, lin: dict, rng) -> dict:
    """An exports' function the constants do not follow: darker the lower the
    light, brighter with a face in it; faces placed by the light; more
    contrast in daylight than in the dark."""
    lv = lin["lv"]
    face = "face_Y" in lin
    return {"ex_L50": 28 + 2.0 * lv + (6 if face else 0) + rng.normal(0, 1.0),
            "ex_face_L": (40 + 1.2 * lv + rng.normal(0, 1.0)) if face else None,
            "ex_spread": m["range"] * (1.02 + 0.02 * lv + rng.normal(0, 0.01))}


def rule_itself(m: dict, lin: dict, rng) -> dict:
    """Exports that are the rule's own output, plus noise."""
    r = presets.rule_tone(presets.tone_evidence(m, lin))
    return {"ex_L50": r["L50"] + rng.normal(0, 1.0),
            "ex_face_L": (r["face_L"] + rng.normal(0, 1.0)) if r["face_L"] is not None and "face_Y" in lin else None,
            "ex_spread": m["range"] * (r["spread_ratio"] + rng.normal(0, 0.01))}


def samples_of(fn, shoots: int = 5, per: int = 48, seed: int = 0, scenes: int = 4):
    """learn_edit's samples, built the way it builds them from the store."""
    rng = np.random.default_rng(seed)
    out, of = [], []
    for s in range(shoots):
        base_lv = rng.uniform(3, 13)
        for i in range(per):
            lv = float(np.clip(base_lv + rng.normal(0, 2.5), 1, 15))
            m, lin = _frame(rng, lv, face=bool(i % 2))
            ex = fn(m, lin, rng)
            mm = dict(m, _tone=presets.tone_evidence(m, lin), _ex_L50=ex["ex_L50"], _ex_spread=ex["ex_spread"],
                      _ex_face_L=ex["ex_face_L"], _scene=f"shoot{s}/{i % scenes}", _lin=lin)
            out.append((mm, {}))
            of.append(Path(f"/shoots/shoot{s}"))
    return out, of


# ------------------------------------------------ the learner

def test_where_his_exports_follow_the_light_the_model_is_used_and_beats_the_rule():
    tone = taste.learn_tone(*samples_of(his_taste))
    for key in taste.TONE_TARGETS:
        e = tone[key]
        assert e["used"], (key, e.get("why"))
        assert e["held_out"] == "shoot" and e["shoots"] == 5
        assert e["mae"] <= 0.9 * e["baseline_mae"], (key, e)
        assert taste._sign_p(e["wins"], e["losses"]) < 0.05
        assert e["features"] == taste.TONE_FEATS and len(e["w"]) == len(taste.TONE_FEATS)


def test_it_predicts_a_shoot_it_never_saw():
    got, of = samples_of(his_taste, shoots=6)
    train = [(s, sh) for s, sh in zip(got, of) if sh.name != "shoot5"]
    tone = taste.learn_tone([s for s, _ in train], [sh for _, sh in train])
    rng = np.random.default_rng(0)
    errs = {"L50": [], "face_L": [], "spread_ratio": []}
    for (m, _), sh in zip(got, of):
        if sh.name != "shoot5":
            continue
        ev = m["_tone"]
        errs["L50"].append(abs(taste.tone_call(tone["L50"], ev, "L50") - m["_ex_L50"]))
        if m["_ex_face_L"] is not None:
            errs["face_L"].append(abs(taste.tone_call(tone["face_L"], ev, "face_L") - m["_ex_face_L"]))
        errs["spread_ratio"].append(abs(taste.tone_call(tone["spread_ratio"], ev, "spread_ratio")
                                        - m["_ex_spread"] / ev["range"]))
    del rng
    assert np.mean(errs["L50"]) < 2.5 and np.mean(errs["face_L"]) < 2.5
    assert np.mean(errs["spread_ratio"]) < 0.03


def test_where_his_exports_are_the_rule_plus_noise_the_rule_stands_and_says_why():
    tone = taste.learn_tone(*samples_of(rule_itself, seed=3))
    for key in taste.TONE_TARGETS:
        e = tone[key]
        assert not e["used"], (key, e)
        assert "rule stands" in e["why"]
        assert "w" not in e
        assert taste.tone_call(e, {"lv": 10}, key) is None


def test_with_fewer_than_three_shoots_it_is_held_out_by_scene_and_says_so():
    tone = taste.learn_tone(*samples_of(his_taste, shoots=2, per=80))
    assert tone["L50"]["held_out"] == "scene"
    if tone["L50"]["used"]:
        assert "held out by scene" in taste.tone_words(tone["L50"], "L50", 45.0)


def test_too_few_frames_is_said_as_a_count():
    tone = taste.learn_tone(*samples_of(his_taste, shoots=3, per=6))
    assert not tone["L50"]["used"] and "too few" in tone["L50"]["why"]


def test_a_model_fitted_on_another_row_is_not_asked():
    tone = taste.learn_tone(*samples_of(his_taste))
    e = dict(tone["L50"], features=taste.TONE_FEATS[:-2])
    assert taste.tone_call(e, {"lv": 10}, "L50") is None


# ------------------------------------------------ presets

def _pred(**kw) -> dict:
    return {"L50": kw.get("L50"), "face_L": kw.get("face_L"), "spread_ratio": kw.get("spread_ratio"),
            "words": {k: f"{k} from your exports: test" for k in kw}}


def test_a_frame_with_no_face_aims_at_the_predicted_midtones_and_says_so():
    day = {"frame_Y": presets.Y(40) / 2 ** GAIN, "clip_any": 0.0, "faces": [], "lv": 12, "headroom_ev": 3.0}
    _, ev_rule, note_rule = presets.decide_exposure(dict(day), 50.0, gain=GAIN, prefer="Manual")
    assert "rule:" in note_rule
    _, ev, note = presets.decide_exposure(dict(day, pred=_pred(L50=52.0)), 50.0, gain=GAIN, prefer="Manual")
    want = math.log2(presets.Y(52.0) / day["frame_Y"]) - GAIN
    assert ev == pytest.approx(round(want, 2)) and ev != ev_rule
    assert "target L* 52" in note and "L50 from your exports" in note
    # A prediction under the frame darkens it, within the same floor as the rule.
    _, ev, _ = presets.decide_exposure(dict(day, pred=_pred(L50=30.0)), 50.0, gain=GAIN, prefer="Manual")
    assert ev < 0 and ev >= max(-presets.AUTO_EV_MAX, presets.BIAS_FLOOR)


def test_every_limit_still_bounds_a_learned_target():
    day = {"frame_Y": presets.Y(30) / 2 ** GAIN, "clip_any": 0.0, "faces": [], "lv": 12, "headroom_ev": 3.0,
           "pred": _pred(L50=90.0)}
    ev = presets.decide_exposure(dict(day), 50.0, gain=GAIN, prefer="Manual")[1]
    assert ev <= presets.AUTO_EV_MAX
    ev = presets.decide_exposure(dict(day, headroom_ev=0.5), 50.0, gain=GAIN, prefer="Manual")[1]
    assert ev <= 0.5 - presets.HEADROOM_MARGIN_EV + 1e-9
    assert presets.decide_exposure(dict(day, iso=12800), 50.0, gain=GAIN, prefer="Manual")[1] == 0.0
    night = dict(day, lv=3)                                    # low light: at most 0.2 stop at LV 3
    ev = presets.decide_exposure(night, 50.0, gain=GAIN, prefer="Manual")[1]
    assert ev <= presets.LOW_LIGHT_LIFT * (3 - presets.NIGHT_LV) / (presets.DAYLIGHT_LV - presets.NIGHT_LV) + 1e-9
    near = dict(day, pred=_pred(L50=presets.Lstar(presets.Y(30) * 2 ** 0.2)))
    assert presets.decide_exposure(near, 50.0, gain=GAIN, prefer="Manual")[1] == 0.0   # the deadband


def test_a_face_aims_at_the_predicted_lightness_inside_the_band_and_under_the_cap():
    y = presets.Y(43) / 2 ** GAIN
    lin = {"face_Y": y, "clip_any": 0.0, "faces": [], "headroom_ev": 3.0, "lv": 12, "frame_Y": y}
    _, ev_rule, note_rule = presets.decide_exposure(dict(lin), 50.0, gain=GAIN, prefer="Manual")
    assert "rule: face toward the band's middle" in note_rule
    _, ev, note = presets.decide_exposure(dict(lin, pred=_pred(face_L=48.0)), 50.0, gain=GAIN, prefer="Manual")
    assert ev == pytest.approx(round(math.log2(presets.Y(48.0) / y) - GAIN, 2)) and "toward L* 48" in note
    assert "face_L from your exports" in note
    # Asked for more than the cap: it stops at FACE_PREFERRED_MAX, and at the
    # daylight face lift.
    aim, _ = presets.face_aim(dict(lin, pred=_pred(face_L=75.0)))
    assert aim == presets.FACE_PREFERRED_MAX
    ev = presets.decide_exposure(dict(lin, pred=_pred(face_L=75.0)), 50.0, gain=GAIN, prefer="Manual")[1]
    assert ev <= presets.DAYLIGHT_FACE_LIFT
    # Asked for less than the band: held at its bottom, and never used to darken a face.
    assert presets.face_aim(dict(lin, pred=_pred(face_L=20.0)))[0] == presets.PUBLISHED.FACE_L_LO
    bright = dict(lin, face_Y=presets.Y(55) / 2 ** GAIN, pred=_pred(face_L=45.0))
    assert presets.decide_exposure(bright, 50.0, gain=GAIN, prefer="Manual")[1] == 0.0


def test_the_s_curve_is_solved_for_the_predicted_spread():
    m = {"frame_L": 45.0, "range": 50.0, "L_p5": 20.0, "L_p95": 70.0}
    for want in (1.02, 1.06, 1.10):
        c = presets.solve_contrast(want, m)
        assert 0 <= c <= presets.TONE_C_MAX
        assert presets.curve_spread_ratio(c, m) == pytest.approx(want, abs=1e-6)
    assert presets.solve_contrast(0.9, m) == 0.0                       # flatter than shot: no curve
    assert presets.solve_contrast(3.0, m) == presets.TONE_C_MAX        # past the reach of a gentle S
    pts, why = presets.tone_curve(12, 50.0, c=presets.solve_contrast(1.10, m), why="from your exports")
    assert pts[3] < 0.125 and why == "from your exports"
    assert presets.tone_curve(12, 90.0, c=0.1)[0] is None             # TONE_WIDE still stands
    # With nothing learned, exactly the rule's curve, and it says so.
    rule, rwhy = presets.tone_curve(12, 50.0)
    assert rwhy.startswith("rule: S-curve 0.10")
    c_rule = presets.rule_contrast(12)
    assert presets.curve_spread_ratio(c_rule, m) == pytest.approx(presets.rule_tone(
        presets.tone_evidence(m, {"lv": 12}))["spread_ratio"])
    assert rule[3] == pytest.approx(presets._s_curve(0.125, c_rule), abs=1e-4)


def test_predictions_come_only_from_models_in_use(monkeypatch):
    got, of = samples_of(his_taste)
    tone = taste.learn_tone(got, of)
    tone["face_L"] = dict(tone["face_L"], used=False)
    monkeypatch.setattr(taste, "load", lambda: {"tone": tone})
    m, lin = got[1][0], got[1][0]["_lin"]
    p = presets.predicted_tone(m, lin)
    assert p["L50"] is not None and p["spread_ratio"] is not None and p["face_L"] is None
    assert p["words"]["L50"].startswith("brightness from your exports: L* ")
    assert "learned on 240 frames, 5 shoots; held-out error" in p["words"]["L50"]
    monkeypatch.setattr(taste, "load", lambda: {})
    assert presets.predicted_tone(m, lin) == {"L50": None, "face_L": None, "spread_ratio": None, "words": {}}


def _frame_tones(monkeypatch, tmp_path, model, m, lin):
    shoot = tmp_path / "shoots" / "2026-09-30"
    (shoot / "raw").mkdir(parents=True)
    (shoot / "raw" / "TSC00001.ARW").write_bytes(b"raw")
    out = tmp_path / "out"
    (out / "previews").mkdir(parents=True)
    monkeypatch.setattr(presets, "measure_frames", lambda jobs, progress=None: {"TSC00001.ARW": {"m": m, "lin": lin}})
    monkeypatch.setattr(taste, "load", lambda: model)
    monkeypatch.setattr(taste, "shoot_overrides", lambda here: {})
    got = presets.frame_tones(shoot / "raw", out, [{"file": "TSC00001.ARW"}], {}, "", None, None, quiet=True)
    return got["TSC00001.ARW"]


def test_a_frame_says_which_decided_it(monkeypatch, tmp_path):
    got, of = samples_of(his_taste)
    tone = taste.learn_tone(got, of)
    m = {"frame_L": 30.0, "range": 50.0, "L_p5": 10.0, "L_p95": 60.0, "clip": 0.0, "kelvin": 4000.0}
    lin = {"clip_any": 0.0, "faces": [], "frame_Y": presets.Y(30) / 2 ** GAIN, "headroom_ev": 3.0, "lv": 12.0, "iso": 400.0}
    per = _frame_tones(monkeypatch, tmp_path, {"tone": tone}, dict(m), dict(lin))
    assert "brightness from your exports: L* " in per["_note"]
    assert "held-out error" in per["_note"] and "vs rule" in per["_note"]
    assert "tones spread x" in per["_note"]
    ratio = presets.predicted_tone(m, lin)["spread_ratio"]
    c = presets.solve_contrast(ratio, m)
    assert per["ToneCurveMasterPoints"][3] == pytest.approx(round(presets._s_curve(0.125, c), 4))
    per = _frame_tones(monkeypatch, tmp_path / "b", {}, dict(m), dict(lin))
    assert "rule: target by light level" in per["_note"] and "tone: rule: S-curve 0.10" in per["_note"]


# ------------------------------------------------ the store

class _Stop(Exception):
    pass


def test_an_export_kept_before_its_tones_were_is_read_once_without_touching_the_raw(tmp_path, monkeypatch):
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    shoot = tmp_path / "shoots" / "2026-09-19"
    (shoot / "raw").mkdir(parents=True)
    pv = tmp_path / "pv.jpg"
    pv.write_bytes(b"jpg")
    frames, rows = [], []
    for i in range(1, 23):
        name = f"TSC{i:05d}.ARW"
        raw = shoot / "raw" / name
        raw.write_bytes(b"raw")
        frames.append({"shoot": shoot, "name": name, "stem": name[:-4], "raw": raw, "preview": pv,
                       "settings": {}, "sidecar": "abc", "export": "e"})
        row = {"key": f"2026-09-19/{name}", "kind": "frame", "shoot": "2026-09-19", "stem": name[:-4],
               "schema": taste.MEASURE_SCHEMA, "sidecar": "abc", "export": "e", "m": {}, "exported": True,
               "clip_any": 0.0, "subject_Y": None, "frame_Y": 0.05, "headroom_ev": 2.0, "lv": 10.0, "iso": 400.0}
        if i != 1:
            row.update(ex_L50=None, ex_spread=None)       # read already (no export then)
        rows.append(row)
    monkeypatch.setattr(taste, "teaching", lambda root: frames)
    learned.measured_add(rows)

    def no_raw(jobs, progress=None):
        raise AssertionError("an export's tones need no RAW read")
    monkeypatch.setattr(presets, "measure_frames", no_raw)
    monkeypatch.setattr("faces.FaceJudge", lambda: None)
    monkeypatch.setattr(taste, "exported_at", lambda max_age=60.0: {})
    monkeypatch.setattr(taste, "is_exported", lambda raw, at=None: True)
    monkeypatch.setattr(taste, "export_path", lambda stem: "x_DxO.jpg" if stem == "TSC00001" else None)
    monkeypatch.setattr(taste, "export_face_L_one", lambda stem, judge: None)
    monkeypatch.setattr(taste, "export_tones", lambda stem: {"ex_L50": 44.0, "ex_spread": 61.0})

    def stop(force=False):
        raise _Stop
    monkeypatch.setattr(learned, "measured_compact", stop)
    with pytest.raises(_Stop):
        taste.learn_edit(tmp_path / "shoots")
    table, _ = learned.measured_read("frame")
    assert table["2026-09-19/TSC00001.ARW"]["ex_L50"] == 44.0
    assert table["2026-09-19/TSC00002.ARW"]["ex_L50"] is None


def test_a_row_without_the_raw_readings_the_model_needs_is_measured_once_more_while_its_raw_is_here(tmp_path, monkeypatch):
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    shoot = tmp_path / "shoots" / "2026-09-19"
    (shoot / "raw").mkdir(parents=True)
    pv = tmp_path / "pv.jpg"
    pv.write_bytes(b"jpg")
    frames, rows = [], []
    full = {"clip_any": 0.0, "subject_Y": None, "frame_Y": 0.05, "headroom_ev": 2.0, "lv": 10.0, "iso": 400.0,
            "ex_L50": None, "ex_spread": None}
    for i in range(1, 23):
        name = f"TSC{i:05d}.ARW"
        raw = shoot / "raw" / name
        raw.write_bytes(b"raw")
        frames.append({"shoot": shoot, "name": name, "stem": name[:-4], "raw": raw, "preview": pv,
                       "settings": {}, "sidecar": "abc", "export": "e"})
        row = {"key": f"2026-09-19/{name}", "kind": "frame", "shoot": "2026-09-19", "stem": name[:-4],
               "schema": taste.MEASURE_SCHEMA, "sidecar": "abc", "export": "e", "m": {}, **full}
        if i == 3:
            del row["headroom_ev"]                         # measured after clip_any, before the headroom was kept
        rows.append(row)
    monkeypatch.setattr(taste, "teaching", lambda root: frames)
    learned.measured_add(rows)
    seen = {}

    def measured(jobs, progress=None):
        seen["jobs"] = jobs
        raise _Stop
    monkeypatch.setattr(presets, "measure_frames", measured)
    monkeypatch.setattr("faces.FaceJudge", lambda: None)
    monkeypatch.setattr(taste, "exported_at", lambda max_age=60.0: {})
    with pytest.raises(_Stop):
        taste.learn_edit(tmp_path / "shoots")
    assert [Path(j[3]).name for j in seen["jobs"]] == ["TSC00003.ARW"]


def test_the_camera_jpeg_keeps_the_ends_of_its_spread():
    img = np.zeros((200, 300, 3), np.uint8)
    img[:, :100] = 40
    img[:, 100:200] = 120
    img[:, 200:] = 220
    m = presets.measure(img, [], None)
    assert m["L_p95"] - m["L_p5"] == pytest.approx(m["range"])
    assert presets.spread_ends(m) == (m["L_p5"], m["L_p95"])
    old = {"frame_L": 50.0, "range": 40.0}                 # a row kept before the ends were
    assert presets.spread_ends(old) == (30.0, 70.0)


# ------------------------------------------------ the gate

def _used(**kw) -> dict:
    e = {"used": True, "mae": 2.0, "baseline_mae": 4.0, "wins": 90, "losses": 30, "n": 120, "shoots": 4,
         "held_out": "shoot", "why": "x"}
    e.update(kw)
    return e


def test_the_gate_passes_a_tone_model_that_cleared_its_bar():
    why, unchecked = learned._check_tone({"L50": _used()}, {}, measured_here=True)
    assert why == [] and not unchecked


def test_the_gate_holds_a_tone_model_that_did_not_beat_the_rule():
    why, _ = learned._check_tone({"L50": _used(mae=3.8)}, {}, measured_here=True)
    assert why and "has not earned the place of the rule" in why[0]
    why, _ = learned._check_tone({"L50": _used(wins=50, losses=45)}, {}, measured_here=True)
    assert why and "closer to your export on 50 and further on 45" in why[0]


def test_the_gate_holds_a_candidate_that_would_drop_a_tone_model_in_use():
    why, _ = learned._check_tone({"L50": {"used": False, "why": "not 10% better"}}, {"L50": _used()}, True)
    assert why and "stop taking each frame's brightness from your exports" in why[0]


def test_the_gate_holds_a_tone_model_worse_than_the_one_in_use_on_the_same_frames():
    new = {"L50": _used(), "against_live": {"L50": {"frames": 80, "now": 2.0, "new": 2.5}}}
    why, _ = learned._check_tone(new, {"L50": _used()}, True)
    assert why and "on the 80 frames that taught the one in use" in why[0]
    new["against_live"]["L50"]["new"] = 2.05                # inside the refit's own jitter
    assert learned._check_tone(new, {"L50": _used()}, True)[0] == []


def test_a_tone_model_with_no_counts_waits_for_a_run_from_outside_and_is_held_from_here():
    bare = {"L50": {"used": True, "w": [0.0] * len(taste.TONE_FEATS)}}
    why, unchecked = learned._check_tone(bare, {}, measured_here=False)
    assert unchecked and "next learning run checks it" in why[0]
    why, unchecked = learned._check_tone(bare, {}, measured_here=True)
    assert not unchecked and "carries no held-out count" in why[0]


def test_against_live_compares_pools_on_the_frames_that_taught_the_one_in_use():
    got, of = samples_of(his_taste, shoots=6)
    tone = taste.learn_tone(got, of)
    live = {"tone": tone, "dataset": {"shoots": [{"shoot": f"shoot{i}"} for i in range(4)]}}
    a = taste.tone_against_live(got, of, live, tone)
    assert set(a) == set(taste.TONE_TARGETS)
    assert a["L50"]["frames"] > 0 and a["L50"]["new"] <= a["L50"]["now"] * (1 + taste.TONE_LIVE_TOL)
    assert taste.tone_against_live(got, of, {"tone": tone}, tone) is None      # nothing says what taught it


def test_the_report_and_the_dataset_say_where_each_comes_from():
    tone = taste.learn_tone(*samples_of(his_taste))
    s = taste.tone_sentence(tone)
    assert s.startswith("From your exports, per frame: brightness, face lightness, contrast")
    mod = {"n": 10, "numeric": {}, "categorical": {}, "tone": tone}
    text = taste.report(mod)
    assert "brightness" in text and "used" in text
    none = taste.learn_tone(*samples_of(rule_itself, seed=3))
    assert "still the rules'" in taste.tone_sentence(none)
