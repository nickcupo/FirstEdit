"""The answer key is found in decisions/, with no symlink to help.

    .venv/bin/python -m pytest tests/test_decisions.py -q

selects.json is one of the handful of files in a shoot that no machine can
rebuild, and it moved out of cull/ -- which Finder reports as 16 GB and which
is named like a cache -- into <shoot>/decisions/. `pl migrate` leaves a
symlink behind at the old name so nothing breaks the day it runs. These
readers still asked for the old name directly and so were living on that
symlink, and the first of them is the expensive one: it is not a file it
would lose if the link went, it is a whole shoot dropping out of every
measurement in tests/eval.md, silently, with each remaining number still
looking exactly as right as before.

The fixture below has decisions/ and NO symlink, which is the state the
symlinks are meant to be a courtesy to and not a crutch for.
"""
from __future__ import annotations

import csv
import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import evaluate  # noqa: E402
import presets  # noqa: E402
import taste  # noqa: E402

RANK_COLS = ["file", "burst", "shot_at", "rating", "face_score", "gaze", "aesthetic", "quality",
             "subj_area", "thirds", "mean_luma", "sharp_rel", "focus", "action", "faces",
             "eyes_open", "smile", "lead_read", "lead_frac"]


def _shoot(root: Path, name: str, kept: list[str] | None) -> Path:
    shoot = root / "shoots" / name
    (shoot / "cull").mkdir(parents=True)
    if kept is None:
        return shoot
    (shoot / "decisions").mkdir()
    (shoot / "decisions" / "selects.json").write_text(json.dumps(kept))
    assert not (shoot / "cull" / "selects.json").is_symlink()
    assert not (shoot / "cull" / "selects.json").exists()
    return shoot


def test_a_shoot_is_enumerated_and_read_through_decisions(tmp_path, monkeypatch):
    kept = [f"TSC{i:05d}.ARW" for i in range(0, 200, 2)]
    shoot = _shoot(tmp_path, "2026-09-16", kept)
    _shoot(tmp_path, "ducksAndDeadlifts", None)          # a real shoot with no answer key at all
    monkeypatch.setattr(evaluate, "PHOTOS", tmp_path)

    assert [p.name for p in evaluate.shoots()] == ["2026-09-16"]
    assert json.loads(evaluate.decision_path(shoot / "cull", "selects.json").read_text()) == kept
    ducks = tmp_path / "shoots" / "ducksAndDeadlifts"
    assert not evaluate.decision_path(ducks / "cull", "selects.json").exists()


def test_the_ranker_learns_from_the_key_where_it_now_lives(tmp_path):
    kept = [f"TSC{i:05d}.ARW" for i in range(0, 200, 2)]
    shoot = _shoot(tmp_path, "2026-09-16", kept)
    rng = random.Random(0)
    with (shoot / "cull" / "cull.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, RANK_COLS)
        w.writeheader()
        for i in range(200):
            name = f"TSC{i:05d}.ARW"
            face = (0.8 if name in kept else 0.2) if rng.random() > 0.15 else 0.5
            w.writerow({"file": name, "burst": f"b{i // 4}", "shot_at": f"{i:04d}", "rating": "3",
                        "face_score": face, "gaze": 0.3, "aesthetic": 0.5, "quality": 0.5,
                        "subj_area": 0.2, "thirds": 0.5, "mean_luma": 90, "sharp_rel": 1.0,
                        "focus": 3.0, "action": 0.2, "faces": 1, "eyes_open": 0.9, "smile": 0.3,
                        "lead_read": 0.5, "lead_frac": 0.5})
    r = taste.learn_ranker(shoot)
    assert r is not None and r["n"] == 200 and r["n_kept"] == 100


def test_his_stars_and_the_copy_record_are_found_too(tmp_path):
    """The other two decision files these modules read. Neither read fails
    loudly when it finds nothing: a missing organize.json writes every
    sidecar to the machine's verdict instead of his, and a missing
    spread.json reads a burst of copied sidecars as a burst of decisions and
    lets the venue converge on whichever frame was the source."""
    shoot = _shoot(tmp_path, "2026-09-16", [])
    (shoot / "cull" / "cull.csv").write_text("file,rating\nTSC00001.ARW,0\nTSC00002.ARW,3\n")
    (shoot / "decisions" / "organize.json").write_text(json.dumps({"photos": {"TSC00001.ARW": {"rating": 5}}}))
    (shoot / "decisions" / "spread.json").write_text(json.dumps({"b1": {"written": ["TSC00002.ARW"]}}))
    assert not (shoot / "cull" / "organize.json").exists()
    assert not (shoot / "cull" / "spread.json").exists()

    assert [r["rating"] for r in presets.load_rows(shoot / "cull" / "cull.csv")] == ["5", "3"]
    taste._SPREAD.pop(str(shoot), None)
    assert taste.spread_written(shoot) == {"TSC00002.ARW"}
