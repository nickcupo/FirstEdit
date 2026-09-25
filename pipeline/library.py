#!/usr/bin/env python3
"""
library.py - where a shoot's work is, what each file in it is, and what may
be taken back.

Four questions this module answers, in one place, so that no command has to
answer them again by hand:

  1. Where are this shoot's RAWs and its cull?   raw_dir() / cull_dir()
  2. What is this file - an original, a decision, a cache, a finished piece
     of work?                                    survey() / Kind
  3. Which photograph is this, after it has been renamed or moved?
                                                 mint() / find()
  4. What may be deleted, or moved, without a person having to look?
                                                 untouchable() / reclaimable()

Nothing here writes to a photograph, a sidecar or a decision file. The only
things it writes are a CACHEDIR.TAG inside a directory it has just created
itself, and its own SQLite catalogue, which is a cache: `rebuild()` makes it
again from the folders in one pass, and losing it costs time and never a
frame.

WHY THIS FILE EXISTS
--------------------
Nine places carry the same line - `raw = shoot/"raw" if (shoot/"raw").is_dir()
else shoot` (studio.Shoot.__init__, gather._build, spread.gather_to, bench.run,
cull.main where it picks out_dir, presets.cull_of, reel.frames, taste.shoot_raw
and taste.learn_colour). Line numbers are deliberately not given: they were,
and every one of them was wrong within a fortnight. The layout of the library
therefore depends on whether the folder someone points at is literally spelled
"raw". A folder of loose RAWs with no raw/ subfolder - the ducks shoot, 98
frames and 98 hand-written sidecars, 2.3 GB - is invisible to every one of
them. That branch is replaced here by one function that says what it found and
refuses to guess.

And the failure this whole module is built against: the lounge shoot holds
6 ARW against 296 culled frames. The only surviving pixels for the other 290
are in cull/decoded/ and cull/previews/ - two folders spelled like caches,
inside a folder spelled like a cache. What protects them today is a text file
the photographer typed, cull/DO-NOT-CLEAN.txt, which no line of code reads.
Here that protection is computed: a frame the shoot knows about, whose RAW is
gone, promotes whatever pixels survive to ORIGINAL, and an ORIGINAL is never
offered to any verb. The note becomes a courtesy rather than the last line of
defence.
"""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import time
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from common import EXIFTOOL, JPEG_EXTS, RAW_EXTS, human, write_atomic  # noqa: E402

ROOT = Path(os.environ.get("PHOTOS_ROOT", Path.home() / "photos")).expanduser()

# The Bagit-era convention PhotoLab knows nothing about and Time Machine,
# Backblaze, borg, restic and rsync all do. The signature line is fixed by the
# spec; it is not ours to choose. Ten of these are already on disk under
# ~/photos, every one of them written by the photographer's own hand.
TAG = "CACHEDIR.TAG"
TAG_SIGNATURE = "Signature: 8a477f597d28d172789f06886806bc55"

SIDECAR_EXTS = {".dop", ".xmp", ".pp3"}

# The files at cull/'s top level that hold a decision, measured across the
# library: 48 files, 1.1 MB, one level above every CACHEDIR.TAG. Not an
# allowlist that has to be kept in step with the code - see _classify, where
# anything unrecognised at that level is treated the same way. The list only
# earns a better `why` string for the ones we can name.
DECISION_NAMES = {
    "organize.json", "labels.json", "selects.json", "selects.prev.json",
    "spread.json", "review.json", "archive.json", "top30.json",
    "reel-plan.json", "edits.md", "DO-NOT-CLEAN.txt", "shoot.json",
}

# And what the pipeline itself writes at that level. These are held exactly as
# the ones above are - nothing here deletes or moves them - but calling them
# decisions of his was wrong in the one direction that matters to a person
# reading a report: cull.csv is a measurement the next cull makes again, and
# a list of twenty "his" files that is mostly the machine's teaches him to
# stop reading the line. review.json and archive.json went the other way and
# are decisions: one is his record of the bursts he has been through, the
# other the record of where his photographs were sent.
OUTPUT_NAMES = {"cull.csv", "bench.csv", "presets.json", "presets.md", "studio.log", "similar.npz"}
# The ones worth a sentence of their own. similar.npz is small (about 1.6 kB a
# frame) and is what keeps a delivered shoot inside the keeper check once its
# RAWs, decodes and previews are gone: the vectors cannot be measured again
# from nothing, so it stays when a shoot is archived or its cache reclaimed.
OUTPUT_WHY = {"similar.npz": "the CLIP vector and hash each stack was formed from, "
                             "which the keeper check reads after the RAWs are gone"}

# Where finished work lands. reel.py already keeps this list for its own
# purposes (EXPORT_DIRS); it is repeated rather than imported because reel.py
# is not ours to change yet and importing it drags in the whole reel stack.
EXPORT_DIRS = ("export", "edit/edited", "cull/picks/edited")

# The directories the cull and the studio build and may rebuild. A name on
# this list is NOT on its own a licence to delete anything - see is_cache and
# untouchable. It is only the shape-matching table for provenance.
CACHE_SHAPES = {
    "thumbs": "cull thumbs",
    "previews": "cull previews",
    "large": "cull large",
    "full": "studio full",
    "decoded": "cull decoded",
    "reelthumbs": "reel thumbs",
    "presets": "presets",
}


class NotAShoot(ValueError):
    """The folder pointed at is not a shoot yet, and guessing would be worse
    than saying so.

    The old branch guessed: point it at any folder and it treated that folder
    as raw/, which is how a stray _cull/ ended up beside the dog shoot and had
    to be cleaned out by hand (MOVES.log, 13 September)."""


# --------------------------------------------------------------- resolution

def layout(shoot: Path) -> str:
    """How this folder is laid out, in one word.

    'standard'  <shoot>/raw + <shoot>/cull       - most shoots
    'flat'      loose RAWs, no raw/ subfolder    - the ducks shoot, and the
                folder of loose frames beside shoots/
    'raw'       the caller pointed straight at a raw/ folder - `pl cull` does
                this, and presets reads the cull from the parent
    'empty'     a folder with no frames in it at all
    """
    shoot = Path(shoot)
    if (shoot / "raw").is_dir():
        return "standard"
    if shoot.name == "raw" and _has_frames(shoot):
        return "raw"
    if _has_frames(shoot):
        return "flat"
    return "empty"


def _has_frames(folder: Path) -> bool:
    try:
        return any(p.suffix.lower() in RAW_EXTS | JPEG_EXTS for p in folder.iterdir())
    except OSError:
        return False


def raw_dir(shoot: Path) -> Path:
    """Where this shoot's originals are.

    Replaces the branch repeated in studio, gather, spread, bench, cull,
    presets, reel and taste (the list is in this module's docstring). Same
    answer as that branch on every shoot laid out the standard way; a real
    answer instead of a wrong one on the flat ones, which it used to treat as
    though the shoot folder itself were raw/."""
    shoot = Path(shoot)
    kind = layout(shoot)
    if kind == "standard":
        return shoot / "raw"
    if kind in ("raw", "flat"):
        return shoot
    raise NotAShoot(f"{shoot} holds no frames; it is not a shoot yet")


def cull_dir(shoot: Path) -> Path:
    """Where this shoot's cull output is.

    ONE rule, used by every command (paths() below):
      1. whichever of cull/ and _cull/ holds a cull.csv, cull/ first;
      2. else whichever of them exists, cull/ first;
      3. else cull/, which is the only name a new cull is ever given.
    `_cull` is read where an old flat shoot has one and never handed out:
    the `_cull` fork produced the stray folder beside the dog shoot that had
    to be moved back by hand, file by file. And a folder that HOLDS the cull
    wins over one that merely exists, because the question every caller is
    asking is "where is cull.csv"; a flat shoot with an empty cull/ made by
    one command and the real cull in _cull/ used to get a different answer
    from each of nine resolvers."""
    return paths(shoot).cull


def shoot_root(path: Path) -> Path:
    """The shoot folder a path belongs to, given the shoot itself, its raw/,
    its cull/ (or an old _cull/), or a file in any of them.

    Every command takes whichever of these a person points it at: `pl cull`
    was documented on <shoot>/raw, gather on <shoot>, and presets worked only
    on raw/ - on a flat shoot or a shoot folder it looked for a _cull that
    was not there and stopped. Resolving the argument here is what makes the
    three the same."""
    path = Path(path).expanduser()
    if path.is_file():
        path = path.parent
    if path.name == "raw":
        return path.parent
    if path.name in ("cull", "_cull") and ((path / "cull.csv").exists() or (path.parent / "shoot.json").exists()
                                           or (path.parent / "raw").is_dir() or _has_frames(path.parent)):
        return path.parent
    return path


@dataclass(frozen=True)
class ShootPaths:
    """A shoot's folders, whatever the layout and whichever of them was
    pointed at. Never raises: an empty or archived shoot still has a place
    its cull is, and its RAW folder is raw/ if it has one."""
    shoot: Path
    raw: Path
    cull: Path

    @property
    def decisions(self) -> Path:
        return self.shoot / "decisions"

    @property
    def picks(self) -> Path:
        return self.cull / "picks"

    @property
    def edit(self) -> Path:
        return self.shoot / "edit"

    @property
    def export(self) -> Path:
        return self.shoot / "export"


def paths(path: Path) -> ShootPaths:
    """The one resolver: shoot, RAW folder and cull folder for any path into
    a shoot. See shoot_root for what may be pointed at and cull_dir for the
    cull rule."""
    shoot = shoot_root(path)
    raw = shoot / "raw" if (shoot / "raw").is_dir() else shoot
    cull = None
    for name in ("cull", "_cull"):
        if (shoot / name / "cull.csv").exists():
            cull = shoot / name
            break
    if cull is None:
        for name in ("cull", "_cull"):
            if (shoot / name).is_dir():
                cull = shoot / name
                break
    return ShootPaths(shoot=shoot, raw=raw, cull=cull or shoot / "cull")


# By number, whatever the extension: the RAW behind a cull.csv row.
_RAWS: dict[str, tuple[tuple, dict[str, Path]]] = {}


def raw_index(shoot: Path) -> dict[str, Path]:
    """Stem -> this shoot's RAW of that number (frame_raw's lookup table),
    for a caller resolving many rows of one shoot: the shoot is resolved and
    its folders stat'd once, not once per row.

    A link in edit/ or cull/picks/ counts only while it still leads to a
    file. The cull's picks are symlinks into raw/ by default, and once the
    RAWs are cleared (2026-09-12-lounge: 6 RAWs left of 296) each one
    dangles: counting it made the studio take a frame whose decode is its
    last pixels for one with an original, and presets put a sidecar beside
    the dangling link. raw/ itself is taken as it lists, because a RAW there
    that is away (evicted to iCloud, a link to a card not mounted) is not
    gone, and its sidecar stays under the name it comes back to."""
    p = paths(shoot)
    folders = [p.raw, p.shoot, p.edit, p.picks]
    stamp = tuple(f.stat().st_mtime_ns if f.is_dir() else 0 for f in folders)
    got = _RAWS.get(str(p.shoot))
    if not got or got[0] != stamp:
        index: dict[str, Path] = {}
        for folder in reversed(folders):         # raw/ last, so it wins
            if folder.is_dir():
                own = folder in (p.raw, p.shoot)
                index.update({f.stem: f for f in folder.iterdir()
                              if f.suffix.lower() in RAW_EXTS and (own or f.exists())})
        got = (stamp, index)
        _RAWS[str(p.shoot)] = got
    return got[1]


