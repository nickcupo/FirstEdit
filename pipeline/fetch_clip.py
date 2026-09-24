#!/usr/bin/env python3
"""
fetch_clip.py - get CLIP ViT-L/14 (about 1.7 GB) into the cache the cull reads.

    ./pl fetch-clip

Downloads through open_clip so the file lands exactly where the cull will
look (the Hugging Face cache, or PIPELINE_CLIP_CACHE). Prints `@@ clip
done total` lines in megabytes for a progress bar, and first tries to copy
an existing download from the default cache so a machine that already has
the weights does not fetch them twice.
"""

from __future__ import annotations

import os
import shutil
import sys
import threading
import time
from pathlib import Path

os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import CLIP_CACHE, CLIP_FILE, CLIP_REPO, clip_ready  # noqa: E402

EXPECTED_MB = 1631  # open_clip_model.safetensors for ViT-L/14 openai; refined from the hub when it answers


def seed_from_default_cache() -> None:
    """If the weights are already in ~/.cache/huggingface and we are told to
    use another cache, copy the repo folder across instead of downloading."""
    if not CLIP_CACHE or clip_ready():
        return
    from huggingface_hub import constants
    folder = "models--" + CLIP_REPO.replace("/", "--")
    src = Path(constants.HF_HUB_CACHE) / folder
    dst = Path(CLIP_CACHE) / folder
    if src.is_dir() and not dst.exists():
        print(f"  copying the weights already on this machine from {src}")
        shutil.copytree(src, dst, symlinks=True)


def total_bytes(root: Path) -> int:
    return sum(p.stat().st_size for p in root.rglob("*") if p.is_file() and not p.is_symlink())


def main() -> int:
    if clip_ready():
        print("  CLIP is already here")
        print(f"@@ clip {EXPECTED_MB} {EXPECTED_MB}")
        return 0
    seed_from_default_cache()
    if clip_ready():
        print("  CLIP copied from the existing cache")
        print(f"@@ clip {EXPECTED_MB} {EXPECTED_MB}")
        return 0
    expected = EXPECTED_MB
    try:
        from huggingface_hub import HfApi
        info = HfApi().model_info(CLIP_REPO, files_metadata=True)
        expected = max(expected, sum((s.size or 0) for s in info.siblings if s.rfilename == CLIP_FILE) // 1_000_000)
    except Exception:  # noqa: BLE001
        pass
    from huggingface_hub import constants
    root = Path(CLIP_CACHE) if CLIP_CACHE else Path(constants.HF_HUB_CACHE)
    root.mkdir(parents=True, exist_ok=True)
    folder = root / ("models--" + CLIP_REPO.replace("/", "--"))
    before = total_bytes(folder) if folder.exists() else 0
    err: list[BaseException] = []

    def work():
        try:
            from open_clip.pretrained import download_pretrained, get_pretrained_cfg
            cfg = get_pretrained_cfg("ViT-L-14-quickgelu", "openai")
            download_pretrained(cfg, cache_dir=CLIP_CACHE)
        except BaseException as e:  # noqa: BLE001
            err.append(e)

    t = threading.Thread(target=work, daemon=True)
    t.start()
    print(f"  downloading CLIP ViT-L/14, about {expected} MB, once")
    print(f"@@ clip 0 {expected}")
    while t.is_alive():
        time.sleep(2)
        have = (total_bytes(folder) - before) // 1_000_000 if folder.exists() else 0
        print(f"@@ clip {min(have, expected - 1)} {expected}", flush=True)
    if err:
        print(f"  download failed: {err[0]}")
        return 1
    if not clip_ready():
        print("  the download finished but the weights are not where the cull looks; see the log")
        return 1
    print(f"@@ clip {expected} {expected}")
    print("  done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
