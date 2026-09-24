"""An engine started on a folder leaves that folder as it found it until
there is a shoot to write into it."""
import http.client
import os
import subprocess
import sys
import time
from pathlib import Path

STUDIO = Path(__file__).resolve().parents[1] / "pipeline" / "studio.py"


def test_starting_on_a_folder_does_not_make_its_shoots_folder(tmp_path):
    """First launch starts the engine on ~/photos before he has chosen his
    library, and the start made ~/photos/shoots, an empty folder in his home
    for a library that lives somewhere else. The empty library still reads
    as empty."""
    home = tmp_path / "home"
    home.mkdir()
    lib = tmp_path / "lib"
    env = dict(os.environ, PHOTOS_ROOT=str(lib), PIPELINE_EXT="/nonexistent",
               PIPELINE_STUDIO_KEY="k", PIPELINE_LEARNED=str(tmp_path / "learned"),
               PIPELINE_ICLOUD=str(tmp_path / "icloud"), PIPELINE_SUPPORT=str(tmp_path / "support"),
               HOME=str(home), PYTHONUNBUFFERED="1")
    env.pop("PIPELINE_BUNDLED_MODELS", None)
    p = subprocess.Popen([sys.executable, str(STUDIO), "--no-open"], env=env, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True)
    try:
        lines, port, served = [], 0, False
        deadline = time.time() + 60
        while time.time() < deadline and not served:
            line = p.stdout.readline()
            if not line:
                break
            lines.append(line)
            if line.startswith("PORT "):
                port = int(line.split()[1])
            served = line.startswith("studio at ")
        assert port and served, lines
        assert "NO SHOOTS" in lines[-1], lines
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        c.request("GET", "/api/shoots", headers={"X-Studio-Key": "k"})
        r = c.getresponse()
        assert r.status == 200
        assert b'"shoots": []' in r.read()
        c.close()
        assert not (lib / "shoots").exists()
    finally:
        p.terminate()
        p.wait(10)
