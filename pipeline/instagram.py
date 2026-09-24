#!/usr/bin/env python3
"""Instagram-sized copies of a shoot's finished photographs.

    ./pl instagram <shoot> --all --plan               work out every cut, make nothing
    ./pl instagram <shoot> TSC06169 TSC06171 ...      these frames
    ./pl instagram <shoot> --all                      every exported frame
    ./pl instagram <shoot> --all --ratio 4:5          the older, safer portrait size
    ./pl instagram <shoot> --all --landscape crop     landscapes cut to portrait too

--plan is the pass to run first. It walks the same frames, looks for the same
subject and writes the same record, and stops there: it says what every copy
would be - the window in the frame's own pixels, the size it would be written
at, and whether the profile grid would cut the subject - without writing a
JPEG. What it decided is in the record, so the run that follows makes the
copies from what you looked at and adjusted rather than deciding again, and
takes no --ratio or --landscape of its own unless you give it one: without
them it makes what was planned.

What it makes, in <shoot>/instagram/:

  portrait    3:4 at 1080x1440 by default - the tallest feed post Instagram
              takes, and the shape its profile grid shows, so the post and its
              thumbnail are the same picture. From a 2:3 frame it gives up 11%
              of the height; 4:5 at 1080x1350 (--ratio 4:5) gives up 17%.
  landscape   left whole, 1080 wide (1080x720 from a 3:2 frame). It fits the
              feed uncropped, but it sits small there, and the grid shows only
              its middle 3:4 - so each one is checked for whether its subject
              is inside that strip, and says so if not. --landscape crop cuts a
              portrait-shaped window out of it instead, around the subject.

Where a crop falls is decided by what the photograph is of: the faces the
detector finds, weighted toward the sharpest (the one the lens was on), else
the scene reader's subject, else the middle. The window keeps every face it
can fit, as near centred on the subject as the frame allows.

A crop and a resize, and nothing else. The colour is your edit: an export in
sRGB, tagged or untagged, is left exactly as it is, and one in anything else is
CONVERTED to sRGB through its own profile rather than handed over to be read as
sRGB by whatever drops the tag. No sharpening and no tone is added: this is a
copy of a finished photograph at another size, not a second edit of it.
Metadata is not carried - Instagram strips it anyway, and a camera serial
number has no business on a post.

Mixed shapes in one carousel: Instagram crops every card to the FIRST one's
shape. A run that makes both portraits and landscapes says so.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import io
import json
import math
import os
import sys
from pathlib import Path

HERE = Path(__file__).parent.absolute()
sys.path.insert(0, str(HERE))

import exports  # noqa: E402
from common import write_atomic  # noqa: E402

WIDE = 1080                   # every Instagram feed size is 1080 wide
RATIOS = {"3:4": (3, 4), "4:5": (4, 5)}
MAX_LANDSCAPE = 1.91          # the widest a feed post may be
TALLEST = 3 / 4               # and the tallest: a 2:3 frame does not fit a feed post whole
GRID = 3 / 4                  # the shape the profile grid shows of every post
# TALLEST and GRID are the same number today and are not the same fact: one is
# what Instagram accepts, the other what its grid shows of what it accepted.
# Instagram has moved the first of them once already (4:5 until 2025).
DETECT_PX = 1800              # detection runs on a copy this size; boxes scale back
JPEG_Q = 92                   # what is written; Instagram re-encodes it whatever it is given


def subject(img, judge, reader) -> tuple[float, float, tuple | None]:
    """(cx, cy, faces box) in the image's own pixels. faces box is the union of
    the main faces, for keeping them all inside the window where they fit."""
    import cv2
    h, w = img.shape[:2]
    k = min(1.0, DETECT_PX / max(h, w))
    small = cv2.resize(img, (int(w * k), int(h * k)), interpolation=cv2.INTER_AREA) if k < 1 else img
    faces = [f for f in judge.detect(small) if f.main] if judge else []
    if faces:
        def sharp(f):
            x, y, bw, bh = (int(v) for v in f.box)
            roi = small[max(0, y):y + bh, max(0, x):x + bw]
            return float(cv2.Laplacian(cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY), cv2.CV_64F).var()) if roi.size else 0.0
        sh = [sharp(f) for f in faces]
        top = max(sh) or 1.0
        wt = [max(0.08, (s / top) ** 2) for s in sh]
        cx = sum(x * (f.box[0] + f.box[2] / 2) for x, f in zip(wt, faces)) / sum(wt) / k
        cy = sum(x * (f.box[1] + f.box[3] / 2) for x, f in zip(wt, faces)) / sum(wt) / k
        x0 = min(f.box[0] for f in faces) / k
        y0 = min(f.box[1] for f in faces) / k
        x1 = max(f.box[0] + f.box[2] for f in faces) / k
        y1 = max(f.box[1] + f.box[3] for f in faces) / k
        # A face is a head. Put the centre a little below it, where the person
        # is, so a portrait crop keeps a body under the face and not sky over it.
        return cx, min(h, cy + (y1 - y0) * 0.6), (x0, y0, x1, y1)
    box = reader.subject_box(small) if reader else None
    if box:
        return (box[0] + box[2] / 2) / k, (box[1] + box[3] / 2) / k, None
    return w / 2, h / 2, None


def place(length: int, span: int, centre: float, keep: tuple[float, float] | None) -> int:
    """Where a window of `span` starts along an edge of `length`: centred on the
    subject, moved just enough to take in `keep` (the faces) when they fit,
    and never off the frame."""
    at = centre - span / 2
    if keep is not None and keep[1] - keep[0] <= span:
        at = min(max(at, keep[1] - span), keep[0])
    return int(round(min(max(at, 0.0), length - span)))


def window(w: int, h: int, want: float, cx: float, cy: float, faces) -> tuple[int, int, int, int]:
    """The crop (x, y, cw, ch) of shape `want` (width over height) out of w x h."""
    if w / h > want:                                  # too wide: take from the sides
        cw, ch = int(round(h * want)), h
        return place(w, cw, cx, faces and (faces[0], faces[2])), 0, cw, ch
    cw, ch = w, int(round(w / want))                  # too tall: take from top and bottom
    return 0, place(h, ch, cy, faces and (faces[1], faces[3])), cw, ch


# ------------------------------------------------------------ the record
#
# <out>/crops.json keeps, per frame, what a crop was decided FROM rather than
# the crop itself: where the subject is (fractions of the frame, so it holds at
# any size), whether the frame is cut or left whole, and his own adjustment if
# he made one. Every window is then arithmetic on that, so changing 3:4 to 4:5
# and making them again moves no crop he placed by hand, and re-opening a crop
# to adjust it needs no detector.
#
#   manual  {"cx", "cy", "scale"}: the centre of his window, and its size as a
#           share of the largest window of that shape the frame can give. The
#           page's editor does the same arithmetic (window_of) to draw it.
#
# The book is also what the planning pass leaves behind, and the reason there
# can be one: a frame's record is written whether or not a copy of it is made,
# so a frame IN THE BOOK WITH NO JPEG BESIDE IT is one whose crop has been
# worked out and not yet cut. The book says which shape it was worked out at
# (ratio, landscape), and a later run with neither flag makes exactly that.
CROPS = "crops.json"


def book(out: Path) -> dict:
    try:
        d = json.loads((out / CROPS).read_text())
        return d if isinstance(d, dict) and "frames" in d else {"frames": {}}
    except (OSError, ValueError):
        return {"frames": {}}


@contextlib.contextmanager
def held(out: Path):
    """The folder, locked, while the book is read, changed and written and
    while a copy in it is made.

    Two things write here: a run making copies, which takes minutes, and the
    studio's editor saving a window, which takes a second. Without the lock
    the run reads the book when it starts and writes it back when it ends,
    so a crop placed by hand in between was overwritten by the run's own idea
    of that frame - the record and the JPEG both. The lock is taken on the
    folder itself rather than on crops.json, which is replaced by rename and
    so is a different file from one moment to the next.

    A folder that cannot be locked (a filesystem with no flock) still works;
    it is then what it was before. Do not nest: the lock is the folder's, and
    a second one taken inside the first waits for a lock this process is
    itself holding. What is called from inside a block takes none of its own
    (make, and keep_book with locked=True); redo takes one and is called from
    outside."""
    out.mkdir(parents=True, exist_ok=True)
    fd = os.open(out, os.O_RDONLY)
    try:
        with contextlib.suppress(OSError):
            fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        with contextlib.suppress(OSError):
            fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def keep_book(out: Path, d: dict, locked: bool = False) -> None:
    """The book, whole or not at all. It was written through one fixed temp
    name and without fsync, so two writers shared a temp file and a power cut
    left the record of every crop truncated.

    Pass locked=True inside a `with held(out)` block. Anything that reads the
    book and writes it back later -- the studio's editor saving a window,
    this file's own run -- should hold the lock across both, or the read is
    already out of date by the time it is written."""
    def save() -> None:
        out.mkdir(parents=True, exist_ok=True)
        write_atomic(out / CROPS, json.dumps(d, indent=1) + "\n")
    if locked:
        save()
    else:
        with held(out):
            save()


def window_of(w: int, h: int, want: float, cx: float, cy: float, scale: float) -> tuple[int, int, int, int]:
    """His window: shape `want`, `scale` of the largest that fits, centred on
    (cx, cy) as fractions, pushed back inside the frame. The page's editor
    runs exactly this to draw what it will save."""
    # Halves round UP, as the page's Math.round does. Python's round() goes to
    # even, and 249 windows in 5,000 came out a pixel taller here than the
    # page drew them - invisible, but "what you see is what is written" should
    # be true exactly or it is not true.
    def up(v: float) -> int:
        return int(math.floor(v + 0.5))
    big = min(w, h * want)
    cw = min(w, max(16, up(big * min(max(scale, 0.05), 1.0))))
    # Rounded up, cw / want can come to one pixel more than the frame is tall:
    # a 4000 x 4002 frame at 3:4 and full size gives 4003, and the window then
    # started at y = -1 and PIL filled that row with black. Both edges are the
    # frame's.
    ch = min(h, up(cw / want))
    x = up(min(max(cx * w - cw / 2, 0), w - cw))
    y = up(min(max(cy * h - ch / 2, 0), h - ch))
    return x, y, cw, ch


def auto(entry: dict, want: float) -> tuple[int, int, int, int]:
    """The window this frame gets of that shape when nobody has placed one:
    on the subject, keeping every face that fits."""
    w, h, s = entry["w"], entry["h"], entry["subject"]
    f = s.get("faces")
    faces = (f[0] * w, f[1] * h, f[2] * w, f[3] * h) if f else None
    return window(w, h, want, s["cx"] * w, s["cy"] * h, faces)


def rect(entry: dict, want: float) -> tuple[tuple[int, int, int, int], tuple[int, int]]:
    """The crop (x, y, w, h) in the frame's pixels, and the size it is written at."""
    w, h = entry["w"], entry["h"]
    if entry["mode"] == "whole":
        fr = w / h
        if fr > MAX_LANDSCAPE:                         # wider than a feed post may be
            return auto(entry, MAX_LANDSCAPE), (WIDE, int(round(WIDE / MAX_LANDSCAPE)))
        if fr < TALLEST:
            # And taller than one may be. A 2:3 portrait left whole is 1080 x
            # 1620, which Instagram will not take: its composer cuts it to the
            # tallest it allows, around the middle of the frame, where the
            # subject may not be. Cut here it is cut around the subject, which
            # is the same thing this does for a panorama.
            return auto(entry, TALLEST), (WIDE, int(round(WIDE / TALLEST)))
        return (0, 0, w, h), (WIDE, int(round(WIDE / fr)))
    out = (WIDE, int(round(WIDE / want)))
    m = entry.get("manual")
    if m:
        return window_of(w, h, want, m["cx"], m["cy"], m["scale"]), out
    return auto(entry, want), out


