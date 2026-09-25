#!/usr/bin/env python3
"""
studio.py - the engine the Mac app drives.

    ./pl studio                # prints the http://127.0.0.1:<port>/ it chose
    ./pl studio --open         # and opens that address in a browser

This served a whole browser page once, and was the product. The Mac app
replaced it. What answers at / now is four sentences saying which program
this is; everything else here is JSON and pictures for the app, and the app
is what a person looks at. `--open` exists for looking at the engine by
hand and is off by default, because this process restarts itself when its
own source changes and the default used to put the retired page in front of
whoever was working in the app at the time.

A shoot is six steps: copy the card, cull, choose keepers, presets, edit in
PhotoLab, done. This works out which of them are done and which is next
(Shoot.steps, Shoot.resume) so that one answer is not written twice. The
cull and the ingest run as jobs with a progress fraction drawn from the
`@@ stage done total` lines the scripts print, and any of them can be
stopped. Work can also be stacked up: WORK, Jobs.add and /api/queue are a
list he fills on purpose, re-read the instant before each one starts, with
nothing that removes photographs allowed onto it.

Two facts are kept apart in everything sent from here and never added
together: what the CULL decided (its tiers, straight out of cull.csv) and
what HE decided (an override, or agreement recorded by having been through
the burst). "keeper" is his word and is never printed over a machine verdict.

An extension (see README.md, "Extensions") can add a kind of shoot with
steps of its own, and serves its own pages from its own port; the app asks
for them through ext_config().

Stdlib only: a threaded HTTP server and JSON endpoints. With --app it is the
process behind the Mac app: it takes a free port, prints `PORT n` for the
app to connect to, and quits when the app closes.
"""

from __future__ import annotations

import argparse
import contextlib
import csv
import errno
import hashlib
import hmac
import importlib.util
import json
import math
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import threading
import time
import webbrowser
from collections import OrderedDict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from stat import S_ISREG
from urllib.parse import urlparse, parse_qs, unquote

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
# `library` is already a function in this module (the /api/library
# answer), so the module it shadows is imported under its own two
# names rather than renamed wholesale.
from library import frame_raw, is_shoot, raw_index, shelf, sidecar_path, paths as shoot_paths  # noqa: E402
from common import (APP_BUNDLE_NAME, APP_NAME, FOR_APP_ENV, decision_path, read_cull, EXT, EXIFTOOL, clip_ready, seed_models,  # noqa: E402
                    support_dir, write_atomic, write_json_atomic)
ROOT = Path(os.environ.get("PHOTOS_ROOT", Path.home() / "photos")).expanduser()
_SHELF: tuple = ()


def shoots_dir() -> Path:
    """Where the shoots stand under this library.

    `ROOT / "shoots"` was written out by hand in six places and appended
    whatever was already there, so pointing PHOTOS_ROOT at the folder his
    shoots are visibly in - the obvious one to pick in a folder chooser -
    looked one level too deep, made that folder, and served an empty studio
    with nothing said. library.shelf() asks the disk instead.

    Asked of ROOT as it is now rather than fixed at import, because ROOT is
    what the tests move. Two stats' worth of cache on top, keyed the way
    dims() is: the answer only changes when the top of the library does, and
    this sits under the image routes.
    """
    global _SHELF

    def stamp(p: Path) -> int:
        try:
            return p.stat().st_mtime_ns
        except OSError:
            return 0

    key = (ROOT, stamp(ROOT), stamp(ROOT / "shoots"))
    if not _SHELF or _SHELF[0] != key:
        _SHELF = (key, shelf(ROOT))
    return _SHELF[1]
RAW_EXTS = {".arw", ".cr2", ".cr3", ".nef", ".dng", ".raf", ".orf", ".rw2", ".jpg", ".jpeg"}
# The columns the page actually reads, plus the four an extension sorts by
# (scene, group, burst, moment) and the sizes rows() adds. Everything else is
# dropped from /api/shoot unless ?full=1 is asked for. face_x and face_y are
# here for the day cull.py writes them: the loupe aims its 1:1 stop at the face
# where they exist and says "centre - no face recorded" where they do not, and
# a column this list does not name would never reach it.
ROW_KEEP = {"file", "stem", "rating", "reason", "face_flags", "face_score", "group", "scene",
            "burst", "quality", "moment", "borderline", "focus", "aesthetic", "shot_at",
            "face_x", "face_y", "override", "label", "edit_note",
            "tw", "th", "lw", "lh", "dw", "dh",
            # Which stack a frame is in and whether it is the cull's guess at
            # the top of it: without these no stack could be drawn. How sure
            # the cull was, and the measurement nearest its line, for a sort
            # on the close calls. face_w/face_h/subject for the day the cull
            # writes a face box and a subject box.
            "stack", "stack_top", "confidence", "close_call", "face_w", "face_h", "subject"}
PY = sys.executable

# The longest edge of the frame the viewer is served. A 6024 px decode drawn
# into 1105 CSS px is 7.5 MB spent on pixels the screen cannot show; the loupe
# asks /crop/ for native pixels when it actually wants them.
FULL_PX = 2600
# The sizes /full/ is served at. 2600 is the default and what the URL means
# with no px, so nothing that asks for a frame the way it always did sees a
# different picture. The rest are for a window bigger than the laptop's: 2600
# is short of a 27" fit view (3606 device px). A px between two of these is
# served the next one up rather than at the exact number asked for, so a pan
# across a wall of sizes does not mint a file per pixel, and each size keeps
# its own URL and so its own cache entry.
FULL_TIERS = (1024, 1600, 2048, 2600, 3200, 4096)
# The widest window /crop/ will cut, in native pixels. 6144 covers a 1:1
# viewport on a 5K display (5056 px), the laptop's own full-screen 1:1 tile
# (4787 px) and the camera's 6000 px long edge, so the whole frame at 1:1 is
# served by the same route. The decode is already in memory at that point and
# a 6144 resize of a 6000 px frame takes nothing.
CROP_MAX_PX = 6144
# Per-shoot pixel sizes of the derivatives, keyed by the shoot and by when its
# cull.csv and its three tiers of derivatives last changed - see Shoot.stamp().
# In memory on purpose: reclaim.py reads any .json in cull/ as a decision, so a
# cache file there would be counted as one of his verdicts and never reclaimed.
_DIMS: dict[tuple, dict] = {}
# How many native decodes may be held in memory at once, and how many requests
# may be cutting one at the same time.
#
# A 6024x4024 decode is 72 MB as an array, and /crop/ read one off the disk on
# every request: a pan is throttled to about eight re-cuts a second and each
# one paid for the whole frame again. ThreadingHTTPServer caps nothing, so
# twelve concurrent crops - one flick of the mouse across the frame - took the
# server from 206 MB RSS to 1,180 MB, measured on 2026-09-13-dog.
#
# Two, because that is the loupe's whole working set: the frame on the screen
# and the one he just arrowed away from. The gate is the same number and not a
# core count, because the ceiling here is memory rather than CPU, and because
# a queued crop can then never evict a frame another thread is still cutting
# from.
FRAMES = 2
_FRAME_CACHE: "OrderedDict[tuple, object]" = OrderedDict()
_FRAME_LOCK = threading.Lock()
_FRAME_GATE = threading.BoundedSemaphore(FRAMES)
# Which thread already holds the gate. The expensive part of a cold frame is
# the RAW decode inside _decoded, and the gate used to be taken AFTER it: eight
# requests for eight frames nobody had opened yet all decoded at once (measured:
# 8 in parallel, 0.76-1.25 s each), which is the whole 72 MB-per-frame working
# set the gate exists to bound. It is taken around the decode now, and the
# callers that already hold it - /crop cutting a window out of the same frame -
# must not queue behind themselves, so it is counted per thread.
_GATE_HELD = threading.local()
# One lock per (shoot, frame), so a second request for a frame that is being
# decoded waits for that decode instead of paying 650 ms to do it again and
# writing over the first one's file as it lands.
_DECODING: dict[tuple, list] = {}
_DECODING_GUARD = threading.Lock()


@contextlib.contextmanager
def _gate():
    """Hold the frame gate, once per thread however deep the call goes."""
    held = getattr(_GATE_HELD, "n", 0)
    if held:
        _GATE_HELD.n = held + 1
        try:
            yield
        finally:
            _GATE_HELD.n = held
        return
    _FRAME_GATE.acquire()
    _GATE_HELD.n = 1
    try:
        yield
    finally:
        _GATE_HELD.n = 0
        _FRAME_GATE.release()


@contextlib.contextmanager
def _decoding(key: tuple):
    """One decode of one frame at a time. The lock is kept only while somebody
    is waiting on it, so a shoot he has been through does not leave a thousand
    locks behind."""
    with _DECODING_GUARD:
        entry = _DECODING.setdefault(key, [threading.Lock(), 0])
        entry[1] += 1
        lock = entry[0]
    try:
        with lock:
            yield
    finally:
        with _DECODING_GUARD:
            entry = _DECODING.get(key)
            if entry is not None:
                entry[1] -= 1
                if entry[1] <= 0:
                    _DECODING.pop(key, None)


_LIBC = None


def _give_memory_back() -> None:
    """Hand freed decode buffers back to the OS.

    A 6024x4024 decode is 72 MB, and macOS's allocator keeps a large block it
    has freed on its own list rather than returning it: after twenty frames
    opened at full resolution, well inside the two-frame cache, this process
    held 3.37 GB RSS with 3.0 GB of it in "Malloc Large (empty)". On a 16 GB
    MacBook with PhotoLab open beside it, that is the studio taking memory it
    is not using and never giving it back. malloc_zone_pressure_relief is the
    documented way to ask for it back; NULL means every zone, 0 means as much
    as it can. It is in libSystem, which is already loaded, so this costs
    nothing to have and does nothing at all where the call is missing."""
    global _LIBC
    try:
        if _LIBC is None:
            import ctypes
            import ctypes.util
            _LIBC = ctypes.CDLL(ctypes.util.find_library("System") or "libSystem.B.dylib")
            _LIBC.malloc_zone_pressure_relief.restype = ctypes.c_size_t
            _LIBC.malloc_zone_pressure_relief.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        _LIBC.malloc_zone_pressure_relief(None, 0)
    except Exception:  # noqa: BLE001
        pass
# Every decision file is read whole, changed and written whole, and this is a
# threading server: two requests that overlap both read the same old file and
# the second one writes his first verdict out of existence. write_atomic makes
# each write all-or-nothing; it cannot make a read-modify-write a transaction.
# Measured before this lock existed: twenty overlapping /api/rating posts left
# five ratings on disk and answered "ok" to all twenty. The page can overlap
# two posts easily - markSeen() is deliberately not awaited, and a K whose
# round trip is still open does not stop the next key - so the window is not
# theoretical. Re-entrant because set_rating files the answer key while it
# holds it, and /api/selects takes the same lock on its own.
_DECIDE_LOCK = threading.RLock()
# How much of a cull each stage is, for one bar across all of them.
# A first cull's longest stretch is decoding every RAW at full resolution, and
# it reported under a name this table did not carry, so the bar sat at 4% for
# the first six minutes of a 1,558-frame card and read as no bar at all. On a
# re-cull the decodes are cached and the stage never reports; status() counts
# a stage as done once a later one has spoken, so the bar does not stall at
# 74% either way.
WEIGHTS = {"previews": 4, "decode": 26, "focus": 10, "faces": 42, "quality": 10, "presets": 5, "thumbs": 3}
# What to call each stage where a person can see it. "faces 240/1157" says
# nothing about what the machine is doing or what it is counting.
STAGE_WORDS = {
    "previews": ("reading the frames", "frames"), "decode": ("decoding the frames", "frames"), "focus": ("checking focus", "frames"),
    "faces": ("looking at faces", "frames"), "quality": ("judging the pictures", "steps"),
    "presets": ("reading the light", "scenes"), "thumbs": ("making thumbnails", "frames"),
    # A frame, as the sidebar and the light table count one: "copying: 412
    # of 1,558 files" sat above a sidebar that said "1,558 frames".
    "copy": ("copying", "frames"), "verify": ("checking the copy", "frames"),
    "clip": ("downloading the picture model", "MB"), "download": ("downloading", "MB"),
    "stage": ("unpacking", "steps"),
    # The storage jobs. archive.py and reclaim.py print `@@ stage done total`
    # where they can, and Jobs.status() prefers it; where they cannot, it reads
    # the "  40/1157 copied and verified" they print anyway and calls it one of
    # these stages. One bar, one convention, no second machine.
    "reel": ("cutting the reel", "frames"),
    # The Instagram step's two jobs: the pass that works each cut out and
    # writes no photograph, and the one that makes the copies.
    "planning": ("working out the cuts", "photographs"),
    "instagram": ("making the Instagram copies", "photographs"),
    "push": ("copying to iCloud", "frames"), "drop": ("removing local originals", "frames"),
    "pull": ("bringing frames back", "frames"), "expire": ("removing from iCloud", "files"),
    "check": ("checking every original", "frames"), "reclaim": ("taking back cache", "files"),
}
INGEST_WEIGHTS = {"copy": 70, "verify": 30}
# By what was asked of the copy. Without a check there is no second stage, so
# the copy is the whole bar: weighted 70 it sat at 70% and jumped to 100%. A
# check at the end reads every byte on both sides again, as long as the copy
# itself, and weighted 30 it ran the time left short by that much.
INGEST_WEIGHTS_BY_VERIFY = {"in-flight": INGEST_WEIGHTS, "end": {"copy": 50, "verify": 50},
                            "none": {"copy": 100}}


def ingest_weights(args) -> dict:
    """The bar's weights for a card copy, read off the command it runs with."""
    try:
        a = [str(x) for x in args]
        mode = a[a.index("--verify") + 1]
    except (TypeError, ValueError, IndexError):
        mode = "in-flight"
    return INGEST_WEIGHTS_BY_VERIFY.get(mode, INGEST_WEIGHTS)


SETUP_WEIGHTS = {"clip": 100}
UPDATE_WEIGHTS = {"download": 90, "stage": 10}
# One stage each: a push is a push. Held as a dict per verb so the bar's
# arithmetic below is the same for these as it is for a cull.
STOR_WEIGHTS = {k: {k: 100} for k in ("push", "drop", "pull", "expire", "check", "reclaim")}
# By kind, for the jobs that are one stage long and are not storage verbs. An
# Instagram make was weighed against the cull's table, where "instagram" is
# not a stage, and its bar sat at 0% until it ended. The planning pass is added
# beside IG_PLAN_KIND.
KIND_WEIGHTS: dict[str, dict[str, int]] = {"instagram": {"instagram": 100}}
# The machine's own homework, as opposed to work he asked for.
#
# A background job exists to help him later. It holds nothing he is waiting
# for, it is asked for again the moment the machine is next idle, and nothing
# it learns is used until it has been checked against every photograph he
# kept - so standing it down mid-way costs nothing but the time already spent.
# Therefore: a background job is never the reason he cannot do something. Every
# route he can press stands it down and starts his work at once (Jobs.make_room
# below). Two jobs of HIS still queue behind each other, because both are work
# he asked for and neither is the machine's to throw away.
#
# Filled in beside LEARN_KIND, where the learning job is defined.
BACKGROUND_KINDS: set[str] = set()
# How long the machine has to be quiet after his work before the homework is
# picked up again. Long enough to cover the gap between drawing a plan and
# confirming it, short enough that it is going again by the time he has put
# the card away.
LEARN_RESUME_QUIET = 120.0
# Settings ▸ Learning (DESIGN.md §2.11): "Learn from finished shoots
# automatically" and "Only when the Mac is idle". The app hands them over in
# the environment at start and again whenever he changes one
# (POST /api/learned/settings); both switches were written and read by
# nothing, so learning ran two minutes after any job whatever they said, in
# the middle of Choose Keepers. An engine started by hand, with no app to say,
# learns as it always has: after a finished shoot, whenever the slot is free.
LEARN_PREFS = {"auto": os.environ.get("PIPELINE_LEARN_AUTO", "1") != "0",
               "idle_only": os.environ.get("PIPELINE_LEARN_IDLE_ONLY", "0") == "1"}
# The reason a finished shoot writes down when it asks for a run: an ask that
# starts with it is the automatic kind, which the first switch is about. Learn
# Now is his, whatever the switch says.
FINISHED_WHY = "you finished "
# How long the Activity window's history is kept across quits, and at most how
# many rows (DESIGN.md §2.7). Enough to read last night's list in the morning,
# and the weekend's on Monday; not a record of his life.
HISTORY_DAYS = 3
HISTORY_MAX = 200
APP = False
UPDATE: dict = {}      # the last answer from update.py --check, filled in by a thread at startup


def staged_update() -> Path:
    """Where a downloaded and checked build waits to be installed: update.py's
    STAGED, worked out the same way, when asked."""
    return support_dir() / "updates" / "staged" / f"{APP_BUNDLE_NAME}.app"


def checks_at_start() -> bool:
    """Whether to ask GitHub once as the app starts. The app says not to
    (PIPELINE_NO_UPDATE_CHECK) when he has turned off "Check for updates
    automatically"; the switch used to change nothing, and the engine asked at
    every launch. A check he asks for from the menu still runs."""
    return APP and not os.environ.get("PIPELINE_NO_UPDATE_CHECK")


def check_for_update(force: bool = False) -> None:
    if not APP:
        return
    try:
        out = subprocess.run([PY, str(HERE / "update.py"), "--check"], capture_output=True, text=True, timeout=20).stdout
        UPDATE.clear()
        UPDATE.update(json.loads(out))
        UPDATE["staged"] = staged_update().exists()
    except Exception:  # noqa: BLE001
        UPDATE.clear()
        # A sentence, not a decoder's. update.py always prints JSON with a
        # readable "error" of its own when it cannot reach GitHub, so this is
        # only for update.py not running at all or answering with something
        # that is not JSON - and "Expecting value: line 1 column 1 (char 0)"
        # on the update card tells him nothing he can act on.
        UPDATE["error"] = "the update check did not answer"


# --------------------------------------------------------- the extension

def load_ext():
    """An extension is a folder with studio_ext.py in it. It declares one extra
    kind of shoot (KIND, ASK, STEPS, LABELS), can add fields to a shoot's info
    (info), flags to the cull (cull_args), folders the page may open (folder),
    and answers POST /api/ext/<name> (route). It declares the address of each
    step's own page in PAGES, which ext_config() puts on /api/shoots and the
    app loads in place of its own screen for that step; the extension serves
    those pages itself, from its own port, with its own copy of the key."""
    p = EXT / "studio_ext.py"
    if not p.exists():
        return None
    sys.path.insert(0, str(EXT))
    spec = importlib.util.spec_from_file_location("studio_ext", p)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# Where this engine's own modules are, for the extension's modules that import
# them (its organizer reads PIPELINE_PUBLIC). Nothing used to set it, and in
# the app the organizer found them only because a folder beside the extension
# happened to be his checkout: the app ran the checkout's code for it, not its
# own. Set before the extension is loaded, so a module it imports as it loads
# sees it, and inherited by every job the studio starts.
os.environ["PIPELINE_PUBLIC"] = str(HERE)
EXTM = load_ext()


def ext_config() -> dict | None:
    if not EXTM:
        return None
    # every: steps the extension adds to EVERY kind of shoot, not only its own,
    # placed before "done". What a shoot is does not decide whether it can go
    # somewhere; an extension that publishes publishes all of them.
    return {"kind": EXTM.KIND, "ask": EXTM.ASK, "steps": EXTM.STEPS, "labels": getattr(EXTM, "LABELS", {}),
            "every": list(getattr(EXTM, "EVERY", [])),
            # Where an extension's own page for a step is, step id -> URL. The
            # app hosts it in a web view; a step with no page here is one the
            # app draws itself, and an extension with no PAGES has none.
            "pages": dict(getattr(EXTM, "PAGES", {}))}


def find_photolab() -> "Path | None":
    """Whatever this machine calls PhotoLab. It ships as DXOPhotoLab10.app here,
    which a case-sensitive glob for 'DxO*PhotoLab*' silently missed, so the
    button opened Finder instead and looked like it had done nothing.

    presets.photolab_app() is asked first because it ranks by the version each
    bundle DECLARES. This function used to take the alphabetically first match,
    which is right today only by luck -- "DXOPhotoLab10" sorts before
    "DXOPhotoLab8" -- and would hand him PhotoLab 10 the day he installs 11.
    The scan below stays as the fallback, because it looks in ~/Applications
    too and tolerates a name nobody has thought of yet."""
    try:
        from presets import photolab_app
        found = photolab_app()
        if found:
            return found[0]
    except Exception:  # noqa: BLE001
        pass
    for d in (Path("/Applications"), Path.home() / "Applications"):
        if not d.is_dir():
            continue
        for a in sorted(d.glob("*.app")):
            n = a.name.lower().replace(" ", "")
            if "photolab" in n and "dxo" in n:
                return a
    return None


# The start of each other editor's application name, lower case with the
# spaces taken out - the same rule the app's Editors.find uses to say where it is.
EDITOR_APPS = {"lightroom": "adobelightroomclassic", "rawtherapee": "rawtherapee", "darktable": "darktable"}
EDITOR_NAMES = {"dxo": "PhotoLab", "lightroom": "Lightroom Classic", "rawtherapee": "RawTherapee",
                "darktable": "darktable"}


def find_editor(editor: str) -> "Path | None":
    """The application for the editor a shoot's presets are written for.
    Open My Keepers in Lightroom Classic launched PhotoLab: the route only
    ever looked for PhotoLab, whatever the button said.

    One folder down as well as at the top: Adobe installs Lightroom Classic
    as /Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app, so
    Open went to Finder saying it was not in Applications while the Presets
    page, asking Launch Services, said it was installed."""
    if editor not in EDITOR_APPS:
        return find_photolab()
    start = EDITOR_APPS[editor]
    for d in (Path("/Applications"), Path.home() / "Applications"):
        if not d.is_dir():
            continue
        try:
            inside = sorted(p for p in d.iterdir() if p.is_dir() and p.suffix != ".app" and not p.name.startswith("."))
        except OSError:
            inside = []
        for where in (d, *inside):
            try:
                apps = sorted(where.glob("*.app"))
            except OSError:
                continue
            for a in apps:
                if a.name.lower().replace(" ", "").startswith(start):
                    return a
    return None


# How long a press waits for macOS to say whether the editor or the Finder
# window opened. `open` returns as soon as Launch Services has answered, well
# inside a second on his Mac. A timeout is unconfirmed, never success.
OPEN_WAIT = 10
OPEN_CLEANUP_WAIT = 1


def _open(args: list[str]) -> str | None:
    """`open` with these arguments, and why it did not open, or None if it did.

    It was started and forgotten, so an editor macOS would not open - moved
    since the list of applications was read, damaged, refused - came back to
    the page as "Opened in PhotoLab at 21:14" with nothing on the screen. The
    answer is waited for now, and a refusal is the page's line."""
    try:
        p = subprocess.Popen(["open", *args], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.PIPE, text=True)
    except OSError as e:
        return f"macOS could not be asked to open it ({e.strerror or e})"
    try:
        _, err = p.communicate(timeout=OPEN_WAIT)
    except subprocess.TimeoutExpired:
        # Stop only the launch helper, not the editor. Do not communicate
        # again: a descendant could still hold its stderr pipe open.
        try:
            p.kill()
            try:
                p.wait(timeout=OPEN_CLEANUP_WAIT)
            except subprocess.TimeoutExpired:
                # Reap it when the OS finally releases it, without keeping
                # the request (and the page's button) waiting indefinitely.
                threading.Thread(target=p.wait, daemon=True).start()
        finally:
            if p.stderr is not None:
                p.stderr.close()
        return f"macOS did not confirm opening within {OPEN_WAIT:g} seconds; check the editor before trying again"
    if p.returncode == 0:
        return None
    said = [line.strip() for line in (err or "").splitlines() if line.strip()]
    return said[-1] if said else f"open stopped with code {p.returncode}"


def kind_of(value) -> str:
    return EXTM.KIND if EXTM and value == EXTM.KIND else "other"


# ------------------------------------------------------------- the model


def _why(e: OSError, act: str = "write there") -> str:
    """What actually stopped it, in a clause that fits either verb.

    Its own function because a refused WRITE and a file that will not READ are
    both errno and both reach the page, and the read half had no sentence at
    all: the front page's damaged-shoot row printed "[Errno 13] Permission
    denied: .../cull.csv" straight out of the kernel. One map, so the two
    never drift into saying the same thing two ways."""
    return {errno.EACCES: f"this Mac would not let the studio {act}",
            errno.EPERM: f"this Mac would not let the studio {act}",
            errno.EROFS: "that disk is read-only",
            errno.ENOSPC: "that disk is full",
            errno.EDQUOT: "there is no room left in your quota",
            errno.ENOENT: "that folder is not there",
            errno.ENOTDIR: "something in that path is not a folder",
            errno.EISDIR: "there is a folder in the way",
            }.get(e.errno, (e.strerror or str(e)).lower())


def _refusal(e: BaseException) -> str:
    """A write that was refused, in his words rather than the kernel's.

    Every decision file goes through write_atomic, which writes a temp file
    beside the target and renames it over, so a read-only decisions folder
    reached him as "[Errno 13] Permission denied:
    .../.labels.json.saerybnm.tmp" - true, unreadable, and naming a file that
    does not exist as far as he is concerned. The temp name is turned back
    into the name he knows, and the errno into what actually stopped it.

    Anything that is not an OSError is left exactly as it was: the refusals
    this page already words well - the answer key declining to narrow, a plan
    that has been overtaken - are sentences, and rewriting them here would be
    a second voice for the same fact."""
    if not isinstance(e, OSError):
        return str(e)
    why = _why(e)
    name = getattr(e, "filename", "") or ""
    if not name:
        return f"nothing was written: {why}."
    p = Path(name)
    # write_atomic's scratch name for X is ".X.<eight characters>.tmp".
    m = re.fullmatch(r"\.(.+)\.[A-Za-z0-9_]{8}\.tmp", p.name)
    if m:
        p = p.with_name(m.group(1))
    return f"{p.name} could not be written in {p.parent}: {why}."


def _broken_file(s: "Shoot", e: Exception) -> tuple[str, str]:
    """Which of a damaged shoot's files will not read, by name and by path.

    A shoot whose decisions file is unreadable costs one row rather than the
    whole list, and that row carried the parser's complaint on its own -
    "Unterminated string starting at: line 1 column 13" - naming no file, no
    folder and no way in. The comment above it says a shoot missing from the
    list is a shoot he cannot open to repair; a row naming nothing is the same
    thing one step further on. Each decision file is read in turn, because the
    one that raised is the one that will raise again."""
    for name in ("organize.json", "labels.json", "review.json", "selects.json"):
        p = decision_path(s.cull, name)
        if not p.exists():
            continue
        try:
            json.loads(p.read_text())
        except ValueError as bad:
            return str(p), f"{p.name} will not read: {bad}"
        except OSError as bad:
            return str(p), _refusal(bad)
    # Not every way info() can fail is a decisions file that will not parse. A
    # cull.csv this Mac will not let the studio read raises here too, and that
    # branch handed the row `str(e)` and no path: "[Errno 13] Permission
    # denied: .../cull.csv" with no file named, no button, and the kernel's
    # voice - the unreadable refusal and the dead-end row, both of them, on the
    # one way in neither was measured on. Whatever the exception names is the
    # file; where it names nothing the shoot's own folder is still a way in.
    if isinstance(e, OSError):
        p = Path(getattr(e, "filename", "") or s.folder)
        return str(p), f"{p.name} could not be read: {_why(e, 'read it')}."
    return str(s.folder), f"this shoot could not be read: {e}"


def within(p: Path, top: Path) -> bool:
    """Whether `p`, with every link on the way followed, is still inside `top`.

    realpath on both sides, so a shoot that is itself a link to another disk
    still contains its own files, and a link inside a shoot that points
    somewhere else does not. A name that does not exist yet resolves as far as
    its parents do, which is what a write about to create it will follow."""
    inside = os.path.realpath(top)
    return os.path.commonpath([os.path.realpath(p), inside]) == inside


def stars_asked(value) -> int | None:
    """A rating the page asked for: None ("as culled") or a whole 0 to 5.

    Refused rather than clamped. A request for -999 stars is not a verdict,
    and writing 0 in its place would put a decision in his name that he never
    made; the page prints the refusal and the frame keeps what it had. A
    string of digits is taken, because the page hands back a cull tier it read
    out of cull.csv, and a true/false is not a number of stars."""
    if value is None:
        return None
    if isinstance(value, str) and re.fullmatch(r"[0-9]+", value.strip()):
        value = int(value)
    elif isinstance(value, float) and value.is_integer():
        value = int(value)
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 5:
        raise ValueError(f"a rating is 0 to 5 stars, not {value!r}")
    return value


def _num(v) -> float:
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def can_cut_reels() -> bool:
    """Whether a reel can be cut on this machine: the private reel step is in
    this build and there is an encoder it can find (PIPELINE_FFMPEG, else
    ffmpeg on PATH, as reel.py looks). The app has none of its own yet."""
    if not (HERE / "reel.py").exists():
        return False
    exe = os.environ.get("PIPELINE_FFMPEG") or shutil.which("ffmpeg")
    return bool(exe) and Path(exe).is_file()


# The steps every shoot has, in order, what makes each one done, and what each
# needs before it can start. An extension's steps are its own (ext_config).
BASE_STEPS = ["ingest", "cull", "keepers", "presets", "edit", "instagram", "reels", "done"]
# The app's own names for the steps (DESIGN.md §2.4, Strings.Steps), letter for
# letter. These were "Copy the card", "Choose keepers" and "Done", so a shoot's
# rows re-lettered the moment it loaded, and the last step was Done in the
# sidebar and the Go menu, Finish in the Keyboard Shortcuts window and on the
# page itself.
STEP_LABELS = {"ingest": "Copy the Card", "cull": "Cull", "keepers": "Choose Keepers", "presets": "Presets",
               "edit": "Edit in PhotoLab", "instagram": "Instagram", "reels": "Reels", "done": "Finish"}
# A copy is done when there are frames and its own log does not say it stopped
# or failed, and it is not still going: a card pulled at 412 of 1,558 left a
# shoot that read as copied in the sidebar and the step list, with Cull as the
# only way on. A shoot copied
# before the copy kept a log has no note, and its frames are all it has to go on.
STEP_DONE = {"ingest": lambda i: i["frames"] > 0 and (i.get("ingest") or {}).get("state") not in ("copying", "stopped", "failed"),
             "cull": lambda i: i["culled"],
             "keepers": lambda i: bool(i["reviewed"]), "presets": lambda i: i["presets"] > 0 and i["sidecars"] > 0,
             "edit": lambda i: i["exported"] > 0, "instagram": lambda i: i["instagram"] > 0,
             "reels": lambda i: i["reels"] > 0,
             "done": lambda i: bool(i["finished"])}
# Sentences, as the sidebar's help and the step page print them.
STEP_NEEDS = {
    "cull": lambda i: None if i["frames"] > 0 or i["culled"] else "There are no frames to cull yet: copy the card first.",
    "keepers": lambda i: None if i["culled"] else "Cull the shoot first.",
    "presets": lambda i: None if i["culled"] else "Cull the shoot first.",
    "edit": lambda i: None if i["culled"] else "Cull the shoot first.",
    # A shoot that already has copies keeps the step open, so they are found
    # where they were even if the exports have since moved.
    "instagram": lambda i: None if i["exported"] > 0 or i["instagram"] > 0 else (
        "Nothing is exported yet: the copies are cut from your finished photographs."),
    "reels": lambda i: None if i["can_cut_reels"] else (
        "Reels are not part of this build." if not (HERE / "reel.py").exists()
        else "Cutting a reel needs a video encoder this Mac does not have."),
    "done": lambda i: None if i["culled"] else "Cull the shoot first.",
}


def cull_summary(rows: list[dict]) -> dict:
    """What the cull did, counted from cull.csv, and one sentence of it.

    A cull that stacks writes a stack column and never rating 1: a frame that
    looks like another is set aside under the stack's top and shown, and only
    a fault it can name is hidden. The sentence said "folded N as duplicates"
    of a cull that folds nothing; `duplicates` is still counted, and still
    said, for a cull.csv written before stacks."""
    t = {k: sum(1 for r in rows if str(r.get("rating")) == k) for k in ("5", "3", "2", "1", "0")}
    stacks: dict[str, int] = {}
    for r in rows:
        if r.get("stack"):
            stacks[r["stack"]] = stacks.get(r["stack"], 0) + 1
    stacked = bool(rows) and "stack" in rows[0]
    under = sum(1 for r in rows if r.get("stack") and str(r.get("stack_top")) != "1")
    out = {"frames": len(rows), "clear_wins": t["5"], "maybes": t["3"], "set_aside": t["2"],
           "duplicates": t["1"], "faults": t["0"], "stacked": stacked, "stacks": len(stacks),
           "stacked_frames": sum(stacks.values()), "under_tops": under, "line": ""}
    if not rows:
        return out
    words = (f"{len(rows)} frames. It shortlisted {_s(t['5'], 'clear win')} and {_s(t['3'], 'maybe')}, "
             f"set {t['2']} aside")
    if stacked:
        words += (f", and stacked {sum(stacks.values())} frames that look alike into {_s(len(stacks), 'stack')}. "
                  f"Nothing was hidden for looking alike; {_s(t['0'], 'frame')} with a fault it can name "
                  f"{'is' if t['0'] == 1 else 'are'} out of sight.")
    else:
        words += f", folded {t['1']} as duplicates, and found {t['0']} with a fault it can name."
    out["line"] = words
    return out


class KeyUnreadable(ValueError):
    """The answer key is on disk and will not parse, so it cannot be compared
    against and must not be written over.

    A ValueError, so a single star click stays as quiet about it as it is
    about a refused narrowing; its own type, so the Re-read button offers to
    confirm only when confirming can actually help."""


class Shoot:
    def __init__(self, folder: Path):
        # The one resolver (library.paths), which every command reads a shoot
        # by: raw/ when there is one, else the shoot itself; the cull where
        # cull.csv is, then whichever of cull/ and _cull/ exists, else cull/.
        # A flat folder culled by the old fork into _cull/ is still read and
        # written there rather than a second cull started beside it. This had
        # a rule of its own that took _cull/ only while no cull/ existed at
        # all, so an empty cull/ made beside it by any other command turned
        # the studio's back on the real cull.
        where = shoot_paths(folder)
        self.folder = where.shoot
        self.raw = where.raw
        self.cull = where.cull
        self.export = where.export
        # Why the answer key was not written on the last star click. A click
        # must not fail because the key was left alone, but it must not go by
        # in silence either: the page prints this in place of the keeper hint.
        self.last_key_refusal = ""
        # cull_stamp() reads cull.csv; a request asks for it two or three times
        # and a Shoot is made per request, so it is worked out once per object.
        self._stamp = ""
        self._stamp_for = -1

    def info(self) -> dict:
        n = sum(1 for p in self.raw.iterdir() if p.suffix.lower() in RAW_EXTS) if self.raw.is_dir() else 0
        # Count whichever sidecar the chosen editor writes, or the presets step
        # never reads as finished for anyone not using PhotoLab. The suffix is
        # read from editors.FORMATS rather than written out again here: a
        # second copy of a vendor's fact is how this repo came to declare a
        # RawTherapee version four releases old in one file and not the other.
        import editors as ed
        rows = self.rows()
        picks = sum(1 for r in rows if self.stars(r) >= 3)
        # Only the keepers' sidecars. raw/ also holds sidecars for frames you
        # have since thrown out, and counting those reads as more sidecars
        # than keepers (410 against 264 on one shoot). The name before the
        # first dot, because a DxO sidecar is <stem>.ARW.dop and an XMP is
        # <stem>.xmp, and both belong to the same frame.
        kept = {r["file"].split(".", 1)[0] for r in rows if self.stars(r) >= 3}
        # Every writer's suffix, not only the chosen editor's. Counting one
        # suffix meant the same untouched folder of 54 .dop files reported "23
        # carrying a sidecar" as dxo and "0" as Lightroom - which un-ticked the
        # Edit checklist and flipped the Presets step back to not-done while
        # nothing on disk had moved. What is on disk does not change because he
        # opened a dropdown. The suffixes actually found are reported too, so
        # the card can say what it counted instead of asserting an editor.
        suffixes = sorted(set(ed.WRITERS.values()))
        found: dict[str, int] = {}
        if self.raw.is_dir():
            for sfx in suffixes:
                # With no cull there is no keeper set, and counting against an
                # empty one reported 0 sidecars for ducksAndDeadlifts - 98 RAWs
                # with 98 .dop files beside them, a shoot he has already been
                # through in PhotoLab - which is how it came to read "Not
                # started" on the front page.
                c = sum(1 for p in self.raw.glob("*" + sfx)
                        if not rows or p.name.split(".", 1)[0] in kept)
                if c:
                    found[sfx] = c
        dops = max(found.values()) if found else 0
        exported = self.exported()               # once: it walks the export folders
        # An export he has made since is picked up here, rather than by a
        # button he has to know to press. "Re-read what I kept" was that
        # button: its own refusal sentence was printed while culling, where the
        # button is not, and the software already knows everything the press
        # would tell it. Only when something new is actually there, so a page
        # load never rewrites his keepers for nothing, and a refusal is carried
        # on the card instead of thrown: the home page must paint either way.
        recorded = self.recorded_keepers()
        if {s for s in exported if s not in recorded}:
            try:
                self.remember_selects()
                recorded = self.recorded_keepers()
            except ValueError as e:
                self.last_key_refusal = str(e)
        # The cull's own tiers and his own verdicts, counted apart. Authorship
        # is DERIVED here and written nowhere: an override on the frame is his;
        # no override in a burst he has been through is him agreeing with the
        # cull; neither is nobody having looked. Deriving it is what lets 174
        # of his 293 keystrokes on one shoot go away - 142 of them wrote the
        # cull's own rating straight back, purely to record "I looked".
        cull_picks = sum(1 for r in rows if int(r["rating"] or 0) >= 3)
        rev = self.review()
        # His verdicts by gather's rule, the one that builds the folder of
        # "the frames you kept": a star, the cull's pick in a burst he has been
        # through and left standing, and the answer key of a shoot worked
        # before there was a record of being through a burst. Counting stars
        # and bursts alone said "you kept 0" on shoots whose folder held 14.
        import gather
        his = self.his(rows)
        self._his, self._rev = his, rev            # GET /api/shoot hands these on as they are
        kept_by_him = sum(1 for v in his["verdicts"].values() if v)
        dropped_by_him = sum(1 for v in his["verdicts"].values() if not v)
        bursts = his["bursts"]
        seen_n = sum(1 for b in bursts if b["seen"])
        # The cull's picks he walked past and left standing: no key pressed, in
        # a burst he has been through, and put forward by the cull. The page
        # prints this as "the cull put forward in bursts you looked through and
        # did not mark", so it counts exactly that. Without the rating it
        # counted every frame he left alone, set-asides included - 1,242 on a
        # shoot where the cull had put forward 150. A count for the page only:
        # what gets a preset is `picks`, and that is unchanged. These frames
        # are also inside `kept`, which is gather's rule and counts a pick he
        # left standing as his; the page takes them out of it, not adds them.
        agreed = sum(1 for r in rows if "override" not in r and int(r.get("rating") or 0) >= 3
                     and gather._burst(r) in his["seen"])
        d = {"name": self.folder.name, "path": str(self.folder), "raw": str(self.raw), "export": str(self.export),
             "kind": self.meta().get("kind"), "reviewed": bool(self.meta().get("reviewed")),
             # His recorded keepers: what every check measures against. This
             # was the sum of his stars and the cull's picks, printed in his
             # voice; that sum is will_be_edited now, and says whose it is not.
             "keepers": len(recorded),
             # What gets a sidecar and goes into edit/: his override where he
             # pressed one, else the cull's tier. Nobody's opinion on its own,
             # and never shown as his.
             "will_be_edited": picks,
             "agreed": agreed,
             "card": self.meta().get("card") or "",
             # What the next cull starts from: what he last asked for, written
             # when a cull starts; on a shoot no cull was asked of yet, what
             # his last shoot was culled with (`cull_from` names it), and 1.9
             # and normal only when no shoot of his has been culled at all.
             **dict(zip(("style", "focus", "cull_from"), _cull_settings(self))),
             # What the cull whose results are on disk ran with, written by
             # cull.py only once it has put cull.csv in place, so a re-cull
             # stopped part way or one that died leaves it naming the results
             # still on screen. Empty on a shoot culled before it was kept,
             # and then nothing is said rather than the defaults above.
             "cull_ran_with": self._ran_with(),
             # Empty when no presets have been written for an editor yet, so
             # the app starts the shoot on the one he chose in Settings or on
             # the first-run sheet. "dxo" here meant neither was ever read.
             "editor": self.meta().get("editor") or "",
             # The RAWs can be cleared after a shoot is delivered while the cull
             # stays. Counting only what is on disk then reads "6 frames, 30 picks",
             # so the frame count is whichever record is more complete.
             "frames": max(n, len(rows)), "raws": n, "raws_cleared": bool(rows) and n < len(rows),
             # Where his exports actually are. exported() already searches
             # export/, a folder inside edit/ and iCloud; the Done card used to
             # assert export/ whatever it found, on a shoot whose export/ is
             # empty and whose 265 edits are in edit/edited/.
             "export_where": self._export_where(exported),
             "export_dirs": self.export_dirs() if exported else [],
             "sidecars": dops, "sidecar_kinds": found, "culled": bool(rows), "picks": picks,
             # The two authors, never added together. cull_picks is the cull's
             # own shortlist straight out of cull.csv; kept is what HE said yes
             # to, either by pressing K or by having been through the burst and
             # left the cull's choice standing. The page prints them as two
             # numbers under two names, because a shoot with no decisions on it
             # used to report 313 of his keepers.
             # What is in <shoot>/reels, so the step can say whether anything
             # has been cut without the page going to look.
             "reels": len(self.reels()), "reel_dir": str(self.folder / "reels"),
             # The Instagram copies already made, by the same count: a look at
             # a folder that is never created to be looked at.
             "instagram": self.instagram_made(),
             "cull_picks": cull_picks, "kept": kept_by_him, "dropped": dropped_by_him,
             # Time bursts, as GET /api/shoot lists them: one burst is one
             # burst however many scenes it crosses.
             "bursts": len(bursts), "seen": seen_n, "at": rev["at"],
             # Empty except when review.json was written against a cull that
             # has since been re-run. The row and the light table both print it
             # beside the counts they draw from his been-through record.
             "review_stale": rev.get("stale", ""),
             # What was asked of the copy, so the ingest card can stop printing
             # "checked" over a copy nothing checked. Absent on every shoot
             # copied before this was recorded, and the card says so.
             "verify": self.meta().get("verify") or "", "ingest": _ingest_note(self),
             "presets": len(self.presets()),
             "presets_ran": _presets_ran(self, self.presets()),
             # What the presets step decided, in its own words: which look the
             # sidecars start from and how exposure was decided, so the page
             # says what was done and not only how many files it wrote.
             "presets_note": next((n for p in self.presets() for n in (p.get("notes") or []) if n.startswith("starting from")), ""),
             "exported": len(exported),
             # Marked on the Done card. Only a finished shoot's edits teach
             # the starting edit; an exported frame counts on its own.
             "finished": bool(self.meta().get("finished")),
             # His keepers as they are recorded: the one number every change to
             # the cull is measured against, from the file the checks read, so
             # the page cannot show one number while the keeper check uses
             # another. Where they came from, in his own terms, and what the
             # answer key refused if it refused anything.
             "recorded_keepers": len(recorded),
             "recorded_from": _recorded_from(recorded, exported),
             # The day it was marked finished, as the Finish page says it.
             "finished_on": self.meta().get("finished") if isinstance(self.meta().get("finished"), str) else "",
             "keepers_note": self.last_key_refusal or "",
             # Whether this shoot teaches: the cull learns from finished shoots
             # and from frames that have been exported, and from nothing else.
             "teaches": bool(self.meta().get("finished")) or bool(exported),
             # And what it teaches from: the frames he exported, however many
             # he kept (learned.taught) - found now, written down at Finish,
             # or recorded by the learning store when it measured them, and
             # never his keepers. The Finish page says it beside the recorded
             # keepers every check still measures against.
             **dict(zip(("taught", "taught_from"), _taught(self, exported))),
             # Which learned models this shoot was culled with, as the cull
             # recorded them, so its card can say so months later.
             "culled_with": self.meta().get("learned") or {},
             "thumbs": (self.cull / "thumbs").is_dir(),
             # Whether the Reels step can do anything on this machine, so it is
             # left out rather than offered and then refused.
             "can_cut_reels": can_cut_reels(),
             "cull_summary": cull_summary(rows)}
        if EXTM and hasattr(EXTM, "info"):
            d.update(EXTM.info(self))
        return d

    def his(self, rows: list[dict] | None = None) -> dict:
        """His verdicts (gather.verdicts), the burst pieces he has been through,
        and the time bursts of this cull with his counts and the cull's in
        each, kept apart.

        The server groups the frames, not the page. The page grouped by scene
        and burst together, and a scene is a CLIP cluster split by the light,
        so one burst - one exchange, seconds long - came apart across two
        screens on 56 of the gym shoot's 89 bursts, and a stack inside it with
        it. A burst here is the time burst, whatever scenes it crosses."""
        import gather
        rows = self.rows() if rows is None else rows
        if not rows:
            return {"verdicts": {}, "seen": set(), "bursts": []}
        seen = gather.seen_bursts(self.cull, rows, gather._overrides(self.cull))
        mine = gather.verdicts(self.cull, rows)
        groups: dict[str, list[dict]] = {}
        for r in rows:
            groups.setdefault(gather.time_burst(r), []).append(r)
        out = []
        for bid, members in groups.items():
            members.sort(key=lambda r: (r.get("shot_at") or "", r["file"]))
            pieces = {gather._burst(r) for r in members}
            # The cull's own top: its highest tier, then its best score. Only
            # the picture the burst list shows for it, never a verdict.
            cover = max(members, key=lambda r: (int(r.get("rating") or 0), _num(r.get("quality"))))
            kept = sum(1 for r in members if mine.get(r["file"]) is True)
            out_n = sum(1 for r in members if mine.get(r["file"]) is False)
            out.append({"id": bid, "index": 0, "scene": members[0].get("scene") or None,
                        "started_at": members[0].get("shot_at") or None,
                        # STEMS, not file names. Every picture route takes a
                        # stem (/thumb/<shoot>/<stem>.jpg) and the app keys its
                        # rows by stem too, so a burst that named files made it
                        # ask for TSC07363.ARW.jpg: 404 on every frame, and a
                        # light table with no photographs in it. His verdicts
                        # are still keyed by file, which is what the row beside
                        # each stem carries.
                        "frames": [_stem(r) for r in members], "cover": _stem(cover),
                        "seen": pieces <= seen, "kept": kept, "out": out_n,
                        "cull_picks": sum(1 for r in members if int(r.get("rating") or 0) >= 3),
                        "undecided": len(members) - kept - out_n})
        out.sort(key=lambda b: (b["started_at"] or "", b["id"]))
        for i, b in enumerate(out):
            b["index"] = i
        return {"verdicts": mine, "seen": seen, "bursts": out}

    def resume(self, bursts: list[dict], rev: dict, kept: int) -> dict:
        """Where Choose Keepers opens, and the sentence that says why.

        In order: the burst he was in, if this cull still has it; else the
        first he has not been through; else, when every burst has been, the
        first. review.at may name a time burst (the app) or a scene/burst piece
        (the web page), and a piece is found inside its time burst."""
        n = len(bursts)
        if not n:
            return {"burst_id": None, "kind": "fresh",
                    "note": "This shoot has not been culled yet, so there is nothing to choose from."}
        through = sum(1 for b in bursts if b["seen"])
        at = str(rev.get("at") or "")
        target = None
        if at:
            if any(b["id"] == at for b in bursts):
                target = at
            elif "/" in at:
                burst_no = at.split("/", 1)[1]
                target = next((b["id"] for b in bursts if b["id"] == burst_no), None)
        if target is not None:
            i = next(b["index"] for b in bursts if b["id"] == target)
            kind, note = "left_off", (f"Back where you left off: burst {i + 1} of {n}. "
                                      f"{through} looked through, {n - through} to go.")
        else:
            first = next((b for b in bursts if not b["seen"]), None)
            gone = "The burst you were in is not in this cull any more. " if at else ""
            if first is None:
                target, kind, note = bursts[0]["id"], "all_seen", f"{gone}Every burst has been looked through. You kept {kept}."
            elif gone or through:
                target, kind = first["id"], "moved"
                note = (f"{gone}Burst {first['index'] + 1} of {n}." if gone else
                        f"Starting at burst {first['index'] + 1} of {n}, the first you have not looked through.")
            else:
                target, kind, note = first["id"], "fresh", f"Burst 1 of {n}. E keep, D drop, F next frame, R next burst. Press ? for the rest."
        if rev.get("stale"):
            note = f"{rev['stale'][0].upper()}{rev['stale'][1:]}. {note}"
        return {"burst_id": target, "kind": kind, "note": note}

    def steps(self, info: dict) -> list[dict]:
        """The steps of this shoot, whether each is done, and whether it can be
        started, with the reason when it cannot. One table: the page kept its
        own copy of the done rules in JavaScript and an extension a third."""
        cfg = ext_config()
        kind = info.get("kind")
        if cfg and kind == cfg["kind"]:
            ids = list(cfg["steps"])
            if "instagram" not in ids:
                # The Instagram copies are a step of every shoot, and an
                # extension's own list was written before there was one. It
                # goes after the edit, where the finished photographs it cuts
                # from are; an extension that names it keeps its own place.
                at = (ids.index("edit") + 1 if "edit" in ids else ids.index("reels") if "reels" in ids
                      else ids.index("done") if "done" in ids else len(ids))
                ids.insert(at, "instagram")
        else:
            every = [x for x in (cfg or {}).get("every", []) if x not in BASE_STEPS]
            ids = BASE_STEPS[:-1] + every + BASE_STEPS[-1:]
        if "reels" in ids and not info.get("can_cut_reels") and not info.get("reels"):
            # Absent, not broken: a machine that cannot encode a reel has no
            # Reels step. One that already has reels in the folder keeps the
            # step, so they are still found where they were.
            ids.remove("reels")
        labels = (cfg or {}).get("labels") or {}
        ext_done = getattr(EXTM, "step_done", None) if EXTM else None
        out = []
        for sid in ids:
            base = sid in BASE_STEPS
            if base:
                done = STEP_DONE[sid](info)
            elif callable(ext_done):
                try:
                    done = bool(ext_done(sid, self, info))
                except Exception:  # noqa: BLE001
                    done = False
            else:
                done = False
            why = STEP_NEEDS.get(sid, lambda i: None)(info) if base else None
            label = labels.get(sid) or STEP_LABELS.get(sid, sid)
            if sid == "edit" and not labels.get(sid) and info.get("editor") in EDITOR_NAMES:
                # Named for the editor the presets were written for, as the
                # page and its button are.
                label = f"Edit in {EDITOR_NAMES[info['editor']]}"
            out.append({"id": sid, "label": label, "done": bool(done),
                        "enabled": why is None, "why_disabled": why, "source": "base" if base else "extension"})
        return out

    def _ran_with(self) -> dict:
        r = self.meta().get("cull_ran_with")
        if not isinstance(r, dict):
            return {}
        try:
            return {"style": "action" if r.get("style") == "action" else "normal",
                    "focus": round(float(r["focus"]), 2)}
        except (KeyError, TypeError, ValueError):
            return {}

    def meta(self) -> dict:
        p = self.folder / "shoot.json"
        try:
            return json.loads(p.read_text()) if p.exists() else {}
        except Exception:  # noqa: BLE001
            return {}

    def set_meta(self, **kv) -> None:
        m = self.meta()
        m.update(kv)
        self.folder.mkdir(parents=True, exist_ok=True)
        write_json_atomic(self.folder / "shoot.json", m)

    def rows(self) -> list[dict]:
        p = self.cull / "cull.csv"
        if not p.exists():
            return []
        with p.open() as fh:
            rows = list(csv.DictReader(fh))
        over = self.overrides()
        lp = decision_path(self.cull, "labels.json")
        labels = {}
        if lp.exists():
            try:
                labels = json.loads(lp.read_text())
            except ValueError:
                labels = {}
        # What the presets step decided on each frame (presets.json "decided"),
        # so a frame left alone says why under its thumbnail.
        decided = {stem: note for p in self.presets() for stem, note in (p.get("decided") or {}).items()}
        dims = self.dims()
        for r in rows:
            r["stem"] = Path(r["file"]).stem
            # Only what was actually measured. A missing tier leaves its keys
            # off the row rather than guessing, so the page can tell "no thumb"
            # from "a thumb of some size or other".
            for tier, a, b in (("t", "tw", "th"), ("l", "lw", "lh"), ("d", "dw", "dh")):
                wh = dims.get(r["stem"], {}).get(tier)
                if wh:
                    r[a], r[b] = wh
            if r["file"] in over:
                r["override"] = over[r["file"]]
            r["label"] = labels.get(r["file"], "")
            r["edit_note"] = decided.get(r["stem"], "")
        return rows

    @staticmethod
    def stars(r: dict) -> int:
        return int(r["override"]) if "override" in r else int(r["rating"] or 0)

    def cull_stamp(self) -> str:
        """Which cull a burst number belongs to.

        A burst is keyed scene/burst and both numbers are the CULL's, handed
        out afresh on every run. review.json outlives a re-cull, so with
        nothing tying the two together the page went on printing "1 of 155
        bursts through" and a green "you kept 59" over keys that now name
        different frames, or no frames at all - his voice, over a record of a
        shoot that no longer exists.

        Hashed over the grouping itself rather than cull.csv's mtime, so a
        re-cull that lands on the same bursts is correctly not a change and
        says nothing at him."""
        p = self.cull / "cull.csv"
        try:
            mt = p.stat().st_mtime_ns
        except OSError:
            return ""
        if self._stamp_for == mt:
            return self._stamp
        try:
            rows = read_cull(self.cull)
        except (OSError, KeyError, ValueError):
            return ""
        h = hashlib.sha1()
        for f in sorted(rows):
            r = rows[f]
            h.update(f"{f}\t{r.get('scene', '')}/{r.get('burst', '')}\n".encode())
        self._stamp_for, self._stamp = mt, h.hexdigest()[:16]
        return self._stamp

    def review(self) -> dict:
        """Which bursts he has actually been through, and where he stopped.

        Its own file, and never a key inside organize.json. That file holds
        his 293 real verdicts and an extension's organiser loads it whole and
        writes it whole, so a second program's key in it is a thing the two of
        them can lose for each other - which is the shape of the selects.json
        incident. Nothing else reads this one: not set_rating, not
        remember_selects, not `./pl bench`. It cannot reach a verdict of his.

        Fails soft on purpose. A review file that will not parse costs him his
        place in the shoot, which is an annoyance; refusing to open the shoot
        over it would cost him the shoot."""
        p = decision_path(self.cull, "review.json")
        try:
            d = json.loads(p.read_text()) if p.exists() else {}
        except (OSError, ValueError):
            return {"at": "", "bursts": {}, "stale": ""}
        b = d.get("bursts")
        b = b if isinstance(b, dict) else {}
        # A seed written before it carried the mark: "from: your overrides" and
        # no "seen", which is what one press of N on a shoot open this
        # afternoon has already put on disk. It says what it always said, so it
        # is read as that rather than costing him the same 99 bursts twice.
        if any(isinstance(v, dict) and v.get("from") and not v.get("seen") for v in b.values()):
            when = self._overrides_when()
            b = {k: (dict(v, seen=when) if isinstance(v, dict) and v.get("from") and not v.get("seen") else v)
                 for k, v in b.items()}
        # Recorded against a cull that has since been re-run. The keys cannot
        # be trusted - "7/6" held five frames before and holds none now - so
        # they are not counted and not shown as his, and the page says why
        # instead of printing a number that means nothing. Nothing of his is
        # lost: every verdict he pressed is keyed by FILE in organize.json, and
        # _review_from_evidence reads the bursts back out of those against the
        # cull that is actually on disk. A file written before this stamp
        # existed has nothing to compare and is left alone.
        stale = ""
        was, now = str(d.get("cull") or ""), self.cull_stamp()
        if b and was and now and was != now:
            stale = ("what you had looked through was recorded against an earlier cull, so it is worked out again "
                     "from the frames you pressed a key on")
            b = {}
        if not b:
            b = self._review_from_evidence()
        return {"at": "" if stale else str(d.get("at") or ""), "bursts": b, "stale": stale}

    def _review_from_evidence(self) -> dict:
        """What he has already been through, on a shoot worked before this file
        existed.

        review.json is new. Without this, the first thing the page says about
        the shoot he has worked hardest is that he has not looked at it: on
        2026-09-16 he made 299 overrides and delivered 154 frames, and every
        card would have read "0 of 89 bursts through, you kept 0". A page that
        opens by denying his work is worse than the burst list it replaced.

        A burst holding an override is a burst he opened and changed something
        in, which is the strongest evidence there is short of the record
        itself. Bursts he agreed with the cull on cannot be recovered - nothing
        wrote them down, which is the gap this file exists to close - so they
        stay unseen and he walks them again. It reads, never writes: the moment
        he finishes one burst the real file takes over."""
        try:
            over = json.loads(decision_path(self.cull, "organize.json").read_text()).get("photos", {})
        except (OSError, ValueError):
            return {}
        touched = {f for f, v in over.items() if v.get("rating") is not None}
        if not touched:
            return {}
        try:
            rows = read_cull(self.cull)
        except (OSError, KeyError):
            return {}
        # The retired page keyed a burst by scene AND burst (burstKey:
        # `r.scene+'/'+r.burst`), because a burst number restarts inside each
        # scene. Seeding on the burst number alone wrote "0" where the page
        # looks for "3/0", so every seeded burst silently failed to match and
        # the whole point of this function was lost.
        seen = {f"{r.get('scene', '')}/{r.get('burst', '')}"
                for f, r in rows.items() if f in touched and r.get("burst") is not None}
        # Marked "seen", like every other burst he has been through. Both
        # readers - info() below and the page's own SEEN - keep only the
        # entries carrying that key, so seeding them with "from" alone handed
        # back 99 bursts that neither of them counted: his most-worked shoot
        # still opened on "0 of 155 bursts through", the exact sentence this
        # function exists to prevent, and the first N press then wrote the
        # unmarked 99 into review.json where the seeding could never run again.
        return {b: {"seen": self._overrides_when(), "from": "your overrides"}
                for b in sorted(seen) if b != "/"}

    def _overrides_when(self) -> str:
        """When he made the verdicts a seeded burst is read from - which is
        when organize.json was last written, and the honest answer to "when was
        this burst been through"."""
        try:
            return time.strftime("%Y-%m-%dT%H:%M:%S",
                                 time.localtime(decision_path(self.cull, "organize.json").stat().st_mtime))
        except OSError:
            return "from your overrides"

    def set_review(self, at=None, seen=None, unseen=None) -> dict:
        """Record that he has been through these bursts, and where he is.

        `seen` is never a verdict and never changes one: it says he looked.
        The page writes it only when he leaves a burst FORWARD, because
        leaving backwards, jumping from the map or opening the index are not
        finishing. A burst can be un-seen again from the header, which is why
        `unseen` exists - a count that says 47 settled when he skated past 12
        of them would be the page flattering him again."""
        # Under the lock for the same reason the ratings are: he holds N down,
        # the page fires markSeen without awaiting it, and two of ten bursts
        # marked "been through" went missing between the browser and the disk.
        with _DECIDE_LOCK:
            d = self.review()
            stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
            for k in (seen or []):
                d["bursts"].setdefault(str(k), {})["seen"] = stamp
            for k in (unseen or []):
                d["bursts"].pop(str(k), None)
            if at is not None:
                d["at"] = str(at)
            # Which cull these numbers were handed out by. Written on every
            # save rather than only the first, so a file seeded from his
            # overrides after a re-cull is stamped with the cull it was
            # actually seeded against.
            d["cull"] = self.cull_stamp()
            # "stale" is review()'s word to the page about the file it just
            # read, and this is about to make it untrue. It has no business on
            # disk, where the next reader would take it for a record.
            d.pop("stale", None)
            self.cull.mkdir(parents=True, exist_ok=True)
            write_json_atomic(decision_path(self.cull, "review.json"), d)
            return d

    def overrides(self) -> dict:
        """Star overrides live in one state file per shoot (cull/organize.json,
        photos -> {rating}), which an extension's own pages may share."""
        p = decision_path(self.cull, "organize.json")
        if not p.exists():
            return {}
        st = json.loads(p.read_text())
        return {k: v["rating"] for k, v in st.get("photos", {}).items() if v.get("rating") is not None}

    def set_rating(self, file: str, rating: int | None) -> None:
        """One verdict at a time, whoever is asking.

        organize.json is read whole, changed and written whole, so two star
        writes that overlap both read the file as it was before either of them
        and the second one writes the first out of existence - silently, with
        an "ok" going back to the page for both. The lock, not the atomic
        write, is what makes a verdict survive the next one."""
        # Checked here as well as at the endpoint, because anything holding a
        # Shoot can call this and `file` goes straight into a path. Unchecked,
        # "../../2026-09-19/raw/TSC05805.ARW" sent to a different shoot
        # rewrote that shoot's PhotoLab sidecar and answered "ok".
        file = self.frame(file)
        rating = stars_asked(rating)
        with _DECIDE_LOCK:
            self._set_rating(file, rating)

    def frame(self, file) -> str:
        """`file` if it is one of this shoot's frames, else a ValueError.

        One of the frames cull.csv lists, which is every frame the page can
        put a verdict on, and a bare name: a name cull.py wrote is never a
        path, so one that is came from somewhere other than this page."""
        if not isinstance(file, str) or not file or file in (".", "..") or Path(file).name != file or "\\" in file:
            raise ValueError("that is not the name of a frame")
        try:
            known = read_cull(self.cull)
        except (OSError, KeyError):
            known = {}
        if file not in known:
            raise ValueError(f"{file} is not a frame of {self.folder.name}")
        return file

    def _set_rating(self, file: str, rating: int | None) -> None:
        p = decision_path(self.cull, "organize.json")
        st = json.loads(p.read_text()) if p.exists() else {}
        photos = st.setdefault("photos", {})
        ph = photos.setdefault(file, {})
        if rating is None:
            ph.pop("rating", None)
        else:
            ph["rating"] = rating
        self.cull.mkdir(parents=True, exist_ok=True)
        # Every star click lands here, so this is the file most likely to be
        # open when the machine is put to sleep or the app is killed. It holds
        # verdicts nothing can rebuild.
        write_json_atomic(p, st)
        # PhotoLab reads the star from the .dop / XMP; keep those in step. "As
        # culled" puts the cull's own rating back.
        if rating is None:
            for r in self.rows():
                if r["file"] == file:
                    # As presets writes it: a cull 5 is 3 + "Clear win", never five stars.
                    rating = {"5": 3, "3": 3, "2": 2, "1": 1}.get(r["rating"], 0)
                    break
        if rating is not None:
            # Beside the frame's RAW and named for it (library.sidecar_path):
            # the cull can name a frame by the camera JPEG it decoded, and
            # raw/TSC04016.jpg.dop is a file PhotoLab never opens, so a star
            # clicked on such a frame never reached TSC04016.ARW.dop. No RAW
            # here, no sidecar to keep in step.
            side = sidecar_path(self.folder, file)
            # write_atomic writes THROUGH a link, which is right for the
            # decisions folder and wrong here: a sidecar that is a link out of
            # this shoot would carry the star into whatever it points at. A
            # link that stays inside the shoot (edit/ beside raw/) is his.
            if side is not None and side.exists() and within(side, self.folder):
                # A half-written .dop is not a lost star, it is PhotoLab
                # refusing to launch past the sidecar and never saying which.
                write_atomic(side, re.sub(r"Rating = \d+,", f"Rating = {rating},", side.read_text(), count=1))
            xmp = self.raw / f"{Path(file).stem}.xmp"
            if xmp.exists() and within(xmp, self.folder):
                # EXIFTOOL, not "exiftool": inside the app nothing is on PATH,
                # so the bare name silently did nothing and the star never
                # reached the sidecar.
                subprocess.run([EXIFTOOL, "-q", "-overwrite_original", f"-XMP:Rating={rating}", str(xmp)], capture_output=True)
        # Choosing a keeper IS the answer key, so it is written every time
        # rather than waiting for a button at the end of the shoot. A shoot
        # whose selects were never saved is one the bench cannot use, and the
        # work of culling it is already done by this point. A refusal here is
        # not an error for a single click; the explicit button reports it.
        try:
            self.remember_selects()
        except ValueError as e:
            self.last_key_refusal = str(e)

    def _export_where(self, exported: set) -> str:
        """Where the exports this shoot has actually are, in a few words.

        exported() searches export/, a folder inside edit/ and iCloud, and the
        Done card went on asserting `export/` whatever it found: on the gym
        shoot, which is marked finished with 265 sidecars and an EMPTY
        export/, the card said the finished photographs were in a folder with
        nothing in it. The function already knew; the sentence never asked."""
        if not exported:
            return ""
        here = self.export_dirs()
        if not here:
            return "Somewhere outside this shoot (iCloud, or a folder moved since)"
        return ", ".join(here[:3])

    def export_dirs(self) -> list[str]:
        """The folders inside this shoot that hold exports: export/, and edit/
        or a folder in it, which is where PhotoLab's own default puts them.
        Each is drawn as its own row with its own Show button; one sentence of
        comma-joined paths could not be opened, and Edit showed only export/,
        whose Show refused on a shoot whose exports were in edit/edited/."""
        here = []
        if self.export.is_dir() and any(self.export.glob("*.jp*g")):
            here.append(str(self.export))
        edit = self.folder / "edit"
        if edit.is_dir():
            for d in sorted([edit] + [q for q in edit.iterdir() if q.is_dir()]):
                if any(d.glob("*.jp*g")):
                    here.append(str(d))
        return here

    def instagram_made(self) -> int:
        """How many Instagram copies are in <shoot>/instagram. Only looked at:
        a shoot nobody has made a copy of has no such folder, and asking must
        not give it one."""
        d = self.folder / "instagram"
        if not d.is_dir():
            return 0
        return sum(1 for p in d.glob("*.jpg") if not p.name.startswith("."))

    def reels(self) -> list[dict]:
        """The clips already cut. `./pl reel` writes them into <shoot>/reels as
        1080x1920 h264, one file per cut, newest first here."""
        d = self.folder / "reels"
        if not d.is_dir():
            return []
        out = []
        for p in sorted(d.glob("*.mp4"), key=lambda q: -q.stat().st_mtime):
            st = p.stat()
            out.append({"name": p.name, "bytes": st.st_size,
                        "at": time.strftime("%Y-%m-%d %H:%M", time.localtime(st.st_mtime))})
        return out

    def exported(self) -> set[str]:
        """The frames of this shoot he has exported, wherever he exported them:
        export/, a folder inside edit/ (PhotoLab's default lands beside the
        RAWs), or iCloud. 154 keepers once sat in edit/edited/ unseen."""
        # The frame's RAW by its number (library.frame_raw), for a cull that
        # names the camera JPEG; where it has gone, the name the cull gave it,
        # which taste still dates by the shoot's own cull.csv.
        have = raw_index(self.folder)
        raws = {Path(r["file"]).stem: have.get(Path(r["file"]).stem) or self.raw / r["file"]
                for r in self.rows()}
        out = set()
        if self.export.is_dir():
            out |= {p.stem.split("_DxO")[0] for p in self.export.glob("*.jp*g")} & set(raws)
        try:
            import taste
            at = taste.exported_at()
            # An export made after the frame and before the camera next used
            # its number (taste.is_exported): the camera reuses its numbers,
            # and another shoot's TSC00012 is not this one's.
            out |= {s for s, raw in raws.items() if taste.is_exported(raw, at)}
        except Exception:  # noqa: BLE001
            pass
        return out

    def recorded_keepers(self) -> set[str]:
        """The frames recorded as his keepers, by stem: the file every check
        measures a change against. An unreadable one answers empty here and is
        never written over; remember_selects is where that is refused."""
        p = decision_path(self.cull, "selects.json")
        try:
            got = json.loads(p.read_text()) if p.exists() else []
            return {Path(f).stem for f in got} if isinstance(got, list) else set()
        except (OSError, ValueError):
            return set()

    def remember_selects(self, narrow: bool = False) -> int:
        """Record what HE chose as this shoot's answer key for `./pl bench`.

        Only the photographer's own decisions count, and they are unioned rather than ranked:
        the frames the photographer exported (the photographer delivered those) and the frames the photographer starred
        by hand (that is the photographer's live verdict). The cull's own ratings are NOT a
        source: filing them as the answer key would measure the cull against
        itself. The one place the cull's keepers count is edit/, because the photographer
        built that folder from them (gather) and took it into PhotoLab: a
        frame in edit/ that the photographer has not since demoted is one the photographer accepted. A
        "reviewed" flag was tried as that evidence and rewrote a hand-made
        12-frame key as the cull's 31; the folder the photographer actually made is the
        evidence, not a flag.

        Taking exports alone is wrong for the same reason in reverse: a shoot
        part way through editing has three JPEGs out and twenty-five keepers,
        and the three would bury the twenty-five."""
        with _DECIDE_LOCK:
            return self._remember_selects(narrow)

    def _remember_selects(self, narrow: bool = False) -> int:
        rows = self.rows()
        if not rows:
            return 0
        known = {r["file"] for r in rows}
        by_stem = {Path(r["file"]).stem: r["file"] for r in rows}
        over = self.overrides()
        chosen = {f for f, v in over.items() if v >= 3 and f in known}
        exported = {by_stem[s] for s in self.exported() if s in by_stem}
        if self.meta().get("finished") and exported:
            # A finished shoot with exports: what he exported is what he kept,
            # and a frame he starred or took into edit/ but did not export was
            # thrown out at the end (PhotoLab's red light is not written to
            # disk; its result is). 154 exports against 291 frames in edit/
            # once read as 284 keepers without this.
            chosen = exported
        else:
            edit = self.folder / "edit"
            if edit.is_dir():
                taken = {by_stem[q.stem] for q in edit.iterdir() if q.stem in by_stem and q.suffix.lower() != ".dop"}
                chosen |= {f for f in taken if over.get(f, 3) >= 3}      # an explicit demotion since still wins
            chosen |= exported
        if not chosen:
            return 0
        self.cull.mkdir(parents=True, exist_ok=True)
        out = decision_path(self.cull, "selects.json")
        # An answer key is hand-made and not reconstructible. One is never
        # narrowed without keeping what was there, and a write that would throw
        # away more than half of it is refused outright: that is what a bad
        # source looks like, not what a change of mind looks like.
        if out.exists():
            # Fail closed. A key that would not parse used to read as an empty
            # set, which switched off both guards below at the one moment they
            # exist for: nothing had been chosen before, so no shrink was ever
            # large enough to refuse and there was nothing to copy aside, and
            # the next star click wrote over the damage with whatever this run
            # happened to find. A key that cannot be read cannot be compared
            # against, so it is left exactly as it is and the run says why.
            try:
                had = json.loads(out.read_text())
                if not isinstance(had, list):
                    raise ValueError(f"expected a list of frames, found {type(had).__name__}")
                had = set(had)
            except FileNotFoundError:
                had = set()                    # deleted between the test and the read
            except (OSError, ValueError, TypeError) as e:
                raise KeyUnreadable(
                    f"not written: {out} is on disk but cannot be read ({e}). "
                    f"Nothing was changed. Look at that file, or move it aside, and try again") from e
            # A finished shoot's key is frozen, not rebuilt from a weaker
            # source. The delivered-set branch above is what keeps the promise
            # in the docstring: 154 exports against 291 frames in edit/, which
            # without it reads as 284 keepers. That branch only holds while
            # exported() can still find the JPEGs - export/, a folder in edit/,
            # or iCloud. If they ever went out of reach the branch would go
            # with them, and the permissive union of overrides and edit/ would
            # file itself over a delivered set on the next star click, quietly,
            # because a single click swallows a refusal. This is that door
            # shut. It is a defence, not a report of damage: no key of his has
            # been rebuilt this way.
            # Both refusals are put to him as a question with the two numbers
            # on its buttons, so they say what would happen and nothing else:
            # no file path, and no "press Re-read again or delete it by hand"
            # from the web page, whose button is gone and whose other answer
            # was never his to be told.
            if self.meta().get("finished") and not exported and had and not narrow:
                raise ValueError(
                    f"Not recorded: this finished shoot's keeper list holds {len(had)} frames chosen from "
                    f"exports that cannot be found now, and recording again would replace it with "
                    f"{len(chosen)} frames taken from your marks and the edit folder. Nothing was changed.")
            if had and len(chosen) < len(had) / 2 and not narrow:
                raise ValueError(f"Not recorded: this would replace {len(had)} chosen frames with {len(chosen)}. "
                                 f"Nothing was changed.")
            if had - chosen:
                write_json_atomic(decision_path(self.cull, "selects.prev.json"), sorted(had))
        write_json_atomic(out, sorted(chosen))
        return len(chosen)

    def remember_exports(self) -> int:
        """Write down the frames he has exported, the moment he finishes the
        shoot (learned.EXPORTS_KEPT). They are what the shoot teaches: "only
        train based on what i've exported. i tend to cull further during
        editing." Found afresh they can go out of reach - an export folder
        moved, a drive unplugged - and the shoot would teach less than he
        delivered. The record only grows: an export he makes
        later joins it, and one that goes missing is still one he delivered.
        Written even when nothing exported is found, as an empty record.
        Beside it a finished shoot teaches the exports the learning store
        recorded when it measured them (learned.taught), and nothing more:
        never every frame he kept, which is what a shoot finished with its
        exports out of reach once taught.
        The answer key is not touched here; every check still measures
        against it (remember_selects). A record that cannot be read is left
        exactly as it is, and nothing is added to it."""
        import learned
        with _DECIDE_LOCK:
            rows = self.rows()
            by_stem = {Path(r["file"]).stem: r["file"] for r in rows}
            now = {by_stem[s] for s in self.exported() if s in by_stem}
            out = decision_path(self.cull, learned.EXPORTS_KEPT)
            try:
                had = json.loads(out.read_text()) if out.exists() else []
            except (OSError, ValueError):
                return 0
            if not isinstance(had, list):
                return 0
            keep = sorted(set(had) | now)
            if keep != sorted(had) or not out.exists():
                out.parent.mkdir(parents=True, exist_ok=True)
                write_json_atomic(out, keep)
            return len(keep)

    def stamp(self) -> tuple:
        """When each tier of derivatives last gained or lost a file.

        dims() was keyed on cull.csv alone, and a decode minted by /full/ or
        /crop/ does not touch cull.csv. So a shoot whose cache had been
        reclaimed went on serving rows with no dw/dh however many frames the
        viewer had since decoded back, and the loupe could not size its crop
        from the row - the one place the row's decoded size is load-bearing.
        A directory's mtime moves when a name is added to it or taken out of
        it, which is exactly what reclaim.py and the viewer do to these three.
        Nanoseconds, because a re-cull inside the same second as the last one
        is a real thing and a whole-second mtime does not notice it."""
        out = []
        for folder in ("thumbs", "large", "decoded"):
            try:
                out.append((self.cull / folder).stat().st_mtime_ns)
            except OSError:
                out.append(0)
        return tuple(out)

    def dims(self) -> dict:
        """The real pixel size of each derivative on disk, per frame.

        The grid used to declare `427w` and `961w` for every frame of every
        shoot. Neither is reliably true: one shoot culled twice holds thumbs at
        480x320, 320x480, 640x427 and 427x640 at once, and a shoot with no
        cull/large/ is served its 480 px thumb under a 961w descriptor. A
        descriptor that lies is worse than none, because the browser believes
        it. Header-only reads, about 0.3 s for a 1157-frame shoot, then a dict.
        """
        csv_p = self.cull / "cull.csv"
        try:
            key = (self.folder.name, csv_p.stat().st_mtime_ns) + self.stamp()
        except OSError:
            return {}
        if key in _DIMS:
            return _DIMS[key]
        from PIL import Image
        out: dict[str, dict] = {}
        for tier, folder in (("t", "thumbs"), ("l", "large"), ("d", "decoded")):
            d = self.cull / folder
            if not d.is_dir():
                continue
            for q in d.glob("*.jpg"):
                try:
                    with Image.open(q) as im:
                        w, h = im.size
                except Exception:  # noqa: BLE001
                    continue       # one unreadable derivative is not a failed page
                out.setdefault(q.stem, {})[tier] = [w, h]
        # A re-cull writes cull.csv, so its old sizes go with it. Other shoots
        # keep theirs: the front page asks every shoot for its rows at once.
        # Over a snapshot and with pop, because the page is served by a
        # threading server: opening a shoot while the front page is still
        # asking runs this twice at once, and a comprehension straight over the
        # live dict raised "dictionary changed size during iteration" while the
        # second del raised KeyError - both of them a 500 on /api/shoot for a
        # cache that should never be able to fail a request.
        for k in list(_DIMS):
            if k[0] == key[0]:
                _DIMS.pop(k, None)
        _DIMS[key] = out
        return out

    def presets(self) -> list[dict]:
        p = self.cull / "presets.json"
        try:
            return json.loads(p.read_text()) if p.exists() else []
        except Exception:  # noqa: BLE001
            return []


def _refused_copy(folder: Path) -> bool:
    """Whether this shoot folder is only what a refused copy left behind.

    A copy that was never going to happen - a card with nothing on it, a full
    disk - still had its log opened here, and the log's folder with it, so the
    next attempt at the same name was told "<name> already exists" about a
    folder holding one empty log. ingest.py creates nothing until the run is
    going to happen; this is the other half. Anything else at all in there -
    one frame, one decision, a folder somebody made - and the answer is that
    the shoot exists, because a name is not worth a photograph."""
    try:
        for p in folder.rglob("*"):
            if p.is_dir():
                continue
            rel = p.relative_to(folder).as_posix()
            if rel == "shoot.json" or (rel.startswith("cull/logs/") and rel.endswith(".log")):
                continue
            return False
    except OSError:
        return False
    return True


def _presets_ran(s: "Shoot", presets: list[dict]) -> dict | None:
    """What the last presets run did: sidecars it wrote, frames he had changed
    in PhotoLab that it left exactly as they were, and frames that already
    carried a sidecar and were not asked to be refreshed - three counts that
    add up to the frames it was given - and, of the ones it wrote, how many
    were his own edited sidecars given the new starting edit under his changes
    (`under`, which only Write Them Again does). The page counted the sidecars
    lying on the disk, and said "12 presets written onto 368 files" after a
    run that wrote none.

    Read off the run's own log, where presets.py already says it for him - a
    look's line ends "; 12 sidecars", and "30 of 42 frames already carry a
    sidecar" is what it skipped - and off the left_alone list presets.json has
    always carried. presets.json is not asked to say more: what presets.py
    writes is not the page's to change. DxO only, the one editor whose run
    says what it skipped. None whenever the log cannot be the run that wrote
    presets.json - no log, a run that did not reach its end, a look it does not
    name, or a cull that has written the presets since - so the page says what
    is on the disk instead."""
    if not presets:
        return None
    log = _kind_log(s, "presets")
    try:
        # The log is written to until the process exits; presets.json a moment
        # before. A cull that wrote the presets since left this log behind.
        if log.stat().st_mtime + 5 < (s.cull / "presets.json").stat().st_mtime:
            return None
        txt = log.read_text(errors="replace")
    except OSError:
        return None
    head = txt.split("\n", 1)[0]
    if "presets.py" not in head or re.search(r"--editor (?!dxo\b)", head):
        return None
    if not re.search(r"^@@ presets (\d+) \1$", txt, re.M):
        return None
    wrote = 0
    for p in presets:
        m = re.search(r"^  " + re.escape(str(p.get("name") or "")) + r": .*; (\d+) sidecars?$", txt, re.M)
        if not m:
            return None
        wrote += int(m.group(1))
    skipped = sum(int(n) for n in re.findall(r"^  (\d+) of \d+ frames already carry a sidecar", txt, re.M))
    changed = sum(len(p.get("left_alone") or []) for p in presets)
    under = sum(int(n) for n in re.findall(r"^  (\d+) sidecars? carr(?:y|ies) your own edits", txt, re.M))
    return {"wrote": wrote, "changed": changed, "already": max(0, skipped - changed), "under": under}


def _cull_settings(s: "Shoot") -> tuple[str, float, str]:
    """What the next cull of this shoot runs with: (style, focus, the shoot
    they were taken from, or "" for its own).

    The shoot's own, once a cull of it has been asked for. Before that, what
    his last shoot was culled with - "people move" and the focus he set there
    - rather than 1.9 and normal: nearly every shoot of his is of people
    moving fast, and every new shoot opened on the defaults, so every evening
    he flipped the switch and dragged the slider back, and a cull started
    without doing it ran seven minutes with the wrong settings. The last shoot
    is the newest by the day its name starts with, of the same kind when it
    has one, and what it was culled with is what cull.py recorded once it had
    results (`cull_ran_with`, with the focus he set rather than the floor that
    card's scale moved it to), else what was last asked of it."""
    m = s.meta()
    if m.get("style") or m.get("focus"):
        return _cull_pair(m.get("style"), m.get("focus")) + ("",)
    kind, best, key = m.get("kind"), None, None
    for other in shoots():
        if other.folder.name == s.folder.name:
            continue
        om = other.meta()
        ran = om.get("cull_ran_with") if isinstance(om.get("cull_ran_with"), dict) else {}
        # The focus he set there, not the floor that card's own scale moved
        # it to (cull.record_run): this card's scale moves it for itself.
        style, focus = ((ran.get("style"), ran.get("asked") or ran.get("focus")) if ran
                        else (om.get("style"), om.get("focus")))
        if not (style or focus):
            continue
        day = re.match(r"\d{4}-\d{2}-\d{2}", other.folder.name)
        try:
            when = (other.folder / "shoot.json").stat().st_mtime
        except OSError:
            when = 0.0
        k = (bool(kind) and om.get("kind") == kind, day.group(0) if day else "", when)
        if key is None or k > key:
            best, key = (style, focus, other.folder.name), k
    if best is None:
        return "normal", 1.9, ""
    return _cull_pair(best[0], best[1]) + (best[2],)


def _cull_pair(style, focus) -> tuple[str, float]:
    """A style and a focus the cull can be given, whatever was written."""
    style = style if style in ("normal", "action") else "normal"
    try:
        focus = float(focus or 1.9)
    except (TypeError, ValueError):
        focus = 1.9
    return style, round(min(3.0, max(1.2, focus)), 2)


def _taught(s: "Shoot", exported: set[str]) -> tuple[int, str]:
    """How many frames this shoot teaches the cull from, and where they came
    from (learned.taught), for the Finish page."""
    try:
        import learned
        got, came = learned.taught(s.folder, exported=exported)
    except Exception:  # noqa: BLE001
        return len(exported), "exported" if exported else ""
    return len(got), came


def _recorded_from(recorded: set[str], exported: set[str]) -> str:
    """Where a shoot's recorded keepers came from, in his words, read off the
    record itself rather than off the rule that would apply now: the rule
    changes when a shoot is marked finished, and Finish records before it
    marks, so "the frames you exported" was said of 368 keepers beside 356
    exports. Every recorded frame exported is the frames he exported; some of
    them is those and the ones he kept; none is the ones he kept."""
    return ("the frames you exported" if recorded and recorded <= exported
            else "the frames you exported and the ones you kept" if recorded & exported
            else "the frames you kept")


def _ingest_note(s: "Shoot") -> dict:
    """What the copy actually did, read off the copy's own log.

    The card said "N frames copied and checked" where N was a count of RAW
    files lying in the folder. It said it after --verify none, after a copy
    that died after three files of four hundred, and directly under a red
    verification FAILURE card. None of those three sentences was about the
    copy; all of them were about `ls`. ingest.py prints its own account and
    ends with either "verification FAILED for: ..." or "N files in <dest>,
    <proof>", so that is what is quoted here, and where there is no log the
    card says there is no log rather than inventing the word "checked".

    The whole log, not its last 20,000 characters. ingest.py prints a `@@ copy`
    line per file, so his own 1,157-frame copy writes a 20,208-character log:
    the tail cut the "$ ... ingest.py ..." line Jobs.start puts at the top off
    the front, the check for it failed, and the proof sentence sitting four
    lines further down was never read - the longer the copy, the more certain
    the card was to fall back to a sentence about `ls`. The identifying line is
    read from the head of the FILE, which is where it is, and the result is
    looked for in all of it. The last such sentence wins: a log is one run, but
    a run that retried has said it twice and only the last time is true.

    A copy that is still going is "copying", never "stopped": its log is the
    same log as one that died at 412 of 1,558, with a "copying" line and no
    result, and the sidebar and the card page said "Copy stopped at 412" of a
    copy that was running while he worked on last night's shoot. Only the
    list of work knows which of the two it is, so it is asked first."""
    live = _copy_in_flight(s.folder.name)
    note = _ingest_note_of(s, live)
    # The cards copied into this shoot before the last one, each by its own
    # log (_keep_earlier_copy_log), each with how it ended: a copy that
    # stopped or failed keeps saying so under a later card's "done", so the
    # shoot never reads as copied while one card of it is half there. A copy
    # that stopped and was then finished is the one the last log accounts for.
    earlier = [said for _, said in _earlier_copies(s)]
    if earlier:
        note["earlier"] = earlier
    return note


def _earlier_copies(s: "Shoot") -> list[tuple[Path, dict]]:
    """Each copy log set aside before a later card's copy (ingest-1.log, -2,
    …, oldest first) with what it says, as _copy_log_says reads it."""
    out = []
    for q in _earlier_copy_logs(_kind_log(s, "ingest")):
        txt = _read_copy_log(q)
        if txt is not None:
            out.append((q, _copy_log_says(txt, q)))
    return out


def _earlier_copy_logs(log: Path) -> list[Path]:
    """ingest-1.log, ingest-2.log, … beside `log`, in the order they were
    set aside: by number, so the tenth does not sort before the second."""
    got = []
    for q in log.parent.glob(f"{log.stem}-*{log.suffix}"):
        n = q.name[len(log.stem) + 1:-len(log.suffix)]
        if n.isdigit():
            got.append((int(n), q))
    return [q for _, q in sorted(got)]


def _read_copy_log(q: Path) -> str | None:
    """A copy log's text, or None when it is not one (_ingest_note_of)."""
    try:
        with q.open(errors="replace") as fh:
            head = fh.read(400)
            if "ingest.py" not in head:
                return None
            return head + fh.read(8_000_000)
    except OSError:
        return None


def _copy_log_says(txt: str, q: Path, live: bool = False) -> dict:
    """How one copy's log says it ended: done, failed, stopped or unclear -
    or copying, while the list says it is still going (_ingest_note)."""
    if "verification FAILED" in txt:
        bad = re.search(r"^verification FAILED for: (.+)$", txt, re.M)
        return {"state": "failed", "detail": (bad.group(1) if bad else "")[:200]}
    done = list(re.finditer(r"^(\d+) files in .+?, (.+)$", txt, re.M))
    if done:
        return {"state": "done", "files": int(done[-1].group(1)), "proof": done[-1].group(2)}
    started = re.search(r"^copying (\d+) files", txt, re.M)
    marks = re.findall(r"^@@ copy (\d+) (\d+)$", txt, re.M)
    got = int(marks[-1][0]) if marks else 0
    if live:
        return {"state": "copying", "files": got, "of": int(started.group(1)) if started else 0}
    if started:
        return {"state": "stopped", "files": got, "of": int(started.group(1))}
    # The copy's own log is here and does not say how it ended - killed
    # mid-line, or written by a version that said something else. That is
    # not the same as there being no log, and the card must not fall back
    # to the sentence for a copy made before logging existed.
    return {"state": "unclear", "log": str(q)}


def _ingest_note_of(s: "Shoot", live: bool) -> dict:
    """The last copy's own account, as _ingest_note describes."""
    for q in (_kind_log(s, "ingest"), s.folder / "logs" / "ingest.log",
              s.cull / "studio.log", s.folder / "studio.log"):
        # An old shared studio.log that a cull or a presets run has since
        # written over is not this copy's proof and must not be quoted. It is
        # rejected on its first 400 bytes, so a 40 MB cull log costs 400.
        txt = _read_copy_log(q)
        if txt is not None:
            return _copy_log_says(txt, q, live)
    return {"state": "copying", "files": 0, "of": 0} if live else {}


def _copy_in_flight(shoot: str) -> bool:
    """Whether a card copy into this shoot is running now or waiting on the
    list. False when there is no list, which is a test or the command line."""
    jobs = getattr(Handler, "jobs", None)
    return bool(jobs) and jobs.copying(shoot)


def _joinable(name: str) -> str:
    """Why no card may be copied into this shoot that already exists now, or
    "" when one may: to finish a copy that stopped part way, or to add a
    second camera's card to the same night's shoot. Which card is
    _copy_into's question.

    Until the shoot is culled, and not while its cull runs: the cull reads the
    frames that are there, and bursts and his marks are built on them.
    ingest.py was always written for this - it never overwrites, it skips a
    frame already there byte for byte, and two different frames that share a
    name are both kept - and the studio refused any folder with one frame in
    it, so a card pulled at 412 of 1,558 had to be copied again, whole, under
    a new name, and the half shoot binned by hand."""
    d = shoots_dir() / name
    if not d.is_dir():
        return ""
    s = Shoot(d)
    if s.rows():
        return (f"{name} has been culled, so a card is not added to it now. "
                f"Copy this card into a shoot of its own.")
    jobs = getattr(Handler, "jobs", None)
    if jobs is not None:
        # Read without the lock, as Jobs.copying is: this is asked while the
        # list chooses its next item under the lock (work_build), and the
        # lock does not re-enter.
        proc, kind, shoot = jobs.proc, jobs.kind, jobs.shoot
        if kind == "cull" and shoot == name and proc is not None and proc.poll() is None:
            return (f"{name} is being culled now. Stop its cull to add this card to it, "
                    f"or copy the card into a shoot of its own.")
    return ""


def _unfinished_copy(s: "Shoot") -> dict | None:
    """A copy into this shoot that did not finish, by its own log - stopped,
    failed its check, or ended in a way nothing can read - with that log
    (`log`) and how many photographs its card held (`card_files`, 0 when the
    log does not say). The last copy's first, then any set aside before a
    later card's. None when every copy into it finished or none left a log,
    and while a copy into it is running now: its log reads as stopped until
    it ends, and this is asked again when the next thing's turn comes."""
    jobs = getattr(Handler, "jobs", None)
    if jobs is not None:
        # Without the lock, as _joinable reads it.
        proc, kind, shoot = jobs.proc, jobs.kind, jobs.shoot
        if kind == "ingest" and shoot == s.folder.name and proc is not None and proc.poll() is None:
            return None
    log = _kind_log(s, "ingest")
    for q in [log] + _earlier_copy_logs(log)[::-1]:
        txt = _read_copy_log(q)
        if txt is None:
            continue
        said = _copy_log_says(txt, q)
        if said["state"] != "done":
            n = re.search(r"^copying (\d+) files", txt, re.M)
            return {**said, "log": q, "card_files": int(n.group(1)) if n else 0}
    return None


def _copy_into(name: str, card: str, into: bool) -> Path | None:
    """Whether this card may be copied into the shoot called `name`, and the
    copy log its run may write over: NotNow when it may not.

    A new shoot's run writes its own log, as it always did: a folder holding
    only a refused copy's log is a new shoot (_refused_copy). Into a shoot
    that exists, only when he asked for that (`into`) and _joinable allows it,
    and then:

      - the card whose copy into it did not finish may finish it, and its run
        writes a whole account of the card over that copy's log. That card is
        the one holding frames there (describe_card), the same number of them
        as the unfinished copy's card had when its log says.
      - any other card may not. He added a second camera's card to a shoot
        whose first card was pulled at 412 of 1,558: the first copy's log was
        written over, the shoot read "done", and the cull followed on the half
        of it - after which the first card could not be finished into it,
        and a card he thought copied was one he might format.
      - with every copy into it finished, any card may, and every log already
        there is set aside and kept (_keep_earlier_copy_log): None."""
    d = shoots_dir() / name
    log = d / "cull" / "logs" / "ingest.log"
    if not d.exists() or _refused_copy(d):
        return log
    if not into:
        raise NotNow(f"{name} already exists")
    why = _joinable(name)
    if why:
        raise NotNow(why)
    s = Shoot(d)
    left = _unfinished_copy(s)
    if left is None:
        return None
    if card:
        here = describe_card(card, [s])
        if here["held"] > 0 and (not left["card_files"] or here["photographs"] == left["card_files"]):
            return left["log"]
    raise NotNow(f"The copy of another card into {name} did not finish. Put that card back to finish it, "
                 f"or copy this one into a shoot of its own.")


def _keep_earlier_copy_log(log: Path, over: Path | None = None) -> None:
    """Before a copy into a shoot, every copy log already there keeps its
    record, set aside beside it as ingest-1.log (-2, …), except the one this
    run is allowed to write over (`over`, _copy_into): a new shoot's own, or
    the log of the copy this run finishes, which is put in the last copy's
    place first. Each is a card's only proof - of a copy that finished, or of
    one that did not and must go on saying so. A file there that is not a
    copy's log is written over, as it always was."""
    try:
        same = over is not None and over.resolve() == log.resolve()
    except OSError:
        same = False
    if log.exists() and not same and _read_copy_log(log) is not None:
        n = 1
        while (log.with_name(f"{log.stem}-{n}{log.suffix}")).exists():
            n += 1
        try:
            os.replace(log, log.with_name(f"{log.stem}-{n}{log.suffix}"))
        except OSError:
            pass
    if over is not None and not same and over.exists():
        try:
            os.replace(over, log)
        except OSError:
            pass


class Jobs:
    """One subprocess at a time, with its log on disk so a reload does not lose it.

    And a queue behind it, asked for by name. A second job used to be refused
    with "a job is already running", which left the app to remember it and try
    again; now a request that says queue: true is given an id and started when
    the one in front of it ends, and GET /api/job says there is one waiting.
    Ids count up from 1 for as long as this server runs, and a job keeps the id
    it was given when it was asked for."""

    def __init__(self, store: Path | None = None):
        self.proc: subprocess.Popen | None = None
        self.log: Path | None = None
        self.title = ""
        self.kind = ""
        self.shoot = ""
        self.why = ""                 # what this job was started for, in his words
        self.started = 0.0
        self.took = 0
        self.stopped = False
        self.lock = threading.Lock()
        self.id = 0                   # the job running now, or the last one
        self._ids = 0
        self.queue: list[dict] = []
        # The id of a background job stood down to make room for his work.
        # _watch reads it: a job that was stood down must NOT be started again
        # the instant it dies, or it takes the slot back before the work it
        # made room for can claim it.
        self._stood_down = 0
        # This run of the engine, so the history can tell the jobs of an
        # earlier run - read back from disk - from this one's, which the app
        # follows itself. "<time>-<pid>-<nonce>": the pid says which process
        # wrote a running job's note (`_engine_up`), and the nonce keeps two
        # runs apart that share a second and a process - an engine that
        # restarts itself in place keeps its pid.
        self.run = f"{int(time.time())}-{os.getpid()}-{secrets.token_hex(3)}"
        # And not the instant HIS job ends either. He is in the middle of
        # something: a plan is drawn, he reads it, he presses apply. Picking
        # the homework back up in the gap means standing it down again two
        # seconds later, and each round trip throws away the minutes it spent
        # gathering and measuring. "When the machine is next idle" means
        # idle, so it waits for a quiet stretch.
        self._quiet_until = 0.0
        self._pickup: threading.Timer | None = None
        # The list, and whether he has held it. Paused stops the NEXT item
        # starting; it never touches the one already running, because a cull
        # halfway through is work, not a plan.
        self.held = False
        # Why the list is held when it was not his Hold that held it: he
        # pressed Stop with work waiting, or the engine stopped under a job
        # (see stop() and load()). The job it was about, so the list can say
        # "Held because you stopped Cull · 2026-09-19". None when he held it
        # himself, or it is not held.
        self.held_after: dict | None = None
        # The job this engine found cut off by the crash of the last one and
        # put back (`_cut_off`), for the line that says the engine restarted.
        # This run's only: it is not written down.
        self.cut_off: dict | None = None
        # Whether the job running now came off the list, so the bar for the
        # whole list counts it and a job he started by hand does not.
        self.from_list = False
        self.cur: dict | None = None
        # Where the list is written down. His intent survives a quit.
        self._store = store
        self._loaded = False
        # What this pass through the list has done and what it had to skip,
        # and a number that changes when a new pass starts - so the app can
        # tell him once, at the end, rather than once a job.
        self.pass_no = 0
        self.done: list[dict] = []
        self.skipped: list[dict] = []
        self.asked = 0                # how many were put on the list this pass
        # Whether each waiting item could still be done, and when that was
        # last asked. /api/job is polled every 1.2 s and the answer costs a
        # look at a folder per item; a couple of seconds old is fresh enough
        # for a row on a screen, and the reading that decides anything is the
        # one _take_next does with nothing cached at all.
        self._checked: dict[int, tuple[float, bool, str, str]] = {}
        # What to do once a job has ended well, by the job's id: the cull a
        # card copy asked to be followed by (_follow_with_a_cull). Only ever
        # run for a job that finished; a copy that stopped, failed or was
        # refused is followed by nothing.
        self._after_done: dict[int, object] = {}

    def _new_id(self) -> int:
        self._ids += 1
        return self._ids

    # ---------------------------------------------------- the list on disk

    def store(self) -> Path:
        """Where the list lives. The app's support folder, never the library:
        it is a thing the app remembers, not a thing in his photographs."""
        if self._store is not None:
            return self._store
        sup = os.environ.get("PIPELINE_SUPPORT")
        return (Path(sup).expanduser() if sup else ROOT) / "queue.json"

    def running_store(self) -> Path:
        """Where the job running now is written down, beside the list, until it
        ends. Found at the next start only when this process went away
        without seeing it end: a crash, not a quit (see load() and quit())."""
        return self.store().parent / "running.json"

    def _mark_running(self, rec: dict) -> None:
        """The caller holds the lock. Never the reason a job does not start."""
        try:
            write_json_atomic(self.running_store(), rec)
        except OSError as e:
            print(f"  (could not write down the job that is running: {e})", flush=True)

    def _unmark_running(self, jid: int | None = None) -> None:
        """Forget the running job's note - only its own, when `jid` says whose."""
        p = self.running_store()
        try:
            if jid is not None and int((json.loads(p.read_text()) or {}).get("id") or 0) != jid:
                return
        except (OSError, ValueError, TypeError, AttributeError):
            pass
        try:
            p.unlink()
        except FileNotFoundError:
            pass
        except OSError as e:
            print(f"  (could not forget the job that ran: {e})", flush=True)

    def history_store(self) -> Path:
        """Where the history of finished work is kept, beside the list."""
        return self.store().parent / "jobs.jsonl"

    def _remember(self, rec: dict) -> None:
        """Write one finished job down, a line of its own. Never the reason
        anything else fails: a history that cannot be written is a history
        that is short a row."""
        try:
            p = self.history_store()
            p.parent.mkdir(parents=True, exist_ok=True)
            with open(p, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(rec) + "\n")
        except OSError as e:
            print(f"  (could not write down the job that ended: {e})", flush=True)

    def history(self, days: float = HISTORY_DAYS) -> list[dict]:
        """The finished work of the last few days, oldest first, every run of
        the engine's - so last night's list can be read in the morning."""
        cutoff = time.time() - days * 86400
        try:
            lines = self.history_store().read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            return []
        out = []
        for line in lines:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if isinstance(r, dict) and float(r.get("ended") or 0) >= cutoff:
                out.append(r)
        return out[-HISTORY_MAX:]

    def _prune_history(self) -> None:
        """Keep only what `history` would read, so the file does not grow for
        the rest of his working life."""
        p = self.history_store()
        if not p.exists():
            return
        keep = self.history()
        try:
            write_atomic(p, "".join(json.dumps(r) + "\n" for r in keep))
        except OSError as e:
            print(f"  (could not trim the history: {e})", flush=True)

    def _save(self) -> None:
        """The caller holds the lock. Only the items that describe themselves
        are written: an extension's job carries a command this process built
        and nothing to rebuild it from, so it is honestly not kept."""
        keep = [{"id": q["id"], "kind": q["kind"], "shoot": q["shoot"], "opts": q.get("opts") or {},
                 "title": q["title"], "does": q.get("does", ""),
                 **({"interrupted": True} if q.get("interrupted") else {})}
                for q in self.queue if q.get("keeps")]
        try:
            write_json_atomic(self.store(), {"ids": self._ids, "held": self.held,
                                             "held_after": self.held_after, "queue": keep})
        except OSError as e:
            print(f"  (the list could not be written to {self.store()}: {e})", flush=True)

    def load(self) -> None:
        """Read the list back after a restart.

        Nothing is checked here. An item is checked the moment before it
        starts and not a second earlier, because that is the only reading that
        is about the shoot as it is - and an item read back at nine in the
        morning against a card that will be plugged in at ten is not stale, it
        is waiting.

        One thing IS looked at: a job the last engine was running when it
        went away without seeing it end (`_cut_off`)."""
        if self._loaded:
            return
        self._loaded = True
        # A list that was never written down, or cannot be read, is an empty
        # one - and the job a crash cut off is still looked for.
        try:
            d = json.loads(self.store().read_text())
        except (OSError, ValueError):
            d = {}
        if not isinstance(d, dict):
            d = {}
        with self.lock:
            self._ids = max(self._ids, int(d.get("ids") or 0))
            self.held = bool(d.get("held"))
            after = d.get("held_after")
            self.held_after = after if self.held and isinstance(after, dict) else None
            for q in d.get("queue") or []:
                if not isinstance(q, dict) or q.get("kind") not in WORK:
                    continue
                self.queue.append({"id": int(q.get("id") or self._new_id()), "kind": q["kind"],
                                   "title": q.get("title") or q["kind"], "shoot": q.get("shoot") or "",
                                   "does": q.get("does") or "", "opts": q.get("opts") or {},
                                   "cmd": None, "log": None, "then": None, "keeps": True, "why": "",
                                   "interrupted": bool(q.get("interrupted"))})
        # Then the job the last engine was running when it went away without
        # seeing it end, if there was one; and the history, trimmed.
        self._cut_off()
        self._prune_history()
        with self.lock:
            if self.queue:
                self.asked = len(self.queue)
                self.pass_no = self.pass_no or 1

    def _cut_off(self) -> None:
        """The job the last engine was running when it crashed.

        It was started in a session of its own so Stop reaches its children,
        which also means it outlives an engine that dies under it - and the
        engine that comes up resumed the list on top of it, two heavy jobs at
        once, while the page offered Cull It again for a cull that was still
        writing. So it is put down first, the whole group, and only if it is
        still the same process. Then, when it is work the list can rebuild,
        it goes back at the top of the list, marked, and the list is held:
        he walked away from it and it is his to start again, not the
        machine's to rerun unasked. What cannot be rebuilt - an extension's
        own work, an update, the machine's homework - is not put back; the
        homework asks for itself again anyway.

        Not while the engine that wrote the note is still up (`_engine_up`):
        its job is running as it should. And a job that was not running any
        more ended by itself while nobody watched - the engine went down and
        was started again only later - so it is written down as it ended, off
        the line its shell wrote (`ended_unwatched`), and a cull that finished
        is not offered to him to run again. Only one with no such line, which
        the Mac went down under, was cut off."""
        p = self.running_store()
        try:
            rec = json.loads(p.read_text())
        except FileNotFoundError:
            return
        except (OSError, ValueError):
            rec = None
        if not isinstance(rec, dict):
            self._unmark_running()
            return
        if _engine_up(str(rec.get("run") or "")):
            return
        stopped = _put_down(int(rec.get("pid") or 0), str(rec.get("script") or ""))
        kind, shoot = str(rec.get("kind") or ""), str(rec.get("shoot") or "")
        title = str(rec.get("title") or "")
        # In the history as what it was: a job the engine went away under.
        # How long it ran is as far as its log was written.
        log = Path(str(rec.get("log") or "")) if rec.get("log") else None
        started = float(rec.get("started") or 0)
        try:
            last = log.stat().st_mtime if log else started
        except OSError:
            last = started
        row = {"run": str(rec.get("run") or ""), "id": int(rec.get("id") or 0), "kind": kind,
               "title": title, "shoot": shoot, "why": "",
               "background": kind in BACKGROUND_KINDS, "from_list": bool(rec.get("from_list")),
               "started": started, "ended": time.time(),
               "elapsed": max(0, int(last - started)) if started else 0}
        ended = None if stopped else ended_unwatched(log)
        if ended is not None:
            self._remember({**row, "ended": max(last, started), "outcome": ended[0], "code": ended[1],
                            "log": readable_log(log)})
            self._unmark_running()
            return
        # A card copy goes back as the copy that finishes into the same shoot
        # (`into`, _copy_into): with the card back in, only what did not reach
        # the shoot is copied, and what did is left exactly as it is. It went
        # back as a copy into a new shoot, which a shoot holding a frame
        # refuses, so it could only ever say it cannot run. Where it stopped
        # is said as well, in the history and on the list.
        copy = copy_stopped_at(log) if kind == "ingest" else None
        stopped_at = (f"The copy stopped at {copy[0]:,} of {copy[1]:,} frames."
                      if copy and copy[1] else "")
        self._remember({**row, "outcome": "failed", "code": None,
                        "log": "\n".join(x for x in (readable_log(log), ENGINE_WENT_AWAY, stopped_at) if x)})
        with self.lock:
            if rec.get("keeps") and kind in WORK and kind not in BACKGROUND_KINDS:
                self._ids = max(self._ids, int(rec.get("id") or 0))
                named = {"why": "crashed", "kind": kind, "title": title, "shoot": shoot}
                opts = dict(rec.get("opts") or {})
                if copy is not None:
                    opts["into"] = True
                    named = {**named, "files": copy[0], "of": copy[1]}
                self.queue.insert(0, {"id": self._new_id(), "kind": kind, "title": title or kind,
                                      "shoot": shoot, "does": str(rec.get("does") or ""),
                                      "opts": opts, "cmd": None, "log": None,
                                      "then": None, "keeps": True, "why": "", "interrupted": True})
                self.cut_off = dict(named)
                if self.queue:
                    self.held = True
                    self.held_after = named
                self._save()
        self._unmark_running()

    def quit(self) -> None:
        """This engine is going away on purpose: he quit, or the library
        changed. What is running stops where it is - the quit alert says so,
        and that it can be started again - and it is not a job cut off by a
        crash, so its note goes first, before anything can be slow."""
        with self.lock:
            p = self.proc
            self._unmark_running()
            if not p or p.poll() is not None:
                return
            self.stopped = True
            _ask_to_stop(p)

    # ------------------------------------------------- filling it and ordering it

    def add(self, kind: str, shoot: str, opts: dict, why: str = "") -> dict:
        """Put one piece of work on the list.

        It is built once here, so nothing that cannot be done is ever put on
        it, and built again when its turn comes. NotNow from either is the
        same sentence in the same words; this one refuses the tap, that one
        writes the line he reads afterwards."""
        made = work_build(kind, shoot, opts)      # raises NotNow
        item = {"id": 0, "kind": kind, "shoot": shoot, "opts": dict(opts or {}),
                "title": made["title"], "does": made.get("does", ""),
                "cmd": None, "log": None, "then": None, "keeps": True, "why": why}
        with self.lock:
            item["id"] = self._new_id()
            if not self.queue and not (self.proc and self.proc.poll() is None):
                self.pass_no += 1
                self.done, self.skipped, self.asked = [], [], 0
            self.queue.append(item)
            self.asked += 1
            self._save()
            # The slot counts as free when what is in it is the machine's own
            # homework: _take_next stands that down rather than waiting on it.
            busy = (self.proc is not None and self.proc.poll() is None
                    and self.kind not in BACKGROUND_KINDS)
            go = not self.held and not busy
        if go:
            self._take_next()
        return self.describe(item)

    def start_list(self) -> None:
        """Get a list that was read back off disk moving again."""
        self._take_next()

    def stand_down(self) -> dict:
        """Put the machine's homework down and ask for it again.

        A seam, so `_take_next` can do what every route he can press does
        without Jobs having to know about learned.py. `make_room_for` sets it
        at import; without it this is make_room alone, which is still correct
        and only loses the note."""
        return Jobs.homework_aside(self)

    # Set below, beside make_room_for: stand the homework down AND write down
    # that it still wants to run.
    homework_aside = staticmethod(lambda jobs: jobs.make_room() or {})

    def reorder(self, ids: list) -> bool:
        """His order, in one move. Ids he did not name keep their places at the
        end, in the order they were in: a drag names what moved, not the whole
        list, and an item added while he was dragging must not vanish."""
        want = [i for i in ids if isinstance(i, int)]
        with self.lock:
            by_id = {q["id"]: q for q in self.queue}
            new = [by_id[i] for i in dict.fromkeys(want) if i in by_id]
            new += [q for q in self.queue if q["id"] not in set(want)]
            if len(new) != len(self.queue):
                return False
            self.queue = new
            self._save()
        return True

    def clear(self) -> int:
        """Take the whole list down. What is running is not on it and is not
        touched: stopping a cull is a different button, and it says so."""
        with self.lock:
            n = len(self.queue)
            for q in self.queue:
                self._checked.pop(q["id"], None)
            self.queue = []
            self.asked = max(0, self.asked - n)
            self._forget_an_empty_hold()
            self._save()
        return n

    def _forget_an_empty_hold(self) -> None:
        """The caller holds the lock. A hold his Stop or a crash made is about
        the work that was waiting; once none is, it goes, with its line, so the
        next thing he adds starts - a Stop over an empty list holds nothing,
        and neither does a list he has since emptied. A hold he pressed
        himself (`held_after` None) is his, and stays."""
        if not self.queue and self.held_after is not None:
            self.held = False
            self.held_after = None

    def hold(self, held: bool) -> bool:
        """Hold the list, or let it go again. Held stops the next one starting.

        An empty list can be held too: that is how he lines up an evening
        while he is still culling and has none of it start until he leaves.
        His own Hold or Continue says why it is held from now on, so the
        line about the Stop that held it goes."""
        with self.lock:
            self.held = bool(held)
            self.held_after = None
            self._save()
            go = not self.held and bool(self.queue) and not (self.proc and self.proc.poll() is None)
        if go:
            self._take_next()
        return self.held

    def describe(self, q: dict) -> dict:
        """One item as the app draws it: what it is, whose shoot it is about,
        what it will do, and whether it could still be done if its turn came
        now. The last one is asked freshly every time this is read, which is
        what puts "that card is not in this Mac any more" in his list before
        he walks away rather than after."""
        # What it was asked for with, as it was asked: a page that shows the
        # settings a waiting cull will run with shows these, and not its own,
        # which a relaunch reads back from the last cull started.
        out = {"id": q["id"], "kind": q["kind"], "title": q["title"], "shoot": q["shoot"],
               "does": q.get("does", ""), "why": q.get("why", ""), "kept": bool(q.get("keeps")),
               "opts": dict(q.get("opts") or {}), "interrupted": bool(q.get("interrupted"))}
        if not q.get("keeps"):
            return {**out, "ready": True, "why_not": ""}
        was = self._checked.get(q["id"])
        if was and time.time() - was[0] < 2.5:
            return {**out, "ready": was[1], "why_not": was[2], "does": was[3] or out["does"]}
        try:
            made = work_build(q["kind"], q["shoot"], q.get("opts") or {})
            ready, why_not, does = True, "", made.get("does") or out["does"]
        except NotNow as e:
            ready, why_not, does = False, str(e), out["does"]
        except Exception as e:      # noqa: BLE001
            ready, why_not, does = False, _refusal(e), out["does"]
        self._checked[q["id"]] = (time.time(), ready, why_not, does)
        return {**out, "ready": ready, "why_not": why_not, "does": does}

    def start(self, kind: str, title: str, cmd: list[str], log: Path, shoot: str = "",
              why: str = "", after_done=None, over: Path | None = None,
              opts: dict | None = None) -> bool:
        """Start it now, or say no while something is running. `over` is, for
        a card copy, the one copy log already there it may write over
        (_copy_into); every other is kept. `opts` are what it was asked for
        with, for one of the list's own kinds, so a crash under it can put it
        back."""
        with self.lock:
            if self.proc and self.proc.poll() is None:
                return False
            self._start(kind, title, cmd, log, shoot, self._new_id(), why, over=over, opts=opts)
            # Under the same lock as the start, so a job that ends at once is
            # not over before it is told what follows it.
            if after_done:
                self._after_done[self.id] = after_done
            return True

    def enqueue(self, kind: str, title: str, cmd: list[str], log: Path, shoot: str = "", then=None,
                why: str = "") -> tuple[int, bool]:
        """Start it now if the slot is free, else put it in line. (id, started).
        `then` runs once the job has actually been started, for what a handler
        records beside a job it started (the card a copy came from).

        The command is frozen here rather than described, which is right for an
        extension's own work - this process built it and there is nothing to
        rebuild it from - and is why such an item is not written to disk. Every
        kind in WORK goes through add() instead and is kept."""
        with self.lock:
            jid = self._new_id()
            if not (self.proc and self.proc.poll() is None) and not self.queue and not self.held:
                self._start(kind, title, cmd, log, shoot, jid, why)
                started = True
            else:
                self.queue.append({"id": jid, "kind": kind, "title": title, "cmd": cmd, "log": log,
                                   "shoot": shoot, "then": then, "why": why, "opts": {},
                                   "does": "", "keeps": False})
                self.asked += 1
                return jid, False
        if then:
            then()
        return jid, started

    def _take_next(self) -> None:
        """Start the next thing on the list.

        Every item is built again here, at the moment before it would start,
        and an item that cannot be done any more is skipped and written down
        with the reason. That is the whole difference between a list and a
        script: he filled this an hour ago, and in that hour the card came
        out, the shoot was culled again, the exports moved. Skipping in
        silence would be the old refusal wearing a nicer coat - it goes into
        `skipped`, and the app reads it back to him when the list empties.

        Never called with the lock held: it starts a process, and it may have
        to stand the machine's homework down first."""
        while True:
            # A background job is never the reason a list of HIS waits. The
            # learning run holds nothing he is waiting for, nothing it has
            # learned is used until it has been checked against every
            # photograph he kept, and the ask is written back down - so it
            # gets out of the way here exactly as it does on every route he
            # can press. Outside the lock, because make_room waits on a
            # process.
            with self.lock:
                in_the_way = (bool(self.queue) and not self.held and self.proc is not None
                              and self.proc.poll() is None and self.kind in BACKGROUND_KINDS)
            if in_the_way:
                self.stand_down()
            with self.lock:
                if self.held or not self.queue or (self.proc and self.proc.poll() is None):
                    return
                q = self.queue[0]
                try:
                    made = ({"title": q["title"], "cmd": q["cmd"], "log": q["log"], "then": q.get("then")}
                            if q.get("cmd") else work_build(q["kind"], q["shoot"], q.get("opts") or {}))
                except NotNow as e:
                    why_not = str(e)
                    made = None
                except Exception as e:      # noqa: BLE001
                    why_not = _refusal(e)
                    made = None
                self.queue.pop(0)
                if made is None:
                    self.skipped.append({"id": q["id"], "kind": q["kind"], "title": q["title"],
                                         "shoot": q["shoot"], "why_not": why_not})
                    self._save()
                    continue
                self._start(q["kind"], made["title"], made["cmd"], Path(made["log"]), q["shoot"],
                            q["id"], q.get("why", ""), from_list=True, over=made.get("over"),
                            opts=q.get("opts") if q.get("keeps") else None, does=made.get("does", ""))
                if made.get("after_done"):
                    self._after_done[q["id"]] = made["after_done"]
                self._save()
                then = made.get("then")
            if then:
                try:
                    then()
                except Exception as e:      # noqa: BLE001
                    print(f"  (after starting job {q['id']}: {e})", flush=True)
            return

    def make_room(self) -> dict | None:
        """Stand the machine's homework down so his own work can start now.

        Learning is a background job (BACKGROUND_KINDS): it holds nothing he is
        waiting for and nothing it produces is used until it has been checked
        against every photograph he kept, so stopping it costs only the time
        already spent, and it is asked for again the moment the slot is free.
        He pressed a button; the machine's homework gets out of the way.

        Returns what was stood down - kind, title, why and how far it had got -
        so the caller can ask for it again and tell him in one line. None when
        nothing was running, or when what was running is his.

        SIGTERM to the group and then a wait, exactly as stop() does and for
        the same reason: learned.py writes files, and the caller is about to
        claim a slot that has to be genuinely free when it does."""
        # Read it before the lock: status() takes the lock itself for the
        # queue, and it is how far along it got that is worth telling him.
        st = self.status()
        if not st["running"] or st["kind"] not in BACKGROUND_KINDS:
            return None
        with self.lock:
            p = self.proc
            if not p or p.poll() is not None or self.id != st["id"]:
                return None
            if self.kind not in BACKGROUND_KINDS:
                return None
            stood = {"kind": self.kind, "title": self.title, "why": self.why, "id": self.id,
                     "shoot": self.shoot, "label": st["label"], "fraction": st["fraction"],
                     "elapsed": st["elapsed"]}
            self._stood_down = self.id
            self._quiet_until = time.time() + LEARN_RESUME_QUIET
            self.stopped = True
            _ask_to_stop(p)
        # Outside the lock: _watch is waiting on this same process and takes
        # the lock the moment it ends.
        try:
            p.wait(timeout=20)
        except subprocess.TimeoutExpired:
            # It would not put itself down. His work is not going to wait on
            # the machine's homework refusing to stop.
            try:
                os.killpg(os.getpgid(p.pid), signal.SIGKILL)
            except (ProcessLookupError, PermissionError, OSError):
                p.kill()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        return stood

    def busy(self, wanted: str = "", can_queue: bool = True) -> dict:
        """Why what he just pressed cannot start, in enough detail to decide.

        Never the bare sentence "a job is already running", which names
        nothing, says nothing about how far along it is or when it will end,
        and offers him nothing to do about it. This names the job, says where
        it has got to and roughly how long is left, and carries the facts the
        app needs to offer him the two real choices: wait (queue it, with the
        id and a cancel), or stop the one in front.

        `can_queue` is False where waiting would be dishonest. An apply is the
        one case: its token is the list he was shown, checked against the
        shoot as it is NOW, and a confirmation held in a queue for five
        minutes is a confirmation of something nobody measured. So that button
        is not offered there, rather than offered and then refused."""
        st = self.status()
        mine = st["title"] or st["kind"] or "something"
        where = st["label"] or st["stage"]
        left = about_how_long(st.get("remaining"))
        detail = mine + (f" — {where}" if where else "")
        detail += f", {left}" if left else ""
        line = (f"{wanted[:1].upper()}{wanted[1:]} has to wait: {detail}." if wanted
                else f"{detail[:1].upper()}{detail[1:]}.")
        return {"error": line,
                "busy": {"id": st["id"], "kind": st["kind"], "title": st["title"],
                         "shoot": st["shoot"], "stage": st["stage"], "label": st["label"],
                         "fraction": st["fraction"], "elapsed": st["elapsed"],
                         "remaining": st.get("remaining"), "remaining_text": left,
                         "background": st["background"], "can_queue": can_queue,
                         "wanted": wanted}}

    def cancel(self, jid: int) -> bool:
        """Take a job out of the line before it starts. True if it was there."""
        with self.lock:
            for i, q in enumerate(self.queue):
                if q["id"] == jid:
                    del self.queue[i]
                    # It was never part of this stretch of work. Leaving it in
                    # the count held the bar for the whole list at four fifths
                    # for ever, which reads as a list that never finished.
                    self.asked = max(0, self.asked - 1)
                    self._checked.pop(jid, None)
                    self._forget_an_empty_hold()
                    self._save()
                    return True
        return False

    def _watch(self, proc: subprocess.Popen, jid: int = 0, cur: dict | None = None) -> None:
        """Wait for this job, then start the next one on the list."""
        proc.wait()
        # Read before the lock is taken: it is a file, and the slot is not
        # held still for it.
        how = ended_as(proc.returncode, (cur or {}).get("log"))
        with self.lock:
            self._unmark_running(jid)
            follow = self._after_done.pop(jid, None)
            ended_well = how == "done" and not (self.proc is proc and self.stopped)
        # Before the list is looked at, so what follows goes on it now and
        # takes its turn: after a card copy, the cull of that shoot, behind
        # anything he had already put there. Outside the lock: it adds to the
        # list, which may start it.
        if follow and ended_well:
            try:
                follow()
            except Exception as e:  # noqa: BLE001
                print(f"  (after job {jid}: {_refusal(e)})", flush=True)
        with self.lock:
            mine = self.proc is proc
            ended = "stopped" if (mine and self.stopped) else how
            # Written down against the job's OWN record and not against
            # whatever holds the slot by the time this wakes up: the two are
            # the same today and were not worth being wrong about.
            if cur is not None and cur.get("from_list") and not cur.get("recorded"):
                cur["recorded"] = True
                cur["outcome"] = "stopped" if (mine and self.stopped) else how
                self.done.append({k: cur[k] for k in ("id", "kind", "title", "shoot", "outcome")})
            stood_down = self._stood_down == jid and jid != 0
            has_next = mine and bool(self.queue) and not self.held
        if cur is not None:
            # Into the history that outlives this engine, so last night's
            # list can be read in the morning. Written before the next piece
            # starts, so the order on disk is the order it ran.
            now = time.time()
            started = float(cur.get("started") or now)
            self._remember({"run": self.run, "id": jid, "kind": cur.get("kind", ""),
                            "title": cur.get("title", ""), "shoot": cur.get("shoot", ""),
                            "why": cur.get("why", ""), "background": cur.get("kind") in BACKGROUND_KINDS,
                            "from_list": bool(cur.get("from_list")), "started": round(started, 3),
                            "ended": round(now, 3), "elapsed": max(0, int(now - started)),
                            "outcome": ended, "code": proc.returncode,
                            "log": readable_log(cur.get("log"))})
        if has_next:
            self._take_next()
            return
        if not stood_down:
            # The learning run a finished shoot asked for while something else
            # held the slot, or one his work stood down. learned.py keeps that
            # ask on disk; this is the moment the slot is free.
            #
            # Not when THIS job was stood down to make room (make_room): the
            # caller is claiming the slot in the same breath, and starting the
            # homework again here would take it back from under him - which is
            # the whole thing this is meant to stop.
            self._pick_up_learning()

    def _pick_up_learning(self) -> None:
        """Start the learning again, once the machine has actually gone quiet.

        The ask itself is on disk (learned.request_run), so it survives a
        restart of this server and a run that was stood down mid-way. All this
        decides is when: not while anything is running, and not inside the
        quiet stretch after his work pushed it aside, because he is usually
        still working then.

        And what Settings ▸ Learning says (`LEARN_PREFS`). With "Learn from
        finished shoots automatically" off, a finished shoot's ask is not
        picked up - it is taken back, so the page does not say a run is
        waiting - while his own Learn Now, stood down for his work, still
        is. With "Only when the Mac is idle" on, it waits for two minutes with
        no key pressed and the pointer still, and looks again when they could
        have passed: the quiet stretch after a job was all there was, and a
        cull ending was enough to start it under him in Choose Keepers."""
        with self.lock:
            if self.proc and self.proc.poll() is None:
                return
            wait = self._quiet_until - time.time()
        if wait > 0:
            self._arm_pickup(wait)
            return
        try:
            import learned
            ask = learned.manifest().get("queued") or {}
        except Exception:  # noqa: BLE001
            return
        why = str(ask.get("why") or "")
        if not why:
            return
        try:
            if not LEARN_PREFS["auto"] and why.startswith(FINISHED_WHY):
                learned.request_run(None)
                return
            if LEARN_PREFS["idle_only"]:
                idle = mac_idle_seconds()
                if idle is not None and idle < LEARN_RESUME_QUIET:
                    self._arm_pickup(max(15.0, LEARN_RESUME_QUIET - idle))
                    return
            learned_start(self, why, shoot=ask.get("shoot") or "")
        except Exception:  # noqa: BLE001
            pass

    def _arm_pickup(self, delay: float) -> None:
        """Look for the learning ask again in `delay` seconds; one timer."""
        with self.lock:
            if self._pickup is not None:
                self._pickup.cancel()
            self._pickup = threading.Timer(delay, self._pick_up_learning)
            self._pickup.daemon = True
            self._pickup.start()

    def _start(self, kind: str, title: str, cmd: list[str], log: Path, shoot: str, jid: int,
               why: str = "", from_list: bool = False, over: Path | None = None,
               opts: dict | None = None, does: str = "") -> None:
        """Start it. The caller holds the lock and knows the slot is free."""
        log.parent.mkdir(parents=True, exist_ok=True)
        if kind == "ingest":
            # A second card into the same shoot: every copy already there
            # keeps its log, finished or not, except the one this run finishes.
            _keep_earlier_copy_log(log, over)
        with log.open("w") as head:
            head.write("$ " + " ".join(cmd) + "\n")
        # Appended to, so the line its parent writes as it ends (ENDED_MARK)
        # lands after everything the job wrote, however the job wrote it.
        fh = log.open("a")
        # Its own process group, so Stop below reaches the children too. A
        # cull runs Python which runs more Python; terminating only the one
        # this holds left the work going and the bar frozen.
        #
        # PYTHONUNBUFFERED, because stdout here is a FILE and not a
        # terminal, and Python block-buffers 8 KB to a file. Every job
        # shorter than 8 KB of output therefore printed NOTHING until it
        # exited -- including its "@@ stage n of m" progress markers, which
        # are the only thing that moves the bar. Standardising a
        # fifteen-frame burst measures each frame off the RAW and takes
        # minutes; with the markers stuck in the buffer the page sat
        # perfectly still for all of them and the only reasonable
        # conclusion was that the button did nothing. The C++ libraries
        # (OpenCV's warnings) write straight to fd 2 and appeared at once,
        # which made it worse: the log looked alive and the work looked
        # dead. The app already sets this for the studio itself; the
        # studio was not passing it on to the work.
        #
        # PIPELINE_FOR_APP, so a storage command ends on its result in the
        # app's words ("… Bring the RAWs Back brings them down again") rather
        # than on a hint to a typist carrying his home path: the panel says
        # that last line under how the job ended (common.for_the_app).
        #
        # Under a parent that writes how it ended as the log's last line
        # (ENDED_MARK), so an engine that went away under it can tell, the
        # next time one starts, whether it finished (`_cut_off`).
        env = dict(os.environ, PYTHONUNBUFFERED="1", **{FOR_APP_ENV: "1"})
        try:
            self.proc = subprocess.Popen(_ending_its_log(cmd), stdout=fh, stderr=subprocess.STDOUT,
                                         cwd=str(HERE), start_new_session=True, env=env)
        finally:
            fh.close()          # the job has its own
        # Written down until it ends, so an engine that dies under it leaves
        # the next one enough to put it down and put it back (`_cut_off`):
        # the process, and - for work the list can rebuild - what it was.
        self._mark_running({"id": jid, "kind": kind, "title": title, "shoot": shoot,
                            "opts": dict(opts or {}), "does": does,
                            "keeps": opts is not None and kind in WORK,
                            "pid": self.proc.pid, "script": cmd[1] if len(cmd) > 1 else cmd[0],
                            "started": round(time.time(), 3), "run": self.run, "log": str(log),
                            "from_list": from_list})
        self.log, self.title, self.kind, self.shoot, self.started = log, title, kind, shoot, time.time()
        self.took, self.stopped, self.id, self.why = 0, False, jid, why
        # This job's own record, so the bar for the whole list and the line he
        # reads afterwards are both about THIS job however long the watcher
        # takes to wake up, and whatever has taken the slot by then.
        self.cur = {"id": jid, "kind": kind, "title": title, "shoot": shoot,
                    "from_list": from_list, "recorded": False, "outcome": "", "log": log,
                    "started": self.started, "why": why}
        self.from_list = from_list
        if kind not in BACKGROUND_KINDS:
            # Quiet means quiet: every job of his pushes the moment the
            # homework may pick itself up back out, so a plan, its apply and
            # the cull after it are one stretch of work and not three
            # openings for the machine to take the slot.
            self._quiet_until = max(self._quiet_until, time.time() + LEARN_RESUME_QUIET)
        threading.Thread(target=self._watch, args=(self.proc, jid, self.cur), daemon=True).start()

    def copying(self, shoot: str) -> bool:
        """Whether a card copy into `shoot` is running or waiting its turn.

        Read without the lock, on purpose: a shoot's info is read while the
        list is choosing its next item under the lock (work_build), and the
        lock does not re-enter. A reading torn between two jobs is wrong for
        one poll; a deadlock is wrong until he quits."""
        proc, kind, name, waiting = self.proc, self.kind, self.shoot, list(self.queue)
        if kind == "ingest" and name == shoot and proc is not None and proc.poll() is None:
            return True
        return any(q.get("kind") == "ingest" and q.get("shoot") == shoot for q in waiting)

    def stop(self) -> bool:
        """Stop what is running. Until this existed the only way out of a
        five-minute cull started with the wrong focus was quitting the app.

        SIGTERM to the group, not SIGKILL: ingest.py and cull.py both write
        files, and a half-written cull.csv is a worse thing to leave behind
        than a job that takes a second to put itself down."""
        with self.lock:
            p = self.proc
            if not p or p.poll() is not None:
                return False
            self.stopped = True
            # Stop holds the rest of the list. He pressed it because he needs
            # the machine, or to cull again with another focus, and the next
            # piece starting the instant this one died made the Mac busy
            # again - and ran the presets against the cull he meant to redo.
            # Only his own work, and only with something waiting: an empty
            # list held by a Stop would keep the next thing he adds from
            # starting, for a reason he has long forgotten. A list he already
            # held keeps its own reason.
            if self.queue and not self.held and self.kind not in BACKGROUND_KINDS:
                self.held = True
                self.held_after = {"why": "stopped", "kind": self.kind, "title": self.title,
                                   "shoot": self.shoot}
                self._save()
            _ask_to_stop(p)
            return True

    def status(self) -> dict:
        # One reading of which job this is, taken together.
        #
        # This used to read self.proc, self.log and self.kind one after
        # another with nothing holding them still, and _start sets them one
        # after another too. Back-to-back jobs made that visible: for one poll
        # between two items of the list the answer was the NEW job's name over
        # the OLD job's exited process, which reads as finished - and the bar
        # for the whole list jumped forward and then fell back.
        with self.lock:
            proc, log, kind, title = self.proc, self.log, self.kind, self.title
            shoot, started, took, stopped = self.shoot, self.started, self.took, self.stopped
            jid, why, cur = self.id, self.why, self.cur
            stood_down = bool(jid) and self._stood_down == jid
            items, held, asked = list(self.queue), self.held, self.asked
            held_after = dict(self.held_after) if self.held_after else None
            cut_off = dict(self.cut_off) if self.cut_off else None
            done, skipped = list(self.done), list(self.skipped)
            pass_no = self.pass_no
        running = bool(proc and proc.poll() is None)
        txt = log.read_text(errors="replace") if log and log.exists() else ""
        lines = [l for l in txt.replace("\r", "\n").splitlines() if l.strip() and "WARN:" not in l and "HF_TOKEN" not in l]
        marks = [l for l in lines if l.startswith("@@ ") and not l.startswith(ENDED_MARK)]
        # A storage job is kind "stor-push" or "plan-drop": the verb after the
        # dash is its one stage. See STAGE_WORDS for why its count is read out
        # of the script's ordinary output rather than from a `@@` line.
        verb = kind.split("-", 1)[1] if "-" in kind else ""
        # The mark wins where there is one. The scrape is only for the stretches
        # a storage script cannot mark, and it goes quiet by itself the moment
        # one appears, so neither has to know about the other.
        if verb and not marks:
            for line in lines:
                m = re.match(r"^\s*(\d+)/(\d+)\b", line)
                if m:
                    marks = [f"@@ {verb} {m.group(1)} {m.group(2)}"]
        stage, frac, label = "", 0.0, ""
        done_stages: dict[str, float] = {}
        for l in marks:
            try:
                _, st, d, t = l.split()
                done_stages[st] = min(1.0, int(d) / max(1, int(t)))
                stage = st
                word, unit = STAGE_WORDS.get(st, (st, ""))
                label = f"{word}: {int(d):,} of {int(t):,} {unit}".strip() if int(t) > 1 else word
            except ValueError:
                pass

        weights = ({"ingest": ingest_weights(getattr(proc, "args", None)), "setup": SETUP_WEIGHTS,
                    "update": UPDATE_WEIGHTS}.get(kind)
                   or KIND_WEIGHTS.get(kind) or STOR_WEIGHTS.get(verb) or WEIGHTS)
        if verb and stage and stage not in weights:
            # Nothing reaches this today: archive.py and reclaim.py print one
            # stage per verb and name it after the verb, so a drop's 26.9 GB of
            # re-hashing is marked `@@ drop`, the same as the unlinking after
            # it. It is here for the run that splits, because the failure is
            # silent - a name this table has never heard of weighs 0 and holds
            # the bar at nothing from the first second to the last - and
            # because weighting those names here would put a second copy of
            # archive.py's running order in the page. The bar is the stage the
            # script is in now, and the label says which that is.
            weights = {stage: 100}
        # Every stage before the one speaking now is over, whether or not it
        # reported (a cached decode prints nothing).
        order = list(weights)
        if stage in order:
            for k in order[:order.index(stage)]:
                done_stages.setdefault(k, 1.0)
        total = sum(weights.values())
        frac = sum(weights.get(k, 0) * v for k, v in done_stages.items()) / total
        if not running and proc is not None and proc.returncode == 0:
            frac = 1.0
        # How long it TOOK, frozen at exit. This was computed from the start
        # time on every request, so a job that ran for one second read 0:18
        # twenty seconds later and went on climbing for as long as its card was
        # on the screen: a cull finished an hour ago appeared as "Done: culling
        # 2026-09-16  63:12", which reads as an hour-long cull.
        if running:
            elapsed = int(time.time() - started) if started else 0
        else:
            if started and not took:
                took = int(time.time() - started)
                with self.lock:
                    if self.started == started and not self.took:
                        self.took = took
            elapsed = took
        # Whether this job came off the list: said on every reading of it,
        # the last ones included. It used to go False the moment the job was
        # written into `done`, so every reading after the end of the list's
        # last job said "started by hand" and the app announced that job as
        # well as the list - two banners where the list promises one.
        from_list = bool(cur and cur.get("from_list"))
        # The job that is running, or has just exited and is not in `done`
        # yet. Either way it is one part of the list that is not finished
        # being counted, and leaving it out for the half-second in between is
        # what made the bar fall back three times in four jobs.
        counting = from_list and not cur.get("recorded")
        waiting = [self.describe(q) for q in items]
        # The bar for the whole list, which is what the Dock shows: a list of
        # four is not four bars, it is one piece of work with four parts. The
        # job running now counts as the fraction it has got to, and only when
        # it came off the list - a cull he started by hand while the list was
        # held is not part of it.
        counted = len(done) + len(skipped) + len(waiting) + (1 if counting else 0)
        listed = max(counted, asked)
        list_frac = ((len(done) + len(skipped) + (frac if counting else 0)) / listed
                     if listed else 0.0)
        return {"running": running, "kind": kind, "shoot": shoot, "title": title, "stage": stage, "label": label,
                "stopped": stopped, "fraction": round(frac, 3), "elapsed": elapsed,
                "id": jid, "queued": bool(waiting), "queue": waiting,
                # The list, as one thing. `pass_no` changes when a new stretch
                # of work starts, so the app can tell him once when it empties
                # rather than once a job (DESIGN.md §2.7).
                "queue_held": held, "queue_held_after": held_after, "queue_cut_off": cut_off,
                "queue_waiting": len(waiting), "queue_pass": pass_no,
                "queue_listed": listed, "queue_fraction": round(list_frac, 3),
                "queue_from_list": from_list,
                "queue_done": done, "queue_skipped": skipped,
                "why": why, "background": kind in BACKGROUND_KINDS,
                # Stopped to make room for work of his (make_room), not by his
                # Stop. The Instagram step reads it: a pass stood down for his
                # press is not a pass he stopped, and it asks for the rest
                # again by itself once the slot is free.
                "stood_down": stood_down and stopped and not running,
                # When it started, in seconds since the epoch: the app's
                # history shows this, not the moment it first happened to look.
                "started": round(started, 3) if started else None,
                "remaining": how_much_longer(running, frac, elapsed),
                # And the words for it, so no screen anywhere has to turn
                # seconds into English twice and get two different answers.
                "remaining_text": about_how_long(how_much_longer(running, frac, elapsed)),
                # With the storage commands' terminal footers in the app's
                # words, since the last line here is what a refused job says.
                "log": "\n".join(w for l in lines if not l.startswith("@@ ")
                                 for w in [plan_words(l)] if w is not None)[-8000:],
                "code": None if running or not proc else proc.returncode}


# Under the log of a job the engine went away under, in the history. The app's
# own words for the same thing (Strings.Activity.engineStoppedWhileRunning).
ENGINE_WENT_AWAY = "The engine stopped while this ran."

# The last line of every job's log, written as the job exits with the code it
# exited with, by the small parent every job runs under (`_JOB_PARENT`). An
# engine that goes away cannot see a job end; the next one reads this to tell
# a job that finished while nobody watched from one the Mac went down under
# (Jobs._cut_off), which leaves no such line.
#
# The parent is also where a Stop goes (`_ask_to_stop`): it passes SIGTERM to
# the whole group once, the job's children with it, and waits for the job to
# put itself down (common.stop_cleanly_on_sigterm), so the engine sees the job
# end when it has and not when its parent was told to. A Stop that lands
# before the job has even started is held until it has, and then passed on:
# sent to the group straight from the engine, it could land in the moment
# between the parent starting and the job starting, and be lost.
ENDED_MARK = "@@ ended "
_JOB_PARENT = """
import os, signal, subprocess, sys
T, C = signal.SIGTERM, signal.SIGCHLD
signal.signal(C, lambda *_: None)   # a child's end is kept for sigwait, not discarded
signal.pthread_sigmask(signal.SIG_BLOCK, {T, C})
try:
    job = subprocess.Popen(sys.argv[1:], preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_UNBLOCK, {T, C}))
except OSError as e:
    print(e, file=sys.stderr, flush=True)
    print("@@ ended 127", flush=True)
    sys.exit(127)
sent = False
while job.poll() is None:
    if signal.sigwait({T, C}) == T and not sent:
        sent = True
        os.killpg(os.getpgrp(), T)
c = job.returncode if job.returncode >= 0 else 128 - job.returncode
print("@@ ended %d" % c, flush=True)
sys.exit(c)
"""


def _ending_its_log(cmd: list[str]) -> list[str]:
    """`cmd`, run under the parent that writes how it ended as the last line
    of its log and passes a Stop on to it."""
    return [sys.executable, "-c", _JOB_PARENT, *cmd]


def _ask_to_stop(p: subprocess.Popen) -> None:
    """SIGTERM to a job, through its parent (`_JOB_PARENT`), which passes it to
    the whole group exactly once: the same signal twice would land in the
    middle of the job's own cleanup and cut it short."""
    try:
        os.kill(p.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError, OSError):
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGTERM)
        except (ProcessLookupError, PermissionError, OSError):
            pass


def ended_unwatched(log) -> tuple[str, int] | None:
    """How a job that exited while no engine watched ended - ("done", 0),
    ("refused", 1), ("failed", 1)... - read off the line its shell wrote, or
    None when it wrote none: the Mac went down under it, or it was killed with
    its shell, and either way it did not get to the end."""
    try:
        with open(log, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            fh.seek(max(0, fh.tell() - 16_000))
            txt = fh.read().decode(errors="replace")
    except (OSError, TypeError):
        return None
    lines = [l.strip() for l in txt.replace("\r", "\n").splitlines() if l.strip()]
    last_cmd = max((i for i, l in enumerate(lines) if l.startswith("$ ")), default=-1)
    ends = [l for l in lines[last_cmd + 1:] if l.startswith(ENDED_MARK)]
    if not ends:
        return None
    try:
        code = int(ends[-1][len(ENDED_MARK):].strip())
    except ValueError:
        return None
    return ended_as(code, Path(log)), code


def _process_command(pid: int) -> str | None:
    """The entire command on macOS and Linux, or None if it cannot be read.

    Linux ps can clip redirected output to 80 columns. The interpreter's
    path alone can hide studio.py, making a live owner's job look orphaned.
    Both BSD and procps accept -ww for unlimited width.
    """
    try:
        result = subprocess.run(["/bin/ps", "-ww", "-o", "command=", "-p", str(pid)],
                                capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else None


def _engine_up(run: str) -> bool:
    """Whether the engine that wrote a running job's note is still up: another
    process, still running studio.py. `run` is its Jobs.run, "<time>-<pid>-…".

    A second engine on the same list - a second `./pl studio`, or the app's
    while an orphaned one still serves - must not put down the first one's
    job, which is running exactly as it should."""
    try:
        pid = int(str(run).split("-")[1])
    except (IndexError, ValueError):
        return False
    if pid <= 0 or pid == os.getpid():
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        pass                    # there, and someone else's to signal
    line = _process_command(pid)
    # A live PID whose identity could not be read is not proof of a crash.
    # Preserve its note and work until ownership can be established.
    return line is None or "studio.py" in line


def copy_stopped_at(log) -> tuple[int, int]:
    """(frames copied, frames on the card) as far as a card copy's log got, from
    its `@@ copy` marks and its "copying N files" line; 0 where it did not say."""
    try:
        txt = Path(log).read_text(errors="replace") if log else ""
    except OSError:
        return 0, 0
    marks = re.findall(r"^@@ copy (\d+) (\d+)$", txt, re.M)
    started = re.search(r"^copying (\d+) files", txt, re.M)
    got = int(marks[-1][0]) if marks else 0
    of = int(started.group(1)) if started else (int(marks[-1][1]) if marks else 0)
    return got, of


def mac_idle_seconds() -> float | None:
    """How long since the last key press or pointer movement on this Mac, as
    the HID system counts it; None when it cannot be read, and then only the
    quiet stretch after his work decides."""
    try:
        out = subprocess.run(["/usr/sbin/ioreg", "-c", "IOHIDSystem", "-d", "4"], capture_output=True,
                             text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r'"HIDIdleTime"\s*=\s*(\d+)', out)
    return int(m.group(1)) / 1e9 if m else None


def readable_log(log) -> str:
    """A job's log as the app is sent it (`Jobs.status`): no progress marks, no
    noise, the storage commands' terminal footers in the app's words, the last
    8,000 characters."""
    try:
        txt = Path(log).read_text(errors="replace") if log else ""
    except OSError:
        return ""
    lines = [l for l in txt.replace("\r", "\n").splitlines()
             if l.strip() and "WARN:" not in l and "HF_TOKEN" not in l]
    return "\n".join(w for l in lines if not l.startswith("@@ ")
                     for w in [plan_words(l)] if w is not None)[-8000:]


def _put_down(pid: int, script: str, wait: float = 5.0) -> bool:
    """Stop the process group a job left behind when the engine that started
    it went away, if it is still that job. True when something was stopped.

    Only a group whose leader is `pid` - every job is started in a session of
    its own - and only while its command line still names the job's script,
    because a number the system has handed out again belongs to someone else.
    SIGTERM first, as Stop does, for the same reason: a half-written cull.csv
    is worse than a job that takes a second to put itself down."""
    if pid <= 0:
        return False
    try:
        if os.getpgid(pid) != pid:
            return False
    except OSError:
        return False
    line = _process_command(pid)
    if line is None or (script and script not in line):
        return False
    # Through the job's parent, which passes it on to the group once
    # (`_ask_to_stop`); a note written before jobs had one names the job
    # itself, and it gets it straight.
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        return False
    end = time.time() + wait
    while time.time() < end:
        try:
            os.killpg(pid, 0)
        except OSError:
            return True
        time.sleep(0.1)
    try:
        os.killpg(pid, signal.SIGKILL)
    except OSError:
        pass
    return True


def ended_as(code: int | None, log: Path | None) -> str:
    """How a job that has exited ended, in the list's words: "done",
    "refused" or "failed". Stopped is the caller's to say; it knows whether
    Stop was pressed.

    A refusal is a script saying no on purpose. It raises SystemExit with its
    sentence, which prints the sentence and no traceback, and exits 1 - so
    every list job that refused used to be written down as "failed", and the
    app counted a guard working as a crash, in red. A crash prints a
    traceback and ends on the exception's own line ("MemoryError",
    "OSError: [Errno 28] No space left on device"); a job killed by a signal,
    out of memory or by hand, ends with a negative code; one that says
    nothing at all did not say no. Only the log after the last command line
    is read: an earlier part of the same job says nothing about how this part
    ended. It is the rule the app applies to a job it watched end
    (`Job.crashed`), so the list and the history call one ending one thing."""
    if code == 0:
        return "done"
    if code is None or code < 0 or code >= 128:
        return "failed"
    try:
        with open(log, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            fh.seek(max(0, fh.tell() - 16_000))
            txt = fh.read().decode(errors="replace")
    except (OSError, TypeError):
        return "failed"
    # The same lines the app is sent (status): no progress marks, no noise.
    lines = [l.strip() for l in txt.replace("\r", "\n").splitlines()
             if l.strip() and "WARN:" not in l and "HF_TOKEN" not in l and not l.startswith("@@ ")]
    last_cmd = max((i for i, l in enumerate(lines) if l.startswith("$ ")), default=-1)
    lines = lines[last_cmd + 1:]
    if not lines or any(l.startswith("Traceback (most recent call last)") for l in lines):
        return "failed"
    last = lines[-1]
    if "Traceback" in last or last.startswith('File "') or _exception_line(last):
        return "failed"
    return "refused"


def _exception_line(line: str) -> bool:
    """"MemoryError", "OSError: [Errno 28] ...", "cv2.error: ...": a dotted
    name ending in Error or Exception (or a module's own .error), alone or
    before a colon. A sentence has a space before any colon, so it never is
    one."""
    name = line.split(":", 1)[0]
    if not (name.endswith("Error") or name.endswith("Exception") or name.endswith(".error")):
        return False
    return all(c.isalnum() or c in "_." for c in name)


def how_much_longer(running: bool, frac: float, elapsed: int) -> int | None:
    """Seconds left, or None when there is no honest answer yet.

    Straight-line off the bar, which is all anyone can say: the stages are
    weighted by how long they take, so the bar already carries what is known
    about the shape of the work. None below a fiftieth of the way through or
    inside the first eight seconds, because "about 4 hours left" at 1% on a
    six-minute job is worse than saying nothing - and saying nothing is what a
    view is told to do here, rather than being handed a number to dress up.

    It is rounded on the way out (about_how_long), because a bar that says "4
    minutes 37 seconds" is claiming a precision no estimate off a fraction has
    ever had."""
    if not running or frac <= 0.02 or elapsed < 8:
        return None
    return max(1, int(elapsed * (1 - frac) / frac))


def about_how_long(seconds: int | None) -> str:
    """"about 4 minutes left". His words, and no false precision in them."""
    if seconds is None:
        return ""
    if seconds < 45:
        return "less than a minute left"
    mins = int(round(seconds / 60))
    if mins < 60:
        return f"about {mins} minute{'s' if mins != 1 else ''} left"
    hours = seconds / 3600
    return f"about {hours:.0f} hour{'s' if round(hours) != 1 else ''} left"


def shoots() -> list[Shoot]:
    """Every shoot on the shelf.

    A folder with nothing whatever in it is not one. `~/photos/shoots/shoots`
    - the empty folder the old mkdir made under a misread PHOTOS_ROOT - was
    listed as a shoot with 0 frames and no steps, an eighth row in his sidebar
    named after a folder he never made. An ingest in flight is not caught by
    this: the first thing the copy does is make the shoot's raw/."""
    base = shoots_dir()
    out = []
    if base.is_dir():
        for p in sorted(base.iterdir(), reverse=True):
            if p.is_dir() and not p.name.startswith(".") and is_shoot(p):
                out.append(Shoot(p))
    return out


def cards() -> list[str]:
    vols = Path("/Volumes")
    if not vols.is_dir():
        return []
    return [str(v) for v in vols.iterdir() if (v / "DCIM").is_dir()]


def describe_card(vol: str, library: list["Shoot"] | None = None) -> dict:
    """What is on a card, and which shoot in this library already holds it.

    His camera formats every card as "Untitled", so the path a card mounts at
    names nothing: the page matched a new card to the shoot recorded against
    "/Volumes/Untitled" and said "already copied as 2026-09-19" of every card
    from the second night on, the one warning meant to stop a double copy. A
    shoot holds a card's frame here when its raw/ has a file of the same name,
    size and time - ingest.py keeps the card's times on its copies, and a name
    and size alone carry almost no identity for this camera (see
    ingest.place). Counted, so a copy that stopped part way says where it
    stopped, one still going says so, and a card holding frames of no shoot
    says nothing at all.

    The photographs are what ingest.py copies: every RAW and JPEG under DCIM,
    not hidden. `first` and `last` are the earliest and latest file times on
    the card, in seconds, which is when the frames were written."""
    root = Path(vol)
    src = root / "DCIM" if (root / "DCIM").is_dir() else root
    stats: list[tuple[Path, os.stat_result]] = []
    try:
        for p in src.rglob("*"):
            if p.suffix.lower() in RAW_EXTS and not p.name.startswith("."):
                try:
                    st = p.stat()
                except OSError:
                    continue
                if S_ISREG(st.st_mode):
                    stats.append((p, st))
    except OSError:
        pass
    out = {"path": vol, "name": root.name, "photographs": len(stats),
           "bytes": sum(st.st_size for _, st in stats),
           "first": int(min((st.st_mtime for _, st in stats), default=0)),
           "last": int(max((st.st_mtime for _, st in stats), default=0)),
           "copied_as": "", "held": 0, "stopped": False, "copying": False}
    best, held = None, 0
    for s in library if library is not None else shoots():
        try:
            there = set(os.listdir(s.raw))
        except OSError:
            continue
        n = 0
        for p, st in stats:
            # The two names ingest.py gives a frame before it falls back to
            # one carrying a piece of its hash, which cannot be guessed here.
            for name in (p.name, f"{p.stem}_{p.parent.name}{p.suffix}"):
                if name not in there:
                    continue
                try:
                    c = (s.raw / name).stat()
                except OSError:
                    continue
                # A card keeps times to two seconds; the copy keeps the card's.
                if c.st_size == st.st_size and abs(c.st_mtime - st.st_mtime) < 2:
                    n += 1
                    break
        if n > held:
            best, held = s, n
    if best is not None:
        # Stopped by the copy's own log, and only when nothing is copying into
        # that shoot now: a copy in flight has the same log as one that died.
        state = _ingest_note(best).get("state") if held < len(stats) else ""
        out.update(copied_as=best.folder.name, held=held,
                   stopped=state == "stopped", copying=state == "copying")
    return out


# ----------------------------------------- where a shoot's photographs are
#
# Everything from here to the endpoints answers one question - are the bytes
# of this frame on this disk, and are they in iCloud - and answers it by
# asking archive.py and reclaim.py rather than by looking at a path.
#
# `Path.exists()` is True for a file macOS has evicted: the name is there,
# `stat` reports the full size, and the first read blocks on a download. 405
# of the 3,202 files in this Drive are in that state today. So a single word
# "archived", or a green tick, would be the same mark over a frame with two
# copies and over a frame whose bytes are not on this machine at all, and two
# of the five states it would cover are one mistake from a lost photograph.
# The only sources here are archive.local() and archive.is_dataless(), and the
# answer is drawn as two cells because it is two questions.
#
#   full   the bytes are on that disk now
#   hollow the name is there and the bytes are not
#   none   there is no copy there
#   gone   it was recorded as being there and it is not

def _cells(r: dict) -> tuple[str, str]:
    """(this Mac, iCloud) for one row of archive.status(), always in that order."""
    if r["here"]:
        mac = "full"
    elif r.get("here_evicted"):
        mac = "hollow"
    else:
        mac = "none"
    if r["up"]:
        up = "full" if r.get("up_local") else "hollow"
    elif r.get("recorded"):
        up = "gone"
    else:
        up = "none"
    return mac, up


def _state(mac: str, up: str) -> str:
    if up == "gone":
        return "missing"
    if mac == "hollow":
        return "here_evicted"
    if mac == "full":
        return "both" if up in ("full", "hollow") else "here_only"
    if up == "full":
        return "icloud_only"
    if up == "hollow":
        return "evicted"
    # Nothing on either disk and nothing recorded. This used to fall through to
    # "missing", which made the panel say "recorded as archived and not found in
    # iCloud" about a frame sitting in raw/ that was never archived at all: the
    # row exists because archive.status() found the file in the shoot, so the
    # name is there, but local() found no blocks behind it and is_dataless()
    # found no eviction to explain that. It is a different alarm and it gets a
    # different word.
    return "unreadable"


def _state_words(state: str, mac: str, up: str) -> str:
    """What that pair of cells means, in the words the page prints beside it.
    The word "safe" appears in exactly one of these, and only where both cells
    are filled. Nothing here is in capitals: the red glyph beside a missing
    frame is the alarm, and "NOT FOUND" shouted it a second time."""
    if state == "missing":
        if mac == "full":
            return "recorded as archived and not found in iCloud; the original is still on this Mac"
        if mac == "hollow":
            # "not on this Mac either" was the sentence here, and it is not true
            # of a hollow left cell: the original IS in the shoot, it is the
            # bytes behind it that are gone.
            return ("recorded as archived and not found in iCloud; the original here is itself "
                    "evicted, so the name is in the shoot and the bytes are not")
        if mac == "mixed":
            return "recorded as archived and not found in iCloud"
        return "recorded as archived and not found in iCloud, and not on this Mac either"
    if state == "unreadable":
        return ("the original is in this shoot and has no bytes on the disk; it was never "
                "archived, so there is nowhere here to fetch it from")
    if state == "here_evicted":
        return ("the local original is itself evicted; the copy in iCloud is the one with bytes"
                if up == "full" else
                "the local original is evicted: the name is here and the bytes are not")
    if state == "both":
        if up == "full":
            return "two copies: on this Mac and in iCloud"
        # "mixed" is a group whose iCloud copies do not agree, which is what a
        # Drive with Optimise Mac Storage on looks like: on a five-frame fixture
        # with one of the five evicted up there, this legend line said the
        # singular sentence over all five. The count is in the panel's own line.
        return ("two copies; some of the iCloud ones would download before they could be checked"
                if up == "mixed" else
                "two copies; the iCloud one would download before it could be checked")
    return {"icloud_only": "in iCloud only — the local original was dropped",
            "evicted": "in iCloud, not on this Mac — reading it downloads it first",
            "here_only": "on this Mac only — one copy"}[state]


# Worst first, so one missing frame is the first row of the fold and not row 900.
STOR_SEVERITY = ("missing", "unreadable", "here_evicted", "evicted", "icloud_only", "here_only", "both")
# The bar reads left to right: safest, lonelier, lonelier still, then the alarms.
STOR_BAR = ("both", "icloud_only", "evicted", "here_evicted", "here_only", "unreadable", "missing")


def _stor_rows(s: Shoot) -> tuple[list[dict], dict]:
    """archive.status() with the two cells worked out, and the counts per state."""
    import archive as amod
    from common import human
    st = amod.status(s.folder)
    out, counts, lost = [], dict.fromkeys(STOR_BAR, 0), 0
    pairs: dict[str, set] = {k: set() for k in STOR_BAR}
    for r in st["rows"]:
        mac, up = _cells(r)
        k = _state(mac, up)
        counts[k] += 1
        pairs[k].add((mac, up))
        if up == "gone" and mac != "full":
            lost += 1
        out.append({"name": r["name"], "bytes": r["bytes"], "bytes_text": human(r["bytes"]),
                    "state": k, "cells": [mac, up], "words": _state_words(k, mac, up)})
    out.sort(key=lambda x: (STOR_SEVERITY.index(x["state"]), x["name"]))
    return out, {"counts": counts, "lost": lost, "status": st, "pairs": pairs}


# How much one cell claims. A legend line stands for a group of frames, so it
# must never claim more than the least reassuring frame in that group. Measured
# on a fixture whose archive copies were all evicted: every row in the fold drew
# "full hollow" and the legend above them drew "full full", because a state name
# is coarser than the pair of cells it was drawn from. Least first, so the
# summary is never kinder than the rows underneath it.
_CELL_CLAIM = {"full": 3, "hollow": 2, "none": 1, "gone": 0}


def _worst_pair(seen: set, fallback: tuple[str, str]) -> tuple[str, str]:
    if not seen:
        return fallback
    return min(seen, key=lambda p: (_CELL_CLAIM[p[0]] + _CELL_CLAIM[p[1]], _CELL_CLAIM[p[0]]))


def _home_cells(seen: set) -> list[str]:
    """The pair of cells a whole shoot gets on the front page.

    Every other pair in this page is about one frame, or about one state, where
    each cell is a yes or a no. This one stands for a mixture, and it was
    drawing ■ ■ - the mark that means bytes on both disks - over a shoot with
    frames that had never been pushed at all: measured on a five-frame fixture
    with three of them up, it drew two filled cells beside "3 of 5 in iCloud".
    There is no yes or no to "are the bytes on that disk" for a group that
    disagrees, and answering with the worst frame in it would put ⋅ ⋅ over a
    shoot that is almost entirely archived. A column the frames disagree on
    says that instead: half filled, for some of them and not all. Each column
    on its own, because the honest left cell and the honest right cell usually
    come from different frames."""
    out = []
    for i in (0, 1):
        col = {p[i] for p in seen} or {"none"}
        out.append(col.pop() if len(col) == 1 else "some")
    return out


def _stem(row: dict) -> str:
    """The name a picture route answers to: the file without its suffix."""
    return row.get("stem") or Path(row["file"]).stem


def _stor_home(s: Shoot) -> dict:
    """The one line and the one glyph a shoot gets on the front page, so the
    answer to "where are my photographs" is there before anything is opened."""
    import archive as amod
    from common import human
    rows, agg = _stor_rows(s)
    sm = amod.summarise(agg["status"])
    c, lost = agg["counts"], agg["lost"]
    frames = sm["frames"]
    if not frames:
        return {"frames": 0, "phrase": "", "cells": ["none", "none"], "bad": False,
                "bytes_here": 0, "bytes_here_text": ""}
    # The one pair of cells that is worked out from the rows rather than
    # asserted, for every branch below that stands for a shoot whose frames do
    # not agree. Worked out once because four branches want it and a fifth one
    # that quietly did not is how this row came to over-promise in the first
    # place.
    mixed = _home_cells(set().union(*agg["pairs"].values()))
    if c["missing"]:
        # The left cell answers one question and only one: are the bytes on
        # this Mac. A hole in iCloud does not empty the disk, and a row that
        # read "no copy here" over 1,156 frames that are all on this disk would
        # argue for exactly the wrong move. But sm["here"] is a count, and any
        # count at all drew the filled mark: a six-frame fixture with four
        # originals already dropped and two still in raw/ drew the mark that
        # means "the bytes are on that disk now" over a shoot four photographs
        # down. The column is worked out the way every other mixed column on
        # this row is; the right cell stays `gone`, because that is the alarm.
        cells = [mixed[0], "gone"]
        phrase, bad = f"{c['missing']} frame{'' if c['missing'] == 1 else 's'} missing", True
    elif c["unreadable"]:
        # A frame in the shoot with no bytes behind its name and nothing
        # recorded in iCloud. Nothing in this pipeline can fetch it, so it is
        # an alarm in its own right and not the tail of "on this Mac only".
        # The cells still answer their own two questions for the whole shoot;
        # the alarm is the phrase, as it is for a missing frame.
        cells = mixed
        phrase, bad = f"{c['unreadable']} frame{'' if c['unreadable'] == 1 else 's'} with no bytes anywhere", True
    elif c["evicted"] or c["here_evicted"]:
        # Some of this shoot is evicted, and this said all of it was. One local
        # original evicted out of five drew ⋅ ▢ - no copy here, and the one up
        # there is hollow - over four frames whose bytes are on this disk, which
        # argues for pulling down a shoot that is already here. The cells come
        # off the rows like every other mixed pair on this page, and the phrase
        # carries the count unless the whole shoot really is in that state.
        # And when the whole shoot IS in one state, which state: these two
        # are opposite sides. "in iCloud, evicted" was printed for either,
        # so a shoot that was never pushed at all, whose RAWs macOS had
        # evicted out of his Drive, read on the front page as archived -
        # `▢ ⋅`, a right-hand cell saying there is no copy there, under a
        # phrase promising one, over the shoot's own panel saying "nothing
        # in iCloud". The bytes of a frame in either state come back from
        # iCloud, which is why neither is an alarm.
        n = c["evicted"] + c["here_evicted"]
        cells = mixed
        if c["evicted"] == frames:
            phrase = "in iCloud, evicted"
        elif c["here_evicted"] == frames:
            phrase = "evicted on this Mac"
        else:
            phrase = f"{n} of {frames} evicted"
        bad = False
    elif sm["up"] == frames and sm["here"] == frames and sm["up_evicted"]:
        # Both copies exist and the local one has its bytes, so this is not an
        # alarm - but it is not "in iCloud too" either, and it was drawing two
        # filled cells over rows that each drew one filled and one hollow. It
        # then drew ■ ▢ and said "one evicted" for any number of them: with
        # Optimise Mac Storage evicting 405 of the 1,847 files in his Drive,
        # one is the number this almost never is, and the hollow right cell
        # denied the bytes of every copy up there that still has them.
        n = sm["up_evicted"]
        cells = mixed
        phrase = ("two copies, one evicted in iCloud" if n == 1
                  else f"two copies; {n} of {frames} evicted in iCloud")
        bad = False
    elif sm["up"] == frames and sm["here"] == frames:
        cells, phrase, bad = ["full", "full"], "in iCloud too", False
    elif sm["up"] == frames and not sm["here"]:
        cells, phrase, bad = ["none", "full"], "in iCloud only", False
    elif sm["up"] == frames:
        # Every frame is up and some of the originals are not here any more.
        # This fell through to the partly-pushed branch below and read "10 of
        # 10 in iCloud", which is true, and is also exactly what a shoot with
        # two whole copies of every frame reads like: the fact it lost was that
        # four of those ten are now down to one copy in the world. The phrase
        # carries that; the left cell already says "some of them".
        gone = frames - sm["here"]
        cells = mixed
        phrase = f"in iCloud; {gone} of {frames} dropped from this Mac"
        bad = False
    elif sm["up"]:
        # Partly pushed. Both cells stand for the whole shoot, and in this
        # branch at least one frame has no copy in iCloud at all, so ■ ■ - the
        # mark that means bytes on both disks - is a promise the shoot does not
        # keep. The phrase beside it was already honest ("3 of 5 in iCloud");
        # the glyph is what he reads at a glance, and it was the one
        # overstating. A shoot fully on both disks still draws ■ ■ above.
        cells = mixed
        phrase, bad = f"{sm['up']} of {frames} in iCloud", False
    else:
        cells, phrase, bad = ["full", "none"], "on this Mac only", False
    # What the shoot holds on this disk, the figure the storage page puts
    # before the phrase and sorts by, so the shoot to clear first is the one
    # at the top. The same sum as the panel's "36.3 GB here"; no words for
    # nothing, which beside "in iCloud only" would only be noise.
    here = sm["bytes_here"]
    return {"frames": frames, "phrase": phrase, "cells": cells, "bad": bad, "lost": lost,
            "bytes_here": here, "bytes_here_text": human(here) if here else ""}


def _stor_line(sm: dict, counts: dict, lost: int, total: int = 0) -> str:
    """The panel's one sentence. Its verdict is the last clause, and the only
    clause in the whole page allowed to say every frame has two copies.

    It counts ORIGINALS and the rest of the page counts photographs, and it
    used to call them both "frames": the lounge's panel read "6 frames · one
    copy" over a shoot of 296 photographs, 290 of which have no original
    anywhere. The word here is originals, and where the shoot has more
    photographs than originals it says so, matching the front-page row that
    was fixed for exactly this."""
    from common import human
    frames = sm["frames"]
    if not frames:
        return "No originals in this shoot."
    n = counts["missing"]
    u = counts["unreadable"]
    # Not covered by anything below: an unreadable frame is not "here", so a
    # shoot with one and nothing archived fell through to "one copy.", which is
    # one copy more than it has. Worked out before the branches rather than
    # inside one of them, because the two alarms can be in the same shoot and
    # this was an `elif`: six frames, one recorded as archived and not in
    # iCloud and five with no bytes behind their names, said the first and not
    # a word of the second.
    hollow = (f"{u} frame{'' if u == 1 else 's'} {'has' if u == 1 else 'have'} no bytes behind "
              f"{'its' if u == 1 else 'their'} name and {'was' if u == 1 else 'were'} never archived.")
    if n:
        # "Nothing here can rebuild them" was hung on the whole missing count
        # whenever a single frame was past rebuilding, and most of that count is
        # usually frames whose local original never went anywhere. A hole in the
        # archive of a frame that is still in raw/ costs a spare; a hole in the
        # archive of a frame that was dropped costs the photograph. They are not
        # the same loss and the sentence must not average them.
        kept = n - lost
        tail = (f"{n} frame{'' if n == 1 else 's'} {'is' if n == 1 else 'are'} recorded as archived "
                f"and not in iCloud")
        if kept and lost:
            tail += (f"; {kept} still {'has' if kept == 1 else 'have'} the original in this shoot, and "
                     f"nothing here can rebuild the other {lost}.")
        elif lost:
            tail += f"; nothing here can rebuild {'it' if lost == 1 else 'them'}."
        else:
            tail += f"; the original of {'that frame' if kept == 1 else 'every one of them'} is still in this shoot."
        if u:
            tail += " " + hollow
    elif u:
        tail = hollow
    elif sm["here"] == frames and sm["up"] == frames and not counts["evicted"] and not counts["here_evicted"]:
        # `up` counts a NAME in iCloud, not bytes on this machine, so a frame
        # whose archive copy macOS has since evicted is still "both" and still
        # lands here. Saying "two copies of every frame" over that is the
        # sentence that sends him to Remove the local RAWs, which drop then
        # refuses one frame at a time: "the iCloud copy is evicted; it must
        # come down to be checked."
        tail = ("two copies of every frame." if not sm["up_evicted"] else
                f"two copies of every frame, but {sm['up_evicted']} of the iCloud copies would "
                f"have to download before anything could check them.")
    elif sm["up"] == frames and not sm["here"]:
        tail = "one copy, and it is in iCloud."
    elif not sm["up"] and sm["here"] == frames:
        # Nothing up there and every original here: the one state row under
        # this line already says "on this Mac only — one copy", and the line
        # said "one copy" a second time beside it.
        tail = ""
    elif not sm["up"]:
        # Nothing up there and not every original here either: the verdict is
        # how many are, and the line does not end as if all of them were.
        tail = f"{sm['here']:,} of {frames:,} on this Mac."
    else:
        tail = f"{sm['up']:,} of {frames:,} in iCloud."
    up_text = f"{human(sm['bytes_up'])} in iCloud" if sm["up"] else "nothing in iCloud"
    # Grouped as every other count on the page is: "1558 originals" sat over a
    # row reading 1,558.
    head = f"{frames:,} original{'' if frames == 1 else 's'}"
    if total and total != frames:
        head += f" of {total:,} frames"
    return " · ".join(x for x in (head, f"{human(sm['bytes_here'])} here", up_text, tail) if x)


def storage(s: Shoot) -> dict:
    """The whole panel in one answer. lstat only, so it never materialises an
    evicted file: measured at 0.15 s on the 1157-frame shoot."""
    import archive as amod
    import reclaim as rmod
    from common import human
    rows, agg = _stor_rows(s)
    sm = amod.summarise(agg["status"])
    counts, lost = agg["counts"], agg["lost"]
    sm["missing"], sm["lost"] = counts["missing"], lost
    # Drawn from the rows this shoot actually has, not from the state's nominal
    # pair, so the legend and the fold cannot say two different things.
    glyph = {k: _worst_pair(agg["pairs"][k], _STOR_GLYPH[k]) for k in STOR_BAR}
    # The glyph may claim the least; the SENTENCE beside it must not claim
    # anything the group does not agree on. Six frames recorded as archived and
    # not in iCloud, two of them still sitting in raw/, drew "and not on this
    # Mac either" across all six, because the worst pair's left cell spoke for
    # frames that did not share it. A column the group disagrees on is handed
    # "mixed" and the words drop that clause; the panel's own line carries the
    # split, with the counts.
    spoken = {k: tuple("mixed" if len({p[i] for p in agg["pairs"][k]}) > 1 else glyph[k][i]
                       for i in (0, 1)) for k in STOR_BAR}
    raw = agg["status"]["rows"]
    sm["here_text"], sm["up_text"] = human(sm["bytes_here"]), human(sm["bytes_up"])
    # What a push would carry and what a drop would free, off the same rows the
    # rest of the panel is drawn from, so a button and the sentence above it can
    # never be about different frames.
    todo = [r for r in raw if not r["up"] and (r["here"] or r.get("here_evicted"))]
    back = [r for r in raw if r["up"] and not r["here"] and not r.get("here_evicted")]
    sm["todo"], sm["todo_text"] = len(todo), human(sum(r["bytes"] for r in todo))
    sm["pullable"], sm["pullable_text"] = len(back), human(sum(r["bytes"] for r in back))
    # What drop could actually take. The button was offered on `up == frames`,
    # which counts NAMES in iCloud: on a fully pushed shoot whose archive copies
    # macOS has since evicted it offered "Remove the local RAWs - frees 26.9 GB"
    # and the dry run then refused every frame one at a time, "the iCloud copy
    # is evicted; it must come down to be checked". drop removes a local
    # original only when the copy up there is recorded, present AND has its
    # bytes, so that is what is counted here. It is still an upper bound, since
    # drop re-hashes what it finds, which is why the page says "up to".
    drops = [r for r in raw if r["here"] and r["up"] and r.get("up_local") and r.get("recorded")]
    sm["droppable"] = len(drops)
    sm["droppable_text"] = human(sum(r["bytes"] for r in drops))
    # The frames drop would refuse for the one reason nothing on this machine
    # can settle without downloading them, so the words beside the button can
    # say why the count is short of the shoot.
    sm["drop_evicted"] = sum(1 for r in raw if r["here"] and r["up"] and not r.get("up_local"))
    m = rmod.measure(rmod.Shoot(s.folder))
    cnt, tot, where = rmod.last_copy_renderings(m["shoot"])
    lib = {}
    try:
        lib = json.loads((ROOT / "library.json").read_text())
    except (OSError, ValueError):
        lib = {}
    keepers = amod.keepers_of(s.folder)
    age = amod.days_since_finished(s.folder)
    days = amod.retention(s.folder)
    return {
        "name": s.folder.name,
        "archive": sm, "states": counts, "order": list(STOR_BAR),
        "words": {k: _state_words(k, *spoken[k]) for k in STOR_BAR},
        "glyphs": {k: list(glyph[k]) for k in STOR_BAR},
        "line": _stor_line(sm, counts, lost, len(s.rows())),
        # derived_text excluded the last-copy renderings, because reclaim files
        # a rendering whose original is gone under ORIGINALS - right for
        # deciding what may be deleted, catastrophic as a sentence: the gym
        # shoot printed "56 KB of derived pixels" in the same paragraph as
        # "8.4 GB" of renderings living in the same three folders, and a person
        # reads 56 KB and concludes the cache is nothing. One figure, covering
        # both, with the split still available beside it.
        "cache": {"bytes": m["reclaimable"], "bytes_text": human(m["reclaimable"]),
                  "files": m["reclaimable_files"],
                  "derived_text": human(m["bytes"][rmod.DERIVED] + tot),
                  "rebuildable_text": human(m["bytes"][rmod.DERIVED]),
                  "refusals": m["refusals"],
                  "last_copy": {"count": cnt, "bytes_text": human(tot), "where": where}},
        "retain": {"days": days,
                   "source": ("shoot" if s.meta().get("retain_days") is not None
                              else "library" if "retain_days" in lib else "default"),
                   # What new shoots get, so the panel's "Use this for new
                   # shoots too" can say whether this number already is it.
                   "library_days": lib.get("retain_days"),
                   "finished": amod.finished(s.folder), "age_days": age,
                   "due_in_days": None if age is None else max(0, days - age),
                   "due": age is not None and age >= days,
                   "keepers": None if keepers is None else len(keepers),
                   "archived": sm["up"]},
        "icloud": amod.icloud_ready(),
        "free": rmod.shutil_free(ROOT), "free_text": human(rmod.shutil_free(ROOT)),
    }


# The pair of cells each state is drawn with when it stands for a whole group
# rather than for one frame, so the legend and the frame rows cannot drift.
_STOR_GLYPH = {"both": ("full", "full"), "icloud_only": ("none", "full"),
               "evicted": ("none", "hollow"), "here_evicted": ("hollow", "full"),
               "here_only": ("full", "none"), "unreadable": ("none", "none"),
               "missing": ("none", "gone")}


def default_retain() -> dict:
    """The library's number of days after a shoot is finished before its
    archived RAWs may be let go: `retain_days` in library.json, read the way
    archive.py reads it (`archive.retention`), or its year when there is none.
    `set` says whether he has ever set it. One number, shown and set in
    Settings ▸ Storage and by a shoot's "Use as default" alike - Settings had
    one of its own that nothing read."""
    try:
        lib = json.loads((ROOT / "library.json").read_text())
    except (OSError, ValueError):
        lib = {}
    if not isinstance(lib, dict):
        lib = {}
    try:
        days = int(lib.get("retain_days", 365))
    except (TypeError, ValueError):
        days = 365
    return {"days": days, "set": "retain_days" in lib}


def set_default_retain(days: int) -> None:
    """Write the library's number, keeping whatever else library.json says."""
    cfg = ROOT / "library.json"
    try:
        lib = json.loads(cfg.read_text())
    except (OSError, ValueError):
        lib = {}
    if not isinstance(lib, dict):
        lib = {}
    lib["retain_days"] = int(days)
    write_json_atomic(cfg, lib)


def library() -> dict:
    """The two facts the CLI's report ends on: what is free, what can be taken
    back, and the folders of photographs no command in this pipeline can see."""
    import reclaim as rmod
    from common import human
    free = rmod.shutil_free(ROOT)
    reclaimable = files = 0
    for p in rmod.shoots_under(ROOT):
        m = rmod.measure(rmod.Shoot(p))
        reclaimable += m["reclaimable"]
        files += m["reclaimable_files"]
    strays, stray_bytes = [], 0
    for p in rmod.strays_under(ROOT):
        m = rmod.measure(rmod.Shoot(p))
        strays.append({"name": p.name, "bytes_text": human(m["total"])})
        stray_bytes += m["total"]
    return {"free_text": human(free), "reclaimable_text": human(reclaimable), "files": files,
            "strays": strays, "strays_text": human(stray_bytes), "root": str(ROOT)}


# --------------------------------------------- planning something destructive
#
# The rule the CLI keeps is that it prints its list and removes nothing without
# --apply. The page keeps the same rule with the same code: "show me what would
# go" runs archive.py or reclaim.py WITHOUT --apply, as a job, and shows what
# came back. Nothing here re-derives what is safe to remove - if it did, the
# page and the terminal could tell him two different stories about the same
# shoot, and only one of them would be the one that runs.

STOR_VERBS = ("push", "drop", "pull", "expire", "reclaim")


def _s(n: int, one: str, many: str = "") -> str:
    """"1 photographs will cease to exist" reads like a machine wrote it, and
    this is the sentence he has to mean before anything is deleted."""
    return f"{n} {one if n == 1 else (many or one + 's')}"


def _stor_argv(s: Shoot, what: str, body: dict, apply: bool) -> list[str]:
    """Exactly the command line he would have typed himself."""
    if what == "reclaim":
        cmd = [PY, str(HERE / "reclaim.py"), "reclaim", str(s.folder)]
    elif what == "check":
        cmd = [PY, str(HERE / "reclaim.py"), "verify", str(s.folder)]
        return cmd + (["--record"] if body.get("record") else [])
    else:
        cmd = [PY, str(HERE / "archive.py"), what, str(s.folder)]
        if what == "push" and body.get("force"):
            cmd.append("--force")
        if what == "expire":
            if body.get("after") is not None:
                cmd += ["--after", str(int(body["after"]))]
            if body.get("keepers"):
                cmd.append("--keepers")
            if body.get("originals"):
                cmd.append("--yes-delete-originals")
    return cmd + (["--apply"] if apply else [])


def _parse_plan(what: str, text: str, body: dict) -> dict:
    """The figures the script itself printed, and none of its own.

    Every pattern below is one literal line of archive.py or reclaim.py. Nothing
    is computed here on purpose: a number sitting on a button that deletes
    photographs has to be the number the command printed, so if a line ever
    stops matching, the page loses its apply button instead of guessing. It
    fails towards refusing, which is the only direction it may fail in."""
    counts: dict[str, int] = {}
    bytes_text, label, why = "", "", ""
    refusals = [l.strip() for l in re.findall(r"^\s+- (.+)$", text, re.M)]
    ready = "REFUSED" not in text
    if what == "push":
        m = re.search(r"^\s*would copy (\d+) frames, (.+?), to ", text, re.M)
        if m:
            counts["frames"], bytes_text = int(m.group(1)), m.group(2)
            label = f"Copy {bytes_text} up"
        for pat in (r"^\s*(\d+ of this shoot's own RAWs are already evicted.*)$",
                    r"^\s*(iCloud Drive is not .*)$"):
            refusals += [x.strip() for x in re.findall(pat, text, re.M)]
        ready = ready and counts.get("frames", 0) > 0
    elif what == "drop":
        # A shoot he has not finished keeps its local RAWs, whatever iCloud
        # holds (archive.drop): a push before Finish is a backup, not a move.
        for pat in (r"^\s*(\S+ is not finished yet, so its RAWs .*)$", r"^\s*(iCloud Drive is not .*)$"):
            refusals += [x.strip() for x in re.findall(pat, text, re.M)]
        m = re.search(r"^\s*would free (.+?) by removing (\d+) originals", text, re.M)
        if m:
            bytes_text, counts["frames"] = m.group(1), int(m.group(2))
            label = f"Remove {_s(counts['frames'], 'original')} and free {bytes_text}"
        e = re.search(r"^\s*and (\d+) further hard links", text, re.M)
        counts["links"] = int(e.group(1)) if e else 0
        refusals += [f"kept {n}: {w}" for n, w in re.findall(r"^\s*kept\s+(\S+): (.+)$", text, re.M)]
        more = re.search(r"^\s*\.\.\. and (\d+) more$", text, re.M)
        if more:
            refusals.append(f"… and {more.group(1)} more refused for the same kinds of reason")
        ready = ready and counts.get("frames", 0) > 0
    elif what == "pull":
        m = re.search(r"(\d+) frames to bring back, (.+)$", text, re.M)
        if m:
            counts["frames"], bytes_text = int(m.group(1)), m.group(2)
            label = f"Bring {_s(counts['frames'], 'frame')} back"
        ready = ready and counts.get("frames", 0) > 0
    elif what == "expire":
        for key, pat in (("protected", r"^\s*(\d+)\s+frames you kept, protected"),
                         ("spare", r"^\s*(\d+)\s+archived spares"),
                         ("only", r"^\s*(\d+)\s+ONLY copies")):
            m = re.search(pat, text, re.M)
            if m:
                counts[key] = int(m.group(1))
        m = re.search(r"^\s*would remove (\d+) files from iCloud, (.+)$", text, re.M)
        if m:
            counts["files"], bytes_text = int(m.group(1)), m.group(2)
        # The first six names the command prints, which are the photographs
        # that would cease to exist. Shown as it shows them, never summarised.
        counts["doomed"] = counts.get("only", 0) if body.get("originals") else 0
        due = re.search(r"was finished (\d+) days ago; the policy lets go after (\d+)", text)
        if due:
            why = (f"{_due_name(text)} was finished {due.group(1)} days ago. The policy lets go after "
                   f"{due.group(2)}. Nothing is due for {int(due.group(2)) - int(due.group(1))} days.")
            ready = False
        elif counts.get("doomed"):
            label = f"Destroy {_s(counts['doomed'], 'photograph')}"
            if counts.get("spare"):
                label += f" and remove {_s(counts['spare'], 'spare')}"
        elif counts.get("files"):
            # "Every one of these frames stays on this Mac" was not true of all
            # of them: expire counts a frame as a spare when its local original
            # is there OR is itself evicted, and the second of those is the one
            # the panel draws `▢ ■` for and calls "the copy in iCloud is the one
            # with bytes". The claim the command actually supports is about the
            # original still being in the shoot, so that is the claim made.
            label = (f"Remove {_s(counts['files'], 'spare copy', 'spare copies')} from iCloud "
                     f"({bytes_text}). Every one of these frames keeps its original in this shoot.")
        ready = ready and bool(counts.get("files"))
    elif what == "reclaim":
        m = re.search(r"^\s+(\d+) files\s+(\S+ \S+)\s+total\s*$", text, re.M)
        if m:
            counts["files"], bytes_text = int(m.group(1)), m.group(2)
            label = f"Take back {bytes_text}"
        ready = ready and counts.get("files", 0) > 0
    return {"what": what, "counts": counts, "bytes_text": bytes_text, "label": label,
            "refusals": refusals, "ready": bool(ready and label), "why": why,
            "names": re.findall(r"^ {6}(\S+)$", text, re.M)}


def _due_name(text: str) -> str:
    m = re.search(r"^\s*(\S+) was finished", text, re.M)
    return m.group(1) if m else "this shoot"


def _stor_state(s: Shoot, what: str) -> str:
    """Where this shoot's photographs are, right now, as one hash.

    lstat only: asking whether a file is there is free, reading one downloads
    it, and this runs on every plan and every apply."""
    import archive as amod
    h = hashlib.sha256()
    for r in amod.status(s.folder)["rows"]:
        h.update(f"{r['name']}|{r['bytes']}|{int(bool(r['here']))}{int(bool(r.get('here_evicted')))}"
                 f"{int(bool(r['up']))}{int(bool(r.get('up_local')))}{int(bool(r.get('recorded')))}\n".encode())
    if what == "expire":
        # The answer key is what makes a frame protected, and the button that
        # rewrites it ("Re-read what I kept") is on this same card. A list drawn
        # against one key and applied against another would delete frames the
        # list showed as protected, and the number he typed would still match
        # the count the old list printed. The key is part of the state that
        # list was drawn against, so it belongs in the fingerprint.
        keep = amod.keepers_of(s.folder)
        h.update(("|".join(sorted(keep)) if keep is not None else "?no key?").encode())
        h.update(f"|{amod.retention(s.folder)}|{amod.days_since_finished(s.folder)}\n".encode())
    if what == "reclaim":
        import reclaim as rmod
        sh = rmod.Shoot(s.folder)
        for p, n in rmod.plan_removal(sh):
            h.update(f"{p}|{n}\n".encode())
        for x in rmod.refusals(sh):
            h.update(f"!{x}\n".encode())
    return h.hexdigest()


def _stor_token(s: Shoot, what: str, argv: list[str], parsed: dict, state: str) -> str:
    """A fingerprint of the exact state that list was drawn against.

    He confirms a list, not a verb. If a frame moved between the list being
    drawn and the button being pressed, the thing he confirmed is not the thing
    that would happen, so apply recomputes this and refuses when it has shifted.

    `state` is handed in rather than measured here, because it has to be the
    state the dry run itself read - and this is also called from apply, which
    can be days later. Measuring it here, at the moment of the call, made the
    token agree with itself and with nothing else: a list drawn before two more
    local RAWs were dropped could be read back, minted a token that validated,
    and applied. He confirmed "Destroy 2 photographs" over two named frames and
    four ceased to exist. See _plan_state."""
    h = hashlib.sha256()
    h.update(("\n".join(argv) + "\n").encode())
    h.update(json.dumps(parsed.get("counts"), sort_keys=True).encode())
    h.update((parsed.get("bytes_text") or "").encode())
    h.update(state.encode())
    return h.hexdigest()


def _reel_mod():
    """reel.py, imported once. It lives in the private repo and is symlinked
    in, so a public build has no such file and the card says so rather than
    failing at the first click."""
    if not (HERE / "reel.py").exists():
        return None
    if "reel" not in _REEL:
        import importlib
        try:
            _REEL["reel"] = importlib.import_module("reel")
        except Exception as e:  # noqa: BLE001
            _REEL["reel"] = None
            _REEL["why"] = str(e)
    return _REEL.get("reel")


_REEL: dict = {}


_EXPORTS: dict = {}
_EXPORTS_FOR = 5.0
# When the lister last answered. A map walked before then is not used after:
# the lister may have just told the page a frame is exported, and the page
# then asks for that frame's exported picture.
_EXPORTS_SINCE = [0.0]


def _reel_exports(mod, folder: Path, src: Path | None) -> dict:
    """The reel module's map of a shoot's exports, kept for a few seconds.

    A grid of thirteen tiles asks /reelthumb/ thirteen times at once, and each
    ask walked every folder an export can land in. A map is used for 5 s, and
    never once the lister has answered since it was walked: the lister's
    answer is what tells the page a frame is exported, and a map from before
    it would serve that frame's RAW under the page's "exported" picture for
    the rest of the visit. The PhotoLab wait's own count does not come
    through here: it is read afresh at every poll."""
    key = (str(folder), str(src or ""))
    now = time.monotonic()
    hit = _EXPORTS.get(key)
    if hit and hit[0] >= _EXPORTS_SINCE[0] and now - hit[0] < _EXPORTS_FOR:
        return hit[1]
    have = mod.exports(folder, src)
    _EXPORTS[key] = (now, have)
    return have


def reel_options(s: Shoot, burst: str = "", src: str = "") -> dict:
    """What the Cut a reel card draws: the bursts worth cutting, the frames of
    the one he has chosen with an `exported` flag on each, and the folders his
    exports were found in so he can point it at one."""
    out: dict = {"sequences": [], "cuts": [], "frames": [], "sources": [], "exports_found": 0, "exports_dir": ""}
    if not (HERE / "reel.py").exists():
        return {**out, "error": "reels are not part of this build"}
    cmd = [PY, str(HERE / "reel.py"), str(s.folder), "--list", "--json"]
    if burst:
        cmd += ["--burst", burst]
    if src:
        cmd += ["--exports", src]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        line = [x for x in r.stdout.splitlines() if x.startswith("{")]
        if line:
            out.update(json.loads(line[-1]))
        else:
            out["error"] = (r.stderr or r.stdout or "the lister said nothing").strip()[-400:]
    except (subprocess.SubprocessError, ValueError) as e:
        out["error"] = str(e)
    out["reels"] = s.reels()
    out["reel_dir"] = str(s.folder / "reels")
    _EXPORTS_SINCE[0] = time.monotonic()
    return out


def reel_exported(s: Shoot, burst: str) -> int:
    """How many frames of this burst have an exported JPEG right now."""
    mod = _reel_mod()
    if mod is None or not burst:
        return 0
    try:
        rows = read_cull(s.cull)
        stems = {Path(f).stem for f, r in rows.items() if str(r.get("burst", "")) == str(burst)}
        have = mod.exports(s.folder, None)
        return sum(1 for st in stems if st in have)
    except (OSError, KeyError, AttributeError):
        return 0


def _kind_log(s: Shoot, kind: str) -> Path:
    """One log per kind of job, not one log for all of them.

    ingest, cull and presets all wrote cull/studio.log and Jobs.start opens it
    "w", so the first cull destroyed the ingest's proof: the only record that
    1,157 files were read back off the disk and matched went under the cull
    that followed it, and the ingest card then had nothing to quote but a count
    of files. Three names, and the copy's own account of itself survives the
    rest of the shoot.

    s.cull unconditionally, which is where /api/ingest has always written the
    copy's log by hand. This asked whether cull/ existed yet, and on the first
    cull of a shoot it does not: the first run's log went to <shoot>/logs and
    every run after it to <shoot>/cull/logs, so the log named "the cull's" was
    whichever of two files the reader happened to look in. Jobs.start makes the
    parent, and every job that reaches here is one that is about to fill cull/
    anyway, so nothing is created that the run itself would not have created.
    _ingest_note still reads the old place, because a shoot copied before today
    has its proof there."""
    return s.cull / "logs" / f"{kind}.log"


def _job_log(s: Shoot) -> Path:
    """Where a storage job writes its log: beside the other logs when the cull
    folder is there, and at the shoot's top level when it is not.

    Jobs.start() mkdirs the log's parent, which is right for a cull - it is
    about to fill that folder anyway - and wrong for everything under this
    panel. ducksAndDeadlifts is 98 loose ARWs with no raw/ and no cull folder,
    so s.cull is a `_cull` that has never existed, and pressing "Check every
    original" on it created that folder in his shoot. Nothing here writes
    anything he asked for; it must not leave a folder behind either."""
    return (s.cull if s.cull.is_dir() else s.folder) / "studio.log"


def _plan_log(s: Shoot) -> Path:
    """The dry run's own log, never the job log the apply writes over. Reading
    a plan back out of a file the next command overwrites is how a page ends up
    showing one list and running another. Beside _job_log and under its rule."""
    return _job_log(s).with_name("storage-plan.log")


def _plan_state(s: Shoot) -> Path:
    """Where the dry run's own state is written down, beside its log.

    A log alone says what WOULD go; it does not say what the shoot looked like
    when that was worked out, and a list is only a promise about the shoot it
    was read from. Written just before the dry run starts and compared against
    the live shoot on every read, so a list that has been overtaken loses its
    button instead of being handed a fresh token that agrees with it."""
    return _plan_log(s).with_name("storage-plan.state")


def _stor_body(q: dict) -> dict:
    """The plan's flags off a query string, so a GET asks for exactly the plan
    a POST drew."""
    def flag(k):
        return q.get(k, ["0"])[0] in ("1", "true", "yes")
    after = None
    if q.get("after"):
        try:
            after = int(q["after"][0])
        except ValueError:
            after = None
    return {"force": flag("force"), "keepers": flag("keepers"),
            "originals": flag("originals"), "after": after}


def read_plan(s: Shoot, what: str, body: dict) -> dict:
    """The plan on disk, if it is the plan that was asked for AND the shoot it
    was drawn from is still the shoot that is there."""
    argv = _stor_argv(s, what, body, apply=False)
    log = _plan_log(s)
    text = log.read_text(errors="replace") if log.exists() else ""
    head = text.splitlines()[0] if text else ""
    if head != "$ " + " ".join(argv):
        return {"error": "that list was drawn for something else. Ask for it again."}
    # The list is only about the shoot it was read from. A plan drawn before
    # two more local RAWs were dropped still printed its two names and its
    # "Destroy 2 photographs", and expire --apply would go on to destroy four:
    # the command recomputes, the piece of paper does not. So the drawing is
    # what is compared, not the reading.
    try:
        drawn = _plan_state(s).read_text().strip()
    except OSError:
        drawn = ""
    state = _stor_state(s, what)
    if drawn != state:
        # Flagged stale rather than just failed, so the page does what it
        # already does when a list is overtaken: say so and draw a new one.
        # A dead button left sitting under an alert is a button he presses
        # again.
        return {"stale": True,
                "error": "this shoot has changed since that list was drawn — here is the list again"}
    parsed = _parse_plan(what, text, body)
    # The command's own words, minus the line it prints for the progress bar.
    # archive.py and reclaim.py now mark their stages, and a dry run marks them
    # too, so "@@ expire 0 4" was appearing in the middle of the list he is
    # asked to confirm. Jobs.status() has always kept these out of the log for
    # the same reason.
    parsed["lines"] = [w for l in text.splitlines()[1:] if l.strip() and not l.startswith("@@ ")
                       for w in [plan_words(l)] if w is not None]
    parsed["token"] = _stor_token(s, what, argv, parsed, state)
    return parsed


# The command line's own footers, as the app puts them. archive.py and
# reclaim.py end a dry run with how to do it for real at a terminal - "nothing
# was removed. Add --apply to remove exactly this." - and the plan sheet printed
# that right above its red Remove button, so he read "nothing was removed"
# beside the button that removes. A footer that only names a flag is dropped;
# one that says something true is put in the app's words. The commands print
# what they print: this is the page's reading of it, and the list's token does
# not depend on it.
PLAN_DROP = ("nothing was removed. Add --apply", "nothing was copied. Add --apply")
PLAN_WORDS = {
    "Those are left alone. Add --yes-delete-originals to include them.":
        'Those are left alone. Tick "Including the frames with no other copy" to include them.',
    "nothing to remove.": "Nothing to remove.",
}
PLAN_PATTERNS = [
    (re.compile(r"Nothing is due\. Override for this run with --after \d+\."), "Nothing is due yet."),
    (re.compile(r"--record writes the (\d+) missing checksums into \S+\."),
     r"\1 originals have no checksum on record yet."),
    # archive.py says this at a terminal; the app is told its own sentence
    # (`for_the_app`), and this is its words should the typist's reach it.
    (re.compile(r"bring them down again with: \./pl archive pull \S+ --apply"),
     "Bring the RAWs Back brings them down again."),
]


def sentence_case(text: str) -> str:
    """A refusal as the app prints it: a sentence, starting with a capital.

    The refusals below were written for the web page, which put them after a
    word of its own, so they start in lower case - "the engine did not answer
    in time", "that shoot's folder is not there any more" - and the app prints
    them where every other sentence is capitalised. Only a first word that is
    a plain lower-case word is touched - the whole word, up to a space or a
    colon, so "lake-night already exists" is not read as "lake" and printed as
    "Lake-night" - and never one that is the name of a shoot ("lake already
    exists" is about the shoot called lake) or of something always written in
    lower case, like ffmpeg or darktable."""
    m = re.match(r"[^\s:,;]+", text)
    if not m:
        return text
    word = m.group(0).rstrip(".!?")
    if not re.fullmatch(r"[a-z][a-z']*", word) or word in LOWER_CASE_NAMES:
        return text
    try:
        if (shoots_dir() / word).exists():
            return text
    except OSError:
        pass
    return text[0].upper() + text[1:]


# Names written in lower case wherever they appear, so a refusal that starts
# with one keeps it: "ffmpeg was not found", "darktable was not found".
LOWER_CASE_NAMES = {"ffmpeg", "ffprobe", "exiftool", "darktable", "darktable-cli"}


def plan_words(line: str) -> str | None:
    """One line of a storage command's output as the app shows it, or None
    for a line that is only there for a terminal."""
    bare = line.strip()
    if any(bare.startswith(p) for p in PLAN_DROP):
        return None
    lead = line[:len(line) - len(line.lstrip())]
    if bare in PLAN_WORDS:
        return lead + PLAN_WORDS[bare]
    for pattern, said in PLAN_PATTERNS:
        if pattern.fullmatch(bare):
            return lead + pattern.sub(said, bare)
    return line


STOR_TITLES = {"push": "copying the RAWs of {n} to iCloud",
               "drop": "removing the local RAWs of {n}",
               "pull": "bringing the RAWs of {n} back",
               "expire": "letting go of the RAWs of {n} in iCloud",
               "reclaim": "taking back {n}'s cache",
               "check": "checking every original of {n}"}


# ------------------------------------------ the list of work he asked for
#
# "Also provide a job queue so i can just tap all the jobs i need to happen."
#
# He comes home from a card with 1,500 frames on it and wants to say, in one
# pass: copy this card, cull it, write the presets on that one, gather the
# keepers, cut a reel of burst 54, make the Instagram copies, push the finished
# shoot's RAWs to iCloud - and then leave. Every one of those is a separate
# trip back to the machine today, because the slot holds one job and the only
# thing he could do about a second was come back and press the button again.
#
# So the line Jobs already kept - one request waiting behind the one running,
# put there by a route - becomes a list he fills on purpose. Three rules make
# it a list of his intentions rather than a list of commands:
#
# 1. What is stored is the KIND, the SHOOT and the options he chose. The
#    command line is built from those at the moment the job starts.
# 2. The shoot is looked at again first. An hour can pass between the tap and
#    the turn, and a shoot can change under a plan: the card can be unplugged,
#    the cull can be re-run, the exports can be moved. An item that can no
#    longer be done is skipped with a sentence he can read afterwards, and
#    never dropped in silence.
# 3. It is written to disk. It is what he asked for, not a detail of this
#    process, and quitting the app at midnight must not throw it away.


class NotNow(Exception):
    """This piece of work cannot be done, in one sentence he can read.

    Raised by a builder both when the item is offered to the list and again
    just before it would start. The second one is the one that matters: it is
    what turns "it did nothing and said nothing" into a line in the list."""


def _q_shoot(name: str) -> Shoot:
    if not isinstance(name, str) or name in (".", "..") or not re.fullmatch(r"[A-Za-z0-9._ -]+", name or ""):
        raise NotNow("that is not a shoot on this Mac")
    p = shoots_dir() / name
    if not p.is_dir():
        raise NotNow(f"there is no shoot called {name} any more")
    return Shoot(p)


def _q_frames(s: Shoot) -> int:
    return sum(1 for p in s.raw.iterdir() if p.suffix.lower() in RAW_EXTS) if s.raw.is_dir() else 0


def _q_burst(o: dict) -> str:
    which = str(o.get("burst") or o.get("id") or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9._/-]{1,40}", which):
        raise NotNow("no burst was named, so there is nothing to make")
    return which


def _b_ingest(name: str, o: dict) -> dict:
    """Copy the Card. The one piece of work whose shoot does not exist yet -
    and the one most likely to have gone stale by its turn, because the card
    it is about can be taken out of the Mac between the tap and the turn."""
    card = str(o.get("card") or "")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name or ""):
        raise NotNow("name the shoot like 2026-10-04-lake")
    verify = o.get("verify") or "in-flight"
    if verify not in ("in-flight", "end", "none"):
        raise NotNow("check the copy while copying, again at the end, or not at all")
    if card not in cards():
        raise NotNow(f"{Path(card).name or 'that memory card'} is not in this Mac any more")
    into = bool(o.get("into"))
    over = _copy_into(name, card, into)
    return {"title": f"copying the card into {name}",
            "does": f"Copy {Path(card).name} into {name}" +
                    {"in-flight": ", checking as it copies.", "end": ", checking it again at the end.",
                     "none": ", without checking it."}[verify],
            "cmd": [PY, str(HERE / "ingest.py"), card, name, "--verify", verify],
            "log": shoots_dir() / name / "cull" / "logs" / "ingest.log",
            # The one copy log already there this run may write over, looked
            # at again the moment before it starts (_copy_into).
            "over": over,
            # A card added to a shoot keeps the shoot's kind; the card and
            # the check asked of it are the last copy's.
            "then": (lambda: Shoot(shoots_dir() / name).set_meta(card=card, verify=verify)) if into else
                    (lambda: Shoot(shoots_dir() / name).set_meta(kind=kind_of(o.get("kind")), card=card,
                                                                 verify=verify)),
            "after_done": _follow_with_a_cull(name) if o.get("then_cull") else None}


def _cull_after_copy(jobs: "Jobs", name: str, copy_id: int) -> None:
    """Move a cull of `name` waiting on the list to just behind the copy into
    it that was put there after it."""
    with jobs.lock:
        ids = [q["id"] for q in jobs.queue]
        cull = next((q["id"] for q in jobs.queue if q.get("kind") == "cull" and q.get("shoot") == name), None)
    if cull is None or copy_id not in ids or ids.index(cull) > ids.index(copy_id):
        return
    ids.remove(cull)
    ids.insert(ids.index(copy_id) + 1, cull)
    jobs.reorder(ids)


def _follow_with_a_cull(name: str):
    """What a card copy that finished is followed by: the cull of its shoot,
    put on the list with his last shoot's settings (_cull_settings), so it
    starts by itself - now, or behind whatever he had already put there.

    He copied the card, clicked a small link, set the two settings back, and
    pressed Cull It: three trips for a step he never skips, and the seven
    minutes of the cull only started once he came back. Nothing is added for
    a shoot a cull of which is already running or waiting (a second card
    copied into it before its cull started: one cull, over both), nor for a
    shoot already culled: a cull of that is his to ask for, nor for one any
    copy into which stopped or failed (_unfinished_copy). The list's own
    rules hold - held, it waits; the shoot is looked at again when its turn
    comes."""
    def follow() -> None:
        jobs = getattr(Handler, "jobs", None)
        if jobs is None:
            return
        d = shoots_dir() / name
        if not d.is_dir() or Shoot(d).rows():
            return
        # Nor while any copy into it did not finish: a card of it is still
        # half there, and a cull of it would be a cull of part of the night.
        if _unfinished_copy(Shoot(d)) is not None:
            return
        with jobs.lock:
            asked = any(q.get("kind") == "cull" and q.get("shoot") == name for q in jobs.queue)
            running = (jobs.kind == "cull" and jobs.shoot == name
                       and jobs.proc is not None and jobs.proc.poll() is None)
        if asked or running:
            return
        jobs.add("cull", name, {}, why="the card was copied")
    return follow


def _b_cull(name: str, o: dict) -> dict:
    s = _q_shoot(name)
    n = _q_frames(s)
    if not n:
        raise NotNow(f"there are no photographs in {name} any more")
    # What he asked for with this cull; else the shoot's own; else what his
    # last shoot was culled with (_cull_settings), which is what the Cull
    # page showed him and what a cull started after a copy runs with.
    was_style, was_focus, _ = _cull_settings(s)
    style, focus = _cull_pair(o.get("style") or was_style, o.get("focus") or was_focus)
    cmd = [PY, str(HERE / "cull.py"), str(s.raw), "--out", str(s.cull), "--copy",
           "--style", style, "--face-floor", f"{focus:.2f}"]
    if o.get("presets"):
        cmd += ["--presets", "--dop"]
    top = int(o.get("top") or 0)
    if top > 0:
        cmd += ["--top", str(top), "--top-by", "scene"]
    elif EXTM and hasattr(EXTM, "cull_args") and s.meta().get("kind") == EXTM.KIND:
        cmd += list(EXTM.cull_args(s))
    return {"title": f"culling {name}", "cmd": cmd, "log": _kind_log(s, "cull"),
            "does": f"Look at {n:,} frames and put the ones worth keeping forward.",
            "then": lambda: s.set_meta(style=style, focus=focus)}


def _b_presets(name: str, o: dict) -> dict:
    s = _q_shoot(name)
    if not _q_frames(s):
        raise NotNow(f"there are no photographs in {name} any more")
    cmd = [PY, str(HERE / "presets.py"), str(s.raw), "--out", str(s.cull), "--dop"]
    if o.get("force"):
        cmd.append("--force")
    if o.get("picks_only"):
        cmd.append("--picks-only")
    editor = o.get("editor") or s.meta().get("editor") or "dxo"
    if editor not in ("dxo", "lightroom", "rawtherapee", "darktable"):
        editor = "dxo"
    cmd += ["--editor", editor]
    return {"title": f"presets for {name}", "cmd": cmd, "log": _kind_log(s, "presets"),
            "does": "Write the starting edit onto every frame that gets one.",
            "then": lambda: s.set_meta(editor=editor)}


def _b_gather(name: str, o: dict) -> dict:
    """The folder of his keepers. It runs as a job here rather than inside the
    request the way /api/open does, because a list he walked away from cannot
    hold a request open for two minutes waiting for hard links."""
    s = _q_shoot(name)
    if not (s.cull / "cull.csv").exists():
        raise NotNow(f"{name} has not been culled yet, so there is nothing to gather")
    return {"title": f"gathering the keepers of {name}",
            "does": "Build the folder of your keepers, each with its preset beside it.",
            "cmd": [PY, str(HERE / "gather.py"), str(s.folder)] + (["--fresh"] if o.get("fresh") else []),
            "log": _kind_log(s, "gather"), "then": None}


def _b_spread(name: str, o: dict) -> dict:
    s = _q_shoot(name)
    if not (HERE / "spread.py").exists():
        raise NotNow("that is not part of this build")
    which = _q_burst(o)
    # --standard and --open because the button says "Standardise the whole
    # burst & open in PhotoLab" and did neither. Both are passed explicitly
    # rather than left to spread.py's own fallback: the button names what it
    # does, so it should ask for it, and a reader comparing the label to this
    # line should not have to go into spread.py to find out whether they agree.
    return {"title": f"preparing burst {which} for PhotoLab",
            # What --standard does, not what copying an edit would: the shoot's
            # own preset beside every frame without a sidecar, exposure levelled
            # across the burst. spread.py's help for the flag: "do not copy an
            # edit of yours". This line is what the list of work shows.
            "does": f"Write the shoot's own preset beside every frame of burst {which} you have "
                    f"not edited, exposure levelled across the burst, and open it in PhotoLab.",
            "cmd": [PY, str(HERE / "spread.py"), str(s.folder), "--burst", which, "--standard", "--open"],
            "log": _kind_log(s, "spread"), "then": None}


def _b_reel(name: str, o: dict) -> dict:
    s = _q_shoot(name)
    if not (HERE / "reel.py").exists():
        raise NotNow("reels are not part of this build")
    fmt = o.get("format") or "cut"
    if fmt not in ("sequence", "cut", "loop", "boomerang", "timelapse"):
        raise NotNow("a reel is a cut, a sequence, a loop, a boomerang or a timelapse")
    cmd = [PY, str(HERE / "reel.py"), str(s.folder), "--format", fmt]
    which = ""
    if fmt == "timelapse":
        tag = str(o.get("tag") or "").strip()
        if tag:
            if not re.fullmatch(r"[A-Za-z0-9 ._&/-]{1,60}", tag):
                raise NotNow("that is not a name from the card")
            cmd += ["--tag", tag]
        every = o.get("every")
        if isinstance(every, (int, float)) and 1 <= every <= 100:
            cmd += ["--every", str(int(every))]
    else:
        which = _q_burst(o)
        cmd += ["--burst", which]
    picked = [str(x) for x in (o.get("frames") or [])]
    if picked:
        if not all(re.fullmatch(r"[A-Za-z0-9._-]{1,60}", x) for x in picked):
            raise NotNow("that is not a frame name")
        cmd += ["--frames", ",".join(picked)]
    follow = str(o.get("follow") or "action")
    if follow not in ("action", "fists", "people", "none"):
        raise NotNow("the crop follows the action, the fists, the people, or nothing")
    cmd += ["--follow", follow]
    size = str(o.get("size") or "1080")
    if size not in ("1080", "1440", "2160", "native"):
        raise NotNow("that is not a size")
    cmd += ["--size", size]
    if o.get("ramp"):
        cmd += ["--ramp"]
    src = str(o.get("exports") or "")
    if src:
        d = Path(src).expanduser()
        if not d.is_dir():
            raise NotNow(f"there is no folder at {d} any more")
        cmd += ["--exports", str(d)]
    try:
        if o.get("fps") is not None:
            cmd += ["--fps", f"{float(o['fps']):g}"]
    except (TypeError, ValueError):
        raise NotNow("the speed has to be a number") from None
    plan = o.get("plan") or {}
    then = None
    if isinstance(plan, dict) and plan:
        pf = s.cull / "reel-plan.json"
        cmd += ["--plan", str(pf)]
        then = lambda: write_json_atomic(pf, plan)  # noqa: E731
    return {"title": reel_title(which, fmt),
            "does": (f"Cut burst {which} into a clip." if which else "Cut the day into a timelapse."),
            "cmd": cmd, "log": _kind_log(s, "reel"), "then": then}


def reel_title(which: str, fmt: str) -> str:
    """A reel's job title, the format in his words: the one the engine calls
    "cut" is Push In on screen, so that "cut" only ever means making the reel
    (Cut It). It read "cutting burst 93 as a cut"."""
    shown = {"cut": "push-in"}.get(fmt, fmt)
    return f"cutting burst {which} as a {shown}" if which else f"cutting a {shown}"


def _ig_ratios() -> tuple[str, ...]:
    """The shapes instagram.py will actually take, from instagram.py."""
    try:
        sys.path.insert(0, str(HERE))
        import instagram as _ig
        return tuple(_ig.RATIOS)
    except Exception:  # noqa: BLE001
        return ("3:4", "4:5")


def _or_list(items) -> str:
    items = list(items)
    return items[0] if len(items) == 1 else " or ".join([", ".join(items[:-1]), items[-1]])


# A frame's name as the Instagram routes take it: a stem, and nothing a
# command line or a path could read as anything else.
IG_STEM = re.compile(r"[A-Za-z0-9._-]{1,60}")


def _cop(n: int) -> str:
    return f"{n} Instagram cop{'y' if n == 1 else 'ies'}"


def _names(stems: list[str], most: int = 3) -> str:
    """"TSC0001, TSC0002 and 4 more": the photographs a sentence is about."""
    if len(stems) > most:
        return f"{', '.join(stems[:most])} and {len(stems) - most} more"
    return stems[0] if len(stems) == 1 else f"{', '.join(stems[:-1])} and {stems[-1]}"


def _left_for_him(stems: list[str], why: str) -> str:
    """"TSC0001 was exported again since and is left for you to look at." """
    one = len(stems) == 1
    return f"{_names(stems)} {'was' if one else 'were'} {why} and {'is' if one else 'are'} left for you to look at."


def _b_instagram(name: str, o: dict) -> dict:
    """Make the Instagram copies. With `stems`, exactly those frames, at the
    shape their cuts were worked out at: the step sends the ones it shows, and
    the command names no shape of its own, so what is made is what was drawn.
    Without, every export of the shoot, as an item already on someone's list
    was written."""
    s = _q_shoot(name)
    stems = o.get("stems")
    if stems is not None:
        if not isinstance(stems, list) or not all(isinstance(x, str) and IG_STEM.fullmatch(x) for x in stems):
            raise NotNow("That is not a frame name.")
        if not stems:
            raise NotNow("No photographs were named, so there is nothing to make.")
        # The ones whose cut is still the one he was shown when this is
        # built. An item left on the list overnight makes what it still can:
        # a photograph whose export has gone is not made from nothing, and
        # one exported again since is not made at all - instagram.py would
        # look for its subject again and cut a copy he never saw. It is
        # named, and left on the wall to be worked out and looked at.
        _ig_forget(s)
        _, frames, _ = _ig_described(s)
        state = {f["stem"]: f["state"] for f in frames}
        named = list(dict.fromkeys(stems))
        keep = [x for x in named if state.get(x) == "planned"]
        left = [_left_for_him(xs, why) for xs, why in (
            ([x for x in named if state.get(x) == "stale"], "exported again since"),
            ([x for x in named if state.get(x) == "unplanned"], "not worked out yet")) if xs]
        if not keep:
            raise NotNow(" ".join(left) if left else "None of those photographs is exported any more.")
        n = len(keep)
        cmd = [PY, str(HERE / "instagram.py"), str(s.folder), *keep]
        does = " ".join([f"Make {n} Instagram-sized cop{'y' if n == 1 else 'ies'}, cut as shown.", *left])
    else:
        # Every photograph the wall shows, by name: `--all` is every JPEG
        # instagram.py can find, reels/ and upload/ included.
        keep = list(_ig_exports(s))
        n = len(keep)
        if not n:
            raise NotNow(f"nothing of {name} has been exported yet, so there is nothing to copy")
        cmd = [PY, str(HERE / "instagram.py"), str(s.folder), *keep]
        does = f"Make Instagram-sized copies of {n:,} finished photograph{'' if n == 1 else 's'}."
    # A shape only when this item says one. Nothing that puts this on the list
    # sends a shape today, and it used to send 3:4 and fit anyway - so a shoot
    # whose crops he had worked out at 4:5 in the studio, and looked at, and
    # adjusted, was remade at 3:4 by the item he left for the night. Given
    # neither, the run makes what was worked out (instagram.py's own default).
    if o.get("ratio") is not None:
        ratio = str(o["ratio"])
        # Asked of instagram.py rather than listed here. The two lists had
        # parted: this one took "1:1" and the script's --ratio does not, so a
        # square left on the list was accepted at the moment he added it and
        # died with argparse's own "invalid choice" when its turn came, hours
        # later, with the shoot's log the only place it was said.
        if ratio not in _ig_ratios():
            raise NotNow(f"Instagram copies are made at {_or_list(_ig_ratios())}, not {ratio}")
        cmd += ["--ratio", ratio]
    if o.get("landscape") is not None:
        landscape = str(o["landscape"])
        if landscape not in ("fit", "crop"):
            raise NotNow("a landscape is left whole or cut to portrait")
        cmd += ["--landscape", landscape]
    return {"title": f"making {_cop(n)} of {name}", "does": does,
            "cmd": cmd, "log": _kind_log(s, "instagram"), "then": None}


def _b_stor(what: str):
    """push, pull and check. The three storage jobs that add a copy or read one
    back, and therefore the three that may be left to run while he is asleep.

    drop, expire and reclaim's apply are not here and must not be: see
    NEVER_QUEUED."""
    def build(name: str, o: dict) -> dict:
        s = _q_shoot(name)
        if not _q_frames(s):
            raise NotNow(f"there are no photographs in {name} any more")
        # A push of a shoot he has not finished is not refused here, or in
        # archive.py: it copies and removes nothing, and the backup the same
        # night is the point. Removing the local RAWs is what waits for
        # Finish, and that is never on the list (NEVER_QUEUED).
        verb = "check" if what == "check" else what
        return {"title": STOR_TITLES[verb].format(n=name),
                "does": {"push": "Copy the RAWs to iCloud and read every one of them back.",
                         "pull": "Bring the RAWs back down from iCloud.",
                         "check": "Read every original back off the disk and check it."}[verb],
                "cmd": _stor_argv(s, verb, o, apply=(verb != "check")),
                "log": _job_log(s), "then": None}
    return build


# What each plan says it does under its row in Up Next, where the app names
# the row for what it checks ("Check what would be copied"). All five said
# "Work out what would go, and show you the list": under a copy to iCloud,
# the opposite of the row's own name, and "the list" was Up Next's old name.
PLAN_DOES = {"push": "Check what would be copied to iCloud, and show you what it found.",
             "pull": "Check what would come back from iCloud, and show you what it found.",
             "drop": "Check which local RAWs would be removed, and show you what it found.",
             "expire": "Check which RAWs in iCloud would be let go, and show you what it found.",
             "reclaim": "Check what cache would be taken back, and show you what it found."}


def _b_plan(what: str):
    """"Do It After" on a storage list. The dry run is put in the line rather
    than turned away, and the state it is measured against is written when it
    actually starts - not now - because a list is only a promise about the
    shoot it was read from."""
    def build(name: str, o: dict) -> dict:
        s = _q_shoot(name)
        return {"title": f"working out what would go in {name}",
                "does": PLAN_DOES[what],
                "cmd": _stor_argv(s, what, o, apply=False), "log": _plan_log(s),
                "then": lambda: write_atomic(_plan_state(s), _stor_state(s, what))}
    return build


# Every kind he may put on the list, and how each one is built when its turn
# comes. Nothing reaches the line that is not in here.
WORK: dict[str, object] = {
    "ingest": _b_ingest,
    "cull": _b_cull,
    "presets": _b_presets,
    "gather": _b_gather,
    "spread": _b_spread,
    "reel": _b_reel,
    "instagram": _b_instagram,
    "stor-push": _b_stor("push"),
    "stor-pull": _b_stor("pull"),
    "stor-check": _b_stor("check"),
    "plan-push": _b_plan("push"),
    "plan-pull": _b_plan("pull"),
    "plan-drop": _b_plan("drop"),
    "plan-expire": _b_plan("expire"),
    "plan-reclaim": _b_plan("reclaim"),
}

# What may never be put on the list, and the sentence he is told instead.
#
# Every one of these removes photographs, and every one of them is measured
# against a list he read at that moment: the plan is drawn, he reads it, the
# token he sends back IS that list. A confirmation held in a queue for an hour
# is a confirmation of something nobody measured - the shoot can be culled
# again, exported again or brought back down in the meantime, and the list the
# apply runs against is not the list he said yes to.
#
# So the answer is no, and it is the same no in the engine and in the app: the
# control is not hidden and then refused, it says this where he can read it.
NEVER_QUEUED = {
    "stor-drop": "Removing the local RAWs is not something to leave on a list. It runs against the "
                 "list you read a moment before, and a list an hour old is about a shoot nobody has "
                 "looked at since. Draw it again and press it while it is in front of you.",
    "stor-expire": "Letting go of RAWs in iCloud is not something to leave on a list. Nothing on this "
                   "Mac would hold those photographs afterwards, and the count you typed has to be "
                   "the count of the list in front of you.",
    "stor-reclaim": "Taking the cache back is not something to leave on a list. It runs against the "
                    "list you read a moment before, and a list an hour old is about a shoot nobody "
                    "has looked at since.",
}


def queue_view(jobs: "Jobs") -> dict:
    """The list, as one object, for the screen whose whole subject it is.

    The running job is in here too, because "what is happening and what is
    waiting" is one question and answering it out of two readings taken a
    moment apart is how a screen comes to show four waiting behind a job that
    finished."""
    st = jobs.status()
    return {"queue": st["queue"], "held": st["queue_held"], "held_after": st["queue_held_after"],
            "cut_off": st["queue_cut_off"],
            "waiting": st["queue_waiting"],
            "listed": st["queue_listed"], "fraction": st["queue_fraction"],
            "pass": st["queue_pass"], "done": st["queue_done"], "skipped": st["queue_skipped"],
            "running": st["running"], "from_list": st["queue_from_list"], "id": st["id"],
            "kind": st["kind"], "title": st["title"], "shoot": st["shoot"],
            "label": st["label"], "remaining_text": st["remaining_text"],
            "job_fraction": st["fraction"], "background": st["background"]}


def work_build(kind: str, shoot: str, opts: dict) -> dict:
    """The command for one item, or NotNow with the reason it cannot be done.

    Called twice in every item's life: once when he offers it to the list, so
    nothing that cannot run is ever put there, and once the moment before it
    starts, because that is the only reading that is about the shoot as it is."""
    if kind in NEVER_QUEUED:
        raise NotNow(NEVER_QUEUED[kind])
    f = WORK.get(kind)
    if f is None:
        raise NotNow("that is not something this can be asked to do")
    return f(shoot, opts or {})


# ------------------------------------------ what the cull has learned
#
# One panel, and the four things he can do about it. Everything in this block
# is thin on purpose: the models, the keeper check, the rules and the words all
# live in learned.py, so the page and the terminal can never tell him two
# different stories about what the cull has learned. Learning runs as an
# ordinary job through the same runner as a cull, with the same bar and the
# same Stop button.

# What it is doing, said the way the panel says it. One stage per thing the
# learning run actually does, in the order it does them, because a single
# "learning" stage covering four minutes of work is a bar that does not move.
#
# "exports" is the stretch that used to report nothing at all: after the last
# `@@ measuring` mark the run goes on to read the finished export of every one
# of those frames, which on his library is minutes. The bar sat at 65% for all
# of it, the label went on saying "288 of 288", and the only thing he could
# conclude from that screen was that the machine had hung.
STAGE_WORDS.update({"gathering": ("reading what you kept", "steps"),
                    "measuring": ("measuring the frames you finished", "frames"),
                    "exports": ("reading the edits you exported", "frames"),
                    "edit": ("working out your starting edit", "steps"),
                    "reasons": ("working out why you drop frames", "steps"),
                    "bursts": ("working out which frames of a burst you keep", "steps"),
                    "learning": ("learning from your finished shoots", "steps"),
                    "checking": ("checking against the photos you kept", "steps")})
# Its kind is "learn-learn" so Jobs.status() weighs these stages rather than a
# cull's (see the verb split there).
#
# Measured, not guessed. One full run over a library with 288 finished frames,
# polled every two seconds: gathering 0-4 s, measuring 4-22 s, reading the
# exports 22-365 s, the three fits and the keeper check 365-395 s. Reading the
# exports is seven eighths of the run and used to report nothing at all, which
# is why the bar stood still at 65% for six of its six and a half minutes.
STOR_WEIGHTS["learn"] = {"gathering": 1, "measuring": 5, "exports": 86,
                         "edit": 3, "reasons": 2, "bursts": 2, "checking": 1}
LEARN_KIND = "learn-learn"
# Measuring a shoot's picture vectors off its previews, so the keeper check can
# reach it (learned.measure_vectors). His, not the machine's homework: he asked
# for it with the Measure button beside the line that says it cannot be checked.
VECTORS_KIND = "learn-vectors"
STOR_WEIGHTS["vectors"] = {"vectors": 100}
STAGE_WORDS["vectors"] = ("measuring the picture vectors", "frames")
# The one background kind today. See BACKGROUND_KINDS at the top: this is what
# makes the learning run stand down for anything he presses, instead of
# refusing him.
BACKGROUND_KINDS.add(LEARN_KIND)
# The Instagram step working out the cuts of a shoot's exports: it writes the
# record and no photograph, it is asked for again by the step whenever there is
# anything left to work out, and a pass that is stopped keeps every frame it
# finished. So it is homework too, and his work never waits on it.
IG_PLAN_KIND = "instagram-plan"
BACKGROUND_KINDS.add(IG_PLAN_KIND)
KIND_WEIGHTS[IG_PLAN_KIND] = {"planning": 100}


def learning_title(shoot: str = "", panel: dict | None = None) -> str:
    """"Learning from 2026-09-21" - the words §2.9 puts on the row.

    The engine writes it, here, once, so the row, the toolbar, the Dock and
    the line after it is stood down all say the same thing. It names the shoot
    the run was started for; a Learn Now with nothing new names none, and says
    so rather than inventing one."""
    if not shoot and panel:
        names = panel.get("new_to_learn_from") or []
        shoot = names[0] if len(names) == 1 else ""
    return f"Learning from {shoot}" if shoot else "Learning from the shoots you have finished"


def learned_panel(jobs: Jobs) -> dict:
    """Everything the panel shows, plus whether the job is running now."""
    import learned
    p = learned.panel()
    st = jobs.status()
    p["running"] = bool(st.get("running") and st.get("kind") == LEARN_KIND)
    # While it runs, the row is a real progress presentation: the title, the
    # stage in words, the bar, how long it has been going and roughly how much
    # is left - and the one thing that makes it safe to look at, which is that
    # stopping it costs nothing. All of it written here, because the engine
    # knows what the job is doing and the app does not.
    if p["running"]:
        p["job"] = {k: st[k] for k in ("label", "fraction", "elapsed", "stage", "id")}
        p["job"]["title"] = learning_title(st.get("shoot", ""), p)
        p["job"]["remaining"] = st.get("remaining")
        p["job"]["remaining_text"] = about_how_long(st.get("remaining"))
        p["job"]["safe_to_stop"] = LEARNING_SAFE_TO_STOP
    else:
        p["job"] = None
    # `queued` means waiting for a turn, which a run that is going is not.
    p["queued"] = bool(p.get("queued")) and not p["running"]
    return p


# Why he can stop it without thinking twice, in one sentence. It is the reason
# this is allowed to be stood down at all, so it is said where he can read it -
# and only the half the page does not already say: the line above the running
# row is "Nothing new is used until it has been checked against every
# photograph you kept", and this repeated it three lines lower.
LEARNING_SAFE_TO_STOP = "Stopping it loses only the time it has spent."
# What he is told after his own work pushed it aside. Not an error: a note.
LEARNING_STOOD_DOWN = "Learning paused; it will pick up when you are finished."


# What a finished shoot's page says when its learning waits for the Mac to be
# left alone (Settings ▸ Learning ▸ Only when the Mac is idle).
LEARNING_WAITS_FOR_IDLE = "Learning from it starts once the Mac has been left alone for two minutes."
# And when it waits for the work running now. The page prints the engine's
# note as it wrote it, under "Finished. Your 154 keepers are recorded …".
LEARNING_WAITS_FOR_SLOT = "Learning from it starts when the work running now is done."


def learn_from_finished(jobs: Jobs, shoot: str) -> dict:
    """What marking a shoot finished does about learning, by Settings ▸
    Learning: nothing when automatic learning is off; the ask written down
    and left for a quiet Mac when it is on "only when idle"; otherwise the
    run, now or behind whatever is running (learned_start)."""
    why = f"{FINISHED_WHY}{shoot}"
    if not LEARN_PREFS["auto"]:
        return {"ok": True, "running": False, "queued": False, "off": True}
    if not LEARN_PREFS["idle_only"]:
        r = learned_start(jobs, why, shoot=shoot)
        return {**r, "note": LEARNING_WAITS_FOR_SLOT} if r.get("queued") else r
    import learned
    learned.request_run(why[:60], shoot)
    jobs._pick_up_learning()
    st = jobs.status()
    if st.get("running") and st.get("kind") == LEARN_KIND:
        return {"ok": True, "running": True, "title": learning_title(shoot)}
    return {"ok": True, "running": False, "queued": True, "note": LEARNING_WAITS_FOR_IDLE}


def learned_start(jobs: Jobs, why: str, shoot: str = "") -> dict:
    """Start the learning job, or remember that it is wanted when the one job
    slot is busy: a cull he started must not be pushed aside by a shoot he has
    just marked finished."""
    import learned
    log = learned.folder() / "run.log"
    # The job's title is the words §2.9 puts on its own row. One name for one
    # job: the toolbar, the Dock, the Activity window and the learning screen
    # all read it off the engine, so none of them can describe it differently.
    if jobs.start(LEARN_KIND, learning_title(shoot),
                  [PY, str(HERE / "learned.py"), "run", "--why", why[:60]], log,
                  shoot=shoot, why=why[:60]):
        learned.request_run(None)               # it is running now, not waiting
        return {"ok": True, "running": True, "title": learning_title(shoot)}
    learned.request_run(why[:60])
    return {"ok": True, "running": False, "queued": True,
            "note": "something else is running; this starts when it is done"}


def make_room_for(jobs: Jobs) -> dict:
    """Stand the machine's homework down, if that is what is in the way.

    Every route he can press calls this before it asks for the slot, so a
    background job is never the reason his work cannot start. What was stood
    down is asked for again on disk (learned.request_run), which is the same
    machinery a finished shoot already uses: the next time the slot is free,
    Jobs._watch picks it up.

    Returns {} when nothing was in the way, or a `paused` note to hand back
    with his job's answer - one line he can read afterwards, rather than a
    thing that happened silently."""
    stood = jobs.make_room()
    if not stood:
        return {}
    if stood.get("kind") == IG_PLAN_KIND:
        # Not learning, so nothing to write down for learned.py and nothing to
        # tell him: the Instagram step asks for the rest of the cuts again
        # itself once the slot is free, and every frame it finished is kept.
        return {}
    try:
        import learned
        learned.request_run(stood.get("why") or "it was paused while you worked",
                            stood.get("shoot") or "")
    except Exception as e:  # noqa: BLE001
        # It could not be written down, so say that rather than promising a
        # run that nothing is now going to start.
        print(f"  (could not write down the learning run to pick up again: {e})", flush=True)
        return {"paused": "Learning stopped so this could start. Press Learn Now when you are finished."}
    return {"paused": LEARNING_STOOD_DOWN,
            "paused_job": {"title": learning_title(stood.get("shoot", "")), "kind": stood["kind"],
                           "label": stood.get("label", ""), "fraction": stood.get("fraction", 0.0),
                           "elapsed": stood.get("elapsed", 0)}}


# What Jobs._take_next calls when the homework is holding the slot a piece of
# his list wants. Set here rather than written into Jobs, because standing it
# down and asking for it again are one act and learned.py is the half of it
# that Jobs has no business knowing about.
Jobs.homework_aside = staticmethod(make_room_for)


def measure_vectors_title(shoot: str) -> str:
    return f"measuring the picture vectors of {shoot}"


def measure_vectors_start(jobs: Jobs, shoot: str) -> dict:
    """The Measure button beside "…has no picture vectors kept": the command
    the line used to tell him to type, as a job with a bar and a Stop. It
    reads the shoot's previews and writes the vectors beside the models, and
    touches nothing of the shoot. The check runs on the next learning run."""
    # A shoot's own name and nothing else: ".." is a folder too, and it is
    # the library (`_q_shoot`).
    try:
        if shoot.startswith("."):
            raise NotNow("")
        s = _q_shoot(shoot)
    except NotNow:
        return {"error": f"there is no shoot called {shoot or 'that'}"}
    import learned
    title = measure_vectors_title(shoot)
    paused = make_room_for(jobs)
    if not jobs.start(VECTORS_KIND, title, [PY, str(HERE / "learned.py"), "vectors", str(s.folder)],
                      learned.folder() / "vectors.log", shoot=shoot):
        return jobs.busy(title, can_queue=False)
    return {"ok": True, "id": jobs.id, "running": True, "title": title, **paused}


# ------------------------------------------ the Instagram step
#
# One wall of the shoot's exported photographs, each with the cut its copy
# would be made with drawn on it, and one button that makes exactly those
# (DESIGN.md §2.17). instagram.py's record, <shoot>/instagram/crops.json, is the
# only source of truth: every window below is arithmetic on it, through
# instagram.describe, which is one function away from the one that makes the
# copies. Everything here answers in the request except working the cuts out
# (a background job, IG_PLAN_KIND) and making the copies (his job, WORK).

_IG_EXPORTS: dict = {}
_IG_WALK = threading.Lock()
# Held from "is a pass of this shoot running?" to the pass started, so two
# asks in the same moment start one pass and not two - the second's stand-down
# of homework took the first pass down and started over. Re-entrant: a shape
# change holds it across standing a pass down, writing the shape and starting
# the pass again, and the last of those is instagram_plan itself.
_IG_PLAN_LOCK = threading.RLock()


def _ig_exports(s: Shoot) -> dict[str, Path]:
    """Stem -> the export a copy is cut from, as instagram.py finds it, in
    stem order, kept for a few seconds.

    The frames are the ones Edit in PhotoLab counts as exported
    (Shoot.exported), and each one's file is its finished photograph
    (exports.files' ranks): the wall once took every JPEG in reels/ as well,
    twenty burst frames he had exported for a reel and never finished as
    stills, and for a frame exported to both it took whichever was newer -
    for two of them a different edit from his finished one.

    The step asks for this on every poll while a plan fills the wall in, and
    once for every tile's picture; each ask walked every folder an export can
    land in. A map is used for 5 s, as the reel tiles' is (_reel_exports), and
    every route that changes the step drops it first (_ig_forget). One walk
    at a time: a wall of tiles opening asks for hundreds of pictures in the
    same second, and each of them walking the folders for itself is the cost
    this is here to save."""
    key = str(s.folder)
    hit = _IG_EXPORTS.get(key)
    if hit and time.monotonic() - hit[0] < _EXPORTS_FOR:
        return hit[1]
    with _IG_WALK:
        hit = _IG_EXPORTS.get(key)
        if hit and time.monotonic() - hit[0] < _EXPORTS_FOR:
            return hit[1]
        import exports
        have = dict(sorted(exports.files(s.folder, s.exported()).items()))
        _IG_EXPORTS[key] = (time.monotonic(), have)
        return have


def _ig_forget(s: Shoot) -> None:
    _IG_EXPORTS.pop(str(s.folder), None)


def _ig_shape(bk: dict) -> tuple[str, str]:
    """The shape a shoot's copies are worked out and made at: the record's,
    else 3:4 with landscapes left whole, which is what instagram.py makes
    when nobody has said otherwise."""
    import instagram as ig
    ratio = bk.get("ratio") if bk.get("ratio") in ig.RATIOS else "3:4"
    landscape = bk.get("landscape") if bk.get("landscape") in ("fit", "crop") else "fit"
    return ratio, landscape


def _ig_records(bk: dict) -> dict:
    recs = bk.get("frames")
    return recs if isinstance(recs, dict) else {}


def _ig_described(s: Shoot) -> tuple[dict, list[dict], list[str]]:
    """(the record, every exported frame described in stem order, the stems
    whose record is there and will not read).

    A record that will not read is described as not worked out, so the step
    asks for it to be worked out again; the planning route drops it first,
    or instagram.py would find it current and leave it as it is."""
    import instagram as ig
    out = s.folder / "instagram"
    bk = ig.book(out)
    recs = _ig_records(bk)
    ratio, landscape = _ig_shape(bk)
    frames: list[dict] = []
    unreadable: list[str] = []
    for stem, src in _ig_exports(s).items():
        e = recs.get(stem)
        try:
            try:
                frames.append(ig.describe(src, out, stem, e if isinstance(e, dict) else None, ratio, landscape))
            except (KeyError, TypeError, ValueError, ZeroDivisionError):
                unreadable.append(stem)
                frames.append(ig.describe(src, out, stem, None, ratio, landscape))
        except OSError:
            continue                    # gone since the map was made: not an export any more
    return bk, frames, unreadable


def instagram_status(s: Shoot, jobs: Jobs) -> dict:
    """GET /api/instagram: the whole wall, at once, starting nothing.

    Frames the profile grid would lose the subject of come first, because
    they are the ones he has to look at; after them, every other frame in
    stem order. `unplanned` counts everything a planning pass would look at,
    exported-again frames included, and `stale` is that part of it."""
    import instagram as ig
    bk, frames, _ = _ig_described(s)
    ratio, landscape = _ig_shape(bk)
    out = s.folder / "instagram"
    name = s.folder.name
    st = jobs.status()

    def running(kind: str) -> dict | None:
        if st["running"] and st["kind"] == kind and st["shoot"] == name:
            return {"id": st["id"], "label": st["label"], "fraction": st["fraction"]}
        return None
    planning = running(IG_PLAN_KIND)
    unplanned = sum(1 for f in frames if f["state"] != "planned")
    misses = [f for f in frames if f["state"] == "planned" and not f["cut"]["grid_ok"]]
    first = {f["stem"] for f in misses}
    # Only when there is something to work out, nothing is working it out,
    # and what holds the one slot is work of his: the machine's own homework
    # is stood down the moment the step asks, so it is never waited for.
    waiting = ({"title": st["title"] or st["kind"], "kind": st["kind"]}
               if unplanned and planning is None and st["running"] and not st["background"] else None)
    return {"shoot": name, "folder": str(out), "folder_exists": out.is_dir(),
            "ratio": ratio, "landscape": landscape, "ratios": list(ig.RATIOS),
            "exported": len(frames), "planned": sum(1 for f in frames if f["state"] == "planned"),
            "unplanned": unplanned, "stale": sum(1 for f in frames if f["state"] == "stale"),
            "made": sum(1 for f in frames if f["copy"]), "grid_misses": len(misses),
            "planning": planning, "making": running("instagram"), "waiting_for": waiting,
            "frames": misses + [f for f in frames if f["stem"] not in first]}


def instagram_plan(s: Shoot, jobs: Jobs) -> dict:
    """POST /api/instagram/plan: work out every cut not yet worked out, in the
    background, and answer at once.

    The step asks when it opens and whenever frames are left over, so this is
    the only place a plan starts, and there is never more than one: there is
    one slot. Nothing is queued and nothing is remembered when work of his
    holds it - the step asks again when it is free. Machine homework in the
    slot (learning, another shoot's plan) is stood down: he is looking at this
    wall now. The plan uses the record's shape, and writes no photograph."""
    with _IG_PLAN_LOCK:
        return _ig_plan(s, jobs)


# An export written this recently may still be being written: PhotoLab puts
# out a shoot's exports one after another while the step is open, and the
# step asks every five seconds. It is left for the next ask rather than read
# half-written; the ask after that finds it whole.
IG_SETTLE = 8.0


def _ig_plan(s: Shoot, jobs: Jobs) -> dict:
    import instagram as ig
    name = s.folder.name
    st = jobs.status()
    if st["running"] and st["kind"] == IG_PLAN_KIND and st["shoot"] == name:
        return {"ok": True, "planning": True, "id": st["id"], "already": True}
    _ig_forget(s)
    _, frames, unreadable = _ig_described(s)
    now = time.time()
    todo: list[str] = []
    settling = 0
    for f in frames:
        if f["state"] == "planned":
            continue
        # A clock that puts an export in the future is not a reason to wait
        # for it for ever.
        if 0 <= now - f["export_mtime"] < IG_SETTLE:
            settling += 1
        else:
            todo.append(f["stem"])
    if not todo:
        return {"ok": True, "planning": False, "nothing": True, **({"settling": settling} if settling else {})}

    def waiting(st: dict) -> dict:
        return {"ok": True, "planning": False,
                "waiting_for": {"title": st["title"] or st["kind"] or "something else", "kind": st["kind"]}}
    if st["running"] and not st["background"]:
        return waiting(st)
    paused = make_room_for(jobs)
    if unreadable:
        out = s.folder / "instagram"
        with ig.held(out):
            bk = ig.book(out)
            recs = _ig_records(bk)
            for stem in unreadable:
                recs.pop(stem, None)
            ig.keep_book(out, bk, locked=True)
    cmd = [PY, str(HERE / "instagram.py"), str(s.folder), *todo, "--plan"]
    if not jobs.start(IG_PLAN_KIND, f"working out the Instagram cuts of {name}", cmd,
                      _kind_log(s, IG_PLAN_KIND), shoot=name):
        return waiting(jobs.status())
    return {"ok": True, "planning": True, "id": jobs.id, "count": len(todo), **paused}


def _ig_manual(m) -> dict | None:
    """A window as the record keeps it - centre and size, clamped the way
    instagram.window_of reads them and rounded to 5 places - or None when it
    is not one."""
    if not isinstance(m, dict):
        return None
    try:
        v = [m[k] for k in ("cx", "cy", "scale")]
        if any(isinstance(x, bool) for x in v):
            return None
        cx, cy, sc = (float(x) for x in v)
    except (KeyError, TypeError, ValueError):
        return None
    if not all(math.isfinite(x) for x in (cx, cy, sc)):
        return None
    return {"cx": round(min(max(cx, 0.0), 1.0), 5), "cy": round(min(max(cy, 0.0), 1.0), 5),
            "scale": round(min(max(sc, 0.05), 1.0), 5)}


def instagram_crop(s: Shoot, body: dict) -> tuple[dict, int]:
    """POST /api/instagram/crop: save his cut of one photograph.

    `mode` cut or whole (set by him once it differs), `manual` his window,
    `auto` back to the automatic one, and `restore` - what undo sends - puts
    mode, whose it was and the window back exactly. Written under the
    folder's lock, so a plan or a make running meanwhile cannot write its own
    idea of this frame over it; both re-read the record per frame.

    A copy that is already made is made again from the new cut at once, so a
    copy in the folder always shows his latest cut. One that is not made
    stays unmade: adjusting a cut before the copies are made must not be
    what makes one."""
    import instagram as ig
    stem = body.get("stem")
    if not isinstance(stem, str) or not IG_STEM.fullmatch(stem):
        return {"error": "Which photograph?"}, 400
    mode = body.get("mode")
    if mode is not None and mode not in ("crop", "whole"):
        return {"error": "A photograph is either cut or left whole."}, 400
    manual = None
    if body.get("manual") is not None:
        manual = _ig_manual(body["manual"])
        if manual is None:
            return {"error": "That is not a cut."}, 400
    restore = body.get("restore")
    back = None
    if restore is not None:
        if not (isinstance(restore, dict) and restore.get("mode") in ("crop", "whole")
                and restore.get("mode_by") in ("run", "you")):
            return {"error": "That is not a cut."}, 400
        if restore.get("manual") is not None:
            back = _ig_manual(restore["manual"])
            if back is None:
                return {"error": "That is not a cut."}, 400
    out = s.folder / "instagram"
    _ig_forget(s)
    src = _ig_exports(s).get(stem)
    if src is None:
        return {"error": f"{stem} is not exported any more."}, 409
    unplanned = {"error": f"{stem} has not been worked out yet."}, 409
    if not (out / ig.CROPS).is_file():
        return unplanned                # and the folder is not made to say so
    with ig.held(out):
        bk = ig.book(out)
        recs = _ig_records(bk)
        e = recs.get(stem)
        if not isinstance(e, dict):
            return unplanned
        if restore is not None:
            e["mode"], e["mode_by"] = restore["mode"], restore["mode_by"]
            if back is None:
                e.pop("manual", None)
            else:
                e["manual"] = back
        else:
            if mode is not None and mode != e.get("mode"):
                e["mode"], e["mode_by"] = mode, "you"
            if body.get("auto"):
                e.pop("manual", None)
            elif manual is not None:
                e["manual"] = manual
        recs[stem] = e
        bk["frames"] = recs
        ig.keep_book(out, bk, locked=True)
    ratio, landscape = _ig_shape(bk)
    frame = ig.describe(src, out, stem, e, ratio, landscape)
    # Made again only from a record of this very export. One made from an
    # earlier export can be a different size from this one, and its window
    # would then be cut out of the wrong picture; it is worked out again
    # first, and made with the rest.
    if frame["copy"] is None or frame["state"] != "planned":
        return {"ok": True, "frame": frame, "remade": False}, 200
    try:
        ig.redo(s.folder, stem, out)            # takes the lock itself, so after the block
    except Exception as x:  # noqa: BLE001
        why = x.args[0] if isinstance(x, KeyError) and x.args else _refusal(x)
        return {"ok": False, "error": f"Saved, but the copy could not be made again: {why}",
                "frame": ig.describe(src, out, stem, e, ratio, landscape)}, 200
    return {"ok": True, "frame": ig.describe(src, out, stem, e, ratio, landscape), "remade": True}, 200


def instagram_shape(s: Shoot, body: dict, jobs: Jobs) -> tuple[dict, int]:
    """POST /api/instagram/shape: the portrait ratio, how landscapes are made,
    or both, for every photograph of the shoot at once.

    Kept in the record, so the next plan and the next make use it. A frame
    whose cut or whole he set himself is not moved; every other one is put
    to the rule a run would give it (instagram.mode_for). Refused while this
    shoot's copies are being made - a make reads the shape once, at its start.

    A pass of this shoot is stood down first, for the same reason, and started
    again here the moment the shape is written, over what it had not reached:
    he changed the shape, he did not stop the pass, and the step read a pass
    that ended stopped with nothing of his in the slot as his Stop. All of it
    under the planning lock, so no ask of the step's can start a pass between
    the two with the shape it had before."""
    with _IG_PLAN_LOCK:
        return _ig_reshape(s, body, jobs)


def _ig_reshape(s: Shoot, body: dict, jobs: Jobs) -> tuple[dict, int]:
    import instagram as ig
    ratio, landscape = body.get("ratio"), body.get("landscape")
    if ratio is None and landscape is None:
        return {"error": "Say which shape: a portrait ratio, or how landscapes are made."}, 400
    if ratio is not None and (not isinstance(ratio, str) or ratio not in ig.RATIOS):
        return {"error": f"Instagram copies are made at {_or_list(ig.RATIOS)}, not {ratio}."}, 400
    if landscape is not None and landscape not in ("fit", "crop"):
        return {"error": "A landscape is left whole or cut to portrait."}, 400
    out = s.folder / "instagram"
    name = s.folder.name
    st = jobs.status()
    if st["running"] and st["shoot"] == name and st["kind"] == "instagram":
        now, _ = _ig_shape(ig.book(out))
        return {"error": f"The copies are being made at {now} right now. Change the shape when they are done."}, 409
    stood = st["running"] and st["shoot"] == name and st["kind"] == IG_PLAN_KIND
    if stood:
        make_room_for(jobs)
    _ig_forget(s)
    with ig.held(out):
        bk = ig.book(out)
        was_ratio, was_landscape = _ig_shape(bk)
        bk["ratio"], bk["landscape"] = ratio or was_ratio, landscape or was_landscape
        recs = _ig_records(bk)
        for e in recs.values():
            if isinstance(e, dict) and e.get("mode_by") != "you":
                with contextlib.suppress(KeyError, TypeError):
                    e["mode"] = ig.mode_for(e, bk["landscape"])
        bk["frames"] = recs
        ig.keep_book(out, bk, locked=True)
    again = _ig_plan(s, jobs) if stood else {}
    return {**instagram_status(s, jobs), "ok": True,
            **({"replanned": bool(again.get("planning"))} if stood else {})}, 200


def exported_picture(s: Shoot, stem: str, px_asked: str) -> tuple[Path | None, bool]:
    """The export of one frame for the Instagram step, upright, at `px` on its
    long side (clamped to 200-2400) and kept per size under cull/exported;
    or, for "full", the export itself, whose bytes are served as they are.
    (path, whether it is the export itself); (None, False) for no export.

    Always the export, never the RAW or the camera's JPEG: the cut is drawn in
    fractions of this picture, and on any other picture it is drawn wrong."""
    src = _ig_exports(s).get(stem)
    if src is None or not src.is_file():
        return None, False
    if px_asked == "full":
        return src, True
    try:
        px = int(px_asked)
    except ValueError:
        px = 400
    px = min(2400, max(200, px))
    out = s.cull / "exported" / str(px) / f"{stem}.jpg"
    if not within(out, s.folder):
        return None, False
    if not out.exists() or out.stat().st_mtime < src.stat().st_mtime:
        import io
        from PIL import Image, ImageOps
        with Image.open(src) as im:
            icc = im.info.get("icc_profile")
            # Decoded at the smallest scale that still covers `px`: a 24 MP
            # export read whole for a 400 px tile is most of the cost of it.
            im.draft("RGB", (px, px))
            up = ImageOps.exif_transpose(im).convert("RGB")
        up.thumbnail((px, px), Image.LANCZOS)
        buf = io.BytesIO()
        up.save(buf, "JPEG", quality=86, **({"icc_profile": icc} if icc else {}))
        out.parent.mkdir(parents=True, exist_ok=True)
        write_atomic(out, buf.getvalue())
    return out, False


def learned_post(path: str, body: dict, jobs: Jobs) -> tuple[dict, int]:
    """POST /api/learned/{run,back,stop,use-anyway}."""
    import learned
    try:
        if path == "/api/learned/run":
            return learned_start(jobs, str(body.get("why") or "Learn now")), 200
        if path == "/api/learned/vectors":
            return measure_vectors_start(jobs, str(body.get("shoot") or "")), 200
        if path == "/api/learned/settings":
            # Settings ▸ Learning, whenever he changes it: no restart. A
            # switch turned so that a waiting ask may go now is looked at now.
            for k in ("auto", "idle_only"):
                if isinstance(body.get(k), bool):
                    LEARN_PREFS[k] = body[k]
            jobs._pick_up_learning()
            return {"ok": True, **LEARN_PREFS}, 200
        name = str(body.get("learner") or "")
        if name not in learned.LEARNERS:
            return {"error": f"there is no learner called {name!r}"}, 400
        if path == "/api/learned/back":
            return learned.back(name), 200
        if path == "/api/learned/stop":
            return learned.stop(name), 200
        if path == "/api/learned/use-anyway":
            # The version has to be named, and it is the one whose frames he
            # has just been shown: this is the single override in the whole
            # business, and it is only his to make with the photographs in
            # front of him.
            return learned.use_anyway(name, str(body.get("version") or "")), 200
    except learned.Refused as e:
        return {"error": str(e)}, 200
    return {"error": "no such action"}, 404


# ------------------------------------------------------------- the page

# ------------------------------------------------- the frame he is about to open
#
# A cold frame costs 650-720 ms, and the 1:1 view is where a sharpness call is
# settled: opening the first frame of a burst he has not been in yet is the one
# place that wait lands, every burst, all session. The viewer says which frames
# it is about to want (POST /api/prefetch) and they are decoded before he asks
# for them. One thread, so a hint can never take both slots of the frame gate
# from the frame he is actually looking at, and the newest hint replaces the
# last one, because where he is going has changed.
_WARM_WANT: list[tuple] = []
_WARM_WAKE = threading.Event()
_WARM_THREAD: threading.Thread | None = None
WARM_MAX = 8


def _warming() -> None:
    while True:
        _WARM_WAKE.wait()
        with _FRAME_LOCK:
            want = list(_WARM_WANT)
            del _WARM_WANT[:]
            _WARM_WAKE.clear()
        for name, stem in want:
            s = Shoot(shoots_dir() / name)
            if not s.folder.is_dir():
                continue
            try:
                Handler._decoded(s, stem)
            except Exception:  # noqa: BLE001
                pass                       # a hint that cannot be answered is not an error
            if _WARM_WAKE.is_set():
                break                      # he has moved; the new hint is the one that matters


def warm(name: str, stems: list[str]) -> int:
    """Ask for these frames of this shoot to be decoded, newest hint first."""
    global _WARM_THREAD
    stems = [x for x in stems if isinstance(x, str) and re.fullmatch(r"[A-Za-z0-9._-]{1,60}", x)][:WARM_MAX]
    with _FRAME_LOCK:
        _WARM_WANT[:] = [(name, x) for x in stems]
        if _WARM_THREAD is None:
            _WARM_THREAD = threading.Thread(target=_warming, daemon=True)
            _WARM_THREAD.start()
        _WARM_WAKE.set()
    return len(stems)


# This used to be the product: one 166 KB page, served here, with the
# extension's cards and script spliced into it. The Mac app replaced it, and a
# page nobody opens on purpose is worse than no page - the engine restarts
# itself when its own source changes, and for a while that put the retired
# thing back in front of him while he was working in the app.
#
# So the address answers, because a port that is listening should say what it
# is, and it says the one useful thing. It carries no key: there is nothing
# here to fetch with one, and this is now the only address that answers
# without it.
PAGE = ("<!doctype html><html lang=en><head><meta charset=utf-8>"
        "<meta name=viewport content='width=device-width,initial-scale=1'>"
        f"<title>{APP_NAME} engine</title><style>"
        "html{color-scheme:light dark}"
        "body{font:16px/1.5 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;"
        "margin:0;min-height:100vh;display:grid;place-items:center;padding:2rem}"
        "main{max-width:32rem;text-align:center}"
        "h1{font-size:1.25rem;font-weight:600;margin:0 0 .5rem}"
        "p{margin:0;opacity:.75}"
        "</style></head><body><main>"
        f"<h1>This is the {APP_NAME} engine.</h1>"
        f"<p>It has no page of its own. Open the {APP_NAME} app, "
        "which is what this engine answers to.</p>"
        "</main></body></html>").encode()


def page() -> bytes:
    return PAGE


# ------------------------------------------------------------- the server
#
# Who may ask. Every request but the page itself carries a key made for this
# launch: the Mac app makes it, hands it over in PIPELINE_STUDIO_KEY and sends
# it as X-Studio-Key on its own calls; a checkout makes one at random. The
# page gets it as an HttpOnly cookie when it loads, which the browser then
# sends with every picture and every fetch the page makes, and with nothing
# another site makes. Host and Origin are checked as well, exactly, port and
# all: they are what keeps a rebound hostname out, and the key is what keeps
# out everything that never sends an Origin at all.

KEY_COOKIE = "studio_key"
KEY_HEADER = "X-Studio-Key"
# The largest POST body taken. The page's biggest is a burst list or a reel
# plan, a few kilobytes; a number the size of the disk in content-length would
# otherwise be read into memory before anything looked at it.
MAX_BODY = 8 * 1024 * 1024
# Sent with every refusal whose body is left unread; send_header also marks
# the connection to be closed once the answer is out.
CLOSE = (("connection", "close"),)


class Handler(BaseHTTPRequestHandler):
    jobs: Jobs
    last_request = time.time()

    def log_message(self, *a):
        pass

    def parse_request(self):
        Handler.last_request = time.time()
        return super().parse_request()

    # Keep-alive, because a grid of a thousand frames is a thousand requests and
    # a fresh TCP connection for each one is what made the server reset them.
    protocol_version = "HTTP/1.1"

    def _send(self, code, body: bytes, ctype: str, cache: bool = False, headers: tuple = ()):
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(body)))
        # A frame's pixels never change under its own name, so let the browser
        # keep them. Everything else is live state and must not be cached.
        self.send_header("cache-control", "public, max-age=604800, immutable" if cache else "no-store")
        # Nothing this server answers is for another origin to embed. With
        # this a browser will not hand one of his photographs to an <img> on
        # any other page, even one that got a request through; the key below
        # is what stops the request, this is what stops the answer.
        self.send_header("cross-origin-resource-policy", "same-origin")
        self.send_header("x-content-type-options", "nosniff")
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj, code=200, headers: tuple = ()):
        if isinstance(obj, dict) and isinstance(obj.get("error"), str):
            obj = {**obj, "error": sentence_case(obj["error"])}
        self._send(code, json.dumps(obj, default=str).encode(), "application/json", headers=headers)

    def _local(self) -> bool:
        """The request is addressed to this server, from this server's page.

        It listens on 127.0.0.1, which keeps other machines out but not other
        pages. Host has to name this server exactly, port included, so a
        hostname rebound to 127.0.0.1 cannot read a shoot back. Origin, where
        the browser sends one, has to be this server exactly: the hostname
        alone was checked before, and a POST from any other program serving on
        127.0.0.1 - another studio, a dev server, a container - was taken as
        this page's own."""
        srv = self.server
        hosts = getattr(srv, "hosts", None)
        if not hosts or (self.headers.get("host") or "").strip().lower() not in hosts:
            return False
        origin = self.headers.get("origin")
        return origin is None or origin.strip().lower() in srv.origins

    def _from_the_page(self) -> bool:
        """A browser that says where a request came from has to say it came
        from this page, or from him typing the address.

        Sec-Fetch-Site is set by the browser and no page can change it. It is
        here for one case the key cannot see: cookies are kept per host and
        not per port, so a page served from another port of this Mac is the
        same SITE as this one and its <img> arrives carrying the cookie. It
        says "same-site" on the way in, and that is not this page. A client
        that sends no such header - the app's own calls, curl - is left to the
        key."""
        site = self.headers.get("sec-fetch-site")
        return site is None or site.strip().lower() in ("same-origin", "none")

    def _keyed(self) -> bool:
        """The request carries this launch's key, in the header the app sends
        or in the cookie the page was given when it loaded.

        This is the check that does not depend on what a browser chooses to
        say. An <img>, a <script src> or a CSS url() sends no Origin at all,
        and until this existed any page open in any tab could put one of his
        photographs on its own screen, or learn which dated shoots exist by
        which guesses loaded. A browser sends this cookie only to a page of
        the same site, and no other page can read it or set the header."""
        key = getattr(self.server, "key", "")
        if not key:
            return False
        want = key.encode()
        sent = self.headers.get(KEY_HEADER)
        if sent is not None and hmac.compare_digest(sent.strip().encode(), want):
            return True
        # By hand rather than http.cookies: the cookies on 127.0.0.1 belong to
        # every program that has ever served there, and SimpleCookie stops at
        # the first one it cannot parse, which would lock the page out over a
        # cookie some other app set.
        names = (KEY_COOKIE, f"{KEY_COOKIE}_{self.server.server_address[1]}")
        for part in (self.headers.get("cookie") or "").split(";"):
            name, _, value = part.strip().partition("=")
            if name in names and hmac.compare_digest(value.strip().encode(), want):
                return True
        return False

    def _refused(self, path: str) -> str:
        """Why this request may not have an answer, or "" if it may."""
        if not self._local():
            return "not for another page"
        if path == "/":
            # The one address served without the key, and now the only reason
            # is that it holds nothing: four sentences saying which program
            # this is. The shoots, the frames and every action are behind the
            # key. Nor is it asked where the navigation came from - a browser
            # may call a typed address anything; the page's own headers refuse
            # a frame instead.
            return ""
        if not self._from_the_page():
            return "not for another page"
        if not self._keyed():
            return ("the studio did not recognize this page - it is from an earlier run of the studio, "
                    "or from somewhere else. Reload it")
        return ""

    def _deny(self, why: str):
        # JSON, because the page reads every answer as JSON and prints its
        # "error", so a refusal arrives as the sentence above rather than as
        # "the app is not answering". The connection is closed after it: a
        # refused POST's body is never read, and left on a keep-alive socket
        # it would be parsed as the next request.
        return self._json({"error": why}, 403, headers=CLOSE)

    def _job(self, body: dict, kind: str, title: str, cmd: list[str], log: Path, shoot: str = "",
             then=None):
        """Start a job, or put it in line when the body asks for that.

        The answer always carries the job's id, so the app can follow this one
        job through GET /api/job rather than guessing from the title, and
        `queued` says whether it is running yet.

        Two things happen before the slot is asked for, and they happen on
        every route he can press, which is why they live here.

        First, the machine's homework gets out of the way (_claim). A
        background job is never the reason his work cannot start; it is stood
        down, asked for again, and his job goes now. He is told in one line
        afterwards, in the answer's `paused`.

        Second, if what IS in the way is another job of his, the refusal says
        which one, how far along it is and roughly how long is left (_busy),
        and carries what the app needs to offer him the two real choices: wait,
        or stop the other one. The bare sentence "a job is already running"
        appears nowhere any more: it named nothing and offered nothing, and
        the one time it mattered he was standing in a gym with a card to
        copy and no idea why the machine had said no."""
        paused = self._claim()
        if body.get("queue"):
            # Onto the one list, described rather than frozen, so it survives a
            # restart and is looked at again before it starts. A kind the list
            # does not know - an extension's own work, an update - keeps the
            # command this request built, and says so by not being written down.
            if kind in WORK:
                try:
                    item = self.jobs.add(kind, shoot, {k: v for k, v in body.items() if k != "queue"})
                except NotNow as e:
                    return self._json({"error": str(e), "queueable": kind not in NEVER_QUEUED}, 409)
                return self._json({"ok": True, "id": item["id"],
                                   "queued": item["id"] != self.jobs.id, "added": item,
                                   **self._list(), **paused})
            jid, started = self.jobs.enqueue(kind, title, cmd, log, shoot, then)
            return self._json({"ok": True, "id": jid, "queued": not started, **paused})
        # A held list does not stop him doing one thing now. Holding is about
        # what the machine starts by itself; the button in front of him says
        # what it will do and then does that. Nothing here ever queues
        # silently: queuing is asked for, by the button or by ⌥.
        if not self.jobs.start(kind, title, cmd, log, shoot,
                               opts={k: v for k, v in body.items() if k != "queue"} if kind in WORK else None):
            return self._json(self._busy(title))
        if then:
            then()
        return self._json({"ok": True, "id": self.jobs.id, "queued": False, **paused})

    def _work(self, body: dict, kind: str, name: str):
        """Do one of the list's own kinds, now or on the list.

        The command is built in exactly one place - the builder in WORK - so
        the thing he does now and the same thing he leaves on the list can
        never become two different command lines. They used to be built twice,
        once here and once in the builder, kept in step by hand; a flag added
        to one and not the other would have been a job that ran differently
        depending on which button he pressed, and nothing would have said so.

        The builder's `then` is the other half of it. Everything that touches
        the shoot - the style and focus into meta.json, the editor, the reel's
        plan file - hangs off that, and `_job` only calls it when the work
        actually starts. Writing it here would mean a cull he put on the list
        at nine changed the shoot at nine and ran at eleven, and a cull the
        engine refused outright changed it and never ran at all."""
        try:
            w = work_build(kind, name, body)
        except NotNow as e:
            # The same question, asked the same way, whichever he pressed. 409
            # when he was offering it to the list, because that is the refusal
            # the app already knows how to put on its board; 400 when he was
            # doing it now.
            return self._json({"error": str(e), "queueable": kind not in NEVER_QUEUED},
                              409 if body.get("queue") else 400)
        return self._job(body, kind, w["title"], w["cmd"], w["log"], name, w.get("then"))

    def _claim(self) -> dict:
        """Make room for work he asked for. See make_room_for."""
        return make_room_for(self.jobs)

    def _list(self) -> dict:
        """The list as it is now, on the answer to anything that changed it.

        The same object GET /api/queue answers with, so the app has one reader
        for it and a request can never leave the screen describing an order
        the engine does not have."""
        return {"list": queue_view(self.jobs)}

    def _busy(self, wanted: str = "", can_queue: bool = True) -> dict:
        """Why it cannot start, named, with its progress and what is left."""
        return self.jobs.busy(wanted, can_queue)

    def _shoot(self, name: str) -> Shoot | None:
        # "." and ".." both match the pattern and both walk out of the shoots
        # folder, so they are named rather than pattern-matched away.
        if not isinstance(name, str) or name in (".", "..") or not re.fullmatch(r"[A-Za-z0-9._ -]+", name):
            return None
        p = shoots_dir() / name
        return Shoot(p) if p.is_dir() else None

    def do_GET(self):
        # The same try/except do_POST has had all along. Without it any
        # exception in here dropped the connection with nothing on it, and the
        # page's fetch catch reported "the app is not answering" - so one
        # truncated organize.json in one shoot blanked all five shoots and told
        # him to restart an app that was answering perfectly well in the same
        # second on every other route.
        try:
            return self._get(self.path)
        except Exception as e:  # noqa: BLE001
            return self._json({"error": _refusal(e)}, 500)

    def _get(self, path):
        u = urlparse(path)
        why = self._refused(u.path)
        if why:
            return self._deny(why)
        q = parse_qs(u.query)
        if u.path == "/":
            # No cookie. The page this address used to serve was how the key
            # reached a browser, and handing it out was the whole reason this
            # one address answered without one. There is no such page now, so
            # the key stays where it belongs: PIPELINE_STUDIO_KEY to the app,
            # X-Studio-Key on its calls, and a Set-Cookie from an extension's
            # own port for the pages it serves itself. Anything that wanders
            # in here with a browser leaves with a sentence and nothing else.
            return self._send(200, page(), "text/html; charset=utf-8", headers=(
                # Not inside anyone else's frame, and nothing may change what
                # its relative URLs mean (base-uri) or run as a plugin.
                ("x-frame-options", "DENY"),
                ("content-security-policy", "default-src 'none'; style-src 'unsafe-inline'; "
                 "frame-ancestors 'none'; base-uri 'none'; object-src 'none'")))
        if u.path == "/api/shoots":
            out = []
            for s in shoots():
                # Per shoot, so one damaged decisions file costs one row and
                # not the whole list. The row that fails still carries its
                # name, because a shoot missing from the list is a shoot he
                # cannot open to repair.
                try:
                    d = s.info()
                except Exception as e:  # noqa: BLE001
                    where, why = _broken_file(s, e)
                    # Which folder the button should show. A decisions file
                    # goes through decision_path, so a migrated library and an
                    # un-migrated one both land right; anything else - an
                    # unreadable cull.csv - is somewhere else in the shoot.
                    dec = decision_path(s.cull, "organize.json").parent
                    out.append({"name": s.folder.name, "path": str(s.folder), "frames": 0,
                                "broken": why, "broken_file": where, "storage": None,
                                "broken_where": "decisions" if where and Path(where).parent == dec else "shoot"})
                    continue
                # Where its photographs are, on the row, before anything is
                # opened. Wrapped because a front page that will not paint at
                # all is worse than one that cannot answer this for one shoot.
                try:
                    d["storage"] = _stor_home(s)
                except Exception as e:  # noqa: BLE001
                    d["storage"] = {"frames": 0, "phrase": "", "cells": ["none", "none"], "bad": False,
                                    "error": str(e)}
                # The same steps /api/shoot sends, done or not, so All Shoots
                # can say where each shoot is up to and a click on a shoot
                # never opened can go to the next one - from the one table,
                # not from a copy of its rules in the app. Wrapped like the
                # rest of the row: a shoot whose steps cannot be worked out
                # loses its Up to, not the whole list. The app reads a row
                # with no steps as one it cannot say that of, and a click on
                # it opens the shoot's own page.
                try:
                    d["steps"] = s.steps(d)
                except Exception:  # noqa: BLE001
                    d["steps"] = None
                out.append(d)
            return self._json({"shoots": out, "cards": cards(), "ext": ext_config(),
                               "ready": clip_ready(), "app": APP, "update": UPDATE})
        if u.path == "/api/update":
            if q.get("force"):
                check_for_update(True)
            elif UPDATE and not UPDATE.get("error"):
                # A download that finished since the last check is ready to
                # install; seeing that is a look at a folder, not another
                # question to GitHub.
                UPDATE["staged"] = staged_update().exists()
            return self._json(UPDATE)
        if u.path == "/api/cards":
            # The paths, as /api/shoots lists them, and what is on each: this
            # reads every file on the card and every raw/ that shares a name
            # with one, so it is asked for by the card page, not on every
            # re-read of the library.
            found = cards()
            return self._json({"cards": found, "described": [describe_card(c) for c in found]})
        if u.path == "/api/learned":                     # what the cull has learned (see the block above)
            return self._json(learned_panel(self.jobs))
        if u.path == "/api/shoot":
            s = self._shoot(q.get("name", [""])[0])
            if not s:
                return self._json({"error": "no such shoot"}, 404)
            if q.get("light"):
                return self._json({"info": s.info()})
            rows = s.rows()
            if not q.get("full"):
                # 18 of the 41 columns were computed, serialised and sent on
                # every shoot open and no line of the page ever read one of
                # them: 888 KB down to about 480 KB on a 1,157-frame shoot.
                # ?full=1 still returns everything, and the README's Extensions
                # section says so, because an extension might read what the
                # page does not.
                rows = [{k: v for k, v in r.items() if k in ROW_KEEP} for r in rows]
            info = s.info()
            # The burst list, the steps and where to resume are worked out here
            # and not in the app: each is a rule the page used to carry its own
            # copy of, and each copy had drifted (see Shoot.his).
            return self._json({"info": info, "rows": rows, "presets": s.presets(),
                               "review": s._rev, "bursts": s._his["bursts"], "steps": s.steps(info),
                               "resume": s.resume(s._his["bursts"], s._rev, info["kept"])})
        m = re.fullmatch(r"/ext/([^/]+)/([a-z_]+)/([A-Za-z0-9._-]+)", u.path)
        if m:
            # A file an extension wants on its own card. The extension says
            # which file, and is the one that knows what is allowed; this only
            # refuses anything that is not a plain file, so a name the
            # extension did not mean to allow cannot reach anything else.
            s = self._shoot(unquote(m.group(1)))
            f = EXTM.serve(s, m.group(2), m.group(3)) if (s and EXTM and hasattr(EXTM, "serve")) else None
            if not f or not Path(f).is_file():
                return self._send(404, b"", "text/plain")
            kind = "image/jpeg" if str(f).lower().endswith((".jpg", ".jpeg")) else "application/octet-stream"
            return self._send(200, Path(f).read_bytes(), kind)
        m = re.fullmatch(r"/exported/([^/]+)/([A-Za-z0-9._-]+)\.jpg", u.path)
        if m:
            # The Instagram step's pictures: the export a copy is cut from,
            # upright, at a tile's 400 px, the editor's 2400, or as it is on
            # disk for 1:1 (px=full, the export's own bytes). Unquoted like
            # /reelthumb/. `v` is the app's own cache-buster, the export's
            # mtime; the answer may be kept only while it still names it.
            s = self._shoot(unquote(m.group(1)))
            if not s:
                return self._send(404, b"", "text/plain")
            f, whole = exported_picture(s, m.group(2), q.get("px", ["400"])[0])
            if f is None:
                return self._send(404, b"", "text/plain")
            src = f if whole else _ig_exports(s).get(m.group(2))
            try:
                kept = src is not None and q.get("v", [""])[0] == str(int(src.stat().st_mtime))
            except OSError:
                kept = False
            return self._send(200, f.read_bytes(), "image/jpeg", cache=kept)
        m = re.fullmatch(r"/reelthumb/([^/]+)/([A-Za-z0-9._-]+)\.jpg", u.path)
        if m:
            # The picture on a reel tile is the JPEG he exported when there is
            # one, because for a finished burst he is choosing what goes in the
            # video and has to be looking at what goes in the video.
            #
            # When there is not, it is the cull's own decode of the RAW, which
            # is what the cut would be built from anyway. It used to 404, and
            # now that every burst is listed rather than only the exported
            # ones, a 404 meant the bursts he most needs to look at -- the ones
            # he has not touched -- were the blank tiles in the grid. The
            # camera's embedded preview is still never a stand-in.
            s = self._shoot(unquote(m.group(1)))
            mod = _reel_mod()
            if not s or mod is None:
                return self._send(404, b"", "text/plain")
            src = q.get("src", [""])[0]
            # A folder, or the lister's own search. It is one of the folders
            # the reel card offered him, and only this page can ask, but a
            # name that is not a folder is not handed on to be walked.
            src_dir = Path(src).expanduser() if src else None
            if src_dir is not None and not src_dir.is_dir():
                return self._send(404, b"", "text/plain")
            have = _reel_exports(mod, s.folder, src_dir)
            f = have.get(m.group(2))
            if f is None or not f.exists():
                row = [{"file": f"{m.group(2)}.ARW"}]
                f = mod.decodes(s.folder, row).get(m.group(2))
            if f is None or not f.exists():
                return self._send(404, b"", "text/plain")
            # The tile's 400 px, or the size a large view asks for: Space on
            # a tile showed the camera's JPEG and then the unedited RAW, a
            # different picture from the export the tile shows and the reel
            # is cut from. Clamped, and kept per size, so asking cannot fill
            # the disk or blow up a decode.
            try:
                px = int(q.get("px", ["400"])[0])
            except ValueError:
                px = 400
            px = min(2400, max(200, px))
            out = (s.cull / "reelthumbs" / f"{m.group(2)}.jpg" if px == 400
                   else s.cull / "reelthumbs" / str(px) / f"{m.group(2)}.jpg")
            if not within(out, s.folder):
                return self._send(404, b"", "text/plain")
            if not out.exists() or out.stat().st_mtime < f.stat().st_mtime:
                import cv2
                im = cv2.imread(str(f))
                if im is None:
                    return self._send(404, b"", "text/plain")
                k = px / max(im.shape[:2])
                if k < 1:
                    im = cv2.resize(im, (int(im.shape[1] * k), int(im.shape[0] * k)), interpolation=cv2.INTER_AREA)
                out.parent.mkdir(parents=True, exist_ok=True)
                cv2.imwrite(str(out), im, [cv2.IMWRITE_JPEG_QUALITY, 86])
            return self._send(200, out.read_bytes(), "image/jpeg")
        if u.path == "/api/reel/options":
            # What is worth cutting, which frames a burst holds, and which of
            # them exist as exports: all of it is reel.py's own lister, which
            # has had a --json mode "for the studio page" since before there
            # was one. This is that page. It reads the JPEGs he exported and
            # never the camera's previews, so a shoot nothing has been exported
            # from answers with nothing and says so.
            s = self._shoot(q.get("shoot", [""])[0] or q.get("name", [""])[0])
            if not s:
                return self._json({"error": "no such shoot"}, 404)
            b = q.get("burst", [""])[0]
            src = q.get("src", [""])[0]
            return self._json(reel_options(s, b if re.fullmatch(r"[A-Za-z0-9._/-]{1,40}", b or "") else "", src))
        if u.path == "/api/reel/watch":
            # He pressed the button, PhotoLab opened, and now the page waits:
            # a rising count means he is mid-export, a count that stops rising
            # means he has finished and the cut can start by itself.
            s = self._shoot(q.get("shoot", [""])[0] or q.get("name", [""])[0])
            if not s:
                return self._json({"error": "no such shoot"}, 404)
            b = q.get("burst", [""])[0]
            return self._json({"jpegs": reel_exported(s, b), "burst": b})
        if u.path == "/api/instagram":
            # The Instagram step's wall, at once. Starts nothing: working the
            # cuts out is POST /api/instagram/plan, which the step asks for.
            s = self._shoot(q.get("name", [""])[0])
            if not s:
                return self._json({"error": "no such shoot"}, 404)
            return self._json(instagram_status(s, self.jobs))
        if u.path == "/api/job":
            return self._json(self.jobs.status())
        if u.path == "/api/jobs/history":
            # What finished in the last few days, every run of the engine's,
            # oldest first - so the Activity window can show last night's
            # list in the morning. `run` is this engine's, whose own jobs the
            # app follows as they happen.
            return self._json({"run": self.jobs.run, "days": HISTORY_DAYS, "jobs": self.jobs.history()})
        if u.path == "/api/queue":
            # The same list /api/job carries, on its own, for the screen whose
            # whole subject is the list. It is one reading of one queue - there
            # is no second mechanism here - and it is beside /api/job rather
            # than inside it so a window showing the list can ask for it at its
            # own pace without every poll of the bar carrying it too.
            return self._json(queue_view(self.jobs))
        if u.path == "/api/storage":
            s = self._shoot(q.get("name", [""])[0])
            if not s:
                return self._json({"error": "no such shoot"}, 404)
            return self._json(storage(s))
        if u.path == "/api/storage/frames":
            # Lazily, on the first opening of the fold: 1157 rows are never
            # built for a panel nobody has unfolded.
            s = self._shoot(q.get("name", [""])[0])
            if not s:
                return self._json({"error": "no such shoot"}, 404)
            return self._json({"rows": _stor_rows(s)[0]})
        if u.path == "/api/storage/plan":
            s = self._shoot(q.get("name", [""])[0])
            what = q.get("what", [""])[0]
            if not s or what not in STOR_VERBS:
                return self._json({"error": "no such shoot"}, 404)
            return self._json(read_plan(s, what, _stor_body(q)))
        if u.path == "/api/storage/library":
            return self._json(library())
        if u.path == "/api/storage/default-retain":
            # The library's own number, which Settings ▸ Storage shows and
            # sets: the same one a shoot's Storage panel sets with "Use as
            # default", and the one archive.py reads for a shoot with none.
            return self._json(default_retain())
        m = re.match(r"^/crop/([^/]+)/([A-Za-z0-9._-]+)\.jpg$", u.path)
        if m:
            # Unquoted like /ext/ and /reelthumb/: the page puts the shoot's
            # name into these URLs as it is, a browser sends a space as %20,
            # and "%" is not a character a shoot name may have.
            s = self._shoot(unquote(m.group(1)))
            if s:
                body = self._crop(s, m.group(2), q)
                if body:
                    # Same URL, same pixels: the box is decided by the query, so
                    # flipping back to a frame he has already looked at at 1:1 is free.
                    return self._send(200, body, "image/jpeg", cache=True)
            return self._send(404, b"not found", "text/plain")
        m = re.match(r"^/(thumb|large|preview|full)/([^/]+)/([A-Za-z0-9._-]+)\.jpg$", u.path)
        if m:
            s = self._shoot(unquote(m.group(2)))
            if s:
                stem = m.group(3)
                if m.group(1) == "full":
                    p = self._full(s, stem, self._full_px(q))
                    # Bytes rather than a path when the frame has no original
                    # left and the capped copy was made in memory on purpose -
                    # see _full. Still cacheable: the same url is the same
                    # pixels either way.
                    if isinstance(p, bytes):
                        return self._send(200, p, "image/jpeg", cache=True)
                    if p:
                        return self._send(200, p.read_bytes(), "image/jpeg", cache=True)
                kind = m.group(1)
                if kind == "thumb":
                    cands = [s.cull / "thumbs" / f"{stem}.jpg", s.cull / "large" / f"{stem}.jpg", s.cull / "previews" / f"{stem}.jpg"]
                elif kind == "large":
                    cands = [s.cull / "large" / f"{stem}.jpg", s.cull / "thumbs" / f"{stem}.jpg", s.cull / "previews" / f"{stem}.jpg"]
                else:
                    cands = [s.cull / "decoded" / f"{stem}.jpg", s.cull / "previews" / f"{stem}.jpg"]
                for p in cands:
                    if p.exists():
                        return self._send(200, p.read_bytes(), "image/jpeg", cache=True)
        self._send(404, b"not found", "text/plain")

    @staticmethod
    def _raw(s, stem: str):
        # By number, whatever its extension, where library.frame_raw looks:
        # raw/ (or a flat shoot's own folder) first, then edit/ and
        # cull/picks/, so a RAW moved beside its edit is still this frame's
        # original and its decode is not read as the last pixels. This spelled
        # out seven extensions of its own and missed .orf and .rw2, which
        # common.RAW_EXTS has. frame_raw takes a file name and drops its
        # suffix; a stem is handed with one so a stem with a dot in it is kept
        # whole.
        return frame_raw(s.folder, f"{stem}.jpg")

    @staticmethod
    def _decoded(s, stem: str):
        """The native decode, made if it is not there yet. The camera only
        embeds a 1616 px preview, which is why a frame looked soft on screen
        whatever its file held, so the RAW is decoded once and kept."""
        decoded = s.cull / "decoded" / f"{stem}.jpg"
        if decoded.exists():
            return decoded
        # About to be written, so it has to land in this shoot. A link left
        # where the decode goes, dangling or not, would take a 7 MB file to
        # wherever it points.
        if not within(decoded, s.folder):
            return None
        raw = Handler._raw(s, stem)
        if raw is None:
            return None
        # One decode of this frame at a time, and the gate around the whole of
        # it. The page asks for the same frame twice easily - the prefetch and
        # the real <img> a keypress later - and both used to pay the full 650 ms
        # and write the same file over each other as it landed.
        with _decoding((str(s.folder), stem)), _gate():
            if decoded.exists():
                return decoded               # the request in front of this one made it
            return Handler._decode_now(s, stem, raw, decoded)

    @staticmethod
    def _decode_now(s, stem: str, raw: Path, decoded: Path):
        from faces import decode_to_file
        # TAG from library rather than spelled again here: a second copy of the
        # tag's name is how a folder comes to be tested for one string and
        # written with another.
        from library import TAG, cache_dir
        # Minted through cache_dir, so that when the VIEWER is the thing which
        # created cull/decoded/ the folder carries a CACHEDIR.TAG from its
        # first file. /full/ and /crop/ grew this folder back, about 7 MB a
        # frame opened, on shoots whose cache he had deliberately reclaimed,
        # and untagged bytes are bytes reclaim.py is right to refuse to touch
        # for ever - so taking the cache back once would have been the last
        # time it could be taken back. Tagged, and with a RAW of its own two
        # lines above to be rebuilt from, each decode is DERIVED to
        # reclaim.category() and reclaimable by reclaim.foreign().
        #
        # cache_dir will not tag a folder that already holds files, whatever
        # it is named, and that is what keeps 2026-09-12-lounge's untagged
        # cull/decoded - the only pixels of 290 frames - untagged.
        fresh = not decoded.parent.exists()
        cache_dir(decoded.parent, built_by="studio")
        made = decode_to_file(raw, decoded, full=True)
        # The 72 MB the decode just freed, back to the OS rather than onto the
        # allocator's own pile. See _give_memory_back.
        _give_memory_back()
        if made is None:
            if fresh:
                # Same rule as _job_log: nothing here writes anything he asked
                # for, so a failed decode must not leave a folder behind.
                #
                # Only where nothing else got there first. Two requests on a
                # reclaimed shoot both read `fresh` before either minted the
                # folder, and where one decode then failed this took the tag
                # off a folder the other had just filled: measured, GOOD.jpg
                # left in an untagged cull/decoded, and cache_dir refuses to
                # tag a folder that holds files, so those bytes were derived,
                # in_cache False, and unreclaimable for ever - the one outcome
                # the minting above exists to prevent.
                try:
                    if not any(p.name != TAG for p in decoded.parent.iterdir()):
                        (decoded.parent / TAG).unlink(missing_ok=True)
                        decoded.parent.rmdir()
                except OSError:
                    pass
            return None
        return decoded

    @staticmethod
    def _decoded_image(s, stem: str):
        """The native decode as an array, from memory when it is already there.

        Keyed on the decode's own mtime as well as its name, because a re-cull
        with --decode half rewrites cull/decoded/<stem>.jpg at 2400 px under
        the same name: a stale array would be cut 1:1 out of the wrong
        resolution, which is a lie about the one question the loupe exists to
        answer. The caller holds the frame gate, so at most FRAMES of these are
        alive at once - see FRAMES for what twelve of them measured."""
        decoded = Handler._decoded(s, stem)
        if decoded is None:
            return None
        try:
            key = (s.folder.name, stem, decoded.stat().st_mtime_ns)
        except OSError:
            return None
        with _FRAME_LOCK:
            img = _FRAME_CACHE.get(key)
            if img is not None:
                _FRAME_CACHE.move_to_end(key)
                return img
        import cv2
        # Outside the lock: a 6024 px JPEG is about 150 ms to decode, and
        # holding the lock across it would serialise a cache HIT on one frame
        # behind a cache miss on another. Two threads racing on the same frame
        # decode it twice and the second write wins, which costs one decode
        # and cannot be wrong.
        img = cv2.imread(str(decoded))
        if img is None:
            return None
        dropped = False
        with _FRAME_LOCK:
            _FRAME_CACHE[key] = img
            _FRAME_CACHE.move_to_end(key)
            while len(_FRAME_CACHE) > FRAMES:
                _FRAME_CACHE.popitem(last=False)
                dropped = True
        if dropped:
            _give_memory_back()
        return img

    @staticmethod
    def _full_px(q: dict) -> int:
        """The size /full/ was asked for, as one of FULL_TIERS. No px at all is
        FULL_PX, which is what the page has always been served."""
        try:
            want = int(float(q.get("px", [""])[0]))
        except (TypeError, ValueError, IndexError):
            return FULL_PX
        return next((t for t in FULL_TIERS if t >= want), FULL_TIERS[-1])

    @staticmethod
    def _full(s, stem: str, px: int = FULL_PX):
        """The frame at a size worth judging sharpness on, and no larger.

        FULL_PX has been in this function for as long as the viewer has, but it
        sat ten lines below an early return of the decode, so on a culled shoot
        - which is every shoot by the time anyone opens the viewer - it never
        ran. The viewer was being handed 7.5 MB of 6024 px frame to draw into
        1105 CSS px. The cap is applied to the decode too now, and where it
        takes pixels away the capped copy is kept in cull/full/ - marked as a
        cache, so what it costs can be taken back - and a second look is free.
        Where it would take none away nothing is written at all. The native
        decode is left alone: it is what /crop/ cuts 1:1 pixels out of.

        A path where the answer is a file, and bytes where the capped copy was
        made in memory because this shoot has no original to rebuild it from
        - see the no-RAW branch below."""
        # The default size where it has always been, and any other size in a
        # folder of its own beside it: one file per size per frame, inside the
        # same tagged cache, so reclaim reads them as what they are.
        cached = (s.cull / "full" / f"{stem}.jpg") if px == FULL_PX else (s.cull / "full" / str(px) / f"{stem}.jpg")
        if cached.exists():
            return cached
        decoded = Handler._decoded(s, stem)
        if decoded is None:
            return None
        try:
            from PIL import Image
            with Image.open(decoded) as im:
                inside = max(im.size) <= px
        except Exception:  # noqa: BLE001
            inside = False
        if inside:
            # Already inside the cap - one shoot's decodes are 2400 px - so
            # there are no more pixels to take away, and it is served where it
            # lies rather than copied.
            return decoded
        if Handler._raw(s, stem) is None:
            # No RAW left in this shoot for this frame, so that decode is not a
            # derivative of anything: it is the only form the photograph still
            # exists in. 2026-09-12-lounge holds 6 RAWs against 296 culled
            # frames and its decodes are the last pixels of 290 of them. A
            # capped copy of one in cull/full/ would be a SECOND last-copy
            # rendering, minted by the viewer one opened frame at a time, and
            # reclaim.py would rightly read it as an original sitting in a
            # folder spelled like a cache - the lounge failure written afresh.
            # The lounge's own decodes are 2400 px and leave by the branch
            # above, but that is a fact about one shoot's decode settings and
            # not a rule, so this is the rule. The cap still applies: it is
            # taken in memory and thrown away, because the pixels are worth
            # capping and the file is not worth minting.
            return Handler._capped(s, stem, px)
        try:
            import cv2
            from library import cache_dir
            # Behind the same gate as /crop/, and out of the same two-frame
            # cache. This branch runs once per frame ever - the capped copy is
            # kept - but "once per frame" is still twelve at a time when he
            # arrows through a burst with the warm ahead of him, and the array
            # it reads is the same 72 MB one.
            with _gate():
                img = Handler._decoded_image(s, stem)
                if img is None:
                    return None
                h, w = img.shape[:2]
                k = px / max(h, w)
                if k >= 1:
                    return decoded
                # Marked as a cache as it is minted, which is what
                # library.cache_dir is for. An untagged folder is one
                # reclaim.py is right to refuse to empty, and this one grows by
                # a frame for every frame he opens: a 1157-frame shoot is about
                # a gigabyte that nothing could take back.
                if not within(cached, s.folder):
                    return decoded              # served, just not kept
                cache_dir(cached.parent, built_by="studio")
                small = cv2.resize(img, (int(w * k), int(h * k)), interpolation=cv2.INTER_AREA)
                if not cv2.imwrite(str(cached), small, [cv2.IMWRITE_JPEG_QUALITY, 90]):
                    return None
        except Exception:
            return None
        return cached if cached.exists() else None

    @staticmethod
    def _capped(s, stem: str, px: int = FULL_PX):
        """The frame capped to px as bytes, written nowhere. See _full."""
        try:
            import cv2
            with _gate():
                img = Handler._decoded_image(s, stem)
                if img is None:
                    return None
                h, w = img.shape[:2]
                # Never upscaled: where the decode is already inside the size
                # asked for it is re-encoded as it is. _full only comes here
                # for a frame bigger than px, but a decode whose header could
                # not be read lands here too and must not be blown up.
                k = min(1.0, px / max(h, w))
                small = img if k == 1.0 else cv2.resize(img, (int(w * k), int(h * k)), interpolation=cv2.INTER_AREA)
                ok, buf = cv2.imencode(".jpg", small, [cv2.IMWRITE_JPEG_QUALITY, 90])
                return buf.tobytes() if ok else None
        except Exception:  # noqa: BLE001
            return None

    @staticmethod
    def _crop(s, stem: str, q: dict):
        """A window of the frame at its own resolution: the loupe.

        Fit-to-window is the one thing the full view cannot be if it is to
        answer the only question it exists for. One gym shoot carries 156 close
        calls and 81 of them turn on sharpness, and they were all being judged
        through an 18% view. The box is cut out of the native decode with no
        resampling at all, so one source pixel can land on one device pixel.
        Never out of cull/full/: that file is capped, and a crop of a capped
        file is not 1:1 however it is labelled. Nothing is written: the cut
        costs about 70 ms, and a cache of every box anyone ever looked at has
        no end to it."""
        def num(k, default, lo, hi):
            try:
                v = float(q.get(k, [""])[0])
            except (TypeError, ValueError, IndexError):
                return default
            if v != v or v in (float("inf"), float("-inf")):
                return default        # NaN compares false against every bound
            return max(lo, min(hi, v))
        cx, cy = num("cx", 0.5, 0.0, 1.0), num("cy", 0.5, 0.0, 1.0)
        px, ar = int(num("px", 1600, 256, CROP_MAX_PX)), num("ar", 0.75, 0.25, 4.0)
        try:
            import cv2
            # The gate first, then the cache: a pan re-cuts the same frame
            # eight times a second and every one of those used to read the
            # whole 72 MB decode off the disk again, while nothing at all
            # stopped twelve of them being in flight together.
            with _gate():
                img = Handler._decoded_image(s, stem)
                if img is None:
                    return None
                ih, iw = img.shape[:2]
                w = min(px, iw)
                h = min(max(1, round(px * ar)), ih)
                # Shifted back inside the frame rather than shrunk: a corner of
                # a photograph is still to be looked at at 1:1, not at some
                # other size that would quietly make the label wrong.
                x = max(0, min(iw - w, int(round(cx * iw - w / 2))))
                y = max(0, min(ih - h, int(round(cy * ih - h / 2))))
                ok, buf = cv2.imencode(".jpg", img[y:y + h, x:x + w], [cv2.IMWRITE_JPEG_QUALITY, 90])
                return buf.tobytes() if ok else None
        except Exception:
            return None

    def do_POST(self):
        u = urlparse(self.path)
        why = self._refused(u.path)
        if why:
            return self._deny(why)
        # JSON and nothing else. A form or a text/plain body is what another
        # page can send without the browser asking this server first, and the
        # body used to be parsed as JSON whatever it said it was.
        if (self.headers.get("content-type") or "").split(";")[0].strip().lower() != "application/json":
            return self._json({"error": "the studio takes JSON"}, 415, headers=CLOSE)
        try:
            n = int(self.headers.get("content-length", 0))
            if not 0 <= n <= MAX_BODY:
                return self._json({"error": "that request is too large"}, 413, headers=CLOSE)
            body = json.loads(self.rfile.read(n) or b"{}")
        except (ValueError, TypeError):
            return self._json({"error": "bad request body"}, 400)
        if not isinstance(body, dict):
            return self._json({"error": "bad request body"}, 400)
        try:
            if u.path == "/api/ingest":
                card, name = body.get("card", ""), body.get("name", "")
                name = name.strip() if isinstance(name, str) else ""
                # Starting with a letter or a digit: a name starting with a dot
                # makes a shoot the list never shows, and one starting with a
                # dash reaches ingest.py as an option rather than a name.
                if not card or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name):
                    return self._json({"error": "pick a card and name the shoot like 2026-10-04-lake"})
                # One of the cards this page offered, and nothing else. ingest.py
                # will copy any folder it is given ("the card, or any folder of
                # files"), which is right at a terminal; here a path in a
                # request made any folder he can read into a shoot the studio
                # would then serve back as his photographs.
                if card not in cards():
                    return self._json({"error": f"{card} is not a memory card this Mac can see: "
                                                "put the card in and pick it from the list"}, 400)
                # Into a shoot that already exists only when he asked for that
                # (`into`): to finish a copy that stopped part way, or to add
                # a second card to the night's shoot, until it is culled.
                into = bool(body.get("into"))
                try:
                    over = _copy_into(name, card, into)
                except NotNow as e:
                    return self._json({"error": str(e)})
                verify = body.get("verify") or "in-flight"
                if verify not in ("in-flight", "end", "none"):
                    return self._json({"error": "verify must be in-flight, end or none"})
                paused = self._claim()
                title = f"copying the card into {name}"
                if body.get("queue"):
                    # A card copy can be left on the list like anything else -
                    # and it is the one item most likely to have gone stale by
                    # its turn, because the card can be taken out of the Mac
                    # in between. _b_ingest looks for it again before it
                    # starts, and says so in his list if it has gone.
                    try:
                        item = self.jobs.add("ingest", name,
                                             {k: v for k, v in body.items() if k not in ("queue", "name")})
                    except NotNow as e:
                        return self._json({"error": str(e)}, 409)
                    # A cull of the shoot already waiting goes behind this
                    # copy, so it is one cull over both cards and not a cull
                    # of the first that then refuses the second.
                    _cull_after_copy(self.jobs, name, item["id"])
                    return self._json({"ok": True, "name": name, "id": item["id"],
                                       "queued": item["id"] != self.jobs.id, "added": item,
                                       **self._list(), **paused})
                ok = self.jobs.start("ingest", title,
                                     [PY, str(HERE / "ingest.py"), card, name, "--verify", verify],
                                     shoots_dir() / name / "cull" / "logs" / "ingest.log", shoot=name,
                                     after_done=_follow_with_a_cull(name) if body.get("then_cull") else None,
                                     over=over,
                                     opts={k: v for k, v in body.items() if k not in ("queue", "name")})
                if ok:
                    # Which card this came from, so putting it back in says so
                    # instead of offering to copy the same shoot twice.
                    # Which card, and what was asked of the copy. The verify
                    # mode was never stored, so the ingest card could not say
                    # "checked" honestly even in principle - it said it after
                    # --verify none, after a copy that died part way, and above
                    # a red verification FAILURE. A card added to a shoot keeps
                    # the shoot's kind.
                    if into:
                        Shoot(shoots_dir() / name).set_meta(card=card, verify=verify)
                    else:
                        Shoot(shoots_dir() / name).set_meta(kind=kind_of(body.get("kind")), card=card, verify=verify)
                return self._json({"ok": True, "name": name, "id": self.jobs.id, "queued": False, **paused} if ok
                                  else self._busy(title))
            if u.path == "/api/update/download":
                if not UPDATE.get("url"):
                    return self._json({"error": "no update to download"})
                return self._job(body, "update", f"downloading version {UPDATE.get('latest')}",
                                 [PY, str(HERE / "update.py"), "--download", UPDATE["url"]], ROOT / "update.log")
            if u.path == "/api/update/install":
                # Only the app's own engine swaps the app. A studio run from a
                # checkout finds the app's support folder, and so its staged
                # build, through the same resolver; asked to install it, it
                # would hand the checkout shell's pid to update.py as the app
                # to wait for.
                if not APP:
                    return self._json({"error": "only the app installs an update"})
                if not staged_update().exists():
                    return self._json({"error": "nothing staged to install"})
                pid = int(os.environ.get("PIPELINE_APP_PID") or os.getppid())
                # Detached: it outlives this server and the app, waits for the app to quit, swaps and relaunches.
                subprocess.Popen([PY, str(HERE / "update.py"), "--install", "--pid", str(pid)], start_new_session=True,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                self._json({"ok": True})
                print("QUIT", flush=True)   # the app quits on this line
                threading.Thread(target=self.server.shutdown, daemon=True).start()
                return None
            if u.path == "/api/job/stop":
                # With an id, the job waiting in line with that id is taken out
                # of it; without one, whatever is running now is stopped.
                jid = body.get("id")
                if isinstance(jid, int) and jid != self.jobs.id:
                    return self._json({"ok": self.jobs.cancel(jid)})
                return self._json({"ok": self.jobs.stop()})
            # ------------------------------------------- the list of work
            #
            # One list, filled on purpose. Everything under here reads or
            # changes the SAME queue Jobs has always had - there is not a
            # second mechanism anywhere - and every one of them answers with
            # the whole list afterwards, so the app never has to work out what
            # its own request did to the order.
            if u.path == "/api/queue":
                kind, name = body.get("kind"), body.get("name") or body.get("shoot") or ""
                if not isinstance(kind, str) or not isinstance(name, str):
                    return self._json({"error": "say what to do and which shoot"}, 400)
                # Whatever else he chose, exactly as the route that does this
                # one thing now would read it off a body.
                opts = {k: v for k, v in body.items() if k not in ("kind", "name", "shoot", "queue")}
                try:
                    item = self.jobs.add(kind, name, opts, why=str(body.get("why") or ""))
                except NotNow as e:
                    # A refusal in one sentence that says why, and the same
                    # sentence the app prints beside the control rather than
                    # hiding it. 409 and not 400: nothing about the request is
                    # malformed, it is the asking that is refused.
                    return self._json({"error": str(e), "queueable": kind not in NEVER_QUEUED,
                                       **self._list()}, 409)
                except Exception as e:      # noqa: BLE001
                    return self._json({"error": _refusal(e)}, 400)
                return self._json({"ok": True, "added": item, "id": item["id"], **self._list()})
            if u.path == "/api/queue/order":
                ids = body.get("ids")
                if not isinstance(ids, list):
                    return self._json({"error": "give the order as a list of ids"}, 400)
                ok = self.jobs.reorder(ids)
                return self._json({"ok": ok, **self._list()})
            if u.path == "/api/queue/remove":
                jid = body.get("id")
                if not isinstance(jid, int):
                    return self._json({"error": "say which one"}, 400)
                return self._json({"ok": self.jobs.cancel(jid), **self._list()})
            if u.path == "/api/queue/clear":
                # What is running is NOT on the list and is not touched by
                # this. Stopping it is a different button and says so.
                return self._json({"ok": True, "removed": self.jobs.clear(), **self._list()})
            if u.path == "/api/queue/hold":
                held = self.jobs.hold(bool(body.get("held", True)))
                return self._json({"ok": True, "held": held, **self._list()})
            if u.path == "/api/storage/default-retain":
                # Settings ▸ Storage's number. A lock, like the shoot's own
                # (see /api/storage/retain): nothing is scheduled by it.
                try:
                    days = max(0, min(36500, int(body.get("days"))))
                except (TypeError, ValueError):
                    return self._json({"error": "give a number of days"})
                set_default_retain(days)
                return self._json({"ok": True, **default_retain()})
            if u.path.startswith("/api/learned/"):       # what the cull has learned (see the block above)
                obj, code = learned_post(u.path, body, self.jobs)
                return self._json(obj, code)
            if u.path == "/api/setup":
                # First run: CLIP into the cache, with a bar. Everything else is in the bundle or the checkout.
                return self._job(body, "setup", "getting the picture model, once",
                                 [PY, str(HERE / "fetch_clip.py")], ROOT / "setup.log")
            s = self._shoot(body.get("name", ""))
            if not s:
                return self._json({"error": "no such shoot"}, 404)
            if u.path == "/api/prefetch":
                # Which frames he is about to want. It answers at once and the
                # decoding happens behind it; nothing here is written that a
                # request for the frame itself would not write.
                stems = body.get("stems") or []
                if not isinstance(stems, list):
                    return self._json({"error": "stems is a list of frame names"}, 400)
                return self._json({"ok": True, "warming": warm(s.folder.name, stems)})
            if u.path == "/api/review":
                # Where he is and which bursts he has been through. It writes
                # its own file and touches no rating, so nothing here can lose
                # or alter a verdict: the worst this endpoint can do is lose
                # his place.
                seen, unseen = body.get("seen") or [], body.get("unseen") or []
                # Lists of burst keys. A string here is iterated a letter at a
                # time, which would file one burst per letter in his record of
                # what he has been through.
                if not isinstance(seen, list) or not isinstance(unseen, list):
                    return self._json({"error": "a burst is named in a list"}, 400)
                r = s.set_review(at=body.get("at"), seen=seen, unseen=unseen)
                return self._json({"ok": True, "seen": len(r["bursts"]), "at": r["at"]})
            if u.path == "/api/kind":
                out: dict = {"ok": True}
                if "kind" in body:
                    s.set_meta(kind=kind_of(body.get("kind")))
                if "reviewed" in body:
                    s.set_meta(reviewed=bool(body["reviewed"]))
                    try:
                        s.remember_selects()
                    except ValueError as e:
                        # Walking past the keepers step files the key as a side
                        # effect. A refusal is the guard working, not a fault in
                        # the server, so it comes back as text the page can show
                        # instead of a 500 nobody reads.
                        return self._json({"ok": True, "error": str(e)})
                if "finished" in body:
                    s.set_meta(finished=time.strftime("%Y-%m-%d") if body["finished"] else False)
                    if body["finished"]:
                        # What it teaches, written down now: the frames he
                        # exported, not every one he kept (learned.taught).
                        s.remember_exports()
                        # A finished shoot is the one thing that teaches, so
                        # the learning run is asked for here rather than by a
                        # button he has to know to press. It waits its turn
                        # behind whatever is running (learned_start), and
                        # nothing it learns is used until the keeper check has
                        # passed it.
                        try:
                            out["learning"] = learn_from_finished(self.jobs, s.folder.name)
                        except Exception as e:  # noqa: BLE001
                            out["learning"] = {"error": _refusal(e)}
                if "style" in body and body["style"] in ("normal", "action"):
                    s.set_meta(style=body["style"])
                return self._json(out)
            if u.path == "/api/open":
                what = body.get("what")
                if not isinstance(what, str):
                    return self._json({"error": "say which folder to show"}, 400)
                if what == "photolab":
                    # Open the folder of frames the photographer kept, not the whole card. The
                    # raw folder is every frame the photographer ever shot, which means finding
                    # the photographer's own selection again inside PhotoLab; gather() builds a
                    # folder that is only the photographer's keepers, each with its sidecar.
                    import gather as gmod
                    try:
                        target, summary = gmod.build_with_summary(s.folder)
                    except Exception as e:  # noqa: BLE001
                        return self._json({"error": f"could not build the edit folder: {e}"})
                    editor = body.get("editor") or s.meta().get("editor") or "dxo"
                    editor = editor if editor in EDITOR_NAMES else "dxo"
                    # The app already displays note instead of its generic success
                    # line. Keep the complete list structured; name only three here.
                    missing = summary["missing_files"]
                    partial = ""
                    if missing:
                        examples = ", ".join(missing[:3])
                        if len(missing) > 3:
                            examples += f" and {len(missing) - 3} more"
                        noun = "original was" if len(missing) == 1 else "originals were"
                        partial = f'{len(missing)} {noun} not found: {examples}.'

                    def opened_note(destination: str) -> str:
                        return (f'Opened {summary["gathered"]} of {summary["total"]} keepers '
                                f'in {destination}. {partial}')

                    def failed(message: str, **extra) -> dict:
                        return {"ok": False, "folder": str(target), "gather": summary,
                                "error": message + (f" {partial}" if partial else ""), **extra}

                    app = find_editor(editor)
                    if app is None:
                        why = _open([str(target)])
                        if why:
                            return self._json(failed(
                                f"{EDITOR_NAMES[editor]} was not found in Applications, "
                                f"and the folder did not open in Finder either: {why}"))
                        note = (f"{EDITOR_NAMES[editor]} was not found in Applications, "
                                "so the folder was opened in Finder.")
                        if partial:
                            note += " " + opened_note("Finder")
                        return self._json({"ok": True, "folder": str(target),
                                           "gather": summary, "note": note})
                    # Waited for: a refusal from macOS is a line on the page,
                    # never "Opened in PhotoLab" over an empty screen.
                    why = _open(["-a", str(app), str(target)])
                    if why:
                        return self._json(failed(
                            f"{EDITOR_NAMES[editor]} did not open: {why}", app=app.name))
                    result = {"ok": True, "folder": str(target), "app": app.name, "gather": summary}
                    if partial:
                        result["note"] = opened_note(EDITOR_NAMES[editor])
                    return self._json(result)
                else:
                    # "decisions" is how a shoot too damaged to open reaches
                    # him: the front page cannot show him the step cards, but
                    # it can put him in front of the file that will not read.
                    # It resolves through decision_path, so a migrated library
                    # and an un-migrated one both land on the right folder.
                    # "shoot" for the damaged row whose broken file is not a
                    # decisions file at all - an unreadable cull.csv - so the
                    # button lands on the folder that actually holds it rather
                    # than confidently opening the wrong one.
                    d = {"export": s.export, "raw": s.raw, "edit": s.folder / "edit",
                         "shoot": s.folder, "reels": s.folder / "reels",
                         "instagram": s.folder / "instagram",
                         "decisions": decision_path(s.cull, "organize.json").parent}.get(what)
                    # One of the folders this shoot's exports were found in,
                    # named by its path - and only one of those, so a request
                    # cannot open any folder it likes.
                    if what == "exported":
                        asked = body.get("path")
                        if not isinstance(asked, str) or asked not in s.export_dirs():
                            return self._json({"ok": False, "error": "That folder holds none of this shoot's exports."})
                        d = Path(asked)
                    if d is None and EXTM and hasattr(EXTM, "folder"):
                        d = EXTM.folder(s, what)
                    d = d or s.folder
                    # A button that says it will SHOW him a folder must not
                    # create one. "Show the export folder" mkdir'd export/
                    # inside his shoot, so a shoot whose exports are in
                    # edit/edited/ grew an empty export/ that the Done card
                    # then pointed at. Same rule as _job_log's.
                    if not d.is_dir():
                        return self._json({"ok": False, "missing": str(d),
                                           "error": f"there is no {d} yet, so there is nothing to show"})
                    why = _open([str(d)])
                    if why:
                        return self._json({"ok": False, "folder": str(d),
                                           "error": f"{d} did not open in Finder: {why}"})
                    return self._json({"ok": True, "folder": str(d)})
            if u.path == "/api/cull":
                # Presets are their own step after the keepers are chosen, so the
                # slowest part of the run is spent on frames that survived. A step
                # list without a "presets" step asks for them here instead, which
                # is how an extension keeps the old one-shot behaviour.
                return self._work(body, "cull", s.folder.name)
            if u.path == "/api/reel":
                # Both shapes are made of a burst. Which of its frames exist as
                # exports is reel.py's business; this passes on what he chose in
                # the card: the burst, the shape, the frames he left in, where
                # to look for his exports, and how it should move.
                return self._work(body, "reel", s.folder.name)
            # The Instagram step (see instagram_status). Working the cuts out
            # and saving one cut or the shape answer at once; making the
            # copies is his work, built in one place (WORK) whether he does it
            # now or leaves it on the list.
            if u.path == "/api/instagram/plan":
                return self._json(instagram_plan(s, self.jobs))
            if u.path == "/api/instagram/make":
                _ig_forget(s)
                return self._work(body, "instagram", s.folder.name)
            if u.path == "/api/instagram/crop":
                obj, code = instagram_crop(s, body)
                return self._json(obj, code)
            if u.path == "/api/instagram/shape":
                obj, code = instagram_shape(s, body, self.jobs)
                return self._json(obj, code)
            if u.path == "/api/spread":
                # His edit from one frame of a burst onto the rest of it, so the
                # whole burst can be exported and the cut is not four frames
                # long. It gathers the burst into its own folder, and that
                # folder is what PhotoLab opens.
                return self._work(body, "spread", s.folder.name)
            if u.path == "/api/presets":
                # Sidecars carry every setting themselves, so nothing is installed into
                # PhotoLab's preset folder and nothing has to be picked from a list.
                return self._work(body, "presets", s.folder.name)
            if u.path == "/api/selects":
                # Kept up to date on every keep and drop; this is the explicit
                # refresh, and the one that picks up an export made since.
                try:
                    n = s.remember_selects(narrow=bool(body.get("confirm")))
                except KeyUnreadable as e:
                    # No confirm flag: pressing the button again cannot mend a
                    # key that will not parse, and the page would otherwise
                    # offer to write over it.
                    return self._json({"error": str(e)})
                except ValueError as e:
                    return self._json({"error": str(e), "confirm": True})
                if not n:
                    return self._json({"error": "Nothing exported or kept yet."})
                return self._json({"n": n, "from": _recorded_from(s.recorded_keepers(), s.exported())})
            if u.path == "/api/label":
                # Why a frame was dropped, in the photographer's words: the training data the cull lacks.
                label = body.get("label", "")
                try:
                    file = s.frame(body.get("file"))
                except ValueError as e:
                    return self._json({"error": str(e)}, 400)
                if not isinstance(label, str) or len(label) > 200:
                    return self._json({"error": "a reason is a few words"}, 400)
                lp = decision_path(s.cull, "labels.json")
                # Read whole, changed, written whole, like the ratings - so it
                # loses a reason to an overlapping write in exactly the same
                # way, and takes the same lock.
                with _DECIDE_LOCK:
                    labels = json.loads(lp.read_text()) if lp.exists() else {}
                    labels[file] = label
                    lp.parent.mkdir(parents=True, exist_ok=True)
                    write_json_atomic(lp, labels)
                return self._json({"ok": True})
            if u.path == "/api/rating":
                # Checked before anything is touched, so a refusal leaves the
                # frame exactly as it was and says why in words the page
                # prints under it. set_rating checks the same again.
                try:
                    file, rating = s.frame(body.get("file")), stars_asked(body.get("rating"))
                except ValueError as e:
                    return self._json({"error": str(e)}, 400)
                s.set_rating(file, rating)
                # The star is written either way; key_note is the answer key
                # saying it declined to follow, in a sentence the page prints
                # rather than an alert that would break the culling rhythm.
                return self._json({"ok": True, "key_note": s.last_key_refusal or ""})
            if u.path == "/api/storage/retain":
                # The number is a lock, not a trigger. Nothing on this machine
                # is scheduled by writing it: all it decides is when the expire
                # button below stops refusing. A timer that deletes photographs
                # while he is not watching is the shape of the selects.json
                # incident, and there is not one in this pipeline.
                try:
                    days = max(0, min(36500, int(body.get("days"))))
                except (TypeError, ValueError):
                    return self._json({"error": "give a number of days"})
                s.set_meta(retain_days=days)
                if body.get("default"):
                    set_default_retain(days)
                return self._json({"ok": True, "days": days})
            if u.path == "/api/storage/check":
                # Nothing to confirm: verify reads and compares, and --record
                # only fills in checksums that were never taken. It is the one
                # storage job with no plan in front of it.
                return self._job(body, "stor-check", STOR_TITLES["check"].format(n=s.folder.name),
                                 _stor_argv(s, "check", body, apply=False), _job_log(s), s.folder.name)
            if u.path == "/api/storage/plan":
                what = body.get("what")
                if what not in STOR_VERBS:
                    return self._json({"error": "no such thing to plan"})
                # What the shoot looks like at the moment the dry run is about
                # to read it. Written first: a state file with no list behind
                # it costs a re-draw, a list with no state behind it is a
                # promise about a shoot nobody measured.
                state = _stor_state(s, what)
                paused = self._claim()
                title = f"working out what would go in {s.folder.name}"
                argv = _stor_argv(s, what, body, apply=False)
                if body.get("queue"):
                    # "Do It After": his request goes into the line rather
                    # than being turned away. The state is written when the
                    # job actually starts, not now, because the list has to be
                    # about the shoot as it is when it is read - which is
                    # _b_plan's `then`, and why this goes through the list
                    # rather than freezing a command here.
                    try:
                        item = self.jobs.add(f"plan-{what}", s.folder.name,
                                             {k: v for k, v in body.items() if k != "queue"})
                    except NotNow as e:
                        return self._json({"error": str(e)}, 409)
                    return self._json({"ok": True, "id": item["id"],
                                       "queued": item["id"] != self.jobs.id, "added": item,
                                       **self._list(), **paused})
                ok = self.jobs.start(f"plan-{what}", title, argv, _plan_log(s), shoot=s.folder.name,
                                     opts={k: v for k, v in body.items() if k != "queue"})
                if ok:
                    write_atomic(_plan_state(s), state)
                return self._json({"ok": True, "id": self.jobs.id, "queued": False, **paused} if ok
                                  else self._busy(title))
            if u.path == "/api/storage/apply":
                what = body.get("what")
                if what not in STOR_VERBS:
                    return self._json({"error": "no such thing to apply"})
                # A bare POST is not a confirmation. The CLI needs --apply after
                # printing its list; this needs the list to have been drawn and
                # handed back. Asked first because it is the one question that
                # can be answered without reading anything: this sat under
                # read_plan, which answers "that list was drawn for something
                # else" whenever there is no plan on disk, so the 400 this
                # endpoint is documented to give was reachable only when a
                # matching plan happened to be lying there. The contract was
                # right and the order was wrong.
                if not body.get("token"):
                    return self._json({"error": "nothing was confirmed: ask for the list first"}, 400)
                plan = read_plan(s, what, body)
                if plan.get("error"):
                    return self._json(plan)
                if not plan["ready"]:
                    return self._json({"error": "that list has nothing in it to apply."})
                # The token is the list he was shown. Refusing on a mismatch is
                # the whole point: a confirmation he saw has to be a
                # confirmation of the thing that actually happens.
                if body.get("token") != plan["token"]:
                    # The list in that answer is the one that was DRAWN, read
                    # back off a log written before the shoot moved; only the
                    # token was recomputed. Handing both back together would
                    # pair a stale description with a live authorisation, which
                    # is exactly the confirmation-of-the-wrong-thing this whole
                    # path exists to prevent. It goes back with no token, and
                    # the page asks for the list again.
                    return self._json({"stale": True, "plan": dict(plan, token=""),
                                       "error": "what is on disk changed since that list was drawn — here it is again"})
                if what == "expire" and plan["counts"].get("doomed"):
                    want = str(plan["counts"]["doomed"])
                    if str(body.get("typed", "")).strip() != want:
                        return self._json({"error": f"type {want} to confirm that {want} photographs will cease to exist"})
                paused = self._claim()
                title = STOR_TITLES[what].format(n=s.folder.name)
                # What it was asked for with goes with it only so a crash
                # under a copy can put it back on the list; a kind that
                # removes anything is not one the list can rebuild, and is
                # never put back (Jobs._cut_off, NEVER_QUEUED).
                ok = self.jobs.start(f"stor-{what}", title,
                                     _stor_argv(s, what, body, apply=True),
                                     _job_log(s), shoot=s.folder.name,
                                     opts={k: v for k, v in body.items() if k not in ("queue", "token")})
                if ok:
                    # A list is spent once it has been acted on. The CLI's is
                    # too: it is on his screen and he types the command again
                    # to see it afresh. Leaving it readable let the same
                    # confirmation be handed back a second time, against a
                    # shoot the first one had already changed.
                    _plan_state(s).unlink(missing_ok=True)
                return self._json({"ok": True, "id": self.jobs.id, "queued": False, **paused} if ok
                                  else self._busy(title, can_queue=False))
            m = re.match(r"^/api/ext/([a-z_]+)$", u.path)
            if m:
                if not EXTM:
                    return self._json({"error": "no extension is installed on this machine"})
                # jobs/log: an extension's long work (anything that talks to the
                # network, or builds) runs through the same runner as a cull, so
                # it gets the same bar, the same log and the same Stop button,
                # rather than a request that hangs the page for two minutes.
                return self._json(EXTM.route(m.group(1), s, body, {
                    "PY": PY, "HERE": HERE, "jobs": self.jobs,
                    # This launch's key. An extension that serves its own pages
                    # has to ask for it the way this server does, and it is in
                    # PIPELINE_STUDIO_KEY for the same reason; here so a route
                    # can hand it to something it starts itself.
                    "key": self.server.key,
                    "log": lambda kind: _kind_log(s, kind)}))
        except Exception as e:  # noqa: BLE001
            # What could not be written and where, in his words: a refused
            # star used to arrive as errno text naming write_atomic's temp file.
            return self._json({"error": _refusal(e)}, 500)
        self._send(404, b"not found", "text/plain")


class Server(ThreadingHTTPServer):
    request_queue_size = 128
    daemon_threads = True

    def __init__(self, addr, handler, key: str | None = None):
        super().__init__(addr, handler)
        # PIPELINE_STUDIO_KEY when something outside made one (the app, a
        # restart of this same process); otherwise one of its own. Never a
        # constant, and never written to disk: it is only good for as long as
        # this server is up.
        self.key = key or os.environ.get("PIPELINE_STUDIO_KEY") or secrets.token_urlsafe(32)
        # The names this server answers to: the port it actually got, which
        # with --port 0 nobody knows until the socket is bound.
        port = self.server_address[1]
        names = ("127.0.0.1", "localhost", "[::1]")
        self.hosts = {f"{h}:{port}" for h in names} | (set(names) if port == 80 else set())
        self.origins = {f"http://{h}" for h in self.hosts}

    def handle_error(self, request, client_address):
        # A client that opened a connection and dropped it before sending a
        # request line (a port probe, a tab closed mid-load) is not an error
        # worth a stack trace in the app's log.
        if isinstance(sys.exc_info()[1], (ConnectionResetError, BrokenPipeError)):
            return
        super().handle_error(request, client_address)



def _mtime(f: str) -> float | None:
    try:
        return Path(f).stat().st_mtime
    except OSError:
        return None


def _inside_app() -> bool:
    """Whether this copy is the one frozen inside the .app bundle."""
    return ".app/Contents/" in str(HERE)


def _sources() -> dict[str, float]:
    """Every source file this process has actually loaded, from the pipeline or
    the extension, with its mtime.

    Taken from sys.modules and not from a list, because a list is what was wrong
    the first time: it named studio.py, reel.py and spread.py. The last two are
    started fresh for every job and can never be stale; restarting for them
    only dropped whatever request was in flight. What CAN be stale is anything
    loaded into this process - common, presets, taste, library, gather, and
    above all the extension's studio_ext.py, which is loaded once at start and
    whose routes are the Publish step. Read on every poll, so a module a
    handler imports for the first time at 3pm is watched from 3pm on."""
    roots = tuple(str(r) for r in (HERE, EXT) if r)
    out = {}
    # EXTM by name as well: load_ext builds it with module_from_spec and never
    # registers it, so it is not in sys.modules, and it was the one file this
    # most needed to watch. Measured: touching studio_ext.py did not restart.
    for m in [*sys.modules.values(), EXTM]:
        f = getattr(m, "__file__", None)
        if not f or not f.endswith(".py"):
            continue
        f = os.path.abspath(f)
        if f.startswith(roots):
            t = _mtime(f)
            if t is not None:
                out[f] = t
    return out


def _compiles(files: list[str]) -> str | None:
    """None if every file compiles, else the first error.

    An editor saves a file half-written, and so does anything that edits a file
    in several steps. Restarting into a syntax error does not restart the
    server: it kills it, and nothing brings it back. So a change is only acted
    on once it compiles, and until then the old process keeps serving."""
    # The builtin compile(), not py_compile: py_compile insists on writing a
    # .pyc somewhere, refused os.devnull as "a non-regular file", and that
    # exception killed the watcher thread on the first change it ever saw.
    for f in files:
        try:
            compile(Path(f).read_text(), f, "exec")
        except SyntaxError as e:
            return f"{Path(f).name}:{e.lineno}: {e.msg}"
        except (OSError, ValueError) as e:
            return f"{Path(f).name}: {e}"
    return None


def _reloader() -> None:
    """Restart this process when its own code changes, once it is safe to.

    Safe means three things. Nothing is running, checked and acted on under the
    job lock: a job started between "nothing is running" and the restart would
    live on as an orphan the new process knows nothing about, and the page
    would offer to start a second one on top of it. The changed files compile.
    And it is a checkout, not the signed app (see the caller)."""
    seen = _sources()
    waiting = None
    while True:
        time.sleep(2)
        # A watcher that dies does not say so: a daemon thread's exception is
        # one traceback in a log nobody reads, and from then on every edit is
        # silently not picked up - the exact staleness this exists to prevent.
        # So a poll that fails is reported and the watching carries on.
        try:
            waiting = _poll(seen, waiting)
        except Exception as e:  # noqa: BLE001
            print(f"  (the code watcher hit {type(e).__name__}: {e}; still watching)", flush=True)


def _poll(seen: dict, waiting: str | None) -> str | None:
    """One look for changed code, and a restart if it is safe. Returns the
    compile error it is waiting on, so that error is printed once, not every
    two seconds."""
    now = _sources()
    changed = [f for f, t in now.items() if f in seen and t != seen[f]]
    for f, t in now.items():
        seen.setdefault(f, t)                         # first sight of a lazy import
    if not changed:
        return waiting
    bad = _compiles(changed)
    if bad:
        if bad != waiting:
            print(f"{bad}\n  not restarting until that compiles; the running copy keeps serving", flush=True)
        return bad
    jobs = Handler.jobs
    with jobs.lock:
        if (jobs.proc and jobs.proc.poll() is None) or jobs.queue:
            return None                               # finish the work first, and whatever is in line behind it
        print(f"\n{', '.join(Path(f).name for f in changed)} changed on disk; restarting so the "
              f"app and the engine agree. The app reconnects on its own.", flush=True)
        try:
            # argv[0] made absolute: nothing here changes directory today, but
            # a relative script path is one os.chdir away from a restart that
            # cannot find its own file.
            os.execv(sys.executable, [sys.executable, os.path.abspath(sys.argv[0]), *sys.argv[1:]])
        except OSError as e:
            print(f"  could not restart ({e}); stop and start it yourself", flush=True)
    return None


def _restart_args(argv: list[str]) -> list[str]:
    """argv without the port it asked for, so main() can put back the port it
    actually got. Nothing needs to be said about opening a page: a page is
    opened only when --open is passed, and a restart inherits that argument
    like any other."""
    out, skip = [], False
    for a in argv:
        if skip:
            skip = False
        elif a == "--port":
            skip = True
        elif not (a.startswith("--port=") or a == "--no-open"):
            out.append(a)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    # 0 by default, as the app has always asked for: the OS picks a free port
    # and the line below prints the address it picked. A fixed default made
    # every checkout in the world answer on the same well-known port, which
    # is where a page trying its luck would look first.
    ap.add_argument("--port", type=int, default=0,
                    help="the port to serve on (default: any free one; the address is printed, and opened only with --open)")
    # --no-open is kept because every caller in the tree passes it; it is now
    # the default, and --open is how a page is asked for.
    ap.add_argument("--no-open", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--open", dest="open_page", action="store_true",
                    help="open the engine's page in a browser (the app is the product; this is for looking at the engine)")
    ap.add_argument("--app", action="store_true", help="run as the process behind the Mac app: print PORT n, seed the models, quit on SIGTERM")
    ap.add_argument("--idle-exit", type=int, default=0, metavar="MINUTES",
                    help="quit after this long with no page open and no job running (0: never); the card watcher uses it so a server it started does not stay up for days")
    a = ap.parse_args()
    global APP
    APP = a.app
    # No shoots/ made here. The folder an engine starts on is not always the
    # one he meant: on first launch it starts on ~/photos before he has
    # picked his real library, and the mkdir left an empty ~/photos/shoots in
    # his home for a library that lives on another drive. The list reads a
    # missing folder as an empty library, and the copy makes the folder when
    # it writes the first shoot into it.
    seed_models()
    Handler.jobs = Jobs()
    try:
        srv = Server(("127.0.0.1", a.port), Handler)
    except OSError as e:
        # A raw Errno 48 traceback out of socketserver says nothing about what
        # to do, and the answer is always the same: another studio already has
        # the port. Name it, so the next line he types is the one that fixes
        # it rather than a search through ps.
        if e.errno != errno.EADDRINUSE:
            raise
        who = subprocess.run(["/usr/sbin/lsof", "-tnP", f"-iTCP:{a.port}", "-sTCP:LISTEN"],
                             capture_output=True, text=True).stdout.split()
        pids = " ".join(who) or "?"
        print(f"port {a.port} is already serving a studio"
              + (f" (pid {pids})" if who else "")
              + f".\n  Stop it:      kill {pids}"
              + f"\n  Or use another port:  --port {a.port + 1}"
              + "\n  Or let it pick one:   --port 0", flush=True)
        return 1
    # The list he left, read back before anything is served - and after the
    # port is his, so an engine that cannot serve never touches the list or
    # the job another engine is running (`Jobs._cut_off`). It is his intent
    # and not a runtime detail: he filled it at midnight and quit, and the
    # first thing this process owes him in the morning is the same list. What
    # was on it is checked one item at a time, the moment before each starts.
    Handler.jobs.load()
    Handler.jobs.start_list()
    port = srv.server_address[1]
    url = f"http://127.0.0.1:{port}/"
    # What a restart of this process has to come back as. The code watcher
    # below re-runs sys.argv, and with the port left to the OS it would come
    # back on another one, a new key and a new tab, and the tab he has open
    # would be talking to nothing. So it restarts on the port it got, with the
    # key it had (execv keeps the environment), and without opening a second
    # tab onto the page that is already open. Jobs and an extension's own
    # servers inherit the key the same way, so they can answer to it too.
    os.environ["PIPELINE_STUDIO_KEY"] = srv.key
    sys.argv = [sys.argv[0], *_restart_args(sys.argv[1:]), "--port", str(port)]
    print(f"PORT {port}", flush=True)
    # What it found, not only where it looked. The line said "shoots in
    # <path>" and nothing else, so a studio serving an empty library read
    # exactly like a studio serving his seven shoots, and the one thing worth
    # knowing - that there was nothing there - had to be guessed from a blank
    # sidebar.
    found = len(shoots())
    where = (f"{found} shoots in {shoots_dir()}" if found
             else f"NO SHOOTS: looked in {shoots_dir()} for folders with a raw/, a cull/ or frames in them")
    print(f"studio at {url}  {where}" + (f"  extension: {EXT.name}" if EXTM else "") + "  (Ctrl-C to stop)", flush=True)
    if checks_at_start():
        threading.Thread(target=check_for_update, daemon=True).start()
    # A learning run that was stood down for his work, and then the studio
    # quit before the machine went quiet, still wants to run: the ask is on
    # disk. Nothing else would look at it until the next job ended.
    _resume = threading.Timer(LEARN_RESUME_QUIET, Handler.jobs._pick_up_learning)
    _resume.daemon = True
    _resume.start()
    # The app sends SIGTERM when its window closes; stop serving, then stop whatever was running.
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=srv.shutdown, daemon=True).start())
    # Only when he says so. The page this would open is the retired studio:
    # the product is the Mac app, and this process is its engine. It opened by
    # default, and an engine restarting itself (below, when its own source
    # changes) carried that default into a checkout that had not rewritten its
    # argv — so editing studio.py in a worktree dropped the old web page into
    # his browser while he was working in the app.
    if a.open_page:
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    # Running from a checkout, this restarts itself when its own source
    # changes. studio.py is loaded once, and the app holds its screens in a
    # running program, so the difference is invisible: the screen looks new,
    # the endpoint behind it is old, and what comes back is a sentence about
    # the old code ("a reel is a cut, a sequence, a loop or a boomerang" from
    # a build that had never heard of a timelapse). That has cost three
    # separate rounds of "it still doesn't work" when the only thing wrong was
    # a process from ten minutes ago.
    #
    # Never inside the app: there Contents/Resources is signed and frozen, the
    # file cannot change under it, and re-exec would work against the app's own
    # lifecycle. Never while a job is running, because re-exec would orphan a
    # cull or a spread mid-write. It waits for the work to finish.
    if not APP and not _inside_app():
        threading.Thread(target=_reloader, daemon=True).start()

    if a.idle_exit > 0:
        # An open page pings every 30 s, so "idle" means no page and no job.
        def reaper():
            while True:
                time.sleep(60)
                if time.time() - Handler.last_request > a.idle_exit * 60 and not Handler.jobs.status()["running"]:
                    print(f"idle for {a.idle_exit} minutes; quitting")
                    srv.shutdown()
                    return
        threading.Thread(target=reaper, daemon=True).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    # On purpose, so not a job cut off by a crash: the note goes, and the
    # whole group is stopped, not only the process at its head.
    Handler.jobs.quit()
    if EXTM and hasattr(EXTM, "shutdown"):
        EXTM.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
