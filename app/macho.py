#!/usr/bin/env python3
"""List every Mach-O file under a folder (executables, .so, .dylib), one per line, for codesign.
Object files (.o) and static archives are not signable and are skipped."""
import struct
import sys
from pathlib import Path

MAGICS = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe"}
for p in Path(sys.argv[1]).rglob("*"):
    if not p.is_file() or p.is_symlink() or p.suffix in (".o", ".a", ".class"):
        continue
    try:
        with p.open("rb") as fh:
            head = fh.read(16)
    except OSError:
        continue
    if len(head) < 16 or head[:4] not in MAGICS:
        continue
    if head[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):
        filetype = struct.unpack("<I", head[12:16])[0]
        if filetype == 1:      # MH_OBJECT
            continue
    print(p)
