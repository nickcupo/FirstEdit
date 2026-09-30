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
    out = tmp_path / "b.roll"
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
    out = tmp_path / "b.roll"
    bp.pack(paths, out, log=lambda *_: None)
    dest = tmp_path / "back"
    bp.unpack(out, dest, [paths[3].name], log=lambda *_: None)
    assert [p.name for p in dest.iterdir()] == [paths[3].name]
    assert (dest / paths[3].name).read_bytes() == paths[3].read_bytes()


def test_packing_twice_writes_the_same_archive(tmp_path):
    paths = _files(tmp_path, _burst(3))
    bp.pack(paths, tmp_path / "1.roll", log=lambda *_: None)
    bp.pack(paths, tmp_path / "2.roll", log=lambda *_: None)
    assert (tmp_path / "1.roll").read_bytes() == (tmp_path / "2.roll").read_bytes()


def test_a_file_it_cannot_model_is_stored_not_refused(tmp_path):
    paths = _files(tmp_path, _burst(2))
    odd = tmp_path / "raw" / "IMG_0001.DNG"
    odd.write_bytes(b"II*\x00" + bytes(range(256)) * 40)
    out = tmp_path / "b.roll"
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
    out = tmp_path / "b.roll"
    bp.pack(paths, out, log=lambda *_: None)
    data = bytearray(out.read_bytes())
    data[-40] ^= 0x10
    bad = tmp_path / "bad.roll"
    bad.write_bytes(bytes(data))
    dest = tmp_path / "back"
    with pytest.raises(ValueError):
        bp.unpack(bad, dest, log=lambda *_: None)
    assert not any(dest.iterdir())


def test_nothing_is_written_over(tmp_path):
    paths = _files(tmp_path, _burst(2))
    out = tmp_path / "b.roll"
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
    assert said[0].startswith("would pack 5 frames in 2 bursts and 0 single frames, ")
    assert not (shoot / "packed").exists(), "the list writes nothing"
    said.clear()
    assert bp.pack_shoot(shoot, apply=True, log=said.append) == 0
    assert sorted(p.name for p in (shoot / "packed").iterdir()) == ["burst-0.roll", "burst-1.roll"]
    assert said[-1].startswith("packed ") and "@@ pack 5 5" in said
    m, _ = bp.read_manifest((shoot / "packed" / "burst-0.roll").read_bytes())
    assert m["key"] == "TSC01001.ARW", "the frame he kept is the one stored whole"
    assert {p.name: p.read_bytes() for p in (shoot / "raw").iterdir()} == raws
    back = tmp_path / "back"
    for a in (shoot / "packed").iterdir():
        bp.unpack(a, back, log=lambda *_: None)
    assert {p.name: p.read_bytes() for p in back.iterdir()} == raws
    said.clear()
    bp.pack_shoot(shoot, apply=False, log=said.append)
    assert said[0] == "nothing left to pack in 2026-01-01-lake."
    assert said[1].startswith("5 frames already packed")


def test_the_finish_page_reads_the_list_the_command_printed(tmp_path):
    studio = pytest.importorskip("studio")
    shoot = _shoot(tmp_path)
    said: list[str] = []
    bp.pack_shoot(shoot, apply=False, log=said.append)
    plan = studio._parse_plan("pack", "\n".join(said), {})
    assert plan["ready"] and plan["counts"]["frames"] == 5 and plan["counts"]["bursts"] == 2
    assert plan["label"].startswith("Pack 5 frames (") and plan["counts"]["singles"] == 0
    argv = studio._stor_argv(studio.Shoot(shoot), "pack", {}, apply=True)
    assert argv[-4:] == [str(Path(studio.HERE) / "burstpack.py"), "shoot", str(shoot), "--apply"]
    empty = studio._parse_plan("pack", "nothing left to pack in x.", {})
    assert not empty["ready"] and not empty["label"]


# ------------------------------------------------------------- the C core

needs_core = pytest.mark.skipif(bp.core() is None, reason="no C compiler here, so no core to compare with numpy")


def _numpy(fn):
    """fn() with the C core put away, so every step runs in numpy."""
    lib = bp._CORE.get("lib")
    bp._CORE["lib"] = None
    try:
        return fn()
    finally:
        bp._CORE["lib"] = lib


@needs_core
def test_the_c_core_writes_the_same_bytes_as_numpy():
    """The format is numpy's, and C is only a faster way to write it: the same
    archive from either, frame alone, frame from its neighbour, blocks that
    break the rules, and an odd number of rows."""
    a, b = (bp.craw_bytes(craw_encode(p)) for p in _burst(2, seed=7))
    blob_c, pc = bp.encode_craw(a, H, W, None)
    blob_n, pn = _numpy(lambda: bp.encode_craw(a, H, W, None))
    assert blob_c == blob_n and (pc == pn).all()
    assert bp.encode_craw(b, H, W, pc)[0] == _numpy(lambda: bp.encode_craw(b, H, W, pn))[0]
    g = np.random.default_rng(8).integers(0, 256, size=34 * 64, dtype=np.uint8).tobytes()
    assert bp.encode_craw(g, 34, 64, None)[0] == _numpy(lambda: bp.encode_craw(g, 34, 64, None))[0]
    odd = bp.craw_bytes(craw_encode(_burst(1)[0][:33]))
    assert bp.encode_craw(odd, 33, W, None)[0] == _numpy(lambda: bp.encode_craw(odd, 33, W, None))[0]


