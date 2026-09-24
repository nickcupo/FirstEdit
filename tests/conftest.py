"""Nothing in the tests may touch what he has learned, or what he has exported.

The learned folder is a real folder in Application Support with his models in
it, the export index walks iCloud, the library is ~/photos, and an installed
extension lives in Application Support too. All of them are read from the
environment, so pointing them at a folder under the test session's own tmp
path here - before any pipeline module is imported, because each module reads
them once at import - is what makes a test run incapable of reading or writing
any of them. A test that wants its own library or learned folder still points
at one itself; this is the floor, not the fixture.

Set, not defaulted. A shell that exports PHOTOS_ROOT=~/photos for his own
./pl runs would otherwise hand the whole suite his real library, and the one
guarantee this file exists for would hold only on machines that happen not to
have it set.

The one exception is asked for by name: PIPELINE_TEST_HIS_LIBRARY=1 leaves
PHOTOS_ROOT as the shell has it, for
test_every_sidecar_on_this_machine_renders_for_every_editor, which exists to
read every sidecar of the real library and is deselected everywhere else. It
reads; nothing in it writes.

And checked. An audit hook watches every open, directory listing and glob for
the whole session and refuses any that reaches his real folders: a module that
builds a path from Path.home() instead of the environment is exactly the bug
this cannot see coming, and the refusal names it. Refused as it happens, so the
read never takes place, and counted as well, because a refusal inside a broad
`except` would otherwise pass as a missing file and the test would go green.
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

_SAFE = Path(tempfile.mkdtemp(prefix="photo-pipeline-tests-"))
_HIS_LIBRARY = os.environ.get("PIPELINE_TEST_HIS_LIBRARY") == "1"
for _k, _v in {"PHOTOS_ROOT": _SAFE / "photos", "PIPELINE_LEARNED": _SAFE / "learned",
               "PIPELINE_ICLOUD": _SAFE / "icloud", "PIPELINE_SUPPORT": _SAFE / "support",
               "PIPELINE_EXT": _SAFE / "no-extension", "PIPELINE_SITE": _SAFE / "no-site",
               "PIPELINE_EVAL_CACHE": _SAFE / "eval-cache"}.items():
    if not (_HIS_LIBRARY and _k == "PHOTOS_ROOT"):
        os.environ[_k] = str(_v)
(_SAFE / "icloud").mkdir(parents=True, exist_ok=True)
# A card copy and a cull refuse to start unless they would leave 20 GB free.
# The fixtures here are kilobytes, so that floor measured the disk the suite
# ran on and not the code: with less than 20 GB free - a CI runner, or this
# Mac on a full day - every test that copies a card failed. The steps the
# studio starts inherit this too.
os.environ["PIPELINE_SPACE_RESERVE"] = "0"

_HOME = Path(os.path.expanduser("~")).resolve()
# His library, his learned models and his extension, and his iCloud Drive.
# The support folder under both of its names: the app renames the old one and
# leaves a link there, and abspath does not follow links, so a read through
# either name is caught.
_PRIVATE = tuple(str(p) for p in ([] if _HIS_LIBRARY else [_HOME / "photos"]) + [
    _HOME / "Library" / "Application Support" / "First Edit",
    _HOME / "Library" / "Application Support" / "Photo Pipeline",
    _HOME / "Library" / "Mobile Documents"])
_REACHED: list[str] = []


def _private(path) -> str | None:
    if isinstance(path, int) or path is None:
        return None
    try:
        p = os.path.abspath(os.fsdecode(path))
    except (TypeError, ValueError):
        return None
    for top in _PRIVATE:
        if p == top or p.startswith(top + os.sep):
            return p
    return None


def _watch(event: str, args: tuple) -> None:
    if event not in ("open", "os.listdir", "os.scandir", "glob.glob", "os.mkdir", "os.remove",
                     "os.rename", "shutil.rmtree", "os.symlink", "os.link"):
        return
    if not args:
        return
    hit = _private(args[0])
    if hit is not None:
        _REACHED.append(f"{event} {hit}")
        raise PermissionError(f"a test reached {hit}, which is his; point it at a tmp folder")


sys.addaudithook(_watch)


def pytest_sessionfinish(session, exitstatus):
    if _REACHED:
        print("\nthe suite reached his real folders:\n  " + "\n  ".join(sorted(set(_REACHED))), file=sys.stderr)
        session.exitstatus = 1
