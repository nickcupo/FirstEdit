"""Finish teaches the cull from the frames he exported, and the keeper check
still counts every frame he kept.

    .venv/bin/python -m pytest tests/test_learns_from_exports.py -q

His answer, 2026-09-23, to whether Finish should teach from the 368 frames he
kept on 2026-09-19 or the 356 he exported: "only train based on what i've
exported. i tend to cull further during editing." So each learner takes its
examples of his from the exports (learned.taught), and nothing about the answer
key or the check that measures a candidate against it moves: a keeper he did
not export is still one no model may hide.

Nothing in here reads or writes ~/photos, his learned folder or iCloud: every
fixture is under pytest's own tmp_path.
"""
from __future__ import annotations

import json
import sys
from datetime import datetime
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import flaws  # noqa: E402
import learned  # noqa: E402
import taste  # noqa: E402
from test_learned import _library, _probe  # noqa: E402

# One group of three: he kept the first two in Choose Keepers and exported only
# the second. The first is the frame he threw out in PhotoLab.
FRAMES = [{"file": "TSC00001.ARW", "aesthetic": 1.0, "group": 1, "burst": 1},
          {"file": "TSC00002.ARW", "aesthetic": 0.99, "group": 1, "burst": 1},
          {"file": "TSC00003.ARW", "aesthetic": 0.0, "group": 1, "burst": 1}]
VECTORS = {"TSC00001.ARW": [1, 0, 0, 0], "TSC00002.ARW": [0, 1, 0, 0], "TSC00003.ARW": [0, 0, 1, 0]}


@pytest.fixture()
def night(tmp_path, monkeypatch):
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    monkeypatch.setattr(learned, "ROOT", tmp_path)
    monkeypatch.setattr(flaws, "ROOT", tmp_path)
    monkeypatch.setattr(taste, "EXPORTS", [])
    monkeypatch.setattr(taste, "_EXPORTED", None)
    learned._EXPORTED.clear()
    shoot = _library(tmp_path, FRAMES, kept=["TSC00001.ARW", "TSC00002.ARW"], vectors=VECTORS)
    return shoot


def _exported(shoot: Path, *files: str) -> None:
    """The frames he exported, as Finish writes them down."""
    (shoot / "decisions" / learned.EXPORTS_KEPT).write_text(json.dumps(list(files)))


def test_a_finished_shoot_teaches_the_frames_he_exported_not_every_one_he_kept(night):
    _exported(night, "TSC00002.ARW")
    assert learned.taught(night) == ({"TSC00002"}, "exported")
    # What he kept is still his answer key, all of it.
    assert learned.recorded_keepers(night) == {"TSC00001", "TSC00002"}


def test_the_keeper_check_still_counts_the_keeper_he_did_not_export(night):
    """The proof that it is exactly as strict: the check reads the answer key
    and nothing else, so it is the same check, frame for frame, with the
    exports written down or not - and the keeper he threw out in PhotoLab is
    still one a candidate is held for hiding."""
    before = learned.keeper_check(learned.shoots_with_verdicts(), "drop-reasons",
                                  flaw_new=_probe([20, 0, 0, 0], -10))
    _exported(night, "TSC00002.ARW")
    sd = learned.shoots_with_verdicts()
    assert [s.keepers for s in sd] == [2] and [len(s.found) for s in sd] == [2]
    after = learned.keeper_check(sd, "drop-reasons", flaw_new=_probe([20, 0, 0, 0], -10))
    assert after == before
    assert not after["passed"] and after["hidden"] == 1
    assert after["shoots"][0]["frames"][0]["stem"] == "TSC00001", "the kept, unexported frame is still protected"

    res = learned.submit("drop-reasons", _probe([20, 0, 0, 0], -10), source="a test")
    assert res["state"] == "held"


def test_the_drop_reasons_learn_what_is_not_a_fault_from_the_exports(night):
    """The frames that stand for "not this fault" are the ones he exported. A
    reason on a keeper of his is still never an example of the fault."""
    _exported(night, "TSC00002.ARW")
    (night / "decisions" / "labels.json").write_text(json.dumps({"TSC00001.ARW": "expression",
                                                                  "TSC00003.ARW": "expression"}))
    (night / "decisions" / "organize.json").write_text(json.dumps({"photos": {"TSC00003.ARW": {"rating": 2}}}))
    rows, left_out = flaws.gather(learned.ROOT)
    assert sorted((r[2], r[3], r[4]) for r in rows) == [("TSC00002", None, True), ("TSC00003", "expression", False)]
    assert left_out["on a frame you kept"] == 1


def test_the_tier_order_learns_the_frames_of_a_burst_he_exported(night, monkeypatch):
    _exported(night, "TSC00002.ARW")
    seen = {}

    def ranker(shoot, quality=None, kept=None):
        seen["kept"] = kept
        return None
    monkeypatch.setattr(taste, "learn_ranker", ranker)
    vid = taste.venue_id(night)
    edit = {"venues": {"features": taste.VENUE_FEATS, "mu": [0] * 7, "sd": [1] * 7,
                       "shoots": {vid: {"label": "x", "centre": [0] * 7, "spread": 1}}}}
    _table, report = learned.train_tier_order(edit, root=learned.ROOT)
    assert seen["kept"] == {"TSC00002"}
    assert report["shoots"][night.name]["from"] == "exported"


