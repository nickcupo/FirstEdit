"""What a sidecar carries, and what a venue is called.

    .venv/bin/python -m pytest tests/test_sidecar.py -q

Three things were wrong in presets.py and one in taste.py, and all four are
the same mistake in different clothes: a fact about one installation on one
day, written into the source as a constant.

  * Sidecar.Software and Source.CafID were literals ("DxO PhotoLab 10.0.0.23",
    "C52941d"). PhotoLab 10 shipped on 2026-09-01 with 8 and 9 still in use,
    and the literal was already wrong on the machine that wrote it.
  * --force rebuilt an existing sidecar from a template frozen at whatever
    PhotoLab wrote when it was captured, so anything a later PhotoLab had put
    in the file went out with the rebuild.
  * A sidecar with no learned venue NAMED "2 - DxO Standard" and announced
    DxO's camera-body rendering, but the Base it wrote carried no rendering
    key at all.
  * A venue's identity was sha1 of the shoot's absolute path, so renaming the
    folder orphaned everything it had taught.

The fixtures here are the shape of PhotoLab's own output, not of the
template: a sidecar with an export recorded in it, a key no version of this
code knows, and CRLF line endings, which is what PhotoLab writes.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import presets  # noqa: E402
import taste  # noqa: E402

# A sidecar as PhotoLab writes one, cut down: an OutputItems block recording
# where the frame was exported, an IPTC description, a ProcessingStatus that
# is not the template's 0, and SomethingNewInPhotoLab11, which stands for
# every key a version of PhotoLab newer than this file may add.
PHOTOLAB_SIDECAR = (
    'Sidecar = {\n'
    '\tDate = "2026-09-18T22:29:42.1330000Z",\n'
    '\tSoftware = "DxO PhotoLab 11.1.0.9",\n'
    '\tSource = {\n'
    '\t\tCafID = "C45224d",\n'
    '\t\tItems = {\n'
    '\t\t\t{\n'
    '\t\t\tAlbums = "",\n'
    '\t\t\tCreationDate = "2026-09-18T22:04:18.4470000Z",\n'
    '\t\t\tIPTC = {\n'
    '\t\t\t\tcontentDescription = "a caption of his",\n'
    '\t\t\t},\n'
    '\t\t\tKeywords = {\n'
    '\t\t\t},\n'
    '\t\t\tModificationDate = "2026-09-18T22:17:37.9570000Z",\n'
    '\t\t\tName = "TSC05691.ARW",\n'
    '\t\t\tOrientation = 1,\n'
    '\t\t\tOutputItems = {\n'
    '\t\t\t\t{\n'
    '\t\t\t\tCreationDate = "2026-09-18T22:17:37.9550000Z",\n'
    '\t\t\t\tPath = "/somewhere/edited/TSC05691_DxO.jpg",\n'
    '\t\t\t\tUuid = "69D03B4B-6EFD-4ABB-8396-D1F45E6B8BB5",\n'
    '\t\t\t\t},\n'
    '\t\t\t},\n'
    '\t\t\tProcessingStatus = 3,\n'
    '\t\t\tRating = 0,\n'
    '\t\t\tSettings = {\n'
    '\t\t\t\tAppliedPresetDisplayName = "1 - DxO Style - Natural",\n'
    '\t\t\t\tAppliedPresetUniqueName = "DEFAULTS/1 - DxO Style - Natural.preset",\n'
    '\t\t\t\tBase = {\n'
    '\t\t\t\t\tExposureBias = 0,\n'
    '\t\t\t\t\tSomethingNewInPhotoLab11 = 7,\n'
    '\t\t\t\t},\n'
    '\t\t\t\tOverrides = {\n'
    '\t\t\t\t},\n'
    '\t\t\t\tVersion = "21.0",\n'
    '\t\t\t},\n'
    '\t\t\tShotDate = "2026-09-18T17:58:00.0000000-08:00",\n'
    '\t\t\tShouldProcess = 2,\n'
    '\t\t\tUuid = "BE76C73E-D03C-4DF6-B8F1-7C17BC12DDAB",\n'
    '\t\t\t},\n'
    '\t\t},\n'
    '\t\tUuid = "5D300210-4E1C-4D24-A5D3-A20343D9EBE8",\n'
    '\t},\n'
    '\tVersion = "21.0",\n'
    '}\n'
)


def _patched(text: str = PHOTOLAB_SIDECAR, base: str | None = None) -> str:
    base = base if base is not None else presets.partial_base({"ExposureBias": 0.42})
    out = presets.patch_dop(text, base, presets.STANDARD, rating=3, keywords=["Scene 01"],
                            when="2026-09-19T00:00:00.0000000Z")
    assert out is not None
    return out


def test_a_sidecar_that_exists_is_patched_and_not_rebuilt():
    """Everything outside the Base survives, including a key no version of
    this code has heard of. Measured on his own tree: over the 180 keepers of
    the four shoots that carry a sidecar, the patch leaves all 1,440 facts
    outside the Base unchanged, where the rebuild changed the item's Uuid on
    all 180, the recorded export on 166 and Source.CafID on 73."""
    out = _patched()
    assert 'Software = "DxO PhotoLab 11.1.0.9"' in out        # not this file's default
    assert 'CafID = "C45224d"' in out
    assert '/somewhere/edited/TSC05691_DxO.jpg' in out        # where PhotoLab exported it
    assert 'contentDescription = "a caption of his"' in out
    assert "ProcessingStatus = 3" in out and "ShouldProcess = 2" in out
    assert 'Uuid = "BE76C73E-D03C-4DF6-B8F1-7C17BC12DDAB"' in out
    assert 'CreationDate = "2026-09-18T22:04:18.4470000Z"' in out
    assert out.count("{") == out.count("}")


def test_the_keys_this_tool_owns_are_the_ones_it_replaces():
    out = _patched()
    assert re.search(r"^\t\t\tRating = 3,$", out, re.M)
    assert 'AppliedPresetDisplayName = "2 - DxO Standard"' in out
    assert 'AppliedPresetUniqueName = "DEFAULTS/2 - DxO Standard.preset"' in out
    assert "ExposureBias = 0.42" in out
    assert "SomethingNewInPhotoLab11" not in out      # the Base is this tool's; that key is not
    assert re.findall(r'^\t{5}"([^"]+)",$', out, re.M) == ["Scene 01"]
    # The dates that record this write, and only those: PhotoLab reconciles a
    # sidecar against its database by date, and OutputItems keeps its own.
    assert '\tDate = "2026-09-19T00:00:00.0000000Z"' in out
    assert '\t\t\tModificationDate = "2026-09-19T00:00:00.0000000Z"' in out
    assert '\t\t\t\tCreationDate = "2026-09-18T22:17:37.9550000Z"' in out


def test_photolabs_crlf_survives_a_patch():
    out = _patched(PHOTOLAB_SIDECAR.replace("\n", "\r\n"))
    assert out.count("\r\n") == out.count("\n")      # every line ending, none left bare


def test_a_file_with_no_base_is_left_to_the_template():
    assert presets.patch_dop("Sidecar = {\n}\n", "x", presets.STANDARD) is None


def test_an_overrides_block_with_nothing_of_his_in_it_does_not_outlive_its_base():
    """PhotoLab materialises the active values into Overrides when a file is
    merely opened. Left standing over a replaced Base they would beat it, and
    the frame would keep the last run's numbers under a new recipe."""
    opened = PHOTOLAB_SIDECAR.replace(
        "\t\t\t\tOverrides = {\n\t\t\t\t},\n",
        "\t\t\t\tOverrides = {\n\t\t\t\t\tProfileGainMapIntensity = 0,\n\t\t\t\t\tUnsharpMaskActive = false,\n\t\t\t\t},\n")
    assert not taste.is_hand(taste._block(opened, "Overrides"))
    assert not taste._block(_patched(opened), "Overrides").strip()


