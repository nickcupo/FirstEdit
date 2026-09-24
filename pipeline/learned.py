#!/usr/bin/env python3
"""
learned.py - everything the cull and the starting edit have learned, in one
folder, checked against every photo he kept before any of it is used.

    ./pl learned                     what is in use, what is held back, and why
    ./pl learned run                 learn from finished shoots, check, swap or hold
    ./pl learned --check             the keeper check, frame by frame, changing nothing
    ./pl learned --back <learner>    go back to the version before
    ./pl learned --stop <learner>    stop using one (its data is kept)
    ./pl learned import <file>       take in a starting edit learned by an older build

Three things learn: why he drops frames (flaws.py), which frames of a burst he
keeps (the ranker taste.py used to hide inside the starting edit), and the
starting edit itself (taste.py). Each one only reorders what the cull shows;
none of them can throw a frame out. Each learns "his" from the frames he
exported (taught, below), and is checked against every frame he kept.

THE FOLDER. Every learned file lives in one writable folder - PIPELINE_LEARNED,
else $PIPELINE_SUPPORT/learned, else the app's Application Support folder - so
the app and a checkout read and write the same models. Never in the repo and
never inside the app bundle: the bundle is signed and read-only, which is how
the app came to read a starting edit baked in at build time and learn nothing
for as long as it was installed.

THE KEEPER CHECK. A new model is a candidate. Before it is used, it is scored
against every keeper of every shoot that carries his verdicts, from each
shoot's cull.csv and the vectors the cull cached, in seconds and without
re-culling anything. It goes live only when no keeper of his moves out of
sight on any shoot, and when every one of his keepers was found. Anything else
is held, with the frames it would have moved listed one by one, because the
only person who can overrule that is him and he can only do it looking at the
photographs.

Its own held-out score is not that check: a drop-reason model retrained on 44
reasons scored AUC 0.90 and 0.97 held out, and would have hidden 15 of his 773
keepers and moved 35 down a level.
"""

from __future__ import annotations

import argparse
import contextlib
import csv
import fcntl
import json
import os
import shutil
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from common import (MODELS, RAW_EXTS, deal_tiers, stack_tiers, decision_path, learned_dir,  # noqa: E402
                    write_atomic, write_json_atomic)

ROOT = Path(os.environ.get("PHOTOS_ROOT", Path.home() / "photos")).expanduser()
# The neutral starting edit that ships with the code: no venues, no ranker, and
# so DxO's own camera-body rendering until something has been learned here.
SEED = HERE / "taste.json"

# Where older builds kept the drop-reason model. Nothing reads it any more;
# take_in_what_was_in_use() brings it in once, as a candidate.
LEGACY_FLAWS = MODELS / "flaws.json"

LEARNERS = ("drop-reasons", "tier-order", "edit")
TITLES = {"drop-reasons": "Why you drop frames",
          "tier-order": "Which frames of a burst you keep",
          "edit": "Your starting edit"}
# What each learner changes, in his words, for the panel and the CLI. Each is
# the line under the learner's title, so it reads as a sentence of its own,
# and it uses the app's words: the frames the cull puts forward, not its
# tiers; a preset, not a sidecar.
CHANGES = {"drop-reasons": "A frame that looks like a reason you gave for dropping one ranks lower in the cull's order.",
           "tier-order": "The order of the frames the cull puts forward inside a burst.",
           "edit": "The first preset of a new shoot. It never re-renders anything you exported."}

# The reasons he gives are stored under the engine's labels, and two of them
# are not the words he presses: the keys after D, and Frame ▸ Why It Is Out,
# say face and framing. A sentence he reads says what he pressed.
REASON_WORDS = {"expression": "face", "composition": "framing"}


def reason_word(label: str) -> str:
    return REASON_WORDS.get(label, label)


class Refused(RuntimeError):
    """Something was not done, with the reason a person can act on."""


class Unreadable(Refused):
    """The record itself will not read. The terminal gets the whole of it,
    path and parser's reason; the page gets `UNREADABLE` in a sentence of its
    own, with the file beside it as a path he can click and the parser's
    reason in its help, rather than a red line that began with his home
    folder."""

    def __init__(self, path: Path, why: str, said: str):
        super().__init__(said)
        self.path, self.why = path, why


# What the page says when the record will not read. Learn Now waits while it
# does not: learning would only refuse for the same reason. It claims nothing
# about what the cull uses meanwhile - the models in use are files of their
# own, read without the record.
UNREADABLE = ("The record of what the cull has learned will not read, so nothing new can be learned until "
              "it does. Nothing in it was changed: look at it, or move it aside.")


# ------------------------------------------------------------- the folder

def folder() -> Path:
    """The one folder the learned models live in.

    PIPELINE_LEARNED for a test or a scratch run, else the support folder the
    app passes (PIPELINE_SUPPORT), else the app's own folder in Application
    Support, so a checkout and the installed app learn from each other instead
    of keeping two models that never meet. common.learned_dir() answers,
    through the one resolver that knows the support folder's old and new
    names."""
    return learned_dir()


def _writable() -> Path:
    """The folder, made if it is not there, and never somewhere that cannot
    hold his learned state: inside the checkout it would be a git diff per
    retrain, and inside the app bundle it would not be writable at all (and
    would break the signature if it were)."""
    d = folder()
    full = d.expanduser().resolve()
    repo = HERE.parent.resolve()
    if full == repo or repo in full.parents:
        raise Refused(f"{d} is inside the checkout; learned files belong outside it (set PIPELINE_LEARNED)")
    if any(p.suffix == ".app" for p in (full, *full.parents)):
        raise Refused(f"{d} is inside an application bundle, which is read-only; set PIPELINE_SUPPORT")
    d.mkdir(parents=True, exist_ok=True)
    (d / "history").mkdir(exist_ok=True)
    return d


def path(learner: str) -> Path:
    """The live model file of one learner. cull.py and presets.py reach it
    through flaws.load() and taste.load(), never by name."""
    return folder() / f"{learner}.json"


def _history(learner: str) -> Path:
    return folder() / "history" / learner


def _manifest_path() -> Path:
    return folder() / "manifest.json"


_REENTRANT = threading.RLock()
_DEPTH = 0


@contextlib.contextmanager
def _locked():
    """One writer at a time, across processes and across threads.

    The studio answers on threads and a learning job runs beside it in another
    process; both read the manifest, change it and write it back. Re-entrant,
    because seeding a starting edit on first use takes it in through the same
    door that takes in a freshly learned one, and a plain flock on a second
    file handle in the same process waits for itself forever."""
    global _DEPTH
    d = _writable()
    with _REENTRANT:
        if _DEPTH:
            _DEPTH += 1
            try:
                yield
            finally:
                _DEPTH -= 1
            return
        with open(d / ".lock", "a+") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            _DEPTH = 1
            try:
                yield
            finally:
                _DEPTH = 0
                fcntl.flock(fh, fcntl.LOCK_UN)


def _blank() -> dict:
    return {"version": 1, "learners": {}, "keepers": {}, "trained_on": {}, "last_run": None, "queued": None}


def manifest() -> dict:
    """What is in use, what is held and what it was checked against.

    A manifest that will not parse is not overwritten: it is the record of
    every version that was ever live, and rewriting it from what happens to be
    on disk now would throw that away."""
    p = _manifest_path()
    if not p.exists():
        return _blank()
    try:
        m = json.loads(p.read_text())
    except (OSError, ValueError) as e:
        raise Unreadable(p, str(e), f"{p} is on disk and cannot be read ({e}). Nothing was changed; look at that "
                                    f"file, or move it aside") from e
    if not isinstance(m, dict) or "learners" not in m:
        raise Unreadable(p, "not a record this version understands",
                         f"{p} is not a record this version understands. Nothing was changed")
    return {**_blank(), **m}


def _save(m: dict) -> None:
    _writable()
    write_json_atomic(_manifest_path(), m)


def _entry(m: dict, learner: str) -> dict:
    e = m["learners"].setdefault(learner, {})
    e.setdefault("chain", [])          # the versions that have been live, oldest first
    e.setdefault("versions", {})
    e.setdefault("events", [])
    e.setdefault("stopped", False)
    e.setdefault("candidate", None)
    return e


def _now() -> str:
    return datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


def _stamp(learner: str) -> str:
    base = datetime.now().strftime("%Y%m%d-%H%M%S")
    d = _history(learner)
    ts, n = base, 1
    while (d / f"{ts}.json").exists():
        n += 1
        ts = f"{base}-{n}"
    return ts


def _note(e: dict, what: str, version: str | None = None) -> None:
    e["events"].append({"at": _now(), "what": what, "version": version})
    del e["events"][:-50]


# ------------------------------------------ the measurements, kept once

# The starting edit is fitted on numbers measured off each finished frame -
# its light, its faces, where his export put them. Measuring one frame costs a
# face detection, a landmark pass and a RAW decode, and the RAW has to be on
# the disk to do it. That made his teaching perishable in two ways at once: a
# shoot whose RAWs had gone to iCloud dropped out of every later fit (527
# finished frames became 283 the first run after he archived 2026-09-16), and
# every run paid for all of it again (471 seconds, growing with the library).
#
# So the numbers are kept, here, beside the models they feed: one line per
# frame, appended, never edited in place. A frame is measured once; after that
# it teaches from this file whether or not its photograph is still on this Mac.
# What is kept is the measurement, not the picture - no pixels, no thumbnail,
# nothing that could stand in for the photograph itself.
#
# The row says what it was measured FROM (the hash of his sidecar, the size and
# date of the export) and WITH (the schema of the measuring code), so a sidecar
# he edits again is re-measured, and a change to how we measure re-measures
# what it can and says so about what it cannot.
MEASURED = "measured.jsonl"
# Rows superseded by a later measurement of the same frame are dropped when
# they outnumber the live ones; below that the file is left alone, because a
# rewrite is the one operation that could lose a row.
_COMPACT_AT = 1.0


def measured_file() -> Path:
    return folder() / MEASURED


_LINES: tuple[tuple, list[dict]] | None = None


def _measured_lines() -> list[dict]:
    """Every row on disk, oldest first. A line that will not parse is skipped,
    never a reason to refuse the whole file: the fit can go on without one
    frame, and stopping the learning because of a half-written line is a worse
    answer than learning from the rest.

    Kept per file and per change. The studio asks the panel for the store's
    size every two seconds while a run is going, and at ten thousand finished
    frames this file is tens of megabytes: re-reading it on each of those would
    make the size of what he has taught the cost of watching it learn."""
    global _LINES
    p = measured_file()
    if not p.exists():
        _LINES = None
        return []
    try:
        st = p.stat()
        mark = (str(p), st.st_mtime_ns, st.st_size)
    except OSError:
        return []
    if _LINES is not None and _LINES[0] == mark:
        return _LINES[1]
    out: list[dict] = []
    try:
        with p.open() as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if isinstance(r, dict) and r.get("key"):
                    out.append(r)
    except OSError:
        return []
    _LINES = (mark, out)
    return out


def measured_read(kind: str | None = None) -> tuple[dict[str, dict], int]:
    """(the newest measurement of each thing, how many rows are on disk).

    A frame measured again appears twice; the later row wins. A frame he has
    since un-finished carries a `gone` row, which removes it from the answer
    and stays on disk as the record that it was there.

    `kind` narrows it: "frame" for the finished frames the starting edit is
    fitted on, "skin" for one reading off one photograph he exported. A row
    written before there were two kinds is a frame."""
    rows = _measured_lines()
    table: dict[str, dict] = {}
    for r in rows:
        if kind is not None and str(r.get("kind") or "frame") != kind:
            continue
        if r.get("gone"):
            table.pop(r["key"], None)
        else:
            table[r["key"]] = r
    return table, len(rows)


def measured_add(rows: list[dict]) -> int:
    """Append measurements. One open, one write, under the same lock as the
    manifest, so a run started from the app and one started from the terminal
    cannot interleave half a line."""
    rows = [r for r in rows if r.get("key")]
    if not rows:
        return 0
    with _locked():
        _writable()
        with measured_file().open("a") as fh:
            fh.write("".join(json.dumps(r, separators=(",", ":"), sort_keys=True) + "\n" for r in rows))
            fh.flush()
            os.fsync(fh.fileno())
    return len(rows)


def measured_compact(force: bool = False) -> int:
    """Rewrite the file with only the newest row per frame. Returns how many
    rows went. Atomic, and it never drops a frame - only older readings of one
    that has been measured again."""
    rows = _measured_lines()
    if not rows:
        return 0
    # The last row for each frame, by position in the file. Compared by
    # position and not by value: two runs can measure a frame to the same
    # numbers, and "is this the row the reader would use" is a question about
    # where it sits, not about what it says.
    last: dict[str, int] = {}
    for i, r in enumerate(rows):
        last[r["key"]] = i
    keep = set(last.values())
    live = [r for i, r in enumerate(rows) if i in keep and not r.get("gone")]
    dead = len(rows) - len(live)
    if not force and dead < _COMPACT_AT * max(1, len(live)):
        return 0
    with _locked():
        _writable()
        write_atomic(measured_file(), "".join(json.dumps(r, separators=(",", ":"), sort_keys=True) + "\n"
                                              for r in live))
    return dead


def measured_forget(shoot: str) -> dict:
    """Drop one shoot's contribution, because he deleted it or it should never
    have taught. His, never automatic: nothing in a run calls this.

    What is taken out is written to the learned folder's history first, so a
    shoot dropped by mistake can be put back by hand rather than re-shot."""
    rows = _measured_lines()
    # Its frames, and the readings taken off the photographs it produced: an
    # export is named for the frame it came from, which is the only thread back
    # to the shoot once it is sitting in iCloud among everything else.
    stems = {str(r.get("stem") or "") for r in rows if r.get("shoot") == shoot} - {""}

    def his(r: dict) -> bool:
        if r.get("shoot") == shoot:
            return True
        k = str(r.get("key") or "")
        return k.startswith("skin/") and Path(k).name.split("_DxO")[0] in stems

    mine = [r for r in rows if his(r)]
    if not mine:
        return {"shoot": shoot, "frames": 0,
                "sentence": f"Nothing in the measurements came from {shoot}; nothing changed."}
    with _locked():
        d = _writable() / "history" / "dropped"
        d.mkdir(parents=True, exist_ok=True)
        kept = d / f"{shoot}-{datetime.now().strftime('%Y%m%d-%H%M%S')}.jsonl"
        write_atomic(kept, "".join(json.dumps(r, separators=(",", ":"), sort_keys=True) + "\n" for r in mine))
        write_atomic(measured_file(), "".join(json.dumps(r, separators=(",", ":"), sort_keys=True) + "\n"
                                              for r in rows if not his(r)))
        m = manifest()
        e = _entry(m, "edit")
        m["dropped_shoots"] = sorted({*(str(x) for x in (m.get("dropped_shoots") or [])), shoot})
        _note(e, f"you dropped {shoot} from the measurements ({len(mine)} frames); "
                 f"they are in {kept.parent.name}/{kept.name}")
        _save(m)
    frames = len({r["key"] for r in mine if not r.get("gone")})
    return {"shoot": shoot, "frames": frames, "kept": str(kept),
            "sentence": f"{shoot} no longer teaches the starting edit: {frames} frames taken out. "
                        f"They are kept in {kept}, and it stays out until you say otherwise "
                        f"(./pl learned --teach-again {shoot}). Learn again to fit without it."}


def dropped_shoots() -> list[str]:
    """Shoots he has taken out of the measurements by hand, and which stay out.

    A drop that the next run quietly undid would not be a drop: the shoot is
    still on the disk, still finished, and the learning would measure it again
    the same evening. So the name is kept, and `--teach-again` is the only way
    back in."""
    try:
        return sorted(str(x) for x in (manifest().get("dropped_shoots") or []))
    except Refused:
        return []


def teach_again(shoot: str) -> dict:
    """Let a shoot he dropped teach again. It is measured afresh on the next
    run, from whatever of it is still here."""
    with _locked():
        m = manifest()
        had = [str(x) for x in (m.get("dropped_shoots") or [])]
        if shoot not in had:
            return {"shoot": shoot, "sentence": f"{shoot} was not one you had taken out; nothing changed."}
        m["dropped_shoots"] = [x for x in had if x != shoot]
        _note(_entry(m, "edit"), f"you let {shoot} teach again")
        _save(m)
    return {"shoot": shoot,
            "sentence": f"{shoot} can teach the starting edit again. Learn again and it is measured afresh."}


def measured_size() -> dict:
    """What the store holds and what it costs, for the panel and for him."""
    p = measured_file()
    try:
        b = p.stat().st_size if p.exists() else 0
    except OSError:
        b = 0
    table, rows = measured_read("frame")
    skin, _ = measured_read("skin")
    shoots: dict[str, int] = {}
    for r in table.values():
        shoots[str(r.get("shoot") or "")] = shoots.get(str(r.get("shoot") or ""), 0) + 1
    return {"path": str(p), "bytes": b, "frames": len(table), "rows": rows, "exports": len(skin),
            "per_frame": int(b / len(table)) if table else 0,
            "shoots": dict(sorted(shoots.items()))}


def measured_words(size: dict) -> str:
    """The store's size in his words. Bytes are ours; megabytes are his."""
    b = int(size.get("bytes") or 0)
    if b < 1024:
        return f"{b} bytes"
    if b < 1024 * 1024:
        return f"{b / 1024:.0f} KB"
    return f"{b / (1024 * 1024):.1f} MB"


# ------------------------------------------------------- versions on disk

def _write_version(learner: str, model: dict, source: str, data: dict | None = None) -> str:
    """Keep a copy of a model, whatever happens to it next. Every version that
    was ever live is here, and so is every candidate that was held."""
    d = _history(learner)
    d.mkdir(parents=True, exist_ok=True)
    ts = _stamp(learner)
    write_json_atomic(d / f"{ts}.json", model, indent=None)
    if data is not None:
        write_json_atomic(d / f"{ts}.data.json", data)
    return ts


def version_model(learner: str, ts: str) -> dict | None:
    p = _history(learner) / f"{ts}.json"
    try:
        return json.loads(p.read_text()) if p.exists() else None
    except (OSError, ValueError):
        return None


