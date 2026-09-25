"""One resolver for where a shoot's things are (library.paths), whatever the
layout and whichever folder a person points a command at.

    .venv/bin/python -m pytest tests/test_layout.py -q
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import library  # noqa: E402


def _standard(tmp_path: Path) -> Path:
    s = tmp_path / "2026-09-12-lounge"
    (s / "raw").mkdir(parents=True)
    (s / "cull").mkdir()
    (s / "cull" / "cull.csv").write_text("file\n")
    (s / "raw" / "TSC04015.ARW").write_bytes(b"r")
    return s


def _flat(tmp_path: Path, cull: str = "cull") -> Path:
    s = tmp_path / "ducksAndDeadlifts"
    (s / cull).mkdir(parents=True)
    (s / cull / "cull.csv").write_text("file\n")
    (s / "TSC05691.ARW").write_bytes(b"r")
    return s


@pytest.mark.parametrize("make", [_standard, _flat])
def test_every_folder_of_a_shoot_names_the_same_shoot(tmp_path, make):
    s = make(tmp_path)
    p = library.paths(s)
    for pointed in (s, p.raw, p.cull, p.raw / next(iter(sorted(p.raw.glob("*.ARW")))).name):
        assert library.paths(pointed) == p, pointed
    assert p.cull == s / "cull"
    assert p.raw == (s / "raw" if (s / "raw").is_dir() else s)



def test_the_cull_is_where_cull_csv_is_with_folders(tmp_path):
    s = _flat(tmp_path, "_cull")
    (s / "cull").mkdir()                                  # made empty by some other command
    assert library.paths(s).cull == s / "_cull"
    assert library.paths(s / "_cull").shoot == s
    empty = tmp_path / "new"
    (empty / "raw").mkdir(parents=True)
    assert library.paths(empty).cull == empty / "cull"


def test_a_frame_the_cull_named_by_its_jpeg_is_its_raw(tmp_path):
    s = _standard(tmp_path)
    assert library.frame_raw(s, "TSC04015.jpg") == s / "raw" / "TSC04015.ARW"
    assert library.sidecar_path(s / "raw", "TSC04015.jpg") == s / "raw" / "TSC04015.ARW.dop"
    assert library.sidecar_path(s, "TSC09999.jpg") is None      # no RAW here: no sidecar beside nothing


# ------------------------------------------------ the commands that read it


class _Stop(Exception):
    pass


def _cull_to(monkeypatch, capsys, pointed: Path) -> tuple[Path, str]:
    """Where `pl cull <pointed>` would write, and what it said it read.

    Stops the run at the first thing it makes, the previews cache inside its
    cull folder: past that point everything is decoding, and the question
    here is only which folders the command chose."""
    import cull
    made: list[Path] = []

    def cache_dir(p, **_k):
        made.append(Path(p))
        raise _Stop

    monkeypatch.setattr(library, "cache_dir", cache_dir)
    monkeypatch.setattr(cull, "read_metadata", lambda files: {})
    monkeypatch.setattr(cull, "FACE_MODEL", pointed / "no-such-model.onnx")
    monkeypatch.setattr(sys, "argv", ["cull.py", str(pointed), "--no-quality", "--no-subject"])
    with pytest.raises(_Stop):
        cull.main()
    return made[0].parent, capsys.readouterr().out


@pytest.mark.parametrize("pointed", ["", "raw", "cull"])
def test_the_cull_takes_any_folder_of_a_standard_shoot(tmp_path, monkeypatch, capsys, pointed):
    """`pl cull <shoot>` listed the shoot folder, found raw/ and cull/ and no
    frames, and stopped with "No images"; <shoot>/raw was the one spelling
    that worked. All three are the same shoot now."""
    s = _standard(tmp_path)
    out, said = _cull_to(monkeypatch, capsys, s / pointed if pointed else s)
    assert out == (s / "cull").resolve()
    assert "1 images in raw" in said


@pytest.mark.parametrize("cull_name, empty_cull, want", [
    (None, False, "cull"),         # never culled: cull/, and never a new _cull/
    ("cull", False, "cull"),
    ("_cull", False, "_cull"),     # the old fork's folder is still written to, not forked
    ("_cull", True, "_cull"),      # ... even beside an empty cull/ another command made
])
def test_the_cull_of_a_flat_shoot_goes_where_the_resolver_says(tmp_path, monkeypatch, capsys,
                                                               cull_name, empty_cull, want):
    if cull_name:
        s = _flat(tmp_path, cull_name)
    else:
        s = tmp_path / "ducksAndDeadlifts"
        s.mkdir()
        (s / "TSC05691.ARW").write_bytes(b"r")
    if empty_cull:
        (s / "cull").mkdir()
    out, said = _cull_to(monkeypatch, capsys, s)
    assert out == (s / want).resolve()
    assert f"1 images in {s.name}" in said
    assert cull_name == "_cull" or not (s / "_cull").exists()


def _studio(tmp_path, monkeypatch):
    import studio
    import taste
    monkeypatch.setattr(studio, "ROOT", tmp_path)
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    monkeypatch.setattr(taste, "EXPORTS", [])
    monkeypatch.setattr(taste, "_EXPORTED", None)
    return studio


def test_the_studio_reads_a_flat_shoot_where_every_command_does(tmp_path, monkeypatch):
    """The studio had a rule of its own that took _cull/ only while no cull/
    existed at all, so an empty cull/ beside a flat shoot's real _cull/
    turned it to the empty one."""
    studio = _studio(tmp_path, monkeypatch)
    s = _flat(tmp_path / "a")
    sh = studio.Shoot(s)
    assert (sh.folder, sh.raw, sh.cull, sh.export) == (s, s, s / "cull", s / "export")
    old = _flat(tmp_path / "b", "_cull")
    (old / "cull").mkdir()
    assert studio.Shoot(old).cull == old / "_cull"
    std = _standard(tmp_path / "c")
    info = studio.Shoot(std / "raw").info()
    assert (info["path"], info["raw"], info["export"]) == (str(std), str(std / "raw"), str(std / "export"))


def test_a_star_on_a_frame_the_cull_named_by_its_jpeg_reaches_the_raws_sidecar(tmp_path, monkeypatch):
    """cull.csv can name the camera JPEG it decoded. The star was written to
    raw/TSC04015.jpg.dop, which is never there and which PhotoLab would not
    open if it were, so the ARW's own sidecar kept the old rating."""
    studio = _studio(tmp_path, monkeypatch)
    s = _standard(tmp_path)
    (s / "cull" / "cull.csv").write_text("file,rating,reason,scene,burst\nTSC04015.jpg,3,,0,0\n")
    dop = s / "raw" / "TSC04015.ARW.dop"
    dop.write_text("{\n\tDxOPhotoLab = {\n\t\tRating = 2,\n\t},\n}\n")
    studio.Shoot(s).set_rating("TSC04015.jpg", 5)
    assert "Rating = 5," in dop.read_text()
    assert not (s / "raw" / "TSC04015.jpg.dop").exists()
    assert studio.Handler._raw(studio.Shoot(s), "TSC04015") == s / "raw" / "TSC04015.ARW"


