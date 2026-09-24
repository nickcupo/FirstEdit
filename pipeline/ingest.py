#!/usr/bin/env python3
"""
ingest.py - copy a card to disk, verified, before anything touches it.

    ./pl ingest /Volumes/CARD 2026-10-04-lake
    ./pl ingest /Volumes/CARD 2026-10-04-lake --verify end

Puts every RAW and JPEG on the card in ~/photos/shoots/2026-10-04-lake/raw
(the camera's DCIM folders flattened into one). The card is never written to;
it stays the backup until the photos are delivered. A file already in raw/ is
never overwritten.

How hard the copy is checked is up to you, and it costs time on the card,
which is the slow end of this:

    in-flight  (default)  hash the bytes on their way past during the copy,
                          then read the copy back off the SSD and compare.
                          One pass over the card. Catches a bad write.
    end                   copy, then read the card a second time and hash
                          both sides. Two passes over the card, so on a
                          card reading at 95 MB/s a 27 GB shoot costs about
                          five minutes more. Catches a bad write and a card
                          that hands back different bytes on a second read,
                          which is what a failing card does.
    none                  copy, check the sizes match, stop. One pass, no
                          hashing. Fastest, and proves the least.

Prints `@@ copy done total` and `@@ verify done total` for a progress bar.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import (  # noqa: E402
    JPEG_EXTS, RAW_EXTS, NotEnoughRoom, human, require_space, stop_cleanly_on_sigterm)

ROOT = Path(os.environ.get("PHOTOS_ROOT", Path.home() / "photos")).expanduser()
EXTS = RAW_EXTS | JPEG_EXTS


CHUNK = 1 << 20


def sha(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as fh:
        for chunk in iter(lambda: fh.read(CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def copy_hashing(src: Path, dst: Path) -> str:
    """Copy and hash in one pass, so the card is read once instead of twice."""
    h = hashlib.sha256()
    with src.open("rb") as fi, dst.open("wb") as fo:
        for chunk in iter(lambda: fi.read(CHUNK), b""):
            h.update(chunk)
            fo.write(chunk)
        fo.flush()
        os.fsync(fo.fileno())
    shutil.copystat(src, dst)
    return h.hexdigest()


def names_for(p: Path, digest: str):
    """The names one card file may take in raw/, in the order it may take them.

    The DCIM folder settles a single card's 100MSDCF/101MSDCF rollover, which
    is the collision this sees most. It settles nothing between two bodies:
    both write 100MSDCF and both start at DSC00001, and two bodies at one
    event put their cards in the same raw/. So the name of last resort carries
    a piece of the frame's own hash, which nothing else on any card can equal."""
    yield p.name
    yield f"{p.stem}_{p.parent.name}{p.suffix}"
    n = 1
    while True:
        yield f"{p.stem}_{digest[:12]}{p.suffix}" if n == 1 else f"{p.stem}_{digest[:12]}-{n}{p.suffix}"
        n += 1


def place(p: Path, dest: Path) -> tuple[Path, bool]:
    """Where this frame goes in raw/, and whether it still has to be copied.

    A taken name is settled on the bytes, never on the size. Size carries
    almost no identity for this camera: across the 1,157 ARWs of one shoot,
    five byte sizes covered 1,066 of them, so "same name, same size" was
    evidence of nothing and the old test read it as proof the frame was
    already ingested. It then recorded the card's file against the first
    file's copy, and every hash after that was taken on the wrong pair.

    Same bytes means already ingested, so say so and copy nothing. Different
    bytes means two real frames, so both are kept."""
    out = dest / p.name
    if not out.exists():
        return out, True
    digest = sha(p)
    for name in names_for(p, digest):
        out = dest / name
        if not out.exists():
            return out, True
        if out.stat().st_size == p.stat().st_size and sha(out) == digest:
            return out, False
    raise AssertionError("names_for never runs out")