def test_a_sidecar_names_the_rendering_it_actually_writes():
    """The no-venue path names DEFAULTS/2 - DxO Standard.preset and the scene
    line announces DxO's camera-body rendering; the Base it wrote carried
    neither ColorRenderingActive nor ColorRenderingType, so the rendering was
    a label. DxO's own preset is the source of the values, never this file."""
    r = presets.standard_rendering()
    assert r["ColorRenderingActive"] is True
    assert r["ColorRenderingType"] == "Original"       # DxO's name for the camera-body rendering
    base = presets.partial_base(r)
    assert 'ColorRenderingType = "Original",' in base
    # DxO writes this beside LocalParameters and never omits it; the partial
    # Base wrote masks without it.
    assert "LocalParametersVersion = 2," in base


def test_the_shipped_fallback_is_checked_and_not_trusted():
    """shipped() answers an unknown preset name with the Natural block, whose
    rendering is DxONatural. Taking it unchecked would write the wrong
    rendering on a machine with no PhotoLab, silently."""
    assert presets.shipped("no such preset").get("ColorRenderingType") == "DxONatural"
    assert presets.STANDARD_RENDERING["ColorRenderingType"] == "Original"


def test_the_software_and_the_catalogue_are_read_not_typed(tmp_path):
    """A shoot with nothing to read from says so, and says what it fell back
    to. Neither value is derivable: Software comes off the installed app and
    CafID names a record in PhotoLab's own catalogue, so it is read out of
    the sidecars PhotoLab has already written beside these frames."""
    empty = tmp_path / "raw"
    empty.mkdir()
    software, cafid, notes = presets.dop_stamp(empty)
    assert cafid == presets.DOP_CAFID_DEFAULT
    assert any("CafID" in n for n in notes)
    assert software == (presets.installed_photolab() or presets.DOP_SOFTWARE_DEFAULT)
    # A sidecar PhotoLab has opened is the witness; the tool's own is not.
    (empty / "TSC00001.ARW.dop").write_text(PHOTOLAB_SIDECAR.replace("C45224d", "C99999z"))
    presets._STAMP.pop(empty, None)
    assert presets.dop_stamp(empty)[1] == "C99999z"


