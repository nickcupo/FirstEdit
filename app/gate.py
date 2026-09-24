#!/usr/bin/env python3
"""The mark a gated build leaves beside the app, and the check STAGE=dmg makes.

    app/gate.py write <app> <marker> --kind public|private --copyleft 0|1 --version V [--version-given 0|1]
    app/gate.py check <app> <marker>       prints "<kind> <copyleft> <version-given> <version>", or refuses

STAGE=dmg packages whatever app is sitting in build/, and nothing recorded
whether that app had ever been through the licence gate: one assembled weeks
ago with ALLOW_COPYLEFT=1, or with the private modules in it, would have been
packaged and notarized like any other. So the run that gates and signs an app
writes this marker, and a DMG is made only from an app that still matches it.

The marker lives outside the bundle, because writing anything inside a signed
app breaks its seal. It holds a fingerprint of every file in the signed app,
by content, so an app that was re-signed, rebuilt or touched by hand since is
refused rather than trusted by its name.

It also remembers whether the version was given by hand (VERSION=...) or read
off `git describe`, because only the second kind has to look like a plain tag
before it may be notarized. That answer belongs to the run that assembled the
app, not to whoever runs STAGE=dmg afterwards, so it is recorded here.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from pathlib import Path

CHUNK = 1 << 20


def fingerprint(app: Path) -> str:
    """One SHA-256 over every entry under the app: its path, and a file's
    bytes or a link's target. Directories count only through what is in them."""
    h = hashlib.sha256()
    for dirpath, dirnames, filenames in os.walk(app, followlinks=False):
        dirnames.sort()
        base = Path(dirpath)
        # A link to a directory shows up in dirnames and is never descended into.
        entries = sorted(filenames + [d for d in dirnames if (base / d).is_symlink()])
        for name in entries:
            p = base / name
            rel = p.relative_to(app).as_posix()
            if p.is_symlink():
                h.update(f"L {rel} -> {os.readlink(p)}\n".encode())
                continue
            f = hashlib.sha256()
            with open(p, "rb") as fh:
                for chunk in iter(lambda: fh.read(CHUNK), b""):
                    f.update(chunk)
            h.update(f"F {rel} {f.hexdigest()}\n".encode())
    return h.hexdigest()


def write(app: Path, marker: Path, kind: str, copyleft: bool, version: str,
          version_given: bool = False) -> None:
    marker.write_text(json.dumps({
        "app": app.name, "kind": kind, "copyleft_allowed": copyleft, "version": version,
        "version_given": version_given,
        "fingerprint": fingerprint(app), "written": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }, indent=1) + "\n")


def check(app: Path, marker: Path) -> tuple[str, bool, bool, str]:
    """(kind, copyleft allowed, version was given by hand, version) of an app
    that matches its marker. Raises SystemExit with the reason otherwise."""
    if not marker.exists():
        raise SystemExit(f"no gate marker at {marker}: this app was not assembled, gated and signed by one "
                         "run of app/build.sh. Run app/build.sh (or STAGE=sign) first.")
    try:
        m = json.loads(marker.read_text())
    except ValueError:
        raise SystemExit(f"the gate marker at {marker} is not readable; build again") from None
    if m.get("fingerprint") != fingerprint(app):
        raise SystemExit(f"{app} is not the app the gate passed on {m.get('written', '?')}: something in it "
                         "changed since. Run STAGE=sign (which gates it again) or a full build.")
    # A marker from an older build has no version_given; "not given" is the
    # strict answer, so such an app is asked to be tagged before notarization.
    return (m.get("kind", "?"), bool(m.get("copyleft_allowed")),
            bool(m.get("version_given")), m.get("version", ""))


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("write")
    w.add_argument("app", type=Path)
    w.add_argument("marker", type=Path)
    w.add_argument("--kind", choices=("public", "private"), required=True)
    w.add_argument("--copyleft", choices=("0", "1"), required=True)
    w.add_argument("--version", required=True)
    w.add_argument("--version-given", choices=("0", "1"), default="0")
    c = sub.add_parser("check")
    c.add_argument("app", type=Path)
    c.add_argument("marker", type=Path)
    a = ap.parse_args(argv[1:])
    if a.cmd == "write":
        write(a.app, a.marker, a.kind, a.copyleft == "1", a.version, a.version_given == "1")
        return 0
    kind, copyleft, version_given, version = check(a.app, a.marker)
    # The version goes last: it is the only field that could hold anything odd.
    print(kind, int(copyleft), int(version_given), version)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
