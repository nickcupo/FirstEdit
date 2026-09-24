"""Working the Instagram cuts out: in the background, once, and out of his way.

    .venv/bin/python -m pytest tests/test_instagram_plan.py -q

The step asks for a planning pass as soon as it opens and whenever frames are
left over, so the cut lines are on the wall without a button being pressed.
That makes it the machine's homework, exactly like learning: it writes the
record and no photograph, any press of his stands it down, and nothing of it
is lost because a stopped pass keeps every frame it finished.

Every job here runs a sleeper in place of Python (instagram_library.sleeper),
so a job can be seen holding the slot and nothing of the pipeline runs.
"""
from __future__ import annotations

import json
import sys
import time
import types
from pathlib import Path

import pytest
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import instagram_library as L  # noqa: E402
from instagram_library import NAME, frames, ig, plan, post, status, studio  # noqa: E402


@pytest.fixture
def shoot(tmp_path):
    return L.make_library(tmp_path)


@pytest.fixture
def srv(shoot, tmp_path, monkeypatch):
    server = L.serve(tmp_path, monkeypatch)
    try:
        yield server
    finally:
        L.stop(server)


@pytest.fixture
def asked(monkeypatch):
    """What was written down for the learning run to pick up again."""
    import learned
    seen: list[tuple] = []
    monkeypatch.setattr(learned, "request_run", lambda why, shoot="": seen.append((why, shoot)))
    return seen


def _his_job(jobs, root: Path, kind: str = "cull", title: str = "culling a shoot"):
    assert jobs.start(kind, title, [sys.executable, "-c", "import time; time.sleep(30)"], root / f"{kind}.log",
                      shoot="elsewhere")


def _learning(jobs, root: Path):
    assert jobs.start(studio.LEARN_KIND, "Learning from elsewhere",
                      [sys.executable, "-c", "import time; time.sleep(30)"], root / "learn.log",
                      shoot="elsewhere", why="you finished elsewhere")


# ------------------------------------------------------------------ asking

def test_opening_the_step_starts_one_plan_of_what_is_left_and_no_second(srv, shoot, tmp_path, monkeypatch):
    plan(shoot, ["F0001", "F0003"])
    L.exported_again(shoot, "F0003")                        # exported again: worked out again
    L.sleeper(tmp_path, monkeypatch)
    code, a = post(srv, "/api/instagram/plan", {"name": NAME})
    assert code == 200 and a["ok"] is True and a["planning"] is True and a["count"] == 3
    jobs = studio.Handler.jobs
    st = jobs.status()
    assert st["kind"] == studio.IG_PLAN_KIND and st["background"] is True and st["shoot"] == NAME
    assert st["title"] == f"working out the Instagram cuts of {NAME}"
    assert a["id"] == st["id"]
    # Only the frames not worked out and the one exported again, in stem
    # order; --plan; and no shape of its own: the record's is used.
    cmd = L.command(jobs)
    assert cmd[1].endswith("instagram.py") and cmd[2] == str(shoot)
    assert cmd[3:] == ["F0002", "F0003", "F0004", "--plan"]
    assert "--ratio" not in cmd and "--landscape" not in cmd and "--all" not in cmd
    # Asked again while it runs: the same one, never a second.
    code, again = post(srv, "/api/instagram/plan", {"name": NAME})
    assert again == {"ok": True, "planning": True, "id": a["id"], "already": True}
    d = status(srv)
    assert d["planning"]["id"] == a["id"] and "fraction" in d["planning"] and "label" in d["planning"]
    assert d["waiting_for"] is None and d["making"] is None


def test_nothing_left_to_work_out_starts_nothing(srv, shoot):
    plan(shoot, list(L.SHAPES))
    code, a = post(srv, "/api/instagram/plan", {"name": NAME})
    assert a == {"ok": True, "planning": False, "nothing": True}
    assert studio.Handler.jobs.status()["running"] is False


def test_his_own_work_in_the_slot_is_waited_for_and_nothing_is_queued(srv, shoot, tmp_path):
    jobs = studio.Handler.jobs
    _his_job(jobs, tmp_path)
    code, a = post(srv, "/api/instagram/plan", {"name": NAME})
    assert a == {"ok": True, "planning": False, "waiting_for": {"title": "culling a shoot", "kind": "cull"}}
    assert jobs.status()["kind"] == "cull" and jobs.status()["queue"] == []
    d = status(srv)
    assert d["waiting_for"] == {"title": "culling a shoot", "kind": "cull"} and d["planning"] is None


