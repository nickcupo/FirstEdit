"""What the cull learns, where it is kept, and the check it has to pass first.

    .venv/bin/python -m pytest tests/test_learned.py -q

The rule these pin down is one sentence: nothing the cull has learned is used
until it has been scored against every photograph he kept, on every shoot that
carries his verdicts, and found to hide none of them. Everything else here is
the machinery that makes that sentence true - where the models live, that a
held one really is not in use, that going back works, and that a reason he gave
on a frame he then kept is not training data.

Nothing in here reads or writes ~/photos, his learned folder or iCloud: every
fixture is built under pytest's own tmp_path, and conftest.py points the
learned folder and the export index at a scratch folder for the whole run.
"""
from __future__ import annotations

import csv
import json
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import flaws  # noqa: E402
import learned  # noqa: E402
import quality as q  # noqa: E402
import taste  # noqa: E402

COLS = ["file", "rating", "reason", "group", "scene", "burst", "shot_at", "quality", "mean_luma", "focus",
        "faces", "lead_read", "lead_frac"] + q.FEATURES


def _library(tmp_path: Path, frames: list[dict], kept: list[str], style: str = "normal",
             name: str = "2026-09-16", vectors: dict[str, list[float]] | None = None,
             key_names: list[str] | None = None, finished: str | bool = "2026-09-17") -> Path:
    """A shoot the keeper check can read: a cull.csv whose quality column is
    the score the cull would have written, his keepers beside it, and the
    picture vectors the cull caches."""
    shoot = tmp_path / "shoots" / name
    (shoot / "raw").mkdir(parents=True)
    (shoot / "cull").mkdir()
    (shoot / "decisions").mkdir()
    (shoot / "shoot.json").write_text(json.dumps({"style": style, "finished": finished}))
    rows = []
    for i, f in enumerate(frames):
        r = {c: 0.0 for c in COLS}
        r.update({"file": f["file"], "rating": f.get("rating", 3), "reason": "", "group": f.get("group", i),
                  "scene": 0, "burst": f.get("burst", 0), "shot_at": f"2026:09:16 18:{i:02d}:00",
                  "sharp_rel": 1.0, "eyes_open": 0.5, "gaze": 0.5, "face_score": 0.5, "focus": 100.0})
        r.update({k: v for k, v in f.items() if k in COLS and k not in ("file", "rating", "group", "burst")})
        rows.append(r)
    alive = [r for r in rows if str(r["rating"]) != "0"]
    feats = {n: np.array([float(r[n]) for r in alive]) for n in q.FEATURES}
    for r, s in zip(alive, q.combined_score(feats, q.DEFAULT_WEIGHTS)):
        r["quality"] = round(float(s), 3)
    with (shoot / "cull" / "cull.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, COLS)
        w.writeheader()
        w.writerows(rows)
    (shoot / "decisions" / "selects.json").write_text(json.dumps(key_names if key_names is not None else kept))
    if vectors:
        np.savez(shoot / "cull" / "similar.npz", files=np.array([r["file"] for r in rows]),
                 clip=np.array([vectors[r["file"]] for r in rows], dtype=np.float16))
    return shoot


def _probe(weights: list[float], b: float) -> dict:
    return {"reasons": {"expression": {"w": weights, "b": b, "n": 24, "auc": 0.9}}, "n": 24}


@pytest.fixture()
def lib(tmp_path, monkeypatch):
    """Three frames of one group, of which he kept the first. A probe that
    names that frame pushes it under its group-mate, which is a keeper hidden."""
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    monkeypatch.setattr(learned, "ROOT", tmp_path)
    monkeypatch.setattr(flaws, "ROOT", tmp_path)
    frames = [{"file": "TSC00001.ARW", "aesthetic": 1.0, "group": 1, "burst": 1},
              {"file": "TSC00002.ARW", "aesthetic": 0.99, "group": 1, "burst": 1},
              {"file": "TSC00003.ARW", "aesthetic": 0.0, "group": 1, "burst": 1}]
    vectors = {"TSC00001.ARW": [1, 0, 0, 0], "TSC00002.ARW": [0, 1, 0, 0], "TSC00003.ARW": [0, 0, 1, 0]}
    _library(tmp_path, frames, kept=["TSC00001.ARW"], vectors=vectors)
    return tmp_path


def test_the_learned_folder_is_one_writable_folder_outside_the_repo(tmp_path, monkeypatch):
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "here"))
    assert learned.folder() == tmp_path / "here"
    monkeypatch.delenv("PIPELINE_LEARNED")
    monkeypatch.setenv("PIPELINE_SUPPORT", str(tmp_path / "support"))
    assert learned.folder() == tmp_path / "support" / "learned"
    monkeypatch.delenv("PIPELINE_SUPPORT")
    monkeypatch.setenv("HOME", str(tmp_path / "home"))     # never his: the answer looks for the folder
    assert learned.folder() == tmp_path / "home" / "Library" / "Application Support" / "First Edit" / "learned"


def test_it_refuses_to_write_inside_the_checkout_or_the_app_bundle(tmp_path, monkeypatch):
    """A learned file in the checkout is a git diff per retrain; one in the
    bundle cannot be written at all, which is how the app came to learn
    nothing for as long as it was installed."""
    monkeypatch.setenv("PIPELINE_LEARNED", str(Path(learned.HERE).parent / "learned"))
    with pytest.raises(learned.Refused):
        learned._writable()
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "FirstEdit.app" / "Contents" / "learned"))
    with pytest.raises(learned.Refused):
        learned._writable()


def test_a_candidate_that_hides_one_of_his_keepers_is_held_with_the_frame_named(lib):
    res = learned.submit("drop-reasons", _probe([20, 0, 0, 0], -10), source="a test")
    assert res["state"] == "held"
    check = res["check"]
    assert check["hidden"] == 1 and not check["passed"]
    frame = check["shoots"][0]["frames"][0]
    assert frame["stem"] == "TSC00001" and frame["new"] == "out of sight"
    assert "'face'" in frame["why"], "the reason in the word on his key, not the engine's label"
    # Held means not in use: the cull reads nothing, and the version is kept.
    assert flaws.load() == {}
    assert not learned.path("drop-reasons").exists()
    assert learned.version_model("drop-reasons", res["version"])["reasons"]


def test_a_candidate_that_moves_nothing_goes_live_and_is_what_the_cull_reads(lib):
    res = learned.submit("drop-reasons", _probe([0, 0, 0, 0], 0.0), source="a test")
    assert res["state"] == "in_use", res["sentence"]
    assert res["check"]["passed"] and res["check"]["moved_down"] == 0 and res["check"]["checked"] == 1
    assert flaws.load()["reasons"]["expression"]["b"] == 0.0
    assert learned.live_version("drop-reasons") == res["version"]


def test_going_back_restores_the_version_before_and_stopping_leaves_the_cull_with_nothing(lib):
    first = learned.submit("drop-reasons", _probe([0, 0, 0, 0], 0.0), source="a test")["version"]
    second = learned.submit("drop-reasons", _probe([0, 0, 0, 0], 0.5), source="a test")["version"]
    assert learned.live_version("drop-reasons") == second
    back = learned.back("drop-reasons")
    assert back["version"] == first and flaws.load()["reasons"]["expression"]["b"] == 0.0
    # And back again: the version before the first one is no model at all.
    learned.back("drop-reasons")
    assert flaws.load() == {}
    learned.submit("drop-reasons", _probe([0, 0, 0, 0], 0.25), source="a test")
    learned.stop("drop-reasons")
    assert flaws.load() == {}
    e = learned.manifest()["learners"]["drop-reasons"]
    assert e["stopped"] and len(e["versions"]) == 3          # nothing it learned was thrown away


def test_using_a_held_version_anyway_takes_the_version_he_was_shown(lib):
    res = learned.submit("drop-reasons", _probe([20, 0, 0, 0], -10), source="a test")
    with pytest.raises(learned.Refused):
        learned.use_anyway("drop-reasons", "20200101-000000")
    out = learned.use_anyway("drop-reasons", res["version"])
    assert out["state"] == "in_use" and flaws.load()["reasons"]["expression"]["b"] == -10
    assert learned.manifest()["learners"]["drop-reasons"]["overridden"]["version"] == res["version"]


def test_keepers_are_matched_by_stem_and_a_shoot_that_cannot_show_them_all_fails_the_check(tmp_path, monkeypatch):
    """The lounge was culled from its decodes, so its cull.csv names .jpg where
    his key names .ARW. A check that keys on the file name sees 0 of its 25
    keepers and reports the shoot as safe."""
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    monkeypatch.setattr(learned, "ROOT", tmp_path)
    frames = [{"file": "TSC00001.jpg", "aesthetic": 1.0, "group": 1, "burst": 1},
              {"file": "TSC00002.jpg", "aesthetic": 0.5, "group": 1, "burst": 1}]
    _library(tmp_path, frames, kept=[], key_names=["TSC00001.ARW"], name="2026-09-12-lounge")
    sd = learned.shoots_with_verdicts()[0]
    assert sd.keepers == 1 and len(sd.found) == 1 and not sd.why
    # And one his key names that the cull.csv does not hold at all: the shoot
    # cannot be vouched for, so no candidate may go live on it.
    (tmp_path / "shoots" / "2026-09-12-lounge" / "decisions" / "selects.json").write_text(
        json.dumps(["TSC00001.ARW", "TSC09999.ARW"]))
    sd = learned.shoots_with_verdicts()[0]
    assert "not in its cull.csv" in sd.why
    check = learned.keeper_check([sd], "drop-reasons", flaw_new=None)
    assert not check["passed"] and check["couldnt_check"][0]["shoot"] == "2026-09-12-lounge"
    # One sentence for the whole set, in his words, naming what to do: the
    # panel used to print the same reason again under every shoot.
    assert "Not checked yet" in check["sentence"] and "2026-09-12-lounge was culled before" in check["sentence"]
    assert "cull it again" in check["sentence"]
    assert "similar.npz" not in check["sentence"] and "vector" not in check["sentence"]


def test_a_shoot_whose_raws_have_been_archived_is_still_checked(lib):
    """The safety net used to shrink in silence: a delivered shoot's RAWs go to
    iCloud, the shoot stopped being re-cullable, and a green check then covered
    573 keepers instead of 773 without saying so. The check reads cull.csv and
    the vectors the cull cached, so nothing it needs leaves with the RAWs."""
    shoot = lib / "shoots" / "2026-09-16"
    for gone in ("raw", "cull/decoded", "cull/previews"):
        if (shoot / gone).exists():
            for f in (shoot / gone).iterdir():
                f.unlink()
            (shoot / gone).rmdir()
    sd = learned.shoots_with_verdicts()
    assert [s.name for s in sd] == ["2026-09-16"] and sd[0].keepers == 1 and not sd[0].why
    check = learned.keeper_check(sd, "drop-reasons", flaw_new=_probe([20, 0, 0, 0], -10))
    assert check["checked"] == 1 and check["hidden"] == 1


def test_a_shoot_with_no_cached_vectors_cannot_vouch_for_a_drop_reason_model(lib):
    (lib / "shoots" / "2026-09-16" / "cull" / "similar.npz").unlink()
    check = learned.keeper_check(learned.shoots_with_verdicts(), "drop-reasons", flaw_new=_probe([1, 0, 0, 0], 0.0))
    assert not check["passed"]
    why = check["couldnt_check"][0]["why"]
    # What it is short of and the one command that supplies it - measured
    # off the previews it already has. It used to tell him to cull the shoot
    # again, which is an evening's work and not the fix.
    assert why == "its frames have no picture vectors kept"
    assert check["couldnt_check"][0]["fix"] == "./pl learned vectors 2026-09-16"
    # Said without the command: the page puts a Measure button beside it and
    # the terminal prints the command under it. It ended in "./pl learned
    # vectors 2026-09-16 measures them", for him to type.
    assert "2026-09-16 has no picture vectors kept; measured off its previews, it can be checked" \
        in check["sentence"], check["sentence"]
    assert "./pl" not in check["sentence"]
    assert learned._check_do(check) == [{"shoot": "2026-09-16", "do": "vectors"}]
    assert "cull it again" not in check["sentence"].lower()
    assert "npz" not in why and "npz" not in check["sentence"]     # no file of ours in a sentence he reads
    # With no drop-reason model in use there is no drop-reason score to
    # replay, so a tier order is measured on what cull.csv already holds and
    # the same shoot can still vouch for that one.
    check = learned.keeper_check(learned.shoots_with_verdicts(), "tier-order")
    assert check["passed"]
    # With one in use it cannot: the file's flaw column says what the model
    # the CULL had thought - zero on every frame of the three shoots his
    # installed app culled - and a replay from it is a replay of some other
    # cull. The shoot is named rather than stood in for.
    probe = _probe([1, 0, 0, 0], 0.0)
    check = learned.keeper_check(learned.shoots_with_verdicts(), "tier-order", flaw_live=probe, flaw_new=probe)
    assert not check["passed"] and check["couldnt_check"][0]["shoot"] == "2026-09-16"
    # And the tier order's page line says the same, with the same button.
    assert "measured off its previews" in check["sentence"] and "./pl" not in check["sentence"]
    assert learned._check_do(check) == [{"shoot": "2026-09-16", "do": "vectors"}]


