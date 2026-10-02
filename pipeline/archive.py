#!/usr/bin/env python3
"""
archive.py - a shoot's RAWs, kept in iCloud Drive.

    ./pl archive report                     what each shoot would cost, and what is already up
    ./pl archive status <shoot>             frame by frame: local, in iCloud, evicted, missing
    ./pl archive push <shoot> [--as raw|packed] [--apply]
                                            copy the originals up and verify them, the night of the
                                            shoot or any time after, as ARWs or packed bursts
                                            (burstpack.py, smaller, lossless). Deletes nothing.
    ./pl archive drop <shoot> [--apply]     remove local originals that are provably in iCloud, once
                                            the shoot is finished
    ./pl archive pull <shoot> [--apply]     bring them back down
    ./pl archive trim <shoot> [--only raw|packed|both] [--apply]
                                            remove copies from iCloud whose RAWs are on this Mac,
                                            the same bytes. No frame is left without a copy.
    ./pl archive repack <shoot> [--apply]   pack the ARWs already in iCloud, then let their ARW
                                            copies go once each packed copy is up and checked
    ./pl archive expire <shoot> [--apply]   let go of archived RAWs he no longer needs. The only
                                            command here that can destroy a photograph outright.

A finished shoot is 27 GB of RAW that will not be culled again, sitting on a
boot volume with 96 GB free. iCloud has room for it: 1.37 TiB at the time this
was written. So push, verify, then drop. Push only copies, so it works on a
shoot the night it is shot, before the card is used again; drop waits until
the shoot is finished.

WHY THIS IS NOT A COPY AND A `rm`
---------------------------------
Two things about iCloud on this machine make the obvious version wrong, and
both are silent.

1. EVICTION. `Optimise Mac Storage` is on, and 405 of the 3,202 files in
   this account's Drive were evicted when they were last counted. Modern
   macOS does not evict by leaving a `.name.icloud` stub the way it used to;
   it leaves a DATALESS file. The path still exists. `stat` still reports the
   real size. `Path.exists()` is True. The only honest signal is that no
   blocks are allocated, and the first read blocks on a network download that
   needs the network to be there.

   So "is the archived copy safe to rely on" cannot be answered by looking for
   the file. It is answered by `local(p)`, below, and nothing here trusts a
   path test instead. Nor is a copy with its bytes here proof that iCloud has
   it: a file in ~/Library/Mobile Documents is on this disk until iCloud says
   it has uploaded it, and `drop` asks (`uploaded`, below).

2. HARD LINKS. A RAW in a shoot is one inode with up to four names: raw/,
   cull/picks/, edit/, reels/burst<N>/. Unlinking raw/TSC05190.ARW frees
   nothing at all while edit/TSC05190.ARW still points at it. `drop` therefore
   removes every name the shoot has for that inode, and says how many it took
   to free one frame. This was measured: link count 4 on the action shoot.

WHAT IT WILL NOT DO
-------------------
  - remove the local originals of a shoot that is not finished (no `finished`
    in shoot.json), because the RAWs of an unfinished shoot are about to be
    read again. Copying them up is not refused: a copy takes nothing away, and
    a backup the same night, before the card is formatted for the next shoot,
    is the point of it
  - drop a single frame it has not just re-hashed, materialised, in iCloud,
    or one iCloud has not said it has uploaded
  - drop a frame whose file here is not the one that was archived
  - drop a frame that also has a name he made (calib-skin/), which it would
    not remove and without which nothing is freed
  - drop anything while the archive manifest disagrees with what is on disk
  - expire an archived copy as a spare unless the file here is the same bytes
  - remove a sidecar, a decision, an export or a reel. Only the originals.

The manifest lives with the decisions, not with the cache: losing the record of
where the photographs went is not something a re-run can rebuild in a hurry.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from common import (RAW_EXTS, decision_path, for_the_app, human, stop_cleanly_on_sigterm,  # noqa: E402
                    write_json_atomic)
import library  # noqa: E402

# The flag macOS sets on a file whose bytes have been evicted to the cloud.
# sys/stat.h: SF_DATALESS. There is no constant for it in Python's stat module.
SF_DATALESS = 0x40000000

ROOT = Path(os.environ.get("PHOTOS_ROOT", Path.home() / "photos")).expanduser()
ICLOUD = Path(os.environ.get(
    "PIPELINE_ICLOUD",
    Path.home() / "Library/Mobile Documents/com~apple~CloudDocs")).expanduser()
# One folder, named for what it is, so it reads as an archive in Finder on any
# device he opens it on rather than as a pile of camera files.
#
# It keeps the name the app had when the folder was made, for good: the app is
# First Edit now, and this folder is not renamed with it. Each shoot's
# archive.json keeps frame names only, and dest_for() rebuilds every path from
# this folder, so another name here would read every archived frame as missing
# (the only copies of some RAWs are in it) and the next push would copy
# gigabytes into a second folder. Nothing in the pipeline moves it.
ARCHIVE_NAME = "Photo Pipeline Archive"
ARCHIVE = ICLOUD / ARCHIVE_NAME
CHUNK = 1 << 20
# How many bursts Pack in iCloud downloads from iCloud at once.
FETCHERS = 6
MANIFEST = "archive.json"


# ------------------------------------------------------------ iCloud facts

def is_dataless(p: Path) -> bool:
    """True when the name is there and the bytes are not.

    This is the whole reason this module exists. An evicted file answers
    exists() with True and stat().st_size with its real size, so every check
    the rest of this pipeline makes about a file being present passes for a
    photograph that is not on the disk at all."""
    try:
        return bool(p.lstat().st_flags & SF_DATALESS)
    except (OSError, AttributeError):
        return False


def local(p: Path) -> bool:
    """The bytes are here, now, without a network."""
    try:
        st = p.lstat()
    except OSError:
        return False
    # st_flags is BSD's: a Mac has it, and Linux, which has no evicted files
    # to flag, does not.
    if getattr(st, "st_flags", 0) & SF_DATALESS:
        return False
    # A sparse or zero-length file is not what we archived. Blocks, not size.
    return st.st_size == 0 or st.st_blocks > 0


def materialise(p: Path, timeout: float = 600.0, poll: float = 0.5, stop=None) -> bool:
    """Ask macOS for the bytes of an evicted file and wait for them.

    Opening it is the request: the read blocks while FileProvider fetches it.
    A thread would hide the wait but not shorten it, so this is deliberately
    the slow, obvious version with a timeout, because the alternative is a
    cull that appears to hang for an hour on frame 400."""
    if local(p):
        return True
    try:
        with open(p, "rb") as fh:
            fh.read(1)
    except OSError:
        # The read IS the request, and when the download cannot happen at all
        # - offline, signed out, over quota - it fails at once. This used to
        # carry on into the wait below regardless, so each frame cost the full
        # ten minutes to learn what the first millisecond had said: an offline
        # pull of the 198 evicted frames of one shoot would have taken about
        # 33 hours to print the same line 198 times.
        return False
    end = time.time() + timeout
    while time.time() < end and not (stop is not None and stop.is_set()):
        if local(p):
            return True
        time.sleep(poll)
    return local(p)


# Where macOS keeps iCloud Drive, whatever PIPELINE_ICLOUD says. A copy under
# here is iCloud's to vouch for; a copy anywhere else is an ordinary file in a
# folder he named, and the file itself is the archive.
MOBILE_DOCUMENTS = Path.home() / "Library" / "Mobile Documents"


def _cf():
    """CoreFoundation, loaded once, or None off a Mac. ctypes rather than a
    pyobjc dependency: one resource query is the whole of what is needed."""
    global _CF
    if _CF is None:
        try:
            import ctypes
            cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
            vp = ctypes.c_void_p
            cf.CFURLCreateFromFileSystemRepresentation.restype = vp
            cf.CFURLCreateFromFileSystemRepresentation.argtypes = [vp, ctypes.c_char_p, ctypes.c_long, ctypes.c_bool]
            cf.CFURLCopyResourcePropertyForKey.restype = ctypes.c_bool
            cf.CFURLCopyResourcePropertyForKey.argtypes = [vp, vp, ctypes.POINTER(vp), ctypes.POINTER(vp)]
            cf.CFRelease.argtypes = [vp]
            cf.CFGetTypeID.restype = ctypes.c_ulong
            cf.CFGetTypeID.argtypes = [vp]
            cf.CFBooleanGetTypeID.restype = ctypes.c_ulong
            cf.CFBooleanGetValue.restype = ctypes.c_bool
            cf.CFBooleanGetValue.argtypes = [vp]
            _CF = (ctypes, cf)
        except (OSError, AttributeError):
            _CF = False
    return _CF or None


_CF = None


def icloud_says(p: Path, key: str = "kCFURLUbiquitousItemIsUploadedKey") -> bool | None:
    """What iCloud's own bookkeeping says about one file: True, False, or None
    when it says nothing at all.

    None is what macOS answers for a file iCloud does not manage - measured on
    an ordinary file on this disk, where every ubiquity key comes back empty
    rather than false - and it is also the answer when the question cannot be
    asked. Callers decide what None means for them; this does not guess."""
    got = _cf()
    if got is None:
        return None
    ctypes, cf = got
    try:
        k = ctypes.c_void_p.in_dll(cf, key)
    except ValueError:
        return None
    raw = os.fsencode(str(p))
    url = cf.CFURLCreateFromFileSystemRepresentation(None, raw, len(raw), False)
    if not url:
        return None
    val, err = ctypes.c_void_p(), ctypes.c_void_p()
    try:
        ok = cf.CFURLCopyResourcePropertyForKey(url, k, ctypes.byref(val), ctypes.byref(err))
        if not ok or not val.value:
            return None
        if cf.CFGetTypeID(val) != cf.CFBooleanGetTypeID():
            return None
        return bool(cf.CFBooleanGetValue(val))
    finally:
        if val.value:
            cf.CFRelease(val)
        if err.value:
            cf.CFRelease(err)
        cf.CFRelease(url)


def uploaded(p: Path) -> bool | None:
    """Whether iCloud has this archived copy on its servers, as iCloud says.

    push says it on every run: iCloud still has to upload what was copied, and
    nothing is safe to drop until it has. Nothing checked. drop hashed the copy
    in ~/Library/Mobile Documents, which proves the bytes are in a folder on
    THIS disk, and then removed every local name on that strength - so a drop
    run straight after a push, or with the upload stalled, left the only copy
    of a frame in a folder that had not left the Mac.

    Answers for a copy iCloud manages. For one it does not (PIPELINE_ICLOUD
    pointed at an ordinary folder or a drive) there is no upload to wait for,
    the file is the archive, and this answers None."""
    return icloud_says(p, "kCFURLUbiquitousItemIsUploadedKey")


def icloud_managed(p: Path) -> bool:
    """Whether this path is inside iCloud Drive, where iCloud must vouch for it.
    The copy's path is resolved and iCloud Drive's is not: it is a fixed place,
    and resolving it would mean reading it."""
    return Path(os.path.realpath(p)).is_relative_to(MOBILE_DOCUMENTS)


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for chunk in iter(lambda: fh.read(CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def progress(stage: str, done: int, total: int) -> None:
    """One machine-readable line per step, the convention cull.py prints.

    The studio draws one bar and it is fed from these. Nothing in this file
    printed them, so the page fell back to scraping the "40/1157 copied and
    verified" line push prints for a person - and drop, pull and expire print
    no such line at all, so a drop of the action shoot, which re-hashes
    26.9 GB out of iCloud before it removes anything, sat at 0% for its
    entire run."""
    print(f"@@ {stage} {done} {total}", flush=True)


def icloud_ready() -> str:
    """Empty when iCloud Drive is usable, else the reason it is not.

    Asked before anything is read, made or copied, so a Mac without iCloud
    Drive refuses with this sentence and leaves no folder behind. The app is
    told it without the path or the variable, which are a typist's."""
    if not ICLOUD.is_dir():
        if for_the_app():
            return ("iCloud Drive is not turned on on this Mac, so nothing was done. "
                    "Turn it on in System Settings, then try again.")
        return (f"iCloud Drive is not at {ICLOUD}. Turn on iCloud Drive in System Settings, "
                f"or set PIPELINE_ICLOUD to where it is.")
    return ""


# ------------------------------------------------------------ the shoot

