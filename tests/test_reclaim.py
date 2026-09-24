"""reclaim removes derived bytes and refuses anything it cannot name a writer
for. Three things it was wrong about, and each of them stopped it working on a
shoot that is in exactly the state the rest of the pipeline puts shoots in.

    .venv/bin/python -m pytest tests/test_reclaim.py -q

The module's own fixture-based selftest is run from tests/test_library.py.
Nothing here reads or writes a library; every fixture is under tmp_path.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import archive  # noqa: E402
import reclaim  # noqa: E402

SIG = reclaim.TAG_SIGNATURE + "\n"


def _shoot(tmp_path: Path, ext: str = ".ARW") -> Path:
    """A culled shoot with its caches tagged, the way the cull leaves one."""
    shoot = tmp_path / "shoots" / "2026-01-01-lake"
    (shoot / "raw").mkdir(parents=True)
    (shoot / "cull").mkdir()
    names = [f"TSC0{i}{ext}" for i in range(4)]
    for n in names:
        (shoot / "raw" / n).write_bytes(b"RAW" + n.encode() + b"\0" * 4096)
    (shoot / "cull" / "cull.csv").write_text("file,rating\n" + "".join(f"{n},3\n" for n in names))
    for d in ("thumbs", "previews"):
        (shoot / "cull" / d).mkdir()
        (shoot / "cull" / d / reclaim.CACHE_TAG).write_text(SIG)
        for n in names:
            (shoot / "cull" / d / f"{Path(n).stem}.jpg").write_bytes(b"J" * 8192)
    (shoot / "shoot.json").write_text('{"kind": "other"}')
    return shoot


def _archive(shoot: Path, up: bool = True) -> None:
    """Push every RAW to iCloud and drop it from the disk, as archive.py does."""
    man = {"shoot": shoot.name, "frames": {}}
    for p in sorted((shoot / "raw").iterdir()):
        d = archive.dest_for(shoot, p.name)
        d.parent.mkdir(parents=True, exist_ok=True)
        if up:
            d.write_bytes(p.read_bytes())
        man["frames"][p.name] = {"bytes": p.stat().st_size, "sha256": archive.sha256(p)}
        p.unlink()
    (shoot / "cull" / archive.MANIFEST).write_text(json.dumps(man))


def test_an_archived_shoot_is_not_refused_as_though_its_cache_were_the_last_copy(tmp_path, monkeypatch):
    """Every RAW of a finished shoot goes to iCloud and comes off the disk -
    that is what archive.py is for - and after it, reclaim read the shoot as
    one whose 1,157 frames had all been lost. It refused the whole shoot for
    ever and billed its 8.3 GB of caches as originals, while archive.json in
    the same folder recorded where the photographs went."""
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    shoot = _shoot(tmp_path)
    _archive(shoot)
    s = reclaim.Shoot(shoot)
    assert s.archived == {"TSC00", "TSC01", "TSC02", "TSC03"}
    assert reclaim.refusals(s) == [], reclaim.refusals(s)
    m = reclaim.measure(s)
    assert m["bytes"][reclaim.ORIGINALS] == 0, "the cache was billed as the photographs"
    assert m["reclaimable_files"] == 8, m["reclaimable_files"]
    assert reclaim.last_copy_renderings(s)[0] == 0

    assert reclaim.reclaim(shoot, apply=True) == 0
    assert not list((shoot / "cull" / "thumbs").glob("*.jpg"))
    assert (shoot / "cull" / "thumbs" / reclaim.CACHE_TAG).exists()
    assert (shoot / "cull" / "cull.csv").exists() and (shoot / "cull" / archive.MANIFEST).exists()


def test_a_frame_the_archive_no_longer_holds_still_refuses_the_shoot(tmp_path, monkeypatch, capsys):
    """The manifest saying a frame was pushed is not the same as the copy
    being there. When it is not, the derived pixels ARE the last copy again."""
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    shoot = _shoot(tmp_path)
    _archive(shoot, up=False)
    why = reclaim.refusals(reclaim.Shoot(shoot))
    assert any("no original on this Mac or in iCloud" in x for x in why), why
    assert reclaim.reclaim(shoot, apply=True) == 2
    assert len(list((shoot / "cull" / "thumbs").glob("*.jpg"))) == 4


def test_a_tag_without_the_signature_licences_nothing(tmp_path, monkeypatch):
    """The licence to empty a folder was taken from the file's NAME. A note he
    wrote under that name, or another tool's file, is not this tool's leave to
    unlink what is in the folder - and library.py, which reads the signature
    line, would have refused the same folder."""
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    shoot = _shoot(tmp_path)
    (shoot / "cull" / "thumbs" / reclaim.CACHE_TAG).write_text("mine, do not clean\n")
    s = reclaim.Shoot(shoot)
    assert (shoot / "cull" / "thumbs") not in s.tagged
    plan = [p for p, _n in reclaim.plan_removal(s)]
    assert not any(p.parent.name == "thumbs" for p in plan), plan
    assert any(p.parent.name == "previews" for p in plan)


def test_a_shoot_shot_to_jpeg_has_originals(tmp_path, monkeypatch):
    """ingest and the cull both take JPEGs. This file counted their bytes and
    then knew of no originals at all, so every culled frame read as lost: the
    shoot was refused for ever, and verify had nothing to checksum."""
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    shoot = _shoot(tmp_path, ext=".JPG")
    s = reclaim.Shoot(shoot)
    assert sorted(s.originals) == ["TSC00", "TSC01", "TSC02", "TSC03"]
    assert reclaim.refusals(s) == []
    assert reclaim.category(s, shoot / "raw" / "TSC00.JPG") == reclaim.ORIGINALS
    assert reclaim.category(s, shoot / "cull" / "thumbs" / "TSC00.jpg") == reclaim.DERIVED

    assert reclaim.verify(shoot, record=True) == 0
    man = reclaim.read_manifest(shoot / reclaim.MANIFEST_NAME)
    assert sorted(man) == [f"raw/TSC0{i}.JPG" for i in range(4)], man
    # And the originals are never in the removal plan, whatever their suffix.
    assert not any(p.parent.name == "raw" for p, _n in reclaim.plan_removal(reclaim.Shoot(shoot)))


def test_a_raw_and_a_jpeg_of_one_frame_are_recorded_under_the_raw(tmp_path, monkeypatch):
    """A camera writing both leaves TSC00.ARW and TSC00.JPG side by side. They
    are one frame, and the RAW is the one the rest of the shoot was made from."""
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    shoot = _shoot(tmp_path)
    (shoot / "raw" / "TSC00.JPG").write_bytes(b"JPEG" + b"\0" * 2048)
    s = reclaim.Shoot(shoot)
    assert s.originals["TSC00"].name == "TSC00.ARW"
    assert reclaim.category(s, shoot / "raw" / "TSC00.JPG") == reclaim.ORIGINALS
