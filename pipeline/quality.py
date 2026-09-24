"""
quality.py - the "is this a good photo" half of the cull.

Sharpness (cull.py) answers "which frame in this burst is in focus". This module
answers the rest, with four signals that each catch something focus cannot:

  aesthetic   CLIP ViT-L/14 embedding through the LAION aesthetic head, trained on
              about 176,000 human ratings. It reads light, composition, and subject
              the way people rate photos, and it is the strongest single signal.
  eyes        MediaPipe face blendshapes. A blink is a bin, a squint is a demerit.
              Smile is recorded too; the taste model decides whether it matters.
  framing     Where the subject sits and how much of the frame it fills, from the
              subject box cull.py already found. Rule-of-thirds proximity, size.
  stacks      Frames taken back to back that look alike, by CLIP and a perceptual
              hash together, measured against this card's own frame-to-frame
              change. A stack arranges frames so they can be compared; it hides
              nothing (see similar_stacks for why it may not).

Everything is standardised within the shoot, so a dark venue is judged against
itself and not against a sunny park.

The weights that combine these are a considered guess (DEFAULT_WEIGHTS), not
fitted. They used to be fittable to one shoot's picks with `cull --learn` and
were then applied to every later shoot; that is retired, because taste measured
on one shoot did not carry to the next.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np


class quiet_stderr:
    """Silence C++ library chatter (TensorFlow Lite, absl) that bypasses Python
    logging. Swaps file descriptor 2 for /dev/null and puts it back."""

    def __enter__(self):
        import sys
        sys.stderr.flush()
        self._saved = os.dup(2)
        self._null = os.open(os.devnull, os.O_WRONLY)
        os.dup2(self._null, 2)
        return self

    def __exit__(self, *exc):
        import sys
        sys.stderr.flush()
        os.dup2(self._saved, 2)
        os.close(self._saved)
        os.close(self._null)
        return False

from common import MODELS, CLIP_CACHE  # noqa: E402
AESTHETIC_HEAD = MODELS / "aesthetic_vit_l14_linear.pth"
LANDMARKER = MODELS / "face_landmarker.task"

# Feature order everywhere. Keep the taste weights file in sync with this.
FEATURES = ["aesthetic", "sharp_rel", "eyes_open", "smile", "subj_area", "thirds", "action", "face_score", "shadow", "flaw", "gaze"]
# face_score is the full-resolution face judge's 0..1 verdict (1.0 when no face was judged).
# sharp_rel is focus relative to the sharpest frame of the same burst, so it says
# "this is the crisp one of its set" and never "close-ups beat wide shots".
DEFAULT_WEIGHTS = {"aesthetic": 0.50, "sharp_rel": 0.10, "eyes_open": 0.00, "action": 0.15,
                   "smile": 0.00, "subj_area": 0.00, "thirds": 0.05, "face_score": 0.00, "shadow": -0.08, "flaw": -0.25, "gaze": 0.08}
# face_score is 0 on purpose. It measures whether a face is sharp, lit, eyes open,
# not blown: exactly the right signal for the veto, where it does its work, and
# the wrong one for the ranking. Among frames that already passed, a higher face
# score did not predict the photographer's pick on either bench shoot, and with
# weight 0.20 the combined ranking scored below the aesthetic head alone
# (portraits 0.17 against 0.25). At 0 it matches or beats the head on both.
# shadow is CLIP's belief that the photographer's own shadow is in the frame; it
# counts against, never vetoes: the prompt is right often enough to rank on, not to throw out.
# subj_area is 0 on purpose: a bigger subject is not a better picture, and
# weighting it buried every wide, environmental frame the photographer chose.


@dataclass
class QualityResult:
    aesthetic: float = 0.0
    eyes_open: float = 0.5      # 1 open, 0 blink, 0.5 unknown (no face landmarks)
    smile: float = 0.0
    subj_area: float = 0.0
    thirds: float = 0.0
    faces_lm: int = 0
    embedding: np.ndarray | None = None


class Quality:
    """Lazily loads the heavy models the first time they are needed."""

    def __init__(self, use_eyes: bool = True, use_aesthetic: bool = True):
        self._clip = None
        self._pre = None
        self._head = None
        self._dev = None
        self._lm = None
        self.use_eyes = use_eyes and LANDMARKER.exists()
        self.use_aesthetic = use_aesthetic and AESTHETIC_HEAD.exists()
        self.notes: list[str] = []

    # ---------------------------------------------------------- aesthetic

    def _load_clip(self):
        if self._clip is not None:
            return True
        try:
            import logging
            logging.getLogger("huggingface_hub").setLevel(logging.ERROR)
            import torch
            import open_clip
        except ImportError as e:
            self.notes.append(f"aesthetic off: {e}")
            self.use_aesthetic = False
            return False
        self._dev = "mps" if torch.backends.mps.is_available() else "cpu"
        model, _, pre = open_clip.create_model_and_transforms("ViT-L-14-quickgelu", pretrained="openai", cache_dir=CLIP_CACHE)
        self._clip = model.to(self._dev).eval()
        self._pre = pre

        class MLP(torch.nn.Module):
            def __init__(s):
                super().__init__()
                s.layers = torch.nn.Sequential(
                    torch.nn.Linear(768, 1024), torch.nn.Dropout(0.2),
                    torch.nn.Linear(1024, 128), torch.nn.Dropout(0.2),
                    torch.nn.Linear(128, 64), torch.nn.Dropout(0.1),
                    torch.nn.Linear(64, 16), torch.nn.Linear(16, 1))

            def forward(s, x):
                return s.layers(x)

        head = MLP()
        head.load_state_dict(torch.load(str(AESTHETIC_HEAD), map_location="cpu"))
        self._head = head.to(self._dev).eval()
        return True

    def aesthetic_batch(self, paths: list[Path], batch: int = 32) -> tuple[np.ndarray, np.ndarray]:
        """Return (aesthetic scores [N], unit embeddings [N,768]) for the images."""
        n = len(paths)
        scores = np.zeros(n, dtype=np.float32)
        embs = np.zeros((n, 768), dtype=np.float32)
        if not self.use_aesthetic or not self._load_clip():
            return scores, embs
        import torch
        from PIL import Image
        with torch.no_grad():
            for i in range(0, n, batch):
                chunk = paths[i:i + batch]
                x = torch.stack([self._pre(Image.open(p).convert("RGB")) for p in chunk]).to(self._dev)
                e = self._clip.encode_image(x)
                e = e / e.norm(dim=-1, keepdim=True)
                s = self._head(e.float()).squeeze(-1)
                scores[i:i + len(chunk)] = s.float().cpu().numpy()
                embs[i:i + len(chunk)] = e.float().cpu().numpy()
        return scores, embs

    # ------------------------------------------------------------ moments

    # What a photo is *of*. CLIP scores each frame against these in the
    # same embedding space the aesthetic head uses, so this costs one text
    # encode per run and nothing per frame. The first group is action; the
    # rest are the moments that sell, plus neutral classes so a portrait
    # shoot or a cat on a bench gets an honest label rather than a label from somebody else's domain.
    MOMENTS = [
        ("action", "an action photo of people moving fast, jumping or playing a sport", True),
        ("embrace", "a photo of two people hugging or kissing", False),
        ("portrait", "a photo of a person posing for a portrait", False),
        ("group", "a photo of a group of people together", False),
        ("crowd", "a photo of a crowd of spectators in a venue", False),
        ("animal", "a photo of a dog or a cat", False),
        ("place", "a photo of a landscape or a building with no people", False),
        ("food", "a photo of a plate of food", False),
    ]
    # A private extension can replace these with its own (a domain has its own
    # moments); see common.EXT and moments.json.
    try:
        import json as _json
        from common import EXT as _EXT
        if (_EXT / "moments.json").exists():
            MOMENTS = [tuple(m) for m in _json.loads((_EXT / "moments.json").read_text())]
    except Exception:  # noqa: BLE001
        pass

    FLAWS = [
        ("shadow", "a photo with the photographer's own shadow falling into the frame"),
        ("shadow", "a photo where the shadow of the person taking the picture is visible on the ground"),
        ("clean", "a photo with no shadow of the photographer in it"),
        ("clean", "a clean, well-composed photo"),
    ]

    def flaws(self, embs: np.ndarray) -> np.ndarray:
        """Per frame: probability that the photographer's shadow is in it."""
        n = embs.shape[0]
        if n == 0 or not self.use_aesthetic or not self._load_clip() or np.abs(embs).sum() == 0:
            return np.zeros(n, dtype=np.float32)
        import torch
        import open_clip
        if getattr(self, "_flaw_text", None) is None:
            tok = open_clip.get_tokenizer("ViT-L-14-quickgelu")
            with torch.no_grad():
                t = self._clip.encode_text(tok([p for _, p in self.FLAWS]).to(self._dev))
                t = t / t.norm(dim=-1, keepdim=True)
            self._flaw_text = t.float().cpu().numpy()
        logits = embs.astype(np.float32) @ self._flaw_text.T * 100.0
        logits -= logits.max(axis=1, keepdims=True)
        p = np.exp(logits)
        p /= p.sum(axis=1, keepdims=True)
        cols = [i for i, (lab, _) in enumerate(self.FLAWS) if lab == "shadow"]
        return p[:, cols].sum(axis=1).astype(np.float32)

    def moments(self, embs: np.ndarray) -> tuple[list[str], np.ndarray]:
        """Per frame: the best-matching moment label, and an action score in
        0..1 (the probability mass on the moments marked as action)."""
        n = embs.shape[0]
        if n == 0 or not self.use_aesthetic or not self._load_clip() or np.abs(embs).sum() == 0:
            return ["" for _ in range(n)], np.zeros(n, dtype=np.float32)
        import torch
        import open_clip
        if getattr(self, "_moment_text", None) is None:
            tok = open_clip.get_tokenizer("ViT-L-14-quickgelu")
            with torch.no_grad():
                t = self._clip.encode_text(tok([p for _, p, _ in self.MOMENTS]).to(self._dev))
                t = t / t.norm(dim=-1, keepdim=True)
            self._moment_text = t.float().cpu().numpy()
        sims = embs.astype(np.float32) @ self._moment_text.T           # [N, M]
        logits = sims * 100.0                                            # CLIP's usual temperature
        logits -= logits.max(axis=1, keepdims=True)
        p = np.exp(logits)
        p /= p.sum(axis=1, keepdims=True)
        action_cols = [i for i, (_, _, a) in enumerate(self.MOMENTS) if a]
        labels = [self.MOMENTS[int(i)][0] for i in p.argmax(axis=1)]
        return labels, p[:, action_cols].sum(axis=1).astype(np.float32)

    # --------------------------------------------------------------- eyes

    def _load_lm(self):
        if self._lm is not None:
            return True
        try:
            with quiet_stderr():
                import mediapipe as mp  # noqa: F401
                from mediapipe.tasks import python as mpp
                from mediapipe.tasks.python import vision
        except ImportError as e:
            self.notes.append(f"eyes off: {e}")
            self.use_eyes = False
            return False
        try:
            opts = vision.FaceLandmarkerOptions(
                base_options=mpp.BaseOptions(model_asset_path=str(LANDMARKER)),
                output_face_blendshapes=True, num_faces=6,
                min_face_detection_confidence=0.4)
            with quiet_stderr():
                self._lm = vision.FaceLandmarker.create_from_options(opts)
        except Exception as e:  # noqa: BLE001
            self.notes.append(f"eyes off: {e}")
            self.use_eyes = False
            return False
        return True

    def eyes(self, bgr: np.ndarray) -> tuple[float, float, int]:
        """(eyes_open 0..1, smile 0..1, faces). Worst blink across faces counts:
        one person blinking in a group shot is still a blink."""
        if not self.use_eyes or not self._load_lm():
            return 0.5, 0.0, 0
        import mediapipe as mp
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        with quiet_stderr():
            res = self._lm.detect(mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb))
        if not res.face_blendshapes:
            return 0.5, 0.0, 0
        worst_blink, best_smile = 0.0, 0.0
        for bs in res.face_blendshapes:
            d = {c.category_name: c.score for c in bs}
            worst_blink = max(worst_blink, max(d.get("eyeBlinkLeft", 0), d.get("eyeBlinkRight", 0)))
            best_smile = max(best_smile, max(d.get("mouthSmileLeft", 0), d.get("mouthSmileRight", 0)))
        return 1.0 - float(worst_blink), float(best_smile), len(res.face_blendshapes)

    # ------------------------------------------------------------ framing

    @staticmethod
    def framing(box, w: int, h: int) -> tuple[float, float]:
        """(subject area fraction, thirds score). thirds is 1.0 when the subject's
        centre sits on a rule-of-thirds point and falls off to 0 at the far corner."""
        if box is None or w <= 0 or h <= 0:
            return 0.0, 0.0
        x, y, bw, bh = box
        area = max(0.0, min(1.0, (bw * bh) / float(w * h)))
        cx, cy = (x + bw / 2) / w, (y + bh / 2) / h
        pts = [(1 / 3, 1 / 3), (2 / 3, 1 / 3), (1 / 3, 2 / 3), (2 / 3, 2 / 3), (0.5, 0.5)]
        d = min(((cx - px) ** 2 + (cy - py) ** 2) ** 0.5 for px, py in pts)
        return area, max(0.0, 1.0 - d / 0.5)


