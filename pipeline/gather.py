#!/usr/bin/env python3
"""
gather.py - one folder to open in PhotoLab: your keepers and their sidecars.

The cull writes `cull/picks/`, which is its own suggestion, and the preset step
writes `.dop` sidecars next to the RAWs in `raw/`, which is 1,157 files you have
to filter every time. Neither is the thing you actually want, which is a folder
holding the frames you chose and nothing else, each with its edit beside it.

    ./pl gather ~/photos/shoots/2026-10-04-lake

Makes `<shoot>/edit/`, containing every frame you kept and its `.dop`. The RAWs
are hard links, so the folder costs no disk and the originals stay where they
are. A sidecar you edit in here is promoted back beside its RAW before the
folder is rebuilt, and one that cannot be promoted is copied into
`<shoot>/decisions/sidecars-set-aside/` rather than removed, so rebuilding
loses nothing of yours - with `--fresh` too. Open `edit/` in PhotoLab and every
frame in it is one you asked for, already carrying its starting edit.

Run it again after changing your mind and it rebuilds from scratch.
"""

from __future__ import annotations

import csv
import hashlib
import json
import os
import re
import shutil
import time

from common import RAW_EXTS, decision_path, decisions_dir, human, stop_cleanly_on_sigterm, write_atomic
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# Where a sidecar goes when gather will not overwrite it and will not throw it
# away either. Beside the decisions, because that is what a sidecar holds, and
# dated, because the reason it is here is that two versions of one edit
# disagreed and only he can say which he meant.
SET_ASIDE = "sidecars-set-aside"


def _block(text: str, name: str) -> str:
    m = re.search(rf"\n(\t+){name} = \{{\n(.*?)\n\1\}},", text, re.S)
    return m.group(2) if m else ""


def cull_of(shoot: Path, raw: Path) -> Path:
    """This shoot's cull folder: whichever is on disk, else `cull/` beside the
    frames. A flat folder's cull is <shoot>/cull, which is where library.py and
    reclaim.py both look; `_cull` is the old fork's name and is still read
    wherever one is on a disk."""
    for name in ("cull", "_cull"):
        if (shoot / name).is_dir():
            return shoot / name
    return shoot / "cull"


def _set_aside(cull: Path, src: Path, whose: str) -> Path:
    """Copy a sidecar out of the way before anything here removes or replaces
    it, and say where it went. Additive: the copy is made first and the
    original is only touched afterwards, by the caller."""
    dest = decisions_dir(cull) / SET_ASIDE / time.strftime("%Y-%m-%d %H%M") / whose / src.name
    dest.parent.mkdir(parents=True, exist_ok=True)
    write_atomic(dest, src.read_bytes())
    shutil.copystat(src, dest)
    return dest


def harvest(out: Path, raw: Path, cull: Path | None = None) -> int:
    """Before edit/ is rebuilt, keep what the photographer did in it.

    A sidecar in edit/ that differs from the copy beside the RAW and carries a
    later ModificationDate - the date PhotoLab writes inside the file - is the
    photographer's newer work, and it is promoted into raw/ before anything
    here is removed.

    Whether it "looks like" an edit is not asked any more. It used to be:
    taste.is_hand reads the keys PhotoLab materialises the moment it opens a
    file - the crop, the white balance, the lens corrections - as not the
    photographer's, which is right for learning from a sidecar and wrong for
    this. A frame the photographer had only cropped, or only warmed, held none
    of the other keys, so harvest passed over it and clear() then unlinked it:
    the edit was gone, and nothing said so.

    mtime is not the date used, because a star the studio writes into raw/
    bumps it with no edit of his behind it."""
    n = 0
    for side in sorted(out.glob("*.dop")):
        text = side.read_text(errors="ignore")
        target = raw / side.name
        if target.exists() and target.read_bytes() == side.read_bytes():
            continue                              # the copy gather put here
        if target.exists():
            theirs = target.read_text(errors="ignore")
            if _written(theirs) >= _written(text):
                # The copy beside the RAW is the newer one (the preset step ran
                # again, say). The one here is not promoted - and clear() sets
                # it aside rather than removing it.
                continue
            if _block(theirs, "Overrides").strip() and cull is not None:
                # Whatever is about to be replaced is kept: PhotoLab has
                # written in that file too, and only he can say which of two
                # edits of one frame he meant.
                _set_aside(cull, target, "raw")
        # His own edit, landing on top of the copy beside the RAW. Half a
        # .dop there is not a lost edit, it is PhotoLab refusing to launch
        # past it and never saying which file: it lands whole or not at
        # all. copystat after, because presets.py keys its sidecar cache
        # on the mtime a copy used to carry.
        write_atomic(target, side.read_bytes())
        shutil.copystat(side, target)
        n += 1
    return n


