#!/usr/bin/env python3
"""
bench.py - the cull against every shoot the photographer has already chosen from.

    ./pl bench                 # every shoot under ~/photos/shoots with cull/selects.json
    ./pl bench 2026-10-04-lake

A shoot's `cull/selects.json` is the list of frames the photographer kept
(exported, edited, put on the site). For each such shoot this runs the
cull with --eval and collects the numbers that matter, and two that are
honest context:

  shown     how many of the chosen frames the cull would put in front of
            the photographer. The one that must be all of them: a keeper
            the cull hides is the worst thing it can do, and hiding is not
            only a veto - a cull.csv from before stacks hid frames for
            looking like another, and those count here as lost.
  under     keepers sitting under the top of a stack of look-alike frames.
            Shown, one key away, and reported apart because a stack top is
            the cull's guess and not its verdict.
  in top N  how many landed in the cull's own pick set (N = 30, or the
            number chosen if larger), against what chance would give.
  P@k       precision of the ranking alone, at k = the number chosen.

Writes tests/bench.md so the numbers travel with the code.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import archive  # noqa: E402
from common import decision_path, write_atomic  # noqa: E402
ROOT = Path(os.environ.get("PHOTOS_ROOT", Path.home() / "photos")).expanduser()
OUT = HERE.parent / "tests" / "bench.md"


def run(shoot: Path) -> dict | None:
    # The one canonical answer to "where are this shoot's RAWs and its cull
    # folder", for both layouts. This file had its own copy, and its copy
    # called a flat shoot's folder _cull, which is the name nothing else in
    # the pipeline reads.
    raw, cull = archive.parts(shoot)
    sel = decision_path(cull, "selects.json")
    if not sel.exists():
        return None
    chosen = json.loads(sel.read_text())
    n = len(chosen)
    # By bytes, not by name. An archived RAW leaves its name on the disk with
    # nothing behind it, so counting names said the shoot could be benched
    # off RAWs that are not here, and the cull then read every one of them
    # back over the network, or failed.
    present = sum(1 for c in chosen if archive.local(raw / c))
    named = sum(1 for c in chosen if (raw / c).exists())
    src, extra = raw, []
    if present < max(1, n // 2):
        # The RAWs were cleared. If the cull kept every chosen frame's decode
        # and the camera previews, the shoot can still be benched from those.
        # Its own cull.csv gives those frames their capture time back, so the
        # bench does not score the action shoot's 1,157 frames as 1,157
        # bursts of one - it has 89 - and call every rule that needs a burst
        # dead because it could not fire.
        dec, prev = cull / "decoded", cull / "previews"
        stems = {Path(c).stem for c in chosen}
        if dec.is_dir() and prev.is_dir() and all((dec / f"{st}.jpg").exists() for st in stems):
            src, extra = dec, ["--previews", str(prev)]
            if named > present:
                print(f"  {shoot.name}: {named - present} of the {n} chosen RAWs are named on disk but archived")
            print(f"  {shoot.name}: RAWs cleared; benching from the cached decodes and camera previews")
        else:
            print(f"  {shoot.name}: {present} of the {n} chosen frames are still on disk; skipped (the RAWs were cleared)")
            return None
    top = max(30, n)
    # The shoot's own settings, or the bench scores an action shoot under the
    # stills profile and rewrites the focus the photographer chose into shoot.json.
    try:
        meta = json.loads((shoot / "shoot.json").read_text())
    except Exception:  # noqa: BLE001
        meta = {}
    style = meta.get("style") if meta.get("style") in ("normal", "action") else "normal"
    focus = float(meta.get("focus") or 1.9)
    cmd = [sys.executable, str(HERE / "cull.py"), str(src), "--out", str(cull), "--keep-previews", "--top", str(top), "--eval", str(sel),
           "--style", style, "--face-floor", f"{focus:.2f}", *extra]
    # This runs the cull in place, over the shoot's real cull folder, because
    # the decodes and previews it needs are there. cull.csv is what the studio
    # and gather read, so the one the photographer is working from is put back afterwards
    # and the bench's own copy is kept beside it.
    import time
    import shutil
    keep_csv = cull / "cull.csv"
    # The photographer's cull.csv is put on disk before the bench is allowed to
    # overwrite it, not held in this process's memory. A kill between the two
    # used to leave the bench's own run as the file the studio and gather read,
    # with the only copy of his in a variable that no longer existed.
    hold = cull / "cull.bench-hold.csv"
    # A hold left behind is a bench that was killed between overwriting his
    # cull.csv and putting it back. Nothing read it, and the next run's own
    # hold wrote over the only copy of his file. It is restored first now,
    # before anything here writes.
    if hold.exists():
        write_atomic(keep_csv, hold.read_bytes())
        hold.unlink(missing_ok=True)
        print(f"  {shoot.name}: a previous bench was interrupted; your cull.csv has been put back")
    saved = keep_csv.read_bytes() if keep_csv.exists() else None
    if saved is not None:
        write_atomic(hold, saved)
    if src is not raw and saved is not None:
        cmd += ["--times", str(hold)]
    t0 = time.time()
    try:
        out = subprocess.run(cmd, capture_output=True, text=True).stdout
    finally:
        if saved is not None and keep_csv.exists():
            shutil.copyfile(keep_csv, cull / "bench.csv")
            write_atomic(keep_csv, saved)
            hold.unlink(missing_ok=True)
    # tests/bench.md travels with the code, so a shoot can be named there by a
    # "label" in its shoot.json instead of its folder name.
    label = shoot.name
    try:
        label = json.loads((shoot / "shoot.json").read_text()).get("label") or shoot.name
    except Exception:  # noqa: BLE001
        pass
    r = {"shoot": label, "chosen": n, "top": top, "minutes": round((time.time() - t0) / 60, 1)}
    m = re.search(r"(\d+) files you chose; (\d+) shown by default, (\d+) LOST(?: \(([^)]*)\))?", out)
    if m:
        r["shown"], r["lost"], r["why"] = int(m.group(2)), int(m.group(3)), (m.group(4) or "")
    m = re.search(r"under a stack's top: (\d+)", out)
    if m:
        r["under"] = int(m.group(1))
    m = re.search(r"in the pick set: (\d+) of (\d+)\s+\(pick set is (\d+) of (\d+) frames; random would land about ([\d.]+)\)", out)
    if m:
        r["in_top"], r["frames"], r["chance"] = int(m.group(1)), int(m.group(4)), float(m.group(5))
    m = re.search(r"combined \(current\)\s+([\d.]+)", out)
    if m:
        r["p_at_k"] = float(m.group(1))
    m = re.search(r"aesthetic only\s+([\d.]+)", out)
    if m:
        r["p_aes"] = float(m.group(1))
    m = re.search(r"random \(expected\)\s+([\d.]+)", out)
    if m:
        r["p_rand"] = float(m.group(1))
    return r


def main() -> int:
    names = sys.argv[1:]
    shoots = [ROOT / "shoots" / n for n in names] if names else sorted(p for p in (ROOT / "shoots").iterdir() if p.is_dir())
    rows = []
    for s in shoots:
        r = run(s)
        if r:
            rows.append(r)
            print(f"  {r['shoot']}: {r.get('shown', '?')}/{r['chosen']} shown, {r.get('lost', '?')} LOST, {r.get('under', 0)} under a stack top; "
                  f"{r.get('in_top', '?')} in top {r['top']} (chance {r.get('chance', 0):.1f}); "
                  f"P@{r['chosen']} {r.get('p_at_k', 0):.2f} vs random {r.get('p_rand', 0):.2f}; {r.get('minutes', '?')} min" + (f"; lost: {r['why']}" if r.get("why") else ""))
    if not rows:
        print("no shoot has a cull/selects.json")
        return 1
    L = [f"# Bench, {date.today().isoformat()}", "",
         "The cull against every shoot the photographer has already chosen from. `shown` is the number that must",
         "stay at all of them: a frame the photographer kept that the cull would not put in front of them is the",
         "worst thing it can do, and `lost` counts every such frame, whether a fault threw it out or an older",
         "cull.csv hid it for looking like another. `under` is keepers shown under the top of a stack, one key",
         "away. `in top N` is the cull's own pick set against chance. `P@k` is the ranking alone, at k = the",
         "number chosen, next to the aesthetic head by itself and to random.", "",
         "| shoot | frames | chosen | shown | lost | under a top | in top N | chance | P@k | aesthetic only | random | minutes |",
         "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        L.append(f"| {r['shoot']} | {r.get('frames', '')} | {r['chosen']} | {r.get('shown', '')} | {r.get('lost', '')}"
                 + (f" ({r['why']})" if r.get("why") else "") +
                 f" | {r.get('under', 0)} | {r.get('in_top', '')} of {r['top']} | {r.get('chance', 0):.1f} | {r.get('p_at_k', 0):.2f} | {r.get('p_aes', 0):.2f} | {r.get('p_rand', 0):.2f} | {r.get('minutes', '')} |")
    OUT.write_text("\n".join(L) + "\n")
    print(f"\n  {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