# ------------------------------------------------------------------ scoring


def standardise(x: np.ndarray) -> np.ndarray:
    x = np.asarray(x, dtype=np.float64)
    sd = x.std()
    return (x - x.mean()) / sd if sd > 1e-9 else np.zeros_like(x)


def combined_score(feats: dict[str, np.ndarray], weights: dict[str, float]) -> np.ndarray:
    """Weighted sum of within-shoot standardised features."""
    total = np.zeros(len(next(iter(feats.values()))), dtype=np.float64)
    for name in FEATURES:
        w = float(weights.get(name, 0.0))
        if w == 0.0:
            continue
        total += w * standardise(feats[name])
    return total


# Back-to-back pairs needed before a card's own median change is used as a
# line. A sample-size guard, not a taste number; cull.MIN_RETEST_PAIRS is the
# same guard on the same kind of measurement.
MIN_PAIRS = 24


def frame_number(name: str) -> int | None:
    """The camera's own counter in a file name (TSC04313.ARW is 4313), or None
    for a name that carries none."""
    m = re.search(r"(\d+)$", Path(name).stem)
    return int(m.group(1)) if m else None


def hash_bits(h) -> np.ndarray:
    """A perceptual hash as 64 booleans, from an imagehash.ImageHash or from
    the bits similar.npz stores, so a stack can be formed again without the
    preview it was hashed from."""
    return np.asarray(h.hash if hasattr(h, "hash") else h, dtype=bool).ravel()


