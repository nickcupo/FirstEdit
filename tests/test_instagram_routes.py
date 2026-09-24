"""The Instagram step's routes: the wall, one cut, the shape, the pictures,
and the copies made from exactly what the wall draws.

    .venv/bin/python -m pytest tests/test_instagram_routes.py -q

He asked for one wall of the shoot's photographs with every cut drawn on it,
where the extension's page had two lists of the same photographs and drew no
line until a cut was opened and closed again. Each field below is something
that wall draws, so each is pinned to the arithmetic that makes the copy.

The server runs in-process against a library under the test's tmp path.
"""
from __future__ import annotations

import io
import json
import sys
from pathlib import Path

import pytest
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import instagram_library as L  # noqa: E402
from instagram_library import NAME, frames, get, get_json, ig, plan, post, status, studio  # noqa: E402


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


def make(monkeypatch, capsys, shoot: Path, *stems: str) -> dict:
    """Make copies the way the job does, in this process: instagram.py with the
    stems and no shape, so it makes what was planned."""
    monkeypatch.setattr(sys, "argv", ["instagram", str(shoot), *stems, "--json"])
    assert ig.main() == 0
    studio._IG_EXPORTS.clear()
    return json.loads(capsys.readouterr().out.strip().splitlines()[-1])


# ------------------------------------------------------------------ the wall

def test_a_shoot_nobody_has_worked_out_is_every_export_unplanned(srv, shoot):
    """Every exported photograph is on the wall from the first moment, before
    a single cut is worked out, and nothing is drawn on any of them yet."""
    d = status(srv)
    assert d["shoot"] == NAME and d["exported"] == 4 and d["unplanned"] == 4 and d["planned"] == 0
    assert d["ratio"] == "3:4" and d["landscape"] == "fit" and d["ratios"] == list(ig.RATIOS)
    assert d["made"] == 0 and d["grid_misses"] == 0 and d["stale"] == 0
    assert d["planning"] is None and d["making"] is None and d["waiting_for"] is None
    assert [f["stem"] for f in d["frames"]] == ["F0001", "F0002", "F0003", "F0004"]
    f = d["frames"][0]
    assert f["state"] == "unplanned" and f["file"] == "F0001_DxO.jpg"
    assert f["export_mtime"] == int(L.src_of(shoot, "F0001").stat().st_mtime)
    assert f["copy"] is None and f["copy_current"] is False
    for k in ("frame", "shape", "mode", "mode_by", "adjusted", "manual", "subject", "cut", "other", "auto", "whole"):
        assert f[k] is None, k
    # Looking is not making: no folder is created to be looked at.
    assert d["folder"] == str(shoot / "instagram") and d["folder_exists"] is False
    assert not (shoot / "instagram").exists()


def test_a_planned_frame_carries_its_cut_the_other_shape_and_whole(srv, shoot):
    plan(shoot, ["F0001", "F0002"], subject={"F0001": (0.3, 0.5)})
    fs = frames(srv)
    land, port = fs["F0001"], fs["F0002"]
    assert land["state"] == port["state"] == "planned"
    assert land["frame"] == [600, 400] and land["shape"] == "landscape"
    assert land["mode"] == "whole" and land["mode_by"] == "run" and land["adjusted"] is False
    assert land["cut"] == {"shape": "whole", "rect": [0, 0, 600, 400], "out": [1080, 720], "grid_ok": True, "kept": 1.0}
    # Left whole, the faint line is the cut at the shoot's ratio.
    assert land["other"]["shape"] == "3:4" and land["other"]["rect"] == [30, 0, 300, 400]
    assert port["shape"] == "portrait" and port["mode"] == "crop"
    assert port["cut"]["shape"] == "3:4" and port["cut"]["out"] == [1080, 1440]
    # Cut, the faint line is the other portrait shape.
    assert port["other"]["shape"] == "4:5" and port["other"]["out"] == [1080, 1350]
    assert port["auto"]["rect"] == port["cut"]["rect"]
    assert port["whole"]["out"] == [1080, 1440]             # too tall for a post, so cut around its subject
    assert fs["F0003"]["state"] == "unplanned"
    d = status(srv)
    assert d["planned"] == 2 and d["unplanned"] == 2


def test_the_frames_whose_subject_the_grid_would_lose_come_first(srv, shoot):
    """The only tiles he must look at. In stem order they were scattered
    through the wall."""
    plan(shoot, list(L.SHAPES), subject={"F0003": (0.9, 0.5)})
    d = status(srv)
    assert d["grid_misses"] == 1
    assert [f["stem"] for f in d["frames"]] == ["F0003", "F0001", "F0002", "F0004"]
    assert d["frames"][0]["cut"]["grid_ok"] is False


