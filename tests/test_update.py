"""What the app is allowed to install over itself.

    .venv/bin/python -m pytest tests/test_update.py -q

update.py is the one thing in the pipeline that takes a file off the internet
and then runs it as him, so every answer it needs before a swap is pinned
here: https on GitHub at every hop, Apple's notarization ticket on the DMG,
the same team as the app asking for the update and First Edit's own bundle
identifier on both,
Gatekeeper's own verdict on the app that came out of it -- and, when any of
those fails, nothing kept and nothing staged.

Nothing here reaches the network or signs anything: the tools update.py shells
out to are answered from the test, and every path is under pytest's own
tmp_path.
"""

from __future__ import annotations

import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pipeline"))
import update  # noqa: E402


OURS = "Identifier=com.nickcupo.firstedit\nTeamIdentifier=TEAM123456\n"
FORMER = "Identifier=com.nickcupo.photo-pipeline\nTeamIdentifier=TEAM123456\n"


def test_the_updater_asks_the_renamed_repository_for_the_renamed_app():
    """The identifier cannot change after the first public release: every copy
    already installed would refuse whatever came next. So it is written here,
    and pinned."""
    assert update.BUNDLE_ID == "com.nickcupo.firstedit"
    assert update.REPO == "nickcupo/first-edit"
    assert update.API == "https://api.github.com/repos/nickcupo/first-edit/releases/latest"
    assert update.AGENT == "first-edit"


def test_the_app_bundle_carries_the_identifier_the_updater_expects():
    """The two have to agree, or the first update after a release is refused
    by the app that asked for it."""
    with (ROOT / "app/Resources/Info.plist").open("rb") as fh:
        got = plistlib.load(fh)["CFBundleIdentifier"]
    assert got == update.BUNDLE_ID


