"""Who may ask the studio for anything, and what a request may name.

    .venv/bin/python -m pytest tests/test_security.py -q

The studio serves his photographs and writes his verdicts, on 127.0.0.1, to
whatever asks. Each attack below was carried out against a live studio before
it was closed, and each one's test was written to fail against that studio:

  - a star sent to one shoot, with a `file` of "../../<other shoot>/raw/X",
    rewrote the OTHER shoot's PhotoLab sidecar and answered "ok";
  - a POST whose Origin named 127.0.0.1 on some other port was taken as the
    page's own, and a text/plain body was parsed as JSON anyway, so any other
    program serving on this Mac could drive every button;
  - an <img> sends no Origin, so any page in any tab could draw one of his
    photographs, and learn which dated shoots exist from which guesses loaded;
  - /api/ingest copied whatever folder it was handed into a new shoot;
  - a rating of 99, or -999, was written as given.

Beside every refusal is the same request made the way the page makes it,
which must still work: the fix is only a fix if the page keeps its pictures.

Nothing here reads or writes ~/photos. The server runs in-process on a port
the OS picks, against a library under pytest's tmp_path.
"""
from __future__ import annotations

import http.client
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest

os.environ.setdefault("PIPELINE_EXT", "/nonexistent")      # no extension's routes in these answers
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import studio  # noqa: E402
import taste  # noqa: E402

KEY = "k3y-for-this-test-only-0123456789abcdef"
DOP = "{\n\tDxOPhotoLab = {\n\t\tRating = 2,\n\t},\n}\n"


class FakeJobs(studio.Jobs):
    """Records what would have been started instead of starting it: an ingest
    that ran here would copy files, and the point is only what was asked."""

    def __init__(self):
        super().__init__()
        self.started: list[list[str]] = []

    def start(self, kind, title, cmd, log, shoot="", **kw):
        self.started.append(list(cmd))
        return True

    def enqueue(self, kind, title, cmd, log, shoot="", then=None):
        self.started.append(list(cmd))
        if then:
            then()
        return self._new_id(), True


def _jpeg(p: Path) -> None:
    from PIL import Image
    p.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", (8, 6), (90, 60, 30)).save(p, "JPEG")


def _shoot(root: Path, name: str, frames=("TSC00001.ARW", "TSC00002.ARW")) -> Path:
    shoot = root / "shoots" / name
    (shoot / "raw").mkdir(parents=True)
    (shoot / "cull").mkdir()
    rows = ["file,rating,reason,scene,burst"] + [f"{f},3,,0,0" for f in frames]
    (shoot / "cull" / "cull.csv").write_text("\n".join(rows) + "\n")
    for f in frames:
        (shoot / "raw" / f).write_bytes(b"raw")
        (shoot / "raw" / f"{f}.dop").write_text(DOP)
        _jpeg(shoot / "cull" / "thumbs" / f"{Path(f).stem}.jpg")
    return shoot


@pytest.fixture
def lib(tmp_path, monkeypatch):
    """Two shoots, a memory card, and a folder that is not a card."""
    monkeypatch.setattr(studio, "ROOT", tmp_path)
    monkeypatch.setenv("PIPELINE_LEARNED", str(tmp_path / "learned"))
    # taste looks for exports in iCloud Drive whatever PIPELINE_ICLOUD says,
    # and every star goes through remember_selects, which asks it.
    monkeypatch.setattr(taste, "EXPORTS", [])
    monkeypatch.setattr(taste, "_EXPORTED", None)
    card = tmp_path / "Volumes" / "UNTITLED"
    (card / "DCIM").mkdir(parents=True)
    monkeypatch.setattr(studio, "cards", lambda: [str(card)])
    decoy = tmp_path / "Desktop"
    decoy.mkdir()
    (decoy / "secret.ARW").write_bytes(b"not his")
    return {"root": tmp_path, "gym": _shoot(tmp_path, "2026-01-01-gym"),
            "lake": _shoot(tmp_path, "2026-01-02-lake"), "card": card, "decoy": decoy}


@pytest.fixture
def srv(lib, monkeypatch):
    jobs = FakeJobs()
    monkeypatch.setattr(studio.Handler, "jobs", jobs, raising=False)
    server = studio.Server(("127.0.0.1", 0), studio.Handler, key=KEY)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    server.jobs = jobs
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()