def test_the_wall_is_his_finished_photographs_not_a_reels_edit(tmp_path, monkeypatch, capsys):
    """A burst's frames exported for a reel are not his finished stills. The
    wall took every JPEG under reels/ - photographs he never finished as
    stills - and, for a frame exported to both, whichever was newer: a
    different edit, which Make then cut the copy from."""
    shapes = {**L.SHAPES, "F0009": (600, 400)}
    shoot = L.make_library(tmp_path, shapes)
    L.src_of(shoot, "F0009").unlink()                      # never exported as a still
    reel = shoot / "reels" / "burst1"
    L.export(reel / "F0009_DxO.jpg", (600, 400), colour=(20, 40, 220))
    L.export(reel / "F0002_DxO.jpg", (400, 600), colour=(20, 40, 220))
    later = L.src_of(shoot, "F0002").stat().st_mtime + 60
    import os
    os.utime(reel / "F0002_DxO.jpg", (later, later))       # the reel's edit is the newer file
    server = L.serve(tmp_path, monkeypatch)
    try:
        d = status(server)
        assert [f["stem"] for f in d["frames"]] == ["F0001", "F0002", "F0003", "F0004"]
        assert d["exported"] == 4
        f2 = {f["stem"]: f for f in d["frames"]}["F0002"]
        assert f2["export_mtime"] == int(L.src_of(shoot, "F0002").stat().st_mtime)
        code, body = get(server, f"/exported/{NAME}/F0002.jpg?px=full")
        assert code == 200 and body == L.src_of(shoot, "F0002").read_bytes()
        # The copy is cut from the finished photograph too.
        plan(shoot, ["F0002"])
        make(monkeypatch, capsys, shoot, "F0002")
        with Image.open(shoot / "instagram" / "F0002.jpg") as im:
            r, g, b = im.convert("RGB").getpixel((im.size[0] - 5, im.size[1] - 5))
        assert r > 150 and b < 100, (r, g, b)
    finally:
        L.stop(server)


def test_a_frame_exported_again_is_stale_and_keeps_its_old_numbers(srv, shoot):
    plan(shoot, list(L.SHAPES))
    was = frames(srv)["F0002"]
    L.exported_again(shoot, "F0002")
    d = status(srv)
    now = {f["stem"]: f for f in d["frames"]}["F0002"]
    assert now["state"] == "stale" and now["cut"] == was["cut"]
    assert now["export_mtime"] > was["export_mtime"]
    # Counted with what a planning pass would look at, and as its own part.
    assert d["unplanned"] == 1 and d["stale"] == 1 and d["planned"] == 3


def test_a_made_copy_is_current_until_the_shape_or_the_export_changes(srv, shoot, monkeypatch, capsys):
    plan(shoot, list(L.SHAPES))
    make(monkeypatch, capsys, shoot, "F0001", "F0002")
    fs = frames(srv)
    for s in ("F0001", "F0002"):
        assert fs[s]["copy"]["out"] == fs[s]["cut"]["out"] and fs[s]["copy_current"] is True
    assert fs["F0003"]["copy"] is None and fs["F0003"]["copy_current"] is False
    assert status(srv)["made"] == 2 and status(srv)["folder_exists"] is True

    # 4:5: the portrait's copy is the wrong size now; the landscape left
    # whole is the same picture at either ratio, so it is still the one shown.
    code, d = post(srv, "/api/instagram/shape", {"name": NAME, "ratio": "4:5"})
    assert code == 200 and d["ok"] is True
    fs = {f["stem"]: f for f in d["frames"]}
    assert fs["F0002"]["copy"]["out"] == [1080, 1440] and fs["F0002"]["cut"]["out"] == [1080, 1350]
    assert fs["F0002"]["copy_current"] is False
    assert fs["F0001"]["copy_current"] is True
    post(srv, "/api/instagram/shape", {"name": NAME, "ratio": "3:4"})
    assert frames(srv)["F0002"]["copy_current"] is True

    # Exported again, and worked out again from the new export: planned, and
    # the copy is older than the photograph it is a copy of.
    L.exported_again(shoot, "F0001")
    assert frames(srv)["F0001"]["copy_current"] is False
    plan(shoot, ["F0001"])
    f = frames(srv)["F0001"]
    assert f["state"] == "planned" and f["copy"] is not None and f["copy_current"] is False


