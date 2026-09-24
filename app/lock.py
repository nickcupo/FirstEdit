#!/usr/bin/env python3
"""The wheels the app is built from, by name, version and SHA-256.

    app/lock.py write <pip --report json> <lock>     (STAGE=lock app/build.sh)
    app/lock.py check <requirements.txt> <lock>      run before every build
    app/lock.py stage <lock> <wheelhouse> <out>      fetch what is not on PyPI, then
                                                     write the lock pip is handed

requirements.txt pins versions, and a version is a label: the bytes behind it
are whatever the index serves at the moment pip asks. The app is a signed,
notarized DMG on a public page, so the bytes that go into it are named here as
well, and `pip install --require-hashes` refuses anything else. It is written
by pip's own resolution of requirements.txt, for the interpreter and the
platform the app is built with, so it lists the dependencies of the
dependencies too -- pip requires all of them to be hashed or none.

`check` asks only whether the lock still answers for what requirements.txt
asks: a version bumped in one and not the other is the way a lock file stops
meaning anything.

Two of the wheels are not on PyPI. The PyPI OpenCV wheels carry a
GPL-configured FFmpeg, which a bundle we hand out may not contain, so they are
built from source by app/tools/build-opencv.sh and published as release
assets. A lock line may therefore name a wheel by URL --

    opencv-python-headless @ https://.../opencv_python_headless-5.0.0.93-...whl \\
        --hash=sha256:...

-- and `write` keeps such a line rather than replacing it with the index's
answer, because pip resolving requirements.txt will always resolve those two
names to PyPI. `stage` is what makes the URL work offline and before the
asset is published: it puts the wheel in a local wheelhouse, checks it against
the hash this file names, and hands pip a file:// line with the same hash.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

PIN = re.compile(r"^\s*([A-Za-z0-9._-]+)\s*==\s*([A-Za-z0-9._+!-]+)\s*$")
# PEP 508's direct reference: a name, an @, and where the bytes are.
DIRECT = re.compile(r"^\s*([A-Za-z0-9._-]+)\s*@\s*(\S+)\s*$")
HASH = re.compile(r"^\s*--hash=sha256:([0-9a-f]{64})\s*$")
CHUNK = 1 << 20


def norm(name: str) -> str:
    """PyPI's own idea of when two names are the same one."""
    return re.sub(r"[-_.]+", "-", name).lower()


def wheel_version(url: str) -> str:
    """The version a wheel's filename states. `name-version-py-abi-plat.whl`."""
    parts = url.rsplit("/", 1)[-1].split("-")
    return parts[1] if len(parts) > 2 else ""


def pins(text: str) -> dict[str, str]:
    out = {}
    for line in text.splitlines():
        line = line.split("#", 1)[0].replace("\\", " ")
        m = PIN.match(line)
        if m:
            out[norm(m.group(1))] = m.group(2)
            continue
        m = DIRECT.match(line)
        if m:
            out[norm(m.group(1))] = wheel_version(m.group(2))
    return out


def blocks(text: str) -> list[tuple[str, list[str]]]:
    """The lock as (normalised name, its lines) pairs, a comment counting as
    part of the requirement it stands above. Leading lines that belong to no
    requirement -- the header -- come back under the empty name."""
    out, pending, name = [], [], ""
    for line in text.splitlines():
        if not line.strip() and not name:
            # A blank line that is not inside a requirement ends the header.
            pending.append(line)
            out.append(("", pending))
            pending = []
            continue
        pending.append(line)
        bare = line.split("#", 1)[0].replace("\\", " ")
        m = PIN.match(bare) or DIRECT.match(bare)
        if m:
            name = norm(m.group(1))
        elif HASH.match(bare) and name:
            out.append((name, pending))
            pending, name = [], ""
    if pending:
        out.append(("", pending))
    return out


def direct_blocks(lock: Path) -> dict[str, list[str]]:
    """The requirements this lock names by URL rather than by version: the
    wheels that are not on any index and that `write` must not throw away."""
    if not lock.exists():
        return {}
    out = {}
    for name, lines in blocks(lock.read_text()):
        if name and any(DIRECT.match(l.split("#", 1)[0].replace("\\", " ")) for l in lines):
            out[name] = lines
    return out


HEADER = [
    "# The wheels app/build.sh installs into the bundle, by SHA-256.",
    "# Written by `STAGE=lock app/build.sh` from requirements.txt, resolved with the",
    "# interpreter and platform the app is built with: CPython 3.12, macOS arm64.",
    "# Do not edit by hand, and regenerate it whenever requirements.txt changes.",
    "# A checkout installs from requirements.txt instead; this is for the DMG.",
    "#",
    "# The lines that name a wheel by URL are the exception: those wheels are not on",
    "# PyPI, app/tools/build-opencv.sh makes them, and regenerating this file keeps",
    "# them exactly as they are. See that script for why, and RELEASING.md for when.",
    "",
]


