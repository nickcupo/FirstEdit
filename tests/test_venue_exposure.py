"""The exposure type, per venue.

His exposure type is a decision about a place, and the pooled learner that
tried to make it one decision for every place lost to a constant on three of
his four shoots. So a venue's own fit is learned on that venue's own finished
frames, used only where it beats both the rule and the venue's commonest
type on scenes it had not seen, each by more than chance, and used only on
the shoot that taught it; the gate refuses a candidate whose counts do not
clear that same bar.

These pin down: the rule is one function, and the learner replays exactly it;
a fit is held out by scene and scaled on its own training frames; it is used
only where it earns it, and says why where it does not; the gate names the
shoot and checks every condition; presets writes the venue's answer only on
the shoot that taught it, never on one that borrows the venue or measures
like nothing; and the page says where it is used and what would let it be
checked.
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


# ----------------------------------------------------------------- the rule

@pytest.mark.parametrize("lin, prefer, mode", [
    ({"clip_any": 0.0005, "face_Y": 0.10}, None, "Manual"),
    ({"clip_any": 0.01, "face_Y": 0.10}, None, "StrongHighlightRecovery"),
    ({"clip_any": 0.01, "face_Y": 0.01}, None, "MediumHighlightRecovery"),
    ({"clip_any": 0.01, "subject_Y": 0.01}, None, "MediumHighlightRecovery"),
    ({"clip_any": 0.01, "face_Y": 0.10}, "Manual", "Manual"),
    ({"clip_any": 0.01, "face_Y": 0.10}, "StrongHighlightRecovery", "StrongHighlightRecovery"),
])
def test_the_rule_is_one_function_and_decide_exposure_writes_what_it_says(lin, prefer, mode):
    assert presets.exposure_mode(lin, prefer) == mode
    keys, _, _ = presets.decide_exposure({**lin, "faces": []}, 50.0, prefer=prefer)
    assert keys["ExposureAutoMode"] == mode


def test_a_frame_whose_sensor_reading_was_never_kept_is_unknown_not_manual():
    """A frame measured before the store kept clip_any, whose RAW has gone:
    the rule's answer there is unknown, and scoring it as Manual would have
    credited or blamed the rule for a decision nobody can replay."""
    assert presets.exposure_mode({"face_Y": 0.1}, None) is None
    assert presets.exposure_mode({"face_Y": 0.1}, "Manual") == "Manual"     # the venue's type needs no reading


def test_the_venue_answer_overrides_which_and_never_how_much():
    lin = {"clip_any": 0.0, "face_Y": 0.10, "faces": []}
    keys, ev, note = presets.decide_exposure(lin, 50.0, mode="StrongHighlightRecovery", why="the venue's own type")
    assert keys == {"ExposureActive": True, "ExposureAutoMode": "StrongHighlightRecovery"} and ev == 0.0
    assert note.endswith("; the venue's own type")
    # Anything that is not one of the three is ignored, and the rule decides.
    keys, _, note = presets.decide_exposure(lin, 50.0, mode="Slight", why="nonsense")
    assert keys["ExposureAutoMode"] == "Manual" and "nonsense" not in note


# ------------------------------------------------------------ the learner

def _venue(n_groups: int = 8, per: int = 6, clip: bool = True, rule_right: bool = False,
           noise: float = 0.0, seed: int = 0) -> list[tuple[dict, dict]]:
    """One venue's finished frames, where his type follows the frame's
    brightness cleanly and scene by scene. With `rule_right` the sensor
    readings are set so the rule agrees with him on every frame; otherwise
    they are set so it never does."""
    rng = np.random.default_rng(seed)
    out = []
    for g in range(n_groups):
        for k in range(per):
            bright = (g + k) % 3
            mode = ("Manual", "StrongHighlightRecovery", "MediumHighlightRecovery")[bright]
            if noise and rng.random() < noise:
                mode = "Manual" if mode != "Manual" else "StrongHighlightRecovery"
            m = {"frame_L": 20.0 + 30 * bright + rng.normal(0, 1), "range": 50.0, "clip": 0.01 * bright,
                 "kelvin": 4000.0, "_scene": f"s{g}", "_face_Y": 0.1}
            if clip:
                if rule_right:
                    m["_clip_any"] = 0.0 if mode == "Manual" else 0.01
                    m["_face_Y"] = 0.1 if mode == "StrongHighlightRecovery" else 0.01
                else:
                    m["_clip_any"] = 0.01 if mode == "Manual" else 0.0
            out.append((m, {"ExposureAutoMode": f'"{mode}"'}))
    return out


def test_a_venue_whose_own_fit_beats_the_rule_and_its_commonest_type_uses_it():
    e = taste.venue_exposure(_venue(), prefer=None)
    assert e["used"], e["why"]
    assert e["fit_right"] > e["rule_right"] and e["fit_right"] > e["commonest_right"]
    assert e["held_out"] == "scene" and e["groups"] == 8
    assert e["vs"]["rule"]["p"] < taste.EXPO_P and e["vs"]["commonest"]["p"] < taste.EXPO_P
    assert taste.expo_beats(e) == (True, "")
    # Counts of his frames, never a bare decimal, in the words the page reads.
    assert f"right on {e['fit_right']} of {e['frames']}" in e["why"]
    # And it answers for a frame of that venue.
    m, _ = _venue()[0]
    assert taste.predict_exposure({"exposure": e}, m) in taste.EXPO_MODES


def test_where_the_rule_already_gets_it_right_the_rule_stands():
    e = taste.venue_exposure(_venue(rule_right=True), prefer=None)
    assert not e["used"]
    assert e["rule_right"] == e["frames"]
    assert taste.predict_exposure({"exposure": e}, _venue()[0][0]) is None


def test_a_venue_the_rule_cannot_be_replayed_on_keeps_the_rule_and_says_why():
    """The portraits venue: its own fit wins by a distance, but its RAWs went
    to iCloud before the store kept the sensor reading the rule needs, so
    nothing can say the fit beats the rule there. It is not used, and the
    reason is one he can act on."""
    e = taste.venue_exposure(_venue(clip=False), prefer=None)
    assert not e["used"]
    assert e["rule_right"] is None and e["rule_unknown"] == e["frames"]
    assert e["fit_right"] > e["commonest_right"]
    assert "cannot be replayed" in e["why"]


def test_a_venue_near_unanimous_about_its_type_needs_no_sensor_reading_to_replay_the_rule():
    frames = [({"frame_L": 30.0 + i % 7, "_scene": f"s{i % 5}"}, {"ExposureAutoMode": '"Manual"'}) for i in range(60)]
    e = taste.venue_exposure(frames, prefer="Manual")
    assert e["rule_right"] == 60 and not e["used"]


def test_too_few_frames_to_hold_out_is_said_as_a_count():
    e = taste.venue_exposure(_venue(n_groups=2, per=5), prefer=None)
    assert not e["used"] and f"it needs {taste.EXPO_MIN_FRAMES} in {taste.EXPO_MIN_GROUPS}" in e["why"]


def test_it_is_held_out_by_scene_even_where_the_starting_edit_holds_out_by_burst():
    """learn_edit groups a shoot by burst when fewer than three of its scenes
    have eight frames; 2026-09-19 is such a shoot, with 31 scenes. A burst's
    neighbours in the same scene share its light, so a fit held out by burst
    has seen the answer, and the page's "on scenes it had not seen" was not
    true there. Scenes are used whenever there are enough of them."""
    frames = _venue(n_groups=8, per=6)
    for i, (m, _) in enumerate(frames):
        m["_burst"] = f"b{i}"                 # every frame its own burst
        m["_group"] = m["_burst"]             # what learn_edit handed over
    e = taste.venue_exposure(frames, prefer=None)
    assert e["held_out"] == "scene" and e["groups"] == 8


def test_with_too_few_scenes_it_is_held_out_by_burst_and_says_so():
    frames = _venue(n_groups=8, per=6)
    for i, (m, _) in enumerate(frames):
        m["_burst"] = m.pop("_scene")
        m["_scene"] = "one" if i % 2 else "two"
    e = taste.venue_exposure(frames, prefer=None)
    assert e["held_out"] == "burst" and e["groups"] == 8
    assert "on bursts it had not seen" in e["why"]
    assert taste.expo_held_words(e) == "bursts"


def test_each_held_out_fit_is_scaled_on_its_own_training_frames(monkeypatch):
    """Scaled on every frame, the frames held out were part of the fit
    scored on them. Every fold's training frames come in centred on
    themselves."""
    seen = []
    real = taste._expo_fit

    def spy(Z, ys):
        seen.append(Z)
        return real(Z, ys)
    monkeypatch.setattr(taste, "_expo_fit", spy)
    frames = _venue(n_groups=6, per=6, seed=4)
    for m, _ in frames:
        m["kelvin"] = 3000.0 + 400 * int(m["_scene"][1:])     # each scene its own light
    taste.venue_exposure(frames, prefer=None)
    assert len(seen) >= 6
    for Z in seen[:6]:
        assert np.allclose(Z.mean(0), 0.0, atol=1e-9)


def test_a_fit_that_beats_the_rule_but_not_its_commonest_type_by_more_than_chance_is_not_used():
    """Both baselines, each by a sign test: a fit that edges the rule and
    ties the constant has earned nothing."""
    x = {"used": True, "frames": 100, "fit_right": 60, "rule_right": 30, "commonest_right": 58,
         "vs": {"rule": {"wins": 35, "losses": 5}, "commonest": {"wins": 10, "losses": 8}}}
    ok, why = taste.expo_beats(x)
    assert not ok and "its commonest type on too few frames to be sure (10 won, 8 lost)" in why
    x["commonest_right"] = 61
    ok, why = taste.expo_beats(x)
    assert not ok and "always" in why and "is right on 61" in why
    assert taste.expo_beats({"used": True, "frames": 100, "fit_right": 90})[0] is False


def test_his_slight_recovery_counts_as_medium_and_a_bare_bias_as_manual():
    assert taste.expo_mode({"ExposureAutoMode": '"SlightHighlightRecovery"'}) == "MediumHighlightRecovery"
    assert taste.expo_mode({"ExposureBias": "-0.7"}) == "Manual"
    assert taste.expo_mode({"ExposureBias": "0"}) == ""


def test_the_sign_test_is_one_sided_and_exact():
    assert taste._sign_p(0, 0) == 1.0
    assert math.isclose(taste._sign_p(5, 0), 1 / 32)
    assert taste._sign_p(3, 3) > 0.5


# --------------------------------------------------------------- the gate

def _edit(exposure: dict, label: str = "a finished shoot", shoots=("2026-09-05-the-gals",)) -> dict:
    return {"n": 600, "venues": {"shoots": {"v1": {"label": label, "shoots": list(shoots), "exposure": exposure}}}}


def _counts(fit=160, rule=120, com=105, frames=198, rw=45, rl=5, cw=60, cl=5, **kw) -> dict:
    return {"used": True, "frames": frames, "fit_right": fit, "rule_right": rule, "commonest_right": com,
            "commonest": "StrongHighlightRecovery",
            "vs": {"rule": {"wins": rw, "losses": rl}, "commonest": {"wins": cw, "losses": cl}}, **kw}


def test_the_gate_refuses_a_venue_fit_worse_than_the_rule_and_names_the_shoot():
    bad = _counts(fit=90, rule=120, rw=5, rl=35)
    check = learned.check_edit(_edit(bad), {"n": 527}, measured_here=True)
    assert not check["passed"]
    assert "2026-09-05-the-gals" in check["sentence"], check["sentence"]
    assert "of that shoot's 198 finished frames, on scenes it had not seen, it is right on 90" in check["sentence"]
    assert "the rule is right on 120" in check["sentence"]
    # His own label beside the shoot, where he gave one.
    named = learned.check_edit(_edit(bad, label="portraits, two people"), {"n": 527}, measured_here=True)
    assert '2026-09-05-the-gals ("portraits, two people")' in named["sentence"], named["sentence"]


def test_the_gate_checks_the_commonest_type_and_the_sign_test_not_only_the_rule():
    """The verifier's case: fit 28, rule 27, commonest 79 used to pass. It
    is held now, and so is a fit that wins on both counts by too few frames
    to be sure."""
    loses_to_constant = _counts(fit=28, rule=27, com=79, frames=100, rw=3, rl=2, cw=2, cl=53)
    check = learned.check_edit(_edit(loses_to_constant), {"n": 527}, measured_here=True)
    assert not check["passed"] and "is right on 79" in check["sentence"], check["sentence"]
    lucky = _counts(fit=110, rule=108, com=100, frames=198, rw=4, rl=2, cw=12, cl=2)
    check = learned.check_edit(_edit(lucky), {"n": 527}, measured_here=True)
    assert not check["passed"] and "the rule on too few frames to be sure (4 won, 2 lost)" in check["sentence"]


def test_a_venue_fit_fitted_here_with_no_counts_is_held_not_passed():
    """measured_here used to let a used venue with no counts at all through
    in silence. A fit made here always carries them."""
    blind = {"used": True, "frames": 198, "fit": {"manual": True}}
    check = learned.check_edit(_edit(blind), {"n": 527}, measured_here=True)
    assert not check["passed"] and not check["couldnt_check"]
    assert "2026-09-05-the-gals it would choose the exposure type itself" in check["sentence"], check["sentence"]


def test_the_gate_passes_a_venue_fit_that_clears_the_bar_and_ignores_one_not_used():
    assert learned.check_edit(_edit(_counts()), {"n": 527}, measured_here=True)["passed"]
    unused = {"used": False, "frames": 198, "fit_right": 10, "rule_right": 120}
    assert learned.check_edit(_edit(unused), {"n": 527}, measured_here=True)["passed"]


def test_what_the_learner_marks_used_the_gate_passes():
    """One bar, read by both: a fit venue_exposure puts in use is never one
    check_edit then refuses."""
    e = taste.venue_exposure(_venue(), prefer=None)
    assert e["used"]
    assert learned.check_edit(_edit(e), {"n": 527}, measured_here=True)["passed"]


def test_a_venue_fit_that_arrives_unmeasured_waits_for_a_run():
    """An import carries weights and no count of the rule: nothing has
    measured it on his photographs, so it waits rather than passing."""
    blind = {"used": True, "frames": 198, "fit": {"manual": True}}
    check = learned.check_edit(_edit(blind), {"n": 527})
    assert not check["passed"] and check["couldnt_check"]
    assert "exposure type" in check["sentence"]


# ------------------------------------------------ what reaches a sidecar

def _shoot(tmp_path) -> Path:
    return tmp_path / "shoots" / "2026-09-30"


def _fitted(label="the gym") -> dict:
    return {"label": label, "shoots": ["2026-09-30"], "type": None,
            "exposure": {"used": True, "fit": {"manual": False, "strong": True}, "frames": 198, "fit_right": 160,
                         "rule_right": 120, "held_out": "scene",
                         "mu": [0.0] * (2 * len(taste.EXPO_FEATS)), "sd": [1.0] * (2 * len(taste.EXPO_FEATS))}}


def _frame_tones(monkeypatch, tmp_path, venue, lin):
    shoot = _shoot(tmp_path)
    (shoot / "raw").mkdir(parents=True)
    (shoot / "raw" / "TSC00001.ARW").write_bytes(b"raw")
    out = tmp_path / "out"
    (out / "previews").mkdir(parents=True)
    m = {"frame_L": 40.0, "range": 50.0, "clip": 0.0, "kelvin": 4000.0}
    monkeypatch.setattr(presets, "measure_frames", lambda jobs, progress=None: {"TSC00001.ARW": {"m": m, "lin": lin}})
    monkeypatch.setattr(taste, "load", lambda: {})
    monkeypatch.setattr(taste, "shoot_overrides", lambda here: {})
    got = presets.frame_tones(shoot / "raw", out, [{"file": "TSC00001.ARW"}], {}, "", None, None,
                              quiet=True, venue=venue)
    return got["TSC00001.ARW"]


def test_the_shoot_that_taught_a_fit_writes_its_own_type_and_says_so(monkeypatch, tmp_path):
    lin = {"clip_any": 0.0, "face_Y": 0.1, "faces": []}          # the rule alone says Manual
    here = taste.venue_id(_shoot(tmp_path))
    per = _frame_tones(monkeypatch, tmp_path, (here, _fitted()), lin)
    assert per["ExposureAutoMode"] == "StrongHighlightRecovery"
    assert "this shoot's own finished frames: right on 160 of 198 on scenes it had not seen" in per["_note"]


def test_a_shoot_that_only_measures_like_a_venue_gets_the_rule_not_its_fit(monkeypatch, tmp_path):
    """A new shoot matched to a venue by its spread borrows that venue's look,
    never its exposure type: the fit was scored on that venue's own frames
    and nothing has measured it on this one. Borrowing a venue's answer lost
    to a constant on 3 of 4 of his shoots."""
    lin = {"clip_any": 0.0, "face_Y": 0.1, "faces": []}
    assert taste.venue_id(_shoot(tmp_path)) != "gymvenue"
    per = _frame_tones(monkeypatch, tmp_path, ("gymvenue", _fitted()), lin)
    assert per["ExposureAutoMode"] == "Manual"
    assert "own finished frames" not in per["_note"]


def test_a_shoot_like_no_venue_gets_the_rule(monkeypatch, tmp_path):
    lin = {"clip_any": 0.0, "face_Y": 0.1, "faces": []}
    per = _frame_tones(monkeypatch, tmp_path, None, lin)
    assert per["ExposureAutoMode"] == "Manual"
    assert "own finished frames" not in per["_note"]


def test_a_venue_whose_fit_did_not_earn_it_gets_the_rule(monkeypatch, tmp_path):
    entry = {"label": "x", "exposure": {"used": False, "fit_right": 10, "frames": 50}}
    per = _frame_tones(monkeypatch, tmp_path, ("v1", entry), {"clip_any": 0.0, "face_Y": 0.1, "faces": []})
    assert per["ExposureAutoMode"] == "Manual"


# ------------------------------------------------ what the store keeps

class _Stop(Exception):
    pass


def test_a_frame_measured_before_the_store_kept_the_sensor_reading_is_measured_once_more(tmp_path, monkeypatch):
    """While its RAW is here: so the rule can be replayed on it for good. A
    frame whose RAW has gone, or that already carries the reading, is left
    exactly as it was."""
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    shoot = tmp_path / "shoots" / "2026-09-19"
    (shoot / "raw").mkdir(parents=True)
    pv = tmp_path / "pv.jpg"
    pv.write_bytes(b"jpg")
    frames, rows = [], []
    for i in range(1, 23):
        name = f"TSC{i:05d}.ARW"
        raw = shoot / "raw" / name
        here = i != 2                                   # frame 2's RAW has gone to iCloud
        if here:
            raw.write_bytes(b"raw")
        frames.append({"shoot": shoot, "name": name, "stem": name[:-4], "raw": raw if here else None,
                       "preview": pv, "settings": {"ExposureAutoMode": '"Manual"'}, "sidecar": "abc", "export": "e"})
        row = {"key": f"2026-09-19/{name}", "kind": "frame", "shoot": "2026-09-19",
               "schema": taste.MEASURE_SCHEMA, "sidecar": "abc", "export": "e", "m": {}}
        if i > 2:                                       # measured since the store kept the reading
            row.update(clip_any=0.001, subject_Y=None, frame_Y=0.05, headroom_ev=2.0, lv=10.0, iso=400.0)
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
    assert [Path(j[3]).name for j in seen["jobs"]] == ["TSC00001.ARW"]


def test_a_candidate_that_passes_says_where_it_chooses_the_exposure_type_itself():
    check = learned.check_edit(_edit(_counts(), label="portraits"), {"n": 527}, measured_here=True)
    assert check["passed"]
    assert ('on 2026-09-05-the-gals ("portraits") (right on 160 of 198 on scenes it had not seen, where the '
            'rule is right on 120)') in check["sentence"], check["sentence"]
    assert "on every new shoot, the rule decides" in check["sentence"]


def test_while_a_venue_fit_is_in_use_the_page_says_so_on_the_in_use_line(tmp_path, monkeypatch):
    """The check's sentence said it once, the day it passed; the in-use line
    read only "Learned from 900 finished frames", and his exposure types
    would have changed with nothing on the page to say why."""
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    model = {"n": 900, "numeric": {}, "vocab": {},
             "venues": {"shoots": {"v1": {"label": "the room", "shoots": ["2026-10-01"], "exposure": _counts()}}}}
    res = learned.submit("edit", model, source="learned: you finished 2026-10-01")
    assert res["state"] == "in_use", res
    row = next(r for r in learned.panel()["learners"] if r["id"] == "edit")
    assert row["state"] == "in_use"
    assert "It chooses the exposure type from that shoot's own finished frames on 2026-10-01" in row["sentence"]
    assert "right on 160 of 198" in row["sentence"]


def test_the_page_says_which_shoot_to_bring_back_so_its_exposure_type_can_be_checked(tmp_path, monkeypatch):
    """The portraits venue's own fit wins by a distance, and cannot be
    checked against the rule until its RAWs are here once. The page says so
    with the command, rather than leaving a fit that is better in silence."""
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    owed = {"used": False, "frames": 198, "fit_right": 161, "commonest_right": 105, "rule_right": None,
            "rule_unknown": 168, "vs": {"commonest": {"wins": 70, "losses": 14}}}
    model = {"n": 600, "numeric": {}, "vocab": {},
             "venues": {"shoots": {"v1": {"label": "portraits", "shoots": ["2026-09-05-the-gals"], "exposure": owed}}}}
    learned.submit("edit", model, source="learned: a test")
    row = next(r for r in learned.panel()["learners"] if r["id"] == "edit")
    assert row["state"] == "in_use"
    assert "right on 161 of 198" in row["needs_sentence"]
    # The command that actually copies: without --apply, pull is a dry run.
    assert "./pl archive pull 2026-09-05-the-gals --apply brings them back from iCloud; then learn again" \
        in row["needs_sentence"], row["needs_sentence"]
    assert "Until it has been checked, the rule decides there." in row["needs_sentence"]
    assert "also held back" not in row["needs_sentence"]
    # On the page: short lines with no command in them, and the shoot to bring
    # back as data, so the line carries a button rather than a terminal command.
    assert row["needs_lines"][0] == "Waiting on you:"
    assert row["needs_lines"][-1] == "Until then the rule decides there."
    assert not any("./pl" in x for x in row["needs_lines"]), row["needs_lines"]
    assert row["needs_do"] == [{"shoot": "2026-09-05-the-gals", "do": "pull"}]


def test_the_download_is_asked_for_only_where_the_fit_beats_the_constant_by_more_than_chance(tmp_path, monkeypatch):
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    lucky = {"used": False, "frames": 198, "fit_right": 110, "commonest_right": 105, "rule_right": None,
             "rule_unknown": 168, "vs": {"commonest": {"wins": 12, "losses": 7}}}
    assert learned._exposure_owed({"venues": {"shoots": {"v1": {"shoots": ["x"], "exposure": lucky}}}}) == ""
    uncounted = dict(lucky, fit_right=161, vs={})
    assert learned._exposure_owed({"venues": {"shoots": {"v1": {"shoots": ["x"], "exposure": uncounted}}}}) == ""


def test_the_download_line_does_not_promise_what_a_version_held_for_something_else_cannot_do(monkeypatch):
    """His newer starting edit is held for its white balance on 2026-09-21.
    Pulling the portraits back lets the fit be checked; it does not put
    that version in use, and the held version's own line says so - not the
    last clause of the paragraph about the download."""
    owed = {"used": False, "frames": 198, "fit_right": 161, "commonest_right": 105, "rule_right": None,
            "rule_unknown": 168, "vs": {"commonest": {"wins": 70, "losses": 14}}}
    model = {"venues": {"shoots": {"v1": {"shoots": ["2026-09-05-the-gals"], "exposure": owed}}}}
    monkeypatch.setattr(learned, "version_model", lambda learner, ts: model)
    e = {"candidate": "20260921-000000",
         "versions": {"20260921-000000": {"source": "learned: you finished 2026-09-21", "data": {}}}}
    out = learned._lines("edit", e, None, {"passed": False, "sentence": "The new version would set the "
                                           "white balance worse than leaving it alone."})
    assert out["candidate_state"] == "held", out
    assert out["candidate_sentence"].endswith("Bringing photographs back does not settle this."), out
    assert "does not settle" not in out["needs_sentence"], out["needs_sentence"]
    assert out["needs_do"] == [{"shoot": "2026-09-05-the-gals", "do": "pull"}]
