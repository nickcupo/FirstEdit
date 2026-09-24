#!/bin/zsh
# Build the two OpenCV wheels the bundle installs, from source, without the
# GPL-encumbered FFmpeg the PyPI wheels carry.
#
#   app/tools/build-opencv.sh [outdir]        default outdir: build/wheels
#   OPENCV_WORK=/somewhere app/tools/build-opencv.sh   the checkout and the object
#                                             files (~8 GB), kept between runs.
#                                             The default is under $TMPDIR, and it
#                                             may not be under a home folder: see
#                                             the note beside WORK below.
#
# Why this script exists
# ----------------------
# `opencv-python-headless` and `opencv-contrib-python` on PyPI are built by
# the opencv-python CI with FFmpeg turned on, and that FFmpeg is configured
# --enable-gpl and linked against libx264, libx265, libbluray, librubberband,
# libvidstab and libopencore-amr. Those are GPL-2.0-or-later. Shipping them
# inside a signed DMG with no source offer is a GPL distribution, so
# app/build.sh refuses a bundle that contains them and the DMG cannot be
# notarized. Nothing in the pipeline decodes video: cv2 is used for imread,
# imwrite, imencode/imdecode, resize, cvtColor, Canny, Sobel, Laplacian,
# GaussianBlur, HoughLinesP, the ONNX dnn loader and the two face nets. The
# FFmpeg inside cv2 is dead weight, and this builds the same version of the
# same two packages with it off.
#
# Both wheels are built because the bundle installs both: requirements.txt
# pins opencv-python-headless, and mediapipe's own metadata requires
# opencv-contrib-python. pip installs them into the same cv2/ directory, so a
# GPL library in either one is a GPL library in the bundle.
#
# Needs: cmake, a C++ toolchain (Xcode command line tools), python3.12, and
# network for the first run (the opencv-python checkout is ~250 MB with its
# submodules, and OpenCV itself takes 20-60 minutes to compile).
set -e -o pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"

