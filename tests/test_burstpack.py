"""burstpack gives back the bytes it was given, every time, or says it cannot.

    .venv/bin/python -m pytest tests/test_burstpack.py -q

Nothing here needs a photograph. The frames are Bayer mosaics made from a
smooth scene with texture and noise, moved a few pixels between frames the way
a hand-held burst moves, then packed into Sony's compressed-ARW blocks and a
TIFF shaped like an ARW. The blocks are real cRAW - the same bit layout dcraw
reads - so the codec takes the path it takes on a camera's file. The number it
saves on these is not a claim about photographs; docs/BURSTPACK.md has those.
"""
from __future__ import annotations

import io
import json
import os
import struct
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import burstpack as bp  # noqa: E402

H, W = 96, 256


def _scene(rng: np.random.Generator, h: int, w: int) -> np.ndarray:
    y, x = np.mgrid[0:h, 0:w]
    base = 300 + 200 * np.sin(x / 23.0) * np.cos(y / 17.0) + 150 * ((x // 40 + y // 30) % 2)
    return base + rng.normal(0, 25, (h, w)).cumsum(1) * 0.05


def _burst(n: int, seed: int = 0, noise: float = 3.0) -> list[np.ndarray]:
    """n mosaics of one scene, each moved by a few even pixels and with its own noise."""
    rng = np.random.default_rng(seed)
    big = _scene(rng, H + 32, W + 32)
    out = []
    for i in range(n):
        dy, dx = 2 * (i % 3), 2 * ((i * 2) % 3)
        frame = big[16 + dy:16 + dy + H, 16 + dx:16 + dx + W] + rng.normal(0, noise, (H, W))
        out.append(np.clip(np.round(frame), 0, 2047).astype(np.int64))
    return out


def craw_encode(p: np.ndarray) -> dict[str, np.ndarray]:
    """Fields the way a camera would fill them from 11-bit pixels."""
    h, w = p.shape
    b = bp.to_blocks(p).reshape(h, w // 16, 16)
    mx, mn = b.max(-1), b.min(-1)
    ix, iN = b.argmax(-1), b.argmin(-1)
    iN = np.where(ix == iN, (ix + 1) % 16, iN)
    sh = bp._shift(mx - mn)
    pos = bp._positions(ix, iN)[..., :14]
    vals = np.take_along_axis(b, pos, -1)
    d = np.clip((vals - mn[..., None] + ((1 << sh[..., None]) >> 1)) >> sh[..., None], 0, 127)
    return {"mx": mx, "mn": mn, "ix": ix, "in": iN, "d": d}


def arw(strip: bytes, h: int, w: int, preview: bytes = b"\xff\xd8preview\xff\xd9") -> bytes:
    """A TIFF laid out the way an ARW is where it matters: IFD0 pointing at a
    SubIFD whose one strip is cRAW (compression 32767, a byte a pixel)."""
    e = lambda tag, typ, cnt, val: struct.pack("<HHII", tag, typ, cnt, val)  # noqa: E731
    make, model = b"SONY\x00", b"ILCE-6500\x00"
    raw_ifd = 8 + 2 + 12 * 3 + 4
    data_at = raw_ifd + 2 + 12 * 6 + 4
    make_at, model_at = data_at, data_at + len(make)
    prev_at = model_at + len(model)
    strip_at = prev_at + len(preview)
    strip_at += (-strip_at) % 16
    out = io.BytesIO()
    out.write(b"II*\x00" + struct.pack("<I", 8))
    out.write(struct.pack("<H", 3) + e(271, 2, len(make), make_at) + e(272, 2, len(model), model_at)
              + e(330, 4, 1, raw_ifd) + struct.pack("<I", 0))
    out.write(struct.pack("<H", 6) + e(256, 4, 1, w) + e(257, 4, 1, h) + e(258, 3, 1, 8) + e(259, 3, 1, 32767)
              + e(273, 4, 1, strip_at) + e(279, 4, 1, len(strip)) + struct.pack("<I", 0))
    out.write(make + model + preview)
    out.write(b"\0" * (strip_at - out.tell()))
    out.write(strip)
    out.write(b"trailing maker data")
    return out.getvalue()


def _files(tmp_path: Path, frames: list[np.ndarray], prefix: str = "TSC0") -> list[Path]:
    paths = []
    for i, p in enumerate(frames):
        f = tmp_path / "raw" / f"{prefix}{1000 + i}.ARW"
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_bytes(arw(bp.craw_bytes(craw_encode(p)), *p.shape, preview=f"preview {i}".encode()))
        os.utime(f, ns=(1_700_000_000_000_000_000 + i, 1_700_000_000_000_000_000 + i))
        paths.append(f)
    return paths


# ------------------------------------------------------------------ pieces

def test_any_block_splits_into_fields_and_back():
    """The 128 bits of a block are (max, min, imax, imin, 14 steps) with nothing
    left over, so a block that breaks every rule still comes back."""
    raw = np.random.default_rng(1).integers(0, 256, size=4 * 64, dtype=np.uint8)
    assert bp.craw_bytes(bp.craw_fields(raw, 4, 64)) == raw.tobytes()


def test_rans_gives_back_every_symbol():
    rng = np.random.default_rng(2)
    rec = bp.Recorder()
    lanes = 37
    for _ in range(50):
        n = int(rng.integers(1, lanes + 1))
        rec.sym("a", rng.integers(0, 3, n), np.minimum(rng.geometric(0.3, n) - 1, 19))
        nb = rng.integers(0, 14, n)
        rec.bits(nb, rng.integers(0, 1 << 14, n) & ((1 << nb) - 1))
    tables = {"a": bp.Tables.from_counts(rec.counts({"a": (3, 20)})["a"])}
    states, words = bp.rans_encode(rec.events, tables, lanes)
    dec = bp.Decoder(states, words, tables)
    for kind, a, v in rec.events:
        got = dec.sym(kind, a) if kind else dec.bits(a)
        assert (got == v).all()
    assert dec.done()


def test_tables_keep_every_symbol_that_occurred():
    counts = np.zeros((2, 255), np.int64)
    counts[0, 3] = 10 ** 9
    counts[0, ::2] += 1
    counts[1] = np.arange(255)
    t = bp.Tables.from_counts(counts)
    assert (t.freq.sum(1) == 1 << bp.PREC).all()
    assert ((t.freq > 0) == (counts > 0)).all()


# ------------------------------------------------------------------- frames

def test_a_frame_alone_and_a_frame_from_its_neighbour_both_come_back():
    a, b = _burst(2)
    sa, sb = (bp.craw_bytes(craw_encode(p)) for p in (a, b))
    blob_a, pa = bp.encode_craw(sa, H, W, None)
    got_a, qa = bp.decode_craw(blob_a, None)
    assert got_a == sa and (qa == pa).all()
    blob_b, _ = bp.encode_craw(sb, H, W, pa)
    got_b, _ = bp.decode_craw(blob_b, qa)
    assert got_b == sb
    alone, _ = bp.encode_craw(sb, H, W, None)
    assert len(blob_b) < len(alone), "the neighbour should have helped: the scene only moved"


def test_blocks_that_break_the_rules_still_come_back():
    """Random bytes: max under min, imax equal to imin, steps past the max."""
    g = np.random.default_rng(3).integers(0, 256, size=34 * 64, dtype=np.uint8).tobytes()
    blob, _ = bp.encode_craw(g, 34, 64, None)
    assert bp.decode_craw(blob, None)[0] == g


def test_an_odd_number_of_rows():
    p = _burst(1)[0][:33]
    s = bp.craw_bytes(craw_encode(p))
    blob, _ = bp.encode_craw(s, 33, W, None)
    assert bp.decode_craw(blob, None)[0] == s


def test_sensor_data_is_found_only_where_an_arw_keeps_it():
    p = _burst(1)[0]
    data = arw(bp.craw_bytes(craw_encode(p)), H, W)
    loc = bp.locate_raw(data)
    assert loc is not None and (loc.H, loc.W, loc.kind) == (H, W, "craw")
    assert data[loc.offset:loc.offset + H * W] == bp.craw_bytes(craw_encode(p))
    assert bp.locate_raw(b"MM\x00*" + data[4:]) is None
    assert bp.locate_raw(b"\xff\xd8 not a tiff") is None
    assert bp.locate_raw(data[:200]) is None       # the strip runs past the end


# ------------------------------------------------------------------ archives

def test_a_burst_comes_back_byte_for_byte_with_its_times(tmp_path):
    paths = _files(tmp_path, _burst(5))
    out = tmp_path / "b.fbp"
    m = bp.pack(paths, out, key=paths[2].name, log=lambda *_: None)
    assert m["key"] == paths[2].name
    refs = {f["name"]: f["ref"] for f in m["frames"]}
    assert refs[paths[2].name] is None
    assert [refs[p.name] for p in paths] == [1, 2, None, 2, 3]
    assert out.stat().st_size < sum(p.stat().st_size for p in paths)
    dest = tmp_path / "back"
    bp.unpack(out, dest, log=lambda *_: None)
    for p in paths:
        assert (dest / p.name).read_bytes() == p.read_bytes()
        assert (dest / p.name).stat().st_mtime_ns == p.stat().st_mtime_ns


def test_one_frame_comes_back_without_the_others(tmp_path):
    paths = _files(tmp_path, _burst(4))
    out = tmp_path / "b.fbp"
    bp.pack(paths, out, log=lambda *_: None)
    dest = tmp_path / "back"
    bp.unpack(out, dest, [paths[3].name], log=lambda *_: None)
    assert [p.name for p in dest.iterdir()] == [paths[3].name]
    assert (dest / paths[3].name).read_bytes() == paths[3].read_bytes()


def test_packing_twice_writes_the_same_archive(tmp_path):
    paths = _files(tmp_path, _burst(3))
    bp.pack(paths, tmp_path / "1.fbp", log=lambda *_: None)
    bp.pack(paths, tmp_path / "2.fbp", log=lambda *_: None)
    assert (tmp_path / "1.fbp").read_bytes() == (tmp_path / "2.fbp").read_bytes()


def test_a_file_it_cannot_model_is_stored_not_refused(tmp_path):
    paths = _files(tmp_path, _burst(2))
    odd = tmp_path / "raw" / "IMG_0001.DNG"
    odd.write_bytes(b"II*\x00" + bytes(range(256)) * 40)
    out = tmp_path / "b.fbp"
    m = bp.pack([paths[0], odd, paths[1]], out, log=lambda *_: None)
    codecs = {f["name"]: (f["codec"], f["ref"]) for f in m["frames"]}
    assert codecs[odd.name] == ("lzma", None)
    # The frame after it could not refer to it, so it stands alone.
    assert codecs[paths[1].name] == ("craw", None)
    dest = tmp_path / "back"
    bp.unpack(out, dest, log=lambda *_: None)
    for p in (paths[0], odd, paths[1]):
        assert (dest / p.name).read_bytes() == p.read_bytes()


def test_a_damaged_archive_writes_nothing(tmp_path):
    paths = _files(tmp_path, _burst(3))
    out = tmp_path / "b.fbp"
    bp.pack(paths, out, log=lambda *_: None)
    data = bytearray(out.read_bytes())
    data[-40] ^= 0x10
    bad = tmp_path / "bad.fbp"
    bad.write_bytes(bytes(data))
    dest = tmp_path / "back"
    with pytest.raises(ValueError):
        bp.unpack(bad, dest, log=lambda *_: None)
    assert not any(dest.iterdir())


def test_nothing_is_written_over(tmp_path):
    paths = _files(tmp_path, _burst(2))
    out = tmp_path / "b.fbp"
    bp.pack(paths, out, log=lambda *_: None)
    with pytest.raises(FileExistsError):
        bp.pack(paths, out, log=lambda *_: None)
    dest = tmp_path / "back"
    dest.mkdir()
    (dest / paths[0].name).write_bytes(b"his")
    with pytest.raises(FileExistsError):
        bp.unpack(out, dest, log=lambda *_: None)
    assert (dest / paths[0].name).read_bytes() == b"his"
    assert sorted(p.name for p in dest.iterdir()) == [paths[0].name]


# ------------------------------------------------------- a shoot, from Finish

def _shoot(tmp_path: Path) -> Path:
    """A culled shoot with two bursts (3 and 2 frames), one frame of each kept."""
    shoot = tmp_path / "photos" / "shoots" / "2026-01-01-lake"
    frames = _burst(3, seed=4) + _burst(2, seed=5)
    paths = _files(shoot, frames)
    rows = ["file,burst,shot_at"] + [f"{p.name},{0 if i < 3 else 1},2026:01:01 10:00:{i:02d}" for i, p in enumerate(paths)]
    (shoot / "cull").mkdir()
    (shoot / "cull" / "cull.csv").write_text("\n".join(rows) + "\n")
    (shoot / "cull" / "selects.json").write_text(json.dumps([paths[1].name, paths[4].name]))
    return shoot


def test_finish_packs_every_burst_and_takes_nothing_away(tmp_path):
    shoot = _shoot(tmp_path)
    raws = {p.name: p.read_bytes() for p in (shoot / "raw").iterdir()}
    said: list[str] = []
    assert bp.pack_shoot(shoot, apply=False, log=said.append) == 0
    assert said[0].startswith("would pack 5 frames in 2 bursts, ")
    assert not (shoot / "packed").exists(), "the list writes nothing"
    said.clear()
    assert bp.pack_shoot(shoot, apply=True, log=said.append) == 0
    assert sorted(p.name for p in (shoot / "packed").iterdir()) == ["burst-0.fbp", "burst-1.fbp"]
    assert said[-1].startswith("packed ") and "@@ pack 5 5" in said
    m, _ = bp.read_manifest((shoot / "packed" / "burst-0.fbp").read_bytes())
    assert m["key"] == "TSC01001.ARW", "the frame he kept is the one stored whole"
    assert {p.name: p.read_bytes() for p in (shoot / "raw").iterdir()} == raws
    back = tmp_path / "back"
    for a in (shoot / "packed").iterdir():
        bp.unpack(a, back, log=lambda *_: None)
    assert {p.name: p.read_bytes() for p in back.iterdir()} == raws
    said.clear()
    bp.pack_shoot(shoot, apply=False, log=said.append)
    assert said[0].startswith("every burst of 2026-01-01-lake is already packed")


def test_the_finish_page_reads_the_list_the_command_printed(tmp_path):
    studio = pytest.importorskip("studio")
    shoot = _shoot(tmp_path)
    said: list[str] = []
    bp.pack_shoot(shoot, apply=False, log=said.append)
    plan = studio._parse_plan("pack", "\n".join(said), {})
    assert plan["ready"] and plan["counts"]["frames"] == 5 and plan["counts"]["bursts"] == 2
    assert plan["label"] == "Pack 2 bursts (5 frames)"
    argv = studio._stor_argv(studio.Shoot(shoot), "pack", {}, apply=True)
    assert argv[-4:] == [str(Path(studio.HERE) / "burstpack.py"), "shoot", str(shoot), "--apply"]
    empty = studio._parse_plan("pack", "every burst of x is already packed, in /x/packed", {})
    assert not empty["ready"] and not empty["label"]
