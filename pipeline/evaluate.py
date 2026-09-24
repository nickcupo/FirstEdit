#!/usr/bin/env python3
"""
evaluate.py - every measurement this machine can make about the cull, each with its n.

    ./pl evaluate                       # everything, then tests/eval.md
    ./pl evaluate --only recall,vetoes  # one section
    ./pl evaluate --pets 600 --cew 400  # smaller samples of the two big datasets
    ./pl evaluate --refresh             # ignore the measurement cache

Why this exists. Every threshold in the cull was set on four of the
photographer's own shoots, and that is how the old rules came to cost 33
keepers: a focus floor set on portraits, a mouth-open rule and a per-burst
quota, each sensible on the shoot it was written for and wrong on the next.
The instruction that produced this file was "use more data than just my 154
keepers", so the harness reports against everything on the machine and says
what each dataset can and cannot answer:

  1 RECALL         his chosen frames that survive the cull's vetoes, per shoot
  2 VETOES         which rule threw out each rejected frame; rules that never fire
  3 RANKING        within-burst pairwise and top-k per burst, beside the pooled AUC
  4 BLINK          recall against the CEW closed-eye crops; negatives from his frames
  5 ANIMAL GATE    Oxford-IIIT Pet: an animal face may never veto a frame
  6 FACE JUDGE     ./pl check against the verdicts settled by eye

Sections 1-3 are recomputed from pixels every time the measuring code
changes, never read out of a shoot's cull.csv. A cull.csv is the record of
whatever rules were in force the day it was written: the three older shoots'
files still carry "motion blur", "mid-word" and "softest in burst"
rejections, which no rule shipping today can produce. An instrument that
reported those would be reporting history.

Nothing here writes inside ~/photos. The measurements are cached under
~/.cache/first-edit/evaluate (PIPELINE_EVAL_CACHE; ~/.cache/photo-pipeline/
evaluate where an earlier run left one), keyed by the frame and by the
source of the code that measures it, so changing a RULE re-runs the verdicts
in seconds while changing a MEASUREMENT re-measures.
"""

from __future__ import annotations

import argparse
import hashlib
import inspect
import json
import os
import random
import re
import subprocess
import sys
import time
from datetime import date
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import cull as cmod  # noqa: E402
from common import decision_path  # noqa: E402
REPO = HERE.parent
PHOTOS = Path(os.environ.get("PHOTOS_ROOT", Path.home() / "photos")).expanduser()
OUT = REPO / "tests" / "eval.md"


def eval_cache() -> Path:
    """PIPELINE_EVAL_CACHE, else ~/.cache/first-edit/evaluate if it is there,
    else ~/.cache/photo-pipeline/evaluate if a run before the rename left
    one (read where it is rather than measured again; nothing is moved),
    else the new name."""
    env = os.environ.get("PIPELINE_EVAL_CACHE")
    if env:
        return Path(env).expanduser()
    cands = [Path.home() / ".cache" / n / "evaluate" for n in ("first-edit", "photo-pipeline")]
    return next((c for c in cands if c.is_dir()), cands[0])


CACHE = eval_cache()
PETS_DIR = Path(os.environ.get("PETS_DIR", PHOTOS / "datasets" / "oxford-pets")).expanduser()
CEW_DIR = Path(os.environ.get("CEW_DIR", PHOTOS / "datasets" / "cew")).expanduser()

# The cull's shipped defaults, read from the cull rather than restated. This
# harness applies the veto chain itself rather than running the cull (a cull
# rewrites cull.csv in the photographer's shoot folder, and this must never
# touch one), so every line it judges against has to come from the file that
# judges against it, or the report is about a tool nobody is using.
DARK_FLOOR = cmod.DARK_FLOOR
BURST_FLOOR = cmod.BURST_FLOOR      # --burst-floor, off unless asked for
BURST_GAP = cmod.BURST_GAP
CLIP_HI_FLOOR = cmod.CLIP_HI_FLOOR

# Every rule in the cull that can throw a frame out, in the order cull.py
# applies them, with the reason string it writes. Listed rather than
# discovered, so that a rule which fires on nothing still gets a row: a rule
# that never fires on 1,705 frames is dead weight and the reader should see
# it. Two are already in that state under the shipped defaults, and the table
# says so instead of leaving them out.
VETO_RULES: list[tuple[str, str]] = [
    ("no preview", "stage 1: nothing to measure; no decode and no camera JPEG"),
    ("blown highlights", f"stage 1: clipped share of the camera JPEG over {CLIP_HI_FLOOR}"),
    ("too dark", f"stage 1: mean brightness under --dark-floor {DARK_FLOOR:.0f} and no face or body found"),
    ("softest in burst", "stage 1: sharp_rel under --burst-floor, which ships at 0.0 (off)"),
    ("blink", "stage 1.5: eyes shut with no smile, on the largest readable face or a co-subject"),
    ("soft", "stage 1.5: a readable face under faces.UNREADABLE (1.2)"),
    ("face in the dark", "stage 1.5: nothing on the face above L* 35"),
    ("blown face", "stage 1.5: a third of the skin at the clip point"),
    ("soft for this person", "stage 1.5: under half their own sharpest frame in the same burst"),
]

# The per-frame numbers section 3 ranks on. Each is a measurement the cull
# already makes; none of them is fitted here. "higher is better" is fixed in
# advance for all of them, so a number under 0.5 means the measurement puts
# his keepers last, and it is printed that way rather than flipped.
RANK_FEATURES: list[tuple[str, str]] = [
    ("face score", "the face judge's 0..1 score for the worst main face"),
    ("focus", "stage 1 focus on the subject box"),
    ("focus vs burst", "that focus over the sharpest frame of the same burst"),
    ("gaze", "the worst main face's gaze to the lens"),
    ("lead face width", "the largest face's width as a share of the frame"),
    ("lead face read", "1 when the landmarker read the largest face"),
    ("frame brightness", "mean luma of the camera JPEG"),
    ("level", "minus the tilt in degrees off level"),
]


# ------------------------------------------------------------------ cache


def _fingerprint() -> str:
    """A hash of the code that MEASURES a frame, not of the code that judges it.

    The split is the whole point of the cache. A change to flag(), verdict()
    or the veto chain is a change to a rule: the cached measurements still
    describe the pixels, and the verdicts are re-derived from them in
    seconds. A change to the detector, the landmarker pass or the focus
    metric is a change to what was measured, and every frame is read again.
    The named constants are in here too, because moving FACE_CONF changes
    what is measured without changing a line of any function below.
    """
    import faces as fmod
    parts: list[str] = []
    for fn in (cmod.focus_frame, cmod.analyse, cmod.exposure, cmod.focus_score,
               cmod.detector_image, cmod.tilt_degrees, cmod.face_crop, cmod.rel_within,
               cmod.SubjectDetector.detect_classes, cmod.SubjectDetector.detect,
               fmod.FaceJudge.detect, fmod.FaceJudge.judge, fmod.FaceJudge.clip_faces,
               fmod.FaceJudge._animal_boxes, fmod.judge_frame, fmod.cluster_people):
        try:
            parts.append(inspect.getsource(fn))
        except OSError:  # pragma: no cover - source always present in a checkout
            parts.append(repr(fn))
    for mod, names in ((cmod, ("DETECT_W", "FACE_CONF", "FACE_PAD", "MIN_FACE_PX", "CROP_PX",
                               "SUBJ_SIZE", "SUBJ_CONF", "SUBJECT_CLASSES")),
                       (fmod, ("DECODE_W", "DETECT_W", "MAIN_FACE_FRAC", "MIN_JUDGE_PX", "FACE_PROMPTS"))):
        parts += [f"{mod.__name__}.{n}={getattr(mod, n, None)!r}" for n in names]
    return hashlib.sha256("\n".join(parts).encode()).hexdigest()[:16]


def _stamp(p: Path) -> str:
    st = p.stat()
    return f"{st.st_size}:{int(st.st_mtime)}"


def _cache_key(shoot: Path) -> str:
    """A cache name that says which library the shoot is in.

    The cache used to be keyed by the folder's name alone, so a scratch clone
    of 2026-09-16 and the real one shared a file: a run against a clone made
    to prove a change was safe could be answered out of measurements of his
    own library, and the other way about. The path under PHOTOS is the key,
    and the root is written into the file as well, so a cache from another
    root is ignored rather than trusted."""
    try:
        rel = shoot.resolve().relative_to(PHOTOS.resolve())
    except ValueError:
        rel = Path(shoot.name)
    return str(rel).replace("/", "_")


def _cache_load(name: str, fp: str) -> dict:
    f = CACHE / f"{name}.json"
    if not f.exists():
        return {}
    try:
        d = json.loads(f.read_text())
    except Exception:  # noqa: BLE001
        return {}
    if d.get("root") not in (None, str(PHOTOS.resolve())):
        return {}
    return d.get("frames", {}) if d.get("fingerprint") == fp else {}


