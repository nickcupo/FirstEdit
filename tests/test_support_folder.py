"""Where the engine finds the app's support folder, now that the app has a new name.

    .venv/bin/python -m pytest tests/test_support_folder.py -q

The folder was ~/Library/Application Support/Photo Pipeline. The app renames
it to First Edit the first time it opens under the new name, and leaves a link
at the old path. A run from a checkout has no PIPELINE_SUPPORT, so it has to
find the folder itself, and every part of the engine has to find the SAME one:
two learned stores that never see each other is the failure this exists to
prevent. So there is one resolver, common.support_dir(), and every other
answer (the learned folder, the extension, the updater) comes from it.

Every home here is under tmp_path. None of these tests looks at his real
Application Support folder: the resolver checks which folders exist, and that
check would otherwise land on his.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

PIPELINE = Path(__file__).resolve().parents[1] / "pipeline"
sys.path.insert(0, str(PIPELINE))
import common  # noqa: E402
import learned  # noqa: E402


@pytest.fixture
def home(tmp_path, monkeypatch) -> Path:
    """A home of our own, with nothing telling the engine where to look."""
    h = tmp_path / "home"
    (h / "Library" / "Application Support").mkdir(parents=True)
    monkeypatch.setenv("HOME", str(h))
    for k in ("PIPELINE_SUPPORT", "PIPELINE_LEARNED", "PIPELINE_EXT"):
        monkeypatch.delenv(k, raising=False)
    return h


def _as(home: Path, name: str) -> Path:
    return home / "Library" / "Application Support" / name


def test_the_names_are_the_new_one_and_the_old_one():
    assert common.APP_NAME == "First Edit"
    assert common.FORMER_APP_NAMES == ("Photo Pipeline",)


def test_the_environment_wins_over_any_folder_on_disk(home, tmp_path, monkeypatch):
    _as(home, "First Edit").mkdir()
    _as(home, "Photo Pipeline").mkdir()
    monkeypatch.setenv("PIPELINE_SUPPORT", str(tmp_path / "scratch"))
    assert common.support_dir() == tmp_path / "scratch"


def test_with_neither_folder_it_is_the_new_name_and_asking_makes_nothing(home):
    assert common.support_dir() == _as(home, "First Edit")
    assert not _as(home, "First Edit").exists(), "asking where it is made one"
    assert common.support_dir(create=True).is_dir()
    assert not _as(home, "Photo Pipeline").exists(), "the old name is never made"


def test_before_the_app_has_renamed_it_the_old_folder_is_found(home):
    """A checkout run on a Mac where the renamed app has not opened yet: his
    models and his learned store are still under the old name, and a new
    empty folder beside them would be a second store."""
    (_as(home, "Photo Pipeline") / "learned").mkdir(parents=True)
    assert common.support_dir() == _as(home, "Photo Pipeline")
    assert common.support_dir(create=True) == _as(home, "Photo Pipeline")
    assert not _as(home, "First Edit").exists()


def test_after_the_rename_the_new_folder_is_found_with_the_link_beside_it(home):
    """What the app leaves: the folder under the new name, and a relative
    link at the old path that points to it."""
    (_as(home, "First Edit") / "learned").mkdir(parents=True)
    _as(home, "Photo Pipeline").symlink_to("First Edit")
    assert common.support_dir() == _as(home, "First Edit")


def test_two_real_folders_are_never_merged_and_the_new_one_is_used(home):
    """The app does the same: the new folder is used and the other is left
    exactly where it is, for him to look at."""
    (_as(home, "First Edit") / "learned").mkdir(parents=True)
    (_as(home, "Photo Pipeline") / "learned").mkdir(parents=True)
    (_as(home, "Photo Pipeline") / "learned" / "manifest.json").write_text("{}")
    assert common.support_dir() == _as(home, "First Edit")
    assert (_as(home, "Photo Pipeline") / "learned" / "manifest.json").read_text() == "{}"


@pytest.mark.parametrize("present", ["First Edit", "Photo Pipeline"])
def test_the_learned_folder_follows_the_same_answer(home, present):
    """learned.folder() and common.learned_dir() used to carry a path each; a
    change to one and not the other is how a checkout and the app would learn
    into two different folders."""
    _as(home, present).mkdir()
    assert common.learned_dir() == _as(home, present) / "learned"
    assert learned.folder() == _as(home, present) / "learned"


@pytest.mark.parametrize("present", ["First Edit", "Photo Pipeline"])
def test_the_extension_is_looked_for_in_the_same_folder(home, present):
    ext = _as(home, present) / "extension"
    ext.mkdir(parents=True)
    (ext / "studio_ext.py").write_text("KIND = 'test'\n")
    assert common._find_ext() == ext


def test_the_extension_named_in_the_environment_wins(home, tmp_path, monkeypatch):
    ext = _as(home, "First Edit") / "extension"
    ext.mkdir(parents=True)
    (ext / "studio_ext.py").write_text("KIND = 'test'\n")
    monkeypatch.setenv("PIPELINE_EXT", str(tmp_path / "mine"))
    assert common._find_ext() == tmp_path / "mine"


@pytest.mark.parametrize("present", ["First Edit", "Photo Pipeline", None])
def test_the_updater_keeps_its_downloads_in_the_same_folder(home, present):
    """update.py reads its folder once, as it starts, so it is asked in a
    process of its own with this home and no PIPELINE_SUPPORT."""
    if present:
        _as(home, present).mkdir()
    env = {k: v for k, v in os.environ.items() if k not in ("PIPELINE_SUPPORT", "PIPELINE_LEARNED")}
    env.update(HOME=str(home), PIPELINE_EXT=str(home / "no-extension"))
    out = subprocess.run([sys.executable, "-c", "import update; print(update.SUPPORT); print(update.UPDATES)"],
                         cwd=PIPELINE, env=env, capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    want = _as(home, present or "First Edit")
    assert out.stdout.splitlines() == [str(want), str(want / "updates")]


# ------------------------------------------------------------ ./pl, in shell

PL = PIPELINE.parent / "pl"
PROBE = "zz-which-extension"


def _fake_ext(folder: Path) -> Path:
    """An extension whose pl says where it is and what it was handed, and
    does nothing else."""
    folder.mkdir(parents=True, exist_ok=True)
    pl = folder / "pl"
    pl.write_text('#!/bin/zsh\necho "ext=${0:A:h}"\necho "public=${PIPELINE_PUBLIC:-}"\necho "cmd=$1"\n')
    pl.chmod(0o755)
    return folder


def _pl(home: Path, **env: str) -> dict[str, str]:
    """./pl with a command only an extension answers, run with this home and
    none of the conftest's variables, so it searches as a checkout run does.
    Each test puts an extension where the search must stop, so it never goes
    on to a real one beside the checkout."""
    e = {k: v for k, v in os.environ.items() if not k.startswith("PIPELINE_")}
    e.update(HOME=str(home), PIPELINE_PUBLIC="/somewhere/else", **env)
    out = subprocess.run(["/bin/zsh", str(PL), PROBE], env=e, capture_output=True, text=True, timeout=30)
    assert out.returncode == 0, out.stdout + out.stderr
    return dict(line.split("=", 1) for line in out.stdout.splitlines() if "=" in line)


def test_pl_finds_the_extension_in_the_old_folder_before_the_app_has_renamed_it(home):
    ext = _fake_ext(_as(home, "Photo Pipeline") / "extension")
    got = _pl(home)
    assert Path(got["ext"]).resolve() == ext.resolve()
    assert got["cmd"] == PROBE


def test_pl_finds_it_in_the_new_folder_with_the_link_beside_it(home):
    ext = _fake_ext(_as(home, "First Edit") / "extension")
    _as(home, "Photo Pipeline").symlink_to("First Edit")
    assert Path(_pl(home)["ext"]).resolve() == ext.resolve()


def test_pl_uses_the_new_folder_when_both_are_real_as_the_engine_does(home):
    new = _fake_ext(_as(home, "First Edit") / "extension")
    _fake_ext(_as(home, "Photo Pipeline") / "extension")
    assert Path(_pl(home)["ext"]).resolve() == new.resolve()
    assert common._find_ext() == _as(home, "First Edit") / "extension"


def test_pl_looks_in_the_support_folder_the_environment_names_first(home, tmp_path):
    _fake_ext(_as(home, "First Edit") / "extension")
    scratch = _fake_ext(tmp_path / "scratch-support" / "extension")
    assert Path(_pl(home, PIPELINE_SUPPORT=str(tmp_path / "scratch-support"))["ext"]).resolve() == scratch.resolve()


def test_pl_runs_the_extension_the_environment_names(home, tmp_path):
    _fake_ext(_as(home, "First Edit") / "extension")
    mine = _fake_ext(tmp_path / "mine")
    assert Path(_pl(home, PIPELINE_EXT=str(mine))["ext"]).resolve() == mine.resolve()


def test_pl_tells_the_extension_where_this_checkouts_engine_is(home):
    """The organizer imports the engine from PIPELINE_PUBLIC. Nothing set it
    on this road, so it guessed at a checkout beside the extension; and one
    inherited from somewhere else is not this checkout's either."""
    _fake_ext(_as(home, "First Edit") / "extension")
    assert _pl(home)["public"] == str(PIPELINE)


