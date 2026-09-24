"""
faces.py - judge every face at real resolution.

The embedded preview in a RAW is 1616 px wide; a face in it is 80 px. That is
why motion blur, closed eyes and a mouth caught mid-word got through the first
version of the cull. This module judges each face on the full-resolution
decode of the RAW (libraw; cull.py decodes every frame first, four at a time):

  sharp      Edge strength over local contrast on the band across the eyes,
             at decoded resolution, so a dim face and a bright one are held to
             the same standard.
  motion     Anisotropy of the gradients inside the face. Defocus blurs every
             direction alike; motion blur smears one direction, and the ratio
             says which.
  lum        Brightness of the face on the camera's own rendering. A face with
             nothing above L* 35 is a silhouette and no slider brings it back.
  blink      MediaPipe blendshapes, worst eye.
  expression jawOpen, squint, brow, pucker, cheek puff from the same
             blendshapes, plus CLIP on the face crop against a handful of
             prompts ("caught mid-sentence", "blinking", "grimace"). Neither is
             reliable alone; together they catch most of what a person would.
  identity   SFace embedding, so frames can be grouped by who is in them and a
             set can hold "the best of each person".

Faces are detected at three scales so one that fills the frame is found as
reliably as one across the room. A frame is judged on its main faces (the ones
big enough to matter), and it is the worst main face that counts: in a photo of
two people, one blink is a blink.
"""

from __future__ import annotations

import os
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

import cv2
import numpy as np

from common import MODELS  # noqa: E402
YUNET = MODELS / "yunet.onnx"
SFACE = MODELS / "face_recognition_sface_2021dec.onnx"
LANDMARKER = MODELS / "face_landmarker.task"

DECODE_W = 2400          # the reference width every size threshold below is stated at; scaled to the real decode
FULL = True              # decode at the sensor's full resolution; the judge scales its thresholds to the width it gets
# The eye band's longer side is resized to this before sharpness is read. It
# is the one size threshold here that is NOT scaled to the frame the way
# detect() scales MIN_JUDGE_PX; judge() holds the same number as a literal.
# The comment used to claim a scaling "per 2400 px of frame width" that no
# line of code has ever done.
BAND_PX = 160
DETECT_W = 1600          # width the face detector runs at
MAIN_FACE_FRAC = 0.05    # a face at least this fraction of frame width is "main"
MIN_JUDGE_PX = 90        # narrower than this and nothing about it can be judged

# What CLIP is asked about each face crop. The first is the good one.
FACE_PROMPTS = [
    ("good", "a photo of a person with a natural, relaxed, flattering expression"),
    ("talking", "a photo of a person caught mid-sentence with their mouth open"),
    ("blink", "a photo of a person with their eyes closed or blinking"),
    ("grimace", "a photo of a person grimacing or making an awkward face"),
    ("away", "a photo of the back or side of a person's head, face not visible"),
    ("object", "a photo of a lamp, a light fixture, a ceiling or an object; there is no person"),
    ("animal", "a close-up photo of a dog's or a cat's face"),
]


# A face this soft could not be read by anyone: no frame kept in 1,705 frames
# of four shoots had its readable face under it. The one absolute sharpness
# number that vetoes; everything softer than a shoot's own taste is a note.
UNREADABLE = 1.2
# The faults that veto a frame. Each transfers between shoots: its value is
# reproduced with any three of the four shoots and costs no keeper on the
# fourth (blink 0.5 with the smile gate, blown 0.35, dark L* 35, soft 1.2).
HARD_FACE_FLAGS = ("blink", "soft", "face in the dark", "blown face")
# The lines those faults are judged against. They live here, with flag(), and
# every other file reads them from here: cull.py restated all five as its own
# constants so that the doubt column could name them, and two copies of a
# threshold is how a threshold drifts.
BLINK_SHUT = 0.5        # eyes at least this shut, with no smile, is a blink
LAUGH_SMILE = 0.45      # a smile this wide makes shut eyes a laugh, not a blink
FACE_DARK_L = 35.0      # nothing above this on the face is a silhouette
BLOWN_FACE = 0.35       # this share of the skin at the clip point is a blown face
ANIMAL_GATE = 0.45      # CLIP this sure it is an animal, and the face may not veto
# A readable face this share of the largest face's area is a co-subject and
# its faults count; smaller, it is behind the subject and only noted.
CO_SUBJECT = 0.5


def verdict(mains: list) -> tuple[list[str], list[str]]:
    """The frame's faults and its notes, from its main faces.

    A fault vetoes only on the LARGEST readable face: judging a frame on its
    worst face is right for a posed couple and wrong for an action shoot, a field or
    a street, where the man behind the subject is blinking. A smaller face's
    fault becomes a note ("blink on a smaller face") that the studio shows.
    Returns (hard, flags): the vetoing faults, and every flag to record."""
    if not mains:
        return [], []
    readable = [fc for fc in mains if fc.read] or mains
    area = max(fc.box[2] * fc.box[3] for fc in readable)
    # A co-subject is a readable face at least half the area of the largest:
    # the second person of a posed couple, whose blink is the picture's
    # fault. A face smaller than that is behind the subject, and its fault
    # is a note.
    co = [fc for fc in readable if fc.box[2] * fc.box[3] >= CO_SUBJECT * area]
    hard: list[str] = []
    for fc in co:
        for fl in fc.flags:
            if fl in HARD_FACE_FLAGS and fl not in hard:
                hard.append(fl)
    flags = {fl for fc in co for fl in fc.flags}
    for fc in mains:
        if fc in co:
            continue
        for fl in fc.flags:
            flags.add(f"{fl} on a smaller face" if fl in HARD_FACE_FLAGS else fl)
    return hard, sorted(flags)