def test_the_ranker_is_fitted_on_the_frames_it_is_given(night, tmp_path):
    """learn_ranker counts the frames it is handed as his, and the answer key
    only when handed nothing, as it always read."""
    shoot = tmp_path / "shoots" / "2026-09-19"
    (shoot / "cull").mkdir(parents=True)
    rows = ["file,rating,burst,shot_at,quality,sharp_rel,eyes_open,face_score"]
    for b in range(40):
        for i in range(4):
            rows.append(f"TSC{b:02d}{i}.ARW,3,{b},2026:09:19 20:{b:02d}:0{i},{0.5 + i / 10},1,0.5,0.5")
    (shoot / "cull" / "cull.csv").write_text("\n".join(rows) + "\n")
    kept = [f"TSC{b:02d}3.ARW" for b in range(40)] + [f"TSC{b:02d}2.ARW" for b in range(40)]
    (shoot / "cull" / "selects.json").write_text(json.dumps(kept))
    every = taste.learn_ranker(shoot)
    exported = taste.learn_ranker(shoot, kept={f"TSC{b:02d}3" for b in range(40)})
    assert every["n_kept"] == 80 and exported["n_kept"] == 40
    assert every["n"] == exported["n"] == 160


# When the camera took the fixture's frames (test_learned._library): the
# afternoon of 2026-09-16. An export has to be newer than that to be this
# frame's.
AFTER = int(datetime(2026, 9, 17, 14, 37).timestamp())
BEFORE = int(datetime(2026, 9, 1, 12, 0).timestamp())


def _measured(shoot: Path, stem: str, exported: bool = False, export_at: int | None = None) -> dict:
    """One finished frame as the learning store keeps it: measured once, with
    whether it read as exported then and the export's own size and date."""
    return {"key": f"{shoot.name}/{stem}.ARW", "kind": "frame", "shoot": shoot.name, "frame": f"{stem}.ARW",
            "stem": stem, "schema": 1, "m": {}, "settings": {}, "exported": exported,
            "export": f"3293058:{export_at}" if export_at else ""}


def test_a_finished_shoot_whose_exports_are_gone_teaches_what_the_store_recorded(night):
    """2026-09-16: finished before exports were written down, its exports not
    found today - its RAWs came back from iCloud newer than every export, so
    the store measured each one as not exported, and kept the export's date.
    It teaches the frames the store recorded an export of, and never its
    keepers: with TSC00001 kept and edited and not exported, it is not his."""
    assert learned.taught(night) == (set(), ""), "no keepers stand in for the exports"
    learned.measured_add([_measured(night, "TSC00001"), _measured(night, "TSC00002", export_at=AFTER)])
    assert learned.taught(night) == ({"TSC00002"}, "exported")
    assert learned.stored_exports(night) == {"TSC00002"}
    # The answer key is still every frame he kept.
    assert learned.recorded_keepers(night) == {"TSC00001", "TSC00002"}


def test_an_export_older_than_the_frame_is_not_the_frames(night):
    """A camera reuses its numbers every ten thousand frames: an export dated
    before this frame was taken is of another frame with the same name."""
    learned.measured_add([_measured(night, "TSC00002", export_at=BEFORE)])
    assert learned.taught(night) == (set(), "")
    learned.measured_add([_measured(night, "TSC00002", exported=True)])
    assert learned.taught(night) == ({"TSC00002"}, "exported")


def test_a_raw_brought_back_after_its_export_does_not_hide_the_export(night):
    """The frame's date is the earlier of the camera's and the RAW's: a RAW
    brought back from iCloud today is dated today, and the export of it made
    the day after the shoot is still its export."""
    import os
    raw = night / "raw" / "TSC00002.ARW"
    raw.write_bytes(b"raw")
    today = int(datetime(2026, 9, 22, 20, 35).timestamp())
    os.utime(raw, (today, today))
    learned.measured_add([_measured(night, "TSC00002", export_at=AFTER)])
    assert learned.taught(night) == ({"TSC00002"}, "exported")


def test_the_skin_readings_are_a_record_of_the_exports_too(night):
    """A shoot none of whose frames carries an edit of his in a sidecar has no
    frame rows, only the skin readings of its exports, one per export file:
    those are its record. An export read before the frame was taken is of
    another frame."""
    def skin(stem: str, at: int) -> dict:
        return {"key": f"skin//exports/09:13:2026/{stem}_DxO.jpg", "kind": "skin", "schema": 1,
                "mark": f"16386594:{at}", "neutral": None, "skin": []}
    learned.measured_add([skin("TSC00001", AFTER), skin("TSC00003", BEFORE), skin("TSC09999", AFTER)])
    assert learned.taught(night) == ({"TSC00001"}, "exported")


