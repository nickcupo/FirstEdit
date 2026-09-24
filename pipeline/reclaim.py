#!/usr/bin/env python3
"""
reclaim.py - what each shoot costs, what of that is safe to take back, and
whether the originals are still the bytes they were.

    ./pl reclaim report                        every shoot in the library, split four ways
    ./pl reclaim reclaim <shoot> [--apply]     take back derived bytes and nothing else
    ./pl reclaim verify <shoot> [--record]     the originals against their stored checksums
    ./pl reclaim selftest                      the rules, against a fixture in a temp folder

Three questions, and only the middle one can remove a file.

`report` answers "what is this costing me" the way `du` does - allocation
accurate, so a frame that has four names (raw/, edit/, reels/burst54/, a
pick) is charged once - but split into the four things a photographer
actually distinguishes: the originals, the decisions, the derived caches,
and the finished work.

`reclaim` removes a file only when three independent things are true of it
at once, and only when the shoot as a whole passes two further gates that
have nothing to do with each other. It prints the total first and removes
nothing without --apply.

`verify` reads every original and compares it to a checksum recorded beside
it, so bit rot and a half-copied restore are things he is told about rather
than things he discovers in PhotoLab a year later.

Nothing here writes to a shoot except `verify --record`, which appends to a
plain-text manifest, and `reclaim --apply`, which unlinks files inside
directories the tool itself marked as its own cache.

This module answers from the folders, on its own rules, and imports nothing
from pipeline/library.py. That is deliberate rather than accidental: it is
the only thing in the pipeline that can unlink a photograph's last
rendering, and a second opinion reached independently is worth more here
than a shared one. The two were written apart and agree on the answer that
matters - on the dog shoot both refuse the same 292 files (this file
because no surviving original exists to rebuild them from, library.py
because no named writer claims them) and both free the same caches.

Where they differ, and what to reconcile if they are ever merged:

  - bytes. Everything here is st_blocks * 512, one charge per inode, which
    is what `du` counts and what the disk actually gives back; it agrees
    with `du -sk` exactly on all nine folders of the real library,
    57,353,916 KiB, to the kilobyte. Apparent size is a different and
    larger number.
  - the 292. This file charges a rendering with no surviving original to
    `originals`, because for that shoot it is the original, in the only
    form there is one. library.py charges it to `decision`. Neither will
    remove it; only the column it appears in differs.

If they are merged, raw_dir, cull_dirs, cull_dir, stem_of and Shoot are the
five things to delete, and the two gates in refusals() are the two things
that must survive the merge intact.
"""

from __future__ import annotations

import hashlib
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from common import JPEG_EXTS, RAW_EXTS, for_the_app, human, stop_cleanly_on_sigterm, write_atomic  # noqa: E402

ROOT = Path(os.environ.get("PHOTOS_ROOT", Path.home() / "photos")).expanduser()

# The tag is the Bagot/Freedesktop CACHEDIR.TAG convention, which he already
# writes by hand and which Time Machine and Backblaze already honour. Here it
# is not a hint: it is the tool's only licence to unlink anything. A cache the
# tool forgot to tag is a cache it never reclaims, which costs disk; a tag the
# tool invents over a folder it did not fill costs photographs. The asymmetry
# only points one way, so this file never writes a tag - the function that
# creates and fills a cache directory is the only thing allowed to.
CACHE_TAG = "CACHEDIR.TAG"
# The signature line the spec fixes, which is what makes the file a licence
# rather than a name. This module used to take the name alone, so a file
# called CACHEDIR.TAG that somebody else wrote, or a note to himself under
# that name, handed this file a licence to unlink the folder's contents -
# while library.py, which reads the line, would have refused the same folder.
TAG_SIGNATURE = "Signature: 8a477f597d28d172789f06886806bc55"

# What the cache stages actually write. Anything else inside a tagged folder
# was put there by something else and is left where it is. The dog shoot's
# cull/thumbs carries a tag and holds 346 files, 291 of them stems that shoot
# has never had a RAW for - so "tagged means this shoot's rebuildable cache"
# was already false on disk before a line of this was written.
CACHE_SUFFIXES = {".jpg", ".jpeg", ".png"}

# A finished export is not a derivative, whatever folder it is sitting in.
# gather.py's clear() learned this by rmtree-ing 154 of them out of
# edit/edited/; the rule is repeated here rather than referenced because the
# two commands must be able to be wrong separately.
DELIVERABLE_DIRS = {"export", "edited"}
DELIVERABLE_SUFFIXES = {".mp4", ".mov"}

# The decisions: his stars, his drop reasons, the answer key, the record of
# which sidecars the machine wrote rather than him, and every .dop, because a
# sidecar is where PhotoLab keeps his hand. About 60 KB per shoot, sitting
# inside a 16 GB folder - which is the whole reason this file is careful.
DECISION_SUFFIXES = {".json", ".csv", ".md", ".txt", ".preset", ".py", ".log", ".dop", ".xmp"}

MANIFEST_NAME = "originals.sha256"

# Any file whose name says this, anywhere in the shoot, stops every verb.
# The lounge shoot has 6 RAWs left against 296 culled frames and a
# hand-written cull/DO-NOT-CLEAN.txt saying its decoded/ and previews/ are the
# only surviving pixels. No code read that file. This one does - and then
# refuses a second time, for its own reasons, in case he never wrote it.
STOP_NAME = "do-not-clean"

ORIGINALS, DECISIONS, DERIVED, DELIVERABLES = "originals", "decisions", "derived", "deliverables"
CATEGORIES = (ORIGINALS, DECISIONS, DERIVED, DELIVERABLES)

# One inode, several names: raw/TSC04534.ARW is also edit/TSC04534.ARW and
# reels/burst54/TSC04534.ARW. It is charged once, to the strongest claim any
# of its names makes, so the figures do not move when he gathers or ungathers.
RANK = {ORIGINALS: 0, DELIVERABLES: 1, DECISIONS: 2, DERIVED: 3}


# ----------------------------------------------------------------- layout


def raw_dir(shoot: Path) -> Path:
    """Where this shoot's originals are. `shoot/raw` when it exists, the
    folder itself when it is literally named raw, and otherwise the folder
    itself - which is how a flat shoot, 98 ARW and 98 .dop loose in one
    directory, is seen at all."""
    shoot = Path(shoot)
    if (shoot / "raw").is_dir():
        return shoot / "raw"
    return shoot


def cull_dirs(shoot: Path) -> list[Path]:
    """Every folder this shoot's cull could be sitting in, likeliest first.

    Two conventions are live in this repo at once: cull.py still writes
    <folder>/_cull when the folder it is handed is not named raw/, and
    library.py prefers <folder>/cull while reading either. Picking one and
    being wrong is not cosmetic here. This is what finds cull.csv, and
    cull.csv is the only record that a frame was ever culled, so looking in
    the wrong place makes missing_originals() empty and silently switches off
    the refusal that is meant to work whether or not he wrote the note - on a
    flat folder, which is exactly the shape the ducks shoot is in. MOVES.log,
    13 September, is the other half of the bill: a stray _cull/ beside the dog
    shoot, moved back into cull/ file by file. So this reads both names and
    protects both, which cannot be wrong whichever convention ends up
    winning."""
    shoot = Path(shoot)
    if (shoot / "raw").is_dir():
        return [shoot / "cull"]
    return [shoot / "cull", shoot / "_cull"]


def cull_dir(shoot: Path) -> Path:
    """Whichever of cull_dirs() is on disk, and <shoot>/cull when neither is."""
    options = cull_dirs(shoot)
    for p in options:
        if p.is_dir():
            return p
    return options[0]


def is_raw(path: Path) -> bool:
    return path.suffix.lower() in RAW_EXTS


def tagged(folder: Path) -> bool:
    """Whether this folder really carries the cache licence: the file AND the
    signature line the spec fixes, which is what library.is_cache has always
    read. The name alone was the test here, and the name is not the licence -
    a file he wrote under it, or another tool's, would have handed this module
    permission to empty the folder it sits in."""
    try:
        with (Path(folder) / CACHE_TAG).open("r", errors="ignore") as fh:
            return fh.readline().strip() == TAG_SIGNATURE
    except OSError:
        return False


def progress(stage: str, done: int, total: int) -> None:
    """One machine-readable line per step, the convention cull.py prints.

    The studio has one progress bar and it is fed from these. This file
    printed none, so a reclaim and a verify both drew a bar that sat at 0%
    from the first second to the last - and a verify of the action shoot
    reads every original it has."""
    print(f"@@ {stage} {done} {total}", flush=True)