# ----------------------------------------- the same names on both sides

def test_the_app_and_the_engine_name_the_same_folders_and_identifier():
    """The app moves the folder and the engine goes looking for it, each by
    names written in its own language. If one side is edited alone, a checkout
    run and the app keep two support folders again."""
    import re
    import update
    src = (PIPELINE.parent / "app/Sources/PipelineKit/Engine/FirstLaunch.swift").read_text()

    def const(enum: str, name: str) -> str:
        block = re.search(rf"enum {enum} \{{(.*?)\n    \}}", src, re.S).group(1)
        return re.search(rf'static let {name} = "([^"]+)"', block).group(1)

    assert const("New", "folder") == common.APP_NAME
    assert const("Old", "folder") in common.FORMER_APP_NAMES
    assert const("New", "bundleID") == update.BUNDLE_ID


def test_the_app_the_updater_and_the_build_name_the_same_app_and_repository():
    """Report an Issue, the update check and the two OpenCV wheels all go to
    one repository. Display branding is independent of the installed executable
    and support-folder name, which must remain compatible."""
    import plistlib
    import update
    app = PIPELINE.parent / "app"
    with (app / "Resources/Info.plist").open("rb") as fh:
        info = plistlib.load(fh)
    assert info["CFBundleName"] == info["CFBundleDisplayName"] == "FirstEdit"
    assert info["CFBundleExecutable"] == common.APP_NAME == "First Edit"
    assert f'"/{update.REPO}/issues/new"' in (app / "Sources/PipelineKit/Help/HelpBook.swift").read_text()
    wheels = [ln for ln in (app / "requirements.lock").read_text().splitlines() if "releases/download" in ln]
    assert len(wheels) == 2 and all(f"https://github.com/{update.REPO}/releases/download/" in ln for ln in wheels)