def grid_ok(entry: dict, r: tuple[int, int, int, int], out: tuple[int, int]) -> bool:
    """Whether the subject is inside what the profile grid shows: its middle 3:4."""
    x, y, cw, ch = r
    sx = (entry["subject"]["cx"] * entry["w"] - x) / cw
    sy = (entry["subject"]["cy"] * entry["h"] - y) / ch
    ratio = out[0] / out[1]
    if ratio > GRID:
        half = GRID / ratio / 2
        return 0.5 - half <= sx <= 0.5 + half
    half = ratio / GRID / 2
    return 0.5 - half <= sy <= 0.5 + half


def in_srgb(im, icc: bytes | None) -> tuple[object, bytes | None, str]:
    """The picture in sRGB, the profile to embed beside it, and a line saying
    what was done if anything was.

    An export with no profile is sRGB by every reader's default, Instagram's
    included, and is left exactly as it is: nothing is decoded and re-encoded
    to no purpose. An export that says sRGB keeps its own profile bytes, so
    the copy carries the photographer's own file's profile and not a
    substitute of ours.

    Anything else is CONVERTED, through its own profile, rather than sent as
    it is. Instagram's own guidance is sRGB, and a wide-gamut file whose
    profile is dropped somewhere in the upload is read as sRGB: the same
    numbers, a narrower space, and every colour pulled in toward grey. The
    conversion is relative colorimetric with black-point compensation, which
    is what Adobe's own Convert to Profile does by default for RGB to RGB.
    A profile lcms cannot open leaves the picture as it stands and says so."""
    from PIL import ImageCms
    if not icc:
        return (im if im.mode == "RGB" else im.convert("RGB")), None, ""
    try:
        prof = ImageCms.ImageCmsProfile(io.BytesIO(icc))
        name = (ImageCms.getProfileDescription(prof) or "").strip()
    except Exception:  # noqa: BLE001
        return (im if im.mode == "RGB" else im.convert("RGB")), None, "its color profile could not be read; left as it is and untagged"
    if im.mode == "RGB" and "srgb" in name.lower():
        return im, icc, ""
    srgb = ImageCms.createProfile("sRGB")
    out = ImageCms.profileToProfile(im, prof, srgb, outputMode="RGB",
                                    renderingIntent=ImageCms.Intent.RELATIVE_COLORIMETRIC,
                                    flags=ImageCms.Flags.BLACKPOINTCOMPENSATION)
    return out, ImageCms.ImageCmsProfile(srgb).tobytes(), f"converted from {name} to sRGB"