def test_a_kept_check_is_said_in_todays_words_and_a_row_offers_to_measure(lib):
    """A check kept by an older build carries the sentence that told him to
    type "./pl learned vectors". What the page says is worked out again from
    the check's own facts - nothing is measured again - and the row carries
    the shoot to measure, for a button."""
    (lib / "shoots" / "2026-09-16" / "cull" / "similar.npz").unlink()
    check = learned.keeper_check(learned.shoots_with_verdicts(), "drop-reasons", flaw_new=_probe([1, 0, 0, 0], 0.0))
    kept = dict(check, sentence="Not checked yet, so nothing has changed: 2026-09-16 has no picture vectors "
                                "kept; ./pl learned vectors 2026-09-16 measures them off the previews, and then "
                                "it can be checked.")
    said = learned._said(kept)
    assert said == check["sentence"] and "./pl" not in said
    # A kept check with too little in it to say again keeps its own words.
    assert learned._said({"sentence": "Checked on the 3 photos you kept."}) == "Checked on the 3 photos you kept."
    e = {"candidate": "v2", "versions": {"v2": {"source": "learned: you finished 2026-09-16"}}}
    lines = learned._lines("drop-reasons", e, None, kept)
    assert lines["candidate_state"] == "couldnt_check"
    assert "./pl" not in lines["candidate_sentence"]
    assert lines["check_do"] == [{"shoot": "2026-09-16", "do": "vectors"}]
    # A learner he stopped offers nothing to do.
    assert learned._lines("drop-reasons", dict(e, stopped=True), None, kept)["check_do"] == []


def test_a_reason_on_a_frame_he_kept_or_never_dropped_is_not_training_data(tmp_path, monkeypatch):
    """His verdict decides what a reason means. A reason left on a frame he
    then kept used to teach the probe that frames like his keeper are bad."""
    monkeypatch.setattr(flaws, "ROOT", tmp_path)
    monkeypatch.setattr(learned, "ROOT", tmp_path)
    frames = [{"file": f"TSC0000{i}.ARW", "aesthetic": 0.5, "group": i, "burst": 1} for i in range(1, 6)]
    shoot = _library(tmp_path, frames, kept=["TSC00001.ARW"])
    labels = {"TSC00001.ARW": "expression",     # he kept it: not a flaw
              "TSC00002.ARW": "",               # cleared: not a reason at all
              "TSC00003.ARW": "expression",     # dropped, with a reason: this one counts
              "TSC00004.ARW": "just no",        # taste, not a fault
              "TSC00005.ARW": "blur"}           # no verdict of his on it
    (shoot / "decisions" / "labels.json").write_text(json.dumps(labels))
    (shoot / "decisions" / "organize.json").write_text(json.dumps(
        {"photos": {"TSC00001.ARW": {"rating": 5}, "TSC00003.ARW": {"rating": 2}, "TSC00004.ARW": {"rating": 2}}}))
    rows, left_out = flaws.gather(tmp_path)
    assert [(r[2], r[3]) for r in rows if r[3]] == [("TSC00003", "expression")]
    assert left_out == {"cleared": 1, "on a frame you kept": 1, "not out by your verdict": 1,
                        "not a fault": 1, "on a shoot not finished yet": 0}
    # What he wrote is left exactly where he wrote it; the filtering is done
    # at training time so the count can be shown to him.
    assert json.loads((shoot / "decisions" / "labels.json").read_text()) == labels


def test_a_reason_seen_on_one_shoot_only_is_not_trained_on(tmp_path, monkeypatch):
    """Held out by shoot, never by frame: frames of one burst on both sides of
    the split mark a probe on near-copies of what it was taught. With every
    example on one shoot there is nothing to hold out."""
    monkeypatch.setattr(flaws, "ROOT", tmp_path)
    monkeypatch.setattr(learned, "ROOT", tmp_path)
    rng = np.random.default_rng(0)
    frames, vectors, labels, over = [], {}, {}, {}
    for i in range(1, 61):
        name = f"TSC{i:05d}.ARW"
        frames.append({"file": name, "aesthetic": 0.5, "group": i, "burst": 1})
        drop = i <= 20
        vectors[name] = list(rng.normal(size=4) + (5 if drop else 0))
        if drop:
            labels[name] = "expression"
            over[name] = {"rating": 2}
    shoot = _library(tmp_path, frames, kept=[f["file"] for f in frames[20:]], vectors=vectors)
    (shoot / "decisions" / "labels.json").write_text(json.dumps(labels))
    (shoot / "decisions" / "organize.json").write_text(json.dumps({"photos": over}))
    # He exported every frame he kept: those are what stand for "not this
    # fault" (learned.taught), and never the keepers themselves.
    (shoot / "decisions" / learned.EXPORTS_KEPT).write_text(json.dumps([f["file"] for f in frames[20:]]))
    out = flaws.train(min_examples=12, root=tmp_path)
    assert out["reasons"] == {}
    assert out["report"]["reasons"]["expression"] == {"examples": 20, "shoots": 1, "needs": 0, "state": "one shoot",
                                                      "on": ["2026-09-16"]}
    # And with the same reason on a second finished shoot, it can be checked.
    frames2 = [dict(f, file=f"TSD{i:05d}.ARW") for i, f in enumerate(frames, 1)]
    vectors2 = {f"TSD{i:05d}.ARW": vectors[f["file"]] for i, f in enumerate(frames, 1)}
    shoot2 = _library(tmp_path, frames2, kept=[f["file"] for f in frames2[20:]], vectors=vectors2, name="2026-09-19")
    (shoot2 / "decisions" / "labels.json").write_text(json.dumps({f"TSD{i:05d}.ARW": "expression" for i in range(1, 21)}))
    (shoot2 / "decisions" / "organize.json").write_text(json.dumps(
        {"photos": {f"TSD{i:05d}.ARW": {"rating": 2} for i in range(1, 21)}}))
    (shoot2 / "decisions" / learned.EXPORTS_KEPT).write_text(json.dumps([f["file"] for f in frames2[20:]]))
    out = flaws.train(min_examples=12, root=tmp_path)
    assert out["report"]["reasons"]["expression"]["state"] == "learned"
    assert out["report"]["reasons"]["expression"]["shoots"] == 2


def test_an_archived_shoot_can_still_see_what_it_exported(tmp_path, monkeypatch):
    """A delivered shoot's RAWs go to iCloud and are dropped. The question
    "was this frame exported" is still answerable, from the capture time the
    shoot's own cull.csv holds, and answering False lost a finished shoot its
    exports, its Done card and its keepers."""
    frames = [{"file": "TSC00001.ARW", "aesthetic": 0.5, "group": 1, "burst": 1}]
    shoot = _library(tmp_path, frames, kept=["TSC00001.ARW"])
    raw = shoot / "raw" / "TSC00001.ARW"
    taste._SHOT_AT.clear()
    at = {"TSC00001": taste.parse_shot_at("2026:09:17 10:00:00")}
    assert not raw.exists()
    assert taste.is_exported(raw, at)
    # An export older than the frame itself belongs to another shoot: a camera
    # reuses its numbers every ten thousand frames.
    assert not taste.is_exported(raw, {"TSC00001": taste.parse_shot_at("2026:09:15 10:00:00")})


def test_the_starting_edit_ships_neutral_and_is_seeded_into_the_learned_folder(tmp_path, monkeypatch):
    """The repo's taste.json is a seed, not his taste: it carries no venues and
    no tier order, so a fresh install starts from DxO's own rendering."""
    seed = json.loads(taste.SEED.read_text())
    assert (seed.get("venues") or {}).get("shoots") == {}
    assert not any("ranker" in json.dumps(v) for v in [seed])
    assert seed.get("n") == 0 and not seed.get("numeric")
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    taste._CACHE = None
    mod = taste.load()
    assert (tmp_path / "learned" / "edit.json").exists()
    assert mod["about"].startswith("The starting edit this ships with")
    assert taste.venue_for(tmp_path / "shoots" / "nothing", {"kelvin": 4000}) is None


def test_a_starting_edit_from_an_older_build_comes_in_with_its_tier_order_separated(tmp_path, monkeypatch):
    """The ranker used to live inside taste.json, where it changed what the
    cull showed with nothing checking it. Coming in, the two are separated: the
    edit is his and goes into use, the tier order waits for the keeper check."""
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    monkeypatch.setattr(learned, "ROOT", tmp_path)
    old = {"n": 42, "numeric": {}, "categorical": {}, "vocab": {},
           "venues": {"features": taste.VENUE_FEATS, "mu": [0] * 7, "sd": [1] * 7,
                      "shoots": {"abc123": {"label": "a finished shoot", "centre": [0] * 7, "spread": 1.0,
                                            "ranker": {"features": taste.RANK_FEATS, "mu": [0] * 17, "sd": [1] * 17,
                                                       "w": [0] * 17, "b": 0.0, "auc": 0.61, "n_kept": 154, "n": 500}}}}}
    (tmp_path / "old-taste.json").write_text(json.dumps(old))
    out = learned.import_taste(tmp_path / "old-taste.json")
    assert out[0]["state"] == "in_use"
    edit = json.loads((tmp_path / "learned" / "edit.json").read_text())
    assert "ranker" not in json.dumps(edit)
    assert learned.manifest()["learners"]["tier-order"]["candidate"]
    assert not learned.path("tier-order").exists()       # nothing unchecked is ever in use


def test_one_rule_says_which_copy_of_a_sidecar_is_his(tmp_path):
    """His copy of a frame's sidecar can sit in raw/, edit/ and cull/picks/ at
    once. Three rules for which one is his gave three answers about what he
    decided; this is the one."""
    shoot = tmp_path / "shoots" / "2026-09-16"
    for d in ("raw", "edit"):
        (shoot / d).mkdir(parents=True)

    def sidecar(where: str, when: str, bias: str) -> Path:
        p = shoot / where / "TSC00001.ARW.dop"
        p.write_text("Sources = {\n\t{\n\t\tOverrides = {\n\t\t\tModificationDate = \"%s\",\n"
                     "\t\t\tExposureBias = %s,\n\t\t},\n\t},\n}\n" % (when, bias))
        return p

    sidecar("raw", "2026-09-18T10:00:00", "-0.5")
    newer = sidecar("edit", "2026-09-19T10:00:00", "-1.5")
    taste._HANDS.clear()
    assert taste.hand_copies(shoot) == {"TSC00001.ARW": newer}
    assert taste.newest_hand(shoot / "raw", "TSC00001.ARW") == newer


def test_the_panel_says_what_is_in_use_what_is_held_and_what_it_was_checked_against(lib):
    learned.submit("drop-reasons", _probe([0, 0, 0, 0], 0.0), source="a test")
    learned.submit("tier-order", {"features": taste.VENUE_FEATS, "mu": [0] * 7, "sd": [1] * 7, "shoots": {}},
                   source="a test")
    held = learned.submit("drop-reasons", _probe([20, 0, 0, 0], -10), source="a test")
    p = learned.panel()
    rows = {r["id"]: r for r in p["learners"]}
    # What is in use is in use, whatever is waiting beside it. The page said
    # "Not in use" over a version that WAS in use because the held
    # candidate's state won; the row now says each of the two things once.
    assert rows["drop-reasons"]["state"] == "in_use"
    assert rows["drop-reasons"]["sentence"].startswith("In use since")
    assert rows["drop-reasons"]["candidate_state"] == "held"
    assert rows["drop-reasons"]["candidate_sentence"].startswith("Held back: a newer version")
    assert "stop putting forward 1 of the photos you kept" in rows["drop-reasons"]["candidate_sentence"]
    assert rows["drop-reasons"]["live"]["version"] != held["version"]
    assert rows["drop-reasons"]["candidate"]["version"] == held["version"]
    assert rows["drop-reasons"]["check"]["hidden"] == 1
    assert rows["edit"]["state"] in ("none", "in_use")
    assert p["keepers"]["photos"] == 1
    assert [f["id"] for f in p["fixed"]] == ["picture-score", "face-checks"]
# ----------------------------------------------------- through the studio

def _studio(tmp_path, monkeypatch):
    """The studio, pointed entirely at the tmp tree - including where it looks
    for his exports, which is a walk of iCloud and of every shoot's export
    folder."""
    import studio
    monkeypatch.setattr(studio, "ROOT", tmp_path)
    monkeypatch.setattr(taste, "ROOT", tmp_path)
    monkeypatch.setattr(taste, "EXPORTS", [tmp_path / "shoots/*/export/**/*_DxO.jpg",
                                           tmp_path / "shoots/*/edit/**/*_DxO.jpg"])
    monkeypatch.setattr(studio.Handler, "jobs", studio.Jobs(), raising=False)
    return studio


