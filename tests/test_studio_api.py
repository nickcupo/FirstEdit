"""What the studio answers the app with.

    .venv/bin/python -m pytest tests/test_studio_api.py -q

The native app codes against these routes, and each field below is a rule that
used to live in the page as well as here - the burst grouping, where to resume,
which step is done - or a number that was printed in his voice when it was the
machine's. Every existing field stays: the web page is still openable by hand.

Nothing here reads or writes ~/photos. The server runs in-process on a port the
OS picks, against a library under pytest's tmp_path.
"""
from __future__ import annotations

import json
import re
import sys
import threading
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import instagram  # noqa: E402
import studio  # noqa: E402
import taste  # noqa: E402

KEY = "k3y-for-this-test-only-0123456789abcdef"
# Two scenes inside ONE time burst, which is the case the page got wrong: a
# scene is a CLIP cluster split by the light and a burst is seconds of shutter.
ROWS = """file,rating,reason,scene,burst,quality,shot_at,stack,stack_top
TSC00001.ARW,5,clear win,0,0,0.9,2026-01-01 10:00:00,,0
TSC00002.ARW,2,similar to 00001,1,0,0.5,2026-01-01 10:00:01,1,0
TSC00003.ARW,3,maybe,1,0,0.7,2026-01-01 10:00:02,1,1
TSC00004.ARW,0,soft,2,1,0.1,2026-01-01 10:30:00,,0
TSC00005.ARW,5,clear win,2,1,0.8,2026-01-01 10:30:01,,0
"""


def _shoot(root: Path, name: str = "2026-01-01-gym") -> Path:
    shoot = root / "shoots" / name
    (shoot / "raw").mkdir(parents=True)
    (shoot / "cull").mkdir()
    (shoot / "cull" / "cull.csv").write_text(ROWS)
    for line in ROWS.splitlines()[1:]:
        (shoot / "raw" / line.split(",")[0]).write_bytes(b"raw")
    return shoot


@pytest.fixture
def lib(tmp_path, monkeypatch):
    monkeypatch.setattr(studio, "ROOT", tmp_path)
    monkeypatch.setattr(taste, "EXPORTS", [])
    monkeypatch.setattr(taste, "_EXPORTED", None)
    monkeypatch.setattr(studio, "cards", lambda: [])
    return {"root": tmp_path, "gym": _shoot(tmp_path)}


@pytest.fixture
def srv(lib, monkeypatch):
    # Its own list on disk, under this test's tmp path: the list survives a
    # restart on purpose, so a shared one would carry a test's work into the
    # next test the same way it carries his into the morning.
    monkeypatch.setattr(studio.Handler, "jobs", studio.Jobs(store=lib["root"] / "queue.json"),
                        raising=False)
    server = studio.Server(("127.0.0.1", 0), studio.Handler, key=KEY)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()


def get(server, path):
    import http.client
    port = server.server_address[1]
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    c.request("GET", path, headers={"Cookie": f"studio_key={KEY}", "Sec-Fetch-Site": "same-origin"})
    r = c.getresponse()
    out = (r.status, r.read())
    c.close()
    return out


def post(server, path, body):
    import http.client
    port = server.server_address[1]
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    c.request("POST", path, json.dumps(body), headers={
        "Cookie": f"studio_key={KEY}", "Sec-Fetch-Site": "same-origin",
        "Origin": f"http://127.0.0.1:{port}", "Content-Type": "application/json"})
    r = c.getresponse()
    out = json.loads(r.read())
    c.close()
    return out


def shoot_json(server, name="2026-01-01-gym"):
    status, body = get(server, f"/api/shoot?name={name}")
    assert status == 200
    return json.loads(body)


# ------------------------------------------------------ bursts and resume

def test_a_burst_that_crosses_two_scenes_is_one_burst(srv):
    """The page keyed a burst by scene AND burst, so one burst came apart
    across two screens on 56 of the gym shoot's 89 - and a stack inside it
    with it. The server groups by the time burst, once, for both readers."""
    d = shoot_json(srv)
    ids = [b["id"] for b in d["bursts"]]
    assert ids == ["0", "1"]
    first = d["bursts"][0]
    assert first["frames"] == ["TSC00001", "TSC00002", "TSC00003"]   # stems: a picture route's names
    assert first["index"] == 0 and first["scene"] == "0" and first["started_at"] == "2026-01-01 10:00:00"
    assert first["cover"] == "TSC00001"                # the cull's top tier, then its best score
    assert first["cull_picks"] == 2 and first["undecided"] == 3 and first["kept"] == 0 and first["seen"] is False


def test_the_stack_columns_reach_the_app(srv):
    """cull.csv carries stack and stack_top; ROW_KEEP dropped them before the
    browser saw them, so no stack could be drawn."""
    rows = {r["file"]: r for r in shoot_json(srv)["rows"]}
    assert rows["TSC00003.ARW"]["stack"] == "1" and rows["TSC00003.ARW"]["stack_top"] == "1"
    assert rows["TSC00001.ARW"]["stack"] == ""


def test_a_fresh_shoot_opens_at_its_first_burst_and_says_the_keys(srv):
    r = shoot_json(srv)["resume"]
    assert r["kind"] == "fresh" and r["burst_id"] == "0" and r["note"].startswith("Burst 1 of 2.")
    # The left hand's keys, as the app's menus show them: his right hand is on the mouse.
    assert "E keep, D drop, F next frame, R next burst" in r["note"]


def test_it_resumes_where_he_left_off_and_moves_on_when_that_burst_is_gone(srv, lib):
    post(srv, "/api/review", {"name": "2026-01-01-gym", "at": "1", "seen": ["0"]})
    d = shoot_json(srv)
    assert [b["seen"] for b in d["bursts"]] == [True, False]
    assert d["info"]["seen"] == 1 and d["info"]["bursts"] == 2
    assert d["resume"]["burst_id"] == "1" and d["resume"]["kind"] == "left_off"
    assert d["resume"]["note"].startswith("Back where you left off: burst 2 of 2. 1 looked through, 1 to go.")
    # A burst this cull does not have any more: on to the first one he has not
    # been through, and the sentence says what happened.
    post(srv, "/api/review", {"name": "2026-01-01-gym", "at": "44"})
    r = shoot_json(srv)["resume"]
    assert r["kind"] == "moved" and r["burst_id"] == "1"
    assert r["note"].startswith("The burst you were in is not in this cull any more.")


def test_a_burst_the_page_marked_by_scene_is_the_same_burst_to_the_app(srv):
    """The web page records a scene/burst piece. Both pieces of burst 0 marked
    is burst 0 been through, and his verdicts inside it are counted."""
    post(srv, "/api/review", {"name": "2026-01-01-gym", "seen": ["0/0"]})
    d = shoot_json(srv)
    assert d["bursts"][0]["seen"] is False             # one piece of it, not the burst
    post(srv, "/api/review", {"name": "2026-01-01-gym", "seen": ["1/0"]})
    d = shoot_json(srv)
    assert d["bursts"][0]["seen"] is True
    assert d["bursts"][0]["kept"] == 2 and d["bursts"][0]["out"] == 1


# ------------------------------------------------------------ two authors

def test_the_counts_say_whose_they_are(srv):
    post(srv, "/api/rating", {"name": "2026-01-01-gym", "file": "TSC00002.ARW", "rating": 5})
    i = shoot_json(srv)["info"]
    # His, by gather's rule - the one that builds the folder of "the frames
    # you kept": the star he pressed, and the frame beside it in the piece of
    # the burst that star says he was in and left standing. The page counted
    # stars alone and said "you kept 0" of shoots whose folder held 14.
    assert i["kept"] == 2
    assert i["agreed"] == 1                    # walked past, left as the cull had it
    assert i["cull_picks"] == 3                # the cull's shortlist
    assert i["will_be_edited"] == 4            # what gets a sidecar: nobody's opinion on its own
    assert i["keepers"] == i["recorded_keepers"] == 1


def test_agreed_counts_only_the_picks_he_left_standing(srv):
    """The Presets page prints this number as "the cull put forward in bursts
    you looked through and did not mark". It counted every frame he left
    alone, set-asides too - 1,242 on a shoot whose cull had put forward 150,
    beside a headline of 369 that the two lines above it could not add up to.
    A count for the page only: what gets a preset is unchanged."""
    post(srv, "/api/rating", {"name": "2026-01-01-gym", "file": "TSC00003.ARW", "rating": 5})
    i = shoot_json(srv)["info"]
    # TSC00002, beside it, was set aside by the cull and he left it so: not a
    # frame the cull put forward, and not in the sentence.
    assert i["agreed"] == 0
    assert i["kept"] == 1
    assert i["will_be_edited"] == 3                # unchanged by what the page is told


def test_the_exports_are_listed_by_folder_and_only_those_can_be_shown(srv, lib, monkeypatch):
    """Finish printed its folders as one comma-joined sentence nobody could
    open, and Edit showed only export/ - whose Show refused on a shoot whose
    exports were in edit/edited/, PhotoLab's own default."""
    opened = []
    monkeypatch.setattr(studio, "_open", lambda args: opened.append(["open", *args]))
    assert shoot_json(srv)["info"]["export_dirs"] == []
    (lib["gym"] / "export").mkdir()
    (lib["gym"] / "export" / "TSC00001.jpg").write_bytes(b"jpg")
    (lib["gym"] / "edit" / "edited").mkdir(parents=True)
    (lib["gym"] / "edit" / "edited" / "TSC00003.jpg").write_bytes(b"jpg")
    dirs = shoot_json(srv)["info"]["export_dirs"]
    assert dirs == [str(lib["gym"] / "export"), str(lib["gym"] / "edit" / "edited")]
    r = post(srv, "/api/open", {"name": "2026-01-01-gym", "what": "exported", "path": dirs[1]})
    assert r["ok"] is True and opened == [["open", dirs[1]]]
    # Only a folder the shoot's exports were found in.
    for other in (str(lib["gym"] / "raw"), "/", None):
        r = post(srv, "/api/open", {"name": "2026-01-01-gym", "what": "exported", "path": other})
        assert r.get("ok") is False and r["error"][0].isupper()
    assert len(opened) == 1


def test_a_shoot_with_no_editor_of_its_own_says_none(srv, lib):
    """It said "dxo", so the editor he chose in Settings or on the first-run
    sheet was never the one a new shoot started on."""
    assert shoot_json(srv)["info"]["editor"] == ""
    lib["gym"].joinpath("shoot.json").write_text(json.dumps({"editor": "lightroom"}))
    assert shoot_json(srv)["info"]["editor"] == "lightroom"


def test_the_keepers_open_in_the_editor_they_were_written_for(srv, lib, monkeypatch, tmp_path):
    """The button said Open My Keepers in Lightroom Classic and the route
    launched PhotoLab, the only application it ever looked for."""
    import gather
    opened, asked = [], []
    monkeypatch.setattr(studio, "_open", lambda args: opened.append(["open", *args]))
    monkeypatch.setattr(gather, "build_with_summary", lambda folder: (tmp_path / "edit",
                        {"total": 1, "gathered": 1, "missing": 0, "missing_files": []}))
    monkeypatch.setattr(studio, "find_editor", lambda e: asked.append(e) or Path(f"/Applications/{e}.app"))
    post(srv, "/api/open", {"name": "2026-01-01-gym", "what": "photolab", "editor": "lightroom"})
    assert asked == ["lightroom"] and opened == [["open", "-a", "/Applications/lightroom.app", str(tmp_path / "edit")]]
    lib["gym"].joinpath("shoot.json").write_text(json.dumps({"editor": "darktable"}))
    post(srv, "/api/open", {"name": "2026-01-01-gym", "what": "photolab"})
    assert asked[-1] == "darktable"
    monkeypatch.setattr(studio, "find_editor", lambda e: None)
    r = post(srv, "/api/open", {"name": "2026-01-01-gym", "what": "photolab", "editor": "rawtherapee"})
    assert r["note"] == "RawTherapee was not found in Applications, so the folder was opened in Finder."


def _stub_open(where: Path, code: int, said: str = "", wait: float = 0) -> Path:
    """A folder holding an `open` that opens nothing: it writes down what it
    was asked, says `said` on stderr, and stops with `code`."""
    import shlex
    where.mkdir(parents=True, exist_ok=True)
    stub = where / "open"
    stub.write_text("#!/bin/sh\n"
                    f"printf '%s\\n' \"$@\" >> {shlex.quote(str(where / 'asked'))}\n"
                    + (f"sleep {wait}\n" if wait else "")
                    + (f"printf '%s\\n' {shlex.quote(said)} >&2\n" if said else "")
                    + f"exit {code}\n")
    stub.chmod(0o755)
    return where


def test_open_says_why_macos_did_not_open_it(monkeypatch, tmp_path):
    """`open` was started and forgotten, so a refusal from macOS was never
    heard: the page said Opened in PhotoLab over an empty screen."""
    refused = _stub_open(tmp_path / "refused", 1, "The application /Applications/DXOPhotoLab10.app "
                                                  "cannot be opened for an unexpected reason.")
    monkeypatch.setenv("PATH", f"{refused}:/usr/bin:/bin")
    assert studio._open(["-a", "/Applications/DXOPhotoLab10.app", "/shoot/edit"]) == (
        "The application /Applications/DXOPhotoLab10.app cannot be opened for an unexpected reason.")
    assert (refused / "asked").read_text().split() == ["-a", "/Applications/DXOPhotoLab10.app", "/shoot/edit"]

    silent = _stub_open(tmp_path / "silent", 3)
    monkeypatch.setenv("PATH", f"{silent}:/usr/bin:/bin")
    assert studio._open(["/shoot/edit"]) == "open stopped with code 3"

    opened = _stub_open(tmp_path / "opened", 0)
    monkeypatch.setenv("PATH", f"{opened}:/usr/bin:/bin")
    assert studio._open(["/shoot/edit"]) is None

    # No `open` to ask at all.
    monkeypatch.setenv("PATH", str(tmp_path / "nowhere"))
    assert studio._open(["/shoot/edit"]).startswith("macOS could not be asked to open it")


def test_open_timeout_is_a_refusal_and_reaps_the_helper(srv, lib, monkeypatch, tmp_path):
    import gather
    import time

    slow = _stub_open(tmp_path / "slow", 1, "late refusal", wait=2)
    monkeypatch.setenv("PATH", f"{slow}:/usr/bin:/bin")
    monkeypatch.setattr(studio, "OPEN_WAIT", 0.05)
    monkeypatch.setattr(gather, "build_with_summary", lambda folder: (tmp_path / "edit",
                        {"total": 1, "gathered": 1, "missing": 0, "missing_files": []}))
    monkeypatch.setattr(studio, "find_editor", lambda e: Path("/Applications/DXOPhotoLab10.app"))
    children = []
    popen = studio.subprocess.Popen

    def remember(*args, **kwargs):
        child = popen(*args, **kwargs)
        children.append(child)
        return child

    monkeypatch.setattr(studio.subprocess, "Popen", remember)
    started = time.monotonic()
    result = post(srv, "/api/open", {"name": "2026-01-01-gym", "what": "photolab"})
    assert time.monotonic() - started < 1.5  # no wait for the descendant's pipe
    assert result["ok"] is False
    assert "macOS did not confirm opening" in result["error"]
    assert len(children) == 1
    assert children[0].returncode is not None
    assert children[0].stderr.closed


def test_open_cleanup_has_a_deadline_even_when_reaping_is_delayed(monkeypatch):
    import io
    import threading

    released = threading.Event()
    reaping = threading.Event()
    done = threading.Event()

    class DelayedChild:
        stderr = io.StringIO()
        killed = False

        def communicate(self, timeout):
            raise studio.subprocess.TimeoutExpired("open", timeout)

        def kill(self):
            self.killed = True

        def wait(self, timeout=None):
            if timeout is not None:
                assert timeout == studio.OPEN_CLEANUP_WAIT
                raise studio.subprocess.TimeoutExpired("open", timeout)
            reaping.set()
            released.wait(2)
            done.set()
            return -9

    child = DelayedChild()
    monkeypatch.setattr(studio.subprocess, "Popen", lambda *a, **kw: child)
    try:
        assert "did not confirm opening" in studio._open(["/shoot/edit"])
        assert child.killed and child.stderr.closed
        assert reaping.wait(1)
    finally:
        released.set()
        assert done.wait(1)


