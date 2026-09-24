"""Which file is a frame's finished photograph (pipeline/exports.py).

    .venv/bin/python -m pytest tests/test_exports.py -q

The Instagram copies are cut from it and the extension publishes it, so a
frame exported twice - the still in export/ and again for a reel - must give
the still, whichever was written last.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import exports  # noqa: E402
import taste  # noqa: E402


def _jpg(p: Path, when: float) -> Path:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(b"\xff\xd8\xff")
    os.utime(p, (when, when))
    return p


def _shoot(root: Path, stems) -> Path:
    shoot = root / "shoots" / "2026-02-02-day"
    (shoot / "raw").mkdir(parents=True)
    (shoot / "cull").mkdir()
    (shoot / "cull" / "cull.csv").write_text("file,rating\n" + "".join(f"{s}.ARW,3\n" for s in stems))
    for s in stems:
        _jpg(shoot / "raw" / f"{s}.ARW", 1_000_000)
    return shoot


def test_the_still_wins_over_a_newer_reel_or_upload_export(tmp_path, monkeypatch):
    monkeypatch.setattr(taste, "EXPORTS", [])
    shoot = _shoot(tmp_path, ["A1", "A2", "A3"])
    still = _jpg(shoot / "export" / "A1_DxO.jpg", 2_000_000)
    _jpg(shoot / "reels" / "b" / "A1_DxO.jpg", 3_000_000)
    _jpg(shoot / "upload" / "A1_DxO.jpg", 3_000_001)
    edit = _jpg(shoot / "edit" / "done" / "A2_DxO.jpg", 2_000_000)
    _jpg(shoot / "reels" / "b" / "A2_DxO.jpg", 3_000_000)
    only = _jpg(shoot / "reels" / "b" / "A3_DxO.jpg", 3_000_000)
    got = exports.files(shoot)
    assert got == {"A1": still, "A2": edit, "A3": only}


def test_within_export_and_edit_the_newest_wins(tmp_path, monkeypatch):
    monkeypatch.setattr(taste, "EXPORTS", [])
    shoot = _shoot(tmp_path, ["A1"])
    _jpg(shoot / "export" / "A1_DxO.jpg", 2_000_000)
    newer = _jpg(shoot / "edit" / "A1_DxO.jpg", 2_500_000)
    assert exports.files(shoot) == {"A1": newer}


def test_icloud_comes_before_a_reel_export_and_is_not_walked_when_not_needed(tmp_path, monkeypatch):
    cloud = tmp_path / "cloud"
    monkeypatch.setattr(taste, "EXPORTS", [cloud / "*_DxO.jpg"])
    shoot = _shoot(tmp_path, ["A1", "A2"])
    _jpg(shoot / "export" / "A1_DxO.jpg", 2_000_000)
    _jpg(shoot / "reels" / "b" / "A2_DxO.jpg", 3_000_000)
    there = _jpg(cloud / "A2_DxO.jpg", 2_000_000)
    assert exports.files(shoot, {"A1", "A2"}) == {"A1": shoot / "export" / "A1_DxO.jpg", "A2": there}
    # Every frame asked for is in export/: iCloud is never looked at.
    walked: list = []
    real = exports.glob.glob
    monkeypatch.setattr(exports.glob, "glob", lambda *a, **k: walked.append(a) or real(*a, **k))
    assert exports.files(shoot, {"A1"}) == {"A1": shoot / "export" / "A1_DxO.jpg"}
    assert walked == []