def stem_of(name: str) -> str:
    """TSC04534.ARW, TSC04534.jpg and TSC04534.ARW.dop are all one frame.

    The lounge shoot's cull.csv is keyed on .jpg because its decodes are all
    that is left of it, while its selects.json is keyed on .ARW; matching on
    the stem is the only thing that sees those as the same 296 frames."""
    s = name
    while True:
        base, dot, ext = s.rpartition(".")
        if not dot or f".{ext.lower()}" not in RAW_EXTS | CACHE_SUFFIXES | {".dop", ".xmp"}:
            return s
        s = base


def looks_like_a_shoot(path: Path) -> bool:
    """True when this folder holds a shoot's own work rather than other
    shoots': a raw/ beside it, a cull/ it has already been culled into, or
    RAWs sitting loose in it.

    cull/ counts on its own so that a shoot whose originals have all gone -
    the lounge shoot's shape carried to its end - is still recognised as a
    shoot and refused for the right reason, instead of being waved away as a
    folder that is not one."""
    path = Path(path)
    if (path / "raw").is_dir():
        return True
    if any(c.is_dir() for c in cull_dirs(path)):
        return True
    try:
        return any(is_raw(c) and c.is_file() and not c.is_symlink() for c in path.iterdir())
    except OSError:
        return False


def not_a_shoot(path: Path) -> str | None:
    """Why this folder may not be measured as one shoot, or None.

    Pointed at ~/photos or ~/photos/shoots, every verb in this file used to
    walk the whole library and answer as though it were a single shoot:
    report drew one row reading 42.6 GB of originals and 10.4 GB of derived
    across five separate shoots, and reclaim built one removal plan spanning
    all of them. Nothing downstream could catch that, because the arithmetic
    is right - it is an answer to a question nobody asked, and it is the
    shape of it that is wrong. So the question is asked here, of the folder,
    before a single file is stat()ed."""
    path = Path(path)
    if not path.is_dir():
        return f"no such folder: {path}"
    if looks_like_a_shoot(path):
        return None
    try:
        inside = [c.name for c in sorted(path.iterdir())
                  if c.is_dir() and not c.name.startswith(".") and looks_like_a_shoot(c)]
    except OSError:
        inside = []
    why = "it has no raw/, no cull/ and no RAWs loose in it"
    if inside:
        shown = ", ".join(inside[:4]) + (", ..." if len(inside) > 4 else "")
        why += (f", and {len(inside)} of the folders in it "
                f"{'is a shoot' if len(inside) == 1 else 'are shoots'} ({shown})")
    return why + ". Name one shoot, or run ./pl reclaim report with no arguments"


# ------------------------------------------------------------- the survey


class Shoot:
    """Everything the three commands need to know about one shoot, read once.

    Built from the folders, never from a database. A catalogue would make
    this faster and would also be a second thing that can be wrong about
    which pixels still exist, and being wrong about that is the failure this
    file is for."""

    def __init__(self, path: Path):
        self.path = Path(path).expanduser().resolve()
        self.raw = raw_dir(self.path)
        self.cull = cull_dir(self.path)
        # The folders that are never a cache whatever is dropped in them: the
        # shoot root, the folder the originals live in, and every name a cull
        # could be under. Held as a set rather than the single self.cull
        # because a flat shoot has two possible cull names and only one of them
        # was being guarded, which let a tag at cull/'s top licence the files
        # sitting directly in it - the one thing in_cache() promises it cannot.
        self.cull_roots = {self.path, self.raw, *cull_dirs(self.path)}
        self.tagged: set[Path] = set()
        self.stops: list[Path] = []
        self.originals: dict[str, Path] = {}
        self.original_inodes: set[tuple[int, int]] = set()
        self.files: list[Path] = []
        # Frames this shoot pushed to iCloud and dropped from the disk. They
        # are not lost and their caches are not the last copy of them, which
        # is what every refusal below used to conclude: a shoot archived the
        # way archive.py exists to archive it could not be reclaimed at all,
        # and its 8.3 GB of thumbnails were billed as originals.
        self.archived: set[str] = set()
        self._walk()
        self.cull_stems = self._cull_stems()
        self.archived = {stem_of(name) for name, up in archived_elsewhere(self).items() if up}

    def _walk(self) -> None:
        for dirpath, dirnames, filenames in os.walk(self.path, followlinks=False):
            d = Path(dirpath)
            dirnames.sort()
            if CACHE_TAG in filenames and tagged(d):
                self.tagged.add(d)
            for name in sorted(filenames):
                p = d / name
                self.files.append(p)
                if STOP_NAME in name.lower():
                    self.stops.append(p)
                if self.is_original(p):
                    # A RAW is an original wherever it sits. The action shoot
                    # keeps 33 of them in calib-skin/ under 13 names on 3 inodes,
                    # each with its own hand-made .dop: same bytes, different
                    # decisions, and none of them tool output.
                    try:
                        st = p.stat()
                    except OSError:
                        continue
                    # The name under raw/ wins over any other name for the same
                    # frame. Which name won used to be whichever os.walk
                    # reached first, and it sorts edit/ before raw/, so 264 of
                    # the action shoot's frames were written into
                    # originals.sha256 as
                    # edit/TSC*.ARW - a hard link `pl gather` makes and unmakes
                    # at will. One re-gather and verify called all 264 GONE,
                    # exited 1, and went on doing so for ever, because nothing
                    # ever removes a recorded line. A bit-rot alarm that is
                    # always sounding is one he stops reading.
                    stem = stem_of(name)
                    prev = self.originals.get(stem)
                    # And the RAW wins over a JPEG of the same frame, because
                    # that is the one the rest of the shoot was made from.
                    better = prev is None or (prev.parent != self.raw and p.parent == self.raw) \
                        or (not is_raw(prev) and is_raw(p))
                    if better:
                        self.originals[stem] = p
                    self.original_inodes.add((st.st_dev, st.st_ino))

    def _cull_stems(self) -> set[str]:
        """The frames the cull has an opinion about. These are what must still
        have originals for this shoot's caches to be rebuildable."""
        csv_path = self.cull / "cull.csv"
        stems: set[str] = set()
        try:
            with csv_path.open(newline="") as fh:
                header = fh.readline()
                if not header.startswith("file"):
                    return stems
                for line in fh:
                    name = line.split(",", 1)[0].strip()
                    if name:
                        stems.add(stem_of(name))
        except OSError:
            pass
        return stems

    def in_cache(self, path: Path) -> bool:
        """True only when this file's own immediate parent carries the tag.

        A tag licenses the folder it is in, never the folders beneath it. One
        tag dropped at cull/'s top level would otherwise declare his
        organize.json, his selects.json, the preset he named himself and
        his DO-NOT-CLEAN.txt deletable by anything that honours the
        convention, which is the whole of Time Machine and Backblaze. The
        shoot root, the originals' own folder and every folder a cull could be
        in are never caches whatever they carry - see self.cull_roots."""
        parent = path.parent
        if parent in self.cull_roots:
            return False
        return parent in self.tagged

    def is_original(self, p: Path) -> bool:
        """A photograph as the camera wrote it: a RAW wherever it sits, and a
        JPEG in the folder this shoot's originals are in.

        The JPEG half was missing, so a shoot shot to JPEG - which ingest and
        the cull both accept - had no originals at all by this file's reading:
        every one of its culled frames counted as lost, the shoot was refused
        for ever, and verify had nothing to checksum."""
        if p.is_symlink() or self.in_cache(p):
            return False
        suffix = p.suffix.lower()
        return suffix in RAW_EXTS or (suffix in JPEG_EXTS and p.parent == self.raw)

    def has_original(self, stem: str) -> bool:
        """Whether the photograph behind this stem still exists somewhere: on
        this disk, or in iCloud with archive.json saying so."""
        return stem in self.originals or stem in self.archived

    def missing_originals(self) -> set[str]:
        return {s for s in self.cull_stems if not self.has_original(s)}


# ---------------------------------------------------------- the one guard


