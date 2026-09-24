"""
common.py - small things more than one script needs: file types, the empty
XMP packet PhotoLab and Lightroom accept, thumbnails, reading cull.csv.
"""

from __future__ import annotations

import csv
import json
import os
import re
import shutil
import tempfile
import threading
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent

# Where the models live. From a checkout: models/ beside pipeline/. From the
# app: a folder in Application Support that the app seeds from its bundle
# (PIPELINE_MODELS and PIPELINE_BUNDLED_MODELS), so learned files can be
# written next to them.
MODELS = Path(os.environ.get("PIPELINE_MODELS", HERE.parent / "models")).expanduser()
MODEL_FILES = ["yunet.onnx", "object_detection_yolox_2022nov.onnx", "face_recognition_sface_2021dec.onnx",
               "aesthetic_vit_l14_linear.pth", "face_landmarker.task"]
# CLIP ViT-L/14 comes from the Hugging Face hub through open_clip. None means
# the hub's own cache (~/.cache/huggingface); the app points it into MODELS.
CLIP_CACHE = os.environ.get("PIPELINE_CLIP_CACHE") or None
CLIP_REPO = "timm/vit_large_patch14_clip_224.openai"
CLIP_FILE = "open_clip_model.safetensors"
# exiftool: on PATH from a checkout, bundled in the app.
EXIFTOOL = os.environ.get("PIPELINE_EXIFTOOL", "exiftool")


# The app's name, and the name it had before. The support folder is named for
# the app. The app renames the old folder to the new name the first time it
# opens under that name and leaves a link where the old one was, so a checkout
# run on a Mac where the app has not been opened since still finds the old
# folder, and after the rename finds the new one. The archive in iCloud Drive
# is another matter: it keeps the old name for good (archive.ARCHIVE_NAME).
APP_NAME = "First Edit"
FORMER_APP_NAMES = ("Photo Pipeline",)


def _app_support() -> Path:
    """~/Library/Application Support/<the app's folder>: the new name if that
    folder is there, else the old name if that one is, else the new name, to
    be made. Two real folders are never merged: the new one wins, as it does
    in the app."""
    base = Path.home() / "Library" / "Application Support"
    cands = [base / n for n in (APP_NAME, *FORMER_APP_NAMES)]
    return next((c for c in cands if c.is_dir()), cands[0])


def support_dir(create: bool = False) -> Path:
    """<PIPELINE_SUPPORT>, else the app's own folder in Application Support.

    The one place the engine works out where the app keeps what it works out
    for itself; the learned folder, the extension and the updater all ask
    here, so a checkout and the app never keep two copies that never meet.
    Never the library: a person's photographs folder is his, and a tool that
    drops its own scratch files among his shoots is one he has to tidy up
    after."""
    env = os.environ.get("PIPELINE_SUPPORT")
    out = Path(env).expanduser() if env else _app_support()
    if create:
        out.mkdir(parents=True, exist_ok=True)
    return out


def _find_ext() -> Path:
    """A private extension for one domain (its own studio steps, commands and
    moment prompts; contract in README.md under "Extensions") is looked for at
    PIPELINE_EXT, else in the app's support folder (support_dir()/extension),
    else beside this repo."""
    env = os.environ.get("PIPELINE_EXT")
    cands = [Path(env).expanduser()] if env else [support_dir() / "extension",
                                                  HERE.parent.parent / "photo-pipeline-extension"]
    for c in cands:
        if (c / "studio_ext.py").exists():
            return c
    return cands[0]


EXT = _find_ext()


def ext_available() -> bool:
    return (EXT / "studio_ext.py").exists()


MANIFEST = HERE / "models.json"


def model_manifest() -> list[dict]:
    """What each weight file must hash to, and where it came from."""
    try:
        return json.loads(MANIFEST.read_text())["models"]
    except (OSError, ValueError, KeyError):
        return []