def render(src: Path, dst: Path, r: tuple[int, int, int, int], out: tuple[int, int]) -> str:
    """A crop and a resize, and nothing else. The export's own ICC profile
    comes along, or the picture is converted to sRGB when it is in something
    else (in_srgb); its metadata, camera serial included, does not. Says what
    the colour needed, if anything."""
    from PIL import Image, ImageOps
    im = ImageOps.exif_transpose(Image.open(src))     # the picture as it is seen, whatever the camera wrote
    im, icc, note = in_srgb(im, im.info.get("icc_profile"))
    x, y, cw, ch = r
    crop = im.crop((x, y, x + cw, y + ch)).resize(out, Image.LANCZOS)
    # 4:4:4. Pillow's default for JPEG is 4:2:0, which halves the colour
    # resolution before Instagram halves it again in its own re-encode, and
    # what suffers is a red edge against skin. Photoshop's Save for Web stops
    # subsampling at quality 51 for the same reason.
    #
    # And no metadata. "comment" is the one field Pillow carries over from the
    # file it was opened from without being asked, so it is cleared by name.
    buf = io.BytesIO()
    crop.save(buf, "JPEG", quality=JPEG_Q, optimize=True, subsampling=0, comment=b"",
              **({"icc_profile": icc} if icc else {}))
    # Whole or not at all, and under a name of its own: the copies were
    # written to <stem>.tmp.jpg and renamed, so two runs of one frame wrote
    # through each other, and a run that was stopped left a .tmp.jpg behind
    # that the studio then listed as a copy that had been made.
    dst.parent.mkdir(parents=True, exist_ok=True)
    write_atomic(dst, buf.getvalue())
    return note