@needs_core
def test_either_unpacks_what_the_other_packed():
    a, b = (bp.craw_bytes(craw_encode(p)) for p in _burst(2, seed=9))
    blob_a, pa = _numpy(lambda: bp.encode_craw(a, H, W, None))
    blob_b, _ = _numpy(lambda: bp.encode_craw(b, H, W, pa))
    got_a, qa = bp.decode_craw(blob_a, None)
    assert got_a == a and bp.decode_craw(blob_b, qa)[0] == b
    blob_c, pc = bp.encode_craw(b, H, W, None)
    assert _numpy(lambda: bp.decode_craw(blob_c, None))[0] == b


@needs_core
def test_the_c_core_says_so_when_a_stream_is_damaged():
    s = bp.craw_bytes(craw_encode(_burst(1, seed=10)[0]))
    parts = bp._unblob(bp.encode_craw(s, H, W, None)[0])
    words = bytearray(parts[-1])
    del words[-8:]                      # cut short
    with pytest.raises(ValueError):
        bp.decode_craw(bp._blob(*parts[:-1], bytes(words)), None)


def test_bursts_are_packed_side_by_side_to_the_same_bytes(tmp_path, monkeypatch):
    one, two = _shoot(tmp_path / "one"), _shoot(tmp_path / "two")
    monkeypatch.setattr(bp, "_workers", lambda n, b: 1)
    assert bp.pack_shoot(one, apply=True, log=lambda *_: None) == 0
    monkeypatch.setattr(bp, "_workers", lambda n, b: 2)
    said: list[str] = []
    assert bp.pack_shoot(two, apply=True, log=said.append) == 0
    assert "packing on 2 cores" in said[1]
    assert "@@ pack 5 5" in said, "every frame a worker packed is counted on the bar"
    for name in ("burst-0.roll", "burst-1.roll"):
        assert (one / "packed" / name).read_bytes() == (two / "packed" / name).read_bytes()


def test_every_frame_is_packed_or_named(tmp_path, monkeypatch):
    """857 shot and 850 packed, with nothing said about the other seven, is the
    bug this is for: a frame in no burst, one the cull never saw, and one whose
    bytes are only in iCloud are each accounted for."""
    shoot = _shoot(tmp_path)
    raw = shoot / "raw"
    extra = _files(tmp_path / "more", _burst(3, seed=11), prefix="TSC9")
    lone, unseen, evicted = (raw / p.name for p in extra)
    for p, q in zip(extra, (lone, unseen, evicted)):
        p.rename(q)
    with (shoot / "cull" / "cull.csv").open("a") as fh:
        fh.write(f"{lone.name},,2026:01:01 11:00:00\n{evicted.name},1,2026:01:01 10:00:09\n")
    import archive
    monkeypatch.setattr(archive, "local", lambda p: Path(p).name != evicted.name)
    said: list[str] = []
    bp.pack_shoot(shoot, apply=False, log=said.append)
    assert said[0].startswith("would pack 7 frames in 2 bursts and 2 single frames, ")
    assert "1 frame will not be packed:" in said
    assert any(line.startswith(f"  - {evicted.name}: in iCloud") for line in said)
    studio = pytest.importorskip("studio")
    plan = studio._parse_plan("pack", "\n".join(said), {})
    assert plan["counts"]["frames"] == 7 and plan["counts"]["singles"] == 2
    assert any(evicted.name in r for r in plan["refusals"]), "the sheet names the frame it leaves out"
    bp.pack_shoot(shoot, apply=True, log=lambda *_: None)
    assert sorted(p.name for p in (shoot / "packed").iterdir()) == [
        "burst-0.roll", "burst-1.roll", f"frame-{lone.stem}.roll", f"frame-{unseen.stem}.roll"]
    back = tmp_path / "back"
    for a in (shoot / "packed").iterdir():
        bp.unpack(a, back, log=lambda *_: None)
    assert sorted(p.name for p in back.iterdir()) == sorted(p.name for p in raw.iterdir() if p != evicted)
    for p in back.iterdir():
        assert p.read_bytes() == (raw / p.name).read_bytes()


# ------------------------------------------------- packed copies in iCloud

def _finished_shoot(tmp_path: Path, monkeypatch) -> tuple[Path, dict[str, bytes]]:
    import archive
    shoot = _shoot(tmp_path)
    (shoot / "shoot.json").write_text(json.dumps({"kind": "other", "finished": "2026-01-02"}))
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    bp.pack_shoot(shoot, apply=True, log=lambda *_: None)
    return shoot, {p.name: p.read_bytes() for p in (shoot / "raw").iterdir()}