def test_an_editor_that_does_not_open_is_a_line_on_the_page(srv, lib, monkeypatch, tmp_path):
    """Open My Keepers in PhotoLab answered ok whatever `open` did, so the page
    said it had opened when nothing had. What macOS said is the refusal now,
    and the same for a folder shown in Finder."""
    import gather
    monkeypatch.setattr(gather, "build_with_summary", lambda folder: (tmp_path / "edit",
                        {"total": 1, "gathered": 1, "missing": 0, "missing_files": []}))
    monkeypatch.setattr(studio, "find_editor", lambda e: Path("/Applications/DXOPhotoLab10.app"))
    refused = _stub_open(tmp_path / "bin", 1, "Unable to find application named 'DXOPhotoLab10.app'")
    monkeypatch.setenv("PATH", f"{refused}:/usr/bin:/bin")
    r = post(srv, "/api/open", {"name": "2026-01-01-gym", "what": "photolab"})
    assert r["ok"] is False
    assert r["error"] == "PhotoLab did not open: Unable to find application named 'DXOPhotoLab10.app'"
    assert (refused / "asked").read_text().split() == ["-a", "/Applications/DXOPhotoLab10.app", str(tmp_path / "edit")]

    # With no editor found the folder goes to Finder, and that can fail too.
    monkeypatch.setattr(studio, "find_editor", lambda e: None)
    r = post(srv, "/api/open", {"name": "2026-01-01-gym", "what": "photolab"})
    assert r["ok"] is False and "the folder did not open in Finder either" in r["error"]

    r = post(srv, "/api/open", {"name": "2026-01-01-gym", "what": "raw"})
    assert r["ok"] is False
    assert r["error"] == f"{lib['gym'] / 'raw'} did not open in Finder: Unable to find application named 'DXOPhotoLab10.app'"

    # And one that opens is still just ok.
    opened = _stub_open(tmp_path / "ok", 0)
    monkeypatch.setenv("PATH", f"{opened}:/usr/bin:/bin")
    monkeypatch.setattr(studio, "find_editor", lambda e: Path("/Applications/DXOPhotoLab10.app"))
    r = post(srv, "/api/open", {"name": "2026-01-01-gym", "what": "photolab"})
    assert r == {"ok": True, "folder": str(tmp_path / "edit"), "app": "DXOPhotoLab10.app",
                 "gather": {"total": 1, "gathered": 1, "missing": 0, "missing_files": []}}


def test_recording_keepers_says_where_they_came_from_and_asks_without_a_path(srv, lib):
    """The finish sheet printed the engine's web-page sentence: a path to
    selects.json, a Re-read button that no longer exists, and "delete it by
    hand". And the finished sentence said "the frames you exported" of a
    record that Finish, which records before it marks, had drawn from more."""
    post(srv, "/api/rating", {"name": "2026-01-01-gym", "file": "TSC00003.ARW", "rating": 5})
    r = post(srv, "/api/selects", {"name": "2026-01-01-gym"})
    assert r["n"] >= 1 and r["from"] == "the frames you kept"
    assert shoot_json(srv)["info"]["recorded_from"] == "the frames you kept"
    key = lib["gym"] / "decisions" / "selects.json"
    if not key.exists():
        key = lib["gym"] / "cull" / "selects.json"
    key.write_text(json.dumps([f"TSC{i:05d}.ARW" for i in range(1, 11)]))
    meta = lib["gym"] / "shoot.json"
    meta.write_text(json.dumps({**(json.loads(meta.read_text()) if meta.exists() else {}), "finished": "2026-09-22"}))
    r = post(srv, "/api/selects", {"name": "2026-01-01-gym"})
    assert r["confirm"] is True
    assert r["error"].startswith("Not recorded: this finished shoot's keeper list holds 10 frames")
    assert "selects.json" not in r["error"] and "Re-read" not in r["error"] and "by hand" not in r["error"]
    assert shoot_json(srv)["info"]["finished_on"] == "2026-09-22"


def test_where_the_keepers_came_from_is_read_off_the_record(lib):
    """A shoot finished before the record said where it came from read "the
    frames you exported" over 368 keepers beside 356 exports: the words were
    the rule for a finished shoot, not what the record holds."""
    ex = {"A", "B", "C"}
    assert studio._recorded_from({"A", "B"}, ex) == "the frames you exported"
    assert studio._recorded_from({"A", "B", "Z"}, ex) == "the frames you exported and the ones you kept"
    assert studio._recorded_from({"Z"}, ex) == "the frames you kept"
    assert studio._recorded_from(set(), ex) == "the frames you kept"


def test_an_editor_installed_in_its_own_folder_is_found(tmp_path, monkeypatch):
    """Adobe puts Lightroom Classic one folder down, and Open said it was not
    in Applications while the Presets page said it was installed."""
    monkeypatch.setattr(studio.Path, "home", staticmethod(lambda: tmp_path))
    app = tmp_path / "Applications" / "Adobe Lightroom Classic" / "Adobe Lightroom Classic.app"
    app.mkdir(parents=True)
    (tmp_path / "Applications" / "Other.app" / "Adobe Lightroom Classic.app").mkdir(parents=True)
    found = studio.find_editor("lightroom")
    assert found is not None and found.name == "Adobe Lightroom Classic.app"
    assert found.parent.name != "Other.app"            # never inside another application


def test_the_presets_card_says_what_the_run_did_not_what_is_on_disk(srv, lib):
    """A re-run without force writes nothing, and the page counted the
    sidecars lying on the disk and said "12 presets written onto 368 files".
    What the run did is read off its own log, as presets.py prints it for him,
    and the left_alone list presets.json has always carried: presets.json is
    not asked to say anything more."""
    import os
    assert shoot_json(srv)["info"]["presets_ran"] is None                 # no run yet
    runs = [{"name": "Cull 01 people shade 1748 (23)", "left_alone": []},
            {"name": "Cull 02 people tungsten 1954 (9)", "left_alone": ["TSC00001", "TSC00002"]}]
    pj = lib["gym"] / "cull" / "presets.json"
    pj.write_text(json.dumps(runs))
    log = lib["gym"] / "cull" / "logs" / "presets.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    run = ("$ python presets.py /x/raw --out /x/cull --dop --picks-only --editor dxo\n"
           "@@ presets 0 3\n@@ presets 2 3\n"
           "  23 of 23 frames already carry a sidecar: left as they are (--force refreshes them)\n"
           "  Cull 01 people shade 1748 (23): combat sport; open shade; 0 sidecars\n"
           "  4 of 9 frames already carry a sidecar: left as they are (--force refreshes them)\n"
           "  Cull 02 people tungsten 1954 (9): combat sport; tungsten; 5 sidecars\n"
           "@@ presets 3 3\n")
    log.write_text(run)
    assert shoot_json(srv)["info"]["presets_ran"] == {"wrote": 5, "changed": 2, "already": 25, "under": 0}
    # Write Them Again: every frame is written, his own edits kept on top of
    # the new starting edit, and the log says how many of those there were.
    forced = run.replace("--picks-only", "--force --picks-only").replace(
        "  23 of 23 frames already carry a sidecar: left as they are (--force refreshes them)\n", "").replace(
        "  4 of 9 frames already carry a sidecar: left as they are (--force refreshes them)\n",
        "  1 sidecar carries your own edits: it was kept, with the starting edit under it refreshed\n"
        "  2 sidecars carry your own edits: those were kept, with the starting edit under them refreshed\n").replace(
        "; 0 sidecars", "; 23 sidecars").replace("; 5 sidecars", "; 9 sidecars")
    log.write_text(forced)
    pj.write_text(json.dumps([{**r, "left_alone": []} for r in runs]))
    assert shoot_json(srv)["info"]["presets_ran"] == {"wrote": 32, "changed": 0, "already": 0, "under": 3}
    pj.write_text(json.dumps(runs))
    # A run that did not reach its end says nothing about what it did.
    log.write_text(run.replace("@@ presets 3 3\n", ""))
    assert shoot_json(srv)["info"]["presets_ran"] is None
    # Nor does the log of a run from before a cull wrote the presets again.
    log.write_text(run)
    os.utime(log, (pj.stat().st_mtime - 600, pj.stat().st_mtime - 600))
    assert shoot_json(srv)["info"]["presets_ran"] is None
    # Another editor's run does not say what it skipped, so the page counts the disk.
    log.write_text(run.replace("--editor dxo", "--editor lightroom"))
    assert shoot_json(srv)["info"]["presets_ran"] is None
    # And a look the log does not name is not this run.
    log.write_text(run.replace("Cull 02", "Cull 07"))
    assert shoot_json(srv)["info"]["presets_ran"] is None


def test_no_storage_sheet_tells_him_to_pass_a_flag():
    """Every storage sheet ended with the command line's footer right above
    the button that does the job: "nothing was removed. Add --apply to remove
    exactly this." beside a red Remove. Each footer the storage commands can
    print is read out of their source, so a new one cannot slip past."""
    import re as _re
    here = Path(__file__).resolve().parents[1] / "pipeline"
    printed = []
    for name in ("archive.py", "reclaim.py"):
        for m in _re.finditer(r'print\(f?"((?:\\n)?\s*[^"]*--[a-z][^"]*)"\)', (here / name).read_text()):
            printed.append(m.group(1).replace("\\n", "").replace("{new}", "12").replace("{age}", "30")
                           .replace("{MANIFEST_NAME}", "checksums.sha256"))
    # Not what a storage verb the app runs can print: the self-test's headings
    # and the usage lines of a command run with no shoot.
    terminal = ("nothing goes without", "--apply, on the", "--gone needs", "which shoot?")
    printed = [p for p in printed if not p.strip().startswith(terminal)]
    assert len(printed) >= 8
    for line in printed:
        said = studio.plan_words(line)
        assert said is None or ("--" not in said and "studio" not in said), line
    assert studio.plan_words("  Those are left alone. Add --yes-delete-originals to include them.") == \
        '  Those are left alone. Tick "Including the frames with no other copy" to include them.'
    assert studio.plan_words("  would remove 4 files from iCloud, 96 MB") == "  would remove 4 files from iCloud, 96 MB"


def test_the_storage_line_groups_its_digits_and_says_one_copy_once():
    """It read "1558 originals · 36.3 GB here · nothing in iCloud · one copy."
    over a row reading 1,558 and "on this Mac only — one copy"."""
    sm = {"frames": 1558, "here": 1558, "up": 0, "up_evicted": 0, "bytes_here": 36_300_000_000, "bytes_up": 0}
    counts = {"missing": 0, "unreadable": 0, "evicted": 0, "here_evicted": 0}
    line = studio._stor_line(sm, counts, 0)
    assert line.startswith("1,558 originals · ") and line.endswith("nothing in iCloud")
    assert "one copy" not in line
    half = dict(sm, up=779, bytes_up=18_000_000_000)
    assert studio._stor_line(half, counts, 0, 1600).endswith("779 of 1,558 in iCloud.")
    assert studio._stor_line(half, counts, 0, 1600).startswith("1,558 originals of 1,600 frames")
    # Nothing in iCloud and not every original here: the line keeps a verdict.
    short = dict(sm, here=1200, bytes_here=28_000_000_000)
    assert studio._stor_line(short, counts, 0).endswith("nothing in iCloud · 1,200 of 1,558 on this Mac.")


def test_a_refusal_reads_as_a_sentence_but_a_shoot_keeps_its_name(lib):
    """The app prints the engine's refusals where every other sentence is
    capitalised; they were written to follow a word of the web page's own."""
    assert studio.sentence_case("the engine did not answer in time") == "The engine did not answer in time"
    assert studio.sentence_case("that shoot's folder is not there any more") == "That shoot's folder is not there any more"
    for kept in ("2026-01-01-gym already exists", "/Volumes/x is not a card", "ducksAndDeadlifts is not culled", ""):
        assert studio.sentence_case(kept) == kept
    (lib["root"] / "shoots" / "lake").mkdir()
    assert studio.sentence_case("lake already exists") == "lake already exists"
    # The whole first word: a hyphenated name is a name, even one that is not a shoot yet.
    for kept in ("lake-night already exists", "lake_2 is not culled", "night2 has no frames",
                 "ffmpeg was not found", "darktable was not found in Applications"):
        assert studio.sentence_case(kept) == kept
    assert studio.sentence_case("nothing exported or kept yet.") == "Nothing exported or kept yet."
    assert studio.sentence_case("cull the shoot first: nothing here yet") == "Cull the shoot first: nothing here yet"


def test_a_reel_tile_can_be_asked_for_at_the_size_of_a_large_view(srv, lib, monkeypatch, tmp_path):
    """Space on a reel tile showed the camera's JPEG, then the unedited RAW:
    not the export the tile shows and the reel is cut from. The export itself
    can now be had at the large view's size, clamped, and kept per size."""
    import types
    import cv2
    import numpy as np
    export = tmp_path / "TSC00001_DxO.jpg"
    cv2.imwrite(str(export), np.full((3000, 2000, 3), 128, np.uint8))
    fake = types.SimpleNamespace(exports=lambda folder, src: {"TSC00001": export}, decodes=lambda folder, rows: {})
    monkeypatch.setattr(studio, "_reel_mod", lambda: fake)

    def size(q=""):
        status, body = get(srv, f"/reelthumb/2026-01-01-gym/TSC00001.jpg{q}")
        assert status == 200
        return cv2.imdecode(np.frombuffer(body, np.uint8), cv2.IMREAD_COLOR).shape[:2]
    assert size() == (400, 266)
    assert size("?px=1600") == (1600, 1066)
    assert size("?px=99999") == (2400, 1600)                   # clamped
    assert size("?px=nonsense") == (400, 266)
    assert (lib["gym"] / "cull" / "reelthumbs" / "1600" / "TSC00001.jpg").exists()


def test_the_cull_summary_talks_about_stacks_and_not_duplicates(srv):
    c = shoot_json(srv)["info"]["cull_summary"]
    assert c["stacked"] is True and c["stacks"] == 1 and c["under_tops"] == 1 and c["duplicates"] == 0
    assert "stacked 2 frames that look alike into 1 stack" in c["line"]
    assert "Nothing was hidden for looking alike" in c["line"] and "duplicate" not in c["line"]


# ---------------------------------------------------------------- the steps

def test_the_steps_are_one_table_with_a_reason_for_every_one_that_is_shut(srv, lib, monkeypatch):
    steps = {s["id"]: s for s in shoot_json(srv)["steps"]}
    assert steps["cull"]["done"] and steps["cull"]["enabled"] and steps["cull"]["source"] == "base"
    assert steps["keepers"]["done"] is False and steps["keepers"]["label"] == "Choose Keepers"
    # A shoot with nothing in it: the cull cannot start, and says why.
    (lib["root"] / "shoots" / "empty" / "raw").mkdir(parents=True)
    steps = {s["id"]: s for s in shoot_json(srv, "empty")["steps"]}
    assert steps["cull"]["enabled"] is False and "copy the card first" in steps["cull"]["why_disabled"]
    assert steps["keepers"]["enabled"] is False and steps["keepers"]["why_disabled"] == "Cull the shoot first."


def test_the_steps_are_called_what_the_app_calls_them(srv, lib):
    """The engine's names were sentence case and ended in Done; the app's, in
    DESIGN.md §2.4 and the Keyboard Shortcuts window, are Title Case and end
    in Finish, so a shoot's rows re-lettered as it loaded. Read from the app's
    own source so the two cannot drift apart again."""
    import re as _re
    swift = (Path(__file__).resolve().parents[1] / "app" / "Sources" / "PipelineKit" / "Design"
             / "Strings.swift").read_text()
    app = dict(_re.findall(r's\("step\.(\w+)", "([^"]+)", "Step name\."\)', swift))
    ids = {"ingest": "ingest", "cull": "cull", "keepers": "keepers", "presets": "presets",
           "edit": "edit", "instagram": "instagram", "reels": "reels", "done": "done"}
    assert {k: app[v] for k, v in ids.items()} == studio.STEP_LABELS
    labels = {s["id"]: s["label"] for s in shoot_json(srv)["steps"]}
    assert labels["done"] == "Finish" and labels["ingest"] == "Copy the Card"
    lib["gym"].joinpath("shoot.json").write_text(json.dumps({"editor": "lightroom"}))
    assert {s["id"]: s["label"] for s in shoot_json(srv)["steps"]}["edit"] == "Edit in Lightroom Classic"


