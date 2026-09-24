#!/usr/bin/env bash
# Build the app, run it against a scratch library, and check the whole path
# end to end (DESIGN.md §4.4).
#
#   tools/smoke.sh --library /path/to/scratch/lib [--app path/to/FirstEdit] [--expect N] [--deep] [--offscreen]
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
# 2. `FirstEdit --smoke-offscreen`: the real RootView is hosted beyond every
#    screen in a non-key/non-main window; the app has no Dock presence. The
#    engine reaches running, real sidebar rows are counted, each shoot must
#    change the real window title through navigation, and the app quits.
# 3. The engine's Python child is gone afterwards.
#
# It never runs against ~/photos, and it points every other folder the engine
# writes to at fresh temporary folders. Only local temporary library clones
# with no symbolic/hard links or dataless files are accepted. No live defaults,
# migrations, display restoration or notification setup is used.
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
    --offscreen) shift ;;  # explicit spelling; all runs are offscreen
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
library=${library:-${PHOTOS_ROOT:-}}
[[ -n "$library" ]] || { echo "smoke: --library is required, and it must be a scratch clone." >&2; exit 2; }
library=$(cd "$library" && pwd -P)
case "$library" in
  /private/tmp/*) ;;
  *) echo "smoke: use a local scratch library clone under /private/tmp." >&2; exit 2 ;;
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

# Discard inherited engine overrides; this must measure the supplied bundle
# and fresh scratch state, never a checkout/extension or a live support folder.
for variable in ${!PIPELINE_@}; do unset "$variable"; done
unset PYTHONHOME PYTHONPATH
scratch=$(mktemp -d /private/tmp/first-edit-smoke.XXXXXX)
export PIPELINE_SMOKE_ROOT="$scratch"
export PHOTOS_ROOT="$library"
export PIPELINE_SUPPORT="$scratch/support"
export PIPELINE_ICLOUD="$scratch/icloud"
export PIPELINE_LEARNED="$scratch/learned"
export PIPELINE_EXT="$scratch/no-extension"
export PIPELINE_SITE="$scratch/no-site"
export CFFIXED_USER_HOME="$scratch/home"
export XDG_CACHE_HOME="$scratch/cache"
export TMPDIR="$scratch/tmp/"
export HF_HOME="$scratch/cache/huggingface"
export TORCH_HOME="$scratch/cache/torch"
export MPLCONFIGDIR="$scratch/cache/matplotlib"
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
export PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1
mkdir -p "$PIPELINE_SUPPORT" "$PIPELINE_ICLOUD" "$PIPELINE_LEARNED" "$PIPELINE_EXT" \
  "$CFFIXED_USER_HOME" "$XDG_CACHE_HOME" "$TMPDIR"
echo "== isolated state: $scratch"

if [[ -z "$binary" ]]; then
  echo "== build"
  (cd "$app" && swift build -c debug --product FirstEdit 2>&1 | tail -1)
  binary="$app/.build/debug/FirstEdit"
fi
[[ -x "$binary" ]] || { echo "smoke: no app at $binary" >&2; exit 1; }

# An older executable treats unknown flags as normal GUI startup. Refuse it
# without launching it, then also require the new process's isolation receipt.
LC_ALL=C grep -aFq 'SMOKE_OFFSCREEN_V1' "$binary" || {
  echo "smoke: this binary has no offscreen entry point; rebuild it first." >&2; exit 2;
}

fail() { echo "SMOKE FAILED: $*"; [[ -f "$PIPELINE_SUPPORT/studio.log" ]] && tail -12 "$PIPELINE_SUPPORT/studio.log"; exit 1; }

echo "== headless check against $library${deep:+ (deep)}"
check=$("$binary" --check --smoke-offscreen $deep 2>/dev/null) || { echo "$check"; fail "--check $deep exited non-zero"; }
echo "$check" | sed 's/^/   /'
echo "$check" | grep -qx 'SMOKE_OFFSCREEN_V1 isolated' || fail "--check did not confirm isolation"
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
[[ "$cpid" =~ ^[1-9][0-9]*$ ]] || fail "--check did not report its real engine PID"
if kill -0 "$cpid" 2>/dev/null; then fail "the --check engine (pid $cpid) is still running"; fi

echo "== the real app shell, offscreen"
out=$(mktemp -t smoke)
"$binary" --smoke-offscreen >"$out" 2>/dev/null &
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

grep -qx 'SMOKE_OFFSCREEN_V1 isolated' "$out" || fail "the app did not confirm isolation"
grep -qx 'SMOKE_OFFSCREEN_V1 verified' "$out" || fail "the app did not complete the offscreen checks"
grep -q '^FAIL ' "$out" && fail "the app reported a failed check"
grep -q '^ENGINE running on http://127.0.0.1:' "$out" || fail "the engine never reached running"
epid=$(sed -n 's/^ENGINE running on .* pid \([0-9]*\)$/\1/p' "$out")
[[ "$epid" =~ ^[1-9][0-9]*$ ]] || fail "the app did not report its real engine PID"
drawn=$(sed -n 's/^SIDEBAR \([0-9]*\) rows drawn$/\1/p' "$out")
[[ "$drawn" =~ ^[0-9]+$ ]] && (( drawn > 0 && drawn >= expect )) || fail "sidebar rows were not drawn"
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
  if kill -0 "$epid" 2>/dev/null; then fail "the engine (pid $epid) outlived the app"; fi
  echo "   engine pid $epid: gone"
fi
if pgrep -P "$apppid" >/dev/null 2>&1; then fail "the app left children behind"; fi
echo "   app pid $apppid: gone, no children"

echo "SMOKE OK: $expect shoots, engine started and stopped cleanly"
