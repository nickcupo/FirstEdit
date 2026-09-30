#!/usr/bin/env python3
"""A packed burst's own icon: the frame he kept, as Finder shows it.

Finder draws a .roll that is on this Mac with the app's Quick Look extension
(app/Sources/RollThumbnail). A .roll that iCloud has evicted is not on this Mac,
so no extension can read it, and Finder would draw a blank page. What an
evicted file does keep is its extended attributes: the custom icon lives
there (the resource fork's 'icns' -16455 and Finder's kHasCustomIcon flag),
and iCloud carries them with the file. So every .roll is given one as it is
written, and the ones already written can be given one with

    ./pl rollicon <folder or .roll>...

The picture is the camera's own JPEG preview of the kept frame, which is in
the frame's non-sensor part, turned upright by the ARW's Orientation: the same
one RollPreview.swift reads. Only the head of the file and that part are read.
A file that is not downloaded is never opened (opening it would download it).
The same picture, upright at the camera's size, is kept beside the icon
(PICTURE): the space bar and a double-click show it for a file that is not
downloaded, so looking at one never downloads it. Both are metadata: the
file's bytes, and so its checksum, do not change.
"""
from __future__ import annotations

import ctypes
import ctypes.util
import errno
import json
import lzma
import os
import struct
import sys
from pathlib import Path

MAGIC = b"FEBURST\x01"
EXT = ".roll"
SF_DATALESS = 0x40000000
RESOURCE_FORK = "com.apple.ResourceFork"
FINDER_INFO = "com.apple.FinderInfo"
HAS_CUSTOM_ICON = 0x0400
CUSTOM_ICON_ID = -16455           # kCustomIconResource
SIZES = (("ic07", 128), ("ic08", 256), ("ic09", 512))
# The picture itself, upright, as the camera made it (a JPEG): what the space
# bar and a double-click show of a file that is not downloaded. "#S" marks it
# for iCloud to carry with the file (xattr_flags.h, XATTR_FLAG_SYNCABLE).
PICTURE = "com.nickcupo.firstedit.keeper#S"

_MAX_MANIFEST = 64 << 20
_MAX_FRAME = 1 << 30


# ------------------------------------------------------------- the picture

def dataless(p: Path) -> bool:
    try:
        return bool(os.stat(p).st_flags & SF_DATALESS)
    except (OSError, AttributeError):
        return False


def keeper_preview(p: Path) -> tuple[bytes, int] | None:
    """(the camera's JPEG of the kept frame, the ARW's Orientation), or None."""
    try:
        with open(p, "rb") as fh:
            return _keeper(lambda at, n: (fh.seek(at), fh.read(n))[1])
    except OSError:
        return None


def keeper_preview_of(archive: bytes) -> tuple[bytes, int] | None:
    return _keeper(lambda at, n: archive[at:at + n])


def _keeper(read) -> tuple[bytes, int] | None:
    head = read(0, len(MAGIC) + 8)
    if len(head) != len(MAGIC) + 8 or head[:len(MAGIC)] != MAGIC:
        return None
    (n,) = struct.unpack_from("<Q", head, len(MAGIC))
    if not 0 < n <= _MAX_MANIFEST:
        return None
    try:
        manifest = json.loads(read(len(MAGIC) + 8, n))
        frames = manifest["frames"]
        key = manifest.get("key")
        f = next((x for x in frames if x.get("name") == key), None) \
            or next((x for x in frames if x.get("ref") is None), None)
        if f is None or not 0 < f["length"] <= _MAX_FRAME:
            return None
        blob = read(len(MAGIC) + 8 + n + f["at"], f["length"])
        if len(blob) != f["length"]:
            return None
        if f.get("codec") == "craw":
            parts = _unblob(blob)
            if not parts:
                return None
            rest = lzma.decompress(parts[0])
            hole = (f["offset"], f["offset"] + f["H"] * f["W"])
        elif f.get("codec") == "lzma":
            rest, hole = lzma.decompress(blob), (0, 0)
        else:
            return None
    except (ValueError, KeyError, TypeError, lzma.LZMAError):
        return None
    return _tiff_preview(rest, hole)


