#!/usr/bin/env python3
"""
check_faces.py - did a change to the face judge break anything we settled by eye?

Runs faces.py over a folder of decoded frames (the half-size JPEGs the cull
caches, no RAWs needed) and compares each verdict with tests/faces_truth.json:
frames that must pass, frames that must be rejected and for what, frames
where there is no human face to find. Thirty seconds. Run it before trusting
a new threshold on a shoot.

    ./pl check                        # uses the folder named in the truth file
    ./pl check ~/somewhere            # another folder of decoded JPEGs
    ./pl check tests/pets_truth.json  # another truth file; the pets one ships in the repo
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import cv2

sys.path.insert(0, str(Path(__file__).resolve().parent))
TRUTH = Path(__file__).resolve().parent.parent / "tests" / "faces_truth.json"
PHOTOS = Path(os.environ.get("PHOTOS_ROOT", Path.home() / "photos")).expanduser()


def fixture_folder(truth_path: Path, truth: dict, arg: str | None) -> Path:
    """Where the frames this truth file is about live.

    A folder named in the truth file as "~/photos/fixtures/faces" is a folder
    inside the library, and the library is wherever PHOTOS_ROOT says it is.
    Resolving it with expanduser alone sent every run at the real library,
    including the runs on a scratch clone that were meant to prove a change
    was safe: the 94 of 94 in the report was measured on his own photographs
    whatever PHOTOS_ROOT was set to. A relative folder is relative to the
    repo, which is where the pet fixtures live."""
    named = arg if arg and not arg.endswith(".json") else truth["folder"]
    p = Path(named)
    home = str(Path("~/photos").expanduser())
    if str(p).startswith("~/photos/") or str(p.expanduser()).startswith(home + "/"):
        return PHOTOS / str(p.expanduser())[len(home) + 1:]
    p = p.expanduser()
    return p if p.is_absolute() else truth_path.resolve().parent.parent / p


def main() -> int:
    arg = sys.argv[1] if len(sys.argv) > 1 else None
    truth_path = Path(arg) if arg and arg.endswith(".json") else TRUTH
    truth = json.loads(truth_path.read_text())
    folder = fixture_folder(truth_path, truth, arg)
    from faces import FaceJudge
    import faces as fmod
    from quality import Quality
    judge = FaceJudge(quality=Quality())
    floor = float(truth.get("sharp_floor", 1.9))
    bad = 0
    for stem, want in truth["frames"].items():
        p = folder / f"{stem}.jpg"
        img = cv2.imread(str(p))
        if img is None:
            print(f"  {stem}: missing from {folder}")
            bad += 1
            continue
        render = cv2.imread(str(folder / f"{stem}.preview.jpg"))   # the camera JPEG; exposure is read off it
        fs = judge.detect(img)
        judge.judge(img, fs, render=render)
        for f in fs:
            judge.flag(f, floor)
        fs = [f for f in fs if "not a face" not in f.flags]
        big = [f for f in fs if f.main]
        fmod.kiss(big)          # the one copy of the rule, in faces.py
        mains = [f for f in big if "face away" not in f.flags]
        hard, flags = fmod.verdict(mains)
        got = "no-face" if not mains else ("reject" if hard else "pass")
        ok = got == want["verdict"] and (not want.get("flag") or want["flag"] in hard)
        mark = "ok " if ok else "XX "
        if not ok:
            bad += 1
        print(f"  {mark}{stem}: want {want['verdict']}{' (' + want['flag'] + ')' if want.get('flag') else ''}, got {got}"
              + (f" [{', '.join(flags)}]" if flags else "") + (f"  · {want['note']}" if want.get("note") and not ok else ""))
    print(f"\n  {len(truth['frames']) - bad} of {len(truth['frames'])} as expected")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