def _sha256(path: Path) -> str:
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def bad_models(deep: bool = False) -> list[str]:
    """Every model that is missing, the wrong size, or (with deep) hashes wrong.

    Size is checked on every call because it is free and it catches the failure
    that actually happened: a 131-byte Git LFS pointer sitting in models/ under
    the name of a 227 KB detector, accepted because the only test was that the
    file was not empty. The hash is checked when something has reason to doubt
    the folder: after a download, or on the app's first run."""
    bad = []
    for e in model_manifest():
        p = MODELS / e["file"]
        if not p.exists():
            bad.append(f"{e['file']}: missing")
        elif p.stat().st_size != e["bytes"]:
            bad.append(f"{e['file']}: {p.stat().st_size} bytes, expected {e['bytes']}")
        elif deep and _sha256(p) != e["sha256"]:
            bad.append(f"{e['file']}: contents do not match the manifest")
    return bad


def models_ready(deep: bool = False) -> bool:
    if not model_manifest():                     # no manifest: fall back to the old test
        return all((MODELS / f).exists() for f in MODEL_FILES)
    return not bad_models(deep)


def clip_ready() -> bool:
    try:
        from huggingface_hub import try_to_load_from_cache
    except ImportError:
        return False
    return isinstance(try_to_load_from_cache(CLIP_REPO, CLIP_FILE, cache_dir=CLIP_CACHE), str)


def seed_models() -> None:
    """The app ships the small models read-only inside its bundle; copy them
    once into the writable models folder."""
    src = os.environ.get("PIPELINE_BUNDLED_MODELS")
    if not src:
        return
    MODELS.mkdir(parents=True, exist_ok=True)
    for p in Path(src).iterdir():
        if p.is_file() and not (MODELS / p.name).exists():
            shutil.copy2(p, MODELS / p.name)

# ------------------------------------------------- what the tool has learned
#
# Everything the pipeline learns rather than reads - the venue's taste, the
# calibration it works out from his own exports - belongs in ONE writable
# folder, so a checkout and the app learn from the same file and neither
# writes where it may not. Never inside the repo (a checkout is a clone of
# somebody's work, not a place to keep his) and never inside the app bundle
# (signed, read-only, and replaced whole by the next update).

def learned_dir(create: bool = False) -> Path:
    """PIPELINE_LEARNED, else <support_dir()>/learned. `create` is left to the
    caller that is about to write, so that merely asking where the folder is
    never makes one."""
    env = os.environ.get("PIPELINE_LEARNED")
    out = Path(env).expanduser() if env else support_dir() / "learned"
    if create:
        out.mkdir(parents=True, exist_ok=True)
    return out


# --------------------------------------------------------- writing safely
#
# Every file this pipeline writes is one of three things: a decision a person
# made and no machine can rebuild (the stars, the drop reasons, the answer
# key), a sidecar an editor will open, or a cache. The first two go through
# write_atomic. A truncating write of either loses work: a kill, a sleep or a
# full disk part-way through leaves half a file under its real name, and for a
# .dop that is worse than nothing, because PhotoLab refuses to launch past a
# sidecar with unbalanced braces and never says which one.

# Set by the studio on every job it starts. A command he types himself never
# has it, and keeps its hints for a terminal.
FOR_APP_ENV = "PIPELINE_FOR_APP"


def for_the_app() -> bool:
    """Whether the studio started this command for the app.

    The app says the last line a storage job printed under "Finished copying
    the RAWs…", so that line has to be the result, in the app's own words: a
    button he can press, never a command to type or a path in his home folder.
    Run from a terminal the same commands keep their hints for a typist."""
    return os.environ.get(FOR_APP_ENV) == "1"


def write_atomic(path: Path, data: str | bytes, encoding: str = "utf-8") -> None:
    """Write to a temp file on the same volume, flush it to the platter, then
    rename over the target. os.replace is atomic within a filesystem, so a
    reader sees either the whole old file or the whole new one, never a
    prefix. The temp file is removed on any failure, so a crashed run leaves
    no litter beside the photographs."""
    path = Path(path)
    # Write through a symlink, not over it. os.replace swaps the NAME, so
    # against a link it would leave a real file where the link was: after the
    # decisions move out of cull/, the first star click would quietly put
    # organize.json back inside the cache folder and the shoot would carry two
    # divergent copies of his stars with nothing saying which is current.
    if path.is_symlink():
        path = Path(os.path.realpath(path))
        # The folder the link names, made if it has gone. decision_path hands
        # out cull/organize.json when that is a link into a decisions/ that is
        # no longer there, and the temp file below is made beside the target,
        # so the star click died in mkstemp with FileNotFoundError and the
        # verdict was not written anywhere. Only for a link: an ordinary path
        # whose folder is missing is still a mistake worth failing on.
        path.parent.mkdir(parents=True, exist_ok=True)
    raw = data if isinstance(data, bytes) else data.encode(encoding)
    # A name per call, not per process. The studio is a threaded HTTP server and
    # two stars clicked quickly land in one process on two threads; a temp name
    # built from the pid alone made them contend for one file, and the loser
    # answered the click with a 500.
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    tmp = Path(name)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(raw)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise


def write_json_atomic(path: Path, obj, indent: int = 1) -> None:
    """The same, for the decision files. Serialised before anything is opened,
    so a value that cannot be encoded fails before the old file is at risk."""
    write_atomic(path, json.dumps(obj, indent=indent) + "\n")


def stop_cleanly_on_sigterm() -> None:
    """Make the studio's Stop button a stop, not a kill.

    The studio stops a job by sending SIGTERM to its whole process group, and
    says why: a script that writes files should get the chance to put itself
    down. None of them took it. Python's default for SIGTERM ends the process
    on the spot, without running a single `finally` or `except BaseException`,
    so every cleanup written for exactly this moment was dead code: a stopped
    ingest left `.TSC01234.ARW.tmp<pid>` in raw/, a stopped pull left a
    `.part` of a RAW beside the originals, and a stopped push left one inside
    iCloud Drive to be uploaded, with the frames it had already copied and
    verified missing from the manifest.

    Raising SystemExit instead unwinds the stack like any other exit, so those
    handlers run, and nothing else changes: the process still ends, with the
    conventional 128 + 15."""
    import signal

    def _stop(signum, _frame):
        raise SystemExit(128 + signum)

    try:
        signal.signal(signal.SIGTERM, _stop)
    except ValueError:
        pass                    # not the main thread: a caller that imported us


# --------------------------------------------------- where a decision lives
#
# The stars, the drop reasons, the answer key and the spread ledger are the
# only files in a shoot that no machine can rebuild, and they used to sit
# inside cull/, which Finder reports as 16 GB and which is named like a cache.
# They live in <shoot>/decisions/ now. `pl migrate` leaves a symlink at the old
# name so nothing breaks the day it runs; this pair is what makes those links a
# courtesy rather than the thing holding the shoot together.

def decisions_dir(cull: Path) -> Path:
    """<shoot>/decisions, given the shoot's cull folder (which is `_cull` on a
    shoot with no raw/ subfolder, so the parent is taken rather than assumed)."""
    return Path(cull).parent / "decisions"


def decision_path(cull: Path, name: str) -> Path:
    """Where to read or write one decision file.

    An existing file wins wherever it is, so a half-migrated library and an
    un-migrated one both read correctly. When neither exists the choice falls
    to whether this shoot has a decisions/ folder at all, so a new file joins
    the shoot's own convention instead of imposing one."""
    moved = decisions_dir(cull) / name
    if moved.exists():
        return moved
    legacy = Path(cull) / name
    if legacy.exists():
        return legacy
    return moved if decisions_dir(cull).is_dir() else legacy


# --------------------------------------------------------- room to write
#
# Nothing here used to ask. A cull writes a full-resolution decode per frame
# and a card copy writes the card; on a volume that is nearly full both fail
# part way, and the cull's failure is the quiet one: a decode that did not
# land is read back as the 1616 px camera preview, and every focus and face
# verdict is then taken on a tenth of the pixels.

SPACE_RESERVE = 20 * 1024 ** 3   # leave the machine this much to live on
# PIPELINE_SPACE_RESERVE, in bytes, sets another floor. The test suite sets 0:
# its fixtures are kilobytes, and whether it passes must not depend on how full
# the disk running it is.
if os.environ.get("PIPELINE_SPACE_RESERVE", "").isdigit():
    SPACE_RESERVE = int(os.environ["PIPELINE_SPACE_RESERVE"])


