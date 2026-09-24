#!/usr/bin/env python3
"""
cull.py - find the frames worth editing from a card full of RAW files.

Three stages.

Stage 1, focus (fast, always on):
  1. Decode every RAW at full resolution (--decode half for half), one per
     worker, and pull the camera's embedded JPEG preview. Focus, faces and
     blur are read off the decode; exposure and the thumbnails off the preview.
  2. Find the subject: faces (YuNet), then people and animals (YOLOX).
  3. Measure focus ON THE SUBJECT. A sharp wire fence with mush behind it must
     not win, and a whole-frame score lets it win every time.
  4. Group frames into bursts by capture time.
  5. Inside each burst, focus relative to the sharpest frame measured the
     same way. It orders the review; it bins nothing unless --burst-floor
     asks it to. A blown or black frame with no subject is binned here.

Stage 1.5, faces (on when the models are present, see faces.py):
  Judge every face on the full-resolution decode: sharpness on the band
  across the eyes, blink and mouth from landmarks, expression from CLIP,
  exposure, and who it is. The faults that bin a frame are the four in
  faces.HARD_FACE_FLAGS (blink with no smile, soft past reading, a face in
  the dark, a blown face), plus "soft for this person": under half that
  person's own sharpest frame in the same burst. Everything else (soft for
  this shoot, a mouth open, motion) is a note that orders the review and
  never bins. A frame is held to its largest readable face and any face
  near its size, not to the worst face in it; a blink behind the subject is
  a note. Two faces touching (a kiss) lift a blink and a mouth open.

Stage 2, quality (on when the models are present, see quality.py):
  6. Aesthetic score from CLIP + the LAION aesthetic head.
  7. Eyes open and smile from MediaPipe face blendshapes, on the face crop
     (only when stage 1.5 did not run).
  8. Framing: subject size and rule-of-thirds placement.
  9. Stacks: frames taken back to back that changed less than this card's
     own median, CLIP and perceptual hash both, are put in one stack. A
     stack is one unbroken run of the shutter inside one burst. It arranges
     frames for comparing; it never hides one.
 10. Tiers per burst by a weighted score (clear win, maybe, probably not),
     with the best of each stack on top. --top N keeps only the N best.

cull.csv carries every frame with its tier (5, 3, 2) or 0 for a fault it
can name, and cull/similar.npz the CLIP vector and perceptual hash of each
frame, so a stack can be formed again without measuring anything twice.

It never modifies or deletes originals, with one opt-in exception: --xmp
writes star ratings into the RAW files themselves (exiftool, in place).

Usage:
    ./pl cull "/path/to/shoot"
    ./pl cull "/path/to/shoot" --out ~/photos/shoots/2026-10-04-lake/cull --top 150
    ./pl cull "/path/to/shoot" --eval picks.json      # how well did it agree with you
    ./pl cull "/path/to/shoot" --no-quality           # stage 1 only, seconds
    ./pl cull "/path/to/shoot" --xmp                  # also write star ratings
    ./pl cull "/path/to/shoot" --presets --dop        # one DxO preset per scene, applied to every frame via .dop sidecars

picks.json is a JSON list of filenames you chose from that shoot.
Requires exiftool and the venv from ./pl setup.
"""

from __future__ import annotations

import os
import warnings

# The detectors are chatty on import: TensorFlow Lite, absl, protobuf, the
# HF hub. None of it is actionable the night before a shoot. Set before any import.
os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "3")
os.environ.setdefault("GLOG_minloglevel", "3")
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
os.environ.setdefault("HF_HUB_VERBOSITY", "error")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
warnings.filterwarnings("ignore")

import argparse
import csv
import io
import json
import math
import re
import shutil
import subprocess
import sys
import tempfile
import contextlib
from dataclasses import dataclass, field
from pathlib import Path

import cv2
import numpy as np

try:
    cv2.utils.logging.setLogLevel(cv2.utils.logging.LOG_LEVEL_ERROR)
except AttributeError:
    pass

RAW_EXTS = {".arw", ".cr2", ".cr3", ".nef", ".raf", ".dng", ".orf", ".rw2"}
# The faults that veto live in faces.py (HARD_FACE_FLAGS), next to the
# measurements they are read from and the verdict rule the fixture check uses.
# A soft face does not veto when the frame has a focus and the face is not
# it: the subject box (stage 1) at least this share as sharp as the burst's
# sharpest. The hand or the ball in focus with the face soft behind it is a picture
# the photographer keeps on purpose; on the action shoot the one such keeper
# a face-only rule would have thrown out reads subject 1.0, face 0.88.
FOCUS_ELSEWHERE = 0.5
JPEG_EXTS = {".jpg", ".jpeg", ".png", ".tif", ".tiff"}
# The clipped share of the camera JPEG that bins a frame in stage 1. It was a
# bare 0.15 inside main() and is named here because the doubt column below has
# to say how far a frame sits from it.
CLIP_HI_FLOOR = 0.15
# The other three lines stage 1 judges against, as module constants and not
# only as argparse defaults, because evaluate.py applies the same chain and
# was restating all three as literals of its own.
DARK_FLOOR = 10.0          # --dark-floor: mean brightness under this, with no subject, is nothing to recover
BURST_FLOOR = 0.0          # --burst-floor: off unless asked for (see the help text)
BURST_GAP = 2.0            # --burst-gap: seconds between frames that starts a new burst
# The doubt column has to name the line a frame was judged against and say how
# far past it the frame sat. Those lines are faces.py's (BLINK_SHUT,
# LAUGH_SMILE, FACE_DARK_L, BLOWN_FACE, ANIMAL_GATE, UNREADABLE, CO_SUBJECT)
# and are read from there, never copied: this file used to restate five of
# them, and a threshold with two homes drifts until cull.csv is describing a
# line that nothing judges against any more.
# Pairs needed before a spread is claimed on a card. The same sample-size
# guard quality.frame_to_frame_change uses for the same kind of measurement.
MIN_RETEST_PAIRS = 24

from common import MODELS, deal_tiers, stack_tiers, EXIFTOOL, NotEnoughRoom, require_space, write_atomic, write_json_atomic  # noqa: E402
FACE_MODEL = MODELS / "yunet.onnx"
SUBJECT_MODEL = MODELS / "object_detection_yolox_2022nov.onnx"

CROP_PX = 256           # analysis crops are resized to this before measuring focus
DETECT_W = 960          # width the detectors run at
FACE_CONF = 0.55
FACE_PAD = 0.45
MIN_FACE_PX = 44        # below this (at DETECT_W) a face crop is too small to judge focus on
SUBJ_SIZE = 640
SUBJ_CONF = 0.35
SUBJECT_CLASSES = {0: "person", 15: "cat", 16: "dog"}


@dataclass
class Frame:
    path: Path
    shot_at: str = ""
    seq: float = 0.0
    # stage 1
    sharp: float = 0.0
    faces: int = 0
    method: str = "none"
    box: tuple | None = None           # subject box in detector coords (x, y, w, h)
    face_box: tuple | None = None      # largest YuNet face, detector coords
    det_size: tuple = (0, 0)           # (w, h) of the detector image
    animal_boxes: list = field(default_factory=list)   # YOLOX dog and cat boxes, detector coords, for the face judge
    mean_luma: float = 0.0
    clip_hi: float = 0.0
    burst: int = -1
    sharp_rel: float = 1.0             # focus / sharpest in the same burst and method
    sharp_peers: int = 1               # how many frames that ratio is relative to (1 = only itself)
    stack: int = -1                    # the run of look-alike frames this one is in (quality.similar_stacks); -1 on its own
    stack_top: bool = False            # the cull's guess at the best of that stack, by quality alone
    lead_read: float = 0.0             # the judged face had landmarks (the ranker reads it)
    lead_frac: float = 0.0             # its width as a share of the frame
    rejected: bool = False
    camera_rating: int = 0             # stars set on the camera in playback; any star is a keep
    # stage 2
    aesthetic: float = 0.0
    eyes_open: float = 0.5
    smile: float = 0.0
    subj_area: float = 0.0
    thirds: float = 0.0
    action: float = 0.0
    moment: str = ""
    shadow: float = 0.0            # CLIP: the photographer's shadow is in the frame
    flaw: float = 0.0              # the learned flaw model's strongest probability, when a model exists
    tilt: float = 0.0              # degrees off level of the strongest near-horizontal line in the top of the frame
    # stage 1.5: faces at decoded resolution
    face_n: int = 0
    face_score: float = 1.0        # worst main face, 0..1
    face_flags: str = ""
    gaze: float = 0.5              # worst main face's gaze to the lens, 0..1
    borderline: str = ""           # a close call the judge made on this frame, if any
    people: str = ""
    faces_lm: int = 0
    group: int = -1
    scene: int = -1
    quality: float = 0.0
    # verdict
    rating: int = 0
    reason: str = ""
    confidence: float = -1.0       # how sure that verdict is, in this card's own units; -1 = the card cannot say
    close_call: str = ""           # the measurement nearest its line, and how far off it was


# ------------------------------------------------------------------ exif


def read_metadata(files: list[Path]) -> dict[str, dict]:
    cmd = [EXIFTOOL, "-j", "-n", "-DateTimeOriginal", "-SubSecTimeOriginal",
           "-FileModifyDate", "-Orientation", "-Rating", *[str(f) for f in files]]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    try:
        return {Path(r["SourceFile"]).name: r for r in json.loads(out)}
    except json.JSONDecodeError:
        return {}


def extract_previews(files: list[Path], outdir: Path, meta: dict[str, dict] | None = None) -> None:
    outdir.mkdir(parents=True, exist_ok=True)
    # Which tag holds the camera's own JPEG depends on the maker. Sony and Canon
    # CR2 use PreviewImage, Nikon NEF and Canon CR3 use JpgFromRaw, and a few put
    # the only usable image in ThumbnailImage. Try them in that order and only for
    # the files still missing a preview, so one exiftool pass per tag at worst.
    for tag in ("-PreviewImage", "-JpgFromRaw", "-ThumbnailImage"):
        todo = [f for f in files if not (outdir / f"{f.stem}.jpg").exists()
                or (outdir / f"{f.stem}.jpg").stat().st_size == 0]
        if not todo:
            break
        subprocess.run([EXIFTOOL, "-b", tag, "-w!", f"{outdir}/%f.jpg",
                        *[str(f) for f in todo]], capture_output=True, text=True)
    missing = [f.name for f in files if not (outdir / f"{f.stem}.jpg").exists()
               or (outdir / f"{f.stem}.jpg").stat().st_size == 0]
    if missing:
        print(f"  no embedded preview in {len(missing)} file(s); exposure is read off the decode for those")
    # The embedded preview is stored as the sensor saw it. A portrait frame comes
    # out sideways, faces are not found, and CLIP is asked about a rotated scene.
    # Apply the orientation tag once here so everything downstream is upright.
    turns = {3: cv2.ROTATE_180, 6: cv2.ROTATE_90_CLOCKWISE, 8: cv2.ROTATE_90_COUNTERCLOCKWISE}
    # cv2.imwrite reports failure by returning False and in no other way. A
    # rotation that did not land leaves the preview the way the sensor stored
    # it, on its side, and YuNet finds no face in a sideways frame: that frame
    # is then judged as though nobody were in it. Say which ones.
    sideways = []
    for f in files:
        o = int((meta or {}).get(f.name, {}).get("Orientation", 1) or 1)
        if o in turns:
            p = outdir / f"{f.stem}.jpg"
            img = cv2.imread(str(p))
            if img is not None and not cv2.imwrite(str(p), cv2.rotate(img, turns[o]), [cv2.IMWRITE_JPEG_QUALITY, 92]):
                sideways.append(f.name)
    if sideways:
        print(f"  WARNING: {len(sideways)} preview(s) could not be written upright "
              f"({', '.join(sorted(sideways)[:4])}{', ...' if len(sideways) > 4 else ''}); a full volume does this. "
              f"Those frames are measured on their side and their faces will be missed.")


def seq_key(meta: dict) -> float:
    # Capture time only. A processed JPEG (a cached decode) has no
    # DateTimeOriginal, and its FileModifyDate is when it was written, minutes
    # apart from its neighbours: a real-looking timestamp that would group the
    # whole shoot into bursts by decode order. Without a capture time the key
    # is 0, the sort is stable so filename order (shooting order) holds, and
    # the burst loop gives such a frame a burst of its own.
    dt = meta.get("DateTimeOriginal") or ""
    if not dt:
        return 0.0
    try:
        date, _, clock = str(dt).partition(" ")
        y, mo, d = (int(x) for x in date.split(":")[:3])
        clock = clock.split("+")[0].split("-")[0].strip()
        h, mi, s = (int(float(x)) for x in clock.split(":")[:3])
        base = ((((y * 12 + mo) * 31 + d) * 24 + h) * 60 + mi) * 60 + s
    except (ValueError, IndexError):
        return 0.0
    sub = meta.get("SubSecTimeOriginal")
    try:
        base += float(f"0.{sub}") if sub is not None else 0.0
    except (TypeError, ValueError):
        pass
    return float(base)


# ------------------------------------------------------------- detectors