def _cache_save(name: str, fp: str, frames: dict) -> None:
    CACHE.mkdir(parents=True, exist_ok=True)
    tmp = CACHE / f"{name}.json.tmp"
    tmp.write_text(json.dumps({"fingerprint": fp, "root": str(PHOTOS.resolve()),
                               "written": date.today().isoformat(), "frames": frames}))
    os.replace(tmp, CACHE / f"{name}.json")


def _said(p: Path) -> str:
    """A path as it goes into the report: under $PHOTOS_ROOT where it is in
    the library, so the file that ships in the repo carries no home folder."""
    try:
        return "$PHOTOS_ROOT/" + str(Path(p).resolve().relative_to(PHOTOS.resolve()))
    except ValueError:
        return str(p)


def _face_to_dict(fc) -> dict:
    from dataclasses import fields as dc_fields
    d = {}
    for f in dc_fields(fc):
        v = getattr(fc, f.name)
        if f.name == "emb":
            d[f.name] = None if v is None else [round(float(x), 6) for x in v]
        elif isinstance(v, tuple):
            d[f.name] = [float(x) for x in v]
        elif isinstance(v, (int, float, str, bool, list, dict)) or v is None:
            d[f.name] = v
    return d


def _face_from_dict(d: dict):
    import faces as fmod
    fc = fmod.Face(box=tuple(d["box"]), conf=d["conf"], frac=d["frac"])
    for k, v in d.items():
        if k in ("box", "conf", "frac"):
            continue
        setattr(fc, k, np.array(v, dtype=np.float32) if k == "emb" and v is not None else v)
    return fc


# ------------------------------------------------------------------ shoots


def shoots() -> list[Path]:
    """Every shoot with an answer key: selects.json is the list of frames the
    photographer kept, exported and published.

    Asked through decision_path, so the answer key is found in decisions/
    wherever `pl migrate` has put it. This line is the one that decides
    whether a shoot is benched at all: reading the old cull/ name directly
    would not cost a file if the compatibility symlink went, it would drop a
    whole shoot out of every measurement in this report, silently and with
    every remaining number still looking right."""
    root = PHOTOS / "shoots"
    if not root.is_dir():
        return []
    return sorted(p for p in root.iterdir() if p.is_dir() and decision_path(p / "cull", "selects.json").exists())


def shoot_meta(shoot: Path) -> dict:
    try:
        return json.loads((shoot / "shoot.json").read_text())
    except Exception:  # noqa: BLE001
        return {}


