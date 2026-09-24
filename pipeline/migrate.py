#!/usr/bin/env python3
"""
migrate.py - take the decisions out of the cache folder.

    ./pl migrate                      # every shoot under ~/photos/shoots, dry run
    ./pl migrate --apply              # actually do it
    ./pl migrate 2026-10-04-lake --apply   # one shoot
    ./pl migrate --undo --apply       # put it all back
    ./pl migrate --adopt --apply      # give a loose folder a raw/ and a shoot.json

WHY THIS EXISTS, measured across the whole library rather than one shoot:

    the portraits shoot   cull/ is 1.6 GB   3 decision files,    470 bytes
    the lounge shoot      cull/ is 297 MB   1 decision file,     427 bytes
    the dog shoot         cull/ is 146 MB   3 decision files,    307 bytes
    the action shoot      cull/ is 8.3 GB   5 decision files, 21,597 bytes
    the ducks shoot       no cull/ at all   98 ARW + 98 .dop, no shoot.json
                          ---------         -------------------------------
                          10.3 GB           12 files, 22,801 bytes

(The dog shoot was counted at four and 787 bytes until 2026-09-18, when the
fourth, `top30.json`, turned out to have no writer in `pipeline/` at all. It
is his, and it stays where it is; see the note above CACHE_NAMES.)

Those 23 KB are the answer keys, the stars, the drop reasons and the record of
which sidecars the machine wrote rather than the photographer. None of them can
be recomputed. All thirteen sit inside folders named `cull`, spelled like a
cache, shown by Finder as gigabytes, and pointed at first by anything that
cleans up. This moves them to `<shoot>/decisions/`, which is spelled like what
it holds, and leaves a symlink behind so that every module that reads
`cull/selects.json` today keeps finding it.

The failure this is designed against is already on disk. The lounge shoot
has 6 RAWs left of 296 frames; its only surviving pixels are in
`cull/decoded/` and `cull/previews/`, protected by a hand-written
`DO-NOT-CLEAN.txt` that no line of code has ever read. Pixels and decisions
surviving only inside something named like a cache is the shape of that
accident, and moving the decisions out is the half of it that costs nothing.

WHAT IT WILL NOT DO, and why the rule is worth more than the bytes:

Two incidents earned it. `gather.py clear()` was once `shutil.rmtree` and ate
154 finished exports out of `edit/edited/`; the comment above it still says so.
And the studio once read an unparseable `selects.json` as an empty set and
wrote over the damage on the next star. Both are the same mistake: a tool
acting on a file whose writer it could not name. So this tool touches a file
only when it can name the writer, and unknown provenance means untouchable by
any verb - not deleted, and not moved either. Everything else in `cull/` is
counted, printed, and left exactly where it is. Measured on the library today
that is six files, and every one of them is his: the `DO-NOT-CLEAN.txt`, the
preset he named himself, the `edits.md` and the export script in the lounge
shoot, a `top30.json` in the dog shoot, and a `reel-plan.json` in the action
shoot, which nothing in `pipeline/` reads or writes. A run that moved those
would be guessing.

The run also separates the three kinds of thing it is leaving behind, because
`cull.csv`, `bench.csv`, `presets.json`, `presets.md` and `studio.log` ARE
this pipeline's and `.DS_Store` is the Finder's, and calling all 23 remaining
files "his" would bury the six that matter. One exception is reported by measurement rather than by name:
where the RAWs a `cull.csv` measured are gone, that `cull.csv` can never be
produced again. The lounge's covers 296 frames and 6 of their RAWs are left,
so that folder is not safe to delete whatever its name says.

Safety properties, in the order they matter:

  - a dry run is the default, and prints every path and byte count
  - a file is copied, flushed, re-read and hashed at its destination before
    the source is unlinked; a mismatch aborts and removes nothing
  - every action is appended to `<shoot>/decisions/MIGRATION.jsonl` before and
    after it happens, and `--undo` replays it backwards with the same
    verification
  - state is recomputed from the disk, never trusted from the log, so a run
    killed at any point finishes correctly when run again
  - nothing here ever deletes an original, a sidecar, an export or a folder

WHAT THE REST OF THE PIPELINE HAD TO DO, and where that stands:

  1. DONE. `common.write_atomic` resolves the name before `os.replace`, so it
     writes THROUGH a symlink instead of over it. Without that, the next star
     click by the studio replaced the link at `cull/organize.json` with a real
     file and the shoot carried two divergent copies of his stars with nothing
     saying which was current.

  2. DONE, at all twenty-one. `common.decisions_dir` and `common.decision_path`
     exist and every site that names a decision file asks through them -
     studio.py, gather.py, flaws.py, bench.py, spread.py, evaluate.py,
     taste.py, presets.py and archive.py. `grep -rn` for a direct
     `cull/selects.json` or `cull/organize.json` in pipeline/ now matches only
     test fixtures. So the symlinks are the courtesy for Finder they were
     meant to be, and `--compat none` is defensible as the default. It is not
     the default yet, and changing it is a decision about his library rather
     than a tidy-up of this file.

  3. DONE. `evaluate.py` enumerates shoots through `decision_path` now, so
     losing a symlink costs it one file rather than a whole shoot.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from common import stop_cleanly_on_sigterm  # noqa: E402

ROOT = Path(os.environ.get("PHOTOS_ROOT", Path.home() / "photos")).expanduser()

DECISIONS = "decisions"
JOURNAL = "MIGRATION.jsonl"
README = "README.txt"

RAW_SUFFIXES = {".arw", ".cr2", ".cr3", ".nef", ".raf", ".rw2", ".dng", ".orf"}


# --------------------------------------------------------------- what is ours
#
# The name alone is not provenance. Each entry says what the pipeline writes
# under that name, and a file that does not have that shape is treated as a
# stranger with a familiar name and left alone. This is the cheap half of the
# rule that gather.py learned the expensive way.

def _is_frame_list(o) -> bool:
    return isinstance(o, list) and all(isinstance(x, str) for x in o)


def _is_photos_map(o) -> bool:
    return isinstance(o, dict) and isinstance(o.get("photos"), dict)


def _is_str_map(o) -> bool:
    return isinstance(o, dict) and all(isinstance(k, str) and isinstance(v, str) for k, v in o.items())


def _is_spread(o) -> bool:
    return isinstance(o, dict) and all(isinstance(v, dict) and "written" in v for v in o.values())


def _is_review(o) -> bool:
    return isinstance(o, dict) and isinstance(o.get("bursts"), dict)


def _is_archive(o) -> bool:
    return isinstance(o, dict) and isinstance(o.get("frames"), dict)


# The writer is named by its function, not by a line number: every line number
# this table carried was wrong within a fortnight of being written.
KNOWN: dict[str, tuple] = {
    # name                 shape check      who writes it                     what it is
    "selects.json":      (_is_frame_list, "studio Shoot.remember_selects", "the answer key: the frames he kept"),
    "selects.prev.json": (_is_frame_list, "studio Shoot.remember_selects", "the answer key as it was before a re-read narrowed it"),
    "organize.json":     (_is_photos_map, "studio Shoot.set_rating",       "his stars, overriding the cull's ratings"),
    "labels.json":       (_is_str_map,    "studio Shoot.set_label",        "why he dropped a frame"),
    "spread.json":       (_is_spread,     "spread.py",                     "which sidecars the machine wrote rather than him"),
    # Both of these were in cull/ and in neither of this file's tables, so a
    # migration left them behind: the record of the bursts he has been through
    # (which the page reads as his) and the record of where a shoot's
    # originals went when they were archived (without which drop frees
    # nothing and the next push copies 27 GB a second time).
    "review.json":       (_is_review,     "studio Shoot.set_review",       "which bursts he has been through, and where he stopped"),
    "archive.json":      (_is_archive,    "archive.py push",               "where this shoot's originals went, frame by frame"),
}

# top30.json was in the table above with `cull.py --top` beside it until the
# review of 2026-09-18 went looking for that writer and did not find one:
# `grep -rn top30 pipeline/` matches nothing that writes a file by that name,
# and cull.py's --top keeps N picks without recording them. MOVES.log has him
# moving one into the dog shoot by hand on 13 Sept, and the frames inside it
# are another shoot's. So it is his, arriving in a folder it was not made in -
# the exact case the rule below exists for. It is now reported and left where
# it is, which costs a file staying put.

# What the pipeline itself writes at cull/'s top level and leaves there. These
# stay: they are output, not decisions, and this migration is not a cleanup.
# Naming them is what lets the run tell the difference between a folder that is
# finally pure cache and one that still holds work of his - without that list
# every one of the 23 files left behind today reads as "his", which is wrong
# for cull.csv and would teach him to ignore the line that matters.
CACHE_NAMES = {"cull.csv", "bench.csv", "presets.json", "presets.md", "studio.log"}
CACHE_SUFFIXES = {".log"}
NOISE = {".DS_Store"}          # the Finder's, not his and not ours


class Refused(Exception):
    """A condition the tool will not work around on its own."""


def progress(stage: str, done: int, total: int) -> None:
    """One machine-readable line per step, the convention cull.py prints.

    Nothing here printed one, so anyone tailing a migration saw the file names
    go by and no idea how many were left. An --adopt of the ducks shoot is
    196 renames and a shoot.json.

    The count is per shoot, not per run: `./pl migrate --apply` with no
    argument takes every shoot in turn and starts again at 0 for each. The
    studio never runs this command, so nothing draws a bar from these."""
    print(f"@@ {stage} {done} {total}", flush=True)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def stamp() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")


def raw_dir(shoot: Path) -> Path:
    """The same branch five other modules repeat. Kept identical on purpose:
    this file is a migration, not the place to change what a shoot is."""
    return shoot / "raw" if (shoot / "raw").is_dir() else shoot


def cull_dir(shoot: Path) -> Path:
    """Where the cull wrote, which is `cull/` beside a `raw/` and `_cull/`
    otherwise - the default cull.py documents.

    A folder that is already on disk is believed ahead of that rule. Deriving
    the name from `raw/` alone loses a shoot the moment its last RAW goes:
    the lounge shoot is six ARW away from having a `cull/` full of decisions
    and no `raw/` at all, and this function used to answer `_cull` for it, so
    the run printed "no cull/ yet", moved nothing, and swallowed the
    unrecomputable-cull.csv warning in the one state where that warning is the
    whole point. Reported by the review of 2026-09-18."""
    for name in ("cull", "_cull"):
        if (shoot / name).is_dir():
            return shoot / name
    return shoot / "cull" if (shoot / "raw").is_dir() else shoot / "_cull"


def is_flat(shoot: Path) -> bool:
    """A folder of loose RAWs with no raw/ and no shoot.json - invisible to
    every command, because they all resolve raw/ by that one branch.
    one folder of 98 ARW and 98 .dop under shoots/ is like this, and another
    29 loose RAWs sit in a folder beside shoots/ entirely."""
    if (shoot / "raw").is_dir():
        return False
    return any(p.suffix.lower() in RAW_SUFFIXES for p in shoot.iterdir() if p.is_file())


def foreign(cull: Path, path: Path) -> str | None:
    """Why this tool may not touch `path`, or None when it may.

    Named for the two incidents that earned it: the 154 finished exports that
    `shutil.rmtree` took out of edit/edited/, and the 290 lounge RAWs that
    survive only in a folder spelled like a cache. A file whose writer cannot
    be named is untouchable by every verb here, move included. The cost of
    being wrong in this direction is a file left where it was; the cost of
    being wrong in the other direction is his."""
    name = path.name
    if name not in KNOWN:
        return "not a file this pipeline writes"
    if path.is_dir():
        return "a directory, not the JSON file of that name"
    check, _writer, _what = KNOWN[name]
    try:
        obj = json.loads(path.read_text())
    except (OSError, ValueError) as e:
        return f"cannot be read ({type(e).__name__}); left exactly as it is"
    if not check(obj):
        return f"does not have the shape {name} is written with"
    return None


# ------------------------------------------------------------------ the plan
#
# Every step is derived from what is on disk right now. The journal is for
# undo and for the record; it is never consulted to decide what to do next,
# because a log that disagreed with the disk would make a killed run finish
# wrong rather than finish late.

class Step:
    def __init__(self, kind: str, src: Path, dst: Path, note: str = "", bytes_: int = 0):
        self.kind = kind          # move | relink | resume | conflict | adopt | broken | skip
        self.src = src
        self.dst = dst
        self.note = note
        self.bytes = bytes_

    def __repr__(self) -> str:
        return f"<{self.kind} {self.src} -> {self.dst}>"


def classify(path: Path) -> str:
    """decision | cache | noise | his. `his` is the one that stops this tool."""
    name = path.name
    if name in KNOWN:
        return "decision"
    if name in CACHE_NAMES or path.suffix in CACHE_SUFFIXES:
        return "cache"
    if name in NOISE:
        return "noise"
    return "his"


def plan_decisions(shoot: Path, compat: str) -> tuple[list[Step], list[tuple[Path, str]], list[Path]]:
    """What this shoot needs, what is left behind and why, and what of cull/'s
    top level is the pipeline's own output."""
    cull, dec = cull_dir(shoot), shoot / DECISIONS
    steps: list[Step] = []
    left: list[tuple[Path, str]] = []
    cache: list[Path] = []
    if not cull.is_dir():
        return steps, left, cache

    for path in sorted(cull.iterdir()):
        if path.is_dir() or path.name in (JOURNAL, README):
            continue
        kind = classify(path)
        if kind == "cache" or kind == "noise":
            cache.append(path)
        elif kind == "his":
            left.append((path, "this pipeline does not write a file by this name"))

    for name in KNOWN:
        src, dst = cull / name, dec / name
        part = dst.with_name(dst.name + ".partial")
        src_is_link = src.is_symlink()
        src_here = src.exists() or src_is_link

        if src_is_link and not dst.exists():
            # Cannot arise from this tool's own order, which only ever links
            # after the destination has been read back and hashed. It means
            # something else removed decisions/ from under the link.
            steps.append(Step("broken", src, dst, "the link is here and its target is gone"))
            continue

        if src_is_link:
            target = Path(os.path.realpath(src))
            if target == dst.resolve():
                continue                                   # already done
            steps.append(Step("broken", src, dst, f"points at {target}, not at decisions/{name}"))
            continue

        if not src_here:
            if dst.exists() and compat == "symlink":
                steps.append(Step("relink", src, dst, "moved already; the compatibility link is missing"))
            continue

        why = foreign(cull, src)
        if why:
            left.append((src, why))
            continue

        size = src.stat().st_size
        # A half-written .partial is ours and unverified, from a run that died
        # mid-copy; move_verified deletes it rather than trusting it, because
        # the source is still whole. It is worth saying out loud, and it says
        # NOTHING about what is already sitting in decisions/.
        #
        # Until the review of 2026-09-18 this was a branch that returned here,
        # so a shoot carrying both a stale .partial and a decisions/ copy that
        # differed went down the plain `move` path: os.replace overwrote the
        # older answer key with no copy kept aside and no LOOK printed. That is
        # the selects.json incident arriving by a third road, and it was
        # reproduced on a fixture of the gym shoot - 154 frames replaced by 2,
        # unrecoverably. The note is carried forward; which step this is stays
        # a decision made by comparing the two files.
        stale = f"a half-written {part.name} from an interrupted run is here" if part.exists() else ""
        if not dst.exists():
            steps.append(Step("move", src, dst, stale, size))
            continue
        if sha256(src) == sha256(dst):
            note = "already at the destination and identical; finishing the move"
            steps.append(Step("resume", src, dst, f"{stale}; {note}" if stale else note, size))
            continue
        note = "both exist and they differ; both will be kept"
        steps.append(Step("conflict", src, dst, f"{stale}; {note}" if stale else note, size))

    return steps, left, cache