def _no_capture_times(shoot: Path, suffix: str = ".ARW") -> None:
    """Take the capture times out of a shoot's cull.csv, and name its frames
    with `suffix`, as 2026-09-12-lounge's names the camera JPEGs the cull
    decoded (TSC04015.jpg) and carries no capture time."""
    import csv
    cc = shoot / "cull" / "cull.csv"
    with cc.open() as fh:
        rows = list(csv.DictReader(fh))
    for r in rows:
        r["shot_at"] = ""
        r["file"] = Path(r["file"]).stem + suffix
    with cc.open("w", newline="") as fh:
        w = csv.DictWriter(fh, list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    taste._SHOT_AT.clear()


def test_with_no_capture_time_the_shoots_own_day_holds_an_export_to_the_frame(night):
    """2026-09-12-lounge: no capture times, and most of its RAWs gone. The
    shoot's own day is when its frames existed by, so its exports made the
    night after count, and one from before that day is another frame's."""
    _no_capture_times(night, ".jpg")
    learned.measured_add([_measured(night, "TSC00002", export_at=AFTER),
                          _measured(night, "TSC00003", export_at=BEFORE)])
    assert learned.taught(night) == ({"TSC00002"}, "exported")


def test_with_no_capture_time_and_no_day_the_raw_found_by_number_holds_it(tmp_path, monkeypatch):
    """A shoot whose folder carries no date: the RAW's own date, found by its
    number although cull.csv names the camera JPEG, holds an export to the
    frame; with neither known, no export is taken as the frame's."""
    import os
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    monkeypatch.setattr(learned, "ROOT", tmp_path)
    monkeypatch.setattr(taste, "EXPORTS", [])
    monkeypatch.setattr(taste, "_EXPORTED", None)
    learned._EXPORTED.clear()
    shoot = _library(tmp_path, FRAMES, kept=["TSC00001.ARW", "TSC00002.ARW"], name="lounge")
    _no_capture_times(shoot, ".jpg")
    learned.measured_add([_measured(shoot, "TSC00002", export_at=AFTER)])
    assert learned.taught(shoot) == (set(), "")
    raw = shoot / "raw" / "TSC00002.ARW"
    raw.write_bytes(b"raw")
    shot = int(datetime(2026, 9, 16, 18, 1).timestamp())
    os.utime(raw, (shot, shot))
    assert learned.taught(shoot) == ({"TSC00002"}, "exported")


def test_an_export_on_disk_is_found_by_number_whatever_cull_csv_calls_the_frame(night, monkeypatch):
    """The lounge's TSC04073 and TSC04127 sit in its own export/ folder, its
    cull.csv names TSC04073.jpg and their RAWs are gone: found now all the
    same, by number, against the shoot's day."""
    import os
    _no_capture_times(night, ".jpg")
    out = night / "export"
    out.mkdir()
    f = out / "TSC00002_DxO.jpg"
    f.write_bytes(b"jpg")
    os.utime(f, (AFTER, AFTER))
    monkeypatch.setattr(taste, "EXPORTS", [night.parent / "*" / "export" / "**" / "*_DxO.jpg"])
    assert learned.exported_frames(night) == {"TSC00002"}
    assert learned.taught(night) == ({"TSC00002"}, "exported")


def test_found_written_down_and_recorded_all_teach_at_once(night):
    """One export found now, or written down at Finish, does not throw away
    what the store recorded: the record only grows, and an export that has
    gone out of reach is still one he delivered. The store is asked only on a
    finished shoot: a shoot still being culled has verdicts he has not
    finished making."""
    learned.measured_add([_measured(night, "TSC00001", export_at=AFTER)])
    _exported(night, "TSC00002.ARW")
    assert learned.taught(night) == ({"TSC00001", "TSC00002"}, "exported")
    (night / "decisions" / learned.EXPORTS_KEPT).unlink()
    assert learned.taught(night) == ({"TSC00001"}, "exported")
    (night / "shoot.json").write_text(json.dumps({"finished": False}))
    assert learned.taught(night) == (set(), "")


def test_one_export_found_today_does_not_hide_the_ones_the_store_recorded(night, tmp_path, monkeypatch):
    """The store records two exports of 2026-09-16; one of them turns up again
    today, newer than its RAW. Both teach - not just the one found."""
    import os
    learned.measured_add([_measured(night, "TSC00001", export_at=AFTER),
                          _measured(night, "TSC00002", export_at=AFTER)])
    icloud = tmp_path / "icloud" / "edited"
    icloud.mkdir(parents=True)
    f = icloud / "TSC00002_DxO.jpg"
    f.write_bytes(b"jpg")
    now = int(datetime(2026, 9, 24, 1, 0).timestamp())
    os.utime(f, (now, now))
    monkeypatch.setattr(taste, "EXPORTS", [tmp_path / "icloud" / "*" / "*_DxO.jpg"])
    assert learned.exported_frames(night) == {"TSC00002"}
    assert learned.taught(night) == ({"TSC00001", "TSC00002"}, "exported")


def _later_shoot(tmp_path: Path, stem: str, taken: str) -> Path:
    """A later shoot whose camera had come round to the same number."""
    later = _library(tmp_path, [{"file": f"{stem}.ARW", "aesthetic": 0.5, "group": 1, "burst": 1}],
                     kept=[f"{stem}.ARW"], name="2026-11-20")
    cc = later / "cull" / "cull.csv"
    cc.write_text(cc.read_text().replace("2026:09:16 18:00:00", taken))
    taste._HOLDERS.clear()
    return later


def test_an_export_made_after_the_camera_came_round_to_the_number_again_is_not_the_frames(night, tmp_path):
    """The camera reuses its numbers - he shoots about 1,500 a night - so an
    export of TSC00002 made after a later shoot's TSC00002 was taken is that
    frame's. Held from above as well as below, in the store and on disk."""
    late = int(datetime(2026, 11, 21, 10, 0).timestamp())
    learned.measured_add([_measured(night, "TSC00001", export_at=late)])
    assert learned.taught(night) == ({"TSC00001"}, "exported"), "no later frame with its number: still its own"
    later = _later_shoot(tmp_path, "TSC00001", "2026:11:20 19:00:00")
    assert learned.taught(night) == (set(), "")
    # One made in its own window still counts, whatever came after it.
    learned.measured_add([{"key": "skin//icloud/edited/TSC00001_DxO.jpg", "kind": "skin", "schema": 1,
                           "mark": f"16386594:{AFTER}", "neutral": None, "skin": []}])
    assert learned.taught(night) == ({"TSC00001"}, "exported")
    # And on disk: the newest export of the number is the later frame's, and
    # the older one is still this frame's.
    raw = night / "raw" / "TSC00001.ARW"
    at = taste.Exports({"TSC00001": [float(late)]})
    assert not taste.is_exported(raw, at)
    assert taste.is_exported(raw, taste.Exports({"TSC00001": [float(AFTER), float(late)]}))
    assert taste.is_exported(later / "raw" / "TSC00001.ARW", at), "and it is the later frame's"


def test_an_export_in_another_shoots_folder_is_that_shoots(night):
    """A skin reading of an export inside another shoot's export/ is that
    shoot's frame, whatever its number."""
    def skin(path: str) -> dict:
        return {"key": f"skin/{path}", "kind": "skin", "schema": 1, "mark": f"16386594:{AFTER}",
                "neutral": None, "skin": []}
    learned.measured_add([skin("/lib/shoots/2026-09-19/export/TSC00001_DxO.jpg"),
                          skin(f"/lib/shoots/{night.name}/export/TSC00002_DxO.jpg")])
    assert learned.taught(night) == ({"TSC00002"}, "exported")


def test_a_raw_brought_back_after_its_export_reads_as_exported_again(night):
    """2026-09-16's RAWs came back from iCloud on 2026-09-22, dated that day,
    after every export of them: the capture time in its cull.csv is when the
    frame existed, so an export made the day after the shoot is its own."""
    import os
    raw = night / "raw" / "TSC00002.ARW"
    raw.write_bytes(b"raw")
    today = int(datetime(2026, 9, 22, 20, 35).timestamp())
    os.utime(raw, (today, today))
    assert taste.is_exported(raw, {"TSC00002": float(AFTER)})
    assert not taste.is_exported(raw, {"TSC00002": float(BEFORE)})


def test_a_shoot_finished_with_none_found_teaches_what_the_store_recorded_since(night):
    """Finish wrote down an empty list - none of its exports in reach - and the
    store measured an export of it afterwards: that export is his."""
    _exported(night)
    assert learned.taught(night) == (set(), "")
    learned.measured_add([_measured(night, "TSC00002", export_at=AFTER)])
    assert learned.taught(night) == ({"TSC00002"}, "exported")


def test_the_starting_edit_teaches_the_stored_exports_of_a_shoot_here_and_the_flag_of_one_gone(night):
    """teaching_rows: a shoot on this Mac is asked, and answers from the store
    when its exports are not found; a shoot no longer here has no capture time
    to hold an export's date to, so only a row measured as exported teaches."""
    learned.measured_add([_measured(night, "TSC00001"), _measured(night, "TSC00002", export_at=AFTER),
                          {**_measured(night, "TSC00007", export_at=AFTER), "shoot": "2026-09-05-the-gals",
                           "key": "2026-09-05-the-gals/TSC00007.ARW"},
                          {**_measured(night, "TSC00008", exported=True), "shoot": "2026-09-05-the-gals",
                           "key": "2026-09-05-the-gals/TSC00008.ARW"}])
    table, _ = learned.measured_read("frame")
    rows, taught_of = taste.teaching_rows(table, {night.name}, night.parent)
    assert sorted(rows) == ["2026-09-05-the-gals/TSC00008.ARW", f"{night.name}/TSC00002.ARW"]
    assert taught_of == {night: {"TSC00002"}}


def test_the_tier_order_and_the_drop_reasons_read_the_stored_exports(night, monkeypatch):
    """The same frames stand for his in the other two learners."""
    learned.measured_add([_measured(night, "TSC00001"), _measured(night, "TSC00002", export_at=AFTER)])
    seen = {}

    def ranker(shoot, quality=None, kept=None):
        seen["kept"] = kept
        return None
    monkeypatch.setattr(taste, "learn_ranker", ranker)
    vid = taste.venue_id(night)
    edit = {"venues": {"features": taste.VENUE_FEATS, "mu": [0] * 7, "sd": [1] * 7,
                       "shoots": {vid: {"label": "x", "centre": [0] * 7, "spread": 1}}}}
    _table, report = learned.train_tier_order(edit, root=learned.ROOT)
    assert seen["kept"] == {"TSC00002"}
    assert report["shoots"][night.name] == {"state": "too few of your keepers to learn from", "keepers": 1,
                                            "from": "exported"}

    rows, _left_out = flaws.gather(learned.ROOT)
    assert [(r[2], r[3], r[4]) for r in rows] == [("TSC00002", None, True)]

    e = next(r for r in learned.contributors(learned.ROOT) if r["shoot"] == night.name)
    assert e["tier_order"].startswith("1 you exported, in its own cull.csv")
    assert (e["edit_frames"], e["edit_taught"]) == (2, 1)


def test_the_keeper_check_is_the_same_whatever_the_store_says_was_exported(night):
    """The store changes what teaches and nothing the check reads: the same
    candidate scores the same against the same answer key, the kept frame he
    did not export included."""
    before = learned.keeper_check(learned.shoots_with_verdicts(), "drop-reasons",
                                  flaw_new=_probe([20, 0, 0, 0], -10))
    learned.measured_add([_measured(night, "TSC00001"), _measured(night, "TSC00002", export_at=AFTER)])
    sd = learned.shoots_with_verdicts()
    assert [s.keepers for s in sd] == [2] and [len(s.found) for s in sd] == [2]
    after = learned.keeper_check(sd, "drop-reasons", flaw_new=_probe([20, 0, 0, 0], -10))
    assert {k: v for k, v in after.items() if k != "at"} == {k: v for k, v in before.items() if k != "at"}
    assert after["hidden"] == 1 and after["shoots"][0]["frames"][0]["stem"] == "TSC00001"


def test_a_shoot_finished_with_no_exports_found_teaches_nothing(tmp_path, monkeypatch):
    """Finished today with none of its exports in reach - exported somewhere
    the engine does not look, or moved since - it teaches nothing, not every
    frame he kept: "only train based on what i've exported." Finish writes the
    empty list down, which is what tells it from a shoot finished before the
    list was kept. The keepers he recorded are still what every check reads."""
    import threading
    import http.client
    import studio
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    for mod in (learned, studio):
        monkeypatch.setattr(mod, "ROOT", tmp_path)
    monkeypatch.setattr(taste, "EXPORTS", [])
    monkeypatch.setattr(taste, "_EXPORTED", None)
    monkeypatch.setattr(studio, "learned_start", lambda jobs, why, shoot="": {"ok": True, "queued": False})
    learned._EXPORTED.clear()
    shoot = _library(tmp_path, FRAMES, kept=["TSC00001.ARW", "TSC00002.ARW"], vectors=VECTORS)
    (shoot / "shoot.json").write_text(json.dumps({"finished": False}))
    key = "k3y-for-this-test-only-0123456789abcdef"
    monkeypatch.setattr(studio.Handler, "jobs", studio.Jobs(store=tmp_path / "queue.json"), raising=False)
    server = studio.Server(("127.0.0.1", 0), studio.Handler, key=key)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        port = server.server_address[1]
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
        c.request("POST", "/api/kind", json.dumps({"name": shoot.name, "finished": True}), headers={
            "Cookie": f"studio_key={key}", "Sec-Fetch-Site": "same-origin",
            "Origin": f"http://127.0.0.1:{port}", "Content-Type": "application/json"})
        assert json.loads(c.getresponse().read())["ok"] is True
        c.close()
    finally:
        server.shutdown()
        server.server_close()
    assert json.loads((shoot / "decisions" / learned.EXPORTS_KEPT).read_text()) == []
    assert learned.taught(shoot) == (set(), "")
    info = studio.Shoot(shoot).info()
    assert (info["taught"], info["taught_from"]) == (0, "")
    assert learned.recorded_keepers(shoot) == {"TSC00001", "TSC00002"}

    # An export made afterwards joins it and teaches.
    (shoot / "decisions" / learned.EXPORTS_KEPT).write_text(json.dumps(["TSC00002.ARW"]))
    assert learned.taught(shoot) == ({"TSC00002"}, "exported")


def test_the_learning_page_says_the_frames_he_exported_as_exported(night, monkeypatch):
    """A shoot that has too few to teach the tier order is said in what it
    teaches from: "12 you exported", not "12 of your keepers" of a count of
    exports. A shoot finished before exports were written down still says
    keepers, because those are what it teaches from."""
    learned._record_training("tier-order", {"shoots": {
        "2026-09-19": {"state": "too few of your keepers to learn from", "keepers": 12, "from": "exported"},
        "2026-09-05-the-gals": {"state": "too few of your keepers to learn from", "keepers": 12,
                                "from": "recorded"}}}, state="not_enough")
    row = next(r for r in learned.panel()["learners"] if r["id"] == "tier-order")
    assert "2026-09-19 has 12 you exported, 18 short of the 30 it needs" in row["needs_sentence"]
    assert "2026-09-05-the-gals has 12 of your keepers, 18 short of the 30 it needs" in row["needs_sentence"]
    assert "2026-09-19: 12 you exported, 18 short of the 30 it needs." in row["needs_lines"]

    # ./pl learned dataset, shoot by shoot: what the tier order reads, and how
    # many of the finished frames measured for the starting edit teach it.
    _exported(night, "TSC00002.ARW")
    monkeypatch.setattr(learned, "measured_read", lambda kind: ({
        f"{night.name}/{s}": {"shoot": night.name, "stem": s} for s in ("TSC00001", "TSC00002")}, []))
    e = next(r for r in learned.contributors(learned.ROOT) if r["shoot"] == night.name)
    assert e["tier_order"].startswith("1 you exported, in its own cull.csv")
    assert (e["edit_frames"], e["edit_taught"]) == (2, 1)


# ------------------------------------ the one in use, counted by the same rule
#
# His decision, 2026-09-24: the one in use is counted by what he exported, as a
# candidate is, so a candidate is compared like with like. A library of three
# finished shoots: the portraits (6 frames, none exported), the gym (10, 4
# exported) and 2026-09-21 (6, 3 exported). The one that came with the app was
# counted when every finished frame taught: 6 + 10 + 1 on a shoot too small to
# be a kind of light = 17, the shape of his 198 + 328 + 1 = 527.

PORTRAITS, GYM = "6656edcbeffa", "ebd2907e56f1"


@pytest.fixture()
def counted(tmp_path, monkeypatch):
    from test_learned import _finished_shoot
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    monkeypatch.setattr(learned, "ROOT", tmp_path)
    monkeypatch.setattr(taste, "EXPORTS", [])
    monkeypatch.setattr(taste, "_EXPORTED", None)
    learned._EXPORTED.clear()
    rows = []
    for name, n, exported, sid in (("2026-09-05-the-gals", 6, 0, PORTRAITS), ("2026-09-16", 10, 4, GYM),
                                   ("2026-09-21", 6, 3, None)):
        shoot = _finished_shoot(tmp_path, name, n, exported=exported)
        if sid:
            meta = json.loads((shoot / "shoot.json").read_text())
            (shoot / "shoot.json").write_text(json.dumps({**meta, "id": sid}))
        rows += [_measured(shoot, f"{name[-2:]}{i:04d}") for i in range(n)]
    learned.measured_add(rows)
    return tmp_path


def _frames(name: str, *numbers: int) -> list[str]:
    return [f"{name[-2:]}{i:04d}.ARW" for i in numbers]


# The one that came with the app: kinds of light keyed by the shoots' ids, and
# no shoot names or frames of its own.
SEED = {"n": 17, "numeric": {}, "vocab": {},
        "venues": {"shoots": {PORTRAITS: {"label": "portraits", "n": 6}, GYM: {"label": "the gym", "n": 10}}}}


def _fresh(*frames: tuple[str, list[str]]) -> dict:
    """A starting edit learned now: its count is the frames it names. It
    knows the same kinds of light as the seed, so the count is all that is
    weighed here; forgetting one still holds a version, as it always did."""
    listed = dict(frames)
    n = sum(len(v) for v in listed.values())
    return {"n": n, "numeric": {}, "vocab": {}, "taught_frames": listed, "venues": SEED["venues"],
            "dataset": {"frames": n, "shoots": [{"shoot": s, "frames": len(v)} for s, v in listed.items()]}}


def test_the_one_in_use_is_counted_by_what_he_exported_as_the_candidate_is(counted):
    now = learned.taught_now()
    assert {s: len(f) for s, f in now.items()} == {"2026-09-05-the-gals": 0, "2026-09-16": 4, "2026-09-21": 3}
    # By the kinds of light it knows, put back to their shoots by id: at most
    # 0 of the portraits' 6 and 4 of the gym's 10 are frames he exported, and
    # the one frame no kind of light accounts for is counted as it was.
    assert learned.edit_count(SEED, now) == {"frames": 5, "as_learned": 17, "how": "shoots", "bound": "most"}
    # A version learned before this kept how many came off each shoot.
    older = {"n": 22, "dataset": {"frames": 22, "shoots": [{"shoot": "2026-09-16", "frames": 10},
                                                            {"shoot": "2026-09-21", "frames": 6},
                                                            {"shoot": "2026-09-05-the-gals", "frames": 6}]}}
    assert learned.edit_count(older, now) == {"frames": 7, "as_learned": 22, "how": "shoots", "bound": "most"}
    # Weighed against the one in use it is counted at the least it could be:
    # it drew every measured frame of its shoots, so here that is the same 7.
    assert learned.edit_count(older, now, least=True) == {"frames": 7, "as_learned": 22, "how": "shoots",
                                                          "bound": "least"}
    check = learned.check_edit({**older, "venues": SEED["venues"]}, SEED, measured_here=True)
    assert check["passed"]
    assert check["sentence"] == (
        "It knows 2 kinds of light. It learned from more of the photographs you exported than the one in use (7 "
        "against 5, counting only what you exported for both; neither kept a list of its own frames, so both were "
        "counted shoot by shoot: at least 7 of this version's 22 and at most 5 of the one in use's 17 are frames "
        "you exported).")
    # One learned from now on keeps its frames, and is counted exactly.
    kept = {"n": 6, "taught_frames": {"2026-09-16": _frames("2026-09-16", 0, 1, 2, 3, 8, 9)}}
    assert learned.edit_count(kept, now) == {"frames": 4, "as_learned": 6, "how": "frames"}
    # Nothing to count by: its own count stands, as strict as it was.
    assert learned.edit_count({"n": 17}, now) == {"frames": 17, "as_learned": 17, "how": "as learned"}
    # A shoot he takes out of the measurements teaches nothing, for the one
    # in use as for a new version.
    learned.measured_forget("2026-09-16")
    assert learned.taught_now()["2026-09-16"] == set()
    assert learned.edit_count(SEED, learned.taught_now())["frames"] == 1


def test_a_candidate_with_fewer_frames_only_under_the_old_count_is_no_longer_held_on_it(counted):
    """7 exported frames against the 17 the one in use was counted with: held
    on the count alone before. Counted by the same rule the one in use has at
    most 5, and the count holds nothing."""
    assert learned.submit("edit", SEED, source="seeded from the neutral starting edit that ships with this"
                          )["state"] == "in_use"
    fresh = _fresh(("2026-09-16", _frames("2026-09-16", 0, 1, 2, 3)), ("2026-09-21", _frames("2026-09-21", 0, 1, 2)))
    res = learned.submit("edit", fresh, source="learned: you finished 2026-09-21", data=learned.edit_data(fresh))
    assert res["state"] == "in_use", res["sentence"]
    check = res["check"]
    assert check["why"] == []
    assert (check["frames_new"], check["frames_now"], check["frames_now_as_learned"]) == (7, 5, 17)
    assert check["counted_now"] == "shoots" and check["counted_new"] == "frames"
    assert check["sentence"].endswith(
        "It learned from more of the photographs you exported than the one in use (7 against 5, counting only what "
        "you exported for both; the one in use kept no list of its own frames, so it was counted shoot by shoot: "
        "at most 5 of its 17 are frames you exported).")


def test_a_candidate_with_genuinely_fewer_exported_frames_is_still_held(counted):
    assert learned.submit("edit", SEED, source="seeded from the neutral starting edit that ships with this"
                          )["state"] == "in_use"
    fewer = _fresh(("2026-09-21", _frames("2026-09-21", 0, 1, 2)))
    res = learned.submit("edit", fewer, source="learned: you finished 2026-09-21", data=learned.edit_data(fewer))
    assert res["state"] == "held"
    assert res["check"]["why"] == [
        "it learned from fewer of the photographs you exported than the one in use (3 against 5, counting only "
        "what you exported for both; the one in use kept no list of its own frames, so it was counted shoot by "
        "shoot: at most 5 of its 17 are frames you exported)"]

    # Against one that kept its frames, exactly and in fewer words.
    kept = _fresh(("2026-09-16", _frames("2026-09-16", 0, 1, 2, 3, 8, 9)))
    assert learned.edit_count(kept, learned.taught_now())["frames"] == 4
    check = learned.check_edit(fewer, kept, measured_here=True)
    assert check["why"] == ["it learned from fewer of the photographs you exported than the one in use "
                            "(3 against 4, counting only what you exported for both)"]
    assert learned.check_edit(_fresh(("2026-09-16", _frames("2026-09-16", 0, 1, 2, 3))), kept,
                              measured_here=True)["passed"]

    # And one that kept nothing to count by keeps its own count.
    check = learned.check_edit(_fresh(("2026-09-21", _frames("2026-09-21", 0, 1, 2)),
                                      ("2026-09-16", _frames("2026-09-16", 0, 1, 2, 3))), {"n": 17},
                               measured_here=True)
    assert check["why"] == ["it saw fewer of your finished photographs than the one in use (7 against 17; the one "
                            "in use kept no record of the shoots that taught it, so its 17 could not be counted "
                            "again by what you exported)"]


def test_the_learning_page_no_longer_asks_him_to_settle_the_count(counted):
    """The row said the 527 belonged to the edit that came with the app and
    that using the held version anyway was his to decide. The count is made by
    one rule now, and the row says only what the check found."""
    learned.submit("edit", SEED, source="seeded from the neutral starting edit that ships with this")
    fewer = _fresh(("2026-09-21", _frames("2026-09-21", 0, 1, 2)))
    learned.submit("edit", fewer, source="learned: you finished 2026-09-21", data=learned.edit_data(fewer))
    row = next(r for r in learned.panel()["learners"] if r["id"] == "edit")
    said = row["candidate_sentence"]
    assert row["candidate_state"] == "held"
    assert "(3 against 5, counting only what you exported for both;" in said
    assert "yours to decide" not in said and "came with the app, not to your" not in said
    assert not hasattr(learned, "_seed_count_words")


def test_a_kind_of_light_carried_over_is_not_counted_and_no_count_is_above_its_own(counted):
    """The shape of 20260922-180651 on his Mac: 283 frames of its own, on two
    kinds of light (82 and 200), and the two it kept as they were learned from
    the version before (198 and 328), which are not in its 283. Counted with
    the carried ones it read "at most 435 of its 283"."""
    here = learned.taught_now()
    carried = "kept as it was learned: none of its frames could be measured this time"
    v = {"n": 283, "venues": {"shoots": {
        "v1": {"n": 82, "shoots": ["2026-09-21"]}, "v2": {"n": 200, "shoots": ["2026-09-16"]},
        PORTRAITS: {"n": 198, "carried": carried}, GYM: {"n": 328, "carried": carried}}}}
    # 3 of 2026-09-21's 82 and 4 of the gym's 200 teach, and the one frame no
    # kind of light accounts for is counted as it was.
    assert learned.edit_count(v, here) == {"frames": 8, "as_learned": 283, "how": "shoots", "bound": "most"}
    # Its own kinds of light alone, never above its own count.
    big = {"n": 5, "venues": {"shoots": {"a": {"n": 6, "shoots": ["2026-09-21"]},
                                         "b": {"n": 9, "shoots": ["2026-09-16"]}}}}
    assert learned.edit_count(big, here)["frames"] == 5
    listed = {"n": 2, "taught_frames": {"2026-09-16": _frames("2026-09-16", 0, 1, 2, 3)}}
    assert learned.edit_count(listed, here)["frames"] == 2


def test_a_version_counted_shoot_by_shoot_is_weighed_at_the_least_it_could_be(counted):
    """Which of a shoot's frames an older version drew is not known. The one
    in use is counted at the most they could be and the version weighed
    against it at the least: 6 of the gym's 10 measured frames, of which 4
    teach, could be all 4 or none of them."""
    here = learned.taught_now()
    six = {"n": 6, "numeric": {}, "vocab": {}, "venues": SEED["venues"],
           "dataset": {"frames": 6, "shoots": [{"shoot": "2026-09-16", "frames": 6}]}}
    assert learned.edit_count(six, here)["frames"] == 4
    assert learned.edit_count(six, here, least=True)["frames"] == 0
    kept = _fresh(("2026-09-21", _frames("2026-09-21", 0, 1)))
    check = learned.check_edit(six, kept, measured_here=True)
    assert check["why"] == [
        "it learned from fewer of the photographs you exported than the one in use (0 against 2, counting only "
        "what you exported for both; this version kept no list of its own frames, so it was counted shoot by "
        "shoot: at least 0 of its 6 are frames you exported)"]
    # Every measured frame of the gym: all four that teach are among them.
    ten = {**six, "n": 10, "dataset": {"frames": 10, "shoots": [{"shoot": "2026-09-16", "frames": 10}]}}
    assert learned.edit_count(ten, here, least=True)["frames"] == 4
    assert learned.check_edit(ten, kept, measured_here=True)["passed"]


def test_a_version_that_cannot_be_counted_again_is_weighed_by_the_old_rule_on_both_sides(counted):
    """One count made by today's rule against one made by the old is not like
    with like, and it would favour the version that cannot be counted: 10
    against the one in use's 5 would pass where 10 against 17 is held. It
    knows the same kinds of light and kept no count of any of them."""
    bare = {"shoots": {PORTRAITS: {"label": "portraits"}, GYM: {"label": "the gym"}}}
    check = learned.check_edit({"n": 10, "numeric": {}, "vocab": {}, "venues": bare}, SEED, measured_here=True)
    assert (check["frames_new"], check["frames_now"]) == (10, 17)
    assert check["counted_new"] == check["counted_now"] == "as learned"
    assert check["why"] == ["it saw fewer of your finished photographs than the one in use (10 against 17; this "
                            "version kept no record of the shoots that taught it, so both were counted as they "
                            "were learned)"]
    passed = learned.check_edit({"n": 17, "numeric": {}, "vocab": {}, "venues": bare}, SEED, measured_here=True)
    assert passed["passed"] and passed["sentence"] == "Learned from 17 finished frames, in 2 kinds of light."


def test_the_one_that_came_with_the_app_is_still_counted_when_its_shoots_have_left_this_mac(counted):
    """Its kinds of light are keyed by the id each shoot answered to before it
    carried one of its own - the hash of where it sat in the library - and
    the learning store keeps the shoots' names, so the two are matched with
    the folders gone. Before, they were matched only through the folders."""
    import shutil
    from library import legacy_shoot_id
    shoots = counted / "shoots"
    seed = {"n": 17, "numeric": {}, "vocab": {}, "venues": {"shoots": {
        legacy_shoot_id(shoots / "2026-09-05-the-gals"): {"n": 6},
        legacy_shoot_id(shoots / "2026-09-16"): {"n": 10}}}}
    assert learned.edit_count(seed, learned.taught_now())["frames"] == 5
    for name in ("2026-09-05-the-gals", "2026-09-16"):
        shutil.rmtree(shoots / name)
    learned._EXPORTED.clear()
    # Away from this Mac a shoot teaches what the store measured as exported:
    # none of these rows was, so each shoot teaches nothing and the count is
    # the one frame no kind of light accounts for - not the 17 it was learned
    # with, which would hold every version learned from his exports again.
    assert learned.edit_count(seed, learned.taught_now()) == {"frames": 1, "as_learned": 17, "how": "shoots",
                                                              "bound": "most"}


def test_a_count_that_cannot_be_made_does_not_lose_the_learning_run(counted, monkeypatch):
    """Reading the library for the count can fail. The check is made inside
    the learning run's submit, outside the run's own guard, and an error
    there threw away a starting edit that had taken minutes to learn. Now the
    count falls back to each version's own and the sentence says why."""
    assert learned.submit("edit", SEED, source="seeded from the neutral starting edit that ships with this"
                          )["state"] == "in_use"

    def fails(root=None):
        raise OSError("the library could not be read")

    monkeypatch.setattr(learned, "taught_now", fails)
    fresh = _fresh(("2026-09-16", _frames("2026-09-16", 0, 1, 2, 3)), ("2026-09-21", _frames("2026-09-21", 0, 1, 2)))
    res = learned.submit("edit", fresh, source="learned: you finished 2026-09-21", data=learned.edit_data(fresh))
    assert res["state"] == "held"
    assert res["check"]["why"] == [
        "it saw fewer of your finished photographs than the one in use (7 against 17; what you exported could not "
        "be read just now, so both were counted as they were learned)"]
    assert learned.version_model("edit", res["version"]) == fresh


def test_going_back_to_the_one_that_came_with_the_app_is_weighed_by_the_same_rule(counted):
    """Going back is a candidate like any other: with a version learned from
    his exports in use, the one that came with the app is weighed at the
    least it could be - none of the portraits' 6 and at least 4 of the gym's
    10 teach, and the frame no kind of light accounts for is not counted for
    it - so 4 against 7, and going back is held on the count, where the 17 it
    was learned with let it through. Use It Anyway is still his."""
    learned.submit("edit", SEED, source="seeded from the neutral starting edit that ships with this")
    fresh = _fresh(("2026-09-16", _frames("2026-09-16", 0, 1, 2, 3)), ("2026-09-21", _frames("2026-09-21", 0, 1, 2)))
    assert learned.submit("edit", fresh, source="learned: you finished 2026-09-21",
                          data=learned.edit_data(fresh))["state"] == "in_use"
    res = learned.back("edit")
    assert res["state"] == "held"
    assert res["check"]["why"] == [
        "it learned from fewer of the photographs you exported than the one in use (4 against 7, counting only what "
        "you exported for both; this version kept no list of its own frames, so it was counted shoot by shoot: at "
        "least 4 of its 17 are frames you exported)"]
    assert learned.use_anyway("edit", res["version"])["state"] == "in_use"
