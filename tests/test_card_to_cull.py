"""From the card to the cull, on the night of a shoot (DESIGN.md §2.6).

    .venv/bin/python -m pytest tests/test_card_to_cull.py -q

What these pin down:
  - a new shoot's cull starts from what his last shoot was culled with, not
    from 1.9 and "people move" off;
  - after a copy that finished, the cull of its shoot starts by itself, and
    after one that did not, nothing does;
  - a copy that stopped finishes into the same shoot, and a second card can
    join a shoot until it is culled - removing nothing, overwriting nothing.

Nothing here reads or writes ~/photos or a real memory card: every library and
every "card" is a folder under pytest's own tmp_path.
"""
from __future__ import annotations

import json
import sys
import threading
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import studio  # noqa: E402
import taste  # noqa: E402


def _shoot(root: Path, name: str, meta: dict | None = None, frames: int = 3) -> Path:
    shoot = root / "shoots" / name
    (shoot / "raw").mkdir(parents=True)
    for i in range(frames):
        (shoot / "raw" / f"TSC{i:05d}.ARW").write_bytes(b"raw" + bytes([i]))
    if meta is not None:
        (shoot / "shoot.json").write_text(json.dumps(meta))
    return shoot


@pytest.fixture
def lib(tmp_path, monkeypatch):
    monkeypatch.setattr(studio, "ROOT", tmp_path)
    monkeypatch.setattr(taste, "EXPORTS", [])
    monkeypatch.setattr(taste, "_EXPORTED", None)
    monkeypatch.setattr(studio, "cards", lambda: [])
    return tmp_path


# ------------------------------------------------ the last shoot's settings

def test_a_new_shoot_culls_as_his_last_shoot_was_culled(lib):
    """Nearly every shoot of his is of people moving fast. Every new shoot
    opened on 1.9 and people move off, so every evening he set both back, and
    a cull he forgot to set ran seven minutes with the wrong ones."""
    _shoot(lib, "2026-09-12-lounge", {"kind": "other", "cull_ran_with": {"style": "normal", "focus": 2.4}})
    _shoot(lib, "2026-09-19", {"kind": "sport", "style": "action", "focus": 1.9,
                               "cull_ran_with": {"style": "action", "focus": 1.6}})
    new = studio.Shoot(_shoot(lib, "2026-09-26", {"kind": "sport"}))
    assert studio._cull_settings(new) == ("action", 1.6, "2026-09-19")
    info = new.info()
    assert (info["style"], info["focus"], info["cull_from"]) == ("action", 1.6, "2026-09-19")

    # The cull that is started without anything asked of it runs with them.
    cmd = studio._b_cull("2026-09-26", {})["cmd"]
    assert cmd[cmd.index("--style") + 1] == "action" and cmd[cmd.index("--face-floor") + 1] == "1.60"
    # What he sets on the page still wins.
    cmd = studio._b_cull("2026-09-26", {"style": "normal", "focus": 2.0})["cmd"]
    assert cmd[cmd.index("--style") + 1] == "normal" and cmd[cmd.index("--face-floor") + 1] == "2.00"


def test_the_last_shoot_of_the_same_kind_comes_first(lib):
    """A portrait evening after a night of sport does not start as sport."""
    _shoot(lib, "2026-09-12-lounge", {"kind": "other", "cull_ran_with": {"style": "normal", "focus": 2.4}})
    _shoot(lib, "2026-09-19", {"kind": "sport", "cull_ran_with": {"style": "action", "focus": 1.6}})
    new = studio.Shoot(_shoot(lib, "2026-09-26-portraits", {"kind": "other"}))
    assert studio._cull_settings(new) == ("normal", 2.4, "2026-09-12-lounge")
    # With no kind of its own, simply the newest.
    bare = studio.Shoot(_shoot(lib, "2026-09-27"))
    assert studio._cull_settings(bare) == ("action", 1.6, "2026-09-19")


def test_a_shoot_keeps_its_own_settings_once_a_cull_was_asked_of_it(lib):
    _shoot(lib, "2026-09-19", {"kind": "sport", "cull_ran_with": {"style": "action", "focus": 1.6}})
    own = studio.Shoot(_shoot(lib, "2026-09-26", {"kind": "sport", "style": "normal", "focus": 2.2}))
    assert studio._cull_settings(own) == ("normal", 2.2, "")
    assert own.info()["cull_from"] == ""


