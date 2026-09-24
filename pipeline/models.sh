#!/bin/zsh
# Fetch the five small models (about 80 MB) into a folder, and prove each one is
# the file it claims to be. Used by ./pl setup and by the app build.
#   pipeline/models.sh <folder>
#
# The work is done in fetch_models.py so there is one implementation of "is this
# the right file", shared with the app's own readiness check. The checksums live
# in models.json beside this script, and they are not decoration: the test they
# replace was `[ -s "$DIR/$1" ]`, which asks only whether a file is non-empty,
# and a 131-byte Git LFS pointer satisfied it for days while standing in for the
# 227 KB face detector.
set -e
DIR="${1:?folder}"
HERE="${0:A:h}"
exec "${PIPELINE_PY:-python3}" "$HERE/fetch_models.py" "$DIR"