def test_the_cut_on_the_wall_is_the_copy_that_is_made_byte_for_byte(srv, shoot, monkeypatch, capsys, tmp_path):
    """What he sees is what is written. Two frames are planned, one of them
    moved by hand, and made; each copy is exactly a render of the rectangle
    the wall drew, at the size the wall said."""
    plan(shoot, list(L.SHAPES), subject={"F0001": (0.8, 0.4)})
    code, _ = post(srv, "/api/instagram/crop", {"name": NAME, "stem": "F0002", "mode": "crop",
                                                 "manual": {"cx": 0.4, "cy": 0.35, "scale": 0.6}})
    assert code == 200
    post(srv, "/api/instagram/crop", {"name": NAME, "stem": "F0001", "mode": "crop"})
    shown = frames(srv)
    made = {r["file"]: r for r in make(monkeypatch, capsys, shoot, "F0001", "F0002")["made"]}
    for s in ("F0001", "F0002"):
        cut = shown[s]["cut"]
        assert made[f"{s}.jpg"]["rect"] == cut["rect"] and made[f"{s}.jpg"]["out"] == cut["out"]
        copy = shoot / "instagram" / f"{s}.jpg"
        assert Image.open(copy).size == tuple(cut["out"])
        ref = tmp_path / "ref" / f"{s}.jpg"
        ig.render(L.src_of(shoot, s), ref, tuple(cut["rect"]), tuple(cut["out"]))
        assert copy.read_bytes() == ref.read_bytes(), s
    # A window placed on a frame that was already cut: his window, the run's mode.
    assert shown["F0002"]["adjusted"] is True and shown["F0002"]["mode_by"] == "run"
    assert shown["F0001"]["mode_by"] == "you"
    assert shown["F0002"]["cut"]["rect"] == list(ig.window_of(400, 600, 3 / 4, 0.4, 0.35, 0.6))


def test_the_wall_answers_quickly_for_a_shoot_of_hundreds(tmp_path, monkeypatch):
    """356 exports, planned: the step polls this while a plan fills in. The
    contract is about 150 ms with a warm cache; the gate here is loose enough
    for a loaded test machine and still catches a per-frame decode."""
    import time
    shapes = {f"G{i:04d}": (60, 40) if i % 7 else (40, 60) for i in range(356)}
    shoot = L.make_library(tmp_path, shapes)
    plan(shoot, list(shapes))
    monkeypatch.setattr(studio, "ROOT", tmp_path)
    monkeypatch.setattr(L.taste, "EXPORTS", [])
    studio._IG_EXPORTS.clear()
    s = studio.Shoot(shoot)
    jobs = studio.Jobs(store=tmp_path / "queue.json")
    studio.instagram_status(s, jobs)
    t = time.perf_counter()
    d = studio.instagram_status(s, jobs)
    took = time.perf_counter() - t
    assert d["exported"] == 356 and d["planned"] == 356
    assert took < 1.0, f"{took * 1000:.0f} ms"


# ------------------------------------------------------------------ one cut

def test_his_window_is_saved_clamped_and_rounded(srv, shoot):
    plan(shoot, list(L.SHAPES))
    code, d = post(srv, "/api/instagram/crop", {"name": NAME, "stem": "F0002",
                                                 "manual": {"cx": 1.7, "cy": 0.123456789, "scale": 0.01}})
    assert code == 200 and d["ok"] is True and d["remade"] is False
    assert d["frame"]["manual"] == {"cx": 1.0, "cy": 0.12346, "scale": 0.05}
    assert d["frame"]["adjusted"] is True
    # The mode was not changed, so it is still the run's.
    assert d["frame"]["mode"] == "crop" and d["frame"]["mode_by"] == "run"
    assert ig.book(shoot / "instagram")["frames"]["F0002"]["manual"] == {"cx": 1.0, "cy": 0.12346, "scale": 0.05}


def test_cut_or_whole_is_his_once_he_changes_it_and_automatic_takes_his_window_away(srv, shoot):
    plan(shoot, list(L.SHAPES))
    code, d = post(srv, "/api/instagram/crop", {"name": NAME, "stem": "F0001", "mode": "crop",
                                                 "manual": {"cx": 0.2, "cy": 0.5, "scale": 0.8}})
    assert d["frame"]["mode"] == "crop" and d["frame"]["mode_by"] == "you" and d["frame"]["cut"]["shape"] == "3:4"
    code, d = post(srv, "/api/instagram/crop", {"name": NAME, "stem": "F0001", "mode": "crop", "auto": True})
    assert d["frame"]["manual"] is None and d["frame"]["adjusted"] is False
    assert d["frame"]["cut"]["rect"] == d["frame"]["auto"]["rect"]
    code, d = post(srv, "/api/instagram/crop", {"name": NAME, "stem": "F0001", "mode": "whole"})
    assert d["frame"]["mode"] == "whole" and d["frame"]["mode_by"] == "you"
    assert d["frame"]["cut"] == {"shape": "whole", "rect": [0, 0, 600, 400], "out": [1080, 720],
                                 "grid_ok": True, "kept": 1.0}


