"""The measurement behind docs/BURSTPACK.md: real burst sensor data, packed.

    .venv/bin/python tests/burstpack_hdrplus.py <folder of payload_N00*.dng> [frames]

Not a test (pytest does not collect it): it needs the DNGs of one burst from
Google's HDR+ burst dataset, https://hdrplusdata.org, folder
20171106_subset/bursts/<name>. Each frame's mosaic is put into Sony cRAW
blocks by the same encoder the tests use, so the codec runs its ARW path on
real sensor noise and real hand-held motion. Prints one JSON line.
"""
from __future__ import annotations

import json
import lzma
import sys
import time
from pathlib import Path

import numpy as np
import rawpy

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import burstpack as bp  # noqa: E402
from test_burstpack import craw_encode  # noqa: E402


def mosaic(path: Path) -> np.ndarray:
    a = rawpy.imread(str(path)).raw_image_visible.astype(np.int64)
    h, w = a.shape
    return np.clip(a[:h - h % 2, :w - w % 32], 0, 2047)


def main() -> None:
    folder = Path(sys.argv[1])
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    strips, shape = [], None
    for f in sorted(folder.glob("payload_N*.dng"))[:n]:
        p = mosaic(f)
        shape = p.shape
        strips.append(bp.craw_bytes(craw_encode(p)))
    H, W = shape
    alone = chain = 0
    prev = prev_dec = None
    t_enc = t_dec = 0.0
    for s in strips:
        alone += len(bp.encode_craw(s, H, W, None)[0])
        t = time.time()
        blob, prev = bp.encode_craw(s, H, W, prev)
        t_enc += time.time() - t
        t = time.time()
        back, prev_dec = bp.decode_craw(blob, prev_dec)
        t_dec += time.time() - t
        assert back == s, "a frame did not come back"
        chain += len(blob)
    total = sum(len(s) for s in strips)
    print(json.dumps({"burst": folder.name, "frames": len(strips), "H": H, "W": W, "bytes": total,
                      "xz": round(sum(len(lzma.compress(s, preset=9)) for s in strips) / total, 4),
                      "alone": round(alone / total, 4), "burst_chain": round(chain / total, 4),
                      "encode_s": round(t_enc / len(strips), 1), "decode_s": round(t_dec / len(strips), 1)}))


if __name__ == "__main__":
    main()