# The rules a check was made under. A stored check is a sentence he reads for
# as long as the candidate stands, and the rules behind it do change: tonight
# the exposure model was retired and the white-balance comparison was rewritten,
# and the page went on quoting a reason about exposure that the code can no
# longer produce. So every check records which rules made it, and a check made
# under older rules is not believed - it is worked out again.
#
# Put the reason in the message when this goes up, and the date, because it is
# the only record of why every verdict was re-derived on one particular day.
#   2 - 2026-09-23: the exposure clauses retired; wb judged on its own baseline,
#       per venue where it is consulted, and against the model in use refitted
#       on the same frames in the same folds.
#   3 - 2026-09-23: a venue's own exposure type is judged against the rule it
#       would replace on that venue (_check_exposure), and the page separates
#       what is in use from what is held and from what is short of evidence.
#   4 - 2026-09-23: a venue's fit is held out by scene and scaled on its own
#       training frames, must beat the rule and the commonest type each by a
#       sign test (taste.expo_beats), and is used only on the shoot that
#       taught it: a starting edit fitted under 3 is learned again.
#   5 - 2026-09-24: the starting edit's frame count is compared under one
#       rule, only what he exported teaching, for the candidate and the one
#       in use alike (edit_count): a starting edit checked under 4, against a
#       count made under the older rule, is learned again.
RULES_VERSION = 5


def _write_check(learner: str, ts: str, check: dict) -> None:
    d = _history(learner)
    d.mkdir(parents=True, exist_ok=True)
    write_json_atomic(d / f"{ts}.check.json", {**check, "rules": RULES_VERSION})


def check_is_stale(learner: str) -> bool:
    """Whether what the page says about this learner was decided under rules
    that are no longer the rules."""
    try:
        e = (manifest().get("learners") or {}).get(learner) or {}
    except Refused:
        return False
    ts = e.get("candidate") or e.get("live")
    if not ts:
        return False
    c = version_check(learner, ts) or {}
    return int(c.get("rules") or 1) < RULES_VERSION


def version_check(learner: str, ts: str) -> dict | None:
    p = _history(learner) / f"{ts}.check.json"
    try:
        return json.loads(p.read_text()) if p.exists() else None
    except (OSError, ValueError):
        return None


def _keep_whatever_is_there(m: dict, learner: str) -> None:
    """Before the live file is replaced or removed, make sure a copy of it is
    in history. It normally is - it was put there when it went live - but a
    file somebody dropped into the folder by hand is still his, and this is the
    one place that could lose it."""
    live = path(learner)
    if not live.exists():
        return
    try:
        model = json.loads(live.read_text())
    except (OSError, ValueError):
        keep = _history(learner) / f"{_stamp(learner)}.unreadable.json"
        keep.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(live, keep)
        return
    e = _entry(m, learner)
    for ts in e["versions"]:
        if version_model(learner, ts) == model:
            return
    ts = _write_version(learner, model, source="found in the folder")
    e["versions"][ts] = {"made": _now(), "source": "found in the folder", "data": {}}
    _note(e, "kept a version that was in the folder and not in the record", ts)


def _make_live(m: dict, learner: str, ts: str | None) -> None:
    """Point the live file at one version, or at none. Atomic, so a cull that
    starts while this happens reads one whole model or the other."""
    _writable()
    _keep_whatever_is_there(m, learner)
    e = _entry(m, learner)
    live = path(learner)
    if ts is None:
        live.unlink(missing_ok=True)
        e["live"] = None
        e["since"] = None
        return
    model = version_model(learner, ts)
    if model is None:
        raise Refused(f"the {learner} version {ts} is not in the folder any more, so it cannot be put back")
    write_atomic(live, json.dumps(model))
    e["live"] = ts
    e["since"] = datetime.now().strftime("%Y-%m-%d")
    e["stopped"] = False
    if ts not in e["chain"]:
        e["chain"].append(ts)
    else:
        e["chain"] = e["chain"][:e["chain"].index(ts) + 1]
    e["versions"].setdefault(ts, {})["was_live"] = True


def live_model(learner: str) -> dict | None:
    """The model the cull or the presets step should use, or None. None means
    nothing is in use - not that nothing is known."""
    p = path(learner)
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except (OSError, ValueError):
        return None


def live_version(learner: str) -> str | None:
    try:
        return _entry(manifest(), learner).get("live")
    except Refused:
        return None


def stamp() -> dict:
    """What a cull should record about the models it used, so its card can say
    what it was culled with months later."""
    out = {"at": datetime.now().strftime("%Y-%m-%d")}
    for name in LEARNERS:
        out[name] = live_version(name)
    return out


def describe(learner: str) -> str:
    """One sentence for a log: which version is in use, or why none is."""
    title = TITLES.get(learner, learner)
    try:
        e = _entry(manifest(), learner)
    except Refused as err:
        return f"{title}: not in use ({err})"
    if path(learner).exists() and live_model(learner) is None:
        return f"{title}: not in use (the file in the learned folder cannot be read)"
    if e.get("stopped"):
        return f"{title}: not in use (you stopped it)"
    if not e.get("live"):
        held = e.get("candidate")
        if held:
            return f"{title}: not in use (a version is waiting for the keeper check; ./pl learned)"
        return f"{title}: nothing learned yet"
    return f"{title}: the version learned {e['live'].split('-')[0]}, in use since {e.get('since')}"


# ----------------------------------------------------- reading the library

_EXPORTED: dict[str, set[str]] = {}


def shoot_meta(shoot: Path) -> dict:
    try:
        return json.loads((Path(shoot) / "shoot.json").read_text())
    except (OSError, ValueError):
        return {}


def cull_dir(shoot: Path) -> Path:
    """Where this shoot's cull.csv is: cull/ beside raw/, _cull/ on a flat
    shoot - but a cull.csv that is actually there wins over either rule, the
    way decision_path lets an existing file win. A delivered shoot whose RAWs
    have gone to iCloud has no raw/ folder left, and answering _cull/ for it
    dropped the whole shoot, and its 200 keepers, out of every check."""
    for c in (shoot / "cull", shoot / "_cull"):
        if (c / "cull.csv").exists():
            return c
    return shoot / "cull" if (shoot / "raw").is_dir() else shoot / "_cull"


def exported_frames(shoot: Path) -> set[str]:
    """The frames of this shoot he has exported, wherever he exports to, by
    stem."""
    key = str(shoot)
    if key in _EXPORTED:
        return _EXPORTED[key]
    import taste
    at = taste.exported_at()
    raw = shoot / "raw" if (shoot / "raw").is_dir() else shoot
    names = [r["file"] for r in _rows(cull_dir(shoot))]
    if not names:
        names = [p.name for p in raw.iterdir() if p.suffix.lower() in RAW_EXTS] if raw.is_dir() else []
    got = {Path(f).stem for f in names if taste.is_exported(raw / f, at)}
    _EXPORTED[key] = got
    return got


def exported_count(shoot: Path) -> int:
    """How many frames of this shoot he has exported, wherever he exports to."""
    return len(exported_frames(shoot))


# ------------------------------------------- what a shoot teaches as his
#
# "only train based on what i've exported. i tend to cull further during
# editing" - his answer, 2026-09-23, to whether Finish should teach from the
# 368 frames he kept on 2026-09-19 or the 356 he exported. What he keeps in
# Choose Keepers is where he starts editing, not what he chose: the twelve he
# kept and did not export are frames he threw out in PhotoLab.
#
# So every learner takes its examples of "his" from the frames he exported:
# the starting edit its edits, the tier order its keepers, the drop reasons
# the frames that are not a fault. Two things do not change, and must not:
#
#   - the answer key, selects.json. Finish records it exactly as before, and
#     the keeper check (ShootCheck, keeper_check) measures every candidate
#     against every frame in it - all 368, the twelve included. A frame he
#     kept and did not export is not a model's to hide, whatever it learned
#     from.
#   - which shoots teach (teaches): finished, or with frames exported.
#
# EXPORTS_KEPT is the exported set written down the moment he finishes a shoot
# (studio's /api/kind), so what the shoot teaches does not shrink to nothing
# the day its exports move out of the places exported() looks. It is written
# even when it is empty.
#
# A finished shoot also teaches the frames the learning store recorded as
# exported when it measured them (stored_exports), alongside whatever is found
# now or written down: the store is his record of exports that have since gone
# out of reach - 2026-09-16's 155 are in iCloud - and one export found today
# does not make the rest any less his. Never its
# keepers: the keepers are where he starts editing, not what he chose. With
# nothing found, written down or recorded, it teaches nothing.

EXPORTS_KEPT = "exported.json"


def recorded_exports(shoot: Path) -> set[str]:
    """The frames written down as exported when he finished this shoot."""
    try:
        got = json.loads(decision_path(cull_dir(shoot), EXPORTS_KEPT).read_text())
    except (OSError, ValueError):
        return set()
    return {Path(str(f)).stem for f in got} if isinstance(got, list) else set()


def recorded_keepers(shoot: Path) -> set[str]:
    """His answer key, by stem: what the keeper check measures against."""
    try:
        got = json.loads(decision_path(cull_dir(shoot), "selects.json").read_text())
    except (OSError, ValueError):
        return set()
    return {Path(str(f)).stem for f in got} if isinstance(got, list) else set()


def _mark_date(mark: object) -> float:
    """The date out of a store row's "size:date" mark of an export; 0 when
    there is none."""
    try:
        return float(str(mark or "").rsplit(":", 1)[1])
    except (IndexError, ValueError):
        return 0.0


def _theirs(key: str, shoot: str) -> bool:
    """Whether an export at this path can be this shoot's: one inside another
    shoot's own folder (its export/ or edit/) is that shoot's frame, whatever
    its number."""
    parts = Path(key).parts
    for i in range(len(parts) - 3):
        if parts[i] == "shoots" and parts[i + 2] in ("export", "edit"):
            return parts[i + 1] == shoot
    return True


def stored_exports(shoot: Path, table: dict[str, dict] | None = None) -> set[str]:
    """The frames of this shoot the learning store recorded as exported, by
    stem: its record of his exports as they were when they were on this Mac,
    which outlives them. `table` is measured_read("frame"), for a caller
    that has already read it.

    Two records say so. A finished frame's own row, measured as exported, or
    carrying the size and date of an export of it. And the skin readings, one
    for every export file the starting edit ever read, by the export's path
    and date - the only record of a shoot whose exports carry no edit of his
    in a sidecar. An export counts for a frame only inside the frame's own
    window (taste.export_counts): after the frame existed and before the
    camera took another frame with its number - it reuses its numbers every
    ten thousand frames. A row measured as exported is taken at its word,
    unless the export it was measured against is dated after that next frame."""
    import taste
    shoot = Path(shoot)
    if table is None:
        table, _ = measured_read("frame")
    skins, _ = measured_read("skin")
    stems = {Path(r["file"]).stem for r in _rows(cull_dir(shoot)) if r.get("file")}
    flagged: dict[str, float] = {}
    dates: dict[str, list[float]] = {}
    for r in table.values():
        if r.get("shoot") != shoot.name or not r.get("frame"):
            continue
        stem = Path(str(r["frame"])).stem
        stems.add(stem)
        when = _mark_date(r.get("export"))
        if r.get("exported"):
            flagged[stem] = max(flagged.get(stem, 0.0), when)
        elif when:
            dates.setdefault(stem, []).append(when)
    for r in skins.values():
        key = str(r.get("key") or "")
        stem = Path(key).name.split("_DxO")[0]
        when = _mark_date(r.get("mark"))
        if stem in stems and when and _theirs(key, shoot.name):
            dates.setdefault(stem, []).append(when)
    out: set[str] = set()
    for stem in set(flagged) | set(dates):
        # Where its RAW would be, for its number: frame_born finds the RAW
        # by number, whatever cull.csv called the frame.
        probe = shoot / "raw" / f"{stem}.raw"
        if stem in flagged:
            when = flagged[stem]
            born = taste.frame_born(probe)
            if not when or not born or when < taste.frame_until(probe, born):
                out.add(stem)
                continue
        if taste.export_counts(probe, dates.get(stem, [])):
            out.add(stem)
    return out


def taught(shoot: Path, exported: set[str] | None = None,
           table: dict[str, dict] | None = None) -> tuple[set[str], str]:
    """The frames this shoot teaches as his, by stem, and where they came from:
    "exported" - the ones he exported: found now, written down when he
    finished it, and, on a finished shoot, recorded by the learning store when
    it measured them - or "" when there are none. All three at once: an export
    found today does not make the ones that have since gone out of reach any
    less his, the way remember_exports' record only grows. Never his recorded
    keepers: those are the answer key, and he culls further in PhotoLab.
    `exported` is the caller's own reading of what is exported, when it has
    one; `table` as stored_exports takes it."""
    out = set(exported if exported is not None else exported_frames(shoot)) | recorded_exports(shoot)
    if shoot_meta(shoot).get("finished"):
        out |= stored_exports(shoot, table)
    return out, ("exported" if out else "")


def teaches(shoot: Path) -> bool:
    """Whether a shoot's decisions are settled enough to learn from: he marked
    it finished, or he has exported frames out of it. A shoot still being
    culled is a set of verdicts he has not finished making."""
    if shoot_meta(shoot).get("finished"):
        return True
    return exported_count(shoot) > 0


def _rows(cull: Path) -> list[dict]:
    p = Path(cull) / "cull.csv"
    if not p.exists():
        return []
    try:
        with p.open() as fh:
            return list(csv.DictReader(fh))
    except (OSError, ValueError):
        return []


def similar_vectors(cull: Path) -> dict[str, np.ndarray] | None:
    """The CLIP vector per frame the cull cached in cull/similar.npz, by stem.

    The cull measures these anyway; keeping them is what lets every shoot stay
    checkable for seconds' work after its RAWs and decodes are gone. A shoot
    without the file can still be checked for anything that only needs
    cull.csv, and the check names it where it cannot."""
    p = Path(cull) / "similar.npz"
    if not p.exists():
        return None
    try:
        z = np.load(p, allow_pickle=False)
    except (OSError, ValueError):
        return None
    names = next((z[k] for k in ("files", "file", "names", "stems") if k in z), None)
    vecs = next((z[k] for k in ("clip", "emb", "embs", "vectors") if k in z), None)
    if names is None or vecs is None or len(names) != len(vecs):
        return None
    V = np.asarray(vecs, dtype=np.float64)
    V = V / (np.linalg.norm(V, axis=1, keepdims=True) + 1e-9)
    return {Path(str(n)).stem: V[i] for i, n in enumerate(names)}


# ------------------------------------- the picture vectors, kept once
#
# The drop-reason learner and the keeper check both read one CLIP vector per
# frame. The cull caches them in cull/similar.npz - but six of his shoots were
# culled before it did, and for those the learner measures 805 vectors off the
# previews on every run while the check cannot run at all ("the cull kept no
# picture vectors for it, so a drop-reason model cannot be scored on it").
#
# The previews outlive the RAWs, so the vectors can be measured once and kept
# here beside the models. It is never done inside a learning run: it is minutes
# of picture model over thousands of frames, and a run he asked for must not
# quietly grow by that. `./pl learned vectors [shoot]` is how he asks.

def vectors_dir() -> Path:
    return folder() / "vectors"


def cached_vectors(shoot: str) -> dict[str, np.ndarray] | None:
    """The vectors kept here for one shoot, by stem, or None."""
    p = vectors_dir() / f"{shoot}.npz"
    if not p.exists():
        return None
    try:
        z = np.load(p, allow_pickle=False)
        names, V = z["stems"], np.asarray(z["clip"], dtype=np.float64)
    except (OSError, ValueError, KeyError):
        return None
    if len(names) != len(V):
        return None
    V = V / (np.linalg.norm(V, axis=1, keepdims=True) + 1e-9)
    return {str(n): V[i] for i, n in enumerate(names)}


def keep_vectors(shoot: str, got: dict[str, np.ndarray]) -> int:
    """Keep what has been measured, merged with what is already here. Whole
    file or nothing: a half-written cache would be read as a shoot whose frames
    are missing, which is how a check comes to say it covered a shoot it did
    not."""
    if not got:
        return 0
    have = cached_vectors(shoot) or {}
    have.update(got)
    stems = sorted(have)
    d = _writable() / "vectors"
    d.mkdir(exist_ok=True)
    # numpy puts ".npz" on the end of a name that has not got one, so the
    # temporary file ends in it and os.replace has something to move.
    tmp = d / f".{shoot}.writing.npz"
    np.savez_compressed(tmp, stems=np.array(stems), clip=np.array([have[s] for s in stems], dtype=np.float32))
    os.replace(tmp, d / f"{shoot}.npz")
    return len(stems)


def measure_vectors(shoot: Path, progress=None) -> dict:
    """Measure the picture vector of every frame of one shoot off its previews
    and keep it. What the cull would have cached had it been this version."""
    cull = cull_dir(shoot)
    prev = cull / "previews"
    rows = _rows(cull)
    stems = sorted({Path(r["file"]).stem for r in rows}) or sorted(p.stem for p in prev.glob("*.jpg"))
    have = {**(similar_vectors(cull) or {}), **(cached_vectors(shoot.name) or {})}
    todo = [s for s in stems if s not in have and (prev / f"{s}.jpg").exists()]
    out = {"shoot": shoot.name, "frames": len(stems), "measured": 0,
           "no_preview": [s for s in stems if s not in have and not (prev / f"{s}.jpg").exists()]}
    if todo:
        from quality import Quality
        q = Quality()
        if not q._load_clip():
            # Said as every other ending is said: the job prints this and
            # nothing else, and a Measure that ended in a KeyError traceback
            # told him nothing about the model it was missing.
            out["why"] = "the picture model is not here; ./pl fetch-clip"
            out["sentence"] = (f"{shoot.name}: nothing was measured. The cull's picture model is not on "
                               f"this Mac yet; download it in Settings ▸ Advanced, then press Measure again.")
            out["refused"] = True
            return out
        got: dict[str, np.ndarray] = {}
        step = 200
        for i in range(0, len(todo), step):
            chunk = todo[i:i + step]
            _, emb = q.aesthetic_batch([prev / f"{s}.jpg" for s in chunk])
            for s, v in zip(chunk, emb):
                got[s] = np.asarray(v, dtype=np.float64)
            if progress:
                progress("vectors", min(i + step, len(todo)), len(todo))
        out["measured"] = keep_vectors(shoot.name, got)
    out["covered"] = len({**have, **(cached_vectors(shoot.name) or {})}.keys() & set(stems))
    out["sentence"] = (f"{shoot.name}: nothing to measure; it has not been culled yet" if not stems else
                       f"{shoot.name}: {out['covered']} of {len(stems)} frames have a picture vector"
                       + (f"; {out['measured']} measured now" if out["measured"] else "")
                       + ("; a drop-reason model can be checked on it" if out["covered"] >= len(stems)
                          else "; it still cannot be checked"))
    return out


