"""The two rules that keep `./pl archive expire` from destroying a photograph,
and the progress line the studio's one bar is drawn from.

    .venv/bin/python -m pytest tests/test_storage.py -q

expire is the only command in the pipeline that can leave a frame with no copy
anywhere. Both rules below were wrong once and both were quiet about it, so
they are pinned here rather than left to the next reading of the file.

Nothing in here reads or writes ~/photos. Every fixture is built under pytest's
own tmp_path, and the archive is pointed at a folder inside it.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import archive  # noqa: E402
import migrate  # noqa: E402
import reclaim  # noqa: E402


def _shoot(base: Path, frames: int = 2, keepers: list[str] | None = None) -> Path:
    """A finished shoot with its RAWs already pushed, as archive.json records
    them: the state every expire runs against."""
    shoot = base / "shoots" / "2026-01-01-gym"
    (shoot / "raw").mkdir(parents=True)
    (shoot / "cull").mkdir(parents=True)
    (shoot / "shoot.json").write_text(json.dumps({"kind": "other", "finished": "2020-01-01"}))
    man = {"shoot": shoot.name, "frames": {}}
    for i in range(frames):
        name = f"TSC0{i}.ARW"
        body = bytes([i]) * 8192
        (shoot / "raw" / name).write_bytes(body)
        up = archive.dest_for(shoot, name)
        up.parent.mkdir(parents=True, exist_ok=True)
        up.write_bytes(body)
        man["frames"][name] = {"bytes": len(body), "sha256": archive.sha256(up), "at": "2020-01-01T00:00:00Z"}
    (shoot / "cull" / archive.MANIFEST).write_text(json.dumps(man))
    if keepers is not None:
        (shoot / "cull" / "selects.json").write_text(json.dumps(keepers))
    return shoot


def _evict(path: Path) -> None:
    """Leave the name and take the bytes.

    macOS evicts with a DATALESS file: the path is there, stat reports the
    real size, and no blocks are allocated. `archive.local` reads the dataless
    flag and st_blocks, and a sparse file of the same length answers that
    second half the same way: it is the only half of the condition a test can
    build without iCloud. `archive.is_dataless` is False for it, which is why
    the push test below uses it for the blockless-and-unflagged case."""
    size = path.stat().st_size
    path.unlink()
    with open(path, "wb") as fh:
        fh.truncate(size)
    assert path.stat().st_size == size and path.lstat().st_blocks == 0


def test_an_evicted_local_original_is_not_a_spare(tmp_path, monkeypatch, capsys):
    """A frame whose local original has itself been evicted is the ONLY copy.

    This read `local(...) or is_dataless(...)`, which counted an evicted local
    original as a live second copy - so the archived file, the only copy with
    bytes anywhere, was filed as the safe one to delete. It skipped both the
    --yes-delete-originals gate and the typed confirmation on the page, and
    the page drew it as a spare. A name is not a copy."""
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    shoot = _shoot(tmp_path, frames=2, keepers=[])

    # The control: with its bytes on the disk, TSC00 is a spare.
    assert archive.expire(shoot, apply=False, after=0, include_keepers=False, destroy_last_copy=False) == 0
    out = capsys.readouterr().out
    assert "2  archived spares" in out and "0  ONLY copies" in out

    _evict(shoot / "raw" / "TSC00.ARW")
    assert archive.expire(shoot, apply=False, after=0, include_keepers=False, destroy_last_copy=False) == 0
    out = capsys.readouterr().out
    assert "1  archived spares" in out, out
    assert "1  ONLY copies" in out, out

    # And it is not removed, because --yes-delete-originals was not given.
    assert archive.expire(shoot, apply=True, after=0, include_keepers=False, destroy_last_copy=False) == 0
    assert archive.dest_for(shoot, "TSC00.ARW").exists(), "the only copy of TSC00 was destroyed"
    assert not archive.dest_for(shoot, "TSC01.ARW").exists(), "the real spare was not removed"


def test_keepers_cannot_get_past_the_no_answer_key_refusal(tmp_path, monkeypatch, capsys):
    """--keepers used to get past the missing answer key, which had it exactly
    backwards. With no selects.json nothing can be identified as a keeper, so
    --keepers does not include a known set: it removes the only protection the
    shoot has and makes every frame eligible."""
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    shoot = _shoot(tmp_path, frames=2, keepers=None)
    assert not (shoot / "cull" / "selects.json").exists()

    rc = archive.expire(shoot, apply=True, after=0, include_keepers=True, destroy_last_copy=True)
    out = capsys.readouterr().out
    assert rc == 1, out
    assert "has no answer key" in out, out
    assert archive.dest_for(shoot, "TSC00.ARW").exists()
    assert archive.dest_for(shoot, "TSC01.ARW").exists()
    assert json.loads((shoot / "cull" / archive.MANIFEST).read_text())["frames"], "the manifest was rewritten"


def test_every_long_loop_says_where_it_has_got_to(tmp_path, monkeypatch, capsys):
    """`@@ <stage> <done> <total>` is the one convention the studio's single
    progress bar is drawn from (cull.py prints them). None of the storage commands
    printed it, so the page scraped push's "40/1157 copied and verified" line
    and got nothing at all for drop, pull, expire, reclaim or verify: a drop
    of the action shoot is a 26.9 GB re-hash that sat at 0% from start to finish.

    The stage words are the ones studio.py's STAGE_WORDS already knows. reclaim verify
    reports as `check` because that is the name the page starts it under."""
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    shoot = _shoot(tmp_path, frames=3, keepers=["TSC00.ARW"])

    def marks(stage: str) -> list[tuple[int, int]]:
        return [(int(a), int(b)) for st, a, b in
                (l.split()[1:] for l in capsys.readouterr().out.splitlines() if l.startswith("@@ "))
                if st == stage]

    archive.drop(shoot, apply=True)
    assert marks("drop") == [(0, 3), (1, 3), (2, 3), (3, 3)]

    archive.pull(shoot, apply=True)
    assert marks("pull") == [(0, 3), (1, 3), (2, 3), (3, 3)]

    # TSC00 is the keeper and is protected; the other two are spares and go.
    archive.expire(shoot, apply=True, after=0, include_keepers=False, destroy_last_copy=False)
    assert marks("expire") == [(0, 2), (1, 2), (2, 2)]

    # Which leaves those two, and a frame that was never pushed, to copy up.
    (shoot / "raw" / "TSC09.ARW").write_bytes(b"9" * 8192)
    archive.push(shoot, apply=True, force=False)
    assert marks("push") == [(0, 3), (1, 3), (2, 3), (3, 3)]

    reclaim.verify(shoot)
    assert marks("check") == [(0, 4), (1, 4), (2, 4), (3, 4), (4, 4)]


def test_migrate_apply_says_where_it_has_got_to(tmp_path, capsys):
    """The same convention across a migration, whose two halves - the
    decisions moving and the loose RAWs being adopted - are one count, because
    they are one wait to the person watching."""
    flat = tmp_path / "shoots" / "loose-frames"
    flat.mkdir(parents=True)
    for i in range(3):
        (flat / f"DUCK0{i}.ARW").write_bytes(b"d" * 4096)
    (flat / "cull").mkdir()
    (flat / "cull" / "selects.json").write_text('["DUCK00.ARW"]')

    rc = migrate.main([str(flat), "--apply", "--adopt", "--root", str(tmp_path)])
    out = capsys.readouterr().out
    assert rc == 0, out
    got = [tuple(int(x) for x in l.split()[2:]) for l in out.splitlines() if l.startswith("@@ migrate ")]
    assert got and got[0][0] == 0 and got[-1] == (got[0][1], got[0][1]), got
    assert [d for d, _t in got] == sorted(d for d, _t in got), got
    assert (flat / "decisions" / "selects.json").exists()
    assert (flat / "raw" / "DUCK00.ARW").exists()


def test_a_flat_shoots_cull_is_the_one_every_other_module_reads(tmp_path):
    """A flat shoot is 98 loose ARW with no raw/ subfolder. Its cull is
    <shoot>/cull, which is where library.py and reclaim.py both look.

    archive.parts said <shoot>/_cull - the fork of the old cull.py that left a
    stray _cull/ beside the dog shoot, moved back by hand on 13 September - so
    on a flat shoot the archive manifest and the answer key were looked for in
    a folder nothing else reads. `expire` would have found no selects.json and
    refused a shoot that has one, and `push` would have minted the stray
    folder again the first time it wrote."""
    flat = tmp_path / "loose-frames"
    (flat / "cull").mkdir(parents=True)
    (flat / "DUCK00.ARW").write_bytes(b"d" * 4096)
    (flat / "cull" / "selects.json").write_text('["DUCK00.ARW"]')
    raw, cull = archive.parts(flat)
    assert raw == flat.resolve() and cull == (flat / "cull").resolve()
    assert archive.keepers_of(flat) == {"DUCK00.ARW"}
    assert archive.manifest_path(flat) == (flat / "cull" / archive.MANIFEST).resolve()

    # A standard shoot is untouched, and an _cull/ that is already on a disk
    # somewhere is still read.
    std = tmp_path / "2026-01-01-gym"
    (std / "raw").mkdir(parents=True)
    assert archive.parts(std)[1] == (std / "cull").resolve()
    legacy = tmp_path / "old-flat"
    (legacy / "_cull").mkdir(parents=True)
    assert archive.parts(legacy)[1] == (legacy / "_cull").resolve()


def test_an_unreadable_answer_key_is_not_answered_from_the_old_copy(tmp_path, monkeypatch, capsys):
    """keepers_of tried decisions/selects.json and then fell back to
    cull/selects.json, taking whichever parsed first. So a key that had moved
    and then become unreadable was answered from whatever older copy was left
    behind at the old name, and expire went on to delete against a stale list
    of keepers without saying a word. Unreadable is None, and None refuses."""
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    shoot = _shoot(tmp_path, frames=2, keepers=["TSC00.ARW"])
    (shoot / "decisions").mkdir()
    (shoot / "decisions" / "selects.json").write_text('["TSC00.ARW", "TSC01.ARW"]')
    assert archive.keepers_of(shoot) == {"TSC00.ARW", "TSC01.ARW"}

    (shoot / "decisions" / "selects.json").write_text("{ truncated")
    assert archive.keepers_of(shoot) is None, "the stale copy in cull/ answered for it"
    rc = archive.expire(shoot, apply=True, after=0, include_keepers=False, destroy_last_copy=True)
    out = capsys.readouterr().out
    assert rc == 1 and "has no answer key" in out, out
    assert archive.dest_for(shoot, "TSC00.ARW").exists()
    assert archive.dest_for(shoot, "TSC01.ARW").exists()

    # A decision file that is readable but is not a list of frames is not an
    # answer key either.
    (shoot / "decisions" / "selects.json").write_text('{"photos": {}}')
    assert archive.keepers_of(shoot) is None


def test_a_flat_shoot_can_be_pushed_dropped_and_pulled(tmp_path, monkeypatch, capsys):
    """A flat shoot is 98 loose ARW: no raw/, no cull/, no decisions/.

    Two things went wrong on that shape and both were silent in their own way.
    push copied every frame to iCloud and then died in write_json_atomic,
    because decision_path names the manifest's folder and makes no folder, so
    nothing was recorded and the next push copied all 2.3 GB up again.
    links_in_shoot then looked for raw/, edit/, cull/picks and reels/, none of
    which a flat shoot has, and drop --apply unlinked nothing at all while
    printing that it had removed the originals and freed the bytes."""
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    flat = tmp_path / "shoots" / "loose-frames"
    flat.mkdir(parents=True)
    (flat / "shoot.json").write_text(json.dumps({"kind": "other", "finished": "2020-01-01"}))
    for i in range(2):
        (flat / f"DUCK0{i}.ARW").write_bytes(bytes([i]) * 8192)

    assert archive.push(flat, apply=True, force=False) == 0
    man = json.loads(archive.manifest_path(flat).read_text())["frames"]
    assert sorted(man) == ["DUCK00.ARW", "DUCK01.ARW"], man

    # Every name really goes, and the count of further links is not negative.
    assert archive.drop(flat, apply=True) == 0
    out = capsys.readouterr().out
    assert "further hard links" not in out, out
    assert not list(flat.glob("*.ARW")), "drop said it had removed them and had not"
    # The way back is the command that copies, by the shoot's name: a plain
    # `pull` is a dry run, and the path it printed was his whole home folder.
    assert "./pl archive pull loose-frames --apply" in out, out
    assert str(flat) not in out.split("bring them down again with:")[-1], out

    assert archive.pull(flat, apply=True) == 0
    assert sorted(p.name for p in flat.glob("*.ARW")) == ["DUCK00.ARW", "DUCK01.ARW"]


def test_drop_takes_every_name_of_a_frame_and_no_other_frames(tmp_path, monkeypatch):
    """A RAW in a standard shoot is one inode under up to four names, and
    unlinking raw/ alone frees nothing while edit/ still points at it.

    The neighbour is here because links_in_shoot compared st_ino alone. An
    inode number is unique on one volume and nowhere else, and the list this
    builds is passed straight to unlink(), so it is keyed on (st_dev, st_ino)
    like every other inode key in the storage modules."""
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    shoot = _shoot(tmp_path, frames=2, keepers=[])
    for sub in ("edit", "cull/picks", "reels/burst9"):
        (shoot / sub).mkdir(parents=True, exist_ok=True)
        (shoot / sub / "TSC00.ARW").hardlink_to(shoot / "raw" / "TSC00.ARW")

    st = (shoot / "raw" / "TSC00.ARW").lstat()
    names = archive.links_in_shoot(shoot, (st.st_dev, st.st_ino))
    assert sorted(str(p.relative_to(shoot)) for p in names) == [
        "cull/picks/TSC00.ARW", "edit/TSC00.ARW", "raw/TSC00.ARW", "reels/burst9/TSC00.ARW"]

    assert archive.drop(shoot, apply=True) == 0
    assert not list(shoot.rglob("TSC00.ARW")), "a name was left behind, so no bytes came back"
    assert not list(shoot.rglob("TSC01.ARW"))


# ------------------------------------------------ the bytes, not the name
#
# Everything below is one rule met in five places: a file's name says nothing
# about its bytes. Each test builds the case where the name is right and the
# bytes are not, and checks that the command about to delete something looks.


def _stranger(path: Path) -> None:
    """A different photograph under the same name and the same size: a second
    card whose counter wrapped, a restore of the wrong frame."""
    size = path.stat().st_size
    path.unlink()
    path.write_bytes(b"\xee" * size)


def test_expire_does_not_call_a_stranger_with_the_name_a_spare(tmp_path, monkeypatch, capsys):
    """expire filed an archived frame as a spare - removable by plain --apply,
    with no --yes-delete-originals and no typed confirmation - whenever a file
    of that name with blocks behind it sat in raw/. If that file is another
    photograph, the archived copy was the only one."""
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    shoot = _shoot(tmp_path, frames=3, keepers=[])
    _stranger(shoot / "raw" / "TSC00.ARW")                     # same size, other bytes
    (shoot / "raw" / "TSC01.ARW").write_bytes(b"\x01" * 100)    # other size

    assert archive.expire(shoot, apply=False, after=0, include_keepers=False, destroy_last_copy=False) == 0
    out = capsys.readouterr().out
    assert "1  archived spares" in out and "2  ONLY copies" in out, out
    assert "2 have a file of the same name here that is not the" in out, out

    assert archive.expire(shoot, apply=True, after=0, include_keepers=False, destroy_last_copy=False) == 0
    assert archive.dest_for(shoot, "TSC00.ARW").exists(), "the only copy of TSC00 was destroyed as a spare"
    assert archive.dest_for(shoot, "TSC01.ARW").exists(), "the only copy of TSC01 was destroyed as a spare"
    assert not archive.dest_for(shoot, "TSC02.ARW").exists(), "the real spare was kept"


def test_expire_looks_again_before_each_spare_goes(tmp_path, monkeypatch, capsys):
    """The hashing is a long read. An original replaced after it was checked
    turns its archived copy into the last one, so the copy stays."""
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    shoot = _shoot(tmp_path, frames=2, keepers=[])
    real = archive.progress

    def progress(stage, done, total):
        real(stage, done, total)
        if stage == "check" and done == total:
            _stranger(shoot / "raw" / "TSC01.ARW")
    monkeypatch.setattr(archive, "progress", progress)
    archive.expire(shoot, apply=True, after=0, include_keepers=False, destroy_last_copy=False)
    out = capsys.readouterr().out
    assert "kept  TSC01.ARW: its original changed after it was checked" in out, out
    assert archive.dest_for(shoot, "TSC01.ARW").exists()
    assert not archive.dest_for(shoot, "TSC00.ARW").exists()
    assert "TSC01.ARW" in json.loads((shoot / "cull" / archive.MANIFEST).read_text())["frames"]


def test_push_refuses_a_raw_with_no_bytes_behind_its_name(tmp_path, monkeypatch, capsys):
    """push screened on the eviction flag alone. A RAW with a size and no
    blocks - no flag either - was hashed as zeros, copied up and recorded as
    healthy, and drop would then have verified that record and removed it."""
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    shoot = tmp_path / "shoots" / "2026-01-02-lake"
    (shoot / "raw").mkdir(parents=True)
    (shoot / "shoot.json").write_text(json.dumps({"finished": "2020-01-01"}))
    (shoot / "raw" / "TSC00.ARW").write_bytes(b"\x07" * 8192)
    (shoot / "raw" / "TSC01.ARW").write_bytes(b"\x08" * 8192)
    _evict(shoot / "raw" / "TSC01.ARW")
    assert not archive.is_dataless(shoot / "raw" / "TSC01.ARW")

    assert archive.push(shoot, apply=True, force=False) == 1
    out = capsys.readouterr().out
    assert "no bytes behind the name" in out and "- TSC01.ARW" in out, out
    assert not (tmp_path / "icloud").exists() or not list((tmp_path / "icloud").rglob("*.ARW"))
    assert not archive.manifest_path(shoot).exists()


def test_pull_restores_over_a_name_with_no_bytes(tmp_path, monkeypatch, capsys):
    """pull skipped every frame whose NAME was in raw/, bytes or not, so the
    frames the panel offered to bring back were the ones it never did."""
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    shoot = _shoot(tmp_path, frames=2)
    good = (shoot / "raw" / "TSC00.ARW").read_bytes()
    _evict(shoot / "raw" / "TSC00.ARW")

    assert archive.pull(shoot, apply=True) == 0
    out = capsys.readouterr().out
    assert "1 frames to bring back" in out, out
    assert (shoot / "raw" / "TSC00.ARW").read_bytes() == good
    assert archive.local(shoot / "raw" / "TSC00.ARW")


def test_a_download_that_cannot_happen_is_not_waited_out(tmp_path, monkeypatch, capsys):
    """materialise sat out its whole ten minutes after the read that asks for
    the bytes had already failed, and pull paid that per frame: an offline
    pull of 198 evicted frames was 33 hours of the same line."""
    import time as _time
    t0 = _time.time()
    assert archive.materialise(tmp_path / "not-there.ARW", timeout=600) is False
    assert _time.time() - t0 < 5

    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    shoot = _shoot(tmp_path, frames=3)
    for i in range(3):
        (shoot / "raw" / f"TSC0{i}.ARW").unlink()
        _evict(archive.dest_for(shoot, f"TSC0{i}.ARW"))       # evicted up there
    asked: list[Path] = []
    monkeypatch.setattr(archive, "materialise", lambda p, *a, **k: asked.append(p) or False)
    assert archive.pull(shoot, apply=True) == 1
    out = capsys.readouterr().out
    assert len(asked) == 1, asked
    assert "2 more are evicted in iCloud and were not asked for after TSC00.ARW" in out, out


def test_drop_leaves_a_frame_that_also_has_a_name_of_his(tmp_path, monkeypatch, capsys):
    """links_in_shoot knew raw/, edit/, cull/picks and reels/. calib-skin/
    holds hand-made names on the same bytes, each with a .dop of its own, so
    drop removed the others, reported the bytes freed, and left the inode on
    the disk while status called the frame dropped. A name of his is not
    drop's to remove, and without it nothing is freed, so the frame stays."""
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    shoot = _shoot(tmp_path, frames=2, keepers=[])
    (shoot / "edit").mkdir()
    (shoot / "edit" / "TSC00.ARW").hardlink_to(shoot / "raw" / "TSC00.ARW")
    (shoot / "calib-skin").mkdir()
    (shoot / "calib-skin" / "TSC00_1base.ARW").hardlink_to(shoot / "raw" / "TSC00.ARW")
    (shoot / "calib-skin" / "TSC00_1base.ARW.dop").write_text("his")

    assert archive.drop(shoot, apply=False) == 0
    out = capsys.readouterr().out
    assert "kept  TSC00.ARW: it also has a name of yours, calib-skin/TSC00_1base.ARW" in out, out
    assert "would free 8 KB by removing 1 originals" in out, out
    assert "further hard links" not in out, out

    assert archive.drop(shoot, apply=True) == 0
    for rel in ("raw/TSC00.ARW", "edit/TSC00.ARW", "calib-skin/TSC00_1base.ARW", "calib-skin/TSC00_1base.ARW.dop"):
        assert (shoot / rel).exists(), f"{rel} was removed"
    assert not (shoot / "raw" / "TSC01.ARW").exists()


