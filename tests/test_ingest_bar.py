"""The card copy's bar, weighted by what was asked of the copy.

    .venv/bin/python -m pytest tests/test_ingest_bar.py -q

With Don't Check there is no second stage, and a copy weighted 70 sat at 70%
and jumped to 100%. With the check at the end, the second pass reads every
byte on both sides again and counted for only 30%, so the time left ran short.
Nothing here touches a card or a library: the job is a sleep, and its log is
written by the test.
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import studio  # noqa: E402


def test_the_weights_come_from_the_command():
    assert studio.ingest_weights(["ingest.py", "/Volumes/CARD", "x", "--verify", "none"]) == {"copy": 100}
    assert studio.ingest_weights(["ingest.py", "--verify", "end"]) == {"copy": 50, "verify": 50}
    assert studio.ingest_weights(["ingest.py", "--verify", "in-flight"]) == studio.INGEST_WEIGHTS
    # ingest.py's own default, and anything it cannot read.
    assert studio.ingest_weights(["ingest.py"]) == studio.INGEST_WEIGHTS
    assert studio.ingest_weights(None) == studio.INGEST_WEIGHTS
    assert studio.ingest_weights(["ingest.py", "--verify"]) == studio.INGEST_WEIGHTS
    for w in studio.INGEST_WEIGHTS_BY_VERIFY.values():
        assert sum(w.values()) == 100


@pytest.mark.parametrize("verify, marks, expected", [
    ("none", "@@ copy 500 1000", 0.5),
    ("end", "@@ copy 1000 1000\n@@ verify 500 1000", 0.75),
    ("in-flight", "@@ copy 500 1000", 0.35),
])
def test_the_copy_bar_is_weighted_by_the_check_he_chose(tmp_path, verify, marks, expected):
    jobs = studio.Jobs(store=tmp_path / "queue.json")
    log = tmp_path / "ingest.log"
    assert jobs.start("ingest", "copying the card into x",
                      [sys.executable, "-c", "import time; time.sleep(5)", "--verify", verify],
                      log, shoot="x")
    try:
        log.write_text(f"$ ingest.py\n{marks}\n")
        assert jobs.status()["fraction"] == pytest.approx(expected)
    finally:
        jobs.clear()
        jobs.stop()
        for _ in range(100):
            if not jobs.status()["running"]:
                break
            time.sleep(0.05)