def test_the_panel_and_its_four_actions_answer_over_the_studio(lib, monkeypatch):
    import threading
    import urllib.error
    import urllib.request
    studio = _studio(lib, monkeypatch)
    held = learned.submit("drop-reasons", _probe([20, 0, 0, 0], -10), source="a test")
    srv = studio.Server(("127.0.0.1", 0), studio.Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    def call(path: str, body: dict | None = None) -> tuple[int, dict]:
        url = f"http://127.0.0.1:{srv.server_address[1]}{path}"
        # Keyed the way the app keys every call, or the server refuses it
        # before the route is reached.
        req = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None,
                                     headers={"content-type": "application/json", studio.KEY_HEADER: srv.key})
        try:
            return 200, json.loads(urllib.request.urlopen(req).read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    try:
        code, p = call("/api/learned")
        assert code == 200
        row = {r["id"]: r for r in p["learners"]}["drop-reasons"]
        assert row["state"] == "held" and row["candidate"]["version"] == held["version"]
        assert row["check"]["shoots"][0]["frames"][0]["stem"] == "TSC00001"
        assert p["running"] is False and p["keepers"]["photos"] == 1
        # Nothing goes live from a page load, and a version he has not been
        # shown cannot be forced.
        assert "error" in call("/api/learned/use-anyway", {"learner": "drop-reasons", "version": "nope"})[1]
        assert flaws.load() == {}
        assert call("/api/learned/use-anyway", {"learner": "drop-reasons", "version": held["version"]})[1]["state"] == "in_use"
        assert flaws.load()["reasons"]["expression"]["b"] == -10
        assert call("/api/learned/back", {"learner": "drop-reasons"})[1]["state"] == "none"
        assert flaws.load() == {}
        assert call("/api/learned/stop", {"learner": "drop-reasons"})[1]["state"] == "stopped"
        assert call("/api/learned/stop", {"learner": "nonsense"}) == (400, {"error": "There is no learner called 'nonsense'"})
    finally:
        srv.shutdown()
        srv.server_close()


def test_an_export_made_since_is_picked_up_without_a_button(tmp_path, monkeypatch):
    """"Re-read what I kept" was a button whose own refusal was printed on a
    screen that does not have it. The software already knows: the Done card and
    the home page notice an export and record it."""
    studio = _studio(tmp_path, monkeypatch)
    frames = [{"file": f"TSC0000{i}.ARW", "aesthetic": 0.5, "group": i, "burst": 1} for i in range(1, 4)]
    shoot = _library(tmp_path, frames, kept=["TSC00001.ARW"], finished=False)
    (shoot / "decisions" / "organize.json").write_text(json.dumps({"photos": {"TSC00001.ARW": {"rating": 5}}}))
    (shoot / "raw" / "TSC00002.ARW").write_bytes(b"raw")
    (shoot / "export").mkdir()
    (shoot / "export" / "TSC00002_DxO.jpg").write_bytes(b"jpg")
    taste._EXPORTED = None
    taste._SHOT_AT.clear()
    info = studio.Shoot(shoot).info()
    assert info["recorded_keepers"] == 2 and info["keepers_note"] == ""
    assert json.loads((shoot / "decisions" / "selects.json").read_text()) == ["TSC00001.ARW", "TSC00002.ARW"]
    assert info["teaches"] and info["exported"] == 1

    # And the guard that stands between an export folder that has moved and
    # his answer key still fires, where he can see it: the card carries the
    # refusal instead of the page losing 154 keepers to 1.
    key = shoot / "decisions" / "selects.json"
    key.write_text(json.dumps([f["file"] for f in frames] + ["TSC00004.ARW", "TSC00005.ARW"]))
    (shoot / "export" / "TSC00009_DxO.jpg").write_bytes(b"jpg")
    (shoot / "raw" / "TSC00009.ARW").write_bytes(b"raw")
    taste._EXPORTED = None
    info = studio.Shoot(shoot).info()
    assert "Nothing was changed" in info["keepers_note"] or info["recorded_keepers"] == 5
    assert "Re-read" not in info["keepers_note"] and "selects.json" not in info["keepers_note"]
    assert len(json.loads(key.read_text())) == 5        # his key is where he left it


# ------------------------------------------- what the starting edit learns

def test_a_shoot_with_nobody_in_it_is_not_matched_to_a_venue_it_is_not_in(tmp_path, monkeypatch):
    """A venue is recognised by seven measurements, two of them off a face. A
    shoot with no faces was compared on the other five against a spread
    measured on seven, so it came out closer than it is and borrowed a look."""
    venue = {"venues": {"features": taste.VENUE_FEATS, "mu": [0.0] * 7, "sd": [1.0] * 7,
                        "shoots": {"abc": {"label": "a finished shoot", "centre": [0.0] * 7, "spread": 2.0,
                                           "look": {}, "base": "1 - DxO Style - Natural"}}}}
    (tmp_path / "edit.json").write_text(json.dumps(venue))
    monkeypatch.setenv("PHOTO_TASTE", str(tmp_path / "edit.json"))
    taste._CACHE = None
    light = {"kelvin": 0.8, "cast_a": 0.8, "cast_b": 0.8, "frame_L": 0.8, "light_chroma": 0.8}
    with_face = taste.venue_for(tmp_path / "shoots" / "somewhere", {**light, "face_L": 0.0, "face_a": 0.0, "face_b": 0.0})
    assert with_face is not None                      # near the centre on all seven
    assert taste.venue_for(tmp_path / "shoots" / "somewhere", light) is None
    taste._CACHE = None


def test_a_colour_grading_zone_is_reported_and_never_written(tmp_path):
    """check_dop refuses a grading zone with no measured gain behind it -
    rightly, because nothing here measures what one does - so a look that
    carried one stopped the whole presets run for that shoot, sidecar by
    sidecar. It is found, counted and said out loud instead."""
    shoot = tmp_path / "shoots" / "2026-09-16"
    (shoot / "raw").mkdir(parents=True)
    (shoot / "shoot.json").write_text(json.dumps({"finished": "2026-09-17"}))
    for i in range(1, 5):
        (shoot / "raw" / f"TSC0000{i}.ARW").write_bytes(b"raw")
        (shoot / "raw" / f"TSC0000{i}.ARW.dop").write_text(
            "Sources = {\n\t{\n\t\tBase = {\n\t\t\tVibrancyIntensity = 0,\n\t\t},\n"
            "\t\tOverrides = {\n\t\t\tVibrancyIntensity = 12,\n"
            "\t\t\tColorGradingParams_Master = {\n\t\t\t\tHue = 315.18,\n\t\t\t\tSat = 4.99,\n\t\t\t\tLum = 0,\n\t\t\t},\n"
            "\t\t},\n\t},\n}\n")
    taste._HANDS.clear()
    taste._SPREAD.clear()
    taste._EXPORTED = None
    got = taste.shoot_overrides(shoot)
    assert got["VibrancyIntensity"] == 12.0                     # his hand on this shoot, written
    assert "_grading" not in got
    zone = got["_not_a_target"]["ColorGradingParams_Master"]
    assert zone["n"] == 4 and "nothing here measures" in zone["why"]
    assert taste.check_dop("\tColorGradingParams_Master = {\n\t\tHue = 315.18,\n\t\tSat = 4.99,\n\t\tLum = 0,\n\t},\n")


def test_the_cull_finds_a_tier_order_by_the_light_it_keeps_beside_it(lib, monkeypatch):
    """The ranker used to be found through the starting edit's venues, so
    turning the starting edit off would have taken the tier order with it.
    Its table carries the same geometry, and the cull asks that."""
    monkeypatch.setenv("PHOTO_TASTE", str(taste.SEED))       # nothing learned about the light
    taste._CACHE = None
    ranker = {"features": taste.RANK_FEATS, "mu": [0.0] * 17, "sd": [1.0] * 17, "w": [0.0] * 17,
              "b": 0.0, "auc": 0.62, "n_kept": 154, "n": 500}
    table = {"features": taste.VENUE_FEATS, "mu": [0.0] * 7, "sd": [1.0] * 7,
             "shoots": {"abc": {"label": "a finished shoot", "centre": [0.0] * 7, "spread": 2.0, "ranker": ranker}}}
    assert learned.submit("tier-order", table, source="a test")["state"] == "in_use"
    light = {"kelvin": 0.1, "cast_a": 0.1, "cast_b": 0.1, "frame_L": 0.1, "light_chroma": 0.1,
             "face_L": 0.1, "face_a": 0.05, "face_b": 0.05}
    assert taste.venue_for(lib / "shoots" / "new one", light) is None          # no venues learned
    got = taste.venue_for(lib / "shoots" / "new one", light, table=learned.tier_order_table())
    assert got and got[1]["ranker"]["auc"] == 0.62
    taste._CACHE = None


def test_the_bar_moves_while_the_cull_is_learning(tmp_path):
    """Learning runs through the same job runner as a cull, so it gets the
    same bar, the same log and the same Stop button. A stage name the bar has
    never heard of weighs nothing and holds it at zero for the whole job."""
    import studio
    log = tmp_path / "run.log"
    log.write_text("$ learned.py run\n@@ gathering 2 2\n@@ measuring 140 281\n")
    j = studio.Jobs()
    j.log, j.kind, j.started = log, studio.LEARN_KIND, 1.0
    st = j.status()
    assert st["stage"] == "measuring"
    assert st["label"] == "measuring the frames you finished: 140 of 281 frames"
    assert st["background"] is True                          # the machine's homework, not his work
    log.write_text("$ learned.py run\n@@ gathering 2 2\n@@ measuring 281 281\n"
                   "@@ exports 3 3\n@@ edit 1 1\n@@ reasons 1 1\n@@ bursts 1 1\n@@ checking 2 2\n")
    assert studio.Jobs.status(j)["fraction"] == 1.0


def test_the_bar_never_goes_backwards_over_a_whole_learning_run(tmp_path):
    """Every mark the run prints, in the order it prints them, read through
    studio's own arithmetic one line at a time.

    A stage name is a POSITION in the run, not a label for what the code is
    doing. status() counts every stage before the one speaking now as done,
    so a mark naming a LATER stage drives the bar past everything between -
    and the next honest mark then falls back. taste.learn_edit marked its two
    measurements "checking", which is the last stage of the whole run: the
    bar read 99%, 100%, and then 96% under "working out your starting edit",
    with the label saying "checking against the photos you kept" while the
    run was still four minutes of learning away from it."""
    import studio
    log = tmp_path / "run.log"
    marks = ["@@ gathering 0 2", "@@ gathering 2 2",
             "@@ measuring 140 281", "@@ measuring 281 281",
             "@@ exports 0 281", "@@ exports 140 281", "@@ exports 281 281",
             # taste.learn_edit's two measurements for the gate, inside the
             # stage the run is actually in.
             "@@ edit 0 3", "@@ edit 1 3", "@@ edit 2 3",
             "@@ edit 1 1", "@@ reasons 1 1", "@@ bursts 1 1",
             "@@ checking 0 2", "@@ checking 1 2", "@@ checking 2 2"]
    seen, was = [], -1.0
    for i in range(1, len(marks) + 1):
        log.write_text("$ learned.py run\n" + "\n".join(marks[:i]) + "\n")
        j = studio.Jobs()
        j.log, j.kind, j.started = log, studio.LEARN_KIND, 1.0
        st = j.status()
        seen.append((marks[i - 1], round(st["fraction"], 3), st["label"]))
        assert st["fraction"] >= was, f"the bar went backwards at {marks[i - 1]}: {seen[-3:]}"
        was = st["fraction"]
    assert seen[-1][1] == 1.0, seen[-1]
    # And the words are the stage the run is really in, throughout.
    assert [w for _, _, w in seen].count("checking against the photos you kept: 2 of 2 steps") == 1
    assert all("checking" not in w for m, _, w in seen if m.startswith("@@ edit"))


def test_a_seeded_edit_says_what_it_carries(tmp_path, monkeypatch):
    """His own learned edit travels inside his own builds, and the panel called
    it "Nothing learned yet" over 527 finished frames and four kinds of light.
    What it says is decided by what is in the file, not by where it came from."""
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    learned._FOLDER = None
    his = tmp_path / "taste.json"
    his.write_text(json.dumps({"n": 527, "venues": {"shoots": {"a": {}, "b": {}}}}))
    assert "527 finished frames" in learned._seed_words(his)
    assert "neutral" not in learned._seed_words(his)

    neutral = tmp_path / "neutral.json"
    neutral.write_text(json.dumps({"n": 0, "venues": {}}))
    assert "neutral" in learned._seed_words(neutral)

    assert learned._edit_size(json.loads(his.read_text())) == (527, 2)
    assert learned._edit_size(None) == (0, 0)


def test_a_seed_that_would_set_the_white_balance_waits_for_a_run_to_measure_it(tmp_path, monkeypatch):
    """The whole door, end to end, not just the gate function.

    PIPELINE_LEARNED_SEED is "the copy from a machine being replaced": a real
    learned starting edit, with real weights, arriving through import_taste,
    which has no frames and so attaches none of the measurements the gate
    reads. It went live on the strength of a self-report made on somebody
    else's library and started writing white balance names on his new shoots
    before anything here had checked one.

    It is now held until a learning run measures it. The shipped seed is
    untouched by this: it has learned nothing and sets no white balance, so
    there is nothing to check and it goes live as it always did."""
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    his = tmp_path / "his-taste.json"
    his.write_text(json.dumps({"n": 527, "numeric": {}, "vocab": {},
                               "venues": {"shoots": {"a": {"label": "the gym"}}},
                               "wb": {"n": 525, "w": [0.1] * 10, "b": 0.0, "mu": [0.0] * 10,
                                      "sd": [1.0] * 10, "accuracy": 0.92, "always_asshot": 0.825}}))
    monkeypatch.setenv("PIPELINE_LEARNED_SEED", str(his))

    assert learned.seed_edit() == taste.SEED, "nothing unmeasured may be the edit that gets read"
    row = next(r for r in learned.panel()["learners"] if r["id"] == "edit")
    assert row["state"] == "couldnt_check", row
    assert row["candidate"] and not row["live"]
    assert row["can_use_anyway"] is True, "it is still his to use with the frames in front of him"
    # What is in use (nothing learned) and what is waiting (this, unmeasured)
    # are two lines, and the waiting one says it is a wait, not a verdict.
    assert row["sentence"].startswith("Not in use: new shoots start from DxO"), row["sentence"]
    assert row["candidate_state"] == "couldnt_check"
    assert row["candidate_sentence"].startswith("Waiting:"), row["candidate_sentence"]
    assert "nothing here has measured it" in row["candidate_sentence"], row["candidate_sentence"]

    # The seed that ships with the code learned nothing and sets no white
    # balance, so it has nothing to be checked against and is used as before.
    for p in sorted((tmp_path / "learned").rglob("*")):
        if p.is_file():
            p.unlink()
    monkeypatch.delenv("PIPELINE_LEARNED_SEED")
    assert learned.seed_edit() == learned.path("edit")
    assert next(r for r in learned.panel()["learners"] if r["id"] == "edit")["state"] == "in_use"

def test_reading_the_exports_moves_the_bar(tmp_path):
    """The stretch that used to report nothing at all.

    On his library the run is six and a half minutes and the export reading is
    six of them: one face read off the finished JPEG of every frame he has
    ever exported. It had no stage of its own, so the last thing the bar heard
    was `@@ measuring 288 288`, and it sat at 65% with a label saying "288 of
    288" for the rest of the run. The only reasonable thing to conclude from
    that screen is that the machine has hung - which is what he concluded, and
    then he could not copy his cards either."""
    import studio
    log = tmp_path / "run.log"
    j = studio.Jobs()
    j.log, j.kind, j.started = log, studio.LEARN_KIND, 1.0

    def frac(marks: str) -> float:
        log.write_text("$ learned.py run\n" + marks)
        return studio.Jobs.status(j)["fraction"]

    measured = frac("@@ gathering 2 2\n@@ measuring 288 288\n")
    quarter = frac("@@ gathering 2 2\n@@ measuring 288 288\n@@ exports 72 288\n")
    half = frac("@@ gathering 2 2\n@@ measuring 288 288\n@@ exports 144 288\n")
    done = frac("@@ gathering 2 2\n@@ measuring 288 288\n@@ exports 288 288\n")
    assert measured < quarter < half < done, "the bar stands still through the longest stretch"
    # And it says what it is doing while it does, in his words rather than the
    # count from a stage that finished minutes ago.
    log.write_text("$ learned.py run\n@@ gathering 2 2\n@@ measuring 288 288\n@@ exports 144 288\n")
    st = studio.Jobs.status(j)
    assert st["label"] == "reading the edits you exported: 144 of 288 frames"
    # Seven eighths of the run is this stage, because that is what it took
    # when it was timed.
    assert done - measured > 0.8


def test_what_is_left_is_a_rounded_guess_or_nothing_at_all(tmp_path):
    """An estimate off a fraction has never been worth a number of seconds, and
    at 1% it is not worth anything: "about 4 hours left" on a six-minute job is
    worse than an honest silence. So there is a floor, and above it the words
    are rounded."""
    import studio
    assert studio.how_much_longer(True, 0.5, 3) is None        # too soon to say
    assert studio.how_much_longer(True, 0.01, 60) is None      # too little of it done
    assert studio.how_much_longer(False, 0.5, 60) is None      # not running
    assert studio.how_much_longer(True, 0.5, 60) == 60
    assert studio.about_how_long(None) == ""
    assert studio.about_how_long(20) == "less than a minute left"
    assert studio.about_how_long(60) == "about 1 minute left"
    assert studio.about_how_long(250) == "about 4 minutes left"
    # No "4 minutes 10 seconds" anywhere: nothing here claims that precision.
    assert "second" not in studio.about_how_long(250)


# ------------------------------------ the measurements, kept once

def _dop(bias: str) -> str:
    return ("Sources = {\n\t{\n\t\tOverrides = {\n"
            f"\t\t\tExposureBias = {bias},\n\t\t\tVibrancyIntensity = 12,\n"
            "\t\t},\n\t},\n}\n")


def _finished_shoot(tmp_path: Path, name: str, n: int, bias: str = "-0.5", exported: int | None = None) -> Path:
    """A shoot he has finished: his sidecars, the RAWs still here, a preview
    each, the cull.csv the scenes are read out of, and the frames he exported
    as Finish writes them down (learned.EXPORTS_KEPT) - every one of them
    unless `exported` says how many of the first."""
    shoot = tmp_path / "shoots" / name
    (shoot / "raw").mkdir(parents=True, exist_ok=True)
    (shoot / "cull" / "previews").mkdir(parents=True, exist_ok=True)
    (shoot / "shoot.json").write_text(json.dumps({"finished": "2026-09-17", "label": name}))
    rows = []
    for i in range(n):
        stem = f"{name[-2:]}{i:04d}"
        (shoot / "raw" / f"{stem}.ARW.dop").write_text(_dop(bias))
        (shoot / "raw" / f"{stem}.ARW").write_bytes(b"raw")
        (shoot / "cull" / "previews" / f"{stem}.jpg").write_bytes(b"jpg")
        rows.append({"file": f"{stem}.ARW", "scene": str(i % 2), "burst": str(i // 3),
                     "shot_at": f"2026:09:16 18:{i:02d}:00", "rating": "3"})
    with (shoot / "cull" / "cull.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, ["file", "scene", "burst", "shot_at", "rating"])
        w.writeheader()
        w.writerows(rows)
    out = [r["file"] for r in rows][: n if exported is None else exported]
    (shoot / "cull" / learned.EXPORTS_KEPT).write_text(json.dumps(out))
    return shoot


def _archive(shoot: Path) -> None:
    """What `./pl archive drop` leaves: the sidecars, the previews and the
    shoot's own record, and not one RAW."""
    for p in (shoot / "raw").iterdir():
        if p.suffix.lower() == ".arw":
            p.unlink()
    taste._HANDS.clear()


@pytest.fixture()
def measured(tmp_path, monkeypatch):
    """learn_edit with the reading of pixels stubbed out. What is under test
    here is which frames it reads and which it keeps, not the arithmetic on
    them, and a fixture that needed the face model could not say anything
    about a frame whose photograph has gone."""
    import faces
    import presets
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    monkeypatch.setattr(learned, "ROOT", tmp_path)
    monkeypatch.setattr(taste, "SHOOTS", tmp_path / "shoots")
    monkeypatch.setattr(taste, "EXPORTS", [])
    monkeypatch.setattr(taste, "_EXPORT_INDEX", {})
    taste._HANDS.clear()
    taste._SPREAD.clear()
    taste._EXPORTED = None
    seen: list[int] = []

    def fake_measure_frames(jobs, progress=None):
        seen.append(len(jobs))
        return {j[0]: {"m": {f: 1.0 + i for i, f in enumerate(taste.FEATS)}, "lin": {"face_Y": 0.05}}
                for j in jobs}

    class Stub:
        def detect(self, img):
            return []

    monkeypatch.setattr(presets, "measure_frames", fake_measure_frames)
    monkeypatch.setattr(faces, "FaceJudge", Stub)
    monkeypatch.setattr(taste, "export_face_L_one", lambda stem, judge: 52.0)
    monkeypatch.setattr(taste, "learn", lambda samples: {"n": len(samples), "features": taste.FEATS})
    for name, val in (("learn_wb", {}), ("learn_colour", {}), ("learn_vocab", {})):
        monkeypatch.setattr(taste, name, lambda *a, _v=val, **k: _v)
    monkeypatch.setattr(taste, "learn_venues",
                        lambda s, sh, g, **k: {"features": taste.VENUE_FEATS, "mu": [0] * 7, "sd": [1] * 7, "shoots": {}})

    def run() -> dict:
        taste._HANDS.clear()
        seen.clear()
        return taste.learn_edit(tmp_path / "shoots")

    run.measured = seen                     # how many frames each run actually read
    return run


def test_a_frame_is_measured_once_and_goes_on_teaching_after_its_raw_is_archived(measured, tmp_path):
    """His question, in one test. The starting edit used to be fitted only on
    the frames whose RAWs happened to be on the disk that day, so the first run
    after he archived 2026-09-16 learned from 283 finished frames where the
    model in use had 527 - and was rightly held for being smaller. What he
    taught does not expire when the photographs move to iCloud."""
    _finished_shoot(tmp_path, "2026-09-16", 20)
    gym = _finished_shoot(tmp_path, "2026-09-19", 20)

    first = measured()
    assert first["dataset"]["frames"] == 40 and first["dataset"]["measured_now"] == 40

    # Nothing new finished: nothing is measured, and it fits from all of it.
    again = measured()
    assert again["dataset"]["measured_now"] == 0 and again["dataset"]["frames"] == 40
    assert sum(measured.measured) == 0, "a run with nothing new must not read a frame"

    # And now the RAWs go to iCloud.
    _archive(gym)
    after = measured()
    assert after["dataset"]["frames"] == 40, "archiving a shoot must not shrink what it has learned from"
    assert after["dataset"]["measured_now"] == 0
    assert after["dataset"]["away"] == 20
    row = next(e for e in after["dataset"]["shoots"] if e["shoot"] == "2026-09-19")
    assert row["where"] == "photographs archived" and row["frames"] == 20
    assert "no longer on this Mac" in after["dataset"]["plain_metric"]
    assert "still teach" in after["dataset"]["plain_metric"]


def test_the_starting_edit_learns_from_the_edits_he_exported_and_keeps_the_rest_measured(measured, tmp_path):
    """"only train based on what i've exported. i tend to cull further during
    editing." A finished shoot's frames he edited in PhotoLab and did not
    export are measured once and kept, and do not teach; the page says how
    many, beside what did."""
    _finished_shoot(tmp_path, "2026-09-19", 30, exported=22)
    mod = measured()
    assert mod["dataset"]["frames"] == 22 and mod["dataset"]["not_exported"] == 8
    assert "8 more you edited and did not export are measured and kept, and do not teach" in mod["dataset"]["sentence"]
    table, _ = learned.measured_read("frame")
    assert len(table) == 30, "measured once and kept, all of them"
    # Exporting the rest later teaches them, without measuring them again.
    shoot = tmp_path / "shoots" / "2026-09-19"
    everything = [f"19{i:04d}.ARW" for i in range(30)]
    (shoot / "cull" / learned.EXPORTS_KEPT).write_text(json.dumps(everything))
    again = measured()
    assert again["dataset"]["frames"] == 30 and again["dataset"]["not_exported"] == 0
    assert sum(measured.measured) == 0


def test_the_starting_edit_keeps_the_frames_it_was_fitted_on_so_it_can_be_counted_again(measured, tmp_path):
    """What a later version is weighed against is this one's count made again
    by the rule of that day, frame by frame, from the names it keeps - and
    only in the model: the manifest keeps the dataset's numbers."""
    _finished_shoot(tmp_path, "2026-09-19", 30, exported=22)
    mod = measured()
    assert mod["taught_frames"] == {"2026-09-19": [f"19{i:04d}.ARW" for i in range(22)]}
    assert "taught_frames" not in learned.edit_data(mod)
    assert learned.edit_count(mod, learned.taught_now()) == {"frames": 22, "as_learned": 22, "how": "frames"}

    # He exports the other eight: the next version learns from 30, and the one
    # it is weighed against is still the 22 it was fitted on.
    shoot = tmp_path / "shoots" / "2026-09-19"
    (shoot / "cull" / learned.EXPORTS_KEPT).write_text(json.dumps([f"19{i:04d}.ARW" for i in range(30)]))
    again = measured()
    check = learned.check_edit(again, mod, measured_here=True)
    assert (check["frames_new"], check["frames_now"], check["counted_now"]) == (30, 22, "frames")
    assert check["passed"]


def test_the_starting_edit_never_marks_a_stage_the_run_has_not_reached(measured, tmp_path, monkeypatch):
    """The other end of the bar going backwards, pinned where the marks are
    printed rather than where they are added up.

    learn_edit's two gate measurements marked "checking", which is the LAST
    stage of the learning run, from the middle of the first of four. The bar
    is only as honest as the stage names, so every name this prints has to be
    at or before where the run actually is."""
    import studio
    _finished_shoot(tmp_path, "2026-09-16", 20)
    # A white balance with weights, which is what turns the gate measurements
    # on: with none there is nothing to check and nothing to mark.
    monkeypatch.setattr(taste, "learn_wb", lambda s: {"n": len(s), "w": [0.1] * 10, "b": 0.0,
                                                      "mu": [0.0] * 10, "sd": [1.0] * 10,
                                                      "accuracy": 0.9, "always_asshot": 0.8})
    seen: list[str] = []
    mod = taste.learn_edit(tmp_path / "shoots", progress=lambda st, d, t: seen.append(st))
    assert "where_used" in mod["wb"], "the gate's measurements were not made at all"
    order = list(studio.STOR_WEIGHTS["learn"])
    at = [order.index(s) for s in seen]
    assert at == sorted(at), seen
    assert seen[-1] == "edit", seen
    assert "checking" not in seen, "that stage is learned.run's, after all three fits"


def test_an_edit_he_makes_again_is_measured_again_and_nothing_else_is(measured, tmp_path):
    shoot = _finished_shoot(tmp_path, "2026-09-16", 20)
    measured()
    (shoot / "raw" / "160003.ARW.dop").write_text(_dop("-1.25"))
    mod = measured()
    assert mod["dataset"]["measured_now"] == 1 and mod["dataset"]["frames"] == 20
    assert sum(measured.measured) == 1


def test_a_sidecar_whose_photograph_has_gone_keeps_what_it_taught_and_says_so(measured, tmp_path):
    """He opens an archived shoot in PhotoLab and moves a slider. There is no
    RAW here to measure it against, so the frame keeps the measurement it has -
    and the panel says how many are in that state rather than quietly counting
    them with the rest."""
    shoot = _finished_shoot(tmp_path, "2026-09-16", 20)
    measured()
    _archive(shoot)
    (shoot / "raw" / "160003.ARW.dop").write_text(_dop("-1.25"))
    mod = measured()
    assert mod["dataset"]["frames"] == 20 and mod["dataset"]["unmeasurable_changes"] == 1
    assert "sidecar you have changed since" in mod["dataset"]["plain_metric"]


def test_a_change_to_the_measuring_code_remeasures_what_it_can_and_counts_the_rest_apart(measured, tmp_path,
                                                                                         monkeypatch):
    _finished_shoot(tmp_path, "2026-09-16", 20)
    gone = _finished_shoot(tmp_path, "2026-09-19", 20)
    measured()
    _archive(gone)
    monkeypatch.setattr(taste, "MEASURE_SCHEMA", taste.MEASURE_SCHEMA + 1)
    mod = measured()
    assert mod["dataset"]["frames"] == 40, "nothing is thrown away because the measuring changed"
    assert mod["dataset"]["measured_now"] == 20, "what can be measured again is"
    assert mod["dataset"]["older_schema"] == 20
    assert "older version of the measuring code" in mod["dataset"]["plain_metric"]


def test_a_frame_he_un_finishes_stops_teaching_and_the_file_keeps_the_record(measured, tmp_path):
    shoot = _finished_shoot(tmp_path, "2026-09-16", 21)
    measured()
    (shoot / "raw" / "160003.ARW.dop").write_text("Sources = {\n\t{\n\t\tOverrides = {\n\t\t},\n\t},\n}\n")
    mod = measured()
    assert mod["dataset"]["frames"] == 20
    rows = [json.loads(x) for x in learned.measured_file().read_text().splitlines()]
    assert any(r.get("gone") and r["key"] == "2026-09-16/160003.ARW" for r in rows) or \
        "2026-09-16/160003.ARW" not in {r["key"] for r in rows}


def test_he_can_take_one_shoot_back_out_and_nothing_does_it_for_him(measured, tmp_path):
    """Dropping a shoot's contribution is his: he deleted it, or it should
    never have taught. Nothing in a run calls this, and what comes out is kept
    where he can put it back."""
    _finished_shoot(tmp_path, "2026-09-16", 20)
    _finished_shoot(tmp_path, "2026-09-19", 20)
    measured()
    out = learned.measured_forget("2026-09-19")
    assert out["frames"] == 20 and Path(out["kept"]).exists()
    table, _ = learned.measured_read("frame")
    assert len(table) == 20 and all(r["shoot"] == "2026-09-16" for r in table.values())
    mod = measured()
    assert mod["dataset"]["frames"] == 20, "a drop the next run undoes is not a drop"
    assert sum(measured.measured) == 0, "and it is not measured all over again either"
    assert learned.dropped_shoots() == ["2026-09-19"]
    assert "teach-again" in learned.dataset_text()
    # And back in, when he says so.
    learned.teach_again("2026-09-19")
    assert measured()["dataset"]["frames"] == 40


def test_the_measurements_say_what_they_hold_and_what_they_cost(measured, tmp_path):
    _finished_shoot(tmp_path, "2026-09-16", 20)
    mod = measured()
    learned.submit("edit", mod, source="a test", data=learned.edit_data(mod))
    size = learned.measured_size()
    assert size["frames"] == 20 and size["bytes"] > 0 and size["per_frame"] > 0
    assert learned.folder() in Path(size["path"]).parents
    words = learned.dataset_text()
    assert "2026-09-16: 20 finished frames" in words
    assert "bytes a frame" in words
    assert "--forget" in words
    # And the panel row says it in the same words, so the page and the terminal
    # cannot tell him two different stories.
    p = learned.panel(tmp_path)
    row = next(r for r in p["learners"] if r["id"] == "edit")
    assert "Learned from 20 finished frames on 1 shoot" in row["learned_from"]
    assert p["measured"]["frames"] == 20


def test_the_measurements_are_never_kept_in_the_library_or_the_repo(measured, tmp_path):
    _finished_shoot(tmp_path, "2026-09-16", 20)
    measured()
    p = learned.measured_file()
    assert p.exists() and p.parent == learned.folder()
    assert tmp_path / "shoots" not in p.parents
    assert Path(__file__).resolve().parents[1] not in p.parents


def test_a_shoot_culled_before_the_cull_kept_its_vectors_can_be_measured_once_and_then_checked(lib):
    """Six of his shoots carry no picture vectors, and that is the whole reason
    a drop-reason model "couldn't be checked" and sat unused. The previews are
    still there, so the vectors can be measured off them once and kept beside
    the models - and then the check is a check, not a shrug."""
    shoot = lib / "shoots" / "2026-09-16"
    (shoot / "cull" / "similar.npz").unlink()
    check = learned.keeper_check(learned.shoots_with_verdicts(), "drop-reasons", flaw_new=_probe([1, 0, 0, 0], 0.0))
    assert not check["passed"] and check["couldnt_check"]

    learned.keep_vectors("2026-09-16", {"TSC00001": np.array([1.0, 0, 0, 0]),
                                        "TSC00002": np.array([0, 1.0, 0, 0]),
                                        "TSC00003": np.array([0, 0, 1.0, 0])})
    check = learned.keeper_check(learned.shoots_with_verdicts(), "drop-reasons", flaw_new=_probe([20, 0, 0, 0], -10))
    assert not check["couldnt_check"], "it can be scored on this shoot now"
    assert check["checked"] == 1 and check["hidden"] == 1, "and it is held for the keeper it would hide"


def test_a_picture_vector_is_measured_off_a_preview_once_and_kept(lib, monkeypatch):
    """The drop-reason learner measured 805 vectors off his previews on every
    single run. Nothing about them changes between runs, and the previews
    outlive the RAWs, so they are measured once."""
    import quality
    shoot = lib / "shoots" / "2026-09-16"
    (shoot / "cull" / "similar.npz").unlink()
    prev = shoot / "cull" / "previews"
    prev.mkdir(parents=True, exist_ok=True)
    stems = ["TSC00001", "TSC00002", "TSC00003"]
    for s in stems:
        (prev / f"{s}.jpg").write_bytes(b"jpg")
    asked: list[int] = []

    class Stub:
        def _load_clip(self):
            return True

        def aesthetic_batch(self, files):
            asked.append(len(files))
            return None, [np.eye(4)[i % 4] for i in range(len(files))]

    monkeypatch.setattr(quality, "Quality", Stub)
    rows = [("2026-09-16", shoot / "cull", s, "expression" if i else None, i == 0) for i, s in enumerate(stems)]
    E, note = flaws.vectors(rows)
    assert asked == [3] and "measured off the previews and kept" in note
    E2, note2 = flaws.vectors(rows)
    assert asked == [3], "nothing is measured a second time"
    assert "3 vectors already measured" in note2
    assert all(np.allclose(a, b) for a, b in zip(E, E2))


def test_measure_without_the_picture_model_says_so_and_ends_as_a_refusal(lib, monkeypatch, capsys):
    """With the model missing, measure_vectors returned no sentence and the
    Measure job ended on a KeyError traceback."""
    import quality
    shoot = lib / "shoots" / "2026-09-16"
    (shoot / "cull" / "similar.npz").unlink()
    prev = shoot / "cull" / "previews"
    prev.mkdir(parents=True, exist_ok=True)
    (prev / "TSC00001.jpg").write_bytes(b"jpg")

    class NoModel:
        def _load_clip(self):
            return False

    monkeypatch.setattr(quality, "Quality", NoModel)
    out = learned.measure_vectors(shoot)
    assert out["measured"] == 0 and out["refused"] is True
    assert out["sentence"].startswith("2026-09-16: nothing was measured.")
    assert "Settings ▸ Advanced" in out["sentence"] and "./pl" not in out["sentence"]
    monkeypatch.setattr(learned, "ROOT", lib)
    assert learned.main(["vectors", str(shoot)]) == 1
    assert "nothing was measured" in capsys.readouterr().out


def test_the_page_says_what_each_shoot_can_still_teach_and_what_stops_it(lib):
    """Which shoots can contribute to which learner, in one place, with the one
    thing that stops one named as something he can do about it."""
    (lib / "shoots" / "2026-09-16" / "cull" / "similar.npz").unlink()
    rows = learned.contributors(lib)
    row = next(r for r in rows if r["shoot"] == "2026-09-16")
    # Finished, with a keeper and nothing exported found or recorded: the
    # keeper does not stand in for an export, and the row says what is missing.
    assert row["teaches"] and row["tier_order"] == "nothing you exported, so nothing to learn an order from"
    assert "no picture vector" in row["drop_reasons"] and "./pl learned vectors 2026-09-16" in row["drop_reasons"]
    assert "What each shoot can still teach" in learned.dataset_text()


def test_a_folder_that_is_not_a_shoot_is_not_named_on_the_learning_page(lib):
    """The library-folder bug made an empty `shoots/shoots` under his shelf.
    The app's own list already refuses it; this page iterated every folder,
    so it stood there saying it teaches nothing yet, which reads as one of his
    shoots having gone wrong rather than as a folder nobody made on purpose.

    A shoot with its frames lying loose in it and no raw/ IS a shoot - that is
    the shape one of his has - so the test asks for both answers at once."""
    (lib / "shoots" / "shoots").mkdir()
    loose = lib / "shoots" / "loose-frames"
    loose.mkdir()
    (loose / "TSC09001.ARW").write_bytes(b"")

    named = {c["shoot"] for c in learned.contributors(lib)}
    assert "shoots" not in named
    assert "loose-frames" in named


def test_what_a_run_did_and_what_the_model_knows_are_different_sentences():
    """The dataset dict is kept with the version and read back by the learning
    page for as long as that version stands, so a sentence written in the
    run's tense stops being true the moment the run ends. It said "639
    measured this time" on the next run, which measured nothing at all.

    What the run prints is `this_run`. What the page reads back is `sentence`,
    and that one is about the store: how many frames are measured and kept."""
    table = {f"2026-09-16/TSC{i:05d}": {"shoot": "2026-09-16", "schema": taste.MEASURE_SCHEMA}
             for i in range(10)}
    d = taste.dataset(table, here={"2026-09-16"}, measured_now=4, stale=[], never=[])
    assert "4 measured this time" in d["this_run"]
    assert "this time" not in d["sentence"]
    assert "All 10 are measured and kept" in d["sentence"]
    assert d["sentence"] == f"{d['learned_from']} {d['plain_metric']}"

    # And a run that measured nothing says so, while the page says the same
    # standing thing it said before.
    again = taste.dataset(table, here={"2026-09-16"}, measured_now=0, stale=[], never=[])
    assert "Nothing new to measure" in again["this_run"]
    assert again["plain_metric"] == d["plain_metric"]


def test_a_shoot_that_is_gone_is_named_in_both_sentences():
    """The clauses that tell him what to do - frames that teach from iCloud,
    frames never measured - have to be in the one he reads on the page, not
    only in the one that scrolled past in a log."""
    table = {f"2026-09-05-the-gals/TSC{i:05d}": {"shoot": "2026-09-05-the-gals",
                                                 "schema": taste.MEASURE_SCHEMA} for i in range(3)}
    d = taste.dataset(table, here=set(), measured_now=0, stale=[],
                      never=["2026-09-05-the-gals/TSC90001"])
    for text in (d["sentence"], d["this_run"]):
        assert "no longer on this Mac" in text
        assert "never been measured" in text
        assert "2026-09-05-the-gals" in text


def test_a_shoot_is_worth_bringing_back_only_while_it_still_owes_something(lib, monkeypatch):
    """The one the panel asks him for, and the trap underneath it.

    A shoot archived before the measurements were kept has finished work
    nothing ever measured, and the page tells him to bring one back and learn
    again. He did - 198 frames, 4.6 GB - and the run said "nothing new finished
    since the last time" and measured none of them, because a photograph
    arriving changes no sidecar, no verdict and no export.

    The first fix put "are its photographs here" in the fingerprint, and that
    was worse: macOS evicts a shoot again the moment the disk gets tight, so
    the page went back to asking for a shoot that had nothing left to teach -
    4.6 GB down from iCloud to measure nothing. What matters is whether frames
    it never measured COULD be measured now, so the run writes down what it was
    owed and this reads it back."""
    shoot = lib / "shoots" / "2026-09-16"
    monkeypatch.setattr(learned, "ROOT", lib)
    (shoot / "raw" / "TSC00001.ARW").write_bytes(b"")
    learned._LOCAL_RAW.clear()

    def owing(n: int) -> None:
        with learned._locked():
            m = learned.manifest()
            m["trained_on"] = {"2026-09-16": learned._fingerprint(shoot)}
            m["owed"] = {"2026-09-16": n} if n else {}
            learned._save(m)

    import archive

    # Nothing owed: here or gone, there is nothing to go and get.
    owing(0)
    assert learned.new_to_learn_from(lib) == []
    monkeypatch.setattr(archive, "local", lambda p: False)
    learned._LOCAL_RAW.clear()
    assert learned.new_to_learn_from(lib) == [], "asked for a shoot that has nothing left to teach"

    # 198 owed and the photographs are not here: still nothing he can do.
    owing(198)
    assert learned.new_to_learn_from(lib) == []

    # 198 owed and the photographs are back: now it is worth a run.
    monkeypatch.setattr(archive, "local", lambda p: True)
    learned._LOCAL_RAW.clear()
    assert learned.new_to_learn_from(lib) == ["2026-09-16"]


def test_the_answer_is_not_taken_again_until_the_folder_moves(lib, monkeypatch):
    """panel() asks this on every poll and a shoot can hold four thousand
    files, so it is cached against the folder's own mtime. A pull writes into
    that folder and an eviction rewrites it, so either one takes it again."""
    shoot = lib / "shoots" / "2026-09-16"
    monkeypatch.setattr(learned, "ROOT", lib)
    (shoot / "raw" / "TSC00001.ARW").write_bytes(b"")
    learned._LOCAL_RAW.clear()

    calls = []
    import archive
    real = archive.local
    monkeypatch.setattr(archive, "local", lambda p: (calls.append(p), real(p))[1])

    assert learned.photographs_here(shoot) is True
    first = len(calls)
    assert first > 0
    assert learned.photographs_here(shoot) is True
    assert len(calls) == first, "asked twice without the folder moving"

    (learned._raw_folder(shoot) / "TSC99999.ARW").write_bytes(b"")
    assert learned.photographs_here(shoot) is True
    assert len(calls) > first, "the folder moved and the answer was not taken again"


# ------------------------------- the starting edit's gate: like against like
#
# Everything below is about one failure. The gate used to read the
# candidate's own reported accuracy against the one in use's and hold the
# candidate when it was 0.02 lower, and those two numbers are from two
# different exams: each measured during that model's own fit, on its own
# frames, in its own scene folds. His model in use reads 0.920 against a
# baseline - what always-AsShot alone scores - of 0.825, and the candidate
# 0.889 against 0.850. Neither headline can be read against the other in
# either direction, because the two were never asked the same questions.


def _wb(accuracy, always_asshot, **extra):
    """A white balance model as taste.learn_edit hands one over: weights, its
    own self-report, and the measurements it made on his frames. where_used
    is present and empty by default - measured, and no venue the presets step
    would consult - because the presence of those keys is how the gate tells
    a model fitted here from one that arrived from somewhere else."""
    return dict({"n": 500, "w": [0.1] * 8, "b": 0.0, "mu": [0.0] * 8, "sd": [1.0] * 8,
                 "accuracy": accuracy, "always_asshot": always_asshot, "where_used": []}, **extra)


def _edit(wb, n=800, venues=("a", "b")):
    return {"n": n, "wb": wb, "venues": {"shoots": {v: {"label": v} for v in venues}}}


def test_a_starting_edit_worse_than_doing_nothing_is_refused_however_the_one_in_use_reads():
    """The floor, and what it is really for.

    taste.learn_wb cannot hand the gate a model of this shape: it measures
    the same two numbers and returns WITHOUT weights when the accuracy does
    not beat the baseline. The refit this clause was written for - his
    2026-09-22 20:48:06, wb n=475, accuracy 0.886 against a baseline of 0.981
    - came out with no weights at all, and the gate of the day held it
    correctly for that. So this is not a bug being pinned; it is the gate
    refusing to depend on the fitter policing itself, because a candidate can
    arrive through a door that did no fitting."""
    check = learned.check_edit(_edit(_wb(0.886, 0.981)), _edit(_wb(0.920, 0.825), n=527))
    assert not check["passed"]
    assert any("89 frames in 100" in w and "right on 98" in w for w in check["why"]), check["why"]
    assert "0.886" not in check["sentence"], "a bare decimal is not a reason he can act on"
    # And the model that actually prompted it, as learn_wb really emits it:
    # no weights, so the first clause of all catches it instead.
    no_w = {"n": 475, "accuracy": 0.886, "always_asshot": 0.981,
            "note": "does not beat always-AsShot on unseen scenes; not used"}
    was = learned.check_edit(_edit(no_w), _edit(_wb(0.920, 0.825), n=527))
    assert not was["passed"]
    assert was["why"] == ["it would stop setting the white balance for you, which the one in use does"]


def test_the_gate_no_longer_holds_a_candidate_for_sitting_a_harder_exam():
    """The other half of the same mistake: the old clause held his candidate
    on the 0.031 between two headlines that were never comparable.

    Not because 0.889 over 0.850 is the better model - by lift over its own
    baseline it is the worse one, 0.039 against 0.095 - but because neither
    reading means anything until both models sit one exam. Nothing here says
    the candidate is worse, so nothing here holds it; what does the saying is
    taste.wb_against_live, below."""
    check = learned.check_edit(_edit(_wb(0.889, 0.850)), _edit(_wb(0.920, 0.825), n=527))
    assert check["passed"], check["why"]


def test_a_candidate_is_held_when_the_same_exam_says_it_is_worse():
    """The comparison that IS fair: both refitted, same frames, same scene
    folds, both held out, only the training pool differing
    (taste.wb_against_live)."""
    against = {"frames": 548, "scenes": 37, "now": 0.923, "new": 0.840, "always_asshot": 0.832,
               "now_right_new_wrong": 60, "new_right_now_wrong": 15}
    check = learned.check_edit(_edit(_wb(0.889, 0.850, against_live=against)),
                               _edit(_wb(0.920, 0.825), n=527))
    assert not check["passed"]
    assert any("548 frames that taught the one in use" in w and "84 frames in 100 against 92" in w
               for w in check["why"]), check["why"]
    # And a difference inside the tolerance on that same exam is not a reason:
    # his real candidate reads 0.922 against 0.923 there, 8 frames one way and
    # 7 the other, which is one frame of difference out of 548.
    same = dict(against, new=0.922, now_right_new_wrong=8, new_right_now_wrong=7)
    assert learned.check_edit(_edit(_wb(0.889, 0.850, against_live=same)),
                              _edit(_wb(0.920, 0.825), n=527))["passed"]


def test_a_candidate_is_held_for_a_venue_where_it_would_be_worse_than_nothing():
    """Pooled numbers hide a venue. His candidate is 0.889 against 0.850 over
    674 frames and still worse than nothing on the one venue it had just
    learned enough Fluo decisions to be consulted on."""
    where = [{"venue": "409ebd49ee42", "label": "2026-09-21", "shoots": ["2026-09-21"],
              "frames": 38, "right": 21, "asshot": 29}]
    check = learned.check_edit(_edit(_wb(0.889, 0.850, where_used=where)),
                               _edit(_wb(0.920, 0.825), n=527))
    assert not check["passed"]
    assert any("right on 21 of that shoot's 38 finished frames" in w and "right on 29" in w
               for w in check["why"]), check["why"]
    # The shoot is NAMED. Two of his four venues carry venue_label's fallback,
    # "a finished shoot", so a reason built on the label alone said which of
    # them it meant to neither of us. A reason he cannot act on is not a
    # reason, and taste.venue_words is what keeps this one actionable.
    assert '"2026-09-21"' in check["sentence"], check["sentence"]
    # The name he gave the shoot, as he wrote it: the sentence used to be run
    # through str.capitalize(), which lowercased every letter after the first.
    named = learned.check_edit(_edit(_wb(0.889, 0.850, where_used=[dict(where[0], label="Emma and Tom")])),
                               _edit(_wb(0.920, 0.825), n=527))
    assert '"Emma and Tom"' in named["sentence"], named["sentence"]
    # A venue he has shot in twice owns the frames of both, and says so.
    twice = [dict(where[0], label="2026-09-21 and 2026-11-02", shoots=["2026-09-21", "2026-11-02"])]
    both = learned.check_edit(_edit(_wb(0.889, 0.850, where_used=twice)),
                              _edit(_wb(0.920, 0.825), n=527))
    assert "of those shoots' 38 finished frames" in both["sentence"], both["sentence"]
    # A venue it gets right is not a reason to hold anything.
    good = [dict(where[0], right=33)]
    assert learned.check_edit(_edit(_wb(0.889, 0.850, where_used=good)),
                              _edit(_wb(0.920, 0.825), n=527))["passed"]


def test_a_starting_edit_that_did_no_fitting_here_is_held_rather_than_waved_through():
    """The door round the back, closed.

    Clauses 2 and 3 read fields only taste.learn_edit can attach, because
    only it has the frames; the floor cannot fire on anything learn_wb emits.
    So a model arriving any other way - import_taste, which seed_edit uses
    for PIPELINE_LEARNED_SEED ("the copy from a machine being replaced") and
    which `./pl learned import` uses - carried weights, neither field, and
    passed with no reasons at all. Taking today's candidate and stripping the
    two keys was enough to turn a held model into a live one.

    It is now held as UNCHECKED, which is a different thing from held on a
    measurement: the panel says so, and the next learning run measures it."""
    fitted = _wb(0.889, 0.850)
    imported = {k: v for k, v in fitted.items() if k not in ("where_used", "against_live")}
    live = _edit(_wb(0.920, 0.825), n=527)
    assert learned.check_edit(_edit(fitted), live)["passed"]

    check = learned.check_edit(_edit(imported), live)
    assert not check["passed"], "a model nothing has measured must not go live"
    assert check["couldnt_check"], check
    assert "nothing here has measured it against your photographs" in check["sentence"], check["sentence"]
    assert check["sentence"].endswith("the next learning run checks it."), check["sentence"]

    # Going back to a version out of his own folder is a different question:
    # it was fitted here and went through the gate of its day, and it must not
    # be refused for carrying no field that existed when it was made.
    assert learned.check_edit(_edit(imported), live, measured_here=True)["passed"]

    # A floor failure is a verdict, not an absence: it is still held, and it
    # is held on the measurement, not for want of one.
    below = learned.check_edit(_edit({k: v for k, v in _wb(0.886, 0.981).items()
                                      if k != "where_used"}), live)
    assert not below["passed"] and not below["couldnt_check"], below

    # And a model that sets no white balance at all has nothing to check.
    assert learned.check_edit(_edit({"n": 0, "note": "nothing learned yet"}), _edit({}))["passed"]


# ------------- and the two measurements the gate reads, where they are made


def _wb_shoot(tmp_path: Path, name: str, asshot: int, fluo: int,
              label: str | None = None, vid: str | None = None):
    """A finished shoot's white balance decisions, as learn_edit hands them to
    the gate: one (measurement, sidecar) pair per frame. No label unless one
    is given - most of his shoots have none, and that is the case that broke
    the sentence he reads."""
    shoot = tmp_path / "shoots" / name
    shoot.mkdir(parents=True, exist_ok=True)
    meta: dict = {"finished": "2026-09-22"}
    if label:
        meta["label"] = label
    if vid:
        meta["id"] = vid
    (shoot / "shoot.json").write_text(json.dumps(meta))
    rows = []
    for i in range(asshot + fluo):
        m = {"kelvin": 3000.0, "cast_a": 0.0, "cast_b": 0.0, "light_chroma": 0.0,
             "frame_L": 50.0, "range": 1.0, "_group": f"{name}/{i % 3}"}
        rows.append((m, {"WhiteBalanceRawPreset": "Fluo" if i < fluo else "AsShot"}))
    return shoot, rows


# A white balance that writes Fluo on everything: the model is not what is
# under test here, only which venues and frames it is asked about.
_ALWAYS_FLUO = {"w": [0.0] * 10, "b": 10.0, "mu": [0.0] * 10, "sd": [1.0] * 10}


def test_the_gate_checks_every_venue_the_presets_step_would_actually_ask():
    """One rule for which venues the model is consulted on, in presets, read
    by presets and by the gate.

    They were written out twice and stopped agreeing: the gate's copy read
    wb_counts and nothing else, so a venue carried over from an older build -
    no wb_counts at all, which is exactly what taste._carry_venues preserves
    - was consulted by the presets step and skipped by the gate. The one
    clause that exists to catch a venue the model gets wrong was blind to the
    venues nobody had counted."""
    import presets
    carried = {"label": "the lounge"}                      # older build: no counts kept
    learned_now = {"label": "2026-09-21", "wb_counts": {"AsShot": 29, "Fluo": 9}}
    left_alone = {"label": "the gym", "wb_counts": {"AsShot": 293, "ManualTemp": 1}}
    settled = {"label": "the hall", "finals": {"WhiteBalanceRawPreset": "AsShot"}}
    assert [presets.consults_wb(v) for v in (carried, learned_now, left_alone, settled)] == \
        [True, True, False, False]
    assert presets.consults_wb(None) is True               # no venue at all: the model answers


def test_a_venue_carried_from_an_older_build_is_checked_like_any_other(tmp_path):
    """The same rule, through the measurement the gate actually reads."""
    shoot, rows = _wb_shoot(tmp_path, "2026-09-21", asshot=29, fluo=9)
    vid = taste.venue_id(shoot)
    mod = {"wb": dict(_ALWAYS_FLUO), "venues": {"shoots": {vid: {"label": taste.venue_label(shoot)}}}}
    got = taste.wb_where_used(mod, rows, [shoot] * len(rows))
    assert len(got) == 1, "a venue with no counts is consulted, so it must be checked"
    assert (got[0]["frames"], got[0]["right"], got[0]["asshot"]) == (38, 9, 29)
    # And a venue the presets step leaves alone is not checked at all: a
    # failure there would be a reason to hold a model over a decision it is
    # never asked to make.
    quiet = {"label": "the gym", "wb_counts": {"AsShot": 38}}
    mod["venues"]["shoots"][vid] = quiet
    assert taste.wb_where_used(mod, rows, [shoot] * len(rows)) == []


def test_the_reason_names_the_shoot_he_would_have_to_go_and_look_at(tmp_path):
    """venue_label answers "a finished shoot" for every shoot he has not
    named, and two of his four venues carry it. A reason reading `on "a
    finished shoot" it would set the white balance worse than leaving it
    alone` names nothing he can open, and it could not even say which of the
    two it meant. A reason he cannot act on is not a reason."""
    shoot, rows = _wb_shoot(tmp_path, "2026-09-21", asshot=29, fluo=9)
    vid = taste.venue_id(shoot)
    mod = {"wb": dict(_ALWAYS_FLUO), "venues": {"shoots": {vid: {"label": taste.venue_label(shoot)}}}}
    assert taste.venue_label(shoot) == taste.UNNAMED_VENUE
    row = taste.wb_where_used(mod, rows, [shoot] * len(rows))[0]
    assert row["label"] == "2026-09-21" and row["shoots"] == ["2026-09-21"]

    # His own name for a place wins over the folder, because it is his.
    his, rows2 = _wb_shoot(tmp_path, "2026-09-05-the-gals", asshot=29, fluo=9,
                           label="portraits, two people, evening in town")
    vid2 = taste.venue_id(his)
    mod2 = {"wb": dict(_ALWAYS_FLUO), "venues": {"shoots": {vid2: {"label": taste.venue_label(his)}}}}
    assert taste.wb_where_used(mod2, rows2, [his] * len(rows2))[0]["label"] == \
        "portraits, two people, evening in town"


def _venue_samples(n: int = 5):
    """What learn_venues reads off a frame: every VENUE_FEAT, a face, and an
    export to measure the renderer's lift against."""
    rows = []
    for _ in range(n):
        m = {f: 1.0 for f in taste.VENUE_FEATS}
        m.update({"face_a": 1.0, "face_b": 1.0, "_face_Y": 0.2, "_exported": True, "_export_L": 55.0})
        rows.append((m, {"ExposureAutoMode": "Manual", "ExposureBias": 0.0,
                         "WhiteBalanceRawPreset": "AsShot"}))
    return rows


def test_a_venue_records_the_shoot_it_was_learned_from(tmp_path, monkeypatch):
    """The two steps that name a venue out loud - the presets step's "a venue
    that measures like it (X)" and the cull's "this shoot measures like a
    finished venue (X)" - have a venue entry and no frames. Deriving the
    shoot from the frames, which is what wb_where_used does, is not open to
    them, so the shoot is written down where the venue is learned.

    A bare folder name, because taste.json is committed and ships inside the
    app: dataset.shoots already carries the same names, and an absolute path
    or his home directory would be a new thing to leak."""
    sh = tmp_path / "shoots" / "2026-09-21"
    sh.mkdir(parents=True)
    (sh / "shoot.json").write_text(json.dumps({"finished": "2026-09-22"}))
    rows = _venue_samples()
    e = list(taste.learn_venues(rows, [sh] * len(rows), 1.3)["shoots"].values())[0]

    assert e["shoots"] == ["2026-09-21"], "the venue does not say what taught it"
    assert e["label"] == taste.UNNAMED_VENUE, "this is the case the name is for"
    name = e["shoots"][0]
    assert "/" not in name and str(tmp_path) not in name and str(Path.home()) not in name, \
        "a folder name, not a path: this file is committed"

    # And a venue whose frames could not be measured this time - its RAWs went
    # to iCloud when it was delivered - keeps it, because _carry_venues keeps
    # the entry as it was learned. That is exactly the venue presets consults
    # and the gate checks, so it is exactly the one that must still have a name.
    mod = {"venues": {"features": taste.VENUE_FEATS, "mu": [0.0] * 7, "sd": [1.0] * 7, "shoots": {}}}
    monkeypatch.setattr(taste, "load", lambda: {"venues": {"mu": [0.0] * 7, "sd": [1.0] * 7,
                                                           "shoots": {"abc123": e}}})
    taste._carry_venues(mod)
    kept = mod["venues"]["shoots"]["abc123"]
    assert kept["carried"] and kept["shoots"] == ["2026-09-21"]


def test_a_venue_entry_alone_is_enough_to_name_the_place(tmp_path):
    """venue_words used to need the shoot names from its caller, and only
    wb_where_used had them. The presets step and the cull have the entry and
    the id and nothing else, and both printed `a finished shoot` - the
    literal fallback, carried by two of his four venues, which names nothing
    he can open and cannot say which of the two it means."""
    assert taste.venue_words({"label": taste.UNNAMED_VENUE, "shoots": ["2026-09-21"]},
                             "abc123") == "2026-09-21"
    # His own name for a place still wins over the folder, because it is his.
    assert taste.venue_words({"label": "the lounge", "shoots": ["2026-09-21"]},
                             "abc123") == "the lounge"
    # Two shoots in one room read as a sentence, not a list.
    assert taste.venue_words({"label": taste.UNNAMED_VENUE, "shoots": ["2026-09-21", "2026-09-19"]},
                             "abc123") == "2026-09-19 and 2026-09-21"
    # The frames win where a caller has them: wb_where_used counts THIS run's
    # frames, and its row says "right on 21 of that shoot's 38", so the name
    # has to be the shoot those 38 came from.
    assert taste.venue_words({"label": taste.UNNAMED_VENUE, "shoots": ["2026-09-21"]},
                             "abc123", ["2026-09-19"]) == "2026-09-19"
    # Nothing recorded and nothing derived - a venue carried from a build
    # older than the record - still never prints the fallback words.
    bare = taste.venue_words({"label": taste.UNNAMED_VENUE}, "abc123")
    assert bare == "abc123" and bare != taste.UNNAMED_VENUE


def test_the_cull_can_name_the_venue_whose_ranker_it_is_about_to_use(tmp_path, monkeypatch):
    """The cull reads learned.tier_order_table, not the starting edit, so that
    a tier order keeps working when the starting edit is turned off. That
    table is built key by key, and a key added to a venue does not arrive in
    it on its own: the shoot has to be carried over, or the cull's own line
    is back to naming a thing he cannot open."""
    sh = tmp_path / "shoots" / "2026-09-21"
    (sh / "cull").mkdir(parents=True)
    (sh / "shoot.json").write_text(json.dumps({"finished": "2026-09-22"}))
    from library import shoot_id
    vid = shoot_id(sh)
    ranker = {"auc": 0.9, "n_kept": 30, "n": 100}
    monkeypatch.setattr(taste, "learn_ranker", lambda shoot, quality=None, kept=None: ranker)
    edit = {"venues": {"features": taste.VENUE_FEATS, "mu": [0.0] * 7, "sd": [1.0] * 7,
                       "shoots": {vid: {"label": taste.UNNAMED_VENUE, "shoots": ["2026-09-21"],
                                        "centre": [0.0] * 7, "spread": 1.0}}}}
    table, _ = learned.train_tier_order(edit, root=tmp_path)
    e = table["shoots"][vid]
    assert taste.venue_words(e, vid) == "2026-09-21", "the cull's line cannot name this venue"

    # An edit model older than the record has no shoots on its venue, and the
    # shoot being learned from here IS that venue's - vid was matched off its
    # own ids - so it names that instead of falling back to a hash.
    old = {"venues": dict(edit["venues"],
                          shoots={vid: {"label": taste.UNNAMED_VENUE, "centre": [0.0] * 7, "spread": 1.0}})}
    table2, _ = learned.train_tier_order(old, root=tmp_path)
    assert taste.venue_words(table2["shoots"][vid], vid) == "2026-09-21"


def test_the_live_pool_is_the_shoots_that_taught_it_and_not_the_rooms_it_knows(tmp_path):
    """taste.wb_against_live refits both arms on the frames that taught the
    model in use, and which frames those are was read off that model's
    VENUES. A venue is a place: frames belong to it by where they were shot,
    not by whether the model in use ever saw them.

    It is right today only because each of his venues was taught by one shoot
    and he has not shot any of them twice. The next time he does, that
    shoot's frames would count as having taught the live model, and the live
    arm would be trained on frames the live model never saw - lending it the
    candidate's own advantage, in the one clause that exists to hold a
    candidate back. Its dataset record names the shoots exactly, so that is
    read first."""
    first, rows1 = _wb_shoot(tmp_path, "2026-09-21", asshot=20, fluo=12, vid="the-hall")
    again, rows2 = _wb_shoot(tmp_path, "2026-11-02", asshot=20, fluo=12, vid="the-hall")
    assert taste.venue_id(first) == taste.venue_id(again) == "the-hall", "one room, two shoots"
    samples = rows1 + rows2
    shoots_of = [first] * len(rows1) + [again] * len(rows2)

    live = {"venues": {"shoots": {"the-hall": {"label": "the hall"}}},
            "dataset": {"shoots": [{"shoot": "2026-09-21", "frames": 32}]}}
    got = taste.wb_against_live(samples, shoots_of, live)
    assert got and got["frames"] == 32, got

    # Off the venues alone, every frame in the library counts as having taught
    # it, the two pools are the same pool, and there is no comparison left to
    # make - which is the silent half of the same mistake.
    no_record = {"venues": live["venues"]}
    assert taste.wb_against_live(samples, shoots_of, no_record) is None
    # Which is still the right fallback for a model made before the record
    # existed - his is one - where the venues are all there is to go on.
    older = {"venues": {"shoots": {"the-hall": {"label": "the hall"}}}}
    other, rows3 = _wb_shoot(tmp_path, "2026-09-19", asshot=20, fluo=12)
    assert taste.wb_against_live(samples + rows3, shoots_of + [other] * len(rows3), older)["frames"] == 64


def test_the_exposure_model_is_no_longer_a_reason_to_hold_anything():
    """It was fitted, written, reported and gated on, and no sidecar was ever
    different for it: presets.decide_exposure writes the mode, from the
    sensor. Retired rather than wired in because it loses to a constant on
    three of his four shoots. A live model from before the retirement still
    carries its weights, and that must not hold the next candidate."""
    was_gated_on = {"n": 527, "accuracy": 0.875, "always_commonest": 0.713,
                    "w_manual": [0.1] * 24, "b_manual": 1.5, "w_strong": [0.1] * 24, "b_strong": 0.2}
    check = learned.check_edit(_edit(_wb(0.889, 0.850)),
                               dict(_edit(_wb(0.920, 0.825), n=527), exposure=was_gated_on))
    assert check["passed"], check["why"]
    assert not hasattr(taste, "learn_exposure")
    assert "exposure" not in json.loads((Path(taste.__file__).parent / "taste.json").read_text())


def test_a_verdict_decided_under_older_rules_is_worked_out_again(lib, monkeypatch):
    """A check is a sentence he reads for as long as the candidate stands, and
    the rules behind it do change. Tonight the exposure model was retired and
    the white-balance comparison rewritten — and the page went on saying "it
    gets the exposure type right on 66 frames in 100", a reason this code can
    no longer reach, because the stored check was believed rather than redone.

    So a check records which rules made it, and one made under older rules is
    stale. The run reads that and fits again instead of quoting it."""
    monkeypatch.setattr(learned, "ROOT", lib)

    # A check written by this build carries the rules it was made under.
    learned._write_check("edit", "20260101-000000", {"passed": False, "why": ["because"]})
    assert (learned.version_check("edit", "20260101-000000") or {})["rules"] == learned.RULES_VERSION

    with learned._locked():
        m = learned.manifest()
        e = learned._entry(m, "edit")
        e["candidate"] = "20260101-000000"
        learned._save(m)
    assert learned.check_is_stale("edit") is False

    # One written before the rules had a number at all — every check on disk
    # before tonight — is stale.
    d = learned._history("edit")
    (d / "20260101-000000.check.json").write_text(json.dumps({"passed": False, "why": ["because"]}))
    assert learned.check_is_stale("edit") is True

    # And a learner with nothing held and nothing live has no stale verdict to
    # re-derive, rather than claiming one.
    with learned._locked():
        m = learned.manifest()
        learned._entry(m, "edit")["candidate"] = None
        learned._save(m)
    assert learned.check_is_stale("edit") is False


# ------------------------------------------ the page says three things apart

def test_a_starting_edit_in_use_is_in_use_while_a_newer_one_is_held(tmp_path, monkeypatch):
    """The page said "Not in use" over the 527-frame starting edit that
    taste.load() was reading, because the held candidate's state won. What
    is in use is said first and as in use; the held one is its own line,
    naming what it learned from and what it would do."""
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    live = {"n": 527, "numeric": {}, "vocab": {},
            "venues": {"shoots": {"a": {"label": "the gym"}, "b": {"label": "a finished shoot",
                                                                  "shoots": ["2026-09-05-the-gals"]}}}}
    assert learned.submit("edit", live, source="learned: a test")["state"] == "in_use"
    newer = {**live, "n": 838, "wb": {"w": [0.1], "accuracy": 0.9, "always_asshot": 0.8,
                                      "where_used": [{"label": "2026-09-21", "shoots": ["2026-09-21"],
                                                      "frames": 38, "right": 21, "asshot": 29}]},
             "dataset": {"frames": 838, "shoots": [{"shoot": "x"}] * 5}}
    res = learned.submit("edit", newer, source="learned: you finished 2026-09-21",
                         data=learned.edit_data(newer))
    assert res["state"] == "held"
    row = next(r for r in learned.panel()["learners"] if r["id"] == "edit")
    assert row["state"] == "in_use"
    assert row["sentence"].startswith("In use since"), row["sentence"]
    assert "Learned from 527 finished frames, in 2 kinds of light (the gym; 2026-09-05-the-gals)" in row["sentence"]
    assert row["candidate_state"] == "held"
    assert row["candidate_sentence"].startswith(
        "Held back: a newer version (learned when you finished 2026-09-21), learned from 838 finished frames on 5 shoots,")
    assert "right on 21 of that shoot's 38" in row["candidate_sentence"]
    assert not row["needs_sentence"], "a held version is not short of anything"
    # The terminal prints the same three lines in the same order.
    text = learned.text(learned.panel())
    assert text.index("In use since") < text.index("Held back:")


def test_held_for_harm_and_short_of_evidence_are_two_different_lines(tmp_path, monkeypatch):
    """Opposite situations with opposite remedies: a version that would cost
    him keepers, and a learner that has not been given enough to learn. The
    second names exactly what he would have to do."""
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    learned._record_training("drop-reasons", {
        "min": 12, "shoots": ["2026-09-16"],
        "reasons": {"blur": {"examples": 6, "shoots": 1, "needs": 6, "state": "too few", "on": ["2026-09-16"]},
                    "expression": {"examples": 24, "shoots": 1, "needs": 0, "state": "one shoot",
                                   "on": ["2026-09-16"]}}}, state="not_enough")
    row = next(r for r in learned.panel()["learners"] if r["id"] == "drop-reasons")
    assert row["state"] == "not_enough" and not row["candidate_sentence"]
    assert row["sentence"] == "Not in use: the cull ranks frames by its own built-in judgement of the picture alone."
    assert row["needs_sentence"].startswith("Not enough yet to learn your own:")
    assert "6 more frames dropped for blur (it has 6 of the 12 it needs)" in row["needs_sentence"]
    # In the words of the keys he pressed: face, not the engine's label.
    assert ("face has 24, all on 2026-09-16: at least 1 more dropped for face on another "
            "finished shoot") in row["needs_sentence"]
    assert "expression" not in row["needs_sentence"]
    # Nothing in either line is a bare decimal or a file of ours.
    for said in (row["sentence"], row["needs_sentence"]):
        assert ".json" not in said and "0." not in said


def test_a_held_version_and_a_learner_short_of_evidence_can_both_be_true(lib):
    """His drop reasons today: the version that came with the app is held
    for hiding keepers, AND his own labels are not yet enough to learn a new
    one. Both are said, each once."""
    learned.submit("drop-reasons", _probe([20, 0, 0, 0], -10), source="the model from before (models/flaws.json)")
    learned._record_training("drop-reasons", {"min": 12, "reasons": {
        "blur": {"examples": 6, "shoots": 1, "needs": 6, "state": "too few", "on": ["2026-09-16"]}}})
    row = next(r for r in learned.panel()["learners"] if r["id"] == "drop-reasons")
    assert row["state"] == "held"
    assert row["candidate_sentence"].startswith(
        "Held back: the version that came with the app (from before it kept its own record) is not used")
    assert "It would stop putting forward 1 of the photos you kept" in row["candidate_sentence"]
    assert "models/flaws.json" not in row["candidate_sentence"]
    assert "6 more frames dropped for blur" in row["needs_sentence"]


def test_the_tier_order_says_which_shoots_cannot_teach_it_and_why(tmp_path, monkeypatch):
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    learned._record_training("tier-order", {"shoots": {
        "2026-09-05-the-gals": {"state": "too few of your keepers to learn from", "keepers": 12},
        "2026-09-19": {"state": "no light measured for it yet"}}}, state="not_enough")
    row = next(r for r in learned.panel()["learners"] if r["id"] == "tier-order")
    assert "2026-09-05-the-gals has 12 of your keepers, 18 short of the 30 it needs" in row["needs_sentence"]
    # Said as something he can do, not as what the engine lacks.
    assert ("2026-09-19 has no frames you finished in PhotoLab that the starting edit has measured"
            in row["needs_sentence"])
    assert "finish some of its keepers and learn again" in row["needs_sentence"]
    assert "no light measured" not in row["needs_sentence"]


def test_the_tier_order_learns_the_picture_score_the_check_replays_not_the_one_in_the_file(tmp_path, monkeypatch):
    """Three of his shoots were culled by a build with no drop-reason model,
    so cull.csv's flaw column is zero on every frame of them; three by one
    that had one. The ranker reads `quality`, which carries that column, and
    is then served the score worked out under the model in use NOW (the
    check's _scores, and the next cull). So it learns that one too."""
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    monkeypatch.setattr(learned, "ROOT", tmp_path)
    frames = [{"file": f"TSC{i:05d}.ARW", "aesthetic": float(i % 5), "group": i, "burst": i // 4,
               "flaw": 0.9 if i % 2 else 0.0} for i in range(40)]
    shoot = _library(tmp_path, frames, kept=[f["file"] for f in frames[:20]])
    written = {r["file"][:-4]: float(r["quality"]) for r in csv.DictReader((shoot / "cull" / "cull.csv").open())}
    replayed = learned._replayed_quality(shoot)
    # Nothing is in use, so the drop-reason score the cull would work out
    # today is zero - and the file's column, written under a model, is not.
    assert replayed is not None and set(replayed) == set(written)
    assert any(abs(replayed[s] - written[s]) > 0.05 for s in written)
    seen = {}

    def ranker(sh, quality=None, kept=None):
        seen["quality"] = quality
        return None
    monkeypatch.setattr(taste, "learn_ranker", ranker)
    edit = {"venues": {"features": taste.VENUE_FEATS, "mu": [0] * 7, "sd": [1] * 7,
                       "shoots": {taste.venue_id(shoot): {"label": "x", "centre": [0] * 7, "spread": 1}}}}
    learned.train_tier_order(edit, root=tmp_path)
    assert seen["quality"] == replayed


def test_the_tier_order_takes_the_light_of_the_newest_starting_edit(tmp_path, monkeypatch):
    """A shoot the starting edit in use has never seen could not teach the
    tier order at all while the newer starting edit waited on its white
    balance - one learner's verdict starving another. The geometry comes
    from the newest fit; the tier order still passes its own check."""
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    live = {"n": 100, "numeric": {}, "vocab": {}, "venues": {"shoots": {"a": {"label": "old"}}}}
    learned.submit("edit", live, source="learned: a test")
    newer = {**live, "n": 200, "venues": {"shoots": {"a": {"label": "old"}, "b": {"label": "new"}}},
             "wb": {"w": [0.1], "accuracy": 0.5, "always_asshot": 0.9}}
    assert learned.submit("edit", newer, source="learned: a test")["state"] == "held"
    assert set(learned._newest_light()["venues"]["shoots"]) == {"a", "b"}
    learned.stop("edit")
    assert learned._newest_light() is None


def test_a_version_learned_on_a_run_he_asked_for_is_named_in_words_not_by_the_command():
    """The run from the terminal records "./pl learned run" as its reason,
    and the page printed "learned when ./pl learned run"."""
    assert learned._version_words("learned: ./pl learned run", False) == "a version (learned when you asked it to learn)"
    assert learned._version_words("learned: asked for", True) == "a newer version (learned when you asked it to learn)"
    assert learned._version_words("learned: you finished 2026-09-13-dog", True) == \
        "a newer version (learned when you finished 2026-09-13-dog)"


def test_what_a_learner_is_short_of_is_a_fact_to_a_line_with_the_shoots_to_act_on(tmp_path, monkeypatch):
    """The page drew the needs as one sentence chained with semicolons, four
    to seven lines of it, and a line asking him to finish a shoot named it
    with nothing to press. The same facts now come a fact to a line, and the
    shoots he could act on come as data the page puts a button beside."""
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    learned._record_training("drop-reasons", {
        "min": 12, "shoots": ["2026-09-16"],
        "reasons": {"blur": {"examples": 6, "shoots": 1, "needs": 6, "state": "too few", "on": ["2026-09-16"]},
                    "composition": {"examples": 12, "shoots": 1, "needs": 0, "state": "one shoot",
                                    "on": ["2026-09-16"]}}}, state="not_enough")
    learned._record_training("tier-order", {"shoots": {
        "2026-09-05-the-gals": {"state": "too few of your keepers to learn from", "keepers": 12},
        "2026-09-13-dog": {"state": "no light measured for it yet"}}}, state="not_enough")
    rows = {r["id"]: r for r in learned.panel()["learners"]}
    drops = rows["drop-reasons"]
    assert drops["needs_lines"] == ["Not enough yet to learn your own:",
                                    "Blur: 6 more drops (6 of the 12 it needs).",
                                    "Framing: 1 more drop on another finished shoot (12 so far, all on 2026-09-16)."]
    assert drops["needs_do"] == []
    order = rows["tier-order"]
    assert order["needs_lines"][0] == "Not enough yet:"
    assert "2026-09-05-the-gals: 12 of your keepers, 18 short of the 30 it needs." in order["needs_lines"]
    assert "2026-09-13-dog: finish some of its keepers in PhotoLab, then learn again." in order["needs_lines"]
    assert order["needs_do"] == [{"shoot": "2026-09-13-dog", "do": "finish"}]
    for row in rows.values():
        for line in row["needs_lines"]:
            assert ";" not in line and "./pl" not in line, line
            assert len(line) <= 110, line


def test_a_learner_with_nothing_learned_beside_a_held_one_still_says_what_it_needs(tmp_path, monkeypatch):
    """"Not learned from:" replaces "Not enough yet:" only over a list; a
    one-line need is kept whole rather than cut to its heading."""
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    L = learned._lines("tier-order", {"candidate": None, "training": {"shoots": {}}, "state": "not_enough"},
                       None, None)
    assert L["needs_lines"] == [L["needs_sentence"]] and L["needs_lines"][0].startswith("Not enough yet")


def test_an_unreadable_record_is_said_as_a_flag_with_the_file_beside_it_not_a_home_path(lib):
    """The page read "no learners" as "unreadable", and the panel still builds
    three blank rows, so a broken record showed as "Nothing learned yet" with
    Learn Now under it. It is a flag now, and the sentence the page shows
    starts with a capital and carries no path: the file is sent beside it."""
    record = learned.folder() / "manifest.json"
    record.parent.mkdir(parents=True, exist_ok=True)
    record.write_text("{not json")
    p = learned.panel(lib)
    assert p["unreadable"] is True
    assert p["record"] == str(record)
    assert p["error"] == learned.UNREADABLE and p["error"][0].isupper()
    assert str(lib) not in p["error"] and "manifest.json" not in p["error"]
    assert p["unreadable_why"]
    # The terminal still gets the whole of it, and nothing was rewritten.
    with pytest.raises(learned.Refused) as e:
        learned.manifest()
    assert str(record) in str(e.value)
    assert record.read_text() == "{not json"


def test_a_readable_record_is_not_flagged(lib):
    p = learned.panel(lib)
    assert "unreadable" not in p and p["error"] == ""