def measure(shoot: Path, workers: int, refresh: bool, log=print) -> tuple[list, dict, str]:
    """Stage 1 and stage 1.5 over a shoot, from the cached decodes and the
    camera previews the cull left behind.

    Every shoot is measured the same way, off cull/decoded and cull/previews,
    and never off raw/. The lounge has no choice - its RAWs were cleared by
    hand and six remain - and measuring the other three the same way means the
    four numbers are comparable and no RAW is decoded again. It is also the
    path the fixture check already runs on, so the verdicts here are the ones
    tests/faces_truth.json was settled against.

    Returns (frames, judged faces by frame index, a sentence naming the source).
    """
    import faces as fmod
    from common import pool_map

    cull = shoot / "cull"
    dec_dir, prev_dir = cull / "decoded", cull / "previews"
    stems = sorted(p.stem for p in dec_dir.glob("*.jpg") if not p.name.endswith(".preview.jpg"))
    if not stems:
        return [], {}, "no cached decodes"
    raw_dir = shoot / "raw"

    # Capture time comes off the RAW while the RAW is still there. Once a
    # shoot is archived, raw/ holds .dop sidecars and nothing else, and this
    # harness then scored the one shoot with real bursts - 1,157 frames in
    # 89 of them - as 1,157 bursts of one, which silently zeroes every rule
    # that compares a frame with its burst mates and made the ranking row for
    # that shoot in tests/bench.md unreproducible. The shoot's own cull.csv
    # carries the time each frame was taken, read off those RAWs while they
    # were here, so it is the second source. Whole seconds: shot_at has no
    # subsecond field, so two frames inside one second keep file order.
    meta: dict = {}
    # By stem and any RAW extension, not by ".ARW": the pipeline takes eight
    # raw formats and a Canon shoot must not silently lose its burst structure
    # and be scored as 1,157 bursts of one.
    raw_of = {p.stem: p for p in sorted(raw_dir.iterdir()) if p.suffix.lower() in cmod.RAW_EXTS} if raw_dir.is_dir() else {}
    raws = [raw_of[s] for s in stems if s in raw_of]
    if len(raws) >= max(1, len(stems) // 2):
        meta = cmod.read_metadata(raws)
    times = "capture time from the RAW EXIF"
    if not meta:
        by_stem = {}
        try:
            import csv as csvmod
            for r in csvmod.DictReader((cull / "cull.csv").read_text().splitlines()):
                if r.get("shot_at"):
                    by_stem[Path(r["file"]).stem] = r["shot_at"]
        except (OSError, ValueError, KeyError):
            by_stem = {}
        got = [s for s in stems if by_stem.get(s)]
        if len(got) >= max(1, len(stems) // 2):
            meta = {f"{s}.jpg": {"DateTimeOriginal": by_stem[s]} for s in got}
            times = f"no RAW on disk; capture time for {len(got)} of {len(stems)} frames from cull.csv, to whole seconds"
        else:
            times = "no capture time survives, so every frame is its own burst"

    fp = _fingerprint()
    key = _cache_key(shoot)
    cached = {} if refresh else _cache_load(key, fp)
    want = [s for s in stems if cached.get(s, {}).get("stamp") != _stamp(dec_dir / f"{s}.jpg")]
    if want:
        log(f"  {shoot.name}: measuring {len(want)} of {len(stems)} frames ({len(stems) - len(want)} cached)")
        jobs = [(i, str(prev_dir / f"{s}.jpg"), str(dec_dir / f"{s}.jpg"), True) for i, s in enumerate(want, 1)]
        t0 = time.time()
        first = dict(pool_map(cmod.focus_frame, jobs, workers=workers,
                              progress=lambda d, n: log(f"    focus {d}/{n}") if d % 200 == 0 else None))
        jobs2 = [(i, str(dec_dir / f"{s}.jpg"), str(dec_dir / f"{s}.jpg"), str(prev_dir / f"{s}.jpg"),
                  [tuple(b) for b in first[i]["animal_boxes"]], first[i]["det_size"][0])
                 for i, s in enumerate(want, 1) if first.get(i)]
        judged = fmod.judge_frames(jobs2, workers=workers,
                                   progress=lambda d, n: log(f"    faces {d}/{n}") if d % 200 == 0 else None)
        from quality import Quality
        fmod.FaceJudge(quality=Quality()).clip_faces([fc for fs in judged.values() if fs for fc in fs])
        for i, s in enumerate(want, 1):
            got = first.get(i)
            cached[s] = {"stamp": _stamp(dec_dir / f"{s}.jpg"), "first": None if got is None else
                         {k: (list(v) if isinstance(v, tuple) else
                              [list(b) for b in v] if k == "animal_boxes" else v) for k, v in got.items()},
                         "faces": [_face_to_dict(fc) for fc in (judged.get(i) or [])]}
        _cache_save(key, fp, cached)
        log(f"  {shoot.name}: {len(want)} frames measured in {(time.time() - t0) / 60:.1f} min")

    frames, judged = [], {}
    for i, s in enumerate(stems, 1):
        c = cached[s]
        fr = cmod.Frame(path=raw_of.get(s) or (dec_dir / f"{s}.jpg"))
        got = c["first"]
        if got is None:
            fr.reason = "no preview"
            frames.append(fr)
            continue
        fr.det_size = tuple(got["det_size"])
        fr.animal_boxes = got["animal_boxes"]
        fr.sharp, fr.faces, fr.method = got["sharp"], got["faces"], got["method"]
        fr.box, fr.face_box = got["box"], got["face_box"]
        fr.tilt, fr.mean_luma, fr.clip_hi = got["tilt"], got["mean_luma"], got["clip_hi"]
        if 1.5 <= abs(fr.tilt) <= 8:
            fr.face_flags = "tilt?"
        m = meta.get(fr.path.name) or meta.get(f"{s}.jpg") or {}
        fr.shot_at = str(m.get("DateTimeOriginal") or "")
        fr.seq = cmod.seq_key(m) if meta else 0.0
        fr.camera_rating = int(m.get("Rating") or 0)
        frames.append(fr)
        judged[i] = [_face_from_dict(d) for d in c["faces"]]

    scored = [f for f in frames if f.sharp > 0]
    burst, prev = 0, None
    for f in sorted(scored, key=lambda x: x.seq):
        if prev is not None and (f.seq == 0 or (f.seq - prev) > BURST_GAP):
            burst += 1
        f.burst, prev = burst, f.seq
    cmod.rel_within(scored)
    w, h = (0, 0)
    try:
        import cv2
        im = cv2.imread(str(dec_dir / f"{stems[0]}.jpg"))
        h, w = im.shape[:2]
    except Exception:  # noqa: BLE001
        pass
    src = f"{len(stems)} cached decodes at {w}x{h} with the camera previews beside them; {times}"
    return frames, judged, src


def apply_vetoes(frames: list, judged: dict, face_floor: float) -> None:
    """The cull's veto chain, in the order cull.py applies it.

    It is re-expressed here and not imported because cull.py holds it inline
    in main(), between writing picks/ and writing cull.csv, and running that
    would rewrite the cull.csv the photographer works from. The harness
    therefore has to be checked against the cull rather than assumed equal to
    it: `--only vetoes` prints the per-frame reason for every rejection so a
    disagreement with a fresh `./pl cull` is visible frame by frame.

    Anything the chain calls is imported from cull.py rather than copied, so
    that a second copy cannot go quietly out of date: this copy was still
    clustering identities with faces.cluster_people, and still reprieving
    "soft duplicate", after cull.py had stopped doing both. A harness that
    measures a rule the tool no longer has is worse than no harness.
    """
    import faces as fmod
    from cull import FOCUS_ELSEWHERE

    scored = [f for f in frames if f.sharp > 0]
    for f in scored:
        if f.clip_hi > CLIP_HI_FLOOR:
            f.rejected, f.reason = True, "blown highlights"
        elif f.mean_luma < DARK_FLOOR and f.method == "center":
            f.rejected, f.reason = True, "too dark"
        elif BURST_FLOOR > 0 and f.sharp_rel < BURST_FLOOR:
            f.rejected, f.reason = True, "softest in burst"

    allfaces: list = []
    for i, fr in enumerate(frames, 1):
        fs = judged.get(i)
        if fs is None:
            continue
        for fc in fs:
            fmod.FaceJudge.flag(fc, face_floor)
            allfaces.append((fr, fc))
        fs = [fc for fc in fs if "not a face" not in fc.flags]
        fr.face_n = len(fs)
        big = [fc for fc in fs if fc.main]
        fmod.kiss(big)
        mains = [fc for fc in big if "face away" not in fc.flags]
        if not mains:
            fr.face_score = 0.45 if fr.method in ("face", "subject") else 0.6
            continue
        worst = min(mains, key=lambda fc: fc.score)
        fr.face_score = worst.score
        fr.gaze = float(min(fc.gaze for fc in mains))
        fr.borderline = next((fc.borderline for fc in mains if fc.borderline), "")
        hard, flags = fmod.verdict(mains)
        lead = max([fc for fc in mains if fc.read] or mains, key=lambda fc: fc.box[2] * fc.box[3])
        fr.lead_read, fr.lead_frac = float(lead.read), float(lead.frac)
        elsewhere = fr.method != "face" and fr.sharp_peers >= 2 and fr.sharp_rel >= FOCUS_ELSEWHERE
        if "soft" in hard and elsewhere:
            hard.remove("soft")
            flags = sorted((set(flags) - {"soft"}) | {"face soft, focus elsewhere"})
        elif "soft?" in flags and elsewhere:
            flags = sorted((set(flags) - {"soft?"}) | {"face soft, focus elsewhere"})
        # Merged, not replaced, exactly as cull.py does it: stage 1 wrote
        # "tilt?" into this field and assigning over it dropped that note.
        fr.face_flags = "; ".join(sorted(set(flags) | {fl for fl in fr.face_flags.split("; ") if fl}))
        if hard and not fr.rejected:
            fr.rejected, fr.reason = True, hard[0]
        if fr.rejected and fr.reason == "softest in burst" and not hard \
                and any(fc.read and fc.sharp >= fmod.UNREADABLE for fc in mains):
            fr.rejected, fr.reason = False, ""

    ids = cmod.people_clusters([fc.emb for _, fc in allfaces])
    for (fr, fc), pid in zip(allfaces, ids):
        fc.person = pid
    best: dict = {}
    lead_of: dict = {}
    frames_of: dict = {}
    for fr, fc in allfaces:
        if fc.main and fc.read and fc.person >= 0 and fr.burst >= 0 and not fc.in_animal:
            key = (fr.burst, fc.person)
            if not fr.rejected:
                best[key] = max(best.get(key, 0.0), fc.sharp)
            frames_of.setdefault(key, set()).add(id(fr))
            cur = lead_of.get(id(fr))
            if cur is None or fc.box[2] * fc.box[3] > cur.box[2] * cur.box[3]:
                lead_of[id(fr)] = fc
    count = {k: len(v) for k, v in frames_of.items()}
    for fr in scored:
        fc = lead_of.get(id(fr))
        if fc is None or fr.rejected or (fr.method != "face" and fr.sharp_peers >= 2 and fr.sharp_rel >= FOCUS_ELSEWHERE):
            continue
        key = (fr.burst, fc.person)
        if count.get(key, 0) >= 2 and best.get(key, 0) > 0 and fc.sharp < 0.5 * best[key]:
            fr.rejected, fr.reason = True, "soft for this person"
    # A star set on the camera in playback is his verdict from the moment the
    # frame was shot, and the cull keeps such a frame whatever the rules say
    # (cull.py, after the person rule). The harness did not, so a frame the
    # cull would show could be counted here as lost, or a rule credited with
    # a rejection the cull never made. The cull's other override, --keep, is
    # an argument of one run and has no place in a harness.
    for fr in scored:
        if fr.camera_rating >= 1 and fr.rejected:
            fr.rejected, fr.reason = False, "kept by hand"


# ------------------------------------------------------------------ statistics


def _avg_rank(x: np.ndarray) -> np.ndarray:
    order = np.argsort(x, kind="mergesort")
    r = np.empty(len(x), float)
    r[order] = np.arange(1, len(x) + 1, dtype=float)
    s = x[order]
    i = 0
    while i < len(s):
        j = i
        while j + 1 < len(s) and s[j + 1] == s[i]:
            j += 1
        if j > i:
            r[order[i:j + 1]] = (i + j + 2) / 2
        i = j + 1
    return r


def auc(score: np.ndarray, keep: np.ndarray) -> float:
    n1, n0 = int(keep.sum()), int((~keep).sum())
    if n1 == 0 or n0 == 0:
        return float("nan")
    r = _avg_rank(np.asarray(score, float))
    return float((r[keep].sum() - n1 * (n1 + 1) / 2) / (n1 * n0))


def within_burst(score: np.ndarray, keep: np.ndarray, burst: np.ndarray) -> tuple[float, int]:
    """Pairwise accuracy inside a burst: over every (kept, not kept) pair of
    the same burst, how often the kept frame scores higher. Ties count a half.

    The pooled keep/reject AUC is confounded and this is the repair. He keeps
    about 1.8 frames of a burst, so whether a frame carries a keep label
    depends on which burst it landed in as much as on the frame: a good frame
    in a burst of 50 is a reject and a middling one shot alone is a keeper.
    Inside one burst that confound is gone, because every frame in the pair
    had the same chance."""
    good = total = 0.0
    for b in np.unique(burst):
        m = burst == b
        s, k = score[m], keep[m]
        if not k.any() or k.all():
            continue
        pos, neg = s[k], s[~k]
        d = pos[:, None] - neg[None, :]
        good += float((d > 0).sum() + 0.5 * (d == 0).sum())
        total += d.size
    return (good / total if total else float("nan")), int(total)


def topk_per_burst(score: np.ndarray, keep: np.ndarray, burst: np.ndarray) -> tuple[float, float, int]:
    """Top-k recall per burst, k = the number kept from that burst. Returns
    (recall, what chance gives, keepers counted)."""
    hit = chance = kept = 0.0
    for b in np.unique(burst):
        m = burst == b
        s, k = score[m], keep[m]
        n, kk = len(s), int(k.sum())
        if kk == 0 or kk == n:
            continue
        top = np.argsort(-s, kind="mergesort")[:kk]
        hit += float(k[top].sum())
        chance += kk * kk / n
        kept += kk
    return (hit / kept if kept else float("nan")), (chance / kept if kept else float("nan")), int(kept)


def permute(fn, score, keep, burst, rounds: int, seed: int = 0) -> tuple[float, float]:
    """The same statistic with his labels shuffled inside each burst, so the
    burst sizes and the number kept per burst stay exactly as they are and
    only which frame he chose is randomised. Returns (null mean, p).

    p is (shuffles at least as far from 0.5 as the real number, plus one)
    over (rounds plus one). The plus one is not a rounding: a statistic that
    beat all 200 shuffles has not been shown to have p = 0, only that p is
    under 1 in 201, and printing 0.000 claims a certainty 200 shuffles
    cannot buy. pct_p() below prints the floor as "<0.005" for the same
    reason. The null spread was computed here as well and thrown away by
    both callers; it is not computed any more."""
    obs = fn(score, keep, burst)[0]
    rng = random.Random(seed)
    null = []
    idx_by_burst = [np.flatnonzero(burst == b) for b in np.unique(burst)]
    for _ in range(rounds):
        sh = keep.copy()
        for idx in idx_by_burst:
            v = list(keep[idx])
            rng.shuffle(v)
            sh[idx] = v
        null.append(fn(score, sh, burst)[0])
    a = np.array([v for v in null if not np.isnan(v)])
    if not len(a) or np.isnan(obs):
        return float("nan"), float("nan")
    p = float((int((np.abs(a - 0.5) >= abs(obs - 0.5)).sum()) + 1) / (len(a) + 1))
    return float(a.mean()), p


def logistic_loso(rows: list[dict], names: list[str], rounds: int) -> list[dict]:
    """A logistic on the per-frame measurements, held out by SHOOT, never by
    frame. Held out by frame it would be learning the burst it came from.

    Plain gradient descent on standardised features, numpy only: sklearn is
    on this machine but is not in requirements.txt, and a harness that only
    runs on one laptop is not a harness."""
    out = []
    shoot_names = sorted({r["shoot"] for r in rows})
    for held in shoot_names:
        tr = [r for r in rows if r["shoot"] != held]
        te = [r for r in rows if r["shoot"] == held]
        X = np.array([[r[n] for n in names] for r in tr], float)
        y = np.array([r["keep"] for r in tr], float)
        if not len(te) or y.sum() < 5:
            continue
        mu, sd = X.mean(0), X.std(0) + 1e-9
        Xs = (X - mu) / sd
        w, b = np.zeros(len(names)), 0.0
        for _ in range(4000):
            p = 1 / (1 + np.exp(-(Xs @ w + b)))
            g = Xs.T @ (p - y) / len(y) + 1e-3 * w
            w -= 0.5 * g
            b -= 0.5 * float((p - y).mean())
        Xt = (np.array([[r[n] for n in names] for r in te], float) - mu) / sd
        s = Xt @ w + b
        keep = np.array([r["keep"] for r in te], bool)
        burst = np.array([r["burst"] for r in te])
        acc, pairs = within_burst(s, keep, burst)
        rec, ch, nk = topk_per_burst(s, keep, burst)
        nm, p = permute(within_burst, s, keep, burst, rounds)
        out.append({"shoot": held, "n": len(te), "keepers": int(keep.sum()), "auc": auc(s, keep),
                    "pairwise": acc, "pairs": pairs, "topk": rec, "chance": ch, "keptk": nk,
                    "null": nm, "p": p})
    return out


# ------------------------------------------------------------------ sections


def section_shoots(args, log) -> dict:
    """Sections 1, 2 and 3: recall, veto attribution and ranking, per shoot."""
    res: dict = {"shoots": [], "rows": []}
    for shoot in shoots():
        meta = shoot_meta(shoot)
        label = meta.get("label") or shoot.name
        chosen = set(Path(c).stem for c in json.loads(decision_path(shoot / "cull", "selects.json").read_text()))
        frames, judged, src = measure(shoot, args.workers, args.refresh, log)
        if not frames:
            res["shoots"].append({"shoot": label, "note": f"{shoot.name}: no cached decodes; nothing can be measured here"})
            continue
        apply_vetoes(frames, judged, float(meta.get("focus") or 1.9))
        keepers = [f for f in frames if f.path.stem in chosen]
        lost = [f for f in keepers if f.rejected]
        by_rule: dict[str, list] = {}
        for f in frames:
            if f.rejected or f.reason == "no preview":
                by_rule.setdefault(f.reason, []).append(f)
        res["shoots"].append({
            "shoot": label, "dir": shoot.name, "frames": len(frames), "chosen": len(chosen),
            "measured": len(keepers), "survive": len(keepers) - len(lost), "source": src,
            "chosen_stems": chosen, "bursts_known": "every frame is its own burst" not in src,
            "by_hand": sum(1 for f in frames if f.camera_rating >= 1),
            "lost": [(f.path.name, f.reason) for f in lost],
            "rules": {k: (len(v), sum(1 for f in v if f.path.stem in chosen)) for k, v in by_rule.items()},
            "rejected": sorted((f.path.name, f.reason) for f in frames if f.rejected),
            "bursts": len({f.burst for f in frames if f.sharp > 0}),
            "stems": {f.path.stem for f in frames},
        })
        for f in frames:
            if f.sharp <= 0:
                continue
            res["rows"].append({
                "shoot": label, "file": f.path.name, "burst": f"{label}/{f.burst}",
                "keep": f.path.stem in chosen, "rejected": f.rejected, "reason": f.reason,
                "face score": f.face_score, "focus": f.sharp, "focus vs burst": f.sharp_rel,
                "gaze": f.gaze, "lead face width": f.lead_frac, "lead face read": f.lead_read,
                "frame brightness": f.mean_luma, "level": -abs(f.tilt),
            })
    return res


def section_blink(args, rows: list[dict], log) -> dict:
    """Blink recall against the CEW closed-eye crops, with the open-eye half
    taken from his own frames because this copy of CEW has none."""
    import cv2
    import faces as fmod
    from quality import Quality

    folder = next((p for p in (CEW_DIR, *sorted(q for q in CEW_DIR.glob("*") if q.is_dir()))
                   if p.is_dir() and any(p.glob("closed_eye_*.jpg"))), None) if CEW_DIR.is_dir() else None
    if folder is None:
        return {"missing": f"{CEW_DIR} holds no closed_eye_*.jpg; the blink row cannot be measured on this machine"}
    files = sorted(folder.glob("closed_eye_*.jpg"))
    rng = random.Random(0)
    sample = files if args.cew >= len(files) else rng.sample(files, args.cew)
    sample.sort()
    fp = _fingerprint()
    cached = {} if args.refresh else _cache_load("cew", fp)
    # The measurements, never the verdict. The key this cache is written
    # under is a hash of the code that MEASURES a frame and deliberately not
    # of flag(), so a stored verdict outlives the rule that produced it: the
    # blink counts in this section stayed as they were when the blink rule or
    # the animal gate moved, until someone thought to pass --refresh. An
    # entry written in the older shape holds flags and no crop reading, and
    # is read again rather than trusted.
    def measured(c: dict) -> bool:
        return all("clip" in f for f in c.get("faces", []))
    todo = [p for p in sample if cached.get(p.name, {}).get("stamp") != _stamp(p) or not measured(cached[p.name])]
    if todo:
        log(f"  cew: reading {len(todo)} of {len(sample)} crops ({len(sample) - len(todo)} cached)")
        judge = fmod.FaceJudge(quality=Quality())
        for n, p in enumerate(todo, 1):
            img = cv2.imread(str(p))
            if img is None:
                cached[p.name] = {"stamp": _stamp(p), "faces": []}
                continue
            fs = judge.detect(img)
            judge.judge(img, fs)
            cached[p.name] = {"stamp": _stamp(p),
                              "faces": [dict(_face_to_dict(fc), emb=None) for fc in fs]}
            if n % 100 == 0:
                log(f"    cew {n}/{len(todo)}")
                _cache_save("cew", fp, cached)
        _cache_save("cew", fp, cached)

    seen = found = read = hit = clip_hit = laugh = unseen = gated = 0
    for p in sample:
        seen += 1
        # The verdict is taken here, from the measurements, every time the
        # report is written, so a blink rule changed this morning shows in
        # this row this morning.
        faces = [_face_from_dict(d) for d in cached[p.name]["faces"]]
        for fc in faces:
            fmod.FaceJudge.flag(fc, 1.9)
        fs = [{"main": fc.main, "read": fc.read, "blink": fc.blink, "smile": fc.smile,
               "flags": fc.flags, "w": fc.box[2],
               "animal": bool(fc.in_animal or fc.clip.get("animal", 0) >= fmod.ANIMAL_GATE)}
              for fc in faces if fc.main]
        if not fs:
            continue
        found += 1
        f = max(fs, key=lambda d: d["w"])
        read += bool(f["read"])
        if "blink" in f["flags"]:
            hit += 1
        elif "blink?" in f["flags"]:
            clip_hit += 1
        # Shut eyes the landmarker DID read, turned into a question by the
        # animal gate: on this dataset 56 of the 62 "blink?" faces were these,
        # and the row above reads as though CLIP had guessed at a face nobody
        # could read. The gate is right to abstain on a dog; it is counted
        # here so the abstention is visible instead of hiding inside a miss.
        if f["read"] and f["animal"] and f["blink"] >= fmod.BLINK_SHUT and f["smile"] < fmod.LAUGH_SMILE:
            gated += 1
        # The two ways a closed eye gets through, kept apart because they are
        # different faults. The smile gate is deliberate - a laugh shuts the
        # eyes too and he keeps laughs - so the misses it causes are the price
        # of that rule and not a broken measurement.
        if f["read"] and f["blink"] >= fmod.BLINK_SHUT and f["smile"] >= fmod.LAUGH_SMILE:
            laugh += 1
        elif f["read"] and f["blink"] < fmod.BLINK_SHUT:
            unseen += 1

    # The negatives. This copy of CEW is the closed-eye half only, so it can
    # bound recall and can say nothing at all about false positives. The
    # open-eye set therefore has to come from his own frames, and the honest
    # choice is the one set of faces whose eyes he vouched for himself: the
    # largest readable face on every frame he kept and exported. Two of the
    # 205 are known blinks he kept anyway (TSC05422, TSC05664 on the action
    # shoot), so the floor on this number is 2 and not 0.
    neg = [r for r in rows if r["keep"] and r["lead face read"] >= 1.0]
    # The blink rule's own false positives. This counted every rejection,
    # whatever took the frame, so a keeper lost to "soft" was reported as a
    # blink the rule got wrong.
    fp = [r["file"] for r in neg if r["rejected"] and r["reason"] == "blink"]
    other = [r["file"] for r in neg if r["rejected"] and r["reason"] != "blink"]
    return {"folder": _said(folder), "files": len(files), "sample": len(sample), "found": found,
            "read": read, "hit": hit, "clip_hit": clip_hit, "seen": seen, "negatives": len(neg),
            "laugh": laugh, "unseen": unseen, "gated": gated, "shoots": len({r["shoot"] for r in neg}),
            "fp": fp, "other": other}


def section_animals(args, log) -> dict:
    """The animal gate at scale. The invariant is absolute: a face the
    landmarker found on a dog or a cat may lower a frame's score, and may
    never throw the frame out."""
    if not (PETS_DIR / "annotations" / "xmls").is_dir() or not (PETS_DIR / "hf" / "data").is_dir():
        return {"missing": f"{PETS_DIR} is not unpacked (annotations/xmls and hf/data); the animal-gate row cannot be measured"}
    import cv2
    import faces as fmod
    import eval_pets as epm
    from quality import Quality

    HARD = fmod.HARD_FACE_FLAGS
    rows = epm.load(PETS_DIR, args.pets)
    # The parquet the images come out of is part of the key: entries here are
    # stored per image id and nothing else would notice the mirror being
    # replaced under them.
    parquet = PETS_DIR / "hf" / "data" / "train-00000-of-00001.parquet"
    fp = _fingerprint() + (":" + _stamp(parquet) if parquet.exists() else "")
    cached = {} if args.refresh else _cache_load("pets", fp)
    judge = fmod.FaceJudge(quality=Quality())
    n = 0
    for stem, raw, sp, hb in rows:
        n += 1
        # An entry written in the older shape holds a verdict and no faces.
        # It is read again rather than trusted.
        if "faces" in cached.get(stem, {}) or cached.get(stem, {}).get("ok") is False:
            continue
        img = cv2.imdecode(np.frombuffer(raw, np.uint8), cv2.IMREAD_COLOR)
        if img is None:
            cached[stem] = {"ok": False}
            continue
        boxes = judge._animal_boxes(img)
        fs = judge.detect(img)
        judge.judge(img, fs, animal_boxes=boxes)
        on_head = [f for f in fs if f.main and epm.centre_in(f.box, hb)]
        # The faces, and not the verdict on them. The key this cache is
        # written under is a hash of the code that MEASURES a frame and
        # deliberately not of flag(), so a verdict stored in here outlives the
        # rule that produced it: this row went on naming chihuahua_184 as a
        # live veto after flag() had stopped raising one, and only re-reading
        # all 3,671 images would have caught it. Identities are dropped; no
        # head box is ever clustered against anything here, and the
        # embeddings would be most of the file.
        cached[stem] = {"ok": True, "species": sp, "yolo": bool(epm.covers(boxes, hb)),
                        "faces": [dict(_face_to_dict(f), emb=None) for f in on_head]}
        if n % 100 == 0:
            log(f"    pets {n}/{len(rows)}")
            _cache_save("pets", fp, cached)
    _cache_save("pets", fp, cached)

    # The verdict is taken here, from the measurements, every time the report
    # is written: the gate and the four faults are rules, and a rule changed
    # this morning has to show in this row this morning.
    got = []
    for stem, *_ in rows:
        c = cached.get(stem, {})
        if not c.get("ok"):
            continue
        on_head = [_face_from_dict(d) for d in c["faces"]]
        for f in on_head:
            judge.flag(f, 1.9)
        got.append((stem, {**c, "read": bool(on_head), "lm": any(f.read for f in on_head),
                           "gated": any(f.in_animal or f.clip.get("animal", 0) >= fmod.ANIMAL_GATE for f in on_head),
                           "hard": sorted({fl for f in on_head for fl in f.flags if fl in HARD}),
                           # Kept so that a head that slips the gate can be read rather
                           # than just counted: the gate has two witnesses and the
                           # report has to say which one was missing.
                           "clip": round(max([f.clip.get("animal", 0) for f in on_head] or [0.0]), 3),
                           "box": any(f.in_animal for f in on_head),
                           "frac": round(max([f.frac for f in on_head] or [0.0]), 3)}))
    read = [(s, c) for s, c in got if c["read"]]
    ungated = [(s, c) for s, c in read if not c["gated"]]
    vetoed = [(s, c) for s, c in ungated if c["hard"]]
    return {"n": len(got), "pool": len(rows), "annotated": len(list((PETS_DIR / "annotations" / "xmls").glob("*.xml"))),
            "yolo": sum(c["yolo"] for _, c in got), "read": len(read),
            "gated": sum(c["gated"] for _, c in read), "vetoed": len(vetoed),
            # A zero on the row above is only as good as the margin behind it:
            # how many heads got past both witnesses, and how many of those
            # were landmark-read, which is the only state in which a fault can
            # veto at all. Zero with eight such heads is luck, not a guard.
            "ungated": len(ungated), "ungated_read": sum(c["lm"] for _, c in ungated),
            "names": [f"{s}, a {c['species']}: would veto for {', '.join(c['hard'])}; CLIP animal {c['clip']:.2f} "
                      f"(gate needs {fmod.ANIMAL_GATE:.2f}), no YOLOX box on the face, head {100 * c['frac']:.0f}% of frame width"
                      for s, c in vetoed[:8]]}


def against_cull_csv(res: dict) -> list[dict]:
    """The harness's verdicts against the cull's own record of the same shoot.

    This is here because the veto chain in this file is a second copy of the
    one inside cull.py's main(), and a second copy drifts. It is also the
    demonstration of why a cull.csv cannot be the instrument: three of the
    four files on this machine still carry "motion blur", "mid-word" and
    "softest in burst" rejections, from rules that no longer exist. Read the
    agreement on the shoot whose file was written by the current rules; read
    the disagreement on the others as the age of the file.
    """
    import csv
    out = []
    for s in res["shoots"]:
        if "note" in s:
            continue
        p = PHOTOS / "shoots" / s["dir"] / "cull" / "cull.csv"
        if not p.exists():
            continue
        try:
            rows = list(csv.DictReader(p.read_text().splitlines()))
        except Exception:  # noqa: BLE001
            continue
        theirs = {Path(r["file"]).stem: (r["rating"] == "0", r["reason"]) for r in rows}
        mine = {Path(n).stem: r for n, r in s["rejected"]}
        # And what that file would not put in front of him at all: a fault, a
        # duplicate from before stacks, or a frame under a stack's top (which
        # is shown, and counted apart). The chain above is recomputed from
        # pixels and cannot see either of the last two.
        hidden, under = cmod.unseen_keepers(rows, s["chosen_stems"])
        both = [k for k in theirs if k in s["stems"]]
        same_call = sum(1 for k in both if theirs[k][0] == (k in mine))
        same_why = sum(1 for k in both if theirs[k][0] and k in mine and theirs[k][1] == mine[k])
        diff = sorted(f"{k}: cull.csv {theirs[k][1] or 'kept'}, here {mine.get(k, 'kept')}"
                      for k in both if theirs[k][0] != (k in mine) or (theirs[k][0] and k in mine and theirs[k][1] != mine[k]))
        out.append({"shoot": s["shoot"], "n": len(both), "same_call": same_call,
                    "theirs": sum(1 for k in both if theirs[k][0]), "mine": len(mine),
                    "same_why": same_why, "diff": diff, "hidden": hidden, "under": under,
                    "written": date.fromtimestamp(p.stat().st_mtime).isoformat()})
    return out


def section_faces(log) -> list[dict]:
    """The face judge against the verdicts settled by eye. `./pl check` is the
    tool that does this and it is called, not reimplemented: a second copy of
    the kiss rule in this file is a second copy to keep in step."""
    out = []
    for name, arg, n in (("frames settled by eye", None, 94), ("pet heads the detector reads as faces", "tests/pets_truth.json", 24)):
        cmd = [sys.executable, str(HERE / "check_faces.py")] + ([arg] if arg else [])
        r = subprocess.run(cmd, capture_output=True, text=True, cwd=REPO)
        m = re.search(r"(\d+) of (\d+) as expected", r.stdout)
        bad = [ln.strip() for ln in r.stdout.splitlines() if ln.strip().startswith("XX")]
        out.append({"what": name, "got": int(m.group(1)) if m else 0, "n": int(m.group(2)) if m else n,
                    "bad": bad, "cmd": "./pl check" + (f" {arg}" if arg else "")})
        log(f"  {name}: {out[-1]['got']}/{out[-1]['n']}")
    return out


# ------------------------------------------------------------------ the report


def pct_p(p: float, rounds: int) -> str:
    """A permutation p at its floor is a bound, not a number: with 200
    shuffles the smallest it can honestly be is 1 in 201."""
    if p != p:
        return "n/a"
    floor = 1.0 / (rounds + 1)
    return f"<{floor:.3f}" if p <= floor else f"{p:.3f}"


def pct(x: float) -> str:
    """n/a, not 0.000 and not "nan": a statistic a dataset cannot answer has to look
    different from one it answered with a bad number."""
    return "n/a" if x != x else f"{x:.3f}"


def report(args, res: dict, blink: dict, animals: dict, facechk: list, csvchk: list, elapsed: float) -> str:
    rows = res["rows"]
    live = [s for s in res["shoots"] if "note" not in s]
    n_frames = sum(s["frames"] for s in live)
    n_kept = sum(s["chosen"] for s in live)
    # Only over shoots that have bursts. A shoot scored without capture times
    # is one frame per burst, so every keeper on it looks like a burst he kept
    # one frame of, and the printed figure was 1.0 keepers per burst: a fact
    # about the missing times, not about how he shoots.
    timed = [s for s in live if s.get("bursts_known")]
    per_burst = [len({r["burst"] for r in rows if r["shoot"] == s["shoot"] and r["keep"]}) for s in timed]
    kept_timed = sum(s["chosen"] for s in timed)
    kpb = kept_timed / sum(per_burst) if sum(per_burst) else float("nan")
    L: list[str] = []
    add = L.append
    add(f"# Evaluate, {date.today().isoformat()}")
    add("")
    add("Everything on this machine that can say whether the cull is any good, each number with its")
    add("n and the dataset it came from. Run with `./pl evaluate`; it writes this file.")
    add("")
    add(f"The whole answer key is {len(live)} shoots from one camera: {n_frames} frames, {n_kept} of them kept. That is")
    add(f"small, and every number below should be read as measured on {len(live)} shoots rather than as a property")
    add("of the cull. Held out by shoot, never by frame: frames of one burst are nearly the same")
    add("picture, and a model held out by frame is scored on frames it has all but seen.")
    add("")

    add("## 1. Recall: the photographer's frames that survive the vetoes")
    add("")
    add("The number that must stay at 100%. A veto on a frame the photographer wanted is the worst")
    add("thing the cull can do, and a change that raises precision and loses a keeper is a worse change.")
    add("")
    add("`survive` is the veto chain recomputed from pixels here. `hidden by its cull.csv` is what the")
    add("file in the shoot folder would not put in front of the photographer at all - a fault, or, in")
    add("a file written before stacks, a frame hidden for looking like another - and `under a top` is")
    add("keepers shown one key under a stack's top, which is not a loss and is counted apart because a")
    add("top is the cull's guess.")
    add("")
    csvby = {c["shoot"]: c for c in csvchk}
    add("| shoot | frames | kept | survive | lost to | hidden by its cull.csv | under a top | source |")
    add("|---|---|---|---|---|---|---|---|")
    for s in res["shoots"]:
        if "note" in s:
            add(f"| {s['shoot']} | | | | | | | {s['note']} |")
            continue
        lost = ", ".join(f"{n} ({why})" for n, why in s["lost"]) or "-"
        c = csvby.get(s["shoot"])
        hid = "no cull.csv" if c is None else (", ".join(f"{n} ({why})" for n, why in c["hidden"]) if c["hidden"] else "none")
        und = "" if c is None else (len(c["under"]) or "-")
        add(f"| {s['shoot']} | {s['frames']} | {s['chosen']} | {s['survive']}/{s['measured']} | {lost} | {hid} | {und} | {s['source']} |")
    add("")
    by_hand = sum(s.get("by_hand", 0) for s in live)
    if by_hand:
        add(f"{by_hand} frames carry a star set on the camera in playback. The cull keeps those whatever the")
        add("rules say, and so does the chain here; without that this harness would report a loss the cull")
        add("does not make. The cull's other override, `--keep`, is an argument of one run and has none here.")
        add("")
    tot = sum(s["measured"] for s in live)
    surv = sum(s["survive"] for s in live)
    add(f"Pooled: {surv} of {tot} keepers survive. The pooled number is here because it was asked for;")
    add("the per-shoot rows above are the ones to read, because a rule that costs nothing on three")
    add("shoots and ten keepers on the fourth is exactly the failure this harness exists to catch.")
    if tot != n_kept:
        add("")
        add(f"`survive` counts the {tot} chosen frames that still have a cached decode to measure, of {n_kept}")
        add("in the answer keys. A chosen frame with no decode left cannot be judged either way and is")
        add("not quietly scored as a pass.")
    add("")

    add("## 2. Which rule threw each frame out")
    add("")
    add("Every rule in the cull that can reject a frame, with the number of frames it took and the")
    add("number of the photographer's own frames it took. A rule that fires on a keeper is a bug and is")
    add("named with the frame. A rule that fires on nothing at all is dead weight and gets a row saying so.")
    add("")
    heads = [s["shoot"] for s in res["shoots"] if "note" not in s]
    add("| rule | " + " | ".join(heads) + " | all | keepers lost | what it is |")
    add("|---" * (len(heads) + 4) + "|")
    for rule, what in VETO_RULES:
        cells, tot_n, tot_k = [], 0, 0
        for s in res["shoots"]:
            if "note" in s:
                continue
            n, k = s["rules"].get(rule, (0, 0))
            cells.append(str(n) if n else "-")
            tot_n += n
            tot_k += k
        names = ", ".join(f"{fn}" for s in res["shoots"] if "note" not in s for fn, why in s["lost"] if why == rule)
        add(f"| {rule} | " + " | ".join(cells) + f" | {tot_n} | {names or ('-' if not tot_k else tot_k)} | {what} |")
    add("")
    dead = [r for r, _ in VETO_RULES if not any(s.get("rules", {}).get(r) for s in live)]
    if dead:
        add(f"Fired on none of the {n_frames} frames: " + ", ".join(f"`{d}`" for d in dead) + ".")
        if "softest in burst" in dead:
            add("`softest in burst` is the per-burst quota. It is still in cull.py, behind `--burst-floor`,")
            add("which ships at 0.0; what it cost in keepers when it was on is stated once, in that")
            add("flag's own help text, and is not restated here. It cannot fire as shipped at all, and it")
            add("still has a reason string that a reader of a cull.csv would take for a live rule.")
            add("`soft duplicate` and `duplicate` are two more such strings in the older files: nothing")
            add("sets either now that frames which look alike are stacked instead of folded away.")
        rest = [d for d in dead if d != "softest in burst"]
        # A rule that needs two frames of one burst cannot fire on a shoot
        # measured without capture times, and calling that "waiting for a
        # frame" reports a hole in the harness as a fact about the rule.
        # "soft for this person" fired ten times on the action shoot's own
        # cull.csv, when the RAWs were still there to date the frames.
        blind = [s["shoot"] for s in live if not s.get("bursts_known")]
        needs_burst = [d for d in rest if d in ("soft for this person",)]
        rest = [d for d in rest if d not in needs_burst]
        if rest:
            add("The rest of the dead list - " + ", ".join(f"`{d}`" for d in rest) + " - is a fact about")
            add(f"these {len(live)} shoots and not about the rules: they are waiting for a frame this camera has not")
            add("handed them yet, which is the right behaviour for a guard. They are dead weight only if")
            add("they stay at zero on a card that should have set them off.")
        if needs_burst:
            add(", ".join(f"`{d}`" for d in needs_burst) + " needs two frames of one person in one time burst.")
            if blind:
                add("It cannot fire at all on " + ", ".join(blind) + ", which " + ("were" if len(blind) > 1 else "was")
                    + " measured with no capture time and so as one frame per burst, so its zero")
                add("here says nothing about the rule.")
        add("")
    if csvchk:
        add("**Against the cull's own record.** The veto chain above is a second copy of the one inside")
        add("cull.py's main(), so it is checked frame by frame against the cull.csv each shoot already")
        add("carries. Where the file is older than the current rules the disagreement is the age of the")
        add("file, and that is exactly why this harness recomputes instead of reading it. The date is the\n"
            "file's mtime and not the age of its rules: a bench run rewrites and restores it. The reason\n"
            "strings are what date it.")
        add("")
        add("| shoot | frames compared | cull.csv rejected | here | same call | same reason | that file last touched |")
        add("|---|---|---|---|---|---|---|")
        for c in csvchk:
            add(f"| {c['shoot']} | {c['n']} | {c['theirs']} | {c['mine']} | {c['same_call']} | {c['same_why']} | {c['written']} |")
        add("")
        for c in csvchk:
            if c["diff"]:
                add(f"{c['shoot']}, first disagreements: " + "; ".join(c["diff"][:6])
                    + (f"; and {len(c['diff']) - 6} more" if len(c["diff"]) > 6 else "") + ".")
        add("")

    add("## 3. Ranking: within a burst, and pooled")
    add("")
    add("The pooled keep/reject number is confounded and has been reported without that caveat. The")
    add(f"photographer keeps {kpb:.1f} frames from each burst that yields anything, so a frame's label depends on")
    add("which burst it landed in as much as on the frame: a good frame in a burst of 50 is a reject and")
    add("a middling one shot alone is a keeper. The within-burst pairwise number asks the question the")
    add("pooled one was meant to ask - of two frames of the same moment, does the measurement prefer the")
    add("one that was kept - and the pooled AUC stays in the table beside it rather than being replaced")
    add("by it. Published work on within-series photo preference sits at about 0.70-0.73 pairwise; that")
    add("is the bar, not 0.5.")
    add("")
    add("Every number is one measurement the cull already makes, with 'higher is better' fixed in")
    add("advance. A number under 0.5 means the measurement ranks the keepers LAST, and it is printed")
    add("that way rather than flipped to look good.")
    add("")
    add("One denominator warning. docs/ML.md's \"best AUC 0.61\" was measured on the 291 frames of the")
    add("action shoot that were reviewed twice, 154 kept against 137 thrown out. The pooled column here is")
    add("over every scored frame of each shoot, keepers against everything else, so it is a different")
    add("quantity and a lower number here is not a regression against that one. The within-burst")
    add("column is the one to compare across rows, because its denominator is a pair of frames of the")
    add("same moment and does not depend on how many frames the shoot has.")
    add("")
    for s in res["shoots"]:
        if "note" in s:
            continue
        sub = [r for r in rows if r["shoot"] == s["shoot"]]
        keep = np.array([r["keep"] for r in sub], bool)
        burst = np.array([r["burst"] for r in sub])
        pairs_any = sum(1 for b in set(burst) if 0 < keep[burst == b].sum() < (burst == b).sum())
        add(f"**{s['shoot']}** - n={len(sub)} frames, {int(keep.sum())} kept, {s['bursts']} bursts, "
            f"{pairs_any} of them with a keeper and a reject in the same burst.")
        add("")
        if not pairs_any:
            add("No burst here holds both a keeper and a reject, so there is no pair to score: "
                + s["source"].split("; ")[-1] + ".")
            add("This shoot can answer the pooled question and cannot answer the within-burst one at all;")
            add("the row is left out rather than filled with the pooled number under another name.")
            add("")
            add("| measurement | pooled AUC | n |")
            add("|---|---|---|")
            for name, _ in RANK_FEATURES:
                add(f"| {name} | {pct(auc(np.array([r[name] for r in sub], float), keep))} | {len(sub)} |")
            add("")
            continue
        add("| measurement | pooled AUC | within-burst pairwise | pairs | shuffled | p | top-k per burst | chance |")
        add("|---|---|---|---|---|---|---|---|")
        for name, _ in RANK_FEATURES:
            sc = np.array([r[name] for r in sub], float)
            a = auc(sc, keep)
            acc, npairs = within_burst(sc, keep, burst)
            rec, ch, _ = topk_per_burst(sc, keep, burst)
            nm, p = permute(within_burst, sc, keep, burst, args.rounds)
            add(f"| {name} | {pct(a)} | {pct(acc)} | {npairs} | {pct(nm)} | {pct_p(p, args.rounds)} | {pct(rec)} | {pct(ch)} |")
        add("")
    loso = logistic_loso(rows, [n for n, _ in RANK_FEATURES], args.rounds)
    if loso:
        add(f"And the same measurements fitted together, held out by shoot: trained on {len(live) - 1} shoots, scored")
        add("on the one left out, which is the only honest way to ask whether any of this transfers.")
        add("")
        add("| held-out shoot | n | keepers | pooled AUC | within-burst pairwise | pairs | shuffled | p | top-k | chance |")
        add("|---|---|---|---|---|---|---|---|---|---|")
        for r in loso:
            add(f"| {r['shoot']} | {r['n']} | {r['keepers']} | {pct(r['auc'])} | {pct(r['pairwise'])} | {r['pairs']} | "
                f"{pct(r['null'])} | {pct_p(r['p'], args.rounds)} | {pct(r['topk'])} | {pct(r['chance'])} |")
        add("")
    add(f"`shuffled` is the same statistic with the labels shuffled inside each burst, {args.rounds} times: the burst")
    add("sizes and the number kept per burst stay exactly as they are, and only which frame was chosen is")
    add("randomised. `p` counts the shuffles at least as far from 0.5 as the real number, plus one, over")
    add(f"the {args.rounds} shuffles plus one: beating every shuffle is not p = 0, it is p under 1 in {args.rounds + 1}, and")
    add("that is what `<` means in the column. At this n a pairwise number inside about 0.05 of 0.5 is")
    add("not distinguishable from chance, whatever it reads.")
    add("")

    add("## 4. Blink recall")
    add("")
    if "missing" in blink:
        add(blink["missing"] + ".")
    else:
        add(f"`{blink['folder']}` holds {blink['files']} crops and every one of them is a CLOSED eye: filenames")
        add("`closed_eye_NNNN.jpg_face_N.jpg`, and no open-eye half was ever copied onto this machine. So")
        add("this dataset bounds RECALL and cannot say one word about false positives. It is")
        add("research-licensed: it is referenced by path, never copied into the repo, and nothing")
        add("trained on it may ship.")
        add("")
        add("| what | n | of the sample |")
        add("|---|---|---|")
        add(f"| crops read | {blink['seen']} | sampled from {blink['files']} with random.seed(0) |")
        add(f"| a main face found at all | {blink['found']} | {100 * blink['found'] / max(1, blink['seen']):.1f}% |")
        add(f"| landmarks read | {blink['read']} | {100 * blink['read'] / max(1, blink['found']):.1f}% of those found |")
        add(f"| flagged `blink` (the flag that vetoes) | {blink['hit']} | {100 * blink['hit'] / max(1, blink['read']):.1f}% of those read |")
        add(f"| flagged `blink?`, so a note and never a veto | {blink['clip_hit']} | CLIP's guess where no landmarks were read, "
            f"and every landmark-read blink the animal gate turned into a question |")
        add(f"| of those, shut eyes the landmarker DID read, gated as an animal | {blink['gated']} | "
            f"{100 * blink['gated'] / max(1, blink['read']):.1f}% of those read |")
        add(f"| shut eyes held back by the smile gate | {blink['laugh']} | {100 * blink['laugh'] / max(1, blink['read']):.1f}% of those read |")
        add(f"| the landmarker did not see shut eyes | {blink['unseen']} | {100 * blink['unseen'] / max(1, blink['read']):.1f}% of those read |")
        add("")
        add("The `blink?` row is not one thing. A crop whose landmarks were never read is CLIP guessing;")
        add("a crop that was read, found shut, and then written as a question because CLIP or a YOLOX box")
        add("called it an animal is the gate abstaining, and on this dataset that is most of the row. The")
        add("gate is right to abstain on a dog's face; the row says how often it does it to a person's.")
        add("")
        add("The two rows below it are the rest of the miss, split because they are different faults. The")
        add("smile gate is deliberate - a laugh shuts the eyes too, real blinks read 0.13 and under on")
        add("smile and laughs 0.47 and up, and the photographer keeps laughs - so those misses are the")
        add("price of a rule that exists to protect keepers. The rows where the landmarker did not see shut")
        add("eyes are the measurement failing, and they are the ones worth working on.")
        add("")
        add("These are tight crops of a face, so the detector meets a nearly face-filling image and")
        add("never has to find the face in a frame. Read the recall as the blink test's own ceiling,")
        add("not as what the cull does on a card.")
        add("")
        add("**The negatives, and exactly how they were chosen.** With no open-eye half, the only")
        add("open-eye set on this machine whose eyes the photographer vouched for is the keeper set. The")
        add(f"negatives are the largest readable face on each frame the photographer kept and exported, {blink['negatives']} of the {n_kept}")
        add("keepers having one at all. They are overwhelmingly open-eyed because they were chosen, which is")
        add("the whole argument for using them; the known exceptions are the two frames on the action")
        add("shoot kept with a blink in them, so a perfect blink rule scores 2 here and not 0.")
        add("")
        add(f"On that set the blink rule fires on {len(blink['fp'])}"
            + (": " + ", ".join(blink["fp"]) + "." if blink["fp"] else " frames."))
        add("This is the same count as the `blink` row of section 2 restricted to keepers, and that is")
        add("where it belongs: a blink false positive IS a lost keeper, and section 1 is the line that")
        add("refuses to let one pass. It counts the frames the BLINK rule took and no others; it used to")
        add("count every rejection among these frames, so a keeper lost to a soft face was reported here")
        add("as a blink the rule got wrong."
            + (f" {len(blink['other'])} of them were taken by another rule ({', '.join(blink['other'][:6])})." if blink["other"] else ""))
    add("")

    add("## 5. The animal gate")
    add("")
    if "missing" in animals:
        add(animals["missing"] + ".")
    else:
        add("A dog, a cat, a lamp or the back of a head may lower a frame's score and may never throw")
        add("the frame out. YuNet reads a pet's head as a human face often enough for that to matter,")
        add(f"and a 'face' that reads soft or blinking would veto the frame. Sampled {animals['n']} of the")
        add(f"{animals['annotated']} Oxford-IIIT Pet images that carry a head box drawn by the dataset's authors, shuffled")
        add("with random.seed(0) by `pipeline/eval_pets.py`'s own loader; the full folder is 11,086 files")
        add("and most carry no box, so the gate can only be scored on the annotated ones. CC BY-SA 4.0,")
        add("referenced by path and never copied into the repo.")
        add("")
        add("| what | n | share |")
        add("|---|---|---|")
        add(f"| images measured | {animals['n']} | of {animals['pool']} drawn |")
        add(f"| a YOLOX cat/dog box covers the head | {animals['yolo']} | {100 * animals['yolo'] / max(1, animals['n']):.1f}% |")
        add(f"| YuNet read the head as a main human face | {animals['read']} | {100 * animals['read'] / max(1, animals['n']):.1f}% |")
        add(f"| of those, gated as an animal | {animals['gated']} | {100 * animals['gated'] / max(1, animals['read']):.1f}% |")
        add(f"| **ungated AND carrying a vetoing fault** | **{animals['vetoed']}** | "
            f"{100 * animals['vetoed'] / max(1, animals['read']):.1f}% of the heads read |")
        add("")
        add("The last row is the invariant, and it must be 0. It counts a pet head that the gate did not")
        add("catch AND that carries one of the four faults that veto, which is a frame thrown out on an")
        add("animal's face as soon as that head is the largest readable face in the picture.")
        add("")
        if animals["vetoed"]:
            add(f"**It is {animals['vetoed']}, not 0.** The gate has two witnesses, a YOLOX cat or dog box around the face")
            add("and CLIP's animal prompt at 0.45, and these heads had neither:")
            add("")
            for nm in animals["names"]:
                add(f"- {nm}")
            add("")
            add("This is the finding that needed more than 24 fixtures. `tests/pets_truth.json` is 24 pet")
            add("heads and the gate holds on all 24; at 600 it does not. The failure is not that the")
            add("animal was missed by one witness - that is expected and is why there are two - but that")
            add("both missed the same head, and nothing downstream asks a second time before the frame")
            add("goes in the bin. Read this as an open fault, not as a measurement of one.")
        else:
            add(f"It is 0 of the {animals['read']} heads read as a face, and that is the invariant holding rather")
            add(f"than a guard: {animals['ungated']} heads got past both witnesses, {animals['ungated_read']} of them landmark-read, which is the")
            add("only state in which a fault can veto. None of those happens to carry one. At 24 fixtures")
            add("it also read 0, which is why the number is taken over the whole annotated set.")
        add("")
        add("`pipeline/eval_pets.py` is the fuller report on the same data, broken down by breed; this")
        add("row is the invariant alone.")
    add("")

    add("## 6. The face judge against the verdicts settled by eye")
    add("")
    add("`./pl check` is called here, not reimplemented. The kiss rule and the verdict rule are written")
    add("once each, in `faces.py` (`kiss`, `verdict`), and the cull, this harness and the fixture check")
    add("all call those; they were three separate copies, and the fixture check's copy had already")
    add("drifted - it stripped the two flags a kiss forgives without recording why.")
    add("")
    add("| what | result | command |")
    add("|---|---|---|")
    for f in facechk:
        add(f"| {f['what']} | {f['got']} of {f['n']} | `{f['cmd']}` |")
    for f in facechk:
        for b in f["bad"]:
            add(f"| | {b} | |")
    add("")

    add("## What is not measured here")
    add("")
    add(f"- **One camera, one photographer, {len(live)} shoots.** {n_frames} frames with an answer key and {n_kept}")
    add("  keepers. Nothing here shows a threshold transfers to another body, another lens or another")
    add("  person's taste, and the per-shoot columns exist because the pooled number hides exactly the")
    add("  failure that cost 33 keepers.")
    smoke = PHOTOS / "shoots" / "ducksAndDeadlifts"
    if smoke.is_dir() and not decision_path(smoke / "cull", "selects.json").exists():
        add(f"- **`{_said(smoke)}`** is {len(list(smoke.glob('*.ARW')))} loose ARW with no answer key and no")
        add("  shoot.json: a genuinely unseen shoot. It is a smoke test and not a score, and it has no")
        add("  cull/decoded, so measuring it would mean decoding RAWs into that shoot folder. This harness")
        add("  writes nothing inside ~/photos, so it has no row here; run `./pl cull` on it by hand.")
    add("- **False positives on blinks** cannot come from CEW on this machine; see section 4.")
    add("- **Recall is measured on the cached decodes**, which is what the fixture check runs on and")
    add("  what the lounge has left. A cull of the RAWs decodes at full resolution; on three of the")
    add("  four shoots the cache IS that full-resolution decode, and on the lounge it is 2400 px wide.")
    add("- **The veto chain is re-expressed in this file**, because cull.py holds it inline in main()")
    add("  and running the cull would rewrite the cull.csv you work from. Section 2 prints the rule")
    add("  behind every rejection so a disagreement with a fresh `./pl cull` shows up frame by frame.")
    add("")
    add(f"Run: {elapsed / 60:.1f} minutes for this one, {args.rounds} permutations, pets sample {args.pets}, cew sample {args.cew}.")
    add("Measurements are cached under `~/.cache/first-edit/evaluate`, keyed by the frame and by")
    add("the source of the code that measures it: change a rule and the verdicts re-run in seconds,")
    add("change a measurement and every frame is read again. `--refresh` ignores the cache.")
    return "\n".join(L) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description="What the cull is worth, on every dataset this machine has.")
    ap.add_argument("--only", default="", help="comma-separated: recall,vetoes,ranker,blink,animals,faces")
    ap.add_argument("--pets", type=int, default=600, help="Oxford-IIIT Pet images to sample (0 = skip)")
    ap.add_argument("--cew", type=int, default=1192, help="CEW closed-eye crops to sample (0 = skip)")
    ap.add_argument("--rounds", type=int, default=200, help="label shuffles in the permutation test")
    ap.add_argument("--workers", type=int, default=max(4, (os.cpu_count() or 8) * 3 // 4))
    ap.add_argument("--refresh", action="store_true", help="ignore the measurement cache and read every frame again")
    ap.add_argument("--out", type=Path, default=OUT)
    args = ap.parse_args()
    only = {s.strip() for s in args.only.split(",") if s.strip()}
    want = lambda k: not only or k in only  # noqa: E731

    t0 = time.time()
    log = print
    print("evaluate: the cull against every dataset with an answer key")
    res = {"shoots": [], "rows": []}
    if want("recall") or want("vetoes") or want("ranker") or want("blink"):
        print("\n[1-3] shoots")
        res = section_shoots(args, log)
        for s in res["shoots"]:
            if "note" in s:
                print(f"  {s['note']}")
            else:
                print(f"  {s['shoot']}: {s['survive']}/{s['measured']} keepers survive; "
                      f"{sum(n for n, _ in s['rules'].values())} of {s['frames']} frames rejected"
                      + (f"; LOST {', '.join(n for n, _ in s['lost'])}" if s["lost"] else ""))
    blink: dict = {"missing": "not run"}
    if want("blink") and args.cew:
        print("\n[4] blink")
        blink = section_blink(args, res["rows"], log)
    animals: dict = {"missing": "not run"}
    if want("animals") and args.pets:
        print("\n[5] animal gate")
        animals = section_animals(args, log)
    facechk: list = []
    if want("faces"):
        print("\n[6] face judge")
        facechk = section_faces(log)
    csvchk = against_cull_csv(res) if res["shoots"] else []
    for c in csvchk:
        print(f"  cull.csv {c['shoot']}: {c['same_call']}/{c['n']} same call, {c['same_why']} same reason "
              f"(that file was written {c['written']}); it would not show him {len(c['hidden'])} of his keepers"
              + (f" ({', '.join(n for n, _ in c['hidden'][:6])})" if c["hidden"] else "")
              + f", and {len(c['under'])} sit under a stack's top")

    if only:
        print("\n  (a partial run; tests/eval.md is only written by a full one)")
        return 0
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(report(args, res, blink, animals, facechk, csvchk, time.time() - t0))
    print(f"\n  {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