class ShootCheck:
    """One shoot with his verdicts on it, ready to be re-scored."""

    def __init__(self, folder: Path):
        import quality as q
        self.folder = folder
        self.name = folder.name
        self.cull = cull_dir(folder)
        self.rows = _rows(self.cull)
        self.why = ""
        self.keepers, self.found, self.missing = 0, [], []
        self.style, self.kpg, self.stacked = "normal", 1, False
        self.alive, self.ids = [], set()
        self._vectors: dict[str, np.ndarray] | None = None
        self._looked = False
        key = decision_path(self.cull, "selects.json")
        try:
            names = json.loads(key.read_text())
            if not isinstance(names, list):
                raise ValueError("expected a list of frames")
        except (OSError, ValueError) as e:
            self.why = f"the frames you kept cannot be read ({e})"
            return
        # By stem, never by file name. The lounge was culled from its decodes,
        # so its cull.csv names TSC04073.jpg where his key names TSC04073.ARW,
        # and a check that keys on the name sees 0 of its 25 keepers and
        # reports the shoot as safe.
        by_stem: dict[str, int] = {}
        for i, r in enumerate(self.rows):
            by_stem.setdefault(Path(r["file"]).stem, i)
        stems = [Path(f).stem for f in names]
        self.keepers = len(set(stems))
        self.found = sorted({by_stem[s] for s in stems if s in by_stem})
        self.missing = sorted({s for s in stems if s not in by_stem})
        meta = shoot_meta(folder)
        self.style = meta.get("style") or "normal"
        self.kpg = 2 if self.style == "action" else 1
        self.stacked = bool(self.rows) and "stack" in self.rows[0]
        self.alive = [i for i, r in enumerate(self.rows) if (r.get("rating") or "0") != "0"]
        self.ids = self._ids()
        if not self.rows:
            self.why = "it has no cull.csv to re-score"
        elif not self.found:
            self.why = "none of the frames you kept are in its cull.csv"
        elif self.missing:
            self.why = f"{len(self.missing)} of the {self.keepers} frames you kept are not in its cull.csv"
        else:
            missing_cols = [c for c in q.FEATURES if c != "flaw" and c not in self.rows[0]]
            if missing_cols:
                self.why = "its cull.csv was written before " + ", ".join(missing_cols) + " was measured"
            else:
                r = self._reproduced()
                if r < 0.999:
                    self.why = f"its own scores cannot be reproduced here (r {r:.3f}); the cull that wrote it scored differently"

    def _ids(self) -> set[str]:
        try:
            from library import legacy_shoot_id, shoot_id
            return {shoot_id(self.folder), legacy_shoot_id(self.folder)}
        except Exception:  # noqa: BLE001
            return set()

    def column(self, name: str) -> np.ndarray:
        return np.array([float(self.rows[i].get(name) or 0) for i in self.alive])

    def _reproduced(self) -> float:
        """How closely re-scoring cull.csv reproduces the score the cull wrote
        into it. Below 0.999 the shoot is refused rather than guessed at."""
        import quality as q
        if not self.alive:
            return 1.0
        feats = {n: self.column(n) for n in q.FEATURES}
        mine = q.combined_score(feats, q.DEFAULT_WEIGHTS)
        theirs = self.column("quality")
        if mine.std() < 1e-9 or theirs.std() < 1e-9:
            return 1.0
        return float(np.corrcoef(mine, theirs)[0, 1])

    def vectors(self) -> dict[str, np.ndarray] | None:
        """The cull's own cached vectors, else the ones he asked to have
        measured off this shoot's previews (`./pl learned vectors`). Both are
        one CLIP vector per frame in the same space; a shoot culled before the
        cull kept them is not a shoot whose photographs cannot be measured, it
        is one nobody had measured yet."""
        if not self._looked:
            self._vectors = similar_vectors(self.cull) or cached_vectors(self.name)
            self._looked = True
        return self._vectors

    def flaw(self, model: dict | None) -> tuple[np.ndarray | None, list[str]]:
        """This shoot's frames scored by one drop-reason model, and the reason
        each frame looks like where one passes 0.5. None when the vectors the
        model needs are not on this shoot."""
        n = len(self.rows)
        if not model or not model.get("reasons"):
            return np.zeros(n), [""] * n
        got = self.vectors()
        if got is None:
            return None, []
        stems = [Path(r["file"]).stem for r in self.rows]
        if any(s not in got for s in stems):
            return None, []
        import flaws
        E = np.array([got[s] for s in stems])
        p, names = flaws.score(E, model)
        return np.asarray(p, dtype=float), names


def shoots_with_verdicts(root: Path | None = None) -> list[ShootCheck]:
    """Every shoot that carries his keepers, in the order the library holds
    them. These are what every candidate is measured against."""
    base = Path(root or ROOT) / "shoots"
    out = []
    if not base.is_dir():
        return out
    for p in sorted(base.iterdir()):
        if not p.is_dir() or p.name.startswith("."):
            continue
        if not decision_path(cull_dir(p), "selects.json").exists():
            continue
        out.append(ShootCheck(p))
    return out


# ------------------------------------------------ replaying the cull's tiers
#
# The check never re-culls. It recomputes the cull's own ranking from cull.csv,
# swaps in the candidate's contribution, and deals the tiers out again the way
# cull.py does. What it must reproduce is where a frame ENDS UP: shown (a clear
# win or a maybe), folded (probably not), or out of sight (a duplicate, or a
# fault the cull refused). A learner can move a frame between those; it can
# never make one a fault, because a fault is a measured veto and no learner
# votes on it.

SHOWN, FOLDED, HIDDEN = 2, 1, 0
LEVEL_WORDS = {SHOWN: "shown", FOLDED: "folded away", HIDDEN: "out of sight"}
TIER_WORDS = {5: "clear win", 3: "maybe", 2: "probably not", 1: "duplicate", 0: "fault"}


def _scores(sd: ShootCheck, flaw: np.ndarray) -> dict[int, float]:
    import quality as q
    feats = {n: sd.column(n) for n in q.FEATURES}
    feats["flaw"] = np.array([flaw[i] for i in sd.alive])
    s = q.combined_score(feats, q.DEFAULT_WEIGHTS)
    return {i: float(s[k]) for k, i in enumerate(sd.alive)}


def _rank_scores(sd: ShootCheck, ranker: dict, score: dict[int, float]) -> dict[int, float]:
    """The venue ranker's order, over the same frames the cull ranks: its
    position in its burst is counted among the frames that survived, which is
    what cull.py hands it."""
    import taste
    by_burst: dict[str, list[int]] = {}
    for i in sd.alive:
        by_burst.setdefault(sd.rows[i].get("burst", ""), []).append(i)
    out = {}
    for fs in by_burst.values():
        fs.sort(key=lambda i: sd.rows[i].get("shot_at", ""))
        for k, i in enumerate(fs):
            row = dict(sd.rows[i], quality=score[i])
            out[i] = taste.rank_score(ranker, taste.rank_features(row, k / max(1, len(fs) - 1), len(fs)))
    return out


def _tiers(sd: ShootCheck, score: dict[int, float], ranker: dict | None = None) -> dict[int, int]:
    """Every frame's tier, dealt out the way cull.py deals them."""
    tier = {i: 0 for i in range(len(sd.rows)) if i not in sd.alive}
    if sd.stacked:
        # The cull that writes a `stack` column does not hide a frame for
        # looking like another one. keep_per_group frames of each stack are
        # tiered like any other frame and the rest wait under its top, set
        # aside - split by common.stack_tiers, the function the cull splits
        # with, over the candidate's own score. Tiering every member instead
        # replayed a cull with a shortlist a third longer than the real one.
        runs: dict[str, list[int]] = {}
        best = []
        for i in sd.alive:
            st = sd.rows[i].get("stack") or ""
            if st:
                runs.setdefault(st, []).append(i)
            else:
                best.append(i)
        tiered, under, _tops = stack_tiers(list(runs.values()), sd.kpg, lambda i: score[i])
        best += tiered
        for i in under:
            tier[i] = 2
    else:
        by_group: dict[str, list[int]] = {}
        for i in sd.alive:
            by_group.setdefault(sd.rows[i].get("group", ""), []).append(i)
        best = []
        for grp in by_group.values():
            ordered = sorted(grp, key=lambda i: score[i], reverse=True)
            best += ordered[:sd.kpg]
            for i in ordered[sd.kpg:]:
                tier[i] = 1
    order = _rank_scores(sd, ranker, score) if ranker else score
    # Dealt by the same function the cull deals with (common.deal_tiers), over
    # the frames in the order the cull hands it: best by the score first, so a
    # tie under the ranker falls the way it falls in cull.py. A replay that
    # dealt its own way would be a check of some other cull.
    best.sort(key=lambda i: score[i], reverse=True)
    by_burst: dict[str, list[int]] = {}
    for i in best:
        by_burst.setdefault(sd.rows[i].get("burst", ""), []).append(i)
    dealt, _across = deal_tiers(list(by_burst.values()), best, lambda i: order[i])
    tier.update(dealt)
    return tier


def _levels(sd: ShootCheck, tier: dict[int, int], score: dict[int, float]) -> dict[int, int]:
    """Where each frame ends up on the page: shown, folded away, or out of
    sight. On a cull that stacks, a frame under a stack's top is one key away
    rather than on the stage, so it counts as folded."""
    level = {i: (SHOWN if t >= 3 else FOLDED if t == 2 else HIDDEN) for i, t in tier.items()}
    if sd.stacked:
        by_stack: dict[str, list[int]] = {}
        for i in sd.alive:
            s = sd.rows[i].get("stack") or ""
            if s:
                by_stack.setdefault(s, []).append(i)
        for members in by_stack.values():
            top = max(members, key=lambda i: score[i])
            for i in members:
                if i != top:
                    level[i] = min(level[i], FOLDED)
    return level


def _why_moved(sd: ShootCheck, i: int, down: bool, names: list[str], kind: str) -> str:
    name = names[i] if names and i < len(names) else ""
    if kind == "drop-reasons" and down and name:
        return f"ranked lower: it looks like '{reason_word(name)}' to the new version"
    if kind == "drop-reasons":
        return "another frame of its group or burst now ranks above it" if down else "ranks higher under the new version"
    if down:
        return "the new burst order puts another frame above it"
    return "the new burst order puts it higher"


def _compare(sd: ShootCheck, before: dict[int, int], after: dict[int, int], tier_b: dict[int, int],
             tier_a: dict[int, int], names: list[str], kind: str) -> dict:
    moved, hidden, lifted, frames = 0, 0, 0, []
    for i in sd.found:
        b, a = before[i], after[i]
        if a == b:
            continue
        down = a < b
        if down:
            moved += 1
            if a == HIDDEN and b > HIDDEN:
                hidden += 1
        else:
            lifted += 1
        frames.append({"shoot": sd.name, "file": sd.rows[i]["file"], "stem": Path(sd.rows[i]["file"]).stem,
                       "burst": sd.rows[i].get("burst", ""), "scene": sd.rows[i].get("scene", ""),
                       "now": LEVEL_WORDS[b], "new": LEVEL_WORDS[a],
                       "tier_now": TIER_WORDS.get(tier_b[i], ""), "tier_new": TIER_WORDS.get(tier_a[i], ""),
                       "down": down, "why": _why_moved(sd, i, down, names, kind)})
    frames.sort(key=lambda f: (not f["down"], f["stem"]))
    return {"moved_down": moved, "hidden": hidden, "lifted": lifted, "frames": frames}


def _rankers_for(sd: ShootCheck, table: dict | None) -> dict[str, dict]:
    """The rankers in a table that could ever be used on this shoot: every
    venue's, except one learned from this shoot itself. A model is never
    scored against the frames it was learned from - on the shoot it came from
    the shipped ranker looks 11 keepers better, and on the next action shoot
    it folds 13."""
    out = {}
    for vid, e in ((table or {}).get("shoots") or {}).items():
        if vid in sd.ids or not (e or {}).get("ranker"):
            continue
        out[vid] = e
    return out


def keeper_check(shoots: list[ShootCheck], kind: str, flaw_live: dict | None = None, flaw_new: dict | None = None,
                 rank_live: dict | None = None, rank_new: dict | None = None) -> dict:
    """Score a candidate against every keeper of every shoot that has his
    verdicts, and say what it would move.

    The rule: it may go live only when no keeper of his drops out of sight on
    any shoot, when every shoot's keepers were all found, and when a shoot
    where keepers are folded away lifts at least as many back. Everything else
    is held, with the frames listed."""
    out = {"kind": kind, "at": _now(), "shoots": [], "couldnt_check": [],
           "keepers": 0, "checked": 0, "moved_down": 0, "hidden": 0, "lifted": 0}
    for sd in shoots:
        out["keepers"] += sd.keepers
        if sd.why:
            out["couldnt_check"].append({"shoot": sd.name, "keepers": sd.keepers, "why": sd.why})
            continue
        fl_b, _ = sd.flaw(flaw_live)
        fl_a, names = sd.flaw(flaw_new)
        # No stand-in for a missing picture vector. This used to fall back on
        # cull.csv's own flaw column whenever both sides carried the same
        # drop-reason model, on the reasoning that the column already said
        # what that model thought. It says what the model the CULL had
        # thought, and three of his shoots were culled by a build with none
        # (their column is zero on every frame) - so a replay from the column
        # is a replay of some other cull. Every shoot of his has its vectors
        # kept; one that does not is named, with the command that fixes it.
        if fl_b is None or fl_a is None:
            # Not a re-cull: the vectors are measured off the previews the
            # shoot already has, by the command named here.
            out["couldnt_check"].append({"shoot": sd.name, "keepers": sd.keepers,
                                         "why": "its frames have no picture vectors kept",
                                         "fix": f"{VECTORS_FIX} {sd.name}"})
            continue
        score_b, score_a = _scores(sd, fl_b), _scores(sd, fl_a)
        options = [("", None, None)]
        if kind == "tier-order":
            vids = set(_rankers_for(sd, rank_live)) | set(_rankers_for(sd, rank_new))
            options = [(((rank_new or {}).get("shoots", {}).get(v) or (rank_live or {}).get("shoots", {}).get(v) or {}).get("label", v),
                        ((rank_live or {}).get("shoots", {}).get(v) or {}).get("ranker"),
                        ((rank_new or {}).get("shoots", {}).get(v) or {}).get("ranker"))
                       for v in sorted(vids)]
            options = [o for o in options if o[1] is not None or o[2] is not None] or [("", None, None)]
        worst = None
        for label, r_b, r_a in options:
            tier_b = _tiers(sd, score_b, r_b)
            tier_a = _tiers(sd, score_a, r_a)
            cmp = _compare(sd, _levels(sd, tier_b, score_b), _levels(sd, tier_a, score_a), tier_b, tier_a, names, kind)
            cmp["option"] = label
            if worst is None or (cmp["hidden"], cmp["moved_down"] - cmp["lifted"]) > (worst["hidden"], worst["moved_down"] - worst["lifted"]):
                worst = cmp
        row = {"shoot": sd.name, "keepers": sd.keepers, "checked": len(sd.found), **worst}
        row["passed"] = row["hidden"] == 0 and row["lifted"] >= row["moved_down"]
        row["why"] = "" if row["passed"] else (
            f"{row['hidden']} of the photos you kept would drop out of sight" if row["hidden"] else
            f"{row['moved_down']} of the photos you kept would be folded away and only {row['lifted']} brought forward")
        out["shoots"].append(row)
        out["checked"] += row["checked"]
        for k in ("moved_down", "hidden", "lifted"):
            out[k] += row[k]
    out["passed"] = (bool(out["shoots"]) and not out["couldnt_check"]
                     and all(s["passed"] for s in out["shoots"]))
    out["sentence"] = _check_sentence(out)
    return out


VECTORS_FIX = "./pl learned vectors"


def _vector_shoots(check: dict | None) -> list[str]:
    """The shoots a check could not reach because their frames have no
    picture vectors kept - the one gap measuring can close."""
    return [str(c["shoot"]) for c in ((check or {}).get("couldnt_check") or [])
            if str(c.get("fix") or "").startswith(VECTORS_FIX) and c.get("shoot")]


def _check_do(*checks: dict | None) -> list[dict]:
    """What the page can put a button beside, for the checks a row shows: a
    shoot to measure the picture vectors of. Once each."""
    out: list[dict] = []
    for c in checks:
        for name in _vector_shoots(c):
            if not any(d["shoot"] == name for d in out):
                out.append({"shoot": name, "do": "vectors"})
    return out


def _said(check: dict) -> str:
    """A kept check's sentence in today's words: worked out again from the
    facts it kept, so a sentence written by an older build - one that ended in
    a command to type - is not what the page says. The facts are the check's
    own; nothing is measured again, and the check is as strict as it was.
    The sentence as it was kept, where the facts to say it again are not."""
    if check.get("kind") != "edit" and "shoots" in check and "couldnt_check" in check:
        try:
            return _check_sentence(check)
        except (KeyError, TypeError, ValueError, IndexError):
            pass
    return str(check.get("sentence") or "")


def _check_sentence(check: dict) -> str:
    """What the check found, in the words the panel and the terminal both use."""
    if check.get("kind") == "edit":
        return check.get("sentence", "")
    if not check["shoots"] and not check["couldnt_check"]:
        return "There are no shoots with photos you kept on them yet, so there is nothing to check it against."
    if check["couldnt_check"]:
        # One sentence for all of them. The panel drew this line and then the
        # same reason again under every shoot: seven copies of one fact, in
        # words naming a file he has never opened.
        # A shoot short of picture vectors is not a shoot to cull again: the
        # vectors are measured off its previews by one command, and a re-cull
        # is an evening's work that would not even be the fix.
        cc = check["couldnt_check"]
        vec = [c for c in cc if str(c.get("fix") or "").startswith("./pl learned vectors")]
        old = [c for c in cc if c not in vec]
        bits = []
        if vec:
            # Said without the command that does it: the app puts a Measure
            # button beside this line (`_check_do`), and the terminal prints
            # the command under it (`text`). The line ended in "./pl learned
            # vectors 2026-09-16 measures them", which he was to type.
            names = ", ".join(str(c["shoot"]) for c in vec)
            one = len(vec) == 1
            bits.append(f"{names} {'has' if one else 'have'} no picture vectors kept; measured off "
                        f"{'its' if one else 'their'} previews, {'it' if one else 'they'} can be checked")
        if old:
            n = len(old)
            bits.append(f"{old[0]['shoot']} was culled before the app kept what this needs; cull it again and it "
                        f"can be checked" if n == 1 else
                        f"{n} of your shoots were culled before the app kept what this needs; cull one of them "
                        f"again and it can be checked there")
        return "Not checked yet, so nothing has changed: " + "; and ".join(bits) + "."
    if check["passed"]:
        return (f"Checked on the {check['checked']} photos you kept: none hidden, "
                f"{check['moved_down']} moved down, {check['lifted']} moved up.")
    # The worst shoot first: the one that hides a photograph, if any does.
    bad = sorted((s for s in check["shoots"] if not s["passed"]),
                 key=lambda s: (-s["hidden"], -(s["moved_down"] - s["lifted"])))
    worst = bad[0]
    # The numbers here are every shoot's, because the button beside this line
    # opens every frame it is about: "See the 74" under a sentence about 21 on
    # one shoot is two different facts wearing one number.
    where = worst["shoot"] if len(bad) == 1 else f"{worst['shoot']} and {len(bad) - 1} more"
    if check["hidden"]:
        return (f"The new version would stop putting forward {check['hidden']} of the photos you kept "
                f"({where}).")
    return (f"It would show {check['moved_down']} of the photos you kept later in their burst "
            f"and {check['lifted']} earlier ({where}).")


