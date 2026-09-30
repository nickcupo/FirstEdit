#!/usr/bin/env python3
"""Write the .roll the Swift tests read (RollPreviewTests).

    .venv/bin/python app/tools/make-roll-fixture.py

Three synthetic frames of one burst, packed by the real burstpack, the middle
one kept. Each ARW's IFD0 carries Orientation 6 and points, through
JPEGInterchangeFormat, at a real 40x30 JPEG that sits AFTER the sensor data,
so a reader has to map the offset across the part burstpack stores apart.
The kept frame's JPEG is written beside it (keeper.jpg), for the test to
compare byte for byte.
"""
import io
import struct
import sys
import tempfile
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "pipeline"))
sys.path.insert(0, str(ROOT / "tests"))
import burstpack as bp  # noqa: E402
from test_burstpack import _burst, craw_encode  # noqa: E402

OUT = ROOT / "app/Tests/PipelineKitTests/Fixtures/Roll"


def jpeg(shade: int) -> bytes:
    b = io.BytesIO()
    Image.new("RGB", (40, 30), (shade, 255 - shade, 90)).save(b, "JPEG", quality=80)
    return b.getvalue()


def arw(strip: bytes, h: int, w: int, preview: bytes) -> bytes:
    e = lambda tag, typ, cnt, val: struct.pack("<HHII", tag, typ, cnt, val)  # noqa: E731
    make = b"SONY\x00"
    raw_ifd = 8 + 2 + 12 * 5 + 4
    data_at = raw_ifd + 2 + 12 * 6 + 4
    strip_at = data_at + len(make)
    strip_at += (-strip_at) % 16
    prev_at = strip_at + len(strip)
    out = io.BytesIO()
    out.write(b"II*\x00" + struct.pack("<I", 8))
    out.write(struct.pack("<H", 5) + e(271, 2, len(make), data_at) + e(274, 3, 1, 6)
              + e(330, 4, 1, raw_ifd) + e(513, 4, 1, prev_at) + e(514, 4, 1, len(preview))
              + struct.pack("<I", 0))
    out.write(struct.pack("<H", 6) + e(256, 4, 1, w) + e(257, 4, 1, h) + e(258, 3, 1, 8) + e(259, 3, 1, 32767)
              + e(273, 4, 1, strip_at) + e(279, 4, 1, len(strip)) + struct.pack("<I", 0))
    out.write(make)
    out.write(b"\0" * (strip_at - out.tell()))
    out.write(strip)
    out.write(preview)
    out.write(b"maker notes")
    return out.getvalue()


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as d:
        paths = []
        for i, p in enumerate(_burst(3, seed=7)):
            f = Path(d) / f"DSC0{1000 + i}.ARW"
            f.write_bytes(arw(bp.craw_bytes(craw_encode(p)), *p.shape, preview=jpeg(40 * (i + 1))))
            paths.append(f)
        out = OUT / "burst-0.roll"
        out.unlink(missing_ok=True)
        man = bp.pack(paths, out, key=paths[1].name, log=lambda *_: None)
        assert man["key"] == "DSC01001.ARW"
        assert any(f["codec"] == "craw" for f in man["frames"] if f["name"] == man["key"])
        (OUT / "keeper.jpg").write_bytes(jpeg(80))
    print(f"wrote {out.relative_to(ROOT)} ({out.stat().st_size} bytes) and keeper.jpg")


if __name__ == "__main__":
    main()