def test_with_no_shoot_culled_yet_it_starts_on_the_defaults(lib):
    first = studio.Shoot(_shoot(lib, "2026-09-26", {"kind": "sport"}))
    assert studio._cull_settings(first) == ("normal", 1.9, "")


# ------------------------------------------------ the cull after the copy

KEY = "k3y-for-this-test-only-0123456789abcdef"


def _card(root: Path, name: str = "Untitled", frames: int = 3) -> Path:
    """A folder the way a camera writes a card: DCIM/100MSDCF/…ARW."""
    card = root / "Volumes" / name
    d = card / "DCIM" / "100MSDCF"
    d.mkdir(parents=True)
    for i in range(frames):
        (d / f"TSC{i:05d}.ARW").write_bytes(b"RAW" + bytes([i]) * 4096)
    return card


def _tiny_cull(root: Path):
    def build(name: str, o: dict) -> dict:
        return {"title": f"culling {name}", "does": "Cull it.",
                "cmd": [sys.executable, "-c", "import time; time.sleep(0.2)"],
                "log": root / f"cull-{name}.log", "then": None}
    return build


@pytest.fixture
def srv(lib, monkeypatch):
    # The copy runs as a real ingest.py, into this library and nowhere else.
    monkeypatch.setenv("PHOTOS_ROOT", str(lib))
    monkeypatch.setattr(studio.Handler, "jobs", studio.Jobs(store=lib / "queue.json"), raising=False)
    monkeypatch.setattr(studio, "WORK", {**studio.WORK, "cull": _tiny_cull(lib)})
    server = studio.Server(("127.0.0.1", 0), studio.Handler, key=KEY)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()


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


def _until(test, tries: int = 400):
    for _ in range(tries):
        if test():
            return True
        time.sleep(0.05)
    return False


def _seen(jobs, kind: str, shoot: str) -> bool:
    st = jobs.status()
    return ((st["kind"] == kind and st["shoot"] == shoot)
            or any(q["kind"] == kind and q["shoot"] == shoot for q in st["queue"])
            or any(d["kind"] == kind and d["shoot"] == shoot for d in st["queue_done"]))


def test_after_a_copy_that_finished_the_cull_starts_by_itself(srv, lib, monkeypatch):
    card = _card(lib)
    monkeypatch.setattr(studio, "cards", lambda: [str(card)])
    jobs = studio.Handler.jobs
    out = post(srv, "/api/ingest", {"card": str(card), "name": "2026-09-26", "verify": "in-flight",
                                    "then_cull": True})
    assert out["ok"] is True, out
    assert _until(lambda: _seen(jobs, "cull", "2026-09-26")), jobs.status()
    assert _until(lambda: not jobs.status()["running"])
    done = jobs.status()["queue_done"]
    assert [(d["kind"], d["shoot"], d["outcome"]) for d in done] == [("cull", "2026-09-26", "done")]
    assert sorted(p.name for p in (lib / "shoots" / "2026-09-26" / "raw").iterdir()) == \
        ["TSC00000.ARW", "TSC00001.ARW", "TSC00002.ARW"]


def test_a_copy_that_did_not_finish_is_followed_by_nothing(srv, lib, monkeypatch):
    """A card with nothing on it: the copy refuses, and nothing is culled."""
    empty = lib / "Volumes" / "Empty"
    (empty / "DCIM").mkdir(parents=True)
    monkeypatch.setattr(studio, "cards", lambda: [str(empty)])
    jobs = studio.Handler.jobs
    out = post(srv, "/api/ingest", {"card": str(empty), "name": "2026-09-27", "then_cull": True})
    assert out["ok"] is True, out
    assert _until(lambda: not jobs.status()["running"])
    time.sleep(0.3)
    assert not _seen(jobs, "cull", "2026-09-27"), jobs.status()


def test_a_copy_not_asked_to_be_followed_is_not(srv, lib, monkeypatch):
    card = _card(lib)
    monkeypatch.setattr(studio, "cards", lambda: [str(card)])
    jobs = studio.Handler.jobs
    assert post(srv, "/api/ingest", {"card": str(card), "name": "2026-09-26"})["ok"] is True
    assert _until(lambda: not jobs.status()["running"])
    time.sleep(0.3)
    assert not _seen(jobs, "cull", "2026-09-26")