def test_undo_puts_the_cut_back_exactly(srv, shoot):
    plan(shoot, list(L.SHAPES))
    before = ig.book(shoot / "instagram")["frames"]["F0001"]
    post(srv, "/api/instagram/crop", {"name": NAME, "stem": "F0001", "mode": "crop",
                                      "manual": {"cx": 0.2, "cy": 0.5, "scale": 0.8}})
    code, d = post(srv, "/api/instagram/crop", {"name": NAME, "stem": "F0001", "restore": {
        "mode": before["mode"], "mode_by": before["mode_by"], "manual": None}})
    assert code == 200 and d["ok"] is True
    assert ig.book(shoot / "instagram")["frames"]["F0001"] == before
    # And redo, with a window.
    code, d = post(srv, "/api/instagram/crop", {"name": NAME, "stem": "F0001", "restore": {
        "mode": "crop", "mode_by": "you", "manual": {"cx": 0.2, "cy": 0.5, "scale": 0.8}}})
    after = ig.book(shoot / "instagram")["frames"]["F0001"]
    assert after["mode"] == "crop" and after["mode_by"] == "you" and after["manual"] == {"cx": 0.2, "cy": 0.5, "scale": 0.8}


def test_a_made_copy_is_made_again_the_moment_its_cut_is_saved(srv, shoot, monkeypatch, capsys):
    plan(shoot, list(L.SHAPES))
    make(monkeypatch, capsys, shoot, "F0002")
    copy = shoot / "instagram" / "F0002.jpg"
    was = copy.read_bytes()
    code, d = post(srv, "/api/instagram/crop", {"name": NAME, "stem": "F0002", "mode": "crop",
                                                 "manual": {"cx": 0.5, "cy": 0.3, "scale": 0.5}})
    assert code == 200 and d["ok"] is True and d["remade"] is True
    assert copy.read_bytes() != was
    assert d["frame"]["copy_current"] is True and d["frame"]["copy"]["out"] == d["frame"]["cut"]["out"]
    # One that was never made stays unmade: adjusting is not making.
    code, d = post(srv, "/api/instagram/crop", {"name": NAME, "stem": "F0004", "mode": "crop",
                                                 "manual": {"cx": 0.5, "cy": 0.5, "scale": 0.7}})
    assert d["remade"] is False and d["frame"]["copy"] is None
    assert not (shoot / "instagram" / "F0004.jpg").exists()


def test_a_copy_that_cannot_be_made_again_still_keeps_the_cut(srv, shoot, monkeypatch, capsys):
    plan(shoot, list(L.SHAPES))
    make(monkeypatch, capsys, shoot, "F0002")

    def fails(*a, **k):
        raise OSError(28, "No space left on device", str(shoot / "instagram" / ".F0002.jpg.abcdefgh.tmp"))
    monkeypatch.setattr(ig, "redo", fails)
    code, d = post(srv, "/api/instagram/crop", {"name": NAME, "stem": "F0002", "mode": "crop",
                                                 "manual": {"cx": 0.5, "cy": 0.3, "scale": 0.5}})
    assert code == 200 and d["ok"] is False
    assert d["error"].startswith("Saved, but the copy could not be made again: ")
    assert ".tmp" not in d["error"]
    assert d["frame"]["manual"] == {"cx": 0.5, "cy": 0.3, "scale": 0.5}
    assert ig.book(shoot / "instagram")["frames"]["F0002"]["manual"] == {"cx": 0.5, "cy": 0.3, "scale": 0.5}


def test_a_cut_is_refused_in_a_sentence_when_it_cannot_be_saved(srv, shoot):
    # Nothing worked out yet: refused, and no folder is made to refuse it.
    code, d = post(srv, "/api/instagram/crop", {"name": NAME, "stem": "F0001", "mode": "crop"})
    assert code == 409 and d["error"] == "F0001 has not been worked out yet."
    assert not (shoot / "instagram").exists()
    plan(shoot, ["F0002"])
    code, d = post(srv, "/api/instagram/crop", {"name": NAME, "stem": "F0001", "mode": "crop"})
    assert code == 409 and d["error"] == "F0001 has not been worked out yet."
    for bad in ("../F0001", "", 7, "F 1"):
        code, d = post(srv, "/api/instagram/crop", {"name": NAME, "stem": bad})
        assert code == 400 and d["error"] == "Which photograph?", bad
    for bad in ({"cx": "left"}, {"cx": 0.5, "cy": 0.5}, [0.5, 0.5, 1], {"cx": float("nan"), "cy": 0.5, "scale": 1},
                {"cx": True, "cy": 0.5, "scale": 1}):
        code, d = post(srv, "/api/instagram/crop", {"name": NAME, "stem": "F0002", "manual": bad})
        assert code == 400 and d["error"] == "That is not a cut.", bad
    code, d = post(srv, "/api/instagram/crop", {"name": NAME, "stem": "F0002", "restore": {"mode": "sideways"}})
    assert code == 400 and d["error"] == "That is not a cut."
    code, d = post(srv, "/api/instagram/crop", {"name": NAME, "stem": "F0002", "mode": "square"})
    assert code == 400 and d["error"] == "A photograph is either cut or left whole."
    code, d = post(srv, "/api/instagram/crop", {"name": "no-such-shoot", "stem": "F0002"})
    assert code == 404


# ------------------------------------------------------------------ the shape

