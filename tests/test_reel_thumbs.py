"""The reel grid's pictures: thirteen tiles are one walk of the export
folders, not thirteen."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import studio  # noqa: E402


class _Lister:
    def __init__(self) -> None:
        self.walks = 0

    def exports(self, folder, src):
        self.walks += 1
        return {"TSC00001": Path(folder) / "export" / "TSC00001.jpg"}


def test_a_grid_of_tiles_walks_the_exports_once(monkeypatch, tmp_path):
    clock = [100.0]
    monkeypatch.setattr(studio.time, "monotonic", lambda: clock[0])
    monkeypatch.setattr(studio, "_EXPORTS", {})
    mod = _Lister()
    for _ in range(13):
        assert "TSC00001" in studio._reel_exports(mod, tmp_path, None)
    assert mod.walks == 1
    # Another folder he pointed it at is its own walk.
    studio._reel_exports(mod, tmp_path, tmp_path / "export")
    assert mod.walks == 2
    # A few seconds on, an export made meanwhile is seen.
    clock[0] += studio._EXPORTS_FOR + 0.1
    studio._reel_exports(mod, tmp_path, None)
    assert mod.walks == 3


def test_a_frame_the_lister_just_called_exported_is_walked_for(monkeypatch, tmp_path):
    clock = [100.0]
    monkeypatch.setattr(studio.time, "monotonic", lambda: clock[0])
    monkeypatch.setattr(studio, "_EXPORTS", {})
    monkeypatch.setattr(studio, "_EXPORTS_SINCE", [0.0])
    mod = _Lister()
    studio._reel_exports(mod, tmp_path, None)          # a tile, before the export
    clock[0] += 1.0
    # The lister answers (its own walk sees the new export) and the page asks
    # for that frame's picture a moment later, well inside the 5 s.
    (tmp_path / "reel.py").write_text('print("{}")\n')  # a lister with nothing to list
    monkeypatch.setattr(studio, "HERE", tmp_path)
    assert "error" not in studio.reel_options(_Shoot(tmp_path))
    clock[0] += 0.5
    studio._reel_exports(mod, tmp_path, None)
    assert mod.walks == 2
    # The tiles after it share that walk.
    studio._reel_exports(mod, tmp_path, None)
    assert mod.walks == 2


class _Shoot:
    def __init__(self, folder: Path) -> None:
        self.folder = folder

    def reels(self) -> list:
        return []
