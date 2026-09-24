"""edit/ is the folder he opens in PhotoLab, and gather rebuilds it.

    .venv/bin/python -m pytest tests/test_gather.py -q

Two things it must never do, and both did: throw away an edit he made in
there, and call the machine's shortlist "the frames you kept".

Nothing here reads or writes a library; every fixture is under tmp_path.
"""
from __future__ import annotations

import csv
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import gather  # noqa: E402
import taste  # noqa: E402

CROP = "\t\t\t\tCropActive = true,\n\t\t\t\tCropRect = {\n\t\t\t\t\t0.1,\n\t\t\t\t},"
EXPOSURE = "\t\t\t\tLightingV3BlackPoint = -3.1,"


def _dop(when: str, overrides: str = "") -> str:
    """A sidecar shaped like PhotoLab's, with the date it writes inside it."""
    body = f"\t\t\tOverrides = {{\n{overrides}\n\t\t\t}},\n" if overrides else "\t\t\tOverrides = {\n\t\t\t},\n"
    return ("Sidecar = {\n"
            f'\tDate = "{when}",\n'
            "\tSource = {\n\t\tItems = {\n\t\t\t{\n"
            f'\t\t\tModificationDate = "{when}",\n'
            "\t\t\tRating = 3,\n"
            f"{body}"
            "\t\t\t},\n\t\t},\n\t},\n}\n")


def _shoot(tmp_path: Path, rows: list[tuple[str, int]], bursts: dict[str, str] | None = None) -> Path:
    """A culled shoot: `rows` is (file, the cull's rating), one burst each
    unless `bursts` says otherwise."""
    shoot = tmp_path / "shoots" / "2026-01-01-lake"
    (shoot / "raw").mkdir(parents=True)
    (shoot / "cull").mkdir()
    with (shoot / "cull" / "cull.csv").open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["file", "rating", "scene", "burst"])
        for i, (name, rating) in enumerate(rows):
            scene, burst = ((bursts or {}).get(name) or f"{i}/0").split("/")
            w.writerow([name, rating, scene, burst])
            (shoot / "raw" / name).write_bytes(b"RAW" + name.encode())
            (shoot / "raw" / f"{name}.dop").write_text(_dop("2026-01-01T10:00:00"))
    return shoot


def test_a_crop_only_edit_made_in_edit_is_promoted_and_not_deleted(tmp_path):
    """harvest promoted a sidecar only when taste.is_hand accepted it, and
    is_hand leaves out every key PhotoLab materialises on open - the crop, the
    white balance, the lens corrections. A frame he had only cropped held none
    of the others, so it was passed over and then unlinked by clear(): the
    edit was gone and nothing said so."""
    shoot = _shoot(tmp_path, [("TSC00.ARW", 5)])
    (shoot / "cull" / "selects.json").write_text('["TSC00.ARW"]')
    edit = gather.build(shoot)
    cropped = _dop("2026-02-02T12:00:00", CROP)
    assert taste.is_hand(gather._block(cropped, "Overrides")) is False, "the fixture is not the case this pins"
    (edit / "TSC00.ARW.dop").write_text(cropped)

    gather.build(shoot)
    assert (shoot / "raw" / "TSC00.ARW.dop").read_text() == cropped, "the crop was not promoted"
    assert (edit / "TSC00.ARW.dop").read_text() == cropped, "and it is back in edit/ for him to carry on"


def test_a_sidecar_that_cannot_be_promoted_is_set_aside_not_deleted(tmp_path):
    """The copy beside the RAW is the newer one (the preset step ran again),
    so the one in edit/ is not promoted. It is still his: it is copied into
    decisions/ before edit/ is rebuilt."""
    shoot = _shoot(tmp_path, [("TSC00.ARW", 5)])
    (shoot / "cull" / "selects.json").write_text('["TSC00.ARW"]')
    edit = gather.build(shoot)
    (edit / "TSC00.ARW.dop").write_text(_dop("2026-01-01T09:00:00", CROP))     # older than raw/'s
    fresh_raw = _dop("2026-03-03T08:00:00")
    (shoot / "raw" / "TSC00.ARW.dop").write_text(fresh_raw)

    gather.build(shoot)
    assert (shoot / "raw" / "TSC00.ARW.dop").read_text() == fresh_raw, "the older copy overwrote the newer one"
    kept = list((shoot / "decisions" / gather.SET_ASIDE).rglob("TSC00.ARW.dop"))
    assert len(kept) == 1, kept
    assert "CropActive" in kept[0].read_text()
    assert kept[0].parent.name == "edit"