def frame_raw(shoot: Path, name: str) -> Path | None:
    """This frame's RAW, found by its number whatever extension the cull
    wrote down, if it is still here. cull.csv can name the camera JPEG the
    cull decoded (2026-09-12-lounge's says TSC04015.jpg) and looking for
    raw/TSC04015.jpg found nothing beside raw/TSC04015.ARW. Looks in raw/
    (or the flat shoot folder), then edit/ and cull/picks/; raw/ wins
    (raw_index)."""
    return raw_index(shoot).get(Path(name).stem)


def sidecar_path(shoot: Path, name: str) -> Path | None:
    """Where this frame's PhotoLab sidecar belongs: beside its RAW, named for
    the RAW (TSC04016.ARW.dop), whatever name the cull gave the frame. None
    when the RAW is not here, because a sidecar beside nothing is a file
    PhotoLab never opens - which is what TSC04016.jpg.dop was."""
    raw = frame_raw(shoot, name)
    return raw.with_name(raw.name + ".dop") if raw is not None else None



def holds_shoots(folder: Path) -> bool:
    """True when this folder is a shelf the shoots stand on rather than a
    shoot: one of the folders inside it has a raw/ of its own.

    A shoot's own subfolders never do. raw/, cull/, edit/, reels/ and export/
    are the whole vocabulary and not one of them carries a second raw/, so
    this cannot mistake a shoot's machinery for a shoot."""
    try:
        kids = [c for c in folder.iterdir() if c.is_dir() and not c.name.startswith(".")]
    except OSError:
        return False
    return any((c / "raw").is_dir() and _has_frames(c / "raw") for c in kids)


def is_shoot(folder: Path) -> bool:
    """Whether this folder is a shoot, seen from outside it.

    The three shapes, and no list of spellings: a raw/ of its own, a cull/ of
    its own (a delivered shoot whose RAWs have been cleared - the lounge holds
    6 ARW against 296 culled frames), or frames lying loose in it (the ducks
    shoot, 98 ARW and no raw/). `layout()` answers the first and third; the
    second is the one it cannot see, because a shoot with its RAWs gone has
    nothing layout() recognises and is still, obviously, a shoot."""
    folder = Path(folder)
    if not folder.is_dir():
        return False
    return layout(folder) in ("standard", "flat") or (folder / "cull").is_dir()


def shelf(root: Path) -> Path:
    """Where this library's shoots stand.

    `<root>/shoots` is the layout, and it is what gets made when a library is
    new. But the folder a person points at is the one with his shoots visibly
    in it, and that folder IS the shelf whatever it is called. Appending
    "shoots" to it unconditionally is how `PHOTOS_ROOT=~/photos/shoots` became
    `~/photos/shoots/shoots` - a folder that did not exist until the studio's
    own mkdir made it, holding nothing, with every shoot still on the disk one
    level up and not a word said about where it had looked.

    Asked of the filesystem and never of a name: `~/photos` resolves to
    `~/photos/shoots` because that is where the shoots are, and
    `~/photos/shoots` resolves to itself for the same reason. A root with
    shoots in neither place resolves to `<root>/shoots`, which is the folder to
    make and the folder to name when there is nothing to show."""
    root = Path(root)
    standard = root / "shoots"
    if holds_shoots(standard) or any(is_shoot(p) for p in _kids(standard)):
        return standard
    if any(is_shoot(p) for p in _kids(root)):
        return root
    return standard


def _kids(folder: Path) -> list[Path]:
    try:
        return [c for c in folder.iterdir() if c.is_dir() and not c.name.startswith(".")]
    except OSError:
        return []


def shoots(root: Path | None = None) -> list[Path]:
    """Every shoot under the library, including the ones no command can see
    today. The ducks shoot and the folder of loose frames beside shoots/ are
    folders of loose RAWs with no shoot.json; they are shoots by the only test
    that matters, which is that they hold photographs.

    Two structural tests decide it and no list of names does. This read
    `p.name in ("shoots", "attic", "datasets", "inbox")`, which is a rule
    about spelling: the fixtures folder was never in it and stayed out of the
    library only because it happens to hold no frames directly - luck, not a
    rule, and luck that would have run out the first time a folder was
    renamed or a fifth one appeared. What is asked instead is what the folder
    is: does it hold frames of its own (layout), and is it a shelf that other
    shoots stand on (holds_shoots). All four of the named folders answer
    those the same way today, on this machine, and so does fixtures."""
    root = Path(root or ROOT)
    out: list[Path] = []
    for base in (root / "shoots", root):
        if not base.is_dir():
            continue
        for p in sorted(base.iterdir()):
            if not p.is_dir() or p.name.startswith("."):
                continue
            if base != root / "shoots" and holds_shoots(p):
                continue
            if layout(p) in ("standard", "flat") and p not in out:
                out.append(p)
    return out


def meta(shoot: Path) -> dict:
    try:
        return json.loads((Path(shoot) / "shoot.json").read_text())
    except (OSError, ValueError):
        return {}


def shoot_id(shoot: Path) -> str:
    """A shoot's name to itself, fixed once and never derived from where it
    sits.

    This was sha1 of the absolute path (taste.shoot_id), and 526 learned
    samples in the committed taste.json hang off two such strings, one for the
    portraits shoot and one for the action shoot - each of them a hash of
    <root>/shoots/<name> as that folder sat on one machine. Renaming the
    action shoot orphans its 328 samples silently, and so does pointing
    PHOTOS_ROOT at another volume.

    The old hash stays as the fallback, so a shoot with no id in its
    shoot.json keeps resolving exactly as it does today and taste.json stays
    bit-for-bit valid. Writing the value it already hashes to into
    shoot.json is then an 18-byte migration that changes no behaviour."""
    sid = meta(shoot).get("id")
    if sid:
        return str(sid)
    return legacy_shoot_id(shoot)


def legacy_shoot_id(shoot: Path) -> str:
    """What taste.shoot_id computes today. Kept so the two venues already in
    taste.json keep matching without anything being relearned."""
    return hashlib.sha1(str(Path(shoot).expanduser().resolve()).encode()).hexdigest()[:12]


# A random new_shoot_id() for a shoot at ingest was here and nothing called it.
# The id a shoot carries is written by taste.stamp_venue_id, which writes the
# PATH HASH the shoot already answers to rather than a fresh value, so that
# taste.json keeps matching bit for bit; a second, random source of ids would
# be a second answer to "which shoot is this" with nothing to say which was
# right. Ingest writing shoot.json would also race the studio, which writes
# the kind and the card into that file as the job starts.


# ------------------------------------------------------------- cache folders

def cache_dir(path: Path, built_by: str = "first-edit") -> Path:
    """Create a directory and mark it, in that order, in one call.

    A CACHEDIR.TAG may only ever be written by the function that creates and
    fills the directory. The alternative - a pass that walks the library and
    offers to tag folders that already exist - asks a human to look at a
    folder and say 'that looks like a cache', which is the same substitution
    of a verdict for a record that lost the answer key. It is also exactly
    what the lounge shoot's cull/decoded would fail: it is spelled like a
    cache and holds the only pixels of 290 frames.

    Called today from the studio, where it mints the full-view cache and the
    decoded cache it builds for the viewer. cull.py makes previews/, decoded/,
    thumbs/ and large/ with a plain mkdir and writes no tag, so on a shoot
    culled by the command line those folders carry no licence and both reclaim
    modules leave them alone for ever - the call belongs where cull.py creates
    each folder, and until it is there the caches of a fresh cull are counted
    and never offered. Everything the tool has not minted itself stays
    untagged, and stays untouched.

    A directory that already exists and already holds files was not minted by
    this call, whatever it is named, so this call does not tag it. Without
    that test, `mkdir(exist_ok=True)` made the sentence above untrue the
    moment anything re-ran over an existing folder: a second `pl cull` over
    the lounge shoot would have written the tag onto cull/decoded, which is
    where the only pixels of 290 frames live. An untagged cache folder from
    an older run therefore stays untagged and stays unreclaimable, which is
    the direction it is safe to be wrong in."""
    path = Path(path)
    fresh = not path.exists()
    path.mkdir(parents=True, exist_ok=True)
    tag = path / TAG
    try:
        empty = not any(p.name != TAG for p in path.iterdir())
    except OSError:
        empty = False
    if not tag.exists() and (fresh or empty):
        write_atomic(tag, f"{TAG_SIGNATURE}\n"
                          "# This directory is a cache rebuilt from the RAWs by First Edit.\n"
                          "# Backup tools that honour CACHEDIR.TAG skip it.\n"
                          f"# Built by: {built_by}\n")
    return path


def is_cache(folder: Path) -> bool:
    """True when this directory carries a real CACHEDIR.TAG. The signature
    line is checked, not just the filename: a file of that name with other
    contents is somebody else's, and the spec says so."""
    try:
        with (Path(folder) / TAG).open("r", errors="ignore") as fh:
            return fh.readline().strip() == TAG_SIGNATURE
    except OSError:
        return False


def tag_writer(folder: Path) -> str | None:
    """The `Built by:` line, when the tag was written by cache_dir. None for
    the ten tags the photographer wrote by hand, which is not a problem: a
    file's provenance is decided per file, not per folder."""
    try:
        for line in (Path(folder) / TAG).read_text(errors="ignore").splitlines():
            if line.lower().startswith("# built by:"):
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return None


# ------------------------------------------------------------ classification

class Kind(str, Enum):
    ORIGINAL = "original"        # a photograph. Irreplaceable.
    DECISION = "decision"        # something a person settled. Irreplaceable.
    DERIVED = "derived"          # the tool made it and the tool can make it again.
    DELIVERABLE = "deliverable"  # finished work. Rebuildable in theory, his in practice.


IRREPLACEABLE = (Kind.ORIGINAL, Kind.DECISION, Kind.DELIVERABLE)