def test_a_copy_off_the_list_is_followed_by_one_cull_behind_what_was_there(srv, lib, monkeypatch):
    """Put on the list, the copy keeps what it was asked for; its cull goes
    behind anything he had already put there, and a cull of the shoot that is
    already waiting is not asked for twice."""
    card = _card(lib)
    monkeypatch.setattr(studio, "cards", lambda: [str(card)])
    jobs = studio.Handler.jobs
    jobs.hold(True)
    out = post(srv, "/api/ingest", {"card": str(card), "name": "2026-09-26", "then_cull": True, "queue": True})
    assert out["ok"] is True, out
    assert jobs.queue[0]["opts"].get("then_cull") is True
    jobs.hold(False)
    assert _until(lambda: not jobs.status()["running"] and not jobs.status()["queue"])
    kinds = [(d["kind"], d["shoot"]) for d in jobs.status()["queue_done"]]
    assert kinds == [("ingest", "2026-09-26"), ("cull", "2026-09-26")]

    # Already culled: nothing is added by a later copy into it.
    shoot = lib / "shoots" / "2026-09-26"
    (shoot / "cull").mkdir(exist_ok=True)
    (shoot / "cull" / "cull.csv").write_text("file,rating\nTSC00000.ARW,3\n")
    studio._follow_with_a_cull("2026-09-26")()
    assert not jobs.queue


# ------------------------------------------------ into a shoot that exists

def _files(folder: Path) -> dict[str, tuple[int, bytes, int]]:
    """Every file under a folder: size, bytes and inode, so a test can say
    nothing already there was rewritten, moved or removed."""
    return {str(q.relative_to(folder)): (q.stat().st_size, q.read_bytes(), q.stat().st_ino)
            for q in sorted(folder.rglob("*")) if q.is_file()}


def _run(jobs):
    assert _until(lambda: not jobs.status()["running"] and not jobs.status()["queue"]), jobs.status()


def test_a_copy_that_stopped_finishes_into_the_same_shoot(srv, lib, monkeypatch):
    """The card came out at 2 of 3. Put back, it finishes into the shoot it
    stopped in: only what did not arrive is copied, and what did is left
    exactly as it is. The same name without asking is still refused."""
    card = _card(lib)
    monkeypatch.setattr(studio, "cards", lambda: [str(card)])
    shoot = lib / "shoots" / "2026-09-26"
    (shoot / "raw").mkdir(parents=True)
    for q in sorted((card / "DCIM" / "100MSDCF").iterdir())[:2]:
        (shoot / "raw" / q.name).write_bytes(q.read_bytes())
    (shoot / "cull" / "logs").mkdir(parents=True)
    (shoot / "cull" / "logs" / "ingest.log").write_text(
        f"$ python ingest.py {card} 2026-09-26\ncopying 3 files, 0.0 GB\n@@ copy 2 3\n")
    before = _files(shoot / "raw")
    assert studio.Shoot(shoot).info()["ingest"]["state"] == "stopped"

    assert post(srv, "/api/ingest", {"card": str(card), "name": "2026-09-26"})["error"] == "2026-09-26 already exists"
    out = post(srv, "/api/ingest", {"card": str(card), "name": "2026-09-26", "into": True})
    assert out["ok"] is True, out
    _run(studio.Handler.jobs)
    after = _files(shoot / "raw")
    assert {k: v for k, v in after.items() if k in before} == before, "what had arrived was rewritten"
    assert sorted(after) == ["TSC00000.ARW", "TSC00001.ARW", "TSC00002.ARW"]
    note = studio.Shoot(shoot).info()["ingest"]
    assert note["state"] == "done" and note["files"] == 3, note
    assert "earlier" not in note, "the copy it finished is the one this log accounts for"


def test_a_second_card_joins_the_nights_shoot_and_both_are_kept(srv, lib, monkeypatch):
    """Two bodies, one night: the second card's frames share the first's names
    and are other photographs. Both are kept, the first card's copy keeps its
    own proof, and nothing of the first is touched."""
    a, b = _card(lib, "A"), lib / "Volumes" / "B"
    d = b / "DCIM" / "100MSDCF"
    d.mkdir(parents=True)
    for i in range(3):
        (d / f"TSC{i:05d}.ARW").write_bytes(b"OTHER" + bytes([i + 7]) * 4096)
    (d / "TSC00009.ARW").write_bytes(b"NEW" * 1000)
    monkeypatch.setattr(studio, "cards", lambda: [str(a), str(b)])
    jobs = studio.Handler.jobs
    assert post(srv, "/api/ingest", {"card": str(a), "name": "2026-09-26"})["ok"] is True
    _run(jobs)
    shoot = lib / "shoots" / "2026-09-26"
    first = _files(shoot / "raw")

    out = post(srv, "/api/ingest", {"card": str(b), "name": "2026-09-26", "into": True, "kind": "other"})
    assert out["ok"] is True, out
    _run(jobs)
    after = _files(shoot / "raw")
    assert {k: v for k, v in after.items() if k in first} == first, "the first card's frames were touched"
    assert len(after) == 7, sorted(after)          # 3 + 3 renamed beside them + 1 new
    assert (shoot / "cull" / "logs" / "ingest-1.log").exists()
    note = studio.Shoot(shoot).info()["ingest"]
    assert note["state"] == "done" and note["files"] == 4
    assert [e["files"] for e in note["earlier"]] == [3]


