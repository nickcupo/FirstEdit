#!/bin/zsh
# One-time setup from a checkout: a venv, the five small models (about 80 MB)
# and CLIP ViT-L/14 (about 1.7 GB, into the Hugging Face cache). Nothing in
# models/ is stored in git. Needs Python 3.12 and exiftool (brew install exiftool).
# The app built by app/build.sh carries all of this inside itself.
set -e -o pipefail
cd "$(dirname "$0")"
# 3.12, and nothing else. requirements.txt is pinned to the versions the app is
# built and tested with, mediapipe has no wheel past 3.12, and the fallback to
# whatever python3 happened to be first sent people into a wall of pip
# resolution errors instead of this sentence.
py=""
for c in python3.12 python3; do
  command -v "$c" >/dev/null || continue
  "$c" -c 'import sys; sys.exit(sys.version_info[:2] != (3, 12))' 2>/dev/null && { py="$c"; break; }
done
if [ -z "$py" ]; then
  echo "First Edit needs Python 3.12 (brew install python@3.12); requirements.txt is pinned to it."
  command -v python3 >/dev/null && echo "  the python3 on this machine is $(python3 -V 2>&1)"
  exit 1
fi
echo "using $($py -V)"
"$py" -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -r requirements.txt
pipeline/models.sh models
# sed, not grep: the progress lines are dropped either way, but grep finding
# nothing to keep would have failed the pipeline, and with pipefail on, a
# failed download now stops this rather than being followed by "done."
.venv/bin/python pipeline/fetch_clip.py | sed '/^@@/d'
echo "done.  ./pl --help says what there is; app/build.sh builds the Mac app."