def detect(src: Path, judge, reader) -> dict:
    """The frame's size and its subject, as fractions."""
    import cv2
    import numpy as np
    from PIL import Image, ImageOps
    im = ImageOps.exif_transpose(Image.open(src)).convert("RGB")
    w, h = im.size
    cx, cy, faces = subject(cv2.cvtColor(np.asarray(im), cv2.COLOR_RGB2BGR), judge, reader)
    # Inside the frame. A detector's box runs off the edge on a face that is
    # half out of the picture, and the part that is off the edge is not a
    # face to keep in the window: read as it came, a box 1.1 frames wide
    # never "fits", so the window stopped being moved to take the faces in at
    # all and simply centred on the subject.
    clamp = lambda v: round(min(max(v, 0.0), 1.0), 5)  # noqa: E731
    return {"src": src.name, "w": w, "h": h, "mtime": int(src.stat().st_mtime),
            "subject": {"cx": clamp(cx / w), "cy": clamp(cy / h), "kind": "face" if faces else "scene",
                        "faces": [clamp(faces[0] / w), clamp(faces[1] / h),
                                  clamp(faces[2] / w), clamp(faces[3] / h)] if faces else None}}


def carry(disk: dict | None, fresh: dict | None, landscape: str) -> tuple[dict, str]:
    """This frame's record, from what is on disk and what was just detected,
    with every decision of the photographer's kept.

    A re-export used to throw his window away without a word: the record was
    replaced by the fresh detection, so a frame he had cropped by hand came
    back cut by the detector the next time he exported it with a different
    edit. His window is in fractions of the frame, so it still describes the
    same framing as long as the export is the same shape; when the shape has
    changed it cannot be trusted, and it is kept in the record (manual_was)
    rather than dropped, with a line saying so.

    And a window he placed keeps the frame cut, whatever --landscape says:
    placing one is a decision to cut, and a later run with the default was
    quietly turning his crop back into the whole frame."""
    if fresh is None:
        entry = dict(disk or {})
    else:
        entry = dict(fresh)
        if disk:
            for k in ("mode", "mode_by"):
                if disk.get("mode_by") == "you" and k in disk:
                    entry[k] = disk[k]
            if disk.get("manual"):
                same_shape = abs(disk["w"] / disk["h"] - entry["w"] / entry["h"]) < 0.005
                entry["manual" if same_shape else "manual_was"] = disk["manual"]
                if not same_shape:
                    entry["manual_was_size"] = [disk["w"], disk["h"]]
    said = ""
    if entry.get("manual_was") and not entry.get("manual"):
        said = "the export is a different shape from the one your crop was placed on: cut automatically, your crop kept in the record"
    if entry.get("mode_by") != "you":
        entry["mode"] = mode_for(entry, landscape)
        entry["mode_by"] = "run"
    return entry, said


