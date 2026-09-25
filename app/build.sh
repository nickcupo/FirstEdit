#!/bin/zsh
# Build "FirstEdit.app" and its DMG: a relocatable CPython with the
# requirements installed, the pipeline, the five small models, exiftool, and
# the Swift app built from the package in app/. CLIP (1.7 GB) is fetched on
# first launch, not bundled, so the DMG stays under GitHub's 2 GB release limit.
#
#   app/build.sh                       the public build, ad-hoc signed: runs here, Gatekeeper warns elsewhere
#   IDENTITY="Developer ID Application: Your Name (TEAMID)" app/build.sh
#   IDENTITY=... NOTARY_PROFILE=first-edit app/build.sh         also notarize and staple: the DMG for the public releases page
#   IDENTITY=... NOTARY_KEY=~/.appstoreconnect/private_keys/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER=<uuid> app/build.sh
#                                                                the same with an App Store Connect API key instead of a keychain profile
#   PRIVATE_BUILD=1 app/build.sh                                 your own copy: carries the symlinked private modules (and
#                                                                PIPELINE_TASTE_SEED as pipeline/taste.json, if set); named -private, never notarized
#   SMOKE_LIBRARY=/path/to/scratch/library app/build.sh          run the smoke test against a real library instead of an empty one
#   OPENCV_WHEELHOUSE=/path/to/wheels app/build.sh               take the two OpenCV wheels from there instead of the URL the
#                                                                lock names (app/tools/build-opencv.sh just wrote them, or the
#                                                                release asset is not published yet); the SHA-256 still has to match
#   STAGE=check app/build.sh                                     the gates only, on this tree and on the app in build/ if there is one;
#                                                                builds, signs and uploads nothing
#   STAGE=lock app/build.sh                                      write app/requirements.lock again, after requirements.txt changed
#   STAGE=assemble app/build.sh                                  build the app and run the gates, then stop before signing
#   STAGE=sign IDENTITY=... app/build.sh                         start again at the signing step (the app is already assembled)
#   STAGE=dmg app/build.sh                                       only the DMG (and notarization), from the signed app in build/,
#                                                                which must be the very app a gated run signed
#
# RELEASING.md is the whole procedure for a release, in order.
#
# NOTARY_PROFILE is a keychain profile from
#   xcrun notarytool store-credentials first-edit --apple-id you@example.com --team-id TEAMID
# (it asks for an app-specific password from appleid.apple.com). The label is
# only a name for the keychain item: one stored earlier under another label
# keeps working when NOTARY_PROFILE names that label.
# Needs Xcode (swift, actool, xcstringstool, codesign, notarytool) and network
# for the first build.
set -e -o pipefail
cd "$(dirname "$0")/.."
# The version is the tag: `git describe --tags`, so the checkout has to have
# its tags. A CI checkout does not by default (actions/checkout fetches one
# commit and no tags; it needs fetch-depth: 0), and then this falls back to
# 0.1.0-<sha>, which update.py compares against every installed copy. A
# notarized build refuses a version that is not a plain tag, below.
VERSION_GIVEN="${VERSION:-}"
# (|| true: with pipefail, git's own failure outside a checkout - an unpacked
# tarball, say - ended the script here, silently, before its first line of output)
VERSION="${VERSION:-$(git describe --tags 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0-$(git rev-parse --short HEAD 2>/dev/null || echo dev)}"
BUILD_NO="$(date +%Y%m%d%H%M)"
PYVER="3.12.14+20260901"
PYURL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYVER#*+}/cpython-${PYVER}-aarch64-apple-darwin-install_only.tar.gz"
EXIFTOOL_VER="13.36"
APP="build/FirstEdit.app"
C="$APP/Contents"
R="$C/Resources"
EXE="$C/MacOS/FirstEdit"
MARKER="build/gate.json"
BPY=build/python/bin/python3
# Everything the bundle is described by lives beside the strings and the icon
# it ships, so one folder is the app's resources and nothing else is.
PLIST=app/Resources/Info.plist
ENTITLEMENTS=app/Resources/entitlements.plist
CATALOG=app/Resources/Localizable.xcstrings
# The icon has no source folder: app/make_icon.py writes the whole layered
# document, art and all, into build/ on every build.
ICON=build/AppIcon.icon
# The macOS the Info.plist promises. The package says the same number
# (platforms: [.macOS(.v15)]) and the assembled binary is checked against this
# one, because a build on a newer Mac that quietly targeted the builder's own
# macOS produced an app that says 15.0 and will not launch on 15.
MACOS_MIN="$(sed -n 's|.*<key>LSMinimumSystemVersion</key><string>\([0-9.]*\)</string>.*|\1|p' "$PLIST")"
MACOS_MIN="${MACOS_MIN:-15.0}"
IDENTITY="${IDENTITY:-}"
SIGN=(codesign --force --options runtime --entitlements "$ENTITLEMENTS")
if [ -n "$IDENTITY" ]; then SIGN+=(--timestamp --sign "$IDENTITY"); else SIGN+=(--sign -); fi
# Apple's timestamp service drops out now and then; a signature made without it is rejected by notarization, so retry.
sign() { local n out; for n in 1 2 3 4 5; do if out=$("${SIGN[@]}" "$@" 2>&1); then return 0; fi; echo "$out" | grep -v "replacing existing signature" || true; echo "  codesign failed (try $n), waiting"; sleep 20; done; return 1; }