def test_learning_in_the_slot_is_stood_down_for_the_wall(srv, shoot, tmp_path, monkeypatch, asked):
    """He is looking at this wall now; learning picks up again later."""
    jobs = studio.Handler.jobs
    _learning(jobs, tmp_path)
    L.sleeper(tmp_path, monkeypatch)
    code, a = post(srv, "/api/instagram/plan", {"name": NAME})
    assert a["planning"] is True and a["count"] == 4
    assert jobs.status()["kind"] == studio.IG_PLAN_KIND
    assert asked == [("you finished elsewhere", "elsewhere")]
    assert a["paused"] == studio.LEARNING_STOOD_DOWN


def test_another_shoots_plan_is_stood_down_quietly(srv, shoot, tmp_path, monkeypatch, asked):
    jobs = studio.Handler.jobs
    L.sleeper(tmp_path, monkeypatch)
    assert jobs.start(studio.IG_PLAN_KIND, "working out the Instagram cuts of elsewhere",
                      [studio.PY, "x"], tmp_path / "other.log", shoot="elsewhere")
    code, a = post(srv, "/api/instagram/plan", {"name": NAME})
    assert a["planning"] is True and "paused" not in a
    assert jobs.status()["shoot"] == NAME and asked == []


# ------------------------------------------------------------------ out of his way

def test_a_make_press_stands_the_plan_down_and_leaves_no_note(srv, shoot, tmp_path, monkeypatch, asked):
    plan(shoot, ["F0001", "F0002"])
    L.sleeper(tmp_path, monkeypatch)
    code, a = post(srv, "/api/instagram/plan", {"name": NAME})
    assert a["planning"] is True
    code, m = post(srv, "/api/instagram/make", {"name": NAME, "stems": ["F0001", "F0002"]})
    assert code == 200 and m["ok"] is True and m["queued"] is False
    # No "paused" line and no learning written down: the step asks for the
    # rest of the cuts again itself when the slot is free.
    assert "paused" not in m and asked == []
    st = studio.Handler.jobs.status()
    assert st["kind"] == "instagram" and st["background"] is False
    d = status(srv)
    assert d["making"]["id"] == m["id"] and d["planning"] is None
    # While the copies are made, what is left to work out waits on them.
    assert d["waiting_for"]["kind"] == "instagram"
    code, again = post(srv, "/api/instagram/plan", {"name": NAME})
    assert again["planning"] is False and again["waiting_for"]["kind"] == "instagram"


def test_make_room_for_a_plan_returns_nothing_to_say(tmp_path, monkeypatch, asked):
    jobs = studio.Jobs(store=tmp_path / "queue.json")
    assert jobs.start(studio.IG_PLAN_KIND, "working out the Instagram cuts of x",
                      [sys.executable, "-c", "import time; time.sleep(30)"], tmp_path / "p.log", shoot="x")
    assert studio.make_room_for(jobs) == {}
    assert asked == [] and jobs.status()["running"] is False
    assert studio.IG_PLAN_KIND in studio.BACKGROUND_KINDS


def test_something_he_left_on_the_list_does_not_wait_on_a_plan(tmp_path, monkeypatch, asked):
    """The list counts the slot as free when the machine's homework holds it."""
    plan(L.make_library(tmp_path), ["F0001"])
    monkeypatch.setattr(studio, "ROOT", tmp_path)
    monkeypatch.setattr(L.taste, "EXPORTS", [])
    studio._IG_EXPORTS.clear()
    L.sleeper(tmp_path, monkeypatch)
    jobs = studio.Jobs(store=tmp_path / "queue.json")
    try:
        assert jobs.start(studio.IG_PLAN_KIND, "working out", [studio.PY, "x"], tmp_path / "p.log", shoot=NAME)
        jobs.add("instagram", NAME, {"stems": ["F0001"]})
        for _ in range(100):
            if jobs.status()["kind"] == "instagram":
                break
            time.sleep(0.05)
        assert jobs.status()["kind"] == "instagram" and asked == []
        assert L.command(jobs)[3:] == ["F0001"]
    finally:
        jobs.clear()
        jobs.stop()
        L.idle(jobs)


# ------------------------------------------------------------------ the bar

def _read(tmp_path, kind: str, log: str) -> dict:
    j = studio.Jobs(store=tmp_path / "queue.json")
    p = tmp_path / f"{kind}.log"
    p.write_text(log)
    j.log, j.kind, j.started = p, kind, 1.0
    return j.status()