def mode_for(entry: dict, landscape: str) -> str:
    """Cut or whole, for a frame whose mode is the run's to decide: cut when
    a window has been placed on it, when it is taller than wide, or when
    landscapes are being cut too; whole otherwise.

    One rule for two callers. A run applies it to every frame it writes, and
    the studio's shape switch applies it to every frame at once when he
    changes how landscapes are made; had each kept its own copy, the switch
    and the next run could disagree about the same frame. A frame whose mode
    he set himself is never passed here."""
    return "crop" if (entry.get("manual") or entry["h"] > entry["w"] or landscape == "crop") else "whole"


def figure(src: Path, out: Path, stem: str, entry: dict, want: float) -> dict:
    """What one copy would come to, worked out and not made: the window `make`
    would cut, in the frame's own pixels, the size it would be written at, and
    whether a copy of it is there already.

    The planning pass is this over every frame. Making the copies is then the
    same arithmetic and a render, so what he looked at and what is written
    cannot be two different decisions - they are one function apart."""
    r, size = rect(entry, want)
    w, h = entry["w"], entry["h"]
    return {"file": f"{stem}.jpg", "from": src.name,
            "shape": "portrait" if h > w else ("square" if w == h else "landscape"),
            "size": f"{size[0]}x{size[1]}", "kept": round(r[2] * r[3] / (w * h), 3),
            "grid_ok": grid_ok(entry, r, size), "subject": entry["subject"]["kind"],
            "adjusted": bool(entry.get("manual")) and entry["mode"] == "crop",
            "mode": entry["mode"], "frame": [w, h], "rect": list(r), "out": list(size),
            "made": (out / f"{stem}.jpg").is_file(), "said": ""}


# The size a copy was written at, read off its header once per version of the
# file: the studio asks for every copy of a shoot each time the step polls.
_COPY_SIZES: dict[str, tuple[int, tuple[int, int]]] = {}


def copy_size(p: Path, st: os.stat_result | None = None) -> tuple[int, int] | None:
    """The pixel size of a copy already in the folder, or None when it will
    not read. Only the header is read."""
    try:
        st = st or p.stat()
    except OSError:
        return None
    hit = _COPY_SIZES.get(str(p))
    if hit and hit[0] == st.st_mtime_ns:
        return hit[1]
    try:
        from PIL import Image
        with Image.open(p) as im:
            size = (int(im.size[0]), int(im.size[1]))
    except Exception:  # noqa: BLE001
        return None
    _COPY_SIZES[str(p)] = (st.st_mtime_ns, size)
    return size


