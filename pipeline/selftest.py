#!/usr/bin/env python3
"""
selftest.py - prove the whole machine still runs, in a minute, without a card.

    ./pl selftest

Takes six RAWs of yours - copied, the first time it runs, from the first
shoot it finds with six whose bytes are actually on the disk - culls them
into a scratch folder with presets and sidecars, and checks that everything
that should exist does: cull.csv with every frame, previews and
full-resolution decodes, at least one preset, a sidecar per frame,
presets.json. Run it the night before an event.

Its six frames are kept in the pipeline's own support folder, not in the
library: a tool that leaves its scratch files among somebody's shoots is one
he has to tidy up after. So it needs a library with photographs in it, and on
a machine that has none it says so and stops rather than half-running.
"""

from __future__ import annotations

import csv
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import archive  # noqa: E402
from common import RAW_EXTS, support_dir  # noqa: E402  - the formats this pipeline takes
ROOT = Path(os.environ.get("PHOTOS_ROOT", Path.home() / "photos")).expanduser()
FIX = support_dir() / "selftest" / "raw"


def seed() -> bool:
    """Six RAWs whose bytes are here.

    By bytes and not by name: an archived RAW keeps its name on the disk with
    nothing behind it, and a self-test seeded from those names decoded six
    files that were not there - or pulled them back over the network at the
    moment the point was to prove the machine works without one."""
    if FIX.is_dir() and any(p.suffix.lower() in RAW_EXTS and archive.local(p) for p in FIX.iterdir()):
        return True
    if not (ROOT / "shoots").is_dir():
        print(f"  no library at {ROOT}: the self-test culls six frames of yours, so it needs a shoot to take "
              f"them from. Point PHOTOS_ROOT at a library, or ingest a card first.")
        return False
    for shoot in sorted((ROOT / "shoots").glob("*/raw")):
        names = [p for p in sorted(shoot.iterdir()) if p.suffix.lower() in RAW_EXTS]
        raws = [p for p in names if archive.local(p)]
        if names and not raws:
            print(f"  {shoot.parent.name}: {len(names)} RAWs, all archived; nothing to seed from here")
        if len(raws) >= 6:
            FIX.mkdir(parents=True, exist_ok=True)
            for p in raws[:6]:
                shutil.copy2(p, FIX / p.name)
            print(f"  seeded {FIX} with six frames from {shoot.parent.name}")
            return True
    return False



def main() -> int:
    if not seed():
        print("  no shoot with six RAWs to seed the self-test from")
        return 1
    t0 = time.time()
    with tempfile.TemporaryDirectory() as tmp:
        raw = Path(tmp) / "raw"
        shutil.copytree(FIX, raw)
        for side in raw.glob("*.dop"):
            side.unlink()
        out = Path(tmp) / "cull"
        cmd = [sys.executable, str(HERE / "cull.py"), str(raw), "--out", str(out), "--keep-previews", "--copy", "--presets", "--dop", "--no-install"]
        r = subprocess.run(cmd, capture_output=True, text=True)
        log = (r.stdout + r.stderr)
        n = sum(1 for p in raw.iterdir() if p.suffix.lower() in RAW_EXTS)
        checks = []
        rows = list(csv.DictReader((out / "cull.csv").open())) if (out / "cull.csv").exists() else []
        checks.append(("cull.csv has every frame", len(rows) == n))
        checks.append(("previews", (out / "previews").is_dir() and sum(1 for _ in (out / "previews").glob("*.jpg")) == n))
        decs = list((out / "decoded").glob("*.jpg")) if (out / "decoded").is_dir() else []
        big = False
        if decs:
            import cv2
            im = cv2.imread(str(decs[0]))
            big = im is not None and im.shape[1] >= 4000
        checks.append(("full-resolution decodes", len(decs) == n and big))
        checks.append(("a preset", (out / "presets").is_dir() and any((out / "presets").glob("*.preset"))))
        checks.append(("presets.json for the app", (out / "presets.json").exists()))
        checks.append(("a sidecar per frame", sum(1 for _ in raw.glob("*.dop")) == n))
        checks.append(("picks copied", (out / "picks").is_dir() and any((out / "picks").iterdir())))
        checks.append(("the cull exited cleanly", r.returncode == 0 and "Traceback" not in log))
        checks.append(("the buttons and the scripts behind them agree", buttons_agree()))
        bad = [c for c, ok in checks if not ok]
        for c, ok in checks:
            print(f"  {'ok ' if ok else 'XX '}{c}")
        print(f"\n  {len(checks) - len(bad)} of {len(checks)} in {time.time() - t0:.0f} s")
        if bad:
            print("\n" + "\n".join(l for l in log.splitlines() if "WARN" not in l and "HF_TOKEN" not in l)[-3000:])
        return 1 if bad else 0


def buttons_agree() -> bool:
    """Every flag the studio passes is a flag the script actually takes.

    This exists because of one afternoon. The page's button said "Standardise
    the whole burst & open in PhotoLab"; the endpoint behind it passed neither
    --standard nor --open, and the spread.py in the shipped bundle had no such
    flags to pass. Three copies of the same feature, none of them agreeing,
    and the only symptom was a button that did nothing at all -- no error, no
    log line, nothing to search for.

    Nothing here runs a job. It reads the command lists out of studio.py and
    asks each script's own --help whether it knows those flags. A build that
    ships a studio newer than its scripts, or older, fails here and says so.
    """
    import re
    src = (HERE / "studio.py").read_text()
    seen = 0
    for script, flags in re.findall(r'str\(HERE / "(\w+\.py)"\)(.*?)\]', src, re.S):
        want = set(re.findall(r'"(--[a-z-]+)"', flags))
        if not want or not (HERE / script).exists():
            continue
        help_text = subprocess.run([sys.executable, str(HERE / script), "--help"],
                                   capture_output=True, text=True).stdout
        missing = sorted(f for f in want if f not in help_text)
        if missing:
            print(f"  studio.py passes {' '.join(missing)} to {script}, which does not take "
                  f"{'them' if len(missing) > 1 else 'it'}")
            return False
        seen += 1
    return seen > 0


if __name__ == "__main__":
    sys.exit(main())