def test_the_bar_says_it_is_working_out_the_cuts(tmp_path):
    st = _read(tmp_path, studio.IG_PLAN_KIND, "$ python instagram.py x --plan\n@@ planning 3 6\n")
    assert st["label"] == "working out the cuts: 3 of 6 photographs"
    assert st["fraction"] == 0.5 and st["stage"] == "planning" and st["background"] is True


def test_the_copies_bar_moves(tmp_path):
    """Weighed against the cull's table, "instagram" was no stage at all and
    the bar sat at nothing until the job ended."""
    st = _read(tmp_path, "instagram", "$ python instagram.py x F1 F2 F3 F4\n@@ instagram 1 4\n")
    assert st["label"] == "making the Instagram copies: 1 of 4 photographs"
    assert st["fraction"] == 0.25 and st["background"] is False


# ------------------------------------------------------------------ the pass itself

def _no_detector(monkeypatch):
    """detect() without the models: the middle of the frame, which is what it
    answers when it finds nothing."""
    for name, thing in (("faces", "FaceJudge"), ("presets", "SceneReader")):
        m = types.ModuleType(name)
        setattr(m, thing, lambda: None)
        monkeypatch.setitem(sys.modules, name, m)
    monkeypatch.setattr(ig, "detect", lambda src, judge, reader: {
        "src": src.name, "w": Image.open(src).size[0], "h": Image.open(src).size[1],
        "mtime": int(src.stat().st_mtime), "subject": {"cx": 0.5, "cy": 0.5, "kind": "scene", "faces": None}})


def test_the_pass_fills_the_wall_in_and_writes_no_photograph(srv, shoot, monkeypatch, capsys):
    """Run as the job runs it, with the stems the route names: every tile gets
    its cut, the folder holds the record and nothing else, and the bar's
    marks are the planning stage's."""
    _no_detector(monkeypatch)
    plan(shoot, ["F0001"])
    stems = [f["stem"] for f in status(srv)["frames"] if f["state"] != "planned"]
    monkeypatch.setattr(sys, "argv", ["instagram", str(shoot), *stems, "--plan", "--json"])
    assert ig.main() == 0
    out = capsys.readouterr().out
    assert "@@ planning 0 3" in out and "@@ planning 3 3" in out and "@@ instagram" not in out
    assert json.loads(out.strip().splitlines()[-1])["planned"]
    assert [p.name for p in (shoot / "instagram").iterdir()] == [ig.CROPS]
    d = status(srv)
    assert d["planned"] == 4 and d["unplanned"] == 0 and d["made"] == 0
    assert all(f["cut"] is not None for f in d["frames"])


def test_a_make_still_marks_its_bar_as_making(srv, shoot, monkeypatch, capsys):
    plan(shoot, ["F0001"])
    monkeypatch.setattr(sys, "argv", ["instagram", str(shoot), "F0001", "--json"])
    assert ig.main() == 0
    out = capsys.readouterr().out
    assert "@@ instagram 0 1" in out and "@@ instagram 1 1" in out and "@@ planning" not in out


def test_a_record_that_will_not_read_is_worked_out_again(srv, shoot, tmp_path, monkeypatch):
    """Described as not worked out, and dropped before the pass starts: left
    in, instagram.py would find it current and leave it as it is, and the
    step would ask for it for ever."""
    plan(shoot, list(L.SHAPES))
    with ig.held(shoot / "instagram"):
        bk = ig.book(shoot / "instagram")
        del bk["frames"]["F0002"]["subject"]
        ig.keep_book(shoot / "instagram", bk, locked=True)
    assert frames(srv)["F0002"]["state"] == "unplanned"
    L.sleeper(tmp_path, monkeypatch)
    code, a = post(srv, "/api/instagram/plan", {"name": NAME})
    assert a["planning"] is True and a["count"] == 1
    assert L.command(studio.Handler.jobs)[3:] == ["F0002", "--plan"]
    assert "F0002" not in ig.book(shoot / "instagram")["frames"]


# ------------------------------------------------------------------ one bad export

def _reading_detector(monkeypatch):
    """detect() without the models but reading the whole picture, as the real
    one does: a half-written export fails here as it fails there."""
    _no_detector(monkeypatch)

    def detect(src, judge, reader):
        with Image.open(src) as im:
            im.load()
            w, h = im.size
        return {"src": src.name, "w": w, "h": h, "mtime": int(src.stat().st_mtime),
                "subject": {"cx": 0.5, "cy": 0.5, "kind": "scene", "faces": None}}
    monkeypatch.setattr(ig, "detect", detect)


