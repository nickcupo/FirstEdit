"""What the repository's own hooks let through.

    .venv/bin/python -m pytest tests/test_hooks.py -q

The hooks are the only thing between a private word and a public history, and
both ways they have failed were silent: the list sat in plain text inside the
hook that was meant to keep it out of the repo, and before that a grep error
passed every commit. So each answer is pinned: no list configured (a
stranger's clone) is let through and says so, a configured list that has gone
missing refuses, and a listed word is refused in a line, a file name and a
commit message.

Every repository here is a scratch one under tmp_path, with its own config and
a made-up word; the real list is never read.
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

HOOKS = Path(__file__).resolve().parents[1] / ".githooks"
SCAN = Path(__file__).resolve().parents[1] / "app" / "tools" / "vocabulary-scan.sh"
pytestmark = pytest.mark.skipif(not shutil.which("zsh") or not shutil.which("git"), reason="the hooks are zsh scripts")


def _git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull, "HOME": str(repo)}
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args],
                          cwd=repo, env=env, capture_output=True, text=True, check=check)


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    r = tmp_path / "repo"
    r.mkdir()
    _git(r, "init", "-q")
    shutil.copytree(HOOKS, r / ".githooks")
    _git(r, "config", "core.hooksPath", ".githooks")
    return r


def _commit(repo: Path, name: str, body: str, message: str = "A file") -> subprocess.CompletedProcess:
    (repo / name).parent.mkdir(parents=True, exist_ok=True)
    (repo / name).write_text(body)
    _git(repo, "add", name)
    return _git(repo, "commit", "-q", "-m", message, check=False)


def _vocab(repo: Path, tmp_path: Path, *words: str) -> Path:
    f = tmp_path / "vocab.txt"
    f.write_text("# a comment line\n\n" + "\n".join(words) + "\n")
    _git(repo, "config", "photopipeline.vocabfile", str(f))
    return f


def test_no_list_configured_lets_a_strangers_clone_commit_and_says_why(repo):
    r = _commit(repo, "a.txt", "zebra crossing\n")
    assert r.returncode == 0, r.stdout + r.stderr
    assert "vocabulary check is skipped" in r.stdout + r.stderr


def test_a_configured_list_that_has_gone_missing_refuses(repo, tmp_path):
    _git(repo, "config", "photopipeline.vocabfile", str(tmp_path / "nowhere.txt"))
    r = _commit(repo, "a.txt", "nothing listed here\n")
    assert r.returncode != 0
    assert "not a file this hook can read" in r.stdout + r.stderr


def test_a_list_with_no_words_refuses(repo, tmp_path):
    f = tmp_path / "vocab.txt"
    f.write_text("# only comments\n\n")
    _git(repo, "config", "photopipeline.vocabfile", str(f))
    r = _commit(repo, "a.txt", "nothing listed here\n")
    assert r.returncode != 0
    assert "lists no words" in r.stdout + r.stderr


def test_a_listed_word_in_an_added_line_is_refused(repo, tmp_path):
    _vocab(repo, tmp_path, "zebra", "okapi")
    r = _commit(repo, "a.txt", "a line about a Zebra\n")
    assert r.returncode != 0
    assert "domain vocabulary in added lines" in r.stdout + r.stderr


def test_a_word_inside_another_word_is_not_a_hit(repo, tmp_path):
    _vocab(repo, tmp_path, "zebra")
    r = _commit(repo, "a.txt", "zebras and zebrafish are other words\n")
    assert r.returncode == 0, r.stdout + r.stderr


def test_a_listed_word_in_a_file_name_is_refused(repo, tmp_path):
    _vocab(repo, tmp_path, "zebra")
    r = _commit(repo, "fixtures/zebra_1.txt", "clean\n")
    assert r.returncode != 0
    assert "the name of an added file" in r.stdout + r.stderr


def test_a_listed_word_in_the_commit_message_is_refused(repo, tmp_path):
    _vocab(repo, tmp_path, "zebra")
    r = _commit(repo, "a.txt", "clean\n", message="The zebra frames are culled")
    assert r.returncode != 0
    assert "commit message" in r.stdout + r.stderr


def test_a_word_in_a_comment_line_of_the_message_is_refused_too(repo, tmp_path):
    """git keeps a # line of a message given with -m, so it is scanned."""
    _vocab(repo, tmp_path, "zebra")
    r = _commit(repo, "a.txt", "clean\n", message="A clean change\n\n# zebra")
    assert r.returncode != 0


def test_a_clean_commit_passes_with_the_list_in_force(repo, tmp_path):
    _vocab(repo, tmp_path, "zebra")
    r = _commit(repo, "a.txt", "clean\n", message="A clean change\n\nWith a body that names nothing listed.")
    assert r.returncode == 0, r.stdout + r.stderr


def test_the_private_modules_are_refused(repo):
    r = _commit(repo, "pipeline/reel.py", "print('x')\n")
    assert r.returncode != 0
    assert "belongs to the private repo" in r.stdout + r.stderr


def test_the_tracked_hooks_carry_no_word_list():
    """The list moved out of the hook; nothing in .githooks may name it again."""
    for f in HOOKS.iterdir():
        text = f.read_text()
        assert "words='" not in text, f"{f.name} carries a literal word list"


# ------------------------------------------------- the key the rename kept
#
# The app is First Edit now, and this key keeps its old name on purpose. His
# clone sets it; a hook or a scan that read a renamed key would find nothing
# set, take his clone for a stranger's, and pass every commit with one line
# saying it skipped. So the key is spelled out in these two, rather than taken
# from _vocab: renaming it in the scripts and in the helper together still
# fails here.

def test_the_hook_is_still_armed_by_the_key_his_clone_sets(repo, tmp_path):
    f = tmp_path / "vocab.txt"
    f.write_text("zebra\n")
    _git(repo, "config", "photopipeline.vocabfile", str(f))
    r = _commit(repo, "a.txt", "a line about a zebra\n")
    assert r.returncode != 0
    assert "domain vocabulary in added lines" in r.stdout + r.stderr


def test_the_tree_scan_is_still_armed_by_the_same_key(tmp_path):
    r = tmp_path / "scan"
    (r / "app" / "tools").mkdir(parents=True)
    shutil.copy(SCAN, r / "app" / "tools" / "vocabulary-scan.sh")
    _git(r, "init", "-q")
    f = tmp_path / "vocab.txt"
    f.write_text("zebra\n")
    _git(r, "config", "photopipeline.vocabfile", str(f))
    (r / "a.txt").write_text("a line about a zebra\n")
    _git(r, "add", "-A")
    env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull, "HOME": str(r)}
    out = subprocess.run(["bash", str(r / "app" / "tools" / "vocabulary-scan.sh")], env=env,
                         capture_output=True, text=True)
    assert out.returncode != 0, out.stdout + out.stderr
    assert "vocabulary is in the tree" in out.stdout
