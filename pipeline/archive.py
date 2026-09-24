#!/usr/bin/env python3
"""
archive.py - a shoot's RAWs, kept in iCloud Drive.

    ./pl archive report                     what each shoot would cost, and what is already up
    ./pl archive status <shoot>             frame by frame: local, in iCloud, evicted, missing
    ./pl archive push <shoot> [--apply]     copy the originals up and verify them, the night of the
                                            shoot or any time after. Deletes nothing.
    ./pl archive drop <shoot> [--apply]     remove local originals that are provably in iCloud, once
                                            the shoot is finished
    ./pl archive pull <shoot> [--apply]     bring them back down
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
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from common import (RAW_EXTS, decision_path, for_the_app, human, stop_cleanly_on_sigterm,  # noqa: E402
                    write_json_atomic)

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


def materialise(p: Path, timeout: float = 600.0, poll: float = 0.5) -> bool:
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
    while time.time() < end:
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
    _cull/ is still honoured, because one may yet be on a disk somewhere."""
    shoot = Path(shoot).expanduser().resolve()
    raw = shoot / "raw" if (shoot / "raw").is_dir() else shoot
    if raw.name == "raw":
        return raw, shoot / "cull"
    legacy = shoot / "_cull"
    return raw, legacy if legacy.is_dir() else shoot / "cull"


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


# ------------------------------------------------------------ status

def status(shoot: Path) -> dict:
    """What is true right now, per frame, without trusting the manifest."""
    shoot = Path(shoot).expanduser().resolve()
    raw, _ = parts(shoot)
    man = load_manifest(shoot)["frames"]
    rows = []
    for p in originals(raw):
        d = dest_for(shoot, p.name)
        rows.append({
            "name": p.name,
            "bytes": p.stat().st_size,
            "here": local(p),
            "here_evicted": is_dataless(p),
            "up": d.exists(),
            "up_local": local(d),
            "recorded": p.name in man,
        })
    # Frames that are in the manifest and no longer beside the RAWs: already dropped.
    here = {r["name"] for r in rows}
    for name, rec in man.items():
        if name not in here:
            d = dest_for(shoot, name)
            rows.append({"name": name, "bytes": rec.get("bytes", 0), "here": False,
                         "here_evicted": False, "up": d.exists(), "up_local": local(d),
                         "recorded": True, "dropped": True})
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