def parts(shoot: Path) -> tuple[Path, Path]:
    """(the folder holding the RAWs, the cull folder), for both layouts.

    A flat shoot's cull is <shoot>/cull, which is where library.cull_dir and
    reclaim.cull_dirs both look. This said <shoot>/_cull, the fork of the old
    cull.py that produced the stray _cull/ beside the dog shoot and had to be
    moved back by hand, file by file (MOVES.log, 13 September). On a flat
    shoot - the ducks shoot is one, 98 loose ARW - it sent the archive
    manifest and the answer-key lookup into a folder nothing else in this
    pipeline reads, so `expire` would have found no selects.json and `push`
    would have minted a second _cull/ the first time it wrote. An existing
    _cull/ is still honoured, because one may yet be on a disk somewhere.

    Both answers are library.paths' now, the one rule. This had its own: a
    flat shoot took _cull/ whenever it existed, even beside a cull/ that
    held the cull.csv, so a flat shoot with both got a different cull here
    than from every other command. And it may be handed the shoot's raw/ or
    cull/ as well as the shoot, as every command may: given raw/ it used to
    answer raw/cull, a folder inside the originals."""
    p = library.paths(Path(shoot).expanduser().resolve())
    return p.raw, p.cull


def originals(raw: Path) -> list[Path]:
    return sorted(p for p in raw.iterdir()
                  if p.is_file() and p.suffix.lower() in RAW_EXTS)


def finished(shoot: Path) -> str:
    """When he marked this shoot done, or empty."""
    try:
        return str(json.loads((shoot / "shoot.json").read_text()).get("finished") or "")
    except (OSError, ValueError):
        return ""


def links_in_shoot(shoot: Path, key: tuple[int, int]) -> list[Path]:
    """Every name this shoot has for one inode.

    Unlinking raw/TSC05190.ARW frees nothing while edit/TSC05190.ARW is the
    same file. Only the folders the pipeline itself links into are searched,
    so a copy he made somewhere of his own is never counted or removed.

    The originals' folder and the cull are asked for by parts() rather than
    spelled `raw` and `cull`. On a flat shoot - the ducks shoot, 98 loose
    ARW with no raw/ at all - this searched four folders that do not exist
    and found no name for any frame, so `drop --apply` unlinked nothing,
    printed "removed 98 originals and their links; 2.3 GB back", and reported
    a negative count of further links on the way. He would have been told his
    RAWs had gone from a disk they were still sitting on.

    Keyed on (st_dev, st_ino), never st_ino alone: an inode number is unique
    on one volume and nowhere else, and every path this returns is about to
    be passed to unlink()."""
    shoot = Path(shoot).expanduser().resolve()
    return [q for q in inode_names(shoot).get(key, []) if pipeline_name(shoot, q)]


def pipeline_name(shoot: Path, q: Path) -> bool:
    """Whether this name for a RAW is one the pipeline keeps: the original in
    its own folder, or a link that gather, the cull or a reel put down.

    Every other name is his. The action shoot's calib-skin folder hangs 36
    names off 3 of its RAWs, each name with a .dop of its own, made by hand."""
    raw, cull = parts(shoot)
    d = q.parent
    return d in (raw, shoot / "edit", cull / "picks") or (shoot / "reels") in q.parents


def inode_names(shoot: Path) -> dict[tuple[int, int], list[Path]]:
    """Every name inside the shoot for every file, by (st_dev, st_ino), in
    one walk. Regular files only: a symlink is not a name for the bytes.

    One walk and not one per frame, because drop asks this for 1,157 frames
    and it is the only way to see a name outside the folders the pipeline
    links into - which is the name drop must not remove and must not pretend
    it has freed the space of."""
    shoot = Path(shoot)
    out: dict[tuple[int, int], list[Path]] = {}
    for dirpath, _dirs, files in os.walk(shoot):
        for fn in sorted(files):
            p = Path(dirpath) / fn
            try:
                st = p.lstat()
            except OSError:
                continue
            if stat.S_ISREG(st.st_mode):
                out.setdefault((st.st_dev, st.st_ino), []).append(p)
    return out


def manifest_path(shoot: Path) -> Path:
    """Where this shoot's record of what went to iCloud is.

    Asked through common.decision_path, which prefers a file that EXISTS
    wherever it is and falls back to the convention only when there is none.
    This picked decisions/ the moment that folder existed, without looking: a
    shoot pushed before `./pl migrate` ran keeps its archive.json in cull/,
    and until this record was added to migrate's table of names it knows how
    to move, migrate left it there. From the day decisions/ appeared this looked
    straight past it - load_manifest would answer "nothing was ever pushed"
    about 26.9 GB that had been, drop would refuse to free a byte, and the
    next push would write a second record in the other folder."""
    return decision_path(parts(shoot)[1], MANIFEST)


def load_manifest(shoot: Path) -> dict:
    try:
        return json.loads(manifest_path(shoot).read_text())
    except (OSError, ValueError):
        return {"shoot": Path(shoot).name, "frames": {}}


def dest_for(shoot: Path, name: str) -> Path:
    return ARCHIVE / Path(shoot).name / name


# ------------------------------------------------------------ packed bursts
#
# A burst packed on the Finish page (burstpack.py) is a second form a frame's
# copy in iCloud can take: packed/<burst>.roll in the shoot's archive folder,
# holding every frame of the burst losslessly, in less space. push
# sends it instead of the burst's ARWs; drop and pull accept it as the copy.
#
# The record is archive.json's "packed": for each file its bytes and SHA-256,
# and for each frame in it that frame's bytes and SHA-256 as it was packed.
# Nothing here trusts a packed file on its record alone. push unpacks it in
# memory, and checks every frame against the RAW on this disk, before copying
# it; drop unpacks the copy IN iCloud and removes a RAW only when what comes
# out is, byte for byte, the RAW it is about to remove; pull checks what it
# writes against the record before the name is given to it.

PACKED = "packed"


def packed_dest(shoot: Path, file: str) -> Path:
    return ARCHIVE / Path(shoot).name / PACKED / file


def _clear_parts(shoot: Path) -> None:
    """A copy into iCloud lands as .<name>.part and takes its name only once
    it has been read back. One that was never finished - the app force-quit,
    the Mac off mid-copy, anything a Stop could not unwind - is left in iCloud
    Drive to be uploaded as a file of its own, and nothing else ever removes
    it. This module is the only thing that writes one, and only one job at a
    time runs on a shoot, so any here when a job starts are strays."""
    for d in (ARCHIVE / Path(shoot).name, ARCHIVE / Path(shoot).name / PACKED):
        for t in (d.glob(".*.part") if d.is_dir() else []):
            t.unlink(missing_ok=True)
            print(f"    removed {t.name}, a copy an earlier run never finished")


def clear_strays(shoots: Path) -> list[str]:
    """What an interrupted pack left anywhere, cleared: the unfinished copies
    in iCloud (_clear_parts) and, in each shoot, the half-written packs and
    the staging folder a repack packs into. A run cleans up after itself when
    it can, and the next run of the same job on the same shoot clears what it
    could not; a shoot that is never packed again kept them - in iCloud Drive,
    uploaded against his storage. Only these names, which nothing but a pack
    writes, and nothing is opened, so nothing iCloud has evicted is fetched.
    For the engine to run when it starts and no job of its own is running.
    Returns what went, for its log."""
    gone: list[str] = []

    def drop(t: Path) -> None:
        try:
            t.unlink()
            gone.append(str(t))
        except OSError:
            pass

    for shoot in (sorted(d for d in shoots.iterdir() if d.is_dir()) if shoots.is_dir() else []):
        packed = shoot / PACKED
        if not packed.is_dir():
            continue
        for t in [*packed.glob(".burst-*.roll.*.tmp"), *packed.glob(".frame-*.roll.*.tmp")]:
            drop(t)
        stage = packed / ".staging"
        if stage.is_dir():
            for t in stage.iterdir():
                drop(t)
            try:
                stage.rmdir()
                gone.append(str(stage))
            except OSError:
                pass
    if ICLOUD.is_dir() and ARCHIVE.is_dir():
        for up in sorted(d for d in ARCHIVE.iterdir() if d.is_dir()):
            for d in (up, up / PACKED):
                for t in (d.glob(".*.part") if d.is_dir() else []):
                    drop(t)
    return gone


def packed_frames(man: dict) -> dict[str, tuple[str, dict]]:
    """Every frame recorded in a packed file up there: name -> (file, frame record)."""
    out: dict[str, tuple[str, dict]] = {}
    for file, rec in (man.get("packed") or {}).items():
        for name, fr in (rec.get("frames") or {}).items():
            out.setdefault(name, (file, fr))
    return out


def _burstpack():
    sys.path.insert(0, str(HERE))
    import burstpack
    return burstpack


def unpacked_hashes(p: Path) -> dict[str, str]:
    """name -> SHA-256 of every frame this packed file gives back, unpacked in
    memory. burstpack checks each frame against the checksum the file carries
    and refuses the whole file if any differs; ValueError, or OSError, if it
    cannot be read or unpacked at all."""
    bp = _burstpack()
    return {name: hashlib.sha256(data).hexdigest() for name, data in bp._unpack_bytes(p.read_bytes()).items()}


def local_packed(shoot: Path) -> list[Path]:
    d = Path(shoot) / PACKED
    return sorted(q for q in d.glob("*" + _burstpack().EXT) if not q.name.startswith(".")) if d.is_dir() else []


# ------------------------------------------------------------ status

def status(shoot: Path) -> dict:
    """What is true right now, per frame, without trusting the manifest."""
    shoot = Path(shoot).expanduser().resolve()
    raw, _ = parts(shoot)
    whole = load_manifest(shoot)
    man = whole["frames"]
    packed = packed_frames(whole)

    def up_of(name: str) -> tuple[bool, bool]:
        # The ARW copy when there is one; else the packed file holding the frame.
        d = dest_for(shoot, name)
        if d.exists() or name not in packed:
            return d.exists(), local(d)
        q = packed_dest(shoot, packed[name][0])
        return q.exists(), local(q)

    rows = []
    for p in originals(raw):
        up, up_local = up_of(p.name)
        rows.append({
            "name": p.name,
            "bytes": p.stat().st_size,
            "here": local(p),
            "here_evicted": is_dataless(p),
            "up": up,
            "up_local": up_local,
            "recorded": p.name in man or p.name in packed,
        })
    # Frames that are in the manifest and no longer beside the RAWs: already dropped.
    here = {r["name"] for r in rows}
    for name, rec in [*man.items(), *((n, fr) for n, (_f, fr) in packed.items() if n not in man)]:
        if name not in here:
            up, up_local = up_of(name)
            rows.append({"name": name, "bytes": rec.get("bytes", 0), "here": False,
                         "here_evicted": False, "up": up, "up_local": up_local,
                         "recorded": True, "dropped": True})
            here.add(name)
    return {"shoot": shoot, "rows": rows, "finished": finished(shoot)}


def summarise(st: dict) -> dict:
    r = st["rows"]
    return {
        "frames": len(r),
        "here": sum(1 for x in r if x["here"]),
        "here_evicted": sum(1 for x in r if x.get("here_evicted")),
        "up": sum(1 for x in r if x["up"]),
        "up_evicted": sum(1 for x in r if x["up"] and not x["up_local"]),
        "dropped": sum(1 for x in r if x.get("dropped")),
        "bytes_here": sum(x["bytes"] for x in r if x["here"]),
        "bytes_up": sum(x["bytes"] for x in r if x["up"]),
    }


# ------------------------------------------------------------ push