def foreign(shoot: Shoot, path: Path) -> bool:
    """True when the tool cannot name itself as the writer of this file.

    Unknown provenance means untouchable, by any verb. A design that will not
    delete a file it cannot name a writer for must not move one either, so
    every future relocation is to ask this same question - the 1.26 GB of
    _DxO.jpg in the action shoot's reels/burst19/edited and burst54/edited is
    that shoot's only finished work (export/ holds 0 files, edit/edited/ holds a
    .DS_Store), and it must survive a tidy-up as surely as it survives a
    delete.

    The two incidents that earned this: the 154 finished exports rmtree'd out
    of edit/edited/, and the 290 lounge RAWs that survived only in a folder
    spelled like a cache."""
    if path.is_symlink():
        # 154 of the action shoot's cull/picks are absolute symlinks, not
        # hard links, and the lounge's point into cull/decoded/. They cost
        # nothing, so
        # there is nothing to win by removing them and a dangling link to lose.
        return True
    if not shoot.in_cache(path):
        return True                                   # no licence
    if path.name == CACHE_TAG:
        return True                                   # the licence itself
    if path.suffix.lower() not in CACHE_SUFFIXES:
        return True                                   # not a shape any cache stage writes
    if not shoot.has_original(stem_of(path.name)):
        return True                                   # nothing survives to rebuild it from
    try:
        st = path.stat()
    except OSError:
        return True
    if (st.st_dev, st.st_ino) in shoot.original_inodes:
        return True                                   # a second name for an original
    return False


def refusals(shoot: Shoot) -> list[str]:
    """Why this shoot may not be reclaimed at all. Each reason is reached
    independently of the others, because the lounge needs to be refused twice:
    once because he wrote the note, and once because the condition the note
    describes is true whether or not he ever wrote it down."""
    out = []
    for p in shoot.stops:
        try:
            first = p.read_text(errors="ignore").strip().splitlines()[0]
        except (OSError, IndexError):
            first = ""
        out.append(f"{p.relative_to(shoot.path)} says so: {first}")
    missing = shoot.missing_originals()
    if missing:
        sample = ", ".join(sorted(missing)[:4])
        # Said as where it looked, because the panel shows this beside a line
        # counting the frames recorded in iCloud: "no surviving original"
        # there read as a contradiction and as a loss, when what it means is
        # that neither this Mac nor the iCloud folder has the file right now.
        out.append(f"{len(missing)} of {len(shoot.cull_stems)} culled frames have no original on this Mac "
                   f"or in iCloud ({sample}{', ...' if len(missing) > 4 else ''}): "
                   f"the cache holds the only copy of those frames")
    if shoot.cull_stems and not shoot.originals and not shoot.archived:
        out.append("none of its originals can be found, on this Mac or in iCloud")
    return out


# ------------------------------------------------------------- accounting


def category(shoot: Shoot, path: Path) -> str:
    """Which of the four things this file is. Unrecognised means his: the
    default has to be the one that is never deleted and never miscounted as
    rebuildable.

    The line that matters is the one between derived and original, and it is
    computed rather than read off a folder name. A rendering whose frame still
    has a RAW in this shoot is derived: throwing it away costs a re-cull.
    A rendering whose frame has no RAW left is the original, in the only form
    there is one - the lounge shoot's 290 decodes are exactly that, and a
    report that billed them as `derived` would be the lounge failure mode
    written down as a figure he reads and acts on."""
    rel = path.relative_to(shoot.path)
    parts = [p.lower() for p in rel.parts]
    suffix = path.suffix.lower()
    if shoot.is_original(path):
        return ORIGINALS
    if suffix in DELIVERABLE_SUFFIXES or set(parts[:-1]) & DELIVERABLE_DIRS or "_dxo" in parts[-1]:
        return DELIVERABLES
    if suffix in DECISION_SUFFIXES:
        # .dop anywhere, and his loose json/csv/md/preset/txt wherever they sit,
        # including inside a folder something has tagged as a cache.
        return DECISIONS
    if suffix in CACHE_SUFFIXES and not path.is_symlink():
        return DERIVED if shoot.has_original(stem_of(path.name)) else ORIGINALS
    if shoot.in_cache(path) or "picks" in parts[:-1]:
        # picks/ carries no tag and is never reclaimed, but its links are the
        # cull's own suggestion and rebuilt on the next run, so they are
        # counted as derived rather than charged to him.
        return DERIVED
    return DECISIONS


def last_copy_renderings(shoot: Shoot) -> tuple[int, int, list[str]]:
    """Renderings this shoot has no original for: how many, how big, and which
    folders they are in.

    They are counted as originals above and refused by foreign() below, but
    they also have to be said out loud, because a folder holding them is not
    what its name says it is. The dog shoot's cull/thumbs carries a
    CACHEDIR.TAG and holds 291 of them - stems that shoot has never had a RAW
    for - so it is a tagged folder that is not purely this shoot's own
    rebuildable cache, and he should know that before a backup tool reads
    the tag and skips it."""
    seen: set[tuple[int, int]] = set()
    count = total = 0
    where: set[str] = set()
    for p in shoot.files:
        if p.suffix.lower() not in CACHE_SUFFIXES or p.is_symlink():
            continue
        if shoot.has_original(stem_of(p.name)) or category(shoot, p) != ORIGINALS:
            continue
        try:
            st = p.lstat()
        except OSError:
            continue
        key = (st.st_dev, st.st_ino)
        if key in seen:
            continue
        seen.add(key)
        count += 1
        total += st.st_blocks * 512
        where.add(str(p.parent.relative_to(shoot.path)))
    return count, total, sorted(where)


def measure(shoot: Shoot) -> dict:
    """What this shoot costs, the way du counts it: st_blocks * 512, one
    charge per inode. Hard links are counted once and so are the 13 names
    calib-skin hangs off one inode, which is why these figures agree with
    `du -sk` on the real library to within a rounding error rather than
    double-counting 15.9 GB of second names across it."""
    best: dict[tuple[int, int], tuple[int, str, int]] = {}
    counts = dict.fromkeys(CATEGORIES, 0)
    for p in shoot.files:
        try:
            st = p.lstat()
        except OSError:
            continue
        cat = category(shoot, p)
        counts[cat] += 1
        key = (st.st_dev, st.st_ino)
        rank = RANK[cat]
        prev = best.get(key)
        if prev is None or rank < prev[0]:
            best[key] = (rank, cat, st.st_blocks * 512)
    bytes_by = dict.fromkeys(CATEGORIES, 0)
    for _rank, cat, nbytes in best.values():
        bytes_by[cat] += nbytes
    plan = plan_removal(shoot)
    return {
        "shoot": shoot,
        "bytes": bytes_by,
        "counts": counts,
        "total": sum(bytes_by.values()),
        "reclaimable": sum(n for _p, n in plan) if not refusals(shoot) else 0,
        "reclaimable_files": len(plan) if not refusals(shoot) else 0,
        "refusals": refusals(shoot),
    }


def plan_removal(shoot: Shoot) -> list[tuple[Path, int]]:
    """Every file reclaim would unlink, and what unlinking it actually frees.

    Only the bytes it is about to release are counted. A link count above one
    is not a proxy for costing nothing here - all 198 ARW in the portraits
    shoot's raw/ report st_nlink=2 with exactly one name anywhere in the home
    directory, and a tool that trusted nlink would misreport that shoot by
    4.6 GB in one direction or the other."""
    out = []
    for p in shoot.files:
        if foreign(shoot, p):
            continue
        try:
            st = p.lstat()
        except OSError:
            continue
        if st.st_nlink > 1 and (st.st_dev, st.st_ino) in shoot.original_inodes:
            continue
        out.append((p, st.st_blocks * 512))
    return out


def unlicensed_derived(shoot: Shoot) -> dict[str, tuple[int, int]]:
    """Derived bytes reclaim will not take, and why, so the difference between
    what a shoot costs and what it can give back is visible rather than
    mysterious. The action shoot's cull/reelthumbs is 2.7 MB with no tag
    today; the dog's 291 orphan thumbs are the only rendering left of frames
    whose RAWs are somewhere else entirely."""
    seen: set[tuple[int, int]] = set()
    why: dict[str, tuple[int, int]] = {}
    for p in shoot.files:
        if category(shoot, p) != DERIVED or not foreign(shoot, p):
            continue
        try:
            st = p.lstat()
        except OSError:
            continue
        key = (st.st_dev, st.st_ino)
        if key in seen:
            continue
        seen.add(key)
        if p.is_symlink():
            reason = "a link, not a copy"
        elif p.name == CACHE_TAG:
            reason = "the note that allows this folder to be cleaned"
        elif not shoot.in_cache(p):
            reason = "not in a cache folder, so never cleaned"
        elif not shoot.has_original(stem_of(p.name)):
            reason = "no surviving original to rebuild it from"
        else:
            reason = "not written by any cache stage"
        n, b = why.get(reason, (0, 0))
        why[reason] = (n + 1, b + st.st_blocks * 512)
    return why