def back_to_back(bursts: list, seqs: list, names: list) -> list[tuple[int, int]]:
    """Every pair of frames taken one straight after the other.

    Two frames are neighbours when nothing was shot between them: they are
    next to each other in capture order inside one time burst, and the
    camera's counter moved by exactly one. A gap in the counter is a frame
    that is not here (deleted in camera, or unreadable), so the frames on
    either side of it are not neighbours, however alike they look. A frame
    with no capture time (a cull of cached decodes, where the RAWs are gone)
    has no burst to sit in, and for those the counter alone says who is next
    to whom; with no counter either, nothing does."""
    nums = [frame_number(n) for n in names]
    order = sorted(range(len(names)), key=lambda i: (seqs[i], names[i]))
    out = []
    for a, b in zip(order, order[1:]):
        timed_a, timed_b = seqs[a] > 0, seqs[b] > 0
        if timed_a != timed_b:
            continue
        if timed_a and bursts[a] != bursts[b]:
            continue
        if nums[a] is not None and nums[b] is not None:
            if nums[b] - nums[a] != 1:
                continue
        elif not timed_a:
            continue
        out.append((a, b))
    return out


def similar_stacks(embs, hashes: list, bursts: list, seqs: list, names: list) -> tuple[list[int], dict]:
    """Stack id per frame (-1 for a frame on its own), and the line it used.

    A stack is frames that look alike, put together so they can be compared,
    never a reason to hide one. The grouping this replaces hid all but one or
    two frames of every "same picture" group, and 65 of the photographer's 773
    keepers across six shoots were among the hidden. No threshold fixes that:
    on back-to-back pairs where he made a choice, CLIP similarity separates
    "kept both" from "kept one" at an AUC of 0.53 to 0.72 and the perceptual
    hash does no better, because at 11 frames a second he chooses between
    near-identical frames on expression and contact, which no whole-frame
    measure sees. So nothing is decided here; frames are only arranged.

    Two rules keep a stack small and honest. Only neighbours are linked (see
    back_to_back), so a stack is always one unbroken run of the shutter and a
    moving subject can no longer chain a whole exchange together across
    bursts: the grouping this replaces joined 45 frames over three bursts and
    61 seconds on the 09-16 action shoot. And the line is this card's own: a
    pair is linked when both its CLIP cosine and its phash distance changed
    less than the median back-to-back pair on the card did. That needs no
    "Fast action" setting to come out right: 09-21 was culled without it, and
    the still-subject thresholds hid 424 of its 857 frames. Measured on the
    six shoots: 0 keepers hidden, and 251 to 361 frames folded under a top on
    each of the three large ones.

    The median reads three things at once and cannot tell them apart: how
    fast the subject moves, how fast the camera fires, and how steady the
    light and the framing are (on 12 still frames, +1 EV moved the hash by a
    median of 6 bits and a 3% reframe by 6, as much as an action shoot's
    frame-to-frame change). That is fine for arranging frames and is the
    reason it decides nothing else, least of all what kind of shoot this is.

    Returns ids 0, 1, 2... in shooting order for runs of two or more frames,
    and a dict saying how many pairs the line was measured on and where it
    sat, or why there is no line (no CLIP vectors, or too few pairs to take
    a median of)."""
    n = len(names)
    out = [-1] * n
    info: dict = {"pairs": 0, "cos": None, "bits": None, "why": ""}
    E = None if embs is None else np.asarray(embs, dtype=np.float64)
    if E is None or len(E) != n or not np.abs(E).sum() or not hashes or len(hashes) != n:
        info["why"] = "no picture model on this run, so nothing to say two frames look alike"
        return out, info
    pairs = [(a, b) for a, b in back_to_back(bursts, seqs, names) if hashes[a] is not None and hashes[b] is not None]
    info["pairs"] = len(pairs)
    if len(pairs) < MIN_PAIRS:
        info["why"] = f"only {len(pairs)} back-to-back pairs, too few to say what 'barely changed' means on this card"
        return out, info
    cos = np.array([float(E[a] @ E[b]) for a, b in pairs])
    bits = np.array([int((hash_bits(hashes[a]) != hash_bits(hashes[b])).sum()) for a, b in pairs])
    c_line, b_line = float(np.median(cos)), float(np.median(bits))
    info["cos"], info["bits"] = c_line, b_line
    nxt = {a: b for (a, b), c, d in zip(pairs, cos, bits) if c >= c_line and d <= b_line}
    runs: list[list[int]] = []
    for a in sorted(nxt, key=lambda i: (seqs[i], names[i])):
        if runs and runs[-1][-1] == a:
            runs[-1].append(nxt[a])
        else:
            runs.append([a, nxt[a]])
    for sid, run in enumerate(runs):
        for i in run:
            out[i] = sid
    return out, info


