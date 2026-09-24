"""What a build is allowed to hand out.

    .venv/bin/python -m pytest tests/test_release.py -q

Two things guard a build: app/gate.py, the mark a gated build leaves so
STAGE=dmg cannot package an app that never went through the gates, and
app/notices.py, which refuses to describe a bundle it cannot name every
licence in. The gates in app/build.sh itself are run here as well, through
`STAGE=check`, which builds and signs nothing.

Nothing here reads ~/photos or the real library: every tree is built under
pytest's own tmp_path.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "app"))
import gate  # noqa: E402
import notices  # noqa: E402
import bundle_metadata  # noqa: E402


def test_local_wheel_locations_do_not_ship_with_the_python_bundle(tmp_path):
    python = tmp_path / "python"
    site = python / "lib/python3.12/site-packages"
    for name, url in (("local", "file:///Users/someone/wheels/package.whl"),
                      ("remote", "https://example.com/package.whl")):
        info = site / f"{name}-1.0.dist-info"
        info.mkdir(parents=True)
        (info / "direct_url.json").write_text(json.dumps({"url": url}))
        (info / "METADATA").write_text("Name: package\nVersion: 1.0\n")
        (info / "LICENSE").write_text("licence contents")
    assert bundle_metadata.remove_local_origins(python) == 1
    assert not (site / "local-1.0.dist-info/direct_url.json").exists()
    assert (site / "remote-1.0.dist-info/direct_url.json").exists()
    for info in site.iterdir():
        assert (info / "METADATA").read_text() == "Name: package\nVersion: 1.0\n"
        assert (info / "LICENSE").read_text() == "licence contents"
    assert bundle_metadata.remove_local_origins(python) == 0
    script = (ROOT / "app/build.sh").read_text()
    assert script.index('app/bundle_metadata.py "$R/python"') < script.index('echo "== 4b.')


def _app_in_build() -> str:
    """Where build.sh assembles the app, read off its APP= line, so these
    tests follow the app's name wherever build.sh sets it rather than keeping
    a copy of it that drifts."""
    m = re.search(r'^APP="(build/[^"/]+\.app)"$', (ROOT / "app/build.sh").read_text(), re.M)
    assert m, "app/build.sh no longer names the app on an APP= line"
    return m.group(1)


BUILT = _app_in_build()


# ------------------------------------------------------------------ gate.py

def _bundle(tmp_path: Path) -> Path:
    app = tmp_path / "FirstEdit.app"
    (app / "Contents/Resources/pipeline").mkdir(parents=True)
    (app / "Contents/Resources/pipeline/cull.py").write_text("print('cull')\n")
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/MacOS/FirstEdit").write_bytes(b"\xcf\xfa\xed\xfe binary")
    return app


def test_the_marker_says_what_kind_of_build_passed_the_gates(tmp_path):
    app = _bundle(tmp_path)
    marker = tmp_path / "gate.json"
    gate.write(app, marker, "public", False, "0.1.4")
    assert gate.check(app, marker) == ("public", False, False, "0.1.4")


def test_a_version_given_by_hand_is_remembered_for_the_packaging_run(tmp_path):
    # STAGE=dmg can run hours after the build, with no VERSION in its
    # environment, and must not read that absence as "this is not a tag".
    app = _bundle(tmp_path)
    marker = tmp_path / "gate.json"
    gate.write(app, marker, "public", False, "1.0.0-beta1", version_given=True)
    assert gate.check(app, marker) == ("public", False, True, "1.0.0-beta1")


def test_an_older_marker_with_no_version_given_is_read_the_strict_way(tmp_path):
    app = _bundle(tmp_path)
    marker = tmp_path / "gate.json"
    gate.write(app, marker, "public", False, "1.0.0-beta1", version_given=True)
    m = json.loads(marker.read_text())
    del m["version_given"]
    marker.write_text(json.dumps(m))
    assert gate.check(app, marker)[2] is False


def test_the_command_line_prints_the_four_answers_in_order(tmp_path):
    app = _bundle(tmp_path)
    marker = tmp_path / "gate.json"
    out = subprocess.run(
        [sys.executable, str(ROOT / "app/gate.py"), "write", str(app), str(marker),
         "--kind", "private", "--copyleft", "1", "--version", "9.9.9-rc1", "--version-given", "1"],
        capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    out = subprocess.run([sys.executable, str(ROOT / "app/gate.py"), "check", str(app), str(marker)],
                         capture_output=True, text=True)
    # build.sh reads these with `read -r KIND COPYLEFT VGIVEN _`.
    assert out.stdout.split() == ["private", "1", "1", "9.9.9-rc1"]


def test_an_app_touched_since_the_gates_ran_is_refused(tmp_path):
    app = _bundle(tmp_path)
    marker = tmp_path / "gate.json"
    gate.write(app, marker, "public", False, "0.1.4")
    (app / "Contents/Resources/pipeline/reel.py").write_text("print('reel')\n")
    with pytest.raises(SystemExit) as e:
        gate.check(app, marker)
    assert "changed since" in str(e.value)


def test_a_symlink_swapped_into_the_bundle_changes_the_fingerprint(tmp_path):
    app = _bundle(tmp_path)
    before = gate.fingerprint(app)
    p = app / "Contents/Resources/pipeline/cull.py"
    p.unlink()
    p.symlink_to(tmp_path / "elsewhere.py")
    assert gate.fingerprint(app) != before


def test_no_marker_at_all_is_a_refusal(tmp_path):
    with pytest.raises(SystemExit) as e:
        gate.check(_bundle(tmp_path), tmp_path / "nothing.json")
    assert "not assembled, gated and signed" in str(e.value)


# --------------------------------------------------------------- notices.py

def test_a_versioned_library_is_read_back_to_its_project():
    assert notices.stem("libavcodec.61.19.101.dylib") == "libavcodec"
    assert notices.stem("libIex-3_3.32.3.3.4.dylib") == "libIex"
    assert notices.stem("libglib-2.0.0.dylib") == "libglib"
    assert notices.stem("libopencore-amrnb.0.dylib") == "libopencore-amrnb"
    assert notices.stem("libraw_r.dylib") == "libraw_r"


class FakeMeta(dict):
    def get_all(self, key, failobj=None):
        return failobj


class FakeDist:
    """As much of importlib.metadata.Distribution as notices.py reads."""

    def __init__(self, name, version, files, licence="MIT"):
        self.metadata = FakeMeta({"Name": name, "Version": version, "License-Expression": licence})
        self.files = files


def test_a_library_nobody_has_read_the_licence_of_stops_the_build(tmp_path):
    (tmp_path / "wheel").mkdir()
    (tmp_path / "wheel/libsomethingnew.1.dylib").write_bytes(b"x")
    d = FakeDist("wheel", "1.0", ["wheel/libsomethingnew.1.dylib"])
    rows, unknown = notices.native_rows([d], tmp_path)
    assert rows == []
    assert unknown and "libsomethingnew" in unknown[0]


def test_libraw_is_named_with_its_copyleft_licence(tmp_path):
    (tmp_path / "rawpy").mkdir()
    (tmp_path / "rawpy/libraw_r.25.dylib").write_bytes(b"x")
    (tmp_path / "rawpy-0.27.1.dist-info").mkdir()
    (tmp_path / "rawpy-0.27.1.dist-info/LICENSE.LibRaw").write_text("LGPL")
    d = FakeDist("rawpy", "0.27.1", ["rawpy/libraw_r.25.dylib", "rawpy-0.27.1.dist-info/LICENSE.LibRaw"])
    rows, unknown = notices.native_rows([d], tmp_path)
    assert not unknown
    assert rows[0][2] == "LGPL-2.1-only or CDDL-1.0"
    assert "LICENSE.LibRaw" in rows[0][4]


def test_ffmpeg_libraries_carry_the_licence_the_binary_states(tmp_path):
    (tmp_path / "cv2/.dylibs").mkdir(parents=True)
    (tmp_path / "cv2/.dylibs/libavcodec.61.dylib").write_bytes(b"x")
    d = FakeDist("opencv-python-headless", "5.0.0.93", ["cv2/.dylibs/libavcodec.61.dylib"])
    rows, _ = notices.native_rows([d], tmp_path, fflic="GPL version 3 or later")
    assert "GPL version 3 or later" in rows[0][2]


def test_one_file_two_wheels_is_one_row_naming_both(tmp_path):
    (tmp_path / "cv2/.dylibs").mkdir(parents=True)
    (tmp_path / "cv2/.dylibs/libpng16.16.dylib").write_bytes(b"x")
    ds = [FakeDist("opencv-contrib-python", "5.0.0.93", ["cv2/.dylibs/libpng16.16.dylib"]),
          FakeDist("opencv-python-headless", "5.0.0.93", ["cv2/.dylibs/libpng16.16.dylib"])]
    rows, _ = notices.native_rows(ds, tmp_path)
    assert len(rows) == 1
    assert rows[0][1] == "opencv-contrib-python 5.0.0.93 and opencv-python-headless 5.0.0.93"


@pytest.mark.skipif(not (ROOT / ".venv/lib").exists(), reason="no venv in this checkout")
def test_every_native_library_in_this_checkouts_venv_has_a_licence():
    """The table is only worth anything if it covers what is actually installed."""
    from importlib.metadata import Distribution
    site = next((ROOT / ".venv/lib").glob("python*/site-packages"), None)
    if site is None:
        pytest.skip("no site-packages")
    ds = sorted(Distribution.discover(path=[str(site)]), key=lambda d: d.metadata["Name"].lower())
    rows, unknown = notices.native_rows(ds, site)
    assert not unknown, f"no licence in app/notices.py for: {unknown[:5]}"
    assert rows, "no native libraries found at all"


# ------------------------------------------------------- app/build.sh's gates

zsh_only = pytest.mark.skipif(sys.platform != "darwin" or not shutil.which("zsh"),
                              reason="app/build.sh is zsh on macOS")


def _tree(tmp_path: Path, kind: str = "public", bundle: bool = True) -> Path:
    """A checkout as build.sh sees it: the scripts it runs, a pipeline with
    something in it, and (optionally) an app already assembled in build/."""
    repo = tmp_path / "repo"
    (repo / "app").mkdir(parents=True)
    for f in ("build.sh", "gate.py", "lock.py", "notices.py", "macho.py", "make_icon.py",
              "dmg_settings.py", "requirements.lock"):
        shutil.copy(ROOT / "app" / f, repo / "app" / f)
    # The two plists live with the app's other resources now that the app is a
    # Swift package, and build.sh reads them from there.
    (repo / "app/Resources").mkdir()
    for f in ("Info.plist", "entitlements.plist"):
        shutil.copy(ROOT / "app" / "Resources" / f, repo / "app" / "Resources" / f)
    shutil.copy(ROOT / "requirements.txt", repo / "requirements.txt")
    (repo / "pipeline").mkdir()
    (repo / "pipeline/taste.json").write_text('{"venues": {}}\n')
    (repo / "pipeline/cull.py").write_text("print('cull')\n")
    if bundle:
        res = repo / BUILT / "Contents/Resources"
        (res / "pipeline").mkdir(parents=True)
        shutil.copy(repo / "pipeline/cull.py", res / "pipeline/cull.py")
        shutil.copy(repo / "pipeline/taste.json", res / "pipeline/taste.json")
        plist = (repo / BUILT / "Contents/Info.plist")
        plist.write_text('<?xml version="1.0" encoding="UTF-8"?>\n'
                         '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
                         '<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>0.1.4</string>'
                         f'<key>PhotoPipelineBuild</key><string>{kind}</string></dict></plist>\n')
    return repo


def _check(repo: Path, **env) -> subprocess.CompletedProcess:
    return subprocess.run(["zsh", "app/build.sh"], cwd=repo, capture_output=True, text=True,
                          env={**os.environ, "STAGE": "check", "HOME": str(repo / "home"), **env})


@zsh_only
def test_the_gates_pass_a_clean_public_tree(tmp_path):
    r = _check(_tree(tmp_path))
    assert r.returncode == 0, r.stdout + r.stderr
    assert "check: ok" in r.stdout


@zsh_only
def test_a_copyleft_library_in_the_bundle_is_refused(tmp_path):
    repo = _tree(tmp_path)
    (repo / BUILT / "Contents/Resources/libx264.164.dylib").write_bytes(b"x")
    assert _check(repo).returncode != 0
    # The gate is off only for exactly 1: it used to be off for any value at all.
    assert _check(repo, ALLOW_COPYLEFT="0").returncode != 0
    assert _check(repo, ALLOW_COPYLEFT="false").returncode != 0
    ok = _check(repo, ALLOW_COPYLEFT="1")
    assert ok.returncode == 0 and "must not be distributed" in ok.stdout


@zsh_only
def test_a_clean_bundle_does_not_end_the_script_where_grep_finds_nothing(tmp_path):
    """The `--enable-gpl` scan exited 1 on a clean bundle, and under pipefail
    that killed the build with no message: the one case it exists to allow."""
    r = _check(_tree(tmp_path))
    assert r.returncode == 0
    assert "GPL-configured" not in r.stdout


@zsh_only
def test_a_public_bundle_carrying_a_private_module_is_refused(tmp_path):
    repo = _tree(tmp_path)
    (repo / BUILT / "Contents/Resources/pipeline/reel.py").write_text("print('reel')\n")
    r = _check(repo)
    assert r.returncode != 0 and "public bundle carries pipeline/reel.py" in r.stdout


@zsh_only
def test_a_symlink_in_the_bundle_is_refused(tmp_path):
    repo = _tree(tmp_path)
    (repo / "outside.py").write_text("print('outside')\n")
    (repo / BUILT / "Contents/Resources/pipeline/spread.py").symlink_to(repo / "outside.py")
    r = _check(repo)
    assert r.returncode != 0 and "symlinks" in r.stdout


@zsh_only
def test_a_private_module_that_is_a_real_file_stops_a_public_build(tmp_path):
    repo = _tree(tmp_path, bundle=False)
    (repo / "pipeline/reel.py").write_text("print('reel')\n")
    r = _check(repo)
    assert r.returncode != 0 and "is a real file here" in r.stdout


@zsh_only
def test_a_symlinked_module_is_named_as_left_out_and_does_not_stop_a_public_build(tmp_path):
    repo = _tree(tmp_path, bundle=False)
    (tmp_path / "private.py").write_text("print('private')\n")
    (repo / "pipeline/reel.py").symlink_to(tmp_path / "private.py")
    r = _check(repo)
    assert r.returncode == 0 and "left out of a public build" in r.stdout


@zsh_only
def test_his_learned_taste_cannot_go_into_a_public_build(tmp_path):
    repo = _tree(tmp_path, bundle=False)
    seed = tmp_path / "his-taste.json"
    seed.write_text('{"venues": {"a": 1}}')
    r = _check(repo, PIPELINE_TASTE_SEED=str(seed))
    assert r.returncode != 0 and "only into a PRIVATE_BUILD" in r.stdout


@zsh_only
def test_a_public_bundle_whose_taste_is_not_the_repositorys_is_refused(tmp_path):
    repo = _tree(tmp_path)
    (repo / BUILT / "Contents/Resources/pipeline/taste.json").write_text('{"venues": {"his": 1}}')
    r = _check(repo)
    assert r.returncode != 0 and "not the repository's" in r.stdout


@zsh_only
def test_an_app_with_no_marker_would_not_be_packaged(tmp_path):
    r = _check(_tree(tmp_path))
    assert "no gate marker" in r.stdout


@zsh_only
def test_a_pin_the_lock_does_not_answer_for_stops_the_build(tmp_path):
    """A version bumped in requirements.txt and not in the lock is how a lock
    file stops meaning anything."""
    repo = _tree(tmp_path, bundle=False)
    req = (repo / "requirements.txt").read_text().replace("numpy==2.5.3", "numpy==2.6.0")
    (repo / "requirements.txt").write_text(req)
    r = _check(repo)
    assert r.returncode != 0
    assert "does not answer for requirements.txt" in r.stdout and "STAGE=lock" in r.stdout


@zsh_only
def test_every_wheel_in_the_lock_is_named_by_its_bytes(tmp_path):
    """Every requirement in the lock names the exact bytes it installs.

    Two of them are not on PyPI: the OpenCV wheels are built without the GPL
    FFmpeg the published ones carry, so they are named by URL (`name @ https://`)
    rather than by version (`name==`). Both forms are a pin and both must carry
    a hash, which is what this counts."""
    lock = (ROOT / "app/requirements.lock").read_text()
    pins = [l for l in lock.splitlines()
            if not l.startswith("#") and ("==" in l or " @ http" in l)]
    hashes = [l for l in lock.splitlines() if "--hash=sha256:" in l]
    assert len(pins) == len(hashes) >= 20
    assert sum(1 for l in pins if " @ http" in l) == 2


@zsh_only
def test_a_bundle_that_does_not_say_which_kind_it_is_is_treated_as_public(tmp_path):
    """An app built before builds said so has no key, and PlistBuddy answers a
    missing key on stdout. Anything but the word private is held to the public
    rules, which are the strict ones."""
    repo = _tree(tmp_path)
    plist = repo / BUILT / "Contents/Info.plist"
    plist.write_text(plist.read_text().replace(
        "<key>PhotoPipelineBuild</key><string>public</string>", ""))
    (repo / BUILT / "Contents/Resources/pipeline/reel.py").write_text("print('reel')\n")
    r = _check(repo)
    assert "the app in build/ is a unknown build" in r.stdout
    assert r.returncode != 0 and "public bundle carries pipeline/reel.py" in r.stdout