def main() -> int:
    ap = argparse.ArgumentParser(description="copy a card to disk", add_help=True)
    ap.add_argument("card", type=Path, help="the card, or any folder of files")
    ap.add_argument("name", help="the shoot name, like 2026-10-04-lake")
    ap.add_argument("--verify", choices=("in-flight", "end", "none"), default="in-flight",
                    help="in-flight: hash while copying, read the copy back off the SSD (one pass over the card, the default). "
                         "end: re-read the card and hash both sides (two passes; also catches a card that reads back differently). "
                         "none: sizes only.")
    args = ap.parse_args()
    stop_cleanly_on_sigterm()
    card, name = args.card, args.name
    src = card / "DCIM" if (card / "DCIM").is_dir() else card
    if not src.is_dir():
        print(f"no such folder: {src}")
        return 1
    dest = ROOT / "shoots" / name / "raw"
    files = sorted(p for p in src.rglob("*") if p.is_file() and p.suffix.lower() in EXTS and not p.name.startswith("."))
    if not files:
        print(f"nothing to copy: no RAW or JPEG under {src}")
        return 1
    total = sum(p.stat().st_size for p in files)
    # What a run that is finishing an interrupted one would actually write.
    # This asked for room for the whole card every time, so the copy that died
    # on a full volume - the one case the check below exists for - was refused
    # on its second attempt for the frames it was not going to copy again.
    # Name and size here, not the bytes: place() settles what is really the
    # same frame, by reading them, when it gets there.
    def here(p: Path) -> bool:
        out = dest / p.name
        try:
            return out.stat().st_size == p.stat().st_size
        except OSError:
            return False
    need = sum(p.stat().st_size for p in files if not here(p))
    print(f"copying {len(files)} files, {total / 1e9:.1f} GB, {src} -> {dest}")
    if need < total:
        print(f"{human(total - need)} of that is already in raw/ under the same name and size; "
              f"asking for room for the rest")
    # Ask for the room before the first frame. A card copy that fills the
    # volume dies part way through, and what it leaves behind is a raw/ that
    # looks like a shoot and is missing its last two hundred frames.
    try:
        require_space(dest, need, f"the copy of {len(files)} files from {src}")
    except NotEnoughRoom as e:
        print(f"\n{e}", file=sys.stderr)
        return 1
    # The folder is made only once the run is going to happen. It used to be
    # the first thing done, so a card with nothing on it, or a volume with no
    # room, left an empty shoot behind - and the studio then answers "<name>
    # already exists" to the person typing the same name again.
    dest.mkdir(parents=True, exist_ok=True)
    # And the shoot starts with the folder its decisions belong in. Without
    # it, common.decision_path takes the shoot's own convention to be cull/,
    # so the first star of a brand new shoot lands inside the cache folder and
    # has to be migrated back out later.
    (dest.parent / "decisions").mkdir(exist_ok=True)
    print(f"@@ copy 0 {len(files)}")
    # In flight, the copy itself produces the source hash; a file that was
    # already there was not read, so it has none and falls back to the card.
    hashing = args.verify == "in-flight"
    pairs: list[tuple[Path, Path, str | None]] = []
    def put(src: Path, out: Path) -> str | None:
        """Land the bytes under a hidden temp name beside their destination and
        rename only once they are all down. A kill, a sleep or a full volume
        part way through a copy used to leave a short file under the frame's
        real name, and nothing downstream can tell a short ARW from a whole
        one: the next run saw the name taken and called the frame ingested.
        os.replace is atomic within a filesystem, so raw/ ends up holding
        either nothing or the entire frame."""
        tmp = out.with_name(f".{out.name}.tmp{os.getpid()}")
        try:
            if hashing:
                digest = copy_hashing(src, tmp)
            else:
                shutil.copy2(src, tmp)
                digest = None
            os.replace(tmp, out)
            return digest
        except BaseException:
            try:
                tmp.unlink()
            except OSError:
                pass
            raise

    collisions: list[str] = []
    ours: dict[str, Path] = {}       # what THIS run wrote, by the name it wrote it under
    for i, p in enumerate(files, 1):
        out, fresh = place(p, dest)
        if fresh:
            ours[out.name] = out
        if not fresh:
            collisions.append(f"{p} is already in raw/, byte for byte, as {out} - not copied again")
        elif out.name != p.name:
            collisions.append(f"{p} is a different frame from {dest / p.name} - copied as {out}")
        # Nothing joins pairs that was not written: a pair whose copy was never
        # made is a frame the verify pass then declares good.
        digest = put(p, out) if fresh else None
        pairs.append((p, out, digest))
        if i % 5 == 0 or i == len(files):
            print(f"@@ copy {i} {len(files)}", flush=True)

    bad = []
    if args.verify == "none":
        print("not hashing (--verify none); checking sizes only")
        bad = [out.name for p, out, _ in pairs if not out.exists() or out.stat().st_size != p.stat().st_size]
    else:
        print("reading the copy back off the disk..." if hashing else "verifying every byte, both sides...")
        print(f"@@ verify 0 {len(pairs)}")
        for i, (p, out, digest) in enumerate(pairs, 1):
            if (digest if digest is not None else sha(p)) != sha(out):
                bad.append(out.name)
            if i % 5 == 0 or i == len(pairs):
                print(f"@@ verify {i} {len(pairs)}", flush=True)
    # A frame that was skipped or renamed must never be silent: it is the one
    # case where the count at the end does not match the count on the card.
    if collisions:
        print(f"{len(collisions)} name collision(s):")
        for line in collisions:
            print(f"  {line}")
    if bad:
        print("verification FAILED for: " + ", ".join(bad[:20]))
        # A copy that did not verify stays on the disk under the frame's real
        # name, and nothing downstream can tell it from a good one: the cull
        # reads it as the photograph, and the next ingest sees the name taken,
        # finds the bytes differ from the card's and copies the frame again
        # under another name, leaving the bad one where it is. Only what this
        # run wrote is renamed - a file that was already there is not ours to
        # touch - and it is renamed rather than removed, because the card may
        # be the thing that is failing and those bytes are still evidence.
        aside = []
        for nm in bad:
            out = ours.get(nm)
            if out is None or not out.exists():
                continue
            spare = out.with_name(out.name + ".unverified")
            n = 2
            while spare.exists():
                spare = out.with_name(f"{out.name}.unverified-{n}")
                n += 1
            os.replace(out, spare)
            aside.append(spare.name)
        if aside:
            print(f"{len(aside)} of those were written by this run and have been renamed, so nothing")
            print(f"reads them as a photograph and the name is free to copy again: {', '.join(aside[:6])}"
                  + (f", and {len(aside) - 6} more" if len(aside) > 6 else ""))
            print("The card was not written to; copy it again.")
        return 1
    proof = {"in-flight": "hashed on the way in and read back", "end": "verified byte for byte, both sides",
             "none": "not hashed; sizes match"}[args.verify]
    print(f"{len(pairs)} files in {dest}, {proof}")
    print(f"next:  ./pl studio    (or ./pl cull \"{dest}\" --copy, then ./pl presets after you have chosen your keepers)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