def test_drop_does_not_remove_a_file_that_is_not_the_one_archived(tmp_path, monkeypatch, capsys):
    """Only the iCloud copy was hashed. A RAW that had since taken the name
    was removed as though it were the frame in iCloud."""
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    shoot = _shoot(tmp_path, frames=2, keepers=[])
    _stranger(shoot / "raw" / "TSC00.ARW")
    archive.drop(shoot, apply=True)
    out = capsys.readouterr().out
    assert "kept  TSC00.ARW: the file here is not the one that was archived" in out, out
    assert (shoot / "raw" / "TSC00.ARW").read_bytes()[:1] == b"\xee"
    assert not (shoot / "raw" / "TSC01.ARW").exists()


def test_drop_waits_for_icloud_to_say_it_has_the_copy(tmp_path, monkeypatch, capsys):
    """drop hashed the copy in the local iCloud Drive folder and removed every
    local name on that strength, while push itself says nothing is safe to
    drop until iCloud has uploaded it. A copy iCloud says it has not uploaded
    stays; so does one inside iCloud Drive that iCloud will not answer for."""
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    shoot = _shoot(tmp_path, frames=2, keepers=[])
    monkeypatch.setattr(archive, "uploaded", lambda d: False if d.name == "TSC00.ARW" else None)
    monkeypatch.setattr(archive, "icloud_managed", lambda d: d.name == "TSC01.ARW")
    assert archive.drop(shoot, apply=True) == 1
    out = capsys.readouterr().out
    assert "kept  TSC00.ARW: iCloud has not finished uploading the copy" in out, out
    assert "kept  TSC01.ARW: iCloud would not say whether it has uploaded the copy" in out, out
    assert (shoot / "raw" / "TSC00.ARW").exists() and (shoot / "raw" / "TSC01.ARW").exists()

    # Outside iCloud Drive there is no upload to wait for, and it says so.
    monkeypatch.setattr(archive, "uploaded", lambda d: None)
    monkeypatch.setattr(archive, "icloud_managed", lambda d: False)
    assert archive.drop(shoot, apply=True) == 0
    out = capsys.readouterr().out
    assert "2 of the copies are in" in out and "which is not iCloud Drive" in out, out
    assert not list((shoot / "raw").glob("*.ARW"))


