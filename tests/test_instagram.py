"""The Instagram copies: where the window falls, what colour comes out, and
whose crop wins.

    .venv/bin/python -m pytest tests/test_instagram.py -q

Nothing here loads a detector. The record (crops.json) is what a copy is made
from, so a test seeds the record and asks what was written.
"""
from __future__ import annotations

import contextlib
import io
import json
import struct
import sys
from pathlib import Path

import pytest
from PIL import Image, ImageCms

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import instagram as ig  # noqa: E402


# ------------------------------------------------------------- a profile to test with
#
# A wide-gamut ICC profile built here rather than read off this machine:
# /System/Library/ColorSync has one, and a test that only runs where that
# folder exists proves nothing on any other machine. This is the smallest
# valid v2 matrix/TRC profile - a white point, three colorants and three tone
# curves - with Display P3's primaries adapted to D50.
def _icc(name: str, prim) -> bytes:
    def s15(x):
        return int(round(x * 65536))

    def xyz(x, y, z):
        return b"XYZ " + b"\0" * 4 + struct.pack(">iii", s15(x), s15(y), s15(z))

    def curv(g):
        return b"curv" + b"\0" * 4 + struct.pack(">I", 1) + struct.pack(">H", int(round(g * 256)))

    text = name.encode("ascii") + b"\0"
    tags = {b"desc": b"desc" + b"\0" * 4 + struct.pack(">I", len(text)) + text + b"\0" * 8 + b"\0" * 70,
            b"wtpt": xyz(0.9642, 1.0, 0.8249),
            b"cprt": b"text" + b"\0" * 4 + b"no copyright\0"}
    for k, v in zip((b"rXYZ", b"gXYZ", b"bXYZ"), prim):
        tags[k] = xyz(*v)
    for k in (b"rTRC", b"gTRC", b"bTRC"):
        tags[k] = curv(2.2)
    names = sorted(tags)
    off = 128 + 4 + 12 * len(names)
    table = body = b""
    for n in names:
        d = tags[n]
        table += n + struct.pack(">II", off + len(body), len(d))
        body += d + b"\0" * ((-len(d)) % 4)
    head = (struct.pack(">I", off + len(body)) + b"\0" * 4 + struct.pack(">I", 0x02100000) + b"mntr" + b"RGB "
            + b"XYZ " + b"\0" * 12 + b"acsp" + b"\0" * 24 + struct.pack(">I", 0)
            + struct.pack(">iii", s15(0.9642), s15(1.0), s15(0.8249)) + b"\0" * 4)
    return head + b"\0" * (128 - len(head)) + struct.pack(">I", len(names)) + table + body


WIDE_GAMUT = _icc("Test Wide RGB", [(0.5151, 0.2412, -0.0011), (0.2920, 0.6922, 0.0419), (0.1571, 0.0666, 0.7841)])
SRGB = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()