def push(shoot: Path, apply: bool, force: bool = False, form: str = "raw") -> int:
    """Copy the originals up and read each one back. Removes nothing, here or
    there, and so asks nothing of the shoot: it used to refuse one not marked
    finished, which put the one backup he wants the same night - before the
    card is formatted for the next shoot - days away, behind his editing.
    Removing the local originals is what waits for Finish (drop, below).
    `force` is what that refusal was passed to get past; it is still taken,
    so a line typed from habit is not an error, and means nothing now.

    `form` is what goes up: "raw", the ARWs as they are, or "packed", each
    burst packed first (burstpack.py) and sent as one smaller file (57-88% of
    its RAWs on real a6500 shoots, by the light). A frame already up in either
    form is not sent again."""
    shoot = Path(shoot).expanduser().resolve()
    bad = icloud_ready()
    if bad:
        print(f"  {bad}")
        return 1
    if apply:
        _clear_parts(shoot)
    raw, _ = parts(shoot)
    if not raw.is_dir():
        print(f"  no such shoot: {shoot}")
        return 1

    frames = originals(raw)
    evicted = [p for p in frames if is_dataless(p)]
    if evicted:
        print(f"  {len(evicted)} of this shoot's own RAWs are already evicted to iCloud and would")
        print("  have to come back down before they could be hashed. Bring Back from iCloud first."
              if for_the_app() else
              f"  have to come back down before they could be hashed. Run: ./pl archive pull {shoot.name} --apply")
        return 1
    # A name with no bytes behind it and no eviction flag either: the size is
    # real, nothing is allocated, and a read hands back zeros. This screened on
    # the flag alone, so such a RAW was hashed as zeros, copied up, recorded as
    # healthy, and from then on read as a good archive copy - which drop would
    # verify against that record and then remove every local name of.
    hollow = [p for p in frames if not local(p)]
    if hollow:
        print(f"  {len(hollow)} of this shoot's own RAWs have no bytes behind the name: the file")
        print("  reports its size and nothing is stored in it, so what would be archived is")
        print("  zeros. Nothing was copied. Look at these before anything else:")
        for p in hollow[:8]:
            print(f"    - {p.name}: no bytes behind the name")
        if len(hollow) > 8:
            print(f"    - ... and {len(hollow) - 8} more")
        return 1

    man = load_manifest(shoot)
    man.setdefault("packed", {})
    # A frame is up when its ARW is, or a packed burst holding it is: either
    # way it is not copied again, whichever form he asks for this time.
    up_already: set[str] = set()
    for file, rec in man["packed"].items():
        q = packed_dest(shoot, file)
        if q.exists() and q.stat().st_size == rec.get("bytes"):
            up_already |= set(rec.get("frames") or {})
    todo, already = [], 0
    for p in frames:
        rec = man["frames"].get(p.name)
        d = dest_for(shoot, p.name)
        if (rec and d.exists() and d.stat().st_size == rec.get("bytes")) or p.name in up_already:
            already += 1
            continue
        todo.append(p)

    total = sum(p.stat().st_size for p in todo)
    print(f"  {shoot.name}: {len(frames)} originals, {already} already up")
    print(f"  would copy {len(todo)} frames, {human(total)}, to {dest_for(shoot, '').parent}")
    if todo and form == "packed":
        print("  packed first, each burst into one smaller file (burstpack), and each")
        print("  file unpacked and checked against its RAWs before it is copied")
    if not todo:
        print("  nothing to do.")
        return 0
    if not apply:
        print("\n  nothing was copied. Add --apply to copy and verify.")
        return 0

    # Packed: the bursts holding what is to go are packed now (a burst packed
    # already is used as it is), and those files go up in place of the ARWs.
    # Which frames a file holds is read off the file; that it holds exactly
    # the RAWs on this disk is proved before it is copied, below, and a file
    # that fails the proof is passed over for its ARWs.
    bp_files: list[tuple[Path, list[str]]] = []
    if form == "packed":
        need = {p.name for p in todo}
        _burstpack().pack_shoot(shoot, True, log=lambda line: print(line, flush=True), only=need)
        covered: set[str] = set()
        for q in local_packed(shoot):
            try:
                inside = [f["name"] for f in _burstpack().read_manifest(q.read_bytes())[0]["frames"]]
            except (OSError, ValueError, KeyError):
                print(f"    {q.name}: not a packed burst this can read; its frames go up as RAWs")
                continue
            if need & set(inside) and not covered & set(inside):
                bp_files.append((q, inside))
                covered |= set(inside)
        todo = [p for p in todo if p.name not in covered]
    packed_frames_n = sum(len(inside) for _q, inside in bp_files)

    dest_dir = ARCHIVE / shoot.name
    dest_dir.mkdir(parents=True, exist_ok=True)
    # The manifest's folder, before the first frame is copied rather than
    # after. decision_path names <shoot>/decisions or <shoot>/cull and makes
    # neither, and a shoot that has never been culled has neither on disk -
    # the ducks shoot is 98 loose ARW and nothing else. So push copied every
    # frame to iCloud and then died in write_json_atomic with a traceback,
    # having recorded not one of them: drop then said nothing was ever pushed,
    # and the next push copied all 2.3 GB up again.
    manifest_path(shoot).parent.mkdir(parents=True, exist_ok=True)
    ok = failed = 0
    steps = len(todo) + packed_frames_n
    step = 0
    by_name = {p.name: p for p in frames}
    for q, inside in bp_files:
        progress("push", step, steps)
        d = packed_dest(shoot, q.name)
        tmp = d.parent / f".{q.name}.part"
        try:
            # The proof: what the file gives back is, frame by frame, the RAW
            # on this disk. A frame whose RAW is not here is taken on the
            # file's own checksum, which burstpack has already matched.
            got = unpacked_hashes(q)
            wrong = [n for n in inside if n not in got
                     or (n in by_name and local(by_name[n]) and sha256(by_name[n]) != got[n])]
            if wrong:
                print(f"    {q.name}: does not unpack to the RAWs here ({wrong[0]}); its frames go up as RAWs")
                todo += [by_name[n] for n in inside if n in by_name and n not in {p.name for p in todo}]
                continue
            want = sha256(q)
            d.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(q, tmp)
            if sha256(tmp) != want:
                tmp.unlink(missing_ok=True)
                print(f"    {q.name}: copied wrong, left alone")
                failed += len(inside)
                continue
            _burstpack().give_icon(tmp)      # a copy does not carry the icon; iCloud keeps it on eviction
            os.replace(tmp, d)
            man["packed"][q.name] = {
                "bytes": q.stat().st_size, "sha256": want,
                "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "frames": {n: {"bytes": (by_name[n].stat().st_size if n in by_name else 0), "sha256": got[n]}
                           for n in inside}}
            ok += len(inside)
        except (OSError, ValueError) as e:
            tmp.unlink(missing_ok=True)
            print(f"    {q.name}: {e}")
            failed += len(inside)
        except BaseException:
            tmp.unlink(missing_ok=True)
            write_json_atomic(manifest_path(shoot), man)
            raise
        step += len(inside)
        print(f"    {step}/{steps} copied and verified")
        write_json_atomic(manifest_path(shoot), man)
    for i, p in enumerate(todo, 1):
        # At the head of the loop, not the foot: a frame that copies wrong
        # takes a `continue`, and a bar that stops moving on the runs worth
        # watching is worse than no bar.
        progress("push", step + i - 1, step + len(todo))
        d = dest_dir / p.name
        tmp = dest_dir / f".{p.name}.part"
        try:
            want = sha256(p)
            shutil.copyfile(p, tmp)
            # Verified from the destination, after the copy, by reading it back.
            # A copy that reports success and lands wrong is the failure this
            # whole module exists to make impossible.
            if sha256(tmp) != want:
                tmp.unlink(missing_ok=True)
                print(f"    {p.name}: copied wrong, left alone")
                failed += 1
                continue
            os.replace(tmp, d)
            man["frames"][p.name] = {"bytes": p.stat().st_size, "sha256": want,
                                     "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
            ok += 1
        except OSError as e:
            tmp.unlink(missing_ok=True)
            print(f"    {p.name}: {e}")
            failed += 1
        except BaseException:
            # Stopped from the studio (SIGTERM arrives as SystemExit). The
            # half-copied .part is inside iCloud Drive, where it would be
            # uploaded as a file of its own, and every frame copied and
            # verified since the last write of the manifest was about to be
            # forgotten and copied up again next time. Neither is left so.
            tmp.unlink(missing_ok=True)
            write_json_atomic(manifest_path(shoot), man)
            raise
        if i % 50 == 0 or i == len(todo):
            print(f"    {i}/{len(todo)} copied and verified")
            write_json_atomic(manifest_path(shoot), man)
    progress("push", step + len(todo), step + len(todo))
    write_json_atomic(manifest_path(shoot), man)
    if for_the_app():
        # One line, and the last: the panel says it under "Finished copying
        # the RAWs of … to iCloud". It ended on `./pl archive drop` and his
        # whole home path.
        said = f"{ok} copied and verified, {failed} failed."
        if ok:
            said += " iCloud still has to upload them, and Remove from This Mac takes none until it has."
        if failed:
            said += f" Back Up to iCloud again copies the {failed} that failed."
        print(f"\n  {said}")
        return 0 if not failed else 1
    print(f"\n  {ok} copied and verified, {failed} failed.")
    print(f"  recorded in {manifest_path(shoot)}")
    if ok:
        print("  iCloud still has to upload them. Nothing is safe to drop until it has:")
        print(f"    ./pl archive drop {shoot}")
    return 0 if not failed else 1


# ------------------------------------------------------------ finished work
#
# The exported photographs: what PhotoLab writes into export/ or edit/edited/,
# the reels, the delivery folders. These were never archived at all, so a
# shoot whose RAWs had all gone to iCloud still kept every finished JPEG on
# this Mac and nowhere else - about 20 GB of the library, and the one copy of
# the work. They go up beside the RAWs, are read back and recorded, and come
# off this Mac with the RAWs once iCloud vouches for them.

FINISHED = "finished"
FINISHED_DIRS = ("export", "edit", "reels", "upload", "cull/picks/edited")
FINISHED_EXTS = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".heic", ".mp4", ".mov", ".m4v"}
# Read live by the delivery step and remade by it at will: kept here.
FINISHED_SKIP = ("upload/_store/previews", "upload/_store/tmp", "upload/_store/zips")


def finished_dest(shoot: Path, rel: str) -> Path:
    return ARCHIVE / Path(shoot).name / FINISHED / rel


def finished_files(shoot: Path) -> list[Path]:
    """Every finished photograph in the shoot with its bytes on this disk.
    Not a name that is also an original in raw/ (a camera JPEG linked into
    edit/ is the RAW archive's to look after), not a link, not a name iCloud
    has emptied."""
    shoot = Path(shoot)
    raw, _ = parts(shoot)
    out = []
    names = None
    for d in FINISHED_DIRS:
        root = shoot / d
        if not root.is_dir():
            continue
        for q in sorted(root.rglob("*")):
            rel = q.relative_to(shoot).as_posix()
            if q.suffix.lower() not in FINISHED_EXTS or q.is_symlink() or not q.is_file():
                continue
            if any(rel.startswith(x + "/") for x in FINISHED_SKIP):
                continue
            st = q.lstat()
            if st.st_nlink > 1:
                names = names if names is not None else inode_names(shoot)
                if any(raw in n.parents for n in names.get((st.st_dev, st.st_ino), [])):
                    continue
            if not local(q):
                continue
            out.append(q)
    return out