def test_a_copy_that_stopped_is_not_a_copied_card(srv, lib):
    """A card pulled at 412 of 1,558 left a shoot the step list called copied,
    with Cull as the only way on. Its own log says it stopped."""
    assert {s["id"]: s for s in shoot_json(srv)["steps"]}["ingest"]["done"] is True   # no log: its frames
    (lib["gym"] / "logs").mkdir()
    log = lib["gym"] / "logs" / "ingest.log"
    log.write_text("$ python ingest.py /Volumes/Untitled 2026-01-01-gym\ncopying 9 files, 0.1 GB\n@@ copy 5 9\n")
    steps = {s["id"]: s for s in shoot_json(srv)["steps"]}
    assert steps["ingest"]["done"] is False
    assert steps["cull"]["enabled"] is True          # the frames that did arrive can still be culled
    log.write_text(log.read_text() + "9 files in /x/raw, verified byte for byte\n")
    assert {s["id"]: s for s in shoot_json(srv)["steps"]}["ingest"]["done"] is True


def test_the_reels_step_is_absent_where_nothing_can_encode_a_reel(srv, monkeypatch):
    monkeypatch.setattr(studio, "can_cut_reels", lambda: False)
    d = shoot_json(srv)
    assert d["info"]["can_cut_reels"] is False
    assert "reels" not in [s["id"] for s in d["steps"]]


def test_every_row_of_the_library_carries_the_steps_its_own_page_does(srv, lib):
    """All Shoots says where each shoot is up to, and a click on a shoot never
    opened goes to its next step: both read the one table the shoot's own
    page reads, sent on its row, rather than a copy of the rules in the app."""
    (lib["root"] / "shoots" / "empty" / "raw").mkdir(parents=True)
    rows = {r["name"]: r for r in json.loads(get(srv, "/api/shoots")[1])["shoots"]}
    for name in ("2026-01-01-gym", "empty"):
        assert rows[name]["steps"] == shoot_json(srv, name)["steps"]
    gym = {s["id"]: s for s in rows["2026-01-01-gym"]["steps"]}
    assert gym["cull"]["done"] and not gym["keepers"]["done"]
    # The first step not done that can be started is where the gym is up to.
    up_to = next(s["id"] for s in rows["2026-01-01-gym"]["steps"] if not s["done"] and s["enabled"])
    assert up_to == "keepers"
    assert next(s["id"] for s in rows["empty"]["steps"] if not s["done"] and s["enabled"]) == "ingest"


def test_a_shoot_whose_steps_cannot_be_worked_out_costs_its_up_to_and_not_the_list(srv, lib, monkeypatch):
    """The steps on each row are worked out per shoot, and one shoot whose
    steps raise - a rule reading a key its info lacks, or an extension's
    table - must cost that row its Up to, not every row: the whole list
    failing is All Shoots and the sidebar saying the shoots could not be
    read."""
    (lib["root"] / "shoots" / "empty" / "raw").mkdir(parents=True)
    real = studio.Shoot.steps

    def steps(self, info):
        if self.folder.name == "empty":
            raise KeyError("frames")
        return real(self, info)

    monkeypatch.setattr(studio.Shoot, "steps", steps)
    status, body = get(srv, "/api/shoots")
    assert status == 200
    rows = {r["name"]: r for r in json.loads(body)["shoots"]}
    assert rows["empty"]["steps"] is None
    assert "broken" not in rows["empty"]
    assert rows["2026-01-01-gym"]["steps"] == shoot_json(srv, "2026-01-01-gym")["steps"]


def test_the_spread_says_it_writes_the_shoots_preset_and_does_not_promise_his_edit(lib, monkeypatch, tmp_path):
    # The Reels step's button once said it would put his edit on the whole
    # burst. The command passes --standard, which spread.py's own help says
    # does not copy an edit of his, so the sentence the list of work shows
    # has to say what the command does.
    here = tmp_path / "bin"
    here.mkdir()
    (here / "spread.py").write_text("")
    monkeypatch.setattr(studio, "HERE", here)
    made = studio._b_spread("2026-01-01-gym", {"burst": "1"})
    assert "--standard" in made["cmd"] and "--open" in made["cmd"]
    assert "preset" in made["does"] and "not edited" in made["does"]
    assert "your edit" not in made["does"]


def test_a_storage_plan_on_the_list_says_what_it_checks(lib):
    # Up Next names a plan for what it checks - "Check what would be copied"
    # - and printed the engine's sentence under it, which for all five was
    # "Work out what would go, and show you the list": under a copy to
    # iCloud, the opposite of the row it sat in.
    said = {what: studio._b_plan(what)("2026-01-01-gym", {})["does"] for what in studio.STOR_VERBS}
    assert set(said) == set(studio.PLAN_DOES)
    assert len(set(said.values())) == len(said), "each plan says its own sentence"
    for what, does in said.items():
        assert does.startswith("Check "), (what, does)
        assert "what would go" not in does and "the list" not in does, (what, does)
    assert "copied to iCloud" in said["push"]
    assert "come back" in said["pull"]
    assert "removed" in said["drop"]


# --------------------------------------------------------------- the frames

def _decoded(shoot: Path, stem: str, w: int, h: int) -> Path:
    from PIL import Image
    p = shoot / "cull" / "decoded" / f"{stem}.jpg"
    p.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", (w, h), (40, 90, 140)).save(p, "JPEG")
    return p


def test_full_is_served_at_the_size_asked_for_and_kept_per_size(srv, lib):
    from PIL import Image
    _decoded(lib["gym"], "TSC00001", 4000, 1000)
    status, body = get(srv, "/full/2026-01-01-gym/TSC00001.jpg?px=1024")
    assert status == 200
    import io
    assert max(Image.open(io.BytesIO(body)).size) == 1024
    assert (lib["gym"] / "cull" / "full" / "1024" / "TSC00001.jpg").exists()
    # No px is the size the page has always been served, in the folder it has
    # always been kept in.
    status, body = get(srv, "/full/2026-01-01-gym/TSC00001.jpg")
    assert max(Image.open(io.BytesIO(body)).size) == studio.FULL_PX
    assert (lib["gym"] / "cull" / "full" / "TSC00001.jpg").exists()
    # A size between two tiers is served the next one up, so a window dragged
    # across the screen does not mint a file per pixel.
    assert studio.Handler._full_px({"px": ["1100"]}) == 1600
    assert studio.Handler._full_px({"px": ["99999"]}) == 4096
    assert studio.Handler._full_px({}) == studio.FULL_PX


def test_a_crop_may_be_the_whole_frame_of_a_big_display(srv, lib):
    """1:1 on a 5K viewport is 5056 px wide and the camera's own long edge is
    6000; the clamp was 3000, so a 1:1 check on the big screen was not 1:1."""
    import io
    from PIL import Image
    _decoded(lib["gym"], "TSC00005", 6000, 4000)
    assert studio.CROP_MAX_PX == 6144
    status, body = get(srv, "/crop/2026-01-01-gym/TSC00005.jpg?px=6000&ar=0.6666&cx=0.5&cy=0.5")
    assert status == 200
    assert Image.open(io.BytesIO(body)).size == (6000, 4000)


def test_a_frame_he_is_about_to_open_is_decoded_before_he_asks(srv, lib):
    """The hint is answered at once and the decoding happens behind it."""
    seen: list = []
    orig = studio.Handler._decoded

    def spy(s, stem):
        seen.append(stem)
        return orig(s, stem)

    studio.Handler._decoded = staticmethod(spy)
    try:
        assert post(srv, "/api/prefetch", {"name": "2026-01-01-gym", "stems": ["TSC00001", "../etc/passwd"]}) == \
            {"ok": True, "warming": 1}
        for _ in range(200):
            if seen:
                break
            import time
            time.sleep(0.01)
        assert seen == ["TSC00001"]
    finally:
        studio.Handler._decoded = orig