def _unblob(b: bytes) -> list[bytes] | None:
    out, i = [], 0
    while i < len(b):
        if i + 8 > len(b):
            return None
        (n,) = struct.unpack_from("<Q", b, i)
        if n > len(b) - i - 8:
            return None
        out.append(b[i + 8:i + 8 + n])
        i += 8 + n
    return out


def _tiff_preview(file: bytes, hole: tuple[int, int]) -> tuple[bytes, int] | None:
    """The largest JPEG IFD0/IFD1 point at, and IFD0's Orientation. Offsets are
    the original ARW's; `file` lacks the sensor data at `hole`."""
    lo, hi = hole

    def at(off: int, count: int) -> bytes | None:
        if off < 0 or count < 0:
            return None
        if hi > lo and off + count > lo:
            if off < hi:
                return None
            off -= hi - lo
        return file[off:off + count] if off + count <= len(file) else None

    hdr = at(0, 8)
    if not hdr or hdr[:2] not in (b"II", b"MM"):
        return None
    e = "<" if hdr[:2] == b"II" else ">"
    orientation, best = 1, b""
    (ifd,) = struct.unpack_from(e + "I", hdr, 4)
    seen: set[int] = set()
    for depth in range(4):
        cnt = at(ifd, 2) if ifd > 0 and ifd not in seen else None
        if not cnt:
            break
        seen.add(ifd)
        (n,) = struct.unpack_from(e + "H", cnt)
        entries = at(ifd + 2, 12 * n + 4) if 0 < n < 1024 else None
        if not entries:
            break
        jat = jlen = None
        for i in range(n):
            tag, typ = struct.unpack_from(e + "HH", entries, 12 * i)
            value = struct.unpack_from(e + ("H" if typ == 3 else "I"), entries, 12 * i + 8)[0]
            if tag == 0x0112 and depth == 0:
                orientation = value
            elif tag == 0x0201:
                jat = value
            elif tag == 0x0202:
                jlen = value
        if jat is not None and jlen and jlen <= _MAX_FRAME:
            j = at(jat, jlen)
            if j and j[:2] == b"\xff\xd8" and len(j) > len(best):
                best = j
        (ifd,) = struct.unpack_from(e + "I", entries, 12 * n)
    if not best:
        return None
    return best, orientation if orientation in (1, 3, 6, 8) else 1


# ---------------------------------------------------------------- the icon

def upright(jpeg: bytes, orientation: int):
    """The camera's JPEG decoded and turned by the ARW's Orientation, or None."""
    import cv2
    import numpy as np
    img = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        return None
    turn = {3: cv2.ROTATE_180, 6: cv2.ROTATE_90_CLOCKWISE, 8: cv2.ROTATE_90_COUNTERCLOCKWISE}.get(orientation)
    return img if turn is None else cv2.rotate(img, turn)


def picture(img) -> bytes | None:
    """The upright picture as a JPEG, at the camera's size."""
    import cv2
    ok, jpg = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 92])
    return jpg.tobytes() if ok else None


def icns(img) -> bytes | None:
    """An icns of the upright picture, centred on a clear square."""
    import cv2
    import numpy as np
    body = b""
    for kind, side in SIZES:
        h, w = img.shape[:2]
        k = side / max(h, w)
        nh, nw = max(1, round(h * k)), max(1, round(w * k))
        small = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_AREA)
        square = np.zeros((side, side, 4), np.uint8)
        y, x = (side - nh) // 2, (side - nw) // 2
        square[y:y + nh, x:x + nw, :3] = small
        square[y:y + nh, x:x + nw, 3] = 255
        ok, png = cv2.imencode(".png", square)
        if not ok:
            return None
        body += kind.encode() + struct.pack(">I", 8 + len(png)) + png.tobytes()
    return b"icns" + struct.pack(">I", 8 + len(body)) + body


def resource_fork(icon: bytes) -> bytes:
    """A resource fork holding one resource, 'icns' -16455: the custom icon."""
    data = struct.pack(">I", len(icon)) + icon
    type_list = struct.pack(">H", 0) + b"icns" + struct.pack(">HH", 0, 2 + 8)
    refs = struct.pack(">hHI", CUSTOM_ICON_ID, 0xFFFF, 0) + struct.pack(">I", 0)   # attrs 0, data at 0
    map_len = 28 + len(type_list) + len(refs)
    header = struct.pack(">IIII", 256, 256 + len(data), len(data), map_len)
    rmap = header + struct.pack(">IHHHH", 0, 0, 0, 28, map_len) + type_list + refs
    return header + bytes(240) + data + rmap


