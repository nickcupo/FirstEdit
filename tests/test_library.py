"""library.py says what every file in a shoot is, and nothing may be deleted
or moved without asking it.

    .venv/bin/python -m pytest tests/test_library.py -q

The two modules that answer that question carry their own fixture-based
selftests, written before there was a tests/ folder. They were run by hand and
by nothing else, so a change could break either of them and every check here
would still pass. They are run first.

Nothing here reads or writes a library; every fixture is under tmp_path.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import archive  # noqa: E402
import library  # noqa: E402
import reclaim  # noqa: E402

SIG = library.TAG_SIGNATURE + "\n"


def test_librarys_own_fixture_selftest_passes(capsys, monkeypatch):
    monkeypatch.setattr(archive, "ARCHIVE", Path("/nonexistent-archive"))
    assert library._selftest() == 0
    assert "FAIL" not in capsys.readouterr().out


def test_reclaims_own_fixture_selftest_passes(capsys, monkeypatch):
    monkeypatch.setattr(archive, "ARCHIVE", Path("/nonexistent-archive"))
    assert reclaim.selftest() == 0
    assert "FAIL" not in capsys.readouterr().out


def _flat(tmp_path: Path, cull_name: str) -> Path:
    """A folder of loose RAWs culled into the folder cull.py would make."""
    shoot = tmp_path / "ducks-and-drills"
    shoot.mkdir(parents=True)
    (shoot / "TSC00.ARW").write_bytes(b"RAW0" + b"\0" * 4096)
    cull = shoot / cull_name
    (cull / "thumbs").mkdir(parents=True)
    (cull / "cull.csv").write_text("file,rating\nTSC00.ARW,3\nTSC01.ARW,3\n")
    (cull / "thumbs" / library.TAG).write_text(SIG)
    for stem in ("TSC00", "TSC01"):
        (cull / "thumbs" / f"{stem}.jpg").write_bytes(b"J" * 2048)
    return shoot


def test_a_flat_shoot_culled_into_an_underscore_cull_is_still_read(tmp_path):
    """cull.py still writes <folder>/_cull when it is handed a folder not
    named raw/, and reclaim, migrate and archive all read one where they find
    it. This answered <shoot>/cull whatever was on disk, so on such a shoot it
    read no cull.csv, computed no pixels of record, and offered the last
    thumbnail of a cleared frame as a cache."""
    for name in ("cull", "_cull"):
        shoot = _flat(tmp_path / name, name)
        assert library.cull_dir(shoot) == shoot / name
        sv = library.survey(shoot)
        assert sv.frames == {"TSC00", "TSC01"}, sv.frames
        assert list(sv.of_record) == ["TSC01"], sv.of_record
        offered = {e.rel for e in sv.reclaimable()[0]}
        assert f"{name}/thumbs/TSC00.jpg" in offered
        assert f"{name}/thumbs/TSC01.jpg" not in offered, "the last pixels of TSC01 were offered"


def test_the_cache_tag_itself_is_never_offered(tmp_path):
    """The tag is the licence to clean the folder. Offered as bytes to take
    back, it makes the reclaimable figure wrong by one file per cache folder
    and, taken, it stops the folder ever being recognised as a cache again."""
    shoot = _flat(tmp_path, "cull")
    sv = library.survey(shoot)
    tag = next(e for e in sv.entries if e.path.name == library.TAG)
    assert sv.untouchable(tag) == "the note that allows this folder to be cleaned"
    assert tag.rel not in {e.rel for e in sv.reclaimable()[0]}


def test_a_raw_inside_a_cache_folder_is_a_photograph(tmp_path):
    """Any non-symlink RAW under cull/, edit/ or picks/ was called a link the
    tool made, with a named writer and no check that the frame it links to is
    here. Inside a tagged folder that made it reclaimable: the guard offered a
    photograph, and counted its bytes as space coming back."""
    shoot = _flat(tmp_path, "cull")
    stray = shoot / "cull" / "thumbs" / "TSC02.ARW"
    stray.write_bytes(b"RAW2" + b"\0" * 4096)
    sv = library.survey(shoot)
    e = next(e for e in sv.entries if e.rel == "cull/thumbs/TSC02.ARW")
    assert e.kind is library.Kind.ORIGINAL, e.why
    assert sv.untouchable(e), "a RAW was offered"
    assert "cull/thumbs/TSC02.ARW" not in {x.rel for x in sv.reclaimable()[0]}

    # A RAW in edit/ whose original is here as well is still the link gather
    # made, and still costs nothing to remove.
    (shoot / "edit").mkdir()
    (shoot / "edit" / "TSC00.ARW").hardlink_to(shoot / "TSC00.ARW")
    sv = library.survey(shoot)
    link = next(e for e in sv.entries if e.rel == "edit/TSC00.ARW")
    assert link.kind is library.Kind.DERIVED and link.names_here == 2


def test_a_camera_jpeg_is_an_original_and_its_thumbnail_is_not(tmp_path):
    """On a shoot shot to JPEG, library filed raw/TSC00.JPG as "nothing here
    wrote it" and then promoted its thumbnail to the last surviving pixels of
    a frame whose original was sitting beside it."""
    shoot = tmp_path / "2026-01-01-lake"
    (shoot / "raw").mkdir(parents=True)
    (shoot / "raw" / "TSC00.JPG").write_bytes(b"JPEG" + b"\0" * 4096)
    (shoot / "cull" / "thumbs").mkdir(parents=True)
    (shoot / "cull" / "cull.csv").write_text("file,rating\nTSC00.JPG,3\n")
    (shoot / "cull" / "thumbs" / library.TAG).write_text(SIG)
    (shoot / "cull" / "thumbs" / "TSC00.jpg").write_bytes(b"J" * 2048)

    sv = library.survey(shoot)
    rels = {e.rel: e for e in sv.entries}
    assert rels["raw/TSC00.JPG"].kind is library.Kind.ORIGINAL, rels["raw/TSC00.JPG"].why
    assert sv.of_record == {}, sv.of_record
    assert rels["cull/thumbs/TSC00.jpg"].kind is library.Kind.DERIVED
    assert "cull/thumbs/TSC00.jpg" in {e.rel for e in sv.reclaimable()[0]}


def test_the_finders_droppings_are_not_a_finished_export(tmp_path):
    """A .DS_Store in export/ answered "a finished export", which is the
    number the Done card reads back as the shoot having been delivered."""
    assert library._deliverable("export/.DS_Store", ".DS_Store") is None
    assert library._deliverable("edit/edited/.DS_Store", ".DS_Store") is None
    assert library._deliverable("export/TSC00_DxO.jpg", "TSC00_DxO.jpg") == "a finished export"


def test_review_json_is_a_decision_and_cull_csv_is_output(tmp_path):
    """Both are held and neither is ever deleted here; what changed is what
    the report calls them. review.json - his record of the bursts he has been
    through - was not on the list at all, and cull.csv, a measurement the next
    cull makes again, was called a decision of his."""
    shoot = tmp_path / "2026-01-01-lake"
    (shoot / "raw").mkdir(parents=True)
    (shoot / "raw" / "TSC00.ARW").write_bytes(b"RAW" + b"\0" * 4096)
    (shoot / "cull").mkdir()
    (shoot / "cull" / "cull.csv").write_text("file,rating\nTSC00.ARW,3\n")
    (shoot / "cull" / "review.json").write_text('{"bursts": {}}')
    sv = library.survey(shoot)
    rels = {e.rel: e for e in sv.entries}
    assert rels["cull/review.json"].kind is library.Kind.DECISION
    assert rels["cull/review.json"].why == "a decision file"
    assert rels["cull/cull.csv"].why == "pipeline output at cull/'s top level"
    assert rels["cull/cull.csv"].kind is library.Kind.DECISION, "output is still never deleted"


def test_the_vectors_the_keeper_check_reads_are_held_and_named(tmp_path, monkeypatch):
    """cull/similar.npz is the one thing that keeps a delivered shoot inside
    the keeper check after its RAWs and decodes are gone. It is held like
    cull.csv - never reclaimed, never dropped - and the report says what it is
    rather than "at cull/'s top level"."""
    monkeypatch.setattr(archive, "ARCHIVE", Path("/nonexistent-archive"))
    shoot = tmp_path / "2026-01-01-lake"
    (shoot / "raw").mkdir(parents=True)
    (shoot / "raw" / "TSC00.ARW").write_bytes(b"RAW" + b"\0" * 4096)
    (shoot / "cull").mkdir()
    (shoot / "cull" / "cull.csv").write_text("file,rating\nTSC00.ARW,3\n")
    (shoot / "cull" / "similar.npz").write_bytes(b"PK\x03\x04" + b"\0" * 64)
    e = {x.rel: x for x in library.survey(shoot).entries}["cull/similar.npz"]
    assert e.kind is library.Kind.DECISION and "keeper check" in e.why
    assert reclaim.category(reclaim.Shoot(shoot), shoot / "cull" / "similar.npz") == reclaim.DECISIONS


# ------------------------------------------------ where the shoots stand
#
# The studio appended "shoots" to PHOTOS_ROOT in six places. Pointing it at
# the folder his shoots are visibly in - which is the obvious one to pick in a
# folder chooser - made it look in <root>/shoots/shoots, a folder that did not
# exist until the studio's own mkdir made it. Empty sidebar, every shoot still
# on the disk, and nothing said.


def _shoot(at: Path, inside: str = "raw") -> Path:
    (at / inside).mkdir(parents=True)
    (at / inside / "TSC00001.ARW").write_bytes(b"")
    return at


def test_the_shelf_is_the_shoots_folder_when_the_root_is_the_library(tmp_path):
    _shoot(tmp_path / "shoots" / "2026-09-16")
    assert library.shelf(tmp_path) == tmp_path / "shoots"


def test_the_shelf_is_itself_when_the_root_already_is_the_shoots_folder(tmp_path):
    """His setting, exactly: PHOTOS_ROOT=~/photos/shoots."""
    _shoot(tmp_path / "shoots" / "2026-09-16")
    _shoot(tmp_path / "shoots" / "2026-09-19")
    assert library.shelf(tmp_path / "shoots") == tmp_path / "shoots"


def test_a_folder_that_holds_shoots_is_the_shelf_whatever_it_is_called(tmp_path):
    _shoot(tmp_path / "a-wedding")
    assert library.shelf(tmp_path) == tmp_path


def test_a_root_with_nothing_in_it_names_the_folder_it_would_make(tmp_path):
    assert library.shelf(tmp_path) == tmp_path / "shoots"
    # And nothing was made by asking.
    assert not (tmp_path / "shoots").exists()


def test_a_delivered_shoot_with_its_raws_cleared_is_still_a_shoot(tmp_path):
    """The lounge: 6 ARW against 296 culled frames, and one day none at all.
    layout() cannot see it - there is no raw/ and no loose frame - and it is
    still, obviously, a shoot."""
    (tmp_path / "shoots" / "2026-09-12-lounge" / "cull").mkdir(parents=True)
    assert library.is_shoot(tmp_path / "shoots" / "2026-09-12-lounge")
    assert library.shelf(tmp_path) == tmp_path / "shoots"


def test_a_folder_with_nothing_whatever_in_it_is_not_a_shoot(tmp_path):
    """shoots/shoots, the one the old mkdir left behind."""
    (tmp_path / "shoots" / "shoots").mkdir(parents=True)
    assert not library.is_shoot(tmp_path / "shoots" / "shoots")
    assert library.shelf(tmp_path) == tmp_path / "shoots"


def test_a_shoot_of_loose_frames_is_a_shoot(tmp_path):
    """The ducks: 98 ARW and no raw/."""
    ducks = tmp_path / "shoots" / "ducksAndDeadlifts"
    ducks.mkdir(parents=True)
    (ducks / "TSC05691.ARW").write_bytes(b"")
    assert library.is_shoot(ducks)
    assert library.shelf(tmp_path) == tmp_path / "shoots"


def test_a_cache_the_tool_mints_says_first_edit_and_one_from_before_is_still_a_cache(tmp_path):
    """The Built by line is free text nothing compares, and the signature
    line is what makes a tag a tag: a folder tagged under the old name stays
    a cache that reclaim may offer."""
    made = library.cache_dir(tmp_path / "fresh")
    text = (made / library.TAG).read_text()
    assert "by First Edit." in text and library.tag_writer(made) == "first-edit"
    assert library.is_cache(made)
    before = tmp_path / "before"
    before.mkdir()
    (before / library.TAG).write_text(SIG + "# This directory is a cache rebuilt from the RAWs by photo-pipeline.\n"
                                            "# Built by: cull\n")
    assert library.is_cache(before) and library.tag_writer(before) == "cull"