def test_a_culled_shoot_takes_no_card_and_a_shoot_being_culled_says_so(srv, lib, monkeypatch):
    card = _card(lib)
    monkeypatch.setattr(studio, "cards", lambda: [str(card)])
    shoot = _shoot(lib, "2026-09-26", {"kind": "sport"})
    (shoot / "cull").mkdir()
    (shoot / "cull" / "cull.csv").write_text("file,rating\nTSC00000.ARW,3\n")
    before = _files(shoot)
    out = post(srv, "/api/ingest", {"card": str(card), "name": "2026-09-26", "into": True})
    assert out["error"].startswith("2026-09-26 has been culled, so a card is not added to it now.")
    assert _files(shoot) == before

    other = _shoot(lib, "2026-09-27", {"kind": "sport"})
    untouched = _files(other)
    jobs = studio.Handler.jobs
    assert jobs.start("cull", "culling 2026-09-27", [sys.executable, "-c", "import time; time.sleep(3)"],
                      lib / "c.log", shoot="2026-09-27")
    out = post(srv, "/api/ingest", {"card": str(card), "name": "2026-09-27", "into": True})
    assert out["error"].startswith("2026-09-27 is being culled now.")
    assert _files(other) == untouched
    jobs.stop()
    assert _until(lambda: not jobs.status()["running"])


def test_a_cull_waiting_goes_behind_a_card_added_to_its_shoot(srv, lib, monkeypatch):
    card = _card(lib)
    monkeypatch.setattr(studio, "cards", lambda: [str(card)])
    _shoot(lib, "2026-09-26", {"kind": "sport"})
    jobs = studio.Handler.jobs
    jobs.hold(True)
    jobs.add("cull", "2026-09-26", {})
    out = post(srv, "/api/ingest", {"card": str(card), "name": "2026-09-26", "into": True,
                                    "then_cull": True, "queue": True})
    assert out["ok"] is True, out
    assert [(q["kind"], q["shoot"]) for q in jobs.queue] == [("ingest", "2026-09-26"), ("cull", "2026-09-26")]
    jobs.hold(False)
    _run(jobs)
    kinds = [(x["kind"], x["shoot"]) for x in jobs.status()["queue_done"]]
    assert kinds == [("ingest", "2026-09-26"), ("cull", "2026-09-26")], "one cull, over both"


# ------------------------------------------------ a card into a shoot half copied

def _half_copied(lib: Path, card: Path, name: str, landed: int, log: str) -> Path:
    """A shoot the copy of `card` did not finish into: `landed` of its frames
    arrived, with the card's own times, and `log` is what the copy said."""
    import shutil
    shoot = lib / "shoots" / name
    (shoot / "raw").mkdir(parents=True)
    for q in sorted((card / "DCIM" / "100MSDCF").iterdir())[:landed]:
        shutil.copy2(q, shoot / "raw" / q.name)
    (shoot / "cull" / "logs").mkdir(parents=True)
    (shoot / "cull" / "logs" / "ingest.log").write_text(f"$ python ingest.py {card} {name}\n{log}")
    return shoot


def _other_camera(lib: Path) -> Path:
    b = lib / "Volumes" / "B"
    d = b / "DCIM" / "100MSDCF"
    d.mkdir(parents=True)
    for i in range(2):
        (d / f"DSC{i:05d}.ARW").write_bytes(b"OTHER" + bytes([i + 7]) * 4096)
    return b


REFUSED = ("The copy of another card into 2026-09-26 did not finish. Put that card back to finish it, "
           "or copy this one into a shoot of its own.")