# ---------------------------------------------------------------- report


def shoots_under(root: Path) -> list[Path]:
    base = root / "shoots"
    if not base.is_dir():
        return []
    return sorted(p for p in base.iterdir() if p.is_dir() and not p.name.startswith("."))


def strays_under(root: Path) -> list[Path]:
    """Folders of photographs that are not under shoots/ at all. One folder
    beside shoots/ holds 29 loose ARW and the attic holds 6.2 GB of freezes
    he made by hand;
    no command in this pipeline can see either, so a report that leaves them
    out is telling him his library is smaller than it is."""
    out = []
    for p in sorted(root.iterdir()) if root.is_dir() else []:
        if not p.is_dir() or p.name.startswith(".") or p.name == "shoots":
            continue
        for _dirpath, _dirnames, filenames in os.walk(p):
            if any(Path(f).suffix.lower() in RAW_EXTS for f in filenames):
                out.append(p)
                break
    return out


def _row(name: str, m: dict, width: int) -> str:
    b = m["bytes"]
    return (f"  {name:<{width}}  {human(b[ORIGINALS]):>10}  {human(b[DECISIONS]):>10}  "
            f"{human(b[DERIVED]):>10}  {human(b[DELIVERABLES]):>12}  {human(m['total']):>10}  "
            f"{human(m['reclaimable']):>11}")


def report(paths: list[Path]) -> int:
    targets = paths or shoots_under(ROOT)
    strays = [] if paths else strays_under(ROOT)
    if not targets and not strays:
        print(f"nothing to report on under {ROOT}")
        return 1
    width = max([len(p.name) for p in targets + strays] + [20])
    head = (f"  {'shoot':<{width}}  {'originals':>10}  {'decisions':>10}  {'derived':>10}  "
            f"{'deliverables':>12}  {'total':>10}  {'reclaimable':>11}")
    print(head)
    print("  " + "-" * (len(head) - 2))
    totals = dict.fromkeys(CATEGORIES, 0)
    grand = free = 0
    notes: list[str] = []
    for p in targets:
        why = not_a_shoot(p)
        if why:
            notes.append(f"  {p.name}: not measured - {why}")
            continue
        m = measure(Shoot(p))
        print(_row(p.name, m, width))
        for c in CATEGORIES:
            totals[c] += m["bytes"][c]
        grand += m["total"]
        free += m["reclaimable"]
        for r in m["refusals"]:
            notes.append(f"  {p.name}: refused - {r}")
        cnt, tot, where = last_copy_renderings(m["shoot"])
        if cnt:
            notes.append(f"  {p.name}: {cnt} renderings in {', '.join(where)} are of frames this shoot has no "
                         f"original for, {human(tot)}. Counted as originals, never reclaimed.")
        up = len(m["shoot"].archived & m["shoot"].cull_stems)
        if up:
            notes.append(f"  {p.name}: {up} frames are archived in iCloud rather than on this disk; "
                         f"archive.json says where, so their caches count as derived.")
    print("  " + "-" * (len(head) - 2))
    print(f"  {'':<{width}}  {human(totals[ORIGINALS]):>10}  {human(totals[DECISIONS]):>10}  "
          f"{human(totals[DERIVED]):>10}  {human(totals[DELIVERABLES]):>12}  {human(grand):>10}  {human(free):>11}")
    measurable = [p for p in strays if not not_a_shoot(p)]
    # A stray that turns out to be a folder OF shoots - attic, which holds four
    # hand-made freezes - still has its size said out loud, because the reason
    # strays are in this report at all is that leaving them out tells him his
    # library is smaller than it is. What it does not get is a row, because the
    # four columns of a row are a claim about one shoot.
    notes += [f"  {p.name}: {human(_du_bytes(p))}, but not one shoot - {not_a_shoot(p)}"
              for p in strays if not_a_shoot(p)]
    if measurable:
        print("\n  not under shoots/, so no command in this pipeline can see them:")
        for p in measurable:
            m = measure(Shoot(p))
            print(_row(p.name, m, width))
    if notes:
        print("\n  " + "-" * (len(head) - 2))
        for n in notes:
            print(n)
    print(f"\n  {human(free)} can be taken back now, on {human(shutil_free(ROOT))} free.")
    print("  reclaim takes only derived bytes, one shoot at a time: ./pl reclaim reclaim <shoot>")
    return 0


def shutil_free(path: Path) -> int:
    import shutil
    p = Path(path)
    while not p.exists() and p != p.parent:
        p = p.parent
    return shutil.disk_usage(p).free


# --------------------------------------------------------------- reclaim


def reclaim(shoot_path: Path, apply: bool = False) -> int:
    why = not_a_shoot(shoot_path)
    if why:
        # Asked before Shoot() is built, because building one over ~/photos
        # walks the datasets as well - 11,086 images that are not his - and
        # then answers about all of it at once.
        print(f"  {Path(shoot_path)}")
        print("\n  REFUSED. Nothing was measured.")
        print(f"    - that is not one shoot: {why}")
        return 1
    shoot = Shoot(shoot_path)
    stop = refusals(shoot)
    m = measure(shoot)
    b = m["bytes"]
    print(f"  {shoot.path}")
    # "cache", the one word the app uses for these bytes on the panel, the
    # button and the library page; "derived" was a fourth name for them. The
    # originals figure is labelled for what it holds, since it counts the
    # renderings that are a frame's only copy and so is larger than the RAWs
    # the panel above it counts.
    print(f"  originals, with renderings that are their only copy {human(b[ORIGINALS])} · "
          f"decisions {human(b[DECISIONS])} · cache {human(b[DERIVED])} · "
          f"deliverables {human(b[DELIVERABLES])}")
    if stop:
        print("\n  REFUSED. Nothing was removed.")
        for r in stop:
            print(f"    - {r}")
        print("\n  There is no flag that overrides this. If the caches here are the last"
              "\n  copy of a frame, the way to free space is to archive them, not to clean them.")
        return 2
    plan = plan_removal(shoot)
    if not plan:
        print("\n  nothing to reclaim: this shoot is already at its floor.")
        return 0
    by_dir: dict[Path, tuple[int, int]] = {}
    for p, n in plan:
        cnt, tot = by_dir.get(p.parent, (0, 0))
        by_dir[p.parent] = (cnt + 1, tot + n)
    total = sum(n for _p, n in plan)
    print("\n  this would remove, and only this:")
    for d in sorted(by_dir):
        cnt, tot = by_dir[d]
        print(f"    {str(d.relative_to(shoot.path)) + '/':<28} {cnt:>6} files  {human(tot):>10}")
    print(f"    {'':<28} {len(plan):>6} files  {human(total):>10}  total")
    left = unlicensed_derived(shoot)
    if left:
        print("\n  left in place:")
        for reason, (cnt, tot) in sorted(left.items(), key=lambda kv: -kv[1][1]):
            print(f"    {cnt:>6} files  {human(tot):>10}   {reason}")
    cnt, tot, where = last_copy_renderings(shoot)
    if cnt:
        print(f"\n  {cnt} renderings in {', '.join(where)} are of frames this shoot has no original for,"
              f"\n  {human(tot)}. They are the last copy of those frames, so they are counted as originals"
              "\n  above and are not in the list.")
    up = len(shoot.archived & shoot.cull_stems)
    if up:
        print(f"\n  {up} of its frames are not on this disk because they were archived; archive.json says"
              "\n  where. Their caches are derived from photographs that still exist, so they are in the"
              "\n  list above - bring the frames back first if you want them: "
              + ("Bring the RAWs Back." if for_the_app() else f"./pl archive pull {shoot.path.name} --apply"))
    if not apply:
        # The page draws its list by running this same command without
        # --apply, as a job with the same one bar. There is no loop on that
        # path, so the bar is told what the run is about rather than left blank.
        progress("reclaim", 0, len(plan))
        print("\n  nothing was removed. Add --apply to remove exactly the files listed above.")
        return 0
    # Read the shoot again from disk before unlinking. The plan above was made
    # from a survey that is now seconds old, and the selects.json incident is
    # what a machine verdict standing in for a look costs: if a DO-NOT-CLEAN
    # note or a cleared original appeared in between, the answer changes here
    # rather than after the files are gone.
    again = Shoot(shoot.path)
    stop = refusals(again)
    if stop:
        print("\n  REFUSED on the second look. Nothing was removed.")
        for r in stop:
            print(f"    - {r}")
        return 2
    freed = removed = skipped = 0
    for i, (p, n) in enumerate(plan):
        progress("reclaim", i, len(plan))
        if foreign(again, p):
            skipped += 1
            continue
        try:
            st = p.lstat()
        except OSError:
            skipped += 1
            continue
        if st.st_blocks * 512 != n:
            # It changed since the plan was printed. He was shown a number;
            # this is no longer the file that number was about.
            skipped += 1
            continue
        try:
            p.unlink()
        except OSError as e:
            print(f"    could not remove {p.name}: {e}")
            skipped += 1
            continue
        removed += 1
        freed += n
    progress("reclaim", len(plan), len(plan))
    if for_the_app():
        # The last line, which the panel says under how the job ended: it was
        # "…and this command works again." in lower case.
        print(f"\n  Removed {removed} files, {human(freed)}."
              + (f" {skipped} skipped: they changed since the list was drawn." if skipped else "")
              + " The next cull makes the cache again.")
        return 0
    print(f"\n  removed {removed} files, {human(freed)}."
          + (f" {skipped} skipped: they changed since the list above." if skipped else ""))
    print("  the tags stay, so the next cull refills these folders and this command works again.")
    return 0