def _written(text: str) -> str:
    """When PhotoLab last wrote this sidecar, from the file itself."""
    m = re.search(r'^\s*ModificationDate = "([^"]+)"', text, re.M)
    return m.group(1) if m else ""


def clear(out: Path, raw: Path, cull: Path) -> tuple[int, list[Path]]:
    """Take out of edit/ only what gather put there: the RAW links and the
    sidecars at its top level. Anything else, a subfolder of exports, a JPEG,
    a note, is the photographer's and stays. This used to be shutil.rmtree,
    and the photographer's 154 finished exports lived in edit/edited/.

    A sidecar that is not the copy gather made is set aside first. After
    harvest the only ones left in that state are the ones it would not promote
    - the copy beside the RAW was newer - and with --fresh it is every edit
    made in here, which this used to delete without a word."""
    n = 0
    aside: list[Path] = []
    for p in sorted(out.iterdir()):
        if p.is_dir():
            continue
        # write_atomic's own leftovers: hidden, our prefix, our suffix, and
        # only ever present because a write here was killed part way. They are
        # unambiguously the pipeline's, so they go with the rest of what the
        # pipeline put here rather than sitting invisibly in the folder the
        # photographer opens in PhotoLab.
        if p.name.startswith(".") and ".tmp" in p.name:
            p.unlink()
            continue
        if p.name.lower().endswith(".dop"):
            target = raw / p.name
            if not (target.exists() and target.read_bytes() == p.read_bytes()):
                aside.append(_set_aside(cull, p, "edit"))
            p.unlink()
            n += 1
        elif p.suffix.lower() in RAW_EXTS:
            p.unlink()
            n += 1
    return n, aside


def _burst(r: dict) -> str:
    """How the web page keys a burst: scene and burst together. The burst
    column is the TIME burst and is numbered across the whole shoot; the page
    split one time burst into a piece per scene, and every piece it marked
    been through is recorded under this key."""
    return f'{r.get("scene", "")}/{r.get("burst", "")}'


def time_burst(r: dict) -> str:
    """The key of the time burst a frame belongs to, as the studio's burst list
    names it (GET /api/shoot's bursts[].id) and as the app records it been
    through. A key with no "/" in it is one of these."""
    return str(r.get("burst", ""))


def _overrides(cull: Path) -> dict[str, int]:
    """The stars he pressed."""
    p = decision_path(cull, "organize.json")
    try:
        photos = json.loads(p.read_text()).get("photos", {})
    except (OSError, ValueError):
        return {}
    return {k: int(v["rating"]) for k, v in photos.items() if v.get("rating") is not None}


def _cull_stamp(rows: list[dict]) -> str:
    """Which cull a burst number belongs to. Both numbers are handed out afresh
    by every cull run, so a record of bursts he has been through means nothing
    against a different one. studio.py Shoot.cull_stamp computes this same
    hash; the two have to agree, because this reads the file that one writes."""
    h = hashlib.sha1()
    for r in sorted(rows, key=lambda r: r["file"]):
        h.update(f"{r['file']}\t{_burst(r)}\n".encode())
    return h.hexdigest()[:16]