def push_finished(shoot: Path, apply: bool) -> int:
    """The finished photographs up beside the RAWs, each read back before it
    is recorded. A photograph whose bytes are already up under another of
    its names (export/ and the same JPEG filed in a delivery folder) is
    recorded against that one copy and not sent twice."""
    shoot = Path(shoot).expanduser().resolve()
    bad = icloud_ready()
    if bad:
        print(f"  {bad}")
        return 1
    whole = load_manifest(shoot)
    rec = whole.setdefault("finished", {})
    by_sha = {r["sha256"]: r["stored"] for r in rec.values() if finished_dest(shoot, r["stored"]).exists()}
    todo = []
    for q in finished_files(shoot):
        rel = q.relative_to(shoot).as_posix()
        r = rec.get(rel)
        if r and finished_dest(shoot, r["stored"]).exists() and r.get("bytes") == q.stat().st_size:
            continue
        todo.append((q, rel))
    if not todo:
        return 0
    # Counted by what actually goes up: the same JPEG filed in export/ and in
    # three delivery folders is one copy up there, and the figure on the
    # button said 25.7 GB for a shoot whose distinct photographs were half that.
    shas = {rel: sha256(q) for q, rel in todo}
    sent, total = set(by_sha), 0
    for q, rel in todo:
        if shas[rel] not in sent:
            sent.add(shas[rel])
            total += q.stat().st_size
    print(f"  would copy {len(todo)} finished photos, {human(total)}, to {finished_dest(shoot, '')}")
    if not apply:
        return 0
    manifest_path(shoot).parent.mkdir(parents=True, exist_ok=True)
    ok = failed = 0
    for i, (q, rel) in enumerate(todo, 1):
        progress("push", i - 1, len(todo))
        try:
            want = shas[rel]
            stored = by_sha.get(want)
            if stored is None:
                d = finished_dest(shoot, rel)
                d.parent.mkdir(parents=True, exist_ok=True)
                tmp = d.parent / f".{d.name}.part"
                try:
                    shutil.copyfile(q, tmp)
                    if sha256(tmp) != want:
                        tmp.unlink(missing_ok=True)
                        print(f"    {rel}: copied wrong, left alone")
                        failed += 1
                        continue
                    os.replace(tmp, d)
                except BaseException:
                    tmp.unlink(missing_ok=True)
                    raise
                stored = by_sha[want] = rel
            rec[rel] = {"bytes": q.stat().st_size, "sha256": want, "stored": stored,
                        "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
            ok += 1
        except OSError as e:
            print(f"    {rel}: {e}")
            failed += 1
        except BaseException:
            write_json_atomic(manifest_path(shoot), whole)
            raise
        if i % 50 == 0:
            write_json_atomic(manifest_path(shoot), whole)
    progress("push", len(todo), len(todo))
    write_json_atomic(manifest_path(shoot), whole)
    print(f"  {ok} finished photos copied and verified, {failed} failed.")
    return 0 if not failed else 1


def drop_finished(shoot: Path, apply: bool) -> int:
    """Finished photographs off this Mac, each only once its copy in iCloud
    has been read back, matched to its record and vouched for by iCloud, and
    the file here is the one that was copied. Waits for Finish, as the RAWs
    do: until then they are still being exported and filed."""
    shoot = Path(shoot).expanduser().resolve()
    whole = load_manifest(shoot)
    rec = whole.get("finished") or {}
    if not rec or not finished(shoot) or icloud_ready():
        return 0
    checked: dict[str, str] = {}
    safe, kept = [], 0
    for q in finished_files(shoot):
        rel = q.relative_to(shoot).as_posix()
        r = rec.get(rel)
        if not r:
            continue
        d = finished_dest(shoot, r["stored"])
        if r["stored"] not in checked:
            why = ""
            if not d.exists():
                why = "not in iCloud"
            elif not local(d):
                why = "the iCloud copy is evicted; it must come down to be checked"
            elif d.stat().st_size != r.get("bytes"):
                why = "the iCloud copy is a different size"
            else:
                why = _unvouched(d) or ("" if sha256(d) == r["sha256"] else "the iCloud copy does not match")
            checked[r["stored"]] = why
        if checked[r["stored"]] or q.stat().st_size != r.get("bytes") or sha256(q) != r["sha256"]:
            kept += 1
            continue
        safe.append((q, d, _sig(q), _sig(d)))
    if not safe:
        return 0
    size = sum(q.lstat().st_blocks * 512 for q, *_ in safe)
    print(f"  and {len(safe)} finished photos on this Mac ({human(size)}) whose copy in iCloud is checked"
          + (f"; {kept} kept" if kept else ""))
    if not apply:
        return 0
    gone = back = 0
    for q, d, qsig, dsig in safe:
        if _sig(q) != qsig or _sig(d) != dsig or _unvouched(d):
            continue
        st = q.lstat()
        try:
            q.unlink()
        except OSError as e:
            print(f"    {q.name}: {e}")
            continue
        gone += 1
        back += st.st_blocks * 512
    print(f"  removed {gone} finished photos; {human(back)} back. Bring Back from iCloud brings them down again.")
    return 0


def pull_finished(shoot: Path, apply: bool) -> int:
    """Every finished photograph recorded up there and not here, back where
    it was, read back against its record before it takes its name."""
    shoot = Path(shoot).expanduser().resolve()
    rec = load_manifest(shoot).get("finished") or {}
    want = [(rel, r) for rel, r in sorted(rec.items()) if not local(shoot / rel)]
    if not want:
        return 0
    print(f"  and {len(want)} finished photos to bring back, {human(sum(r.get('bytes', 0) for _, r in want))}")
    if not apply:
        return 0
    bad = 0
    for i, (rel, r) in enumerate(want, 1):
        progress("pull", i - 1, len(want))
        src, dst = finished_dest(shoot, r["stored"]), shoot / rel
        tmp = dst.parent / f".{dst.name}.part"
        try:
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, tmp)
            if sha256(tmp) != r["sha256"]:
                raise OSError("came back different from what was copied up")
            os.replace(tmp, dst)
        except OSError as e:
            tmp.unlink(missing_ok=True)
            print(f"    {rel}: {e}")
            bad += 1
    progress("pull", len(want), len(want))
    print(f"  {len(want) - bad} finished photos back, {bad} failed.")
    return 1 if bad else 0


# ------------------------------------------------------------ sidecars
#
# His edits: a .dop (PhotoLab) or .xmp beside each RAW, and the copy gather
# puts beside the link in edit/. They were never archived, so the edits of a
# shoot whose RAWs had gone up lived on this Mac alone, and once the RAWs had
# gone raw/ and edit/ held nothing but 1,500 sidecars each. They go up with
# the RAWs; when a frame's RAW leaves, its sidecar is gathered into
# decisions/sidecars/, which everything that learns from his edits reads
# (library.ShootPaths.sidecars); and it goes back beside the RAW when the RAW
# comes back, which is where PhotoLab looks. None is ever deleted, except a
# copy byte for byte the same as the one kept.

SIDECAR_EXTS = (".dop", ".xmp")
SIDECARS = "sidecars"


def _frame_of(name: str) -> str:
    """The frame a sidecar belongs to, by number: TSC0001.ARW.dop and
    TSC0001.xmp both say TSC0001."""
    return name.split(".", 1)[0].lower()


def sidecar_files(shoot: Path) -> list[Path]:
    where = library.paths(Path(shoot))
    out = []
    for folder in (where.raw, where.edit, where.sidecars):
        if folder.is_dir():
            out += sorted(q for q in folder.iterdir()
                          if q.suffix.lower() in SIDECAR_EXTS and q.is_file() and not q.is_symlink() and local(q))
    return out


def push_sidecars(shoot: Path, apply: bool) -> int:
    """Every sidecar up beside the RAWs, again whenever it has changed: they
    are edited after the RAWs went up, and the copy up there is the newest."""
    shoot = Path(shoot).expanduser().resolve()
    if icloud_ready():
        return 0
    whole = load_manifest(shoot)
    rec = whole.setdefault(SIDECARS, {})
    todo = []
    for q in sidecar_files(shoot):
        rel = q.relative_to(shoot).as_posix()
        want = sha256(q)
        r = rec.get(rel)
        if r and r.get("sha256") == want and (ARCHIVE / shoot.name / SIDECARS / r["stored"]).exists():
            continue
        todo.append((q, rel, want))
    if not todo:
        return 0
    print(f"  and {len(todo)} sidecars (your edits), {human(sum(q.stat().st_size for q, *_ in todo))}")
    if not apply:
        return 0
    manifest_path(shoot).parent.mkdir(parents=True, exist_ok=True)
    bad = 0
    for q, rel, want in todo:
        d = ARCHIVE / shoot.name / SIDECARS / rel
        tmp = d.parent / f".{d.name}.part"
        try:
            d.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(q, tmp)
            if sha256(tmp) != want:
                raise OSError("copied wrong")
            os.replace(tmp, d)
            rec[rel] = {"bytes": q.stat().st_size, "sha256": want, "stored": rel,
                        "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        except OSError as e:
            tmp.unlink(missing_ok=True)
            print(f"    {rel}: {e}")
            bad += 1
        except BaseException:
            tmp.unlink(missing_ok=True)
            write_json_atomic(manifest_path(shoot), whole)
            raise
    write_json_atomic(manifest_path(shoot), whole)
    print(f"  {len(todo) - bad} sidecars copied and verified, {bad} failed.")
    return 1 if bad else 0


def sidecar_moves(shoot: Path) -> list[Path]:
    """The sidecars in raw/ and edit/ of frames whose RAW is not on this Mac."""
    where = library.paths(Path(shoot))
    here = {_frame_of(p.name) for p in originals(where.raw) if local(p)}
    out = []
    for folder in (where.raw, where.edit):
        if folder.is_dir():
            out += [q for q in sorted(folder.iterdir())
                    if q.suffix.lower() in SIDECAR_EXTS and q.is_file() and not q.is_symlink()
                    and _frame_of(q.name) not in here and local(q)]
    return out


def gather_sidecars(shoot: Path, apply: bool) -> int:
    """The sidecars of frames whose RAW is not on this Mac, out of raw/ and
    edit/ into decisions/sidecars/. A second copy that is byte for byte the
    one kept goes; one that differs is kept beside it under older/, the newer
    of the two (by when it was written) taking the name."""
    shoot = Path(shoot).expanduser().resolve()
    where = library.paths(shoot)
    moves = sidecar_moves(shoot)
    if not moves:
        return 0
    print(f"  and {len(moves)} sidecars of frames in iCloud, gathered into {where.sidecars.relative_to(shoot)}/")
    if not apply:
        return 0
    where.sidecars.mkdir(parents=True, exist_ok=True)
    for q in moves:
        t = where.sidecars / q.name
        if not t.exists():
            os.replace(q, t)
        elif sha256(t) == sha256(q):
            q.unlink()
        else:
            old = where.sidecars / "older"
            old.mkdir(exist_ok=True)
            newer, other = (q, t) if q.stat().st_mtime > t.stat().st_mtime else (t, q)
            n = 1
            while (old / f"{n}-{q.name}").exists():
                n += 1
            os.replace(other, old / f"{n}-{q.name}")
            if newer is q:
                os.replace(q, t)
    return 0


def return_sidecars(shoot: Path, apply: bool) -> int:
    """Back beside the RAW, for every frame whose RAW is on this Mac again."""
    shoot = Path(shoot).expanduser().resolve()
    where = library.paths(shoot)
    if not where.sidecars.is_dir():
        return 0
    here = {_frame_of(p.name) for p in originals(where.raw) if local(p)}
    back = [q for q in sorted(where.sidecars.iterdir())
            if q.is_file() and q.suffix.lower() in SIDECAR_EXTS and _frame_of(q.name) in here]
    if back and apply:
        for q in back:
            if not (where.raw / q.name).exists():
                os.replace(q, where.raw / q.name)
        print(f"  {len(back)} sidecars back beside their RAWs")
    return 0


# ------------------------------------------------------------ drop

def _sig(p: Path) -> tuple[int, int, int, int] | None:
    """Which file this is, cheaply: volume, inode, size and mtime. What drop
    checked has to still be what it removes."""
    try:
        st = p.lstat()
    except OSError:
        return None
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns)


def _unvouched(d: Path) -> str:
    """Why iCloud cannot yet be said to hold this archived copy, or empty.

    A copy outside iCloud Drive (PIPELINE_ICLOUD pointed at a drive or an
    ordinary folder) has no upload to wait for: the file drop has just hashed
    is the archive. A copy inside it has to be vouched for by iCloud, and a
    question it will not answer is not a yes."""
    up = uploaded(d)
    if up is True:
        return ""
    if up is False:
        return "iCloud has not finished uploading the copy; drop again once it has"
    if icloud_managed(d):
        return "iCloud would not say whether it has uploaded the copy"
    return ""


def _pack_frames(q: Path) -> dict[str, str] | None:
    """name -> SHA-256 of every frame a packed burst on this disk holds, from
    its header alone, or None when it is not one that can be read."""
    try:
        b = _burstpack()
        with open(q, "rb") as fh:
            head = fh.read(len(b.MAGIC) + 8)
            if len(head) < len(b.MAGIC) + 8 or head[:len(b.MAGIC)] != b.MAGIC:
                return None
            n = int.from_bytes(head[len(b.MAGIC):], "little")
            man = b.read_manifest(head + fh.read(n))[0]
        return {f["name"]: f["sha256"] for f in man["frames"]}
    except (OSError, ValueError, KeyError, TypeError):
        return None