# ---------------------------------------------------------------- verify


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def manifest_path(shoot: Shoot) -> Path:
    """At the shoot's top level, beside shoot.json, never inside cull/.

    Plain text in `shasum -a 256 -c` format, so the check survives this tool
    being uninstalled. The names inside are relative to the shoot folder and
    not to raw/ - a frame reads as raw/TSC04534.ARW - so the recipe is run
    from the shoot:

        cd <shoot> && shasum -a 256 -c originals.sha256

    which is the same line the manifest's own header carries. This docstring
    used to say `cd raw && shasum -a 256 -c ../originals.sha256`, which makes
    every line FAIL on a library that is in perfect health. A recovery recipe
    that cries corruption when there is none is worse than no recipe, and this
    is the one command in the pipeline meant to outlive the pipeline."""
    return shoot.path / MANIFEST_NAME


def read_manifest(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    try:
        text = path.read_text()
    except OSError:
        return out
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        digest, _, name = line.partition("  ")
        if digest and name:
            out[name] = digest
    return out


GONE_PREFIX = "#gone "


def read_gone(path: Path) -> dict[str, str]:
    """Frames recorded as deliberately let go, and the day each was let go.

    Kept as comment lines inside the manifest itself rather than in a second
    file, because `shasum -a 256 -c` ignores a comment and the manifest is
    meant to outlive this tool. A frame named here has no checksum line left,
    so the recipe still passes; the note is what stops the next verify from
    calling it bit rot."""
    out: dict[str, str] = {}
    try:
        text = path.read_text()
    except OSError:
        return out
    for line in text.splitlines():
        if not line.startswith(GONE_PREFIX):
            continue
        when, _, name = line[len(GONE_PREFIX):].strip().partition("  ")
        if name:
            out[name.strip()] = when.strip()
    return out


def write_manifest(path: Path, entries: dict[str, str], gone: dict[str, str] | None = None) -> None:
    body = ["# sha256 of this shoot's originals, one line per file, relative to this folder.",
            "# Written by ./pl reclaim verify --record. Check it with nothing but:",
            "#     shasum -a 256 -c originals.sha256",
            "# A line here is a claim about bytes that cannot be made again once they change,",
            "# so verify will not quietly rewrite one that stopped matching.",
            "# A '#gone' line says a frame was let go on purpose and is not bit rot."]
    body += [f"{GONE_PREFIX}{when}  {name}" for name, when in sorted((gone or {}).items())]
    body += [f"{entries[name]}  {name}" for name in sorted(entries)]
    write_atomic(path, "\n".join(body) + "\n")


def archived_elsewhere(shoot: Shoot) -> dict[str, bool]:
    """The frames this shoot pushed into iCloud, and whether each archived
    copy is still up there.

    verify called every archived-and-dropped original GONE and exited 1, for
    ever, with nothing to do about it - while archive.py's manifest was
    sitting in the same shoot recording exactly where those bytes went. This
    is the one place reclaim.py asks another module rather than the folders:
    the folders no longer hold the answer, which is the whole point of having
    dropped them.

    exists(), deliberately, and not archive.local(). The question is where
    the photograph went, and macOS evicting the archived copy to save disk
    has not moved it; local() answers whether the bytes are on this Mac right
    now, which would report 405 of this account's 3,202 iCloud files lost."""
    try:
        import archive as amod
    except ImportError:            # archive.py is optional; verify is not
        return {}
    man = amod.load_manifest(shoot.path).get("frames") or {}
    return {name: amod.dest_for(shoot.path, name).exists() for name in man}


def verify(shoot_path: Path, record: bool = False, accept_drift: bool = False,
           let_go: list[str] | None = None) -> int:
    why = not_a_shoot(shoot_path)
    if why:
        print(f"  {Path(shoot_path)}")
        print("\n  REFUSED. Nothing was read.")
        print(f"    - that is not one shoot: {why}")
        return 1
    shoot = Shoot(shoot_path)
    mpath = manifest_path(shoot)
    stored = read_manifest(mpath)
    gone_on_purpose = read_gone(mpath)
    here = {str(p.relative_to(shoot.path)): p for p in shoot.originals.values()}

    # One hash per INODE, not per name. The action shoot holds 1,190 originals on
    # 1,157 distinct inodes: calib-skin hangs 36 names off 3 of them, 12 each,
    # so hashing per name read 27.7 GB where 26.9 GB would do and put 785.5 MB
    # of it through sha256 twelve times over to learn nothing the first read
    # had not already said. Every name of an inode is given that one digest,
    # so the manifest still carries a line per name and `shasum -c` still
    # passes on all of them.
    groups: dict[tuple[int, int], list[str]] = {}
    unreadable: list[str] = []
    for name in sorted(here):
        try:
            st = here[name].lstat()
        except OSError as e:
            unreadable.append(f"{name}: {e}")
            continue
        groups.setdefault((st.st_dev, st.st_ino), []).append(name)

    print(f"  {shoot.path}")
    print(f"  {len(here)} originals on {len(groups)} inodes, {len(stored)} recorded in {MANIFEST_NAME}")
    ok = drift = new = missing = 0
    drifted: list[str] = []
    entries = dict(stored)
    for i, names in enumerate(groups.values()):
        progress("check", i, len(groups))
        try:
            digest = sha256(here[names[0]])
        except OSError as e:
            unreadable.append(f"{names[0]}: {e}")
            continue
        for name in names:
            was = stored.get(name)
            if was is None:
                new += 1
                if record:
                    entries[name] = digest
            elif was == digest:
                ok += 1
            else:
                drift += 1
                drifted.append(name)
                if record and accept_drift:
                    entries[name] = digest
    progress("check", len(groups), len(groups))
    for name in unreadable:
        print(f"    unreadable: {name}")
    missing += len(unreadable)

    # What `let_go` is for, and why it is not --accept-drift: --accept-drift
    # forgives a file whose BYTES changed under a name that is still there,
    # which is the one thing that must stay hard to reach. This forgives a
    # name that is not there at all, which is an ordinary thing to do to a
    # photograph on purpose, and it has to be sayable or a deliberate
    # deletion makes verify exit 1 for the rest of the shoot's life.
    asked = set(let_go or [])
    archived = archived_elsewhere(shoot)
    kept_archived, lost_archive = [], []
    for name in sorted(stored):
        if name in here:
            continue
        base = Path(name).name
        if base in archived:
            if archived[base]:
                kept_archived.append(name)
            else:
                lost_archive.append(name)
            continue
        if name in gone_on_purpose:
            continue
        if name in asked:
            continue                       # reported below, as it is recorded
        missing += 1
        print(f"    GONE: {name} was recorded here and is not on disk now")
    for name in lost_archive:
        missing += 1
        print(f"    GONE: {name} is not on disk and archive.json says it went to iCloud,"
              f"\n          where it is not either. Look before you do anything else.")
    if kept_archived:
        n = len(kept_archived)
        print(f"\n  {n} original{'' if n == 1 else 's'} {'is' if n == 1 else 'are'} not on disk because"
              f"\n  {'it was' if n == 1 else 'they were'} archived and dropped; archive.json says where."
              "\n  Not counted as missing.")
    if gone_on_purpose:
        n = len(gone_on_purpose)
        print(f"  {n} {'is' if n == 1 else 'are'} recorded in {MANIFEST_NAME} as let go on purpose.")

    if drifted:
        print(f"\n  {len(drifted)} originals no longer hash to what was recorded:")
        for name in drifted[:20]:
            print(f"    DRIFT: {name}")
        if len(drifted) > 20:
            print(f"    ... and {len(drifted) - 20} more")
        print("  A RAW does not change by itself. This is bit rot, a bad copy back from a"
              "\n  drive, or something that rewrote the file. Do not re-record it until you"
              "\n  know which - the recorded hash is the only witness you have left.")
    print(f"\n  {ok} unchanged · {drift} drifted · {new} not recorded yet · {missing} gone")

    # Letting a frame go is an instruction naming a file, so it writes the
    # manifest whether or not --record was asked for; but it will not let go
    # of a frame that is still on the disk, and it will not let go of one the
    # archive says it can still fetch, because neither of those is gone.
    refused_release = []
    for name in sorted(asked):
        if name in here:
            refused_release.append(f"{name} is on the disk right now")
        elif Path(name).name in archived and archived[Path(name).name]:
            refused_release.append(f"{name} is in iCloud; ./pl archive pull {shoot.path.name} --apply "
                                   f"brings it back")
        elif name not in stored and name not in gone_on_purpose:
            near = [k for k in sorted(stored) if Path(k).name == Path(name).name]
            hint = f"; did you mean {near[0]}?" if near else ""
            refused_release.append(f"{name} is not recorded in {MANIFEST_NAME}; nothing to let go of{hint}")
        else:
            gone_on_purpose[name] = time.strftime("%Y-%m-%d")
            entries.pop(name, None)
            print(f"  let go: {name}, recorded as deliberate on {gone_on_purpose[name]}")
    for r in refused_release:
        print(f"  NOT let go: {r}")
    # A note about a frame that has come back is a stale note, not a record.
    for name in [n for n in gone_on_purpose if n in here]:
        gone_on_purpose.pop(name)
        print(f"  {name} is on the disk again; its #gone note was dropped")

    if record or asked:
        if record and drifted and not accept_drift:
            print(f"  recorded {new} new checksums; the {len(drifted)} drifted lines were left as they were."
                  "\n  --accept-drift rewrites them, which throws away the evidence.")
        write_manifest(mpath, entries, gone_on_purpose)
        print(f"  wrote {mpath}")
    elif new and not for_the_app():
        # A flag to type. Check Every Original records nothing, so from the
        # app the count above ("… not recorded yet") is the last line.
        print(f"  --record writes the {new} missing checksums into {MANIFEST_NAME}.")
    return 1 if (drift and not accept_drift) or missing or refused_release else 0


# -------------------------------------------------------------- selftest
#
# The tests live in this file rather than in tests/ because this module owns
# its own rules and they are worth nothing untested. Everything below builds
# its fixture in a temp folder; nothing here reads or writes ~/photos.


def _mk(path: Path, data: bytes = b"") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data or b"x" * 4096)
    return path