@dataclass
class Entry:
    """One name on disk. Not one photograph: calib-skin holds 33 names on 3
    inodes, each name with its own hand-written .dop, so names and pixels are
    counted separately throughout."""
    rel: str
    path: Path
    kind: Kind
    bytes: int
    why: str
    stem: str = ""
    dev: int = 0                 # the volume. An inode number is only unique on one.
    inode: int = 0
    nlink: int = 1
    names_here: int = 1          # names of this inode found inside this survey
    symlink: bool = False
    target: str = ""
    dangling: bool = False
    built_by: str | None = None  # None means: nothing can name a writer for it

    @property
    def ino_key(self) -> tuple[int, int]:
        """What identifies these bytes: (st_dev, st_ino), never st_ino alone.

        Inode numbers are unique within a volume and nowhere else. Everything
        in this file is keyed on this - byte ownership, de-duplication, what
        counts as a second name for an original - and all of it was keyed on
        the number alone, which is correct exactly as long as the whole
        library sits on one disk. Putting a finished shoot on an external
        drive is the point of archiving it, and the first shoot that moved
        would have collided with an unrelated frame on the boot volume and
        been charged its bytes."""
        return (self.dev, self.inode)

    @property
    def unowned(self) -> bool:
        """Unknown provenance. True for every original, every decision, every
        finished export, and for anything sitting in a cache folder that the
        tool cannot account for - 291 such files are in
        the dog shoot's cull/thumbs right now, stems with no frame in that
        shoot."""
        return self.built_by is None

    @property
    def shared_outside(self) -> int:
        """Names of this inode that this survey did not see. Above zero means
        removing every name here frees nothing.

        Measured, library-wide: 1,029 inodes under the library report a link
        count above one while carrying exactly one name inside it. All 198 ARW
        of the portraits shoot are among them - one of them reports st_nlink
        2, and `find ~ -inum` turns up that one name and no
        other. So the second name is outside the home directory, or the count
        is simply stale; nothing on this machine can tell which. Either way
        st_nlink cannot be read as 'this file is free', and it is not read
        that way anywhere here: reclaim counts only what it is about to
        unlink, and a file reporting a name it cannot see is counted at
        zero rather than guessed at in either direction."""
        return max(0, self.nlink - self.names_here)


@dataclass
class Bytes:
    apparent: int = 0    # every name counted
    unique: int = 0      # each inode counted once
    shared_out: int = 0  # bytes on inodes with a name this survey cannot see

    def __str__(self) -> str:
        if self.apparent == self.unique:
            return human(self.unique)
        return f"{human(self.unique)} ({human(self.apparent)} apparent)"


@dataclass
class Survey:
    shoot: Path
    id: str
    layout: str
    entries: list[Entry] = field(default_factory=list)
    frames: set[str] = field(default_factory=set)         # every stem the shoot knows
    of_record: dict[str, list[str]] = field(default_factory=dict)  # stem -> surviving pixels
    notes: list[str] = field(default_factory=list)

    # ---- byte accounting that does not double-count a hard link

    def owner(self) -> dict[tuple[int, int], Kind]:
        """Which kind an inode's bytes belong to, when its names disagree.

        The action shoot's edit/ holds 154 hard links to raw/, and its reels/
        holds more; calib-skin holds 33 names on 3 inodes. The same bytes are
        therefore an original AND a link the tool made. Charged to both, that
        shoot's derived total reads 14.5 GB when only 8.3 GB of it is
        cache; charged to neither, the library does not add up. They are
        charged to whichever name it would hurt most to lose, so that the
        derived column is only ever what deleting derived files would
        actually free."""
        rank = {Kind.ORIGINAL: 0, Kind.DELIVERABLE: 1, Kind.DECISION: 2, Kind.DERIVED: 3}
        own: dict[tuple[int, int], Kind] = {}
        for e in self.entries:
            if e.symlink:
                continue
            if e.ino_key not in own or rank[e.kind] < rank[own[e.ino_key]]:
                own[e.ino_key] = e.kind
        return own

    def bytes(self, kind: Kind | None = None) -> Bytes:
        own = self.owner()
        b = Bytes()
        seen: set[tuple[int, int]] = set()
        for e in self.entries:
            if kind is not None and e.kind is not kind:
                continue
            b.apparent += e.bytes
            if e.symlink or e.ino_key in seen:
                continue
            if kind is not None and own.get(e.ino_key) is not kind:
                continue          # these bytes are charged to a name that matters more
            seen.add(e.ino_key)
            b.unique += e.bytes
            if e.shared_outside:
                b.shared_out += e.bytes
        return b

    def by_kind(self) -> dict[Kind, Bytes]:
        return {k: self.bytes(k) for k in Kind}

    # ---- the one guard, used by every verb

    def untouchable(self, e: Entry) -> str | None:
        """Why this file may not be deleted OR moved, or None.

        One predicate for both verbs, because a design that will not delete a
        file it cannot name a writer for must not move one either. The reels
        split moves reels/burst19/ and reels/burst54/ - and inside them sit 70
        finished _DxO.jpg exports, 1.26 GB, which are the only copy the
        action shoot's finished work has: its export/ holds 0 files and its
        edit/edited/ holds a .DS_Store. Those two folders are what this
        predicate exists to make into a no-op.

        The gates, in the order they fire:
          1. it is not derived                  (original, decision, deliverable)
          2. nothing can name what wrote it     (the 154 exports rmtree'd out
                                                 of edit/edited/)
          3. it is the last pixels of a frame   (the 290 lounge RAWs that
                                                 survived only in a folder
                                                 spelled like a cache)
          4. the folder it is in was not minted by the tool
        """
        if e.kind is not Kind.DERIVED:
            return f"{e.kind.value}: {e.why}"
        if e.unowned:
            return "nothing in the pipeline can be named as its writer"
        if e.path.suffix.lower() in RAW_EXTS:
            # reclaim.py's own guard says this and it belongs here too: a RAW
            # is a photograph wherever it sits, and a verb that has to decide
            # whether one is "only a link" is one bad answer away from
            # unlinking the only copy of a frame.
            return "a photograph, wherever it sits"
        if e.path.name == TAG:
            # The licence to clean the folder, counted as bytes to take back
            # and offered up with them. Removing it does not free a cache; it
            # stops the folder ever being recognised as one again.
            return "the note that allows this folder to be cleaned"
        if e.stem and e.rel in self.of_record.get(e.stem, ()):
            return f"the only surviving pixels of {e.stem}"
        if not is_cache(e.path.parent):
            return "the folder it sits in was not created by this tool"
        return None

    def reclaimable(self) -> tuple[list[Entry], Bytes]:
        """What can be taken back with no judgement call, and what that is
        actually worth.

        A file whose inode has a name outside this survey is listed but
        counted at zero: unlinking one of four names frees nothing. That is
        why this returns entries and bytes separately, and why the bytes come
        from the inode tally rather than from a sum of sizes."""
        keep = [e for e in self.entries if self.untouchable(e) is None]
        # An inode is only worth its bytes if every one of its names is going.
        going: dict[tuple[int, int], int] = {}
        for e in keep:
            if not e.symlink:
                going[e.ino_key] = going.get(e.ino_key, 0) + 1
        free = Bytes()
        counted: set[tuple[int, int]] = set()
        for e in keep:
            free.apparent += e.bytes
            if e.symlink or e.ino_key in counted:
                continue
            counted.add(e.ino_key)
            if going.get(e.ino_key, 0) >= e.names_here and not e.shared_outside:
                free.unique += e.bytes
            else:
                free.shared_out += e.bytes
        return keep, free

    def _of_record_rels(self) -> set[str]:
        return {r for v in self.of_record.values() for r in v}

    def strangers(self) -> list[Entry]:
        """Files sitting inside a folder the tool tagged that the tool cannot
        account for: not a frame this shoot knows, not a preset, not the tag.
        Reported every time, removed never. The dog shoot's cull/thumbs holds
        291 of them today - stems with no frame anywhere in that shoot - so
        'tagged means this shoot's rebuildable cache' is already false on
        disk, and a design whose whole licence to delete is the tag would
        have taken them."""
        of_record = self._of_record_rels()
        return [e for e in self.entries
                if e.unowned and e.rel not in of_record and is_cache(e.path.parent)]

    def survivors_in_caches(self) -> list[Entry]:
        """Pixels of record that happen to sit inside a tagged folder. Not
        strangers and not a mistake: this is the lounge, where the tag on
        cull/thumbs is correct for 1 frame and wrong for the 9 whose RAW is
        gone. The tag is a hint about a folder; this is a fact about a
        frame, and the fact wins."""
        return [e for e in self.entries
                if e.rel in self._of_record_rels() and is_cache(e.path.parent)]


# ---- the shape table: what the pipeline writes, and where

def _cache_shape(rel_parts: tuple[str, ...], stem: str, frames: set[str]) -> str | None:
    """Can the pipeline name what wrote this file? Returns the writer, or None.

    This is deliberately narrow. Everything the tool writes into a cache
    folder is <a stem this shoot knows>.jpg, a preset named by presets.build,
    or the tag itself. The dog shoot's cull/thumbs holds 346 files of which 291
    are stems with no frame in that shoot; under this test they have no named
    writer, so no verb touches them and the count is printed instead."""
    if not rel_parts:
        return None
    name = rel_parts[-1]
    if name == TAG:
        return "cache_dir"
    folder = rel_parts[-2] if len(rel_parts) >= 2 else ""
    # reelthumbs/<8 hex>/<stem>.jpg - one folder per planned cut
    if "reelthumbs" in rel_parts:
        folder = "reelthumbs"
    kinds = CACHE_SHAPES.get(folder)
    if kinds is None:
        return None
    if folder == "presets":
        # presets.build writes "Cull NN <scene> ...preset" and nothing else.
        return "presets" if name.startswith("Cull ") and name.endswith(".preset") else None
    if not name.lower().endswith(tuple(JPEG_EXTS)):
        return None
    return kinds if stem in frames else None


def frames_of(shoot: Path) -> set[str]:
    """Every stem this shoot knows about: the RAWs it still has, plus every
    row of cull.csv.

    Keyed on the stem, never on the filename, because the two disagree on
    disk. The lounge shoot's cull.csv is keyed on one frame's .jpg and its
    selects.json on the same frame's .ARW - one frame under two names, because
    the RAWs were cleared after the cull and the decodes took their place."""
    out: set[str] = set()
    try:
        rd = raw_dir(shoot)
    except NotAShoot:
        rd = Path(shoot)
    if rd.is_dir():
        for p in rd.iterdir():
            if p.suffix.lower() in RAW_EXTS | JPEG_EXTS:
                out.add(p.stem)
    csvp = None
    try:
        csvp = cull_dir(shoot) / "cull.csv"
    except NotAShoot:
        pass
    if csvp and csvp.exists():
        import csv as _csv
        try:
            with csvp.open() as fh:
                for r in _csv.DictReader(fh):
                    if r.get("file"):
                        out.add(Path(r["file"]).stem)
        except (OSError, ValueError):
            pass
    return out


def _rel_to(base: Path, p: Path) -> str:
    """A path written relative to `base`, even when it sits beside it rather
    than under it.

    `pl cull` is pointed straight at a raw/ folder, and for such a folder the
    cull lives one level up. Path.relative_to raises there, so surveying the
    lounge shoot's raw/ - the one shoot whose pixels of record are the whole
    point - died with a ValueError instead of answering."""
    try:
        return str(p.relative_to(base))
    except ValueError:
        return os.path.relpath(p, base)