def _export(path: Path, size=(1200, 800), colour=(220, 40, 40), icc=None, orientation=None, comment=None) -> Path:
    im = Image.new("RGB", size, colour)
    im.paste((10, 200, 40), (0, 0, size[0] // 4, size[1] // 4))        # a corner to tell the ends apart
    kw = {}
    if icc:
        kw["icc_profile"] = icc
    if comment:
        kw["comment"] = comment
    if orientation:
        ex = Image.Exif()
        ex[274] = orientation
        kw["exif"] = ex
    path.parent.mkdir(parents=True, exist_ok=True)
    im.save(path, "JPEG", quality=95, **kw)
    return path


def _entry(w: int, h: int, mode: str = "crop", **kw) -> dict:
    e = {"src": "TSC00001_DxO.jpg", "w": w, "h": h, "mtime": 0, "mode": mode, "mode_by": "run",
         "subject": {"cx": 0.5, "cy": 0.5, "kind": "scene", "faces": None}}
    e.update(kw)
    return e


# ------------------------------------------------------------------ the window

def test_a_window_never_leaves_the_frame():
    """cw / want, rounded up, can come to one pixel more than the frame is
    tall: at 4000 x 4002 and 3:4 the window was 4003 tall and started at
    y = -1, and PIL filled that row with black."""
    x, y, cw, ch = ig.window_of(4000, 4002, 3 / 4, 0.5, 0.5, 1.0)
    assert x >= 0 and y >= 0 and x + cw <= 4000 and y + ch <= 4002
    for w, h, want, scale in ((4000, 4002, 3 / 4, 1.0), (6105, 4000, 4 / 5, 1.0), (1000, 1000, 3 / 4, 0.05),
                              (999, 1501, 3 / 4, 0.97), (4000, 6105, 3 / 4, 1.0)):
        x, y, cw, ch = ig.window_of(w, h, want, 0.5, 0.5, scale)
        assert 0 <= x and 0 <= y and x + cw <= w and y + ch <= h, (w, h, want, scale)


def test_a_frame_too_tall_for_a_post_is_cut_around_its_subject():
    """A 2:3 portrait left whole is 1080 x 1620, which Instagram does not
    take: its composer cuts it around the middle of the frame, wherever the
    subject is. A panorama was already being cut to 1.91; this is the same
    rule at the other end."""
    tall = _entry(4000, 6000, mode="whole")
    r, size = ig.rect(tall, 3 / 4)
    assert size == (1080, 1440)
    assert r[2] / r[3] == pytest.approx(3 / 4, abs=0.002)
    wide = _entry(6000, 2000, mode="whole")
    r, size = ig.rect(wide, 3 / 4)
    assert size == (1080, int(round(1080 / ig.MAX_LANDSCAPE)))
    ok = _entry(6000, 4000, mode="whole")
    assert ig.rect(ok, 3 / 4) == ((0, 0, 6000, 4000), (1080, 720))


# ------------------------------------------------------------------ whose crop

def test_a_window_you_placed_keeps_the_frame_cut():
    """Placing a window is a decision to cut. A landscape he had cropped by
    hand went back to being the whole frame on the next run without
    --landscape crop, and his window was ignored."""
    e, said = ig.carry(_entry(6000, 4000, manual={"cx": 0.4, "cy": 0.5, "scale": 0.8}), None, "fit")
    assert e["mode"] == "crop" and not said
    e, _ = ig.carry(_entry(6000, 4000), None, "fit")
    assert e["mode"] == "whole"


def test_your_window_survives_a_re_export_of_the_same_shape():
    """A new edit of the same photograph is a new file, and the record was
    thrown away with it: the crop he had placed by hand came back cut by the
    detector. His window is in fractions, so it describes the same framing."""
    disk = _entry(6000, 4000, manual={"cx": 0.4, "cy": 0.5, "scale": 0.8}, mode_by="you")
    fresh = {"src": "TSC00001_DxO.jpg", "w": 3000, "h": 2000, "mtime": 99,
             "subject": {"cx": 0.2, "cy": 0.3, "kind": "face", "faces": None}}
    e, said = ig.carry(disk, fresh, "fit")
    assert e["manual"] == disk["manual"] and e["mtime"] == 99 and not said
    assert e["subject"]["cx"] == 0.2                     # the subject is the new file's


def test_a_window_placed_on_a_differently_shaped_export_is_kept_and_named():
    """Cropped again in PhotoLab, the export is not the same picture and his
    window cannot be trusted on it. It is kept in the record rather than
    dropped, and the run says why the copy was cut automatically."""
    disk = _entry(6000, 4000, manual={"cx": 0.4, "cy": 0.5, "scale": 0.8})
    fresh = {"src": "TSC00001_DxO.jpg", "w": 4000, "h": 4000, "mtime": 99,
             "subject": {"cx": 0.5, "cy": 0.5, "kind": "scene", "faces": None}}
    e, said = ig.carry(disk, fresh, "fit")
    assert "manual" not in e
    assert e["manual_was"] == disk["manual"] and e["manual_was_size"] == [6000, 4000]
    assert "your crop kept in the record" in said


def test_cut_or_whole_set_by_hand_is_never_moved_by_a_run():
    e, _ = ig.carry(_entry(6000, 4000, mode="whole", mode_by="you"), None, "crop")
    assert e["mode"] == "whole" and e["mode_by"] == "you"


# ------------------------------------------------------------------ the colour

def _made(tmp_path: Path, **kw) -> Image.Image:
    src = _export(tmp_path / "TSC00001_DxO.jpg", **kw)
    dst = tmp_path / "out" / "TSC00001.jpg"
    note = ig.render(src, dst, (0, 0, 400, 300), (400, 300))
    im = Image.open(dst)
    im.load()
    im.info["said"] = note
    return im


def test_an_export_with_no_profile_is_left_exactly_as_it_is(tmp_path):
    """sRGB is what every reader assumes of an untagged file, Instagram
    included, and his own exports carry no profile at all."""
    im = _made(tmp_path)
    assert im.info.get("icc_profile") is None
    assert im.getpixel((399, 299))[:3] == pytest.approx((220, 40, 40), abs=2)
    assert im.info["said"] == ""


def test_an_srgb_export_keeps_its_own_profile_byte_for_byte(tmp_path):
    im = _made(tmp_path, icc=SRGB)
    assert im.info["icc_profile"] == SRGB
    assert im.info["said"] == ""


def test_a_wide_gamut_export_is_converted_and_not_merely_relabelled(tmp_path):
    """A file in something else, handed over as it is, is read as sRGB by
    whatever drops the tag on the way up: the same numbers in a narrower
    space, every colour pulled in toward grey. Converted through its own
    profile, it keeps the colour it had."""
    im = _made(tmp_path, icc=WIDE_GAMUT)
    assert "sRGB" in ImageCms.getProfileDescription(ImageCms.ImageCmsProfile(io.BytesIO(im.info["icc_profile"])))
    assert im.getpixel((399, 299))[:3] != pytest.approx((220, 40, 40), abs=2)
    assert "converted from Test Wide RGB to sRGB" in im.info["said"]


def test_no_metadata_and_no_chroma_subsampling(tmp_path):
    """Pillow carries a JPEG comment over from the file it opened without
    being asked, and writes 4:2:0 by default - the colour resolution halved
    before Instagram halves it again, which is what a red edge against skin
    shows first."""
    from PIL import JpegImagePlugin
    im = _made(tmp_path, comment=b"written by something else", orientation=None)
    assert "comment" not in im.info and "exif" not in im.info
    assert JpegImagePlugin.get_sampling(im) == 0            # 4:4:4


def test_the_picture_is_the_one_the_camera_meant_to_show(tmp_path):
    """A portrait frame written landscape with Orientation 6 is a portrait to
    everything that reads EXIF, and the record's own w and h are measured the
    same way, so the window and the picture have to agree about which way up
    it is."""
    src = _export(tmp_path / "TSC00001_DxO.jpg", size=(1200, 800), orientation=6)
    dst = tmp_path / "out" / "TSC00001.jpg"
    ig.render(src, dst, (0, 0, 800, 1200), (400, 600))
    im = Image.open(dst)
    assert im.size == (400, 600)
    assert im.getpixel((10, 10))[:3] == pytest.approx((220, 40, 40), abs=3)     # the green corner turned with it
    assert im.getpixel((390, 10))[:3] == pytest.approx((10, 200, 40), abs=3)


def test_a_copy_is_whole_or_not_there_and_leaves_nothing_behind(tmp_path):
    src = _export(tmp_path / "TSC00001_DxO.jpg")
    out = tmp_path / "out"
    ig.render(src, out / "TSC00001.jpg", (0, 0, 400, 300), (400, 300))
    assert [p.name for p in out.iterdir()] == ["TSC00001.jpg"]


# ------------------------------------------------------------------ the record

def test_the_book_is_written_whole(tmp_path):
    out = tmp_path / "instagram"
    ig.keep_book(out, {"ratio": "3:4", "frames": {"TSC00001": _entry(6000, 4000)}})
    assert json.loads((out / ig.CROPS).read_text())["frames"]["TSC00001"]["w"] == 6000
    assert [p.name for p in out.iterdir()] == [ig.CROPS]


def test_a_run_reads_the_record_again_before_it_writes_each_frame(tmp_path, monkeypatch):
    """A run over a whole shoot takes minutes. It used to read the record when
    it started and write it back when it ended, so a window saved in the
    studio's editor while it ran - the record and the copy both - was
    overwritten by what the run had read before he placed it."""
    shoot = tmp_path / "2026-09-21"
    out = shoot / "instagram"
    srcs = {s: _export(shoot / "export" / f"{s}_DxO.jpg") for s in ("TSC00001", "TSC00002")}
    monkeypatch.setattr(ig.exports, "files", lambda shoot, want=None: dict(srcs))
    ig.keep_book(out, {"ratio": "3:4", "frames": {
        s: dict(_entry(1200, 800, mode="whole"), src=f"{s}_DxO.jpg", mtime=int(p.stat().st_mtime))
        for s, p in srcs.items()}})

    # The editor is another process, and it saves its window while the run is
    # between two frames: here, just before the run takes the lock for the
    # first of them. What the run read when it started says "whole".
    real_held, saved = ig.held, []
    @contextlib.contextmanager
    def held(out_dir):
        if not saved:
            saved.append(True)
            d = ig.book(out_dir)
            d["frames"]["TSC00002"].update(mode="crop", mode_by="you",
                                           manual={"cx": 0.3, "cy": 0.4, "scale": 0.5})
            ig.keep_book(out_dir, d)
        with real_held(out_dir):
            yield
    monkeypatch.setattr(ig, "held", held)
    monkeypatch.setattr(sys, "argv", ["instagram", str(shoot), "--all", "--json"])
    assert ig.main() == 0
    after = ig.book(out)["frames"]["TSC00002"]
    assert after["mode"] == "crop" and after["mode_by"] == "you"
    assert after["manual"] == {"cx": 0.3, "cy": 0.4, "scale": 0.5}
    assert Image.open(out / "TSC00002.jpg").size == (1080, 1440)      # his window, not the whole frame


def test_a_face_half_out_of_the_picture_still_moves_the_window(tmp_path, monkeypatch):
    """A detector's box runs off the edge on a face that is half out of the
    frame, and what is off the edge is not a face to keep in the window. Read
    as it came, a box wider than the frame never "fits", so place() gave up
    on the faces and simply centred the window on the subject."""
    src = _export(tmp_path / "TSC00001_DxO.jpg", size=(1200, 800))
    monkeypatch.setattr(ig, "subject", lambda img, judge, reader: (-40.0, 900.0, (-300.0, -100.0, 400.0, 1000.0)))
    d = ig.detect(src, None, None)
    assert all(0.0 <= v <= 1.0 for v in d["subject"]["faces"])
    assert 0.0 <= d["subject"]["cx"] <= 1.0 and 0.0 <= d["subject"]["cy"] <= 1.0
    e = dict(d, mode="crop", mode_by="run")
    (x, y, cw, ch), size = ig.rect(e, 3 / 4)
    assert x == 0 and 0 <= y and y + ch <= 800                  # the faces pull it to the edge they are on


# ------------------------------------------------------------------ the plan
#
# --plan is the pass that happens before anything is written: the same frames,
# the same decision, the same record, and no JPEG. What it says has to be what
# the copies then are, or looking at it first is worse than not looking.

def _shoot(tmp_path: Path, monkeypatch, sizes: dict[str, tuple[int, int]]) -> tuple[Path, Path, dict]:
    """A shoot with exports of the given shapes, and no detector: the subject
    is the middle of the frame, which is what detect() answers when nothing is
    found in it.

    A frame nobody has looked at yet is what a plan is for, so these runs take
    the path that would load a detector, and the detector is stood in for -
    the models are a download and a test that needs one proves nothing on a
    machine without it."""
    import types
    shoot = tmp_path / "2026-09-21"
    srcs = {s: _export(shoot / "export" / f"{s}_DxO.jpg", size=sz) for s, sz in sizes.items()}
    monkeypatch.setattr(ig.exports, "files", lambda shoot, want=None: dict(srcs))
    for name, thing in (("faces", "FaceJudge"), ("presets", "SceneReader")):
        m = types.ModuleType(name)
        setattr(m, thing, lambda: None)
        monkeypatch.setitem(sys.modules, name, m)
    monkeypatch.setattr(ig, "detect", lambda src, judge, reader: {
        "src": src.name, "w": Image.open(src).size[0], "h": Image.open(src).size[1],
        "mtime": int(src.stat().st_mtime),
        "subject": {"cx": 0.5, "cy": 0.5, "kind": "scene", "faces": None}})
    return shoot, shoot / "instagram", srcs


def _run(monkeypatch, capsys, *args) -> dict:
    monkeypatch.setattr(sys, "argv", ["instagram", *[str(a) for a in args], "--json"])
    assert ig.main() == 0
    return json.loads(capsys.readouterr().out.strip().splitlines()[-1])


def test_a_plan_writes_no_picture_and_says_what_every_cut_would_be(tmp_path, monkeypatch, capsys):
    """He presses Plan, and nothing in the folder is a photograph: the record
    of what was decided, and that is all. Every frame says its window in the
    frame's own pixels, the size it would be written at, and whether the
    profile grid would cut its subject."""
    shoot, out, _ = _shoot(tmp_path, monkeypatch, {"TSC00001": (6000, 4000), "TSC00002": (4000, 6000)})
    j = _run(monkeypatch, capsys, shoot, "--all", "--plan")
    assert [p.name for p in out.iterdir()] == [ig.CROPS]
    assert sorted(r["file"] for r in j["planned"]) == ["TSC00001.jpg", "TSC00002.jpg"]
    for r in j["planned"]:
        assert r["made"] is False
        assert len(r["rect"]) == 4 and len(r["out"]) == 2
        assert "grid_ok" in r and r["mode"] in ("crop", "whole")
    land = next(r for r in j["planned"] if r["file"] == "TSC00001.jpg")
    assert land["mode"] == "whole" and land["rect"] == [0, 0, 6000, 4000] and land["out"] == [1080, 720]
    port = next(r for r in j["planned"] if r["file"] == "TSC00002.jpg")
    assert port["mode"] == "crop" and port["out"] == [1080, 1440]


def test_what_the_plan_said_is_what_the_copies_come_out_as(tmp_path, monkeypatch, capsys):
    """The whole point of looking first. Making them is the same arithmetic on
    the same record - so every window, every size and every grid flag is the
    one he approved, to the pixel."""
    shoot, out, _ = _shoot(tmp_path, monkeypatch, {"TSC00001": (6000, 4000), "TSC00002": (4000, 6000)})
    planned = {r["file"]: r for r in _run(monkeypatch, capsys, shoot, "--all", "--plan")["planned"]}
    made = {r["file"]: r for r in _run(monkeypatch, capsys, shoot, "--all")["made"]}
    assert set(planned) == set(made)
    for f, p in planned.items():
        assert [p[k] for k in ("rect", "out", "mode", "kept", "grid_ok")] == \
               [made[f][k] for k in ("rect", "out", "mode", "kept", "grid_ok")]
        assert Image.open(out / f).size == tuple(p["out"])


def test_a_crop_adjusted_after_the_plan_is_the_one_that_is_made(tmp_path, monkeypatch, capsys):
    """Between the plan and the copies he opens one and moves it. Making them
    must not decide that frame again: a run re-reads the record, and his
    window is in it."""
    shoot, out, _ = _shoot(tmp_path, monkeypatch, {"TSC00001": (6000, 4000), "TSC00002": (4000, 6000)})
    _run(monkeypatch, capsys, shoot, "--all", "--plan")
    # what the studio's editor saves: a window, and the mode it implies
    with ig.held(out):
        d = ig.book(out)
        d["frames"]["TSC00001"]["manual"] = {"cx": 0.2, "cy": 0.6, "scale": 0.5}
        ig.keep_book(out, d, locked=True)
    his = ig.window_of(6000, 4000, 3 / 4, 0.2, 0.6, 0.5)
    made = {r["file"]: r for r in _run(monkeypatch, capsys, shoot, "--all")["made"]}
    assert made["TSC00001.jpg"]["rect"] == list(his)
    assert made["TSC00001.jpg"]["adjusted"] is True and made["TSC00001.jpg"]["mode"] == "crop"
    assert Image.open(out / "TSC00001.jpg").size == (1080, 1440)
    assert made["TSC00002.jpg"]["adjusted"] is False          # and nothing else moved


def test_the_copies_are_made_at_the_shape_they_were_planned_at(tmp_path, monkeypatch, capsys):
    """A plan at 4:5 and then a plain run: the run used to make 3:4, its own
    default, while the record and the studio's editor both said 4:5. The
    shape is part of what he approved."""
    shoot, out, _ = _shoot(tmp_path, monkeypatch, {"TSC00002": (4000, 6000)})
    j = _run(monkeypatch, capsys, shoot, "--all", "--plan", "--ratio", "4:5", "--landscape", "crop")
    assert j["planned"][0]["out"] == [1080, 1350]
    assert ig.book(out)["landscape"] == "crop"
    made = _run(monkeypatch, capsys, shoot, "--all")["made"][0]
    assert made["out"] == [1080, 1350] and Image.open(out / "TSC00002.jpg").size == (1080, 1350)
    # and he can still say otherwise
    assert _run(monkeypatch, capsys, shoot, "--all", "--ratio", "3:4")["made"][0]["out"] == [1080, 1440]


def test_planning_again_after_a_copy_was_made_leaves_the_copy_alone(tmp_path, monkeypatch, capsys):
    """Planning is not a way to lose work: it writes the record, and a JPEG
    already in the folder is neither rewritten nor removed. It says which
    frames have one."""
    shoot, out, _ = _shoot(tmp_path, monkeypatch, {"TSC00001": (6000, 4000)})
    _run(monkeypatch, capsys, shoot, "--all")
    was = (out / "TSC00001.jpg").read_bytes()
    j = _run(monkeypatch, capsys, shoot, "--all", "--plan")
    assert j["planned"][0]["made"] is True
    assert (out / "TSC00001.jpg").read_bytes() == was


def test_the_queue_takes_the_shapes_the_script_takes_and_no_others():
    """That the two lists agree. The one that matters — that the BUILDER asks
    rather than carrying its own copy — is in tests/test_studio_api.py, which
    goes through WORK["instagram"] and fails when the old hardcoded tuple is
    put back. This one only pins the source of truth, and on its own it would
    pass with the bug still in place; a peer proved that by restoring the line
    and watching every test go green."""
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "pipeline"))
    import instagram as ig
    import studio

    assert studio._ig_ratios() == tuple(ig.RATIOS)
    assert "1:1" not in studio._ig_ratios()
    said = studio._or_list(studio._ig_ratios())
    for shape in studio._ig_ratios():
        assert shape in said