def test_fresh_sets_the_edits_aside_instead_of_discarding_them(tmp_path):
    """--fresh skipped harvest and then cleared the folder, so every sidecar
    PhotoLab had written his edit into was unlinked without a word, while the
    docstring promised a rebuild loses nothing."""
    shoot = _shoot(tmp_path, [("TSC00.ARW", 5)])
    (shoot / "cull" / "selects.json").write_text('["TSC00.ARW"]')
    edit = gather.build(shoot)
    mine = _dop("2026-02-02T12:00:00", EXPOSURE)
    (edit / "TSC00.ARW.dop").write_text(mine)

    gather.build(shoot, fresh=True)
    assert (shoot / "raw" / "TSC00.ARW.dop").read_text() != mine, "--fresh promoted it after all"
    kept = list((shoot / "decisions" / gather.SET_ASIDE).rglob("TSC00.ARW.dop"))
    assert len(kept) == 1 and kept[0].read_text() == mine, kept


def test_the_copy_beside_the_raw_is_kept_when_an_edit_replaces_it(tmp_path):
    """Promoting an edit from edit/ writes over the sidecar beside the RAW.
    When that one carries PhotoLab's writing too, it is copied aside first:
    which of two edits of one frame he meant is not a machine's to decide."""
    shoot = _shoot(tmp_path, [("TSC00.ARW", 5)])
    (shoot / "cull" / "selects.json").write_text('["TSC00.ARW"]')
    edit = gather.build(shoot)
    beside = _dop("2026-01-05T10:00:00", EXPOSURE)
    (shoot / "raw" / "TSC00.ARW.dop").write_text(beside)
    newer = _dop("2026-02-02T12:00:00", CROP)
    (edit / "TSC00.ARW.dop").write_text(newer)

    gather.build(shoot)
    assert (shoot / "raw" / "TSC00.ARW.dop").read_text() == newer
    kept = list((shoot / "decisions" / gather.SET_ASIDE).rglob("*/raw/TSC00.ARW.dop"))
    assert len(kept) == 1 and kept[0].read_text() == beside, kept


def test_the_culls_own_picks_are_not_frames_you_kept(tmp_path):
    """Every row the cull rated 3 or more went into edit/, whether or not he
    had ever looked at the burst - and the studio reads edit/ back as frames
    he accepted, so the machine's shortlist became his answer key by way of a
    folder. What goes in now is a star of his, the cull's pick in a burst he
    has been through, and the answer key."""
    rows = [("TSC00.ARW", 5), ("TSC01.ARW", 4), ("TSC02.ARW", 2), ("TSC03.ARW", 5), ("TSC04.ARW", 5)]
    shoot = _shoot(tmp_path, rows, bursts={"TSC00.ARW": "0/0", "TSC01.ARW": "0/0", "TSC02.ARW": "0/0",
                                           "TSC03.ARW": "1/0", "TSC04.ARW": "2/0"})
    cull = shoot / "cull"
    # He was through scene 0 and left the cull's picks standing there; he
    # starred TSC02 up himself; scene 1 and 2 he has never opened.
    (cull / "organize.json").write_text(json.dumps({"photos": {"TSC02.ARW": {"rating": 4}}}))
    (cull / "review.json").write_text(json.dumps({"bursts": {"0/0": {"seen": "2026-01-02T10:00:00"}}}))
    assert gather.keepers(cull) == ["TSC00.ARW", "TSC01.ARW", "TSC02.ARW"]
    assert gather.unreviewed_picks(cull) == 2

    # With no record of bursts at all - a shoot worked before there was one -
    # the evidence answers instead, exactly as the studio reads it: a burst
    # holding a star of his is a burst he opened. Scene 0 is his that way, and
    # the answer key adds a frame from a scene he never opened.
    (cull / "review.json").unlink()
    (cull / "selects.json").write_text('["TSC04.ARW"]')
    assert gather.keepers(cull) == ["TSC00.ARW", "TSC01.ARW", "TSC02.ARW", "TSC04.ARW"]

    # A demotion of his beats the key and the cull alike.
    (cull / "organize.json").write_text(json.dumps({"photos": {"TSC04.ARW": {"rating": 1}}}))
    assert gather.keepers(cull) == []


def test_a_burst_record_from_an_earlier_cull_is_not_read(tmp_path):
    """Scene and burst numbers are handed out afresh by every cull, so a
    record written against an earlier one names frames this grouping does not
    have. It is not counted, and the evidence - the frames he pressed a key
    on - answers instead."""
    shoot = _shoot(tmp_path, [("TSC00.ARW", 5), ("TSC01.ARW", 5)],
                   bursts={"TSC00.ARW": "0/0", "TSC01.ARW": "1/0"})
    cull = shoot / "cull"
    (cull / "review.json").write_text(json.dumps({"bursts": {"0/0": {"seen": "x"}, "1/0": {"seen": "x"}},
                                                  "cull": "a-cull-that-is-gone"}))
    assert gather.keepers(cull) == []
    rows = list(csv.DictReader((cull / "cull.csv").open()))
    (cull / "review.json").write_text(json.dumps({"bursts": {"0/0": {"seen": "x"}},
                                                  "cull": gather._cull_stamp(rows)}))
    assert gather.keepers(cull) == ["TSC00.ARW"]