def pixels_of_record(shoot: Path, frames: set[str] | None = None) -> dict[str, list[str]]:
    """For every frame whose original is gone, the surviving pixels, best
    first, as paths relative to the shoot.

    This is the invariant the lounge shoot needed and did not have. It is
    computed from what is on disk - 6 RAWs against 296 culled frames - and
    not declared by a filename, a note or a flag. cull/DO-NOT-CLEAN.txt says
    the same thing in English; nothing reads it, and it only covers the one
    shoot whose photographer happened to think of it."""
    shoot = Path(shoot)
    frames = frames_of(shoot) if frames is None else frames
    try:
        rd, cd = raw_dir(shoot), cull_dir(shoot)
    except NotAShoot:
        return {}
    # A camera JPEG in the originals' folder is the original of that frame,
    # so its thumbnail is not the last copy of anything.
    have_raw = ({p.stem for p in rd.iterdir() if p.suffix.lower() in RAW_EXTS | JPEG_EXTS}
                if rd.is_dir() else set())
    # Best pixels first. decoded is the full-resolution decode; previews is
    # the camera's own 1616 px rendering; large and thumbs are the grid.
    ladder = ("decoded", "full", "previews", "large", "thumbs")
    # Read the names that are on disk rather than guessing one spelling per
    # folder. Guessing `<stem>.jpg` missed twice over, and both misses ended
    # with the last pixels of a frame in the reclaim list:
    #   - a decode written as <stem>.jpeg was never promoted at all, while
    #     _cache_shape happily accepted the same file as a thumbnail the tool
    #     could make again. JPEG_EXTS has held both spellings all along.
    #   - this volume is case-insensitive, so the guessed path matched a file
    #     named <stem>.JPG and then recorded the promotion under the guessed
    #     spelling. No walk ever produces that spelling, so _classify's
    #     membership test never fired and the file was offered.
    # Matching is done on a lowered stem for the same reason.
    want = {s.lower(): s for s in frames - have_raw}
    out: dict[str, list[str]] = {}
    for d in ladder:
        try:
            here = sorted((cd / d).iterdir())
        except OSError:
            continue
        for p in here:
            if p.suffix.lower() not in JPEG_EXTS or p.is_dir():
                continue
            stem = want.get(p.stem.lower())
            if stem is not None:
                out.setdefault(stem, []).append(_rel_to(shoot, p))
    return {s: out[s] for s in sorted(out)}


# Neither his nor the pipeline's. A .DS_Store in export/ was counted as a
# finished export, which is the number the Done card reads.
NOISE = {".DS_Store", ".localized", "Thumbs.db", "desktop.ini"}


def _deliverable(rel: str, name: str) -> str | None:
    parts = rel.split("/")
    if name in NOISE or name.startswith("._"):
        return None
    if rel.startswith(EXPORT_DIRS):
        return "a finished export"
    if "edited" in parts[:-1]:
        # reels/burst54/edited/TSC05183_DxO.jpg - 44 files, 776 MB, and the
        # only copy the gym shoot's finished work has.
        return "a finished export, in a folder he made"
    if parts[0] == "reels" and name.lower().endswith(".mp4"):
        return "a finished reel"
    if name.lower().endswith(("_dxo.jpg", "_dxo.jpeg", "_dxo.tif")):
        return "an export PhotoLab wrote"
    return None


def survey(shoot: Path, follow_links: bool = False) -> Survey:
    """Walk one shoot and say what every file in it is.

    Read-only. It opens cull.csv and shoot.json and stats everything else."""
    shoot = Path(shoot).expanduser().resolve()
    sv = Survey(shoot=shoot, id=shoot_id(shoot), layout=layout(shoot))
    sv.frames = frames_of(shoot)
    sv.of_record = pixels_of_record(shoot, sv.frames)
    if sv.of_record:
        sv.notes.append(f"{len(sv.of_record)} frames have no original left; their surviving "
                        f"pixels are held as {Kind.ORIGINAL.value} and offered to nothing")
    try:
        rawrel = str(raw_dir(shoot).relative_to(shoot)) if raw_dir(shoot) != shoot else ""
    except (NotAShoot, ValueError):
        rawrel = ""
    of_record_rels = {r for v in sv.of_record.values() for r in v}

    counts: dict[tuple[int, int], int] = {}
    entries: list[Entry] = []
    for dirpath, dirnames, filenames in os.walk(shoot, followlinks=follow_links):
        dirnames[:] = [d for d in sorted(dirnames) if d != ".git"]
        d = Path(dirpath)
        for fn in sorted(filenames):
            p = d / fn
            try:
                st = p.lstat()
            except OSError:
                continue
            rel = str(p.relative_to(shoot))
            parts = tuple(rel.split("/"))
            stem = Path(fn).stem
            if stem.endswith(".ARW") or stem.endswith(".arw"):
                stem = Path(stem).stem            # TSC04534.ARW.dop -> TSC04534
            sym = p.is_symlink()
            e = Entry(rel=rel, path=p, kind=Kind.DERIVED, bytes=st.st_size, why="",
                      stem=stem, dev=st.st_dev, inode=st.st_ino, nlink=st.st_nlink, symlink=sym)
            if sym:
                e.target = os.readlink(p)
                e.dangling = not p.exists()
                e.bytes = st.st_size
            else:
                counts[e.ino_key] = counts.get(e.ino_key, 0) + 1
            _classify(e, sv, parts, rawrel, of_record_rels)
            entries.append(e)
    for e in entries:
        if not e.symlink:
            e.names_here = counts.get(e.ino_key, 1)
            # The second half of _classify's link test, which needs the whole
            # walk to answer: a RAW under cull/, edit/ or picks/ is the link
            # gather or the cull made only while the frame it links to is
            # still here. With one name it is a photograph in an odd place,
            # and inside a tagged folder the old verdict handed it a writer
            # and let the guard offer it up.
            if e.kind is Kind.DERIVED and e.path.suffix.lower() in RAW_EXTS and e.names_here < 2:
                e.kind, e.built_by = Kind.ORIGINAL, None
                e.why = f"an original, in {Path(e.rel).parent}, with no other name in this shoot"
    sv.entries = entries
    return sv


def _classify(e: Entry, sv: Survey, parts: tuple[str, ...], rawrel: str, of_record: set[str]) -> None:
    """One file, one verdict. Order matters, and it is the order of how much
    it would hurt to be wrong."""
    name = parts[-1]
    ext = Path(name).suffix.lower()

    # 1. The pixels of record. Before anything else, including the folder
    #    name, because the whole point is that the folder is named 'decoded'.
    if e.rel in of_record:
        e.kind, e.why = Kind.ORIGINAL, f"the only surviving pixels of {e.stem}"
        return

    # 2. A RAW is a photograph wherever it is found. That includes the
    #    calibration folder of the action shoot, where 33 names sit on 3
    #    inodes - 13 versions of one frame, each with its own hand-written
    #    .dop. Any rule that reads 'shares an inode with a RAW' as 'the tool
    #    made it' deletes those, and any identity that collapses them to 3
    #    assets loses 30 of his decisions.
    #
    #    A JPEG in the originals' own folder is a photograph too. The camera
    #    writes them, ingest copies them and the cull reads them; this filed
    #    them as "nothing here wrote it" and then promoted their thumbnails to
    #    the last surviving pixels of a frame whose original was sitting
    #    beside them.
    in_raw = (rawrel and parts[0] == rawrel) or (len(parts) == 1 and sv.layout in ("flat", "raw"))
    if (ext in RAW_EXTS or (ext in JPEG_EXTS and in_raw)) and not e.symlink:
        if in_raw:
            e.kind, e.why = Kind.ORIGINAL, ("an original, in raw/" if rawrel
                                            else "an original, in a folder with no raw/ yet")
        elif parts[0] in ("edit", "cull") or (len(parts) > 1 and parts[-2] == "picks"):
            # Called a link the tool made - but only if the original it is a
            # link to is here as well, which is known once the walk has
            # counted the names of each inode (see survey). On its own it is
            # the only copy of those pixels, whatever folder it sits in.
            e.kind, e.why, e.built_by = Kind.DERIVED, "a link to an original in raw/", "gather/cull"
        else:
            e.kind, e.why = Kind.ORIGINAL, f"an original, in {'/'.join(parts[:-1]) or 'the shoot folder'}"
        return

    # 3. Sidecars. Six point seven megabytes across the whole library and
    #    every one of them carries his hand or the starting edit his hand is
    #    measured against. They are never in the way of anything.
    if ext in SIDECAR_EXTS:
        e.kind, e.why = Kind.DECISION, "a sidecar"
        return

    # 4. Finished work.
    why = _deliverable(e.rel, name)
    if why:
        e.kind, e.why = Kind.DELIVERABLE, why
        return

    # 5. Anything the tool can prove it wrote, inside a folder the tool minted.
    writer = _cache_shape(parts, e.stem, sv.frames)
    if writer and is_cache(e.path.parent):
        e.kind, e.why, e.built_by = Kind.DERIVED, f"written by {writer}", writer
        return

    # 6. The links the cull and gather make. cull.py already knows this
    #    rule: a symlink, or a file on the same inode as a RAW. Note that
    #    the action shoot's cull/picks holds 154 ABSOLUTE SYMLINKS, not hard links -
    #    the brief and two of the three designs assumed hard links, and the
    #    lounge's 28 picks point into cull/decoded, at pixels of record.
    if e.symlink:
        e.kind, e.why, e.built_by = Kind.DERIVED, "a link the cull made", "cull picks"
        if e.dangling:
            e.why = "a link the cull made, pointing at nothing"
        return

    # 7. Everything else. A file at cull/'s top level, a note, a preset he
    #    wrote, a script he wrote, a .DS_Store. It is held as a decision and
    #    it has no named writer, so nothing may delete it and nothing may
    #    move it. Being wrong in this direction costs disk; being wrong in the
    #    other direction cost 154 finished exports once already.
    if name in DECISION_NAMES:
        e.kind, e.why = Kind.DECISION, "a decision file"
    elif name in OUTPUT_NAMES:
        e.kind, e.why = Kind.DECISION, OUTPUT_WHY.get(name, "pipeline output at cull/'s top level")
    elif parts[0] == "cull" and len(parts) == 2:
        e.kind, e.why = Kind.DECISION, "at cull/'s top level, above every cache"
    else:
        e.kind, e.why = Kind.DECISION, "nothing here wrote it"


# ------------------------------------------------------------------ identity
#
# WHAT IS ACTUALLY IN THESE FILES. Read off one frame of the action shoot with
# exiftool, 255 tags. The serial below is made up, as every serial printed in
# this repository is: a camera body is as identifying as a name.
#
#   ImageUniqueID          ABSENT.  Sony does not write it on the ILCE-6500.
#   SerialNumber           ABSENT.
#   InternalSerialNumber   00ff0000aa00        <- the body, and it is stable:
#                          identical on a shoot eleven days earlier and on one
#                          two days later.
#   ShutterCount           4960                <- 4113 on the earlier shoot,
#                          6117 on the later. Monotonic, one per frame, per body.
#   SubSecDateTimeOriginal 2026:09:16 18:26:33-08:00
#   Model                  ILCE-6500
#
# So the camera gives no unique id, but body+count is one, and body+count+time
# is one that also survives a counter reset. The photograph's own bytes give
# another. Neither is enough alone:
#
#   - Bytes alone cannot hold calib-skin: 33 names, 3 inodes, 33 separate
#     hand-made sidecars. Content addressing calls those 3 photographs and
#     silently discards 30 of his decisions.
#   - EXIF alone cannot hold the lounge: 290 of its frames have no RAW left
#     to read EXIF from.
#
# So: a photograph is (shoot, name). Its bytes are a fid, which many
# photographs may share. Its cam_key is a witness, recorded so a frame that
# turns up again on a card or an old drive is recognised before it is trusted.