# ------------------------------------------------------------------ the step's arithmetic
#
# The studio's Instagram step draws every cut on the photograph it will be cut
# from, and the app redraws a cut he drags with its own copy of this
# arithmetic. These are the numbers both sides are held to (the contract's
# test vectors), and the description the step is drawn from.

@pytest.mark.parametrize("w,h,want,cx,cy,scale,rect", [
    (4000, 6000, 0.75, 0.5, 0.5, 1.0, (0, 334, 4000, 5333)),
    (4000, 6000, 0.8, 0.5, 0.3, 0.8, (400, 0, 3200, 4000)),
    (6000, 4000, 0.75, 0.9, 0.5, 1.0, (3000, 0, 3000, 4000)),
    (6000, 4000, 0.8, 0.1, 0.1, 0.5, (0, 0, 1600, 2000)),
    (4000, 4002, 0.75, 0.5, 0.5, 1.0, (499, 0, 3002, 4002)),
    (1200, 800, 0.75, 0.25, 0.75, 0.33333, (200, 467, 200, 267)),
    (5000, 5000, 0.8, 0.0, 1.0, 0.05, (0, 4750, 200, 250)),
    (3000, 4500, 0.75, 0.61234, 0.38765, 0.72, (757, 304, 2160, 2880)),
])
def test_a_window_is_where_the_app_draws_it(w, h, want, cx, cy, scale, rect):
    assert ig.window_of(w, h, want, cx, cy, scale) == rect