# ------------------------------------------------- the check for the edit
#
# The starting edit cannot lose a keeper: it writes the first sidecar of a new
# shoot and never touches the cull or anything already exported. What it can do
# is become a worse starting point, and the three ways that has happened are
# learning from less than before (exports that moved out of reach), losing a
# venue whose frames can no longer be measured, and bringing a white balance
# that writes the wrong name on frames the one in use gets right.

def _check_wb(new: dict, now: dict, measured_here: bool) -> tuple[list[str], bool]:
    """Whether the candidate's white balance may replace the one in use.

    The white balance is the one thing the starting edit learns that reaches
    a sidecar, so this is where the gate does its work. Returns the reasons
    to hold it, and whether it was held for want of a measurement rather than
    on one.

    WHY THE COMPARISON CHANGED. The gate used to read the candidate's own
    reported accuracy against the one in use's and hold the candidate when it
    was 0.02 lower. Those two numbers come from two different exams: each was
    measured during that model's own fit, on that model's own frames, in that
    model's own scene folds. The model in use was fitted on 527 frames of
    which 62% came off a single shoot that is 99.7% one class; the candidate
    was fitted on 838, of which 674 carry a white balance decision. Their
    baselines - what always-AsShot alone scores - are 0.825 and 0.850, so the
    candidate's exam is if anything the EASIER one by that measure, and the
    headline gap of 0.920 against 0.889 is not the gap in skill: over its own
    baseline the model in use lifts 0.095 and the candidate 0.039. Neither
    number can be read against the other, in either direction, because the
    two were never asked the same questions.

    (An earlier draft of this docstring justified the change with 0.713
    against 0.620. Those are the two models' `exposure.always_commonest` -
    the retired exposure model's baseline, not the white balance's - and the
    claim they were always-AsShot was simply wrong.)

    So:

    1. THE FLOOR, from the candidate's own honest self-report. A model that
       does not beat leaving every frame as the camera shot it is not a model
       and cannot ship, whatever the one in use scores. It needs nothing but
       the candidate, which is why it is first.

       Honestly: taste.learn_wb cannot hand this clause a model to refuse. It
       measures the same two numbers and returns WITHOUT weights when the
       accuracy does not beat the baseline, so a model of that shape never
       gets a "w" to gate. The model that prompted this - his 2026-09-22
       20:48:06 refit, wb n=475, accuracy 0.886 against a baseline of 0.981 -
       came out of learn_wb with no weights at all and the OLD gate held it
       correctly, saying it would stop setting the white balance for you. The
       clause is kept anyway, and it is not decoration: a candidate can reach
       this function from a door that did no fitting (an import, a seed), and
       the fitter refusing its own bad models is the fitter's promise, not
       the gate's. A gate that only works while the thing it guards behaves
       is not a gate.

    2. WHERE IT SHIPS, per venue (taste.wb_where_used). Pooled numbers hide a
       venue: tonight's candidate is 0.889 against 0.850 over 674 frames and
       still worse than nothing on the one venue it had just learned to be
       consulted on. A venue it would be asked about and gets wrong is a
       photograph, so it is checked one venue at a time.

    3. AGAINST THE ONE IN USE, like for like (taste.wb_against_live). Both
       arms refitted, same frames, same folds, both held out by scene, only
       the training pool differing - see that function for why nothing
       simpler is honest. The 0.02 tolerance is kept, and only here does it
       mean anything, because only here are the two numbers from one exam.
       On his library it reads 0.922 for the candidate against 0.923 for the
       one in use over 548 frames in 37 folds, 8 frames one way and 7 the
       other: one frame of difference, and no evidence of a regression.

    AND THE DOOR ROUND THE BACK. Clauses 2 and 3 read fields that only
    taste.learn_edit attaches, because only it has the frames. A model that
    arrives any other way - import_taste, which seed_edit uses for
    PIPELINE_LEARNED_SEED, "the copy from a machine being replaced", and
    which `./pl learned import` uses - carries weights and neither field, and
    clause 1 cannot fire on it for the reason above. Left to those three
    clauses it would sail through unmeasured and start writing white balance
    names on his new shoots. So a candidate that would set a white balance
    and brings nothing measured on his photographs is held as unchecked, not
    passed: `measured_here` is the caller's word for whether this model was
    ever fitted and checked against his frames here.
    """
    used_now, used_new = "w" in now, "w" in new
    if used_now and not used_new:
        return ["it would stop setting the white balance for you, which the one in use does"], False
    if not used_new:
        return [], False
    out: list[str] = []
    acc, base = float(new.get("accuracy") or 0), float(new.get("always_asshot") or 0)
    if base and acc <= base:
        # Shares of frames, not bare decimals: 0.886 against 0.981 is 89 in
        # 100 against 98, and the second number is what doing nothing scores.
        out.append(f"it gets the white balance right on {round(acc * 100)} frames in 100 it had not seen, "
                   f"where leaving every frame as the camera shot it is right on {round(base * 100)}")
    # Measured on his photographs, or not measured at all. A refusal above is
    # a verdict and stands on its own; this is only for a model nothing has
    # been able to say anything about.
    if not out and not measured_here and not ({"where_used", "against_live"} & set(new)):
        # One clause and no full stop inside it: every reason here is joined
        # to the others with a semicolon and read as one sentence.
        return ([("it would set the white balance on your new shoots and nothing here has measured it against "
                  "your photographs yet: it was learned somewhere else, and the next learning run checks it")],
                True)
    for v in new.get("where_used") or []:
        if int(v.get("right") or 0) < int(v.get("asshot") or 0):
            # "that shoot's" is right for a venue taught by one shoot, which
            # every one of his is; a venue he has shot twice is "those shoots'".
            whose = "those shoots'" if len(v.get("shoots") or []) > 1 else "that shoot's"
            out.append(f"on \"{v['label']}\" it would set the white balance worse than leaving it alone: "
                       f"right on {v['right']} of {whose} {v['frames']} finished frames, where leaving "
                       f"every one as the camera shot it is right on {v['asshot']}")
    ag = new.get("against_live")
    if ag and float(ag.get("new") or 0) < float(ag.get("now") or 0) - 0.02:
        out.append(f"on the {ag['frames']} frames that taught the one in use, both asked only about scenes "
                   f"they had not seen, it gets the white balance right on {round(float(ag['new']) * 100)} "
                   f"frames in 100 against {round(float(ag['now']) * 100)} for the one in use")
    return out, False


def _check_exposure(new: dict, measured_here: bool) -> tuple[list[str], bool]:
    """Whether the candidate's per-venue exposure types may be used.

    A venue's own fit replaces the rule (presets.exposure_mode) on the shoot
    that taught it and nowhere else, so the question is asked venue by venue,
    against the same bar taste.venue_exposure decides by (taste.expo_beats):
    right on more of his finished frames, on scenes it had not seen, than
    the rule replayed on the same frames AND than the venue's commonest type,
    each by more than chance. One venue that does not clear it holds the
    whole candidate, and the reason names the shoot that taught that venue,
    because a label like "a finished shoot" is not something he can open.

    taste.venue_exposure only marks a venue `used` when it already clears
    the bar, so on a candidate this learner fitted here the clause should
    never fire. It is here for the same reason the white balance's floor is:
    a candidate can arrive through a door that did no fitting (an import, a
    seed, a hand-edited file). One that carries none of the counts has been
    measured against nothing: from outside, that waits for a run to measure
    it; fitted here, it is held, because a fit made here always carries them
    and one that does not is not what this learner wrote."""
    import taste
    out: list[str] = []
    unmeasured = False
    for vid, e in (((new.get("venues") or {}).get("shoots")) or {}).items():
        x = (e or {}).get("exposure") or {}
        if not x.get("used"):
            continue
        where = _venue_shoot_words(e, vid)
        ok, short = taste.expo_beats(x)
        if ok:
            continue
        if x.get("fit_right") is None or x.get("rule_right") is None or x.get("commonest_right") is None \
                or not x.get("vs"):
            if not measured_here:
                unmeasured = True
                continue
            out.append(f"on {where} it would choose the exposure type itself, and {short}")
            continue
        out.append(f"on {where} its own exposure type has not earned the place of the rule: of that shoot's "
                   f"{int(x.get('frames') or 0)} finished frames, on {taste.expo_held_words(x)} it had not "
                   f"seen, {short}")
    if unmeasured and not out:
        return (["it would choose the exposure type on a venue of yours and nothing here has measured it "
                 "against the rule on your photographs yet: the next learning run checks it"], True)
    return out, False


def _exposure_used_words(model: dict | None) -> str:
    """The clause that says where a starting edit chooses the exposure type
    itself, or '' where it chooses it nowhere. Said in the check's sentence
    when a candidate passes and on the in-use line for as long as it is in
    use: a change to what his sidecars say that the page did not mention
    would be a change he could not trace."""
    import taste
    own = []
    for vid, e in (((model or {}).get("venues") or {}).get("shoots") or {}).items():
        x = (e or {}).get("exposure") or {}
        if x.get("used"):
            own.append(f"{_venue_shoot_words(e, vid)} (right on {x.get('fit_right')} of {x.get('frames')} "
                       f"on {taste.expo_held_words(x)} it had not seen, where the rule is right on "
                       f"{x.get('rule_right')})")
    if not own:
        return ""
    return (f"It chooses the exposure type from that shoot's own finished frames on {'; '.join(own)}; "
            f"everywhere else, and on every new shoot, the rule decides.")


def _venue_shoot_words(entry: dict, vid: str) -> str:
    """A venue named by the shoot that taught it, with his label beside it
    when he gave one: '2026-09-05-the-gals ("portraits, two people, evening
    in town")'."""
    import taste
    names = [str(n) for n in ((entry or {}).get("shoots") or []) if str(n).strip()]
    label = str((entry or {}).get("label") or "").strip()
    if not names:
        return f'"{taste.venue_words(entry or {}, vid)}"'
    shoot = names[0] if len(names) == 1 else " and ".join((", ".join(names[:-1]), names[-1]))
    return f'{shoot} ("{label}")' if label and label != taste.UNNAMED_VENUE else shoot


# ------------------------------------------- how many frames taught it, today
#
# "only train based on what i've exported" made every new starting edit count
# only the frames he exported, and the one in use went on counting what taught
# it when every finished frame of a finished shoot did: 436 against 527, and
# every new version held on the count alone. His decision, 2026-09-24: count
# the one in use by the same rule, so a candidate is compared like with like.
#
# So both counts are made here, by the rule a new starting edit is fitted by
# (taste.teaching_rows over the learning store), from what each version kept
# of where its frames came from:
#
#   "frames"      the frames it was fitted on, by name (a version learned from
#                 now on keeps them): each is asked again, and the count is
#                 exact.
#   "shoots"      only how many came off each shoot, or off each kind of light
#                 its shoot is known by (every version before this, and the
#                 one that came with the app). Which frames of a shoot they
#                 were is not known, so the count is a bound, and always the
#                 strict one: the one in use at the most it could be (a
#                 shoot's share capped at what that shoot teaches today), the
#                 version weighed against it at the least (a shoot's share
#                 less every measured frame of it that does not teach).
#   "as learned"  nothing that says where its frames came from: its own count
#                 stands, as strict as it always was. When it is the version
#                 weighed against the one in use that cannot be counted again,
#                 the one in use is not counted again either, and the two are
#                 compared as they were learned - the rule before this one.
#
# A kind of light carried over from the version before, kept as it was learned
# because none of its frames could be measured, is not among the frames that
# version counted, and is not counted here. Frames nothing accounts for - a
# shoot the store has never measured, a frame on no kind of light - are counted
# as they were for the one in use and not at all for the version weighed
# against it. A shoot he took out of the measurements teaches nothing. No
# count is ever above the version's own.
#
# Reading any of this can fail - the store, a shoot's folder, the exports.
# That never fails the check, which a finished learning run is waiting on: the
# count falls back to each version's own, and the sentence says why. Only the
# count moves; the white balance, the exposure type and the keeper check are
# exactly as they were.

def frames_by_shoot(rows) -> dict[str, list[str]]:
    """Store rows as the frames of each shoot, by the file name the store
    keeps them under: what a starting edit keeps of the frames it was fitted
    on (`taught_frames`), and what taught_now answers with."""
    out: dict[str, set[str]] = {}
    for r in rows:
        shoot, frame = str(r.get("shoot") or ""), str(r.get("frame") or "")
        if shoot and frame:
            out.setdefault(shoot, set()).add(frame)
    return {s: sorted(f) for s, f in sorted(out.items())}


def taught_now(root: Path | None = None) -> dict[str, set[str]]:
    """What teaches a new starting edit today, shoot by shoot: every shoot the
    learning store has measured, with the frames of it teaching_rows keeps -
    the frames he exported - and every shoot he took out of the measurements,
    with none."""
    import taste
    base = Path(root or ROOT) / "shoots"
    table, _ = measured_read("frame")
    here = {p.name for p in base.iterdir() if p.is_dir()} if base.is_dir() else set()
    rows, _ = taste.teaching_rows(table, here, base)
    out: dict[str, set[str]] = {str(r.get("shoot") or ""): set() for r in table.values()}
    for shoot in dropped_shoots():
        out.setdefault(shoot, set())
    for shoot, frames in frames_by_shoot(rows.values()).items():
        out[shoot] = set(frames)
    out.pop("", None)
    return out


def measured_by_shoot() -> dict[str, set[str]]:
    """Every frame the learning store has measured, shoot by shoot, whether it
    teaches or not: what a shoot's share of a version was drawn from."""
    table, _ = measured_read("frame")
    return {s: set(f) for s, f in frames_by_shoot(table.values()).items()}


def _shoots_by_venue(root: Path | None = None, names=()) -> dict[str, str]:
    """Venue id -> the shoot it belongs to: how the kinds of light of a
    version that kept no shoot names (the one that came with the app) are put
    back to the shoots that taught them.

    First from what is kept: `names`, the shoots the learning store has
    measured, each by the id it answered to before it carried one of its own
    - the hash of where it sits in the library, worked out from its name, so
    it holds after the folder has left this Mac. Then from the shoots that
    are here, by the id in their shoot.json. A folder that cannot be read is
    passed over."""
    import taste
    from library import legacy_shoot_id
    base = Path(root or ROOT) / "shoots"
    out: dict[str, str] = {}
    for name in sorted(str(n) for n in names if str(n).strip()):
        try:
            out.setdefault(legacy_shoot_id(base / name), name)
        except (OSError, ValueError, RuntimeError):
            continue
    try:
        folders = sorted(p for p in base.iterdir() if p.is_dir()) if base.is_dir() else []
    except OSError:
        folders = []
    for shoot in folders:
        try:
            for vid in taste.venue_ids(shoot):
                out.setdefault(vid, shoot.name)
        except (OSError, ValueError):
            continue
    return out


class Today:
    """What teaches a new starting edit today, read once for a check and only
    when a count needs it - or all at once with read(), before the manifest is
    locked, so the lock is not held while the library is read.

    Nothing here raises. What cannot be read answers None, `failed` says so,
    and edit_count falls back to the version's own count."""

    def __init__(self, taught=None, root: Path | None = None):
        # `taught` is taught_now's answer, or a callable that makes it: a
        # caller that already has it does not read the library twice.
        self.root = root
        self.failed = ""
        self._got: dict = {}
        self._make = {"taught": taught if callable(taught) else (lambda: taught_now(self.root)),
                      "measured": measured_by_shoot,
                      "venues": lambda: _shoots_by_venue(self.root, set(self.taught() or ()))}
        if taught is not None and not callable(taught):
            self._got["taught"] = taught

    def _ask(self, key: str):
        if key not in self._got:
            try:
                self._got[key] = self._make[key]()
            except Exception as e:  # noqa: BLE001 - a count that cannot be made is counted as learned
                self._got[key] = None
                self.failed = self.failed or f"{type(e).__name__}: {e}"
                print(f"  the starting edit's frame count could not be made again ({self.failed})", file=sys.stderr)
        return self._got[key]

    def taught(self) -> dict[str, set[str]] | None:
        return self._ask("taught")

    def measured(self) -> dict[str, set[str]] | None:
        return self._ask("measured")

    def venues(self) -> dict[str, str] | None:
        return self._ask("venues")

    def read(self) -> "Today":
        self.taught()
        self.measured()
        self.venues()
        return self


def edit_count(model: dict | None, now, least: bool = False) -> dict:
    """How many of the frames that taught this starting edit teach under
    today's rule, and how that was counted (the block above). `now` is
    taught_now's answer, a callable that returns it, or a Today; it is asked
    only when the version kept something to count by. `least` counts the
    version weighed against the one in use: where a count can only be bounded,
    the least it could be.

    {"frames": the count compared, "as_learned": its own count, "how": ...,
     "bound": "most" or "least" when counted shoot by shoot, "unread": True
     when what it needed could not be read}"""
    m = model or {}
    n = int(m.get("n") or 0)
    out = {"frames": n, "as_learned": n, "how": "as learned"}
    if not n:
        return out
    today = now if isinstance(now, Today) else Today(now)
    unread = {**out, "unread": True}
    listed = m.get("taught_frames")
    if isinstance(listed, dict) and listed:
        t = today.taught()
        if t is None:
            return unread
        got = 0
        for shoot, frames in listed.items():
            frames = [str(f) for f in (frames or [])]
            if shoot in t:
                got += sum(1 for f in frames if f in t[shoot])
            elif not least:
                got += len(frames)
        rest = 0 if least else max(0, n - sum(len(v or []) for v in listed.values()))
        return {**out, "frames": min(n, got + rest), "how": "frames"}
    groups: dict[tuple[str, ...], int] = {}
    shoots = ((m.get("dataset") or {}).get("shoots")) or []
    if shoots:
        pairs = [([str((e or {}).get("shoot") or "")], int((e or {}).get("frames") or 0)) for e in shoots]
    else:
        # A kind of light carried over from the version before is not among
        # the frames this one counted: 283 of its own, and the 198 and 328
        # it kept as they were are not in that 283.
        ven = {vid: e or {} for vid, e in (((m.get("venues") or {}).get("shoots")) or {}).items()
               if not (e or {}).get("carried")}
        named = {vid: [str(s) for s in (e.get("shoots") or []) if str(s).strip()] for vid, e in ven.items()}
        known = (today.venues() or {}) if any(not v for v in named.values()) else {}
        pairs = [(named[vid] or ([known[vid]] if vid in known else []), int(e.get("n") or 0))
                 for vid, e in ven.items()]
    for names, k in pairs:
        if names and all(names) and k > 0:
            key = tuple(sorted(set(names)))
            groups[key] = groups.get(key, 0) + k
    if not groups:
        return unread if today.failed else out
    t = today.taught()
    every = today.measured() if least else {}
    if t is None or every is None:
        return unread
    counted = still = 0
    for names, k in groups.items():
        if all(s in t for s in names):
            counted += k
            teach = sum(len(t[s]) for s in names)
            if least:
                seen = sum(len(every.get(s) or ()) for s in names)
                still += max(0, min(k, seen) - max(0, seen - teach))
            else:
                still += min(k, teach)
    if not counted:
        return unread if today.failed else out
    rest = 0 if least else max(0, n - counted)
    return {**out, "frames": min(n, still + rest), "how": "shoots", "bound": "least" if least else "most"}