CHUNK = 1 << 20


def fid_of(path: Path) -> str:
    """sha256 of a file's bytes. 2.4 GB/s on this machine, so 21 seconds for
    the 50 GB library; at ingest it is free, because ingest.copy_hashing
    already computes exactly this and throws it away after verifying."""
    h = hashlib.sha256()
    with Path(path).open("rb") as fh:
        for chunk in iter(lambda: fh.read(CHUNK), b""):
            h.update(chunk)
    return "sha256:" + h.hexdigest()


def short(fid: str) -> str:
    """A handle he can read aloud. Sixteen hex of the full hash, which is
    always kept, so a collision is detectable rather than silent."""
    return fid.split(":")[-1][:16]


EXIF_FIELDS = ("Model", "InternalSerialNumber", "ShutterCount",
               "SubSecDateTimeOriginal", "DateTimeOriginal", "ImageUniqueID")


def exif(paths: list[Path], timeout: int = 600) -> dict[str, dict]:
    """The identity-bearing tags, one exiftool call for the lot. Measured on
    his own frames: 2.3 seconds for 200 ARW batched, about 12 ms a frame, so
    fourteen seconds for the gym shoot and under a minute for the library.
    One at a time it is minutes, because the cost is starting perl.

    Two flags are deliberately NOT here, and both were tried first:

      -fast2  skips the MakerNotes, and InternalSerialNumber and ShutterCount
              are MakerNotes tags. With it, every cam_key in the library came
              back None and nothing said why. -fast alone is no faster than
              no flag on these files (2.27s against 2.32s over 200 frames),
              so there is nothing to buy.
      -n      renders InternalSerialNumber as a run of decimal bytes instead
              of hex. ShutterCount comes back as an integer either
              way, so -n only makes the body's name unreadable.

    Paths go in on stdin. 1,157 absolute paths is 60 KB of argv, and the day
    a shoot is big enough for that to hit ARG_MAX is not a day this should
    fail on."""
    paths = [Path(p) for p in paths]
    if not paths:
        return {}
    cmd = [EXIFTOOL, "-j"] + [f"-{f}" for f in EXIF_FIELDS] + ["-@", "-"]
    try:
        r = subprocess.run(cmd, input="\n".join(str(p) for p in paths), capture_output=True,
                           text=True, timeout=timeout, check=False)
        rows = json.loads(r.stdout) if r.stdout.strip() else []
    except (OSError, ValueError, subprocess.SubprocessError):
        return {}
    return {row.get("SourceFile", ""): row for row in rows}


def cam_key(tags: dict) -> str | None:
    """'ILCE-6500|00ff0000aa00|4960|2026:09:16 18:26:33-08:00'.

    Used to re-bind a frame whose bytes changed - a sidecar embedded, a
    re-ingest from the card, a rewrite by another tool - to the photograph it
    already was. If ImageUniqueID ever does appear it is preferred, because
    then the camera is saying it rather than us inferring it."""
    if tags.get("ImageUniqueID"):
        return f"uid|{tags['ImageUniqueID']}"
    model = tags.get("Model") or tags.get("SonyModelID")
    body = tags.get("InternalSerialNumber")
    count = tags.get("ShutterCount")
    when = tags.get("SubSecDateTimeOriginal") or tags.get("DateTimeOriginal")
    if not (model and count and when):
        return None
    return f"{model}|{body or '?'}|{count}|{when}"


@dataclass
class Asset:
    shoot_id: str
    name: str
    stem: str
    ext: str
    fid: str
    cam_key: str | None
    bytes: int
    shot_at: str | None = None
    state: str = "here"      # here | of_record | missing | archived


def mint(path: Path, shoot: Path, digest: str | None = None, tags: dict | None = None) -> Asset:
    """Give a frame its identity, once, at ingest.

    `digest` is what ingest.py already has in hand from copy_hashing, so
    minting costs a card read of nothing. Passing it is the whole point."""
    path = Path(path)
    st = path.stat()
    fid = digest if (digest or "").startswith("sha256:") else \
        ("sha256:" + digest if digest else fid_of(path))
    t = tags if tags is not None else exif([path]).get(str(path), {})
    return Asset(shoot_id=shoot_id(shoot), name=path.name, stem=path.stem,
                 ext=path.suffix.lower(), fid=fid, cam_key=cam_key(t), bytes=st.st_size,
                 shot_at=str(t.get("SubSecDateTimeOriginal") or t.get("DateTimeOriginal") or "") or None)


@dataclass
class Hit:
    rung: str
    certainty: str          # 'exact' | 'strong' | 'probable' | 'ambiguous'
    shoot_id: str
    name: str
    rel: str
    note: str = ""


def find(con: sqlite3.Connection, *, fid: str | None = None, key: str | None = None,
         sid: str | None = None, name: str | None = None, stem: str | None = None,
         size: int | None = None) -> list[Hit]:
    """Find a photograph again after a rename, a move, or a re-ingest.

    The ladder, strongest rung first. It stops at the first rung that answers,
    and it never merges rungs: an answer from rung 4 is returned marked
    ambiguous rather than being silently narrowed to one row, because the
    camera's counter wraps at TSC09999 and the ducks shoot already starts
    one frame past where the action shoot's last frame left off.

      1  fid       the bytes themselves, exact
      2  cam_key   body + shutter count + capture time, strong
      3  shoot+name  what every command uses today, probable
      4  name      across the whole library, ambiguous by construction
      5  size      last resort, listed and never acted on
    """
    def rows(sql: str, args: tuple) -> list[sqlite3.Row]:
        return list(con.execute(sql, args))

    if fid:
        r = rows("SELECT * FROM asset WHERE fid = ?", (fid,))
        if r:
            return [Hit("fid", "exact", x["shoot_id"], x["name"],
                        _rel(con, x), "one fid, many names: the same bytes under another name"
                        if len(r) > 1 else "") for x in r]
    if key:
        r = rows("SELECT * FROM asset WHERE cam_key = ?", (key,))
        if r:
            # More than one row here is not an ambiguity, it is one exposure
            # wearing several names. Measured on the library: 1,575 of 1,865
            # assets carry a cam_key and 1,542 of those keys are distinct.
            # Every repeated key comes back with exactly twelve names, and
            # they are the action shoot's calib-skin - three frames kept eleven times
            # over, each copy with its own hand-written .dop. The remaining
            # 290 assets carry no key at all: they are the lounge's frames of
            # record, JPEG decodes with no MakerNotes left to read.
            note = "the same exposure, under more than one name" if len(r) > 1 else \
                "body, shutter count and capture time agree"
            return [Hit("cam_key", "strong", x["shoot_id"], x["name"], _rel(con, x), note) for x in r]
    if sid and name:
        r = rows("SELECT * FROM asset WHERE shoot_id = ? AND name = ?", (sid, name))
        if r:
            return [Hit("shoot+name", "probable", x["shoot_id"], x["name"], _rel(con, x)) for x in r]
    if name or stem:
        r = rows("SELECT * FROM asset WHERE name = ? OR stem = ?", (name or "", stem or (Path(name or "").stem)))
        if r:
            note = "more than one shoot has a frame by this name" if len(r) > 1 else ""
            return [Hit("name", "ambiguous" if len(r) > 1 else "probable",
                        x["shoot_id"], x["name"], _rel(con, x), note) for x in r]
    if size:
        r = rows("SELECT * FROM asset WHERE bytes = ?", (size,))
        # Five byte sizes covered 1,066 of one shoot's 1,157 ARW, so this rung
        # reports and is never acted on. ingest.py:place learned that already.
        return [Hit("size", "ambiguous", x["shoot_id"], x["name"], _rel(con, x),
                    "size is not identity on this camera") for x in r]
    return []


def _rel(con: sqlite3.Connection, asset: sqlite3.Row) -> str:
    """Where that photograph was last seen, in full. The shoot's path is
    advisory - he moves folders in Finder and the catalogue finds out at the
    next rebuild - so this is a place to go and look, never a promise."""
    shoot = con.execute("SELECT path FROM shoot WHERE id = ?", (asset["shoot_id"],)).fetchone()
    base = shoot["path"] if shoot else "?"
    # The underscore is a wildcard in LIKE, and 33 of the gym's names carry
    # one: TSC04534_1base.ARW would match TSC04534-1base.ARW just as happily,
    # and calib-skin is precisely where several names sit on the same frame.
    # An answer that says "go and look here" has to name the right file.
    pattern = "%" + "".join("\\" + c if c in "\\%_" else c for c in asset["name"])
    here = con.execute("SELECT rel FROM file WHERE shoot_id = ? AND kind = 'original' "
                       "AND rel LIKE ? ESCAPE '\\' ORDER BY length(rel) LIMIT 1",
                       (asset["shoot_id"], pattern)).fetchone()
    return f"{base}/{here['rel'] if here else asset['name']}"


# ----------------------------------------------------------------- catalogue
#
# The folders are the truth. This is an index over them, and every column in
# it was read out of a file that is still there. `rebuild` makes it again from
# nothing in one pass, so deleting it on purpose, mid-shoot, loses a person
# nothing but the time of the next rebuild. That is the only condition under
# which a database is allowed anywhere near these photographs: DxO's own
# catalogue is not trusted here either - he froze a copy of it into attic by
# hand on 17 September rather than rely on it.

