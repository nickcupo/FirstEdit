"""What every storage script leans on common.py for: writing a decision
through its compatibility link, stopping when the studio says stop, running
per-frame work across processes, and where what the tool learns is kept.

    .venv/bin/python -m pytest tests/test_common_io.py -q

Nothing in here reads or writes a library; every fixture is under tmp_path.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

PIPELINE = Path(__file__).resolve().parents[1] / "pipeline"
sys.path.insert(0, str(PIPELINE))
import common  # noqa: E402


def test_a_decision_written_through_a_dangling_link_lands_where_the_link_points(tmp_path):
    """cull/organize.json is a link into decisions/ after a migration. With
    decisions/ gone, decision_path still hands out the link, and the write
    died in mkstemp: the star click was lost with a FileNotFoundError."""
    cull = tmp_path / "shoot" / "cull"
    cull.mkdir(parents=True)
    (cull / "organize.json").symlink_to(Path("..") / "decisions" / "organize.json")
    assert not (tmp_path / "shoot" / "decisions").exists()
    assert common.decision_path(cull, "organize.json") == cull / "organize.json"

    common.write_json_atomic(common.decision_path(cull, "organize.json"), {"photos": {}})
    assert (cull / "organize.json").is_symlink(), "the link was replaced by a file"
    assert (tmp_path / "shoot" / "decisions" / "organize.json").read_text().strip().startswith("{")


def test_an_ordinary_path_in_a_missing_folder_still_fails(tmp_path):
    """Only a link's folder is made. A plain path whose folder is not there is
    a caller's mistake, and minting folders for it is how a stray _cull/ was
    made once already."""
    with pytest.raises(FileNotFoundError):
        common.write_atomic(tmp_path / "nowhere" / "x.json", "{}")
    assert not (tmp_path / "nowhere").exists()


def test_a_stopped_write_leaves_no_temp_file_and_the_old_file_whole(tmp_path):
    """The studio's Stop is SIGTERM to the job's group. Python's default for
    it ends the process without running write_atomic's cleanup, so the temp
    file stayed beside the photographs. With the handler, the stop unwinds:
    the target keeps its old bytes, the temp file goes, and the exit status is
    still the conventional 143."""
    target = tmp_path / "organize.json"
    target.write_text('{"photos": {"A.ARW": {"rating": 4}}}\n')
    script = tmp_path / "stop.py"
    script.write_text(f"""
import os, signal, sys
sys.path.insert(0, {str(PIPELINE)!r})
import common
common.stop_cleanly_on_sigterm()
real = os.fsync
def fsync(fd):
    os.kill(os.getpid(), signal.SIGTERM)   # the studio pressing Stop mid-write
    real(fd)