def _bound(c: dict) -> str:
    return "at least" if c.get("bound") == "least" else "at most"


def _count_how(c: dict, who: str) -> str:
    """How one side's count was made, where it was not made frame by frame."""
    if c["how"] == "shoots":
        return (f"{who} kept no list of its own frames, so it was counted shoot by shoot: {_bound(c)} "
                f"{c['frames']} of its {c['as_learned']} are frames you exported")
    if c["how"] == "as learned" and c.get("unread"):
        return (f"what taught {who} could not be read just now, so its {c['as_learned']} could not be counted "
                f"again by what you exported")
    if c["how"] == "as learned":
        return (f"{who} kept no record of the shoots that taught it, so its {c['as_learned']} could not be "
                f"counted again by what you exported")
    return ""


def _count_words(new: dict, now: dict) -> str:
    """Both counts in brackets, and how each was made."""
    one_rule = new["how"] != "as learned" and now["how"] != "as learned"
    bits = [f"{new['frames']} against {now['frames']}" + (", counting only what you exported for both"
                                                          if one_rule else "")]
    if new["how"] == now["how"] == "shoots":
        bits.append(f"neither kept a list of its own frames, so both were counted shoot by shoot: {_bound(new)} "
                    f"{new['frames']} of this version's {new['as_learned']} and {_bound(now)} {now['frames']} of "
                    f"the one in use's {now['as_learned']} are frames you exported")
    elif new["how"] == "as learned" and (new.get("unread") or now.get("unread")):
        bits.append("what you exported could not be read just now, so both were counted as they were learned")
    elif new["how"] == "as learned" and now.get("matched"):
        bits.append("this version kept no record of the shoots that taught it, so both were counted as they "
                    "were learned")
    elif new["how"] != now["how"]:
        bits += [w for w in (_count_how(now, "the one in use"), _count_how(new, "this version")) if w]
    return "(" + "; ".join(bits) + ")"


def check_edit(candidate: dict, live: dict | None, measured_here: bool = False, today: Today | None = None) -> dict:
    """measured_here says this model has already been fitted and checked
    against his photographs on this Mac - it is a version out of this
    learner's own folder. It defaults to FALSE so that a door added later has
    to say so: the bypass this closes was a candidate arriving from outside
    and being judged as though it had been measured.

    `today` is what teaches today, for the frame count, when the caller has
    read it already (submit and back read it before they lock the manifest);
    without it the count reads it here, and only if it needs to."""
    live = live or {}
    why: list[str] = []
    n_new, n_live = int(candidate.get("n") or 0), int(live.get("n") or 0)
    ven_new = set(((candidate.get("venues") or {}).get("shoots") or {}))
    ven_live = set(((live.get("venues") or {}).get("shoots") or {}))
    # Every reason here is read by him, in a row about his photographs. A
    # number he cannot act on is not a reason, it is a measurement with its
    # units missing: this row once said "exposure type reads 0.519", which
    # told him neither what was wrong nor what to do about it.
    #
    # The two counts are made by one rule (edit_count), the library read once
    # for both and only when one of them kept something to count by: the one
    # in use at the most it could be, this version at the least. Where this
    # version cannot be counted again, neither is the one in use, and the two
    # are compared as they were learned, as strictly as before the rule
    # changed: one count made by today's rule against one made by the old
    # would not be like with like, and would favour this version.
    today = today or Today()
    if n_live:
        c_new = edit_count(candidate, today, least=True)
        c_live = edit_count(live, today)
        if c_new["how"] == "as learned" and c_live["how"] != "as learned":
            c_live = {"frames": n_live, "as_learned": n_live, "how": "as learned", "matched": True}
    else:
        c_new = {"frames": n_new, "as_learned": n_new, "how": "as learned"}
        c_live = {"frames": 0, "as_learned": 0, "how": "as learned"}
    k_new, k_live = c_new["frames"], c_live["frames"]
    one_rule = c_new["how"] != "as learned" and c_live["how"] != "as learned"
    if n_live and k_new < k_live:
        why.append(("it learned from fewer of the photographs you exported than the one in use " if one_rule else
                    "it saw fewer of your finished photographs than the one in use ") + _count_words(c_new, c_live))
    # Where a count was made again and did not hold it, the sentence still
    # says both numbers: the row above it says the one in use learned from
    # its own count, and the number it was compared on is not that one.
    counted = ""
    if n_live and k_new >= k_live and any(c["how"] != "as learned" and c["frames"] != c["as_learned"]
                                          for c in (c_new, c_live)):
        more = "more" if k_new > k_live else "as many"
        than = "than" if k_new > k_live else "as"
        counted = (f"It learned from {more} of the photographs you exported {than} the one in use " if one_rule else
                   f"It saw {more} of your finished photographs {than} the one in use ") + _count_words(c_new, c_live) + "."
    lost = ven_live - ven_new
    if lost:
        kinds = "one kind of light" if len(lost) == 1 else f"{len(lost)} kinds of light"
        why.append(f"it has forgotten {kinds} the one in use knows")
    wb_why, unchecked = _check_wb(candidate.get("wb") or {}, live.get("wb") or {}, measured_here)
    why += wb_why
    ex_why, ex_unchecked = _check_exposure(candidate, measured_here)
    why += ex_why
    unchecked = unchecked or ex_unchecked
    # frames_now and frames_new are the two counts compared, both by today's
    # rule; what each version counted when it was learned, and how the count
    # was made again, are kept beside them.
    out = {"kind": "edit", "at": _now(), "passed": not why, "why": why,
           "frames_now": k_live, "frames_new": k_new,
           "frames_now_as_learned": n_live, "frames_new_as_learned": n_new,
           "counted_now": c_live["how"], "counted_new": c_new["how"],
           "venues_now": len(ven_live), "venues_new": len(ven_new),
           "shoots": [], "couldnt_check": [], "keepers": 0, "checked": 0,
           "moved_down": 0, "hidden": 0, "lifted": 0}
    # Held for want of a measurement reads differently from held on one, and
    # the panel already knows the difference: submit() and back() turn a
    # non-empty couldnt_check into the state "couldnt_check", and the app's
    # row says "Not checked on: ..." under the sentence rather than treating
    # it as a verdict about his photographs.
    if unchecked:
        out["couldnt_check"] = [{"shoot": "the photographs you have finished", "keepers": 0,
                                 "why": "it was learned somewhere else and no run here has measured it yet"}]
    kinds = "one kind of light" if len(ven_new) == 1 else f"{len(ven_new)} kinds of light"
    # Where the version carries its own dataset, the row's first line already
    # says how many finished frames taught it and which shoots they were on, so
    # this says the thing that line does not: how many kinds of light are in
    # it. Two lines on one row must not spend both saying one number.
    passed = (f"It knows {kinds}." if candidate.get("dataset")
              else f"Learned from {n_new} finished frames, in {kinds}.")
    own = _exposure_used_words(candidate)
    if own:
        passed += " " + own
    # str.capitalize() lowercases everything after the first letter, and a
    # reason can now carry the name he gave a shoot: it turned "Emma and Tom,
    # the roof" into "emma and tom, the roof" in the one line he reads.
    held = "; ".join(why)
    out["sentence"] = ("Nothing learned from finished work yet." if not why and not n_new else
                       passed if not why else held[:1].upper() + held[1:] + ".")
    if counted:
        out["sentence"] += " " + counted
    return out


# --------------------------------------------------------- what to do next

def submit(learner: str, model: dict, source: str, data: dict | None = None,
           shoots: list[ShootCheck] | None = None) -> dict:
    """Take a newly trained model in as a candidate, check it, and either swap
    it in or hold it with the frames it would have moved."""
    if learner not in LEARNERS:
        raise Refused(f"{learner} is not one of {', '.join(LEARNERS)}")
    # What teaches today, for the starting edit's frame count: read before the
    # manifest is locked, so the lock is not held while the library is, and
    # only when there is a starting edit in use to count against.
    today = Today().read() if learner == "edit" and int((live_model("edit") or {}).get("n") or 0) else None
    with _locked():
        m = manifest()
        e = _entry(m, learner)
        live = live_model(learner)
        if live == model:
            e["training"] = data or {}
            _save(m)
            return {"learner": learner, "version": e.get("live"), "state": "in_use", "check": e.get("check"),
                    "sentence": f"{TITLES[learner]}: nothing new; what is in use already says this"}
        if learner == "edit":
            # No measured_here: a model coming in through the front door has
            # to carry its own measurements. taste.learn_edit attaches them;
            # import_taste cannot, and its model is held until a run measures
            # it, rather than being waved through on the strength of a
            # self-report made on somebody else's frames.
            check = check_edit(model, live, today=today)
        else:
            shoots = shoots if shoots is not None else shoots_with_verdicts()
            check = _check_for(learner, model, live, shoots)
        # Learning the same thing again is not a new version. Without this,
        # every run put another copy of an unchanged candidate in the folder
        # and the record of what changed when filled up with days on which
        # nothing did.
        same = e.get("candidate") if version_model(learner, e.get("candidate") or "") == model else None
        ts = same or _write_version(learner, model, source, data)
        e["versions"][ts] = {"made": e["versions"].get(ts, {}).get("made", _now()), "source": source, "data": data or {}}
        _write_check(learner, ts, check)
        e["training"] = data or {}
        e["check"] = _summary(check)
        if check["passed"]:
            _make_live(m, learner, ts)
            e["candidate"] = None
            e["state"] = "in_use"
            _note(e, f"in use ({source})", ts)
        else:
            e["candidate"] = ts
            e["state"] = "couldnt_check" if check.get("couldnt_check") else "held"
            _note(e, f"held ({check['sentence']})", ts)
        e["sentence"] = _sentence(learner, e, check)
        m["keepers"] = {"photos": check.get("keepers", 0),
                        "shoots": len(check.get("shoots", [])) + len(check.get("couldnt_check", [])),
                        "at": _now()} if learner != "edit" else m.get("keepers", {})
        _save(m)
        return {"learner": learner, "version": ts, "state": e["state"], "check": check,
                "sentence": f"{TITLES[learner]}: {e['sentence']}"}


def _check_for(learner: str, model: dict | None, live: dict | None, shoots: list[ShootCheck],
               today: Today | None = None) -> dict:
    """The check for a version already in this learner's folder: going back to
    one, stopping, or re-scoring what is held. Every model it is given was
    fitted here and went through the gate of its day, which is why the edit
    check is told measured_here - going back to a version he has used is his
    to do, and must not be refused for carrying no field that existed when it
    was made."""
    if learner == "drop-reasons":
        return keeper_check(shoots, "drop-reasons", flaw_live=live, flaw_new=model)
    if learner == "tier-order":
        context = live_model("drop-reasons")
        return keeper_check(shoots, "tier-order", flaw_live=context, flaw_new=context, rank_live=live, rank_new=model)
    return check_edit(model or {}, live, measured_here=True, today=today)


def _summary(check: dict) -> dict:
    return {k: check.get(k) for k in ("kind", "at", "passed", "keepers", "checked", "moved_down", "hidden",
                                      "lifted", "sentence", "why", "frames_now", "frames_new",
                                      "frames_now_as_learned", "frames_new_as_learned", "counted_now",
                                      "counted_new")
            if check.get(k) is not None}


def _plural(n: int, one: str, many: str | None = None) -> str:
    return f"{n} {one if n == 1 else (many or one + 's')}"


def _needs_parts(learner: str, training: dict) -> dict:
    """What this learner is short of before it can learn anything of his, as
    counts of what he would have to do - never a word like "insufficient".

    This is the opposite situation from a version held back: there, something
    was learned and the check found it would cost him photographs; here,
    nothing could be learned yet, and the remedy is more of his own evidence.
    The two used to read the same ("Not in use."), and they need opposite
    things from him.

    Said three ways from one set of facts, so they cannot disagree:
      sentence  one sentence, for the terminal and the record
      lines     the same, a fact to a line, for the page - the sentence ran to
                seven lines chained with semicolons and had to be read twice
      do        the shoots a line asks him to act on, and what to do there,
                so the page can put a button beside it rather than a command"""
    t = training or {}
    out: dict = {"sentence": "", "lines": [], "do": []}
    if learner == "drop-reasons":
        reasons = t.get("reasons") or {}
        if not reasons:
            out["sentence"] = ("Not enough yet to learn why you drop frames: say why when you drop one (press 1–6 "
                               "after D on Choose Keepers), on a shoot you then finish, and it learns from those.")
            out["lines"] = ["Not enough yet to learn why you drop frames.",
                            "Say why when you drop one — press 1–6 after D on Choose Keepers — on a shoot "
                            "you then finish."]
            return out
        need = int(t.get("min") or 12)
        bits, lines = [], []
        for label, e in sorted(reasons.items(), key=lambda kv: reason_word(kv[0])):
            r = reason_word(label)
            st, n = e.get("state"), int(e.get("examples") or 0)
            on = [str(x) for x in (e.get("on") or [])]
            if st == "too few":
                more = int(e.get('needs') or max(0, need - n))
                bits.append(f"{_plural(more, 'more frame')} dropped for {r} (it has {n} of the {need} it needs)")
                lines.append(f"{r.capitalize()}: {_plural(more, 'more drop')} ({n} of the {need} it needs).")
            elif st == "one shoot":
                where = f" on {on[0]}" if on else " on one shoot"
                bits.append(f"{r} has {n}, all{where}: at least 1 more dropped for {r} on another finished "
                            f"shoot lets it be checked across shoots")
                lines.append(f"{r.capitalize()}: 1 more drop on another finished shoot ({n} so far, all{where}).")
        if not bits:
            return out
        out["sentence"] = "Not enough yet to learn your own: " + "; ".join(bits) + "."
        out["lines"] = ["Not enough yet to learn your own:"] + lines
        return out
    if learner == "tier-order":
        per = t.get("shoots") or {}
        few = [(s, e) for s, e in sorted(per.items()) if e.get("state") == "too few of your keepers to learn from"]
        dark = [s for s, e in sorted(per.items()) if e.get("state") == "no light measured for it yet"]
        bits, lines = [], []
        if few:
            import taste
            # The count is of what the shoot teaches (`taught`): the frames he
            # exported, found now, written down at Finish or recorded by the
            # learning store, and never his keepers. A run recorded before
            # that was the rule says "recorded" - its keepers stood in - and
            # is said as what it counted.
            def mine(e: dict) -> str:
                return "you exported" if e.get("from") == "exported" else "of your keepers"
            bits.append(", ".join(f"{s} has {int(e.get('keepers') or 0)} {mine(e)}, "
                                  f"{max(0, taste.RANK_MIN_KEEPERS - int(e.get('keepers') or 0))} short of the "
                                  f"{taste.RANK_MIN_KEEPERS} it needs" if e.get("keepers") is not None else
                                  f"{s} has fewer than {taste.RANK_MIN_KEEPERS} {mine(e)}"
                                  for s, e in few))
            lines += [f"{s}: {int(e.get('keepers') or 0)} {mine(e)}, "
                      f"{max(0, taste.RANK_MIN_KEEPERS - int(e.get('keepers') or 0))} short of the "
                      f"{taste.RANK_MIN_KEEPERS} it needs." if e.get("keepers") is not None else
                      f"{s}: fewer than {taste.RANK_MIN_KEEPERS} {mine(e)}." for s, e in few]
        if dark:
            # What he can do about it, not what the engine lacks: an order is
            # tied to a shoot by the light the starting edit measured on the
            # frames he finished there, and these have none it has measured.
            one = len(dark) == 1
            bits.append(f"{', '.join(dark)} {'has' if one else 'have'} no frames you finished in PhotoLab that "
                        f"the starting edit has measured, and an order is tied to a shoot through that light; "
                        f"finish some of {'its' if one else 'their'} keepers and learn again, and "
                        f"{'it' if one else 'they'} can teach this")
            lines += [f"{s}: finish some of its keepers in PhotoLab, then learn again." for s in dark]
            lines.append("An order is tied to a shoot through the light measured on the frames you finished there.")
            out["do"] += [{"shoot": s, "do": "finish"} for s in dark]
        if not bits:
            out["sentence"] = "Not enough yet: it learns from a finished shoot with at least 30 photos you kept."
            out["lines"] = [out["sentence"]]
            return out
        out["sentence"] = "Not enough yet: " + "; ".join(bits) + "."
        out["lines"] = ["Not enough yet:"] + lines
        return out
    if t.get("note"):
        out["sentence"] = f"Not enough yet: {t['note']}."
    else:
        out["sentence"] = "Not enough yet: it learns from the sidecars of shoots you have finished."
    out["lines"] = [out["sentence"]]
    return out


def _seed_words(seed: Path) -> str:
    """What the bundled starting edit is, read rather than assumed: his own
    learned file travels inside his builds, and calling that "neutral" is the
    kind of thing that makes the panel lie."""
    try:
        frames, kinds = _edit_size(json.loads(Path(seed).read_text()))
    except (OSError, ValueError):
        return "the starting edit that ships with this"
    if frames or kinds:
        return f"the starting edit that ships with this copy ({frames} finished frames)"
    return "the neutral starting edit that ships with this"


def _edit_size(model: dict | None) -> tuple[int, int]:
    """How much a starting edit actually knows: finished frames, kinds of light."""
    m = model or {}
    return int(m.get("n") or 0), len(((m.get("venues") or {}).get("shoots") or {}))