class SubjectDetector:
    """YOLOX person/animal boxes for when no face is visible."""

    def __init__(self, model: Path):
        self.net = cv2.dnn.readNetFromONNX(str(model))
        self._grid = None
        self._stride = None

    def _grids(self):
        if self._grid is None:
            gs, ss = [], []
            for s in (8, 16, 32):
                hs, ws = SUBJ_SIZE // s, SUBJ_SIZE // s
                xv, yv = np.meshgrid(np.arange(ws), np.arange(hs))
                gs.append(np.stack((xv, yv), 2).reshape(-1, 2))
                ss.append(np.full((hs * ws, 1), s))
            self._grid = np.concatenate(gs, 0)
            self._stride = np.concatenate(ss, 0)
        return self._grid, self._stride

    def detect_classes(self, img: np.ndarray) -> list[tuple[tuple, int]]:
        """(box, class id) pairs; 0 person, 15 cat, 16 dog."""
        h, w = img.shape[:2]
        r = min(SUBJ_SIZE / h, SUBJ_SIZE / w)
        rs = cv2.resize(img, (int(w * r), int(h * r)), interpolation=cv2.INTER_LINEAR)
        canvas = np.full((SUBJ_SIZE, SUBJ_SIZE, 3), 114, np.uint8)
        canvas[:rs.shape[0], :rs.shape[1]] = rs
        self.net.setInput(cv2.dnn.blobFromImage(canvas, 1.0, (SUBJ_SIZE, SUBJ_SIZE), swapRB=False))
        out = self.net.forward()[0].copy()
        grid, stride = self._grids()
        out[:, :2] = (out[:, :2] + grid) * stride
        out[:, 2:4] = np.exp(out[:, 2:4]) * stride
        scores = out[:, 4:5] * out[:, 5:]
        cls = scores.argmax(1)
        conf = scores.max(1)
        keep = (conf > SUBJ_CONF) & np.isin(cls, list(SUBJECT_CLASSES))
        if not keep.any():
            return []
        boxes, confs, clss = [], [], []
        for row, c, k in zip(out[keep], conf[keep], cls[keep]):
            cx, cy, bw, bh = row[:4] / r
            boxes.append([int(cx - bw / 2), int(cy - bh / 2), int(bw), int(bh)])
            confs.append(float(c))
            clss.append(int(k))
        idx = cv2.dnn.NMSBoxes(boxes, confs, SUBJ_CONF, 0.45)
        if idx is None or len(idx) == 0:
            return []
        return [(tuple(boxes[int(i)]), clss[int(i)]) for i in np.array(idx).flatten()]

    def detect(self, img: np.ndarray) -> list[tuple[int, int, int, int]]:
        return [b for b, _ in self.detect_classes(img)]


def tilt_degrees(gray: np.ndarray) -> float:
    """The strongest long, near-horizontal line in the top 45% of the frame
    (a horizon, a roofline, a fence rail), in degrees off level. 0 when
    there is none worth trusting."""
    h, w = gray.shape[:2]
    top = gray[: int(h * 0.45)]
    edges = cv2.Canny(top, 60, 160)
    lines = cv2.HoughLinesP(edges, 1, np.pi / 360, threshold=int(w * 0.12), minLineLength=int(w * 0.35), maxLineGap=12)
    if lines is None:
        return 0.0
    best, best_len = 0.0, 0.0
    for x1, y1, x2, y2 in np.asarray(lines).reshape(-1, 4):
        ang = np.degrees(np.arctan2(y2 - y1, x2 - x1))
        if abs(ang) > 12:
            continue
        ln = float(np.hypot(x2 - x1, y2 - y1))
        if ln > best_len:
            best, best_len = float(ang), ln
    return best


def progress(stage: str, done: int, total: int) -> None:
    """One machine-readable line per step, for anything watching the log (the studio draws a bar from them)."""
    print(f"@@ {stage} {done} {total}", flush=True)


def focus_score(gray: np.ndarray) -> float:
    crop = cv2.resize(gray, (CROP_PX, CROP_PX), interpolation=cv2.INTER_AREA)
    return float(cv2.Laplacian(crop, cv2.CV_64F).var())


def detector_image(img: np.ndarray) -> np.ndarray:
    h, w = img.shape[:2]
    return cv2.resize(img, (DETECT_W, int(h * DETECT_W / float(w))), interpolation=cv2.INTER_AREA)


def analyse(small: np.ndarray, face_det, subj_det, subs: list | None = None):
    """Return (focus, count, method, framing box, largest face box) on `small`.

    Focus comes from the face when it is big enough to judge, otherwise from
    the person or animal box, otherwise the centre. The framing box is always
    the largest person or animal when one is found, so composition is judged on
    the whole subject and not on a face that is 3% of the frame."""
    sh, sw = small.shape[:2]
    gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)

    def score_boxes(boxes, pad, min_px):
        best, best_box = 0.0, None
        for (x, y, bw, bh) in boxes:
            px, py = bw * pad, bh * pad
            x0 = max(0, int(x - px))
            y0 = max(0, int(y - py))
            x1 = min(sw, int(x + bw + px))
            y1 = min(sh, int(y + bh + py))
            if x1 - x0 < min_px or y1 - y0 < min_px:
                continue
            s = focus_score(gray[y0:y1, x0:x1])
            if s > best:
                best, best_box = s, (x, y, bw, bh)
        return best, best_box

    faces: list[tuple] = []
    face_box = None
    if face_det is not None:
        face_det.setInputSize((sw, sh))
        _, det = face_det.detect(small)
        faces = [(float(d[0]), float(d[1]), float(d[2]), float(d[3]))
                 for d in (det if det is not None else []) if float(d[14]) >= FACE_CONF]
        if faces:
            face_box = max(faces, key=lambda b: b[2] * b[3])

    if subs is None:
        subs = subj_det.detect(small) if subj_det is not None else []
    subs = sorted(subs, key=lambda b: b[2] * b[3], reverse=True)
    frame_box = subs[0] if subs else face_box

    big_faces = [b for b in faces if max(b[2], b[3]) >= MIN_FACE_PX]
    if big_faces:
        best, _ = score_boxes(big_faces, FACE_PAD, 24)
        if best > 0:
            return best, len(faces), "face", frame_box, face_box

    if subs:
        best, _ = score_boxes(subs[:3], 0.05, 40)
        if best > 0:
            return best, len(subs), "subject", frame_box, face_box

    if faces:  # small faces and no body found: judge on a generous head crop
        best, _ = score_boxes(faces, 1.0, 24)
        if best > 0:
            return best, len(faces), "face", frame_box, face_box

    y0, y1 = int(sh * 0.20), int(sh * 0.80)
    x0, x1 = int(sw * 0.20), int(sw * 0.80)
    return focus_score(gray[y0:y1, x0:x1]), 0, "center", frame_box, face_box


def exposure(img: np.ndarray) -> tuple[float, float]:
    """Mean brightness and the share at the white clip point. The share at the
    black point used to be returned too, computed on every frame and read by
    nothing; it is also useless as a dark gate, since a lounge keeper has more
    than half its frame at the black point on purpose."""
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    return float(gray.mean()), float((gray > 250).sum()) / gray.size


def face_crop(small: np.ndarray, face_box, grow: float = 1.3, size: int = 256) -> np.ndarray | None:
    """Square crop around the largest face, for the landmarker."""
    if face_box is None:
        return None
    sh, sw = small.shape[:2]
    x, y, fw, fh = face_box
    cx, cy, r = x + fw / 2, y + fh / 2, max(fw, fh) * grow
    x0, y0 = int(max(0, cx - r)), int(max(0, cy - r))
    x1, y1 = int(min(sw, cx + r)), int(min(sh, cy + r))
    if x1 - x0 < 32 or y1 - y0 < 32:
        return None
    return cv2.resize(small[y0:y1, x0:x1], (size, size), interpolation=cv2.INTER_CUBIC)


def frame_label(p: Path) -> str:
    """How a frame is named to the photographer: the camera's counter as it
    appears in the file name (TSC04313.ARW is "04313"), or the whole stem
    for a name that carries none."""
    m = re.search(r"(\d+)$", p.stem)
    return m.group(1) if m else p.stem


def stack_verdicts(alive: list[Frame], keep_per_group: int) -> list[Frame]:
    """Put the cull's guess on top of each stack, and return the frames that
    go on to be tiered.

    The top is the frame with the best quality score and nothing else. The
    rule this replaces put a sharper frame first whatever the score said,
    and in 9 of the 19 keepers it hid on the 09-16 action shoot the keeper
    was the softer frame; the size of a sharpness gap separates his keepers
    from the frames beside them at an AUC of 0.42 to 0.47, which is chance.
    The top is still only a guess, and cull.csv says top and not best: on
    that shoot, the only finished one with stacks, it holds a keeper in 35
    of the 63 stacks that contain one, where picking a frame of each at
    random would hold 30.5. That thin margin is why the page has to show a
    stack as a stack and not as one frame with the rest tidied away.

    keep_per_group frames of a stack (the top first, then by quality) are
    tiered like any other frame; 2 with --style action, where the frames of
    one exchange differ more than they look. The rest of the stack stays on
    the page as set aside (2) with a reason naming the top, never hidden: a
    frame is hidden only for a fault the cull can name. Tiering one frame per
    stack, not all of them, is what keeps the shortlist the size it was: on
    the six measured shoots it moves from 23 to 29, 20 to 24, 26 to 26, 313
    to 317, 198 to 251 and 722 to 764 frames, where letting every member be
    tiered took 09-21 to 311.

    A run the stacking found but which has fewer than two frames left once
    the faults are out is not a stack, and its frames are cleared of it."""
    # The split itself is common.stack_tiers, which the keeper check replays.
    runs: dict[int, list[int]] = {}
    for k, f in enumerate(alive):
        if f.stack >= 0:
            runs.setdefault(f.stack, []).append(k)
    tiered = [f for f in alive if f.stack < 0]
    ks, under, tops = stack_tiers(list(runs.values()), keep_per_group, lambda k: alive[k].quality)
    for mem in runs.values():
        if len(mem) < 2:
            for k in mem:
                alive[k].stack = -1
    top_of = {}
    for k in tops:
        alive[k].stack_top = True
        top_of[alive[k].stack] = alive[k]
    tiered += [alive[k] for k in ks]
    for k in under:
        alive[k].rating, alive[k].reason = 2, f"similar to {frame_label(top_of[alive[k].stack].path)}"
    return tiered


def frame_rows(frames: list[Frame]) -> list[dict]:
    """The columns unseen_keepers reads, from frames still in memory, spelt
    the way cull.csv spells them."""
    return [{"file": f.path.name, "rating": f.rating, "reason": f.reason,
             "stack": "" if f.stack < 0 else f.stack, "stack_top": 1 if f.stack_top else 0} for f in frames]


def unseen_keepers(rows, chosen: set[str]) -> tuple[list[tuple[str, str]], list[tuple[str, str]]]:
    """(lost, under) among the frames he chose, by what the page shows first.

    Lost is every one he would not see without going looking for it: a fault
    (0), and in a cull.csv written before stacks a duplicate (1) as well, so
    an old file is scored by what it did and not by what the cull does now.
    Under is one shown beneath the top of its stack, one key away, named
    with that top. Rows are cull.csv rows or frame_rows(); matched by stem,
    so a select recorded against a RAW finds its cached decode."""
    rows = list(rows)
    def stack_of(r) -> str:
        s = r.get("stack")
        s = "" if s is None else str(s).strip()
        return "" if s == "-1" else s
    tops = {stack_of(r): Path(r["file"]) for r in rows if stack_of(r) and str(r.get("stack_top", "0")).strip() in ("1", "True")}
    lost, under = [], []
    for r in rows:
        if Path(r["file"]).stem not in chosen:
            continue
        try:
            rating = int(float(r.get("rating") or 0))
        except ValueError:
            rating = 0
        if rating <= 1:
            lost.append((r["file"], r.get("reason") or ("duplicate" if rating == 1 else "not measured")))
        elif stack_of(r) and str(r.get("stack_top", "0")).strip() not in ("1", "True"):
            top = tops.get(stack_of(r))
            under.append((r["file"], frame_label(top) if top is not None else "?"))
    return lost, under


def never_above_top(alive: list[Frame]) -> None:
    """A frame under a stack's top may be tiered as high as the top and no
    higher. The tiers order by the venue's ranker where one exists and the
    top is chosen by quality, so the two can disagree; the top is the one
    the page shows first, and the shortlist must not contradict it."""
    tops = {f.stack: f for f in alive if f.stack >= 0 and f.stack_top}
    for f in alive:
        t = tops.get(f.stack)
        if t is not None and f is not t and f.rating > t.rating:
            f.rating, f.reason = t.rating, t.reason


def rel_within(frames: list[Frame]) -> None:
    """sharp_rel = focus / sharpest focus among frames of the same burst that were
    measured the same way. 1.0 means the crisp one of its set."""
    by_bm: dict[tuple[int, str], list[Frame]] = {}
    for f in frames:
        by_bm.setdefault((f.burst, f.method), []).append(f)
    for grp in by_bm.values():
        best = max(f.sharp for f in grp)
        for f in grp:
            f.sharp_rel = f.sharp / best if best > 0 else 1.0
            f.sharp_peers = len(grp)


# ------------------------------------------------------- who is in the frame