def seen_bursts(cull: Path, rows: list[dict], over: dict[str, int]) -> set[str]:
    """The bursts he has actually been through, as the studio records them.

    review.json is his record of having looked: leaving a burst forward marks
    it. A file written against an earlier cull is not read - its keys name
    frames that grouping no longer has - and a shoot worked before that file
    existed falls back to the same evidence the studio uses, which is a burst
    holding a star of his."""
    try:
        d = json.loads(decision_path(cull, "review.json").read_text())
    except (OSError, ValueError):
        d = {}
    bursts = d.get("bursts") if isinstance(d.get("bursts"), dict) else {}
    # "from" and no "seen" is a burst seeded from his overrides before the mark
    # was written; it says what it always said.
    seen = {k for k, v in bursts.items() if isinstance(v, dict) and (v.get("seen") or v.get("from"))}
    was = str(d.get("cull") or "")
    if seen and was and was != _cull_stamp(rows):
        seen = set()
    if not seen:
        seen = {_burst(r) for r in rows if r["file"] in over}
    # Two spellings of one record. The page marked a scene/burst piece; the app
    # marks a whole time burst, which is every piece of it. The pieces are
    # what every reader below asks for, so a time burst is spelled out into
    # its pieces here, once, and the key it came in as is kept beside them.
    times = {k for k in seen if "/" not in k}
    if times:
        seen |= {_burst(r) for r in rows if time_burst(r) in times}
    return seen


def _answer_key(cull: Path, rows: list[dict]) -> set[str]:
    """The frames named in selects.json, under the names this cull uses.

    Matched on the stem: a shoot culled from its decodes after its RAWs were
    cleared has cull.csv keyed on TSC04015.jpg and its answer key on
    TSC04015.ARW, and those are one frame."""
    try:
        chosen = json.loads(decision_path(cull, "selects.json").read_text())
    except (OSError, ValueError):
        return set()
    if not isinstance(chosen, list):
        return set()               # not an answer key; an unreadable one is not a smaller one
    by_stem = {Path(r["file"]).stem: r["file"] for r in rows}
    return {by_stem.get(Path(str(x)).stem, Path(str(x)).name) for x in chosen}


def keepers(cull: Path) -> list[str]:
    """The frames HE kept, in the cull's own order.

    Three sources and all three are his: a star he pressed, the cull's own
    pick in a burst he has been through and left standing, and the answer key
    for the shoots he worked before there was a record of being through a
    burst. The cull's rating on its own is not one of them and must not be:
    this built the folder called "the frames you kept" out of every frame the
    machine rated 3 or more, including the 90 picks in the 56 bursts of one
    shoot he had never opened - and the studio then read that folder back as
    frames he had accepted, so the machine's shortlist became his answer key
    by way of a folder. studio.py kept_by_him counts the same three sources."""
    rows = list(csv.DictReader((cull / "cull.csv").open()))
    mine = verdicts(cull, rows)
    return [r["file"] for r in rows if mine.get(r["file"])]


def verdicts(cull: Path, rows: list[dict]) -> dict[str, bool]:
    """Every frame he has a verdict on: True kept, False not. A frame with no
    entry is one nobody has looked at, which is neither.

    The rule keepers() builds the folder from, and the one the studio counts
    "you kept" by, so the number on the card and the folder he opens cannot
    disagree. `rows` are cull.csv's, as the caller already has them."""
    over = _overrides(cull)
    seen = seen_bursts(cull, rows, over)
    chosen = _answer_key(cull, rows)
    out: dict[str, bool] = {}
    for r in rows:
        f = r["file"]
        if f in over:
            out[f] = over[f] >= 3                 # a demotion of his wins over everything
        elif f in chosen:
            out[f] = True
        elif _burst(r) in seen:
            out[f] = int(r["rating"] or 0) >= 3   # he went through it and left it standing
    return out