def test_the_grid_loses_a_subject_off_to_the_side_of_a_whole_landscape():
    wide = _entry(6000, 4000, mode="whole", subject={"cx": 0.9, "cy": 0.5, "kind": "scene", "faces": None})
    r, out = ig.rect(wide, 3 / 4)
    assert out == (1080, 720) and ig.grid_ok(wide, r, out) is False
    wide["subject"]["cx"] = 0.5
    assert ig.grid_ok(wide, r, out) is True


def test_cut_or_whole_is_one_rule():
    """mode_for is what a run gives a frame, and what the studio's shape
    switch gives every frame whose mode is not his."""
    assert ig.mode_for(_entry(4000, 6000), "fit") == "crop"             # taller than wide
    assert ig.mode_for(_entry(6000, 4000), "fit") == "whole"
    assert ig.mode_for(_entry(6000, 4000), "crop") == "crop"
    assert ig.mode_for(_entry(5000, 5000), "fit") == "whole"
    assert ig.mode_for(_entry(6000, 4000, manual={"cx": 0.5, "cy": 0.5, "scale": 1}), "fit") == "crop"
    e, _ = ig.carry(None, _entry(6000, 4000), "crop")
    assert e["mode"] == ig.mode_for(e, "crop") == "crop" and e["mode_by"] == "run"