def describe(src: Path, out: Path, stem: str, entry: dict | None, ratio: str, landscape: str) -> dict:
    """One exported frame as the studio's Instagram step draws it: the cut a
    copy would be made with now, the other shape's window beside it, the
    automatic window and what "whole" would be, and whether a copy is there
    and is exactly that cut.

    `cut` is rect(), the function make() cuts with, so the line drawn on the
    photograph and the copy written from it are one function apart - the same
    promise figure() makes to the planning pass. `ratio` and `landscape` are
    the shape the record is kept at; every frame's mode was already set from
    `landscape` when its record was written (mode_for), so it is carried
    along to say which shape this is a description of, not used again.

    The states, as the step names them:
      unplanned  no record for this frame: its cut has not been worked out
      planned    a record made from this very export (same file, same mtime)
      stale      a record made from an earlier export of it: its numbers are
                 still given, so something can be drawn, but a copy is not
                 made from them until it is worked out again
    A copy is current when it is there, is the size the cut is written at,
    and is newer than the export: then it is the cut shown, because a cut
    changed after a copy was made is made again at once."""
    st = src.stat()
    export_mtime = int(st.st_mtime)
    p = out / f"{stem}.jpg"
    try:
        cst = p.stat()
    except OSError:
        cst = None
    size = copy_size(p, cst) if cst is not None else None
    copy = {"out": list(size), "at": int(cst.st_mtime)} if (cst is not None and size) else None
    blank = {"stem": stem, "file": src.name, "export_mtime": export_mtime, "state": "unplanned",
             "frame": None, "shape": None, "mode": None, "mode_by": None, "adjusted": None,
             "manual": None, "subject": None, "cut": None, "other": None, "auto": None, "whole": None,
             "copy": copy, "copy_current": False}
    if not entry:
        return blank
    fresh = entry.get("src") == src.name and entry.get("mtime") == export_mtime
    want = RATIOS[ratio][0] / RATIOS[ratio][1]
    # The other portrait shape: 4:5 beside 3:4 and the other way about.
    other_ratio = next((r for r in RATIOS if r != ratio), ratio)
    other_want = RATIOS[other_ratio][0] / RATIOS[other_ratio][1]
    w, h = entry["w"], entry["h"]
    mode = entry["mode"]
    r, sz = rect(entry, want)
    cut = {"shape": ratio if mode == "crop" else "whole", "rect": list(r), "out": list(sz),
           "grid_ok": grid_ok(entry, r, sz), "kept": round(r[2] * r[3] / (w * h), 3)}
    cropped = dict(entry, mode="crop")
    if mode == "crop":
        o, osz = rect(cropped, other_want)
        other = {"shape": other_ratio, "rect": list(o), "out": list(osz), "grid_ok": grid_ok(entry, o, osz)}
    else:
        o, osz = rect(cropped, want)
        other = {"shape": ratio, "rect": list(o), "out": list(osz), "grid_ok": grid_ok(entry, o, osz)}
    a, _ = rect(dict(entry, manual=None, mode="crop"), want)
    wr, wsz = rect(dict(entry, manual=None, mode="whole"), want)
    return {**blank, "state": "planned" if fresh else "stale", "frame": [w, h],
            "shape": "portrait" if h > w else ("square" if w == h else "landscape"),
            "mode": mode, "mode_by": entry.get("mode_by") or "run",
            "adjusted": bool(entry.get("manual")) and mode == "crop",
            "manual": entry.get("manual") or None, "subject": entry["subject"],
            "cut": cut, "other": other, "auto": {"rect": list(a)},
            "whole": {"rect": list(wr), "out": list(wsz), "grid_ok": grid_ok(entry, wr, wsz)},
            # Current only for a record made from this export: a copy cut
            # from an earlier one's numbers is not the cut this export gets.
            "copy_current": bool(fresh and copy and copy["out"] == cut["out"] and cst.st_mtime >= st.st_mtime)}


def make(src: Path, out: Path, stem: str, entry: dict, want: float) -> dict:
    """Write one copy from its record, and say what it came to."""
    r = figure(src, out, stem, entry, want)
    r["said"] = render(src, out / f"{stem}.jpg", tuple(r["rect"]), tuple(r["out"]))
    r["made"] = True
    return r


