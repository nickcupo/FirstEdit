"""Remove local installation locations from a copied Python bundle.

The dependency lock and NOTICES retain package versions, hashes and sources.
Pip's optional direct_url record additionally remembers where a wheel was on
the build machine. That file is not needed to import or run the package.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from urllib.parse import urlsplit


def remove_local_origins(python: Path) -> int:
    removed = 0
    for record in python.glob("lib/python*/site-packages/*.dist-info/direct_url.json"):
        origin = json.loads(record.read_text())
        if urlsplit(origin.get("url", "")).scheme.lower() == "file":
            record.unlink()
            removed += 1
    return removed


if __name__ == "__main__":
    print(f"  removed {remove_local_origins(Path(sys.argv[1]))} local wheel-location records")