def people_clusters(embs: list) -> list[int]:
    """faces.cluster_people, handed the faces in an order that is a property of
    the set rather than of the card's directory listing.

    The clustering is greedy: the first embedding seeds a cluster, every later
    one joins the nearest seed above OpenCV's same-person threshold or starts
    its own, and the seeds that happen to exist already decide the rest. Its
    answer is therefore a function of the order it was handed, which is the
    order the files came off the card. That would be nobody's business if it
    did not gate a veto, but "soft for this person" below is computed against
    it. Measured on the 2,950 faces of the 09-16 action shoot: nine orders of
    the same embeddings gave nine different partitions and between 50 and 61
    people, and that fault fired on between 5 and 10 frames with nothing else
    changed - TSC04605, TSC04606, TSC04689, TSC05048, TSC05066, TSC05474,
    TSC05475 and TSC05485 were in or out by luck of the ordering. None of them
    was a frame the photographer kept, and that was luck too. A veto whose
    outcome depends on filesystem order is not a veto.

    So the order comes out of the embeddings: the face most like the rest of
    the card goes first and the odd ones out last. "Most like the rest" is the
    sum of its cosine similarity to every face on the card, which is the same
    number whatever order they arrive in; it is rounded to six places before
    sorting, so that a last-bit difference in a floating-point sum almost
    never reorders two faces, and ties fall back to the embedding's own
    bytes. Almost never, not never: the sum itself is taken in whatever order
    the faces arrived, and two faces whose likeness straddles a rounding
    boundary could still change places. A tie there is two identical vectors,
    and identical vectors join the same cluster whichever is reached first.

    Connected components at the same threshold would be order-independent with
    none of this, and are worse rather than merely different: single linkage
    chains through a shoot, leaving 1 cluster on the portraits and 2 on the
    action shoot - the whole card one person - whereupon the fault fired on 40
    frames and took two frames the photographer kept, TSC05125 and TSC05241.
    Seeding in this order leaves 12, 27, 6 and 60 people on the four shoots,
    one partition under every order tried, the fault down from 5-10 frames to
    4, and recall unchanged on every shoot.
    """
    import faces as fmod
    out = [-1] * len(embs)
    idx = [i for i, e in enumerate(embs) if e is not None]
    if not idx:
        return out
    M = np.stack([np.asarray(embs[i], dtype=np.float64).ravel() for i in idx])
    likeness = M @ M.sum(0)     # sum_j cos(i, j), without building the n x n matrix
    order = sorted(range(len(idx)), key=lambda k: (-round(float(likeness[k]), 6), M[k].tobytes()))
    for pos, pid in enumerate(fmod.cluster_people([embs[idx[k]] for k in order])):
        out[idx[order[pos]]] = pid
    return out


# --------------------------------------------------- how sure a verdict is


def card_spreads(frames: list[Frame], allfaces: list) -> tuple[dict[str, float], dict[str, int], float]:
    """How far each measurement moves between two frames of the same subject
    taken back to back: this card's own test-retest spread.

    A veto is a measurement against a line, and until now the cull could not
    say whether a frame was a hand's breadth past that line or a hair. Two
    frames of one person inside one time burst are the same face under the
    same light a fraction of a second apart, so the difference between their
    measurements is mostly the measurement moving rather than the person.
    Mostly, not entirely - an eye really does shut between two frames - so
    this OVERSTATES the spread, and every confidence built on it is the
    cautious end of the range rather than a flattering one.

    Robust because a burst holds real changes as well as noise: 1.4826 times
    the median absolute difference, divided by root two because a difference
    carries two measurements' worth of spread. Frame-level numbers are paired
    by back-to-back frames of a burst, face-level ones by the same person in
    the same burst, which is what people_clusters is for.

    Returns (spread per measurement, pairs it was measured over, how far blink
    and smile move together over those same pairs, which is what scoring the
    blink conjunction needs and no spread on its own can say). A card that
    cannot answer says nothing: the lounge's RAWs were cleared by hand, no
    capture time survives, so it is 296 bursts of one frame, has no pair at
    all, and gets no confidence column rather than a made-up one.
    """
    face_pairs: dict[tuple, list] = {}
    for fr, fc in allfaces:
        if fc.main and fc.person >= 0:
            face_pairs.setdefault((fr.burst, fc.person), []).append((fr.seq, fr.path.name, fc))
    diffs: dict[str, list] = {k: [] for k in ("blink", "smile", "sharp", "lum", "blown")}
    # The same pairs, signed, for the two measurements the blink rule asks
    # about together. A spread says how far one measurement moves; it cannot
    # say whether the other moves with it, and the blink rule is a conjunction.
    moved: dict[str, list] = {"blink": [], "smile": []}
    for lst in face_pairs.values():
        lst.sort(key=lambda t: (t[0], t[1]))
        for (_, na, a), (_, nb, b) in zip(lst, lst[1:]):
            if na == nb:                      # two faces of one frame are not a re-measurement
                continue
            for k in diffs:
                diffs[k].append(abs(getattr(a, k) - getattr(b, k)))
            for k in moved:
                moved[k].append(getattr(b, k) - getattr(a, k))
    by_burst: dict[int, list[Frame]] = {}
    for fr in frames:
        by_burst.setdefault(fr.burst, []).append(fr)
    for k in ("clip_hi", "mean_luma"):
        diffs[k] = []
    for lst in by_burst.values():
        lst.sort(key=lambda f: (f.seq, f.path.name))
        for a, b in zip(lst, lst[1:]):
            for k in ("clip_hi", "mean_luma"):
                diffs[k].append(abs(getattr(a, k) - getattr(b, k)))
    spread, pairs = {}, {}
    for k, v in diffs.items():
        pairs[k] = len(v)
        med = float(np.median(v)) if v else 0.0
        # A median difference of exactly zero says the pairs never moved, which
        # is a measurement that cannot be re-measured, not a perfect one.
        spread[k] = 1.4826 * med / math.sqrt(2.0) if len(v) >= MIN_RETEST_PAIRS and med > 0 else 0.0
    db, dm = np.array(moved["blink"]), np.array(moved["smile"])
    together = 0.0
    if len(db) >= MIN_RETEST_PAIRS and db.std() > 0 and dm.std() > 0:
        r = float(np.corrcoef(db, dm)[0, 1])
        together = r if math.isfinite(r) else 0.0
    return spread, pairs, together


def _sure(margin: float, spread: float) -> float:
    """The share of re-measurements that would land on the same side of the
    line, for a call this far past it on a card that moves this much. -1 when
    the card could not say how much it moves."""
    if spread <= 0:
        return -1.0
    return 0.5 * (1.0 + math.erf(margin / (spread * math.sqrt(2.0))))


# Twenty-point Gauss-Legendre, built once: _both is called for every main face
# of every frame and the nodes do not depend on the call.
_GL_X, _GL_W = np.polynomial.legendre.leggauss(20)


def _both(margin_a: float, spread_a: float, margin_b: float, spread_b: float, rho: float) -> float:
    """The share of re-measurements where BOTH calls land on the same side of
    their lines: two margins this far past them, on a card that moves them
    this much and leans them together this way.

    A conjunction is not min(). min() is the chance the weaker of the two
    holds, which is an upper bound on the chance both do, and the blink rule
    is a conjunction - eyes at least BLINK_SHUT shut AND a smile under
    LAUGH_SMILE. Reporting that bound flattered the one rule that has cost
    this photographer keepers (TSC05422 and TSC05664 on the action shoot are
    blinks he kept anyway).

    The joint chance is the bivariate normal orthant. Sheppard's integral
    gives it as the product plus a correction that runs over the correlation,
    so at rho = 0 this IS Phi(h) * Phi(k) and it falls away from the product as
    the two errors lean against each other. Measured on the same back-to-back
    pairs the spreads come from - 1,518 of them over the three cards of four
    that have any - blink and smile move together at +0.186 (95% CI +0.137 to
    +0.234, and per card +0.376, +0.222, +0.153), so the two margins lean
    against each other and even the product is a shade optimistic.

    It only bites on the close ones, which is where the column is read. On the
    portraits card (spreads 0.055 and 0.051) a face at blink 0.53 with a smile
    of 0.43 came out of min() at 0.653 and is 0.415 here; a blink of 0.72 with
    no smile is 1.000 either way.

    -1 where the card could not say how much either measurement moves."""
    if spread_a <= 0 or spread_b <= 0:
        return -1.0
    h, k = margin_a / spread_a, margin_b / spread_b
    p = _sure(margin_a, spread_a) * _sure(margin_b, spread_b)
    if abs(rho) < 1e-9:
        return p
    t = rho * (_GL_X + 1.0) / 2.0         # the nodes onto [0, rho]
    one = 1.0 - t * t
    corr = float(np.sum(_GL_W * np.exp(-(h * h - 2.0 * t * h * k + k * k) / (2.0 * one)) / np.sqrt(one)))
    return float(min(1.0, max(0.0, p + rho * corr / (4.0 * math.pi))))


def fault_chances(fr: Frame, mains: list, spread: dict, dark_floor: float,
                  person: tuple | None = None, together: float = 0.0) -> dict[str, tuple[float, str]]:
    """Per fault that could bin this frame: how sure that call is, and the
    sentence that says why it was close.

    Only faults the chain would actually act on are in here. One forgiven
    because the focus is elsewhere, or because two faces are touching, or
    because it sits on a face too small to veto, or on an animal's head, is
    not a fault, and a frame must not be reported as a doubtful keep over a
    fault nothing was ever going to apply to it.
    """
    out: dict[str, tuple[float, str]] = {}

    def put(rule: str, what: str, value: float, line: float, margin: float, key: str) -> None:
        s = _sure(margin, spread.get(key, 0.0))
        if s < 0:
            return
        note = f"{what} {value:.2f} against {line:.2f}, and this card moves it {spread[key]:.3f} between frames"
        if s > out.get(rule, (-1.0, ""))[0]:
            out[rule] = (s, note)

    put("blown highlights", "clipped share", fr.clip_hi, CLIP_HI_FLOOR, fr.clip_hi - CLIP_HI_FLOOR, "clip_hi")
    if fr.method == "center":
        put("too dark", "frame brightness", fr.mean_luma, dark_floor, dark_floor - fr.mean_luma, "mean_luma")
    if person is not None and spread.get("sharp", 0.0) > 0:
        # Both sides of this one are measured on this card, so the difference
        # carries two spreads, the half-weight side contributing a quarter.
        sharp, line = person
        wob = spread["sharp"] * math.sqrt(1.25)
        out["soft for this person"] = (_sure(line - sharp, wob),
                                       f"their focus {sharp:.2f} against {line:.2f}, "
                                       f"a gap this card moves {wob:.3f} between frames")
    if not mains:
        return out
    import faces as fmod
    # faces.verdict's own co-subject rule, read from its constant: a readable
    # face at least half the largest one's area is a second subject and its
    # fault vetoes; anything smaller is behind the subject and only noted, so
    # its doubt is not this frame's doubt either.
    readable = [fc for fc in mains if fc.read] or mains
    area = max(fc.box[2] * fc.box[3] for fc in readable)
    elsewhere = fr.method != "face" and fr.sharp_peers >= 2 and fr.sharp_rel >= FOCUS_ELSEWHERE
    for fc in readable:
        if fc.box[2] * fc.box[3] < fmod.CO_SUBJECT * area:
            continue
        if not fc.read or fc.clip.get("animal", 0) >= fmod.ANIMAL_GATE or fc.in_animal:
            continue            # the abstention in faces.flag(): these may never veto
        if "close faces" not in fc.flags:
            # The blink rule is a conjunction, and so is its chance: the two
            # margins are (blink - BLINK_SHUT) and (LAUGH_SMILE - smile), so a
            # re-measurement that raises both readings pushes one margin up and
            # the other down, and the correlation the margins carry is minus
            # the one the measurements do.
            p = _both(fc.blink - fmod.BLINK_SHUT, spread.get("blink", 0.0),
                      fmod.LAUGH_SMILE - fc.smile, spread.get("smile", 0.0), -together)
            if p >= 0 and p > out.get("blink", (-1.0, ""))[0]:
                out["blink"] = (p, f"eyes {fc.blink:.2f} against {fmod.BLINK_SHUT:.2f} and smile {fc.smile:.2f} "
                                   f"against {fmod.LAUGH_SMILE:.2f}, on a card that moves them "
                                   f"{spread['blink']:.3f} and {spread['smile']:.3f} and moves them "
                                   f"together {together:+.2f}")
        # A face whose eye band was too small to measure has no sharpness and
        # cannot be binned soft, so it has no doubt about being soft either.
        if not elsewhere and fc.sharp > 0:
            put("soft", "face focus", fc.sharp, fmod.UNREADABLE, fmod.UNREADABLE - fc.sharp, "sharp")
        put("face in the dark", "face brightness", fc.lum, fmod.FACE_DARK_L, fmod.FACE_DARK_L - fc.lum, "lum")
        put("blown face", "skin at the clip point", fc.blown, fmod.BLOWN_FACE, fc.blown - fmod.BLOWN_FACE, "blown")
    return out