def test_drop_looks_again_just_before_each_frame_goes(tmp_path, monkeypatch, capsys):
    """All the hashing happens first and all the unlinking after. A copy
    removed from iCloud in between - from another device, say - must not have
    its local names taken on the strength of a check made minutes ago."""
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    shoot = _shoot(tmp_path, frames=2, keepers=[])
    real = archive.progress

    def progress(stage, done, total):
        real(stage, done, total)
        if stage == "drop" and done == total:
            archive.dest_for(shoot, "TSC01.ARW").unlink()
    monkeypatch.setattr(archive, "progress", progress)
    assert archive.drop(shoot, apply=True) == 0
    out = capsys.readouterr().out
    assert "kept  TSC01.ARW: it changed after it was checked" in out, out
    assert (shoot / "raw" / "TSC01.ARW").exists(), "the only copy left was removed"
    assert "removed 1 originals" in out, out


def test_drop_counts_only_what_it_actually_removed(tmp_path, monkeypatch, capsys):
    """An unlink that failed was printed and the frame counted as removed
    anyway, with its bytes in the total freed."""
    import stat as _stat
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    shoot = _shoot(tmp_path, frames=2, keepers=[])
    (shoot / "edit").mkdir()
    (shoot / "edit" / "TSC00.ARW").hardlink_to(shoot / "raw" / "TSC00.ARW")
    (shoot / "edit").chmod(_stat.S_IRUSR | _stat.S_IXUSR)       # the link cannot go
    try:
        assert archive.drop(shoot, apply=True) == 1
    finally:
        (shoot / "edit").chmod(0o755)
    out = capsys.readouterr().out
    assert "removed 1 originals and their links; 8 KB back." in out, out
    assert "1 could not be removed completely" in out, out
    assert (shoot / "edit" / "TSC00.ARW").exists()