def test_packed_bursts_go_up_come_down_and_let_the_raws_go(tmp_path, monkeypatch, capsys):
    import archive
    import reclaim
    shoot, raws = _finished_shoot(tmp_path, monkeypatch)
    assert archive.push(shoot, apply=False, form="packed") == 0
    assert "packed first" in capsys.readouterr().out
    assert archive.push(shoot, apply=True, form="packed") == 0
    up = tmp_path / "icloud" / shoot.name
    assert sorted(p.name for p in (up / "packed").iterdir()) == ["burst-0.roll", "burst-1.roll"]
    assert not list(up.glob("*.ARW")), "the packed bursts went up instead of the RAWs"
    man = archive.load_manifest(shoot)
    assert set(archive.packed_frames(man)) == set(raws)
    assert all(r["up"] and r["recorded"] for r in archive.status(shoot)["rows"])
    assert bp.check_shoot(shoot, log=lambda *_: None) == 0
    assert archive.push(shoot, apply=False) == 0
    assert "nothing to do." in capsys.readouterr().out, "nothing goes up twice, in either form"

    assert archive.drop(shoot, apply=True) == 0
    assert not list((shoot / "raw").iterdir())
    rows = archive.status(shoot)["rows"]
    assert len(rows) == 5 and all(r.get("dropped") and r["up"] for r in rows)
    assert all(reclaim.archived_elsewhere(reclaim.Shoot(shoot)).values())

    # Back from the copy in iCloud, with the shoot's own packed/ gone too.
    import shutil
    shutil.rmtree(shoot / "packed")
    assert archive.pull(shoot, apply=True) == 0
    assert {p.name: p.read_bytes() for p in (shoot / "raw").iterdir()} == raws


def test_a_packed_copy_that_is_not_the_one_pushed_frees_nothing(tmp_path, monkeypatch, capsys):
    import archive
    shoot, raws = _finished_shoot(tmp_path, monkeypatch)
    archive.push(shoot, apply=True, form="packed")
    q = archive.packed_dest(shoot, "burst-0.roll")
    data = bytearray(q.read_bytes())
    data[-100] ^= 1
    q.write_bytes(bytes(data))
    archive.drop(shoot, apply=True)
    out = capsys.readouterr().out
    assert "does not match what was pushed" in out
    left = sorted(p.name for p in (shoot / "raw").iterdir())
    assert left == ["TSC01000.ARW", "TSC01001.ARW", "TSC01002.ARW"], "burst 0 stays; burst 1 was proved and went"


def test_a_packed_copy_is_unpacked_before_it_is_believed(tmp_path, monkeypatch, capsys):
    """A copy whose record has been made to match it - so only unpacking it can
    tell - does not let a RAW go."""
    import archive
    from common import write_json_atomic
    shoot, raws = _finished_shoot(tmp_path, monkeypatch)
    archive.push(shoot, apply=True, form="packed")
    q = archive.packed_dest(shoot, "burst-1.roll")
    data = bytearray(q.read_bytes())
    data[-100] ^= 1
    q.write_bytes(bytes(data))
    man = archive.load_manifest(shoot)
    man["packed"]["burst-1.roll"]["sha256"] = archive.sha256(q)
    write_json_atomic(archive.manifest_path(shoot), man)
    archive.drop(shoot, apply=True)
    assert "does not unpack" in capsys.readouterr().out
    assert sorted(p.name for p in (shoot / "raw").iterdir()) == ["TSC01003.ARW", "TSC01004.ARW"]


def test_a_raw_changed_after_packing_goes_up_as_itself(tmp_path, monkeypatch, capsys):
    import archive
    shoot, raws = _finished_shoot(tmp_path, monkeypatch)
    p = shoot / "raw" / "TSC01003.ARW"
    b = bytearray(p.read_bytes())
    b[200] ^= 1
    p.write_bytes(bytes(b))
    assert bp.check_shoot(shoot, log=lambda *_: None) == 1, "the check says the packed copy is not this RAW"
    archive.push(shoot, apply=True, form="packed")
    assert "does not unpack to the RAWs here" in capsys.readouterr().out
    up = tmp_path / "icloud" / shoot.name
    assert sorted(x.name for x in up.glob("*.ARW")) == ["TSC01003.ARW", "TSC01004.ARW"]
    assert [x.name for x in (up / "packed").iterdir()] == ["burst-0.roll"]


def test_raw_goes_up_as_raw_even_beside_packed_bursts(tmp_path, monkeypatch):
    import archive
    shoot, raws = _finished_shoot(tmp_path, monkeypatch)
    assert archive.push(shoot, apply=True) == 0
    up = tmp_path / "icloud" / shoot.name
    assert sorted(p.name for p in up.glob("*.ARW")) == sorted(raws)
    assert not (up / "packed").exists()


def test_packed_packs_first_when_nothing_is_packed_yet(tmp_path, monkeypatch):
    import archive
    shoot = _shoot(tmp_path)
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    assert not (shoot / "packed").exists()
    assert archive.push(shoot, apply=True, form="packed") == 0
    assert sorted(p.name for p in (tmp_path / "icloud" / shoot.name / "packed").iterdir()) == \
        ["burst-0.roll", "burst-1.roll"]