def spare_packs(shoot: Path, whole: dict, frames: list[Path]) -> list[tuple[Path, list[Path]]]:
    """Packed bursts on this Mac that nothing up there is a copy of, but whose
    every frame is: the frame's RAW (or a packed burst holding it) recorded in
    iCloud with the same bytes, and vouched for by iCloud. With the copy each
    leans on.

    These are what a pack made after the RAWs had already gone up leaves: a
    whole second copy of the shoot that push has nothing to do with (the
    frames are up) and that drop used to keep because no burst of that name
    was ever copied. 15 GB of one shoot sat so. Nothing in iCloud is read
    here: each copy was read back and matched to its record when it went up,
    and the frame's own original was dropped against it, so the pack is the
    only thing on this disk that still holds it. A frame whose original is
    still here is not a spare's to vouch for and keeps the pack."""
    here = {p.name for p in frames}
    man = whole.get("frames") or {}
    recorded = whole.get("packed") or {}
    packed = packed_frames(whole)
    out = []
    for q in local_packed(shoot):
        if q.name in recorded or not local(q):
            continue
        held = _pack_frames(q)
        if not held:
            continue
        ups: list[Path] = []
        for name, sha in held.items():
            if name in here:
                break
            rec = man.get(name)
            if rec and rec.get("sha256") == sha:
                d = dest_for(shoot, name)
                if d.exists() and d.stat().st_size == rec.get("bytes") and not _unvouched(d):
                    ups.append(d)
                    continue
            if name in packed and packed[name][1].get("sha256") == sha:
                d = packed_dest(shoot, packed[name][0])
                if d.exists() and not _unvouched(d):
                    ups.append(d)
                    continue
            break
        else:
            out.append((q, sorted(set(ups))))
    return out


def _let_decode_go(shoot: Path, stem: str) -> int:
    """The full-size decode of a frame whose original has just gone, removed
    with it. Returns the bytes that came back.

    The viewer decodes a RAW once and keeps it, about 7 MB a frame, and it
    can only ever make one from a RAW on this disk; with the RAW in iCloud it
    shows the preview instead and never downloads one. So the decode is the
    biggest thing a finished shoot keeps once its RAWs have gone, and nothing
    else ever removed it: 8.8 GB of decodes outlived one shoot's RAWs. Only
    the decode of this frame, whose original was read back out of iCloud and
    matched a moment ago, so it is derived from a photograph that still
    exists, which is reclaim's own rule for an archived frame's caches."""
    _raw, cull = parts(shoot)
    back = 0
    for ext in (".jpg", ".jpeg", ".JPG", ".JPEG"):
        q = cull / "decoded" / f"{stem}{ext}"
        try:
            st = q.lstat()
        except OSError:
            continue
        if not q.is_file() or q.is_symlink():
            continue
        try:
            q.unlink()
        except OSError:
            continue
        back += st.st_blocks * 512 if st.st_nlink == 1 else 0
    return back


def drop(shoot: Path, apply: bool) -> int:
    """Remove local originals, and only ones proved to be up and whole."""
    shoot = Path(shoot).expanduser().resolve()
    bad = icloud_ready()
    if bad:
        print(f"  {bad}")
        return 1
    raw, _ = parts(shoot)
    # The rule push used to keep, where it belongs: the RAWs of a shoot he has
    # not finished are still going to be read - chosen, edited, cut into reels
    # - so their local copies stay whatever iCloud holds. Only a copy is let
    # through before Finish.
    if not finished(shoot):
        print(f"  {shoot.name} is not finished yet, so its RAWs are still going to be read. Nothing was removed.")
        print("  Press Finish This Shoot on its Finish step first.")
        return 1
    whole = load_manifest(shoot)
    man = whole["frames"]
    packed = packed_frames(whole)
    if not man and not packed:
        print(f"  {shoot.name} has no archive manifest: nothing was ever pushed.")
        return 1

    frames = originals(raw)
    names = inode_names(shoot)
    safe, refused = [], []
    unmanaged = 0
    # What each packed copy in iCloud unpacks to, worked out once per file:
    # file -> (name -> SHA-256), or the reason it cannot be relied on.
    unpacked: dict[str, dict[str, str] | str] = {}

    def by_arw(p: Path) -> tuple[Path | None, dict | None, str]:
        """(the copy, its record, why not): the ARW in iCloud."""
        rec = man.get(p.name)
        d = dest_for(shoot, p.name)
        if not rec:
            return None, None, "never pushed"
        if not d.exists():
            return None, None, "not in iCloud"
        # The copy has to be HERE to be hashed. An evicted archive copy cannot
        # be verified without downloading it, and dropping the local original
        # on the strength of a file we have not read is the one thing this must
        # never do.
        if not local(d):
            return None, None, "the iCloud copy is evicted; it must come down to be checked"
        if d.stat().st_size != rec.get("bytes"):
            return None, None, "the iCloud copy is a different size"
        why = _unvouched(d)
        if why:
            return None, None, why
        if sha256(d) != rec.get("sha256"):
            return None, None, "the iCloud copy does not match what was pushed"
        return d, rec, ""

    def by_packed(p: Path) -> tuple[Path | None, dict | None, str]:
        """(the copy, the frame's record, why not): the packed burst in iCloud,
        unpacked, giving back this frame."""
        if p.name not in packed:
            return None, None, ""
        file, fr = packed[p.name]
        arec = whole["packed"][file]
        q = packed_dest(shoot, file)
        if not q.exists():
            return None, None, "its packed burst is not in iCloud"
        if not local(q):
            return None, None, "its packed burst in iCloud is evicted; it must come down to be checked"
        if q.stat().st_size != arec.get("bytes"):
            return None, None, "its packed burst in iCloud is a different size"
        why = _unvouched(q)
        if why:
            return None, None, why
        if file not in unpacked:
            if sha256(q) != arec.get("sha256"):
                unpacked[file] = "its packed burst in iCloud does not match what was pushed"
            else:
                try:
                    unpacked[file] = unpacked_hashes(q)
                except (OSError, ValueError) as e:
                    unpacked[file] = f"its packed burst in iCloud does not unpack ({e})"
        got = unpacked[file]
        if isinstance(got, str):
            return None, None, got
        if got.get(p.name) != fr.get("sha256"):
            return None, None, "its packed burst in iCloud does not give this frame back as it was packed"
        return q, fr, ""

    # The bar counts this loop rather than the unlinking below it. Dropping
    # the action shoot reads 26.9 GB back out of iCloud to re-hash it and
    # then makes about 1,157 unlink() calls: all of the waiting is here.
    for i, p in enumerate(frames):
        progress("drop", i, len(frames))
        # Either copy will do, the ARW first. Each has been read back out of
        # iCloud and matched to its record before it is relied on at all.
        d, rec, why = by_arw(p)
        if d is None:
            d2, rec2, why2 = by_packed(p)
            if d2 is not None:
                d, rec, why = d2, rec2, ""
            elif why2 and why in ("never pushed", "not in iCloud"):
                why = why2
        if d is None:
            refused.append((p, why))
            continue
        # And the file about to be removed has to be the one that was
        # archived. Only the iCloud copy was checked, so a RAW that had taken
        # this name since the push - a second card whose counter had wrapped,
        # a restore from a drive - would have been removed as though it were
        # the frame in iCloud.
        if not local(p):
            refused.append((p, "the original here has no bytes on this disk; look at it before anything removes it"))
            continue
        if p.stat().st_size != rec.get("bytes"):
            refused.append((p, "the file here is not the one that was archived (a different size)"))
            continue
        st = p.lstat()
        every = names.get((st.st_dev, st.st_ino), [p])
        theirs = [q for q in every if not pipeline_name(shoot, q)]
        if theirs:
            # calib-skin/: names he made on the same bytes, each with a .dop of
            # its own. drop does not remove a name of his, and without that one
            # the others free nothing, so the frame stays whole instead of
            # being reported as dropped while its bytes are still on the disk.
            refused.append((p, f"it also has a name of yours, {theirs[0].relative_to(shoot)}, which drop "
                               "does not remove, so removing the others would free nothing"))
            continue
        if sha256(p) != rec.get("sha256"):
            refused.append((p, "the file here is not the one that was archived"))
            continue
        if not icloud_managed(d):
            unmanaged += 1
        safe.append((p, d, _sig(p), _sig(d), [q for q in every if pipeline_name(shoot, q)],
                     st.st_nlink > len(every)))
    progress("drop", len(frames), len(frames))

    # The shoot's own packed bursts, where the same file is up there: the one
    # in iCloud checked as a packed copy is checked above (there, vouched for,
    # its record's bytes) and this one the same bytes as it. Packing a shoot
    # and copying it up would otherwise leave half the RAWs' size behind.
    safe_packed = []
    for q in local_packed(shoot):
        arec = (whole.get("packed") or {}).get(q.name)
        up = packed_dest(shoot, q.name)
        if not arec or not up.exists() or not local(up) or up.stat().st_size != arec.get("bytes") \
                or _unvouched(up) or not local(q) or q.stat().st_size != arec.get("bytes"):
            continue
        if sha256(up) == arec.get("sha256") and sha256(q) == arec.get("sha256"):
            safe_packed.append((q, up, _sig(q), _sig(up)))
    for q, ups in spare_packs(shoot, whole, frames):
        safe_packed.append((q, ups, _sig(q), [_sig(u) for u in ups]))

    print(f"  {shoot.name}: {len(safe)} frames verified in iCloud, {len(refused)} refused")
    for p, why in refused[:8]:
        print(f"    kept  {p.name}: {why}")
    if len(refused) > 8:
        print(f"    ... and {len(refused) - 8} more")
    if not safe and not safe_packed:
        print("\n  nothing is safe to remove.")
        return 1

    # Space is only freed when every name for the inode goes. A frame whose
    # inode reports a name this walk cannot see (st_nlink above the names in
    # the shoot) is removed from the shoot all the same - its bytes are safe in
    # the archive and under that other name - but it is not counted as space
    # coming back, because it does not.
    freed = sum(p.stat().st_size for p, _d, _ps, _ds, _n, elsewhere in safe if not elsewhere)
    held = [p for p, _d, _ps, _ds, _n, elsewhere in safe if elsewhere]
    extra = sum(len(n) for *_x, n, _e in safe) - len(safe)
    packed_freed = sum(q.stat().st_size for q, *_x in safe_packed)
    print(f"\n  would free {human(freed + packed_freed)} by removing {len(safe)} originals")
    if safe_packed:
        print(f"  and {len(safe_packed)} packed bursts on this Mac ({human(packed_freed)}) whose frames are all in iCloud already")
    if extra:
        print(f"  and {extra} further hard links to them inside the shoot (edit/, cull/picks/,")
        print("  reels/), without which not one byte would actually come back")
    if held:
        print(f"  {len(held)} of those have a name outside this shoot as well, so their "
              f"{human(sum(p.stat().st_size for p in held))} stay on the disk until that name goes; not counted above")
    if unmanaged:
        print(f"  {unmanaged} of the copies are in {ARCHIVE}, which is not iCloud Drive: what was")
        print("  verified is that copy, on that disk, and it is the only one once these are removed")
    if not apply:
        print("\n  nothing was removed. Add --apply to remove exactly this.")
        return 0

    gone = back = 0
    changed, partial = [], []
    for p, d, psig, dsig, links, elsewhere in safe:
        # Checked again, one frame at a time, just before its names go. The
        # hashing above is a long read (26.9 GB for one shoot), and a copy
        # removed or replaced from another device in that time must not have
        # its local names taken on the strength of a check made minutes ago.
        if _sig(d) != dsig or not local(d) or _unvouched(d) or _sig(p) != psig:
            changed.append(p)
            print(f"    kept  {p.name}: it changed after it was checked; run drop again")
            continue
        size = p.stat().st_size
        failed = []
        for q in links:
            try:
                q.unlink()
            except FileNotFoundError:
                pass
            except OSError as e:
                failed.append(q)
                print(f"    {q}: {e}")
        # Counted only when every name went: a frame with one name left is
        # still on the disk, and the line below is what he reads as freed.
        if failed:
            partial.append(p)
            continue
        gone += 1
        back += 0 if elsewhere else size
        back += _let_decode_go(shoot, p.stem)
    packed_gone = 0
    for q, up, qsig, usig in safe_packed:
        # The same look again as for a RAW, just before it goes. A spare pack
        # leans on every copy its frames have up there rather than on one.
        if isinstance(up, list):
            moved = _sig(q) != qsig or any(_sig(u) != s or _unvouched(u) for u, s in zip(up, usig))
        else:
            moved = _sig(q) != qsig or _sig(up) != usig or not local(up) or _unvouched(up)
        if moved:
            changed.append(q)
            print(f"    kept  {q.name}: it changed after it was checked; run drop again")
            continue
        size = q.stat().st_size
        try:
            q.unlink()
        except OSError as e:
            print(f"    {q.name}: {e}")
            continue
        packed_gone += 1
        back += size
    if for_the_app():
        said = f"Removed {gone} originals and their links; {human(back)} back."
        if packed_gone:
            said = (f"Removed {gone} originals and their links, and {packed_gone} packed bursts; "
                    f"{human(back)} back.")
        if partial:
            said += f" {len(partial)} could not be removed completely and are still on this disk."
        if changed:
            said += f" {len(changed)} changed after they were checked and were left alone."
        print(f"\n  {said} Bring Back from iCloud brings them down again.")
        return 1 if partial else 0
    print(f"\n  removed {gone} originals and their links; {human(back)} back.")
    if partial:
        print(f"  {len(partial)} could not be removed completely: the names left are listed above,")
        print("  and those frames are still on this disk")
    if changed:
        print(f"  {len(changed)} changed after they were checked and were left alone")
    print(f"  bring them down again with: ./pl archive pull {shoot.name} --apply")
    return 1 if partial else 0