def test_a_stopped_push_leaves_no_part_file_and_keeps_what_it_verified(tmp_path):
    """The studio's Stop is SIGTERM. push used to die on the spot: the .part
    it was writing stayed inside iCloud Drive to be uploaded as a file of its
    own, and the frames already copied and verified were not in the manifest,
    so the next push copied them all again."""
    import subprocess
    shoot = tmp_path / "shoots" / "2026-01-03-lake"
    (shoot / "raw").mkdir(parents=True)
    (shoot / "cull").mkdir()
    (shoot / "shoot.json").write_text(json.dumps({"finished": "2020-01-01"}))
    for i in range(3):
        (shoot / "raw" / f"TSC0{i}.ARW").write_bytes(bytes([i]) * 8192)
    (tmp_path / "icloud").mkdir()
    script = tmp_path / "stop.py"
    script.write_text(f"""
import os, shutil, signal, sys
sys.path.insert(0, {str(Path(archive.__file__).parent)!r})
sys.argv = ["archive.py", "push", {str(shoot)!r}, "--apply"]
import archive
real, n = shutil.copyfile, [0]
def copyfile(a, b):
    n[0] += 1
    real(a, b)
    if n[0] == 2:
        os.kill(os.getpid(), signal.SIGTERM)     # Stop, while frame two is a .part
shutil.copyfile = copyfile
sys.exit(archive.main())
""")
    env = dict(__import__("os").environ, PIPELINE_ICLOUD=str(tmp_path / "icloud"), PHOTOS_ROOT=str(tmp_path))
    r = subprocess.run([sys.executable, str(script)], capture_output=True, text=True, env=env, timeout=60)
    assert r.returncode == 143, (r.returncode, r.stdout, r.stderr)
    up = tmp_path / "icloud" / "Photo Pipeline Archive" / shoot.name
    assert sorted(p.name for p in up.iterdir()) == ["TSC00.ARW"], "a .part was left inside iCloud Drive"
    man = json.loads(archive.manifest_path(shoot).read_text())["frames"]
    assert sorted(man) == ["TSC00.ARW"], man