def unrecomputable_cull(shoot: Path) -> str | None:
    """cull.csv is machine output everywhere except where the RAWs it measured
    are gone. The lounge shoot has 6 RAWs against 296 rows, so its cull.csv
    can never be produced again - it is a measurement of frames that no longer
    exist. This does not move it (it is not a decision and the name is the
    pipeline's), but a run that called that folder pure cache would be lying."""
    cc = cull_dir(shoot) / "cull.csv"
    if not cc.exists() or cc.is_symlink():
        return None
    raw = raw_dir(shoot)
    try:
        import csv
        with cc.open() as fh:
            rows = [r for r in csv.DictReader(fh) if r.get("file")]
    except (OSError, ValueError):
        return None
    if not rows:
        return None
    # Match on the stem, not the filename. The lounge shoot was culled from
    # its decodes after the RAWs were cleared, so its `file` column reads
    # TSC04015.jpg while its selects.json reads TSC04015.ARW; comparing the
    # names would have reported 0 of 296 present on the one shoot this check
    # exists for.
    have = {p.stem for p in raw.iterdir() if p.is_file() and p.suffix.lower() in RAW_SUFFIXES} if raw.is_dir() else set()
    here = sum(1 for r in rows if Path(r["file"]).stem in have)
    if here * 2 < len(rows):
        return (f"cull.csv measures {len(rows)} frames and only {here} of their RAWs are still here: "
                f"it cannot be recomputed. cull/ is NOT safe to delete on this shoot.")
    return None