def free_bytes(path: Path) -> int:
    """Free space on the volume holding `path`, or its nearest parent that
    exists yet."""
    p = Path(path)
    while not p.exists() and p != p.parent:
        p = p.parent
    return shutil.disk_usage(p).free


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit in ("B", "KB") else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


class NotEnoughRoom(RuntimeError):
    """Raised before a step starts, never part way through it."""


def require_space(path: Path, need: int, what: str, reserve: int = SPACE_RESERVE) -> None:
    """Refuse to start a step that cannot finish. `need` is the step's own
    estimate in bytes, measured from this library rather than guessed."""
    free = free_bytes(path)
    if free - need >= reserve:
        return
    raise NotEnoughRoom(
        f"not enough room for {what}: it needs about {human(need)} and "
        f"{human(free)} is free, which would leave less than {human(reserve)}. "
        f"Free some space, or point PHOTOS_ROOT at a larger volume.")


RAW_EXTS = {".arw", ".cr2", ".cr3", ".nef", ".raf", ".dng", ".orf", ".rw2"}
JPEG_EXTS = {".jpg", ".jpeg"}
THUMB_PX = 640        # the grid: sharp on a 2x screen at the default tile size
LARGE_PX = 1440       # the same frame for when the tiles are dragged large
EMPTY_XMP = ('<?xpacket begin="\ufeff" id="W5M0MpCehiHzreSzNTczkc9d"?>\n<x:xmpmeta xmlns:x="adobe:ns:meta/">'
             '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"></rdf:RDF></x:xmpmeta>\n<?xpacket end="w"?>\n')


# ------------------------------------------------------------------ data


def slugify(s: str) -> str:
    return re.sub(r"^-|-$", "", re.sub(r"[^a-z0-9]+", "-", s.lower()))


def parse_shot_at(s: str) -> float:
    try:
        return datetime.strptime(s[:19], "%Y:%m:%d %H:%M:%S").timestamp()
    except ValueError:
        return 0.0


def read_cull(out: Path) -> dict[str, dict]:
    rows: dict[str, dict] = {}
    with (out / "cull.csv").open() as fh:
        for r in csv.DictReader(fh):
            rows[r["file"]] = r
    return rows


def segment(files: list[dict], gap: float) -> list[dict]:
    """Split time-ordered files into segments wherever the gap exceeds `gap` seconds."""
    segs: list[dict] = []
    cur: list[str] = []
    prev = None
    for f in files:
        if prev is not None and f["t"] - prev > gap and cur:
            segs.append({"files": cur})
            cur = []
        cur.append(f["name"])
        prev = f["t"]
    if cur:
        segs.append({"files": cur})
    for i, s in enumerate(segs):
        s["id"] = i
        s["assign"] = {"type": "none"}
    return segs


def ensure_thumbs(previews: Path, thumbs: Path, files: list[dict], decoded: Path | None = None,
                  large: Path | None = None) -> None:
    """Grid thumbnails, from the camera's own rendering of the frame.

    These are what the photographer looks at, so they have to look like the
    photograph. The full decode is libraw with no auto-brighten: correct, and
    about 16 L* darker than the same frame as the camera rendered it, measured
    over an action shoot. Built from the decode, every tile in the review step
    came out around a stop and a half down and flat, as though a starting edit
    had already been applied to it; the camera's embedded JPEG is the frame as
    it was seen. It is only about 1600 px, which is too soft to call a missed
    focus on, so judging focus by eye happens in the full view (studio's
    `/full/`), which stays on the decode. The decode is the fallback here for
    frames whose RAW had no embedded preview."""
    import cv2
    thumbs.mkdir(parents=True, exist_ok=True)
    todo = [f for f in files if not (thumbs / f"{f['stem']}.jpg").exists()]
    if todo:
        print(f"  thumbnails: {len(todo)}...")
    for f in todo:
        img = cv2.imread(str(previews / f"{f['stem']}.jpg"))
        if img is None and decoded is not None:
            img = cv2.imread(str(decoded / f"{f['stem']}.jpg"))
        if img is None:
            continue
        h, w = img.shape[:2]
        # Two sizes. A thousand frames at 1440 px is half a gigabyte of images
        # for one screenful, which is what made the grid crawl; the big one is
        # fetched only when the tiles are actually that big.
        for px, out in ((LARGE_PX, large), (THUMB_PX, thumbs)):
            if out is None:
                continue
            out.mkdir(parents=True, exist_ok=True)
            k = px / max(h, w)
            im = cv2.resize(img, (int(w * k), int(h * k)), interpolation=cv2.INTER_AREA) if k < 1 else img
            cv2.imwrite(str(out / f"{f['stem']}.jpg"), im, [cv2.IMWRITE_JPEG_QUALITY, 90])
    for f in files:
        p = thumbs / f"{f['stem']}.jpg"
        if p.exists():
            import cv2 as _cv
            im = _cv.imread(str(p))
            f["th"], f["tw"] = (im.shape[0], im.shape[1]) if im is not None else (3, 4)