# The tag of opencv-python whose wheels are 5.0.0.93 on PyPI: the version
# app/requirements.lock pins. Moving this means moving the pins with it.
TAG=93
VERSION=5.0.0.93
PY="${PYTHON:-python3.12}"
OUT="${1:-$REPO/build/wheels}"
# Not under the repository, and not under a home folder. OpenCV writes its
# whole CMake configuration into the binary as the string cv2.getBuildInformation()
# returns, so the interpreter's path, numpy's path and the source path are all
# inside cv2.abi3.so afterwards. app/build.sh refuses a public bundle that
# carries the build machine's home folder anywhere, and it is right to: that
# is his user name, in a DMG on a public page.
WORK="${OPENCV_WORK:-${TMPDIR:-/tmp}/photo-pipeline-opencv}"
case "${WORK:A}" in
  "$HOME"|"$HOME"/*)
    echo "refusing to build in $WORK: it is under $HOME, and OpenCV writes the paths it"
    echo "was built at into cv2.abi3.so. app/build.sh then refuses the bundle for carrying"
    echo "this machine's home folder. Build somewhere else (the default is ${TMPDIR:-/tmp})."
    exit 1 ;;
esac
# The wheel is tagged for the macOS it was built to run on, not the one it was
# built on; 13.0 is what the PyPI wheels say and what the bundled interpreter
# accepts.
export MACOSX_DEPLOYMENT_TARGET=13.0
# No ninja is assumed to be installed. CI_BUILD=1 makes setup.py ask for
# "Unix Makefiles" explicitly, and it is also what puts ci_build = True in
# cv2/version.py, the way the PyPI wheels have it.
export CI_BUILD=1
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$(sysctl -n hw.ncpu)}"
export MAKEFLAGS="-j$CMAKE_BUILD_PARALLEL_LEVEL"
# setup.py runs `git submodule update` otherwise, which re-fetches a checkout
# this script has already placed.
export OPENCV_PYTHON_SKIP_GIT_COMMANDS=1
# pkg-config is the other way a library on the build machine gets into the
# wheel, and CMAKE_IGNORE_PREFIX_PATH does not cover it: the contrib `text`
# module found Homebrew's Tesseract through pkg-config and delocate then
# copied it, leptonica, libarchive, libb2, giflib and the rest into cv2, each
# one built for macOS 26 while the app promises 15. Pointed at nothing,
# pkg-config finds nothing.
mkdir -p "${TMPDIR:-/tmp}/opencv-no-pkgconfig"
export PKG_CONFIG_LIBDIR="${TMPDIR:-/tmp}/opencv-no-pkgconfig"
export PKG_CONFIG_PATH=""

# The flags. -DWITH_FFMPEG=OFF is the one the licence turns on; everything
# else keeps a library off the build machine from being linked in and then
# vendored into the wheel by delocate, which is how the PyPI wheels came to
# carry a hundred dylibs from Homebrew in the first place.
FLAGS=(
  # arm64, one architecture.
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_BUILD_TYPE=Release
  # Nothing is taken from Homebrew or /usr/local. The image codecs below are
  # built from OpenCV's own 3rdparty/ instead, so the wheel is self-contained
  # and the same on any Mac.
  "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local"
  # The whole point.
  -DWITH_FFMPEG=OFF
  # The other video backends: none is used, and each one is a door for a
  # codec library. AVFoundation is Apple's and not copyleft, but it is video
  # capture and the pipeline has never opened a camera.
  -DWITH_GSTREAMER=OFF
  -DWITH_AVFOUNDATION=OFF
  -DWITH_1394=OFF
  -DWITH_V4L=OFF
  -DWITH_XINE=OFF
  -DWITH_ARAVIS=OFF
  -DWITH_OBSENSOR=OFF
  -DWITH_MSMF=OFF
  -DVIDEOIO_ENABLE_PLUGINS=OFF
  # Image codecs, from OpenCV's own sources: JPEG and PNG are what the
  # pipeline reads and writes, and TIFF, WEBP, JPEG2000 and OpenEXR are here
  # so imread still answers for a file it answered for before.
  -DBUILD_ZLIB=ON
  -DBUILD_JPEG=ON
  -DBUILD_PNG=ON
  -DBUILD_TIFF=ON
  -DBUILD_WEBP=ON
  -DBUILD_OPENJPEG=ON
  -DBUILD_OPENEXR=ON
  -DWITH_OPENEXR=ON
  -DWITH_AVIF=OFF
  -DWITH_JPEGXL=OFF
  -DWITH_IMGCODEC_HDR=ON
  -DWITH_IMGCODEC_SUNRASTER=ON
  -DWITH_IMGCODEC_PXM=ON
  -DWITH_IMGCODEC_PFM=ON
  # dnn reads ONNX, which is protobuf; OpenCV's own copy, not the machine's.
  -DBUILD_PROTOBUF=ON
  -DWITH_PROTOBUF=ON
  # Patented algorithms stay out, as they do in the PyPI wheels.
  -DOPENCV_ENABLE_NONFREE=OFF
  # The contrib modules that reach for a library on the build machine. OCR is
  # the big one: the published opencv-contrib-python wheel vendors Tesseract
  # and its dozen dependencies, none of which this pipeline has ever called,
  # and the copies on this Mac need a newer macOS than the app promises.
  -DWITH_TESSERACT=OFF
  -DWITH_HALIDE=OFF
  -DWITH_VULKAN=OFF
  -DWITH_OPENVINO=OFF
  -DWITH_FREETYPE=OFF
  -DWITH_HARFBUZZ=OFF
  # No GUI, no Java, no tests, no docs, no sample apps.
  -DWITH_QT=OFF
  -DWITH_GTK=OFF
  -DWITH_WIN32UI=OFF
  -DBUILD_opencv_apps=OFF
  -DBUILD_opencv_java=OFF
  -DBUILD_TESTS=OFF
  -DBUILD_PERF_TESTS=OFF
  -DBUILD_DOCS=OFF
  -DBUILD_EXAMPLES=OFF
  # One .so for every supported Python, the way the PyPI wheels are built.
  -DPYTHON3_LIMITED_API=ON
  # The name, not the path. libpython is optional on Unix and is never linked
  # here; setup.py passes the full path to the interpreter this venv was made
  # from, which on any Mac with a uv or Homebrew Python is inside a home
  # folder, and that path is then a line of cv2.getBuildInformation() forever.
  -DPYTHON3_LIBRARY=libpython3.12.dylib
)

echo "== source: opencv-python at tag $TAG -> $WORK"
if [ ! -d "$WORK/.git" ]; then
  mkdir -p "$(dirname "$WORK")"
  git clone --recursive --depth 1 --branch "$TAG" https://github.com/opencv/opencv-python.git "$WORK"
fi
( cd "$WORK" && git describe --tags | grep -qx "$TAG" ) \
  || { echo "  $WORK is not opencv-python at tag $TAG"; exit 1; }

echo "== a venv to build in (never the repository's .venv)"
VENV="$WORK/.build-venv"
if [ ! -x "$VENV/bin/python" ]; then
  "$PY" -m venv "$VENV"
  "$VENV/bin/python" -m pip install -q --upgrade pip
  # pyproject.toml's build requirements, pinned there; delocate vendors and
  # rewrites whatever did get linked, and reports what that was.
  "$VENV/bin/python" -m pip install -q "numpy==2.0.2" "setuptools<70.0.0" \
    "scikit-build>=0.14.0" packaging wheel delocate
fi

mkdir -p "$OUT"
build() {   # $1: package name, $2: 1 to add the contrib modules
  local name=$1 contrib=$2
  echo "== building $name $VERSION (contrib=$contrib, headless, no FFmpeg)"
  # A fresh _skbuild: the two wheels are different CMake configurations and a
  # reused cache is how the second one silently becomes the first.
  rm -rf "$WORK/_skbuild" "$WORK/dist"
  ( cd "$WORK" \
    && ENABLE_HEADLESS=1 ENABLE_CONTRIB=$contrib \
       OPENCV_PYTHON_PACKAGE_NAME=$name \
       CMAKE_ARGS="${FLAGS[*]}" \
       "$VENV/bin/python" setup.py -q bdist_wheel )
  local whl
  whl=("$WORK"/dist/*.whl)
  echo "== delocate: what is still linked from outside the wheel"
  "$VENV/bin/delocate-listdeps" --all "${whl[1]}"
  "$VENV/bin/delocate-wheel" -w "$OUT" -v "${whl[1]}"
  # The same question app/build.sh asks of the assembled bundle, asked here
  # where it can still be answered by building again somewhere else.
  "$VENV/bin/python" - "$OUT/${whl[1]:t}" "$HOME" <<'PY'
import sys, zipfile
whl, home = sys.argv[1], sys.argv[2].encode()
if len(home) > 5:
    with zipfile.ZipFile(whl) as z:
        bad = [n for n in z.namelist() if home in z.read(n)]
    if bad:
        print(f"  refusing: {whl} carries this machine's home folder in:")
        for n in bad[:5]:
            print(f"    {n}")
        print("  Build it somewhere that is not under it; see the top of this script.")
        raise SystemExit(1)
print("  no home folder in the wheel")
PY
}

build opencv-python-headless 0
build opencv-contrib-python 1

echo "== the wheels, by SHA-256"
shasum -a 256 "$OUT"/opencv_*-"$VERSION"-*.whl
ls -l "$OUT"/opencv_*-"$VERSION"-*.whl
echo
echo "Copy each line's hash into app/requirements.lock beside its package, and"
echo "put the wheels where app/build.sh can find them (see RELEASING.md)."