def test_the_shape_is_kept_in_the_record_and_moves_every_cut_but_his(srv, shoot):
    plan(shoot, list(L.SHAPES))
    # He cuts one landscape himself. A press that changes nothing (Whole on a
    # frame already whole) makes nothing his.
    post(srv, "/api/instagram/crop", {"name": NAME, "stem": "F0003", "mode": "crop"})
    post(srv, "/api/instagram/crop", {"name": NAME, "stem": "F0001", "mode": "whole"})
    code, d = post(srv, "/api/instagram/shape", {"name": NAME, "landscape": "crop"})
    assert code == 200 and d["ok"] is True and d["landscape"] == "crop" and d["ratio"] == "3:4"
    bk = ig.book(shoot / "instagram")
    assert bk["landscape"] == "crop" and bk["ratio"] == "3:4"
    assert bk["frames"]["F0001"]["mode"] == "crop" and bk["frames"]["F0001"]["mode_by"] == "run"
    assert bk["frames"]["F0004"]["mode"] == "crop"             # the square, the run's: moved
    fs = {f["stem"]: f for f in d["frames"]}
    assert fs["F0001"]["cut"]["shape"] == "3:4"
    code, d = post(srv, "/api/instagram/shape", {"name": NAME, "ratio": "4:5", "landscape": "fit"})
    bk = ig.book(shoot / "instagram")
    assert bk["ratio"] == "4:5" and bk["landscape"] == "fit"
    assert bk["frames"]["F0001"]["mode"] == "whole"            # the run's: moved back
    assert bk["frames"]["F0003"]["mode"] == "crop"             # his: never moved
    assert bk["frames"]["F0003"]["mode_by"] == "you"
    fs = {f["stem"]: f for f in d["frames"]}
    assert fs["F0002"]["cut"]["out"] == [1080, 1350] and fs["F0003"]["cut"]["shape"] == "4:5"


def test_a_shape_that_is_not_one_is_refused(srv, shoot):
    code, d = post(srv, "/api/instagram/shape", {"name": NAME, "ratio": "1:1"})
    assert code == 400 and "1:1" in d["error"] and all(r in d["error"] for r in ig.RATIOS)
    code, d = post(srv, "/api/instagram/shape", {"name": NAME, "ratio": ["3:4"]})
    assert code == 400
    code, d = post(srv, "/api/instagram/shape", {"name": NAME, "landscape": "stretch"})
    assert code == 400 and d["error"] == "A landscape is left whole or cut to portrait."
    code, d = post(srv, "/api/instagram/shape", {"name": NAME})
    assert code == 400


def test_the_shape_cannot_change_under_copies_being_made(srv, shoot, tmp_path, monkeypatch):
    """A make reads the shape once, at its start, and writes it back with
    every frame: changed under it, half the copies would be one shape and the
    record would say the other."""
    plan(shoot, list(L.SHAPES))
    L.sleeper(tmp_path, monkeypatch)
    code, d = post(srv, "/api/instagram/make", {"name": NAME, "stems": ["F0001"]})
    assert code == 200 and d["ok"] is True
    code, d = post(srv, "/api/instagram/shape", {"name": NAME, "ratio": "4:5"})
    assert code == 409
    assert d["error"] == "The copies are being made at 3:4 right now. Change the shape when they are done."
    assert ig.book(shoot / "instagram")["ratio"] == "3:4"
    assert status(srv)["making"]["id"] == studio.Handler.jobs.id


def test_a_shape_change_stands_this_shoots_plan_down_and_starts_it_again(srv, shoot, tmp_path, monkeypatch):
    """A plan writes the shape it started with back into the record with
    every frame, so it would put the old shape back. It is stood down, the
    shape is written, and the pass is started again in the same request over
    what it had not reached: he changed the shape, he did not stop the pass,
    and the step read a pass that ended stopped as his Stop and never worked
    out the rest."""
    plan(shoot, ["F0001"])
    L.sleeper(tmp_path, monkeypatch)
    jobs = studio.Handler.jobs
    code, d = post(srv, "/api/instagram/plan", {"name": NAME})
    assert d["planning"] is True
    first = d["id"]
    code, d = post(srv, "/api/instagram/shape", {"name": NAME, "ratio": "4:5"})
    assert code == 200 and d["ratio"] == "4:5" and d["replanned"] is True
    st = jobs.status()
    assert st["running"] is True and st["kind"] == studio.IG_PLAN_KIND and st["id"] != first
    assert d["planning"]["id"] == st["id"] and d["unplanned"] == 3
    assert L.command(jobs)[3:] == ["F0002", "F0003", "F0004", "--plan"]
    assert ig.book(shoot / "instagram")["ratio"] == "4:5"