def test_gather_refuses_missing_source_and_leaves_edit_alone(tmp_path):
    """With the RAWs archived and dropped, raw/ holds sidecars and nothing
    else. This cleared edit/, linked nothing, and told him to open the empty
    folder in PhotoLab - which the studio's own button did for him."""
    shoot = _shoot(tmp_path, [("TSC00.ARW", 5)])
    (shoot / "cull" / "selects.json").write_text('["TSC00.ARW"]')
    edit = gather.build(shoot)
    (shoot / "raw" / "TSC00.ARW").unlink()

    with pytest.raises(FileNotFoundError) as e:
        gather.build(shoot)
    assert "archive" not in str(e.value).lower()
    assert "pull" not in str(e.value)
    assert str(shoot) not in str(e.value)
    assert "Restore" in str(e.value)
    assert (edit / "TSC00.ARW").exists(), "edit/ was cleared before it refused"
    assert (edit / "TSC00.ARW.dop").exists()


def test_the_closing_line_says_what_the_run_actually_did(tmp_path, monkeypatch, capsys):
    """"the RAWs are hard links, so this folder costs nothing" was printed
    whatever happened, including after the copy fallback: on a volume with no
    hard links the folder is a second copy of every frame."""
    shoot = _shoot(tmp_path, [("TSC00.ARW", 5)])
    (shoot / "cull" / "selects.json").write_text('["TSC00.ARW"]')
    monkeypatch.setattr(gather.os, "link", lambda *a: (_ for _ in ()).throw(OSError("no hard links here")))
    monkeypatch.setattr(sys, "argv", ["gather.py", str(shoot)])
    assert gather.main() == 0
    out = capsys.readouterr().out
    assert "1 of them had to be copied" in out, out
    assert "hard links, so they cost nothing" not in out, out


def test_nothing_kept_yet_says_how_many_the_cull_picked(tmp_path, monkeypatch, capsys):
    shoot = _shoot(tmp_path, [("TSC00.ARW", 5), ("TSC01.ARW", 5)])
    monkeypatch.setattr(sys, "argv", ["gather.py", str(shoot)])
    assert gather.main() == 1
    out = capsys.readouterr().out
    assert "nothing is kept yet" in out and "2 frames in bursts you have not looked through" in out, out
    assert not (shoot / "edit").exists()


@pytest.mark.parametrize("suffix", [".ARW", ".arw", ".NEF"])
def test_preview_keeper_resolves_unique_original_and_only_its_sidecar(tmp_path, suffix):
    shoot = _shoot(tmp_path, [("TSC00.jpg", 5), ("TSC01.jpg", 5)])
    (shoot / "cull" / "selects.json").write_text('["TSC00.ARW", "TSC01.ARW"]')
    raw = shoot / "raw"
    (raw / "TSC00.jpg").rename(raw / f"TSC00{suffix}")
    (raw / "TSC01.jpg").unlink()
    # JPEG colour parameters must never become the RAW starting edit.
    edit, result = gather._build(shoot, False)
    original = edit / f"TSC00{suffix}"
    assert original.samefile(raw / original.name)
    assert not list(edit.glob("*.dop"))
    assert result["missing"] == 1 and result["linked"] == 1
    recipe = _dop("2026-02-02T12:00:00", CROP)
    (raw / f"{original.name}.dop").write_text(recipe)
    gather.build(shoot)
    assert (edit / f"{original.name}.dop").read_text() == recipe
    assert not (edit / "TSC00.jpg.dop").exists()


@pytest.mark.parametrize("fresh", [False, True])
def test_ambiguous_preview_refuses_before_changing_edits(tmp_path, fresh):
    shoot = _shoot(tmp_path, [("TSC00.jpg", 5)])
    (shoot / "cull" / "selects.json").write_text('["TSC00.ARW"]')
    raw = shoot / "raw"
    (raw / "TSC00.jpg").rename(raw / "TSC00.ARW")
    (raw / "TSC00.NEF").write_bytes(b"other original")
    edit = shoot / "edit"
    edit.mkdir()
    mine = edit / "TSC00.ARW.dop"
    mine.write_text(_dop("2026-03-03T12:00:00", CROP))
    with pytest.raises(ValueError, match="more than one original"):
        gather.build(shoot, fresh=fresh)
    assert mine.read_text() == _dop("2026-03-03T12:00:00", CROP)
    assert not (raw / mine.name).exists()
    assert not (shoot / "decisions").exists()