def test_two_requests_for_one_cold_frame_decode_it_once(lib, monkeypatch):
    """Both used to pay the full 650 ms and write the same file over each
    other as it landed."""
    import time
    calls = []

    def slow(raw, out, full=True):
        calls.append(out)
        time.sleep(0.3)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(b"decoded")
        return object()

    import faces
    monkeypatch.setattr(faces, "decode_to_file", slow)
    s = studio.Shoot(lib["gym"])
    (lib["gym"] / "raw" / "TSC00001.ARW").rename(lib["gym"] / "raw" / "TSC00001.ARW")
    out: list = []
    threads = [threading.Thread(target=lambda: out.append(studio.Handler._decoded(s, "TSC00001"))) for _ in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert len(calls) == 1 and out[0] == out[1] and out[0].read_bytes() == b"decoded"


# ------------------------------------------------------------- long jobs

def test_a_second_job_can_wait_its_turn_instead_of_being_refused(srv, lib):
    jobs = studio.Handler.jobs
    log = lib["root"] / "one.log"
    assert jobs.start("cull", "first", [sys.executable, "-c", "import time; time.sleep(3)"], log)
    first = jobs.status()
    assert first["running"] and first["id"] == 1 and first["queued"] is False
    jid, started = jobs.enqueue("cull", "second", [sys.executable, "-c", "print(1)"], lib["root"] / "two.log")
    assert (jid, started) == (2, False)
    st = jobs.status()
    assert st["queued"] is True and len(st["queue"]) == 1
    # A row says what it is, whose shoot it is about and whether it could
    # still be done. `kept` is false here on purpose: this one carries a
    # command this process built and nothing to rebuild it from, so it is
    # honestly not written down to survive a restart. `opts` is what it was
    # asked for with, which a page shows while it waits; this one was built
    # as a command, and was asked for with nothing. `interrupted` is only
    # ever true on work a crash cut off and the next engine put back.
    assert st["queue"][0] == {"id": 2, "kind": "cull", "title": "second", "shoot": "",
                              "does": "", "why": "", "kept": False, "opts": {},
                              "interrupted": False, "ready": True, "why_not": ""}
    # And it can be taken out of the line again before it starts.
    assert jobs.cancel(2) is True and jobs.status()["queued"] is False
    assert jobs.cancel(2) is False
    jobs.stop()


def test_the_update_card_never_shows_a_decoder_error(monkeypatch):
    monkeypatch.setattr(studio, "APP", True)
    monkeypatch.setattr(studio.subprocess, "run", lambda *a, **k: (_ for _ in ()).throw(OSError("no such file")))
    studio.check_for_update()
    assert studio.UPDATE["error"] == "the update check did not answer"


def test_the_check_at_launch_is_his_to_turn_off(monkeypatch):
    """"Check for updates automatically" switched off used to change nothing:
    the engine asked GitHub at every launch. The app now says so in the
    environment, and a check he asks for from the menu still runs."""
    monkeypatch.setattr(studio, "APP", True)
    monkeypatch.delenv("PIPELINE_NO_UPDATE_CHECK", raising=False)
    assert studio.checks_at_start()
    monkeypatch.setenv("PIPELINE_NO_UPDATE_CHECK", "1")
    assert not studio.checks_at_start()
    monkeypatch.setattr(studio, "APP", False)
    monkeypatch.delenv("PIPELINE_NO_UPDATE_CHECK")
    assert not studio.checks_at_start()


def test_a_finished_download_is_seen_without_asking_github_again(srv, tmp_path, monkeypatch):
    """The download is a job; when it ends the app looks again to offer
    Install. That look reads the folder the build was staged in, and never
    runs update.py - a forced check would ask GitHub a second time."""
    monkeypatch.setenv("PIPELINE_SUPPORT", str(tmp_path / "support"))
    monkeypatch.setattr(studio, "UPDATE", {"newer": True, "current": "1.1", "latest": "1.2",
                                           "url": "https://github.com/x/a.dmg", "staged": False})
    monkeypatch.setattr(studio.subprocess, "run",
                        lambda *a, **k: (_ for _ in ()).throw(AssertionError("asked GitHub again")))
    assert json.loads(get(srv, "/api/update")[1])["staged"] is False
    # Where update.py stages it, under the app's new name.
    assert studio.staged_update() == tmp_path / "support" / "updates" / "staged" / "First Edit.app"
    studio.staged_update().mkdir(parents=True)
    assert json.loads(get(srv, "/api/update")[1])["staged"] is True


def test_a_studio_from_a_checkout_never_installs_the_apps_staged_update(srv, tmp_path, monkeypatch):
    """A checkout's studio finds the app's support folder through the same
    resolver, so it can see a build the app staged. Asked to install it, it
    would pass its own parent - a shell - to update.py as the app to wait for
    and swap. Only the app's engine installs."""
    monkeypatch.setenv("PIPELINE_SUPPORT", str(tmp_path / "support"))
    studio.staged_update().mkdir(parents=True)
    started = []
    monkeypatch.setattr(studio.subprocess, "Popen", lambda *a, **k: started.append(a))
    monkeypatch.setattr(studio, "APP", False)
    assert post(srv, "/api/update/install", {}) == {"error": "Only the app installs an update"}
    assert started == []
    assert studio.staged_update().exists()


def test_a_copy_that_was_refused_does_not_take_the_name(srv, lib):
    """The log's folder was made before the copy was, so a card with nothing
    on it left a shoot behind and the next attempt was told the name existed."""
    left = lib["root"] / "shoots" / "2026-02-02-new"
    (left / "cull" / "logs").mkdir(parents=True)
    (left / "cull" / "logs" / "ingest.log").write_text("$ ingest.py\n")
    (left / "shoot.json").write_text("{}")
    assert studio._refused_copy(left) is True
    (left / "raw").mkdir()
    (left / "raw" / "TSC00009.ARW").write_bytes(b"raw")
    assert studio._refused_copy(left) is False


def test_a_decode_lands_whole_or_not_at_all(tmp_path, monkeypatch):
    """decode_to_file wrote straight to the name everything else tests for,
    so two overlapping writers could leave half a frame under it - and the
    temp file has to keep the .jpg, or cv2 has no encoder for it and every
    decode fails."""
    import faces
    import numpy as np
    out = tmp_path / "cull" / "decoded" / "TSC00001.jpg"
    monkeypatch.setattr(faces, "FULL", True)
    monkeypatch.setattr(faces, "cv2", faces.cv2)
    monkeypatch.setattr(faces, "_decode_raw", None, raising=False)
    img = np.zeros((6, 8, 3), dtype="uint8")

    class FakeRaw:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def postprocess(self, **kw):
            return img

    monkeypatch.setitem(sys.modules, "rawpy", type("M", (), {"imread": staticmethod(lambda p: FakeRaw())}))
    assert faces.decode_to_file(tmp_path / "TSC00001.ARW", out) is not None
    assert out.exists() and out.stat().st_size > 0
    assert [p.name for p in out.parent.iterdir()] == ["TSC00001.jpg"], "no temp file left behind"


def test_a_served_frame_is_plain_srgb(srv, lib):
    """Nothing in the viewer's path tags a profile, and the app draws what it
    is given as sRGB. A frame that arrived carrying another profile would be
    drawn wrong on the second screen and nowhere would say so."""
    import io
    from PIL import Image
    _decoded(lib["gym"], "TSC00001", 1200, 800)
    for path in ("/full/2026-01-01-gym/TSC00001.jpg?px=1024",
                 "/crop/2026-01-01-gym/TSC00001.jpg?px=600&ar=0.75"):
        status, body = get(srv, path)
        assert status == 200
        im = Image.open(io.BytesIO(body))
        assert im.mode == "RGB" and im.format == "JPEG"
        assert not im.info.get("icc_profile"), f"{path} carries a colour profile"


def _idle(jobs, tries: int = 100) -> None:
    """Stop whatever is running and wait for the slot to be free: start()
    refuses while the last child is still on its way out."""
    import time as _t
    jobs.clear()
    jobs.stop()
    for _ in range(tries):
        if not jobs.status()["running"]:
            return
        _t.sleep(0.05)
    raise AssertionError("the job slot never came free")


def test_finishing_writes_down_what_he_exported_and_leaves_his_keepers_as_they_are(srv, lib, monkeypatch):
    """Finish records his keepers exactly as before - the answer key every
    check measures against - and writes down the frames he exported beside
    them, which are what the shoot teaches. The page gets both numbers."""
    import learned
    monkeypatch.setattr(studio, "learned_start", lambda jobs, why, shoot="": {"ok": True, "queued": False})
    gym = lib["gym"]
    (gym / "export").mkdir()
    for stem in ("TSC00001", "TSC00005"):
        (gym / "export" / f"{stem}_DxO.jpg").write_bytes(b"jpg")
    (gym / "cull" / "organize.json").write_text(json.dumps(
        {"photos": {"TSC00003.ARW": {"rating": 5}}}))       # kept, never exported
    r = post(srv, "/api/selects", {"name": "2026-01-01-gym"})
    assert r["n"] == 3, r
    key = studio.decision_path(gym / "cull", "selects.json")
    recorded = json.loads(key.read_text())
    out = post(srv, "/api/kind", {"name": "2026-01-01-gym", "finished": True})
    assert out["ok"] is True
    assert json.loads(key.read_text()) == recorded, "Finish must not touch the answer key"
    written = studio.decision_path(gym / "cull", learned.EXPORTS_KEPT)
    assert json.loads(written.read_text()) == ["TSC00001.ARW", "TSC00005.ARW"]
    info = shoot_json(srv)["info"]
    assert info["recorded_keepers"] == 3
    assert info["taught"] == 2 and info["taught_from"] == "exported"

    # An export that goes out of reach afterwards is still what it teaches.
    (gym / "export" / "TSC00005_DxO.jpg").unlink()
    learned._EXPORTED.clear()
    info = shoot_json(srv)["info"]
    assert info["exported"] == 1 and info["taught"] == 2


def test_marking_a_shoot_finished_is_what_starts_the_learning(srv, lib, monkeypatch, tmp_path):
    """The one thing that teaches is a shoot he has finished, so the run is
    asked for there and not by a button he has to know to press. It waits its
    turn rather than pushing a cull aside."""
    import learned
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    monkeypatch.setattr(learned, "_FOLDER", None, raising=False)
    seen: list[str] = []
    monkeypatch.setattr(learned, "request_run", lambda why, shoot="": seen.append(why))

    out = post(srv, "/api/kind", {"name": "2026-01-01-gym", "finished": True})
    assert out["learning"]["ok"] is True and out["learning"]["running"] is True
    # And it says which shoot, in the words the learning screen uses.
    assert out["learning"]["title"] == "Learning from 2026-01-01-gym"
    assert seen == [None]                        # running now, nothing left waiting
    assert studio.Handler.jobs.status()["kind"] == studio.LEARN_KIND
    _idle(studio.Handler.jobs)

    # With the one slot busy, the run is remembered instead of refused, and
    # the cull that is running is left alone.
    jobs = studio.Handler.jobs
    assert jobs.start("cull", "first", [sys.executable, "-c", "import time; time.sleep(3)"], lib["root"] / "one.log")
    out = post(srv, "/api/kind", {"name": "2026-01-01-gym", "finished": True})
    assert out["learning"]["ok"] is True and out["learning"]["running"] is False
    assert out["learning"]["queued"] is True
    # In the page's own words: it prints this under "Finished. Your …".
    assert out["learning"]["note"] == studio.LEARNING_WAITS_FOR_SLOT
    assert seen[-1].startswith("you finished ")
    assert jobs.status()["title"] == "first"
    _idle(jobs)


def _asks(monkeypatch):
    """learned's ask on disk, as a list: what request_run was last told."""
    import learned
    state: dict = {"queued": None}

    def request_run(why, shoot=""):
        state["queued"] = {"why": why, "shoot": shoot} if why else None
        return {"queued": bool(why)}
    monkeypatch.setattr(learned, "request_run", request_run)
    monkeypatch.setattr(learned, "manifest", lambda: {"queued": state["queued"]})
    return state


def test_with_automatic_learning_off_finishing_a_shoot_learns_nothing(srv, lib, monkeypatch):
    """Settings ▸ Learning ▸ "Learn from finished shoots automatically" was
    read by nothing: he turned it off and the next Finish started a run."""
    state = _asks(monkeypatch)
    started: list[str] = []
    monkeypatch.setattr(studio, "learned_start", lambda j, why, shoot="": started.append(why) or {"ok": True})
    monkeypatch.setitem(studio.LEARN_PREFS, "auto", False)
    out = post(srv, "/api/kind", {"name": "2026-01-01-gym", "finished": True})
    assert out["learning"] == {"ok": True, "running": False, "queued": False, "off": True}
    assert started == [] and state["queued"] is None
    # A finished shoot's ask left from before is taken back, not run...
    state["queued"] = {"why": "you finished 2026-01-01-gym", "shoot": "2026-01-01-gym"}
    studio.Handler.jobs._pick_up_learning()
    assert started == [] and state["queued"] is None
    # ...while his own Learn Now, stood down for his work, still comes back.
    state["queued"] = {"why": "Learn now", "shoot": ""}
    studio.Handler.jobs._pick_up_learning()
    assert started == ["Learn now"]


def test_only_when_idle_waits_for_the_mac_to_be_left_alone(srv, lib, monkeypatch):
    """"Only when the Mac is idle" was read by nothing either: a cull ending
    was enough to start learning two minutes later under his hands in Choose
    Keepers. It waits for two minutes with no key and no pointer now."""
    state = _asks(monkeypatch)
    started: list[str] = []
    monkeypatch.setattr(studio, "learned_start", lambda j, why, shoot="": started.append(why) or {"ok": True})
    monkeypatch.setitem(studio.LEARN_PREFS, "idle_only", True)
    idle = {"s": 4.0}
    monkeypatch.setattr(studio, "mac_idle_seconds", lambda: idle["s"])
    armed: list[float] = []
    jobs = studio.Handler.jobs
    monkeypatch.setattr(jobs, "_arm_pickup", lambda d: armed.append(d))

    out = post(srv, "/api/kind", {"name": "2026-01-01-gym", "finished": True})
    assert out["learning"]["running"] is False and out["learning"]["queued"] is True
    assert out["learning"]["note"] == studio.LEARNING_WAITS_FOR_IDLE
    assert state["queued"]["why"] == "you finished 2026-01-01-gym"
    assert started == []
    # It looks again when two minutes of quiet could have passed.
    assert armed and abs(armed[-1] - (studio.LEARN_RESUME_QUIET - 4.0)) < 0.01

    idle["s"] = studio.LEARN_RESUME_QUIET + 1
    jobs._pick_up_learning()
    assert started == ["you finished 2026-01-01-gym"]

    # A Mac whose idle time cannot be read is not held back for ever.
    started.clear()
    idle["s"] = None
    jobs._pick_up_learning()
    assert started == ["you finished 2026-01-01-gym"]


def test_the_learning_switches_reach_the_engine_without_a_restart(srv, monkeypatch):
    monkeypatch.setitem(studio.LEARN_PREFS, "auto", True)
    monkeypatch.setitem(studio.LEARN_PREFS, "idle_only", False)
    _asks(monkeypatch)
    out = post(srv, "/api/learned/settings", {"auto": False, "idle_only": True})
    assert out == {"ok": True, "auto": False, "idle_only": True}
    assert studio.LEARN_PREFS == {"auto": False, "idle_only": True}
    # Nonsense changes nothing.
    assert post(srv, "/api/learned/settings", {"auto": "yes"})["auto"] is False


def test_measure_is_the_command_the_learning_page_used_to_ask_him_to_type(srv, lib, monkeypatch, tmp_path):
    """"2026-09-16 has no picture vectors kept; ./pl learned vectors
    2026-09-16 measures them" - a terminal command, on a page in an app. The
    page has a Measure button now, and this is what it starts: his job, with
    a bar and a Stop, reading the shoot's previews and nothing else."""
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    started: list[tuple] = []
    jobs = studio.Handler.jobs
    monkeypatch.setattr(jobs, "start", lambda kind, title, cmd, log, shoot="", **k: started.append(
        (kind, title, cmd, log, shoot)) or True)
    out = post(srv, "/api/learned/vectors", {"shoot": "2026-01-01-gym"})
    assert out["ok"] is True and out["title"] == "measuring the picture vectors of 2026-01-01-gym"
    kind, title, cmd, log, shoot = started[0]
    assert kind == studio.VECTORS_KIND and kind not in studio.BACKGROUND_KINDS
    assert cmd[1].endswith("learned.py") and cmd[2:] == ["vectors", str(lib["gym"])]
    assert shoot == "2026-01-01-gym" and log.name == "vectors.log"
    # Its bar is its own one stage, in words.
    assert studio.STOR_WEIGHTS["vectors"] == {"vectors": 100}
    assert studio.STAGE_WORDS["vectors"][0] == "measuring the picture vectors"
    # A shoot that is not there is said so, and nothing starts.
    started.clear()
    assert "error" in post(srv, "/api/learned/vectors", {"shoot": "no-such-shoot"})
    assert "error" in post(srv, "/api/learned/vectors", {"shoot": "../2026-01-01-gym"})
    # ".." is a folder too - the library's - and never a shoot.
    for name in ("..", ".", ".hidden"):
        assert "error" in post(srv, "/api/learned/vectors", {"shoot": name}), name
    assert started == []


def test_a_bursts_frames_are_names_a_picture_route_answers_to(srv):
    """The app asks for /thumb/<shoot>/<name>.jpg with whatever the burst list
    called the frame, and keys its rows by the same name. A burst that named
    files (TSC00001.ARW) asked for TSC00001.ARW.jpg on every frame: 404, and a
    light table with no photographs in it. Measured on his own library."""
    j = shoot_json(srv)
    bursts = j["bursts"]
    assert bursts, "the fixture shoot has bursts"
    stems = {r["stem"] for r in j["rows"]}
    for b in bursts:
        for name in b["frames"]:
            assert "." not in name, f"{name} carries a suffix"
            assert name in stems, f"{name} is not a stem of this shoot"
        assert b["cover"] in stems
    # And the route really answers to one of them.
    status, body = get(srv, f"/thumb/2026-01-01-gym/{bursts[0]['frames'][0]}.jpg")
    assert status in (200, 404)          # 404 only if the fixture has no picture
    if status == 404:
        assert b"no such" in body or b"not" in body


# ------------------------- when his work and the machine's homework collide
#
# One afternoon he marked a shoot finished, which starts the learning run, and
# then went to copy that shoot's RAWs to iCloud. The answer was the whole of
# {"error": "a job is already running"} - thirty-seven bytes that name no job,
# give no progress, promise no end and offer nothing to do. He was mid-shoot
# and there was nothing on his screen that could tell him why.
#
# Two rules came out of it and these are the tests of them.

def _busy_with_learning(jobs, lib):
    """Put a learning run in the slot, the way finishing a shoot does."""
    assert jobs.start(studio.LEARN_KIND, "learning from your finished shoots",
                      [sys.executable, "-c", "import time; time.sleep(30)"],
                      lib["root"] / "learn.log", shoot="2026-01-01-gym",
                      why="you finished 2026-01-01-gym")
    return jobs


def test_his_work_never_waits_on_the_machines_homework(srv, lib, monkeypatch):
    """The learning run stands down and his job starts at once.

    It costs nothing: nothing it has learned is used until it has been checked
    against every photograph he kept, the ask is written back down, and it
    picks up again when the Mac is quiet. So it is never the reason he cannot
    do something."""
    import learned
    jobs = studio.Handler.jobs
    asked: list[tuple] = []
    monkeypatch.setattr(learned, "request_run", lambda why, shoot="": asked.append((why, shoot)))
    _busy_with_learning(jobs, lib)
    assert jobs.status()["kind"] == studio.LEARN_KIND

    out = post(srv, "/api/storage/plan", {"name": "2026-01-01-gym", "what": "push"})

    assert "error" not in out, out
    assert out["ok"] is True
    # It is not silent about it: one line he can read afterwards.
    assert out["paused"] == studio.LEARNING_STOOD_DOWN
    assert out["paused_job"]["title"] == "Learning from 2026-01-01-gym"
    # And his job holds the slot now.
    assert jobs.status()["kind"] == "plan-push"
    # The run said it still wants to run, with the reason it had.
    assert asked and asked[-1] == ("you finished 2026-01-01-gym", "2026-01-01-gym")
    _idle(jobs)


def test_the_homework_does_not_take_the_slot_straight_back(srv, lib, monkeypatch):
    """Standing it down is pointless if it restarts the instant his job ends.

    He draws a plan, reads it and presses apply: three jobs in a row with him
    thinking in between. Each opening the homework took would have cost it the
    minutes it had already spent, and cost him another refusal."""
    import learned
    jobs = studio.Handler.jobs
    monkeypatch.setattr(learned, "manifest", lambda: {"queued": {"why": "you finished it", "shoot": "s"}})
    started: list[str] = []
    monkeypatch.setattr(studio, "learned_start",
                        lambda j, why, shoot="": started.append(why))
    _busy_with_learning(jobs, lib)
    jobs.make_room()
    # His own short job, and then nothing.
    assert jobs.start("plan-push", "working it out", [sys.executable, "-c", "pass"],
                      lib["root"] / "plan.log")
    for _ in range(100):
        if not jobs.status()["running"]:
            break
        time.sleep(0.05)
    time.sleep(0.4)
    assert started == [], "the homework took the slot back while he was still working"
    # It is not forgotten, only waiting for a quiet stretch.
    assert jobs._quiet_until > time.time()
    _idle(jobs)


def test_two_of_his_own_jobs_still_queue_behind_each_other(srv, lib, monkeypatch):
    """Both are work he asked for and neither is the machine's to throw away.
    That part was already right and stays exactly as it was."""
    jobs = studio.Handler.jobs
    assert jobs.start("cull", "culling 2026-01-01-gym",
                      [sys.executable, "-c", "import time; time.sleep(5)"],
                      lib["root"] / "cull.log", shoot="2026-01-01-gym")
    out = post(srv, "/api/storage/plan", {"name": "2026-01-01-gym", "what": "push"})
    assert out.get("ok") is not True
    # The cull is untouched.
    assert jobs.status()["kind"] == "cull" and jobs.status()["running"]
    _idle(jobs)


def test_a_refusal_names_the_job_its_progress_and_what_is_left(srv, lib):
    """No route answers the bare sentence any more.

    What comes back names which job is in the way, where it has got to in the
    engine's own stage words, roughly how long is left, and the fact that the
    queue will take the request - which is everything the app needs to offer
    him the two real choices instead of a dead end."""
    jobs = studio.Handler.jobs
    log = lib["root"] / "cull.log"
    assert jobs.start("cull", "culling 2026-01-01-gym",
                      [sys.executable, "-c", "import time; time.sleep(5)"], log,
                      shoot="2026-01-01-gym")
    # Give the bar something to report, the way a real cull does.
    log.write_text("$ cull.py\n@@ faces 240 1157\n")
    jobs.started = time.time() - 60

    out = post(srv, "/api/storage/plan", {"name": "2026-01-01-gym", "what": "push"})

    assert out["error"] != "a job is already running"
    assert "culling 2026-01-01-gym" in out["error"]
    assert "looking at faces" in out["error"]
    assert "left" in out["error"]
    b = out["busy"]
    assert b["title"] == "culling 2026-01-01-gym"
    assert b["kind"] == "cull" and b["shoot"] == "2026-01-01-gym"
    assert b["label"] == "looking at faces: 240 of 1,157 frames"
    assert 0 < b["fraction"] < 1
    assert b["remaining"] > 0 and b["remaining_text"].endswith("left")
    assert b["background"] is False        # his own work: the choice is his
    assert b["can_queue"] is True          # and the queue will take it
    assert b["wanted"] == "working out what would go in 2026-01-01-gym"
    _idle(jobs)


def test_no_route_answers_the_bare_sentence(srv, lib):
    """Belt and braces over the four that used to, by asking each of them
    while a job of his is running and reading what comes back."""
    jobs = studio.Handler.jobs
    asks = [
        ("/api/storage/plan", {"name": "2026-01-01-gym", "what": "push"}),
        ("/api/storage/check", {"name": "2026-01-01-gym"}),
        ("/api/cull", {"name": "2026-01-01-gym"}),
        ("/api/presets", {"name": "2026-01-01-gym"}),
    ]
    for path, body in asks:
        assert jobs.start("cull", "culling 2026-01-01-gym",
                          [sys.executable, "-c", "import time; time.sleep(5)"],
                          lib["root"] / "cull.log", shoot="2026-01-01-gym")
        out = post(srv, path, body)
        if out.get("ok"):
            _idle(jobs)
            continue
        assert out["error"] != "a job is already running", path
        if "busy" in out:
            assert out["busy"]["title"] == "culling 2026-01-01-gym", path
        _idle(jobs)


def test_he_can_ask_for_it_to_wait_its_turn_instead(srv, lib):
    """The other choice. The queue is the engine's and has been all along;
    this is the app asking for it by name, with an id to take it back out."""
    jobs = studio.Handler.jobs
    assert jobs.start("cull", "culling 2026-01-01-gym",
                      [sys.executable, "-c", "import time; time.sleep(5)"],
                      lib["root"] / "cull.log", shoot="2026-01-01-gym")
    out = post(srv, "/api/storage/plan",
               {"name": "2026-01-01-gym", "what": "push", "queue": True})
    assert out["ok"] is True and out["queued"] is True and out["id"] > 0
    assert post(srv, "/api/job/stop", {"id": out["id"]})["ok"] is True
    _idle(jobs)


# ----------------------------------------- the list of work he asked for
#
# "Also provide a job queue so i can just tap all the jobs i need to happen."
#
# He comes home from a card, wants to say all of it in one pass and then walk
# away. These are about the list he fills, not about the one request that had
# to wait - that one is above, and it is the same queue underneath.


def _tiny(name: str, o: dict, seconds: float = 0.2, root: Path | None = None) -> dict:
    """A piece of work that does nothing for a moment, so a list of four can
    be watched from end to end in a test rather than in six minutes."""
    return {"title": f"doing {o.get('what') or name}", "does": f"Do {o.get('what') or name}.",
            "cmd": [sys.executable, "-c", f"import time; time.sleep({seconds})"],
            "log": (root or Path("/tmp")) / f"{o.get('what') or name}.log", "then": None}


@pytest.fixture
def fake_work(monkeypatch, lib):
    """Four real kinds, built out of a sleep. The list, its order and its
    re-checking are what is under test here; what each job actually does is
    cull.py's business and is tested where cull.py is."""
    made = {}
    for kind in ("cull", "presets", "gather", "stor-push"):
        made[kind] = lambda name, o, k=kind: _tiny(k, o, root=lib["root"])
    monkeypatch.setattr(studio, "WORK", {**studio.WORK, **made})
    return made


def _drain(jobs, tries: int = 300) -> None:
    for _ in range(tries):
        st = jobs.status()
        if not st["running"] and not st["queue"]:
            return
        time.sleep(0.05)
    raise AssertionError("the list never emptied")


def test_he_can_stack_up_an_evening_and_walk_away(srv, lib, fake_work):
    """Four things in one pass, in the order he asked for them.

    This is the whole ask: copy this card, cull it, write the presets, push
    the RAWs - said once, before he leaves, instead of four trips back to the
    machine."""
    jobs = studio.Handler.jobs
    ids = []
    for kind in ("cull", "presets", "gather", "stor-push"):
        out = post(srv, "/api/queue", {"kind": kind, "name": "2026-01-01-gym", "what": kind})
        assert out["ok"] is True, out
        ids.append(out["id"])
    # The first one is running; the other three are waiting, in order.
    st = jobs.status()
    assert st["running"] is True
    assert [q["kind"] for q in st["queue"]] == ["presets", "gather", "stor-push"]
    assert st["queue_listed"] == 4
    # Each row says whose shoot it is and what it will do.
    assert st["queue"][0]["shoot"] == "2026-01-01-gym"
    assert st["queue"][0]["does"] == "Do presets."
    assert st["queue"][0]["ready"] is True and st["queue"][0]["why_not"] == ""
    _drain(jobs)
    assert [d["kind"] for d in jobs.status()["queue_done"]] == ["cull", "presets", "gather", "stor-push"]
    assert jobs.status()["queue_fraction"] == 1.0


def test_a_list_job_that_says_no_is_written_down_as_refused_and_a_crash_as_failed(srv, lib, monkeypatch):
    """A script refuses by raising SystemExit with its sentence, which exits
    1 with no traceback. The list wrote every non-zero exit down as "failed",
    so the app counted a guard working as a crash, in red, in the same window
    whose history called the same job "Refused"."""
    said = "2026-01-01-gym has no archive manifest: nothing was ever pushed."
    bodies = {
        "cull": f"raise SystemExit({said!r})",
        "presets": "raise MemoryError()",
        "gather": "import os, signal; os.kill(os.getpid(), signal.SIGKILL)",
        "stor-push": "print('pushed')",
    }

    def work(kind):
        return lambda name, o: {"title": f"doing {kind}", "does": f"Do {kind}.",
                                "cmd": [sys.executable, "-c", bodies[kind]],
                                "log": lib["root"] / f"{kind}.log", "then": None}
    monkeypatch.setattr(studio, "WORK", {**studio.WORK, **{k: work(k) for k in bodies}})
    jobs = studio.Handler.jobs
    jobs.hold(True)
    for k in bodies:
        assert post(srv, "/api/queue", {"kind": k, "name": "2026-01-01-gym"})["ok"] is True
    jobs.hold(False)
    _drain(jobs)
    done = {d["kind"]: d["outcome"] for d in jobs.status()["queue_done"]}
    assert done == {"cull": "refused", "presets": "failed", "gather": "failed", "stor-push": "done"}


def test_how_a_job_ended_is_read_from_the_last_command_only(tmp_path):
    """The same rule the app applies to a job it watched end (Job.crashed)."""
    log = tmp_path / "x.log"
    log.write_text("$ first.py\nTraceback (most recent call last):\nValueError: bad\n"
                   "$ cull.py x\n@@ faces 3 9\nx has no photographs in it.\n")
    assert studio.ended_as(1, log) == "refused"
    log.write_text("$ presets.py x\nOSError: [Errno 28] No space left on device\n")
    assert studio.ended_as(1, log) == "failed"
    log.write_text("$ cull.py x\n")
    assert studio.ended_as(2, log) == "failed", "nothing said is not a refusal"
    assert studio.ended_as(-9, log) == "failed"
    assert studio.ended_as(137, log) == "failed"
    assert studio.ended_as(0, log) == "done"
    assert studio.ended_as(1, tmp_path / "missing.log") == "failed"
    assert studio.ended_as(1, None) == "failed"


def test_he_can_move_one_up_the_list_and_take_one_off_it(srv, lib, fake_work):
    jobs = studio.Handler.jobs
    ids = [post(srv, "/api/queue", {"kind": k, "name": "2026-01-01-gym", "what": k})["id"]
           for k in ("cull", "presets", "gather", "stor-push")]
    # The cull is running; the three behind it are his to order.
    waiting = ids[1:]
    out = post(srv, "/api/queue/order", {"ids": [waiting[2], waiting[0], waiting[1]]})
    assert out["ok"] is True
    assert [q["id"] for q in out["list"]["queue"]] == [waiting[2], waiting[0], waiting[1]]
    # And one of them was a mistake.
    out = post(srv, "/api/queue/remove", {"id": waiting[0]})
    assert out["ok"] is True
    assert [q["id"] for q in out["list"]["queue"]] == [waiting[2], waiting[1]]
    # The answer to every one of these carries the list, so the screen can
    # never be showing an order the engine does not have.
    assert out["list"]["waiting"] == 2
    _idle(jobs)


def test_holding_the_list_stops_the_next_one_and_not_the_one_running(srv, lib, fake_work):
    """Hold is about what the machine starts by itself. A cull halfway through
    is work, not a plan, and nothing here touches it."""
    jobs = studio.Handler.jobs
    for k in ("cull", "presets", "gather"):
        post(srv, "/api/queue", {"kind": k, "name": "2026-01-01-gym", "what": k})
    out = post(srv, "/api/queue/hold", {"held": True})
    assert out["held"] is True
    assert jobs.status()["running"] is True          # the cull is untouched
    for _ in range(200):
        if not jobs.status()["running"]:
            break
        time.sleep(0.05)
    time.sleep(0.4)
    st = jobs.status()
    assert st["running"] is False
    assert [q["kind"] for q in st["queue"]] == ["presets", "gather"], "a held list started the next one"
    assert post(srv, "/api/queue/hold", {"held": False})["held"] is False
    _drain(jobs)


def test_stop_holds_the_rest_of_the_list_and_says_why(srv, lib, monkeypatch):
    """He pressed Stop because he needs the machine, or to cull again with a
    different focus. The next piece starting the instant the cull died made
    the Mac busy again and ran the presets against the cull he meant to redo.
    Stop holds what is waiting, and the list says it was his Stop."""
    made = {k: (lambda name, o, k=k: _tiny(k, o, seconds=5 if k == "cull" else 0.2, root=lib["root"]))
            for k in ("cull", "presets", "gather")}
    monkeypatch.setattr(studio, "WORK", {**studio.WORK, **made})
    jobs = studio.Handler.jobs
    for k in ("cull", "presets", "gather"):
        post(srv, "/api/queue", {"kind": k, "name": "2026-01-01-gym", "what": k})
    assert jobs.status()["kind"] == "cull"
    assert post(srv, "/api/job/stop", {})["ok"] is True
    for _ in range(200):
        if not jobs.status()["running"]:
            break
        time.sleep(0.05)
    time.sleep(0.4)
    st = jobs.status()
    assert st["running"] is False, "the next piece started the moment the cull was stopped"
    assert [q["kind"] for q in st["queue"]] == ["presets", "gather"]
    assert st["queue_held"] is True
    assert st["queue_held_after"] == {"why": "stopped", "kind": "cull", "title": "doing cull",
                                      "shoot": "2026-01-01-gym"}
    # The list's own reading says the same, and it is written down.
    status, body = get(srv, "/api/queue")
    assert json.loads(body)["held_after"]["why"] == "stopped"
    again = studio.Jobs(store=lib["root"] / "queue.json")
    again.load()
    assert again.status()["queue_held_after"]["kind"] == "cull"
    # Continue is his, and from then on the reason is his too.
    out = post(srv, "/api/queue/hold", {"held": False})
    assert out["held"] is False and out["list"]["held_after"] is None
    _drain(jobs)


def test_stop_with_nothing_waiting_holds_nothing(srv, lib):
    """A Stop over an empty list must not leave a hold behind it: the next
    thing he adds, an hour later, would wait for a reason he has forgotten."""
    jobs = studio.Handler.jobs
    assert jobs.start("cull", "culling 2026-01-01-gym",
                      [sys.executable, "-c", "import time; time.sleep(5)"],
                      lib["root"] / "cull.log", shoot="2026-01-01-gym")
    assert jobs.stop() is True
    _idle(jobs)
    st = jobs.status()
    assert st["queue_held"] is False and st["queue_held_after"] is None


def test_an_empty_list_can_be_held_so_nothing_added_starts(srv, lib, fake_work):
    """Hold first, then stack the evening up while he is still culling: none
    of it starts until he says so."""
    jobs = studio.Handler.jobs
    out = post(srv, "/api/queue/hold", {"held": True})
    assert out["held"] is True and out["list"]["queue"] == []
    post(srv, "/api/queue", {"kind": "cull", "name": "2026-01-01-gym", "what": "cull"})
    time.sleep(0.3)
    st = jobs.status()
    assert st["running"] is False and [q["kind"] for q in st["queue"]] == ["cull"]
    post(srv, "/api/queue/hold", {"held": False})
    _drain(jobs)


def test_clearing_takes_the_list_down_and_leaves_the_job_running(srv, lib, fake_work):
    jobs = studio.Handler.jobs
    for k in ("cull", "presets", "gather"):
        post(srv, "/api/queue", {"kind": k, "name": "2026-01-01-gym", "what": k})
    out = post(srv, "/api/queue/clear", {})
    assert out["removed"] == 2 and out["list"]["queue"] == []
    assert jobs.status()["running"] is True
    _idle(jobs)


def test_nothing_that_removes_photographs_may_be_left_on_a_list(srv, lib):
    """An apply is measured against a list he read at that moment. A
    confirmation held in a queue for an hour is a confirmation of something
    nobody measured, so the answer is no - and the sentence says why, rather
    than the control being hidden and then refused."""
    for kind in ("stor-drop", "stor-expire", "stor-reclaim"):
        out = post(srv, "/api/queue", {"kind": kind, "name": "2026-01-01-gym"})
        assert out.get("ok") is not True, kind
        assert out["queueable"] is False, kind
        assert "list" in out["error"], kind
        assert studio.Handler.jobs.status()["queue"] == []
    # And the ones that add a copy or read one back are fine.
    out = post(srv, "/api/queue", {"kind": "stor-check", "name": "2026-01-01-gym"})
    assert out["ok"] is True
    _idle(studio.Handler.jobs)


def test_the_list_survives_a_restart(srv, lib, fake_work):
    """It is his intent, not a detail of this process. He filled it at
    midnight and quit; the first thing the morning owes him is the same list."""
    jobs = studio.Handler.jobs
    jobs.hold(True)
    for k in ("presets", "gather", "stor-push"):
        post(srv, "/api/queue", {"kind": k, "name": "2026-01-01-gym", "what": k})
    assert [q["kind"] for q in jobs.status()["queue"]] == ["presets", "gather", "stor-push"]

    # The app quits. A new engine comes up and reads what he left.
    again = studio.Jobs(store=lib["root"] / "queue.json")
    again.load()
    st = again.status()
    assert [q["kind"] for q in st["queue"]] == ["presets", "gather", "stor-push"]
    assert [q["shoot"] for q in st["queue"]] == ["2026-01-01-gym"] * 3
    assert st["queue_held"] is True, "it was held when he left it"
    # Ids do not start again from 1 and collide with what he is looking at.
    assert again.add("cull", "2026-01-01-gym", {"what": "cull"})["id"] > st["queue"][-1]["id"]
    again.clear()
    _idle(jobs)


def _gone(pid: int, tries: int = 100) -> bool:
    import os
    for _ in range(tries):
        try:
            os.killpg(pid, 0)
        except OSError:
            return True
        time.sleep(0.05)
    return False


def test_a_job_a_crash_cut_off_goes_back_to_the_top_of_a_held_list(lib, monkeypatch):
    """The engine died under a cull the list had started. The banner said
    nothing was lost; the cull was not mentioned, not back on the list and
    not reported as failed - and, started in a session of its own, it went
    on writing while the new engine resumed the list on top of it. It is put
    down, put back first, and the list is held for him to continue."""
    made = {k: (lambda name, o, k=k: _tiny(k, o, seconds=30 if k == "cull" else 0.2, root=lib["root"]))
            for k in ("cull", "presets")}
    monkeypatch.setattr(studio, "WORK", {**studio.WORK, **made})
    store = lib["root"] / "queue.json"
    first = studio.Jobs(store=store)
    # The engine that dies does nothing more once it has: no next piece.
    first.add("cull", "2026-01-01-gym", {"what": "cull"})
    monkeypatch.setattr(first, "_take_next", lambda: None)
    monkeypatch.setattr(first, "_pick_up_learning", lambda: None)
    first.add("presets", "2026-01-01-gym", {"what": "presets"})
    pid = first.proc.pid
    assert first.running_store().exists()

    again = studio.Jobs(store=store)
    again.load()
    assert _gone(pid), "the cull the crash cut off was left running beside the new engine"
    st = again.status()
    assert [q["kind"] for q in st["queue"]] == ["cull", "presets"]
    assert st["queue"][0]["interrupted"] is True and st["queue"][0]["opts"] == {"what": "cull"}
    assert st["queue"][1]["interrupted"] is False
    assert st["queue_held"] is True
    assert st["queue_held_after"] == {"why": "crashed", "kind": "cull", "title": "doing cull",
                                      "shoot": "2026-01-01-gym"}
    assert not again.running_store().exists()
    # The line that says the engine restarted can name it: this run found it.
    assert studio.queue_view(again)["cut_off"]["kind"] == "cull"
    # Held means held: starting the list does not run it.
    again.start_list()
    assert again.status()["running"] is False
    # And written down, so a second restart does not lose the mark.
    third = studio.Jobs(store=store)
    third.load()
    assert third.status()["queue"][0]["interrupted"] is True
    assert third.status()["queue_cut_off"] is None, "a later start found nothing cut off"


def test_what_a_crash_cut_off_that_cannot_be_rebuilt_is_only_put_down(lib):
    """An extension's own work carries a command this engine built and nothing
    to rebuild it from: it is stopped, and not put back."""
    store = lib["root"] / "queue.json"
    first = studio.Jobs(store=store)
    assert first.start("ext-upload", "uploading", [sys.executable, "-c", "import time; time.sleep(30)"],
                       lib["root"] / "ext.log")
    pid = first.proc.pid
    again = studio.Jobs(store=store)
    again.load()
    assert _gone(pid)
    st = again.status()
    assert st["queue"] == [] and st["queue_held"] is False
    assert not again.running_store().exists()


def test_a_job_that_ends_or_a_quit_leaves_nothing_to_put_back(lib):
    """Only a crash leaves the note behind: a job that ended forgets it, and
    so does a quit, which stops what is running on purpose."""
    store = lib["root"] / "queue.json"
    jobs = studio.Jobs(store=store)
    assert jobs.start("cull", "culling", [sys.executable, "-c", "pass"], lib["root"] / "c.log",
                      shoot="2026-01-01-gym", opts={})
    for _ in range(100):
        if not jobs.status()["running"] and not jobs.running_store().exists():
            break
        time.sleep(0.05)
    assert not jobs.running_store().exists()
    assert jobs.start("cull", "culling", [sys.executable, "-c", "import time; time.sleep(30)"],
                      lib["root"] / "c.log", shoot="2026-01-01-gym", opts={})
    pid = jobs.proc.pid
    assert jobs.running_store().exists()
    jobs.quit()
    assert not jobs.running_store().exists()
    assert _gone(pid)
    again = studio.Jobs(store=store)
    again.load()
    assert again.status()["queue"] == []


def test_a_number_handed_out_again_is_not_put_down(lib):
    """The process a note names may be gone and its number reused: only a
    group led by that number, still running the job's own script, is
    stopped."""
    import subprocess as sp
    other = sp.Popen([sys.executable, "-c", "import time; time.sleep(30)"], start_new_session=True)
    try:
        assert studio._put_down(other.pid, "some/other/script.py") is False
        assert other.poll() is None
    finally:
        other.kill()
        other.wait()


def _orphaned(lib, monkeypatch, kind: str, code: str, **start):
    """An engine that starts a job and then goes away, leaving its note: the
    job runs on with nobody watching it."""
    first = studio.Jobs(store=lib["root"] / "queue.json")
    for name in ("_take_next", "_pick_up_learning", "_unmark_running"):
        monkeypatch.setattr(first, name, lambda *a, **k: None)
    monkeypatch.setattr(first, "_remember", lambda rec: None)
    log = lib["root"] / f"{kind}.log"
    assert first.start(kind, f"doing {kind}", [sys.executable, "-c", code], log,
                       shoot="2026-01-01-gym", opts=start.get("opts", {"what": kind}))
    return first, log


def test_a_job_that_finished_while_nobody_watched_is_not_put_back(lib, monkeypatch):
    """The engine went down, a restart failed twice and he started the app
    again an hour later, after the cull had finished on its own. It was put
    back at the top, held, and written down as failed: he was asked to run a
    finished cull again. How it ended is the last line of its log."""
    first, log = _orphaned(lib, monkeypatch, "cull", "print('culled 1,558 frames')")
    first.proc.wait()
    assert studio.ended_unwatched(log) == ("done", 0)
    again = studio.Jobs(store=lib["root"] / "queue.json")
    again.load()
    st = again.status()
    assert st["queue"] == [] and st["queue_held"] is False and st["queue_cut_off"] is None
    assert not again.running_store().exists()
    h = again.history()
    assert [(r["kind"], r["outcome"], r["code"]) for r in h] == [("cull", "done", 0)]
    assert h[0]["log"].endswith("\nculled 1,558 frames"), "no line about the engine going away under it"


def test_a_job_that_said_no_while_nobody_watched_is_written_down_as_refused(lib, monkeypatch):
    first, log = _orphaned(lib, monkeypatch, "presets", "raise SystemExit('Cull the shoot first.')")
    first.proc.wait()
    again = studio.Jobs(store=lib["root"] / "queue.json")
    again.load()
    assert again.status()["queue"] == []
    assert [(r["outcome"], r["code"]) for r in again.history()] == [("refused", 1)]


def test_a_job_the_mac_went_down_under_is_put_back(lib, monkeypatch):
    """No process and no last line: it did not get to its end - the Mac
    restarted under it - so it goes back at the top, held."""
    store = lib["root"] / "queue.json"
    log = lib["root"] / "cull.log"
    log.write_text("$ python cull.py\n@@ decode 400 1558\n")
    import subprocess as sp
    gone = sp.Popen([sys.executable, "-c", "pass"])
    gone.wait()
    studio.write_json_atomic(store.parent / "running.json",
                             {"id": 4, "kind": "cull", "title": "culling 2026-01-01-gym",
                              "shoot": "2026-01-01-gym", "opts": {"what": "cull"}, "does": "",
                              "keeps": True, "pid": gone.pid, "script": "cull.py",
                              "started": time.time() - 60, "run": "1-1-a", "log": str(log),
                              "from_list": True})
    again = studio.Jobs(store=store)
    again.load()
    st = again.status()
    assert [q["kind"] for q in st["queue"]] == ["cull"] and st["queue"][0]["interrupted"] is True
    assert st["queue_held"] is True and st["queue_held_after"]["why"] == "crashed"
    assert again.history()[-1]["outcome"] == "failed"


@pytest.mark.parametrize("process_read", ["native", "narrow", "unavailable"])
def test_a_second_engine_leaves_the_first_ones_job_alone(lib, monkeypatch, process_read):
    """A second `./pl studio`, or the app's engine while an orphaned one still
    serves, read the first one's note and put its running cull down, back on
    the list and held - under an engine that was watching it."""
    import subprocess as sp
    first, log = _orphaned(lib, monkeypatch, "cull", "import time; time.sleep(30)")
    # The engine that wrote the note is another process, still running
    # studio.py.
    other = sp.Popen([sys.executable, "-c", "import time; time.sleep(30)", "x" * 160, "studio.py"])
    original_run = sp.run

    def read_process(args, **kwargs):
        if args[0] == "/bin/ps":
            if process_read == "unavailable":
                raise sp.TimeoutExpired(args, 5)
            result = original_run(args, **kwargs)
            if process_read == "narrow" and "-ww" not in args:
                # procps on Linux clips a redirected command to its width.
                result.stdout = result.stdout[:80]
            return result
        return original_run(args, **kwargs)

    monkeypatch.setattr(sp, "run", read_process)
    try:
        note = json.loads(first.running_store().read_text())
        studio.write_json_atomic(first.running_store(), {**note, "run": f"1-{other.pid}-a"})
        again = studio.Jobs(store=lib["root"] / "queue.json")
        again.load()
        assert first.proc.poll() is None, "the first engine's cull was put down"
        assert again.status()["queue"] == [] and again.status()["queue_held"] is False
        assert again.running_store().exists(), "its note is the first engine's"
        assert again.history() == []
    finally:
        other.kill()
        other.wait()
        studio._ask_to_stop(first.proc)
        first.proc.wait()


def test_a_card_copy_a_crash_cut_off_says_where_it_stopped(lib, monkeypatch):
    """A card copy the crash cut off goes back at the top as the copy that
    finishes into the same shoot (`into`): put back as a copy into a new
    shoot, it could only ever say it cannot run, since a shoot holding a
    frame refuses that. The history and the list say how far it got, and
    what waits behind it - the cull of it - is held with it."""
    made = {"presets": lambda name, o: _tiny("presets", o, root=lib["root"])}
    monkeypatch.setattr(studio, "WORK", {**studio.WORK, **made})
    first, log = _orphaned(lib, monkeypatch, "ingest",
                           "print('copying 1558 files, 38.2 GB'); print('@@ copy 412 1558', flush=True);"
                           " import time; time.sleep(30)")
    first.add("presets", "2026-01-01-gym", {"what": "presets"})
    for _ in range(100):
        if re.search(r"^@@ copy 412", log.read_text(), re.M):
            break
        time.sleep(0.05)
    pid = first.proc.pid
    again = studio.Jobs(store=lib["root"] / "queue.json")
    again.load()
    assert _gone(pid)
    st = again.status()
    assert [q["kind"] for q in st["queue"]] == ["ingest", "presets"], "the copy is back at the top"
    assert st["queue"][0]["interrupted"] is True
    assert st["queue"][0]["opts"] == {"what": "ingest", "into": True}, "it goes back to finish into its shoot"
    assert st["queue_held"] is True
    after = st["queue_held_after"]
    assert (after["why"], after["kind"], after["files"], after["of"]) == ("crashed", "ingest", 412, 1558)
    assert "put_back" not in after
    assert studio.queue_view(again)["cut_off"]["of"] == 1558
    h = again.history()[-1]
    assert h["outcome"] == "failed" and h["log"].endswith("The copy stopped at 412 of 1,558 frames.")
    # Nothing else waiting: the copy alone is back, held, and the restart
    # line still says how far it got.
    third_store = lib["root"] / "alone" / "queue.json"
    third_store.parent.mkdir()
    lone, lone_log = _orphaned({"root": third_store.parent}, monkeypatch, "ingest",
                               "print('copying 5 files'); print('@@ copy 2 5', flush=True);"
                               " import time; time.sleep(30)")
    for _ in range(100):
        if re.search(r"^@@ copy 2", lone_log.read_text(), re.M):
            break
        time.sleep(0.05)
    fourth = studio.Jobs(store=third_store)
    fourth.load()
    assert [q["kind"] for q in fourth.status()["queue"]] == ["ingest"]
    assert fourth.status()["queue_held"] is True
    assert fourth.status()["queue_cut_off"]["of"] == 5


def test_a_hold_a_stop_made_goes_with_the_last_thing_waiting(srv, lib, fake_work):
    """Stop held the list; he then cleared it, or took its last row off. The
    empty list stayed held, still saying "Held because you stopped Cull", and
    the next thing he added an hour later waited for a reason he had long
    forgotten. His own Hold stays his."""
    jobs = studio.Handler.jobs
    jobs.held, jobs.held_after = True, {"why": "stopped", "kind": "cull", "title": "", "shoot": "x"}
    post(srv, "/api/queue", {"kind": "presets", "name": "2026-01-01-gym", "what": "presets"})
    post(srv, "/api/queue", {"kind": "gather", "name": "2026-01-01-gym", "what": "gather"})
    ids = [q["id"] for q in jobs.status()["queue"]]
    assert jobs.cancel(ids[0]) and jobs.status()["queue_held"] is True
    assert jobs.cancel(ids[1])
    st = jobs.status()
    assert st["queue_held"] is False and st["queue_held_after"] is None
    # After a crash, and Clear.
    jobs.held, jobs.held_after = True, {"why": "crashed", "kind": "cull", "title": "", "shoot": "x"}
    post(srv, "/api/queue", {"kind": "presets", "name": "2026-01-01-gym", "what": "presets"})
    jobs.clear()
    assert jobs.status()["queue_held"] is False
    # His own Hold over an emptied list stays.
    jobs.hold(True)
    post(srv, "/api/queue", {"kind": "presets", "name": "2026-01-01-gym", "what": "presets"})
    jobs.clear()
    assert jobs.status()["queue_held"] is True
    jobs.hold(False)
    _idle(jobs)


def test_a_stop_is_passed_on_once_and_waits_for_the_job_to_put_itself_down(lib):
    """Every job runs under a parent that writes how it ended. A Stop goes
    through it to the whole group once - twice would cut the job's own
    cleanup short - and the engine sees the job end when it has."""
    jobs = studio.Jobs(store=lib["root"] / "queue.json")
    log = lib["root"] / "stop.log"
    code = ("import signal, time\n"
            "hits = []\n"
            "def stop(*_):\n"
            "    hits.append(1)\n"
            "    if len(hits) == 1:\n"
            "        raise SystemExit(143)\n"
            "signal.signal(signal.SIGTERM, stop)\n"
            "print('working', flush=True)\n"
            "try:\n"
            "    time.sleep(30)\n"
            "finally:\n"
            "    time.sleep(0.5)\n"
            "    print('put itself down after', len(hits), flush=True)\n")
    assert jobs.start("cull", "culling", [sys.executable, "-c", code], log, shoot="2026-01-01-gym", opts={})
    for _ in range(100):
        if re.search(r"^working$", log.read_text(), re.M):
            break
        time.sleep(0.05)
    assert jobs.stop()
    jobs.proc.wait(timeout=10)
    text = log.read_text()
    assert "put itself down after 1" in text
    assert text.rstrip().endswith("@@ ended 143")
    # And one pressed the instant it starts still stops it.
    assert jobs.start("cull", "culling", [sys.executable, "-c", "import time; time.sleep(30)"],
                      log, shoot="2026-01-01-gym", opts={})
    assert jobs.stop()
    jobs.proc.wait(timeout=10)


def test_the_history_outlives_the_engine_for_a_few_days(srv, lib, fake_work):
    """He quits, or the Mac restarts overnight, after a list ran. In the
    morning Activity said "Nothing has run yet in this session", and which of
    last night's jobs failed could not be found from the app."""
    jobs = studio.Handler.jobs
    for k in ("cull", "presets"):
        post(srv, "/api/queue", {"kind": k, "name": "2026-01-01-gym", "what": k})
    _drain(jobs)
    for _ in range(100):
        if len(jobs.history()) == 2:
            break
        time.sleep(0.05)
    status, body = get(srv, "/api/jobs/history")
    assert status == 200
    d = json.loads(body)
    assert d["run"] == jobs.run and d["days"] == studio.HISTORY_DAYS
    assert [(r["kind"], r["outcome"], r["from_list"]) for r in d["jobs"]] == [("cull", "done", True),
                                                                             ("presets", "done", True)]
    assert all(r["run"] == jobs.run and r["shoot"] == "2026-01-01-gym" for r in d["jobs"])
    assert all(r["ended"] >= r["started"] > 0 for r in d["jobs"])

    # The next morning: another engine reads the same history, and the
    # jobs are an earlier run's.
    again = studio.Jobs(store=lib["root"] / "queue.json")
    again.load()
    assert [r["kind"] for r in again.history()] == ["cull", "presets"]
    assert all(r["run"] != again.run for r in again.history())


def test_the_history_keeps_days_not_a_lifetime(lib):
    """Older than the few days it keeps, a row is not read, and the next start
    takes it out of the file."""
    store = lib["root"] / "queue.json"
    jobs = studio.Jobs(store=store)
    old = time.time() - (studio.HISTORY_DAYS + 1) * 86400
    lines = [{"run": "a", "id": 1, "kind": "cull", "shoot": "x", "started": old, "ended": old + 60,
              "elapsed": 60, "outcome": "failed", "log": "MemoryError"},
             {"run": "b", "id": 2, "kind": "presets", "shoot": "x", "started": time.time() - 3600,
              "ended": time.time() - 3500, "elapsed": 100, "outcome": "done", "log": ""}]
    jobs.history_store().write_text("".join(json.dumps(r) + "\n" for r in lines) + "not json\n")
    assert [r["id"] for r in jobs.history()] == [2]
    again = studio.Jobs(store=store)
    again.load()
    kept = jobs.history_store().read_text().splitlines()
    assert len(kept) == 1 and json.loads(kept[0])["id"] == 2


def test_a_job_the_engine_went_away_under_is_in_the_history_as_failed(lib, monkeypatch):
    """The history the morning after says what the crash did, in the words the
    app uses for it in the evening."""
    store = lib["root"] / "queue.json"
    first = studio.Jobs(store=store)
    log = lib["root"] / "c.log"
    assert first.start("cull", "culling", [sys.executable, "-c", "print('reading the frames', flush=True);"
                                                                 " import time; time.sleep(30)"],
                       log, shoot="2026-01-01-gym", opts={})
    monkeypatch.setattr(first, "_take_next", lambda: None)
    monkeypatch.setattr(first, "_pick_up_learning", lambda: None)
    monkeypatch.setattr(first, "_remember", lambda rec: None)       # it died: it wrote nothing more
    pid = first.proc.pid
    for _ in range(100):
        if "reading the frames" in log.read_text():
            break
        time.sleep(0.05)
    again = studio.Jobs(store=store)
    again.load()
    assert _gone(pid)
    h = again.history()
    assert len(h) == 1
    assert h[0]["outcome"] == "failed" and h[0]["kind"] == "cull" and h[0]["run"] == first.run
    assert h[0]["log"].endswith(studio.ENGINE_WENT_AWAY)
    assert "reading the frames" in h[0]["log"]


def test_settings_and_the_storage_panel_set_one_default_for_letting_go(srv, lib, monkeypatch):
    """Settings ▸ Storage had a number of its own that nothing read, while
    every shoot's panel went on saying 365. There is one: the library's, which
    archive.py reads for a shoot with none of its own."""
    import archive
    monkeypatch.setattr(archive, "ROOT", lib["root"])      # one library, as in the app
    status, body = get(srv, "/api/storage/default-retain")
    assert status == 200 and json.loads(body) == {"days": 365, "set": False}
    out = post(srv, "/api/storage/default-retain", {"days": 90})
    assert out == {"ok": True, "days": 90, "set": True}
    # The shoot's panel reads it, and so does the command that lets go.
    panel = json.loads(get(srv, "/api/storage?name=2026-01-01-gym")[1])
    assert panel["retain"]["days"] == 90 and panel["retain"]["source"] == "library"
    assert archive.retention(lib["gym"]) == 90
    # A shoot's "Use as default" moves the same number Settings shows.
    post(srv, "/api/storage/retain", {"name": "2026-01-01-gym", "days": 30, "default": True})
    assert json.loads(get(srv, "/api/storage/default-retain")[1])["days"] == 30
    # Nonsense is refused, and what else library.json says is kept.
    lib_json = lib["root"] / "library.json"
    lib_json.write_text(json.dumps({"retain_days": 30, "something": "else"}))
    assert "error" in post(srv, "/api/storage/default-retain", {"days": "soon"})
    post(srv, "/api/storage/default-retain", {"days": 400})
    assert json.loads(lib_json.read_text()) == {"retain_days": 400, "something": "else"}


def test_an_item_that_can_no_longer_run_is_skipped_with_a_line_he_can_read(srv, lib, monkeypatch):
    """A shoot can change under a plan. What must never happen is that it goes
    quiet: it is skipped, the reason is kept, and the app reads it back to him
    when the list empties."""
    jobs = studio.Handler.jobs
    jobs.hold(True)
    out = post(srv, "/api/queue", {"kind": "cull", "name": "2026-01-01-gym"})
    assert out["ok"] is True
    assert out["added"]["ready"] is True
    assert out["added"]["does"].startswith("Look at 5 frames")

    # Between the tap and the turn, the photographs go.
    for p in (lib["gym"] / "raw").iterdir():
        p.unlink()
    jobs._checked.clear()
    st = jobs.status()
    assert st["queue"][0]["ready"] is False
    assert st["queue"][0]["why_not"] == "there are no photographs in 2026-01-01-gym any more"

    jobs.hold(False)
    _drain(jobs)
    skipped = jobs.status()["queue_skipped"]
    assert len(skipped) == 1
    assert skipped[0]["title"] == "culling 2026-01-01-gym"
    assert skipped[0]["why_not"] == "there are no photographs in 2026-01-01-gym any more"
    assert jobs.status()["queue_done"] == []


def test_a_card_taken_out_between_the_tap_and_the_turn_says_so(srv, lib, monkeypatch, tmp_path):
    """The item most likely to go stale, and the one it matters most about:
    the copy is the first thing he asks for and he is not in the room for it."""
    card = tmp_path / "EOS_DIGITAL"
    (card / "DCIM").mkdir(parents=True)
    monkeypatch.setattr(studio, "cards", lambda: [str(card)])
    jobs = studio.Handler.jobs
    jobs.hold(True)
    out = post(srv, "/api/queue", {"kind": "ingest", "name": "2026-02-02-lake",
                                   "card": str(card), "verify": "in-flight"})
    assert out["ok"] is True
    assert out["added"]["does"] == "Copy EOS_DIGITAL into 2026-02-02-lake, checking as it copies."

    monkeypatch.setattr(studio, "cards", lambda: [])       # he took it out
    jobs._checked.clear()
    row = jobs.status()["queue"][0]
    assert row["ready"] is False
    assert row["why_not"] == "EOS_DIGITAL is not in this Mac any more"
    jobs.clear()


def _card(tmp_path: Path, frames: int, at: float) -> Path:
    """A card as his camera writes it: mounted as Untitled, DCIM/100MSDCF."""
    import os
    card = tmp_path / "Volumes" / "Untitled"
    d = card / "DCIM" / "100MSDCF"
    d.mkdir(parents=True, exist_ok=True)
    for i in range(1, frames + 1):
        p = d / f"DSC{i:05d}.ARW"
        p.write_bytes(b"x" * 40)
        os.utime(p, (at + i, at + i))
    (d / "._DSC00001.ARW").write_bytes(b"resource fork")     # not a photograph
    return card


def test_a_new_card_named_like_the_last_one_is_not_already_copied(lib, monkeypatch, tmp_path):
    """His camera formats every card as Untitled. The page matched cards by
    the path they mount at and said "already copied as 2026-09-19" of every
    new card from the second night on."""
    import shutil
    old = _card(tmp_path / "night1", 3, 1_700_000_000)
    lib["gym"].joinpath("shoot.json").write_text(json.dumps({"card": "/Volumes/Untitled"}))
    for p in (old / "DCIM" / "100MSDCF").glob("DSC*.ARW"):
        shutil.copy2(p, lib["gym"] / "raw" / p.name)
    # Night two: the same names, the same sizes, other frames.
    new = _card(tmp_path / "night2", 4, 1_700_090_000)
    d = studio.describe_card(str(new))
    assert d["name"] == "Untitled"
    assert d["photographs"] == 4 and d["bytes"] == 160
    assert (d["first"], d["last"]) == (1_700_090_001, 1_700_090_004)
    assert d["copied_as"] == "" and d["held"] == 0
    # Night one's card, put back in: all of it is in the shoot.
    d = studio.describe_card(str(old))
    assert (d["copied_as"], d["held"], d["photographs"], d["stopped"]) == ("2026-01-01-gym", 3, 3, False)


def test_a_card_whose_copy_stopped_says_where(lib, tmp_path):
    import shutil
    card = _card(tmp_path, 5, 1_700_000_000)
    for p in sorted((card / "DCIM" / "100MSDCF").glob("DSC*.ARW"))[:2]:
        shutil.copy2(p, lib["gym"] / "raw" / p.name)
    (lib["gym"] / "logs").mkdir()
    (lib["gym"] / "logs" / "ingest.log").write_text(
        "$ python ingest.py /Volumes/Untitled 2026-01-01-gym\ncopying 5 files, 0.0 GB\n@@ copy 2 5\n")
    d = studio.describe_card(str(card))
    assert (d["copied_as"], d["held"], d["photographs"], d["stopped"]) == ("2026-01-01-gym", 2, 5, True)


def test_a_copy_still_going_is_copying_and_not_stopped(srv, lib, tmp_path):
    """A copy in flight writes the same log as one that died: a "copying" line
    and no result. The sidebar said "Copy stopped at 2 of 5" and the card page
    said the copy stopped, of a copy that was running while he worked on
    another shoot. Only the list knows which it is."""
    import shutil
    jobs = studio.Handler.jobs
    name = "2026-01-01-gym"
    card = _card(tmp_path, 5, 1_700_000_000)
    for p in sorted((card / "DCIM" / "100MSDCF").glob("DSC*.ARW"))[:2]:
        shutil.copy2(p, lib["gym"] / "raw" / p.name)
    log = studio._kind_log(studio.Shoot(lib["gym"]), "ingest")
    # A stand-in for ingest.py that is still going, named as the log names it.
    assert jobs.start("ingest", f"copying the card into {name}",
                      [sys.executable, "-c", "import time; time.sleep(20)", "ingest.py"], log, shoot=name)
    try:
        with log.open("a") as fh:
            fh.write("copying 5 files, 0.0 GB\n@@ copy 2 5\n")
        d = studio.describe_card(str(card))
        assert (d["copied_as"], d["held"], d["stopped"], d["copying"]) == (name, 2, False, True)
        row = next(r for r in json.loads(get(srv, "/api/shoots")[1])["shoots"] if r["name"] == name)
        assert row["ingest"] == {"state": "copying", "files": 2, "of": 5}
        steps = {st["id"]: st for st in shoot_json(srv)["steps"]}
        assert steps["ingest"]["done"] is False
    finally:
        _idle(jobs)
    # Now it has stopped, and the same log says so.
    d = studio.describe_card(str(card))
    assert (d["stopped"], d["copying"]) == (True, False)
    assert studio._ingest_note(studio.Shoot(lib["gym"]))["state"] == "stopped"


def test_a_copy_waiting_on_the_list_is_not_said_to_have_stopped(lib, monkeypatch):
    jobs = studio.Jobs()
    monkeypatch.setattr(studio.Handler, "jobs", jobs, raising=False)
    assert not jobs.copying("2026-01-01-gym")
    jobs.queue.append({"id": 7, "kind": "ingest", "shoot": "2026-01-01-gym"})
    assert jobs.copying("2026-01-01-gym") and not jobs.copying("2026-01-02-lake")
    assert studio._ingest_note(studio.Shoot(lib["gym"])) == {"state": "copying", "files": 0, "of": 0}


def test_the_card_page_is_told_what_is_on_each_card(srv, lib, monkeypatch, tmp_path):
    card = _card(tmp_path, 2, 1_700_000_000)
    monkeypatch.setattr(studio, "cards", lambda: [str(card)])
    status, body = get(srv, "/api/cards")
    out = json.loads(body)
    assert out["cards"] == [str(card)]
    assert [(c["path"], c["photographs"], c["copied_as"]) for c in out["described"]] == [(str(card), 2, "")]


def test_the_list_is_one_bar_and_not_four(srv, lib, fake_work):
    """The Dock shows the list, not the job. Four things is one piece of work
    with four parts, and a bar that goes back to nothing three times is a bar
    that says the machine restarted."""
    jobs = studio.Handler.jobs
    for k in ("cull", "presets", "gather", "stor-push"):
        post(srv, "/api/queue", {"kind": k, "name": "2026-01-01-gym", "what": k})
    seen = []
    for _ in range(300):
        st = jobs.status()
        seen.append(st["queue_fraction"])
        if not st["running"] and not st["queue"]:
            break
        time.sleep(0.05)
    assert seen == sorted(seen), f"the bar for the whole list went backwards: {seen}"
    assert seen[-1] == 1.0


def test_a_job_he_started_by_hand_is_not_counted_as_part_of_the_list(srv, lib):
    """He pressed Cull It. There is no list, and the Dock must not draw one."""
    jobs = studio.Handler.jobs
    assert jobs.start("cull", "culling 2026-01-01-gym",
                      [sys.executable, "-c", "import time; time.sleep(5)"],
                      lib["root"] / "cull.log", shoot="2026-01-01-gym")
    st = jobs.status()
    assert st["queue_from_list"] is False
    assert st["queue_listed"] == 0 and st["queue_fraction"] == 0.0
    _idle(jobs)


def test_a_list_job_still_says_it_came_off_the_list_after_it_ended(srv, lib, fake_work):
    """The list speaks for its own jobs, once, at the end. The flag went False
    as soon as the job was written down, so the readings after the last job
    ended said it was started by hand and the app announced it too."""
    jobs = studio.Handler.jobs
    post(srv, "/api/queue", {"kind": "cull", "name": "2026-01-01-gym", "what": "cull"})
    _drain(jobs)
    for _ in range(100):
        if jobs.status()["queue_done"]:
            break
        time.sleep(0.05)
    st = jobs.status()
    assert st["running"] is False and [d["kind"] for d in st["queue_done"]] == ["cull"]
    assert st["queue_from_list"] is True
    # And it is counted once, not once in `done` and again as the job.
    assert st["queue_listed"] == 1 and st["queue_fraction"] == 1.0


def test_the_job_says_when_it_started(srv, lib):
    """The app's history shows when the engine started a job, not when the
    app first happened to look - which, for work the list started while he
    was away, could be an hour later."""
    jobs = studio.Handler.jobs
    before = time.time()
    assert jobs.start("cull", "culling 2026-01-01-gym",
                      [sys.executable, "-c", "import time; time.sleep(5)"],
                      lib["root"] / "cull.log", shoot="2026-01-01-gym")
    st = jobs.status()
    assert before - 1 <= st["started"] <= time.time() + 1
    _idle(jobs)


def test_the_list_is_one_reading_beside_the_bar(srv, lib, fake_work):
    """GET /api/queue answers with what is happening AND what is waiting, in
    one object. Two readings taken a moment apart is how a screen comes to
    show three waiting behind a job that has already finished."""
    jobs = studio.Handler.jobs
    for k in ("cull", "presets", "gather"):
        post(srv, "/api/queue", {"kind": k, "name": "2026-01-01-gym", "what": k})
    status, body = get(srv, "/api/queue")
    assert status == 200
    d = json.loads(body)
    assert d["running"] is True and d["title"] == "doing cull" and d["from_list"] is True
    assert [q["kind"] for q in d["queue"]] == ["presets", "gather"]
    assert d["waiting"] == 2 and d["listed"] == 3 and d["held"] is False
    assert d["done"] == [] and d["skipped"] == []
    # And it is the same object every POST that changes the list answers with.
    out = post(srv, "/api/queue/hold", {"held": True})
    assert set(out["list"]) == set(d)
    _idle(jobs)


def test_the_list_never_waits_on_the_machines_homework(srv, lib, fake_work, monkeypatch):
    """The learning run gets out of the way of the list exactly as it gets out
    of the way of a button. It holds nothing he is waiting for, nothing it has
    learned is used until it has been checked against every photograph he
    kept, and the ask is written back down - so it is never the reason a list
    of his sits still."""
    import learned
    jobs = studio.Handler.jobs
    asked: list[tuple] = []
    monkeypatch.setattr(learned, "request_run", lambda why, shoot="": asked.append((why, shoot)))
    _busy_with_learning(jobs, lib)
    assert jobs.status()["kind"] == studio.LEARN_KIND

    out = post(srv, "/api/queue", {"kind": "cull", "name": "2026-01-01-gym", "what": "cull"})

    assert out["ok"] is True
    for _ in range(100):
        if jobs.status()["kind"] != studio.LEARN_KIND:
            break
        time.sleep(0.05)
    st = jobs.status()
    assert st["kind"] == "cull" and st["running"] is True, "the list waited on the homework"
    assert st["queue_from_list"] is True
    # And the run said it still wants to go, with the reason it had.
    assert asked, "the learning run was stood down without being asked for again"
    _idle(jobs)


def test_taking_one_off_the_list_takes_it_out_of_the_count_too(srv, lib, fake_work):
    """Four things minus one he changed his mind about is three, and the bar
    for the whole list has to reach the end. It sat at four fifths for ever,
    which reads as a list that never finished."""
    jobs = studio.Handler.jobs
    jobs.hold(True)
    ids = [post(srv, "/api/queue", {"kind": k, "name": "2026-01-01-gym", "what": k})["id"]
           for k in ("cull", "presets", "gather")]
    assert post(srv, "/api/queue/remove", {"id": ids[1]})["ok"] is True
    jobs.hold(False)
    _drain(jobs)
    st = jobs.status()
    assert st["queue_listed"] == 2 and st["queue_fraction"] == 1.0
    assert [d["kind"] for d in st["queue_done"]] == ["cull", "gather"]


def test_a_push_of_a_shoot_he_has_not_finished_goes_on_the_list(srv, lib):
    """Copy the RAWs to iCloud the same night, before Finish: it copies and
    removes nothing, so the list takes it for a shoot not marked finished,
    which it used to turn away. Removing the local RAWs is what waits for
    Finish (archive.drop), and that is never on the list."""
    shoot = studio.Shoot(lib["gym"])
    assert not shoot.meta().get("finished")
    jobs = studio.Handler.jobs
    jobs.hold(True)
    out = post(srv, "/api/queue", {"kind": "stor-push", "name": "2026-01-01-gym"})
    assert out["ok"] is True, out
    assert "--force" not in studio.work_build("stor-push", "2026-01-01-gym", {})["cmd"]
    out = post(srv, "/api/queue", {"kind": "stor-drop", "name": "2026-01-01-gym"})
    assert out.get("ok") is not True and out["queueable"] is False
    jobs.clear()
    jobs.hold(False)
    _idle(jobs)


def test_a_cull_left_on_the_list_does_not_change_the_shoot_until_its_turn(srv, lib, fake_work):
    """What he chose is part of the item, not something written into the shoot
    at the moment he taps.

    The style and the focus used to go into meta.json in the route, before the
    list was even asked. So a cull he put on the list at nine changed the shoot
    at nine and ran at eleven, and a cull the engine refused outright changed
    it and never ran at all - two hours in which the shoot said it was about to
    be culled one way by a job that was going to be culled another."""
    meta = lib["gym"] / "shoot.json"
    meta.write_text(json.dumps({"style": "normal", "focus": 1.9}))
    jobs = studio.Handler.jobs
    jobs.hold(True)

    out = post(srv, "/api/cull", {"name": "2026-01-01-gym", "style": "action",
                                  "focus": 2.6, "queue": True})
    assert out["ok"] is True
    # On the list, carrying his choice as part of the item...
    assert jobs.queue[0]["opts"]["style"] == "action"
    assert jobs.queue[0]["opts"]["focus"] == 2.6
    # ...and the shoot is untouched.
    assert json.loads(meta.read_text())["style"] == "normal"
    assert json.loads(meta.read_text())["focus"] == 1.9
    # The list tells the app what it will run with, so the Cull page shows
    # these while it waits rather than what the shoot says, which is the last
    # cull started.
    opts = jobs.status()["queue"][0]["opts"]
    assert (opts["style"], opts["focus"]) == ("action", 2.6)

    jobs.clear()
    _idle(jobs)


def test_a_reel_left_on_the_list_does_not_write_its_plan_until_its_turn(srv, lib, monkeypatch):
    """Same rule, the other kind of side effect: the plan file a reel runs
    against is written when the reel runs, not when it is offered."""
    monkeypatch.setattr(studio, "HERE", studio.HERE)
    if not (studio.HERE / "reel.py").exists():
        pytest.skip("reels are not part of this build")
    plan_file = lib["gym"] / "cull" / "reel-plan.json"
    jobs = studio.Handler.jobs
    jobs.hold(True)
    out = post(srv, "/api/reel", {"name": "2026-01-01-gym", "burst": "0", "format": "cut",
                                  "plan": {"TSC00001.ARW": 3}, "queue": True})
    assert out["ok"] is True
    assert not plan_file.exists(), "the plan is written at its turn, not at the tap"
    # The format the engine calls "cut" is Push In on screen, and in the
    # job's title too: "cutting burst 0 as a cut" used "cut" for two things.
    assert out["added"]["title"].endswith("as a push-in"), out["added"]["title"]
    jobs.clear()
    _idle(jobs)


def test_the_reel_that_pushes_in_is_called_that_in_its_title():
    """"cutting burst 93 as a cut" used "cut" for the format and for making
    the reel; the format is Push In on screen and in the title."""
    assert studio.reel_title("93", "cut") == "cutting burst 93 as a push-in"
    assert studio.reel_title("93", "loop") == "cutting burst 93 as a loop"
    assert studio.reel_title("", "timelapse") == "cutting a timelapse"


def test_a_refused_cull_leaves_the_shoot_exactly_as_it_was(srv, lib):
    """A refusal is not a half-done thing. If the work cannot be built, the
    shoot must look afterwards exactly as it did before he pressed."""
    meta = lib["gym"] / "shoot.json"
    meta.write_text(json.dumps({"style": "normal", "focus": 1.9}))
    for f in (lib["gym"] / "raw").iterdir():
        f.unlink()
    out = post(srv, "/api/cull", {"name": "2026-01-01-gym", "style": "action", "focus": 2.6})
    assert out.get("ok") is not True
    assert out["error"] == "There are no photographs in 2026-01-01-gym any more"
    assert json.loads(meta.read_text()) == {"style": "normal", "focus": 1.9}


def test_one_place_builds_the_command_for_a_kind(srv, lib):
    """The thing he does now and the same thing he leaves on the list are one
    command line, because there is one builder. They used to be built twice and
    kept in step by hand, which is a flag added to one and not the other."""
    seen = []
    real = studio.WORK["cull"]

    def spy(name, o):
        seen.append(dict(o))
        return real(name, o)

    studio.WORK["cull"] = spy
    try:
        now = post(srv, "/api/cull", {"name": "2026-01-01-gym", "style": "action", "focus": 2.6})
        assert now["ok"] is True
        studio.Handler.jobs.stop()
        _idle(studio.Handler.jobs)
        later = post(srv, "/api/cull", {"name": "2026-01-01-gym", "style": "action",
                                        "focus": 2.6, "queue": True})
        assert later["ok"] is True
    finally:
        studio.WORK["cull"] = real
        studio.Handler.jobs.clear()
        _idle(studio.Handler.jobs)
    # Every start of a cull went through the one builder, doing it now included.
    assert len(seen) >= 2
    assert real(lib["gym"].name, seen[0])["cmd"] == real(lib["gym"].name, seen[1])["cmd"]


def test_doing_it_now_still_writes_what_he_chose_into_the_shoot(srv, lib):
    """The other half of the rule. Deferring the write must not lose it: a
    cull he does now records the style and the focus he picked, so the next
    one offers the same answer back."""
    meta = lib["gym"] / "shoot.json"
    meta.write_text(json.dumps({"style": "normal", "focus": 1.9}))
    out = post(srv, "/api/cull", {"name": "2026-01-01-gym", "style": "action", "focus": 2.6})
    assert out["ok"] is True
    assert json.loads(meta.read_text())["style"] == "action"
    assert json.loads(meta.read_text())["focus"] == 2.6
    studio.Handler.jobs.stop()
    _idle(studio.Handler.jobs)


def test_the_report_names_what_the_cull_on_disk_ran_with_and_nothing_else(srv, lib):
    """The report's "Culled with focus 1.6 (a little lenient)" says what the
    results on screen came from. `focus` and `style` are written when a cull
    STARTS, as what the next one starts from, so a re-cull he stopped, or one
    that died, left them naming a run whose results were never written; and a
    shoot that recorded nothing read back 1.9 and normal as if they were facts
    about it."""
    import cull
    meta = lib["gym"] / "shoot.json"
    # Culled before this was kept: nothing to name.
    info = shoot_json(srv)["info"]
    assert info["cull_ran_with"] == {}
    assert (info["style"], info["focus"]) == ("normal", 1.9)
    # The cull that put cull.csv in place records what it ran with, including
    # a floor the card's own scale moved it to.
    cull.record_run(meta, "action", 2.371)
    info = shoot_json(srv)["info"]
    assert info["cull_ran_with"] == {"style": "action", "focus": 2.37}
    assert (info["style"], info["focus"]) == ("action", 2.37)
    # A cull started with other settings changes what the next one starts
    # from, and not what the results still on disk ran with.
    studio._b_cull(lib["gym"].name, {"style": "normal", "focus": 1.6})["then"]()
    info = shoot_json(srv)["info"]
    assert (info["style"], info["focus"]) == ("normal", 1.6)
    assert info["cull_ran_with"] == {"style": "action", "focus": 2.37}


def test_the_run_record_never_writes_over_a_shoot_json_it_cannot_add_to(tmp_path):
    import cull
    meta = tmp_path / "shoot.json"
    meta.write_text('["not", "a table"]')
    cull.record_run(meta, "normal", 1.9)
    assert meta.read_text() == '["not", "a table"]'
    half = '{"style": "act'
    meta.write_text(half)
    cull.record_run(meta, "normal", 1.9)
    assert meta.read_text() == half


def test_the_engine_opens_no_page_unless_it_is_asked(tmp_path):
    """The engine restarts itself when its own source changes, and it used to
    open its page by default — so editing studio.py in a worktree dropped the
    retired web page into his browser while he was working in the app. The Mac
    app is the product; this process is its engine."""
    import subprocess
    root = Path(__file__).resolve().parent.parent
    src = (root / "pipeline/studio.py").read_text()
    assert "if a.open_page:" in src, "the page is opened only when asked for"
    assert '"--no-open"]' not in src.split("def _restart_args")[0], "no argv rewrite to suppress it"
    out = subprocess.run([sys.executable, str(root / "pipeline/studio.py"), "--help"],
                         capture_output=True, text=True, timeout=60).stdout
    assert "--open" in out and "only with --open" in out


def test_the_list_makes_the_instagram_copies_at_the_shape_they_were_worked_out_at(lib):
    """He works the crops out at 4:5 in the studio, looks at all of them and
    moves two, and leaves "Make the Instagram copies" on the list for the
    night. Nothing that puts that item on the list sends a shape, and this
    sent 3:4 and fit anyway - so the morning's copies were a different shape
    from the ones he had approved. Given no shape, it names none, and the run
    makes what was worked out."""
    ex = lib["gym"] / "export"
    ex.mkdir()
    for line in ROWS.splitlines()[1:]:
        (ex / (Path(line.split(",")[0]).stem + "_DxO.jpg")).write_bytes(b"jpeg")
    cmd = studio.WORK["instagram"]("2026-01-01-gym", {})["cmd"]
    assert "--ratio" not in cmd and "--landscape" not in cmd
    # And a shape he did name is still obeyed.
    cmd = studio.WORK["instagram"]("2026-01-01-gym", {"ratio": "4:5", "landscape": "crop"})["cmd"]
    assert cmd[-4:] == ["--ratio", "4:5", "--landscape", "crop"]


def test_a_square_left_on_the_list_is_refused_where_he_presses_it(lib):
    """The shape on the item is checked against instagram.py's own --ratio,
    and not against a list kept here. These were two lists and they had
    parted: this end took "1:1" and the script's end never did, so a square
    added to the list was taken in as perfectly fine, sat there until its turn
    came, and died hours later with argparse's "invalid choice" in a shoot log
    he was asleep for. Asked at the moment he presses, he hears it while he
    can still pick another shape, and he is told which shapes there are."""
    ex = lib["gym"] / "export"
    ex.mkdir()
    for line in ROWS.splitlines()[1:]:
        (ex / (Path(line.split(",")[0]).stem + "_DxO.jpg")).write_bytes(b"jpeg")

    with pytest.raises(studio.NotNow) as refused:
        studio.WORK["instagram"]("2026-01-01-gym", {"ratio": "1:1"})
    said = str(refused.value)
    assert "1:1" in said
    # Which shapes there are, not merely that this is not one of them.
    assert all(shape in said for shape in instagram.RATIOS)

    # Tied to the script rather than repeated here, which is how they parted
    # the first time: everything --ratio takes is passed through, and a shape
    # it does not take is refused, whatever that list grows into later.
    for shape in instagram.RATIOS:
        cmd = studio.WORK["instagram"]("2026-01-01-gym", {"ratio": shape})["cmd"]
        assert cmd[-2:] == ["--ratio", shape]
    for shape in ("1:1", "16:9", "2:3"):
        assert shape not in instagram.RATIOS
        with pytest.raises(studio.NotNow):
            studio.WORK["instagram"]("2026-01-01-gym", {"ratio": shape})


def test_an_extension_and_its_jobs_are_told_where_this_engine_is(tmp_path):
    """The extension's organizer imports this engine's modules through
    PIPELINE_PUBLIC. Nothing set it, so in the app the organizer found them
    only because a folder beside the extension happened to be his checkout,
    and ran the checkout's code rather than the app's own."""
    import os
    assert os.environ["PIPELINE_PUBLIC"] == str(studio.HERE)
    assert (Path(os.environ["PIPELINE_PUBLIC"]) / "common.py").is_file()
    jobs = studio.Jobs(store=tmp_path / "queue.json")
    log = tmp_path / "ext.log"
    assert jobs.start("ext", "an extension's job",
                      [sys.executable, "-c", "import os; print('public=' + os.environ.get('PIPELINE_PUBLIC', ''))"], log)
    for _ in range(200):
        if not jobs.status()["running"]:
            break
        time.sleep(0.05)
    assert f"public={studio.HERE}" in log.read_text()


@pytest.mark.parametrize("finder", [False, True])
@pytest.mark.parametrize("failure", [None, "launch refused"])
def test_partial_gather_reports_missing_keepers_on_every_open_path(srv, lib, monkeypatch, finder, failure):
    # Real gather, synthetic originals, and a launcher that opens nothing.
    shoot = lib["gym"]
    names = [f"FRAME{i:03}.jpg" for i in range(27)]
    (shoot / "cull" / "cull.csv").write_text(
        "file,rating,scene,burst\n" + "".join(f"{name},5,0,0\n" for name in names))
    (shoot / "cull" / "selects.json").write_text(json.dumps(names))
    (shoot / "raw" / "FRAME000.ARW").write_bytes(b"synthetic original")
    monkeypatch.setattr(studio, "find_editor",
                        lambda e: None if finder else Path("/Applications/PhotoLab.app"))
    opened = []
    monkeypatch.setattr(studio, "_open", lambda args: opened.append(args) or failure)
    result = post(srv, "/api/open", {"name": shoot.name, "what": "photolab"})
    assert result["gather"] == {"total": 27, "gathered": 1, "missing": 26,
                                "missing_files": names[1:]}
    assert len(opened) == 1
    assert len(list((shoot / "edit").iterdir())) == 1
    text = result["error"] if failure else result["note"]
    assert "26 originals were not found: FRAME001.jpg, FRAME002.jpg, FRAME003.jpg and 23 more." in text
    assert "FRAME004.jpg" not in text
    assert "archive" not in text and "pull" not in text
    if failure:
        assert result["ok"] is False and "note" not in result
        assert failure in text and "Opened" not in text
        assert ("folder did not open in Finder either" if finder else "PhotoLab did not open") in text
    else:
        assert result["ok"] is True
        assert f"Opened 1 of 27 keepers in {'Finder' if finder else 'PhotoLab'}." in text
        if finder:
            assert "PhotoLab was not found in Applications" in text


def test_partial_gather_note_names_one_missing_keeper(srv, lib, monkeypatch):
    import gather
    monkeypatch.setattr(gather, "build_with_summary", lambda folder: (
        lib["gym"] / "edit", {"total": 2, "gathered": 1, "missing": 1, "missing_files": ["FRAME001.jpg"]}))
    monkeypatch.setattr(studio, "find_editor", lambda e: Path("/Applications/PhotoLab.app"))
    monkeypatch.setattr(studio, "_open", lambda args: None)
    result = post(srv, "/api/open", {"name": lib["gym"].name, "what": "photolab"})
    assert result["note"] == "Opened 1 of 2 keepers in PhotoLab. 1 original was not found: FRAME001.jpg."