# ------------------------------------------------------------ pull

def pull(shoot: Path, apply: bool) -> int:
    shoot = Path(shoot).expanduser().resolve()
    raw, _ = parts(shoot)
    whole = load_manifest(shoot)
    man = whole["frames"]
    packed = packed_frames(whole)
    if not man and not packed:
        print(f"  {shoot.name} has no archive manifest.")
        return 1
    # Wanted is "no bytes here", not "no name here". A name with nothing
    # behind it - evicted, or blockless - was answered "already here" by
    # exists(), so pull skipped exactly the frames the panel was offering to
    # bring back. Restoring over such a name is safe: the copy lands as a
    # .part and is renamed over it only once it hashes right.
    #
    # A frame whose only copy is in a packed burst is unpacked from it: from
    # the shoot's own packed/ when that file is the one recorded, which needs
    # no download, else from the copy in iCloud.
    both = {**{n: fr for n, (_f, fr) in packed.items()}, **man}
    want = [(n, r) for n, r in sorted(both.items()) if not local(raw / n)]
    arw = {n for n in man if dest_for(shoot, n).exists()}
    evicted = [n for n, _ in want if (is_dataless(dest_for(shoot, n)) if n in arw
                                      else n in packed and is_dataless(packed_dest(shoot, packed[n][0])))]
    total = sum(r.get("bytes", 0) for _, r in want)
    print(f"  {shoot.name}: {len(want)} frames to bring back, {human(total)}")
    if evicted:
        print(f"  {len(evicted)} of them are evicted in iCloud and must download first.")
    if not want:
        print("  nothing to do.")
        return 0
    if not apply:
        print("\n  nothing was copied. Add --apply.")
        return 0
    raw.mkdir(parents=True, exist_ok=True)
    ok = bad = 0
    gave_up, waited_out = "", 0
    opened: dict[str, dict[str, bytes] | str] = {}

    def from_packed(name: str) -> bytes | str:
        """The frame's bytes out of its packed burst, or why they could not be had."""
        file, _fr = packed[name]
        if file not in opened:
            arec = whole["packed"][file]
            here_q, up_q = shoot / PACKED / file, packed_dest(shoot, file)
            src = here_q if (local(here_q) and here_q.stat().st_size == arec.get("bytes")
                             and sha256(here_q) == arec.get("sha256")) else up_q
            if src is up_q:
                if not up_q.exists():
                    opened[file] = "its packed burst is not in iCloud"
                elif not local(up_q) and not materialise(up_q):
                    opened[file] = "iCloud did not hand its packed burst over"
            if file not in opened:
                try:
                    wanted = {n for n, _ in want if n in packed and packed[n][0] == file}
                    opened[file] = _burstpack()._unpack_bytes(src.read_bytes(), wanted)
                except (OSError, ValueError) as e:
                    opened[file] = f"its packed burst does not unpack ({e})"
        got = opened[file]
        if isinstance(got, str):
            return got
        # Taken, not read: a shoot's worth of unpacked frames is never held at once.
        return got.pop(name, None) or "its packed burst does not hold it"

    for i, (name, rec) in enumerate(want, 1):
        progress("pull", i - 1, len(want))
        d = dest_for(shoot, name)
        here = raw / name
        if name not in arw and name in packed:
            data = from_packed(name)
            if isinstance(data, str):
                print(f"    {name}: {data}")
                bad += 1
                continue
            if is_dataless(here) and here.stat().st_size != len(data):
                print(f"    {name}: a different file of this name is here, evicted; left alone")
                bad += 1
                continue
            tmp = raw / f".{name}.part"
            try:
                tmp.write_bytes(data)
                if sha256(tmp) != rec.get("sha256"):
                    tmp.unlink(missing_ok=True)
                    print(f"    {name}: came back wrong, not kept")
                    bad += 1
                    continue
                os.replace(tmp, here)
                ok += 1
            except OSError as e:
                tmp.unlink(missing_ok=True)
                print(f"    {name}: {e}")
                bad += 1
            except BaseException:
                tmp.unlink(missing_ok=True)
                raise
            continue
        rec = man.get(name, rec)
        if not d.exists():
            print(f"    {name}: not in iCloud")
            bad += 1
            continue
        if is_dataless(here) and here.stat().st_size != rec.get("bytes"):
            # An evicted file of this name that is not the size of the frame
            # archived under it. Its bytes are somewhere in iCloud under this
            # name; replacing it would put the archived frame there instead.
            print(f"    {name}: a different file of this name is here, evicted; left alone")
            bad += 1
            continue
        if not local(d):
            if gave_up:
                # Once iCloud has not handed one over, asking for the next is
                # the same wait for the same answer - ten minutes a frame.
                waited_out += 1
                bad += 1
                continue
            if not materialise(d):
                print(f"    {name}: iCloud did not hand it over")
                gave_up = name
                bad += 1
                continue
        tmp = raw / f".{name}.part"
        try:
            shutil.copyfile(d, tmp)
            if sha256(tmp) != rec.get("sha256"):
                tmp.unlink(missing_ok=True)
                print(f"    {name}: came back wrong, not kept")
                bad += 1
                continue
            os.replace(tmp, here)
            ok += 1
        except OSError as e:
            tmp.unlink(missing_ok=True)
            print(f"    {name}: {e}")
            bad += 1
        except BaseException:
            # A stop from the studio: no half RAW is left beside the originals.
            tmp.unlink(missing_ok=True)
            raise
        if i % 50 == 0 or i == len(want):
            print(f"    {i}/{len(want)}")
    progress("pull", len(want), len(want))
    if for_the_app():
        said = f"{ok} back, {bad} failed."
        if waited_out:
            said += (f" {waited_out} more are evicted in iCloud and were not asked for after {gave_up};"
                     " Bring Back from iCloud again asks for them once iCloud can hand them over.")
        print(f"\n  {said}")
        return 0 if not bad else 1
    if waited_out:
        print(f"  {waited_out} more are evicted in iCloud and were not asked for after {gave_up}:")
        print("  run pull again when iCloud can hand them over")
    print(f"\n  {ok} back, {bad} failed.")
    return 0 if not bad else 1


# ------------------------------------------------------------ report

# ------------------------------------------------------------ expire

def retention(shoot: Path) -> int:
    """How many days after a shoot is finished its non-keepers may be let go.

    The shoot's own `retain_days` first, then `retain_days` in the library's
    library.json, then a year.

    A year is not a measurement and there is nothing to measure it against:
    how long a finished shoot is worth keeping is his judgement and no run of
    this pipeline can tell him. So it is a floor rather than a policy - expire
    prints the number it used on every run, and either file overrides it -
    and it is the one number here that is waiting for him to set it. Neither
    file is written from this function: it reads, and expire deletes on what
    it read."""
    try:
        v = json.loads((shoot / "shoot.json").read_text()).get("retain_days")
        if v is not None:
            return int(v)
    except (OSError, ValueError, TypeError):
        pass
    cfg = ROOT / "library.json"
    try:
        return int(json.loads(cfg.read_text()).get("retain_days", 365))
    except (OSError, ValueError, TypeError):
        return 365