# What the cull or the sidecar does when a learner has nothing in use, said on
# its row, so "Not in use" is never a sentence that stops before telling him
# what is happening instead.
INSTEAD = {"drop-reasons": "the cull ranks frames by its own built-in judgement of the picture alone",
           "tier-order": "each burst is ordered by the cull's own built-in judgement",
           "edit": "new shoots start from DxO's own camera-body rendering and what the sensor says"}


def _light_words(model: dict | None) -> str:
    """The kinds of light a starting edit knows, named by the shoots that
    taught them where it can: the one line on the page that says what is in
    use has to say it about HIS shoots."""
    import taste
    ven = ((model or {}).get("venues") or {}).get("shoots") or {}
    if not ven:
        return "no kind of light of its own"
    names = [taste.venue_words(e or {}, vid) for vid, e in ven.items()]
    kinds = "one kind of light" if len(ven) == 1 else f"{len(ven)} kinds of light"
    return f"{kinds} ({'; '.join(names)})" if len(names) <= 4 else kinds


def _in_use_line(learner: str, e: dict, check: dict | None) -> str:
    since = e.get("since")
    ov = e.get("overridden") or {}
    if ov.get("version") and ov.get("version") == e.get("live"):
        return f"In use since {since}, after you chose to use it with the frames in front of you."
    if learner == "edit":
        # What is IN it, not where it came from. A seeded model may be the
        # neutral one that ships with the code, or his own learned edit
        # carried into a build of his — and the page once said "Nothing
        # learned yet" over 527 finished frames and four kinds of light.
        live = live_model("edit")
        frames, _kinds = _edit_size(live)
        source = str(((e.get("versions") or {}).get(e.get("live")) or {}).get("source") or "")
        if not frames and not _kinds:
            return (f"In use since {since}, and it has learned nothing yet: {INSTEAD['edit']}, "
                    f"until you finish a shoot.")
        came = (" It came with this copy of the app rather than from a shoot you finished here."
                if source.startswith("seeded") else "")
        # Where it chooses the exposure type itself, for as long as it does:
        # the check said so once, on the day it passed, and a line that stops
        # saying it the day after leaves a change in his sidecars untraced.
        own = _exposure_used_words(live)
        return (f"In use since {since}. Learned from {frames} finished frames, in {_light_words(live)}.{came}"
                + (f" {own}" if own else ""))
    if check and check.get("kind") != "edit" and check.get("checked"):
        return f"In use since {since}. {_said(check)}"
    return f"In use since {since}."


def _candidate_line(learner: str, e: dict, check: dict | None) -> tuple[str, str]:
    """(state, sentence) for the version waiting beside the one in use - or
    beside nothing - when there is one. "held" is a verdict: it was learned,
    checked, and would cost him something, and the sentence says what.
    "couldnt_check" is a wait: nothing has been able to measure it yet."""
    ts = e.get("candidate")
    if not ts or e.get("stopped"):
        return "", ""
    v = (e.get("versions") or {}).get(ts) or {}
    data = v.get("data") or {}
    frm = ""
    if learner == "edit":
        ds = data.get("dataset") or {}
        if ds.get("frames"):
            shoots = len(ds.get("shoots") or [])
            frm = f", learned from {ds['frames']} finished frames on {_plural(shoots, 'shoot')},"
        elif data.get("frames"):
            frm = f", learned from {data['frames']} finished frames,"
    what = _version_words(str(v.get("source") or ""), bool(e.get("live")))
    if not check:
        return "couldnt_check", f"Waiting: {what}{frm} has not been checked against the photos you kept yet."
    said = _said(check).strip()
    # The check's own sentence says what it would do; "The new version" at its
    # head is the thing this line has just named.
    if said.startswith("The new version would"):
        said = "It would" + said[len("The new version would"):]
    if check.get("couldnt_check"):
        return "couldnt_check", f"Waiting: {what}{frm} has not been checked yet. {said}".strip()
    if check.get("passed"):
        return "", ""
    return "held", f"Held back: {what}{frm} is not used. {said}"


def _version_words(source: str, beside_live: bool) -> str:
    """Which version a held one is, in words about where it came from rather
    than a timestamp or a file name."""
    newer = "a newer version" if beside_live else "a version"
    if source.startswith("learned: "):
        when = source[len('learned: '):].strip()
        # A run asked for from the terminal records the command as its
        # reason; "learned when ./pl learned run" is not a sentence.
        if not when or when.startswith("./pl") or when == "asked for":
            return f"{newer} (learned when you asked it to learn)"
        return f"{newer} (learned when {when})"
    if source.startswith("seeded") or "came with the app" in source or "models/flaws.json" in source:
        return "the version that came with the app (from before it kept its own record)"
    if source.startswith("imported"):
        return f"the version {source}"
    return newer


def _lines(learner: str, e: dict, live_check: dict | None, cand_check: dict | None) -> dict:
    """Everything the page says about one learner, as the engine's own
    sentences, in three parts that answer three different questions:

      sentence            what is in use now, and what it was learned from
      candidate_sentence  what is waiting beside it, and why it waits
      needs_sentence      what it is short of, in things he could do

    The page said "Not in use" over a starting edit that WAS in use - a held
    candidate's state won over the version live beside it - and it said "Not
    in use" in the same words over a version held for doing harm and a
    learner that had never had enough to learn from. Those are three facts;
    each gets its own line."""
    out = {"state": "none", "sentence": "", "candidate_state": "", "candidate_sentence": "", "needs_sentence": "",
           "needs_lines": [], "needs_do": [], "check_do": _check_do(cand_check, live_check)}
    if e.get("stopped"):
        out.update(state="stopped", sentence="Not in use. You stopped it; everything it learned is kept.",
                   check_do=[])
        return out
    live = bool(e.get("live"))
    cstate, csent = _candidate_line(learner, e, cand_check)
    out["candidate_state"], out["candidate_sentence"] = cstate, csent
    if live:
        out["state"] = "in_use"
        out["sentence"] = _in_use_line(learner, e, live_check)
    elif cstate:
        out["state"] = "held" if cstate == "held" else "couldnt_check"
        out["sentence"] = f"Not in use: {INSTEAD[learner]}."
    else:
        out["state"] = "not_enough" if e.get("state") == "not_enough" else "none"
        out["sentence"] = f"Not in use: {INSTEAD[learner]}." if out["state"] == "not_enough" else "Nothing learned yet."
    if learner == "edit":
        # The one thing the starting edit is short of that he can supply: a
        # venue whose own exposure type beat its commonest type on scenes it
        # had not seen, but whose RAWs went to iCloud before the store kept
        # what the rule reads, so the fit cannot be checked against the rule
        # there and the rule stands.
        newest = version_model("edit", e["candidate"]) if e.get("candidate") else live_model("edit")
        # Whether the version carrying the fit is itself held for something
        # else: a pull cannot settle that, and the line must not promise it.
        also = cstate == "held" and bool(e.get("candidate"))
        owed = _exposure_owed(newest)
        if owed:
            parts = _exposure_owed_parts(newest)
            out["needs_sentence"] = owed
            out["needs_lines"], out["needs_do"] = parts["lines"], parts["do"]
            if also:
                # Said on the line it is about - the held version's - rather
                # than as the last clause of a seven-line paragraph about a
                # download, where "the reason above" was two paragraphs up.
                out["candidate_sentence"] += " Bringing photographs back does not settle this."
            return out
    if learner != "edit" or not live:
        parts = _needs_parts(learner, e.get("training") or {})
        need = parts["sentence"]
        # Only where it is true that more of his evidence is what is missing:
        # a learner with a fresh candidate of its own that simply failed the
        # check is not short of anything, and telling him to label more frames
        # would send him to fix the wrong thing.
        trained = (e.get("training") or {})
        short = (learner == "drop-reasons" and not any((r or {}).get("state") == "learned"
                                                       for r in (trained.get("reasons") or {}).values())) \
            or (learner == "tier-order" and any((s or {}).get("state") != "learned"
                                                for s in (trained.get("shoots") or {}).values())) \
            or out["state"] == "not_enough"
        if need and short and learner == "tier-order" and cstate and need.startswith("Not enough yet: "):
            # Beside a version that was learned and held, the shoots that
            # could not teach it are not "not enough" - something was learned
            # - they are the shoots it did not learn from, and why.
            need = "Not learned from: " + need[len("Not enough yet: "):]
            parts["lines"] = (["Not learned from:"] + parts["lines"][1:] if parts["lines"][:1] == ["Not enough yet:"]
                              else [need])
        if need and short:
            out["needs_sentence"] = need
            out["needs_lines"], out["needs_do"] = parts["lines"], parts["do"]
    return out


def _exposure_owed(model: dict | None) -> str:
    """What bringing a shoot's photographs back once would let the starting
    edit check, said as the command that does it.

    Raised only where it is worth his download: the venue's own fit beats
    its commonest type by more than chance (the same sign test the fit has
    to pass to be used), so the one thing between it and the check is the
    rule it cannot be replayed against. And said as what it is - the pull
    lets the next learning run check it; whether the version carrying it
    then goes into use is still that version's own check, which may be
    holding it for something else. That is said on the held version's own
    line (`_lines`), not here."""
    parts = _exposure_owed_parts(model)
    if not parts["sentence"]:
        return ""
    return parts["sentence"] + " Until it has been checked, the rule decides there."


def _exposure_owed_parts(model: dict | None) -> dict:
    """`_exposure_owed`'s facts: its sentence without the closing clause, the
    same said a fact to a line for the page, and the shoots to bring back -
    a button on the page, where the sentence names a command."""
    import taste
    bits, lines, do = [], [], []
    for vid, e in (((model or {}).get("venues") or {}).get("shoots") or {}).items():
        x = (e or {}).get("exposure") or {}
        if x.get("used") or not x.get("rule_unknown"):
            continue
        c = (x.get("vs") or {}).get("commonest") or {}
        if c.get("wins") is None or c.get("losses") is None \
                or int(x.get("fit_right") or 0) <= int(x.get("commonest_right") or 0) \
                or taste._sign_p(int(c["wins"]), int(c["losses"])) >= taste.EXPO_P:
            continue
        shoots = [str(n) for n in (e.get("shoots") or []) if str(n).strip()]
        pull = "; ".join(f"./pl archive pull {n} --apply" for n in shoots) or "bring its photographs back"
        where = _venue_shoot_words(e, vid)
        bits.append(f"on {where} its own exposure type is right on {x['fit_right']} of "
                    f"{x['frames']} finished frames on {taste.expo_held_words(x)} it had not seen, against "
                    f"{x['commonest_right']} for its commonest type, but it cannot be checked against the rule "
                    f"it would replace until the photographs of {x['rule_unknown']} of those frames are on this "
                    f"Mac once ({pull} brings them back from iCloud; then learn again)")
        lines += [f"On {where}, its own exposure type is right on {x['fit_right']} of {x['frames']} finished "
                  f"frames it had not seen; its commonest type, on {x['commonest_right']}.",
                  f"Bring back the photographs of {x['rule_unknown']} of those frames once, then learn again, "
                  f"and it can be checked against the rule it would replace."]
        do += [{"shoot": n, "do": "pull"} for n in shoots]
    if not bits:
        return {"sentence": "", "lines": [], "do": []}
    return {"sentence": "Waiting on you: " + "; ".join(bits) + ".",
            "lines": ["Waiting on you:"] + lines + ["Until then the rule decides there."], "do": do}


def _sentence(learner: str, e: dict, check: dict | None) -> str:
    """The row's lines joined, for the terminal and the record: what is in
    use, then what is waiting, then what it is short of."""
    live_check = version_check(learner, e["live"]) if e.get("live") else None
    cand_check = check if e.get("candidate") else None
    if e.get("candidate") and cand_check is None:
        cand_check = version_check(learner, e["candidate"])
    L = _lines(learner, e, live_check, cand_check)
    return " ".join(x for x in (L["sentence"], L["candidate_sentence"], L["needs_sentence"]) if x)


def back(learner: str, shoots: list[ShootCheck] | None = None) -> dict:
    """Go back to the version before the one in use, and put the one he is
    leaving where he can pick it up again.

    It goes through the same keeper check, so going back cannot quietly cost a
    keeper either - except back to no model at all, which is his to do the same
    way stopping is, and which says what it changes rather than refusing.

    On a learner he has stopped, the version before is the one that was in use
    when he stopped it: this is how "stop using this" is undone."""
    today = Today().read() if learner == "edit" else None
    with _locked():
        m = manifest()
        e = _entry(m, learner)
        chain = list(e.get("chain") or [])
        if not chain:
            raise Refused(f"{TITLES.get(learner, learner)} has no version to go back to")
        was = e.get("live")
        if was:
            chain = chain[:-1] if chain[-1] == was else chain
            prev = chain[-1] if chain else None
        else:
            prev = chain[-1]              # stopped, or gone back past everything: turn it on again
        model = version_model(learner, prev) if prev else None
        if prev and model is None:
            raise Refused("the version before is not in the folder any more, so it cannot be put back")
        shoots = shoots if shoots is not None else (shoots_with_verdicts() if learner != "edit" else [])
        check = _check_for(learner, model, live_model(learner), shoots, today=today)
        if not check["passed"] and prev:
            e["candidate"] = prev
            e["state"] = "couldnt_check" if check.get("couldnt_check") else "held"
            e["check"] = _summary(check)
            _write_check(learner, prev, check)
            e["sentence"] = _sentence(learner, e, check)
            _note(e, f"going back was held ({check['sentence']})", prev)
            _save(m)
            return {"learner": learner, "state": e["state"], "version": prev, "check": check,
                    "sentence": f"Going back would change what you see. {check['sentence']} Nothing changed."}
        e["chain"] = chain
        _make_live(m, learner, prev)
        e["state"] = "in_use" if prev else "none"
        e["check"] = _summary(check)
        # The version he just left is kept in front of him, with what using it
        # again would do, so nothing he has learned disappears off the panel.
        e["candidate"] = was if was and was != prev else None
        if e["candidate"]:
            _write_check(learner, was, _check_for(learner, version_model(learner, was), model, shoots, today=today))
        e["sentence"] = _sentence(learner, e, check)
        _note(e, "went back to the version before", prev)
        _save(m)
        said = (f"{TITLES[learner]}: back to the version from {prev.split('-')[0]}." if prev
                else f"{TITLES[learner]}: back to nothing learned.")
        # Going back to nothing is always his to do, and it still changes what
        # the cull shows: what it changes is said here rather than found later.
        return {"learner": learner, "state": e["state"], "version": prev, "check": check,
                "sentence": said if check["passed"] else f"{said} {check['sentence']}"}


def stop(learner: str, shoots: list[ShootCheck] | None = None) -> dict:
    """Stop using a learner. Every version it ever had stays in the folder, so
    this is a switch and not a delete, and the version it was using stays on
    the panel with what turning it back on would do."""
    with _locked():
        m = manifest()
        e = _entry(m, learner)
        was = e.get("live")
        _make_live(m, learner, None)
        e["stopped"] = True
        e["state"] = "stopped"
        if was:
            e["candidate"] = was
            shoots = shoots if shoots is not None else (shoots_with_verdicts() if learner != "edit" else [])
            _write_check(learner, was, _check_for(learner, version_model(learner, was), None, shoots))
        e["sentence"] = _sentence(learner, e, None)
        _note(e, "stopped", was)
        _save(m)
        return {"learner": learner, "state": "stopped", "version": was, "sentence": e["sentence"]}


def use_anyway(learner: str, version: str, shoots: list[ShootCheck] | None = None) -> dict:
    """Use a held version even though the check held it. The version has to be
    named, and it is the one the frames he has just looked at belong to: this
    is the one override in the whole business and it is only his to make with
    the photographs in front of him."""
    with _locked():
        m = manifest()
        e = _entry(m, learner)
        if e.get("candidate") != version:
            raise Refused("that is not the version being held now; open what it would move and try again")
        if version_model(learner, version) is None:
            raise Refused("that version is not in the folder any more")
        _make_live(m, learner, version)
        e["candidate"] = None
        e["state"] = "in_use"
        e["overridden"] = {"at": _now(), "version": version}
        check = version_check(learner, version)
        e["sentence"] = f"In use since {e.get('since')}, after you chose to use it with the frames in front of you."
        _note(e, "used anyway, after seeing the frames", version)
        _save(m)
        return {"learner": learner, "state": "in_use", "version": version, "check": check, "sentence": e["sentence"]}


# ------------------------------------------------------------- first use
#
# Nothing that was in use before is dropped in silence. The starting edit baked
# into older builds and the drop-reason model in models/flaws.json are taken in
# here: the edit as it was (it was in use, and it is his), the drop-reason
# model as a candidate, because it has never been scored against his keepers
# and the check says it would hide 12 of them.

def _split_taste(model: dict) -> tuple[dict, dict | None]:
    """An older taste.json, split into the starting edit and the tier order
    that was hiding inside it. They are two different things: one writes
    sidecars, the other changes what the cull shows."""
    edit = json.loads(json.dumps(model))
    ven = (edit.get("venues") or {})
    table = {"features": ven.get("features"), "mu": ven.get("mu"), "sd": ven.get("sd"), "shoots": {}}
    for vid, e in (ven.get("shoots") or {}).items():
        r = e.pop("ranker", None)
        if r:
            table["shoots"][vid] = {"label": e.get("label", vid), "centre": e.get("centre"),
                                    "spread": e.get("spread"), "ranker": r}
    return edit, (table if table["shoots"] else None)


def import_taste(file: Path, source: str | None = None, check_now: bool = True) -> list[dict]:
    """Take in a starting edit learned by an older build (pipeline/taste.json,
    or the copy from a machine being replaced)."""
    file = Path(file)
    try:
        model = json.loads(file.read_text())
    except (OSError, ValueError) as e:
        raise Refused(f"{file} cannot be read as a learned starting edit ({e})") from e
    if not isinstance(model, dict) or not ({"numeric", "venues", "vocab"} & set(model)):
        raise Refused(f"{file} does not look like a starting edit this understands")
    edit, table = _split_taste(model)
    src = source or f"imported from {file.name}"
    out = [submit("edit", edit, source=src)]
    if table:
        if check_now:
            out.append(submit("tier-order", table, source=src))
        else:
            with _locked():
                m = manifest()
                e = _entry(m, "tier-order")
                ts = _write_version("tier-order", table, src)
                e["versions"][ts] = {"made": _now(), "source": src, "data": {}}
                e["candidate"] = ts
                e["state"] = "held"
                e["sentence"] = ("Not in use. It came with your starting edit and has not been checked "
                                 "against the photos you kept yet.")
                _note(e, "taken in, waiting for the keeper check", ts)
                _save(m)
                out.append({"learner": "tier-order", "state": "held", "version": ts, "sentence": e["sentence"]})
    return out