def test_his_own_star_and_dates_are_not_this_tools_to_move():
    """A sidecar of his is patched with the Base and the label only. His star
    lives in Rating, which newest_hand does not read -- it reads Overrides --
    so --force would have taken a star he set in PhotoLab for the cull's own
    tier."""
    his = PHOTOLAB_SIDECAR.replace("Rating = 0,", "Rating = 5,")
    out = presets.patch_dop(his, presets.partial_base({"ExposureBias": 0.42}), presets.STANDARD)
    assert out is not None
    assert re.search(r"^\t\t\tRating = 5,$", out, re.M)
    assert '\tDate = "2026-09-18T22:29:42.1330000Z"' in out
    assert 'AppliedPresetDisplayName = "2 - DxO Standard"' in out     # the label follows the Base
    assert "ExposureBias = 0.42" in out


def test_a_venue_survives_a_rename(tmp_path):
    """sha1 of the absolute path made a venue's identity a fact about where
    its folder sat. The two venues in the committed taste.json still answer
    to their old hashes, because a shoot with no id of its own falls back to
    exactly that."""
    shoot = tmp_path / "2026-09-16"
    shoot.mkdir()
    (shoot / "shoot.json").write_text(json.dumps({"label": "an action shoot"}))
    before = taste.venue_id(shoot)
    assert taste.stamp_venue_id(shoot) == before          # the id it already answered to
    moved = tmp_path / "2026-09-16-gym"
    shoot.rename(moved)
    assert taste.venue_id(moved) == before
    assert before in taste.venue_ids(moved)
    assert taste.stamp_venue_id(moved) is None            # stamped once, never restamped


def test_taste_json_carries_no_path_no_user_and_no_shoot_name():
    """It is committed and ships inside the app."""
    mod = taste.load() or {}
    for vid, e in ((mod.get("venues") or {}).get("shoots") or {}).items():
        assert re.fullmatch(r"[0-9a-f]{12}", vid), vid
        assert "/" not in json.dumps(e.get("label", ""))
    blob = json.dumps(mod)
    assert "/Users/" not in blob and "photos/shoots" not in blob


def test_a_face_mask_is_written_the_way_photolab_writes_one():
    """A review called the mask form one with no precedent in PhotoLab's own
    output. It has one: he edited a mask's temperature in PhotoLab on
    TSC04583 and PhotoLab serialised the whole mask back into Overrides in
    this exact shape, Ids and all (~/photos/attic/your-corrections-2026-09-18,
    written by PhotoLab 10.0.2.28; its index.json records the frame's one
    changed key as LocalParameters). The claim is false and this locks it."""
    m = presets.ai_mask({"name": "Face 1", "x": 0.3, "y": 0.3, "ExposureBias": 0.5, "short": 0.2})
    assert set(m) == {"UIParams", "Corrections", "Options", "Id", "Geometry"}
    assert m["UIParams"] == {"Name": "Face 1"}
    assert m["Corrections"] == {"ExposureBias": 0.5}       # "short" is a note, not a DxO key
    assert m["Options"] == {"Disabled": False, "Opacity": 100}
    bg, group = m["Geometry"]
    assert bg == {"MaskValue": 0, "Type": "Background"}
    assert group["Type"] == "Group" and group["UIParams"]["Name"] == "AI Mask"
    child = group["ChildGeometry"][0]
    assert child["Type"] == "SemanticMask"
    assert child["Prompts"] == [{"Type": "PositivePoint", "Value": [0.3, 0.3]}]
    assert child["ReferenceColorPoint"] == [0.3, 0.3]
    assert child["ChrominanceSelectivity"] == 50 and child["LuminanceSelectivity"] == 50


def test_the_newest_photolab_is_the_one_with_the_highest_version(tmp_path, monkeypatch):
    """Newest by the version the bundle declares, never by the bundle's name.
    A reverse sort of the names puts DXOPhotoLab9.app above DXOPhotoLab10.app,
    so on the machine this function exists for -- one with 8, 9 and 10 side by
    side -- it stamped every sidecar with the oldest PhotoLab on the disk."""
    import glob as _g
    import plistlib
    apps = []
    for name, ver in [("DXOPhotoLab8.app", "8.9.1.4"), ("DXOPhotoLab10.app", "10.0.2.28"),
                      ("DXOPhotoLab9.app", "9.4.0.87")]:
        d = tmp_path / name / "Contents"
        d.mkdir(parents=True)
        with (d / "Info.plist").open("wb") as fh:
            plistlib.dump({"CFBundleVersion": ver}, fh)
        apps.append(str(tmp_path / name))
    monkeypatch.setattr(_g, "glob", lambda pat: apps)
    assert presets.installed_photolab() == "DxO PhotoLab 10.0.2.28"