def keepers_of(shoot: Path) -> set[str] | None:
    """The frames he chose. None when that cannot be established, which has to
    stop the whole thing: without the answer key there is no way to tell a
    photograph he kept from one he did not, and this deletes photographs.

    One file, found by the rule every other reader in the pipeline uses
    (common.decision_path), and not by trying decisions/ and then falling back
    to cull/. That fallback meant an answer key that had moved and then become
    unreadable was answered instead from whatever older copy was left at the
    old name: a stale list of keepers, protecting the wrong frames, chosen
    without a word. It is the selects.json incident with the consequence
    pointed at the delete. A key that will not read is None, and None refuses.

    A list, too. The studio once read an unparseable selects.json as an empty
    set; answering a dict with its keys would be the same mistake wearing a
    different shape."""
    _, cull = parts(shoot)
    try:
        chosen = json.loads(decision_path(cull, "selects.json").read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(chosen, list):
        return None
    return {Path(str(x)).name for x in chosen}


def _same_bytes(p: Path, rec: dict) -> bool:
    """Whether the file at p is the photograph this archive record is of:
    the recorded size and the recorded hash. A record with no hash cannot be
    matched, and an unreadable file is not a match."""
    want = rec.get("sha256")
    try:
        return bool(want) and p.stat().st_size == rec.get("bytes") and sha256(p) == want
    except OSError:
        return False


def days_since_finished(shoot: Path) -> int | None:
    done = finished(shoot)
    if not done:
        return None
    try:
        t = time.mktime(time.strptime(done[:10], "%Y-%m-%d"))
    except ValueError:
        return None
    return int((time.time() - t) / 86400)


def expire(shoot: Path, apply: bool, after: int | None, include_keepers: bool,
           destroy_last_copy: bool) -> int:
    """Let go of archived RAWs he no longer needs.

    This is the only command here that can destroy a photograph outright. Every
    other one leaves a second copy somewhere. So it separates what it is about
    to do into two lists and will not touch the dangerous one without being
    told twice: an archived frame whose local original is still on the disk is
    losing a spare, and an archived frame whose local original was dropped is
    losing the photograph."""
    shoot = Path(shoot).expanduser().resolve()
    raw, _ = parts(shoot)
    man = load_manifest(shoot)["frames"]
    if not man:
        print(f"  {shoot.name} has nothing archived.")
        return 1

    keep = keepers_of(shoot)
    if keep is None:
        # --keepers used to get past this, which had it exactly backwards: with
        # no answer key nothing can be identified as a keeper, so --keepers does
        # not include a known set, it removes the only protection the shoot has
        # and makes every frame eligible.
        print(f"  {shoot.name} has no answer key (selects.json), so there is no way to tell")
        print("  which frames you kept. Refusing, because this deletes photographs.")
        return 1
    keep = keep or set()

    age = days_since_finished(shoot)
    limit = after if after is not None else retention(shoot)
    if age is None:
        print(f"  {shoot.name} is not marked finished, so nothing here has started ageing.")
        return 1
    if age < limit:
        print(f"  {shoot.name} was finished {age} days ago; the policy lets go after {limit}.")
        print(f"  Nothing is due. Override for this run with --after {age}.")
        return 0

    spare, only, protected, stranger = [], [], [], []
    todo, checked = [], {}
    for name, rec in sorted(man.items()):
        d = dest_for(shoot, name)
        if not d.exists():
            continue
        if name in keep and not include_keepers:
            protected.append(name)
            continue
        todo.append((name, rec, d))
    # A spare is a frame whose local original still HAS ITS BYTES, and they
    # are the bytes that were archived. This read `local(...) or
    # is_dataless(...)`, which counted a local original that had itself been
    # evicted as a live second copy — so the archived file, the only copy with
    # bytes anywhere, was filed as the safe one to delete and skipped both the
    # --yes-delete-originals gate and the typed confirmation in the page. And
    # then it read local() alone, which is a name with blocks behind it and
    # nothing more: a different RAW that had taken the name (a second card
    # whose counter had wrapped, a half-written restore) made the archived
    # frame a "spare" that plain --apply deleted. A name is not a copy; the
    # same bytes are, and they are read to be sure. Size is not enough on
    # this camera - five sizes covered 1,066 of one shoot's 1,157 frames.
    for i, (name, rec, d) in enumerate(todo):
        progress("check", i, len(todo))
        here = raw / name
        if not local(here):
            only.append((name, rec, d))
        elif _same_bytes(here, rec):
            spare.append((name, rec, d))
            checked[name] = _sig(here)
        else:
            only.append((name, rec, d))
            stranger.append(name)
    progress("check", len(todo), len(todo))

    print(f"  {shoot.name}: finished {age} days ago, policy {limit} days")
    print(f"    {len(protected):>5}  frames you kept, protected"
          + ("" if not include_keepers else " (NOT protected: --keepers was passed)"))
    print(f"    {len(spare):>5}  archived spares, the original is still on this disk")
    print(f"    {len(only):>5}  ONLY copies, the original was dropped from this disk")
    if stranger:
        print(f"           of which {len(stranger)} have a file of the same name here that is not the")
        print("           photograph that was archived, so the archived one is still its only copy")
    if only:
        sz = sum(r.get("bytes", 0) for _, r, _ in only)
        print(f"\n  Removing those {len(only)} would destroy the only copy of {len(only)} photographs")
        print(f"  ({human(sz)}). There is no undo and no second place to fetch them from.")
        for name, _, _ in only[:6]:
            print(f"      {name}")
        if len(only) > 6:
            print(f"      ... and {len(only) - 6} more")
        if not destroy_last_copy:
            print("\n  Those are left alone. Add --yes-delete-originals to include them.")

    doomed = list(spare) + (list(only) if destroy_last_copy else [])
    freed = sum(r.get("bytes", 0) for _, r, _ in doomed)
    if not doomed:
        print("\n  nothing to remove.")
        return 0
    print(f"\n  would remove {len(doomed)} files from iCloud, {human(freed)}")
    if not apply:
        # The page runs this same command without --apply to draw its list, as
        # a job with the same one bar. There is no loop on that path, so the
        # bar is told what the run is about rather than left blank.
        progress("expire", 0, len(doomed))
        print("  nothing was removed. Add --apply.")
        return 0

    gone, kept, back = 0, 0, 0
    for i, (name, rec, d) in enumerate(doomed):
        progress("expire", i, len(doomed))
        # A spare is only a spare while its original is still the file that
        # was hashed above. Checked again, cheaply, just before the archived
        # copy goes: the hashing is a long read, and a file removed or
        # replaced in that time turns this into the last copy.
        if name in checked and _sig(raw / name) != checked[name]:
            print(f"    kept  {name}: its original changed after it was checked")
            kept += 1
            continue
        try:
            d.unlink()
            man.pop(name, None)
            gone += 1
            back += rec.get("bytes", 0)
        except OSError as e:
            print(f"    {name}: {e}")
    progress("expire", len(doomed), len(doomed))
    # The whole record with only its frames replaced: it carries more than the
    # ARWs now ("packed"), and a record rebuilt from the frames alone would
    # forget every packed burst up there.
    whole = load_manifest(shoot)
    whole["frames"] = man
    whole.setdefault("shoot", shoot.name)
    write_json_atomic(manifest_path(shoot), whole)
    if for_the_app():
        print(f"\n  Removed {gone} from iCloud, {human(back)} of your iCloud quota back."
              + (f" {kept} left alone because they changed after they were checked." if kept else ""))
        return 0
    print(f"\n  removed {gone} from iCloud, {human(back)} of your iCloud quota back.")
    if kept:
        print(f"  {kept} left alone because they changed after they were checked")
    return 0


def restore_for_work(shoot: Path) -> int:
    """Before a step that reads the RAWs - the cull, the presets, the
    PhotoLab folder - every frame recorded as archived whose RAW is not on
    this Mac is put back into the shoot, from its copy in iCloud or its
    packed burst, checked as Bring Back from iCloud checks it. So a shoot
    whose RAWs were moved off this Mac is culled and edited again as though
    they had never left, with no step of his own first.

    0 when every RAW is here, or has come back; else the step stops, because
    a cull of part of a shoot would write its verdicts over the frames it
    could not see."""
    shoot = library.paths(Path(shoot).expanduser().resolve()).shoot
    raw, _ = parts(shoot)
    whole = load_manifest(shoot)
    missing = sorted(n for n in {*(whole.get("frames") or {}), *packed_frames(whole)} if not local(raw / n))
    if not missing:
        return 0
    print(f"  {len(missing)} RAWs of {shoot.name} are not on this Mac; bringing them back first, each checked",
          flush=True)
    rc = pull(shoot, apply=True)
    left = [n for n in missing if not local(raw / n)]
    if left:
        print(f"  {len(left)} RAWs could not be brought back ({left[0]} first), so nothing else was done."
              " Its copy in iCloud has to be reachable; try again when it is.", flush=True)
        return 1
    return rc


def repack(shoot: Path, apply: bool) -> int:
    """The ARWs already in iCloud, packed, and then their ARW copies let go.

    Two halves, and a frame never has fewer than one checked copy between
    them. First, each burst whose frames are up only as ARWs is packed: from
    the RAW on this Mac when that is the same bytes as the record, else from
    the ARW in iCloud (downloaded if it has to be), each checked against its
    record before it is packed; the packed file is proved by unpacking it,
    copied up and read back, and recorded. Then an ARW copy in iCloud goes only
    when its frame's packed copy up there is downloaded, vouched for by iCloud
    and unpacks - that copy - to the ARW's recorded bytes. A packed copy iCloud
    has not finished uploading keeps its ARWs until this runs again."""
    shoot = Path(shoot).expanduser().resolve()
    bad = icloud_ready()
    if bad:
        print(f"  {bad}")
        return 1
    if apply:
        _clear_parts(shoot)
    raw, _ = parts(shoot)
    whole = load_manifest(shoot)
    man = whole.setdefault("frames", {})
    packs = whole.setdefault("packed", {})
    inside = packed_frames(whole)
    todo = sorted(n for n in man if n not in inside and dest_for(shoot, n).exists())
    covered = sorted(n for n in man if n in inside and dest_for(shoot, n).exists())
    print(f"  {shoot.name}: {len(todo)} frames in iCloud as ARWs only; "
          f"{len(covered)} ARW copies whose frame is packed up there too")
    if todo:
        size = sum(man[n].get("bytes", 0) for n in todo)
        print(f"  would pack {len(todo)} frames in iCloud, {human(size)}, into packed bursts, each checked,")
        print("  and then let their ARW copies go, each only once its packed copy is up and gives it back exactly")
        far = sum(1 for n in todo if not (local(raw / n) or local(dest_for(shoot, n))))
        if far:
            print(f"  {far} of them are on neither this Mac nor downloaded, so they are read from iCloud as they are packed")
    elif covered:
        print(f"  would remove {len(covered)} ARW copies from iCloud, "
              f"{human(sum(man[n].get('bytes', 0) for n in covered))}, whose frame is in a packed burst up there, checked")
    if not todo and not covered:
        print("\n  nothing to do.")
        return 0
    if not apply:
        progress("repack", 0, len(todo) + len(covered))
        print("  nothing was changed. Add --apply.")
        return 0

    bp = _burstpack()
    manifest_path(shoot).parent.mkdir(parents=True, exist_ok=True)
    stage = shoot / PACKED / ".staging"
    # What a stopped run left here is only ever its own unfinished output.
    for t in (stage.iterdir() if stage.is_dir() else []):
        t.unlink(missing_ok=True)
    groups = bp.group_names(shoot, set(todo))
    # The bar is the shoot's frames packed, all of them, starting from those
    # an earlier run packed: a Pack in iCloud stopped half way and started
    # again picks up where it was, and the bar says so rather than starting
    # at nought. Letting the ARW copies go is a stage of its own after it
    # (`letgo`), so its count never reads as frames still to pack.
    steps, step = len(inside) + len(todo), len(inside)
    packed_n = failed = 0
    progress("repack", step, steps)
    if step:
        # Where this run starts, for the time left to be this run's own.
        print(f"@@ from repack {step} {steps}", flush=True)
    # The packing itself takes a minute a burst on one core, so bursts are
    # packed side by side, as pack_shoot does. Before that, a burst whose ARWs
    # are only in iCloud has to be downloaded - iCloud stores, it cannot pack -
    # and one download at a time left most of the cores waiting on it, so
    # FETCHERS bursts are fetched and checked at once, in threads, a bounded
    # way ahead of the packing and handed to it in order. What writes to
    # iCloud or the manifest stays here, one burst at a time: as each comes
    # back, the copy up, the read back and the record.
    inflight: dict[str, tuple[list[str], str, Path]] = {}   # gid -> names, file, staged output
    giving_up = threading.Event()

    def fetch(names: list[str]) -> tuple[list[Path], str]:
        """A burst's ARWs, each here and checked against its record, or why not."""
        srcs: list[Path] = []
        for n in names:
            if giving_up.is_set():
                return [], "stopped"
            p, d = raw / n, dest_for(shoot, n)
            if local(p) and _same_bytes(p, man[n]):
                srcs.append(p)
                continue
            if not local(d) and not materialise(d, stop=giving_up):
                return [], f"iCloud did not hand {n} over"
            if not _same_bytes(d, man[n]):
                return [], f"the ARW of {n} in iCloud does not match what was pushed"
            srcs.append(d)
        return srcs, ""

    def jobs():
        nonlocal step, failed
        from collections import deque
        from concurrent.futures import ThreadPoolExecutor
        fetchers = ThreadPoolExecutor(max_workers=FETCHERS, thread_name_prefix="fetch")
        ahead: deque = deque()
        todo = iter(groups)

        def top_up() -> None:
            while len(ahead) < workers + FETCHERS:
                g = next(todo, None)
                if g is None:
                    return
                ahead.append((g, fetchers.submit(fetch, g[1])))

        try:
            top_up()
            while ahead:
                (gid, names, key), got = ahead.popleft()
                srcs, why = got.result()
                top_up()
                yield from _one(gid, names, key, srcs, why)
        finally:
            # A Stop: the downloads give up rather than hold the way out.
            giving_up.set()
            fetchers.shutdown(wait=False, cancel_futures=True)

    def _one(gid: str, names: list[str], key, srcs: list[Path], why: str):
        """One fetched burst: said and counted when it could not be fetched,
        else named, staged and handed to a packer."""
        nonlocal step, failed
        if why:
            failed += len(names)
            step += len(names)
            progress("repack", step, steps)
            print(f"    {gid}: not packed: {why}", flush=True)
            return
        file = f"{gid}{bp.EXT}"
        i = 2
        taken = {f for _, f, _ in inflight.values()}
        while file in packs or file in taken or packed_dest(shoot, file).exists():
            file, i = f"{gid}-{i}{bp.EXT}", i + 1
        stage.mkdir(parents=True, exist_ok=True)
        out = stage / file
        out.unlink(missing_ok=True)
        inflight[gid] = (names, file, out)
        yield gid, srcs, key, out           # packed and proved by unpacking before it is written

    def finish(gid: str, _before: int, _after: int, err: str | None) -> None:
        nonlocal step, failed, packed_n
        names, file, out = inflight[gid]
        step += len(names)
        q = packed_dest(shoot, file)
        tmp = q.parent / f".{file}.part"
        try:
            if err is not None:
                raise ValueError(err)
            want = sha256(out)
            q.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(out, tmp)
            if sha256(tmp) != want:
                tmp.unlink(missing_ok=True)
                failed += len(names)
                print(f"    {file}: copied wrong, left alone", flush=True)
                return
            bp.give_icon(tmp)                # a copy does not carry the icon; iCloud keeps it on eviction
            os.replace(tmp, q)
            packs[file] = {"bytes": out.stat().st_size, "sha256": want,
                           "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                           "frames": {n: {"bytes": man[n].get("bytes", 0), "sha256": man[n].get("sha256")}
                                      for n in names}}
            write_json_atomic(manifest_path(shoot), whole)
            packed_n += len(names)
            print(f"    {file}: {len(names)} frames, {human(q.stat().st_size)} in place of "
                  f"{human(sum(man[n].get('bytes', 0) for n in names))}", flush=True)
        except (OSError, ValueError) as e:
            tmp.unlink(missing_ok=True)
            failed += len(names)
            print(f"    {gid}: {e}", flush=True)
        except BaseException:
            tmp.unlink(missing_ok=True)
            raise
        finally:
            out.unlink(missing_ok=True)
            inflight.pop(gid, None)
            progress("repack", step, steps)

    biggest = max((man[n].get("bytes", 0) for _, names, _ in groups for n in names), default=0)
    workers = bp._workers(len(groups), biggest) if groups else 1
    if len(groups) > 1:
        print(f"  packing on {workers} {'core' if workers == 1 else 'cores'}", flush=True)
    try:
        if workers == 1:
            for job in jobs():
                finish(*bp._pack_one(job, lambda *_: None))
        else:
            bp._pack_parallel(jobs(), workers, lambda _line: None, finish)
    except BaseException:
        # Stopped from the studio (SIGTERM arrives as SystemExit): the pool is
        # ended by then; what was copied up and recorded stays recorded, and
        # the half-copied .part files, inside iCloud Drive, are not left.
        for _, file, out in inflight.values():
            (packed_dest(shoot, file).parent / f".{file}.part").unlink(missing_ok=True)
            out.unlink(missing_ok=True)
        write_json_atomic(manifest_path(shoot), whole)
        raise
    try:
        stage.rmdir()
    except OSError:
        pass

    # The second half: ARW copies whose frame is now in a packed copy up there.
    inside = packed_frames(whole)
    gone = back = waiting = 0
    unpacked: dict[str, dict[str, str] | str] = {}
    letgo = sorted(x for x in man if x in inside and dest_for(shoot, x).exists())
    for i, n in enumerate(letgo):
        progress("letgo", i, len(letgo))
        file, fr = inside[n]
        arec, q, d = packs[file], packed_dest(shoot, file), dest_for(shoot, n)
        if not q.exists() or q.stat().st_size != arec.get("bytes"):
            continue
        why = _unvouched(q)
        if why:
            waiting += 1
            continue
        if not local(q) and not materialise(q):
            waiting += 1
            continue
        if file not in unpacked:
            try:
                unpacked[file] = (unpacked_hashes(q) if sha256(q) == arec.get("sha256")
                                  else "does not match what was pushed")
            except (OSError, ValueError) as e:
                unpacked[file] = f"does not unpack ({e})"
        got = unpacked[file]
        if isinstance(got, str):
            print(f"    kept  {n}: its packed burst in iCloud {got}")
            continue
        if got.get(n) != man[n].get("sha256") or fr.get("sha256") != man[n].get("sha256"):
            print(f"    kept  {n}: its packed burst in iCloud does not give it back as the ARW was")
            continue
        size = man[n].get("bytes", 0)
        try:
            d.unlink()
        except FileNotFoundError:
            pass
        except OSError as e:
            print(f"    {n}: {e}")
            continue
        man.pop(n, None)
        gone += 1
        back += size
    if letgo:
        progress("letgo", len(letgo), len(letgo))
    else:
        progress("repack", steps, steps)
    write_json_atomic(manifest_path(shoot), whole)
    said = f"Packed {packed_n} frames in iCloud; removed {gone} ARW copies, {human(back)} of your iCloud quota back."
    if waiting:
        said += (f" {waiting} ARW copies stay until iCloud has uploaded their packed burst;"
                 " Free Up Space again lets them go.")
    if failed:
        said += f" {failed} frames could not be packed and keep their ARWs."
    print(f"\n  {said}")
    return 1 if failed else 0