def plan_adopt(shoot: Path) -> tuple[list[Step], list[tuple[Path, str]]]:
    """Give a flat folder a raw/ so that every command can see it. Renames
    within one directory: no bytes move, no copy, no delete."""
    steps: list[Step] = []
    left: list[tuple[Path, str]] = []
    if not is_flat(shoot):
        return steps, left
    raw = shoot / "raw"
    for p in sorted(shoot.iterdir()):
        if p.is_dir() or p.name.startswith("."):
            continue
        low = p.name.lower()
        if p.suffix.lower() in RAW_SUFFIXES or low.endswith(".dop"):
            steps.append(Step("adopt", p, raw / p.name, "", p.stat().st_size))
        else:
            left.append((p, "not a RAW or a sidecar"))
    if not (shoot / "shoot.json").exists():
        steps.append(Step("shootjson", shoot / "shoot.json", shoot / "shoot.json", "written blank; fill the label in the studio"))
    return steps, left


# --------------------------------------------------------------- the journal

def journal_path(shoot: Path) -> Path:
    return shoot / DECISIONS / JOURNAL


def record(shoot: Path, **row) -> None:
    """Append one line and flush it to the platter. Written before the act it
    describes and again after, so a kill between the two is visible as a line
    with no `done` rather than as silence."""
    p = journal_path(shoot)
    p.parent.mkdir(parents=True, exist_ok=True)
    row.setdefault("at", now())
    with open(p, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(row, sort_keys=True) + "\n")
        fh.flush()
        os.fsync(fh.fileno())


