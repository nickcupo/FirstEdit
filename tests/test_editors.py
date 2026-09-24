"""What a sidecar declares itself to be, what each writer can carry, and whose file it is.

    .venv/bin/python -m pytest tests/test_editors.py -q

Three numbers in editors.py are the vendors' and not ours, and each one was
wrong in a way that renders a frame differently rather than failing: a
RawTherapee profile declaring PPVERSION 347 is loaded through the 10 degree
standard observer, a darktable colour label written as a name comes back as the
number 0 (red), and Camera Raw's process version 5 is not the one that fixed
the banding in the colour mixer this pipeline writes to. They live in
editors.FORMATS so that following a vendor forward is one line there and one
line here.

The manifest test is the one that keeps the rest honest. CARRIES is a second
description of what the writers do, and a second description drifts, so every
field it names is rendered twice -- once at rest, once moved -- and a field it
calls dropped must change nothing while a field it claims must change
something.
"""
from __future__ import annotations

import configparser
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import editors as ed  # noqa: E402
import taste  # noqa: E402

WRITES = ("lightroom", "rawtherapee", "darktable")     # dxo's sidecar is written by presets.write_dops

# One frame's worth of a real starting edit, with every field moved off its
# rest value so that "did this field reach the file" has an answer.
PROBE = {
    "exposure": 1.35, "temperature": 5200, "tint": 12, "highlights": -40, "shadows": 35,
    "blacks": -30, "whites": 25, "contrast": 20, "vibrance": 18, "saturation": 9,
    "dehaze": 15, "vignette": -30, "skin_sat": -12, "red_sat": -20, "red_lum": 8,
    "masks": [{"x": 0.51, "y": 0.42, "exposure": 0.6}],
    "name": "action, hard light", "notes": ["face 1.2 EV under target"],
    "rating": 3, "label": "Yellow",
}
# A .pp3 carries no white balance block at all without a kelvin, so the tint
# has to be measured with one in place or it would read as dropped.
CONTEXT = {"tint": {"temperature": 5200}}


def _render(editor: str, **kw) -> str:
    rating, label = kw.pop("rating", 0), kw.pop("label", "")
    return ed.render(editor, ed.Edit(**kw), rating=rating, label=label)


def test_the_declared_versions_are_the_vendors_own_numbers():
    """The pins. RawTherapee: rtgui/ppversion.h at tag 5.13 says PPVERSION 353.
    darktable: src/common/exif.cc says DT_XMP_EXIF_VERSION 5. Adobe: process
    version 6 arrived with Camera Raw 15.4, and every crs file written by 16.x
    through 18.x still declares it. Changing a number here without changing
    FORMATS, or the other way round, fails the next test."""
    assert ed.FORMATS["rawtherapee"].declares == {"AppVersion": "5.13", "Version": "353"}
    assert ed.FORMATS["darktable"].declares == {"xmp_version": "5"}
    assert ed.FORMATS["lightroom"].declares == {"Version": "15.4", "ProcessVersion": "15.4"}


def test_every_declared_version_reaches_the_file_it_describes():
    """The table is only worth having if the writers read from it."""
    pp3 = _render("rawtherapee", temperature=5200)
    assert "\nVersion=353" in pp3 and "\nAppVersion=5.13" in pp3
    assert 'crs:ProcessVersion="15.4"' in _render("lightroom") and 'crs:Version="15.4"' in _render("lightroom")
    assert 'darktable:xmp_version="5"' in _render("darktable")


def test_a_computed_kelvin_names_its_observer():
    """The incident this file's version pin caused. RawTherapee forces the 10
    degree observer on any profile declaring 347 to 349 and its own default is
    2 degrees, so a kelvin the cull computed rendered differently from the same
    kelvin typed in by hand. Naming the observer means the rendering no longer
    rests on the version number being read the way we expect."""
    pp3 = _render("rawtherapee", temperature=5200, tint=12)
    assert "StandardObserver=TWO_DEGREES" in pp3
    assert "Temperature=5200" in pp3 and "Setting=Custom" in pp3


def test_a_darktable_colour_label_is_a_number():
    """darktable writes colour labels with snprintf("%d") and reads them with
    toLong. A name there is not rejected: exiv2 hands back 0 and the frame
    comes up red. Yellow is 1."""
    xmp = _render("darktable", label="Yellow", rating=3)
    assert "<darktable:colorlabels><rdf:Seq><rdf:li>1</rdf:li></rdf:Seq></darktable:colorlabels>" in xmp
    assert "<rdf:li>Yellow</rdf:li>" not in xmp
    assert 'xmp:Label="Yellow"' in xmp          # the portable route, which darktable prefers over its own key
    # RawTherapee numbers the same five colours from 1, with 0 meaning none.
    assert "ColorLabel=2" in _render("rawtherapee", label="Yellow")