def test_icloud_says_nothing_about_an_ordinary_file(tmp_path):
    """Measured: macOS answers every ubiquity key with no value at all for a
    file iCloud does not manage, not with False. So None is the answer here,
    and the copy is judged by where it sits."""
    f = tmp_path / "a.ARW"
    f.write_bytes(b"x")
    assert archive.icloud_says(f) is None
    assert archive.uploaded(tmp_path / "missing.ARW") is None
    assert archive.icloud_managed(f) is False
    assert archive.icloud_managed(archive.MOBILE_DOCUMENTS / "com~apple~CloudDocs" / "x.ARW") is True


# ------------------------------------------------ what the panel says after

def _said_on_the_panel(out: str) -> str:
    """The line the storage panel shows under how a job ended.

    The studio's log leaves out the `@@` marks, and the app's
    Job.refusalSentence takes the last line that is neither empty nor the
    `$ command` the log opens with."""
    lines = [l.strip() for l in out.splitlines()
             if l.strip() and not l.startswith("@@ ") and not l.strip().startswith("$ ")]
    return lines[-1]


def _no_terminal_in(line: str, tmp_path: Path) -> None:
    assert "./pl" not in line and " --" not in line, line
    assert str(tmp_path) not in line and "/" not in line.replace("·", ""), line
    assert line[0].isupper() or line[0].isdigit(), line