def test_copies_in_icloud_go_only_where_this_mac_has_the_raws(tmp_path, monkeypatch, capsys):
    import archive
    shoot, raws = _finished_shoot(tmp_path, monkeypatch)
    # Burst 0 up as RAWs, burst 1 packed: both forms at once.
    for name in ("TSC01000.ARW", "TSC01001.ARW", "TSC01002.ARW"):
        d = archive.dest_for(shoot, name)
        d.parent.mkdir(parents=True, exist_ok=True)
        d.write_bytes(raws[name])
    man = archive.load_manifest(shoot)
    man["frames"] = {n: {"bytes": len(raws[n]), "sha256": archive.sha256(archive.dest_for(shoot, n))}
                     for n in ("TSC01000.ARW", "TSC01001.ARW", "TSC01002.ARW")}
    from common import write_json_atomic
    write_json_atomic(archive.manifest_path(shoot), man)
    archive.push(shoot, apply=True, form="packed")
    up = tmp_path / "icloud" / shoot.name
    assert sorted(p.name for p in (up / "packed").iterdir()) == ["burst-1.roll"]

    # One RAW here changed: its copy up there stays, and the packed burst is untouched by --only raw.
    (shoot / "raw" / "TSC01000.ARW").write_bytes(b"x" + raws["TSC01000.ARW"][1:])
    assert archive.trim(shoot, apply=True, form="raw") == 0
    out = capsys.readouterr().out
    assert "TSC01000.ARW: the RAW here is not the one in iCloud" in out
    assert sorted(p.name for p in up.glob("*.ARW")) == ["TSC01000.ARW"]
    assert (up / "packed" / "burst-1.roll").exists()
    man = archive.load_manifest(shoot)
    assert sorted(man["frames"]) == ["TSC01000.ARW"] and "burst-1.roll" in man["packed"]

    assert archive.trim(shoot, apply=True, form="packed") == 0
    assert not (up / "packed" / "burst-1.roll").exists()
    assert archive.load_manifest(shoot)["packed"] == {}
    assert sorted(p.name for p in (shoot / "raw").iterdir()) == sorted(raws), "no RAW here was touched"


def test_with_the_raws_gone_every_copy_up_there_stays(tmp_path, monkeypatch, capsys):
    import archive
    shoot, raws = _finished_shoot(tmp_path, monkeypatch)
    archive.push(shoot, apply=True, form="packed")
    archive.drop(shoot, apply=True)
    assert not list((shoot / "raw").iterdir())
    assert not list((shoot / "packed").iterdir()), "the packed bursts here went too, the same files being up"
    capsys.readouterr()
    assert archive.trim(shoot, apply=True) == 0
    assert "nothing to remove." in capsys.readouterr().out
    assert len(list((tmp_path / "icloud" / shoot.name / "packed").iterdir())) == 2
    assert archive.pull(shoot, apply=True) == 0
    assert {p.name: p.read_bytes() for p in (shoot / "raw").iterdir()} == raws


def test_letting_go_keeps_the_record_of_packed_bursts(tmp_path, monkeypatch):
    """expire rewrote archive.json from its ARW records alone, which forgot
    every packed burst up there."""
    import archive
    shoot, raws = _finished_shoot(tmp_path, monkeypatch)
    (shoot / "shoot.json").write_text(json.dumps({"kind": "other", "finished": "2000-01-01"}))
    archive.push(shoot, apply=True, form="packed")
    d = archive.dest_for(shoot, "TSC01000.ARW")
    d.write_bytes(raws["TSC01000.ARW"])
    man = archive.load_manifest(shoot)
    man["frames"]["TSC01000.ARW"] = {"bytes": len(raws["TSC01000.ARW"]), "sha256": archive.sha256(d)}
    from common import write_json_atomic
    write_json_atomic(archive.manifest_path(shoot), man)
    archive.expire(shoot, True, 0, True, False)
    assert not d.exists(), "the ARW spare was let go"
    assert set(archive.load_manifest(shoot)["packed"]) == {"burst-0.roll", "burst-1.roll"}


def test_the_sheets_read_the_forms_and_the_new_lists(tmp_path, monkeypatch, capsys):
    studio = pytest.importorskip("studio")
    import archive
    shoot, raws = _finished_shoot(tmp_path, monkeypatch)
    s = studio.Shoot(shoot)
    assert studio._stor_argv(s, "push", {"form": "packed"}, apply=True)[-3:] == ["--as", "packed", "--apply"]
    assert "--as" not in studio._stor_argv(s, "push", {"form": "raw"}, apply=False)
    assert studio._stor_argv(s, "trim", {"form": "packed"}, apply=False)[-2:] == ["--only", "packed"]
    assert studio._stor_argv(s, "trim", {}, apply=False)[-2:] == ["--only", "both"]
    assert studio._stor_body({"form": ["packed"]})["form"] == "packed"
    assert studio._stor_body({"form": ["rm -rf"]})["form"] is None

    archive.push(shoot, apply=False, form="packed")
    plan = studio._parse_plan("push", capsys.readouterr().out, {"form": "packed"})
    assert plan["ready"] and plan["label"] == "Pack and copy 5 frames up"
    archive.push(shoot, apply=True, form="packed")
    capsys.readouterr()
    archive.trim(shoot, apply=False, form="both")
    plan = studio._parse_plan("trim", capsys.readouterr().out, {"form": "both"})
    assert plan["ready"] and plan["label"].startswith("Remove 2 copies from iCloud (")
    archive.drop(shoot, apply=False)
    plan = studio._parse_plan("drop", capsys.readouterr().out, {})
    assert plan["ready"] and plan["counts"]["packed"] == 2
    assert plan["label"].startswith("Remove 5 originals and 2 packed bursts, and free ")