def test_a_label_we_cannot_number_still_travels_as_text():
    """xmp:Label is free text. An unmappable label must not become a wrong
    number, and must not be dropped either."""
    xmp = _render("darktable", label="To print")
    assert 'xmp:Label="To print"' in xmp and "colorlabels" not in xmp
    assert "ColorLabel=" not in _render("rawtherapee", label="To print")


def test_the_rating_survives_the_ignore_embedded_rating_preference():
    """exif.cc reads xmp:Rating only when the file carries darktable:xmp_version
    or the user has left that preference off. auto_presets_applied=0 is the
    other half: it is what darktable writes for an imported, undeveloped frame,
    and it is what makes darktable still apply the user's own automatic presets
    the first time the frame is opened."""
    xmp = _render("darktable", rating=3)
    assert 'darktable:xmp_version="5"' in xmp
    assert 'darktable:auto_presets_applied="0"' in xmp
    assert 'xmp:Rating="3"' in xmp


def test_the_sidecar_goes_where_that_editor_looks_for_it():
    """darktable reads <whole file name>.xmp; the 198 sidecars it wrote in the
    2026-09-05 shoot are all TSCnnnnn.ARW.xmp. Lightroom and Camera Raw read
    <stem>.xmp. Writing the darktable one to the Lightroom name puts it where
    darktable will never look and on top of the Lightroom file."""
    raw = Path("/shoot/raw/TSC03957.ARW")
    assert ed.sidecar_path("darktable", raw).name == "TSC03957.ARW.xmp"
    assert ed.sidecar_path("lightroom", raw).name == "TSC03957.xmp"
    assert ed.sidecar_path("rawtherapee", raw).name == "TSC03957.ARW.pp3"
    assert ed.sidecar_path("dxo", raw).name == "TSC03957.ARW.dop"


@pytest.mark.parametrize("editor", WRITES)
def test_the_manifest_matches_what_the_writer_actually_does(editor):
    """CARRIES is a second description of the writers, and a second description
    drifts. Every field it names is rendered at rest and moved: a field it calls
    dropped must change nothing, and a field it claims must change something."""
    for fieldname, (level, why) in ed.CARRIES[editor].items():
        base = dict(CONTEXT.get(fieldname, {}))
        rest = _render(editor, **base)
        moved = _render(editor, **{**base, fieldname: PROBE[fieldname]})
        if level == ed.DROPPED:
            assert rest == moved, f"{editor} says it drops {fieldname}, but the file changed: {why}"
        else:
            assert rest != moved, f"{editor} claims {fieldname} ({level}), but nothing in the file moved: {why}"


@pytest.mark.parametrize("fieldname,other_way", (("highlights", 40), ("shadows", -35), ("blacks", 30)))
def test_a_one_sided_mapping_says_so(fieldname, other_way):
    """The drift test above moves each field one way only, so a writer that
    carries half of a field's range passes it. Three of RawTherapee's mappings
    are one-sided -- it has no white point, its highlight and shadow
    compressions only go one way, and its black point is clamped at zero -- and
    22 of the 1,190 .dop sidecars on this machine carry a positive black point,
    which is written nowhere. A note that says "approximated" for a setting
    that never reaches the file is the drift this pair of tests exists to
    stop."""
    assert _render("rawtherapee") == _render("rawtherapee", **{fieldname: other_way}), \
        f"{fieldname} now maps both ways: CARRIES still says it does not"
    assert ed.CARRIES["rawtherapee"][fieldname][1].startswith("only a"), \
        f"{fieldname} is one-sided in the writer; the manifest has to say which way"


@pytest.mark.parametrize("editor", WRITES)
def test_the_summary_names_what_is_lost(editor):
    """The sentence the studio shows instead of silently writing a worse file."""
    line = ed.summary(editor)
    assert line.startswith(editor)
    for fieldname in ed.manifest(editor)["dropped"]:
        assert fieldname.replace("_", " ") in line
    assert "not carried: masks" in ed.summary("lightroom")


