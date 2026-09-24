"""The suite cannot reach his real folders: conftest.py points every one of
them somewhere else, and refuses a read that goes around it."""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

import pytest


def _conftest():
    return next(m for n, m in sys.modules.items() if n.endswith("conftest") and hasattr(m, "_REACHED"))


@pytest.mark.parametrize("var", ["PIPELINE_SUPPORT", "PIPELINE_LEARNED", "PIPELINE_ICLOUD", "PIPELINE_EXT", "PHOTOS_ROOT",
                                 "PIPELINE_EVAL_CACHE"])
def test_every_folder_of_his_is_pointed_at_tmp(var):
    if var == "PHOTOS_ROOT" and os.environ.get("PIPELINE_TEST_HIS_LIBRARY") == "1":
        pytest.skip("asked to read his library by name")
    assert os.environ[var].startswith(os.path.realpath(tempfile.gettempdir())) or \
        os.environ[var].startswith(tempfile.gettempdir())


@pytest.mark.parametrize("name", ["First Edit", "Photo Pipeline"])
def test_a_read_that_goes_around_the_environment_is_refused(name):
    """Under the app's name and under the name it had before, which is a link
    to the same folder once the app has renamed it."""
    c = _conftest()
    before = len(c._REACHED)
    target = Path(os.path.expanduser("~")).resolve() / "Library" / "Application Support" / name / "learned"
    with pytest.raises(PermissionError):
        os.listdir(target)
    with pytest.raises(PermissionError):
        open(target / "manifest.json")
    # Counted, and then forgiven here: this test is the one that asked.
    assert len(c._REACHED) == before + 2
    del c._REACHED[before:]