def test_an_export_is_matched_to_a_frame_the_cull_named_by_its_jpeg(tmp_path, monkeypatch):
    """exports.frames paired each cull.csv row with raw/<its name>, and
    raw/TSC04015.jpg does not exist, so an iCloud export of that frame could
    never be held to its RAW's date and was never found."""
    import os

    import exports
    import taste
    s = _standard(tmp_path)
    (s / "cull" / "cull.csv").write_text("file,rating\nTSC04015.jpg,3\n")
    os.utime(s / "raw" / "TSC04015.ARW", (1_000_000, 1_000_000))
    cloud = tmp_path / "cloud"
    cloud.mkdir()
    there = cloud / "TSC04015_DxO.jpg"
    there.write_bytes(b"\xff\xd8\xff")
    os.utime(there, (2_000_000, 2_000_000))
    monkeypatch.setattr(taste, "EXPORTS", [cloud / "*_DxO.jpg"])
    assert exports.frames(s) == {"TSC04015": s / "raw" / "TSC04015.ARW"}
    assert exports.files(s) == {"TSC04015": there}
    assert exports.files(s / "cull") == {"TSC04015": there}


def test_gather_and_the_bench_read_the_cull_that_holds_cull_csv(tmp_path, monkeypatch):
    import bench
    import gather
    s = _flat(tmp_path, "_cull")
    (s / "cull").mkdir()
    assert gather.cull_of(s, s) == s / "_cull"
    (s / "_cull" / "selects.json").write_text("[]")
    seen: list = []
    real = bench.decision_path
    monkeypatch.setattr(bench, "decision_path", lambda cull, name: seen.append(cull) or real(cull, name))
    bench.run(s)
    assert seen and seen[0] == (s / "_cull").resolve()