def _fixture(base: Path) -> tuple[Path, Path, Path]:
    """Three shoots: one healthy, one with its originals cleared the way
    the lounge shoot's were, and one laid out flat the way a folder of loose
    RAWs is, with its originals cleared too."""
    good = base / "shoots" / "2026-01-01-gym"
    for i in range(4):
        _mk(good / "raw" / f"TSC0{i}.ARW", bytes([i]) * 8192)
        _mk(good / "raw" / f"TSC0{i}.ARW.dop", b"hand")
    for sub in ("decoded", "previews", "thumbs"):
        _mk(good / "cull" / sub / CACHE_TAG, b"Signature: 8a477f597d28d172789f06886806bc55\n")
        for i in range(4):
            _mk(good / "cull" / sub / f"TSC0{i}.jpg", b"d" * 16384)
    _mk(good / "cull" / "reelthumbs" / "TSC00.jpg", b"d" * 4096)          # no tag: no licence
    _mk(good / "cull" / "cull.csv", b"file,rating\nTSC00.ARW,3\nTSC01.ARW,2\nTSC02.ARW,4\nTSC03.ARW,1\n")
    _mk(good / "cull" / "organize.json", b'{"photos":{}}')
    _mk(good / "cull" / "selects.json", b'["TSC00.ARW"]')
    _mk(good / "cull" / "decoded" / "notes-of-his.txt", b"his")           # foreign, inside a tag
    _mk(good / "cull" / "decoded" / "TSC99.jpg", b"orphan" * 100)         # no original: untouchable
    (good / "cull" / "picks").mkdir(parents=True, exist_ok=True)
    (good / "cull" / "picks" / "TSC00.ARW").symlink_to(good / "raw" / "TSC00.ARW")
    _mk(good / "cull" / "picks" / "TSC00.ARW.dop", b"his hand, edited in picks")
    (good / "edit").mkdir(parents=True, exist_ok=True)
    os.link(good / "raw" / "TSC00.ARW", good / "edit" / "TSC00.ARW")      # a second name, charged once
    _mk(good / "edit" / "edited" / "TSC00_DxO.jpg", b"f" * 32768)         # the only finished work
    _mk(good / "reels" / "2026-01-01-cut1.mp4", b"m" * 8192)
    _mk(good / "reels" / "burst9" / "edited" / "TSC01_DxO.jpg", b"f" * 32768)
    _mk(good / "shoot.json", b'{"kind":"other"}')

    lounge = base / "shoots" / "2026-01-02-lounge"
    _mk(lounge / "raw" / "TSC10.ARW", b"a" * 8192)                        # 1 of 4 frames left
    _mk(lounge / "cull" / "cull.csv", b"file,rating\nTSC10.jpg,3\nTSC11.jpg,3\nTSC12.jpg,2\nTSC13.jpg,4\n")
    for i in range(10, 14):
        _mk(lounge / "cull" / "decoded" / f"TSC{i}.jpg", b"d" * 16384)
        _mk(lounge / "cull" / "previews" / f"TSC{i}.jpg", b"p" * 4096)
    _mk(lounge / "cull" / "thumbs" / CACHE_TAG, b"Signature: 8a477f597d28d172789f06886806bc55\n")
    _mk(lounge / "cull" / "thumbs" / "TSC10.jpg", b"t" * 4096)
    _mk(lounge / "cull" / "DO-NOT-CLEAN.txt",
        b"NOT A CACHE. decoded/ and previews/ are the only surviving pixels for 3 of these frames.\n")
    _mk(lounge / "shoot.json", b'{"kind":"other"}')

    # No raw/ subfolder and no shoot.json, the shape a loose folder is in,
    # with the cull beside the frames where library.py puts one - and with a
    # CACHEDIR.TAG dropped at the cull's own top, which is the case in_cache()
    # exists to refuse. Three of its four frames have been cleared, so the
    # structural refusal has to fire here without any note being written.
    flat = base / "shoots" / "loose-frames"
    _mk(flat / "DUCK01.ARW", b"a" * 8192)
    for i in range(1, 5):
        _mk(flat / f"DUCK0{i}.ARW.dop", b"hand")
    _mk(flat / "cull" / "cull.csv",
        b"file,rating\nDUCK01.ARW,3\nDUCK02.ARW,3\nDUCK03.ARW,3\nDUCK04.ARW,3\n")
    _mk(flat / "cull" / CACHE_TAG, b"Signature: 8a477f597d28d172789f06886806bc55\n")
    _mk(flat / "cull" / "DUCK01.jpg", b"his own export, loose in the cull root")
    _mk(flat / "cull" / "thumbs" / CACHE_TAG, b"Signature: 8a477f597d28d172789f06886806bc55\n")
    for i in range(1, 5):
        _mk(flat / "cull" / "thumbs" / f"DUCK0{i}.jpg", b"t" * 4096)
    # resolved, because /var is a symlink to /private/var on macOS and Shoot resolves
    return good.resolve(), lounge.resolve(), flat.resolve()