def read_journal(shoot: Path) -> list[dict]:
    p = journal_path(shoot)
    if not p.exists():
        return []
    out = []
    for line in p.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except ValueError:
            continue           # a torn last line from a kill; the act it half
    return out                 # describes is still visible on the disk itself


# ------------------------------------------------------------------- the acts

def _fsync_dir(d: Path) -> None:
    fd = os.open(d, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def move_verified(src: Path, dst: Path) -> tuple[int, str]:
    """Copy, flush, read the copy back off the disk, hash it, and only then
    unlink the source. Returns (bytes, sha256).

    The read-back is not superstition. These files are 23 KB against 10 GB of
    cache in the same folder, and the one thing that must never happen is a
    truncated answer key at the destination and no answer key at the source."""
    want = sha256(src)
    size = src.stat().st_size
    dst.parent.mkdir(parents=True, exist_ok=True)
    part = dst.with_name(dst.name + ".partial")
    if part.exists():
        part.unlink()
    with open(src, "rb") as rfh, open(part, "wb") as wfh:
        shutil.copyfileobj(rfh, wfh)
        wfh.flush()
        os.fsync(wfh.fileno())
    shutil.copystat(src, part)
    if sha256(part) != want:
        part.unlink()
        raise Refused(f"{src.name}: the copy did not match the source; nothing was removed")
    os.replace(part, dst)
    _fsync_dir(dst.parent)
    if sha256(dst) != want or dst.stat().st_size != size:
        raise Refused(f"{src.name}: the destination does not match after the rename; the source is untouched")
    src.unlink()
    _fsync_dir(src.parent)
    return size, want


def link_back(src: Path, dst: Path) -> None:
    """The compatibility link: cull/selects.json -> ../decisions/selects.json.

    Relative, so the shoot folder can be renamed, copied to a drive or opened
    from a different PHOTOS_ROOT with the link still true. An absolute one
    would dangle the first time he moves a folder in Finder, which MOVES.log
    shows him doing by hand."""
    if src.is_symlink() or src.exists():
        src.unlink()
    src.parent.mkdir(parents=True, exist_ok=True)
    src.symlink_to(Path(os.path.relpath(dst, src.parent)))


def _shrinkage(old: Path, new: Path) -> str | None:
    """When two versions of one decision file disagree and the incoming one
    holds markedly less, say so. Comparing counts is all this can honestly
    do - which one he meant is not a thing a machine can work out."""
    try:
        a, b = json.loads(old.read_text()), json.loads(new.read_text())
    except (OSError, ValueError):
        return None
    for get in (lambda o: o if isinstance(o, list) else None,
                lambda o: list(o.get("photos", {})) if isinstance(o, dict) and "photos" in o else None,
                lambda o: list(o) if isinstance(o, dict) else None):
        x, y = get(a), get(b)
        if x is None or y is None:
            continue
        if len(x) and len(y) * 2 < len(x):
            return (f"the copy arriving from cull/ names {len(y)} frames where the one already in "
                    f"decisions/ named {len(x)}. Nothing was thrown away; both are here.")
        return None
    return None


README_TEXT = """\
This folder holds the decisions. Everything in it was made by a person and
cannot be recomputed by any amount of processing: the frames kept, the stars,
the reasons a frame was dropped, and the record of which sidecars the machine
wrote rather than the photographer.

It used to live in cull/, which is a cache, is measured in gigabytes, and is
the first folder any cleanup points at. These files are measured in kilobytes.

cull/ may be deleted in full once it holds nothing but this pipeline's own
output; these files are not that. The links inside cull/ point here, so
anything still reading cull/selects.json keeps working.

MIGRATION.jsonl is the log of how this folder was made, with enough in it to
reverse every step:  ./pl migrate <shoot> --undo --apply
"""


# -------------------------------------------------------------------- running

def do_decisions(shoot: Path, steps: list[Step], compat: str, out, step=None) -> int:
    dec = shoot / DECISIONS
    dec.mkdir(parents=True, exist_ok=True)
    rm = dec / README
    if not rm.exists():
        rm.write_text(README_TEXT)
        record(shoot, op="readme", to=f"{DECISIONS}/{README}", done=True)
    done = 0
    for st in steps:
        # At the head of the loop, so a step that is refused or relinked still
        # moves the count: three of the four kinds below leave by `continue`.
        if step:
            step()
        rel_src = os.path.relpath(st.src, shoot)
        rel_dst = os.path.relpath(st.dst, shoot)
        if st.kind == "broken":
            print(f"    REFUSED  {rel_src}: {st.note}", file=out)
            continue
        if st.kind == "relink":
            link_back(st.src, st.dst)
            record(shoot, op="symlink", frm=rel_src, to=rel_dst, done=True)
            print(f"    linked   {rel_src} -> {rel_dst}", file=out)
            done += 1
            continue
        if st.kind == "conflict":
            # Never choose between two versions of a decision on his behalf.
            # This is the selects.json incident in miniature: the studio read a
            # key it could not parse as an empty set and wrote over it. Both
            # copies are kept, the newer one goes into place, and the run says
            # the other one's name out loud.
            aside = st.dst.with_name(f"{st.dst.stem}.superseded-{stamp()}{st.dst.suffix}")
            shrink = _shrinkage(st.dst, st.src)
            os.replace(st.dst, aside)
            record(shoot, op="aside", frm=rel_dst, to=os.path.relpath(aside, shoot), done=True, shrink=shrink or "")
            print(f"    KEPT     {rel_dst} differs from {rel_src}; kept as {aside.name}", file=out)
            if shrink:
                # The studio refuses a write that would halve an answer key,
                # for the reason recorded in studio's remember_selects. This is the same
                # shape arriving by a different road, and the tool will not
                # quietly decide which of the two he meant.
                print(f"    LOOK     {shrink}", file=out)
                print(f"             read both before running anything else: {aside.name} is the longer one.", file=out)
        record(shoot, op="move", frm=rel_src, to=rel_dst, bytes=st.bytes, done=False)
        size, digest = move_verified(st.src, st.dst)
        record(shoot, op="move", frm=rel_src, to=rel_dst, bytes=size, sha256=digest, done=True)
        if compat == "symlink":
            link_back(st.src, st.dst)
            record(shoot, op="symlink", frm=rel_src, to=rel_dst, done=True)
        elif compat == "copy":
            shutil.copy2(st.dst, st.src)
            record(shoot, op="copyback", frm=rel_dst, to=rel_src, done=True)
        # "finished" for a conflict read as though the disagreement had been
        # settled; it had not, and the line above it is the one that matters.
        word = {"move": "moved", "conflict": "replaced", "resume": "finished"}.get(st.kind, "moved")
        print(f"    {word:8} {rel_src} -> {rel_dst}  ({size:,} bytes, verified)", file=out)
        done += 1
    return done


def do_adopt(shoot: Path, steps: list[Step], out, step=None) -> int:
    done = 0
    renamed = side = 0
    for st in steps:
        if step:
            step()
        if st.kind == "shootjson":
            meta = {"kind": "other", "label": "", "style": "normal", "focus": 1.9}
            st.dst.write_text(json.dumps(meta, indent=1) + "\n")
            record(shoot, op="shootjson", to="shoot.json", created=True, done=True)
            print("    wrote    shoot.json (label blank; set it in the studio)", file=out)
            done += 1
            continue
        st.dst.parent.mkdir(parents=True, exist_ok=True)
        ino = st.src.stat().st_ino
        record(shoot, op="adopt", frm=os.path.relpath(st.src, shoot), to=os.path.relpath(st.dst, shoot), done=False)
        # A rename inside one directory. The inode is checked on the far side
        # because this is the one place the tool handles an original, and a
        # rename that silently became a copy would double 2.3 GB on a disk
        # that is 91% full.
        os.rename(st.src, st.dst)
        if st.dst.stat().st_ino != ino:
            raise Refused(f"{st.src.name}: the rename did not preserve the file; stopping")
        record(shoot, op="adopt", frm=os.path.relpath(st.src, shoot), to=os.path.relpath(st.dst, shoot),
               inode=ino, bytes=st.bytes, done=True)
        if st.src.name.lower().endswith(".dop"):
            side += 1
        else:
            renamed += 1
        done += 1
    if renamed or side:
        # One line, not 196. Printing a rename per frame buries the shoot.json
        # line under it, and the inode check below is the thing worth saying.
        print(f"    adopted  {renamed} RAWs and {side} sidecars into raw/ "
              f"(renamed in place, same inodes, 0 bytes copied)", file=out)
    if done:
        _fsync_dir(shoot)
    return done


def do_undo(shoot: Path, apply: bool, forget: bool, out) -> int:
    """Replay the log backwards, with the same verification going the other
    way. Everything this tool made is removed; nothing else is."""
    rows = [r for r in read_journal(shoot) if r.get("done")]
    if not rows:
        print("  nothing to undo (no MIGRATION.jsonl, or nothing completed)", file=out)
        return 0
    n = unadopted = 0
    for i, r in enumerate(reversed(rows)):
        progress("migrate", i, len(rows))
        op = r.get("op")
        if op == "symlink":
            src = shoot / r["frm"]
            if src.is_symlink():
                if apply:
                    src.unlink()
                print(f"    unlink   {r['frm']} (the compatibility link)", file=out)
                n += 1
        elif op == "copyback":
            src = shoot / r["to"]
            if src.exists() and not src.is_symlink():
                if apply:
                    src.unlink()
                print(f"    unlink   {r['to']} (the compatibility copy)", file=out)
                n += 1
        elif op == "move":
            dst, src = shoot / r["to"], shoot / r["frm"]
            if not dst.exists():
                continue
            if src.is_symlink() and apply:
                src.unlink()
            if src.exists() and not src.is_symlink():
                print(f"    REFUSED  {r['frm']} is back already and is a real file; {r['to']} left where it is", file=out)
                continue
            print(f"    restore  {r['to']} -> {r['frm']}", file=out)
            if apply:
                move_verified(dst, src)
                record(shoot, op="undo-move", frm=r["to"], to=r["frm"], done=True)
            n += 1
        elif op == "aside":
            print(f"    left     {r['to']} in place (a copy that differed; yours to read)", file=out)
        elif op == "adopt":
            dst, src = shoot / r["to"], shoot / r["frm"]
            if dst.exists() and not src.exists():
                if apply:
                    os.rename(dst, src)
                    record(shoot, op="undo-adopt", frm=r["to"], to=r["frm"], done=True)
                unadopted += 1
                n += 1
        elif op == "shootjson" and r.get("created"):
            p = shoot / "shoot.json"
            if p.exists():
                print("    unlink   shoot.json (this tool wrote it)", file=out)
                if apply:
                    p.unlink()
                n += 1
        elif op == "readme":
            p = shoot / DECISIONS / README
            if p.exists():
                print(f"    unlink   {DECISIONS}/{README}", file=out)
                if apply:
                    p.unlink()
                n += 1
    progress("migrate", len(rows), len(rows))
    if unadopted:
        print(f"    restore  {unadopted} RAWs and sidecars back out of raw/ (renamed in place)", file=out)
    if apply:
        # Only the raw/ this tool's own --adopt made. Without the `unadopted`
        # test this removed any empty raw/ it found, including one he had made
        # himself and not filled yet - an undo is meant to remove what this
        # tool made and nothing else, and an empty folder is still a folder he
        # put there. Reported by the review of 2026-09-18.
        raw = shoot / "raw"
        if unadopted and raw.is_dir() and not any(raw.iterdir()):
            raw.rmdir()
            print("    rmdir    raw/ (empty again)", file=out)
        dec = shoot / DECISIONS
        if dec.is_dir():
            rest = [p for p in dec.iterdir() if p.name != JOURNAL]
            if not rest:
                if forget:
                    journal_path(shoot).unlink(missing_ok=True)
                    dec.rmdir()
                    print(f"    rmdir    {DECISIONS}/ (and its log, as asked)", file=out)
                else:
                    keep = shoot / f"MIGRATION-undone-{stamp()}.jsonl"
                    os.replace(journal_path(shoot), keep)
                    dec.rmdir()
                    print(f"    kept     the log as {keep.name}; --forget removes it too", file=out)
            else:
                print(f"    kept     {DECISIONS}/ ({len(rest)} file(s) this tool did not put there)", file=out)
    return n


# ----------------------------------------------------------------------- main

def shoots_under(root: Path) -> list[Path]:
    d = root / "shoots"
    if not d.is_dir():
        return []
    return sorted(p for p in d.iterdir() if p.is_dir() and not p.name.startswith("."))


def resolve(target: str, root: Path) -> Path:
    p = Path(target).expanduser()
    if p.is_dir():
        return p.resolve()
    q = root / "shoots" / target
    if q.is_dir():
        return q.resolve()
    raise Refused(f"no such shoot: {target}")


def run_shoot(shoot: Path, args, out) -> tuple[int, int, int]:
    """Returns (acted, left_behind, refused)."""
    print(f"\n  {shoot.name}", file=out)
    if args.undo:
        n = do_undo(shoot, args.apply, args.forget, out)
        return n, 0, 0

    acted = refused = 0
    dsteps, dleft, dcache = plan_decisions(shoot, args.compat)
    asteps, aleft = (plan_adopt(shoot) if args.adopt else ([], []))
    flat = is_flat(shoot)

    if flat and not args.adopt:
        n_raw = sum(1 for p in shoot.iterdir() if p.is_file() and p.suffix.lower() in RAW_SUFFIXES)
        n_dop = sum(1 for p in shoot.iterdir() if p.is_file() and p.name.lower().endswith(".dop"))
        print(f"    {n_raw} loose RAWs and {n_dop} sidecars, no raw/ and no shoot.json:", file=out)
        # It is not invisible to everything - library.shoots, the reclaim
        # report and archive.parts all see a folder like this - so saying so
        # sent him looking for a fault that was not there. What it has no
        # cull/ for is that nothing has culled it.
        print("    the studio and gather do not see it, and nothing has culled it yet.", file=out)
        print("    Run with --adopt to give it a raw/ (renames inside one folder, no bytes move).", file=out)

    total = sum(s.bytes for s in dsteps)
    for st in dsteps:
        if st.kind == "broken":
            refused += 1

    if not dsteps and not asteps:
        if (shoot / DECISIONS).is_dir():
            print("    already migrated; nothing to do", file=out)
        elif not cull_dir(shoot).is_dir() and not flat:
            print("    no cull/ yet", file=out)
        elif cull_dir(shoot).is_dir():
            print("    no decision files here", file=out)
    else:
        if args.apply:
            # One count across both halves of the run, because they are one
            # thing to the person waiting: the decisions move, then the loose
            # RAWs are adopted.
            total = len(dsteps) + len(asteps)
            seen = [0]

            def step(total: int = total, seen: list = seen) -> None:
                progress("migrate", seen[0], total)
                seen[0] += 1

            acted += do_decisions(shoot, dsteps, args.compat, out, step) if dsteps else 0
            acted += do_adopt(shoot, asteps, out, step) if asteps else 0
            progress("migrate", total, total)
        else:
            for st in dsteps:
                rel_src, rel_dst = os.path.relpath(st.src, shoot), os.path.relpath(st.dst, shoot)
                if st.kind == "broken":
                    print(f"    REFUSED  {rel_src}: {st.note}", file=out)
                elif st.kind == "relink":
                    # Counted, because --apply counts it. A shoot needing only
                    # a link said "0 file(s) would move" and then "1 moved".
                    print(f"    would link    {rel_src} -> {rel_dst}   ({st.note})", file=out)
                    acted += 1
                else:
                    tail = f"   ({st.note})" if st.note else ""
                    print(f"    would move    {rel_src} -> {rel_dst}  {st.bytes:,} bytes{tail}", file=out)
                    acted += 1
            for st in asteps:
                if st.kind == "shootjson":
                    print("    would write   shoot.json (blank label)", file=out)
                else:
                    print(f"    would rename  {os.path.relpath(st.src, shoot)} -> {os.path.relpath(st.dst, shoot)}"
                          f"  ({st.bytes:,} bytes, same folder, no copy)", file=out)
                acted += 1
            if dsteps and total:
                print(f"    {total:,} bytes of decisions would leave a cull/ of {human(du(cull_dir(shoot)))}", file=out)

    if dcache:
        # The Finder's droppings are not this pipeline's output, and a tool
        # whose whole claim is that it can name the writer of every file must
        # not put .DS_Store in a sentence that ends "this pipeline wrote".
        # Found on 2026-09-18 in the dog and action shoots, where that line named
        # a .DS_Store among five files of ours.
        junk = sorted(p.name for p in dcache if p.name in NOISE)
        ours = sorted(p.name for p in dcache if p.name not in NOISE)
        if ours:
            print(f"    cache    {len(ours)} file(s) this pipeline wrote, staying in cull/: {', '.join(ours)}", file=out)
        if junk:
            print(f"    junk     {len(junk)} the Finder's, neither his nor ours: {', '.join(junk)}", file=out)

    for path, why in dleft + aleft:
        print(f"    HIS      {os.path.relpath(path, shoot)}: {why}; untouched", file=out)

    warn = unrecomputable_cull(shoot)
    if warn:
        print(f"    WARNING  {warn}", file=out)

    if dleft:
        print(f"    cull/ is not pure cache yet: {len(dleft)} file(s) in it are his, not this pipeline's.", file=out)
    elif not warn and cull_dir(shoot).is_dir() and (shoot / DECISIONS).is_dir():
        print("    cull/ now holds nothing but this pipeline's own output.", file=out)
    return acted, len(dleft) + len(aleft), refused


def du(path: Path) -> int:
    """Bytes under `path`, counting a file once however many names it has.

    `du` does this and so must anything whose number he will compare against
    it. edit/ holds 264 RAWs that are hard links to raw/, three names to one
    inode, and adding every name up called the action shoot 45.1 GB against du's
    36.5 GB - 24% of a shoot that does not exist. Today this is only ever
    aimed at a cull/, which has no hard links in it, so the two agreed to
    within 0.7% and the fault was invisible; it would not have stayed
    invisible the first time the number was aimed at a shoot. Symlinks are
    counted at lstat size, which is what du does with them too: cull/picks is
    161 symlinks into raw/, not the 4 GB Finder shows."""
    if not path.is_dir():
        return 0
    n = 0
    seen: set[tuple[int, int]] = set()
    for p, _dirs, files in os.walk(path):
        for f in files:
            try:
                st = os.lstat(os.path.join(p, f))
            except OSError:
                continue
            if st.st_nlink > 1:
                key = (st.st_dev, st.st_ino)
                if key in seen:
                    continue
                seen.add(key)
            n += st.st_size
    return n


def human(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024.0
    return f"{n} B"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="pl migrate",
        description="Move the decisions out of cull/ and into decisions/. Prints what it would do and changes nothing unless told to.")
    ap.add_argument("shoots", nargs="*", help="a shoot folder or its name; default is every shoot under PHOTOS_ROOT/shoots")
    ap.add_argument("--apply", action="store_true", help="actually do it (without this, nothing is written)")
    ap.add_argument("--undo", action="store_true", help="put everything back, verifying on the way")
    ap.add_argument("--forget", action="store_true", help="with --undo, remove the migration log as well")
    ap.add_argument("--adopt", action="store_true", help="also give a loose folder of RAWs a raw/ and a shoot.json")
    ap.add_argument("--compat", choices=("symlink", "copy", "none"), default="symlink",
                    help="what to leave at cull/<name> so existing readers still find it (default: symlink)")
    ap.add_argument("--root", default=str(ROOT), help="PHOTOS_ROOT")
    args = ap.parse_args(argv)
    stop_cleanly_on_sigterm()

    root = Path(args.root).expanduser()
    try:
        targets = [resolve(t, root) for t in args.shoots] if args.shoots else shoots_under(root)
    except Refused as e:
        print(f"  {e}")
        return 2
    if not targets:
        print(f"  no shoots under {root / 'shoots'}")
        return 1

    out = sys.stdout
    head = "undoing" if args.undo else "migrating"
    print(f"  {head} {len(targets)} shoot(s) under {root}"
          f"{'' if args.apply else '   DRY RUN - nothing will be written'}", file=out)

    acted = left = refused = 0
    for shoot in targets:
        try:
            a, m, r = run_shoot(shoot, args, out)
        except Refused as e:
            print(f"    STOPPED  {e}", file=out)
            return 3
        acted += a
        left += m
        refused += r

    print("", file=out)
    if args.undo:
        print(f"  {acted} step(s) {'reversed' if args.apply else 'would be reversed'}", file=out)
    else:
        print(f"  {acted} file(s) {'moved' if args.apply else 'would move'}; "
              f"{left} left alone because this tool did not write them"
              + (f"; {refused} refused" if refused else ""), file=out)
    if not args.apply:
        print("  nothing was changed. Add --apply to do it.", file=out)
    elif not args.undo:
        print("  reverse it at any time with:  ./pl migrate --undo --apply", file=out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
