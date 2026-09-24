"""The measuring tools, held to the same standards as the cull.

    .venv/bin/python -m pytest tests/test_harness.py -q

A harness that reads the wrong library, restates a threshold the tool no
longer uses, counts a name on a disk as a photograph, or prints p = 0.000
off 200 shuffles is worse than no harness: every number it produces still
looks right. Each test here stands for one of those, found in the audit.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import archive  # noqa: E402
import bench  # noqa: E402
import cull  # noqa: E402
import evaluate  # noqa: E402
import selftest  # noqa: E402


def test_the_harness_judges_against_the_culls_own_lines():
    """Four thresholds were restated here as literals. A line with two homes
    drifts, and then the report is about a tool nobody is running."""
    assert (evaluate.DARK_FLOOR, evaluate.BURST_FLOOR, evaluate.BURST_GAP, evaluate.CLIP_HI_FLOOR) == \
           (cull.DARK_FLOOR, cull.BURST_FLOOR, cull.BURST_GAP, cull.CLIP_HI_FLOOR)


def test_the_measurement_cache_belongs_to_one_library(tmp_path, monkeypatch):
    """Keyed by the shoot's name alone, a scratch clone and the real library
    shared a cache file: a run made to prove a change was safe could be
    answered out of measurements of his own photographs."""
    monkeypatch.setattr(evaluate, "PHOTOS", tmp_path / "photos")
    monkeypatch.setattr(evaluate, "CACHE", tmp_path / "cache")
    (tmp_path / "photos" / "shoots" / "2026-09-16").mkdir(parents=True)
    key = evaluate._cache_key(tmp_path / "photos" / "shoots" / "2026-09-16")
    assert key == "shoots_2026-09-16"
    evaluate._cache_save(key, "fp1", {"TSC1": {"stamp": "x"}})
    assert evaluate._cache_load(key, "fp1") == {"TSC1": {"stamp": "x"}}
    assert evaluate._cache_load(key, "fp2") == {}, "a change to the measuring code re-reads the frames"
    # the same shoot name under another library does not answer for this one
    other = tmp_path / "clone"
    (other / "shoots" / "2026-09-16").mkdir(parents=True)
    monkeypatch.setattr(evaluate, "PHOTOS", other)
    assert evaluate._cache_load(evaluate._cache_key(other / "shoots" / "2026-09-16"), "fp1") == {}


def test_a_path_in_the_report_carries_no_home_folder(tmp_path, monkeypatch):
    monkeypatch.setattr(evaluate, "PHOTOS", tmp_path)
    assert evaluate._said(tmp_path / "datasets" / "cew") == "$PHOTOS_ROOT/datasets/cew"
    assert evaluate._said(Path("/somewhere/else")) == "/somewhere/else"


def test_a_permutation_p_cannot_be_zero():
    """200 shuffles can say p is under 1 in 201 and cannot say it is 0."""
    score = np.arange(40, dtype=float)
    burst = np.repeat(np.arange(8), 5)
    keep = np.zeros(40, bool)
    keep[4::5] = True                 # the best frame of every burst: nothing can beat it
    assert evaluate.within_burst(score, keep, burst)[0] == 1.0
    nm, p = evaluate.permute(evaluate.within_burst, score, keep, burst, rounds=20, seed=1)
    assert p == 1 / 21 and 0.3 < nm < 0.7
    assert evaluate.pct_p(p, 20) == "<0.048"
    assert evaluate.pct_p(0.5, 20) == "0.500"
    assert evaluate.pct_p(float("nan"), 20) == "n/a"


def _shoot_with_a_hold(tmp_path) -> Path:
    shoot = tmp_path / "shoots" / "2026-09-16"
    (shoot / "raw").mkdir(parents=True)
    (shoot / "cull").mkdir()
    (shoot / "decisions").mkdir()
    for i in range(4):
        (shoot / "raw" / f"TSC{i:05d}.ARW").write_bytes(b"raw")
    (shoot / "decisions" / "selects.json").write_text(json.dumps([f"TSC{i:05d}.ARW" for i in range(4)]))
    (shoot / "cull" / "cull.csv").write_text("file,rating\nbench,0\n")
    (shoot / "cull" / "cull.bench-hold.csv").write_text("file,rating\nhis,5\n")
    return shoot


def test_an_interrupted_bench_gives_his_cull_csv_back(tmp_path, monkeypatch):
    """The hold file is written before the bench overwrites his cull.csv. It
    was never read back, so a bench killed at the wrong moment left its own
    run as the file the studio reads, and the next bench wrote over the only
    copy of his."""
    shoot = _shoot_with_a_hold(tmp_path)
    monkeypatch.setattr(bench.subprocess, "run", lambda *a, **k: subprocess.CompletedProcess(a, 0, "", ""))
    bench.run(shoot)
    assert (shoot / "cull" / "cull.csv").read_text() == "file,rating\nhis,5\n"
    assert not (shoot / "cull" / "cull.bench-hold.csv").exists()


def test_the_bench_looks_where_the_rest_of_the_pipeline_looks(tmp_path):
    """A flat shoot's cull folder is <shoot>/cull. bench.py called it _cull,
    the name that produced a stray folder beside the dog shoot."""
    flat = tmp_path / "ducksAndDeadlifts"
    flat.mkdir()
    raw, cull = archive.parts(flat)
    assert raw == flat.resolve() and cull == (flat / "cull").resolve()


def test_a_name_on_the_disk_is_not_a_photograph(tmp_path, monkeypatch):
    """An archived RAW leaves its name behind with no bytes. Seeding the
    self-test from those names decoded files that are not there, or pulled
    them back over the network at the moment the point was to prove the
    machine works without one."""
    root = tmp_path / "photos"
    fix = root / "fixtures" / "selftest" / "raw"
    fix.mkdir(parents=True)
    hollow = fix / "TSC00001.ARW"
    with hollow.open("wb") as fh:
        fh.truncate(1 << 20)          # a name, a size, and no blocks behind it
    if hollow.stat().st_blocks:
        import pytest
        pytest.skip("this filesystem allocates blocks for a sparse file")
    assert archive.local(hollow) is False
    monkeypatch.setattr(selftest, "ROOT", root)
    monkeypatch.setattr(selftest, "FIX", fix)
    assert selftest.seed() is False, "a folder of hollow names is not a seeded fixture"
    (fix / "TSC00002.ARW").write_bytes(b"raw bytes")
    assert selftest.seed() is True


def test_the_measurement_cache_moved_to_the_new_name_and_an_old_one_is_still_read(tmp_path, monkeypatch):
    """A cache is time, not data: nothing is moved. A run before the rename
    left ~/.cache/photo-pipeline/evaluate, and that one is read where it is
    until a cache under the new name exists. Under a home that is tmp_path."""
    monkeypatch.delenv("PIPELINE_EVAL_CACHE", raising=False)
    monkeypatch.setenv("HOME", str(tmp_path))
    new, old = tmp_path / ".cache/first-edit/evaluate", tmp_path / ".cache/photo-pipeline/evaluate"
    assert evaluate.eval_cache() == new
    old.mkdir(parents=True)
    assert evaluate.eval_cache() == old
    new.mkdir(parents=True)
    assert evaluate.eval_cache() == new
    monkeypatch.setenv("PIPELINE_EVAL_CACHE", str(tmp_path / "told"))
    assert evaluate.eval_cache() == tmp_path / "told"