def push(shoot: Path, apply: bool, force: bool = False) -> int:
    """Copy the originals up and read each one back. Removes nothing, here or
    there, and so asks nothing of the shoot: it used to refuse one not marked
    finished, which put the one backup he wants the same night - before the
    card is formatted for the next shoot - days away, behind his editing.
    Removing the local originals is what waits for Finish (drop, below).
    `force` is what that refusal was passed to get past; it is still taken,
    so a line typed from habit is not an error, and means nothing now."""
    shoot = Path(shoot).expanduser().resolve()
    bad = icloud_ready()
    if bad:
        print(f"  {bad}")
        return 1
    raw, _ = parts(shoot)
    if not raw.is_dir():
        print(f"  no such shoot: {shoot}")
        return 1

    frames = originals(raw)
    evicted = [p for p in frames if is_dataless(p)]
    if evicted:
        print(f"  {len(evicted)} of this shoot's own RAWs are already evicted to iCloud and would")
        print("  have to come back down before they could be hashed. Bring the RAWs Back first."
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
    todo, already = [], 0
    for p in frames:
        rec = man["frames"].get(p.name)
        d = dest_for(shoot, p.name)
        if rec and d.exists() and d.stat().st_size == rec.get("bytes"):
            already += 1
            continue
        todo.append(p)

    total = sum(p.stat().st_size for p in todo)
    print(f"  {shoot.name}: {len(frames)} originals, {already} already up")
    print(f"  would copy {len(todo)} frames, {human(total)}, to {dest_for(shoot, '').parent}")
    if not todo:
        print("  nothing to do.")
        return 0
    if not apply:
        print("\n  nothing was copied. Add --apply to copy and verify.")
        return 0

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
    for i, p in enumerate(todo, 1):
        # At the head of the loop, not the foot: a frame that copies wrong
        # takes a `continue`, and a bar that stops moving on the runs worth
        # watching is worse than no bar.
        progress("push", i - 1, len(todo))
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
    progress("push", len(todo), len(todo))
    write_json_atomic(manifest_path(shoot), man)
    if for_the_app():
        # One line, and the last: the panel says it under "Finished copying
        # the RAWs of … to iCloud". It ended on `./pl archive drop` and his
        # whole home path.
        said = f"{ok} copied and verified, {failed} failed."
        if ok:
            said += " iCloud still has to upload them, and Remove the Local RAWs takes none until it has."
        if failed:
            said += f" Copy the RAWs to iCloud again copies the {failed} that failed."
        print(f"\n  {said}")
        return 0 if not failed else 1
    print(f"\n  {ok} copied and verified, {failed} failed.")
    print(f"  recorded in {manifest_path(shoot)}")
    if ok:
        print("  iCloud still has to upload them. Nothing is safe to drop until it has:")
        print(f"    ./pl archive drop {shoot}")
    return 0 if not failed else 1


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
    man = load_manifest(shoot)["frames"]
    if not man:
        print(f"  {shoot.name} has no archive manifest: nothing was ever pushed.")
        return 1

    frames = originals(raw)
    names = inode_names(shoot)
    safe, refused = [], []
    unmanaged = 0
    # The bar counts this loop rather than the unlinking below it. Dropping
    # the action shoot reads 26.9 GB back out of iCloud to re-hash it and
    # then makes about 1,157 unlink() calls: all of the waiting is here.
    for i, p in enumerate(frames):
        progress("drop", i, len(frames))
        rec = man.get(p.name)
        d = dest_for(shoot, p.name)
        if not rec:
            refused.append((p, "never pushed"))
            continue
        if not d.exists():
            refused.append((p, "not in iCloud"))
            continue
        # The copy has to be HERE to be hashed. An evicted archive copy cannot
        # be verified without downloading it, and dropping the local original
        # on the strength of a file we have not read is the one thing this must
        # never do.
        if not local(d):
            refused.append((p, "the iCloud copy is evicted; it must come down to be checked"))
            continue
        if d.stat().st_size != rec.get("bytes"):
            refused.append((p, "the iCloud copy is a different size"))
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
        why = _unvouched(d)
        if why:
            refused.append((p, why))
            continue
        if sha256(d) != rec.get("sha256"):
            refused.append((p, "the iCloud copy does not match what was pushed"))
            continue
        if sha256(p) != rec.get("sha256"):
            refused.append((p, "the file here is not the one that was archived"))
            continue
        if not icloud_managed(d):
            unmanaged += 1
        safe.append((p, d, _sig(p), _sig(d), [q for q in every if pipeline_name(shoot, q)],
                     st.st_nlink > len(every)))
    progress("drop", len(frames), len(frames))

    print(f"  {shoot.name}: {len(safe)} frames verified in iCloud, {len(refused)} refused")
    for p, why in refused[:8]:
        print(f"    kept  {p.name}: {why}")
    if len(refused) > 8:
        print(f"    ... and {len(refused) - 8} more")
    if not safe:
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
    print(f"\n  would free {human(freed)} by removing {len(safe)} originals")
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
    if for_the_app():
        said = f"Removed {gone} originals and their links; {human(back)} back."
        if partial:
            said += f" {len(partial)} could not be removed completely and are still on this disk."
        if changed:
            said += f" {len(changed)} changed after they were checked and were left alone."
        print(f"\n  {said} Bring the RAWs Back brings them down again.")
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
    man = load_manifest(shoot)["frames"]
    if not man:
        print(f"  {shoot.name} has no archive manifest.")
        return 1
    # Wanted is "no bytes here", not "no name here". A name with nothing
    # behind it - evicted, or blockless - was answered "already here" by
    # exists(), so pull skipped exactly the frames the panel was offering to
    # bring back. Restoring over such a name is safe: the copy lands as a
    # .part and is renamed over it only once it hashes right.
    want = [(n, r) for n, r in sorted(man.items()) if not local(raw / n)]
    evicted = [n for n, _ in want if is_dataless(dest_for(shoot, n))]
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
    for i, (name, rec) in enumerate(want, 1):
        progress("pull", i - 1, len(want))
        d = dest_for(shoot, name)
        here = raw / name
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
                     " Bring the RAWs Back again asks for them once iCloud can hand them over.")
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
    write_json_atomic(manifest_path(shoot), {"shoot": shoot.name, "frames": man})
    if for_the_app():
        print(f"\n  Removed {gone} from iCloud, {human(back)} of your iCloud quota back."
              + (f" {kept} left alone because they changed after they were checked." if kept else ""))
        return 0
    print(f"\n  removed {gone} from iCloud, {human(back)} of your iCloud quota back.")
    if kept:
        print(f"  {kept} left alone because they changed after they were checked")
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


def main() -> int:
    ap = argparse.ArgumentParser(prog="./pl archive", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["report", "status", "push", "drop", "pull", "expire"])
    ap.add_argument("shoot", nargs="?")
    ap.add_argument("--apply", action="store_true", help="actually do it")
    ap.add_argument("--force", action="store_true",
                    help="taken and ignored: push copies any shoot now, finished or not")
    ap.add_argument("--after", type=int, default=None,
                    help="expire: days since the shoot was finished (default: its retain_days, else the library's, else 365)")
    ap.add_argument("--keepers", action="store_true",
                    help="expire: include the frames you chose, which are protected by default")
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
    return {"status": lambda: show_status(p),
            "push": lambda: push(p, a.apply, a.force),
            "drop": lambda: drop(p, a.apply),
            "pull": lambda: pull(p, a.apply),
            "expire": lambda: expire(p, a.apply, a.after, a.keepers, a.destroy)}[a.command]()


if __name__ == "__main__":
    sys.exit(main())