def test_a_shoot_json_that_will_not_parse_is_never_written_over(tmp_path):
    """meta() answers {} both for a shoot with no shoot.json and for one whose
    file will not parse. Stamping on the second reading replaced his kind,
    label, style and focus with a single id -- his record overwritten by a
    machine's failure to read it, which is the selects.json mistake."""
    shoot = tmp_path / "2026-09-12-lounge"
    shoot.mkdir()
    half = '{\n "kind": "other",\n "label": "a lounge, red light, two people",\n "style": "norm'
    (shoot / "shoot.json").write_text(half)
    assert taste.stamp_venue_id(shoot) is None
    assert (shoot / "shoot.json").read_text() == half
    (shoot / "shoot.json").write_text('["not", "a table"]')
    assert taste.stamp_venue_id(shoot) is None          # and does not raise
    assert (shoot / "shoot.json").read_text() == '["not", "a table"]'
    # A shoot with no shoot.json at all still gets one: there is nothing of
    # his there to lose.
    fresh = tmp_path / "2026-09-20"
    fresh.mkdir()
    assert taste.stamp_venue_id(fresh) == taste.venue_id(fresh)


def test_the_orientation_is_refreshed_on_the_patch_path():
    """The template wrote Orientation from exiftool and the patch that
    replaced it left the line standing, so --force quietly stopped correcting
    a frame whose EXIF had been rewritten. It is the camera's reading, not a
    decision of his: over the 730 sidecars of 2026-09-16, 509 of them opened
    by PhotoLab and 507 carrying his own edits, Source.Items.Orientation holds
    only 1 (380) and 6 (350), both of them readings a camera writes, so
    nothing of his lives on that line. Refreshing it is right; GUESSING it is
    not, which is the second assert and
    test_an_unreadable_frame_does_not_flatten_his_orientation."""
    out = presets.patch_dop(PHOTOLAB_SIDECAR, presets.partial_base({"ExposureBias": 0.42}),
                            presets.STANDARD, orientation=6)
    assert re.findall(r"^\t+Orientation = \d+,$", out, re.M) == ["\t\t\tOrientation = 6,"]
    assert out.count("{") == out.count("}")
    # Not given, not touched: a caller with no EXIF to offer changes nothing.
    left = presets.patch_dop(PHOTOLAB_SIDECAR, presets.partial_base({"ExposureBias": 0.42}), presets.STANDARD)
    assert re.findall(r"^\t+Orientation = \d+,$", left, re.M) == ["\t\t\tOrientation = 1,"]


def test_a_patched_file_is_still_checked_whole():
    """check_dop is asked about the Base the pipeline composed, because the
    settings around it are his and his mask carries a local white balance it
    refuses. The Base is 12 KB of a 16 KB sidecar, so asking about it ALONE
    left the other 3.4 KB unchecked with the patch's substitutions just
    spliced through it. check_written is the part that does not depend on
    whose settings these are, and the patch path runs both."""
    out = _patched()
    assert taste.check_written(out) == []
    assert taste.check_written(out.replace('"DEFAULTS/', '"USER/'))
    assert taste.check_written(out.replace("ShouldProcess = 2,", "ShouldProcess = 2,\n\t\t\t{"))
    assert taste.check_written(out.replace('\t\t\tKeywords = {\n', '\t\t\tKeywords = {\n\t\t\t\t"Scene 01",\n'))
    # and it refuses none of it for carrying an edit of his
    his = out.replace("\t\t\t\tOverrides = {\n\t\t\t\t},\n",
                      "\t\t\t\tOverrides = {\n\t\t\t\t\tLocalWhiteBalanceRawTemperature = 2412.48,\n\t\t\t\t},\n")
    assert any("local white balance" in b for b in taste.check_dop(his))
    assert taste.check_written(his) == []


def test_the_catalogue_is_voted_on_by_the_whole_folder(tmp_path):
    """Source.CafID is settled by majority vote, and the vote used to be
    taken over sorted(glob)[:500]. That is not a read budget, it is an
    alphabetical sample: this folder's first 500 files by name say C11111a
    251 to 249, and the folder as a whole says C99999z 349 to 251. On
    2026-09-16 the two ids in his own sidecars really do run that close (299
    to 210), so the cut decided a live question."""
    raw = tmp_path / "raw"
    raw.mkdir()
    opened = PHOTOLAB_SIDECAR.replace("\t\t\t\tOverrides = {\n\t\t\t\t},\n",
                                      "\t\t\t\tOverrides = {\n\t\t\t\t\tUnsharpMaskActive = false,\n\t\t\t\t},\n")
    for i in range(500):
        (raw / f"A{i:04d}.ARW.dop").write_text(opened.replace("C45224d", "C11111a" if i < 251 else "C99999z"))
    for i in range(100):
        (raw / f"Z{i:04d}.ARW.dop").write_text(opened.replace("C45224d", "C99999z"))
    presets._STAMP.pop(raw, None)
    assert presets.dop_stamp(raw)[1] == "C99999z"