def test_a_pass_stood_down_for_his_work_says_so_and_his_stop_does_not(tmp_path, monkeypatch):
    """The job's own word for how it ended, which the step reads: `stood_down`
    for the engine making room, never for his Stop."""
    jobs = studio.Jobs(store=tmp_path / "queue.json")
    cmd = [sys.executable, "-c", "import time; time.sleep(30)"]
    assert jobs.start(studio.IG_PLAN_KIND, "working out the Instagram cuts of x", cmd, tmp_path / "p.log", shoot="x")
    assert jobs.status()["stood_down"] is False
    studio.make_room_for(jobs)
    st = jobs.status()
    assert st["running"] is False and st["stopped"] is True and st["stood_down"] is True
    assert jobs.start(studio.IG_PLAN_KIND, "working out the Instagram cuts of x", cmd, tmp_path / "p.log", shoot="x")
    assert jobs.status()["stood_down"] is False
    jobs.stop()
    L.idle(jobs)
    st = jobs.status()
    assert st["stopped"] is True and st["stood_down"] is False


def test_a_shape_change_with_no_pass_running_starts_none(srv, shoot, tmp_path, monkeypatch):
    plan(shoot, ["F0001"])
    L.sleeper(tmp_path, monkeypatch)
    code, d = post(srv, "/api/instagram/shape", {"name": NAME, "ratio": "4:5"})
    assert code == 200 and "replanned" not in d and d["planning"] is None
    assert studio.Handler.jobs.status()["running"] is False


# ------------------------------------------------------------------ the pictures

def test_the_picture_is_the_export_upright_at_the_size_asked(srv, shoot):
    L.export(L.src_of(shoot, "F0001"), (3000, 2000))
    L.export(L.src_of(shoot, "F0002"), (600, 400), orientation=6)      # a portrait, written on its side

    def size(q, stem="F0001"):
        code, body = get(srv, f"/exported/{NAME}/{stem}.jpg{q}")
        assert code == 200
        w, h = Image.open(io.BytesIO(body)).size
        assert abs(max(w, h) / min(w, h) - 1.5) < 0.01          # the whole picture, not a crop of it
        return (w, h)
    assert size("")[0] == 400
    assert size("?px=1000&v=1")[0] == 1000
    assert size("?px=99999")[0] == 2400                      # clamped
    assert size("?px=12")[0] == 200
    assert size("?px=nonsense")[0] == 400
    assert (shoot / "cull" / "exported" / "1000" / "F0001.jpg").is_file()
    w, h = size("", "F0002")
    assert h == 400 and w < h                                # upright


def test_full_is_the_exports_own_bytes(srv, shoot):
    code, body = get(srv, f"/exported/{NAME}/F0001.jpg?px=full")
    assert code == 200 and body == L.src_of(shoot, "F0001").read_bytes()


def test_the_picture_is_made_again_after_a_re_export(srv, shoot):
    code, first = get(srv, f"/exported/{NAME}/F0001.jpg")
    L.export(L.src_of(shoot, "F0001"), (600, 400), colour=(20, 30, 220))
    L.exported_again(shoot, "F0001", by=60)
    code, second = get(srv, f"/exported/{NAME}/F0001.jpg")
    assert code == 200 and second != first
    r, g, b = Image.open(io.BytesIO(second)).convert("RGB").getpixel((350, 250))
    assert b > 150 and r < 80


def test_a_picture_with_no_export_is_not_found(srv, shoot):
    assert get(srv, f"/exported/{NAME}/F9999.jpg")[0] == 404
    assert get(srv, "/exported/no-such-shoot/F0001.jpg")[0] == 404
    assert get(srv, f"/exported/{NAME}/..%2F..%2Fraw%2FF0001.jpg")[0] == 404


def test_the_picture_may_be_kept_only_while_it_names_the_export(srv, shoot):
    import http.client
    mt = int(L.src_of(shoot, "F0001").stat().st_mtime)

    def cache(q):
        c = http.client.HTTPConnection("127.0.0.1", srv.server_address[1], timeout=30)
        c.request("GET", f"/exported/{NAME}/F0001.jpg{q}",
                  headers={"Cookie": f"studio_key={L.KEY}", "Sec-Fetch-Site": "same-origin"})
        r = c.getresponse()
        r.read()
        c.close()
        return r.getheader("cache-control")
    assert "immutable" in cache(f"?v={mt}")
    assert cache("?v=1") == "no-store" and cache("") == "no-store"


# ------------------------------------------------------------------ making

def _builder(shoot, monkeypatch, tmp_path, o):
    monkeypatch.setattr(studio, "ROOT", tmp_path)
    monkeypatch.setattr(L.taste, "EXPORTS", [])
    studio._IG_EXPORTS.clear()
    return studio.WORK["instagram"](NAME, o)