def ask(server, method, path, body=None, headers=None, raw=None, host=True):
    """One request, with every header exactly as given: Host is this server's
    own unless it is overridden or left off, and nothing else is added."""
    port = server.server_address[1]
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    c.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
    h = {"Host": f"127.0.0.1:{port}"} if host else {}
    h.update(headers or {})
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    if data is not None:
        h.setdefault("Content-Type", "application/json")
        h.setdefault("Content-Length", str(len(data)))
    for k, v in h.items():
        c.putheader(k, v)
    c.endheaders(data)
    r = c.getresponse()
    out = (r.status, r.read(), {k.lower(): v for k, v in r.getheaders()}, r.msg.get_all("set-cookie") or [])
    c.close()
    return out


def page_post(server, path, body, **extra):
    """A POST the way the page's own api() makes it: same origin, JSON, and
    the cookie the page was given."""
    port = server.server_address[1]
    h = {"Origin": f"http://127.0.0.1:{port}", "Cookie": f"studio_key={KEY}",
         "Sec-Fetch-Site": "same-origin", "Content-Type": "application/json"}
    h.update(extra)
    return ask(server, "POST", path, body, h)


def page_get(server, path):
    return ask(server, "GET", path, headers={"Cookie": f"studio_key={KEY}", "Sec-Fetch-Site": "same-origin"})


def stars(shoot: Path) -> dict:
    p = shoot / "cull" / "organize.json"
    return json.loads(p.read_text()).get("photos", {}) if p.exists() else {}


# ------------------------------------------------------------- the key


def test_the_address_says_what_it_is_and_hands_nothing_over(srv):
    """The engine used to serve the studio page here, and that page was how
    the key reached a browser. The Mac app replaced it. What answers now is
    four sentences naming the program, and the key is not in them: there is no
    Set-Cookie on this address at all, so the only ways to hold the key are
    PIPELINE_STUDIO_KEY, the app's own header, and an extension's own port."""
    status, body, h, cookies = ask(srv, "GET", "/")
    assert status == 200 and b"<title>" in body
    assert b"First Edit" in body and b"Photo Pipeline" not in body
    assert cookies == [], "the engine's own address hands out no key"
    assert KEY.encode() not in body
    assert "frame-ancestors 'none'" in h["content-security-policy"]
    assert h["x-frame-options"] == "DENY"


def test_the_retired_page_is_gone(srv):
    """It was 166 KB of a UI nobody opens on purpose, and while it existed the
    engine could put it in front of him: restarting itself on a source change
    re-opened it. Neither the file nor a route to it is left."""
    from pathlib import Path
    import pipeline.studio as st
    assert not (Path(st.__file__).parent / "studio.html").exists()
    assert isinstance(st.PAGE, bytes) and len(st.PAGE) < 2000


def test_nothing_but_the_page_answers_without_the_key(srv, lib):
    """Every route but / is behind the key, including every picture."""
    gym = "2026-01-01-gym"
    for path in ("/api/shoots", "/api/cards", f"/api/shoot?name={gym}", "/api/job", "/api/update",
                 f"/api/storage?name={gym}", "/api/storage/library", f"/api/reel/options?name={gym}",
                 f"/thumb/{gym}/TSC00001.jpg", f"/large/{gym}/TSC00001.jpg", f"/preview/{gym}/TSC00001.jpg",
                 f"/full/{gym}/TSC00001.jpg", f"/crop/{gym}/TSC00001.jpg?cx=0.5",
                 f"/reelthumb/{gym}/TSC00001.jpg", f"/ext/{gym}/ig/TSC00001.jpg", "/nothing-here"):
        status, body, h, _ = ask(srv, "GET", path)
        assert status == 403, path
        assert "recognize this page" in json.loads(body)["error"], path
    for path in ("/api/rating", "/api/open", "/api/cull", "/api/ingest", "/api/job/stop", "/api/storage/apply"):
        status, _, h, _ = ask(srv, "POST", path, {"name": gym})
        assert status == 403, path
        assert h.get("connection") == "close", path
    assert not srv.jobs.started