def unreviewed_picks(cull: Path) -> int:
    """How many of the cull's own picks are in bursts he has not been through.
    What he would have been handed as "the frames you kept" before, and the
    number the message names when there is nothing of his to gather yet."""
    rows = list(csv.DictReader((cull / "cull.csv").open()))
    over = _overrides(cull)
    seen = seen_bursts(cull, rows, over)
    return sum(1 for r in rows if int(r["rating"] or 0) >= 3
               and r["file"] not in over and _burst(r) not in seen)


def build(shoot: Path, fresh: bool = False) -> Path:
    """Make <shoot>/edit and return it. Raises if there is nothing to gather."""
    return _build(Path(shoot), fresh)[0]


def build_with_summary(shoot: Path, fresh: bool = False) -> tuple[Path, dict]:
    """Build once and return a JSON-safe account of which keepers are available.
    Missing names are the cull's names, not guessed original filenames."""
    out, counts = _build(Path(shoot), fresh)
    return out, {"total": counts["frames"], "gathered": counts["linked"] + counts["copied"],
                 "missing": counts["missing"], "missing_files": counts["missing_files"]}


def _original(raw: Path, name: str) -> Path | None:
    """Keep exact filenames; recover preview names by a unique, case-sensitive
    stem and a known RAW suffix, as the engine identifies recull frames.
    Never guess between two camera originals or treat a sidecar as a frame."""
    if Path(name).name != name or name in ("", ".", ".."):
        raise ValueError("invalid keeper filename; edit/ was left as it is")
    exact = raw / name
    if exact.is_file():
        return exact
    candidates = [p for p in raw.iterdir()
                  if p.is_file() and p.stem == Path(name).stem
                  and p.suffix.lower() in RAW_EXTS]
    if len(candidates) > 1:
        raise ValueError(f"more than one original matches {name}; edit/ was left as it is. "
                         "Resolve the duplicate originals before gathering again")
    return candidates[0] if candidates else None


def _build(shoot: Path, fresh: bool) -> tuple[Path, dict]:
    """The whole of it, with the counts a person would want read back.

    One implementation, not two: the command and the studio's Open in PhotoLab
    button build the same folder, and the second copy of this had neither the
    refusal below nor the sidecars set aside."""
    shoot = Path(shoot).expanduser().resolve()
    raw = shoot / "raw" if (shoot / "raw").is_dir() else shoot
    cull = cull_of(shoot, raw)
    if not (cull / "cull.csv").exists():
        raise FileNotFoundError("this shoot has not been culled yet")
    files = keepers(cull)
    if not files:
        n = unreviewed_picks(cull)
        raise ValueError("nothing is kept yet"
                         + (f"; the cull has picked {n} frames in bursts you have not looked through" if n else ""))
    out = shoot / "edit"
    # Resolve every keeper before harvest or clear can change anything. A
    # preview's JPEG sidecar is not a RAW recipe: use only the resolved name.
    sources = [_original(raw, name) for name in files]
    names = [p.name for p in sources if p is not None]
    if len(names) != len(set(names)):
        raise ValueError("multiple keeper names resolve to the same original; "
                         "edit/ was left as it is")
    # clear() removes RAW links, including the last link when raw/ was
    # removed. Refuse the whole rebuild even if other keepers are available;
    # this also protects formerly kept frames and works with --fresh.
    if out.exists() and any(p.is_file() and p.suffix.lower() in RAW_EXTS
                            and not (raw / p.name).is_file() for p in out.iterdir()):
        raise FileNotFoundError(
            "edit/ still holds originals missing from the source folder; edit/ and its "
            "sidecars were left as they are. Restore those originals to the source "
            "folder before rebuilding")
    if not names:
        raise FileNotFoundError(
            f"the originals for the frames you kept were not found in {raw.name}/. "
            "edit/ was left as it is. Locate the originals and restore them to the "
            "source folder before opening in PhotoLab again")
    # clear() deliberately preserves JPEGs and other personal files.
    for src in sources:
        if src is not None and src.suffix.lower() not in RAW_EXTS:
            dst = out / src.name
            if dst.exists() and not dst.samefile(src):
                raise ValueError("edit/ contains a different file with the same name; "
                                 "edit/ was left as it is")
    kept = 0
    aside: list[Path] = []
    if out.exists() and not fresh:
        kept = harvest(out, raw, cull)
    if out.exists():
        _n, aside = clear(out, raw, cull)
    out.mkdir(parents=True, exist_ok=True)

    linked = copied = side = missing = 0
    copied_bytes = 0
    for src in sources:
        if src is None:
            missing += 1
            continue
        name = src.name
        dst = out / name
        try:
            if not dst.exists():
                os.link(src, dst)  # same disk: no copy, no extra space
            linked += 1
        except OSError:
            shutil.copy2(src, dst)
            copied += 1
            copied_bytes += src.stat().st_size
        dop = raw / f"{name}.dop"
        if dop.exists():
            # A real copy, not a link: PhotoLab rewrites these. This is the
            # folder he opens, and half a sidecar in it takes the application
            # down before he sees the shoot, so it lands whole or not at all.
            write_atomic(out / f"{name}.dop", dop.read_bytes())
            shutil.copystat(dop, out / f"{name}.dop")
            side += 1
    return out, {"kept": kept, "aside": aside, "linked": linked, "copied": copied,
                 "copied_bytes": copied_bytes, "side": side, "missing": missing,
                 "frames": len(files),
                 "missing_files": [name for name, src in zip(files, sources) if src is None]}