def test_face_masks_are_declared_lost_rather_than_invented():
    """DxO's mask is a prompt point and an exposure bias with no extent. A
    Lightroom radial needs a size, and a size nothing measured is an edit
    nothing measured, so it is declared instead of guessed."""
    e = ed.Edit(name="x", masks=PROBE["masks"])
    assert ed.CARRIES["dxo"]["masks"][0] == ed.FULL
    for editor in WRITES:
        assert ed.CARRIES[editor]["masks"][0] == ed.DROPPED
        assert ed.render(editor, e) == ed.render(editor, ed.Edit(name="x"))


# A darktable sidecar as darktable itself writes one, trimmed from
# ~/photos/shoots/2026-09-05-the-gals/raw/TSC03957.ARW.xmp. Nothing here
# carries the pipeline's stamp, so it is someone else's file.
THEIRS = """<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 4.4.0-Exiv2">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
    xmlns:darktable="http://darktable.sf.net/"
   xmp:Rating="1"
   darktable:xmp_version="5"
   darktable:history_end="12">
   <darktable:history><rdf:Seq><rdf:li darktable:operation="exposure"/></rdf:Seq></darktable:history>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
"""


@pytest.mark.parametrize("editor", WRITES)
def test_a_sidecar_we_did_not_write_is_kept(editor):
    """The .dop path refuses to replace a file with his hand in it, --force or
    not. These three used to replace whatever was there, which is eighty
    Lightroom edits gone on the next run of presets."""
    assert ed.render(editor, ed.Edit(name="x"), existing=THEIRS) is None
    assert ed.render(editor, ed.Edit(name="x"), existing="Version=347\n[Exposure]\nCompensation=0.50\n") is None
    assert ed.is_ours(THEIRS) is False


@pytest.mark.parametrize("editor", WRITES)
def test_our_own_sidecar_is_ours_to_refresh(editor):
    """And the stamp has to survive a round trip, or the second run would treat
    the first run's own file as the photographer's and never update it again."""
    mine = _render(editor, name="x", rating=2)
    assert ed.is_ours(mine) is True
    assert ed.render(editor, ed.Edit(name="x"), rating=2, existing=mine) is not None
    assert ed.render(editor, ed.Edit(name="x"), rating=2, existing="   ") is not None     # nothing there yet


@pytest.mark.parametrize("editor", WRITES)
@pytest.mark.parametrize("line", ["first-edit sidecar", "photo-pipeline sidecar"])
def test_a_sidecar_carrying_either_name_is_ours_to_refresh(editor, line):
    """Every sidecar written before the rename says photo-pipeline. Those are
    his shoots' existing files, and they have to stay ours for good, or the
    next run would leave every one of them as it is."""
    mine = _render(editor, name="x", rating=2)
    assert "first-edit sidecar for " + editor in mine        # a new file says the new name
    carried = mine.replace("first-edit sidecar", line)
    assert ed.is_ours(carried) is True
    assert ed.render(editor, ed.Edit(name="x"), rating=3, existing=carried) is not None


@pytest.mark.parametrize("editor", WRITES)
def test_a_sidecar_carrying_neither_name_is_still_kept(editor):
    """The same file with the line taken out, which is what an editor does
    when it saves over it, is his."""
    mine = _render(editor, name="x", rating=2)
    theirs = mine.replace("first-edit sidecar", "saved by the editor")
    assert ed.is_ours(theirs) is False
    assert ed.render(editor, ed.Edit(name="x"), rating=3, existing=theirs) is None


def test_the_old_line_is_accepted_for_good():
    assert ed.MARK == "first-edit sidecar"
    assert "photo-pipeline sidecar" in ed.FORMER_MARKS


@pytest.mark.parametrize("editor", ("lightroom", "darktable"))
def test_the_stamp_is_a_legal_xml_comment(editor):
    """It goes inside one, and a double hyphen in there makes the file
    unparseable -- which for a sidecar means the editor refuses the frame."""
    assert "--" not in ed._stamp(editor)
    ET.fromstring(_render(editor, name="a & b <c>", rating=3, label="Yellow", notes=["one", "two"]))


@pytest.mark.parametrize("editor", ("lightroom", "darktable"))
def test_free_text_reaches_the_file_as_the_text_it_was(editor):
    """The scene name is built from what the frames are ("Cull 03 people flash
    18:26 (9)"), the notes are prose, and a label is free text: one ampersand
    in any of them and the XMP does not parse, which is a frame the editor
    refuses to show. This test used to strip the ampersand and the angle
    brackets out of its own probe before rendering, so it proved nothing."""
    name = 'Ben & Jo <the "gals">'
    root = ET.fromstring(_render(editor, name=name, rating=3, label='Ben & Jo', notes=["highlights < -20 & clipped"]))
    said = [el.text for el in root.iter() if el.text and "Ben" in el.text]
    assert said == [name], said
    assert 'xmp:Label="Ben &amp; Jo"' in _render(editor, name="x", label="Ben & Jo")