# A public build is the default, and the other kind has to be asked for by
# its exact name. The flag used to run the other way (PUBLIC_BUILD=1 left the
# private modules out), and the command the header documented for the public
# releases page never set it: a forgotten flag should cost a missing reel
# button in his own copy, not private source in a notarized public DMG.
KIND=public
if [ "${PRIVATE_BUILD:-}" = 1 ]; then KIND=private
elif [ -n "${PRIVATE_BUILD:-}" ]; then echo "  PRIVATE_BUILD=${PRIVATE_BUILD} is not 1, so this is a public build"; fi
[ -n "${PUBLIC_BUILD:-}" ] && echo "  (PUBLIC_BUILD is no longer read: public is the default, PRIVATE_BUILD=1 is the other kind)"
# ALLOW_COPYLEFT means allow only when it is exactly 1. It was any non-empty
# value, so ALLOW_COPYLEFT=0, written to keep the gate on, turned it off.
COPYLEFT=0
if [ "${ALLOW_COPYLEFT:-}" = 1 ]; then COPYLEFT=1
elif [ -n "${ALLOW_COPYLEFT:-}" ]; then echo "  ALLOW_COPYLEFT=${ALLOW_COPYLEFT} is not 1, so the licence gate stays on"; fi
# The files that live in the private repo and are symlinked in. .gitignore
# and .githooks/pre-commit name the same two.
PRIVATE_MODULES=(reel.py spread.py)

# --- the gates -----------------------------------------------------------
# Each one prints why it refuses and returns non-zero; the caller decides
# whether that ends the run. They are functions so STAGE=check can run every
# one of them against what is here without building anything.

gate_tree() {
  # What a public build would take from pipeline/. `cp` follows a symlink, so a
  # plain copy would have put the private modules' source into a DMG published
  # on a public releases page while the repo they live in stays private. The
  # public copy takes regular files only; this says what it leaves out, and
  # refuses a private module that has turned into a real file, which would
  # otherwise be one rename away from being copied.
  local bad=0 links n
  links=$(find pipeline -type l 2>/dev/null | sort | tr '\n' ' ')
  if [ "$KIND" = public ]; then
    [ -n "$links" ] && echo "  left out of a public build (symlinks into the private repo): $links"
    for n in $PRIVATE_MODULES; do
      if [ -f "pipeline/$n" ] && [ ! -L "pipeline/$n" ]; then
        echo "  refusing: pipeline/$n is a real file here, not the symlink into the private repo."
        echo "  A public build must not carry it; move it back to the private repo."
        bad=1
      fi
    done
    if [ -n "${PIPELINE_TASTE_SEED:-}" ]; then
      echo "  refusing: PIPELINE_TASTE_SEED is his learned file and goes only into a PRIVATE_BUILD=1."
      bad=1
    fi
  elif [ -n "${PIPELINE_TASTE_SEED:-}" ] && [ ! -s "$PIPELINE_TASTE_SEED" ]; then
    echo "  refusing: PIPELINE_TASTE_SEED names $PIPELINE_TASTE_SEED, which is missing or empty"
    bad=1
  fi
  # taste.json is the starting edit; the app is nothing without it.
  if [ ! -s pipeline/taste.json ]; then
    echo "  refusing: pipeline/taste.json is missing: run ./pl taste first"
    bad=1
  fi
  # The binary Info.plist names is the file this script writes at $EXE. If the
  # two part, the bundle is a folder Finder will not open, and nothing says why.
  local named
  named=$(sed -n 's|.*<key>CFBundleExecutable</key><string>\([^<]*\)</string>.*|\1|p' "$PLIST" 2>/dev/null)
  if [ "$named" != "${EXE:t}" ]; then
    echo "  refusing: $PLIST names the executable \"$named\" and this script writes \"${EXE:t}\"."
    echo "  They have to be the same name; EXE is set near the top of app/build.sh."
    bad=1
  fi
  return $bad
}

gate_vocabulary() {
  # The private extension's vocabulary, over everything under app/ — source,
  # comments, test names, fixture data, file names — and over whatever else is
  # named here, which is how the compiled string catalog inside an assembled
  # bundle gets scanned as well. The word list is not in this repository; the
  # script reads it from the file git config names (.githooks/vocab.zsh).
  [ -x app/tools/vocabulary-scan.sh ] || { echo "  no app/tools/vocabulary-scan.sh in this tree"; return 0; }
  app/tools/vocabulary-scan.sh "$@" | sed 's/^/  /'
  return ${pipestatus[1]}
}

