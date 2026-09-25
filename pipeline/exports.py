"""Where a shoot's finished JPEGs are.

One answer for everything that needs the exported file of a frame rather than
the fact that it was exported: the Instagram crops, and anything an extension
publishes. It used to live in one caller and would have been written again in
the next.

A frame's finished photograph is in export/ or edit/ (PhotoLab's default lands
beside the RAWs), and the newest file of a frame there wins. iCloud comes next,
but only for an export NEWER than this shoot's RAW of the same name: the camera
reuses its file numbers, and another shoot's TSC04534 in the shared folder is
not this one's. reels/ (a burst's frames exported for a cut) and upload/ come
last, for a frame that has no other export: a burst frame can be exported for
a reel after the still, with another edit, and the newest file winning across
every folder put that edit where his finished photograph belongs - an
Instagram copy cut from a picture he never finished as a still. The uploader's
own previews under _store/ are never exports.
"""
from __future__ import annotations

import csv
import glob
from pathlib import Path

import library

HERE_DIRS = ("export", "edit", "reels", "upload")
# Which export of a frame is its finished photograph: the lowest rank that has
# one, then the newest within that rank.
RANK = {"export": 0, "edit": 0, "reels": 2, "upload": 2}
ICLOUD_RANK = 1


def frames(shoot: Path) -> dict[str, Path]:
    """Stem -> the RAW, for every frame the cull knows about.

    The cull folder is the one every command reads (library.cull_dir): the
    one holding cull.csv, then whichever of cull/ and _cull/ is on disk,
    else cull/. This had a rule of its own that once answered `_cull` for
    every flat shoot and later took whichever folder existed, so a flat
    shoot's cull.csv went unread and a delivered shoot reported no exports
    at all.

    The RAW is found by number (library.frame_raw): the cull can name a
    frame by the camera JPEG it decoded, and raw/TSC04016.jpg is never there
    beside raw/TSC04016.ARW, so on such a shoot no iCloud export could be
    held to a RAW's date and none was ever matched. A frame whose RAW has
    gone keeps the name the cull gave it, which does not exist, as before."""
    p = library.paths(shoot)
    f = p.cull / "cull.csv"
    if not f.exists():
        return {}
    have = library.raw_index(p.shoot)
    with f.open() as fh:
        return {Path(r["file"]).stem: have.get(Path(r["file"]).stem) or p.raw / r["file"]
                for r in csv.DictReader(fh)}


def stem_of(name: str) -> str:
    return name.split("_DxO")[0].rsplit(".", 1)[0]


def files(shoot: Path, want: set[str] | None = None) -> dict[str, Path]:
    """Stem -> the exported JPEG of that frame: its finished photograph, by
    the ranks above.

    `want` narrows it to those frames (the studio passes the set it counts as
    exported, so this cannot disagree with its front page); without it, every
    frame of the shoot is looked for. iCloud is walked only for a wanted frame
    this shoot's export/ and edit/ do not have: the studio asks for a wall's
    worth of frames every few seconds while it works, and walking iCloud's
    folders each time bought nothing when every one of them was here."""
    shoot = library.shoot_root(shoot)
    raws = frames(shoot)
    want = set(want) if want is not None else set(raws)
    best: dict[str, tuple[int, float, Path]] = {}

    def take(f: Path, rank: int, floor: float = 0.0) -> None:
        if "_store" in f.parts:
            return
        s = stem_of(f.name)
        if s not in want:
            return
        try:
            m = f.stat().st_mtime
        except OSError:
            return
        if m < floor:
            return
        was = best.get(s)
        if was is None or rank < was[0] or (rank == was[0] and m > was[1]):
            best[s] = (rank, m, f)

    for d in HERE_DIRS:
        root = shoot / d
        if root.is_dir():
            for f in root.rglob("*.jp*g"):
                take(f, RANK[d])
    need = {s for s in want if s not in best or best[s][0] > ICLOUD_RANK}
    if need:
        try:
            import taste
            for pat in taste.EXPORTS:
                if "shoots" in str(pat):
                    continue                    # this shoot's own folders are done above
                for f in glob.glob(str(pat), recursive=True):
                    f = Path(f)
                    s = stem_of(f.name)
                    raw = raws.get(s)
                    if s in need and raw is not None and raw.exists():
                        take(f, ICLOUD_RANK, floor=raw.stat().st_mtime)
        except Exception:  # noqa: BLE001
            pass                                # iCloud unreadable is not no exports
    return {s: v[2] for s, v in best.items()}