SCHEMA = """
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS shoot (
  id        TEXT PRIMARY KEY,       -- shoot.json "id", else the old path hash
  legacy_id TEXT,                   -- sha1(abs path)[:12]: what taste.json keys on
  path      TEXT NOT NULL,          -- ADVISORY. A stale path means go and look.
  label     TEXT,
  layout    TEXT NOT NULL,
  seen_at   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS asset (            -- one photograph = one name in one shoot
  shoot_id TEXT NOT NULL REFERENCES shoot(id) ON DELETE CASCADE,
  name     TEXT NOT NULL,
  stem     TEXT NOT NULL,
  ext      TEXT NOT NULL,
  fid      TEXT,                    -- 'sha256:...' of the bytes. NULL until hashed.
  cam_key  TEXT,                    -- body | shutter count | capture time
  bytes    INTEGER NOT NULL,
  shot_at  TEXT,
  state    TEXT NOT NULL,           -- here | of_record | missing | archived
  volume   TEXT,                    -- the drive's label when state = 'archived'
  PRIMARY KEY (shoot_id, name)
);
CREATE INDEX IF NOT EXISTS asset_fid  ON asset(fid);
CREATE INDEX IF NOT EXISTS asset_cam  ON asset(cam_key);
CREATE INDEX IF NOT EXISTS asset_name ON asset(name);
CREATE INDEX IF NOT EXISTS asset_stem ON asset(stem);

CREATE TABLE IF NOT EXISTS file (             -- every name on disk, links included
  shoot_id   TEXT NOT NULL REFERENCES shoot(id) ON DELETE CASCADE,
  rel        TEXT NOT NULL,
  kind       TEXT NOT NULL,         -- original | decision | derived | deliverable
  why        TEXT NOT NULL,         -- in prose, for the person reading the table
  bytes      INTEGER NOT NULL,
  dev        INTEGER,               -- the volume; an inode is only unique on one
  inode      INTEGER,
  nlink      INTEGER,
  names_here INTEGER,               -- names of this inode inside the library
  symlink    INTEGER NOT NULL DEFAULT 0,
  target     TEXT,
  built_by   TEXT,                  -- NULL means nothing can name its writer
  stem       TEXT,
  PRIMARY KEY (shoot_id, rel)
);
CREATE INDEX IF NOT EXISTS file_inode ON file(dev, inode);
CREATE INDEX IF NOT EXISTS file_kind  ON file(kind);

CREATE TABLE IF NOT EXISTS decision (         -- his, recorded, never held only here
  shoot_id TEXT NOT NULL REFERENCES shoot(id) ON DELETE CASCADE,
  rel      TEXT NOT NULL,
  bytes    INTEGER NOT NULL,
  sha256   TEXT NOT NULL,
  mtime    REAL NOT NULL,
  PRIMARY KEY (shoot_id, rel)
);

CREATE TABLE IF NOT EXISTS of_record (        -- frames whose original is gone
  shoot_id TEXT NOT NULL REFERENCES shoot(id) ON DELETE CASCADE,
  stem     TEXT NOT NULL,
  rel      TEXT NOT NULL,           -- surviving pixels, best first
  seq      INTEGER NOT NULL,
  PRIMARY KEY (shoot_id, stem, seq)
);
"""

SCHEMA_VERSION = 2   # 2: file.dev, so an inode number is read against its volume


def _schema_version(con: sqlite3.Connection) -> int | None:
    """What version made this file, or None when it is new or unreadable."""
    try:
        row = con.execute("SELECT value FROM meta WHERE key = 'schema'").fetchone()
        return int(row["value"]) if row else None
    except (sqlite3.Error, TypeError, ValueError):
        return None


def connect(db: Path | str = None) -> sqlite3.Connection:
    """Open the catalogue, making it if it is not there.

    WAL and synchronous=NORMAL: a crash can lose the last few rows of an
    index, which the next rebuild replaces, and cannot corrupt the file. The
    decisions themselves never live here - see `decision`, which stores a
    hash and a size so drift is visible, and not the content, so this file can
    never become the only copy of anything."""
    path = Path(db) if db else Path(ROOT) / "library.db"
    if str(path) != ":memory:":
        path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(path))
    con.row_factory = sqlite3.Row
    # An index made by an older schema is thrown away rather than repaired.
    # CREATE TABLE IF NOT EXISTS leaves an existing table exactly as it was,
    # so the day `file` gained its `dev` column every INSERT against a
    # catalogue made by the previous version would have failed, for ever, on
    # the one machine that had run both. Nothing is lost by dropping it:
    # every column in here was read out of a file that is still there, and
    # `rebuild` makes the whole thing again in one stat-only pass.
    have = _schema_version(con)
    if have is not None and have != SCHEMA_VERSION:
        for table in ("file", "asset", "decision", "of_record", "shoot", "meta"):
            con.execute(f"DROP TABLE IF EXISTS {table}")
    con.executescript(SCHEMA)
    con.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('schema', ?)", (str(SCHEMA_VERSION),))
    con.commit()
    return con


def rebuild(root: Path | None = None, db: Path | str = ":memory:", hash_originals: bool = False,
            read_exif: bool = False, progress=None) -> sqlite3.Connection:
    """Make the whole catalogue again from the folders.

    Reads the library; writes only the database. Two passes are optional
    because they are the expensive ones: `hash_originals` is one full read of
    every original (about 21 seconds for 50 GB on this machine, minutes off a
    USB drive), and `read_exif` is one batched exiftool call per shoot.
    Without them a rebuild is a stat-only walk, which is what makes it
    reasonable to throw the file away whenever it is doubted."""
    root = Path(root or ROOT)
    con = connect(db)
    con.execute("DELETE FROM file")
    con.execute("DELETE FROM asset")
    con.execute("DELETE FROM decision")
    con.execute("DELETE FROM of_record")
    con.execute("DELETE FROM shoot")
    now = int(time.time())
    seen_ids: set[str] = set()
    for sh in shoots(root):
        sv = survey(sh)
        # Two folders can carry the same shoot.json "id" - copy a shoot to
        # attic as a freeze, work on the copy, put it back under another
        # name, and there are two. Both then write to the same primary key
        # and the second silently replaces the first: the index loses a whole
        # shoot, and `find` answers with the wrong folder, which is the one
        # question this file exists to get right. The path hash cannot
        # collide, so the later folder falls back to it and says so.
        if sv.id in seen_ids:
            sv.notes.append(f"another shoot already claims the id {sv.id}; indexed under its "
                            f"path hash {legacy_shoot_id(sh)} instead - go and look at both")
            sv.id = legacy_shoot_id(sh)
        seen_ids.add(sv.id)
        if progress:
            progress(sh, sv)
        con.execute("INSERT OR REPLACE INTO shoot VALUES (?,?,?,?,?,?)",
                    (sv.id, legacy_shoot_id(sh), str(sh), meta(sh).get("label"), sv.layout, now))
        con.executemany(
            "INSERT OR REPLACE INTO file VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            [(sv.id, e.rel, e.kind.value, e.why, e.bytes, e.dev, e.inode, e.nlink, e.names_here,
              int(e.symlink), e.target or None, e.built_by, e.stem) for e in sv.entries])
        con.executemany(
            "INSERT OR REPLACE INTO of_record VALUES (?,?,?,?)",
            [(sv.id, stem, rel, i) for stem, rels in sv.of_record.items() for i, rel in enumerate(rels)])

        originals = [e for e in sv.entries if e.kind is Kind.ORIGINAL and not e.symlink]
        tags = exif([e.path for e in originals]) if read_exif else {}
        rows = []
        for e in originals:
            t = tags.get(str(e.path), {})
            state = "of_record" if e.stem in sv.of_record else "here"
            rows.append((sv.id, Path(e.rel).name, e.stem, e.path.suffix.lower(),
                         fid_of(e.path) if hash_originals else None, cam_key(t) if t else None,
                         e.bytes, str(t.get("SubSecDateTimeOriginal") or t.get("DateTimeOriginal") or "") or None,
                         state, None))
        con.executemany("INSERT OR REPLACE INTO asset VALUES (?,?,?,?,?,?,?,?,?,?)", rows)

        # Decisions get a hash whatever the flags say. They are 1.1 MB of JSON
        # and 6.7 MB of sidecars across the library; refusing to hash those to
        # save a second would be refusing to notice the one kind of drift that
        # matters.
        dec = []
        for e in sv.entries:
            if e.kind is not Kind.DECISION or e.symlink or e.bytes > (4 << 20):
                continue
            try:
                dec.append((sv.id, e.rel, e.bytes, fid_of(e.path).split(":")[1], e.path.stat().st_mtime))
            except OSError:
                continue
        con.executemany("INSERT OR REPLACE INTO decision VALUES (?,?,?,?,?)", dec)
    con.commit()
    # Fold the write-ahead log back into the file itself, so the catalogue on
    # disk is one file and not three. WAL is right for the writes; a library
    # someone might copy to a drive should not depend on a -wal beside it.
    try:
        con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    except sqlite3.DatabaseError:
        pass
    return con


def drift(con: sqlite3.Connection, root: Path | None = None) -> list[str]:
    """Where the catalogue and the disk disagree about a decision. A line here
    is a prompt to go and look, never an error and never a licence."""
    out = []
    for row in con.execute("SELECT s.path, d.rel, d.sha256, d.bytes FROM decision d JOIN shoot s ON s.id = d.shoot_id"):
        p = Path(row["path"]) / row["rel"]
        if not p.exists():
            out.append(f"gone: {p}")
        elif p.stat().st_size != row["bytes"] or fid_of(p).split(":")[1] != row["sha256"]:
            out.append(f"changed since the catalogue was built: {p}")
    return out


# ---------------------------------------------------------------- the shelf
#
# Insisted on by the lens that asked which of these he would enjoy using:
# finding last March's reel should be one Finder window sorted by name, not a
# command. reels/ is not split - splitting it would move 1.26 GB of exports
# that exist in exactly one place - so a second NAME is added instead. A hard
# link inside one volume costs zero bytes, breaks no path, and leaves
# spread.py's hardcoded shoot/reels/burst<N> and reel.py's recursive walk of
# EXPORT_DIRS alone. It is the same trick cull/picks is already made of.

def shelf_plan(root: Path | None = None) -> list[tuple[Path, str]]:
    """Every finished reel in the library and the name it would take on the
    shelf: <date-name>-<label>-cut<N>.mp4. Derivable, so the shelf is
    rebuildable and never the only copy of anything."""
    root = Path(root or ROOT)
    out = []
    for sh in shoots(root):
        reels = sh / "reels"
        if not reels.is_dir():
            continue
        label = (meta(sh).get("label") or "").split(",")[0].strip().replace(" ", "-").lower()
        for mp4 in sorted(reels.glob("*.mp4")):
            name = f"{sh.name}-{label + '-' if label else ''}{mp4.stem.split('-')[-1]}{mp4.suffix}"
            out.append((mp4, name))
    return out


def shelve(dest: Path, plan: list[tuple[Path, str]]) -> list[str]:
    """Lay the shelf out at `dest` as hard links. Never copies, never moves,
    never removes: a name that is already there and already points at the same
    inode is left alone, and one that points elsewhere is reported rather than
    replaced."""
    dest = Path(dest)
    dest.mkdir(parents=True, exist_ok=True)
    made = []
    for src, name in plan:
        dst = dest / name
        if dst.exists():
            # (st_dev, st_ino), because the shelf is the one thing here that
            # is expected to sit on another volume, and inode numbers repeat
            # across volumes. On the number alone, an unrelated file on the
            # shelf's own disk answered "already linked" and the name was
            # passed over in silence. Either way the reel is not shelved -
            # os.link cannot cross a volume - but he is told which name is in
            # the way instead of finding the shelf short by one.
            a, b = dst.stat(), src.stat()
            if (a.st_dev, a.st_ino) != (b.st_dev, b.st_ino):
                made.append(f"left alone, it is not the same file: {dst}")
            continue
        try:
            os.link(src, dst)
            made.append(f"{name} -> {src}")
        except OSError as err:
            made.append(f"could not link {name}: {err}")
    return made


# -------------------------------------------------------------------- report