def test_after_a_storage_job_the_panel_is_told_the_result_in_its_own_words(tmp_path, monkeypatch, capsys):
    """After Copy the RAWs to iCloud the panel said `./pl archive drop` and his
    whole home path; after Remove the Local RAWs, `./pl archive pull … --apply`;
    after Take Back the Cache, "…this command works again." in lower case. The
    studio marks every job it starts, and the last line is then the result,
    naming the app's buttons. The same commands typed in a terminal keep their
    hints (test_a_flat_shoot_can_be_pushed_dropped_and_pulled)."""
    monkeypatch.setenv("PIPELINE_FOR_APP", "1")
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    flat = tmp_path / "shoots" / "loose-frames"
    flat.mkdir(parents=True)
    (flat / "shoot.json").write_text(json.dumps({"kind": "other", "finished": "2020-01-01"}))
    for i in range(2):
        (flat / f"DUCK0{i}.ARW").write_bytes(bytes([i]) * 8192)

    assert archive.push(flat, apply=True, force=False) == 0
    line = _said_on_the_panel(capsys.readouterr().out)
    assert line.startswith("2 copied and verified, 0 failed."), line
    assert "Remove the Local RAWs" in line, line
    _no_terminal_in(line, tmp_path)

    assert archive.drop(flat, apply=True) == 0
    line = _said_on_the_panel(capsys.readouterr().out)
    assert line == "Removed 2 originals and their links; 16 KB back. Bring the RAWs Back brings them down again.", line
    _no_terminal_in(line, tmp_path)

    assert archive.pull(flat, apply=True) == 0
    line = _said_on_the_panel(capsys.readouterr().out)
    assert line == "2 back, 0 failed.", line

    # Take Back the Cache, on a shoot whose caches the cull tagged.
    shoot = tmp_path / "shoots" / "2026-01-01-lake"
    (shoot / "raw").mkdir(parents=True)
    (shoot / "cull").mkdir()
    names = [f"TSC0{i}.ARW" for i in range(2)]
    for n in names:
        (shoot / "raw" / n).write_bytes(b"RAW" + n.encode() + b"\0" * 4096)
    (shoot / "cull" / "cull.csv").write_text("file,rating\n" + "".join(f"{n},3\n" for n in names))
    (shoot / "cull" / "thumbs").mkdir()
    (shoot / "cull" / "thumbs" / reclaim.CACHE_TAG).write_text(reclaim.TAG_SIGNATURE + "\n")
    for n in names:
        (shoot / "cull" / "thumbs" / f"{Path(n).stem}.jpg").write_bytes(b"J" * 8192)
    (shoot / "shoot.json").write_text('{"kind": "other"}')
    assert reclaim.reclaim(shoot, apply=True) == 0
    line = _said_on_the_panel(capsys.readouterr().out)
    assert line.startswith("Removed 2 files, "), line
    assert line.endswith("The next cull makes the cache again."), line
    _no_terminal_in(line, tmp_path)

    # Check Every Original records nothing, so it ends on its count and not
    # on the flag that would.
    reclaim.verify(shoot)
    line = _said_on_the_panel(capsys.readouterr().out)
    assert line.startswith("0 unchanged · 0 drifted · 2 not recorded yet"), line
    _no_terminal_in(line, tmp_path)