def test_packed_bursts_unpack_into_any_folder_and_never_over_a_file(tmp_path, monkeypatch):
    import archive
    shoot, raws = _finished_shoot(tmp_path, monkeypatch)
    archive.push(shoot, apply=True, form="packed")
    archive.drop(shoot, apply=True)
    assert not list((shoot / "packed").iterdir()), "so these come out of iCloud"
    out = tmp_path / "Desktop" / "lake RAWs"
    said: list[str] = []
    assert bp.export_shoot(shoot, out, log=said.append) == 0
    assert said[-1].startswith("5 RAWs unpacked into ")
    assert {p.name: p.read_bytes() for p in out.iterdir()} == raws
    assert (out / "TSC01000.ARW").stat().st_mtime_ns == 1_700_000_000_000_000_000

    (out / "TSC01001.ARW").write_bytes(b"his own")
    (out / "TSC01002.ARW").unlink()
    said.clear()
    assert bp.export_shoot(shoot, out, log=said.append) == 1
    assert "1 RAWs unpacked" in said[-1] and "3 were there already" in said[-1]
    assert (out / "TSC01001.ARW").read_bytes() == b"his own", "a different file of that name is left alone"
    assert (out / "TSC01002.ARW").read_bytes() == raws["TSC01002.ARW"]
    assert not list(out.glob(".*.tmp"))


def test_raws_come_back_by_themselves_before_work_that_reads_them(tmp_path, monkeypatch, capsys):
    """Cull, presets and the PhotoLab folder call this first: a shoot whose
    RAWs left this Mac is worked on as though they never had."""
    import archive
    shoot, raws = _finished_shoot(tmp_path, monkeypatch)
    assert archive.restore_for_work(shoot) == 0
    assert "bringing them back" not in capsys.readouterr().out, "nothing to do when every RAW is here"
    archive.push(shoot, apply=True, form="packed")
    archive.drop(shoot, apply=True)
    assert not list((shoot / "raw").iterdir())
    studio = pytest.importorskip("studio")
    assert studio._q_frames(studio.Shoot(shoot)) == 5, "the steps still see a shoot of five photographs"
    assert archive.restore_for_work(shoot / "raw") == 0
    assert {p.name: p.read_bytes() for p in (shoot / "raw").iterdir()} == raws


def test_work_stops_when_a_raw_cannot_come_back(tmp_path, monkeypatch, capsys):
    import archive
    shoot, raws = _finished_shoot(tmp_path, monkeypatch)
    archive.push(shoot, apply=True, form="packed")
    archive.drop(shoot, apply=True)
    archive.packed_dest(shoot, "burst-1.roll").unlink()
    assert archive.restore_for_work(shoot) == 1
    assert "could not be brought back" in capsys.readouterr().out


def test_raws_already_in_icloud_are_packed_there_and_their_arws_let_go(tmp_path, monkeypatch, capsys):
    import archive
    import shutil
    shoot = _shoot(tmp_path)
    (shoot / "shoot.json").write_text(json.dumps({"kind": "other", "finished": "2026-01-02"}))
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    raws = {p.name: p.read_bytes() for p in (shoot / "raw").iterdir()}
    archive.push(shoot, apply=True)                    # up as RAW files
    archive.drop(shoot, apply=True)                    # and gone from this Mac
    up = tmp_path / "icloud" / shoot.name
    assert sorted(p.name for p in up.glob("*.ARW")) == sorted(raws)
    capsys.readouterr()
    assert archive.repack(shoot, apply=False) == 0
    assert "would pack 5 frames in iCloud" in capsys.readouterr().out
    assert archive.repack(shoot, apply=True) == 0     # read from iCloud, since nothing is here
    assert not list(up.glob("*.ARW")), "the ARW copies went, the packed ones being up and checked"
    assert sorted(p.name for p in (up / "packed").iterdir()) == ["burst-0.roll", "burst-1.roll"]
    man = archive.load_manifest(shoot)
    assert man["frames"] == {} and set(archive.packed_frames(man)) == set(raws)
    assert not (shoot / "packed" / ".staging").exists()
    shutil.rmtree(shoot / "packed", ignore_errors=True)
    assert archive.pull(shoot, apply=True) == 0
    assert {p.name: p.read_bytes() for p in (shoot / "raw").iterdir()} == raws
    capsys.readouterr()
    assert archive.repack(shoot, apply=False) == 0
    assert "nothing to do." in capsys.readouterr().out


def test_arw_copies_wait_for_icloud_to_have_the_packed_one(tmp_path, monkeypatch, capsys):
    import archive
    shoot = _shoot(tmp_path)
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    archive.push(shoot, apply=True)
    monkeypatch.setattr(archive, "_unvouched", lambda d: "iCloud has not finished uploading the copy"
                        if d.suffix == ".roll" else "")
    assert archive.repack(shoot, apply=True) == 0
    assert "5 ARW copies stay until iCloud has uploaded" in capsys.readouterr().out
    up = tmp_path / "icloud" / shoot.name
    assert len(list(up.glob("*.ARW"))) == 5 and len(list((up / "packed").iterdir())) == 2
    monkeypatch.setattr(archive, "_unvouched", lambda d: "")
    assert archive.repack(shoot, apply=False) == 0
    assert "would remove 5 ARW copies from iCloud" in capsys.readouterr().out
    assert archive.repack(shoot, apply=True) == 0
    assert not list(up.glob("*.ARW"))