# ------------------------------------------------------------- the tiers
# How a cull deals its tiers, in one place. cull.py deals them and the keeper
# check (learned._tiers) replays them to see where a candidate would move a
# keeper; two copies of this rule are how "the check passed" comes to be about
# a cull nobody runs. Pure: indices in, tiers out, and nothing about frames.
CLEAR_WIN, MAYBE, SET_ASIDE = 5, 3, 2


def stack_tiers(stacks: list[list[int]], keep_per_group: int, score) -> tuple[list[int], list[int], list[int]]:
    """Which frames of each stack go on to be tiered: (tiered, set aside under
    a top, the tops). The top is the best by `score`, and keep_per_group
    frames of a stack - the top first - are tiered like any other frame; the
    rest wait under it, set aside and shown. A stack left with fewer than two
    frames is no stack, and its frame is tiered on its own."""
    tiered: list[int] = []
    under: list[int] = []
    tops: list[int] = []
    for mem in stacks:
        if len(mem) < 2:
            tiered += mem
            continue
        ordered = sorted(mem, key=score, reverse=True)
        tops.append(ordered[0])
        tiered += ordered[:keep_per_group]
        under += ordered[keep_per_group:]
    return tiered, under, tops


def deal_tiers(bursts: list[list[int]], order: list[int], score) -> tuple[dict[int, int], bool]:
    """Every tiered frame's tier, and whether the tiers cut across the shoot.

    `bursts` are the frames of each time burst, `order` is every one of them,
    both in the order the caller ranks them (ties keep that order: the sort is
    stable). A burst is the lane because the frames in it are the same moment:
    per lane the best twelfth, and at least two, are clear wins, as many again
    are maybes, and the rest are set aside. Where most bursts are one frame each
    (single-frame shooting, or no capture times) every lone frame would be its
    own clear win, so the whole shoot is one lane instead."""
    lone = sum(1 for fs in bursts if len(fs) == 1)
    across = lone > len(bursts) // 2
    out: dict[int, int] = {}
    for fs in ([order] if across else bursts):
        ordered = sorted(fs, key=score, reverse=True)
        n_win = max(2, len(ordered) // 12)
        for k, i in enumerate(ordered):
            out[i] = CLEAR_WIN if k < n_win else MAYBE if k < 2 * n_win else SET_ASIDE
    return out, across


# ------------------------------------------------------- a frame per core
#
# What one worker costs while a cull is running: its own cv2 DNNs, a mediapipe
# graph and a full-resolution decode in hand. Measured on the 54-frame dog
# shoot with 12 workers, /usr/bin/time -l: 5.2 GB peak footprint for the whole
# run, parent included, which is about 0.4 GB a worker. 0.6 GB here, because
# the frame in hand is a 6024x4024 array (72 MB) and an action shoot's workers
# hold more of them at once than this one's did.
WORKER_BYTES = 600 * 1024 ** 2
# And what is left for everything else: PhotoLab, the studio itself, and the
# machine. A cull that takes the last gigabyte of a 16 GB MacBook is a cull
# that swaps, and swapping is slower than having fewer workers.
WORKER_RESERVE = 3 * 1024 ** 3


def default_workers() -> int:
    """Three quarters of the cores: the machine stays usable and the
    efficiency cores are not what the wall clock waits for. Never more than
    the memory can hold, because a worker holds models and a full-resolution
    frame, and on a small machine the cores are not the ceiling."""
    cores = max(1, (os.cpu_count() or 4) * 3 // 4)
    try:
        ram = os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE")
    except (ValueError, OSError, AttributeError):
        return cores
    return max(1, min(cores, int((ram - WORKER_RESERVE) // WORKER_BYTES)))


# One pool per run, not one per stage. A cull spun up a fresh spawn pool for
# the decodes, another for focus and another for the faces, and every worker
# of every one of them paid the import cost again: mediapipe alone is 0.42 s
# cold, torch 0.57 s, on up to twelve processes three times over. The pool is
# kept between stages and the workers keep what they have already imported.
_POOL: dict = {"ex": None, "n": 0}
_POOL_LOCK = threading.Lock()


def shared_pool(n: int):
    """A process pool with at least n workers, made once and kept."""
    import multiprocessing as mp
    from concurrent.futures import ProcessPoolExecutor
    with _POOL_LOCK:
        ex, have = _POOL["ex"], _POOL["n"]
        if ex is not None and have >= n:
            return ex
        if ex is not None:
            ex.shutdown(wait=False, cancel_futures=True)
        _POOL["ex"] = ProcessPoolExecutor(max_workers=n, mp_context=mp.get_context("spawn"))
        _POOL["n"] = n
        return _POOL["ex"]


def close_pool(broken: bool = False) -> None:
    """Let the workers go: at the end of a run, or when the pool has broken and
    the next caller must not be handed it."""
    with _POOL_LOCK:
        ex, _POOL["ex"], _POOL["n"] = _POOL["ex"], None, 0
    if ex is not None:
        ex.shutdown(wait=not broken, cancel_futures=broken)


def pool_map(fn, jobs: list, workers: int | None = None, progress=None, min_jobs: int = 8):
    """fn over jobs, across processes, yielding results as they come in order.

    Per-frame work here (LibRaw, small CPU nets, image decoding) is
    independent and scales almost linearly with cores, and one frame at a
    time it used one core of twelve. A handful of jobs runs in this process
    (a worker takes seconds to load its models), and so does everything if
    workers cannot start (no importable main module, no memory): slower is
    fine, no output is not. fn must be a module-level function."""
    n = default_workers() if workers is None else workers
    done = 0

    def tick():
        nonlocal done
        done += 1
        if progress:
            progress(done, len(jobs))

    if len(jobs) < min_jobs or n < 2:
        for job in jobs:
            yield fn(job)
            tick()
        return
    from concurrent.futures.process import BrokenProcessPool

    def serial(start: int, why: BaseException):
        print(f"    (one frame at a time from here: {type(why).__name__})", flush=True)
        for job in jobs[start:]:
            yield fn(job)
            tick()

    # Only the POOL failing falls back to one frame at a time. This caught
    # OSError around the whole run, and an OSError is also what a job raises
    # for itself - a RAW that is not there, one archived to iCloud - so one
    # missing frame let the pool run every job already handed to it with the
    # results thrown away, then ran them all again here and hit the same
    # error. A job's own exception now reaches the caller exactly as it would
    # have one frame at a time, and nothing still queued is run for nobody.
    ex = None
    try:
        ex = shared_pool(min(n, len(jobs)))
        # One job per message rather than two: with pairs, the job that failed
        # took its neighbour's finished result down with it.
        results = ex.map(fn, jobs, chunksize=1)
    except (BrokenProcessPool, OSError) as e:    # no workers at all: no memory, no processes left
        close_pool(broken=True)
        yield from serial(0, e)
        return
    got, broke, finished = 0, None, False
    try:
        while True:
            try:
                res = next(results)
            except StopIteration:
                finished = True
                break
            except BrokenProcessPool as e:
                broke = e
                break
            got += 1
            yield res
            tick()
    finally:
        # The pool is kept for the next stage, but only when this one ended
        # tidily. A caller that stopped reading has jobs still queued on it and
        # a broken pool has nothing running at all, and neither may be handed
        # to the stage after this one.
        if not finished:
            close_pool(broken=True)
    if broke is not None:
        yield from serial(got, broke)