# A preset with the one thing write_dops needs from it: a Base to sit on.
_PRESET = "Preset = {\n\tBase = {\n\t\tExposureBias = 0.25,\n\t},\n}\n"


def _his_shoot(tmp_path, sidecar: str) -> tuple[Path, Path]:
    """A raw/ folder holding a sidecar of HIS and no RAW beside it.

    That is not a contrived shape. archive.py puts a finished shoot's RAWs in
    iCloud, Optimise Mac Storage evicts them, and a shoot whose card is not
    mounted looks the same: the sidecars are all that is on disk. 2026-09-16
    is in exactly this state today -- 459 sidecars in raw/ and 459 of them
    with no RAW beside them."""
    raw = tmp_path / "raw"
    raw.mkdir(parents=True)
    dop = raw / "TSC05691.ARW.dop"
    dop.write_text(sidecar)
    presets._STAMP.pop(raw, None)
    return raw, dop


_HIS_EDIT = ("\t\t\t\tOverrides = {\n\t\t\t\t},\n",
             "\t\t\t\tOverrides = {\n\t\t\t\t\tExposureBias = -0.35,\n\t\t\t\t},\n")


def test_an_unreadable_frame_does_not_flatten_his_orientation(tmp_path):
    """Orientation is refreshed from exiftool, and exiftool returns NOTHING
    for a frame it cannot open. The fallback that filled in for it was a
    literal 1, and on the patch path that 1 was spliced into his sidecar as
    though the camera had said it.

    350 of 2026-09-16's 730 sidecars carry Orientation = 6 and not one of the
    RAWs that folder names is on disk, so a --force over it turned every one
    of those 350 portraits landscape in PhotoLab -- a rotation lost to a
    default, on files whose RAWs were merely evicted. A reading is written; a
    guess is not."""
    raw, dop = _his_shoot(tmp_path, PHOTOLAB_SIDECAR
                          .replace("\t\t\tOrientation = 1,", "\t\t\tOrientation = 6,")
                          .replace(*_HIS_EDIT))
    presets.write_dops(raw, tmp_path / "out", [{"file": "TSC05691.ARW", "rating": "3"}],
                       "Cull test", _PRESET, ["Scene 01"], force=True)
    after = dop.read_text()
    assert re.findall(r"^\t+Orientation = \d+,$", after, re.M) == ["\t\t\tOrientation = 6,"]
    assert "ExposureBias = -0.35," in after            # and his edit is still under it


def test_write_dops_checks_the_whole_patched_file_and_not_just_the_base(tmp_path):
    """The other half of test_a_patched_file_is_still_checked_whole, which
    pins check_written itself but calls it directly: nothing there fails if
    write_dops stops asking it about the patched file, which is precisely the
    narrowing this guards.

    PhotoLab reads every sidecar beside the RAWs at launch and aborts on an
    unbalanced one before there is a window to say which of 1,157 files is at
    fault, so a brace the patch carried through from his own bytes has to be
    caught here or not at all. check_dop sees only the composed Base and has
    nothing to say about a caption."""
    broken = PHOTOLAB_SIDECAR.replace('contentDescription = "a caption of his"',
                                      'contentDescription = "a caption of his {"').replace(*_HIS_EDIT)
    raw, dop = _his_shoot(tmp_path, broken)
    before = dop.read_text()
    with pytest.raises(SystemExit) as e:
        presets.write_dops(raw, tmp_path / "out", [{"file": "TSC05691.ARW", "rating": "3"}],
                           "Cull test", _PRESET, ["Scene 01"], force=True)
    assert "unbalanced braces" in str(e.value)
    assert dop.read_text() == before                   # refused, and nothing half written
    # The same file without the stray brace is written, so it is the brace
    # that was refused and not the shape of the fixture.
    raw2, dop2 = _his_shoot(tmp_path / "ok", PHOTOLAB_SIDECAR.replace(*_HIS_EDIT))
    presets.write_dops(raw2, tmp_path / "out2", [{"file": "TSC05691.ARW", "rating": "3"}],
                       "Cull test", _PRESET, ["Scene 01"], force=True)
    assert taste.check_written(dop2.read_text()) == []


class _NoFaces:
    """A face detector that finds nothing, so a crop falls where the frame's
    own shape puts it."""
    def detect(self, img):
        return []


def _portrait_preview(out: Path) -> None:
    import cv2
    import numpy as np
    (out / "previews").mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(out / "previews" / "TSC05691.jpg"), np.full((600, 400, 3), 128, np.uint8))   # as displayed


def _crop_rect(text: str) -> list[float]:
    m = re.search(r"\n(\t+)CropRect = \{\n(.*?)\n\1\},", text, re.S)
    return [round(float(v.strip().rstrip(",")), 4) for v in m.group(2).split("\n")] if m else []


