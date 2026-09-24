#!/usr/bin/env python3
"""
eval_pets.py - the animal gate against the Oxford-IIIT Pet dataset.

YuNet reads a cat or dog head as a human face often enough to matter, and a
"face" that reads soft or blinking would veto the frame. The gate (a YOLOX
cat/dog box around the face, or CLIP's animal prompt at 0.45) turns those
verdicts into questions. This measures how often it fires on a named public
dataset instead of on one photographer's dog: 3,686 of the 11,086 photos
carry a head box drawn by the dataset's authors (CC BY-SA 4.0), and 3,671 of
those have an image in the parquet mirror below.

    ./pl setup
    .venv/bin/python pipeline/eval_pets.py            # 600 sampled images
    .venv/bin/python pipeline/eval_pets.py 3686       # all 3,671 of them

Needs, once:
    annotations.tar.gz from https://www.robots.ox.ac.uk/~vgg/data/pets/
      extracted so that <data>/annotations/xmls/*.xml exists
    data/train-00000-of-00001.parquet from the timm/oxford-iiit-pet mirror on
      Hugging Face (same data, same licence, fast download), at
      <data>/hf/data/train-00000-of-00001.parquet
with <data> = $PHOTOS_ROOT/datasets/oxford-pets (the library) or $PETS_DIR.
"""

from __future__ import annotations

import glob
import os
import random
import sys
import warnings
import xml.etree.ElementTree as ET
from pathlib import Path

warnings.filterwarnings("ignore")
os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"

import cv2  # noqa: E402
import numpy as np  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
import faces as fmod  # noqa: E402
# The faults that veto, read from the file that defines them. This was a
# hand-written copy and had already drifted: it still listed "motion blur" and
# "mid-word", two strings no rule in flag() can produce.
HARD = fmod.HARD_FACE_FLAGS


def head_box(xml: str) -> tuple[str, tuple[int, int, int, int]]:
    o = ET.parse(xml).getroot().find("object")
    b = o.find("bndbox")
    return o.find("name").text, tuple(int(b.find(k).text) for k in ("xmin", "ymin", "xmax", "ymax"))


def centre_in(box, hb) -> bool:
    x, y, w, h = box
    cx, cy = x + w / 2, y + h / 2
    return hb[0] <= cx <= hb[2] and hb[1] <= cy <= hb[3]


def covers(boxes, hb) -> bool:
    hx, hy = (hb[0] + hb[2]) / 2, (hb[1] + hb[3]) / 2
    return any(bx <= hx <= bx + bw and by <= hy <= by + bh for bx, by, bw, bh in boxes)


def load(data: Path, n: int) -> list[tuple[str, bytes, str, tuple]]:
    import pyarrow.parquet as pq
    xmls = {os.path.basename(x)[:-4]: x for x in glob.glob(str(data / "annotations" / "xmls" / "*.xml"))}
    pf = pq.ParquetFile(data / "hf" / "data" / "train-00000-of-00001.parquet")
    rows = []
    for batch in pf.iter_batches(batch_size=256, columns=["image", "image_id"]):
        for im, iid in zip(batch.column("image").to_pylist(), batch.column("image_id").to_pylist()):
            if iid in xmls:
                rows.append((iid, im["bytes"], *head_box(xmls[iid])))
    random.seed(0)
    random.shuffle(rows)
    return rows[:n]


def main() -> int:
    from faces import FaceJudge
    from quality import Quality
    # Under the library PHOTOS_ROOT names, like every other dataset this
    # repo reads (evaluate.py resolves PETS_DIR the same way). The literal
    # "~/photos" here meant a run on a scratch clone still read the real one.
    photos = Path(os.environ.get("PHOTOS_ROOT", Path.home() / "photos")).expanduser()
    data = Path(os.environ.get("PETS_DIR", photos / "datasets" / "oxford-pets")).expanduser()
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 600
    rows = load(data, n)
    judge = FaceJudge(quality=Quality())
    total = read = yolo = g_box = g_clip = g_any = veto = 0
    species: dict[str, list[int]] = {}
    for stem, raw, sp, hb in rows:
        img = cv2.imdecode(np.frombuffer(raw, np.uint8), cv2.IMREAD_COLOR)
        if img is None:
            continue
        total += 1
        boxes = judge._animal_boxes(img)
        yolo += covers(boxes, hb)
        fs = judge.detect(img)
        judge.judge(img, fs, animal_boxes=boxes)
        for f in fs:
            judge.flag(f, 1.9)
        on_head = [f for f in fs if f.main and centre_in(f.box, hb)]
        if not on_head:
            continue
        read += 1
        s = species.setdefault(sp, [0, 0])
        s[0] += 1
        by_box = any(f.in_animal for f in on_head)
        by_clip = any(f.clip.get("animal", 0) >= fmod.ANIMAL_GATE for f in on_head)
        g_box += by_box
        g_clip += by_clip
        if by_box or by_clip:
            g_any += 1
            s[1] += 1
        else:
            hard = sorted({fl for f in on_head for fl in f.flags if fl in HARD})
            veto += bool(hard)
            print(f"  ungated {stem}: clip animal {max(f.clip.get('animal', 0) for f in on_head):.2f}"
                  + (f", would veto for {', '.join(hard)}" if hard else ", no hard flag"))
    print(f"\nimages: {total}   a YOLOX cat/dog box covers the head: {yolo} ({100 * yolo / total:.1f}%)")
    print(f"YuNet read the head as a human face: {read} ({100 * read / total:.1f}%)")
    if read:
        print(f"  gated by the box: {g_box} ({100 * g_box / read:.1f}%)   by CLIP: {g_clip} ({100 * g_clip / read:.1f}%)"
              f"   by either: {g_any} ({100 * g_any / read:.1f}%)")
        print(f"  ungated with a hard flag, so the frame would be vetoed: {veto} ({100 * veto / read:.1f}%)")
        for sp, (a, g) in sorted(species.items()):
            print(f"  {sp}: {a} read as faces, {g} gated ({100 * g / a:.0f}%)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