@pytest.mark.parametrize("log, landed", [
    ("copying 5 files, 0.0 GB\n@@ copy 2 5\n", 2),
    ("copying 5 files, 0.0 GB\n@@ copy 5 5\nverification FAILED for: TSC00002.ARW\n"
     "The card was not written to; copy it again.\n", 2),
])
def test_another_card_is_not_added_to_a_shoot_whose_copy_did_not_finish(srv, lib, monkeypatch, log, landed):
    """Card A came out at 2 of 5 (or its copy failed its check). A second
    camera's card added to the shoot wrote over A's log, the shoot read done,
    and the cull followed on half the night - after which A could no longer be
    finished into it. Now the second card is refused, nothing is changed, and
    A put back finishes the copy and is followed by the cull."""
    a, b = _card(lib, "A", frames=5), _other_camera(lib)
    monkeypatch.setattr(studio, "cards", lambda: [str(a), str(b)])
    shoot = _half_copied(lib, a, "2026-09-26", landed, log)
    before = _files(shoot)
    was = studio.Shoot(shoot).info()["ingest"]["state"]
    assert was in ("stopped", "failed")
    jobs = studio.Handler.jobs

    out = post(srv, "/api/ingest", {"card": str(b), "name": "2026-09-26", "into": True, "then_cull": True})
    assert out.get("error") == REFUSED, out
    out = post(srv, "/api/ingest", {"card": str(b), "name": "2026-09-26", "into": True, "then_cull": True,
                                    "queue": True})
    assert out.get("error") == REFUSED, out
    time.sleep(0.3)
    assert _files(shoot) == before, "a refused card changed the shoot"
    assert not _seen(jobs, "cull", "2026-09-26")
    assert studio.Shoot(shoot).info()["ingest"]["state"] == was

    # Card A, put back, is the one card that may finish it.
    out = post(srv, "/api/ingest", {"card": str(a), "name": "2026-09-26", "into": True, "then_cull": True})
    assert out["ok"] is True, out
    assert _until(lambda: _seen(jobs, "cull", "2026-09-26")), jobs.status()
    _run(jobs)
    note = studio.Shoot(shoot).info()["ingest"]
    assert note["state"] == "done" and note["files"] == 5 and "earlier" not in note, note
    raw = sorted(p.name for p in (shoot / "raw").iterdir() if not p.name.endswith(".unverified"))
    assert raw == [f"TSC{i:05d}.ARW" for i in range(5)]


def test_a_card_on_the_list_is_refused_at_its_turn_when_the_copy_before_it_stopped(lib, monkeypatch):
    """Two cards in, the second put on the list behind the first's copy: when
    its turn comes the first has stopped, and the second is not copied."""
    a, b = _card(lib, "A", frames=5), _other_camera(lib)
    monkeypatch.setattr(studio, "cards", lambda: [str(a), str(b)])
    _half_copied(lib, a, "2026-09-26", 2, "copying 5 files, 0.0 GB\n@@ copy 2 5\n")
    with pytest.raises(studio.NotNow) as e:
        studio.work_build("ingest", "2026-09-26", {"card": str(b), "into": True})
    assert str(e.value) == REFUSED
    made = studio.work_build("ingest", "2026-09-26", {"card": str(a), "into": True})
    assert made["over"] == lib / "shoots" / "2026-09-26" / "cull" / "logs" / "ingest.log"


def test_a_copy_that_did_not_finish_keeps_its_log_and_holds_the_cull(srv, lib, monkeypatch):
    """Should another card's copy ever start over an unfinished one, the
    unfinished copy's log is set aside and kept, the shoot goes on saying a
    card of it did not finish, and no cull follows. That card, put back,
    finishes it, and the record of it is the finished copy's."""
    a, b = _card(lib, "A", frames=5), _other_camera(lib)
    monkeypatch.setattr(studio, "cards", lambda: [str(a), str(b)])
    shoot = _half_copied(lib, a, "2026-09-26", 2, "copying 5 files, 0.0 GB\n@@ copy 2 5\n")
    logs = shoot / "cull" / "logs"
    jobs = studio.Handler.jobs
    assert jobs.start("ingest", "copying the card into 2026-09-26",
                      [studio.PY, str(studio.HERE / "ingest.py"), str(b), "2026-09-26", "--verify", "in-flight"],
                      logs / "ingest.log", shoot="2026-09-26",
                      after_done=studio._follow_with_a_cull("2026-09-26"))
    _run(jobs)
    assert sorted(p.name for p in logs.iterdir()) == ["ingest-1.log", "ingest.log"]
    note = studio.Shoot(shoot).info()["ingest"]
    assert note["state"] == "done" and note["files"] == 2
    assert note["earlier"] == [{"state": "stopped", "files": 2, "of": 5}]
    assert not _seen(jobs, "cull", "2026-09-26"), "a cull followed a shoot one card of which is half there"
    assert studio._unfinished_copy(studio.Shoot(shoot))["log"] == logs / "ingest-1.log"

    # B again: refused. A: finishes it, in the last copy's place.
    assert post(srv, "/api/ingest", {"card": str(b), "name": "2026-09-26", "into": True})["error"] == REFUSED
    out = post(srv, "/api/ingest", {"card": str(a), "name": "2026-09-26", "into": True, "then_cull": True})
    assert out["ok"] is True, out
    assert _until(lambda: _seen(jobs, "cull", "2026-09-26")), jobs.status()
    _run(jobs)
    note = studio.Shoot(shoot).info()["ingest"]
    assert note["state"] == "done" and note["files"] == 5
    assert note["earlier"] == [{"state": "done", "files": 2, "proof": "hashed on the way in and read back"}]
    assert studio._unfinished_copy(studio.Shoot(shoot)) is None