def trim(shoot: Path, apply: bool, form: str = "both") -> int:
    """Remove copies from iCloud that this Mac also holds, and nothing else.

    `form` is which: "raw", the ARW copies, "packed", the packed bursts, or
    "both". An ARW copy goes only when the RAW here is the same bytes; a packed
    burst only when every frame it holds is here as its RAW, the same bytes.
    Either way no frame is left with fewer than one copy, and the one it keeps
    is the RAW on this Mac, checked again just before the copy up there goes.

    What this is not is expire, which lets archived copies go on a schedule
    and can leave a frame with none. Nothing here waits for Finish or for the
    retention lock, because nothing here can lose a photograph."""
    shoot = Path(shoot).expanduser().resolve()
    bad = icloud_ready()
    if bad:
        print(f"  {bad}")
        return 1
    raw, _ = parts(shoot)
    whole = load_manifest(shoot)
    man = whole.get("frames") or {}
    packs = whole.get("packed") or {}
    goes: list[tuple[str, str, Path, int, dict[Path, tuple | None]]] = []
    kept: list[tuple[str, str]] = []
    if form in ("raw", "both"):
        for name, rec in sorted(man.items()):
            d = dest_for(shoot, name)
            if not d.exists():
                continue
            p = raw / name
            if not p.exists():
                kept.append((name, "this Mac has no copy of it"))
            elif not local(p):
                kept.append((name, "its RAW here has no bytes on this disk"))
            elif not _same_bytes(p, rec):
                kept.append((name, "the RAW here is not the one in iCloud"))
            else:
                goes.append(("raw", name, d, rec.get("bytes", 0), {p: _sig(p)}))
    if form in ("packed", "both"):
        for file, arec in sorted(packs.items()):
            q = packed_dest(shoot, file)
            if not q.exists():
                continue
            frames = arec.get("frames") or {}
            missing = [n for n, fr in frames.items() if not (local(raw / n) and _same_bytes(raw / n, fr))]
            if missing or not frames:
                kept.append((file, f"{missing[0] if missing else 'it'} is not on this Mac as the RAW that was packed"
                                   + (f", nor are {len(missing) - 1} more of its frames" if len(missing) > 1 else "")))
                continue
            goes.append(("packed", file, q, arec.get("bytes", 0), {raw / n: _sig(raw / n) for n in frames}))
    n_raw = sum(1 for g in goes if g[0] == "raw")
    n_packed = len(goes) - n_raw
    freed = sum(g[3] for g in goes)
    print(f"  {shoot.name}: {n_raw} RAW copies and {n_packed} packed bursts in iCloud are also on this Mac")
    for key, why in kept[:8]:
        print(f"    - {key}: {why}")
    if len(kept) > 8:
        print(f"    - ... and {len(kept) - 8} more stay for the same kinds of reason")
    if not goes:
        print("\n  nothing to remove.")
        return 0
    print(f"\n  would remove {len(goes)} files from iCloud, {human(freed)}; every frame in them keeps its RAW on this Mac")
    if not apply:
        progress("trim", 0, len(goes))
        print("  nothing was removed. Add --apply.")
        return 0
    gone = kept_n = back = 0
    for i, (kind, key, d, size, sigs) in enumerate(goes):
        progress("trim", i, len(goes))
        # The copy up there goes only while the RAWs here are still the files
        # that were hashed above.
        if any(_sig(p) != sig or not local(p) for p, sig in sigs.items()):
            print(f"    kept  {key}: a RAW here changed after it was checked")
            kept_n += 1
            continue
        try:
            d.unlink()
        except FileNotFoundError:
            pass
        except OSError as e:
            print(f"    {key}: {e}")
            continue
        (man if kind == "raw" else packs).pop(key, None)
        gone += 1
        back += size
    progress("trim", len(goes), len(goes))
    whole["frames"], whole["packed"] = man, packs
    write_json_atomic(manifest_path(shoot), whole)
    said = f"Removed {gone} from iCloud, {human(back)} of your iCloud quota back. Every frame is still on this Mac."
    if kept_n:
        said += f" {kept_n} left alone because a RAW changed after it was checked."
    print(f"\n  {said}")
    return 0


def report() -> int:
    bad = icloud_ready()
    if bad:
        print(f"  {bad}")
    shoots = sorted(p for p in (ROOT / "shoots").iterdir() if p.is_dir()) if (ROOT / "shoots").is_dir() else []
    print(f"  {'shoot':24s} {'frames':>7} {'on disk':>10} {'in iCloud':>10} {'dropped':>8}  finished")
    print("  " + "-" * 76)
    for s in shoots:
        raw, _ = parts(s)
        if not raw.is_dir():
            continue
        st = summarise(status(s))
        print(f"  {s.name:24s} {st['frames']:>7} {human(st['bytes_here']):>10} "
              f"{human(st['bytes_up']):>10} {st['dropped']:>8}  {finished(s) or '-'}")
    if ARCHIVE.is_dir():
        print(f"\n  archive: {ARCHIVE}")
    else:
        print(f"\n  nothing archived yet. It will go to {ARCHIVE}")
    return 0


def show_status(shoot: Path) -> int:
    st = status(Path(shoot).expanduser().resolve())
    s = summarise(st)
    print(f"  {Path(shoot).name}: {s['frames']} frames, finished {st['finished'] or 'no'}")
    print(f"    on this disk        {s['here']:>5}   {human(s['bytes_here'])}")
    if s["here_evicted"]:
        print(f"    evicted HERE        {s['here_evicted']:>5}   the name is there, the bytes are not")
    print(f"    in iCloud           {s['up']:>5}   {human(s['bytes_up'])}")
    if s["up_evicted"]:
        print(f"      of which evicted  {s['up_evicted']:>5}   would download before it could be checked")
    print(f"    dropped locally     {s['dropped']:>5}")
    return 0


def _either(code: int, then, p: Path, apply: bool) -> int:
    """A RAW step and the steps for the rest of a shoot: those run whatever
    the RAW step found, and a shoot whose RAWs have all gone already but
    whose exports and sidecars are still here is not "nothing to do"."""
    rc, did = then(p, apply)
    return rc if did else max(code, rc)


def _after_drop(p: Path, apply: bool) -> tuple[int, bool]:
    p = Path(p).expanduser().resolve()
    before = _here_count(p)
    rc = drop_finished(p, apply)
    rc = max(rc, gather_sidecars(p, apply) if finished(p) else 0)
    return rc, _here_count(p) != before or (not apply and _would(p))


def _after_pull(p: Path, apply: bool) -> tuple[int, bool]:
    rc = max(pull_finished(p, apply), return_sidecars(p, apply))
    return rc, bool((load_manifest(Path(p).expanduser().resolve()).get("finished")))


def _here_count(p: Path) -> int:
    return len(finished_files(p)) + len(sidecar_files(p))


def _would(p: Path) -> bool:
    """Whether a dry run of the steps after drop found anything to do."""
    rec = load_manifest(p).get("finished") or {}
    return any(q.relative_to(p).as_posix() in rec for q in finished_files(p)) or bool(
        finished(p) and sidecar_moves(p))


def main() -> int:
    ap = argparse.ArgumentParser(prog="./pl archive", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["report", "status", "push", "drop", "pull", "expire", "trim", "repack"])
    ap.add_argument("shoot", nargs="?")
    ap.add_argument("--apply", action="store_true", help="actually do it")
    ap.add_argument("--force", action="store_true",
                    help="taken and ignored: push copies any shoot now, finished or not")
    ap.add_argument("--after", type=int, default=None,
                    help="expire: days since the shoot was finished (default: its retain_days, else the library's, else 365)")
    ap.add_argument("--keepers", action="store_true",
                    help="expire: include the frames you chose, which are protected by default")
    ap.add_argument("--as", dest="form", choices=["raw", "packed"], default="raw",
                    help="push: the ARWs as they are (raw), or each burst packed first into one smaller file (packed)")
    ap.add_argument("--only", dest="only", choices=["raw", "packed", "both"], default="both",
                    help="trim: which copies in iCloud to remove when this Mac holds the RAWs")
    ap.add_argument("--yes-delete-originals", dest="destroy", action="store_true",
                    help="expire: also remove archived frames whose local original is gone. This destroys photographs.")
    a = ap.parse_args()
    stop_cleanly_on_sigterm()
    if a.command == "report":
        return report()
    if not a.shoot:
        print(f"  ./pl archive {a.command} <shoot>")
        return 1
    p = Path(a.shoot).expanduser()
    if not p.is_dir():
        p = ROOT / "shoots" / a.shoot
    if not p.is_dir():
        print(f"  no such shoot: {a.shoot}")
        return 1
    # The shoot itself, whichever of its folders was named (library.paths),
    # the same shoot parts() answers for. parts() re-roots raw/ and cull/ to
    # it, and every other path here (dest_for's folder in iCloud, the
    # manifest's "shoot", the names pipeline_name keeps) is built from this
    # one: handed <shoot>/raw and left as it was, a push went to ARCHIVE/raw/
    # while being recorded in the real shoot's manifest.
    p = library.paths(p.resolve()).shoot
    return {"status": lambda: show_status(p),
            "push": lambda: max(push(p, a.apply, a.force, a.form), push_finished(p, a.apply),
                                push_sidecars(p, a.apply)),
            "trim": lambda: trim(p, a.apply, a.only),
            "repack": lambda: repack(p, a.apply),
            "drop": lambda: _either(drop(p, a.apply), _after_drop, p, a.apply),
            "pull": lambda: _either(pull(p, a.apply), _after_pull, p, a.apply),
            "expire": lambda: expire(p, a.apply, a.after, a.keepers, a.destroy)}[a.command]()


if __name__ == "__main__":
    sys.exit(main())
