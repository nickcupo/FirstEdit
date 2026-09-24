#!/usr/bin/env python3
"""
update.py - the app updating itself from the releases page.

    update.py --check                 print JSON: current, latest, url, notes
    update.py --download URL          fetch the DMG into the updates folder, with @@ download progress
    update.py --stage DMG             check what was downloaded, copy the app out of it, ready to install
    update.py --install --pid N       wait for the running app (pid) to quit, swap the app, relaunch

The app (studio.py --app) drives these. Nothing here runs from a checkout;
there, `git pull` is the update. PIPELINE_APP_PATH is the installed app,
PIPELINE_APP_VERSION its version, PIPELINE_SUPPORT its support folder.

This is the one thing in the pipeline that takes a file off the internet and
then runs it as him. So: https, on GitHub, at every hop of the redirect; the
DMG has to carry Apple's notarization ticket; and the app inside it has to be
signed by the same team as the app that is asking for the update, under the
one bundle identifier both have to carry (BUNDLE_ID). A download that fails
any of those is deleted rather than kept, and nothing is staged. --check says
plainly when it cannot reach the releases page instead of handing the page a
Python exception.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from common import APP_BUNDLE_NAME, APP_NAME, support_dir  # noqa: E402

REPO = "nickcupo/first-edit"
API = f"https://api.github.com/repos/{REPO}/releases/latest"
# The app's bundle identifier. The running app and the download must both
# carry it, so it is fixed for good once a release is out: a copy already
# installed would refuse any release signed under another one. It changed
# once, from com.nickcupo.photo-pipeline, before any release was public;
# that first copy under the new identifier is installed by hand, and an app
# still signed under the old one is told so rather than updated.
BUNDLE_ID = "com.nickcupo.firstedit"
AGENT = "first-edit"
SUPPORT = support_dir()
UPDATES = SUPPORT / "updates"
STAGED = UPDATES / "staged" / f"{APP_BUNDLE_NAME}.app"
APP = Path(os.environ.get("PIPELINE_APP_PATH", f"/Applications/{APP_BUNDLE_NAME}.app"))
CURRENT = os.environ.get("PIPELINE_APP_VERSION", "0")


def vtuple(v: str) -> tuple:
    return tuple(int(x) for x in re.findall(r"\d+", v.split("-")[0])[:3]) or (0,)


def on_github(url: str) -> bool:
    """https, and a GitHub host. The release API hands back a download URL and
    GitHub redirects it to its asset store; every hop is checked, because a
    redirect is the one part of a download nobody sees."""
    u = urllib.parse.urlsplit(url)
    host = (u.hostname or "").lower()
    return u.scheme == "https" and (host == "github.com" or host.endswith((".github.com", ".githubusercontent.com")))


class GitHubOnly(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not on_github(newurl):
            raise urllib.error.URLError(f"the download was redirected off GitHub, to {newurl}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def signature(path: Path) -> dict:
    """What codesign says about a bundle: Identifier, TeamIdentifier, and the
    authorities that signed it. Missing keys mean it is not signed that way."""
    r = subprocess.run(["codesign", "-dv", "--verbose=4", str(path)], capture_output=True, text=True)
    out: dict = {}
    for line in (r.stderr + r.stdout).splitlines():
        k, _, v = line.partition("=")
        if _ and k.strip() and k.strip() not in out:
            out[k.strip()] = v.strip()
    return out


def refuse(why: str, dmg: Path | None = None, detail: str = "") -> None:
    """Nothing half-installed is left behind: the staged app goes, and so does
    the download, so the next check starts from nothing rather than offering
    the same broken file again."""
    print(f"  {why}" + (f"\n{detail.strip()}" if detail.strip() else ""))
    shutil.rmtree(STAGED, ignore_errors=True)
    if dmg is not None:
        dmg.unlink(missing_ok=True)
    sys.exit(1)


def check() -> dict:
    req = urllib.request.Request(API, headers={"Accept": "application/vnd.github+json", "User-Agent": AGENT})
    try:
        with urllib.request.build_opener(GitHubOnly()).open(req, timeout=10) as r:
            rel = json.load(r)
    except urllib.error.HTTPError as e:
        return {"current": CURRENT, "newer": False, "error": f"GitHub answered {e.code} when asked for the latest release"}
    except (urllib.error.URLError, TimeoutError, OSError):
        # No network, a captive wifi, a flight. Said as a person would say it:
        # the page used to print json.JSONDecodeError's own words here.
        return {"current": CURRENT, "newer": False, "error": "this Mac cannot reach GitHub at the moment"}
    except ValueError:
        return {"current": CURRENT, "newer": False, "error": "GitHub did not answer with a release"}
    tag = rel.get("tag_name", "")
    asset = next((a for a in rel.get("assets", []) if a["name"].endswith(".dmg")), None)
    out = {"current": CURRENT, "latest": tag.lstrip("v"), "url": asset["browser_download_url"] if asset else "",
           "size": asset["size"] if asset else 0, "notes": rel.get("body", ""), "page": rel.get("html_url", ""),
           "newer": bool(asset) and vtuple(tag) > vtuple(CURRENT) and on_github(asset["browser_download_url"]),
           "installed": not str(APP).startswith("/Volumes/"),
           "build": build_kind(),
           "last_install": last_install()}
    return out


def build_kind() -> str:
    """public, or private for a copy built with PRIVATE_BUILD=1, which carries
    modules the public one does not. PlistBuddy says its complaints on stdout,
    so a missing key would otherwise have become the answer."""
    try:
        r = subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print :PhotoPipelineBuild",
                            str(APP / "Contents/Info.plist")], capture_output=True, text=True)
    except OSError:
        return "unknown"
    got = r.stdout.strip()
    return got if r.returncode == 0 and got in ("public", "private") else "unknown"


def last_install() -> dict:
    """What became of the last install, so a failed swap is said once rather
    than offered again for ever."""
    try:
        was = json.loads((UPDATES / "install.json").read_text())
    except (OSError, ValueError):
        return {}
    return {} if was.get("ok") else was


def download(url: str) -> Path:
    if not on_github(url):
        print(f"  refusing to download {url}: an update comes from GitHub over https, and nowhere else.")
        sys.exit(1)
    UPDATES.mkdir(parents=True, exist_ok=True)
    # The name comes off a URL, so it is allowed to be a name and nothing else.
    name = re.sub(r"[^A-Za-z0-9._-]", "-", urllib.parse.urlsplit(url).path.rsplit("/", 1)[-1])
    dest = UPDATES / (name if name.endswith(".dmg") else "update.dmg")
    part = dest.with_name(dest.name + ".part")
    req = urllib.request.Request(url, headers={"User-Agent": AGENT})
    with urllib.request.build_opener(GitHubOnly()).open(req, timeout=30) as r, part.open("wb") as fh:
        total = int(r.headers.get("Content-Length") or 0)
        mb = max(1, total // 1_000_000)
        done = 0
        last = -1
        print(f"@@ download 0 {mb}", flush=True)
        for chunk in iter(lambda: r.read(1 << 20), b""):
            fh.write(chunk)
            done += len(chunk)
            if done // 1_000_000 != last:
                last = done // 1_000_000
                print(f"@@ download {min(last, mb - 1)} {mb}", flush=True)
    if total and done != total:
        part.unlink(missing_ok=True)
        print(f"  the download stopped early: {done:,} bytes of {total:,}. Not installing.")
        sys.exit(1)
    part.replace(dest)
    print(f"@@ download {mb} {mb}", flush=True)
    print(f"  downloaded {dest.name}, {done / 1e6:.0f} MB")
    return dest


def stage(dmg: Path) -> Path:
    """Everything that has to be true before an app off the internet replaces
    the one running. Each answer is checked on its own; a refusal takes the
    download and the half-staged copy with it."""
    print("@@ stage 0 4", flush=True)
    # 1. Apple has notarized this DMG, checked the way Gatekeeper checks it.
    # The verdict is spctl's exit status as well as its words: the words alone
    # said "Notarized Developer ID" in output that also said "rejected".
    r = subprocess.run(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "-v", str(dmg)],
                       capture_output=True, text=True)
    said = r.stderr + r.stdout
    if r.returncode != 0 or "accepted" not in said or "Notarized Developer ID" not in said:
        refuse("the download is not a DMG Apple has notarized; not installing.", dmg, said)

    print("@@ stage 1 4", flush=True)
    out = subprocess.run(["hdiutil", "attach", "-nobrowse", "-noautoopen", "-readonly", str(dmg)], capture_output=True, text=True, check=True).stdout
    mount = re.search(r"(/Volumes/.*)$", out, re.M).group(1).strip()
    try:
        src = next(Path(mount).glob("*.app"), None)
        if src is None:
            refuse("there is no app inside that disk image; not installing.", dmg)
        if STAGED.exists():
            shutil.rmtree(STAGED)
        STAGED.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["ditto", str(src), str(STAGED)], check=True)
    finally:
        subprocess.run(["hdiutil", "detach", "-quiet", mount], capture_output=True)

    print("@@ stage 2 4", flush=True)
    # 2. The signature is whole, every nested piece of it.
    r = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(STAGED)], capture_output=True, text=True)
    if r.returncode != 0:
        refuse("the staged app does not verify; not installing.", dmg, r.stderr)

    # 3. It is the same app, from the same team, as the one asking for the
    # update: this app's bundle identifier (BUNDLE_ID) on both, the same Team
    # ID, signed by Apple's chain. Without this, "notarized" only means Apple
    # has seen it -- and Apple notarizes a great deal of software that is not
    # this.
    mine, theirs = signature(APP), signature(STAGED)
    team = mine.get("TeamIdentifier", "not set")
    ident = mine.get("Identifier", "")
    if team == "not set" or not ident:
        refuse(f"this copy of {APP_NAME} was not signed with a Developer ID, so there is nothing to "
               "match a download against. Build it again from the checkout instead.", dmg)
    if ident != BUNDLE_ID:
        refuse(f"this copy is signed as {ident}, not as {APP_NAME} ({BUNDLE_ID}), so it cannot take "
               f"{APP_NAME}'s releases. Install the new version by hand from the releases page.", dmg)
    if theirs.get("TeamIdentifier") != team or theirs.get("Identifier") != BUNDLE_ID:
        refuse(f"the downloaded app is signed by {theirs.get('TeamIdentifier', 'nobody')} as "
               f"{theirs.get('Identifier', 'nothing')}, not by {team} as {BUNDLE_ID}. Not installing.", dmg)
    req = f'anchor apple generic and identifier "{BUNDLE_ID}" and certificate leaf[subject.OU] = "{team}"'
    r = subprocess.run(["codesign", "--verify", "--strict", "-R", f"={req}", str(STAGED)], capture_output=True, text=True)
    if r.returncode != 0:
        refuse("the downloaded app does not satisfy this app's own signing requirement; not installing.", dmg, r.stderr)

    print("@@ stage 3 4", flush=True)
    # 4. And Gatekeeper would let it run: the same question the Mac asks on
    # the first launch, asked before the swap rather than after it.
    r = subprocess.run(["spctl", "--assess", "--type", "execute", "-vv", str(STAGED)], capture_output=True, text=True)
    said = r.stderr + r.stdout
    if r.returncode != 0 or "accepted" not in said:
        refuse("the downloaded app is not one this Mac would open; not installing.", dmg, said)

    # The release may need a newer macOS than this one (14.0 from 0.1.3, for
    # the wheels the bundle carries); an app that will not launch is no update.
    import platform
    import plistlib
    try:
        with (STAGED / "Contents/Info.plist").open("rb") as fh:
            need = str(plistlib.load(fh).get("LSMinimumSystemVersion", "0"))
    except Exception:  # noqa: BLE001
        need = "0"
    if vtuple(platform.mac_ver()[0]) < vtuple(need):
        refuse(f"this release needs macOS {need}; this Mac runs {platform.mac_ver()[0]}. Not installing.", dmg)
    dmg.unlink(missing_ok=True)
    print("@@ stage 4 4", flush=True)
    print(f"  ready to install from {STAGED}")
    return STAGED


def install(pid: int) -> None:
    """Runs detached from the app: waits for it to quit, swaps the bundle, relaunches."""
    log = UPDATES / "install.log"
    # The log is what is left when a swap goes wrong, so it is kept -- but it
    # is kept short: it used to be appended to for ever.
    if log.exists() and log.stat().st_size > 200_000:
        log.write_text("\n".join(log.read_text(errors="ignore").splitlines()[-400:]) + "\n")
    with log.open("a") as fh:
        def say(m):
            fh.write(time.strftime("%H:%M:%S ") + m + "\n")
            fh.flush()
        say(f"waiting for pid {pid} to quit")
        for _ in range(600):
            try:
                os.kill(pid, 0)
            except OSError:
                break
            time.sleep(0.5)
        else:
            say("the app did not quit; giving up")
            done(False, "the app did not quit, so nothing was installed")
            return
        old = APP.with_name(APP.name + ".old")
        try:
            if old.exists():
                shutil.rmtree(old)
            if APP.exists():
                APP.rename(old)
            shutil.move(str(STAGED), str(APP))
            shutil.rmtree(old, ignore_errors=True)
            say(f"installed {APP}")
            done(True, "")
        except Exception as e:  # noqa: BLE001
            say(f"swap failed: {e}; putting the old app back")
            if not APP.exists() and old.exists():
                old.rename(APP)
            # The staged copy goes, and the reason is written where the page
            # can read it. It used to stay, so the update card offered the
            # same install at every launch and it failed the same way every
            # time, silently: /Applications needs a password to write to when
            # the app was installed by someone else.
            shutil.rmtree(STAGED, ignore_errors=True)
            done(False, str(e))
        subprocess.Popen(["open", str(APP)])
        say("relaunched")


def done(ok: bool, why: str) -> None:
    """What happened to the last install, for the page to say out loud."""
    UPDATES.mkdir(parents=True, exist_ok=True)
    (UPDATES / "install.json").write_text(json.dumps(
        {"ok": ok, "error": why, "at": time.strftime("%Y-%m-%dT%H:%M:%S"), "version": CURRENT}) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--download")
    ap.add_argument("--stage", type=Path)
    ap.add_argument("--install", action="store_true")
    ap.add_argument("--pid", type=int, default=0)
    a = ap.parse_args()
    if a.check:
        print(json.dumps(check()))
    elif a.download:
        dmg = download(a.download)
        stage(dmg)
    elif a.stage:
        stage(a.stage)
    elif a.install:
        install(a.pid)
    else:
        ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