def test_the_app_and_its_staged_update_are_named_first_edit(tmp_path):
    env = {k: v for k, v in os.environ.items() if k != "PIPELINE_APP_PATH"}
    env["PIPELINE_SUPPORT"] = str(tmp_path / "support")
    out = subprocess.run([sys.executable, "-c", "import update; print(update.APP); print(update.STAGED)"],
                         cwd=ROOT / "pipeline", env=env, capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    assert out.stdout.splitlines() == ["/Applications/First Edit.app",
                                       str(tmp_path / "support/updates/staged/First Edit.app")]


def test_github_is_told_who_is_asking_by_the_new_name(monkeypatch):
    seen = []

    def opened(self, req, *a, **k):
        seen.append(req)
        raise update.urllib.error.URLError("offline")

    monkeypatch.setattr(update.urllib.request.OpenerDirector, "open", opened)
    update.check()
    assert seen and seen[0].full_url == update.API
    assert seen[0].get_header("User-agent") == "first-edit"


def test_only_github_over_https_is_a_download():
    assert update.on_github("https://github.com/nickcupo/first-edit/releases/download/v1/a.dmg")
    assert update.on_github("https://objects.githubusercontent.com/x/a.dmg")
    assert not update.on_github("http://github.com/x/a.dmg")          # not https
    assert not update.on_github("https://github.com.example.net/a.dmg")   # not GitHub
    assert not update.on_github("https://example.net/a.dmg")
    assert not update.on_github("file:///tmp/a.dmg")


def test_a_download_from_anywhere_else_is_refused(tmp_path, capsys):
    with pytest.raises(SystemExit):
        update.download("https://example.net/First-Edit.dmg")
    assert "comes from GitHub over https" in capsys.readouterr().out


def test_being_offline_is_a_sentence_not_an_exception(monkeypatch):
    import urllib.error

    def no_network(*a, **k):
        raise urllib.error.URLError("nodename nor servname provided")

    monkeypatch.setattr(update.urllib.request.OpenerDirector, "open", no_network)
    out = update.check()
    assert out["newer"] is False
    assert out["error"] == "this Mac cannot reach GitHub at the moment"
    json.dumps(out)   # the page reads it as JSON, always


class Ran:
    """Stands in for the tools stage() shells out to, answering each by name."""

    def __init__(self, **answers):
        self.answers = answers
        self.seen: list[list[str]] = []

    def __call__(self, cmd, *a, **k):
        self.seen.append(list(cmd))
        name = Path(cmd[0]).name
        if name == "ditto":
            _app(Path(cmd[2]))   # what the real ditto would leave behind
        rc, out, err = self.answers.get(f"{name} {cmd[1]}" if len(cmd) > 1 else name, self.answers.get(name, (0, "", "")))
        return subprocess.CompletedProcess(cmd, rc, out, err)


def _app(path: Path) -> Path:
    (path / "Contents").mkdir(parents=True, exist_ok=True)
    (path / "Contents/Info.plist").write_bytes(
        b'<?xml version="1.0"?><!DOCTYPE plist><plist version="1.0"><dict>'
        b"<key>LSMinimumSystemVersion</key><string>14.0</string></dict></plist>")
    return path


def _staged(tmp_path: Path, monkeypatch) -> Path:
    """A downloaded DMG and the app already copied out of it."""
    monkeypatch.setattr(update, "UPDATES", tmp_path / "updates")
    monkeypatch.setattr(update, "STAGED", tmp_path / "updates/staged/First Edit.app")
    monkeypatch.setattr(update, "APP", tmp_path / "Applications/First Edit.app")
    _app(update.APP)
    _app(update.STAGED)
    dmg = update.UPDATES / "First-Edit-9.9.9.dmg"
    dmg.parent.mkdir(parents=True, exist_ok=True)
    dmg.write_bytes(b"not really a dmg")
    return dmg


def _tools(**over) -> Ran:
    ok_spctl = (0, "", "accepted\nsource=Notarized Developer ID")
    answers = {
        "spctl --assess": ok_spctl,
        "hdiutil attach": (0, "/dev/disk9\tApple_HFS\t/Volumes/First Edit\n", ""),
        "hdiutil detach": (0, "", ""),
        "ditto": (0, "", ""),
        "codesign --verify": (0, "", ""),
        "codesign -dv": (0, "", OURS),
    }
    answers.update(over)
    return Ran(**answers)


def _run_stage(monkeypatch, tmp_path, tools, dmg):
    monkeypatch.setattr(update.subprocess, "run", tools)
    monkeypatch.setattr(update.Path, "glob", lambda self, pat: iter([update.STAGED]))
    return update.stage(dmg)


def test_a_dmg_spctl_rejects_is_deleted_and_nothing_is_staged(tmp_path, monkeypatch, capsys):
    dmg = _staged(tmp_path, monkeypatch)
    tools = _tools(**{"spctl --assess": (3, "", "rejected\nsource=Notarized Developer ID")})
    with pytest.raises(SystemExit):
        _run_stage(monkeypatch, tmp_path, tools, dmg)
    assert "notarized" in capsys.readouterr().out
    assert not dmg.exists() and not update.STAGED.exists()


def test_an_app_from_another_team_is_refused(tmp_path, monkeypatch, capsys):
    dmg = _staged(tmp_path, monkeypatch)
    said = _refused_for(monkeypatch, dmg, capsys, mine=OURS,
                        theirs="Identifier=com.nickcupo.firstedit\nTeamIdentifier=SOMEONE99\n")
    assert "SOMEONE99" in said and "TEAM123456" in said
    assert not dmg.exists() and not update.STAGED.exists()


def _refused_for(monkeypatch, dmg, capsys, mine: str, theirs: str) -> str:
    """stage() with codesign describing the running app as `mine` and the
    download as `theirs`; it has to refuse, and this is what it said."""
    seen: list = []

    def codesign_dv(cmd, *a, **k):
        seen.append(cmd)
        return subprocess.CompletedProcess(cmd, 0, "", theirs if len(seen) > 1 else mine)

    tools = _tools()
    real = tools.__call__

    def dispatch(cmd, *a, **k):
        if cmd[:2] == ["codesign", "-dv"]:
            return codesign_dv(cmd, *a, **k)
        return real(cmd, *a, **k)

    monkeypatch.setattr(update.subprocess, "run", dispatch)
    monkeypatch.setattr(update.Path, "glob", lambda self, pat: iter([update.STAGED]))
    with pytest.raises(SystemExit):
        update.stage(dmg)
    return capsys.readouterr().out


def test_a_download_signed_under_the_old_identifier_is_refused(tmp_path, monkeypatch, capsys):
    """Same team, but not First Edit: an old release is not an update."""
    dmg = _staged(tmp_path, monkeypatch)
    said = _refused_for(monkeypatch, dmg, capsys, mine=OURS, theirs=FORMER)
    assert "com.nickcupo.photo-pipeline" in said and "com.nickcupo.firstedit" in said
    assert not dmg.exists() and not update.STAGED.exists()


def test_a_copy_still_signed_under_the_old_identifier_is_told_to_install_by_hand(tmp_path, monkeypatch, capsys):
    """The first copy under the new identifier is installed by hand; an app
    signed under the old one never swaps itself for it, and says why."""
    dmg = _staged(tmp_path, monkeypatch)
    said = _refused_for(monkeypatch, dmg, capsys, mine=FORMER, theirs=OURS)
    assert "signed as com.nickcupo.photo-pipeline" in said and "by hand" in said
    assert not dmg.exists() and not update.STAGED.exists()


def test_an_ad_hoc_signed_copy_does_not_update_itself(tmp_path, monkeypatch, capsys):
    dmg = _staged(tmp_path, monkeypatch)
    tools = _tools(**{"codesign -dv": (0, "", "Identifier=a.out\n")})   # no TeamIdentifier at all
    with pytest.raises(SystemExit):
        _run_stage(monkeypatch, tmp_path, tools, dmg)
    assert "Build it again from the checkout" in capsys.readouterr().out


def test_gatekeeper_must_accept_the_staged_app_too(tmp_path, monkeypatch, capsys):
    dmg = _staged(tmp_path, monkeypatch)
    calls = {"n": 0}
    tools = _tools()
    real = tools.__call__

    def dispatch(cmd, *a, **k):
        if cmd[0] == "spctl":
            calls["n"] += 1
            if "execute" in cmd:
                return subprocess.CompletedProcess(cmd, 3, "", "rejected")
        return real(cmd, *a, **k)

    monkeypatch.setattr(update.subprocess, "run", dispatch)
    monkeypatch.setattr(update.Path, "glob", lambda self, pat: iter([update.STAGED]))
    with pytest.raises(SystemExit):
        update.stage(dmg)
    assert "not one this Mac would open" in capsys.readouterr().out
    assert not dmg.exists() and not update.STAGED.exists()


def test_a_release_that_passes_every_check_is_staged(tmp_path, monkeypatch, capsys):
    dmg = _staged(tmp_path, monkeypatch)
    monkeypatch.setattr("platform.mac_ver", lambda: ("15.0", ("", "", ""), "arm64"))
    tools = _tools()
    got = _run_stage(monkeypatch, tmp_path, tools, dmg)
    assert got == update.STAGED and update.STAGED.exists()
    assert not dmg.exists()   # the download is not kept once it is unpacked
    out = capsys.readouterr().out
    assert "@@ stage 4 4" in out
    # The requirement it was checked against names this app's own team, and
    # First Edit's identifier.
    assert any("certificate leaf[subject.OU] = \"TEAM123456\"" in " ".join(c) for c in tools.seen)
    assert any('identifier "com.nickcupo.firstedit"' in " ".join(c) for c in tools.seen)


def test_a_failed_swap_says_so_once_instead_of_offering_itself_again(tmp_path, monkeypatch):
    _staged(tmp_path, monkeypatch)
    monkeypatch.setattr(update.os, "kill", lambda *a: (_ for _ in ()).throw(OSError()))
    monkeypatch.setattr(update.shutil, "move", lambda *a: (_ for _ in ()).throw(PermissionError("/Applications is read-only")))
    monkeypatch.setattr(update.subprocess, "Popen", lambda *a, **k: None)
    update.install(pid=999999)
    was = json.loads((update.UPDATES / "install.json").read_text())
    assert was["ok"] is False and "read-only" in was["error"]
    assert not update.STAGED.exists()           # nothing left to offer
    assert update.APP.exists()                  # and the old app is back
    assert update.last_install()["ok"] is False


@pytest.mark.skipif(sys.platform != "darwin", reason="PlistBuddy is macOS's")
def test_the_build_kind_is_only_what_the_bundle_says(tmp_path, monkeypatch):
    """PlistBuddy prints its complaints on stdout, so "Print: Entry ... Does Not
    Exist" would have become the kind of build this is."""
    monkeypatch.setattr(update, "APP", tmp_path / "First Edit.app")
    (update.APP / "Contents").mkdir(parents=True)
    (update.APP / "Contents/Info.plist").write_bytes(
        b'<?xml version="1.0"?><!DOCTYPE plist><plist version="1.0"><dict>'
        b"<key>CFBundleName</key><string>First Edit</string></dict></plist>")
    assert update.build_kind() == "unknown"
    (update.APP / "Contents/Info.plist").write_bytes(
        b'<?xml version="1.0"?><!DOCTYPE plist><plist version="1.0"><dict>'
        b"<key>PhotoPipelineBuild</key><string>private</string></dict></plist>")
    assert update.build_kind() == "private"