os.fsync = fsync
common.write_atomic({str(target)!r}, "{{}}")
print("not reached")
""")
    r = subprocess.run([sys.executable, str(script)], capture_output=True, text=True, timeout=60)
    assert r.returncode == 143, (r.returncode, r.stdout, r.stderr)
    assert "not reached" not in r.stdout
    assert target.read_text().startswith('{"photos"'), "the old decision file was damaged"
    assert [p.name for p in tmp_path.iterdir() if p.name.endswith(".tmp")] == []


CALLS: list[int] = []


def _job(n: int) -> int:
    """Module level, so a spawned worker can find it."""
    CALLS.append(n)
    if n == 3:
        raise FileNotFoundError(f"frame {n} is not on this disk")
    return n * 10


def test_a_jobs_own_oserror_reaches_the_caller_and_is_not_run_again(capsys):
    """pool_map caught OSError around the whole run, and an OSError is what a
    job raises for a RAW that is not there. The pool then finished every
    queued job with its result thrown away, and the serial fallback ran them
    all again in this process and hit the same error."""
    CALLS.clear()
    with pytest.raises(FileNotFoundError):
        list(common.pool_map(_job, list(range(8)), workers=2, min_jobs=2))
    out = capsys.readouterr().out
    assert "one frame at a time" not in out, out
    assert CALLS == [], f"jobs were re-run in this process: {CALLS}"


def test_pool_map_still_answers_in_order():
    assert list(common.pool_map(_job, [0, 1, 2, 4, 5, 6, 7, 8], workers=2, min_jobs=2)) == \
        [0, 10, 20, 40, 50, 60, 70, 80]
    # And the handful that runs in this process is unchanged.
    CALLS.clear()
    assert list(common.pool_map(_job, [1, 2], workers=2)) == [10, 20]
    assert CALLS == [1, 2]


def test_stop_handler_is_harmless_off_the_main_thread():
    import threading
    err: list[BaseException] = []

    def run():
        try:
            common.stop_cleanly_on_sigterm()
        except BaseException as e:  # noqa: BLE001
            err.append(e)

    t = threading.Thread(target=run)
    t.start()
    t.join()
    assert err == []
    assert os.getpid() > 0


def test_what_the_tool_learns_has_one_writable_home(tmp_path, monkeypatch):
    """One folder, wherever the pipeline is run from: the env var if there is
    one, else the app's support folder, and never the repo or the bundle -
    both of which a checkout or an update replaces under it."""
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "told"))
    assert common.learned_dir() == tmp_path / "told"
    assert not (tmp_path / "told").exists(), "asking where it is made one"
    assert common.learned_dir(create=True).is_dir()

    monkeypatch.delenv("PIPELINE_LEARNED")
    monkeypatch.setenv("PIPELINE_SUPPORT", str(tmp_path / "support"))
    assert common.learned_dir() == tmp_path / "support" / "learned"

    # No environment: the app's own folder, found under a home that is
    # tmp_path, so the answer is worked out without looking at his.
    monkeypatch.delenv("PIPELINE_SUPPORT")
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    assert common.learned_dir() == tmp_path / "home" / "Library" / "Application Support" / "FirstEdit" / "learned"
    assert PIPELINE not in common.learned_dir().parents


def test_one_pool_serves_every_stage_of_a_run():
    """A cull span up a fresh spawn pool for the decodes, another for focus and
    another for the faces, and every worker of every one of them paid the
    import cost again (mediapipe 0.42 s cold, torch 0.57 s, on up to twelve
    processes three times over)."""
    common.close_pool()
    assert list(common.pool_map(_job, [0, 1, 2, 4], workers=2, min_jobs=2)) == [0, 10, 20, 40]
    first = common._POOL["ex"]
    assert first is not None
    assert list(common.pool_map(_job, [5, 6, 7, 8], workers=2, min_jobs=2)) == [50, 60, 70, 80]
    assert common._POOL["ex"] is first, "the second stage started a pool of its own"
    # A pool that broke, or one a caller walked away from, is never handed on.
    with pytest.raises(FileNotFoundError):
        list(common.pool_map(_job, list(range(8)), workers=2, min_jobs=2))
    assert common._POOL["ex"] is None
    common.close_pool()


def test_the_workers_are_counted_against_the_memory_as_well_as_the_cores(monkeypatch):
    """A worker holds its own detectors and a full-resolution frame, so on a
    small machine the cores are not the ceiling."""
    monkeypatch.setattr(common.os, "cpu_count", lambda: 16)
    monkeypatch.setattr(common.os, "sysconf", lambda k: {"SC_PHYS_PAGES": 8 * 1024 ** 3 // 4096,
                                                         "SC_PAGE_SIZE": 4096}[k])
    assert common.default_workers() == (8 * 1024 ** 3 - common.WORKER_RESERVE) // common.WORKER_BYTES
    monkeypatch.setattr(common.os, "sysconf", lambda k: {"SC_PHYS_PAGES": 48 * 1024 ** 3 // 4096,
                                                         "SC_PAGE_SIZE": 4096}[k])
    assert common.default_workers() == 12           # three quarters of the cores, with room to spare