def doubt(fr: Frame, chances: dict) -> tuple[float, str]:
    """(confidence, the close call) for the verdict this frame actually got.

    For a frame that was binned it is the chance the rule that binned it would
    bin it again. For a frame that survived it is one minus the chance of the
    fault that came nearest to firing, so the column means the same thing
    either way: how sure the cull is of the call it made on this frame, and
    -1 where this card gave it no way of knowing.

    It goes into cull.csv and no further yet. The page is handed a short list
    of columns (studio.py's ROW_KEEP) and this is not one of them, so the
    number is in the file and reaches the browser only on /api/shoot?full=1;
    a sort built on it needs the column added there first.
    """
    if fr.rejected:
        got = chances.get(fr.reason)
        return (round(got[0], 3), got[1]) if got else (-1.0, "")
    if not chances:
        return -1.0, ""
    rule, (p, note) = max(chances.items(), key=lambda kv: kv[1][0])
    return round(1.0 - p, 3), f"nearest fault {rule}: {note}"


# ------------------------------------------------------------------ main


_FOCUS: dict = {}


def focus_frame(job: tuple) -> tuple[int, dict | None]:
    """(index, preview path, decoded path or "", use the subject detector) ->
    the first pass's measurements of one frame. Runs in a worker process with
    its own two detectors; nothing in it is shared between frames."""
    i, src, dec_path, want_subj = job
    if not _FOCUS:
        cv2.setNumThreads(1)              # one frame per core
        _FOCUS["face"] = _FOCUS["subj"] = None
        try:
            if FACE_MODEL.exists():
                _FOCUS["face"] = cv2.FaceDetectorYN.create(str(FACE_MODEL), "", (320, 320), FACE_CONF, 0.3, 5000)
            if want_subj and SUBJECT_MODEL.exists():
                _FOCUS["subj"] = SubjectDetector(SUBJECT_MODEL)
        except cv2.error:
            pass
    face_det, subj_det = _FOCUS["face"], _FOCUS["subj"]
    img = cv2.imread(src) if src else None
    if img is None:
        return i, None
    dec = cv2.imread(dec_path) if dec_path and dec_path != src else None
    # A decode that was asked for and did not read back leaves this frame
    # measured on the camera's 1616 px preview, about a tenth of the sensor.
    # The caller counts them; this is not something to find out from the CSV.
    small = detector_image(dec if dec is not None else img)
    pairs = subj_det.detect_classes(small) if subj_det is not None else []
    sharp, faces, method, box, face_box = analyse(small, face_det, subj_det, subs=[b for b, _ in pairs])
    mean_luma, clip_hi = exposure(detector_image(img))
    return i, {"det_size": (small.shape[1], small.shape[0]), "animal_boxes": [b for b, c in pairs if c in (15, 16)],
               "sharp": sharp, "faces": faces, "method": method, "box": box, "face_box": face_box,
               "tilt": tilt_degrees(cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)), "mean_luma": mean_luma, "clip_hi": clip_hi,
               "preview_only": bool(dec_path) and dec is None}