def write_similar(path: Path, names: list, clip, bits, seqs: list, bursts: list, line: dict) -> None:
    """cull/similar.npz: what the stacks were formed from, one row per frame.

    files  the frame's file name, the key everything else is read by
    clip   its unit CLIP vector, float16 (768 values)
    phash  its perceptual hash, 64 booleans
    seq    capture time in seconds (0 when the file carried none)
    burst  the time burst the cull put it in
    line   the card's median CLIP cosine and phash distance between
           back-to-back frames, and how many pairs that was measured on

    The cull forms its stacks from exactly these float16 vectors, so
    similar_stacks over this file gives the same stacks back. Written in one
    rename, like everything else the cull writes."""
    import io
    from common import write_atomic
    buf = io.BytesIO()
    np.savez(buf, files=np.array([str(n) for n in names]), clip=np.asarray(clip, dtype=np.float16),
             phash=np.asarray(bits, dtype=bool), seq=np.asarray(seqs, dtype=np.float64),
             burst=np.asarray(bursts, dtype=np.int32),
             line=np.array([line.get("cos") or 0.0, line.get("bits") or 0.0, line.get("pairs") or 0], dtype=np.float64))
    write_atomic(path, buf.getvalue())


def read_similar(path: Path) -> dict | None:
    """cull/similar.npz as a dict of arrays, or None when there is none or it
    does not read. Never unpickles: the file holds numbers and names only."""
    try:
        with np.load(path, allow_pickle=False) as z:
            return {k: z[k] for k in z.files}
    except (OSError, ValueError, KeyError):
        return None