def kiss(big: list) -> None:
    """Two faces touching is a kiss or a cheek-to-cheek: shut eyes and an open
    mouth are the picture there, not a fault. Both faces trade those flags for
    "close faces", so the record says why they were let through.

    `big` is a frame's main faces, and it is sorted here in place from left to
    right, because that is the order the pairs are read in. The rule lives
    beside verdict() because three callers apply it - the cull, the evaluate
    harness and the fixture check - and three copies had already drifted: the
    fixture check stripped the two flags and added nothing, so a frame could
    pass there for a reason the cull would never have written.
    """
    big.sort(key=lambda fc: fc.box[0])
    for fa, fb in zip(big, big[1:]):
        ax, ay, aw, ah = fa.box
        bx, by, bw, bh = fb.box
        near = (abs((bx + bw / 2) - (ax + aw / 2)) < 1.15 * (aw + bw) / 2
                and abs((by + bh / 2) - (ay + ah / 2)) < 0.8 * (ah + bh) / 2)
        if not near:
            continue
        for fc in (fa, fb):
            if any(fl in fc.flags for fl in ("blink", "mid-word?")):
                fc.flags = [fl for fl in fc.flags if fl not in ("blink", "mid-word?")] + ["close faces"]


@dataclass
class Face:
    box: tuple            # x, y, w, h in decoded-image pixels
    conf: float
    frac: float           # width as a fraction of frame width
    main: bool = False
    sharp: float = 0.0    # eye-band sharpness, size-normalised
    motion: float = 1.0   # gradient anisotropy; ~1 isotropic, >2.5 smeared
    blink: float = 0.0    # 0 open .. 1 shut
    smile: float = 0.0
    jaw_open: float = 0.0
    squint: float = 0.0
    brow_down: float = 0.0
    pucker: float = 0.0
    cheek: float = 0.0
    in_animal: bool = False # the face sits inside a YOLOX dog or cat box; it may not veto
    read: bool = False    # landmarks found
    profile: bool = False  # turned away; the landmarker is frontal and will not read it
    eye_gap: float = 0.0   # distance between the eyes over face width; small means turned
    nose_off: float = 0.0  # nose off the eyes' midpoint, in eye-gaps; large means turned
    lum: float = 255.0    # face brightness on the camera rendering (see judge)
    blown: float = 0.0    # share of the inner face at the clip point on the camera rendering
    blown_raw: float = 0.0  # the same on the decode: the camera JPEG clips skin the RAW still holds
    top: float = 1.0      # face top as a fraction of frame height (0 = touching the top edge)
    gaze: float = 0.5     # 1 = eyes and head to the lens, 0 = looking well away; 0.5 when unread
    borderline: str = ""  # the call that was close, if any: "blink", "sharp", "motion", "blown"
    clip: dict = field(default_factory=dict)   # prompt label -> probability
    emb: np.ndarray | None = None
    person: int = -1      # identity cluster, filled in later
    flags: list = field(default_factory=list)
    score: float = 1.0    # 0..1, higher is better


def decode(raw_path: Path, out_jpg: Path, full: bool | None = None) -> np.ndarray | None:
    """libraw decode at the sensor's full resolution (or half), camera white
    balance, no auto-brighten. Cached as a JPEG next to the cull.

    `full` defaults to the module's FULL, read when the call is made and not
    when this file was imported. Binding it as a default argument meant
    `--decode half` set FULL after import and nothing ever saw it."""
    if out_jpg.exists():
        return cv2.imread(str(out_jpg))
    img = decode_to_file(raw_path, out_jpg, full)
    return img


def decode_to_file(raw_path: Path, out_jpg: Path, full: bool | None = None) -> np.ndarray | None:
    """The decode itself; safe to run in a worker process."""
    full = FULL if full is None else full
    try:
        import rawpy
        with rawpy.imread(str(raw_path)) as r:
            rgb = r.postprocess(half_size=not full, use_camera_wb=True, no_auto_bright=True, output_bps=8)
    except Exception:
        return None
    img = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
    if not full:
        h, w = img.shape[:2]
        s = DECODE_W / max(h, w)
        if s < 1:
            img = cv2.resize(img, (int(w * s), int(h * s)), interpolation=cv2.INTER_AREA)
    out_jpg.parent.mkdir(parents=True, exist_ok=True)
    # cv2.imwrite reports failure by returning False and in no other way. This
    # used to hand back the image regardless, so on a full volume the decode
    # existed only inside the worker that made it: the frame counted as
    # decoded, nothing was on disk, and every step after it read the 1616 px
    # camera preview instead. A decode that did not land is a failure. The
    # part-written file goes with it, because the only test anything makes
    # later is that a file of that name is there.
    # Written beside it and moved into place, the way common.write_atomic
    # writes every decision file: a name that exists is a whole file. Two
    # requests for the same frame that overlap (the viewer's prefetch and the
    # <img> a keypress later) used to write the same bytes over each other as
    # they landed, and a reader in between could get half of one.
    tmp = None
    try:
        # The temp name keeps the .jpg on the end: cv2.imwrite chooses its
        # encoder from the extension and refuses a name it cannot read one
        # from, which is a decode that fails on every frame.
        fd, name = tempfile.mkstemp(dir=str(out_jpg.parent), prefix=out_jpg.stem + ".", suffix=out_jpg.suffix)
        os.close(fd)
        tmp = Path(name)
        if not cv2.imwrite(str(tmp), img, [cv2.IMWRITE_JPEG_QUALITY, 92]):
            raise OSError(f"could not write {out_jpg}")
        os.replace(tmp, out_jpg)
        tmp = None
    except (OSError, ValueError):
        if tmp is not None:
            try:
                tmp.unlink()
            except OSError:
                pass
        return None
    return img