def test_a_crop_on_an_unreadable_frame_takes_the_orientation_its_sidecar_records(tmp_path):
    """The patch path stopped guessing Orientation when exiftool read nothing;
    the crop did not, and placed a portrait's crop in its display frame, which
    PhotoLab reads in the sensor's. The sidecar on disk records the camera's
    reading from the last time the RAW could be opened, and that is used."""
    raw, dop = _his_shoot(tmp_path, PHOTOLAB_SIDECAR
                          .replace("\t\t\tOrientation = 1,", "\t\t\tOrientation = 6,")
                          .replace(*_HIS_EDIT))
    _portrait_preview(tmp_path / "out")
    presets.write_dops(raw, tmp_path / "out", [{"file": "TSC05691.ARW", "rating": "3"}], "Cull test", _PRESET,
                       ["Scene 01"], force=True, crop="4:5", judge=_NoFaces(), tones={"TSC05691.ARW": {"_base": "standard"}})
    # 4:5 out of a 2:3 portrait, full width and a third down from the faces'
    # line, turned into the sensor's frame (flip 6: x, y, w, h -> y, 1-x-w, h, w)
    assert _crop_rect(dop.read_text()) == [0.0522, 0.0, 0.8333, 1.0]


def test_a_crop_with_nothing_to_say_how_the_camera_was_held_is_not_placed(tmp_path, capsys):
    raw = tmp_path / "raw"
    raw.mkdir()
    presets._STAMP.pop(raw, None)
    _portrait_preview(tmp_path / "out")
    presets.write_dops(raw, tmp_path / "out", [{"file": "TSC05691.ARW", "rating": "3"}], "Cull test", _PRESET,
                       ["Scene 01"], crop="4:5", judge=_NoFaces(), tones={"TSC05691.ARW": {"_base": "standard"}})
    text = (raw / "TSC05691.ARW.dop").read_text()
    assert "CropRect" not in text
    assert "1 frame got no crop" in capsys.readouterr().out
    # And the 1 the template had to write for a file that must carry one is
    # not read back on the next run as though the camera had said it.
    assert re.search(r"^\t+Orientation = 1,$", text, re.M)
    presets.write_dops(raw, tmp_path / "out", [{"file": "TSC05691.ARW", "rating": "3"}], "Cull test", _PRESET,
                       ["Scene 01"], force=True, crop="4:5", judge=_NoFaces(), tones={"TSC05691.ARW": {"_base": "standard"}})
    assert "CropRect" not in (raw / "TSC05691.ARW.dop").read_text()
    assert "1 frame got no crop" in capsys.readouterr().out


_OPENED_LENS = "\n".join(f"\t\t\t\t\t{k} = {v}," for k, v in sorted(presets.LENS_OPENED.items()))


def _with_overrides(body: str) -> str:
    return PHOTOLAB_SIDECAR.replace("\t\t\t\tOverrides = {\n\t\t\t\t},\n",
                                    f"\t\t\t\tOverrides = {{\n{body}\n\t\t\t\t}},\n")


def test_what_photolab_materialises_for_the_lens_goes_and_a_choice_stays():
    """lens_to_dxo stripped every Distortion*/Vignetting*/ChromaticAberration*/
    UnsharpMask* key whatever its value, so a deliberate DistortionActive =
    false was deleted along with the block PhotoLab writes on open. Only
    PhotoLab's own materialised values (LENS_OPENED), and values that merely
    echo the Base under them, are PhotoLab's."""
    opened = _with_overrides(_OPENED_LENS)
    text, gone = presets.lens_to_dxo(opened)
    assert gone == len(presets.LENS_OPENED)
    assert not taste._block(text, "Overrides").strip()
    assert not presets.is_his(opened)
    his = opened.replace("DistortionActive = true,", "DistortionActive = false,")
    text, gone = presets.lens_to_dxo(his)
    assert gone == len(presets.LENS_OPENED) - 1
    assert taste._block(text, "Overrides").strip() == "DistortionActive = false,"
    assert presets.is_his(his)


def test_a_sidecar_whose_only_edit_is_a_lens_tool_survives_force(tmp_path):
    """hand_keys counts no lens key as his, so a frame he had switched
    distortion correction off on looked like the pipeline's own file: --force
    emptied its Overrides and the choice was gone."""
    raw, dop = _his_shoot(tmp_path, _with_overrides("\t\t\t\t\tDistortionActive = false,"))
    assert presets.newest_hand(raw, "TSC05691.ARW") == dop
    presets.write_dops(raw, tmp_path / "out", [{"file": "TSC05691.ARW", "rating": "3"}],
                       "Cull test", _PRESET, ["Scene 01"], force=True)
    after = dop.read_text()
    assert taste._block(after, "Overrides").strip() == "DistortionActive = false,"
    assert "SomethingNewInPhotoLab11" not in after                   # and the starting edit under it was refreshed


