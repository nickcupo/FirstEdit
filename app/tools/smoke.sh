#!/usr/bin/env bash
# Build the app, run it against a scratch library, and check the whole path
# end to end (DESIGN.md §4.4).
#
#   tools/smoke.sh --library /path/to/scratch/lib [--app path/to/FirstEdit] [--expect N] [--deep]
#
# 1. `FirstEdit --check`: the engine starts with a per-launch key and
#    answers an authenticated GET /api/shoots. With --deep it goes through
#    EVERY culled shoot: it builds the session the window builds, takes the
#    frame the light table would open on, and decodes its thumb, its /full and
#    a /crop through the app's own decoder, checking each bitmap has pixels
#    and is not one flat colour. It prints frames, rows, bursts and the
#    cull.csv columns per shoot — which needs a library with culled shoots in
#    it, so app/build.sh asks for it only when it was given a real one.
#
#    Every culled shoot, not the first one: his seven were culled by four
#    builds over three weeks and their cull.csv files do not carry the same
#    columns. Checking the newest and calling it a pass is how a light table
#    that drew no photograph in any shoot went out.
# 2. `FirstEdit --smoke`: the real app opens its window, the engine reaches
#    running, the sidebar is read back out of the window's accessibility tree
#    and must list every shoot, and the app quits.
# 3. The engine's Python child is gone afterwards.
#
# It never runs against ~/photos, and it points every other folder the engine
# writes to at scratch folders beside the library.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
app=$(dirname "$here")

library=""
binary=""
expect=""
deep=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --library) library="$2"; shift 2 ;;
    --app) binary="$2"; shift 2 ;;
    --expect) expect="$2"; shift 2 ;;
    --deep) deep="--deep"; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
library=${library:-${PHOTOS_ROOT:-}}
[[ -n "$library" ]] || { echo "smoke: --library is required, and it must be a scratch clone." >&2; exit 2; }
library=$(cd "$library" && pwd)
case "$library" in
  "$HOME"/photos|"$HOME"/photos/*) echo "smoke: refusing to run against $HOME/photos." >&2; exit 2 ;;
esac
[[ -d "$library/shoots" ]] || { echo "smoke: no shoots folder in $library" >&2; exit 2; }
# The engine's own rule for what a shoot is (pipeline/library.py is_shoot): a
# folder with a raw/, a cull/, or frames lying loose in it. Counting every
# directory under shoots/ instead counted `shoots/shoots` — the empty folder
# the studio's own mkdir used to leave behind under a misread PHOTOS_ROOT — as
# a shoot, so this check and the app disagreed by one on his library.
if [[ -z "$expect" ]]; then
  expect=0
  for d in "$library"/shoots/*/; do
    [[ -d "$d" ]] || continue
    case "$(basename "$d")" in .*) continue ;; esac
    if [[ -d "$d/raw" || -d "$d/cull" ]] ||
       find "$d" -maxdepth 1 -type f \( -iname '*.arw' -o -iname '*.cr2' -o -iname '*.cr3' \
          -o -iname '*.nef' -o -iname '*.dng' -o -iname '*.raf' -o -iname '*.orf' \
          -o -iname '*.rw2' -o -iname '*.jpg' -o -iname '*.jpeg' \) -print -quit | grep -q .; then
      expect=$((expect + 1))
    fi
  done
fi

scratch=$(dirname "$library")
export PHOTOS_ROOT="$library"
export PIPELINE_SUPPORT=${PIPELINE_SUPPORT:-$scratch/support}
export PIPELINE_ICLOUD=${PIPELINE_ICLOUD:-$scratch/icloud}
export PIPELINE_LEARNED=${PIPELINE_LEARNED:-$scratch/learned}
export PIPELINE_EXT=${PIPELINE_EXT:-$scratch/no-extension}
mkdir -p "$PIPELINE_SUPPORT" "$PIPELINE_ICLOUD" "$PIPELINE_LEARNED" "$PIPELINE_EXT"
# The one folder that is deliberately not created: a run that would publish
# anything has nowhere to publish it to.
export PIPELINE_SITE=${PIPELINE_SITE:-$scratch/no-site}
[[ -e "$PIPELINE_SITE" ]] && { echo "smoke: $PIPELINE_SITE exists; name a folder that does not." >&2; exit 2; }