def redo(shoot: Path, stem: str, out: Path | None = None) -> dict:
    """Make one frame again from its record, with no detector: what the page's
    editor calls when he saves an adjustment. A second, not a minute."""
    shoot = Path(shoot)
    out = out or shoot / "instagram"
    src = exports.files(shoot, {stem}).get(stem)
    # Under the lock, so that a run making copies of the whole shoot cannot
    # write its own idea of this frame over the window just saved.
    with held(out):
        d = book(out)
        entry = d["frames"].get(stem)
        if not entry:
            raise KeyError(f"{stem} has not been made yet")
        if src is None:
            raise KeyError(f"{stem} has no export any more")
        want = RATIOS[d.get("ratio", "3:4")][0] / RATIOS[d.get("ratio", "3:4")][1]
        return make(src, out, stem, entry, want)


def one(s: str, src: Path, out: Path, ratio: str, landscape: str, want: float, *,
        plan: bool, redetect: bool, models) -> dict:
    """Work out one frame's copy, or make it: its record carried forward (and
    its subject looked for, where it has to be), written, and the copy's
    figures - or the copy itself - from it."""
    was = book(out)["frames"].get(s)
    # The subject is looked for once. An export made again since (a new
    # edit, a new crop in PhotoLab) is a different picture, so it is looked
    # for again; so is everything, with --redetect. The detector runs outside
    # the lock: it takes seconds, and his editor should not wait on it.
    stale = (not was or was.get("src") != src.name or was.get("mtime") != int(src.stat().st_mtime))
    fresh = None
    if stale or redetect:
        judge, reader = models()
        fresh = detect(src, judge, reader)
    # The book is read again here, and written, and the copy made, all under
    # one lock: a run over a whole shoot takes minutes, and a window saved in
    # the studio while it runs used to be overwritten by what this run had
    # read when it started.
    with held(out):
        d = book(out)
        entry, said = carry(d["frames"].get(s) or was, fresh, landscape)
        d["frames"][s] = entry
        d["ratio"], d["landscape"] = ratio, landscape
        keep_book(out, d, locked=True)
        # A plan writes the record and nothing else. It is inside the lock
        # all the same: the record is what the copies are then made from,
        # and his editor saving a window is the other writer of it.
        r = figure(src, out, s, entry, want) if plan else make(src, out, s, entry, want)
    r["said"] = "; ".join(x for x in (said, r["said"]) if x)
    return r


def _why(e: BaseException) -> str:
    return f"{type(e).__name__}: {e}" if str(e) else type(e).__name__