def test_mine_too_replaces_every_copy_and_keeps_each_one(tmp_path):
    """--mine-too rebuilt raw/ only. His copy in edit/ kept the edit, and
    gather promotes the newest copy with his hand in it on the next run, so
    the file he asked to be rid of came back. And nothing was kept: the one
    flag here that throws an edit away now copies each one into
    decisions/replaced/<time>/ first."""
    raw, dop = _his_shoot(tmp_path, _with_overrides("\t\t\t\t\tExposureBias = -0.35,"))
    edit = tmp_path / "edit"
    edit.mkdir()
    other = edit / dop.name
    other.write_text(_with_overrides("\t\t\t\t\tExposureBias = -0.90,"))
    presets.write_dops(raw, tmp_path / "out", [{"file": "TSC05691.ARW", "rating": "3"}],
                       "Cull test", _PRESET, ["Scene 01"], force=True, mine_too=True)
    assert "ExposureBias = -0.35," not in dop.read_text()
    assert "ExposureBias = -0.90," not in other.read_text()
    assert dop.read_text() == other.read_text()             # nothing left to promote over it
    kept = sorted(p for p in (tmp_path / "decisions" / "replaced").rglob("*.dop"))
    assert [p.parent.name for p in kept] == ["edit", "raw"]
    assert "ExposureBias = -0.35," in (kept[1]).read_text()
    assert "ExposureBias = -0.90," in (kept[0]).read_text()


def test_without_mine_too_a_different_edit_of_his_elsewhere_is_left_alone(tmp_path, capsys):
    """And a copy carrying only what PhotoLab materialises on open is not a
    different edit of his: it was being left behind holding the last run's
    recipe because its Overrides block merely had something in it."""
    raw, dop = _his_shoot(tmp_path, _with_overrides("\t\t\t\t\tExposureBias = -0.35,"))
    edit, picks = tmp_path / "edit", tmp_path / "cull" / "picks"
    edit.mkdir()
    picks.mkdir(parents=True)
    # Older by the date PhotoLab wrote inside it, so the copy beside the RAW
    # is the one newest_hand takes and this one is the other edit.
    (edit / dop.name).write_text(_with_overrides("\t\t\t\t\tExposureBias = -0.90,")
                                 .replace("2026-09-18T22:17:37.9570000Z", "2026-09-17T09:00:00.0000000Z"))
    (picks / dop.name).write_text(_with_overrides(_OPENED_LENS))
    presets.write_dops(raw, tmp_path / "out", [{"file": "TSC05691.ARW", "rating": "3"}],
                       "Cull test", _PRESET, ["Scene 01"], force=True)
    assert "ExposureBias = -0.90," in (edit / dop.name).read_text()          # his, and not ours to replace
    assert (picks / dop.name).read_text() == dop.read_text()                 # PhotoLab's own materialisation, refreshed
    assert not (tmp_path / "decisions" / "replaced").exists()
    assert "1 copy in cull/picks/ or edit/ carries a different edit of yours" in capsys.readouterr().out


def test_a_frame_of_his_that_was_left_alone_is_named(tmp_path):
    """presets.json carries left_alone, so the card's "nothing you had changed
    was touched" is a list of frames and not a promise."""
    raw, dop = _his_shoot(tmp_path, _with_overrides("\t\t\t\t\tExposureBias = -0.35,"))
    before = dop.read_text()
    left: list = []
    presets.write_dops(raw, tmp_path / "out", [{"file": "TSC05691.ARW", "rating": "3"}],
                       "Cull test", _PRESET, ["Scene 01"], left_alone=left)
    assert left == ["TSC05691"] and dop.read_text() == before


# ------------------------------------------- a cull that named the camera JPEG

def _lounge(tmp_path, flat: bool = False) -> Path:
    """A shoot whose cull.csv names the camera JPEG (2026-09-12-lounge's says
    TSC04016.jpg) while the RAW beside it is TSC04016.ARW. Returns the RAW
    folder, the one build and write_dops are handed."""
    shoot = tmp_path / "2026-09-12-lounge"
    raw = shoot if flat else shoot / "raw"
    raw.mkdir(parents=True)
    (shoot / "cull").mkdir()
    (raw / "TSC04016.ARW").write_bytes(b"RAW")
    presets._STAMP.pop(raw, None)
    return raw


_STANDARD_TONES = {"TSC04016.jpg": {"_base": "standard"}, "TSC09999.jpg": {"_base": "standard"}}