def test_a_rawtherapee_profile_still_parses_as_the_ini_it_is():
    """The stamp is a comment above the first group, which is where a keyfile
    parser tolerates one."""
    cp = configparser.ConfigParser()
    cp.read_string(_render("rawtherapee", temperature=5200, tint=12, exposure=1.35,
                           highlights=-40, rating=3, label="Green"))
    assert cp["Version"]["version"] == "353"
    assert cp["White Balance"]["standardobserver"] == "TWO_DEGREES"
    assert cp["General"]["rank"] == "3"


@pytest.mark.parametrize("editor,written", (("darktable", "TSC03957.ARW.xmp"), ("lightroom", "TSC03957.xmp"),
                                            ("rawtherapee", "TSC03957.ARW.pp3")))
def test_presets_writes_where_that_editor_looks_and_keeps_what_it_did_not_write(tmp_path, editor, written):
    """Knowing the name and the rule in this file is no use while presets.py
    works the path out for itself, which is what it did: every .xmp went to
    <stem>.xmp, so with --editor darktable the cull's stars reached darktable
    for none of the 198 frames of the 2026-09-05 shoot and landed on top of the
    Lightroom sidecar on the way. Under --force it also replaced whatever was
    there, which is the one thing the .dop path refuses to do."""
    import presets
    (tmp_path / "TSC03957.ARW").write_bytes(b"")
    rows = [{"file": "TSC03957.ARW", "rating": "3"}]
    args = (tmp_path, rows, "Cull 01 people flash", {}, ["one"], editor)
    assert presets.write_for_editor(*args, quiet=True) == 1
    assert [p.name for p in sorted(tmp_path.iterdir()) if p.name != "TSC03957.ARW"] == [written]
    assert presets.write_for_editor(*args, force=True, quiet=True) == 1      # ours to refresh
    (tmp_path / written).write_text(THEIRS)
    assert presets.write_for_editor(*args, force=True, quiet=True) == 0      # his
    assert (tmp_path / written).read_text() == THEIRS


def test_a_scene_hands_these_three_no_exposure_and_no_mask(tmp_path):
    """CARRIES describes what a WRITER can carry: Lightroom's takes an
    exposure EV for EV. What the presets run gives it is another question.
    decide() reports a scene's exposure and never sets it, and the face masks
    are decided per frame on the .dop path, so every sidecar written here
    says +0.00 while the studio was being told exposure was carried. The
    manifest now names both, and the run says so where it writes them."""
    import presets
    ms = [{"clip": 0.0, "black": 0.0, "range": 40.0, "frame_L": 55.0, "face_L": 52.0,
           "face_rg": 1.4, "subject_L": 55.0} for _ in range(4)]
    settings, notes = presets.decide(ms, [], [], "person", "window")
    e = ed.from_dxo("Cull 01 people window", settings, notes)
    assert e.exposure == 0.0 and e.masks == []
    assert 'crs:Exposure2012="+0.00"' in ed.render("lightroom", e)
    for editor in WRITES:
        assert set(ed.manifest(editor)["not_decided"]) == {"exposure", "masks"}
        assert "not decided for this editor: exposure, masks" in ed.summary(editor)
    assert ed.manifest("dxo")["not_decided"] == {}       # the .dop is where both are decided


# ------------------------------------------------------------ the scene keyword

def test_the_scene_keyword_never_rewrites_a_sidecar_your_editor_wrote(tmp_path):
    """--xmp ran exiftool -overwrite_original over <stem>.xmp, which is where
    Lightroom and Camera Raw keep a person's develop settings, with none of
    the guard write_for_editor keeps. A file without the pipeline's stamp is
    somebody else's."""
    import presets
    theirs = tmp_path / "TSC03957.xmp"
    theirs.write_text(THEIRS)
    assert presets.tag_xmp(tmp_path, ["TSC03957"], "Scene 01") == (0, 1)
    assert theirs.read_text() == THEIRS