def split_by_light(scene_ids: list[int], luma: "np.ndarray",
                   spread: float = 25.0, min_frames: int = 6) -> list[int]:
    """Split a semantic scene when the light inside it moves.

    CLIP is asked what a frame is of, so an hour in one gym is one scene to it
    however the light behaves, and the preset built for that scene is built for
    an average that describes none of it. Measured on a 1,157-frame action
    shoot: 1,141 frames in a single scene whose frame brightness ran from 31 to
    168 out of 255, well over two stops, under one preset.

    Frames in a scene are sorted by brightness and cut wherever the running
    group would exceed `spread`, so every part is at most that wide by
    construction. A part smaller than `min_frames` is left with its neighbour,
    because a preset is measured from the frames in it and a handful is not
    enough to measure from.

    Brightness only. This used to take a `warmth` argument as well, but nothing
    in the function read it and the caller had no colour temperature to hand, so
    it was always an array of zeros. Whether a scene should also split on colour
    temperature is a real question and an open one; it is not answered here.
    """
    out = list(scene_ids)
    nxt = max(scene_ids) + 1 if scene_ids else 0
    for sid in sorted(set(scene_ids)):
        idx = [i for i, s in enumerate(scene_ids) if s == sid]
        if len(idx) < min_frames * 2:
            continue
        v = luma[idx]
        if float(v.max() - v.min()) <= spread:
            continue
        order = sorted(range(len(idx)), key=lambda j: v[j])
        groups, cur = [], [order[0]]
        for j in order[1:]:
            if v[j] - v[cur[0]] > spread and len(cur) >= min_frames:
                groups.append(cur)
                cur = [j]
            else:
                cur.append(j)
        if len(cur) >= min_frames or not groups:
            groups.append(cur)
        else:
            groups[-1].extend(cur)
        for g in groups[1:]:                       # the first keeps the scene's id
            for j in g:
                out[idx[j]] = nxt
            nxt += 1
    return out


def scene_clusters(embs, n: int, cos_thresh: float = 0.90) -> list[int]:
    """Coarser than same-picture: frames of the same location and subject. Used so
    a --top N cut takes the best of every scene before the second-best of any."""
    parent = list(range(n))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    if embs is None or embs.shape[0] != n or np.abs(embs).sum() == 0:
        return list(range(n))
    with np.errstate(all="ignore"):
        sims = embs.astype(np.float64) @ embs.astype(np.float64).T
    for i in range(n):
        for j in np.where(sims[i] >= cos_thresh)[0]:
            if j > i:
                ra, rb = find(i), find(int(j))
                if ra != rb:
                    parent[rb] = ra
    roots = [find(i) for i in range(n)]
    ids = {r: k for k, r in enumerate(dict.fromkeys(roots))}
    return [ids[r] for r in roots]


# ------------------------------------------------------------------ measuring


def precision_at_k(scores: np.ndarray, truth: np.ndarray, k: int) -> float:
    top = np.argsort(-scores)[:k]
    return float(truth[top].sum()) / max(1, min(k, int(truth.sum())))


def load_weights(path: Path) -> dict[str, float]:
    return json.loads(path.read_text())
