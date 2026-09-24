"""The card is the only copy until this run finishes.

    .venv/bin/python -m pytest tests/test_ingest.py -q

So: a run that refuses leaves nothing behind, a run that is finishing an
interrupted one asks for the room it actually needs, and a copy that fails
verification never keeps the frame's own name.

Nothing here reads or writes a library; every fixture is under tmp_path.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import common  # noqa: E402
import ingest  # noqa: E402


def _card(tmp_path: Path, frames: int = 3) -> Path:
    card = tmp_path / "CARD" / "DCIM" / "100MSDCF"
    card.mkdir(parents=True)
    for i in range(frames):
        (card / f"TSC0{i}.ARW").write_bytes(bytes([i + 1]) * 4096)
    return tmp_path / "CARD"


def _run(monkeypatch, tmp_path: Path, card: Path, name: str, *args) -> int:
    monkeypatch.setattr(ingest, "ROOT", tmp_path)
    monkeypatch.setattr(sys, "argv", ["ingest.py", str(card), name, *args])
    return ingest.main()


def test_a_refused_ingest_leaves_no_shoot_behind(monkeypatch, tmp_path, capsys):
    """raw/ was made before the run could refuse, so a card with nothing on it
    left an empty shoot on disk - and the studio then answers "already exists"
    to the person typing that name again."""
    empty = tmp_path / "CARD"
    (empty / "DCIM").mkdir(parents=True)
    assert _run(monkeypatch, tmp_path, empty, "2026-10-04-lake") == 1
    assert "nothing to copy" in capsys.readouterr().out
    assert not (tmp_path / "shoots" / "2026-10-04-lake").exists()

    card = _card(tmp_path)

    def no_room(*a, **k):
        raise ingest.NotEnoughRoom("not enough room for the copy")
    monkeypatch.setattr(ingest, "require_space", no_room)
    assert _run(monkeypatch, tmp_path, card, "2026-10-05-lake") == 1
    assert not (tmp_path / "shoots" / "2026-10-05-lake").exists()


def test_a_resumed_ingest_asks_for_the_room_it_still_needs(monkeypatch, tmp_path, capsys):
    """The room asked for was the whole card every time, so the copy that died
    on a full volume was refused on its second attempt over the frames it was
    not going to copy again - which is the one case the check exists for."""
    card = _card(tmp_path, frames=3)
    asked: list[int] = []
    real = ingest.require_space
    monkeypatch.setattr(ingest, "require_space", lambda path, need, what, **k: (asked.append(need), real(path, need, what))[1])
    assert _run(monkeypatch, tmp_path, card, "2026-10-04-lake") == 0
    assert asked == [3 * 4096], asked

    raw = tmp_path / "shoots" / "2026-10-04-lake" / "raw"
    (raw / "TSC02.ARW").unlink()                      # the frame the interrupted run never reached
    asked.clear()
    assert _run(monkeypatch, tmp_path, card, "2026-10-04-lake") == 0
    assert asked == [4096], asked
    out = capsys.readouterr().out
    assert "already in raw/ under the same name and size" in out, out


def test_a_copy_that_fails_verification_does_not_keep_the_frames_name(monkeypatch, tmp_path, capsys):
    """It stayed under the frame's real name with no sign that it was bad: the
    cull reads it as the photograph, and the next run finds the name taken and
    copies the frame again under a second name, leaving it there."""
    card = _card(tmp_path, frames=2)
    raw = tmp_path / "shoots" / "2026-10-04-lake" / "raw"
    real = ingest.sha
    monkeypatch.setattr(ingest, "sha", lambda p: "not the same" if p.parent == raw and p.name == "TSC01.ARW" else real(p))
    assert _run(monkeypatch, tmp_path, card, "2026-10-04-lake", "--verify", "end") == 1
    out = capsys.readouterr().out
    assert "verification FAILED" in out and "have been renamed" in out, out
    assert not (raw / "TSC01.ARW").exists(), "the bad copy still wears the frame's name"
    assert (raw / "TSC01.ARW.unverified").read_bytes() == (card / "DCIM" / "100MSDCF" / "TSC01.ARW").read_bytes()
    assert (raw / "TSC00.ARW").exists(), "the frame that verified was not touched"

    # And the name is free, so running it again copies that frame properly.
    monkeypatch.setattr(ingest, "sha", real)
    assert _run(monkeypatch, tmp_path, card, "2026-10-04-lake", "--verify", "end") == 0
    assert (raw / "TSC01.ARW").exists() and (raw / "TSC01.ARW.unverified").exists()


def test_a_file_that_was_already_there_is_not_renamed_by_this_run(monkeypatch, tmp_path):
    """Only what this run wrote is its to move. A copy already in raw/ that
    fails verification is a thing to look at, not a thing to rename."""
    card = _card(tmp_path, frames=1)
    raw = tmp_path / "shoots" / "2026-10-04-lake" / "raw"
    assert _run(monkeypatch, tmp_path, card, "2026-10-04-lake") == 0
    real = ingest.sha
    monkeypatch.setattr(ingest, "sha", lambda p: "not the same" if p.parent == raw else real(p))
    assert _run(monkeypatch, tmp_path, card, "2026-10-04-lake", "--verify", "end") == 1
    assert (raw / "TSC00.ARW").exists() and not (raw / "TSC00.ARW.unverified").exists()


def test_a_new_shoot_starts_with_the_folder_its_decisions_belong_in(monkeypatch, tmp_path):
    """Only migrate ever made decisions/, so a shoot ingested today had its
    first star written into cull/ - the cache folder the decisions were moved
    out of - and had to be migrated back out again later."""
    card = _card(tmp_path, frames=1)
    assert _run(monkeypatch, tmp_path, card, "2026-10-04-lake") == 0
    shoot = tmp_path / "shoots" / "2026-10-04-lake"
    assert (shoot / "decisions").is_dir()
    assert common.decision_path(shoot / "cull", "organize.json") == shoot / "decisions" / "organize.json"