def _decode_job(args) -> tuple[str, bool]:
    """(the decode's path, whether it is on disk when this returns).

    Whether the file is there is the only thing the parent can act on: an
    image in a worker that has since exited is not a decode anyone can read.
    This used to answer with `is not None`, which was true of a frame whose
    write had failed, and the parent counted it as done."""
    raw, out, full = args
    if Path(out).exists():
        return out, True
    decode_to_file(Path(raw), Path(out), full)
    return out, Path(out).exists()


def decode_all(pairs: list[tuple[Path, Path]], workers: int = 4, progress=None, full: bool | None = None) -> int:
    """Decode many RAWs in parallel. pairs are (raw, out_jpg).

    Returns how many of `pairs` are on disk at the end, which is not the same
    as how many were attempted: the count used to come off the loop itself, so
    a run that wrote nothing still reported every frame decoded and the cull
    went on to measure faces on camera previews and call the shoot clean.

    The resolution is resolved here, in the parent, and travels in each job.
    A worker started by spawn imports this module fresh, so a FULL the caller
    set after import does not reach it."""
    from common import pool_map
    full = FULL if full is None else full
    todo = [(str(r), str(o), full) for r, o in pairs if not Path(o).exists()]
    done = len(pairs) - len(todo)
    if progress:
        progress(done, len(pairs))
    if not todo:
        return done
    lost: list[str] = []
    # The run's one pool (common.pool_map), not a second one of this stage's
    # own: the workers the focus and face stages will use are the workers that
    # decode, and they pay their imports once between them.
    for out, ok in pool_map(_decode_job, todo, workers=max(1, workers)):
        if not ok:
            lost.append(Path(out).name)
            continue
        done += 1
        if progress and (done % 5 == 0 or done == len(pairs)):
            progress(done, len(pairs))
    if lost:
        print(f"  WARNING: {len(lost)} of {len(pairs)} decodes did not land "
              f"({', '.join(sorted(lost)[:4])}{', ...' if len(lost) > 4 else ''}): a full volume does this. "
              f"Those frames have no full-resolution image, so whatever reads them next reads the "
              f"camera's preview at about a tenth of the pixels. Free some room and run the cull again.", flush=True)
        # The bar must not finish clean on a step that did not: the studio
        # draws the last mark it sees for a stage.
        if progress:
            progress(done, len(pairs))
    return done


class quiet_stderr:
    def __enter__(self):
        import sys
        sys.stderr.flush()
        self._saved = os.dup(2)
        self._null = os.open(os.devnull, os.O_WRONLY)
        os.dup2(self._null, 2)

    def __exit__(self, *exc):
        import sys
        sys.stderr.flush()
        os.dup2(self._saved, 2)
        os.close(self._saved)
        os.close(self._null)
        return False