def report(sv: Survey) -> str:
    lines = [f"{sv.shoot.name}  [{sv.layout}]  id {sv.id}"]
    for kind, b in sv.by_kind().items():
        n = sum(1 for e in sv.entries if e.kind is kind)
        if n:
            lines.append(f"  {kind.value:<12} {n:>6} files  {str(b):>26}")
    keep, free = sv.reclaimable()
    lines.append(f"  {'reclaimable':<12} {len(keep):>6} files  {human(free.unique):>12} freed"
                 + (f", {human(free.shared_out)} shared with a name elsewhere" if free.shared_out else ""))
    out = [e for e in sv.entries if not e.symlink and e.shared_outside]
    if out:
        b = Bytes()
        seen: set[tuple[int, int]] = set()
        for e in out:
            if e.ino_key not in seen:
                seen.add(e.ino_key)
                b.unique += e.bytes
        lines.append(f"  {len(out)} files report a name this walk cannot see ({human(b.unique)}); "
                     f"those bytes are never counted as reclaimable")
    n = len(sv.strangers())
    if n:
        lines.append(f"  {n} file{'s' if n != 1 else ''} in a tagged folder "
                     f"{'have' if n != 1 else 'has'} no named writer; left in place")
    n = len(sv.survivors_in_caches())
    if n:
        lines.append(f"  {n} file{'s' if n != 1 else ''} in a tagged folder "
                     f"{'are' if n != 1 else 'is'} the last pixels of a frame; held as original")
    for note in sv.notes:
        lines.append(f"  note: {note}")
    return "\n".join(lines)


# ------------------------------------------------------------------ selftest