def write(report: Path, lock: Path) -> int:
    keep = direct_blocks(lock)
    got = json.loads(report.read_text())["install"]
    rows = []
    for item in sorted(got, key=lambda i: norm(i["metadata"]["Name"] if "Name" in i["metadata"] else i["metadata"]["name"])):
        m = item["metadata"]
        name = m.get("name") or m.get("Name")
        if norm(name) in keep:
            # pip resolved this one against PyPI, because that is the only
            # place requirements.txt can point it. The bundle takes the wheel
            # the URL names instead; say so if the versions have parted.
            held = pins("\n".join(keep[norm(name)])).get(norm(name), "")
            if held != m["version"]:
                print(f"  {name}: requirements.txt resolves to {m['version']} and the wheel this")
                print(f"  lock names by URL is {held or 'unversioned'}.")
                print("  Build the new version with app/tools/build-opencv.sh and put its URL and")
                print("  SHA-256 here, or pin requirements.txt back.")
                return 1
            rows.append((norm(name), keep[norm(name)]))
            continue
        info = item.get("download_info", {})
        digest = info.get("archive_info", {}).get("hashes", {}).get("sha256")
        url = info.get("url", "")
        if not digest:
            print(f"  no sha256 for {name}: pip resolved it to {url or 'something with no archive'}.")
            print("  Every wheel has to be named by its bytes or the lock is decoration.")
            return 1
        rows.append((norm(name), [
            f"# {url.rsplit('/', 1)[-1]}",
            f"{name}=={m['version']} \\",
            f"    --hash=sha256:{digest}",
        ]))
    missing = [n for n in keep if n not in {r[0] for r in rows}]
    if missing:
        print(f"  the lock names {', '.join(sorted(missing))} by URL, and pip's resolution of")
        print("  requirements.txt does not ask for it at all. Remove the line, or put the")
        print("  package back into requirements.txt.")
        return 1
    lines = list(HEADER)
    for _, block in sorted(rows):
        lines.extend(block)
    lock.write_text("\n".join(lines) + "\n")
    print(f"  {len(rows)} wheels in {lock}"
          + (f", {len(keep)} of them built here" if keep else ""))
    return 0


def check(requirements: Path, lock: Path) -> int:
    if not lock.exists():
        print(f"  there is no {lock}. Write it with: STAGE=lock app/build.sh")
        return 1
    asked, locked = pins(requirements.read_text()), pins(lock.read_text())
    wrong = [f"{n}: requirements.txt says {v}, the lock says {locked.get(n, 'nothing')}"
             for n, v in asked.items() if locked.get(n) != v]
    if wrong:
        print(f"  {lock} does not answer for requirements.txt:")
        for w in wrong[:8]:
            print(f"    {w}")
        print("  Write it again with: STAGE=lock app/build.sh")
        return 1
    return 0


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def stage(lock: Path, wheelhouse: Path, out: Path) -> int:
    """Hand pip a lock it can install offline. Every requirement named by a
    URL is put in the wheelhouse first -- from OPENCV_WHEELHOUSE if it is set
    (a wheel just built and not yet published), from the wheelhouse itself if
    it is already there, and otherwise downloaded -- and checked against the
    SHA-256 the lock names before its line is rewritten to point at the file.
    The hash never changes: only where the bytes are read from does."""
    wheelhouse.mkdir(parents=True, exist_ok=True)
    spare = os.environ.get("OPENCV_WHEELHOUSE", "")
    lines, staged = [], 0
    for _, block in blocks(lock.read_text()):
        url = digest = ""
        for line in block:
            bare = line.split("#", 1)[0].replace("\\", " ")
            m = DIRECT.match(bare)
            if m:
                url = m.group(2)
            m = HASH.match(bare)
            if m:
                digest = m.group(1)
        if not url:
            lines.extend(block)
            continue
        name = url.rsplit("/", 1)[-1]
        if not digest:
            print(f"  {name} is named by URL and by no hash. A lock without the bytes is decoration.")
            return 1
        local = wheelhouse / name
        for candidate in ([Path(spare) / name] if spare else []) + [local]:
            if candidate.exists() and sha256(candidate) == digest:
                if candidate != local:
                    local.write_bytes(candidate.read_bytes())
                break
            if candidate.exists():
                print(f"  {candidate} is not the wheel this lock names:")
                print(f"    the lock says sha256:{digest}")
                print(f"    that file is  sha256:{sha256(candidate)}")
                print("  Build it again with app/tools/build-opencv.sh, or take the published one.")
                return 1
        else:
            print(f"  fetching {name}")
            try:
                with urllib.request.urlopen(url, timeout=120) as r, open(local, "wb") as fh:
                    while chunk := r.read(CHUNK):
                        fh.write(chunk)
            except Exception as e:                       # noqa: BLE001 - the reason is the message
                local.unlink(missing_ok=True)
                print(f"  {url}\n  could not be fetched: {e}")
                print("  That wheel is built by app/tools/build-opencv.sh and published as a release")
                print("  asset. Build it and point OPENCV_WHEELHOUSE at the folder it wrote, or put")
                print(f"  the file in {wheelhouse}.")
                return 1
            if sha256(local) != digest:
                print(f"  {url}\n  is not the wheel this lock names: sha256:{sha256(local)}")
                local.unlink(missing_ok=True)
                return 1
        staged += 1
        for line in block:
            bare = line.split("#", 1)[0].replace("\\", " ")
            m = DIRECT.match(bare)
            lines.append(f"{m.group(1)} @ {local.resolve().as_uri()} \\" if m else line)
    out.write_text("\n".join(lines) + "\n")
    print(f"  {staged} wheel{'' if staged == 1 else 's'} from {wheelhouse}, the rest from the index")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] not in ("write", "check", "stage"):
        print(__doc__.strip().splitlines()[2])
        return 2
    if argv[1] == "stage":
        if len(argv) != 5:
            print("app/lock.py stage <lock> <wheelhouse> <out>")
            return 2
        return stage(Path(argv[2]), Path(argv[3]), Path(argv[4]))
    if len(argv) != 4:
        print(__doc__.strip().splitlines()[2])
        return 2
    return write(Path(argv[2]), Path(argv[3])) if argv[1] == "write" else check(Path(argv[2]), Path(argv[3]))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