def selftest() -> int:
    import tempfile
    fails: list[str] = []

    def check(name: str, cond: bool, detail: str = "") -> None:
        print(f"    {'ok  ' if cond else 'FAIL'}  {name}{'' if cond else '  <- ' + detail}")
        if not cond:
            fails.append(name)

    with tempfile.TemporaryDirectory(prefix="reclaim-selftest-") as tmp:
        base = Path(tmp)
        good, lounge, flat = _fixture(base)

        print("\n  the healthy shoot")
        s = Shoot(good)
        m = measure(s)
        check("no refusals", not m["refusals"], str(m["refusals"]))
        check("originals seen", len(s.originals) == 4, str(sorted(s.originals)))
        check("tagged dirs found", len(s.tagged) == 3, str(sorted(p.name for p in s.tagged)))
        plan = dict(plan_removal(s))
        names = sorted(p.name for p in plan)
        check("plan is 12 decoded/preview/thumb jpgs", len(plan) == 12, str(names))
        check("the tag itself is kept", not any(p.name == CACHE_TAG for p in plan))
        check("his note inside a tagged folder is kept", not any(p.name == "notes-of-his.txt" for p in plan))
        check("a cache jpg with no surviving original is kept", not any(p.name == "TSC99.jpg" for p in plan))
        check("and is charged as an original, not as derived",
              category(s, good / "cull" / "decoded" / "TSC99.jpg") == ORIGINALS)
        check("and is named in the report's notes", last_copy_renderings(s)[0] == 1, str(last_copy_renderings(s)))
        check("untagged reelthumbs is kept", not any("reelthumbs" in str(p) for p in plan))
        check("picks symlink is kept", not any(p.parent.name == "picks" for p in plan))
        check("his hand-edited .dop in picks is kept",
              not any(p.name.endswith(".dop") for p in plan))
        check("no original is in the plan", not any(is_raw(p) for p in plan))
        check("no deliverable is in the plan",
              not any("_DxO" in p.name or p.suffix == ".mp4" for p in plan))

        b = m["bytes"]
        raws = sum((good / "raw" / f"TSC0{i}.ARW").lstat().st_blocks * 512 for i in range(4))
        check("originals charged once for two names (raw/ and the link in edit/)",
              b[ORIGINALS] == raws + last_copy_renderings(s)[1],
              f"{b[ORIGINALS]} != {raws} + {last_copy_renderings(s)[1]}")
        check("deliverables counted", b[DELIVERABLES] > 0, human(b[DELIVERABLES]))
        check("decisions counted", b[DECISIONS] > 0, human(b[DECISIONS]))
        check("derived counted", b[DERIVED] > 0, human(b[DERIVED]))
        du = _du_bytes(good)
        check(f"total agrees with du ({human(m['total'])} vs {human(du)})",
              abs(m["total"] - du) <= max(8192, du // 50), f"{m['total']} vs {du}")

        print("\n  the cleared shoot (the lounge shoot's shape)")
        ls = Shoot(lounge)
        r = refusals(ls)
        check("refused", bool(r), "not refused")
        check("refused by the hand-written note", any("DO-NOT-CLEAN" in x for x in r), str(r))
        check("refused again by the condition itself",
              any("no original on this Mac or in iCloud" in x for x in r), str(r))
        check("the two reasons are independent", len(r) >= 2, str(r))
        lm = measure(ls)
        check("nothing is reclaimable there", lm["reclaimable"] == 0)
        # The decodes and previews of the 3 cleared frames are 3 x (16 KB + 4 KB)
        # of pixels that exist nowhere else. They must not appear in the column
        # headed "derived", because that column is the one he reads as spare.
        check("its last-copy pixels are billed as originals, not derived",
              lm["bytes"][ORIGINALS] > lm["bytes"][DERIVED], f"{lm['bytes']}")
        check("and are named in the notes", last_copy_renderings(ls)[0] == 6, str(last_copy_renderings(ls)))
        before = sorted(str(p.relative_to(lounge)) for p in ls.files)
        rc = reclaim(lounge, apply=True)
        after = sorted(str(p.relative_to(lounge)) for p in Shoot(lounge).files)
        check("reclaim --apply exits 2", rc == 2, str(rc))
        check("not one file was removed", before == after,
              str(set(before) ^ set(after)))

        print("\n  with the note deleted, the condition still refuses")
        (lounge / "cull" / "DO-NOT-CLEAN.txt").unlink()
        ls2 = Shoot(lounge)
        r2 = refusals(ls2)
        check("still refused with no note on disk", bool(r2), str(r2))
        check("reclaim --apply still exits 2", reclaim(lounge, apply=True) == 2)
        check("its thumbs, which are tagged, are still there",
              (lounge / "cull" / "thumbs" / "TSC10.jpg").exists())

        print("\n  the flat shoot (a folder of loose RAWs, cleared)")
        fs = Shoot(flat)
        check("its cull is found where library.py puts one", fs.cull == flat / "cull", str(fs.cull))
        check("so its 4 culled frames are seen", len(fs.cull_stems) == 4, str(sorted(fs.cull_stems)))
        fr = refusals(fs)
        check("refused, with no note anywhere on disk", bool(fr), str(fr))
        check("refused for the right reason",
              any("no original on this Mac or in iCloud" in x for x in fr), str(fr))
        fplan = [p for p, _n in plan_removal(fs)]
        check("a tag at the cull root licences nothing sitting in it",
              not any(p.parent == flat / "cull" for p in fplan), str(fplan))
        check("his loose export in the cull root is kept",
              (flat / "cull" / "DUCK01.jpg") not in fplan)
        check("reclaim --apply exits 2 there", reclaim(flat, apply=True) == 2)
        check("and its last three frames' thumbs are still there",
              all((flat / "cull" / "thumbs" / f"DUCK0{i}.jpg").exists() for i in (2, 3, 4)))

        print("\n  nothing goes without --apply")
        s = Shoot(good)
        before = sorted(str(p.relative_to(good)) for p in s.files)
        rc = reclaim(good)
        after = sorted(str(p.relative_to(good)) for p in Shoot(good).files)
        check("default run exits 0", rc == 0, str(rc))
        check("default run removed nothing", before == after, str(set(before) ^ set(after)))

        print("\n  --apply, on the healthy shoot")
        want = sum(n for _p, n in plan_removal(Shoot(good)))
        rc = reclaim(good, apply=True)
        s2 = Shoot(good)
        check("exits 0", rc == 0, str(rc))
        check("the 12 cache jpgs are gone",
              not any(p.suffix == ".jpg" and p.parent.name in ("decoded", "previews", "thumbs")
                      and p.name != "TSC99.jpg" for p in s2.files))
        check("TSC99.jpg survived", (good / "cull" / "decoded" / "TSC99.jpg").exists())
        check("his note survived", (good / "cull" / "decoded" / "notes-of-his.txt").exists())
        check("the tags survived", len(s2.tagged) == 3, str(sorted(p.name for p in s2.tagged)))
        check("every original survived", len(s2.originals) == 4, str(sorted(s2.originals)))
        check("every .dop survived", sum(1 for p in s2.files if p.suffix == ".dop") == 5)
        check("the finished exports survived",
              (good / "edit" / "edited" / "TSC00_DxO.jpg").exists()
              and (good / "reels" / "burst9" / "edited" / "TSC01_DxO.jpg").exists())
        check("the reel survived", (good / "reels" / "2026-01-01-cut1.mp4").exists())
        check("cull.csv, organize.json and selects.json survived",
              all((good / "cull" / f).exists() for f in ("cull.csv", "organize.json", "selects.json")))
        check("freed what it said it would", want > 0 and measure(s2)["reclaimable"] == 0, str(want))
        check("running it again is a no-op", reclaim(good, apply=True) == 0)

        print("\n  verify")
        rc = verify(good, record=True)
        check("first record exits 0", rc == 0, str(rc))
        check("manifest written", (good / MANIFEST_NAME).exists())
        man = read_manifest(good / MANIFEST_NAME)
        check("one line per original", len(man) == 4, str(man))
        check("shasum -c format", all(len(d) == 64 for d in man.values()))
        # TSC00.ARW has two names, raw/ and the hard link in edit/. The line
        # must name raw/, because edit/ is a folder `pl gather` rebuilds; a
        # manifest keyed on it reports a frame GONE after a re-gather and keeps
        # saying so for ever.
        check("a frame with two names is recorded under raw/, not edit/",
              "raw/TSC00.ARW" in man and "edit/TSC00.ARW" not in man, str(sorted(man)))
        check("the recipe in the manifest's header actually checks out",
              _shasum_c(good) == 0)
        check("clean verify exits 0", verify(good) == 0)
        (good / "raw" / "TSC01.ARW").write_bytes(b"z" * 8192)
        check("drift is reported", verify(good) == 1)
        check("drift is not quietly re-recorded",
              verify(good, record=True) == 1
              and read_manifest(good / MANIFEST_NAME)["raw/TSC01.ARW"] == man["raw/TSC01.ARW"])
        check("--accept-drift rewrites it",
              verify(good, record=True, accept_drift=True) == 0
              and read_manifest(good / MANIFEST_NAME)["raw/TSC01.ARW"] != man["raw/TSC01.ARW"])
        (good / "raw" / "TSC02.ARW").unlink()
        check("a vanished original is reported", verify(good) == 1)

        print("\n  a frame let go on purpose")
        check("--gone accepts it, and verify stops exiting 1 for ever",
              verify(good, let_go=["raw/TSC02.ARW"]) == 0)
        check("the note is in the manifest, where shasum -c ignores it",
              read_gone(good / MANIFEST_NAME) == {"raw/TSC02.ARW": time.strftime("%Y-%m-%d")}
              and _shasum_c(good) == 0, str(read_gone(good / MANIFEST_NAME)))
        check("its checksum line went with it", "raw/TSC02.ARW" not in read_manifest(good / MANIFEST_NAME))
        check("the next run is quiet about it", verify(good) == 0)
        check("--gone will not let go of a frame that is on the disk",
              verify(good, let_go=["raw/TSC03.ARW"]) == 1
              and "raw/TSC03.ARW" not in read_gone(good / MANIFEST_NAME))
        check("--accept-drift is still the only way to forgive a CHANGED file",
              "raw/TSC01.ARW" in read_manifest(good / MANIFEST_NAME))

        print("\n  one read per inode, not one per name")
        (good / "calib-skin").mkdir(parents=True, exist_ok=True)
        for tag in ("1base", "2clearview"):
            os.link(good / "raw" / "TSC00.ARW", good / "calib-skin" / f"TSC00_{tag}.ARW")
        reads: list[Path] = []
        real_sha = globals()["sha256"]
        globals()["sha256"] = lambda q: (reads.append(q), real_sha(q))[1]
        try:
            rc = verify(good, record=True)
        finally:
            globals()["sha256"] = real_sha
        originals_now = len(Shoot(good).originals)
        check("calib-skin's shape: three names, one inode, one read",
              rc == 0 and len(reads) == 3 and originals_now == 5,
              f"{len(reads)} reads for {originals_now} originals")
        man2 = read_manifest(good / MANIFEST_NAME)
        check("and every name still carries its own line, with that one digest",
              man2["calib-skin/TSC00_1base.ARW"] == man2["raw/TSC00.ARW"]
              == man2["calib-skin/TSC00_2clearview.ARW"])
        check("the recipe still checks out over all of them", _shasum_c(good) == 0)

        print("\n  an original that was archived and dropped")
        import archive as amod
        was, amod.ARCHIVE = amod.ARCHIVE, base / "icloud"
        try:
            up = base / "icloud" / good.name
            up.mkdir(parents=True)
            (up / "TSC03.ARW").write_bytes((good / "raw" / "TSC03.ARW").read_bytes())
            (good / "cull" / "archive.json").write_text(
                '{"shoot": "%s", "frames": {"TSC03.ARW": {"bytes": 8192}}}' % good.name)
            (good / "raw" / "TSC03.ARW").unlink()
            check("it is not reported missing: archive.json says where it went",
                  verify(good) == 0)
            (up / "TSC03.ARW").unlink()
            check("and when it is not in iCloud either, that IS an alarm", verify(good) == 1)
        finally:
            amod.ARCHIVE = was

        print("\n  a folder that is not one shoot")
        check("the library root is refused", bool(not_a_shoot(base)), str(not_a_shoot(base)))
        check("shoots/ is refused, and says which shoots it holds",
              "are shoots" in (not_a_shoot(base / "shoots") or ""), str(not_a_shoot(base / "shoots")))
        check("a shoot is not refused", not_a_shoot(good) is None, str(not_a_shoot(good)))
        check("a cleared shoot with no RAWs left is still a shoot",
              not_a_shoot(lounge) is None, str(not_a_shoot(lounge)))
        before = sorted(str(q.relative_to(base)) for q in base.rglob("*") if q.is_file())
        check("reclaim --apply on the library root exits 1", reclaim(base, apply=True) == 1)
        check("and on shoots/ too", reclaim(base / "shoots", apply=True) == 1)
        check("verify refuses it as well", verify(base / "shoots") == 1)
        after = sorted(str(q.relative_to(base)) for q in base.rglob("*") if q.is_file())
        check("not one file was touched by any of that", before == after,
              str(set(before) ^ set(after)))

        print("\n  report")
        old, globals()["ROOT"] = ROOT, base
        try:
            check("report runs over the whole library", report([]) == 0)
        finally:
            globals()["ROOT"] = old

    print(f"\n  {'all checks passed' if not fails else str(len(fails)) + ' FAILED: ' + ', '.join(fails)}")
    return 1 if fails else 0


def _shasum_c(shoot: Path) -> int:
    """Run the manifest's own printed recipe, from where it says to run it.

    The recipe is the whole point of writing plain text rather than JSON, so
    the selftest runs it rather than trusting that it reads correctly."""
    import subprocess
    r = subprocess.run(["shasum", "-a", "256", "-c", MANIFEST_NAME],
                       cwd=shoot, capture_output=True, text=True)
    return r.returncode


def _du_bytes(path: Path) -> int:
    """What `du -sk` would say, computed the same way, for the selftest's
    comparison. Directories report 0 blocks on APFS and symlinks report 0."""
    seen: set[tuple[int, int]] = set()
    total = 0
    for dirpath, _dirnames, filenames in os.walk(path):
        for name in filenames:
            try:
                st = (Path(dirpath) / name).lstat()
            except OSError:
                continue
            key = (st.st_dev, st.st_ino)
            if key in seen:
                continue
            seen.add(key)
            total += st.st_blocks * 512
    return total


# ------------------------------------------------------------------ main


USAGE = """usage: ./pl reclaim <command>

  report [<shoot>...]                   what every shoot costs: originals, decisions, derived, deliverables
  reclaim <shoot> [--apply]             remove derived bytes and nothing else. Prints the list first;
                                        removes nothing without --apply
  verify <shoot> [--record]             every original against its stored checksum
                 [--accept-drift]       rewrite a checksum that stopped matching (throws away the evidence)
                 [--gone <name>]        record that this frame was let go on purpose, so it stops
                                        being reported as missing. Repeatable. Not the same as
                                        --accept-drift, which is about a file that CHANGED.
  selftest                              the rules, against a fixture in a temp folder

An original that was archived and dropped is not missing and is not asked
about: archive.json records where it went, and verify reads it.
"""


def main(argv: list[str] | None = None) -> int:
    stop_cleanly_on_sigterm()
    argv = list(sys.argv[1:] if argv is None else argv)
    # --gone takes a value, and the flag split below cannot see that, so it is
    # lifted out first. A name is a path as the manifest spells it, relative to
    # the shoot: raw/TSC05422.ARW.
    let_go: list[str] = []
    rest: list[str] = []
    it = iter(argv)
    for a in it:
        if a == "--gone":
            nxt = next(it, None)
            if nxt is None or nxt.startswith("--"):
                print(f"  --gone needs a frame's name as {MANIFEST_NAME} spells it, e.g."
                      "  --gone raw/TSC05422.ARW")
                return 1
            let_go.append(nxt)
        elif a.startswith("--gone="):
            let_go.append(a.split("=", 1)[1])
        else:
            rest.append(a)
    argv = rest
    flags = {a for a in argv if a.startswith("--")}
    args = [a for a in argv if not a.startswith("--")]
    if not args or args[0] in ("-h", "help"):
        print(USAGE)
        return 1
    cmd, rest = args[0], [Path(a).expanduser() for a in args[1:]]
    if cmd == "report":
        return report(rest)
    if cmd == "reclaim":
        if not rest:
            print("which shoot? ./pl reclaim reclaim ~/photos/shoots/<name> [--apply]")
            return 1
        worst = 0
        for p in rest:
            worst = max(worst, reclaim(p, apply="--apply" in flags))
        return worst
    if cmd == "verify":
        if not rest:
            print("which shoot? ./pl reclaim verify ~/photos/shoots/<name> [--record]")
            return 1
        worst = 0
        for p in rest:
            worst = max(worst, verify(p, record="--record" in flags,
                                       accept_drift="--accept-drift" in flags, let_go=let_go))
        return worst
    if cmd == "selftest":
        return selftest()
    print(USAGE)
    return 1


if __name__ == "__main__":
    sys.exit(main())