@pytest.mark.parametrize("fresh", [False, True])
@pytest.mark.parametrize("still_kept", [False, True])
def test_partial_rebuild_never_removes_edit_only_original(tmp_path, fresh, still_kept):
    shoot = _shoot(tmp_path, [("TSC00.ARW", 5), ("TSC01.ARW", 5)])
    selected = shoot / "cull" / "selects.json"
    selected.write_text('["TSC00.ARW", "TSC01.ARW"]')
    edit = gather.build(shoot)
    original = edit / "TSC00.ARW"
    inode = original.stat().st_ino
    mine = _dop("2026-03-03T12:00:00", CROP)
    (edit / "TSC00.ARW.dop").write_text(mine)
    raw_side = shoot / "raw" / "TSC00.ARW.dop"
    before = raw_side.read_bytes()
    (shoot / "raw" / original.name).unlink()
    if not still_kept:
        selected.write_text('["TSC01.ARW"]')
    with pytest.raises(FileNotFoundError, match="edit/ still holds originals"):
        gather.build(shoot, fresh=fresh)
    assert original.stat().st_ino == inode
    assert (edit / "TSC00.ARW.dop").read_text() == mine
    assert raw_side.read_bytes() == before
    assert (edit / "TSC01.ARW").exists()


def test_absent_original_does_not_invent_archive_record(tmp_path):
    shoot = _shoot(tmp_path, [("TSC00.jpg", 5)])
    (shoot / "cull" / "selects.json").write_text('["TSC00.ARW"]')
    (shoot / "raw" / "TSC00.jpg").unlink()
    with pytest.raises(FileNotFoundError) as error:
        gather.build(shoot)
    message = str(error.value)
    assert "not found" in message
    assert "archiv" not in message and "pull" not in message
    assert str(shoot) not in message
    assert not (shoot / "edit").exists()


def test_exact_raw_wins_over_other_format_with_same_stem(tmp_path):
    shoot = _shoot(tmp_path, [("TSC00.ARW", 5)])
    (shoot / "cull" / "selects.json").write_text('["TSC00.ARW"]')
    (shoot / "raw" / "TSC00.NEF").write_bytes(b"different format")
    edit = gather.build(shoot)
    assert (edit / "TSC00.ARW").samefile(shoot / "raw" / "TSC00.ARW")
    assert not (edit / "TSC00.NEF").exists()


def test_two_keeper_names_cannot_share_one_destination(tmp_path):
    shoot = _shoot(tmp_path, [("TSC00.jpg", 5), ("TSC00.ARW", 5)])
    (shoot / "cull" / "organize.json").write_text(json.dumps({
        "photos": {"TSC00.jpg": {"rating": 5}, "TSC00.ARW": {"rating": 5}}}))
    (shoot / "raw" / "TSC00.jpg").unlink()
    with pytest.raises(ValueError, match="multiple keeper names"):
        gather.build(shoot)
    assert not (shoot / "edit").exists()


def test_exact_jpeg_remains_a_jpeg_and_rebuild_preserves_its_link(tmp_path):
    shoot = _shoot(tmp_path, [("TSC00.jpg", 5)])
    (shoot / "cull" / "selects.json").write_text('["TSC00.jpg"]')
    edit = gather.build(shoot)
    original = edit / "TSC00.jpg"
    inode = original.stat().st_ino
    gather.build(shoot)
    assert original.stat().st_ino == inode
    assert (edit / "TSC00.jpg.dop").exists()


def test_personal_jpeg_collision_refuses_before_harvest(tmp_path):
    shoot = _shoot(tmp_path, [("TSC00.jpg", 5)])
    (shoot / "cull" / "selects.json").write_text('["TSC00.jpg"]')
    edit = shoot / "edit"
    edit.mkdir()
    (edit / "TSC00.jpg").write_bytes(b"personal export")
    mine = _dop("2026-03-03T12:00:00", CROP)
    (edit / "TSC00.jpg.dop").write_text(mine)
    with pytest.raises(ValueError, match="different file"):
        gather.build(shoot)
    assert (edit / "TSC00.jpg").read_bytes() == b"personal export"
    assert (edit / "TSC00.jpg.dop").read_text() == mine
    assert (shoot / "raw" / "TSC00.jpg.dop").read_text() != mine


def test_public_summary_is_json_safe_and_build_still_returns_a_path(tmp_path):
    shoot = _shoot(tmp_path, [("TSC00.ARW", 5)])
    (shoot / "cull" / "selects.json").write_text('["TSC00.ARW"]')
    out, summary = gather.build_with_summary(shoot)
    assert out == shoot / "edit"
    assert json.loads(json.dumps(summary)) == {
        "total": 1, "gathered": 1, "missing": 0, "missing_files": []}
    assert gather.build(shoot) == out