def seed_edit() -> Path:
    """The starting edit file to read, seeding it on first use.

    A checkout and the app both ship a neutral seed inside them (no venues, no
    ranker, so DxO's own camera-body rendering); PIPELINE_LEARNED_SEED points
    at a starting edit to begin from instead. A learner he has stopped is not
    seeded again: it reads the neutral seed for as long as it is off."""
    p = path("edit")
    if p.exists():
        return p
    try:
        m = manifest()
        e = m["learners"].get("edit") or {}
    except Refused:
        return SEED
    if e.get("stopped") or e.get("chain"):
        return SEED                 # he stopped it, or went back past everything
    src = os.environ.get("PIPELINE_LEARNED_SEED")
    seed = Path(src).expanduser() if src else SEED
    try:
        seeded_from = seed.name if src else _seed_words(seed)
        import_taste(seed, source=("seeded from " + seeded_from),
                     check_now=False)
    except (Refused, OSError):
        return SEED
    return p if p.exists() else SEED


def take_in_what_was_in_use() -> list[str]:
    """The models older builds used, taken in as candidates so the keeper check
    has its say before they are used again. Runs once; after that the folder's
    own record is what counts."""
    said = []
    m = manifest()
    e = m["learners"].get("drop-reasons") or {}
    if not e.get("versions") and LEGACY_FLAWS.exists():
        try:
            model = json.loads(LEGACY_FLAWS.read_text())
        except (OSError, ValueError):
            model = None
        if model and model.get("reasons"):
            with _locked():
                m = manifest()
                ent = _entry(m, "drop-reasons")
                ts = _write_version("drop-reasons", model, "the version that came with the app")
                ent["versions"][ts] = {"made": _now(), "source": "the version that came with the app", "data": {}}
                ent["candidate"] = ts
                ent["state"] = "held"
                _note(ent, "taken in from models/flaws.json, waiting for the keeper check", ts)
                _save(m)
            said.append(f"took in the drop-reason model from {LEGACY_FLAWS} as a candidate")
    return said


# ----------------------------------------------------------- the learners

def edit_data(model: dict) -> dict:
    """What the panel says a starting edit was learned from: how many finished
    frames, the kinds of light in his own words (a venue's label is the one he
    gave its shoot), and the dataset behind it - which shoots taught it, how
    many of those frames were measured on this run, and how many came off
    shoots whose photographs are no longer on this Mac.

    That last part is the answer to "how did it have less than it started
    with", and it is recorded with the version so the answer is still there
    months later, not worked out afresh from a library that has moved on."""
    ven = ((model or {}).get("venues") or {}).get("shoots") or {}
    out = {"frames": int(model.get("n") or 0), "venues": len(ven),
           "venue_labels": [str(e.get("label") or vid) for vid, e in ven.items()],
           "carried": [str(e.get("label") or vid) for vid, e in ven.items() if e.get("carried")]}
    ds = (model or {}).get("dataset")
    if ds:
        out["dataset"] = ds
    return out


def _newest_light() -> dict | None:
    """The newest measurement of the light of his venues: the starting edit
    waiting beside the one in use when there is one, else the one in use.

    The tier order takes only the GEOMETRY from it - where each venue sits and
    how far its frames spread - to know which shoot a ranker belongs to. It
    used to take it from the starting edit in use and nothing else, and so
    could not learn an order for any shoot the starting edit in use had never
    seen: while the newer starting edit was held for its white balance on
    2026-09-21, 2026-09-19 and 2026-09-21 could not teach the tier order at
    all, and learning again could not change that. One learner's verdict on a
    white balance is no reason for another to stop learning; the tier order
    still has to pass its own keeper check before the cull uses it."""
    try:
        e = _entry(manifest(), "edit")
    except Refused:
        return live_model("edit")
    if e.get("candidate") and not e.get("stopped"):
        got = version_model("edit", e["candidate"])
        if got and ((got.get("venues") or {}).get("shoots")):
            return got
    return live_model("edit")


def train_tier_order(edit_model: dict | None, root: Path | None = None) -> tuple[dict | None, dict]:
    """Which frames of a burst he keeps, learned per venue from that venue's
    own finished shoot: cull.csv, and the frames he kept.

    The light a venue is recognised by is measured by the starting edit's
    learner, so the geometry is copied from it here and kept in this file: a
    tier order that had to read the starting edit to know where it applies
    would stop working the day he turned the starting edit off."""
    import taste
    base = Path(root or ROOT) / "shoots"
    ven = ((edit_model or {}).get("venues") or {})
    known = ven.get("shoots") or {}
    table = {"features": ven.get("features"), "mu": ven.get("mu"), "sd": ven.get("sd"), "shoots": {}}
    report: dict = {"shoots": {}}
    if not base.is_dir():
        return None, report
    for shoot in sorted(p for p in base.iterdir() if p.is_dir()):
        if not teaches(shoot):
            continue
        ids = set()
        try:
            from library import legacy_shoot_id, shoot_id
            ids = {shoot_id(shoot), legacy_shoot_id(shoot)}
        except Exception:  # noqa: BLE001
            pass
        vid = next((v for v in ids if v in known), None)
        if vid is None:
            report["shoots"][shoot.name] = {"state": "no light measured for it yet"}
            continue
        # The frames he exported, not every one he kept (`taught`): the
        # ones he kept and threw out in PhotoLab are not the frames of a
        # burst he keeps. The check the order then has to pass still counts
        # every keeper he recorded.
        mine, came_from = taught(shoot)
        r = taste.learn_ranker(shoot, quality=_replayed_quality(shoot), kept=mine)
        if r is None:
            report["shoots"][shoot.name] = {"state": "too few of your keepers to learn from",
                                            "keepers": len(mine), "from": came_from}
            continue
        report["shoots"][shoot.name] = {"state": "learned" if r["auc"] >= taste.RANK_MIN_AUC else "no better than chance",
                                        "auc": r["auc"], "keepers": r["n_kept"], "frames": r["n"], "from": came_from}
        if r["auc"] < taste.RANK_MIN_AUC:
            continue
        e = known[vid]
        # Carried key by key, so a key added to a venue does not silently stop
        # existing here: the cull names this venue out loud ("this shoot
        # measures like a finished venue (X)") and taste.venue_words needs the
        # shoot to put in X when he never labelled the place. `shoot` is that
        # shoot - vid was matched from its own ids - so an edit model older
        # than the record still names something he can open.
        table["shoots"][vid] = {"label": e.get("label", vid), "centre": e.get("centre"), "spread": e.get("spread"),
                                "shoots": e.get("shoots") or [shoot.name], "ranker": r}
    return (table if table["shoots"] else None), report


def _replayed_quality(shoot: Path) -> dict[str, float] | None:
    """Every frame's picture score on a finished shoot, as the cull would work
    it out today: cull.csv's own measurements, with the drop-reason score of
    the model in use now (from the picture vectors kept for the shoot) in
    place of the one written into the file.

    WHY. The tier order ranks on the cull's `quality` column, and that column
    carries -0.25 x the drop-reason score of whatever model the cull that
    wrote it happened to have. Three of his shoots (2026-09-16, 2026-09-19,
    2026-09-21) were culled by the installed app, whose bundle carried no
    drop-reason model, so their `flaw` column is exactly zero on every frame;
    the three before were culled from a checkout that read models/flaws.json,
    so theirs is not. A ranker fitted on the file's column learns a picture
    score whose meaning depends on which build culled the shoot, and is then
    served - by the keeper check (_scores) and by the next cull - a score
    worked out under the model in use NOW. Replaying the score here makes
    training, check and use read one number.

    Nothing needs re-culling for this: every shoot of his has its picture
    vectors kept (`./pl learned vectors`). None when the file is too old to
    replay (the check refuses such a shoot too) or the vectors the model in
    use needs are missing - the ranker then learns from the file's column as
    it always did, and ShootCheck says why that shoot cannot be checked."""
    try:
        sd = ShootCheck(shoot)
    except Exception:  # noqa: BLE001
        return None
    import quality as q
    if not sd.rows or not sd.alive or any(c not in sd.rows[0] for c in q.FEATURES if c != "flaw"):
        return None
    fl, _ = sd.flaw(live_model("drop-reasons"))
    if fl is None:
        return None
    return {Path(sd.rows[i]["file"]).stem: v for i, v in _scores(sd, fl).items()}


def tier_order_table() -> dict | None:
    """The venue table the cull looks a ranker up in. None when nothing is in
    use, which is what the cull should treat as "rank by the score"."""
    return live_model("tier-order")


# ------------------------------------------------------------ one job

_LOCAL_RAW: dict[str, tuple[tuple, bool]] = {}


def _raw_folder(shoot: Path) -> Path:
    """Where this shoot's photographs are: its own raw/, or the shoot folder
    itself for the flat shape (frames lying loose in it, no raw/)."""
    d = shoot / "raw"
    return d if d.is_dir() else shoot


def photographs_here(shoot: Path) -> bool:
    """Whether any of this shoot's photographs have their BYTES on this Mac.

    A name is not bytes: an archived RAW keeps its name, and `stat` reports its
    full size, while the first read blocks on a download. archive.local() is
    the one place that knows the difference.

    Cached against the folder's own mtime because panel() asks this on every
    poll and a shoot can hold four thousand files. A pull writes into that
    folder and an eviction rewrites it, so either one moves the mtime and the
    answer is taken again."""
    d = _raw_folder(shoot)
    try:
        st = d.stat()
        key = (st.st_mtime_ns, st.st_size, st.st_ino)
    except OSError:
        return False
    hit = _LOCAL_RAW.get(str(d))
    if hit and hit[0] == key:
        return hit[1]
    try:
        import archive
        out = any(p.suffix.lower() in RAW_EXTS and archive.local(p) for p in d.iterdir())
    except Exception:  # noqa: BLE001
        out = any(p.suffix.lower() in RAW_EXTS for p in d.iterdir())
    _LOCAL_RAW[str(d)] = (key, out)
    return out


def _fingerprint(shoot: Path) -> dict:
    """What would make this shoot worth learning from again: his flag, his
    keepers, his reasons, how many sidecars he has finished - and whether its
    photographs are on this Mac at all.

    Whether its photographs are on this Mac is deliberately NOT in here. It
    was, for about an hour, and it was the wrong shape: macOS evicts a shoot
    again as soon as the disk gets tight, so the fingerprint changed every time
    it came and went and the page asked him to learn from a shoot that had
    nothing left to teach - which costs him 4.6 GB down from iCloud to measure
    nothing. What the arriving photographs change is whether frames that were
    never measured CAN be measured, and that is asked in new_to_learn_from,
    against the count this run wrote down."""
    cull = cull_dir(shoot)

    def when(p: Path) -> int:
        try:
            return int(p.stat().st_mtime)
        except OSError:
            return 0

    key = decision_path(cull, "selects.json")
    lab = decision_path(cull, "labels.json")
    dops = 0
    newest = 0
    for d in ("raw", "edit", "cull/picks"):
        folder_ = shoot / d
        if folder_.is_dir():
            for p in folder_.glob("*.dop"):
                dops += 1
                newest = max(newest, when(p))
    return {"finished": str(shoot_meta(shoot).get("finished") or ""), "key": when(key), "labels": when(lab),
            "sidecars": dops, "sidecar_at": newest, "exports": exported_count(shoot)}


def new_to_learn_from(root: Path | None = None) -> list[str]:
    """Shoots that teach and whose evidence has changed since the last run."""
    base = Path(root or ROOT) / "shoots"
    if not base.is_dir():
        return []
    try:
        had = manifest().get("trained_on") or {}
    except Refused:
        had = {}
    # What the last run could not measure, per shoot, because the photographs
    # were not here. A shoot with a count above zero is one that bringing back
    # would actually teach something; a shoot at zero teaches the same whether
    # its RAWs are on this disk or in iCloud, which is the whole point of
    # keeping the measurements.
    try:
        owed = manifest().get("owed") or {}
    except Refused:
        owed = {}
    out = []
    for shoot in sorted(p for p in base.iterdir() if p.is_dir()):
        if not teaches(shoot):
            continue
        if had.get(shoot.name) != _fingerprint(shoot):
            out.append(shoot.name)
        elif owed.get(shoot.name) and photographs_here(shoot):
            out.append(shoot.name)
    return out


def request_run(why: str | None, shoot: str = "") -> dict:
    """Ask for a run when something else is already running, or take the ask
    back once one has started. The studio has one job slot, and a cull he
    started must not be pushed aside by a shoot he has just marked finished.

    It is also how a run that WAS going says it still wants to: work he asks
    for stands the learning down, and the ask written here is what picks it up
    again when the machine is next quiet. `shoot` rides along so the row can
    still say which shoot it is learning from when it does."""
    with _locked():
        m = manifest()
        m["queued"] = {"why": why, "shoot": shoot, "at": _now()} if why else None
        _save(m)
    return {"queued": bool(why), "why": why}


def due(root: Path | None = None) -> bool:
    """Whether there is something new to learn from and it has been a day.
    What to do about it is the app's business (it waits for the Mac to be
    idle); whether there is anything to do is this file's."""
    if not new_to_learn_from(root):
        return False
    try:
        last = (manifest().get("last_run") or {}).get("at") or ""
    except Refused:
        return True
    try:
        return (datetime.now() - datetime.strptime(last, "%Y-%m-%dT%H:%M:%S")).total_seconds() > 24 * 3600
    except ValueError:
        return True


def run(why: str = "asked for", root: Path | None = None, progress=None) -> dict:
    """Gather, train, check, and swap or hold. This is the one job: "Learn now"
    presses it and finishing a shoot presses it, so there is one path and one
    set of results, not two."""
    t0 = time.time()
    root = Path(root or ROOT)
    said: list[str] = []

    # `@@ stage done total`, which is what the studio's job runner reads to
    # move a bar and to say in words what the machine is doing (STAGE_WORDS
    # there). One stage per thing this run actually does, in the order it does
    # them: a single "learning" stage covering the whole middle of the run
    # left the bar standing still for minutes with a label that went on
    # reporting a count that had finished.
    def step(stage: str, done: int, total: int) -> None:
        print(f"@@ {stage} {done} {total}", flush=True)
        if progress:
            progress(stage, done, total)

    _writable()
    step("gathering", 0, 2)
    said += take_in_what_was_in_use()
    seed_edit()
    shoots = shoots_with_verdicts(root)
    keepers = sum(s.keepers for s in shoots)
    print(f"  {keepers} photos you kept, on {len(shoots)} shoots")
    step("gathering", 2, 2)
    fresh = new_to_learn_from(root)
    results = {}

    # The starting edit first: the tier order needs the light it measures to
    # know which shoots a ranker belongs to.
    import taste
    # What the run could not measure because the photographs were not here,
    # per shoot. Left as it was when the starting edit is not re-learned, so a
    # skipped run never forgets what an earlier one was owed.
    owed: dict | None = None
    # A check made under older rules is worked out again even when nothing new
    # has finished: the numbers behind the sentence on his page have to be the
    # ones the rules in this build would produce, or the page is quoting a
    # verdict nobody would reach today.
    if fresh or not live_model("edit") or check_is_stale("edit"):
        print("  the starting edit: reading your finished sidecars...")
        try:
            # Its two long stretches - measuring the frames, then reading the
            # export of each one - report through the same marks as everything
            # else, so the bar moves for the four minutes they take.
            edit = taste.learn_edit(root / "shoots", progress=step)
        except Exception as e:  # noqa: BLE001
            edit = None
            said.append(f"the starting edit could not be learned this time ({e})")
        if edit and edit.get("n"):
            data = edit_data(edit)
            owed = dict((data.get("dataset") or {}).get("never_measured_by_shoot") or {})
            results["edit"] = submit("edit", edit, source=f"learned: {why}", data=data)
            print("  " + results["edit"]["sentence"])
        else:
            _record_training("edit", {"note": "not enough finished frames to learn a starting edit from"})
    else:
        print("  the starting edit: nothing new finished since the last time")
    step("edit", 1, 1)

    import flaws
    print("  why you drop frames:")
    drop = flaws.train(root=root)
    rep = drop.pop("report")
    if drop.get("reasons"):
        results["drop-reasons"] = submit("drop-reasons", drop, source=f"learned: {why}", data=rep, shoots=shoots)
        print("  " + results["drop-reasons"]["sentence"])
    else:
        _record_training("drop-reasons", rep, state="not_enough")
    step("reasons", 1, 1)

    print("  which frames of a burst you keep:")
    table, trep = train_tier_order(_newest_light(), root)
    if table:
        results["tier-order"] = submit("tier-order", table, source=f"learned: {why}", data=trep, shoots=shoots)
        print("  " + results["tier-order"]["sentence"])
    else:
        _record_training("tier-order", trep, state="not_enough")
    step("bursts", 1, 1)

    # Anything still being held is re-checked against the keepers as they are
    # now, so the number in the panel is never older than his library. Counted
    # out one learner at a time: it is a check against every photograph he
    # kept, which is the slowest thing left, and a 0-then-1 said nothing about
    # where in it the run was.
    todo = [name for name in LEARNERS if name not in results]
    step("checking", 0, max(1, len(todo)))
    for i, name in enumerate(todo, 1):
        recheck(name, shoots)
        step("checking", i, len(todo))
    if not todo:
        step("checking", 1, 1)

    base = root / "shoots"
    trained_on = {p.name: _fingerprint(p) for p in sorted(base.iterdir())
                  if p.is_dir() and teaches(p)} if base.is_dir() else {}
    with _locked():
        m = manifest()
        m["trained_on"] = trained_on
        m["keepers"] = {"photos": keepers, "shoots": len(shoots), "at": _now()}
        if owed is not None:
            m["owed"] = owed
        m["last_run"] = {"at": _now(), "why": why, "took": int(time.time() - t0), "ok": True,
                         "said": said, "learned_from": fresh}
        m["queued"] = None
        _save(m)
    for s in said:
        print("  " + s)
    print(f"  done in {int(time.time() - t0)}s")
    return panel()


def _record_training(learner: str, data: dict, state: str | None = None) -> None:
    with _locked():
        m = manifest()
        e = _entry(m, learner)
        e["training"] = data
        if state and not e.get("live") and not e.get("candidate") and not e.get("stopped"):
            e["state"] = state
        e["sentence"] = _sentence(learner, e, version_check(learner, e.get("candidate")) if e.get("candidate") else None)
        _save(m)