def _in_icloud_only(tmp_path: Path, monkeypatch) -> Path:
    import archive
    shoot = _shoot(tmp_path)
    (shoot / "shoot.json").write_text(json.dumps({"kind": "other", "finished": "2026-01-02"}))
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    archive.push(shoot, apply=True)                    # up as RAW files
    archive.drop(shoot, apply=True)                    # and gone from this Mac
    assert not list((shoot / "raw").iterdir())
    return shoot


def test_packing_in_icloud_runs_bursts_side_by_side_and_packs_the_same_bytes(tmp_path, monkeypatch, capsys):
    import archive
    got = {}
    for workers in (1, 2):
        shoot = _in_icloud_only(tmp_path / f"on-{workers}", monkeypatch)
        monkeypatch.setattr(bp, "_workers", lambda n, size, w=workers: w)
        capsys.readouterr()
        assert archive.repack(shoot, apply=True) == 0
        out = capsys.readouterr().out
        assert f"packing on {workers} {'core' if workers == 1 else 'cores'}" in out
        assert "Packed 5 frames in iCloud; removed 5 ARW copies" in out
        up = tmp_path / f"on-{workers}" / "icloud" / shoot.name / "packed"
        # Each frame's mtime is its copy's in iCloud, which each run pushed anew.
        got[workers] = {p.name: (archive.unpacked_hashes(p),
                                 [{k: v for k, v in f.items() if k != "mtime_ns"}
                                  for f in bp.read_manifest(p.read_bytes())[0]["frames"]])
                        for p in up.iterdir()}
        assert not (shoot / "packed" / ".staging").exists()
    assert sorted(got[2]) == ["burst-0.roll", "burst-1.roll"]
    assert got[2] == got[1], "side by side, each burst packs as it does on one core"


def test_a_burst_that_cannot_be_packed_in_icloud_does_not_stop_the_others(tmp_path, monkeypatch, capsys):
    import archive
    shoot = _in_icloud_only(tmp_path, monkeypatch)
    monkeypatch.setattr(bp, "_workers", lambda n, size: 2)
    bad = archive.dest_for(shoot, "TSC01003.ARW")
    bad.write_bytes(bad.read_bytes()[:-1] + b"\0")
    capsys.readouterr()
    assert archive.repack(shoot, apply=True) == 1
    out = capsys.readouterr().out
    assert "burst-1: not packed: the ARW of TSC01003.ARW in iCloud does not match what was pushed" in out
    up = tmp_path / "icloud" / shoot.name
    assert sorted(p.name for p in (up / "packed").iterdir()) == ["burst-0.roll"]
    assert sorted(p.name for p in up.glob("*.ARW")) == ["TSC01003.ARW", "TSC01004.ARW"], \
        "the burst left out keeps its ARWs; the packed one's go"
    assert not list(up.rglob("*.part"))


def test_the_pool_takes_a_burst_only_as_a_worker_comes_free(tmp_path):
    """So repack's fetching from iCloud runs just ahead of the packing."""
    frames = [f for s in range(5) for f in _burst(2, seed=10 + s)]
    paths = _files(tmp_path, frames)
    handed, ended = [], []

    def jobs():
        for i in range(5):
            handed.append(i)
            assert len(handed) - len(ended) <= 2, "one burst for each of two workers, never more"
            yield f"b{i}", paths[2 * i:2 * i + 2], None, tmp_path / f"b{i}{bp.EXT}"

    bp._pack_parallel(jobs(), 2, lambda _line: None, lambda bid, b, a, err: ended.append((bid, err)))
    assert sorted(ended) == [(f"b{i}", None) for i in range(5)]


def test_every_packed_burst_written_is_given_its_icon(tmp_path, monkeypatch):
    """Here, and each copy into iCloud, which a copy would otherwise leave without one."""
    import archive
    import rollicon
    given: list[str] = []
    monkeypatch.setattr(rollicon, "give_icon", lambda p, archive=None: given.append(Path(p).name) or True)
    monkeypatch.setattr(bp, "_workers", lambda n, size: 1)       # in this process, where the patch is
    shoot = _shoot(tmp_path)
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    assert archive.push(shoot, apply=True, form="packed") == 0
    here = [n for n in given if n.startswith(".burst-") and n.endswith(".tmp")]
    up = [n for n in given if n.endswith(".roll.part")]
    assert len(here) == 2, "each written in packed/ on this Mac"
    assert sorted(up) == [".burst-0.roll.part", ".burst-1.roll.part"], "and each copy up, before it takes its name"