# ------------------------------------------------------ extended attributes

_libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
_libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                           ctypes.c_uint32, ctypes.c_int]
_libc.getxattr.restype = ctypes.c_ssize_t
_libc.setxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                           ctypes.c_uint32, ctypes.c_int]
_libc.setxattr.restype = ctypes.c_int
XATTR_NOFOLLOW = 0x0001


def _get(p: Path, name: str) -> bytes | None:
    path, key = os.fsencode(p), name.encode()
    n = _libc.getxattr(path, key, None, 0, 0, XATTR_NOFOLLOW)
    if n < 0:
        err = ctypes.get_errno()
        if err == getattr(errno, "ENOATTR", errno.ENODATA):     # macOS; Linux calls it ENODATA
            return None
        raise OSError(err, os.strerror(err), str(p))
    buf = ctypes.create_string_buffer(n)
    n = _libc.getxattr(path, key, buf, n, 0, XATTR_NOFOLLOW)
    if n < 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err), str(p))
    return buf.raw[:n]


def _set(p: Path, name: str, value: bytes) -> None:
    if _libc.setxattr(os.fsencode(p), name.encode(), value, len(value), 0, XATTR_NOFOLLOW) != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err), str(p))


def stored_picture(p: Path) -> bytes | None:
    """The kept frame's picture this file carries, read without its contents."""
    try:
        return _get(p, PICTURE)
    except OSError:
        return None


def has_icon(p: Path) -> bool:
    try:
        info = _get(p, FINDER_INFO)
    except OSError:
        return False
    return bool(info and len(info) >= 10 and struct.unpack_from(">H", info, 8)[0] & HAS_CUSTOM_ICON)


def give_icon(p: Path, archive: bytes | None = None) -> bool:
    """Give the .roll at p its kept frame: as its icon, and as the picture
    the space bar and a double-click show when it is not downloaded.
    `archive` is its bytes when the caller has them. False, and nothing
    written, when p is not downloaded or holds no picture to show; an OSError
    is not caught."""
    p = Path(p)
    if archive is None and dataless(p):
        return False
    found = keeper_preview_of(archive) if archive is not None else keeper_preview(p)
    img = upright(*found) if found else None
    icon = icns(img) if img is not None else None
    jpg = picture(img) if img is not None else None
    if not icon or not jpg:
        return False
    info = bytearray((_get(p, FINDER_INFO) or b"").ljust(32, b"\0")[:32])
    struct.pack_into(">H", info, 8, struct.unpack_from(">H", info, 8)[0] | HAS_CUSTOM_ICON)
    _set(p, PICTURE, jpg)
    _set(p, RESOURCE_FORK, resource_fork(icon))
    _set(p, FINDER_INFO, bytes(info))
    return True


# --------------------------------------------------------------------- CLI

def main(argv: list[str] | None = None) -> int:
    import argparse
    ap = argparse.ArgumentParser(description="Give packed bursts their kept frame: their Finder icon, "
                                             "and the picture shown when they are not downloaded.")
    ap.add_argument("paths", nargs="+", type=Path, help=".roll files, or folders holding them")
    ap.add_argument("--again", action="store_true", help="also those that have one already")
    a = ap.parse_args(argv)
    files: list[Path] = []
    for p in a.paths:
        p = p.expanduser()
        files += sorted(q for q in p.rglob(f"*{EXT}") if not q.name.startswith(".")) if p.is_dir() else [p]
    given = had = far = bad = 0
    for q in files:
        if not a.again and has_icon(q) and stored_picture(q):
            had += 1
        elif dataless(q):
            far += 1                  # opening it would download it
        else:
            try:
                ok = give_icon(q)
            except OSError as e:
                print(f"  {q}: {e}")
                ok = False
            given, bad = given + ok, bad + (not ok)
    print(f"{given} given an icon, {had} had one, {far} not downloaded (left alone), {bad} without a picture")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