def _described(tmp_path, entry, ratio="3:4", name="TSC00001_DxO.jpg"):
    src = tmp_path / "export" / name
    if not src.exists():
        _export(src, size=(60, 40))
    entry = dict(entry, src=src.name, mtime=int(src.stat().st_mtime))
    return ig.describe(src, tmp_path / "instagram", "TSC00001", entry, ratio, "fit")


@pytest.mark.parametrize("entry,cut,other,auto,whole", [
    # A landscape left whole, its subject off to the side: the grid loses it.
    (_entry(6000, 4000, mode="whole", subject={"cx": 0.81, "cy": 0.5, "kind": "scene", "faces": None}),
     {"shape": "whole", "rect": [0, 0, 6000, 4000], "out": [1080, 720], "grid_ok": False, "kept": 1.0},
     {"shape": "3:4", "rect": [3000, 0, 3000, 4000]}, [3000, 0, 3000, 4000], [0, 0, 6000, 4000]),
    # A portrait, cut automatically.
    (_entry(4000, 6000, subject={"cx": 0.48, "cy": 0.31, "kind": "face", "faces": None}),
     {"shape": "3:4", "rect": [0, 0, 4000, 5333], "out": [1080, 1440], "grid_ok": True, "kept": 0.889},
     {"shape": "4:5", "rect": [0, 0, 4000, 5000]}, [0, 0, 4000, 5333], [0, 0, 4000, 5333]),
    # A portrait he moved.
    (_entry(4000, 6000, manual={"cx": 0.52, "cy": 0.4, "scale": 0.85},
            subject={"cx": 0.48, "cy": 0.31, "kind": "face", "faces": None}),
     {"shape": "3:4", "rect": [380, 134, 3400, 4533], "out": [1080, 1440], "grid_ok": True, "kept": 0.642},
     {"shape": "4:5", "rect": [380, 275, 3400, 4250]}, [0, 0, 4000, 5333], [0, 0, 4000, 5333]),
    # A landscape he cut.
    (_entry(6000, 4000, mode_by="you", subject={"cx": 0.3, "cy": 0.5, "kind": "scene", "faces": None}),
     {"shape": "3:4", "rect": [300, 0, 3000, 4000], "out": [1080, 1440], "grid_ok": True, "kept": 0.5},
     {"shape": "4:5", "rect": [200, 0, 3200, 4000]}, [300, 0, 3000, 4000], [0, 0, 6000, 4000]),
])
def test_a_frame_is_described_as_its_copy_would_be_made(tmp_path, entry, cut, other, auto, whole):
    d = _described(tmp_path, entry)
    assert d["state"] == "planned" and d["cut"] == cut
    assert {k: d["other"][k] for k in ("shape", "rect")} == other
    assert d["auto"] == {"rect": auto} and d["whole"]["rect"] == whole
    # The line drawn is the window make() cuts, one function apart.
    r, size = ig.rect(entry, 3 / 4)
    assert d["cut"]["rect"] == list(r) and d["cut"]["out"] == list(size)
    assert d["adjusted"] is bool(entry.get("manual")) and d["frame"] == [entry["w"], entry["h"]]
    assert d["copy"] is None and d["copy_current"] is False


def test_the_other_shape_of_a_frame_cut_at_4_5_is_3_4(tmp_path):
    d = _described(tmp_path, _entry(4000, 6000), ratio="4:5")
    assert d["cut"]["shape"] == "4:5" and d["cut"]["out"] == [1080, 1350]
    assert d["other"]["shape"] == "3:4" and d["other"]["out"] == [1080, 1440]


def test_a_frame_with_no_record_is_described_with_nothing_drawn(tmp_path):
    src = _export(tmp_path / "export" / "TSC00001_DxO.jpg", size=(60, 40))
    d = ig.describe(src, tmp_path / "instagram", "TSC00001", None, "3:4", "fit")
    assert d["state"] == "unplanned" and d["cut"] is None and d["frame"] is None and d["copy_current"] is False
    assert d["file"] == "TSC00001_DxO.jpg" and d["export_mtime"] == int(src.stat().st_mtime)