def test_the_copies_made_are_the_stems_shown_at_the_shape_worked_out(shoot, monkeypatch, tmp_path):
    plan(shoot, list(L.SHAPES))
    made = _builder(shoot, monkeypatch, tmp_path, {"stems": ["F0002", "F0001", "F0002"]})
    cmd = made["cmd"]
    assert cmd[1].endswith("instagram.py") and cmd[2] == str(shoot)
    assert cmd[3:] == ["F0002", "F0001"]
    assert "--all" not in cmd and "--ratio" not in cmd and "--landscape" not in cmd and "--plan" not in cmd
    assert made["title"] == f"making 2 Instagram copies of {NAME}"
    assert made["does"] == "Make 2 Instagram-sized copies, cut as shown."
    one = _builder(shoot, monkeypatch, tmp_path, {"stems": ["F0004"]})
    assert one["title"] == f"making 1 Instagram copy of {NAME}"
    assert one["does"] == "Make 1 Instagram-sized copy, cut as shown."


def test_an_item_whose_photographs_are_partly_gone_makes_the_rest(shoot, monkeypatch, tmp_path):
    plan(shoot, list(L.SHAPES))
    L.src_of(shoot, "F0002").unlink()
    cmd = _builder(shoot, monkeypatch, tmp_path, {"stems": ["F0001", "F0002"]})["cmd"]
    assert cmd[3:] == ["F0001"]
    for s in ("F0001", "F0003"):
        L.src_of(shoot, s).unlink()
    with pytest.raises(studio.NotNow) as no:
        _builder(shoot, monkeypatch, tmp_path, {"stems": ["F0001", "F0002", "F0003"]})
    assert str(no.value) == "None of those photographs is exported any more."


def test_a_make_that_names_no_frames_or_bad_ones_is_refused(shoot, monkeypatch, tmp_path):
    for bad in (["../x"], "F0001", [7], ["F 1"]):
        with pytest.raises(studio.NotNow) as no:
            _builder(shoot, monkeypatch, tmp_path, {"stems": bad})
        assert str(no.value) == "That is not a frame name.", bad
    with pytest.raises(studio.NotNow) as no:
        _builder(shoot, monkeypatch, tmp_path, {"stems": []})
    assert str(no.value) == "No photographs were named, so there is nothing to make."


def test_an_item_with_no_stems_still_makes_every_export(shoot, monkeypatch, tmp_path):
    """Items already on someone's list were written before the step sent
    stems; they must still run as they were - over the photographs the wall
    shows, by name, since `--all` is every JPEG instagram.py can find."""
    made = _builder(shoot, monkeypatch, tmp_path, {})
    assert made["cmd"][3:] == ["F0001", "F0002", "F0003", "F0004"]
    assert made["title"] == f"making 4 Instagram copies of {NAME}"


def test_a_photograph_exported_again_after_it_was_listed_is_not_made_and_is_named(shoot, monkeypatch, tmp_path):
    """An item on Up Next names its photographs; one exported again since
    would have its subject looked for again and a copy cut that he never
    saw. It is left out when the item is built, and the line says which."""
    plan(shoot, list(L.SHAPES))
    L.exported_again(shoot, "F0002")
    made = _builder(shoot, monkeypatch, tmp_path, {"stems": ["F0001", "F0002", "F0003"]})
    assert made["cmd"][3:] == ["F0001", "F0003"]
    assert made["does"] == ("Make 2 Instagram-sized copies, cut as shown. "
                            "F0002 was exported again since and is left for you to look at.")
    L.exported_again(shoot, "F0003")
    with ig.held(shoot / "instagram"):
        bk = ig.book(shoot / "instagram")
        del bk["frames"]["F0004"]
        ig.keep_book(shoot / "instagram", bk, locked=True)
    with pytest.raises(studio.NotNow) as no:
        _builder(shoot, monkeypatch, tmp_path, {"stems": ["F0002", "F0003", "F0004"]})
    assert str(no.value) == ("F0002 and F0003 were exported again since and are left for you to look at. "
                             "F0004 was not worked out yet and is left for you to look at.")


def test_making_now_and_leaving_it_on_the_list_are_one_builder(srv, shoot, tmp_path, monkeypatch):
    plan(shoot, list(L.SHAPES))
    L.sleeper(tmp_path, monkeypatch)
    code, d = post(srv, "/api/instagram/make", {"name": NAME, "stems": ["F0001", "F0002"]})
    assert code == 200 and d["ok"] is True and d["queued"] is False and isinstance(d["id"], int)
    jobs = studio.Handler.jobs
    st = jobs.status()
    assert st["kind"] == "instagram" and st["title"] == f"making 2 Instagram copies of {NAME}"
    assert L.command(jobs)[3:] == ["F0001", "F0002"]
    # ⌥: onto the list, through the same builder, with the stems kept.
    code, d = post(srv, "/api/queue", {"kind": "instagram", "name": NAME, "stems": ["F0003"]})
    assert code == 200 and d["ok"] is True
    item = d["added"]
    assert item["kind"] == "instagram" and item["opts"]["stems"] == ["F0003"]
    assert item["title"] == f"making 1 Instagram copy of {NAME}" and item["ready"] is True
    # The route's own queue flag goes to the same place.
    code, d = post(srv, "/api/instagram/make", {"name": NAME, "stems": ["F0004"], "queue": True})
    assert code == 200 and d["queued"] is True
    # And a refusal comes back as the engine's sentence, queueable or not.
    code, d = post(srv, "/api/instagram/make", {"name": NAME, "stems": ["nope/x"]})
    assert code == 400 and d["error"] == "That is not a frame name." and d["queueable"] is True
    code, d = post(srv, "/api/instagram/make", {"name": NAME, "stems": ["nope/x"], "queue": True})
    assert code == 409 and d["error"] == "That is not a frame name."
    jobs.clear()