def _unreadable(e: BaseException) -> bool:
    """Whether the export itself would not decode - truncated, half-written,
    not a picture - rather than the Mac refusing a read or a write, which
    carries the system's own error number."""
    return isinstance(e, (SyntaxError, ValueError)) or (isinstance(e, OSError) and e.errno is None)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("shoot", type=Path)
    ap.add_argument("frames", nargs="*", help="which frames, by name (TSC06169); --all for every export")
    ap.add_argument("--all", action="store_true", help="every exported frame of the shoot")
    ap.add_argument("--plan", action="store_true",
                    help="work out every crop, write it down and make nothing: what each copy would "
                         "be, to look at and adjust before any of them is cut")
    ap.add_argument("--ratio", choices=tuple(RATIOS), default=None,
                    help="portrait shape: 3:4 (1080x1440) or 4:5 (1080x1350). Without this, the shape "
                         "this shoot was last planned or made at, else 3:4")
    ap.add_argument("--landscape", choices=("fit", "crop"), default=None,
                    help="fit: leave a landscape whole at 1080 wide. crop: cut the portrait "
                         "shape out of it too, around the subject - for a carousel of one shape. "
                         "A frame you set one way in the studio's editor stays that way. Without "
                         "this, what this shoot was last planned or made with, else fit.")
    ap.add_argument("--redetect", action="store_true",
                    help="look for the subject again even where it was found before")
    ap.add_argument("--out", type=Path, help="where to write; default <shoot>/instagram")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    shoot = a.shoot.expanduser().resolve()
    found = exports.files(shoot)
    names = {exports.stem_of(n) for n in a.frames}
    if a.all:
        todo = found
    else:
        if not names:
            ap.error("say which frames, or --all")
        missing = sorted(names - set(found))
        if missing:
            print(json.dumps({"error": f"no export of {', '.join(missing[:6])}"}) if a.json
                  else f"no export of {', '.join(missing[:6])}")
            return 1
        todo = {s: found[s] for s in names}
    if not todo:
        print(json.dumps({"error": "nothing exported yet"}) if a.json else "nothing exported yet")
        return 1
    out = (a.out or shoot / "instagram").expanduser()
    # The shape is the plan's unless he says otherwise. A crop he looked at and
    # adjusted was planned at some shape, and a plain `--all` afterwards used to
    # make it at 3:4 whatever he had planned it at - the record said 4:5, the
    # studio's editor drew 4:5, and what came out of the folder was 3:4.
    have = book(out)
    ratio = a.ratio or (have.get("ratio") if have.get("ratio") in RATIOS else None) or "3:4"
    landscape = a.landscape or (have.get("landscape") if have.get("landscape") in ("fit", "crop") else None) or "fit"
    want = RATIOS[ratio][0] / RATIOS[ratio][1]

    detector: list = []

    def models() -> tuple:
        """The subject detector, loaded the first time a frame needs it."""
        if not detector:
            from faces import FaceJudge
            from presets import SceneReader
            detector.extend((FaceJudge(), SceneReader()))
        return detector[0], detector[1]

    made = []
    failed: list[tuple[str, BaseException]] = []
    verb = "worked out" if a.plan else "made"
    # The studio's bar reads these. A plan is its own stage, so the bar and
    # its words say "working out the cuts" and not "making the copies" over a
    # pass that writes no photograph.
    stage = "planning" if a.plan else "instagram"
    for i, (s, src) in enumerate(sorted(todo.items())):
        print(f"@@ {stage} {i} {len(todo)}", flush=True)
        # One export that will not read is that photograph's problem, not the
        # pass's. A half-written file - PhotoLab still exporting while the
        # studio's step works the cuts out - ended the whole pass, and every
        # photograph after it in the list was left unworked with it. It is
        # skipped with a line saying so, and no record is written for it, so
        # the next pass tries it again once the file is whole.
        try:
            r = one(s, src, out, ratio, landscape, want, plan=a.plan, redetect=a.redetect, models=models)
        except Exception as e:  # noqa: BLE001
            failed.append((src.name, e))
            print(f"  {src.name:22s} could not be {verb} ({_why(e)})"
                  + ("; left for the next pass" if a.plan else ""), flush=True)
            continue
        made.append(r)
        if not a.json:
            print(f"  {r['from']:22s} {r['shape']:9s} {'cut  ' if r['mode'] == 'crop' else 'whole'}"
                  f" -> {r['size']}  kept {r['kept']:.0%}"
                  + ("  (your crop)" if r["adjusted"] else "")
                  + ("" if r["grid_ok"] else "   the grid thumbnail cuts its subject")
                  + (f"   {r['said']}" if r["said"] else ""), flush=True)
    print(f"@@ {stage} {len(todo)} {len(todo)}", flush=True)
    # A pass that worked some out has done its job: the rest are asked for
    # again. One that could work none out, and a make that left any copy
    # unmade, end as failed, with the one fact he can act on as the last
    # line - a pass that did nothing and exited well would be asked for again
    # every five seconds, for ever.
    trouble = ""
    if failed:
        (f, e), more = failed[0], len(failed) - 1
        also = f" (and {more} more)" if more else ""
        trouble = f"{f}{also} could not be {verb}: {_why(e)}."
        if _unreadable(e):
            trouble += " If it is still being exported, wait for it to finish; otherwise export it again."
        if made and a.plan:
            trouble = ""
    if failed and not made:
        print(json.dumps({"error": trouble}) if a.json else trouble)
        return 1
    sizes = {r["size"] for r in made}
    note = ("these are not all one shape: in a carousel Instagram crops every card to the "
            "first one's shape" if len(sizes) > 1 else "")
    if a.json:
        print(json.dumps({"out": str(out), "ratio": ratio, "landscape": landscape,
                          "planned" if a.plan else "made": made, "note": note}))
    else:
        cut = sum(1 for r in made if not r["grid_ok"])
        lost = f"; {cut} would lose the subject in the grid" if cut else ""
        if a.plan:
            print(f"\n  {len(made)} worked out at {ratio}, landscapes {landscape}{lost}. Nothing has "
                  f"been made: look at these, adjust any of them, then make the copies.")
        else:
            print(f"\n  {len(made)} in {out}{lost}")
        if note:
            print(f"  {note}")
        if failed and a.plan:
            print(f"  {len(failed)} could not be worked out and {'is' if len(failed) == 1 else 'are'} left for the next pass.")
    if trouble:
        print(trouble if not a.json else json.dumps({"error": trouble}))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