def _half_written(p: Path) -> None:
    data = p.read_bytes()
    p.write_bytes(data[: len(data) // 2])


def test_one_half_written_export_is_skipped_and_the_pass_goes_on(shoot, monkeypatch, capsys):
    """PhotoLab still writing one export while the step works the cuts out:
    that photograph is left for the next pass, with a line saying so, and
    every one after it is worked out. The pass ended at it, and every
    photograph after it in the list was left with it."""
    _reading_detector(monkeypatch)
    _half_written(L.src_of(shoot, "F0002"))
    monkeypatch.setattr(sys, "argv", ["instagram", str(shoot), *L.SHAPES, "--plan"])
    assert ig.main() == 0
    out = capsys.readouterr().out
    assert "F0002_DxO.jpg" in out and "could not be worked out" in out and "left for the next pass" in out
    assert "1 could not be worked out and is left for the next pass." in out
    recs = ig.book(shoot / "instagram")["frames"]
    assert sorted(recs) == ["F0001", "F0003", "F0004"]


def test_a_pass_that_can_read_nothing_fails_with_the_reason(shoot, monkeypatch, capsys):
    """Nothing worked out at all is a failure he is shown, with what to do -
    not a pass that did nothing, ended well, and is asked for again every
    five seconds."""
    _reading_detector(monkeypatch)
    _half_written(L.src_of(shoot, "F0002"))
    monkeypatch.setattr(sys, "argv", ["instagram", str(shoot), "F0002", "--plan"])
    assert ig.main() == 1
    last = capsys.readouterr().out.strip().splitlines()[-1]
    assert last.startswith("F0002_DxO.jpg could not be worked out: OSError")
    assert last.endswith("If it is still being exported, wait for it to finish; otherwise export it again.")
    assert "F0002" not in ig.book(shoot / "instagram")["frames"]


def test_a_make_that_cannot_read_one_makes_the_rest_and_says_so(shoot, monkeypatch, capsys):
    _reading_detector(monkeypatch)
    plan(shoot, list(L.SHAPES))
    p = L.src_of(shoot, "F0002")
    t = p.stat().st_mtime
    _half_written(p)
    import os
    os.utime(p, (t, t))                     # its record still reads as current
    monkeypatch.setattr(sys, "argv", ["instagram", str(shoot), "F0001", "F0002", "F0003"])
    assert ig.main() == 1
    last = capsys.readouterr().out.strip().splitlines()[-1]
    assert last.startswith("F0002_DxO.jpg could not be made: ")
    assert sorted(x.name for x in (shoot / "instagram").glob("*.jpg")) == ["F0001.jpg", "F0003.jpg"]


# ------------------------------------------------------------------ one pass at a time

def test_two_asks_at_once_start_one_pass(srv, shoot, tmp_path, monkeypatch):
    """The check, the stand-down of homework and the start are one step: two
    asks in the same moment used to start two passes, the second standing the
    first down (it is homework) and starting over."""
    import threading
    L.sleeper(tmp_path, monkeypatch)
    real = studio.make_room_for

    def slow(jobs):
        time.sleep(0.3)                     # the gap the second ask fell into
        return real(jobs)
    monkeypatch.setattr(studio, "make_room_for", slow)
    go = threading.Barrier(2)
    answers: list[dict] = []

    def ask():
        go.wait()
        answers.append(post(srv, "/api/instagram/plan", {"name": NAME})[1])
    ts = [threading.Thread(target=ask) for _ in range(2)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert len(answers) == 2 and all(a["planning"] for a in answers)
    assert answers[0]["id"] == answers[1]["id"]
    assert sum(1 for a in answers if a.get("already")) == 1
    st = studio.Handler.jobs.status()
    assert st["running"] is True and st["id"] == answers[0]["id"]


def test_an_export_still_being_written_waits_for_the_next_ask(srv, shoot, tmp_path, monkeypatch):
    """An export written in the last few seconds may be half-written: it is
    left for the next ask, which the step makes five seconds later."""
    import os
    monkeypatch.setattr(studio, "IG_SETTLE", 60.0)
    L.sleeper(tmp_path, monkeypatch)
    code, a = post(srv, "/api/instagram/plan", {"name": NAME})
    assert a == {"ok": True, "planning": False, "nothing": True, "settling": 4}
    old = time.time() - 120
    for s in ("F0001", "F0003"):
        os.utime(L.src_of(shoot, s), (old, old))
    code, a = post(srv, "/api/instagram/plan", {"name": NAME})
    assert a["planning"] is True and a["count"] == 2
    assert L.command(studio.Handler.jobs)[3:] == ["F0001", "F0003", "--plan"]