if [[ -z "$binary" ]]; then
  echo "== build"
  (cd "$app" && swift build -c debug --product FirstEdit 2>&1 | tail -1)
  binary="$app/.build/debug/FirstEdit"
fi
[[ -x "$binary" ]] || { echo "smoke: no app at $binary" >&2; exit 1; }

fail() { echo "SMOKE FAILED: $*"; [[ -f "$PIPELINE_SUPPORT/studio.log" ]] && tail -12 "$PIPELINE_SUPPORT/studio.log"; exit 1; }

echo "== headless check against $library${deep:+ (deep)}"
check=$("$binary" --check $deep 2>/dev/null) || { echo "$check"; fail "--check $deep exited non-zero"; }
echo "$check" | sed 's/^/   /'
echo "$check" | grep -q "^OK $expect shoots$" || fail "--check did not list $expect shoots"
if [[ -n "$deep" ]]; then
  # One line per culled shoot, and a photograph decoded through the app's own
  # decoder in each. A shoot that answers its routes but whose light table gets
  # no rows — a shoot culled by an older build, which is most of his — is a
  # FAIL line here and used never to be looked at at all.
  echo "$check" | grep -q '^FAIL ' && fail "a culled shoot has no photograph in its light table"
  echo "$check" | grep -q '^OK a photograph decodes in all ' ||
    fail "--deep did not get through every culled shoot"
  for d in "$library"/shoots/*/; do
    [[ -d "$d/cull/cull.csv" || -f "$d/cull/cull.csv" ]] || continue
    name=$(basename "$d")
    echo "$check" | grep -q "^OK $name: " || fail "--deep never reported on $name"
  done
fi
cpid=$(echo "$check" | sed -n 's/^engine pid \([0-9]*\)$/\1/p')
if [[ -n "$cpid" ]] && kill -0 "$cpid" 2>/dev/null; then fail "the --check engine (pid $cpid) is still running"; fi

echo "== the app"
out=$(mktemp -t smoke)
"$binary" --smoke >"$out" 2>/dev/null &
apppid=$!
for _ in $(seq 1200); do kill -0 "$apppid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$apppid" 2>/dev/null; then
  kill "$apppid" 2>/dev/null || true
  cat "$out"
  fail "the app did not quit within 120 s"
fi
status=0; wait "$apppid" || status=$?
sed 's/^/   /' "$out"
[[ $status -eq 0 ]] || fail "the app exited $status"

grep -q '^ENGINE running on http://127.0.0.1:' "$out" || fail "the engine never reached running"
epid=$(sed -n 's/^ENGINE running on .* pid \([0-9]*\)$/\1/p' "$out")
shown=$(sed -n 's/^SIDEBAR \([0-9]*\) shoots:.*$/\1/p' "$out")
[[ "$shown" == "$expect" ]] || fail "the sidebar showed ${shown:-no} shoots, expected $expect"
for d in "$library"/shoots/*/; do
  [[ -d "$d" ]] || continue          # an empty library is a library
  name=$(basename "$d")
  grep '^SIDEBAR' "$out" | grep -q -- "$name" || fail "the sidebar does not show $name"
done
grep -q '^ENGINE stopped$' "$out" || fail "the app did not stop its engine on the way out"

echo "== nothing left running"
if [[ -n "$epid" ]] && [[ "$epid" != "0" ]]; then
  if pgrep -f studio.py | grep -qx "$epid"; then fail "the engine (pid $epid) outlived the app"; fi
  echo "   engine pid $epid: gone"
fi
if pgrep -P "$apppid" >/dev/null 2>&1; then fail "the app left children behind"; fi
echo "   app pid $apppid: gone, no children"

echo "SMOKE OK: $expect shoots, engine started and stopped cleanly"