def test_the_studio_tells_every_job_it_starts_that_it_speaks_to_the_app(tmp_path):
    """Without the mark the commands above cannot tell the panel from a
    terminal, and would end on a command to type again."""
    import time
    import studio
    jobs = studio.Jobs()
    assert jobs.start("stor-check", "checking", [sys.executable, "-c",
                      "import common; print('for the app' if common.for_the_app() else 'for a terminal')"],
                      tmp_path / "job.log")
    for _ in range(200):
        if not jobs.status()["running"]:
            break
        time.sleep(0.05)
    assert _said_on_the_panel(jobs.status()["log"]) == "for the app"


def test_the_archive_keeps_its_name_now_that_the_app_is_first_edit():
    """Each shoot's archive.json keeps frame names only, and every path is
    rebuilt from this folder: another name here would read each archived
    frame as missing and push the next shoot into a second folder. ICLOUD is
    the suite's tmp folder here (conftest.py)."""
    assert archive.ARCHIVE_NAME == "Photo Pipeline Archive"
    assert archive.ARCHIVE == archive.ICLOUD / "Photo Pipeline Archive"
    assert archive.dest_for(Path("shoots/2026-09-16"), "TSC00001.ARW") == \
        archive.ICLOUD / "Photo Pipeline Archive" / "2026-09-16" / "TSC00001.ARW"


# ----------------------------------------- a copy the same night, before Finish

def _tonight(base: Path, frames: int = 3) -> Path:
    """Tonight's shoot, straight off the card: RAWs, a pick sharing an inode
    with one of them, a sidecar, and nothing marked finished."""
    shoot = base / "shoots" / "2026-09-23-night"
    (shoot / "raw").mkdir(parents=True)
    (shoot / "cull" / "picks").mkdir(parents=True)
    (shoot / "shoot.json").write_text(json.dumps({"kind": "other"}))
    for i in range(frames):
        (shoot / "raw" / f"TSC1{i}.ARW").write_bytes(bytes([i + 1]) * 8192)
    (shoot / "raw" / "TSC10.ARW.dop").write_text("sidecar")
    import os
    os.link(shoot / "raw" / "TSC10.ARW", shoot / "cull" / "picks" / "TSC10.ARW")
    return shoot


def _everything_in(shoot: Path) -> dict[str, tuple[int, str, int]]:
    """Every file in the shoot: its size, its hash and its link count."""
    return {str(p.relative_to(shoot)): (p.stat().st_size, archive.sha256(p), p.stat().st_nlink)
            for p in sorted(shoot.rglob("*")) if p.is_file()}