def test_bursts_are_recorded_as_they_finish_while_the_next_are_still_being_fetched(tmp_path):
    """Fetching a burst can be a download from iCloud. With every core filled
    before anything finished was looked at, Pack in iCloud sat at nought for
    minutes with bursts already packed."""
    import time
    frames = [f for s in range(4) for f in _burst(2, seed=20 + s)]
    paths = _files(tmp_path, frames)
    events: list[str] = []

    def jobs():
        for i in range(4):
            time.sleep(2)                                  # the download
            events.append(f"handed b{i}")
            yield f"b{i}", paths[2 * i:2 * i + 2], None, tmp_path / f"b{i}{bp.EXT}"

    bp._pack_parallel(jobs(), 4, lambda _line: None, lambda bid, b, a, err: events.append(f"ended {bid}"))
    assert sorted(e for e in events if e.startswith("ended")) == [f"ended b{i}" for i in range(4)]
    assert events.index("handed b3") > min(events.index(e) for e in events if e.startswith("ended")), \
        "a finished burst is recorded before the last one is even fetched"


def test_pack_in_icloud_downloads_several_bursts_at_once(tmp_path, monkeypatch, capsys):
    """iCloud cannot pack; each ARW comes down first. One at a time, the
    download was the whole of the wait and most cores sat idle."""
    import threading
    import time
    import archive
    shoot = _in_icloud_only(tmp_path, monkeypatch)
    now = [0]
    most = [0]
    lock = threading.Lock()

    def slow_download(p, timeout=600.0, poll=0.5, stop=None):
        with lock:
            now[0] += 1
            most[0] = max(most[0], now[0])
        time.sleep(1)
        with lock:
            now[0] -= 1
        return True

    monkeypatch.setattr(archive, "local", lambda p: False)          # every ARW is up there only
    monkeypatch.setattr(archive, "materialise", slow_download)
    monkeypatch.setattr(bp, "_workers", lambda n, size: 2)
    assert archive.repack(shoot, apply=True) == 0
    assert most[0] == 2, "both bursts fetched at once"
    up = tmp_path / "icloud" / shoot.name
    assert sorted(p.name for p in (up / "packed").iterdir()) == ["burst-0.roll", "burst-1.roll"]
    assert "Packed 5 frames in iCloud" in capsys.readouterr().out


_STOPPED_MIDWAY = """
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from common import stop_cleanly_on_sigterm
stop_cleanly_on_sigterm()
import burstpack as bp
jobs = [(f"b{i}", [Path(f)], None, Path(sys.argv[2]) / f"b{i}.roll") for i, f in enumerate(sys.argv[3:])]
print("packing", flush=True)
bp._pack_parallel(jobs, 3, lambda _line: None, lambda *_: None)
"""


def test_a_stop_ends_a_pack_on_many_cores_at_once(tmp_path):
    """The studio's Stop is SIGTERM to every process of the job. Each worker
    here is stuck reading a pipe nobody writes to, and one core has nothing to
    do: under multiprocessing.Pool that idle worker died holding the queue's
    lock and the pack never ended."""
    import os
    import signal
    import subprocess
    import time
    fifos = []
    for i in range(2):
        f = tmp_path / f"TSC0{i}.ARW"
        os.mkfifo(f)
        fifos.append(str(f))
    p = subprocess.Popen([sys.executable, "-c", _STOPPED_MIDWAY, str(bp._here()), str(tmp_path), *fifos],
                         stdout=subprocess.PIPE, text=True, start_new_session=True)
    try:
        assert p.stdout.readline().strip() == "packing"
        time.sleep(3)                                    # the workers are up and stuck
        os.killpg(p.pid, signal.SIGTERM)
        p.wait(timeout=20)
    except subprocess.TimeoutExpired:
        pytest.fail("the pack did not end after Stop")
    finally:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    time.sleep(0.5)
    with pytest.raises((ProcessLookupError, PermissionError)):
        os.killpg(p.pid, 0)                              # and nothing of it is left running
    assert not list(tmp_path.glob("*.roll"))


def test_copies_a_run_never_finished_are_cleared_from_icloud(tmp_path, monkeypatch, capsys):
    """A .part is a copy that never took its name: the app force-quit or the
    Mac off mid-copy. Left in iCloud Drive it is uploaded as a file of its own."""
    import archive
    shoot = _in_icloud_only(tmp_path, monkeypatch)
    up = tmp_path / "icloud" / shoot.name
    (up / "packed").mkdir(exist_ok=True)
    stray = [up / ".TSC01000.ARW.part", up / "packed" / ".burst-7.roll.part"]
    for t in stray:
        t.write_bytes(b"half a copy")
    assert archive.repack(shoot, apply=False) == 0
    assert all(t.exists() for t in stray), "only a run that writes clears them"
    capsys.readouterr()
    assert archive.repack(shoot, apply=True) == 0
    out = capsys.readouterr().out
    assert not any(t.exists() for t in stray)
    assert sorted(p.name for p in (up / "packed").iterdir()) == ["burst-0.roll", "burst-1.roll"]
    assert "removed .burst-7.roll.part, a copy an earlier run never finished" in out
    assert "removed .TSC01000.ARW.part, a copy an earlier run never finished" in out