class FaceJudge:
    def __init__(self, quality=None):
        self.det = cv2.FaceDetectorYN.create(str(YUNET), "", (320, 320), 0.6, 0.3, 5000) if YUNET.exists() else None
        self.rec = cv2.FaceRecognizerSF.create(str(SFACE), "") if SFACE.exists() else None
        self.quality = quality      # a quality.Quality, for CLIP
        self._lm = None
        self._text = None
        self.notes: list[str] = []

    # ------------------------------------------------------------ models

    def _landmarker(self):
        if self._lm is not None:
            return self._lm
        if not LANDMARKER.exists():
            return None
        try:
            with quiet_stderr():
                from mediapipe.tasks import python as mpp
                from mediapipe.tasks.python import vision
                opts = vision.FaceLandmarkerOptions(
                    base_options=mpp.BaseOptions(model_asset_path=str(LANDMARKER)),
                    output_face_blendshapes=True, num_faces=1, min_face_detection_confidence=0.3)
                self._lm = vision.FaceLandmarker.create_from_options(opts)
        except Exception as e:  # noqa: BLE001
            self.notes.append(f"landmarks off: {e}")
        return self._lm

    def _clip_text(self):
        if self._text is not None or self.quality is None or not self.quality._load_clip():
            return self._text
        import torch
        import open_clip
        tok = open_clip.get_tokenizer("ViT-L-14-quickgelu")
        with torch.no_grad():
            t = self.quality._clip.encode_text(tok([p for _, p in FACE_PROMPTS]).to(self.quality._dev))
            t = t / t.norm(dim=-1, keepdim=True)
        self._text = t.float().cpu().numpy()
        return self._text

    # ------------------------------------------------------------ per frame

    def detect(self, img: np.ndarray) -> list[Face]:
        if self.det is None:
            return []
        h, w = img.shape[:2]
        s = min(1.0, DETECT_W / w)
        small = cv2.resize(img, (int(w * s), int(h * s)), interpolation=cv2.INTER_AREA) if s < 1 else img
        faces: list[Face] = []

        def run(im, scale):
            self.det.setInputSize((im.shape[1], im.shape[0]))
            _, det = self.det.detect(im)
            for d in (det if det is not None else []):
                x, y, fw, fh = (float(v) / scale for v in d[:4])
                # Skip a detection that overlaps one we already have.
                dup = False
                for g in faces:
                    gx, gy, gw, gh = g.box
                    ix = max(0, min(x + fw, gx + gw) - max(x, gx))
                    iy = max(0, min(y + fh, gy + gh) - max(y, gy))
                    inter = ix * iy
                    if inter / (fw * fh + gw * gh - inter + 1e-6) > 0.4:
                        dup = True
                        break
                if dup:
                    continue
                f = Face(box=(x, y, fw, fh), conf=float(d[14]), frac=fw / w)
                f._row = d.copy()  # type: ignore[attr-defined]  # YuNet row (with landmarks) for SFace alignment
                f._row[:14] /= scale   # type: ignore[attr-defined]
                faces.append(f)

        run(small, s)
        # A face that fills the frame is larger than the detector's biggest
        # anchor at 1600 px; a second pass at 640 px catches it.
        for dw in (640, 320):
            s2 = dw / w
            run(cv2.resize(img, (dw, int(h * s2)), interpolation=cv2.INTER_AREA), s2)
        # A box mostly inside a larger face is a part of it (an eye, a nose),
        # not a second face. YuNet suppresses by IoU and a nested box can sit
        # under that: on TSC04354 her face read sharp at 4.0 and a box nested
        # inside it read soft and vetoed the frame. The passes run at three
        # sizes, so the larger face may arrive after the nested one; filter
        # once everything is in.
        keep = []
        for f in faces:
            x, y, fw, fh = f.box
            nested = False
            for g in faces:
                gx, gy, gw, gh = g.box
                if g is f or gw * gh <= fw * fh:
                    continue
                ix = max(0, min(x + fw, gx + gw) - max(x, gx))
                iy = max(0, min(y + fh, gy + gh) - max(y, gy))
                if ix * iy / (fw * fh + 1e-6) > 0.8:
                    nested = True
                    break
            if not nested:
                keep.append(f)
        faces = keep
        faces.sort(key=lambda f: -f.box[2] * f.box[3])
        unit = w / DECODE_W          # every pixel threshold is stated at the 2400 px reference width
        if faces:
            biggest = faces[0].frac
            for f in faces:
                f.main = f.box[2] >= MIN_JUDGE_PX * unit and (f.frac >= MAIN_FACE_FRAC or f.frac >= 0.6 * biggest)
        return faces

    def _animal_boxes(self, img: np.ndarray) -> list[tuple]:
        """YOLOX dog and cat boxes in decode coordinates. The cull passes its
        own; this is for the judge running alone, as in check_faces."""
        if not hasattr(self, "_subj"):
            from cull import SubjectDetector, SUBJECT_MODEL
            self._subj = SubjectDetector(SUBJECT_MODEL) if SUBJECT_MODEL.exists() else None
        if self._subj is None:
            return []
        h, w = img.shape[:2]
        k = 960 / w
        small = cv2.resize(img, (960, int(h * k)), interpolation=cv2.INTER_AREA)
        return [tuple(v / k for v in b) for b, c in self._subj.detect_classes(small) if c in (15, 16)]

    def judge(self, img: np.ndarray, faces: list[Face], render: np.ndarray | None = None,
              animal_boxes: list[tuple] | None = None, clip: bool = True) -> None:
        """`render` is the camera's own JPEG of the frame, if there is one;
        face brightness is read off that, since it is what the photographer
        sees, while the linear decode is what the blur metrics need."""
        h, w = img.shape[:2]
        if render is not None:
            k = render.shape[1] / w
            rl = cv2.cvtColor(render, cv2.COLOR_BGR2LAB)[..., 0]
            rv = render
            for f in faces:
                x, y, fw, fh = f.box
                sl = (slice(int((y + 0.2 * fh) * k), int((y + 0.85 * fh) * k)), slice(int((x + 0.2 * fw) * k), int((x + 0.8 * fw) * k)))
                if rl[sl].size:
                    # Reduce over the channels inside the face box, not over the
                    # whole frame: same numbers, a fraction of the work.
                    rvs = rv[sl].max(axis=2)
                    # P90 of L*, or of the strongest channel: a face under a
                    # red gel has almost no L* but plenty of red, and is fine.
                    f.lum = float(max(np.percentile(rl[sl], 90), 0.75 * np.percentile(rvs, 90)))
                    f.blown = float((rvs >= 250).mean())
        if animal_boxes is None:
            animal_boxes = self._animal_boxes(img)
        # This used to be img.max(axis=2) over the whole decode. On a 24
        # megapixel frame that is 141 ms, about a quarter of the entire cull,
        # and it was spent to fill one diagnostic number read on a few hundred
        # pixels per face. The reduction happens inside the face box now.
        for f in faces:
            f.top = float(f.box[1] / h)
            # YuNet returns right eye, left eye, nose, and the mouth corners.
            # A face turned away foreshortens the gap between the eyes and puts
            # the nose off their midpoint, which is the whole reason the
            # landmarker cannot read it: MediaPipe's model is frontal.
            row = getattr(f, "_row", None)
            if row is not None and len(row) >= 14:
                re_, le_ = np.array(row[4:6]), np.array(row[6:8])
                nose = np.array(row[8:10])
                gap = float(np.linalg.norm(re_ - le_))
                mid = (re_ + le_) / 2
                f.eye_gap = gap / max(f.box[2], 1e-6)
                f.nose_off = float(abs(nose[0] - mid[0])) / max(gap, 1e-6)
                f.profile = bool(f.eye_gap < 0.25 or f.nose_off > 1.0)
            cx, cy = f.box[0] + f.box[2] / 2, f.box[1] + f.box[3] / 2
            f.in_animal = any(bx <= cx <= bx + bw and by <= cy <= by + bh for bx, by, bw, bh in animal_boxes)
            x, y, fw, fh = f.box
            sd = (slice(int(y + 0.2 * fh), int(y + 0.85 * fh)), slice(int(x + 0.2 * fw), int(x + 0.8 * fw)))
            patch = img[sd]
            if patch.size:
                f.blown_raw = float((patch.max(axis=2) >= 250).mean())
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        lm = self._landmarker()
        crops = []
        for f in faces:
            x, y, fw, fh = f.box
            # A generous square crop for landmarks and CLIP.
            cx, cy, r = x + fw / 2, y + fh / 2, max(fw, fh) * 0.75
            x0, y0 = int(max(0, cx - r)), int(max(0, cy - r))
            x1, y1 = int(min(w, cx + r)), int(min(h, cy + r))
            crop = img[y0:y1, x0:x1]
            if crop.size == 0:
                crops.append(None)
                continue
            crops.append(crop)

            # Sharpness on the eye band. A fixed fraction of the face box is
            # right for a face looking at you and wrong for one turned away,
            # where it lands on a cheek: 66% of the faces on an action shoot
            # are in profile, and their measured sharpness was describing the
            # wrong pixels. YuNet reports where it found the eyes, so on a
            # profile the band is put there. On a frontal face the fixed band
            # stays, because it is what the 94-frame fixture was settled
            # against and moving it there changed four of those verdicts.
            row = getattr(f, "_row", None)
            if f.profile and row is not None and len(row) >= 10:
                re_, le_ = (float(row[4]), float(row[5])), (float(row[6]), float(row[7]))
                exs, eys = (re_[0], le_[0]), (re_[1], le_[1])
                pad = max(fw * 0.12, abs(exs[0] - exs[1]) * 0.35, 8.0)
                ex0, ex1 = int(min(exs) - pad), int(max(exs) + pad)
                ey0, ey1 = int(min(eys) - pad * 0.8), int(max(eys) + pad * 0.8)
            else:
                ex0, ex1 = int(x + fw * 0.15), int(x + fw * 0.85)
                ey0, ey1 = int(y + fh * 0.25), int(y + fh * 0.55)
            band = gray[max(0, ey0):min(h, ey1), max(0, ex0):min(w, ex1)]
            if band.size > 100:
                target = 160
                bs = target / max(band.shape)
                bandr = cv2.resize(band, (max(8, int(band.shape[1] * bs)), max(8, int(band.shape[0] * bs))), interpolation=cv2.INTER_AREA if bs < 1 else cv2.INTER_CUBIC)
                # Edge strength on the eye band against the band's own contrast:
                # the 95th percentile of gradient magnitude after a light
                # denoise, over the band's standard deviation. Noise raises the
                # denominator as well as the numerator, so a grainy ISO 12800
                # face is not mistaken for a sharp one, and a dark face is
                # judged on its detail rather than on how little light it got.
                bf = cv2.GaussianBlur(bandr.astype(np.float64), (0, 0), 1.0)
                gm = np.hypot(cv2.Sobel(bf, cv2.CV_64F, 1, 0), cv2.Sobel(bf, cv2.CV_64F, 0, 1))
                f.sharp = float(np.percentile(gm, 95) / (bandr.std() + 1e-6))
                # Structure tensor anisotropy over the face: motion blur kills
                # gradients along one axis and leaves the other.
                # Inner face only (eyes, nose, mouth), with saturated pixels
                # masked: a bright light tube beside a face is a strong edge
                # in one direction and looks exactly like motion blur otherwise.
                ix0, ix1 = int(x + fw * 0.2), int(x + fw * 0.8)
                iy0, iy1 = int(y + fh * 0.2), int(y + fh * 0.85)
                face_g = gray[max(0, iy0):min(h, iy1), max(0, ix0):min(w, ix1)].astype(np.float64)
                if face_g.size > 400:
                    ok = (face_g < 245) & (face_g > 8)
                    gx = np.abs(cv2.Sobel(face_g, cv2.CV_64F, 1, 0, ksize=3))[ok]
                    gy = np.abs(cv2.Sobel(face_g, cv2.CV_64F, 0, 1, ksize=3))[ok]
                    if gx.size > 100:
                        mx, my = float(np.mean(gx)) + 1e-6, float(np.mean(gy)) + 1e-6
                        f.motion = float(max(mx, my) / min(mx, my))

            # Landmarks and blendshapes.
            if lm is not None:
                try:
                    import mediapipe as mp
                    face_in = cv2.resize(crop, (384, 384), interpolation=cv2.INTER_AREA if crop.shape[0] > 384 else cv2.INTER_CUBIC)
                    rgb = cv2.cvtColor(face_in, cv2.COLOR_BGR2RGB)
                    with quiet_stderr():
                        res = lm.detect(mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb))
                    if res.face_blendshapes:
                        b = {c.category_name: c.score for c in res.face_blendshapes[0]}
                        f.read = True
                        f.blink = max(b.get("eyeBlinkLeft", 0), b.get("eyeBlinkRight", 0))
                        f.smile = max(b.get("mouthSmileLeft", 0), b.get("mouthSmileRight", 0))
                        f.jaw_open = b.get("jawOpen", 0)
                        f.squint = max(b.get("eyeSquintLeft", 0), b.get("eyeSquintRight", 0))
                        f.brow_down = max(b.get("browDownLeft", 0), b.get("browDownRight", 0))
                        f.pucker = max(b.get("mouthPucker", 0), b.get("mouthFunnel", 0))
                        f.cheek = b.get("cheekPuff", 0)
                        # Gaze: eye-direction blendshapes say where the eyes point relative
                        # to the head; the nose against the eye line says where the head
                        # points. Both near zero is a face looking down the lens.
                        eyes = max(b.get("eyeLookOutLeft", 0) + b.get("eyeLookInRight", 0),
                                   b.get("eyeLookInLeft", 0) + b.get("eyeLookOutRight", 0)) / 2
                        vert = max(b.get("eyeLookUpLeft", 0) + b.get("eyeLookUpRight", 0),
                                   b.get("eyeLookDownLeft", 0) + b.get("eyeLookDownRight", 0)) / 2
                        yaw = 0.0
                        try:
                            lm_pts = res.face_landmarks[0]
                            nose, le, re_ = lm_pts[1], lm_pts[33], lm_pts[263]
                            span = abs(re_.x - le.x) + 1e-6
                            yaw = abs(nose.x - (le.x + re_.x) / 2) / span   # 0 straight on, ~0.5 full profile
                        except Exception:  # noqa: BLE001
                            pass
                        f.gaze = float(max(0.0, 1.0 - 1.4 * eyes - 1.0 * vert - 1.6 * yaw))
                except Exception:  # noqa: BLE001
                    pass

            # Identity.
            if self.rec is not None:
                try:
                    aligned = self.rec.alignCrop(img, f._row)  # type: ignore[attr-defined]
                    e = self.rec.feature(aligned)
                    f.emb = (e / (np.linalg.norm(e) + 1e-9)).astype(np.float32).ravel()
                except Exception:  # noqa: BLE001
                    pass

        # CLIP on the face crops. With clip=False the crops ride along on the
        # faces and are judged later, across frames, in one pass (clip_faces):
        # a frame's two or three crops at a time leaves a GPU idle.
        if not clip:
            for f, c in zip(faces, crops):
                f._crop = c  # type: ignore[attr-defined]
            return
        text = self._clip_text()
        if text is not None and any(c is not None for c in crops):
            import torch
            from PIL import Image
            idx = [i for i, c in enumerate(crops) if c is not None]
            with torch.no_grad():
                x = torch.stack([self.quality._pre(Image.fromarray(cv2.cvtColor(crops[i], cv2.COLOR_BGR2RGB))) for i in idx]).to(self.quality._dev)
                e = self.quality._clip.encode_image(x)
                e = (e / e.norm(dim=-1, keepdim=True)).float().cpu().numpy()
            logits = (e @ text.T) * 100.0
            logits -= logits.max(axis=1, keepdims=True)
            p = np.exp(logits)
            p /= p.sum(axis=1, keepdims=True)
            for k, i in enumerate(idx):
                faces[i].clip = {lab: float(p[k, j]) for j, (lab, _) in enumerate(FACE_PROMPTS)}

    def clip_faces(self, faces: list[Face], batch: int = 96) -> None:
        """CLIP over the crops judge(clip=False) left on these faces, in large
        batches: the same prompts and the same arithmetic as judge(), once
        over a whole shoot instead of once per frame."""
        todo = [f for f in faces if getattr(f, "_crop", None) is not None]
        text = self._clip_text()
        if text is not None and todo:
            import torch
            from PIL import Image
            for s in range(0, len(todo), batch):
                part = todo[s:s + batch]
                with torch.no_grad():
                    x = torch.stack([self.quality._pre(Image.fromarray(cv2.cvtColor(f._crop, cv2.COLOR_BGR2RGB))) for f in part]).to(self.quality._dev)  # type: ignore[attr-defined]
                    e = self.quality._clip.encode_image(x)
                    e = (e / e.norm(dim=-1, keepdim=True)).float().cpu().numpy()
                logits = (e @ text.T) * 100.0
                logits -= logits.max(axis=1, keepdims=True)
                p = np.exp(logits)
                p /= p.sum(axis=1, keepdims=True)
                for k, f in enumerate(part):
                    f.clip = {lab: float(p[k, j]) for j, (lab, _) in enumerate(FACE_PROMPTS)}
        for f in faces:
            if hasattr(f, "_crop"):
                del f._crop  # type: ignore[attr-defined]

    # ------------------------------------------------------------ verdicts

    @staticmethod
    def flag(f: Face, sharp_floor: float) -> None:
        """Turn measurements into reasons a person would give.

        Two kinds. A FAULT vetoes the frame and transfers between shoots at
        no keeper cost on every one of four shoots held out in turn: a blink
        with no smile, skin at the clip point, nothing above L* 35, a face
        unreadably soft (under UNREADABLE; nothing kept in 1,705 frames was).
        A DIAGNOSIS, written with a question mark, orders the review and
        never bins: soft for a posed shoot but not for an action shoot (between
        UNREADABLE and sharp_floor), a mouth open (a shout, an effort),
        a smaller face's fault. Set on one kind of shoot those cost 43 of
        152 keepers on another; they are the photographer's tolerances.

        And one note that is neither, because it is not about the face: "no
        sharpness to judge", where the face carried too few pixels for the
        measurement to have been taken at all."""
        f.flags = []
        # A laugh shuts the eyes too. Shut eyes with a smile is a laugh and
        # stays; shut eyes with no smile is a blink and goes. Blink magnitude
        # cannot tell them apart (real blinks read 0.57 to 0.72, laughs 0.73
        # to 0.76 on the fixture), so only the smile decides: laughs read 0.47
        # and up, blinks 0.13 and under.
        if f.read and f.blink >= BLINK_SHUT and f.smile < LAUGH_SMILE:
            f.flags.append("blink")
        elif not f.read and f.clip.get("blink", 0) >= 0.7:
            f.flags.append("blink?")
        # judge() reads sharpness off the band across the eyes and wants a
        # hundred pixels of band; under that there is nothing to run a Sobel
        # over and f.sharp is left at the Face default. A face with no
        # sharpness is not a soft face. Calling it one binned chihuahua_184 of
        # the Oxford-IIIT Pet set - a dog's head 12 px wide on a 204 px image -
        # for a measurement nobody had taken, and that was the only frame in
        # all 3,671 annotated images of that set where an animal's face vetoed.
        if f.sharp <= 0.0:
            f.flags.append("no sharpness to judge")
        elif f.sharp < UNREADABLE:
            f.flags.append("soft")
        elif f.sharp < sharp_floor:
            f.flags.append("soft?")
        # Motion blur is stored (f.motion, the gradient anisotropy) and not
        # flagged: over 1,977 main faces on an action shoot it has a maximum
        # of 1.61 (median 1.03), so no threshold on it ever fired.
        # Without landmarks, CLIP is the only witness, so it has to be sure.
        # The 0.45 jaw gate is inert too: it fires on 10 of 2,542 main faces
        # across four shoots and turning it off leaves the fixture at 94/94.
        # Every mid-word verdict that matters is CLIP alone (all 6 fixture
        # mid-word frames and all 12 mid-word keeper losses on an action shoot
        # have jaw_open under 0.17), and CLIP's threshold cannot move: 0.65
        # breaks 4 fixture frames, 0.80 breaks 6. Scoping the flag off for
        # action shoots is a regression (465 review frames at .785 recall to
        # 537 at .713).
        # A mouth caught open is a diagnosis, never a veto: set from portraits
        # (0.5) it loses 43 of 152 readable-face keepers on an action shoot,
        # set from the action shoot (0.7) it fires on nothing. It stays as the
        # measurement, and the review order carries it.
        talk_thresh = 0.5 if f.read else 0.65
        if f.smile < 0.35 and f.clip.get("talking", 0) >= talk_thresh:
            f.flags.append("mid-word?")
        # If landmarks were read, the face is visible, whatever CLIP thinks.
        if not f.read and f.clip.get("away", 0) >= 0.7:
            f.flags.append("face away")
        # The detector fires on the odd lamp. No landmarks and CLIP says
        # object: not a face at all, and nothing about it counts.
        if not f.read and f.clip.get("object", 0) >= 0.4:
            f.flags = ["not a face"]
        # A face with nothing above 35 is a silhouette; there is no exposure
        # slider that brings it back. Under 65 it is dim.
        # What was close. The studio puts these in front of the photographer first.
        if f.read and 0.45 <= f.blink < 0.72 and f.smile < 0.5:
            f.borderline = "blink"
        elif f.read and UNREADABLE * 0.9 <= f.sharp <= UNREADABLE * 1.25:
            f.borderline = "sharp"
        elif f.read and 1.45 <= f.motion <= 1.75:
            f.borderline = "motion"
        elif 0.22 <= f.blown < BLOWN_FACE:
            f.borderline = "blown"
        if f.lum < FACE_DARK_L:
            f.flags.append("face in the dark")
        elif f.lum < 65:
            f.flags.append("dim face")
        # A face with a third of its skin at the clip point of the camera JPEG
        # has nothing left in the RAW either; under that it is hot, and the
        # RAW's extra stop may bring it back, so it is flagged, not thrown out.
        # Measured on a flash-lit night set: good frames read 0.00-0.07,
        # white faces 0.29-0.89.
        if f.blown >= BLOWN_FACE:
            f.flags.append("blown face")
        elif f.blown >= 0.10:
            f.flags.append("hot face")
        # The top of the head against the top edge of the frame.
        if f.top < 0.012:
            f.flags.append("head cut")
        # A soft 0..1 score for ranking among frames that pass.
        s = 1.0
        s *= 1.0 - 0.5 * max(0.0, f.blink - 0.15)
        s *= min(1.0, f.sharp / (sharp_floor * 1.3)) ** 0.5
        s *= 1.0 / (1.0 + max(0.0, f.motion - 1.3) * 1.5)
        s *= 1.0 - 0.5 * max(0.0, f.jaw_open - 0.3) * (1 - f.smile)
        s *= 0.8 + 0.2 * f.clip.get("good", 0.5)
        s *= 1.0 - 0.3 * f.clip.get("grimace", 0.0)
        s *= 1.0 + 0.1 * f.smile
        s *= min(1.0, f.lum / 60.0) ** 0.4     # dim is a look; only a silhouette is a fault
        s *= 1.0 - 0.6 * min(1.0, f.blown / BLOWN_FACE)
        if f.top < 0.012:
            s *= 0.85
        f.score = float(max(0.0, min(1.1, s)))
        # No landmarks means the landmarker did not see a frontal human face
        # here: a dog, a lamp, the back of a head, or a face turned away. None
        # of those may veto a frame, and that abstention is load-bearing.
        #
        # It was tried twice. Letting all the pixel-measured verdicts through
        # cost 10 of the 94 fixture frames. Moving the eye band onto the eyes
        # YuNet actually found first, so the sharpness describes the right
        # pixels, still cost 9: TSC04143, 04147, 04149, 04152 and 04144 are the
        # kiss frames in red light, 04362 is the dog held close, 03950, 03993
        # and 04169 are soft on purpose. The photographer keeps soft frames
        # when the moment is the picture, and a profile is exactly when that
        # happens. The abstention is protecting those, not failing to judge.
        # At full resolution the landmarker will read a dog's face as a face.
        # CLIP knows an animal when it sees one; that face may not veto either.
        # And CLIP misses some (a white dog held close read 0.08), so a face
        # sitting inside a YOLOX dog or cat box is an animal too.
        #
        # Barring a face by its size instead was tried and is wrong. Holding
        # every fault to MIN_JUDGE_PX as an absolute ("narrower than this and
        # nothing about it can be judged", which detect() scales to the frame)
        # costs nothing on his four shoots, where the narrowest main face in
        # 2,542 is 92 px, and it takes 189 of the 654 blinks the rule finds in
        # the 1,192 CEW closed-eye crops, whose faces run from 28 px up. Size
        # invalidates the measurement read off the eye band and not the ones
        # read off the landmarks, so it is the sharpness above that abstains.
        #
        # Every vetoing fault is turned into a question, not three of the four:
        # a face turned away in the dark kept its "face in the dark" veto
        # through an abstention that was meant to stop it, and a fifth fault
        # added to HARD_FACE_FLAGS would have slipped through the same gap.
        if not f.read or f.clip.get("animal", 0) >= ANIMAL_GATE or f.in_animal:
            f.flags = [fl + "?" if fl in HARD_FACE_FLAGS else fl for fl in f.flags]
            if f.clip.get("animal", 0) >= ANIMAL_GATE or f.in_animal:
                f.borderline = ""