gate_strings() {
  # The compiled catalog, scanned the way a person reads it: what is inside
  # the bundle, not what the source says. Nothing to scan is not an answer —
  # gate_app is what refuses a bundle with no catalog in it.
  local -a lproj
  lproj=("$R"/*.lproj(N))
  (( ${#lproj} )) || return 0
  gate_vocabulary "${lproj[@]}"
}

gate_bundle() {
  # Run on the assembled app, before it is signed and again whenever it is.
  local bad=0 kind="$1" f n links gpl
  local -a banned
  # 1. Nothing in the bundle's pipeline is a link, in either kind of build: a
  # link out of a signed bundle is a path on the build machine.
  links=$(find "$R/pipeline" -type l 2>/dev/null | head -5)
  if [ -n "$links" ]; then
    echo "  refusing: the bundle's pipeline folder holds symlinks:"; echo "$links" | sed 's/^/    /'
    bad=1
  fi
  if [ "$kind" != private ]; then
    # 2. A public bundle carries no private module, however it got there, and
    # nothing that came through a link in the tree.
    for n in $PRIVATE_MODULES; do
      if [ -e "$R/pipeline/$n" ]; then echo "  refusing: a public bundle carries pipeline/$n"; bad=1; fi
    done
    # Nothing today can trip this one: the copy step is `find -type f`, and a
    # symlink is type l, so a linked module is never copied in the first place.
    # It is here for the day someone reaches for cp -RL or a plain cp -R and
    # the link stops being visible as a link - then this is what catches it.
    for f in "$R"/pipeline/*(N.); do
      if [ -L "pipeline/${f:t}" ]; then
        echo "  refusing: $R/pipeline/${f:t} was copied through a symlink in the tree"; bad=1
      fi
    done
    # 3. His learned taste goes only into his own copy: a public bundle's
    # taste.json is the repository's, byte for byte.
    if [ -f "$R/pipeline/taste.json" ] && ! cmp -s "$R/pipeline/taste.json" pipeline/taste.json; then
      echo "  refusing: the bundle's taste.json is not the repository's"; bad=1
    fi
  fi
  # 4. Licences: nothing copyleft may be inside a bundle we hand out. The PyPI
  # opencv wheels carry their own FFmpeg, and that FFmpeg is linked against
  # libx264 and libx265, which are GPL-2.0-or-later. Verified with otool:
  # cv2.abi3.so -> @loader_path/.dylibs/libavcodec.61.dylib -> @loader_path/libx264.164.dylib,
  # five hard load commands deep, so the libraries cannot simply be deleted.
  # Nothing in the pipeline decodes video; they do nothing here except make the
  # DMG a distribution of GPL code with no source offer. The bundle installs
  # OpenCV built from source with -DWITH_FFMPEG=OFF instead (app/tools/build-opencv.sh),
  # and this gate is what notices the day it stops doing that.
  banned=()
  while IFS= read -r f; do [ -n "$f" ] && banned+=("$f"); done < <(find "$R" \( \
    -name 'libx264*' -o -name 'libx265*' -o -name 'libbluray*' -o -name 'librubberband*' \
    -o -name 'libvidstab*' -o -name 'libxvid*' -o -name 'libopencore-amr*' -o -name 'frei0r*' \) 2>/dev/null)
  if (( ${#banned} )); then
    echo "  refusing: ${#banned} copyleft libraries are in the bundle"
    printf '    %s\n' "${banned[@]:0:8}"
    echo "  The OpenCV wheels this bundle installs are built without FFmpeg by"
    echo "  app/tools/build-opencv.sh; a bundle with these libraries in it took the PyPI"
    echo "  wheels instead, so check app/requirements.lock and build/wheels."
    echo "  Set ALLOW_COPYLEFT=1 to build anyway (a local build you do not hand out)."
    (( COPYLEFT )) || bad=1
  fi
  # grep exits 1 when it finds nothing, which under pipefail made a clean
  # bundle, the one case this gate exists to let through, end the script
  # right here with no message at all.
  # (not NOTICES.md: it quotes the configure flag in the paragraph explaining all this)
  gpl=$(grep -rl --exclude=NOTICES.md -- '--enable-gpl' "$R" 2>/dev/null | head -3 || true)
  if [ -n "$gpl" ]; then
    echo "  refusing: a GPL-configured binary is in the bundle"
    print -rl -- "${(@f)gpl}" | sed 's/^/    /'
    (( COPYLEFT )) || bad=1
  fi
  # 5. The build machine's home folder is nowhere in a public bundle: it is
  # his user name, and it reached the bundle once through pip's scripts and
  # once through every .pyc. The app's own binary is included on purpose — a
  # release build with debug information in it carries the path it was
  # compiled at, which on his machine is his home folder.
  if [ "$kind" != private ] && [ ${#HOME} -gt 5 ]; then
    f=$(grep -rlF -- "$HOME" "$C" 2>/dev/null | head -3 || true)
    if [ -n "$f" ]; then
      echo "  refusing: the bundle carries this machine's home folder ($HOME):"
      print -rl -- "${(@f)f}" | sed 's/^/    /'
      bad=1
    fi
  fi
  (( COPYLEFT )) && echo "  ALLOW_COPYLEFT=1: this build must not be distributed"
  return $bad
}

gate_app() {
  # The parts of the bundle that come out of the Swift package: the binary,
  # the compiled string catalog, the compiled asset catalog. Each one is a
  # step that can fail quietly — actool and xcstringstool both exit 0 with an
  # empty output directory if you point them at the wrong thing — so each one
  # is checked for here rather than assumed from a build that "ran".
  local bad=0 minos keys strings iconname
  if [ ! -x "$EXE" ]; then
    echo "  refusing: there is no executable at $EXE"
    return 1
  fi
  # arm64, and the macOS it says it needs is the one Info.plist promises.
  if ! file -b "$EXE" | grep -q 'Mach-O.*arm64'; then
    echo "  refusing: $EXE is not an arm64 Mach-O: $(file -b "$EXE")"
    bad=1
  fi
  minos=$(xcrun vtool -show-build "$EXE" 2>/dev/null | awk '/minos/ {print $2; exit}')
  if [ -z "$minos" ]; then
    echo "  refusing: $EXE does not say which macOS it was built for"
    bad=1
  elif [ "$minos" != "$MACOS_MIN" ]; then
    echo "  refusing: the app is built for macOS $minos and Info.plist promises $MACOS_MIN."
    echo "  Package.swift's platforms and LSMinimumSystemVersion have to be the same number."
    bad=1
  fi
  # The strings a person reads. Compiled, and with every key the source
  # catalog has: an empty .strings file is what a missing --language leaves
  # behind, and a key short is a sentence that shows as its own name.
  strings="$R/en.lproj/Localizable.strings"
  if [ ! -s "$strings" ]; then
    echo "  refusing: no compiled string catalog at $strings"
    bad=1
  elif [ -f "$CATALOG" ]; then
    keys=$(plutil -convert json -o - "$strings" 2>/dev/null \
           | /usr/bin/python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)
    want=$(/usr/bin/python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["strings"]))' "$CATALOG")
    if [ "$keys" != "$want" ]; then
      echo "  refusing: the bundle has $keys strings and $CATALOG has $want."
      echo "  A key with no English value in the catalog is the usual reason."
      bad=1
    fi
  fi
  # The icon. actool writes Assets.car and AppIcon.icns, and says in its
  # partial plist which name it used; Info.plist has to name the same one or
  # the Dock shows a blank page.
  [ -s "$R/Assets.car" ] || { echo "  refusing: no compiled asset catalog at $R/Assets.car"; bad=1; }
  iconname=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$C/Info.plist" 2>/dev/null) || iconname=""
  if [ -n "$iconname" ] && [ ! -s "$R/$iconname.icns" ]; then
    echo "  refusing: Info.plist names the icon $iconname and there is no $R/$iconname.icns"
    bad=1
  fi
  # Nothing from the build tree rode along.
  local -a debris
  debris=()
  while IFS= read -r f; do [ -n "$f" ] && debris+=("$f"); done < <(find "$C" -maxdepth 3 \
    \( -name '*.dSYM' -o -name '*.swiftmodule' -o -name '*.swiftdoc' -o -name '.build' \) 2>/dev/null)
  if (( ${#debris} )); then
    echo "  refusing: build leftovers are inside the bundle:"
    printf '    %s\n' "${debris[@]:0:5}"
    bad=1
  fi
  return $bad
}

# The kind of build an app in build/ is, from its own Info.plist rather than
# from whatever this run was asked for: the bundle is what it is. PlistBuddy
# says a missing key on stdout, so only the two words it may say are believed,
# and the gates treat anything else as a public build, which is the strict one.
bundle_kind() {
  local k
  k=$(/usr/libexec/PlistBuddy -c 'Print :PhotoPipelineBuild' "$C/Info.plist" 2>/dev/null) || k=""
  case "$k" in
    public|private) print -r -- "$k" ;;
    *) print -r -- unknown ;;
  esac
}

notices() {   # $1: where to write it
  echo "== NOTICES.md, generated from what is actually in the bundle"
  "$BPY" app/notices.py "$R" "$VERSION" "$PYURL" "$1"
}

smoke() {
  # The assembled app, run before it is signed: the engine starts out of the
  # bundle, answers an authenticated request, and the real offscreen shell lists
  # what the library holds and quits. This is what catches "the bundle is
  # signed but the interpreter cannot start" before a DMG exists.
  #
  # SMOKE_LIBRARY names a scratch clone of a library. Without one the app is
  # run against an empty library made here, which still exercises every part
  # that can be wrong about a bundle. Neither is ever ~/photos: smoke.sh
  # refuses that outright.
  local lib="${SMOKE_LIBRARY:-}"
  local -a deep
  [ -x app/tools/smoke.sh ] || { echo "  no app/tools/smoke.sh in this tree"; return 1; }
  if [ -n "$lib" ]; then
    deep=(--deep)
  else
    lib="$(mktemp -d /private/tmp/first-edit-smoke-library.XXXXXX)/library"
    mkdir -p "$lib/shoots"
    echo "  no SMOKE_LIBRARY: running against an empty one in $lib"
  fi
  app/tools/smoke.sh --offscreen --library "$lib" --app "$EXE" $deep | sed 's/^/  /'
  return ${pipestatus[1]}
}

if [ "${STAGE:-}" = lock ]; then
  echo "== lock: resolving requirements.txt into app/requirements.lock"
  [ -x "$BPY" ] || { echo "  build once first: the lock is resolved with the interpreter the app ships"; exit 1; }
  "$BPY" -m pip install -q --upgrade pip
  "$BPY" -m pip install --dry-run --ignore-installed --quiet --report build/resolve.json -r requirements.txt
  "$BPY" app/lock.py write build/resolve.json app/requirements.lock
  exit 0
fi

if [ "${STAGE:-}" = check ]; then
  echo "== check: the gates, and nothing else ($KIND build)"
  bad=0
  gate_tree || bad=1
  TOOLPY="$BPY"; [ -x "$TOOLPY" ] || TOOLPY=$(command -v python3 || true)
  [ -n "$TOOLPY" ] && { "$TOOLPY" app/lock.py check requirements.txt app/requirements.lock || bad=1; }
  [ -d app/Sources ] && { gate_vocabulary || bad=1; }
  # app/main.swift is gone: the package's FirstEdit target is the app.
  # This says so if it ever comes back, because a second entry point that
  # nothing builds is a file people read and believe.
  [ -f app/main.swift ] && { echo "  app/main.swift is back and nothing builds it: the package's FirstEdit target is the app"; bad=1; }
  if [ -d "$APP" ]; then
    kind=$(bundle_kind)
    echo "  the app in build/ is a $kind build"
    gate_bundle "$kind" || bad=1
    if [ -e "$EXE" ]; then
      gate_app || bad=1
      gate_strings || bad=1
    else
      echo "  no executable in the bundle, so the app's own gates have nothing to read"
    fi
    [ -x "$BPY" ] && { notices "build/NOTICES.check.md" || bad=1; }
    # gate.py and lock.py are stdlib only, so any python answers for them; the
    # bundle's own is not built yet when someone checks a tree before building.
    if [ -n "$TOOLPY" ]; then
      if [ -f "$MARKER" ]; then
        "$TOOLPY" app/gate.py check "$APP" "$MARKER" >/dev/null 2>&1 && echo "  it is the app a gated run signed" \
          || echo "  it is not the app a gated run signed: STAGE=dmg would refuse it"
      else
        echo "  no gate marker: STAGE=dmg would refuse it until a gated run signs it"
      fi
    fi
  else
    echo "  no app in build/ to check; the bundle gates run when one is assembled"
  fi
  (( bad )) && { echo "check: refused"; exit 1; }
  echo "check: ok"
  exit 0
fi

if [ "${STAGE:-}" = "sign" ] || [ "${STAGE:-}" = "dmg" ]; then
  [ -d "$APP" ] || { echo "no $APP to sign"; exit 1; }
  # The app keeps the version and kind it was assembled with.
  VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$C/Info.plist")
  KIND=$(bundle_kind)
  [ "$KIND" = unknown ] && { echo "$APP does not say whether it is a public or a private build; assemble it again"; exit 1; }
else

echo "== 0. the tree ($KIND build)"
gate_tree || exit 1
gate_vocabulary || exit 1

echo "== 1. python $PYVER + requirements"
if [ ! -x build/python/bin/python3.12 ]; then
  mkdir -p build && curl -sSL --fail -o build/py.tgz "$PYURL" && tar xzf build/py.tgz -C build && rm build/py.tgz
fi
"$BPY" -m pip install -q --upgrade pip
# By SHA-256, not by version: a version is a label, and the bytes behind it are
# whatever the index serves at the moment pip asks. This DMG is signed,
# notarized and handed out.
"$BPY" app/lock.py check requirements.txt app/requirements.lock || exit 1
# Two of those wheels are not on PyPI. The published OpenCV wheels carry a
# GPL-configured FFmpeg, which the gate below refuses, so they are built from
# source by app/tools/build-opencv.sh and the lock names them by URL. `stage`
# puts each one in build/wheels -- from OPENCV_WHEELHOUSE if it is set, from
# build/wheels if it is already there, and otherwise from the URL -- checks it
# against the SHA-256 the lock names, and writes the lock pip is handed with
# those lines pointing at the files. The hashes are the lock's either way.
"$BPY" app/lock.py stage app/requirements.lock build/wheels build/requirements.lock || exit 1
"$BPY" -m pip install -q --require-hashes -r build/requirements.lock
# And then make sure the cv2 in build/python is really the one we just staged.
# pip answers "already satisfied" on a version number, and both OpenCV wheels
# carry the SAME version as the published ones they replace, so a build/python
# left over from an earlier build kept the PyPI cv2 -- with its GPL-configured
# FFmpeg and its seven copyleft libraries -- and only the gate at 4b noticed,
# after twenty minutes of assembling. The evidence is a .dylibs folder: ours
# links nothing but macOS, so it has none.
if [ -d build/python/lib/python3.12/site-packages/cv2/.dylibs ]; then
  echo "  the cv2 in build/python is not the one staged (it has bundled libraries); installing ours over it"
  "$BPY" -m pip install -q --no-deps --force-reinstall build/wheels/*.whl
  [ -d build/python/lib/python3.12/site-packages/cv2/.dylibs ] \
    && { echo "  refusing: cv2 still carries bundled libraries after a forced reinstall"; exit 1; }
  echo "  cv2 is the staged build now"
fi

echo "== 2. models and exiftool"
pipeline/models.sh build/models
if [ ! -f build/exiftool/exiftool ]; then
  curl -sSL --fail -o build/exiftool.tgz "https://github.com/exiftool/exiftool/archive/refs/tags/$EXIFTOOL_VER.tar.gz"
  rm -rf build/exiftool && mkdir -p build/exiftool && tar xzf build/exiftool.tgz -C build/exiftool --strip-components 1 && rm build/exiftool.tgz
fi

echo "== 3. the app's own code"
# The tests before the build that goes out, not after it: they are two seconds
# and they cover the decoding of every route, the verdict queue, the key map
# and the strings.
mkdir -p build
if ! swift test --package-path app > build/swift-test.log 2>&1; then
  echo "  Swift tests had a transient runner failure; retrying once"
  swift test --package-path app > build/swift-test.log 2>&1 \
    || { tail -20 build/swift-test.log; echo "  the app's own tests did not pass; nothing is assembled"; exit 1; }
fi
tail -1 build/swift-test.log | sed 's/^/  /'
swift build --package-path app -c release --arch arm64 > build/swift-build.log 2>&1 \
  || { tail -20 build/swift-build.log; echo "  swift build failed"; exit 1; }
tail -1 build/swift-build.log | sed 's/^/  /'
# Where the binary landed, from SwiftPM rather than from a path written down
# here: .build/release is a symlink whose target has already changed once
# (6.4 builds into .build/out/Products/Release), and a bundle assembled around
# a stale binary is the kind of thing nobody notices for a release or two.
SWIFTBIN=$(swift build --package-path app -c release --arch arm64 --show-bin-path 2>/dev/null | tail -1)
[ -n "$SWIFTBIN" ] || SWIFTBIN=app/.build/release
[ -x "$SWIFTBIN/FirstEdit" ] || { echo "swift build produced no FirstEdit in $SWIFTBIN"; exit 1; }

echo "== 4. assemble"
rm -rf "$APP" "$MARKER" && mkdir -p "$C/MacOS" "$R"
cp -R build/python "$R/python"
# Cached wheels retain the previous build machine's path in pip metadata.
# Clean the copied bundle only; the dependency cache and licence files stay.
"$BPY" app/bundle_metadata.py "$R/python"
rm -rf "$R/python/lib/python3.12/test" "$R/python/lib/python3.12/idlelib" "$R/python/lib/python3.12/tkinter" "$R/python/share" "$R/python/include"
# tkinter went, and Tcl and Tk stayed: the libraries and their script folders
# are most of what is left of it, and nothing here draws a Tk window.
rm -rf "$R"/python/lib/libtcl*(N) "$R"/python/lib/libtk*(N) "$R"/python/lib/tcl*(N) "$R"/python/lib/tk*(N) \
       "$R"/python/lib/itcl*(N) "$R"/python/lib/thread*(N) "$R"/python/lib/python3.12/lib-dynload/_tkinter*(N)
# pip's console scripts (torchrun, huggingface-cli, ...) are written with the
# build folder's absolute path as their shebang: broken on any other Mac, and
# one of the places the build machine's user name reached the bundle. The app
# never calls them.
for f in "$R"/python/bin/*; do
  [ -f "$f" ] && head -c 2 "$f" 2>/dev/null | grep -q '#!' && head -1 "$f" | grep -q "^#!/Users/" && rm -f "$f"
done
# The other place was every .pyc, which records the path it was compiled at.
# They were dead weight besides: cp does not keep a source file's mtime, so
# the .pyc beside it no longer matched and Python compiled everything again at
# every launch, with nowhere to keep the result (the bundle is signed). They
# are compiled again here against the copied files, with the build folder cut
# off their paths, and marked to be trusted without a timestamp check, since a
# signed bundle cannot change underneath them. -f, and no bytecode written by
# the interpreter itself: starting it imports the encodings modules, which
# otherwise wrote their .pyc with the full path first, and compileall skips a
# .pyc whose timestamp matches whatever mode it was asked for.
find "$R/python" -name __pycache__ -type d -prune -exec rm -rf {} +
PYTHONDONTWRITEBYTECODE=1 "$R/python/bin/python3" -m compileall -f -q -j 0 --invalidation-mode unchecked-hash \
  -s "$PWD/$R/python" -p "${APP:t}/Contents/Resources/python" "$PWD/$R/python/lib" >/dev/null \
  || echo "  some files did not compile; Python compiles those at import instead"
# Real files only. A public build copies regular files and skips a symlink,
# so it simply does not carry the private modules and the studio hides their
# step; gate_tree above has said what it left out. His own build copies
# through the links, so reels work.
mkdir -p "$R/pipeline"
if [ "$KIND" = private ]; then
  cp pipeline/*.py pipeline/*.sh pipeline/*.json "$R/pipeline/"
  echo "  this build carries the private modules, so reels work; it must not be handed out"
  if [ -n "${PIPELINE_TASTE_SEED:-}" ]; then
    # His learned starting edit lives outside the repo now; his own copy
    # starts from it instead of the neutral one the repository carries.
    "$BPY" -c 'import json,sys; json.load(open(sys.argv[1]))' "$PIPELINE_TASTE_SEED" \
      || { echo "  PIPELINE_TASTE_SEED is not a JSON file: $PIPELINE_TASTE_SEED"; exit 1; }
    cp "$PIPELINE_TASTE_SEED" "$R/pipeline/taste.json"
    echo "  pipeline/taste.json is $PIPELINE_TASTE_SEED"
  fi
else
  find pipeline -maxdepth 1 -type f \( -name '*.py' -o -name '*.sh' -o -name '*.json' \) \
    ! -name reel.py ! -name spread.py -exec cp {} "$R/pipeline/" \;
fi
cp -R pipeline/templates "$R/pipeline/templates"
cp -R build/models "$R/models"
cp -R build/exiftool "$R/exiftool"

# The strings a person reads, compiled out of the catalog the app is written
# against. Running from a checkout there is no compiled catalog and the default
# value in Strings.swift shows instead, which is the same English sentence —
# so a catalog that failed to compile is invisible at runtime, and the gate
# below is what notices.
rm -rf "$R"/*.lproj(N)
xcrun xcstringstool compile --language en --output-directory "$R" "$CATALOG"

# The icon, drawn from app/make_icon.py as a layered .icon document and
# compiled by actool, which turns it into the same two files a catalog did —
# Assets.car and the loose AppIcon.icns — and additionally into the dark,
# clear and tinted appearances the system derives from the layers. The
# pictures are not committed: a generated file beside its generator goes stale
# the first time the generator changes.
# --standalone-icon-behavior all, because the loose .icns is what the DMG
# badges its window with and what anything that cannot read a CAR file shows;
# the default writes only a couple of its sizes.
"$BPY" app/make_icon.py "$ICON" | sed 's/^/  /'
xcrun actool "$ICON" --compile "$R" --platform macosx \
  --minimum-deployment-target "$MACOS_MIN" --app-icon AppIcon \
  --standalone-icon-behavior all \
  --output-partial-info-plist build/icon-plist.plist --output-format human-readable-text >/dev/null
# What actool says it called the icon has to be what Info.plist names, or the
# Dock shows a blank page and nothing else complains.
for key in CFBundleIconName CFBundleIconFile; do
  want=$(/usr/libexec/PlistBuddy -c "Print :$key" build/icon-plist.plist 2>/dev/null) || want=""
  have=$(sed -n "s|.*<key>$key</key><string>\([^<]*\)</string>.*|\1|p" "$PLIST")
  [ -z "$want" ] || [ "$want" = "$have" ] || {
    echo "  refusing: actool wrote $key=$want and $PLIST says $have"; exit 1; }
done

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NO/" -e "s/__KIND__/$KIND/" "$PLIST" > "$C/Info.plist"
cp "$SWIFTBIN/FirstEdit" "$EXE"
# Debug information belongs beside the build, not inside a bundle that is
# handed out: it is tens of megabytes and it carries the paths it was compiled
# at, which on his machine are under his home folder.
strip -S -x "$EXE" 2>/dev/null || true
[ -x "$EXE" ] || { echo "the app's binary did not reach the bundle"; exit 1; }
fi

if [ "${STAGE:-}" != "dmg" ]; then
# NOTICES.md is written into build/ and carried by the bundle; STAGE=dmg puts
# the same file beside the DMG in dist/. It is not tracked: it names the
# version it was made for, so a committed copy was out of date one commit
# later with nothing to say so.
notices build/NOTICES.md
cp build/NOTICES.md "$R/NOTICES.md"

echo "== 4b. the gates, on the assembled app"
gate_bundle "$KIND" || exit 1
gate_app || exit 1
gate_strings || exit 1
echo "  ok"

echo "== 4c. the smoke test: the assembled app, against a scratch library"
smoke || { echo "the assembled app did not pass its own smoke test; not signing it"; exit 1; }

if [ "${STAGE:-}" = assemble ]; then
  echo "assembled and gated, not signed: $APP"
  exit 0
fi

echo "== 5. sign every Mach-O, then the app"
xattr -cr "$APP"
files=("${(@f)$("$BPY" app/macho.py "$R")}")
for ((i = 1; i <= ${#files}; i += 40)); do sign "${files[@]:$((i-1)):40}"; done
echo "  ${#files} files signed"
sign "$APP"
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | tail -1
if [ -n "$IDENTITY" ]; then
  # (read into a variable first: with pipefail, grep -q closing the pipe would make codesign look like it failed)
  sig=$(codesign -dv --verbose=2 "$APP" 2>&1)
  echo "$sig" | grep -qE "flags=0x[0-9a-f]+\([^)]*runtime" || { echo "the app is not signed with the hardened runtime; stopping"; exit 1; }
  echo "$sig" | grep -q "^Authority=Developer ID Application" || { echo "the app is not signed with the Developer ID; stopping"; exit 1; }
  spctl --assess --type execute -vv "$APP" 2>&1 | tail -2 || true
fi
# And again, now that it is signed. The run before signing catches a bundle
# that was assembled wrong; this one catches the failure that only exists
# afterwards — the hardened runtime refusing the interpreter, or a Mach-O the
# signing pass missed — which is otherwise found by the first person to open
# the DMG.
echo "== 5b. the signed app still runs"
smoke || { echo "the signed app does not run; it is not a DMG"; exit 1; }

# The mark STAGE=dmg checks: this app, exactly as signed, passed the gates.
# Whether the version was given by hand is recorded with it, because STAGE=dmg
# can be a run of its own, hours later, with no VERSION in its environment.
if [ -n "$VERSION_GIVEN" ]; then VGIVEN=1; else VGIVEN=0; fi
"$BPY" app/gate.py write "$APP" "$MARKER" --kind "$KIND" --copyleft "$COPYLEFT" \
  --version "$VERSION" --version-given "$VGIVEN"
fi

echo "== 6. dmg"
[ -x "$BPY" ] || { echo "no build/python to package with; run a full build"; exit 1; }
gated=$("$BPY" app/gate.py check "$APP" "$MARKER") || { echo "refusing to package it"; exit 1; }
# Everything the packaging decisions rest on comes from the marker, not from
# this invocation: a STAGE=dmg run on its own has no VERSION and no
# PRIVATE_BUILD in its environment, and must not read their absence as an answer.
read -r KIND COPYLEFT VGIVEN _ <<< "$gated"
NOTARY=()
if [ -n "${NOTARY_KEY:-}" ]; then NOTARY=(--key "${NOTARY_KEY/#\~/$HOME}" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
elif [ -n "${NOTARY_PROFILE:-}" ]; then NOTARY=(--keychain-profile "$NOTARY_PROFILE"); fi
# A DMG that must not be handed out is named for what it is, and is never
# notarized: notarization is what makes a DMG open cleanly on someone else's Mac.
SUFFIX=""
[ "$KIND" = private ] && SUFFIX="-private"
[ "$COPYLEFT" = 1 ] && SUFFIX="$SUFFIX-local"
if [ ${#NOTARY[@]} -gt 0 ]; then
  if [ -n "$SUFFIX" ]; then
    echo "refusing to notarize a $KIND build$([ "$COPYLEFT" = 1 ] && echo ' made with ALLOW_COPYLEFT=1'): it is not for anyone else"
    exit 1
  fi
  # A dash means `git describe` landed past the last tag - unless the version
  # was spelled out by hand, which is the one case where a dash (1.0.0-beta1)
  # is the tag. The marker remembers which it was.
  if [ "$VGIVEN" != 1 ] && [[ "$VERSION" == *-* ]]; then
    echo "refusing to notarize version $VERSION: it is not a tag. Tag the commit (git tag vX.Y.Z) and build again."
    exit 1
  fi
fi
mkdir -p dist
DMG="dist/First-Edit-$VERSION$SUFFIX.dmg"
rm -f "$DMG"
# dmgbuild writes the Finder window layout itself (no Finder scripting): app left, Applications right, the arrow between.
# It is installed beside the bundle's interpreter, not into it: build/python is
# what gets copied into the app, and a DMG tool has no business inside one.
[ -d build/tools/dmgbuild ] || "$BPY" -m pip install -q --target build/tools dmgbuild
PYTHONPATH=build/tools "$BPY" -m dmgbuild -s app/dmg_settings.py -D app="$APP" "FirstEdit" "$DMG" | grep -v "^$" || true
[ -s "$DMG" ] || { echo "dmgbuild produced nothing"; exit 1; }
[ -n "$IDENTITY" ] && codesign --force --timestamp --sign "$IDENTITY" "$DMG"
# The notices that describe this DMG, beside it: they go up to the release as an asset of their own.
cp "$R/NOTICES.md" "dist/First-Edit-$VERSION$SUFFIX-NOTICES.md"
du -sh "$APP" "$DMG"

if [ ${#NOTARY[@]} -gt 0 ]; then
  echo "== 7. notarize (a few minutes)"
  xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait 2>&1 | tee build/notary.log
  grep -q "status: Accepted" build/notary.log || { echo "notarization did not accept the DMG; see: xcrun notarytool log <id> ${NOTARY[*]}"; exit 1; }
  # the ticket takes a minute to reach Apple's CDN after acceptance
  for n in 1 2 3 4 5 6 7 8 9 10; do xcrun stapler staple "$DMG" >/dev/null 2>&1 && break; sleep 30; done
  xcrun stapler validate "$DMG"
  echo "notarized and stapled: $DMG"
elif [ -n "$IDENTITY" ]; then
  echo "signed, not notarized: set NOTARY_PROFILE or NOTARY_KEY to notarize"
else
  echo "ad-hoc signed: fine on this Mac; other Macs will warn. Set IDENTITY to sign for real."
fi
[ -n "$SUFFIX" ] && echo "this is a$([ "$KIND" = private ] && echo ' private') build$([ "$COPYLEFT" = 1 ] && echo ' with copyleft libraries in it'): keep it to yourself"
exit 0