def test_a_copy_the_engine_went_down_under_goes_back_and_finishes_into_its_shoot(srv, lib, monkeypatch):
    """The engine went down at 2 of 5. The copy goes back at the top of Up
    Next, held, as the copy that finishes into the same shoot; Continue, with
    the card in, copies only what did not arrive, leaves what did exactly as
    it is, and the cull it was asked to be followed by follows it."""
    a = _card(lib, "A", frames=5)
    monkeypatch.setattr(studio, "cards", lambda: [str(a)])
    shoot = _half_copied(lib, a, "2026-09-26", 2, "copying 5 files, 0.0 GB\n@@ copy 2 5\n")
    before = _files(shoot / "raw")
    jobs = studio.Handler.jobs
    # What the engine that went down wrote down about the copy it ran: no
    # process left to put down, and no line saying how it ended.
    studio.write_json_atomic(jobs.running_store(), {
        "id": 7, "kind": "ingest", "title": "copying the card into 2026-09-26", "shoot": "2026-09-26",
        "opts": {"card": str(a), "verify": "in-flight", "kind": "sport", "then_cull": True},
        "does": "", "keeps": True, "pid": 0, "script": "ingest.py", "started": time.time() - 60,
        "run": "1-0-gone", "log": str(shoot / "cull" / "logs" / "ingest.log"), "from_list": False})
    jobs.load()
    st = jobs.status()
    assert [q["kind"] for q in st["queue"]] == ["ingest"]
    assert st["queue"][0]["interrupted"] is True and st["queue"][0]["opts"]["into"] is True
    assert st["queue_held"] is True
    assert (st["queue_held_after"]["files"], st["queue_held_after"]["of"]) == (2, 5)
    assert _files(shoot / "raw") == before, "the restart changed the shoot"

    jobs.hold(False)
    assert _until(lambda: _seen(jobs, "cull", "2026-09-26")), jobs.status()
    _run(jobs)
    after = _files(shoot / "raw")
    assert {k: v for k, v in after.items() if k in before} == before, "what had arrived was rewritten"
    raw = sorted(p.name for p in (shoot / "raw").iterdir() if not p.name.endswith(".unverified"))
    assert raw == [f"TSC{i:05d}.ARW" for i in range(5)]
    note = studio.Shoot(shoot).info()["ingest"]
    assert note["state"] == "done" and note["files"] == 5, note


def test_a_new_shoot_starts_from_the_focus_he_set_not_the_floor_a_card_moved_it_to(lib):
    """The cull moves the face floor for a card whose own scale is outside
    every card it was set on, and records the floor it used. A new shoot
    starts from the focus he set there - its own card moves it for itself -
    and not from a number he never chose."""
    import cull
    last = _shoot(lib, "2026-09-19", {"kind": "sport", "style": "action", "focus": 1.6})
    cull.record_run(last / "shoot.json", "action", 1.34, asked=1.6)
    ran = json.loads((last / "shoot.json").read_text())["cull_ran_with"]
    assert ran == {"style": "action", "focus": 1.34, "asked": 1.6}
    new = studio.Shoot(_shoot(lib, "2026-09-26", {"kind": "sport"}))
    assert studio._cull_settings(new) == ("action", 1.6, "2026-09-19")
    # Not moved: nothing more is written.
    cull.record_run(last / "shoot.json", "action", 1.6, asked=1.6)
    assert json.loads((last / "shoot.json").read_text())["cull_ran_with"] == {"style": "action", "focus": 1.6}