def main() -> int:
    stop_cleanly_on_sigterm()
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    fresh = "--fresh" in sys.argv
    if not args:
        print("usage: ./pl gather ~/photos/shoots/<name> [--fresh]"
              "   (--fresh: rebuild from the sidecars beside the RAWs; edits made in edit/ are set"
              " aside in decisions/, not promoted)")
        return 1
    try:
        out, r = _build(Path(args[0]).expanduser().resolve(), fresh)
    except (FileNotFoundError, ValueError) as e:
        print(f"  {e}")
        return 1

    print(f"  {out}")
    if r["kept"]:
        print(f"  {r['kept']} sidecar{'s' if r['kept'] != 1 else ''} you had edited in the old edit/ folder promoted into raw/ first")
    if r["aside"]:
        print(f"  {len(r['aside'])} sidecar{'s' if len(r['aside']) != 1 else ''} in edit/ that could not be promoted "
              f"{'were' if len(r['aside']) != 1 else 'was'} copied to")
        print(f"    {r['aside'][0].parent.parent}  before the folder was rebuilt")
    print(f"  {r['linked'] + r['copied']} frames ({r['linked']} linked, {r['copied']} copied), {r['side']} with a sidecar")
    if r["missing"]:
        print(f"  {r['missing']} frames are in the cull but not in raw/ any more")
    if r["side"] < r["linked"] + r["copied"]:
        print(f"  {r['linked'] + r['copied'] - r['side']} have no sidecar yet: run ./pl presets first if you want the starting edit")
    print("\n  open that folder in PhotoLab. Every frame in it is one you kept.")
    # What this run actually did. The hard-link sentence was printed whatever
    # happened, including after the copy fallback below it: on a volume with no
    # hard links the folder is a second copy of every frame, and he was told it
    # cost nothing and deleted nothing.
    if r["copied"]:
        print(f"  {r['copied']} of them had to be copied ({human(r['copied_bytes'])}): this volume does not make")
        print("  hard links, so that much disk is in use until you delete the folder.")
    if r["linked"]:
        print(f"  {'the other ' if r['copied'] else 'the '}RAWs are hard links, so they cost nothing and deleting them deletes nothing.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