def test_a_shoot_not_finished_is_copied_up_and_nothing_here_is_removed(tmp_path, monkeypatch, capsys):
    """Copy the RAWs to iCloud the same night, before Finish: a backup before
    the card is formatted for the next shoot. It copies and reads back, and
    every file of the shoot is where it was, byte for byte, with the same
    names on the same bytes. It used to refuse any shoot not marked finished."""
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud" / "archive")
    shoot = _tonight(tmp_path)
    before = _everything_in(shoot)

    assert archive.push(shoot, apply=True, force=False) == 0, capsys.readouterr().out
    after = _everything_in(shoot)
    manifest = str(archive.manifest_path(shoot).relative_to(shoot))
    assert {k: v for k, v in after.items() if k != manifest} == before
    assert sorted(json.loads(archive.manifest_path(shoot).read_text())["frames"]) == \
        ["TSC10.ARW", "TSC11.ARW", "TSC12.ARW"]
    for name in ("TSC10.ARW", "TSC11.ARW", "TSC12.ARW"):
        assert archive.sha256(archive.dest_for(shoot, name)) == archive.sha256(shoot / "raw" / name)


def test_removing_the_local_raws_waits_for_finish_even_once_they_are_up(tmp_path, monkeypatch, capsys):
    """The rule push used to keep, where it belongs now: the RAWs of a shoot
    he has not finished are still going to be read, so Remove the Local RAWs
    refuses it, dry run or not, and nothing is removed. Finished, the same
    drop goes ahead - the control that shows the refusal is the only reason."""
    monkeypatch.setenv("PIPELINE_FOR_APP", "1")
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud" / "archive")
    shoot = _tonight(tmp_path)
    assert archive.push(shoot, apply=True) == 0
    capsys.readouterr()
    before = _everything_in(shoot)

    for apply in (False, True):
        assert archive.drop(shoot, apply=apply) == 1
        out = capsys.readouterr().out
        assert "2026-09-23-night is not finished yet, so its RAWs are still going to be read. Nothing was removed." in out
        assert _said_on_the_panel(out) == "Press Finish This Shoot on its Finish step first."
        assert _everything_in(shoot) == before

    (shoot / "shoot.json").write_text(json.dumps({"kind": "other", "finished": "2026-09-24"}))
    assert archive.drop(shoot, apply=True) == 0
    assert not list((shoot / "raw").glob("*.ARW"))


def test_with_no_icloud_drive_the_copy_refuses_and_leaves_nothing_behind(tmp_path, monkeypatch, capsys):
    """A Mac with iCloud Drive turned off: the copy says so before it reads a
    frame, makes no folder anywhere, writes no record into the shoot, and the
    app is told in its own words - no path, no variable to set."""
    gone = tmp_path / "no-icloud-here"
    monkeypatch.setattr(archive, "ICLOUD", gone)
    monkeypatch.setattr(archive, "ARCHIVE", gone / archive.ARCHIVE_NAME)
    shoot = _tonight(tmp_path)
    before = _everything_in(shoot)

    for apply in (False, True):
        assert archive.push(shoot, apply=apply) == 1
        out = capsys.readouterr().out
        assert f"iCloud Drive is not at {gone}." in out, out
    assert not gone.exists()
    assert _everything_in(shoot) == before
    assert not archive.manifest_path(shoot).exists()

    monkeypatch.setenv("PIPELINE_FOR_APP", "1")
    assert archive.push(shoot, apply=True) == 1
    line = _said_on_the_panel(capsys.readouterr().out)
    assert line == ("iCloud Drive is not turned on on this Mac, so nothing was done. "
                    "Turn it on in System Settings, then try again."), line
    # "iCloud" keeps its own lower-case i, so the check is only for the path
    # and the variable a typist would set.
    assert "/" not in line and "PIPELINE_ICLOUD" not in line and "./pl" not in line
    assert not gone.exists()
    assert _everything_in(shoot) == before


def test_the_plan_sheet_shows_why_the_local_raws_stay_and_why_nothing_went_up(tmp_path, monkeypatch, capsys):
    """The two refusals above, as the plan sheet lists them: the lines the
    commands printed, and no button to press."""
    import studio
    monkeypatch.setenv("PIPELINE_FOR_APP", "1")
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud" / "archive")
    shoot = _tonight(tmp_path)
    assert archive.push(shoot, apply=True) == 0
    capsys.readouterr()
    archive.drop(shoot, apply=False)
    plan = studio._parse_plan("drop", capsys.readouterr().out, {})
    assert plan["ready"] is False
    assert plan["refusals"] == ["2026-09-23-night is not finished yet, so its RAWs are still going to be read. "
                                "Nothing was removed."]

    monkeypatch.setattr(archive, "ICLOUD", tmp_path / "no-icloud-here")
    archive.push(shoot, apply=False)
    plan = studio._parse_plan("push", capsys.readouterr().out, {})
    assert plan["ready"] is False
    assert plan["refusals"] == ["iCloud Drive is not turned on on this Mac, so nothing was done. "
                                "Turn it on in System Settings, then try again."]