def recheck(learner: str, shoots: list[ShootCheck] | None = None) -> dict | None:
    """Score what is held (or what is in use) against his keepers as they are
    now. A check is a statement about his library, and his library changes."""
    with _locked():
        m = manifest()
        e = _entry(m, learner)
        ts = e.get("candidate")
        if not ts or learner == "edit":
            return None
        model = version_model(learner, ts)
        if model is None:
            return None
        check = _check_for(learner, model, live_model(learner), shoots if shoots is not None else shoots_with_verdicts())
        _write_check(learner, ts, check)
        e["check"] = _summary(check)
        if check["passed"] and not e.get("stopped"):
            # It was held against the keepers as they were; they have changed
            # since, and it passes now. The rule is the rule either way.
            _make_live(m, learner, ts)
            e["candidate"] = None
            e["state"] = "in_use"
            _note(e, "in use (checked again against your keepers as they are now)", ts)
        else:
            e["state"] = "couldnt_check" if check.get("couldnt_check") else "held"
        e["sentence"] = _sentence(learner, e, check)
        _save(m)
        return check


# ------------------------------------------------------------- the panel

def panel(root: Path | None = None) -> dict:
    """Everything "What the cull has learned" shows, in one answer."""
    bad: Unreadable | None = None
    try:
        m = manifest()
        err = ""
    except Unreadable as e:
        m, err, bad = _blank(), UNREADABLE, e
    except Refused as e:
        m, err = _blank(), str(e)
    out: dict = {"folder": str(folder()), "error": err, "keepers": m.get("keepers") or {},
                 "last_run": m.get("last_run"), "queued": bool(m.get("queued")),
                 "new_to_learn_from": [], "due": False, "learners": []}
    if bad:
        # Said as a flag, not left to be inferred: the rows below are still
        # built, from a blank record, and a page that read "no learners"
        # as "unreadable" read three blank rows as "nothing learned yet" -
        # and offered Learn Now over a record it could not write to.
        out.update(unreadable=True, record=str(bad.path), unreadable_why=bad.why)
    # What the measurements cost him, on the screen beside the folder they are
    # in: a store that grows one row per finished frame for the rest of his
    # working life is a thing he is entitled to see the size of.
    try:
        size = measured_size()
        out["measured"] = {**size, "words": measured_words(size)}
    except Exception as e:  # noqa: BLE001
        out["measured"] = {"error": str(e)}
    try:
        out["new_to_learn_from"] = new_to_learn_from(root)
        out["due"] = due(root)
    except Exception as e:  # noqa: BLE001
        out["new_to_learn_from_error"] = str(e)
    for name in LEARNERS:
        e = dict(m["learners"].get(name) or {})
        ts = e.get("candidate")
        cand_check = version_check(name, ts) if ts else None
        live_check = version_check(name, e["live"]) if e.get("live") else None
        # The check the row's frames and "See the N" belong to: the one on the
        # version waiting, when there is one, because that is the decision
        # still open; otherwise the one in use.
        check = cand_check if ts else live_check
        # Worked out here, not read back: a sentence stored when the version
        # went live would still be saying it months later, after a check that
        # has since been run again says otherwise.
        said = _lines(name, e, live_check, cand_check)
        row = {"id": name, "title": TITLES[name], "changes": CHANGES[name], "state": said["state"],
               "sentence": said["sentence"], "candidate_state": said["candidate_state"],
               "candidate_sentence": said["candidate_sentence"], "needs_sentence": said["needs_sentence"],
               # The same needs, a fact to a line, and the shoots they ask
               # him to act on, so the page draws short lines and a button
               # rather than a paragraph ending in a command.
               "needs_lines": said["needs_lines"], "needs_do": said["needs_do"],
               # The shoots its check could not reach for want of picture
               # vectors, which a Measure button beside the line fixes.
               "check_do": said["check_do"],
               "live": None, "candidate": None, "training": e.get("training") or {},
               # What the row's menu may offer: going back is also how a
               # learner he stopped is turned on again, so it is offered
               # wherever there is a version behind this one.
               "can_go_back": bool(e.get("chain")),
               "can_stop": bool(e.get("live")),
               "can_use_anyway": bool(ts), "check": check}
        if e.get("live"):
            v = (e.get("versions") or {}).get(e["live"]) or {}
            row["live"] = {"version": e["live"], "since": e.get("since"), "made": v.get("made"),
                           "source": v.get("source"), "data": v.get("data") or {}}
        if ts:
            v = (e.get("versions") or {}).get(ts) or {}
            row["candidate"] = {"version": ts, "made": v.get("made"), "source": v.get("source"),
                                "data": v.get("data") or {}}
        # WHAT IT READ, on the row, in the engine's own words. His question
        # after the last run was "shouldn't the learn add to the existing
        # dataset, not replace it? How did it have less than it started with" -
        # and the panel had no answer on it, only a version that had been held
        # for being smaller. So the dataset the version was actually fitted on
        # is said out loud: how many frames, from which shoots, how many were
        # measured on this run, and how many came off shoots whose photographs
        # are no longer on this Mac. It belongs to the version the row is
        # about, so a held candidate is described by what IT read.
        #
        # `learned_from` is the version IN USE: the page put the candidate's
        # dataset ("Learned from 838 finished frames") straight above "Not in
        # use" while the 527-frame version beside it was the one writing his
        # sidecars. The candidate's own size is said in its own line.
        # `plain_metric` is about the measurement store, which the newest fit
        # read, so it follows the newest version.
        live_ds = ((row.get("live") or {}).get("data") or {}).get("dataset")
        ds = ((row.get("candidate") or row.get("live") or {}).get("data") or {}).get("dataset") \
            or (row.get("training") or {}).get("dataset")
        if ds:
            row["dataset"] = ds
            row["plain_metric"] = str(ds.get("plain_metric") or "")
        # Always sent, empty when the version in use has no dataset of its
        # own (its sentence says what it was learned from): an app that finds
        # the key missing falls back on a version's `source`, which put the
        # held candidate's "learned: you finished ..." - and once a file name
        # - over a row whose version in use it did not describe.
        row["learned_from"] = str((live_ds or {}).get("learned_from") or "")
        out["learners"].append(row)
    # The two that do not learn, said out loud, so the panel is the whole list
    # of what moves and what does not.
    out["fixed"] = [{"id": "picture-score", "title": "Picture judgement",
                     "sentence": "Built in, not trained on your photographs."},
                    {"id": "face-checks", "title": "Face checks",
                     "sentence": "Fixed rules (eyes closed, soft, caught mid-word), checked against faces "
                                 "settled by eye."}]
    return out


def text(p: dict) -> str:
    L = ["What the cull has learned", ""]
    k = p.get("keepers") or {}
    if k:
        L.append(f"  Nothing new is used until it has been checked against all {k.get('photos', 0)} photos you kept, "
                 f"on {k.get('shoots', 0)} shoots.")
        L.append("")
    if p.get("error"):
        L.append(f"  {p['error']}")
        L.append("")
    for row in p["learners"]:
        L.append(f"  {row['title']}")
        # What is in use first, then what is waiting beside it, then what it
        # is short of: the same three lines the app draws, in the same words.
        if row.get("learned_from"):
            L.append(f"    {row['learned_from']}")
        L.append(f"    {row['sentence']}")
        if row.get("candidate_sentence"):
            L.append(f"    {row['candidate_sentence']}")
        vec = [d["shoot"] for d in row.get("check_do") or [] if d.get("do") == "vectors"]
        if vec:
            # The app has a Measure button here; a typist has the command.
            L.append(f"    {VECTORS_FIX} {' '.join(vec)}   measures them")
        if row.get("needs_sentence"):
            L.append(f"    {row['needs_sentence']}")
        if row.get("plain_metric"):
            L.append(f"    {row['plain_metric']}")
        c = row.get("check") or {}
        for s in c.get("shoots", []):
            if s["moved_down"] or s["lifted"]:
                L.append(f"      {s['shoot']}: {s['checked']} of your keepers checked, {s['moved_down']} moved down, "
                         f"{s['lifted']} moved up, {s['hidden']} hidden")
        for s in c.get("couldnt_check", []):
            L.append(f"      {s['shoot']}: could not be checked - {s['why']}")
    for row in p.get("fixed", []):
        L.append(f"  {row['title']}: {row['sentence']}")
    L.append("")
    ms = p.get("measured") or {}
    if ms.get("frames"):
        L.append(f"  Measured once and kept: {ms['frames']} finished frames and {ms.get('exports', 0)} of your "
                 f"exported photographs, {ms.get('words')} in {ms['path']} "
                 f"({ms.get('per_frame', 0)} bytes a frame). ./pl learned dataset")
    lr = p.get("last_run")
    if lr:
        took = f"{lr['took']}s" if lr.get("took") else "under a second"
        L.append(f"  Last learned {lr['at']} ({lr['why']}, {took}).")
    if p.get("new_to_learn_from"):
        L.append(f"  New to learn from: {', '.join(p['new_to_learn_from'])}. Run ./pl learned run")
    return "\n".join(L)


def frames_text(p: dict) -> str:
    L = []
    for row in p["learners"]:
        c = row.get("check") or {}
        frames = [f for s in c.get("shoots", []) for f in s.get("frames", [])]
        if not frames:
            continue
        L.append(f"  {row['title']}: {len(frames)} of your keepers would move")
        for f in frames:
            L.append(f"    {f['shoot']} {f['stem']}: {f['now']} -> {f['new']} ({f['tier_now']} -> {f['tier_new']}); {f['why']}")
    return "\n".join(L)


def dataset_text() -> str:
    """Every shoot in the measurement store, what it contributes, and whether
    its photographs are still on this Mac.

    This is the page his question deserves an answer on: the store is what
    keeps a shoot teaching after its RAWs have gone, and a list of what is in
    it - with the one command that takes a shoot back out - is the whole of
    his control over it."""
    size = measured_size()
    table, _ = measured_read("frame")
    L = ["What the starting edit has been taught", ""]
    root = ROOT / "shoots"
    if not table:
        L.append("  Nothing measured yet. ./pl learned run")
    for shoot, n in sorted(size["shoots"].items(), key=lambda kv: (-kv[1], kv[0])) if table else []:
        d = root / shoot
        if not d.is_dir():
            where = "not on this Mac; what it taught is kept here"
        else:
            import taste
            where = "photographs here" if taste._has_raw(shoot) else "photographs archived; it still teaches"
        older = sum(1 for r in table.values()
                    if r.get("shoot") == shoot and int(r.get("schema") or 0) != _measure_schema())
        line = f"  {shoot}: {n} finished frame{'' if n == 1 else 's'}, {where}"
        if older:
            line += f"; {older} measured by an older version of the measuring code"
        L.append(line)
    L.append("")
    if table:
        L.append(f"  {size['frames']} frames and {size.get('exports', 0)} of your exported photographs, "
                 f"{measured_words(size)} in {size['path']} ({size.get('per_frame', 0)} bytes a frame).")
    L.append("  ./pl learned --forget <shoot>   take one shoot back out. Nothing here does that by itself.")
    for shoot in dropped_shoots():
        L.append(f"  {shoot}: you took it out; it does not teach. ./pl learned --teach-again {shoot}")
    L += ["", "What each shoot can still teach", ""]
    for e in contributors():
        if not e["teaches"]:
            L.append(f"  {e['shoot']}: {e['edit_frames']} finished frame{'' if e['edit_frames'] == 1 else 's'} of it "
                     f"are measured and kept, but it is not marked finished and nothing of it is exported, so "
                     f"nothing else learns from it yet"
                     if e["edit_frames"] else
                     f"  {e['shoot']}: not finished and nothing exported, so it teaches nothing yet")
            continue
        L.append(f"  {e['shoot']} ({e['raws']})")
        L.append(f"    your starting edit: {e['edit_frames']} finished frame"
                 f"{'' if e['edit_frames'] == 1 else 's'} measured and kept"
                 + ("" if e["edit_taught"] == e["edit_frames"] else
                    f", {e['edit_taught']} of them what it learns from: only what you export teaches"))
        L.append(f"    which frames of a burst you keep: {e['tier_order']}")
        L.append(f"    why you drop frames: {e['drop_reasons']}")
    return "\n".join(L)


def _measure_schema() -> int:
    import taste
    return taste.MEASURE_SCHEMA


def contributors(root: Path | None = None) -> list[dict]:
    """What each shoot can still teach each of the three learners, and what
    stops it where something does.

    The starting edit reads measurements it now keeps, so a shoot teaches it
    for good once it has been measured. The other two read files that were
    never on the RAWs: the tier order reads cull.csv and the frames he kept,
    and the drop reasons read his labels and one picture vector per frame. So
    neither decays when a shoot is archived - but a shoot culled before the
    cull kept its vectors has none, and that is the one thing here that stops
    a drop-reason model being checked at all."""
    import taste
    base = Path(root or ROOT) / "shoots"
    store, _ = measured_read("frame")
    out: list[dict] = []
    if not base.is_dir():
        return out
    from library import is_shoot
    # A folder on the shelf, not every folder under it. This page is a list of
    # what each shoot can still teach, and `~/photos/shoots/shoots` - the
    # empty folder an old misread of PHOTOS_ROOT made - stood in it saying it
    # teaches nothing yet, which reads as a shoot of his that has gone wrong.
    for shoot in sorted(p for p in base.iterdir() if p.is_dir() and is_shoot(p)):
        cull = cull_dir(shoot)
        rows = _rows(cull)
        # What it teaches as his (`taught`): the frames he exported, found
        # now, written down at Finish, or as the store recorded them.
        mine, _ = taught(shoot, table=store)
        measured = [r for r in store.values() if r.get("shoot") == shoot.name]
        e: dict = {"shoot": shoot.name, "teaches": teaches(shoot),
                   "raws": "here" if taste._has_raw(shoot.name) else "archived",
                   "edit_frames": len(measured),
                   # Of those, the ones the starting edit learns from.
                   "edit_taught": sum(1 for r in measured
                                      if str(r.get("stem") or Path(str(r.get("frame") or "")).stem) in mine),
                   "rows": len(rows)}
        key = decision_path(cull, "selects.json")
        e["keepers"] = len(json.loads(key.read_text())) if key.exists() else 0
        e["tier_order"] = ("no cull.csv to learn an order from" if not rows else
                           "no frames you kept" if not e["keepers"] else
                           "nothing you exported, so nothing to learn an order from" if not mine else
                           f"{len(mine)} you exported, in its own cull.csv, which is all this one reads")
        labels = decision_path(cull, "labels.json")
        try:
            lab = json.loads(labels.read_text()) if labels.exists() else {}
        except (OSError, ValueError):
            lab = {}
        e["reasons"] = sum(1 for v in lab.values() if v)
        have = similar_vectors(cull) is not None or cached_vectors(shoot.name) is not None
        stems = {Path(r["file"]).stem for r in rows}
        covered = 0
        if have:
            got = {**(cached_vectors(shoot.name) or {}), **(similar_vectors(cull) or {})}
            covered = len(stems & set(got))
        e["vectors"] = covered
        gave = ("no reasons you gave" if not e["reasons"] else
                "1 reason you gave" if e["reasons"] == 1 else f"{e['reasons']} reasons you gave")
        e["drop_reasons"] = (f"{gave}; every frame has a picture vector, so a model can be checked here"
                             if rows and covered >= len(stems) else
                             f"{gave}; {len(stems) - covered} of its {len(stems)} frames have no picture vector, so no "
                             f"drop-reason model can be checked here - ./pl learned vectors {shoot.name}")
        out.append(e)
    return out


# ------------------------------------------------------------------ CLI

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", nargs="?", default="show", choices=["show", "run", "import", "check", "dataset", "vectors"],
                    help="show what is in use (default), run the learning job, take in an older starting edit, "
                         "list the measurements it has kept, or measure the picture vectors of a shoot that was "
                         "culled before the cull kept them")
    ap.add_argument("file", nargs="?", type=Path, help="the file to import, or the shoot to measure vectors for")
    ap.add_argument("--check", action="store_true", help="the keeper check, frame by frame, changing nothing")
    ap.add_argument("--back", metavar="LEARNER", help="go back to the version before")
    ap.add_argument("--stop", metavar="LEARNER", help="stop using one; what it learned is kept")
    ap.add_argument("--use-anyway", metavar="LEARNER", help="use what is held, after looking at the frames it moves")
    ap.add_argument("--forget", metavar="SHOOT",
                    help="drop one shoot's frames from the measurements: you deleted it, or it should never have "
                         "taught. What comes out is kept aside, and nothing is refitted until you learn again")
    ap.add_argument("--teach-again", metavar="SHOOT", help="let a shoot you dropped teach again")
    ap.add_argument("--why", default="", help="what asked for this run, for the record it keeps")
    ap.add_argument("--json", action="store_true", help="print the panel as JSON")
    a = ap.parse_args(argv)
    try:
        if a.back:
            print(back(a.back)["sentence"])
            return 0
        if a.stop:
            print(stop(a.stop)["sentence"])
            return 0
        if a.use_anyway:
            e = _entry(manifest(), a.use_anyway)
            if not e.get("candidate"):
                print(f"{TITLES.get(a.use_anyway, a.use_anyway)}: nothing is being held")
                return 1
            print(frames_text(panel()))
            print(use_anyway(a.use_anyway, e["candidate"])["sentence"])
            return 0
        if a.forget:
            print(measured_forget(a.forget)["sentence"])
            return 0
        if a.teach_again:
            print(teach_again(a.teach_again)["sentence"])
            return 0
        if a.command == "dataset":
            print(dataset_text())
            return 0
        if a.command == "vectors":
            base = ROOT / "shoots"
            from library import is_shoot
            names = ([str(a.file)] if a.file else
                     [p.name for p in sorted(base.iterdir()) if p.is_dir() and is_shoot(p)])
            refused = False
            for name in names:
                d = base / name
                if not d.is_dir():
                    print(f"  {name} is not a shoot in {base}")
                    continue
                r = measure_vectors(d, progress=lambda st, i, n: print(f"@@ {st} {i} {n}", flush=True))
                print("  " + r["sentence"])
                refused = refused or bool(r.get("refused"))
            return 1 if refused else 0
        if a.command == "run":
            p = run(why=a.why or "./pl learned run")
        elif a.command == "import":
            if not a.file:
                print("say which file to import")
                return 2
            for r in import_taste(a.file):
                print("  " + r["sentence"])
            p = panel()
        else:
            p = panel()
            if a.check or a.command == "check":
                shoots = shoots_with_verdicts()
                for name in LEARNERS:
                    if name != "edit":
                        recheck(name, shoots)
                p = panel()
    except Refused as e:
        print(f"  {e}")
        return 1
    if a.json:
        print(json.dumps(p, default=str))
    else:
        print(text(p))
        if a.check or a.command == "check":
            print(frames_text(p))
    return 0


if __name__ == "__main__":
    sys.exit(main())