def _selftest() -> int:
    """A fixture built in a temp directory that carries every shape measured
    in the real library, then the assertions each of those shapes earned.

    Nothing here reads or writes ~/photos."""
    import shutil
    import tempfile
    tmp = Path(tempfile.mkdtemp(prefix="library-selftest-"))
    ok = 0
    try:
        root = tmp / "photos"
        (root / "shoots").mkdir(parents=True)

        # --- a standard shoot, laid out like the action shoot ------------
        gym = root / "shoots" / "2026-01-16-action"
        (gym / "raw").mkdir(parents=True)
        stems = [f"TSC{n:05d}" for n in range(4534, 4544)]
        for s in stems:
            (gym / "raw" / f"{s}.ARW").write_bytes(b"RAW" + s.encode() + b"\0" * 4096)
            (gym / "raw" / f"{s}.ARW.dop").write_text("Sidecar = {}\n")
        (gym / "shoot.json").write_text(json.dumps({"label": "an action shoot", "style": "action"}))
        (gym / "cull").mkdir()
        (gym / "cull" / "cull.csv").write_text("file,rating\n" + "".join(f"{s}.ARW,3\n" for s in stems))
        for f in ("organize.json", "selects.json", "labels.json", "spread.json"):
            (gym / "cull" / f).write_text("{}")
        for d in ("thumbs", "previews", "decoded", "large"):
            cache_dir(gym / "cull" / d, built_by="selftest")
            for s in stems:
                (gym / "cull" / d / f"{s}.jpg").write_bytes(b"J" * 2048)
        # a stem this shoot has never heard of, inside a tagged folder:
        # the dog shoot's cull/thumbs holds 291 of these today.
        (gym / "cull" / "thumbs" / "TSC09999.jpg").write_bytes(b"J" * 2048)
        # picks are ABSOLUTE SYMLINKS, as measured, not hard links
        (gym / "cull" / "picks").mkdir()
        for s in stems[:4]:
            (gym / "cull" / "picks" / f"{s}.ARW").symlink_to(gym / "raw" / f"{s}.ARW")
        (gym / "cull" / "picks" / f"{stems[0]}.ARW.dop").write_text("Sidecar = { hand }\n")
        # edit/ is hard links, and edit/edited/ is his
        (gym / "edit").mkdir()
        for s in stems[:4]:
            os.link(gym / "raw" / f"{s}.ARW", gym / "edit" / f"{s}.ARW")
        (gym / "edit" / "edited").mkdir()
        (gym / "edit" / "edited" / f"{stems[0]}_DxO.jpg").write_bytes(b"X" * 9000)
        (gym / "export").mkdir()
        # reels: deliverables and staging mixed, with exports inside the staging
        (gym / "reels" / "burst54" / "edited").mkdir(parents=True)
        (gym / "reels" / "2026-01-16-action-cut54.mp4").write_bytes(b"M" * 5000)
        for s in stems[4:6]:
            os.link(gym / "raw" / f"{s}.ARW", gym / "reels" / "burst54" / f"{s}.ARW")
            (gym / "reels" / "burst54" / f"{s}.ARW.dop").write_text("Sidecar = { his }\n")
            (gym / "reels" / "burst54" / "edited" / f"{s}_DxO.jpg").write_bytes(b"X" * 11000)
        # calib-skin: many names, one inode, one hand-made sidecar each
        (gym / "calib-skin").mkdir()
        for tag in ("1base", "2noclearview", "3clearview5"):
            os.link(gym / "raw" / f"{stems[0]}.ARW", gym / "calib-skin" / f"{stems[0]}_{tag}.ARW")
            (gym / "calib-skin" / f"{stems[0]}_{tag}.ARW.dop").write_text(f"Sidecar = {{ {tag} }}\n")

        # --- the lounge: RAWs cleared, decodes are the only pixels --------
        lounge = root / "shoots" / "2026-01-12-lounge"
        (lounge / "raw").mkdir(parents=True)
        lstems = [f"TSC{n:05d}" for n in range(4015, 4025)]
        (lounge / "raw" / f"{lstems[0]}.ARW").write_bytes(b"RAW" + b"\0" * 4096)
        (lounge / "cull").mkdir()
        (lounge / "cull" / "cull.csv").write_text("file,rating\n" + "".join(f"{s}.jpg,3\n" for s in lstems))
        (lounge / "cull" / "DO-NOT-CLEAN.txt").write_text("NOT A CACHE.\n")
        for d in ("decoded", "previews"):
            (lounge / "cull" / d).mkdir()          # deliberately NOT tagged
            for s in lstems:
                (lounge / "cull" / d / f"{s}.jpg").write_bytes(b"P" * 3000)
        cache_dir(lounge / "cull" / "thumbs", built_by="selftest")
        for s in lstems:
            (lounge / "cull" / "thumbs" / f"{s}.jpg").write_bytes(b"t" * 500)
        (lounge / "cull" / "picks").mkdir()
        (lounge / "cull" / "picks" / f"{lstems[1]}.jpg").symlink_to(lounge / "cull" / "decoded" / f"{lstems[1]}.jpg")

        # --- a flat shoot: loose RAWs, no raw/, no shoot.json ------------
        ducks = root / "shoots" / "loose-frames"
        ducks.mkdir()
        for n in range(5691, 5696):
            (ducks / f"TSC{n}.ARW").write_bytes(b"RAW" + b"\0" * 4096)
            (ducks / f"TSC{n}.ARW.dop").write_text("Sidecar = { his }\n")

        # --- the two shapes that sit beside shoots/ at the library's top ---
        # The folder of loose frames beside shoots/ is 29 loose ARW and is a
        # shoot. fixtures is a shelf: it holds frames only through the folders
        # inside it, one of which has a raw/. Neither is decided by its name.
        nsfw = root / "beside-shoots"
        nsfw.mkdir()
        for n in range(3490, 3493):
            (nsfw / f"TSC{n}.ARW").write_bytes(b"RAW" + b"\0" * 4096)
        (root / "fixtures" / "faces").mkdir(parents=True)
        (root / "fixtures" / "faces" / "TSC03714.jpg").write_bytes(b"J" * 512)
        (root / "fixtures" / "selftest" / "raw").mkdir(parents=True)
        (root / "fixtures" / "selftest" / "raw" / "TSC00001.ARW").write_bytes(b"RAW" + b"\0" * 512)

        def check(label: str, cond: bool, detail: str = "") -> None:
            nonlocal ok
            print(f"  {'ok  ' if cond else 'FAIL'}  {label}{(': ' + detail) if detail else ''}")
            if cond:
                ok += 1
            else:
                raise AssertionError(label)

        print("\nresolution")
        check("a standard shoot resolves to raw/ and cull/",
              raw_dir(gym) == gym / "raw" and cull_dir(gym) == gym / "cull")
        check("a folder of loose RAWs resolves instead of being invisible",
              layout(ducks) == "flat" and raw_dir(ducks) == ducks and cull_dir(ducks) == ducks / "cull")
        check("pointing straight at raw/ still works, as `pl cull` does",
              raw_dir(gym / "raw") == gym / "raw" and cull_dir(gym / "raw") == gym / "cull")
        try:
            raw_dir(tmp / "nothing-here")
            check("an empty folder refuses instead of guessing", False)
        except NotAShoot:
            check("an empty folder refuses instead of guessing", True)
        check("every shoot is found, including the two with no shoot.json",
              [p.name for p in shoots(root)] == ["2026-01-12-lounge", "2026-01-16-action",
                                                 "loose-frames", "beside-shoots"],
              str([p.name for p in shoots(root)]))
        check("a folder of loose RAWs beside shoots/ is one of them",
              not holds_shoots(nsfw) and layout(nsfw) == "flat")
        check("and a shelf that holds a shoot is not, whatever it is called",
              holds_shoots(root / "fixtures") and root / "fixtures" not in shoots(root))
        check("a shoot's own raw/, cull/ and edit/ do not make it a shelf",
              not holds_shoots(gym) and not holds_shoots(ducks))
        check("a shoot with no id falls back to the hash taste.json keys on",
              shoot_id(gym) == legacy_shoot_id(gym))
        (gym / "shoot.json").write_text(json.dumps({"label": "an action shoot", "id": "ebd2907e56f1"}))
        check("an id in shoot.json survives a rename", shoot_id(gym) == "ebd2907e56f1")

        sv = survey(gym)
        rels = {e.rel: e for e in sv.entries}

        print("\nclassification")
        check("a RAW in raw/ is an original", rels["raw/TSC04534.ARW"].kind is Kind.ORIGINAL)
        check("a sidecar is a decision", rels["raw/TSC04534.ARW.dop"].kind is Kind.DECISION)
        check("a thumbnail the tool wrote is derived and names its writer",
              rels["cull/thumbs/TSC04534.jpg"].kind is Kind.DERIVED
              and rels["cull/thumbs/TSC04534.jpg"].built_by == "cull thumbs")
        check("a stranger in a tagged folder has no named writer",
              rels["cull/thumbs/TSC09999.jpg"].unowned)
        check("cull/selects.json sits above every tag and is a decision",
              rels["cull/selects.json"].kind is Kind.DECISION)
        check("a hand-edited .dop left in cull/picks is a decision, not a pick",
              rels["cull/picks/TSC04534.ARW.dop"].kind is Kind.DECISION)
        check("a finished export in edit/edited/ is a deliverable",
              rels["edit/edited/TSC04534_DxO.jpg"].kind is Kind.DELIVERABLE)
        check("a finished export inside reels/burst54/edited/ is a deliverable too",
              rels["reels/burst54/edited/TSC04538_DxO.jpg"].kind is Kind.DELIVERABLE)
        check("the finished reel is a deliverable", rels["reels/2026-01-16-action-cut54.mp4"].kind is Kind.DELIVERABLE)
        check("many names on one inode stay many photographs (calib-skin: 33 on 3)",
              sum(1 for e in sv.entries if e.rel.startswith("calib-skin/") and e.kind is Kind.ORIGINAL) == 3
              and sum(1 for e in sv.entries if e.rel.startswith("calib-skin/") and e.kind is Kind.DECISION) == 3)

        print("\nthe guard, on delete and on move alike")
        keep, free = sv.reclaimable()
        kept = {e.rel for e in keep}
        for bad in ("edit/edited/TSC04534_DxO.jpg", "reels/burst54/edited/TSC04538_DxO.jpg",
                    "reels/burst54/TSC04538.ARW.dop", "cull/selects.json", "raw/TSC04534.ARW",
                    "cull/thumbs/TSC09999.jpg", "calib-skin/TSC04534_1base.ARW"):
            check(f"untouchable: {bad}", bad not in kept, sv.untouchable(rels[bad]) or "")
        check("the caches the tool minted are reclaimable",
              "cull/decoded/TSC04534.jpg" in kept and "cull/thumbs/TSC04534.jpg" in kept)
        check("the stranger in the tagged folder is named in the report, not deleted",
              [e.rel for e in sv.strangers()] == ["cull/thumbs/TSC09999.jpg"])

        print("\nhard links and symlinks")
        edit_link = rels["edit/TSC04534.ARW"]
        check("edit/ is a hard link to raw/, on the same volume and inode",
              edit_link.ino_key == rels["raw/TSC04534.ARW"].ino_key and edit_link.names_here >= 2,
              f"{edit_link.names_here} names of inode {edit_link.ino_key}")
        check("cull/picks is a symlink, not a hard link, as measured on disk",
              rels["cull/picks/TSC04534.ARW"].symlink)
        b = sv.bytes(Kind.ORIGINAL)
        raw_only = sum((gym / "raw" / f"{s}.ARW").stat().st_size for s in stems)
        check("originals are counted once however many names they have",
              b.unique == raw_only and b.apparent > b.unique,
              f"unique {b.unique} vs apparent {b.apparent}")
        check("a link to a RAW frees nothing, and says so",
              free.unique == sum(e.bytes for e in keep if not e.symlink and e.names_here == 1))

        print("\nthe lounge: pixels that survive in a folder spelled like a cache")
        lv = survey(lounge)
        lrels = {e.rel: e for e in lv.entries}
        check("a frame with no RAW promotes its decode to an original (the lounge: 290)",
              len(lv.of_record) == 9 and lrels["cull/decoded/TSC04016.jpg"].kind is Kind.ORIGINAL,
              f"{len(lv.of_record)} frames of record")
        check("the previews of those frames are originals too",
              lrels["cull/previews/TSC04016.jpg"].kind is Kind.ORIGINAL)
        lkeep, lfree = lv.reclaimable()
        check("nothing in decoded/ or previews/ is offered",
              not any(r.startswith(("cull/decoded", "cull/previews")) for r in {e.rel for e in lkeep}))
        check("the tagged thumbs of the same shoot still are",
              any(e.rel.startswith("cull/thumbs/TSC") for e in lkeep), human(lfree.unique))
        check("the frame that still has its RAW is not a frame of record",
              lstems[0] not in lv.of_record)
        check("a tagged folder holding last pixels is reported as that, not as a stranger",
              len(lv.survivors_in_caches()) == 9 and lv.strangers() == [],
              f"{len(lv.survivors_in_caches())} survivors inside cull/thumbs")
        # and the proof that this is computed, not read out of his note
        (lounge / "cull" / "DO-NOT-CLEAN.txt").unlink()
        lv2 = survey(lounge)
        check("removing his note changes nothing", len(lv2.of_record) == len(lv.of_record))

        print("\nidentity")
        a = mint(gym / "raw" / f"{stems[0]}.ARW", gym, tags={})
        check("a frame's fid is the sha256 of its bytes",
              a.fid == fid_of(gym / "raw" / f"{stems[0]}.ARW") and a.fid.startswith("sha256:"))
        check("minting from the digest ingest already has reads nothing",
              mint(gym / "raw" / f"{stems[0]}.ARW", gym, digest=a.fid, tags={}).fid == a.fid)
        check("cam_key is built from what a Sony ARW actually carries",
              cam_key({"Model": "ILCE-6500", "InternalSerialNumber": "00ff0000aa00",
                       "ShutterCount": 4960, "SubSecDateTimeOriginal": "2026:09:16 18:26:33-08:00"})
              == "ILCE-6500|00ff0000aa00|4960|2026:09:16 18:26:33-08:00")
        check("with no ImageUniqueID, no serial and no count, it says so rather than inventing one",
              cam_key({"Model": "ILCE-6500"}) is None)

        print("\ncatalogue")
        con = rebuild(root, db=tmp / "library.db")
        nshoots = con.execute("SELECT count(*) c FROM shoot").fetchone()["c"]
        nfiles = con.execute("SELECT count(*) c FROM file").fetchone()["c"]
        check("it holds all four shoots and every file", nshoots == 4 and nfiles == len(sv.entries)
              + len(lv2.entries) + len(survey(ducks).entries) + len(survey(nsfw).entries),
              f"{nshoots} shoots, {nfiles} files")
        check("and nothing from the shelf beside them",
              not con.execute("SELECT 1 FROM file WHERE rel LIKE '%faces%'").fetchone())
        old_db = tmp / "old.db"
        c0 = sqlite3.connect(str(old_db))
        c0.executescript("CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);"
                         "CREATE TABLE file(shoot_id TEXT, rel TEXT);"
                         "INSERT INTO meta VALUES('schema','1');")
        c0.commit()
        c0.close()
        c1 = connect(old_db)
        cols = {r["name"] for r in c1.execute("PRAGMA table_info(file)")}
        check("a catalogue made by an older schema is thrown away and made again",
              "dev" in cols and _schema_version(c1) == SCHEMA_VERSION, str(sorted(cols)))
        c1.close()
        check("every decision has a hash on record",
              con.execute("SELECT count(*) c FROM decision").fetchone()["c"] > 0)
        check("the frames of record are in the catalogue as well as on disk",
              con.execute("SELECT count(DISTINCT stem) c FROM of_record").fetchone()["c"] == 9)
        # identity ladder
        con2 = rebuild(root, db=tmp / "library2.db", hash_originals=True)
        fid = con2.execute("SELECT fid FROM asset WHERE name = ?", (f"{stems[0]}.ARW",)).fetchone()["fid"]
        hits = find(con2, fid=fid)
        check("rung 1 finds a frame by its bytes, and every name those bytes wear",
              hits and hits[0].rung == "fid" and len(hits) == 4, f"{len(hits)} names")
        hits = find(con2, sid=shoot_id(gym), name=f"{stems[1]}.ARW")
        check("rung 3 finds it by shoot and name", hits and hits[0].rung == "shoot+name")
        check("rung 4 says so when a name is not unique",
              all(h.certainty in ("probable", "ambiguous") for h in find(con2, name=f"{stems[1]}.ARW")))
        check("nothing was written into the shoots by the catalogue",
              not list(root.rglob("*.db")) and not list(root.rglob("*-wal")))
        # the rebuild really is a rebuild
        before = [tuple(r) for r in con2.execute("SELECT shoot_id, rel, kind FROM file ORDER BY 1,2")]
        con2.close()
        (tmp / "library2.db").unlink()
        con3 = rebuild(root, db=tmp / "library2.db", hash_originals=True)
        after = [tuple(r) for r in con3.execute("SELECT shoot_id, rel, kind FROM file ORDER BY 1,2")]
        check("deleting the catalogue and making it again gives the same answer", before == after)
        check("drift is silent when nothing has drifted", drift(con3, root) == [])
        (gym / "cull" / "selects.json").write_text('{"changed": true}')
        check("drift speaks up when a decision file changes under it",
              any("selects.json" in line for line in drift(con3, root)))
        con.close()
        con3.close()

        print("\ntwo volumes, one inode number")
        # The failure the (st_dev, st_ino) key exists to prevent, built by
        # hand because it takes two disks to meet it any other way: an
        # archived shoot on an external drive whose frame happens to wear the
        # same inode number as one on the boot volume. On st_ino alone the
        # second is charged nothing and the library reads short by its size.
        twin = [Entry(rel="raw/A.ARW", path=gym / "raw" / f"{stems[0]}.ARW", kind=Kind.ORIGINAL,
                      bytes=1000, why="", dev=16777232, inode=7),
                Entry(rel="raw/B.ARW", path=gym / "raw" / f"{stems[1]}.ARW", kind=Kind.ORIGINAL,
                      bytes=1000, why="", dev=16777233, inode=7)]
        tsv = Survey(shoot=gym, id="two-volumes", layout="standard", entries=twin)
        check("a frame on another volume is not mistaken for one already counted",
              tsv.bytes(Kind.ORIGINAL).unique == 2000, str(tsv.bytes(Kind.ORIGINAL)))
        check("and it is not mistaken for a second name of it either",
              len(tsv.owner()) == 2, str(tsv.owner()))

        print("\nthe shelf")
        plan = shelf_plan(root)
        made = shelve(tmp / "shelf", plan)
        shelf = sorted(p.name for p in (tmp / "shelf").iterdir())
        check("a finished reel gets a second name and keeps its first",
              len(shelf) == 1 and (gym / "reels" / "2026-01-16-action-cut54.mp4").exists()
              and (tmp / "shelf" / shelf[0]).stat().st_ino
              == (gym / "reels" / "2026-01-16-action-cut54.mp4").stat().st_ino, f"{shelf} {made}")

        print(f"\n{ok} checks passed")
        print("\n" + report(sv))
        print(report(lv2))
        print(report(survey(ducks)))
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser(description="the library: what is where, and what may be taken back")
    ap.add_argument("--selftest", action="store_true", help="build a fixture in a temp folder and check it")
    ap.add_argument("--survey", nargs="?", const="", metavar="SHOOT",
                    help="read-only: classify one shoot, or the whole library")
    ap.add_argument("--root", type=Path, default=None)
    args = ap.parse_args()
    if args.selftest:
        return _selftest()
    if args.survey is not None:
        root = args.root or ROOT
        targets = [Path(args.survey).expanduser().resolve()] if args.survey else shoots(root)
        total = Bytes()
        for sh in targets:
            sv = survey(sh)
            print(report(sv))
            _, free = sv.reclaimable()
            total.unique += free.unique
            total.shared_out += free.shared_out
        print(f"\nreclaimable across {len(targets)} shoots: {human(total.unique)}"
              + (f" (a further {human(total.shared_out)} is shared with a name this walk cannot see)"
                 if total.shared_out else ""))
        return 0
    ap.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
