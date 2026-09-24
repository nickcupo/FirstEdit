"""A small library for the Instagram step's tests, and the server over it.

One shoot with a few exports of each shape, and records written the way a
planning pass writes them (instagram.carry over what detect() answers) but
without a detector: the models are a download, and a test that needs one
proves nothing on a machine without it. Nothing here reads or writes ~/photos:
the library is under the test's own tmp path, and conftest.py points
everything else away from his folders.

Not a test module (pytest collects test_*.py), so the two test files that
share it can import plain functions from it and keep their fixtures their own.
"""
from __future__ import annotations

import http.client
import json
import os
import sys
import threading
import time
from pathlib import Path

from PIL import Image, ImageOps

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import instagram as ig  # noqa: E402
import studio  # noqa: E402
import taste  # noqa: E402

KEY = "k3y-for-the-instagram-step-tests-0123456789"
NAME = "2026-02-02-day"
# Two landscapes, a portrait and a square, named so that stem order is not
# the order the wall shows them in once a grid miss is in play.
SHAPES = {"F0001": (600, 400), "F0002": (400, 600), "F0003": (600, 400), "F0004": (500, 500)}


def export(path: Path, size: tuple[int, int], colour=(200, 60, 40), orientation: int | None = None) -> Path:
    """A finished photograph: one colour with a green corner, so the ends of a
    crop can be told apart."""
    im = Image.new("RGB", size, colour)
    im.paste((10, 200, 40), (0, 0, size[0] // 4, size[1] // 4))
    kw = {}
    if orientation:
        ex = Image.Exif()
        ex[274] = orientation
        kw["exif"] = ex
    path.parent.mkdir(parents=True, exist_ok=True)
    im.save(path, "JPEG", quality=92, **kw)
    return path


def make_library(root: Path, shapes: dict[str, tuple[int, int]] | None = None, exported: bool = True) -> Path:
    shapes = SHAPES if shapes is None else shapes
    shoot = root / "shoots" / NAME
    (shoot / "raw").mkdir(parents=True)
    (shoot / "cull").mkdir()
    (shoot / "cull" / "cull.csv").write_text("file,rating\n" + "".join(f"{s}.ARW,3\n" for s in shapes))
    for s in shapes:
        (shoot / "raw" / f"{s}.ARW").write_bytes(b"raw")
    if exported:
        for s, size in shapes.items():
            export(shoot / "export" / f"{s}_DxO.jpg", size)
    return shoot


def src_of(shoot: Path, stem: str) -> Path:
    return next((shoot / "export").glob(f"{stem}_*.jpg"))


def plan(shoot: Path, stems, subject: dict | None = None, ratio: str | None = None,
         landscape: str | None = None) -> dict:
    """Records for these frames, as `instagram.py --plan` writes them, with the
    subject where given (default: the middle, which is what detect() answers
    when nothing is found). Returns the record."""
    out = shoot / "instagram"
    subject = subject or {}
    with ig.held(out):
        bk = ig.book(out)
        ratio = ratio or bk.get("ratio") or "3:4"
        landscape = landscape or bk.get("landscape") or "fit"
        for s in stems:
            src = src_of(shoot, s)
            with Image.open(src) as im:
                w, h = ImageOps.exif_transpose(im).size
            at = subject.get(s, (0.5, 0.5))
            fresh = {"src": src.name, "w": w, "h": h, "mtime": int(src.stat().st_mtime),
                     "subject": {"cx": at[0], "cy": at[1], "kind": "scene", "faces": None}}
            e, _ = ig.carry(bk["frames"].get(s), fresh, landscape)
            bk["frames"][s] = e
        bk["ratio"], bk["landscape"] = ratio, landscape
        ig.keep_book(out, bk, locked=True)
    return ig.book(out)


def exported_again(shoot: Path, stem: str, by: float = 30.0) -> None:
    """He exported it again: the same file, written later."""
    p = src_of(shoot, stem)
    t = p.stat().st_mtime + by
    os.utime(p, (t, t))


def serve(root: Path, monkeypatch):
    monkeypatch.setattr(studio, "ROOT", root)
    monkeypatch.setattr(taste, "EXPORTS", [])
    monkeypatch.setattr(taste, "_EXPORTED", None)
    monkeypatch.setattr(studio, "cards", lambda: [])
    # The library's exports were written a moment ago; the step leaves an
    # export that new for the next ask (studio.IG_SETTLE), and the tests of
    # that set it back themselves.
    monkeypatch.setattr(studio, "IG_SETTLE", 0.0)
    studio._IG_EXPORTS.clear()
    # Its own list on disk, under this test's tmp path: the list survives a
    # restart on purpose, so a shared one would carry work between tests.
    monkeypatch.setattr(studio.Handler, "jobs", studio.Jobs(store=root / "queue.json"), raising=False)
    server = studio.Server(("127.0.0.1", 0), studio.Handler, key=KEY)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def stop(server) -> None:
    jobs = studio.Handler.jobs
    jobs.stop()
    idle(jobs)
    server.shutdown()
    server.server_close()


def idle(jobs, tries: int = 400) -> None:
    for _ in range(tries):
        if not jobs.status()["running"]:
            return
        time.sleep(0.05)
    raise AssertionError("the job slot never came free")


def sleeper(root: Path, monkeypatch, seconds: int = 30) -> Path:
    """Every job the engine starts runs this instead of Python: it sleeps, so
    a job can be seen holding the slot, and it runs nothing of the pipeline's.
    The command it was given is still the job's (`command`)."""
    p = root / "sleeper"
    p.write_text(f"#!/bin/sh\nsleep {seconds}\n")
    p.chmod(0o755)
    monkeypatch.setattr(studio, "PY", str(p))
    return p


def command(jobs) -> list[str]:
    """The command the running job was started with, without the parent that
    every job runs under to write how it ended (studio._ending_its_log)."""
    args = list(jobs.proc.args)
    wrap = studio._ending_its_log([])
    return args[len(wrap):] if args[:len(wrap)] == wrap else args


def get(server, path: str) -> tuple[int, bytes]:
    c = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=30)
    c.request("GET", path, headers={"Cookie": f"studio_key={KEY}", "Sec-Fetch-Site": "same-origin"})
    r = c.getresponse()
    out = (r.status, r.read())
    c.close()
    return out


def get_json(server, path: str) -> dict:
    status, body = get(server, path)
    assert status == 200, (status, body[:200])
    return json.loads(body)


def post(server, path: str, body: dict) -> tuple[int, dict]:
    port = server.server_address[1]
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    c.request("POST", path, json.dumps(body), headers={
        "Cookie": f"studio_key={KEY}", "Sec-Fetch-Site": "same-origin",
        "Origin": f"http://127.0.0.1:{port}", "Content-Type": "application/json"})
    r = c.getresponse()
    out = (r.status, json.loads(r.read()))
    c.close()
    return out


def status(server) -> dict:
    return get_json(server, f"/api/instagram?name={NAME}")


def frames(server) -> dict[str, dict]:
    return {f["stem"]: f for f in status(server)["frames"]}