def test_the_scene_keyword_lands_where_lightroom_reads_it_and_does_not_pile_up(tmp_path):
    """exiftool's += adds the value whether or not the bag already holds it,
    so a second run gave the frame the keyword twice; and the scenes are
    renumbered every time they are read, so last run's number was left
    beside this run's. What is ours is written whole."""
    import presets
    side = tmp_path / "TSC03957.xmp"
    assert presets.tag_xmp(tmp_path, ["TSC03957"], "Scene 01") == (1, 0)
    assert ed.is_ours(side.read_text()) and ed.keywords_of(side.read_text()) == ["Scene 01"]
    presets.tag_xmp(tmp_path, ["TSC03957"], "Scene 01")
    presets.tag_xmp(tmp_path, ["TSC03957"], "Scene 02")
    assert ed.keywords_of(side.read_text()) == ["Scene 02"]
    ET.fromstring(side.read_text())


@pytest.mark.parametrize("line", ["first-edit sidecar", "photo-pipeline sidecar"])
def test_a_sidecar_on_disk_under_either_name_takes_this_runs_keyword(tmp_path, line):
    """The sidecars already in his shoots were written under the old name,
    and a run under the new one still refreshes them."""
    import presets
    side = tmp_path / "TSC03957.xmp"
    presets.tag_xmp(tmp_path, ["TSC03957"], "Scene 01")
    side.write_text(side.read_text().replace("first-edit sidecar", line))
    assert presets.tag_xmp(tmp_path, ["TSC03957"], "Scene 02") == (1, 0)
    assert ed.keywords_of(side.read_text()) == ["Scene 02"]


def test_the_scene_keyword_joins_the_starting_edit_this_run_wrote(tmp_path):
    """--editor lightroom --xmp write the same file, in that order: the
    keyword goes into the sidecar the run just wrote, beside the notes it
    carries, and takes nothing out of it."""
    import presets
    (tmp_path / "TSC03957.ARW").write_bytes(b"")
    rows = [{"file": "TSC03957.ARW", "rating": "3"}]
    presets.write_for_editor(tmp_path, rows, "Cull 01 people flash", {}, ["a note of the run's"], "lightroom", quiet=True)
    assert presets.tag_xmp(tmp_path, ["TSC03957"], "Scene 01") == (1, 0)
    text = (tmp_path / "TSC03957.xmp").read_text()
    assert ed.keywords_of(text) == ["a note of the run's", "Scene 01"]
    assert 'crs:Exposure2012' in text and ed.is_ours(text)
    ET.fromstring(text)


# --------------------------------------------------------------- his own tree

# The library this machine actually has, which is PHOTOS_ROOT when it is set
# and ~/photos when it is not -- the same answer taste gives every other part
# of the pipeline. Read from Path.home() directly, this test read his real
# library even when the run was pointed at a scratch copy of it.
SHOOTS = taste.ROOT / "shoots"


def _settings(text: str) -> dict:
    """A .dop's Base block as the scene reader's settings dict: PhotoLab writes
    Lua literals, the reader holds numbers."""
    out: dict = {}
    for k, v in taste.flat_block(text, "Base").items():
        if v in ("true", "false"):
            out[k] = v == "true"
        elif v.startswith('"'):
            out[k] = v.strip('"')
        else:
            try:
                out[k] = float(v)
            except ValueError:
                out[k] = v
    return out


@pytest.mark.skipif(not SHOOTS.exists(), reason="his shoots tree is not on this machine")
def test_every_sidecar_on_this_machine_renders_for_every_editor():
    """Read-only, and the point of it is the count: the thresholds in this
    project were set on four of his shoots, so a writer is measured on every
    .dop under ~/photos rather than on one fixture -- 1,190 of them across five
    shoots as this was written, the ducks-and-deadlifts card included. Each one
    becomes an Edit and is rendered three ways; an XMP that does not parse or a
    profile that does not read back is a frame an editor would refuse."""
    dops = sorted(SHOOTS.rglob("*.dop"))
    assert len(dops) > 100, f"only {len(dops)} sidecars found under {SHOOTS}"
    for p in dops:
        e = ed.from_dxo(p.stem, _settings(p.read_text(errors="ignore")))
        for editor in WRITES:
            text = ed.render(editor, e, rating=3, label="Blue")
            assert ed.is_ours(text), f"{p.name} -> {editor}: no stamp"
            for v in ed.FORMATS[editor].declares.values():
                assert v in text, f"{p.name} -> {editor}: {v} missing"
            if editor == "rawtherapee":
                configparser.ConfigParser().read_string(text)
            else:
                ET.fromstring(text)