def test_a_picture_on_another_page_is_not_drawn(srv):
    """What <img src="http://127.0.0.1:PORT/thumb/..."> on another page sends:
    no Origin and, from another site, no cookie. From another PORT of this
    Mac the cookie does go - cookies are per host - and the browser says
    same-site, which is not this page."""
    path = "/thumb/2026-01-01-gym/TSC00001.jpg"
    assert ask(srv, "GET", path, headers={"Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "no-cors"})[0] == 403
    assert ask(srv, "GET", path, headers={"Cookie": f"studio_key={KEY}", "Sec-Fetch-Site": "same-site",
                                          "Sec-Fetch-Mode": "no-cors"})[0] == 403
    status, body, h, _ = page_get(srv, path)
    assert status == 200 and body[:2] == b"\xff\xd8"
    # And were a request ever to get through, a browser still will not hand
    # the answer to another origin's page.
    assert h["cross-origin-resource-policy"] == "same-origin"


def test_the_header_or_either_cookie_will_do(srv):
    """The app sends the header; the page sends the cookie. A second studio
    opened in the same browser writes its own key into studio_key, and the one
    named for this port is still there."""
    port = srv.server_address[1]
    assert ask(srv, "GET", "/api/job", headers={"X-Studio-Key": KEY})[0] == 200
    assert ask(srv, "GET", "/api/job", headers={"X-Studio-Key": KEY[:-1]})[0] == 403
    assert ask(srv, "GET", "/api/job", headers={"Cookie": f"studio_key={KEY}x"})[0] == 403
    two = f"studio_key=another-studios-key; studio_key_{port}={KEY}"
    assert ask(srv, "GET", "/api/job", headers={"Cookie": two})[0] == 200
    # Some other program on 127.0.0.1 left a cookie http.cookies cannot parse.
    junk = f'prefs={{"a": "b c"}}; ;;=x; studio_key={KEY}'
    assert ask(srv, "GET", "/api/job", headers={"Cookie": junk})[0] == 200
    # A cookie for another port is not this one's.
    assert ask(srv, "GET", "/api/job", headers={"Cookie": f"studio_key_1={KEY}"})[0] == 403


def test_the_key_comes_from_the_environment_when_the_app_made_one(lib, monkeypatch):
    monkeypatch.setenv("PIPELINE_STUDIO_KEY", "made-by-the-app")
    server = studio.Server(("127.0.0.1", 0), studio.Handler)
    assert server.key == "made-by-the-app"
    server.server_close()
    monkeypatch.delenv("PIPELINE_STUDIO_KEY")
    a, b = studio.Server(("127.0.0.1", 0), studio.Handler), studio.Server(("127.0.0.1", 0), studio.Handler)
    assert a.key != b.key and len(a.key) >= 32
    a.server_close()
    b.server_close()


# ------------------------------------------------------------- Host and Origin


def test_host_has_to_name_this_server_port_and_all(srv):
    port = srv.server_address[1]
    key = {"X-Studio-Key": KEY}
    for host in (f"evil.example:{port}", "127.0.0.1:1", "127.0.0.1", f"127.0.0.1.evil.example:{port}"):
        assert ask(srv, "GET", "/api/job", headers={"Host": host, **key})[0] == 403, host
        assert ask(srv, "GET", "/", headers={"Host": host})[0] == 403, host
    assert ask(srv, "GET", "/api/job", headers=key, host=False)[0] == 403
    for host in (f"127.0.0.1:{port}", f"localhost:{port}", f"[::1]:{port}", f"LOCALHOST:{port}"):
        assert ask(srv, "GET", "/api/job", headers={"Host": host, **key})[0] == 200, host


def test_origin_has_to_be_this_server_exactly(srv, lib):
    """SEC-02: Origin was compared by hostname alone, so a page on any other
    port of this Mac could drive every button."""
    port = srv.server_address[1]
    body = {"name": "2026-01-01-gym", "seen": ["0/0"]}
    for origin in ("http://127.0.0.1:1", f"http://evil.example:{port}", "null", f"https://127.0.0.1:{port}",
                   f"http://127.0.0.1:{port}.evil.example"):
        status, _, _, _ = page_post(srv, "/api/review", body, Origin=origin)
        assert status == 403, origin
    assert not (lib["gym"] / "cull" / "review.json").exists()
    for origin in (f"http://127.0.0.1:{port}", f"http://localhost:{port}"):
        assert page_post(srv, "/api/review", body, Origin=origin)[0] == 200, origin
    assert (lib["gym"] / "cull" / "review.json").exists()


def test_a_post_has_to_be_json(srv, lib):
    """A form or a text/plain body is what another page can send without the
    browser asking first, and it used to be parsed as JSON regardless."""
    body = json.dumps({"name": "2026-01-01-gym", "seen": ["0/0"]}).encode()
    for ctype in ("text/plain", "application/x-www-form-urlencoded", "multipart/form-data; boundary=x", ""):
        status, _, h, _ = ask(srv, "POST", "/api/review", raw=body,
                              headers={"Content-Type": ctype, "X-Studio-Key": KEY})
        assert status == 415, ctype
    assert not (lib["gym"] / "cull" / "review.json").exists()
    status, _, _, _ = ask(srv, "POST", "/api/review", raw=body,
                          headers={"Content-Type": "application/json; charset=utf-8", "X-Studio-Key": KEY})
    assert status == 200
    # A body that is JSON but not an object, and a length that is a lie.
    assert page_post(srv, "/api/review", ["2026-01-01-gym"])[0] == 400
    assert ask(srv, "POST", "/api/review", raw=b"{}", headers={
        "X-Studio-Key": KEY, "Content-Type": "application/json", "Content-Length": str(studio.MAX_BODY + 1)})[0] == 413


# ------------------------------------------------------------- what a request may name


def test_a_star_cannot_walk_out_of_its_shoot(srv, lib):
    """SEC-01, as it was carried out: a star addressed to one shoot rewrote
    another shoot's PhotoLab sidecar."""
    lake_dop = lib["lake"] / "raw" / "TSC00001.ARW.dop"
    for file in ("../../2026-01-02-lake/raw/TSC00001.ARW", str(lake_dop)[:-4], "..", ".", "",
                 "raw/TSC00001.ARW", "..\\..\\x", None, 5, ["TSC00001.ARW"], "TSC09999.ARW"):
        status, body, _, _ = page_post(srv, "/api/rating", {"name": "2026-01-01-gym", "file": file, "rating": 5})
        assert status == 400, file
        assert json.loads(body)["error"], file
    assert lake_dop.read_text() == DOP
    assert (lib["gym"] / "raw" / "TSC00001.ARW.dop").read_text() == DOP
    assert stars(lib["gym"]) == {} and stars(lib["lake"]) == {}
    # The page's own star still lands, in its own shoot's sidecar.
    status, body, _, _ = page_post(srv, "/api/rating", {"name": "2026-01-01-gym", "file": "TSC00001.ARW", "rating": 5})
    assert status == 200 and json.loads(body)["ok"]
    assert "Rating = 5," in (lib["gym"] / "raw" / "TSC00001.ARW.dop").read_text()
    assert stars(lib["gym"]) == {"TSC00001.ARW": {"rating": 5}}
    assert lake_dop.read_text() == DOP


def test_a_rating_is_as_culled_or_zero_to_five(srv, lib):
    """SEC-06. Refused, not clamped: writing 0 for a request of -999 would be
    a verdict in his name that nobody made."""
    for r in (99, 6, -1, -999, 3.5, "abc", "", "-1", True, False, [3], {"r": 3}):
        status, _, _, _ = page_post(srv, "/api/rating", {"name": "2026-01-01-gym", "file": "TSC00002.ARW", "rating": r})
        assert status == 400, r
    assert stars(lib["gym"]) == {}
    assert (lib["gym"] / "raw" / "TSC00002.ARW.dop").read_text() == DOP
    # The page sends a number, or a tier it read out of cull.csv as a string,
    # or null for "as culled".
    for r, want in ((0, 0), (5, 5), ("3", 3), (2.0, 2)):
        assert page_post(srv, "/api/rating", {"name": "2026-01-01-gym", "file": "TSC00002.ARW", "rating": r})[0] == 200
        assert stars(lib["gym"])["TSC00002.ARW"] == {"rating": want}
    assert page_post(srv, "/api/rating", {"name": "2026-01-01-gym", "file": "TSC00002.ARW", "rating": None})[0] == 200
    assert "rating" not in stars(lib["gym"])["TSC00002.ARW"]


def test_set_rating_checks_its_own_input(lib):
    """Anything holding a Shoot can call it, not only the endpoint."""
    s = studio.Shoot(lib["gym"])
    with pytest.raises(ValueError):
        s.set_rating("../../2026-01-02-lake/raw/TSC00001.ARW", 3)
    with pytest.raises(ValueError):
        s.set_rating("TSC00001.ARW", 7)
    assert stars(lib["gym"]) == {}
    assert (lib["lake"] / "raw" / "TSC00001.ARW.dop").read_text() == DOP


def test_a_sidecar_that_links_out_of_the_shoot_is_not_written_through(srv, lib):
    """write_atomic follows a link, which is right for decisions/ and wrong
    for a sidecar pointing into another shoot. A link that stays inside the
    shoot is his, and is followed."""
    gym, lake_dop = lib["gym"], lib["lake"] / "raw" / "TSC00001.ARW.dop"
    side = gym / "raw" / "TSC00002.ARW.dop"
    side.unlink()
    side.symlink_to(lake_dop)
    assert page_post(srv, "/api/rating", {"name": "2026-01-01-gym", "file": "TSC00002.ARW", "rating": 4})[0] == 200
    assert lake_dop.read_text() == DOP
    assert stars(gym)["TSC00002.ARW"] == {"rating": 4}          # the star itself is kept
    (gym / "edit").mkdir()
    inside = gym / "edit" / "TSC00001.ARW.dop"
    inside.write_text(DOP)
    (gym / "raw" / "TSC00001.ARW.dop").unlink()
    (gym / "raw" / "TSC00001.ARW.dop").symlink_to(Path("..") / "edit" / "TSC00001.ARW.dop")
    assert page_post(srv, "/api/rating", {"name": "2026-01-01-gym", "file": "TSC00001.ARW", "rating": 4})[0] == 200
    assert "Rating = 4," in inside.read_text()


def test_a_reason_is_for_a_frame_of_this_shoot(srv, lib):
    for file in ("../../2026-01-02-lake/raw/TSC00001.ARW", "TSC09999.ARW", None):
        assert page_post(srv, "/api/label", {"name": "2026-01-01-gym", "file": file, "label": "blur"})[0] == 400
    assert page_post(srv, "/api/label", {"name": "2026-01-01-gym", "file": "TSC00001.ARW", "label": 5})[0] == 400
    assert not (lib["gym"] / "cull" / "labels.json").exists()
    assert page_post(srv, "/api/label", {"name": "2026-01-01-gym", "file": "TSC00001.ARW", "label": "blur"})[0] == 200
    assert json.loads((lib["gym"] / "cull" / "labels.json").read_text()) == {"TSC00001.ARW": "blur"}


def test_what_to_show_and_which_bursts_are_of_the_shape_they_are_read_as(srv, lib, monkeypatch):
    """Two values the page sends that are read as something with a shape: a
    string where a list of bursts is expected is iterated a letter at a time,
    and "what to show" is looked up in a table and then opened."""
    opened = []
    monkeypatch.setattr(studio, "_open", lambda args: opened.append(["open", *args]))
    for seen in ("0/0", {"0/0": 1}, 3):
        assert page_post(srv, "/api/review", {"name": "2026-01-01-gym", "seen": seen})[0] == 400, seen
    assert not (lib["gym"] / "cull" / "review.json").exists()
    assert page_post(srv, "/api/review", {"name": "2026-01-01-gym", "seen": ["3/1"]})[0] == 200
    assert list(json.loads((lib["gym"] / "cull" / "review.json").read_text())["bursts"]) == ["3/1"]
    for what in ({"raw": 1}, ["raw"], 5, None):
        assert page_post(srv, "/api/open", {"name": "2026-01-01-gym", "what": what})[0] == 400, what
    assert not opened
    assert page_post(srv, "/api/open", {"name": "2026-01-01-gym", "what": "raw"})[0] == 200
    assert opened == [["open", str(lib["gym"] / "raw")]]


def test_a_shoot_name_cannot_leave_the_shoots_folder(srv, lib):
    for name in ("..", ".", "../shoots/2026-01-01-gym", "%2e%2e", "2026-01-01-gym/../..", ["2026-01-01-gym"], None):
        status, _, _, _ = page_post(srv, "/api/review", {"name": name, "seen": ["0/0"]})
        assert status == 404, name
    for path in ("/thumb/%2e%2e/TSC00001.jpg", "/thumb/..%2f2026-01-01-gym/TSC00001.jpg",
                 "/thumb/2026-01-01-gym/..%2fTSC00001.jpg", "/full/2026-01-01-gym/../TSC00001.jpg"):
        assert page_get(srv, path)[0] == 404, path


def test_a_shoot_with_a_space_in_its_name_still_has_its_pictures(srv, lib):
    """The page puts the shoot's name into these URLs as it is, and a browser
    sends the space as %20. /ext/ and /reelthumb/ unquoted it; these did not."""
    _shoot(lib["root"], "old shoot")
    assert page_get(srv, "/thumb/old%20shoot/TSC00001.jpg")[0] == 200
    assert page_get(srv, "/large/old%20shoot/TSC00001.jpg")[0] == 200


def test_a_decode_is_not_written_through_a_link_out_of_the_shoot(srv, lib, tmp_path, monkeypatch):
    """The viewer writes cull/decoded/<stem>.jpg the first time a frame is
    opened. A link left there, dangling, would take the file anywhere."""
    import faces

    def decode(raw, out, full=None):          # the fixture's RAWs are not RAWs
        _jpeg(Path(out))
        return True
    monkeypatch.setattr(faces, "decode_to_file", decode)
    outside = tmp_path / "elsewhere" / "TSC00001.jpg"
    outside.parent.mkdir()
    d = lib["gym"] / "cull" / "decoded"
    d.mkdir()
    (d / "TSC00001.jpg").symlink_to(outside)
    assert page_get(srv, "/full/2026-01-01-gym/TSC00001.jpg")[0] == 404
    assert page_get(srv, "/crop/2026-01-01-gym/TSC00001.jpg?cx=0.5")[0] == 404
    assert not outside.exists()
    # The same decode, with nothing in the way, is made and served.
    assert page_get(srv, "/full/2026-01-01-gym/TSC00002.jpg")[0] == 200
    assert (d / "TSC00002.jpg").is_file()


# ------------------------------------------------------------- the card


def test_a_copy_is_only_ever_from_a_card_the_page_offered(srv, lib):
    """SEC-05: /api/ingest handed any path to ingest.py, which copies any
    folder it is given, into a new shoot the studio then served back."""
    for card in (str(lib["decoy"]), str(lib["card"]) + "/", str(lib["card"].parent), "/", "--help", ["x"]):
        status, body, _, _ = page_post(srv, "/api/ingest", {"card": card, "name": "2026-02-02-new", "verify": "none"})
        assert "error" in json.loads(body), card
    assert not srv.jobs.started
    assert not (lib["root"] / "shoots" / "2026-02-02-new").exists()
    for name in ("-rf", ".hidden", "..", "a/b", "", None, 7):
        status, body, _, _ = page_post(srv, "/api/ingest", {"card": str(lib["card"]), "name": name})
        assert "error" in json.loads(body), name
    assert not srv.jobs.started
    status, body, _, _ = page_post(srv, "/api/ingest", {"card": str(lib["card"]), "name": "2026-02-02-new", "verify": "none"})
    assert json.loads(body) == {"ok": True, "name": "2026-02-02-new", "id": 0, "queued": False}
    assert srv.jobs.started[0][-4:] == [str(lib["card"]), "2026-02-02-new", "--verify", "none"]


# ------------------------------------------------------------- a checkout


def test_restarting_keeps_the_port_it_got():
    assert studio._restart_args(["--port", "0", "--idle-exit", "5", "--no-open"]) == ["--idle-exit", "5"]
    assert studio._restart_args(["--port=8770", "--app"]) == ["--app"]


def test_a_checkout_takes_a_free_port_and_says_which(tmp_path):
    """SEC-07: a checkout used to answer on 8770, the one port nobody had to
    look for. Now it takes whatever the OS gives it and prints the address,
    and the key it was handed is the one it asks for."""
    home = tmp_path / "home"
    home.mkdir()
    env = dict(os.environ, PHOTOS_ROOT=str(tmp_path / "lib"), PIPELINE_EXT="/nonexistent",
               PIPELINE_STUDIO_KEY="handed-over", PIPELINE_LEARNED=str(tmp_path / "learned"),
               PIPELINE_ICLOUD=str(tmp_path / "icloud"), PIPELINE_SUPPORT=str(tmp_path / "support"),
               HOME=str(home), PYTHONUNBUFFERED="1")
    env.pop("PIPELINE_BUNDLED_MODELS", None)
    script = Path(studio.__file__).resolve()
    p = subprocess.Popen([sys.executable, str(script), "--no-open"], env=env, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True)
    try:
        lines, port, url = [], 0, ""
        deadline = time.time() + 60
        while time.time() < deadline and not url:
            line = p.stdout.readline()
            if not line:
                break
            lines.append(line)
            if line.startswith("PORT "):
                port = int(line.split()[1])
            if line.startswith("studio at "):
                url = line.split()[2]
        assert port and port != 8770, lines
        assert url == f"http://127.0.0.1:{port}/", lines
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        c.request("GET", "/api/job", headers={"X-Studio-Key": "handed-over"})
        assert c.getresponse().status == 200
        c.close()
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        c.request("GET", "/api/job")
        assert c.getresponse().status == 403
        c.close()
    finally:
        p.terminate()
        p.wait(10)
