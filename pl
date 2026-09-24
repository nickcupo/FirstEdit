#!/bin/zsh
# The pipeline's one entry point. ./pl <command> [args]
#   ingest   /Volumes/CARD 2026-10-04-name [--verify in-flight|end|none]   copy a card into ~/photos/shoots/<name>/raw
#   cull     <raw> [--top N --copy --presets --dop]   focus, faces at full resolution, quality (presets optional, and better run after you choose keepers)
#   presets  <raw> [--install --dop --xmp --picks-only]   one PhotoLab preset per scene, from what the scene is
#   gather   <shoot>                          one folder of YOUR keepers and their sidecars, to open in PhotoLab
#   spread   <shoot> --burst N                 put your edit from one frame onto the whole burst
#   reel     <shoot> [--list --burst N --all]   cut a burst into a 1080x1920 clip
#   instagram <shoot> [frames | --all] [--plan]   Instagram-sized copies: 3:4 portraits, landscapes
#                                              whole. --plan works every cut out and makes nothing
#   studio                                    the whole thing in one local page
#   reclaim  report|reclaim <shoot>|verify <shoot>   what every shoot costs, and the cache it is safe to delete
#   migrate  [<shoot>] [--apply|--undo]        move your decisions out of the cache folder (dry run by default)
#   archive  report|status|push|drop|pull|expire <shoot>   a shoot's RAWs in iCloud Drive: push copies any shoot's; drop waits for Finish
#   check [truth.json]                        the face judge against frames we settled by eye
#   bench                                     the cull against every shoot you have already chosen from
#   evaluate                                  every dataset with an answer key: recall, vetoes, ranking, blink, animals, faces
#   learn                                     turn the reasons you gave for drops into a candidate, checked against every photo you kept before it is used
#   learned  [run | import <file> | --check | --back <learner> | --stop <learner>]   what the cull has learned, and the check it had to pass
#   learned  dataset | vectors [<shoot>] | --forget <shoot> | --teach-again <shoot>   what it was taught, measured once and kept
#   taste                                     the starting edit, measured from the edits you have made
#   selftest                                  run the whole machine on six frames and check what came out
#   fetch-clip                                get CLIP ViT-L/14 into the cache (setup does this)
#   setup                                     venv and models, once
# Anything else is handed to an extension's own pl, if one is installed (see README, Extensions).
set -e
HERE="${0:A:h}"
PY="$HERE/.venv/bin/python"
cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  setup)    exec "$HERE/setup.sh" "$@" ;;
  ingest)   exec "$PY" "$HERE/pipeline/ingest.py" "$@" ;;
  cull)     exec "$PY" "$HERE/pipeline/cull.py" "$@" ;;
  presets)  exec "$PY" "$HERE/pipeline/presets.py" "$@" ;;
  gather)   exec "$PY" "$HERE/pipeline/gather.py" "$@" ;;
  spread|reel)
    # Both live in the private repo and are symlinked in. A public build leaves
    # them out, so say what is missing rather than dying on a path.
    f="$HERE/pipeline/$cmd.py"
    [ -f "$f" ] || { echo "$cmd is not part of this build."; exit 1; }
    exec "$PY" "$f" "$@" ;;
  instagram) exec "$PY" "$HERE/pipeline/instagram.py" "$@" ;;
  studio)   exec "$PY" "$HERE/pipeline/studio.py" "$@" ;;
  reclaim)  exec "$PY" "$HERE/pipeline/reclaim.py" "$@" ;;
  archive)  exec "$PY" "$HERE/pipeline/archive.py" "$@" ;;
  migrate)  exec "$PY" "$HERE/pipeline/migrate.py" "$@" ;;
  check)    exec "$PY" "$HERE/pipeline/check_faces.py" "$@" ;;
  bench)    exec "$PY" "$HERE/pipeline/bench.py" "$@" ;;
  evaluate) exec "$PY" "$HERE/pipeline/evaluate.py" "$@" ;;
  learn)    exec "$PY" "$HERE/pipeline/flaws.py" "$@" ;;
  learned)  exec "$PY" "$HERE/pipeline/learned.py" "$@" ;;
  taste)    exec "$PY" "$HERE/pipeline/taste.py" "$@" ;;
  selftest) exec "$PY" "$HERE/pipeline/selftest.py" "$@" ;;
  fetch-clip) exec "$PY" "$HERE/pipeline/fetch_clip.py" "$@" ;;
  *)
    # Where common.py looks, in the same order: PIPELINE_EXT, then the app's
    # support folder (which is where an extension installed for the app lives,
    # and which this skipped), then beside this repo. The support folder the
    # way common.support_dir() finds it: PIPELINE_SUPPORT, else First Edit's
    # folder if it is there, else Photo Pipeline's if the app has not renamed
    # it yet, else First Edit's.
    # Testing this search itself: set PIPELINE_EXT=/nonexistent first, or it
    # finds, and runs, whatever extension is really installed on the machine.
    if [ -n "${PIPELINE_EXT:-}" ]; then
      EXT="$PIPELINE_EXT"
    else
      if [ -n "${PIPELINE_SUPPORT:-}" ]; then
        SUP="${PIPELINE_SUPPORT/#\~/$HOME}"
      else
        SUP="$HOME/Library/Application Support/First Edit"
        [ -d "$SUP" ] || [ ! -d "$HOME/Library/Application Support/Photo Pipeline" ] \
          || SUP="$HOME/Library/Application Support/Photo Pipeline"
      fi
      EXT="$HERE/../photo-pipeline-extension"
      for c in "$SUP/extension" "$HERE/../photo-pipeline-extension"; do
        [ -x "$c/pl" ] && { EXT="$c"; break; }
      done
    fi
    # The extension's commands import this engine's modules from where
    # PIPELINE_PUBLIC says, as they do when the studio starts them; without
    # it they guessed at a checkout beside the extension, which need not be
    # this one.
    if [ -n "$cmd" ] && [ -x "$EXT/pl" ]; then
      PIPELINE_PY="$PY" PIPELINE_PUBLIC="$HERE/pipeline" exec "$EXT/pl" "$cmd" "$@"
    fi
    # Every comment line of the header, however many there are: the range was
    # counted by hand and stopped one line short of its own last sentence.
    awk 'NR > 1 && /^#/ {print} NR > 1 && !/^#/ {exit}' "$0"
    [ -x "$EXT/pl" ] && sed -n '4,5p' "$EXT/pl"; exit 1 ;;
esac