def test_the_engine_clears_what_packs_cut_short_left_in_every_shoot(tmp_path, monkeypatch):
    """A shoot nobody packs again kept its strays for good, one in iCloud
    uploaded against his storage; the engine clears them when it starts."""
    import archive
    monkeypatch.setattr(archive, "ICLOUD", tmp_path / "icloud")
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud" / "Photo Pipeline Archive")
    shoots = tmp_path / "photos" / "shoots"
    kept = []
    for name in ("2026-01-01-lake", "2026-01-02-gym"):
        packed = shoots / name / "packed"
        (packed / ".staging").mkdir(parents=True)
        (packed / ".staging" / "burst-3.roll").write_bytes(b"half")
        (packed / ".burst-4.roll.abc123.tmp").write_bytes(b"half")
        (packed / "burst-1.roll").write_bytes(b"a finished pack")
        up = archive.ARCHIVE / name
        (up / "packed").mkdir(parents=True)
        (up / ".TSC01000.ARW.part").write_bytes(b"half")
        (up / "packed" / ".burst-2.roll.part").write_bytes(b"half")
        (up / "packed" / "burst-1.roll").write_bytes(b"a finished pack")
        (up / "TSC01001.ARW").write_bytes(b"a finished copy")
        kept += [packed / "burst-1.roll", up / "packed" / "burst-1.roll", up / "TSC01001.ARW"]
    gone = archive.clear_strays(shoots)
    assert len(gone) == 2 * 5, "four files and the staging folder, in each of two shoots"
    assert all(p.exists() for p in kept), "nothing finished is touched"
    left = [p for p in tmp_path.rglob("*") if p.name.startswith(".")]
    assert not left
    assert archive.clear_strays(shoots) == [], "and a second time there is nothing"


def test_the_sheet_reads_the_repack_list(tmp_path, monkeypatch, capsys):
    studio = pytest.importorskip("studio")
    import archive
    shoot = _shoot(tmp_path)
    monkeypatch.setattr(archive, "ARCHIVE", tmp_path / "icloud")
    archive.push(shoot, apply=True)
    capsys.readouterr()
    archive.repack(shoot, apply=False)
    plan = studio._parse_plan("repack", capsys.readouterr().out, {})
    assert plan["ready"] and plan["label"].startswith("Pack 5 frames in iCloud (")
    assert studio._stor_argv(studio.Shoot(shoot), "repack", {}, apply=True)[-3:] == ["repack", str(shoot), "--apply"]


def _fake_imaging(monkeypatch) -> list[Path]:
    """cull's exiftool and faces' rawpy, stood in for: each writes a JPEG
    named for the frame holding the SHA-256 of the RAW it was handed, so the
    test sees which bytes the viewer made its pictures from."""
    import hashlib
    import types
    import common
    made: list[Path] = []

    def extract_previews(files, outdir, meta=None):
        for f in files:
            (outdir / f"{f.stem}.jpg").write_text(hashlib.sha256(f.read_bytes()).hexdigest())
            made.append(f)

    def decode_to_file(raw, out, full=True):
        out.write_text(hashlib.sha256(raw.read_bytes()).hexdigest())
        return out

    def ensure_thumbs(previews, thumbs, files, decoded=None, large=None):
        for f in files:
            for d in (thumbs, large):
                d.mkdir(parents=True, exist_ok=True)
                (d / f"{f['stem']}.jpg").write_bytes((previews / f"{f['stem']}.jpg").read_bytes())

    monkeypatch.setitem(sys.modules, "cull", types.SimpleNamespace(
        extract_previews=extract_previews, read_metadata=lambda files: {}))
    monkeypatch.setitem(sys.modules, "faces", types.SimpleNamespace(decode_to_file=decode_to_file))
    monkeypatch.setattr(common, "ensure_thumbs", ensure_thumbs)
    return made


@pytest.mark.parametrize("where", ["here", "icloud"])
def test_a_frame_only_in_a_packed_burst_still_has_its_pictures(tmp_path, monkeypatch, where):
    import hashlib
    import shutil
    import archive
    studio = pytest.importorskip("studio")
    shoot, raws = _finished_shoot(tmp_path, monkeypatch)
    if where == "icloud":
        assert archive.push(shoot, apply=True, form="packed") == 0
        shutil.rmtree(shoot / "packed")
    shutil.rmtree(shoot / "raw")                      # the RAWs let go, and the cache taken back
    made = _fake_imaging(monkeypatch)
    s = studio.Shoot(shoot)
    sha = {Path(n).stem: hashlib.sha256(b).hexdigest() for n, b in raws.items()}
    first = sorted(sha)[0]

    assert studio.Handler._raw(s, first) is None
    assert studio.Handler._previews_from_packed(s, first)
    burst = {p.stem for p in made}
    assert first in burst and len(burst) == 3, "the whole burst in one unpack, and only that burst"
    for stem in burst:
        for sub in ("previews", "thumbs", "large"):
            assert (shoot / "cull" / sub / f"{stem}.jpg").read_text() == sha[stem]
    assert (shoot / "cull" / "previews" / "CACHEDIR.TAG").exists(), "made here, so reclaimable again"
    n = len(made)
    assert studio.Handler._previews_from_packed(s, sorted(burst)[1]) and len(made) == n

    decoded = studio.Handler._decoded(s, first)
    assert decoded is not None and decoded.read_text() == sha[first]
    assert not (shoot / "raw").exists(), "the RAW is not put back into the shoot"
    assert studio.Handler._decoded(s, "TSC09999") is None