def cluster_people(embs: list[np.ndarray], thresh: float = 0.363) -> list[int]:
    """Greedy identity clustering on SFace cosine similarity. 0.363 is OpenCV's
    recommended same-person threshold for this model."""
    ids = [-1] * len(embs)
    centroids: list[np.ndarray] = []
    for i, e in enumerate(embs):
        if e is None:
            continue
        best, bj = -1.0, -1
        for j, c in enumerate(centroids):
            s = float(e @ c)
            if s > best:
                best, bj = s, j
        if bj >= 0 and best >= thresh:
            ids[i] = bj
            centroids[bj] = centroids[bj] * 0.9 + e * 0.1
            centroids[bj] /= np.linalg.norm(centroids[bj]) + 1e-9
        else:
            ids[i] = len(centroids)
            centroids.append(e.copy())
    return ids


# ------------------------------------------------------ a frame per core
_WORKER_JUDGE: dict = {}


def judge_frame(job: tuple) -> tuple[int, list | None]:
    """(index, image or RAW path, decoded-JPEG path, preview path, animal boxes
    in detector coordinates, detector width) -> (index, judged faces without
    CLIP, their crops attached). Runs in a worker process with its own models."""
    i, path, dec_path, preview, animal_boxes, det_w = job
    if "j" not in _WORKER_JUDGE:
        cv2.setNumThreads(1)              # one frame per core
        _WORKER_JUDGE["j"] = FaceJudge()
    judge = _WORKER_JUDGE["j"]
    from common import RAW_EXTS
    p = Path(path)
    img = decode(p, Path(dec_path)) if p.suffix.lower() in RAW_EXTS else cv2.imread(path)
    if img is None:
        return i, None
    fs = judge.detect(img)
    k = img.shape[1] / det_w if det_w else 1.0
    judge.judge(img, fs, render=cv2.imread(preview) if preview else None,
                animal_boxes=[tuple(v * k for v in b) for b in animal_boxes], clip=False)
    return i, fs


def judge_frames(jobs: list[tuple], workers: int, progress=None) -> dict:
    """judge_frame over a shoot, a frame per core (common.pool_map)."""
    from common import pool_map
    return dict(pool_map(judge_frame, jobs, workers=workers, progress=progress))