@pytest.mark.parametrize("flat", [False, True])
def test_a_frame_the_cull_named_by_its_jpeg_gets_its_raws_sidecar(tmp_path, capsys, flat):
    """The sidecar was built at shoot / r["file"], so a cull that named the
    JPEG wrote TSC04016.jpg.dop beside nothing and the RAW PhotoLab opens got
    none. It goes beside the RAW, named for it and saying so inside; and a
    frame with neither a RAW of its number nor the file the cull named gets
    nothing, said once."""
    raw = _lounge(tmp_path, flat)
    rows = [{"file": "TSC04016.jpg", "rating": "3"}, {"file": "TSC09999.jpg", "rating": "3"}]
    assert presets.write_dops(raw, tmp_path / "out", rows, "Cull test", _PRESET, ["Scene 01"], tones=_STANDARD_TONES) == 1
    dop = raw / "TSC04016.ARW.dop"
    assert re.findall(r'^\t+Name = "([^"]*)",$', dop.read_text(), re.M) == ["TSC04016.ARW"]
    assert sorted(p.name for p in tmp_path.rglob("*.dop")) == ["TSC04016.ARW.dop"]      # no .jpg.dop, and nothing for TSC09999
    out = capsys.readouterr().out
    assert out.count("got no sidecar") == 1 and "1 frame got no sidecar (TSC09999.jpg)" in out, out
    # And the measuring reads the RAW, where there is one, and the old path where not.
    assert presets.frame_file(raw, "TSC04016.jpg") == raw / "TSC04016.ARW"
    assert presets.frame_file(raw, "TSC09999.jpg") == raw / "TSC09999.jpg"


def test_a_frame_named_by_its_jpeg_finds_his_copy_by_the_raws_name(tmp_path):
    raw = _lounge(tmp_path)
    his = raw / "TSC04016.ARW.dop"
    his.write_text(_with_overrides("\t\t\t\t\tExposureBias = -0.35,"))
    taste._HANDS.clear()
    assert presets.newest_hand(raw, "TSC04016.jpg") == his
    left: list = []
    presets.write_dops(raw, tmp_path / "out", [{"file": "TSC04016.jpg", "rating": "3"}], "Cull test", _PRESET,
                       ["Scene 01"], tones=_STANDARD_TONES, left_alone=left)
    assert left == ["TSC04016"] and "ExposureBias = -0.35," in his.read_text()


def _orphan(raw: Path, text: str) -> Path:
    orphan = raw / "TSC04016.jpg.dop"
    orphan.write_text(text.replace('Name = "TSC05691.ARW"', 'Name = "TSC04016.jpg"'))
    return orphan


def test_an_orphan_of_his_is_read_as_the_raws_copy_and_left_where_it_is(tmp_path, capsys):
    """Earlier runs left TSC04016.jpg.dop beside nothing. One carrying his hand
    is the frame's hand copy until the RAW has a sidecar of its own: left
    alone without --force, and under it the RAW's sidecar is written from it,
    his edit kept. The orphan is never deleted, moved or rewritten."""
    raw = _lounge(tmp_path)
    orphan = _orphan(raw, _with_overrides("\t\t\t\t\tExposureBias = -0.35,"))
    before = orphan.read_bytes()
    left: list = []
    rows = [{"file": "TSC04016.jpg", "rating": "3"}]
    presets.write_dops(raw, tmp_path / "out", rows, "Cull test", _PRESET, ["Scene 01"], tones=_STANDARD_TONES, left_alone=left)
    assert left == ["TSC04016"] and not (raw / "TSC04016.ARW.dop").exists()
    out = capsys.readouterr().out
    assert "1 sidecar named for a camera JPEG (TSC04016.jpg.dop)" in out and "left in place" in out, out
    assert "1 carries your own edits" in out
    presets.write_dops(raw, tmp_path / "out", rows, "Cull test", _PRESET, ["Scene 01"], tones=_STANDARD_TONES, force=True)
    after = (raw / "TSC04016.ARW.dop").read_text()
    assert "ExposureBias = -0.35," in after
    assert re.findall(r'^\t+Name = "([^"]*)",$', after, re.M) == ["TSC04016.ARW"]
    assert orphan.read_bytes() == before
    assert "named for a camera JPEG" not in capsys.readouterr().out          # said once for the run


def test_an_orphan_the_pipeline_wrote_is_not_his_and_is_not_used(tmp_path, capsys):
    raw = _lounge(tmp_path)
    orphan = _orphan(raw, PHOTOLAB_SIDECAR)
    before = orphan.read_bytes()
    left: list = []
    presets.write_dops(raw, tmp_path / "out", [{"file": "TSC04016.jpg", "rating": "3"}], "Cull test", _PRESET,
                       ["Scene 01"], tones=_STANDARD_TONES, left_alone=left)
    assert left == [] and (raw / "TSC04016.ARW.dop").exists()
    assert "SomethingNewInPhotoLab11" not in (raw / "TSC04016.ARW.dop").read_text()      # built fresh, not from the orphan
    assert orphan.read_bytes() == before
    out = capsys.readouterr().out
    assert "not used and was left in place" in out and "your own edits" not in out, out


def test_another_editors_sidecar_goes_beside_the_raw_too(tmp_path):
    raw = _lounge(tmp_path)
    rows = [{"file": "TSC04016.jpg", "rating": "3"}, {"file": "TSC09999.jpg", "rating": "3"}]
    skipped: list = []
    assert presets.write_for_editor(raw, rows, "Cull 01", {}, [], "darktable", quiet=True, no_raw=skipped) == 1
    assert (raw / "TSC04016.ARW.xmp").exists() and not (raw / "TSC04016.jpg.xmp").exists()
    assert skipped == ["TSC09999.jpg"]
