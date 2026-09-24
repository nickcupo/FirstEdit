#!/usr/bin/env python3
"""Fetch the five small models into a folder, and prove each one is the file it
claims to be.

    pipeline/fetch_models.py <folder>

Every weight is pinned by SHA-256 in models.json. A file already on disk that
hashes correctly is left alone; one that does not is replaced, and a download
that arrives wrong is deleted rather than kept. CLIP is not here: it is 1.7 GB
and comes through the Hugging Face hub in fetch_clip.py.

This is a module rather than five lines of shell because the check has to mean
something. The test it replaces was `[ -s file ]`, which asks only whether a
file is non-empty, and a 131-byte Git LFS pointer satisfied it for days while
standing in for the 227 KB face detector. The URLs also name a mutable branch,
so what arrives today need not be what arrived last week.
"""
from __future__ import annotations

import hashlib
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from common import model_manifest  # noqa: E402

CHUNK = 1 << 20


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(url: str, dest: Path) -> None:
    """Straight to a temp name beside the target, so an interrupted download
    never leaves something that looks finished."""
    tmp = dest.with_name(dest.name + ".part")
    try:
        with urllib.request.urlopen(url, timeout=120) as r, open(tmp, "wb") as fh:
            while True:
                chunk = r.read(CHUNK)
                if not chunk:
                    break
                fh.write(chunk)
        tmp.replace(dest)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("pipeline/fetch_models.py <folder>", file=sys.stderr)
        return 2
    out = Path(argv[1]).expanduser()
    out.mkdir(parents=True, exist_ok=True)

    models = model_manifest()
    if not models:
        print(f"no manifest at {HERE / 'models.json'}", file=sys.stderr)
        return 1

    for e in models:
        path = out / e["file"]
        if path.exists() and path.stat().st_size == e["bytes"] and sha256(path) == e["sha256"]:
            continue
        if path.exists():
            print(f"  {e['file']} is on disk but is not the file it should be; fetching it again")
            path.unlink()
        try:
            fetch(e["url"], path)
        except (urllib.error.URLError, OSError) as err:
            print(f"could not fetch {e['file']}: {err}", file=sys.stderr)
            print(f"  from {e['url']}", file=sys.stderr)
            return 1
        got = sha256(path)
        if got != e["sha256"]:
            path.unlink(missing_ok=True)
            print(f"refusing {e['file']}: expected {e['sha256']}, got {got}", file=sys.stderr)
            print("  The download did not arrive intact, or upstream has changed the file.",
                  file=sys.stderr)
            return 1
        print(f"  {e['file']} ok")

    print(f"models in {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