def test_a_second_press_while_copies_are_being_made_says_what_it_waits_on(srv, shoot, tmp_path, monkeypatch):
    plan(shoot, list(L.SHAPES))
    L.sleeper(tmp_path, monkeypatch)
    post(srv, "/api/instagram/make", {"name": NAME, "stems": ["F0001"]})
    code, d = post(srv, "/api/instagram/make", {"name": NAME, "stems": ["F0002"]})
    assert code == 200 and d["busy"]["kind"] == "instagram" and d["busy"]["can_queue"] is True
    assert d["error"].startswith(f"Making 1 Instagram copy of {NAME} has to wait: making 1 Instagram copy of {NAME}")


# ------------------------------------------------------------------ the step

def test_the_step_comes_after_the_edit_and_is_done_when_a_copy_is_made(srv, shoot, monkeypatch, capsys):
    d = get_json(srv, f"/api/shoot?name={NAME}")
    ids = [s["id"] for s in d["steps"]]
    assert ids.index("instagram") == ids.index("edit") + 1
    step = {s["id"]: s for s in d["steps"]}["instagram"]
    assert step["label"] == "Instagram" and step["done"] is False and step["enabled"] is True
    assert step["source"] == "base"
    assert d["info"]["instagram"] == 0
    assert not (shoot / "instagram").exists()                   # counting made no folder
    plan(shoot, ["F0001"])
    make(monkeypatch, capsys, shoot, "F0001")
    d = get_json(srv, f"/api/shoot?name={NAME}")
    assert d["info"]["instagram"] == 1
    assert {s["id"]: s for s in d["steps"]}["instagram"]["done"] is True


def test_the_step_says_why_it_is_shut_when_nothing_is_exported(tmp_path, monkeypatch):
    L.make_library(tmp_path, exported=False)
    server = L.serve(tmp_path, monkeypatch)
    try:
        d = get_json(server, f"/api/shoot?name={NAME}")
        step = {s["id"]: s for s in d["steps"]}["instagram"]
        assert step["enabled"] is False
        assert step["why_disabled"] == "Nothing is exported yet: the copies are cut from your finished photographs."
        w = status(server)
        assert w["exported"] == 0 and w["frames"] == [] and w["unplanned"] == 0
        code, a = post(server, "/api/instagram/plan", {"name": NAME})
        assert a == {"ok": True, "planning": False, "nothing": True}
    finally:
        L.stop(server)


@pytest.mark.parametrize("theirs,where", [
    (["ingest", "cull", "keepers", "edit", "print", "done"], ["ingest", "cull", "keepers", "edit", "instagram", "print", "done"]),
    (["ingest", "cull", "reels", "done"], ["ingest", "cull", "instagram", "reels", "done"]),
    (["ingest", "cull", "done"], ["ingest", "cull", "instagram", "done"]),
    (["ingest", "cull"], ["ingest", "cull", "instagram"]),
    (["ingest", "instagram", "cull", "edit", "done"], ["ingest", "instagram", "cull", "edit", "done"]),
])
def test_an_extensions_own_list_of_steps_gets_the_step_after_the_edit(tmp_path, monkeypatch, theirs, where):
    shoot = L.make_library(tmp_path)
    monkeypatch.setattr(studio, "ROOT", tmp_path)
    monkeypatch.setattr(studio, "ext_config", lambda: {"kind": "own", "steps": theirs, "labels": {}, "every": []})
    monkeypatch.setattr(studio, "can_cut_reels", lambda: True)
    s = studio.Shoot(shoot)
    info = {**s.info(), "kind": "own"}
    assert [x["id"] for x in s.steps(info)] == where


def test_show_the_folder_opens_the_copies_and_never_makes_the_folder(srv, shoot, monkeypatch, capsys):
    opened: list = []
    monkeypatch.setattr(studio, "_open", lambda args: opened.append(["open", *args]))
    code, d = post(srv, "/api/open", {"name": NAME, "what": "instagram"})
    assert d["ok"] is False and d["missing"] == str(shoot / "instagram")
    assert not (shoot / "instagram").exists() and opened == []
    plan(shoot, ["F0001"])
    make(monkeypatch, capsys, shoot, "F0001")
    code, d = post(srv, "/api/open", {"name": NAME, "what": "instagram"})
    assert d["ok"] is True and d["folder"] == str(shoot / "instagram")
    assert opened == [["open", str(shoot / "instagram")]]
