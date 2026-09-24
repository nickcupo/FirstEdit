#!/usr/bin/env bash
# Save what the real engine actually answers, route by route, into
# app/Tests/PipelineKitTests/Fixtures/.
#
# The decoding tests run against these bytes and nothing else. A model that
# compiles against the design document but not against the server is the one
# failure that stops every other crew, so the fixtures are captured from a
# running studio rather than written by hand.
#
# It never touches a real library: it wants a scratch clone and says so.
#
#   tools/capture-fixtures.sh --library /path/to/scratch/lib
#
# --library must hold a "shoots" folder. PIPELINE_SUPPORT, PIPELINE_ICLOUD and
# PIPELINE_SITE are pointed at scratch folders beside it unless they are
# already set, and no extension is loaded.
#
# The Instagram captures work cuts out with the real subject detector, from
# the models the engine finds (PIPELINE_MODELS, else the checkout's models/).
# A checkout without them still captures every shape, with each subject in
# the middle of its frame.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
app=$(dirname "$here")
repo=$(dirname "$app")
out="$app/Tests/PipelineKitTests/Fixtures"

library=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --library) library="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$library" ]]; then
  echo "capture-fixtures: --library is required, and it must be a scratch clone." >&2
  exit 2
fi
library=$(cd "$library" && pwd)
case "$library" in
  "$HOME"/photos|"$HOME"/photos/*)
    echo "capture-fixtures: refusing to run against $HOME/photos. Clone it first." >&2
    exit 2 ;;
esac
[[ -d "$library/shoots" ]] || { echo "capture-fixtures: no shoots folder in $library" >&2; exit 2; }

python=${PIPELINE_PYTHON:-$repo/.venv/bin/python}
[[ -x "$python" ]] || { echo "capture-fixtures: no interpreter at $python" >&2; exit 2; }

scratch=${PIPELINE_SCRATCH:-$(dirname "$library")}
export PHOTOS_ROOT="$library"
export PIPELINE_SUPPORT=${PIPELINE_SUPPORT:-$scratch/support}
export PIPELINE_ICLOUD=${PIPELINE_ICLOUD:-$scratch/icloud}
export PIPELINE_SITE=${PIPELINE_SITE:-$scratch/no-site}
# A folder with no studio_ext.py in it, so the engine finds no extension.
# Unsetting PIPELINE_EXT is not enough: the search then falls back to the
# app's own support folder, and a machine with the private extension installed
# captured its vocabulary straight into these files.
export PIPELINE_EXT=${PIPELINE_EXT:-$scratch/no-extension}
mkdir -p "$PIPELINE_SUPPORT" "$PIPELINE_ICLOUD" "$PIPELINE_SITE" "$PIPELINE_EXT" "$out"
if [[ -e "$PIPELINE_EXT/studio_ext.py" ]]; then
  echo "capture-fixtures: PIPELINE_EXT points at a real extension; fixtures must be captured without one." >&2
  exit 2
fi
export PYTHONUNBUFFERED=1
# The app sends a per-launch key on every request. Today's server ignores an
# unknown header; the crew landing X-Studio-Key will require it. Sending it
# here means the fixtures are captured the same way either version is talked to.
export PIPELINE_STUDIO_KEY=${PIPELINE_STUDIO_KEY:-$(/usr/bin/python3 -c 'import base64,os;print(base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("="))')}

log=$(mktemp -t capture-fixtures)
"$python" "$repo/pipeline/studio.py" --app --no-open --port 0 >"$log" 2>&1 &
server=$!
cleanup() {
  if kill -0 "$server" 2>/dev/null; then
    kill "$server" 2>/dev/null || true
    for _ in $(seq 30); do kill -0 "$server" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$server" 2>/dev/null || true
  fi
  wait "$server" 2>/dev/null || true
}
trap cleanup EXIT

port=""
for _ in $(seq 200); do
  port=$(sed -n 's/^PORT \([0-9][0-9]*\)$/\1/p' "$log" | head -1)
  [[ -n "$port" ]] && break
  kill -0 "$server" 2>/dev/null || { echo "capture-fixtures: the engine stopped:" >&2; cat "$log" >&2; exit 1; }
  sleep 0.1
done
[[ -n "$port" ]] || { echo "capture-fixtures: no PORT line in 20 s:" >&2; cat "$log" >&2; exit 1; }
base="http://127.0.0.1:$port"
echo "engine on $port, library $library"

saved=0
get() { # get <fixture name> <path+query>
  local name=$1 path=$2 code
  code=$(curl -sS -o "$out/$name.json" -w '%{http_code}' \
         -H "X-Studio-Key: $PIPELINE_STUDIO_KEY" "$base$path" || echo 000)
  if [[ -s "$out/$name.json" ]]; then
    if ! /usr/bin/python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$out/$name.json" 2>/dev/null; then
      echo "  $name: $code, not JSON — removed (the engine has no such route yet)" >&2
      rm -f "$out/$name.json"
      return 0
    fi
    scrub "$out/$name.json"
    echo "  $name: $code  $(wc -c <"$out/$name.json" | tr -d ' ') bytes"
    saved=$((saved + 1))
  else
    echo "  $name: $code, empty — removed" >&2
    rm -f "$out/$name.json"
  fi
}

post() { # post <fixture name> <path> <json body>
  local name=$1 path=$2 body=$3 code
  code=$(curl -sS -o "$out/$name.json" -w '%{http_code}' -X POST \
         -H "X-Studio-Key: $PIPELINE_STUDIO_KEY" -H 'content-type: application/json' \
         -d "$body" "$base$path" || echo 000)
  if [[ -s "$out/$name.json" ]]; then
    scrub "$out/$name.json"
    echo "  $name: POST $code  $(wc -c <"$out/$name.json" | tr -d ' ') bytes"
    saved=$((saved + 1))
  else
    echo "  $name: POST $code, empty — removed" >&2
    rm -f "$out/$name.json"
  fi
}

# Three things are changed after capture, and only these three. Shapes, types,
# field names and the engine's own sentences are untouched.
#
# 1. The scratch folder this ran against is written back as a stable path, so
#    no fixture carries one machine's home folder into a public repo.
# 2. A word from the private extension's vocabulary is replaced by "redacted".
#    A shoot's `kind` is extension-supplied and DESIGN.md §2.16 says such a
#    word is never in a test fixture. It is still a String and still decodes.
# 3. The names filed in a shoot are renamed; see the scrubber below.
scrub() {
  /usr/bin/python3 - "$1" "$library" "$PIPELINE_SUPPORT" "$PIPELINE_ICLOUD" "$private_words" "$repo" "$HOME" <<'PY'
import re, sys
path, lib, support, icloud, words, repo, home = sys.argv[1:8]
name = path.rsplit("/", 1)[-1]
text = open(path, encoding="utf-8").read()
# Longest first, so a folder inside another is not half-rewritten. The home
# folder is last and is the backstop: the engine looks in iCloud for exports
# and reports what it found there, and a home folder is not something a public
# repository holds.
for real, stable in sorted(((lib, "/scratch/photos"), (support, "/scratch/support"),
                            (icloud, "/scratch/icloud"), (repo, "/checkout"),
                            (home, "/home")), key=lambda p: -len(p[0])):
    text = text.replace(real, stable)
text, n = re.subn(rf"\b(?:{words})\b", "redacted", text, flags=re.I)
if n:
    print(f"      redacted {n} private word(s) in {name}")
# 3. The names filed in a shoot (the reel lister's `tags`) are his venues and
#    the people he shot for, which is not a public repository's business
#    either. They become "name 1", "name 2"; the counts beside them stay.
if '"tags"' in text:
    import json
    try:
        obj = json.loads(text)
    except ValueError:
        obj = None
    if isinstance(obj, dict) and isinstance(obj.get("tags"), list) and obj["tags"]:
        for i, t in enumerate(obj["tags"]):
            if isinstance(t, dict) and "name" in t:
                t["name"] = f"name {i + 1}"
        text = json.dumps(obj)
        print(f"      renamed {len(obj['tags'])} filed name(s) in {name}")
if "/Users/" in text:
    line = next(l for l in text.splitlines() if "/Users/" in l)
    raise SystemExit(f"capture-fixtures: {name} still holds a home folder: {line[:120]}")
open(path, "w", encoding="utf-8").write(text)
PY
}
private_words=$("$here/vocabulary-scan.sh" --words)

# Which shoot is which shape, asked of the server rather than assumed, so a
# different clone still captures a culled one and an un-culled one.
curl -sS -H "X-Studio-Key: $PIPELINE_STUDIO_KEY" "$base/api/shoots" >"$out/shoots.json"
pick=$(mktemp -t capture-pick)
cat >"$pick" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
rows = [r for r in d["shoots"] if not r.get("broken")]
# The smallest culled shoot, because these files are committed and the rows of
# a 1,157-frame shoot are a megabyte of repository for no extra shape.
done = sorted((r for r in rows if r.get("culled")), key=lambda r: r.get("frames", 0))
plain = next((r["name"] for r in rows if not r.get("culled")), "")
print(done[0]["name"] if done else "", plain)
PY
read -r culled uncelled < <(/usr/bin/python3 "$pick" "$out/shoots.json")
rm -f "$pick"
scrub "$out/shoots.json"
echo "  shoots.json: culled=$culled un-culled=${uncelled:-none}"
saved=$((saved + 1))

get cards           "/api/cards"
get update          "/api/update"
get job             "/api/job"
get storage-library "/api/storage/library"
get queue-empty     "/api/queue"           # the list with nothing on it
get learned         "/api/learned"           # not in every engine yet; captured when it is

if [[ -n "$culled" ]]; then
  e=$(/usr/bin/python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$culled")
  get shoot              "/api/shoot?name=$e"
  get shoot-full         "/api/shoot?name=$e&full=1"
  get shoot-light        "/api/shoot?name=$e&light=1"
  get storage            "/api/storage?name=$e"
  get storage-frames     "/api/storage/frames?name=$e"
  get reel-options       "/api/reel/options?name=$e"
  get reel-watch         "/api/reel/watch?name=$e&burst=1"
  # The same answer asked about one burst, which is the only way `frames` is
  # ever filled: the Reels step's frame grid is drawn from it. The burst is the
  # best one the lister offers as a cut that is part exported and part not, so
  # the grid's two kinds of tile are both in it; failing that, its first.
  rb=$(/usr/bin/python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));c=d.get("cuts") or d.get("sequences") or [];m=[x for x in c if 0<x.get("exported",0)<x.get("frames",0)];print((m or c)[0]["burst"] if c else "")' "$out/reel-options.json" 2>/dev/null || true)
  if [[ -n "$rb" ]]; then
    get reel-options-burst "/api/reel/options?name=$e&burst=$rb"
    # Its own name: under `reel-watch` it overwrote burst 1's answer above.
    get reel-watch-burst   "/api/reel/watch?name=$e&burst=$rb"
  fi
  # The refusal a plan gives when nothing has been drawn yet. It is a real
  # shape and the app has to render it, so it is captured before any plan is.
  get storage-plan-undrawn "/api/storage/plan?name=$e&what=push"
  # Then a real one. The POST runs the command's own dry run — it writes
  # nothing but the plan log — and the GET reads back what it printed.
  for what in reclaim drop; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
           -H "X-Studio-Key: $PIPELINE_STUDIO_KEY" -H 'content-type: application/json' \
           -d "{\"name\":\"$culled\",\"what\":\"$what\"}" "$base/api/storage/plan" || echo 000)
    for _ in $(seq 600); do
      running=$(curl -sS -H "X-Studio-Key: $PIPELINE_STUDIO_KEY" "$base/api/job" \
                | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["running"])')
      [[ "$running" == "False" ]] && break
      sleep 0.5
    done
    get "storage-plan-$what" "/api/storage/plan?name=$e&what=$what"
  done
  # And a job that has finished, which is a different shape from an idle one.
  get job-finished "/api/job"

  # The list of work, filled and held, which is the shape the Activity window
  # draws. Held first, so nothing is started on the clone by capturing it, and
  # cleared afterwards so the clone is left as it was found.
  curl -sS -o /dev/null -X POST -H "X-Studio-Key: $PIPELINE_STUDIO_KEY" \
       -H 'content-type: application/json' -d '{"held":true}' "$base/api/queue/hold" || true
  for kind in cull presets gather; do
    curl -sS -o /dev/null -X POST -H "X-Studio-Key: $PIPELINE_STUDIO_KEY" \
         -H 'content-type: application/json' -d "{\"kind\":\"$kind\",\"name\":\"$culled\"}" \
         "$base/api/queue" || true
  done
  get queue "/api/queue"
  curl -sS -o /dev/null -X POST -H "X-Studio-Key: $PIPELINE_STUDIO_KEY" \
       -H 'content-type: application/json' -d '{}' "$base/api/queue/clear" || true
  curl -sS -o /dev/null -X POST -H "X-Studio-Key: $PIPELINE_STUDIO_KEY" \
       -H 'content-type: application/json' -d '{"held":false}' "$base/api/queue/hold" || true

  # The write side. These go to the clone and nowhere else: one verdict of his
  # on the first frame, one reason, one burst recorded as been through. The
  # point is the answers — RatingResult, ReviewResult, KindResult and OK are
  # models six crews compile against, and a shoot carrying a verdict of his is
  # the only way `override` (an Int beside a `rating` that is a String) reaches
  # a fixture at all.
  first=$(/usr/bin/python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["rows"][0]["file"] if d["rows"] else "")' "$out/shoot.json")
  bkey=$(/usr/bin/python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));r=(d["rows"] or [{}])[0];print("%s/%s" % (r.get("scene",""), r.get("burst","")))' "$out/shoot.json")
  if [[ -n "$first" ]]; then
    post rating "/api/rating" "{\"name\":\"$culled\",\"file\":\"$first\",\"rating\":5}"
    post label  "/api/label"  "{\"name\":\"$culled\",\"file\":\"$first\",\"label\":\"blur\"}"
    post review "/api/review" "{\"name\":\"$culled\",\"at\":\"$bkey\",\"seen\":[\"$bkey\"]}"
    post kind   "/api/kind"   "{\"name\":\"$culled\"}"
    get shoot-decided "/api/shoot?name=$e"
    # And taken back, through the same routes, so the clone is as it was and
    # the next capture's `shoot.json` is again a shoot nobody has marked.
    for body in "{\"name\":\"$culled\",\"file\":\"$first\",\"rating\":null}"; do
      curl -sS -o /dev/null -X POST -H "X-Studio-Key: $PIPELINE_STUDIO_KEY" \
           -H 'content-type: application/json' -d "$body" "$base/api/rating"
    done
    curl -sS -o /dev/null -X POST -H "X-Studio-Key: $PIPELINE_STUDIO_KEY" -H 'content-type: application/json' \
         -d "{\"name\":\"$culled\",\"file\":\"$first\",\"label\":\"\"}" "$base/api/label"
    curl -sS -o /dev/null -X POST -H "X-Studio-Key: $PIPELINE_STUDIO_KEY" -H 'content-type: application/json' \
         -d "{\"name\":\"$culled\",\"at\":\"\",\"unseen\":[\"$bkey\"]}" "$base/api/review"
  fi
fi
if [[ -n "$uncelled" ]]; then
  e=$(/usr/bin/python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$uncelled")
  get shoot-not-culled "/api/shoot?name=$e"
  get storage-not-culled "/api/storage?name=$e"
fi

# The refusal shape, which is a route's other half: every model has to decode
# {"error": "..."} without losing the engine's sentence.
get error-no-such-shoot "/api/shoot?name=no-such-shoot-at-all"
get error-bad-plan      "/api/storage/plan?name=no-such-shoot-at-all&what=push"

# The Instagram step, captured from a shoot of its own built beside the clone
# rather than in it, so the clone is left as it was found and these files stay
# small: the whole culled shoot is hundreds of frames, and the wall answers
# with every one of them. Seventeen of the culled shoot's exports are cloned
# in (cp -c: no bytes are copied), the portraits and landscapes first in stem
# order, under the culled shoot's own name, so the stems are real ones and the
# app's scenes find these very photographs in --library. The shoot's own
# shoot.json is not copied: its kind is an extension's word.
#
# The cuts are worked out by the real engine, subject detector and all, so
# the numbers are the ones a person would get. With no models where the
# engine looks (PIPELINE_MODELS, else the checkout's models/), every subject
# is the middle of its frame and the shapes are still right.
#
# What is staged, in order, and what each capture shows:
#   instagram-empty          the shoot before anything is exported into it
#   instagram-plan-waiting   a plan asked for while copies of his are being made
#   instagram-plan           a plan started, ten frames worked out and six not
#   instagram-planning       the wall while that plan runs
#   job-instagram-plan       /api/job while it runs
#   instagram                every state a tile has: made and current, made at
#                            the other shape, his window, cut by him, exported
#                            again (made and not), not worked out yet
#   instagram-crop           his window saved on a made copy, made again
#   instagram-shape          the whole wall at 4:5
if [[ -n "$culled" ]]; then
  ig="$scratch/fixtures-instagram.$$"
  rm -rf "$ig"
  mkdir -p "$ig/shoots"
  ig=$(cd "$ig" && pwd)
  (
    export PHOTOS_ROOT="$ig"
    "$python" "$repo/pipeline/studio.py" --app --no-open --port 0 >"$ig/log" 2>&1 &
    third=$!
    trap 'kill "$third" 2>/dev/null || true; wait "$third" 2>/dev/null || true' EXIT
    p=""
    for _ in $(seq 200); do
      p=$(sed -n 's/^PORT \([0-9][0-9]*\)$/\1/p' "$ig/log" | head -1)
      [[ -n "$p" ]] && break
      sleep 0.1
    done
    if [[ -z "$p" ]]; then
      echo "  instagram: the engine for its shoot did not start" >&2
      exit 0
    fi
    "$python" - "http://127.0.0.1:$p" "$out" "$library/shoots/$culled" "$ig" "$repo" <<'PY' ||
import json, os, subprocess, sys, time, urllib.error, urllib.request
from pathlib import Path

base, out, src_shoot, lib, repo = sys.argv[1:6]
key = os.environ["PIPELINE_STUDIO_KEY"]
name = Path(src_shoot).name
shoot = Path(lib) / "shoots" / name
sys.path.insert(0, f"{repo}/pipeline")
import exports  # noqa: E402
from PIL import Image  # noqa: E402


def call(method, path, body=None):
    req = urllib.request.Request(base + path, method=method,
                                 data=None if body is None else json.dumps(body).encode(),
                                 headers={"X-Studio-Key": key, "content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            raw, code = r.read(), r.status
    except urllib.error.HTTPError as e:
        raw, code = e.read(), e.code
    return code, json.loads(raw), raw


def save(fixture, got):
    code, obj, raw = got
    Path(out, f"{fixture}.json").write_bytes(raw)
    with open(Path(lib, "saved"), "a") as fh:            # for the scrub, which is the shell's
        fh.write(f"{fixture}.json\n")
    print(f"  {fixture}: {code}  {len(raw)} bytes", flush=True)
    return obj


def idle(wait=900):
    for _ in range(wait * 4):
        if not call("GET", "/api/job")[1]["running"]:
            return
        time.sleep(0.25)
    raise SystemExit("  instagram: a job did not end in time")


def upright(p):
    with Image.open(p) as im:
        w, h = im.size
        if (im.getexif() or {}).get(274) in (5, 6, 7, 8):
            w, h = h, w
    return w, h


# Seventeen of its exports: five portraits and twelve landscapes, the first of
# each in stem order. The last landscape arrives late and is never worked out.
found = dict(sorted(exports.files(Path(src_shoot)).items()))
shapes = {s: upright(p) for s, p in found.items()}
tall = [s for s, (w, h) in shapes.items() if h > w][:5]
wide = [s for s, (w, h) in shapes.items() if w > h][:12]
if len(tall) < 2 or len(wide) < 6:
    raise SystemExit(f"  instagram: {name} has too few exports of each shape to show the step")
first, second, late = tall[:3] + wide[:7], tall[3:] + wide[7:11], wide[11:]
(shoot / "raw").mkdir(parents=True)
(shoot / "cull").mkdir()
rows = {Path(r).stem: r for r in exports.frames(Path(src_shoot)).values()}
(shoot / "cull" / "cull.csv").write_text(
    "file\n" + "".join(f"{Path(rows[s]).name}\n" for s in sorted(first + second + late)))


def bring(stems):
    (shoot / "export").mkdir(exist_ok=True)
    for s in stems:
        subprocess.run(["cp", "-c", str(found[s]), str(shoot / "export" / found[s].name)], check=True)


q = f"?name={name}"
save("instagram-empty", call("GET", "/api/instagram" + q))
bring(first)
call("POST", "/api/instagram/plan", {"name": name})
idle()
bring(second)

# His job in the slot: two copies being made, and a plan asked for meanwhile.
made = [tall[0], wide[0]]
call("POST", "/api/instagram/make", {"name": name, "stems": made})
got = call("POST", "/api/instagram/plan", {"name": name})
if got[1].get("waiting_for"):
    save("instagram-plan-waiting", got)
else:
    print("  instagram-plan-waiting: the copies were made before the plan was asked for; "
          "the hand-written one stays", file=sys.stderr)
idle()

# The plan itself, and the wall and the bar while it runs: caught once the
# first of the six has been worked out, so the wall is part filled in.
got = call("POST", "/api/instagram/plan", {"name": name})
if not got[1].get("planning"):
    print("  instagram-plan: nothing was left to work out, so no plan was started", file=sys.stderr)
else:
    save("instagram-plan", got)
    for _ in range(1200):
        st = call("GET", "/api/job")[1]
        if not st["running"] or st["fraction"] > 0:
            break
        time.sleep(0.1)
    if st["running"]:
        save("instagram-planning", call("GET", "/api/instagram" + q))
        save("job-instagram-plan", call("GET", "/api/job"))
    else:
        print("  instagram-planning: the plan ended before it could be seen running", file=sys.stderr)
idle()

# A copy made at 4:5 and the shape put back, so it is made at the other shape.
call("POST", "/api/instagram/shape", {"name": name, "ratio": "4:5"})
call("POST", "/api/instagram/make", {"name": name, "stems": [tall[1]]})
idle()
call("POST", "/api/instagram/shape", {"name": name, "ratio": "3:4"})
bring(late)
call("POST", "/api/instagram/crop", {"name": name, "stem": tall[2], "mode": "crop",
                                     "manual": {"cx": 0.46, "cy": 0.38, "scale": 0.82}})
call("POST", "/api/instagram/crop", {"name": name, "stem": wide[1], "mode": "crop"})
for s in (wide[0], wide[2]):                    # exported again: one made, one not
    p = shoot / "export" / found[s].name
    t = p.stat().st_mtime + 60
    os.utime(p, (t, t))
save("instagram", call("GET", "/api/instagram" + q))
save("instagram-crop", call("POST", "/api/instagram/crop", {"name": name, "stem": tall[0], "mode": "crop",
                                                            "manual": {"cx": 0.5, "cy": 0.42, "scale": 0.9}}))
save("instagram-shape", call("POST", "/api/instagram/shape", {"name": name, "ratio": "4:5"}))
PY
      echo "  instagram: the captures stopped part way; the ones listed above were saved" >&2
  )
  while read -r f; do
    library=$ig scrub "$out/$f"
    saved=$((saved + 1))
  done < <(cat "$ig/saved" 2>/dev/null || true)
  rm -rf "$ig"
fi

# A library holding one shoot whose decisions file will not parse, captured
# from its own engine so the seven-shoot clone stays seven shoots.
broken=$(mktemp -d -t fixtures-broken)
mkdir -p "$broken/shoots/a-broken-shoot/cull" "$broken/shoots/a-broken-shoot/raw"
printf '{ this is not json' >"$broken/shoots/a-broken-shoot/cull/organize.json"
printf 'file,stem,rating\n' >"$broken/shoots/a-broken-shoot/cull/cull.csv"
printf '{"not":' >"$broken/shoots/a-broken-shoot/shoot.json"
(
  export PHOTOS_ROOT="$broken"
  "$python" "$repo/pipeline/studio.py" --app --no-open --port 0 >"$broken/log" 2>&1 &
  second=$!
  for _ in $(seq 200); do
    p=$(sed -n 's/^PORT \([0-9][0-9]*\)$/\1/p' "$broken/log" | head -1)
    [[ -n "$p" ]] && break
    sleep 0.1
  done
  if [[ -n "${p:-}" ]]; then
    curl -sS -H "X-Studio-Key: $PIPELINE_STUDIO_KEY" "http://127.0.0.1:$p/api/shoots" >"$out/shoots-broken.json"
    library=$broken scrub "$out/shoots-broken.json"
    echo "  shoots-broken: $(wc -c <"$out/shoots-broken.json" | tr -d ' ') bytes"
  else
    echo "  shoots-broken: the second engine did not start" >&2
  fi
  kill "$second" 2>/dev/null || true
  wait "$second" 2>/dev/null || true
)
rm -rf "$broken"

echo "$saved fixtures in $out"