def venue_ranker(shoot: Path, alive: list, judge=None, preview=None) -> dict | None:
    """The ranker of the finished venue this shoot measures like, if any.

    Up to 60 surviving frames' camera JPEGs are measured the way the presets
    step measures them (kelvin, the cast on the neutrals, frame and face
    brightness, the chroma of the light) and their medians looked up against
    the venues of the tier order in use (learned.tier_order_table). A venue
    is used only inside its own spread, and only when its ranker beat chance
    held out by burst. Nothing in use is the ordinary answer, and it means
    the tiers follow the score: rankers no longer live in taste.json, and a
    tier order is in use only once it has passed the keeper check."""
    try:
        import statistics
        import taste as tmod
        import learned
        table = learned.tier_order_table()
        if not table:
            return None
        import presets as pmod
        top = shoot.parent if shoot.name == "raw" else shoot
        v = tmod.venue_for(top, table=table)
        if v is None:
            sample = alive[:: max(1, len(alive) // 60)][:60]
            pool = []
            for fr in sample:
                img = cv2.imread(str(preview(fr))) if preview is not None else None
                if img is None:
                    continue
                faces = [f for f in judge.detect(img) if f.main] if judge is not None else []
                m = pmod.measure(img, faces, None)
                m["kelvin"] = pmod.kelvin_from_raw(fr.path) if fr.path.suffix.lower() in RAW_EXTS else None
                pool.append(m)
            mid = {}
            for f in tmod.VENUE_FEATS[:-1] + ["face_a", "face_b"]:
                vals = [float(m[f]) for m in pool if m.get(f) is not None]
                if vals:
                    mid[f] = statistics.median(vals)
            v = tmod.venue_for(top, mid, table=table) if mid else None
        if v is None:
            return None
        r = v[1].get("ranker")
        if r and r.get("auc", 0) >= tmod.RANK_MIN_AUC:
            print(f"  this shoot measures like a finished venue ({tmod.venue_words(v[1], v[0])}): its ranker orders the tiers")
            return r
    except Exception as e:  # noqa: BLE001
        print(f"  (no venue ranker: {e})")
    return None


def record_run(meta_path: Path, style: str, face_floor: float, asked: float | None = None) -> None:
    """Write beside the shoot how the cull whose cull.csv was just put in
    place was run. Called only after that file is written, so a cull that is
    stopped or dies before it has results records nothing. `asked` is the
    focus he set, when this card's own scale moved the floor away from it."""
    try:
        meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
        if not isinstance(meta, dict):
            return      # not a table this can add to, and never written over
        meta["style"] = style
        # The floor the faces were actually judged against, which is the
        # one asked for except on a card whose own scale is outside every
        # card it was set on (see the band in main). Writing the asked-for
        # number here would have the studio and the harness re-run with a
        # floor this run did not use.
        meta["focus"] = round(float(face_floor), 2)
        # The same two again, under a key only this writes. The studio also
        # writes `style` and `focus`, when a cull STARTS, as what the next
        # cull starts from: after a cull he stopped, or one that died, those
        # two name a run whose results were never written, and the report
        # printed them under the older results still on screen.
        meta["cull_ran_with"] = {"style": style, "focus": round(float(face_floor), 2)}
        # And the focus he set, which is what the NEXT shoot starts from
        # (studio._cull_settings): a floor moved for this card's scale is
        # this card's, and a new card moves what he set for its own.
        if asked is not None and round(float(asked), 2) != meta["cull_ran_with"]["focus"]:
            meta["cull_ran_with"]["asked"] = round(float(asked), 2)
        # Which learned versions this cull ran with (None for a learner
        # that had nothing in use), so the shoot's card can say what it
        # was culled with months after the learned folder has moved on.
        try:
            import learned
            meta["learned"] = learned.stamp()
        except Exception as e:  # noqa: BLE001
            meta["learned"] = {"error": str(e)}
        write_json_atomic(meta_path, meta)
    except (OSError, ValueError):
        pass


def main() -> int:
    ap = argparse.ArgumentParser(description="Find the frames worth editing.")
    ap.add_argument("folder", type=Path)
    ap.add_argument("--out", type=Path, default=None, help="where picks/ and cull.csv go (default: <shoot>/cull beside a raw/ folder, else <folder>/cull)")
    ap.add_argument("--burst-gap", type=float, default=BURST_GAP, help="seconds between frames that starts a new burst")
    ap.add_argument("--keep-per-group", type=int, default=0, help="frames of each stack of look-alike frames that are tiered with the rest (default 1, or 2 with --style action); the others stay on the page, set aside under the stack's top")
    ap.add_argument("--top", type=int, default=0, help="keep only the N best picks overall (0 = all best-of-group)")
    ap.add_argument("--no-faces", action="store_true", help="skip the decoded-RAW face stage (blink, motion, expression)")
    ap.add_argument("--decode", choices=["full", "half"], default="full", help="decode RAWs at the sensor's full resolution (default) or half; focus and faces are read off the decode")
    ap.add_argument("--workers", type=int, default=max(4, (os.cpu_count() or 8) * 3 // 4),
                    help="processes for the per-frame stages: RAW decodes, the first pass, the face pass (default: three quarters of the cores)")
    # 1.9 is fixed on purpose and sweeping it is a trap. The 94-frame faces
    # fixture passes 94/94 only for floors in [1.86, 1.98]: 1.85 and 2.00 both
    # drop two frames, 1.45 drops six, 2.40 drops twelve. Every per-shoot
    # replacement measured (leave-one-shoot-out quantiles, Otsu, MAD fences)
    # lost to the constant at the review size the photographer reaches, and the metric
    # carries no signal about the photographer's choices (AUC 0.38-0.69 by shoot). It is also
    # the bar under which the burst reprieve (stage 1.5) cannot fire: a face
    # below it is flagged soft, soft is a hard flag, and the reprieve needs no
    # hard flag. The studio slider is how it is moved, deliberately, per shoot.
    ap.add_argument("--face-floor", type=float, default=1.9,
                    help="the focus a face needs to pass without a note on THIS shoot; under it a face is noted 'soft?' and the frame comes last in the review, never binned. The veto is faces.UNREADABLE (1.2), which no kept frame has been under")
    ap.add_argument("--keep", default="", help="comma-separated filenames that are picks no matter what the scores say (the one the client asked for, the artsy soft one)")
    ap.add_argument("--top-by", choices=["scene", "quality"], default="scene",
                    help="how --top chooses: 'scene' takes the best of every scene first (an event: every setup gets covered); 'quality' is the plain N best (a portfolio night: the parrot does not get a seat)")
    ap.add_argument("--burst-floor", type=float, default=BURST_FLOOR,
                    help="off by default. Within a time burst, reject below this fraction of the sharpest frame's focus number. It is a quota that grows with the burst's length: at the 0.35 it shipped with, measured again on 22 September over the action shoot's 1,157 cached decodes and the 154 frames he kept, it rejects 208 frames instead of 64 and takes 9 of those keepers, 7 of them that no other rule touches. That is the one figure for what it costs; the same-person rule below replaced it")
    # --style used to decide what counted as "the same picture" (two sets of
    # CLIP and hash thresholds) and so which frames were hidden. It no longer
    # decides that: stacks are linked by the card's own frame-to-frame change
    # (quality.similar_stacks), and nothing is hidden for looking alike. What
    # it still decides is how many frames of one stack are tiered, because the
    # frames of one exchange on an action shoot differ more than they look.
    ap.add_argument("--style", choices=["normal", "action"], default="normal",
                    help="normal: subjects that hold still. action: action, sport, anything where the subject moves between frames, so two frames of each stack are tiered instead of one")
    ap.add_argument("--taste", type=Path, default=None, help="retired, with --learn: the ranking weights are quality.DEFAULT_WEIGHTS")
    ap.add_argument("--eval", type=Path, default=None, help="JSON list of filenames you picked; reports agreement, and names every one of them the cull would not show you")
    ap.add_argument("--learn", type=Path, default=None, help="retired; see the studio's home page, 'What the cull has learned'")
    ap.add_argument("--times", type=Path, default=None,
                    help="an earlier cull.csv, for a cull of cached decodes whose RAWs are archived: its shot_at column gives those frames their capture time back, so the shoot keeps its bursts")
    ap.add_argument("--no-subject", action="store_true", help="skip person/animal detection")
    ap.add_argument("--no-quality", action="store_true", help="stage 1 only: focus and bursts")
    ap.add_argument("--no-eyes", action="store_true", help="skip eye and smile detection")
    ap.add_argument("--copy", action="store_true", help="picks/ holds real files (hard links where the filesystem allows, so they cost no disk) instead of symlinks")
    ap.add_argument("--xmp", action="store_true", help="write star ratings into the RAW files themselves, in place (exiftool -overwrite_original)")
    ap.add_argument("--presets", action="store_true", help="build one DxO preset per scene from what was measured (see presets.py)")
    ap.add_argument("--no-install", action="store_true",
                    help="with --presets: leave PhotoLab's preset folder alone (the self-test passes this; installing there replaces the presets of your other shoots)")
    ap.add_argument("--dop", action="store_true", help="with --presets: write a PhotoLab .dop sidecar per frame so the folder opens with the preset and star rating already applied")
    ap.add_argument("--crop", default=None, help="with --dop: place a crop of this aspect (4:5, 1:1) on every pick, faces on the upper third")
    ap.add_argument("--level", action="store_true", help="with --dop: straighten picks the cull flagged as tilted")
    ap.add_argument("--dry-run", action="store_true", help="report only, write nothing")
    ap.add_argument("--previews", type=Path, default=None, help="folder of the camera's own JPEGs named <stem>.jpg, for culling cached decodes whose RAWs are gone (exposure and aesthetics are read off these)")
    # Previews and thumbnails are always kept. A cull whose result cannot be
    # looked at is not a finished cull, and making that an opt-in flag meant a
    # run could leave 1157 frames with nothing to show for them. They cost about
    # 350 KB a frame. The full-resolution decodes are the expensive ones, at
    # 2.3 MB a frame, so those stay behind a flag.
    ap.add_argument("--keep-decoded", "--keep-previews", dest="keep_decoded", action="store_true",
                    help="keep the full-resolution decodes in <out>/decoded after the run (about 2.3 MB a frame; lets the bench re-run and the studio show full-size frames after the RAWs are gone). Without it they are removed at the end, unless the folder was already there")
    ap.add_argument("--dark-floor", type=float, default=DARK_FLOOR, help="reject a frame with no subject when its mean brightness (0-255) is below this; frames with a subject are never rejected for darkness")
    args = ap.parse_args()
    # --learn fitted one set of ranking weights to one shoot's picks and
    # applied them to every later shoot of every kind. docs/TRAINING.md's own
    # measurement says taste does not carry between shoots that way, and the
    # file it wrote had never been fitted on this library. What the cull
    # learns now, it learns from finished shoots and checks against every
    # keeper before using, and the studio shows it; --eval still measures.
    if args.taste is not None:
        print("--taste is retired with --learn: one set of weights fitted to one shoot does not carry to the next.\n"
              "What the cull has learned from your finished shoots is under ./pl learned, and nothing there is\n"
              "used until it has been checked against every photo you kept.", file=sys.stderr)
        return 2
    if args.learn is not None:
        print("--learn is retired: see ./pl learned. The one set of ranking weights it fitted to a single shoot was applied to every\n"
              "later shoot, and taste does not carry between shoots that way. What the cull learns from your\n"
              "finished shoots is on the studio's home page, under 'What the cull has learned', and nothing there\n"
              "is used until it has been checked against every photo you kept. To see how this cull agrees with\n"
              "your picks, run it with --eval instead.", file=sys.stderr)
        return 2
    # Two frames of each stack are tiered on an action shoot, where the frames
    # of one exchange differ more than they look. This was two frames per
    # same-picture group, back when a group hid the rest: with one an action
    # shoot lost 66 of the photographer's 252 keepers, and with two it lost 4.
    # Nothing is hidden for looking alike now; this only decides how many of
    # a stack can reach the shortlist.
    if not args.keep_per_group:
        args.keep_per_group = 2 if args.style == "action" else 1

    folder = args.folder.expanduser().resolve()
    if not folder.is_dir():
        print(f"Not a folder: {folder}", file=sys.stderr)
        return 1
    files = sorted(p for p in folder.iterdir() if p.suffix.lower() in RAW_EXTS | JPEG_EXTS)
    if not files:
        print(f"No images in {folder}", file=sys.stderr)
        return 1
    # <shoot>/cull, the name the rest of the pipeline writes and reads. A folder
    # of loose frames is its own shoot, so its cull goes inside it; a _cull/
    # left there by the old fork of this script is still written to rather
    # than forked a second time beside it.
    if args.out is None:
        if folder.name == "raw":
            args.out = folder.parent / "cull"
        else:
            args.out = folder / ("_cull" if (folder / "_cull").is_dir() and not (folder / "cull").exists() else "cull")
    out_dir = args.out.expanduser().resolve()
    print(f"{len(files)} images in {folder.name}")

    # Detectors
    face_det = None
    if FACE_MODEL.exists():
        try:
            face_det = cv2.FaceDetectorYN.create(str(FACE_MODEL), "", (320, 320), FACE_CONF, 0.3, 5000)
        except cv2.error as e:
            print(f"  face detector unavailable ({e})")
    subj_det = None
    if not args.no_subject and SUBJECT_MODEL.exists():
        try:
            subj_det = SubjectDetector(SUBJECT_MODEL)
        except cv2.error as e:
            print(f"  subject detector unavailable ({e})")
    if face_det is None and subj_det is None:
        print("  no detectors: center crops only, results will be rough")

    quality = None
    if not args.no_quality:
        try:
            sys.path.insert(0, str(Path(__file__).resolve().parent))
            import quality as qmod
            quality = qmod.Quality(use_eyes=not args.no_eyes)
            if not quality.use_aesthetic and not quality.use_eyes:
                quality = None
        except Exception as e:  # noqa: BLE001
            print(f"  quality stage off ({e})")
            quality = None

    meta = read_metadata(files)
    # A cull of cached decodes carries no EXIF: the decode and the camera JPEG
    # beside it have none, so every frame would stand alone in a burst of one
    # and every rule that compares a frame with its neighbours would have
    # nothing to compare it to. --times hands those frames their capture time
    # back, out of the cull.csv an earlier run wrote while the RAWs were still
    # here. Whole seconds, because shot_at carries no subsecond field, so
    # frames inside one second stay in file order, which is shooting order.
    if args.times is not None and args.times.exists():
        try:
            times = {Path(r["file"]).stem: r.get("shot_at", "") for r in csv.DictReader(args.times.read_text().splitlines())}
        except (OSError, ValueError, KeyError):
            times = {}
        got = 0
        for f in files:
            if not meta.get(f.name, {}).get("DateTimeOriginal") and times.get(f.stem):
                meta.setdefault(f.name, {})["DateTimeOriginal"] = times[f.stem]
                got += 1
        print(f"  capture time for {got} of {len(files)} frames read from {args.times.name}, to whole seconds")
    frames = [Frame(path=f, shot_at=str(meta.get(f.name, {}).get("DateTimeOriginal", "")),
                    seq=seq_key(meta.get(f.name, {}))) for f in files]

    # Previews go to <out>/previews so the studio can show them without a second
    # extraction, and so the run leaves something a person can review.
    keep_dir = None if args.dry_run else (out_dir / "previews")
    tmp_obj = None if keep_dir else tempfile.TemporaryDirectory()   # a local: removed when main returns, not at the block's end
    # Each cache folder is minted through library.cache_dir, which writes its
    # CACHEDIR.TAG as it creates it. A plain mkdir left a command-line cull's
    # caches untagged, and an untagged folder is one both reclaim modules
    # count and never offer: the licence to take bytes back is written only by
    # whatever made them. A folder that is already there and full is left as
    # it was, tag or none (see cache_dir for the shoot that needs that).
    from library import cache_dir
    if keep_dir is not None:
        cache_dir(keep_dir, built_by="cull")
    with contextlib.nullcontext(str(keep_dir) if keep_dir else tmp_obj.name) as tmp:
        tmpdir = Path(tmp)
        tmpdir.mkdir(parents=True, exist_ok=True)
        raws = [f.path for f in frames if f.path.suffix.lower() in RAW_EXTS]
        raws = [p for p in raws if not (tmpdir / f"{p.stem}.jpg").exists()]
        if raws:
            print("  extracting previews...")
            progress("previews", 0, 1)
            extract_previews(raws, tmpdir, meta)
            progress("previews", 1, 1)

        def preview_of(fr: Frame) -> Path:
            # A cull of cached decodes (the RAWs are gone) is handed the
            # original camera JPEGs with --previews; without them, exposure
            # and aesthetics would be read off the dark neutral decode.
            if args.previews is not None:
                p = args.previews / f"{fr.path.stem}.jpg"
                if p.exists():
                    return p
            return tmpdir / f"{fr.path.stem}.jpg" if fr.path.suffix.lower() in RAW_EXTS else fr.path

        # ---------------- decode: every RAW at full resolution, in parallel
        # Focus, faces and blur are read off real pixels; the camera's own
        # preview is kept for what the photographer sees (exposure, thumbs).
        #
        # The decodes go to <out>/decoded, which is where the bench, the studio
        # and the preset step all look for them. They used to be written into
        # <out>/previews/decoded unless --keep-decoded was passed, which was
        # neither temporary (nothing ever deleted them) nor findable (nothing
        # looked there), so the flag cost the disk whether it was passed or not
        # and bought nothing. Now the flag decides only whether they survive the
        # run, and a folder that was already here is never removed.
        dec_dir = (tmpdir / "decoded") if args.dry_run else (out_dir / "decoded")
        decoded_before = dec_dir.exists()
        if not args.dry_run:
            cache_dir(dec_dir, built_by="cull")
        full_decode = args.decode == "full"
        decodes: dict[str, Path] = {}
        # Ask for the room before the first frame rather than dying at frame
        # 400 with half the shoot decoded and the rest judged, silently, on
        # the camera preview. The figures are measured on this library, not
        # guessed: cull/decoded came to 7.6 GB for the 1,157 frames of the
        # 09-16 gym shoot, 6.5 MB a frame, and previews, large and thumbs
        # together to about 0.6 MB a frame. Decodes already on disk are left
        # out of the estimate; a second run with --keep-decoded must not be
        # refused for space it is not going to ask for.
        want_dec = [fr for fr in frames if fr.path.suffix.lower() in RAW_EXTS
                    and not (dec_dir / f"{fr.path.stem}.jpg").exists()]
        need = int(len(want_dec) * 6.5 * 1024 ** 2 + len(frames) * 0.6 * 1024 ** 2)
        try:
            require_space(dec_dir, need, f"the cull of {folder.name}: {len(want_dec)} decodes and {len(frames)} previews")
        except NotEnoughRoom as e:
            print(f"\n{e}", file=sys.stderr)
            return 1
        try:
            import faces as fmod
            fmod.FULL = full_decode
            pairs = [(fr.path, dec_dir / f"{fr.path.stem}.jpg") for fr in frames if fr.path.suffix.lower() in RAW_EXTS]
            if pairs:
                print(f"  decoding {len(pairs)} RAWs at {'full' if full_decode else 'half'} resolution, {args.workers} at a time...")
                progress("decode", 0, len(pairs))
                fmod.decode_all(pairs, workers=args.workers, progress=lambda d, t: progress("decode", d, t), full=full_decode)
            decodes = {fr.path.stem: (dec_dir / f"{fr.path.stem}.jpg") for fr in frames if fr.path.suffix.lower() in RAW_EXTS}
        except Exception as e:  # noqa: BLE001
            print(f"  decode off ({e}); focus from the previews")

        def decode_of(fr: Frame) -> Path:
            p = decodes.get(fr.path.stem)
            return p if p is not None and p.exists() else preview_of(fr)

        # ---------------- stage 1: focus
        print("  stage 1: focus...")
        progress("focus", 0, len(frames))
        # Two image reads, two detectors, tilt and exposure per frame, none of
        # it shared between frames: a frame per core (common.pool_map).
        from common import pool_map
        # A decode that never landed is nobody's error today: decode_of hands
        # back the camera preview and the frame is judged on a tenth of the
        # pixels with nothing in the log. Count them and name them.
        jobs, fell_back = [], set()
        for i, fr in enumerate(frames, 1):
            src = preview_of(fr)
            dec = decode_of(fr)
            want = decodes.get(fr.path.stem)
            if want is not None and dec != want:
                fell_back.add(fr.path.name)
            jobs.append((i, str(src) if src.exists() else "", str(dec) if dec != src else "", subj_det is not None))
        first = dict(pool_map(focus_frame, jobs, workers=args.workers,
                              progress=lambda d, n: progress("focus", d, n) if d % 10 == 0 or d == n else None))
        for i, fr in enumerate(frames, 1):
            got = first.get(i)
            if got is None:
                fr.reason = "no preview"
                continue
            if got["preview_only"]:
                fell_back.add(fr.path.name)
            fr.camera_rating = int(meta.get(fr.path.name, {}).get("Rating") or 0)
            fr.det_size, fr.animal_boxes = got["det_size"], got["animal_boxes"]
            fr.sharp, fr.faces, fr.method, fr.box, fr.face_box = got["sharp"], got["faces"], got["method"], got["box"], got["face_box"]
            fr.tilt = got["tilt"]
            if 1.5 <= abs(fr.tilt) <= 8:
                fr.face_flags = (fr.face_flags + "; " if fr.face_flags else "") + "tilt?"
            fr.mean_luma, fr.clip_hi = got["mean_luma"], got["clip_hi"]

        if fell_back:
            names = ", ".join(sorted(fell_back)[:4])
            print(f"  WARNING: {len(fell_back)} of {len(frames)} frames were judged on the camera's preview, not the decode "
                  f"({names}{', ...' if len(fell_back) > 4 else ''}): the decode is missing or would not read, which is what "
                  f"a full volume or a killed run leaves behind. Focus, face and subject verdicts on those frames come off "
                  f"about a tenth of the sensor's pixels. Re-run the cull once there is room.")
            # The bar must not finish clean on a stage that did not: the studio
            # draws the last mark it sees for a stage.
            progress("focus", len(frames) - len(fell_back), len(frames))

        scored = [f for f in frames if f.sharp > 0]
        if not scored:
            print("Nothing scored.", file=sys.stderr)
            return 1

        burst, prev = 0, None
        for f in sorted(scored, key=lambda x: x.seq):
            # No capture time (a cull of cached decodes) means no burst
            # membership: the frame stands alone rather than joining every
            # other timeless frame in one burst.
            if prev is not None and (f.seq == 0 or (f.seq - prev) > args.burst_gap):
                burst += 1
            f.burst, prev = burst, f.seq
        rel_within(scored)

        for f in scored:
            if f.clip_hi > CLIP_HI_FLOOR:
                f.rejected, f.reason = True, "blown highlights"
            elif f.mean_luma < args.dark_floor and f.method == "center":
                # No face, no body, and nearly black: nothing to recover. A dark
                # frame *with* a subject is often a deliberate exposure for the
                # highlights and the RAW has the shadows; leave it in.
                f.rejected, f.reason = True, "too dark"
            elif args.burst_floor > 0 and f.sharp_rel < args.burst_floor:
                # Off unless asked for. sharp_rel is a
                # ratio to the sharpest frame of the burst, and the maximum of n
                # draws grows with n, so a fixed floor on it is a quota that
                # depends on the burst's length: pooled over four shoots this
                # fires on 0.0% of frames in bursts of 2, 7.8% at 4, 9.9% at 8,
                # 20.6% at 16 and 50.4% past 16, with nothing about the focus
                # changing. What it costs in keepers is stated once, in
                # --burst-floor's help above, against the answer key that is
                # current; this comment used to carry two other figures (27,
                # and 10 of 294) from answer keys that no longer exist. Every
                # adaptive boundary tried in its place (Otsu, percentiles,
                # Tukey, a largest-spacing test) did worse at equal review
                # size, and demoting instead of rejecting needs the review
                # order to carry it, which it does not yet.
                f.rejected, f.reason = True, "softest in burst"

        # ---------------- stage 1.5: every face, at real resolution
        # The preview is 1616 px wide and a face in it is 80 px: blur, blinks
        # and a mouth caught mid-word are invisible there. So every face is
        # judged on the decode this run already made (libraw, full resolution
        # unless --decode half). A fault bins the frame only when it is on the
        # largest readable face or on one at least half its area, so a blink
        # in a posed couple bins the frame and a blink on the man behind the
        # subject is a note (faces.verdict).
        judge = None
        face_floor = args.face_floor
        if not args.no_faces and quality is not None:
            try:
                import faces as fmod
                judge = fmod.FaceJudge(quality=quality)
            except Exception as e:  # noqa: BLE001
                print(f"  face stage off ({e})")
        if judge is not None:
            print("  stage 1.5: faces at full resolution...")
            progress("faces", 0, len(scored))
            allfaces: list = []
            # Every face on real pixels is CPU work (detection, landmarks,
            # sharpness, identity) and independent per frame, so it runs a
            # frame per core; CLIP on the face crops then runs once over the
            # whole shoot in large batches, which is how a GPU wants to be
            # fed. One frame at a time this pass was 0.7 s a frame on one
            # core of twelve, with the GPU idle between two-crop batches.
            jobs = [(i, str(fr.path), str(dec_dir / f"{fr.path.stem}.jpg"), str(preview_of(fr)), [tuple(b) for b in fr.animal_boxes], fr.det_size[0])
                    for i, fr in enumerate(scored, 1)]
            judged = fmod.judge_frames(jobs, workers=args.workers, progress=lambda d, n: progress("faces", d, n) if d % 5 == 0 or d == n else None)
            judge.clip_faces([fc for fs in judged.values() if fs for fc in fs])
            # What an in-focus face reads on THIS card, before a line is drawn
            # on any of them. This used to be measured after the judging and
            # printed, which made it the one number in the cull that was
            # computed and then thrown away; the print stayed useful and the
            # measurement decided nothing.
            #
            # It decides one thing now. 1.9 is the focus a face needs to pass
            # without a note, and it is the one number here with no way of
            # noticing it is on the wrong card: a softer lens, a diffusion
            # filter, heavy in-camera noise reduction or frames grabbed from
            # video move the whole distribution, and then the note fires on
            # everything or on nothing and says nothing about it. So the floor
            # is used as given wherever it sits inside the range of card scales
            # it has been validated on, and outside that range the card's own
            # reading takes over. The photographer's shoots read 3.37, 2.92,
            # too few to say, and 2.80 at the ninth decile of a readable face,
            # putting 1.9 at 0.56x, 0.65x and 0.68x of an in-focus face; the
            # band below is those extremes rounded outwards, so on all four of
            # his cards this changes the floor by nothing at all, which is the
            # point. It widens as cards accumulate, which is what the line
            # printed here is for.
            #
            # No veto depends on the floor - faces.UNREADABLE does the binning
            # and does not move - so this can shift a note and the review order
            # and cannot cost a keeper.
            ref = sorted(fc.sharp for fs in judged.values() if fs for fc in fs
                         if fc.main and fc.read and not fc.in_animal and fc.sharp > 0)
            if len(ref) >= 40:          # a sample-size guard, not a taste number
                p90 = ref[min(len(ref) - 1, int(0.9 * len(ref)))]
                face_floor = min(max(args.face_floor, 0.56 * p90), 0.68 * p90)
                print(f"    in-focus faces on this card read {p90:.2f}; --face-floor {args.face_floor:.2f} "
                      f"is {args.face_floor / p90:.2f}x that (the photographer's four shoots: 0.56, 0.65, 0.68)")
                if abs(face_floor - args.face_floor) > 0.005:
                    print(f"    that is outside every card this floor was set on, so the card's own reading is used: "
                          f"faces are noted soft under {face_floor:.2f} on this one, not {args.face_floor:.2f} "
                          f"(a note and the review order; nothing is binned for it)")
            else:
                print(f"    {len(ref)} readable faces: too few to say what an in-focus face reads on this card, "
                      f"so --face-floor {args.face_floor:.2f} is used as given")
            for i, fr in enumerate(scored, 1):
                fs = judged.get(i)
                if fs is None:
                    continue
                for fc in fs:
                    judge.flag(fc, face_floor)
                    allfaces.append((fr, fc))
                fs = [fc for fc in fs if "not a face" not in fc.flags]
                fr.face_n = len(fs)
                big = [fc for fc in fs if fc.main]
                fmod.kiss(big)
                # The back of a head (or a parrot) is not a face to judge.
                mains = [fc for fc in big if "face away" not in fc.flags]
                if not mains:
                    # Nothing judgeable at full resolution. If the preview
                    # stage saw a face or a body, it is there but too dark or
                    # too blurred to read, and that is not a point in its favour.
                    fr.face_score = 0.45 if fr.method in ("face", "subject") else 0.6
                if mains:
                    worst = min(mains, key=lambda fc: fc.score)
                    fr.face_score = worst.score
                    fr.gaze = float(min(fc.gaze for fc in mains))
                    fr.borderline = next((fc.borderline for fc in mains if fc.borderline), "")
                    hard, flags = fmod.verdict(mains)
                    lead = max([fc for fc in mains if fc.read] or mains, key=lambda fc: fc.box[2] * fc.box[3])
                    fr.lead_read, fr.lead_frac = float(lead.read), float(lead.frac)
                    # "Focus elsewhere" is a claim about the rest of the frame: it
                    # holds only when the first pass measured something other
                    # than the face (the subject's box) and there are burst
                    # mates to be relative to. sharp_rel is 1.0 for a frame alone
                    # in its set and is the face's own number when the focus was
                    # read off the face, and on both the excuse was empty.
                    elsewhere = fr.method != "face" and fr.sharp_peers >= 2 and fr.sharp_rel >= FOCUS_ELSEWHERE
                    if "soft" in hard and elsewhere:
                        hard.remove("soft")
                        flags = sorted((set(flags) - {"soft"}) | {"face soft, focus elsewhere"})
                    elif "soft?" in flags and elsewhere:
                        flags = sorted((set(flags) - {"soft?"}) | {"face soft, focus elsewhere"})
                    # Merged, not replaced: stage 1 may already have written
                    # "tilt?" here, and assigning over it dropped that note on
                    # every frame with a judged face, which is most of them.
                    fr.face_flags = "; ".join(sorted(set(flags) | {fl for fl in fr.face_flags.split("; ") if fl}))
                    if hard and not fr.rejected:
                        fr.rejected, fr.reason = True, hard[0]
                    # The reprieve: the first pass binned this frame as the softest of
                    # its burst on a focus number; the judge has now read a face at
                    # full resolution and found it sharp and clean. The judge wins.
                    #
                    # "soft duplicate" was in this list and is gone. Nothing has
                    # set that reason since the dup floor stopped rejecting, and
                    # the dup floor itself is gone now that similar frames are
                    # stacked rather than ranked against each other by focus.
                    # The string still appears in older cull.csv files, which is
                    # exactly why a cull.csv cannot be read as a list of live rules.
                    if fr.rejected and fr.reason == "softest in burst" and not hard \
                            and any(fc.read and fc.sharp >= fmod.UNREADABLE for fc in mains):
                        fr.rejected, fr.reason = False, ""
                if i % 50 == 0 or i == len(scored):
                    print(f"    {i}/{len(scored)}")
                if i % 5 == 0 or i == len(scored):
                    progress("faces", i, len(scored))
            ids = people_clusters([fc.emb for _, fc in allfaces])
            for (fr, fc), pid in zip(allfaces, ids):
                fc.person = pid
            byframe: dict = {}
            for fr, fc in allfaces:
                if fc.main and fc.person >= 0 and not fc.in_animal:
                    byframe.setdefault(id(fr), set()).add(fc.person)
            for fr in scored:
                fr.people = " ".join(f"p{p}" for p in sorted(byframe.get(id(fr), ())))
            # Softer than half of the same person's sharpest frame in the same
            # burst. In units that mean the same on any card and lens ("0.4x
            # his best"), which is what the photographer would say; it needs
            # two frames of the person in the burst. It replaces the burst
            # quota on a focus number: 1 keeper of 154 on the action shoot it
            # was set on, none on the other three, and it removes nothing there.
            best: dict = {}
            count: dict = {}
            lead_of: dict = {}
            frames_of: dict = {}
            for fr, fc in allfaces:
                if fc.main and fc.read and fc.person >= 0 and fr.burst >= 0 and not fc.in_animal:
                    key = (fr.burst, fc.person)
                    # Their sharpest among the frames still standing: a blink
                    # at 3.3 is not the frame the photographer would keep, and
                    # measured against it a 1.5 the photographer exported read as "soft".
                    if not fr.rejected:
                        best[key] = max(best.get(key, 0.0), fc.sharp)
                    frames_of.setdefault(key, set()).add(id(fr))
                    cur = lead_of.get(id(fr))
                    if cur is None or fc.box[2] * fc.box[3] > cur.box[2] * cur.box[3]:
                        lead_of[id(fr)] = fc
            count = {k: len(v) for k, v in frames_of.items()}
            person_line: dict = {}
            for fr in scored:
                fc = lead_of.get(id(fr))
                if fc is None or fr.rejected or (fr.method != "face" and fr.sharp_peers >= 2 and fr.sharp_rel >= FOCUS_ELSEWHERE):
                    continue
                key = (fr.burst, fc.person)
                if count.get(key, 0) >= 2 and best[key] > 0:
                    # The line this frame was held to, kept whether it passed or
                    # not: the doubt column has to say how close a frame that
                    # survived came as well as how far one that did not.
                    person_line[id(fr)] = (fc.sharp, 0.5 * best[key])
                    if fc.sharp < 0.5 * best[key]:
                        fr.rejected, fr.reason = True, "soft for this person"
                        fr.face_flags = "; ".join(sorted(set(fr.face_flags.split("; ") if fr.face_flags else []) | {f"{fc.sharp / best[key]:.1f}x their sharpest in the burst"}))

            # ---------------- how sure the cull is, frame by frame
            # There was no way for the cull to say "I am not sure about this
            # one". A fault at a hair past its line and a fault a mile past it
            # came out of cull.csv as the same word. The judge already noticed
            # the close ones (faces.Face.borderline: a blink at 0.6, a face
            # within a tenth of the floor); this puts a number on the same
            # thing, in units of how much this card's own back-to-back frames
            # move, and puts a column in cull.csv for the studio to sort on.
            spread, pairs, together = card_spreads(scored, allfaces)
            mains_of: dict = {}
            for fr, fc in allfaces:
                if fc.main and "not a face" not in fc.flags and "face away" not in fc.flags:
                    mains_of.setdefault(id(fr), []).append(fc)
            for fr in scored:
                fr.confidence, fr.close_call = doubt(fr, fault_chances(
                    fr, mains_of.get(id(fr), []), spread, args.dark_floor, person_line.get(id(fr)), together))
            said = [fr for fr in scored if fr.confidence >= 0]
            if said:
                moves = ", ".join(f"{k} {spread[k]:.3f}" for k in ("blink", "sharp", "lum", "clip_hi") if spread.get(k))
                if together:
                    moves += f"; blink and smile move together {together:+.2f}"
                close = sorted((fr for fr in said if fr.rejected and fr.confidence < 0.9), key=lambda f: f.confidence)
                print(f"    how sure: measured on {len(said)} of {len(scored)} frames from {pairs['sharp']} pairs of "
                      f"one subject back to back and {pairs['clip_hi']} pairs of frames ({moves})")
                if close:
                    print(f"    {len(close)} binned frames are close calls (least sure first): "
                          + ", ".join(f"{fr.path.name} {fr.reason} {fr.confidence:.2f}" for fr in close[:4])
                          + (", ..." if len(close) > 4 else ""))
            else:
                print("    how sure: no two frames of one subject back to back on this card, so nothing can be said "
                      "about how far a verdict was from its line; the confidence column is left empty")
            for n in judge.notes:
                print(f"    note: {n}")

        # ---------------- stage 2: quality, on every scored frame so grouping sees them all
        hashes: list = []
        embs = None
        if quality is not None:
            print("  stage 2: quality...")
            progress("quality", 0, 1)
            paths = [preview_of(f) for f in scored]
            if quality.use_aesthetic:
                print("    aesthetic (CLIP)...")
                aes, embs = quality.aesthetic_batch(paths)
                for f, a in zip(scored, aes):
                    f.aesthetic = float(a)
                labels, action = quality.moments(embs)
                shadows = quality.flaws(embs)
                # The learned flaw model, when the photographer's drops have taught one.
                try:
                    import flaws as fmodel
                    fm = fmodel.load()
                    if fm.get("reasons"):
                        fp, fnames = fmodel.score(embs, fm)
                        for f, pf, nm in zip(scored, fp, fnames):
                            f.flaw = float(pf)
                            if nm:
                                f.face_flags = (f.face_flags + "; " if f.face_flags else "") + f"{nm}?"
                    # What it used, or why it used nothing, from the learned
                    # folder's own record: "no drop reasons" is as much a fact
                    # about this cull as the reasons would have been.
                    print("  " + fmodel.describe())
                except Exception as e:  # noqa: BLE001
                    print(f"  drop reasons off ({e})")
                for f, sh in zip(scored, shadows):
                    f.shadow = float(sh)
                    if sh >= 0.95:
                        f.face_flags = (f.face_flags + "; " if f.face_flags else "") + "shadow?"
                for f, lab, a in zip(scored, labels, action):
                    if f.method == "center":
                        # Nobody detected, so the labels that are about people
                        # cannot apply and the action score has nothing to be about.
                        lab = lab if lab in ("crowd", "place", "animal", "portrait") else ""
                        a = 0.0
                    f.moment, f.action = lab, float(a)
            try:
                import imagehash
                from PIL import Image
                for p in paths:
                    with Image.open(p) as im:
                        hashes.append(imagehash.phash(im))
            except ImportError:
                hashes = []
            if quality.use_eyes:
                print("    eyes and framing...")
            for i, f in enumerate(scored, 1):
                f.subj_area, f.thirds = quality.framing(f.box, *f.det_size)
                if judge is None and quality.use_eyes and f.face_box is not None and not f.rejected:
                    img = cv2.imread(str(preview_of(f)))
                    crop = face_crop(detector_image(img), f.face_box)
                    if crop is not None:
                        f.eyes_open, f.smile, f.faces_lm = quality.eyes(crop)
                if i % 50 == 0 or i == len(scored):
                    print(f"      {i}/{len(scored)}")
            for n in quality.notes:
                print(f"    note: {n}")

    # ---------------- stacks: frames that look alike, side by side
    # Nothing in this block decides whether a frame is shown. It used to: a
    # same-picture group showed one frame (two with --style action) and hid
    # the rest as duplicates, and 65 of his 773 keepers over six shoots were
    # among the hidden. See quality.similar_stacks for why no threshold could
    # have made that safe. The dup floor that sorted a softer frame last in
    # its group went with it: the size of a sharpness gap says nothing about
    # which of two frames he keeps.
    similar = None           # what cull/similar.npz is written from
    stack_line: dict = {}
    if quality is not None and hashes:
        import quality as qmod
        progress("quality", 1, 1)
        # Stacks are formed from the vectors exactly as similar.npz stores
        # them (float16), so a stack formed again from that file is this one.
        vec16 = None if embs is None else np.asarray(embs, dtype=np.float32).astype(np.float16)
        bits = np.array([qmod.hash_bits(h) for h in hashes], dtype=bool)
        sids, stack_line = qmod.similar_stacks(vec16, list(bits), [f.burst for f in scored],
                                               [f.seq for f in scored], [f.path.name for f in scored])
        for f, sid in zip(scored, sids):
            f.stack = sid
        if stack_line.get("cos") is not None:
            similar = (vec16, bits)
            print(f"    similar frames: back to back, frames on this card change a median of {stack_line['bits']:.0f} "
                  f"of 64 phash bits and CLIP {stack_line['cos']:.3f} ({stack_line['pairs']} pairs); "
                  f"neighbors that changed less than both are stacked")
        else:
            print(f"    similar frames: {stack_line.get('why') or 'not measured'}; nothing is stacked")
        scenes = qmod.scene_clusters(embs, len(scored))
        # A preset is built per scene from that scene's light, so a scene has to
        # be a light as well as a subject.
        luma = np.array([f.mean_luma for f in scored], dtype=float)
        before = len(set(scenes))
        scenes = qmod.split_by_light(scenes, luma)
        if len(set(scenes)) > before:
            print(f"  scenes: {before} by subject, {len(set(scenes))} once the light is taken into account")
        for f, sc in zip(scored, scenes):
            f.scene = sc

    alive = [f for f in scored if not f.rejected]

    # ---------------- ranking and verdicts
    if quality is not None and alive:
        import quality as qmod
        # One set of weights for every shoot. --taste and --learn fitted a set
        # to one shoot's picks and applied it to every later one, and taste
        # does not carry between shoots that way (docs/TRAINING.md measured
        # it); what the cull learns now comes through the learned folder,
        # checked against every keeper first.
        weights = qmod.DEFAULT_WEIGHTS
        feats = {n: np.array([getattr(f, n) for f in alive]) for n in qmod.FEATURES}
        q = qmod.combined_score(feats, weights)
        for f, s in zip(alive, q):
            # The face judge's verdict is one weighted feature like the rest
            # (its hard vetoes already happened), weighed against light,
            # composition and the rest by quality.DEFAULT_WEIGHTS.
            f.quality = float(s)
        rank_key = lambda f: f.quality  # noqa: E731
    else:
        rank_key = lambda f: f.sharp  # noqa: E731

    best_of = stack_verdicts(alive, args.keep_per_group)
    stacked = {f.stack for f in alive if f.stack >= 0}
    for f in scored:
        if f.stack not in stacked:
            f.stack = -1          # a run that the faults left with one frame is no stack
    best_of.sort(key=rank_key, reverse=True)
    # ---------------- tiers: what to look at, in what order
    # A burst is one exchange, and the photographer keeps about two frames
    # of it. Per burst, the two best frames are the CLEAR WINS (5), the next
    # two are MAYBES (3), the rest are PROBABLY NOT (2) and wait one key
    # below the stage with the stacked frames that were not tiered; only
    # faults (0) are hidden. Ordered by the venue's own ranker where one exists, learned
    # from what he kept on a finished shoot that measures like this one
    # (taste.learn_ranker; used above 0.60 held out by burst), else by the
    # score. Measured on the action shoot against the 154 frames he exported:
    # the two best per burst hold 39% of them at 36% precision, the four best
    # 55%, against 30% by chance. That is the ceiling of any ranking there;
    # what the tiers do is put the pile in an order and hide what is broken.
    scorer = rank_key
    ranker = venue_ranker(folder, alive, judge if "judge" in dir() else None, preview_of)
    if ranker is not None and args.eval:
        import taste as tmod
        own = tmod.venue_for(folder.parent if folder.name == "raw" else folder)
        if own is not None and own[1].get("ranker") is ranker:
            print("  --eval on the venue this ranker was learned from: ranked without it, so the bench is not in-sample")
            ranker = None
    if ranker is not None:
        by_burst_n: dict[int, list[Frame]] = {}
        for f in alive:
            by_burst_n.setdefault(f.burst, []).append(f)
        for fs in by_burst_n.values():
            fs.sort(key=lambda f: f.shot_at)
        pos = {id(f): (i / max(1, len(fs) - 1), len(fs)) for fs in by_burst_n.values() for i, f in enumerate(fs)}
        import taste as tmod
        rscore = {id(f): tmod.rank_score(ranker, tmod.rank_features(
            {"face_score": f.face_score, "gaze": f.gaze, "aesthetic": f.aesthetic, "quality": f.quality, "subj_area": f.subj_area,
             "thirds": f.thirds, "mean_luma": f.mean_luma, "sharp_rel": f.sharp_rel, "focus": f.sharp, "action": f.action, "faces": f.faces,
             "eyes_open": f.eyes_open, "smile": f.smile, "lead_read": f.lead_read, "lead_frac": f.lead_frac}, *pos[id(f)])) for f in alive}
        scorer = lambda f: rscore[id(f)]  # noqa: E731
        print(f"  ranked by the venue's own ranker ({ranker['auc']:.2f} held out by burst on {ranker['n_kept']} kept frames)")
    # Dealt by common.deal_tiers, which the keeper check replays: the lanes,
    # the share that is a clear win and the one-lane rule live there, once.
    by_burst: dict[int, list[int]] = {}
    for k, f in enumerate(best_of):
        by_burst.setdefault(f.burst, []).append(k)
    dealt, across = deal_tiers(list(by_burst.values()), list(range(len(best_of))), lambda k: scorer(best_of[k]))
    if across:
        lone = sum(1 for ks in by_burst.values() if len(ks) == 1)
        print(f"  {lone} of {len(by_burst)} bursts hold one frame: tiers cut across the shoot, not per burst")
    # By rank alone. A note (soft for a portrait, a mouth open, a dim face) is
    # on nearly every frame of an action shoot and is the photographer's
    # tolerance there, so it is shown on the tile and does not gate a tier:
    # gating on it left 2 clear wins in 1,157 frames.
    tiers = {5: 0, 3: 0, 2: 0}
    words = {5: "clear win", 3: "maybe", 2: "probably not"}
    for k, t in dealt.items():
        best_of[k].rating, best_of[k].reason = t, words[t]
        tiers[t] += 1
    under = sum(1 for f in alive if f.stack >= 0 and not f.stack_top)
    print(f"  tiers: {tiers[5]} clear wins, {tiers[3]} maybes, {tiers[2]} probably not; {under} frames under the top of "
          f"{len(stacked)} stacks, shown; {sum(1 for f in scored if f.rejected)} faults hidden")
    # --top and the studio's order follow the same ranking as the tiers.
    best_of.sort(key=scorer, reverse=True)
    rank_key = scorer
    if args.top and len(best_of) > args.top and args.top_by == "quality":
        # Plain best N, with two small caps so a burst of near-identical
        # frames cannot fill the set: at most 2 per time burst and a quarter
        # of N per scene.
        per_burst: dict[int, int] = {}
        per_scene: dict[int, int] = {}
        scene_cap = max(3, args.top // 4)
        kept: list[Frame] = []
        for f in best_of:
            if len(kept) >= args.top:
                break
            if per_burst.get(f.burst, 0) >= 2 or per_scene.get(f.scene, 0) >= scene_cap:
                continue
            kept.append(f)
            per_burst[f.burst] = per_burst.get(f.burst, 0) + 1
            per_scene[f.scene] = per_scene.get(f.scene, 0) + 1
        for f in best_of:
            if f not in kept and len(kept) < args.top:
                kept.append(f)
        keep_ids = {id(f) for f in kept}
        for f in best_of:
            if id(f) not in keep_ids:
                f.rating, f.reason = 2, "below the cut"
            elif f.rating < 3:
                f.rating, f.reason = 3, "maybe"        # --top N is N picks, whatever tier they came from
    elif args.top and len(best_of) > args.top:
        # Every setup is represented, in proportion to the time the
        # photographer spent on it: a scene with a fifth of the frames gets a
        # fifth of the picks, and no scene gets none. Inside a scene the best
        # by score go first. The score is a suggestion inside a setup; the
        # setups themselves are the photographer's own choice of where to
        # stand, and that is the stronger signal.
        by_scene: dict[int, list[Frame]] = {}
        for f in best_of:
            by_scene.setdefault(f.scene, []).append(f)
        n_all = sum(len(v) for v in by_scene.values())
        alloc = {sc: max(1, int(round(args.top * len(v) / n_all))) for sc, v in by_scene.items()}
        while sum(alloc.values()) > args.top:
            over = [sc for sc in alloc if alloc[sc] > 1]
            if over:
                sc = max(over, key=lambda sc: alloc[sc] - args.top * len(by_scene[sc]) / n_all)
                alloc[sc] -= 1
                continue
            # More setups than picks. Every setup cannot have one, and this used
            # to give up here and hand back more frames than --top asked for:
            # 33 setups and --top 30 returned 33. Drop the smallest setups
            # instead, the same "in proportion to the time spent there" rule as
            # the share above, carried to its end.
            if len(alloc) <= 1:
                break
            del alloc[min(alloc, key=lambda sc: (len(by_scene[sc]), sc))]
        while sum(alloc.values()) < args.top:
            sc = max(alloc, key=lambda sc: (args.top * len(by_scene[sc]) / n_all - alloc[sc]) if alloc[sc] < len(by_scene[sc]) else -1e9)
            if alloc[sc] >= len(by_scene[sc]):
                break
            alloc[sc] += 1
        kept: list[Frame] = []
        for sc in alloc:
            lane = by_scene[sc]
            lane.sort(key=rank_key, reverse=True)
            per_burst: dict[int, int] = {}
            chosen = 0
            for f in lane:
                if chosen >= alloc[sc]:
                    break
                if per_burst.get(f.burst, 0) >= 2:
                    continue
                kept.append(f)
                per_burst[f.burst] = per_burst.get(f.burst, 0) + 1
                chosen += 1
        keep_ids = {id(f) for f in kept}
        for f in best_of:
            if id(f) not in keep_ids:
                f.rating, f.reason = 2, "below the cut"
            elif f.rating < 3:
                f.rating, f.reason = 3, "maybe"
    never_above_top(alive)
    # Taste beats the tool. Anything named in --keep is a pick, rejected or not.
    keep = {k.strip() for k in args.keep.split(",") if k.strip()}
    # A star set on the camera in playback is the photographer's verdict from the moment it was shot.
    for f in scored:
        if f.camera_rating >= 1:
            keep.add(f.path.name)
            f.face_flags = (f.face_flags + "; " if f.face_flags else "") + f"camera {f.camera_rating}★"
    for f in scored:
        if f.path.name in keep or f.path.stem in keep:
            # The confidence column answers "how sure is the cull of the call
            # it made on this frame". The call on this frame was the
            # photographer's, so the cull's own certainty about the verdict it
            # has just been overruled on is not an answer to that question: a
            # frame reading "kept by hand" beside "0.98" reads as the cull
            # being sure it kept it. It abstains here as it does anywhere else
            # it cannot say.
            f.rejected, f.rating, f.reason = False, 5, "kept by hand"
            f.confidence, f.close_call = -1.0, ""
            if f not in alive:
                alive.append(f)
    picks = sorted([f for f in alive if f.rating >= 3], key=lambda x: x.seq)
    below = [f for f in alive if f.rating == 2]
    rejects = [f for f in scored if f.rejected]

    print()
    print(f"  bursts by time       {burst + 1}")
    print(f"  stacks               {len(stacked)}, holding {sum(1 for f in alive if f.stack >= 0)} frames "
          f"that look alike; none hidden for it")
    if quality is not None:
        print(f"  scenes               {len({f.scene for f in alive})}")
    print(f"  picks (3 and 5 star) {len(picks)}   of which 5 star {sum(1 for f in picks if f.rating == 5)}")
    if below:
        print(f"  {'below --top' if args.top else 'set aside'} (2 star) {len(below)}, "
              f"{sum(1 for f in below if f.reason.startswith('similar to'))} of them under a stack's top")
    print(f"  rejects (0 star)     {len(rejects)}")
    if rejects:
        why: dict[str, int] = {}
        for f in rejects:
            why[f.reason] = why.get(f.reason, 0) + 1
        print("    " + ", ".join(f"{k}: {v}" for k, v in sorted(why.items())))
    counts = {m: sum(1 for f in scored if f.method == m) for m in ("face", "subject", "center")}
    print(f"  scored on faces {counts['face']}, bodies {counts['subject']}, nothing found {counts['center']}")
    if quality is not None:
        # eyes_open and faces_lm are filled in ONLY on the fallback path above
        # (`if judge is None`), where eyes are read off the camera preview.
        # When the full-resolution judge runs — which is the normal path — it
        # does the eye work itself on real pixels and these two stay at their
        # defaults. Printing them regardless said "eyes read on 0 frames" on a
        # run that had just judged 94 of them and binned 28 blinks, which reads
        # as a veto fired on a measurement nobody took. The line now says which
        # pass did the reading, or says nothing.
        if judge is None:
            blinks = [f for f in alive if f.faces_lm and f.eyes_open < 0.4]
            print(f"  eyes read on         {sum(1 for f in alive if f.faces_lm)} frames "
                  f"(preview), blinks {len(blinks)}")
        if judge is not None:
            reasons: dict[str, int] = {}
            for f in scored:
                if f.rejected and f.reason in fmod.HARD_FACE_FLAGS + ("soft for this person",):
                    reasons[f.reason] = reasons.get(f.reason, 0) + 1
            print(f"  faces judged         {sum(1 for f in scored if f.face_n)} frames; rejected for " + (", ".join(f"{k} {v}" for k, v in sorted(reasons.items())) or "nothing"))
            print(f"  people found         {len({p for f in scored for p in f.people.split()})}")
        moms: dict[str, int] = {}
        for f in alive:
            if f.moment:
                moms[f.moment] = moms.get(f.moment, 0) + 1
        if moms:
            print("  moments              " + ", ".join(f"{k} {v}" for k, v in sorted(moms.items(), key=lambda kv: -kv[1])))

    # ---------------- evaluation
    if args.eval:
        import quality as qmod
        chosen = {Path(c).stem for c in json.load(open(args.eval))}   # by stem: a select recorded against the RAW matches its cached decode
        y = np.array([1.0 if f.path.stem in chosen else 0.0 for f in alive])
        npos = int(y.sum())
        # Lost is every keeper he would not see without going looking, not
        # only the ones a fault threw out. This used to count rejections
        # alone, so a keeper hidden as a duplicate showed up as a "missed"
        # line and never in the number: the bench read 152 of 154 on the
        # action shoot while 19 more of its keepers were hidden.
        lost, under = unseen_keepers(frame_rows(frames), chosen)
        here = {f.path.stem for f in frames}
        got = [f for f in picks if f.path.stem in chosen]
        print(f"\n  ground truth: {len(chosen)} files you chose; {sum(1 for c in chosen if c in here) - len(lost)} shown by default, "
              f"{len(lost)} LOST" + (f" ({', '.join(n + ': ' + why for n, why in lost)})" if lost else "")
              + (f"; {sum(1 for c in chosen if c not in here)} not in this folder" if any(c not in here for c in chosen) else ""))
        print(f"  under a stack's top: {len(under)}, shown one key away"
              + (f" ({', '.join(n + ' under ' + top for n, top in under[:8])}{', ...' if len(under) > 8 else ''})" if under else ""))
        print(f"  in the pick set: {len(got)} of {len(chosen)}   (pick set is {len(picks)} of {len(scored)} frames; "
              f"random would land about {len(chosen) * len(picks) / max(1, len(scored)):.1f})")
        missed = [f for f in alive if f.path.stem in chosen and f.rating < 3]
        for f in missed:
            print(f"    not shortlisted: {f.path.name} ({f.reason})")
        if npos == 0:
            print("  none of the listed files are in this folder; check names")
        else:
            X = np.column_stack([np.array([getattr(f, n) for f in alive]) for n in qmod.FEATURES])
            ks = sorted({npos, min(2 * npos, len(alive)), min(40, len(alive))})
            print("  precision at k (share of your picks captured in the top k):")
            print(f"    {'':22s}" + "".join(f"k={k:<7d}" for k in ks))
            def row(name, s):
                print(f"    {name:22s}" + "".join(f"{qmod.precision_at_k(s, y, k):.2f}     " for k in ks))
            # Expected value for a random ordering, not one lucky draw.
            print(f"    {'random (expected)':22s}" + "".join(
                f"{(k * npos / len(alive)) / max(1, min(k, npos)):.2f}     " for k in ks))
            row("sharpness only", np.array([f.sharp_rel for f in alive]))
            if quality is not None:
                row("aesthetic only", X[:, 0])
                row("eyes only", X[:, 2])
                row("combined (current)", np.array([f.quality for f in alive]))

    if args.dry_run:
        print("\ndry run, nothing written")
        return 0

    out_dir.mkdir(parents=True, exist_ok=True)
    # `group` stays for the readers written before stacks: a stack's frames
    # share its id and every other scored frame has one of its own, so no
    # reader looking for "the other frames of this group" finds a stranger.
    nxt = max((f.stack for f in scored), default=-1) + 1
    for f in sorted(scored, key=lambda x: (x.seq, x.path.name)):
        if f.stack >= 0:
            f.group = f.stack
        else:
            f.group, nxt = nxt, nxt + 1
    # The whole file is built in memory and put in place in one rename. This
    # is the run's verdicts, the tiers and the drop reasons; a kill or a full
    # volume part way through the old truncating write left a cull.csv that
    # read back as a shorter shoot, with nothing to say rows were missing.
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["file", "rating", "reason", "face_flags", "face_score", "people", "group", "scene", "burst", "quality", "moment", "action", "shadow", "flaw", "tilt", "gaze", "borderline", "focus", "sharp_rel",
                "aesthetic", "eyes_open", "smile", "subj_area", "thirds", "faces", "method",
                "mean_luma", "clip_hi", "shot_at", "lead_read", "lead_frac",
                # Appended and not inserted: everything that reads this file
                # reads it by column name, and an older reader must keep working.
                "confidence", "close_call", "stack", "stack_top"])
    for f in sorted(frames, key=lambda x: x.path.name):
        w.writerow([f.path.name, f.rating, f.reason, f.face_flags, round(f.face_score, 3), f.people, f.group, f.scene, f.burst, round(f.quality, 3), f.moment, round(f.action, 3), round(f.shadow, 3), round(f.flaw, 3), round(f.tilt, 1), round(f.gaze, 2), f.borderline,
                    round(f.sharp, 1), round(f.sharp_rel, 3), round(f.aesthetic, 3),
                    round(f.eyes_open, 2), round(f.smile, 2), round(f.subj_area, 3),
                    round(f.thirds, 3), f.faces, f.method, round(f.mean_luma, 1),
                    round(f.clip_hi, 4), f.shot_at, round(f.lead_read, 0), round(f.lead_frac, 4),
                    "" if f.confidence < 0 else f"{f.confidence:.3f}", f.close_call,
                    "" if f.stack < 0 else f.stack, 1 if f.stack_top else 0])
    write_atomic(out_dir / "cull.csv", buf.getvalue())
    # What the stacks were formed from, per frame, so the studio can form
    # them again or say why two frames sit together, and a check on a shoot
    # whose RAWs are archived never has to run CLIP over it a second time.
    # It is derived from the previews and costs about 1.6 kB a frame.
    if similar is not None:
        import quality as qmod
        qmod.write_similar(out_dir / "similar.npz", [f.path.name for f in scored], *similar,
                           [f.seq for f in scored], [f.burst for f in scored], stack_line)

    # Record how this cull was run beside the shoot, so the studio shows the
    # settings that actually produced what is on screen even when the cull was
    # run from the command line.
    meta_path = out_dir.parent / "shoot.json"
    if not args.dry_run and meta_path.parent.is_dir():
        record_run(meta_path, args.style, face_floor, asked=args.face_floor)

    picks_dir = out_dir / "picks"
    if picks_dir.exists():
        # Clear only what the cull itself put here: symlinks, and files that
        # are the same inode as a RAW in the shoot (its hard links). A sidecar
        # is never touched, and neither is a file that is not ours: five
        # hand-edited .dop files were sitting in this folder while this was an
        # unconditional rmtree, one re-cull away from being gone.
        raw_inodes = {q.stat().st_ino for q in folder.iterdir() if q.is_file()}
        for q in picks_dir.iterdir():
            if q.is_symlink() or (q.is_file() and q.suffix.lower() != ".dop" and q.stat().st_ino in raw_inodes):
                q.unlink()
    picks_dir.mkdir(parents=True, exist_ok=True)
    linked = 0
    for f in picks:
        dest = picks_dir / f.path.name
        if dest.is_symlink():
            dest.unlink()
        elif dest.exists():
            if dest.stat().st_ino == f.path.stat().st_ino:
                linked += 1          # already this very file
            continue                 # a copy from an older run, or not ours: left alone
        if not args.copy:
            dest.symlink_to(f.path)
            continue
        # A hard link is a real file to every tool that opens it, and costs no
        # disk: 471 picks on an action shoot were 11 GB of byte-for-byte
        # duplicate RAWs beside the originals they were copied from. Falls back
        # to a copy across filesystems, where linking cannot work.
        try:
            os.link(f.path, dest)
            linked += 1
        except OSError:
            shutil.copy2(f.path, dest)
    if not args.dry_run:
        from common import ensure_thumbs
        progress("thumbs", 0, 1)
        cache_dir(out_dir / "thumbs", built_by="cull")
        cache_dir(out_dir / "large", built_by="cull")
        ensure_thumbs(out_dir / "previews", out_dir / "thumbs", [{"stem": f.path.stem} for f in frames],
                      decoded=dec_dir, large=out_dir / "large")
        progress("thumbs", 1, 1)
    print(f"\n  {out_dir / 'cull.csv'}")
    how = ("links" if linked == len(picks) else "copies") if args.copy else "symlinks"
    print(f"  {picks_dir}  ({len(picks)} {how})")

    if args.xmp:
        # The cull's 5 is a tier, not five stars (presets.write_dops writes it as 3 + "Clear win").
        for rating in (0, 1, 2, 3):
            grp = [f.path for f in scored if (min(f.rating, 3) == rating and not f.rejected) or (rating == 0 and f.rejected)]
            if grp:
                subprocess.run([EXIFTOOL, "-q", "-overwrite_original", f"-XMP:Rating={rating}",
                                *[str(p) for p in grp]], capture_output=True)
        print("  ratings written to XMP")
    if args.presets and not args.dry_run:
        import presets as pmod
        print("\n  presets, one per scene...")
        progress("presets", 0, 1)
        # Installing replaces every "Cull ..." preset in PhotoLab's folder
        # (presets.build), so a run on scratch frames must not: the self-test
        # was deleting the scene presets of real shoots on every run.
        pmod.build(folder, out_dir, install=not args.no_install, xmp=args.xmp, dop=args.dop, crop=args.crop, level=args.level, quality=quality)
        progress("presets", 1, 1)
        print(f"  {out_dir / 'presets.md'}")
    # Last, because the thumbnails and the preset step both read the decodes.
    # A folder that was already here belongs to an earlier run that asked for
    # it, so it is never removed.
    if not args.keep_decoded and not decoded_before and dec_dir.is_dir():
        shutil.rmtree(dec_dir, ignore_errors=True)
        print(f"  decodes discarded (--keep-decoded keeps them in {dec_dir})")
    return 0


if __name__ == "__main__":
    try:
        code = main()
    finally:
        # The run's workers, let go at the end of it rather than at the end of
        # every stage. They hold the imports the next stage would have paid
        # for again (common.shared_pool).
        from common import close_pool
        close_pool()
    sys.exit(code)
