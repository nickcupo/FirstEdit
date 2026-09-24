#!/usr/bin/env python3
"""NOTICES.md, generated from what is actually in the bundle.

    app/notices.py <Contents/Resources> <version> <python url> <out.md>

Run by app/build.sh from the repository root, with the bundle's own
interpreter. A notices file written by hand is wrong the first time a wheel is
bumped and stays wrong until someone asks for it. This one reads the licence,
the copyright line and a source URL out of the bundle itself: the dist-info of
every wheel that was installed, every native library those wheels carry,
models.json for the weights, and the FFmpeg libraries' own configure strings.
A bundled dependency that will not say what its licence is fails the build
rather than being listed as unknown.

The file is not tracked. It embedded the version it was generated for, so a
committed copy was stale by the next commit and nothing said so; the one that
counts is the one inside the app and beside its DMG in dist/.
"""
import json
import re
import subprocess
import sys
from importlib.metadata import Distribution
from pathlib import Path

# A License field is free text and half the wheels put prose in it: cycler says
# "Copyright (c) 2015, matplotlib project", kiwisolver a row of equals signs,
# scipy its whole BSD header, python-dateutil "Dual License". Only
# License-Expression (PEP 639) is a licence identifier by definition; a one-line
# License that names a licence family is taken as one, and everything else falls
# through to the Trove classifiers.
CLASSIFIER = {
    "Apache Software License": "Apache-2.0",
    "BSD License": "BSD",
    "MIT License": "MIT",
    "Mozilla Public License 2.0 (MPL 2.0)": "MPL-2.0",
    "Python Software Foundation License": "PSF-2.0",
    "Historical Permission Notice and Disclaimer (HPND)": "HPND",
    "ISC License (ISCL)": "ISC",
    "zlib/libpng License": "Zlib",
    "The Unlicense (Unlicense)": "Unlicense",
}
FAMILY = re.compile(r"\b(MIT|BSD|Apache|MPL|Mozilla|PSF|Python|ISC|Zlib|GPL|LGPL|AGPL"
                    r"|Unlicense|CC0|HPND|Artistic|Boost|BSL|CNRI|Public Domain)\b", re.I)
NAMED = ("license", "license.txt", "license.md", "licence", "licence.txt",
         "copying", "copying.txt", "notice", "notice.txt")
COPYRIGHT = re.compile(r"^(copyright|\(c\)|©)\b.*\b(19|20)\d\d", re.I)


def licence_of(m) -> tuple[str, str]:
    expr = (m.get("License-Expression") or "").strip()
    if expr:
        return expr, "License-Expression"
    lic = (m.get("License") or "").strip()
    if lic and "\n" not in lic and len(lic) <= 40 and FAMILY.search(lic):
        return lic, "License"
    names = [CLASSIFIER.get(c.rsplit("::", 1)[-1].strip(), c.rsplit("::", 1)[-1].strip())
             for c in (m.get_all("Classifier") or [])
             if c.startswith("License ::") and c.rsplit("::", 1)[-1].strip() != "OSI Approved"]
    if names:
        return " or ".join(dict.fromkeys(names)), "Classifier"
    return "", ""


def first_copyright(text: str) -> str:
    for line in text.splitlines():
        line = line.strip(" \t*#")
        if COPYRIGHT.match(line):
            return re.sub(r"\s+", " ", line)[:110]
    return ""


def copyright_of(d, m) -> str:
    """The first copyright line in the licence files the wheel itself ships.
    Only a file actually called LICENSE (or COPYING, or NOTICE) counts, and the
    line has to carry a year, which is what keeps Apache-2.0's own appendix
    ("Copyright [yyyy] [name of copyright owner]") out of the table.

    It is the first such line and not, reliably, the distribution's own, and
    the column is headed for what it is rather than pretending otherwise.
    matplotlib's LICENSE wraps "Copyright (c) 2012- Matplotlib Development
    Team" inside a sentence, so the first line that starts with the word is the
    AMS fonts' one 98 lines further down; mediapipe's gives Lucent
    Technologies, jaxlib's the OpenSSL project, setuptools' the FSF. A licence
    file that also carries the licences of software the wheel bundles cannot be
    read for one holder, and guessing which of them is the author would be
    worse than pointing at the file."""
    cands = [f for f in (d.files or []) if Path(str(f)).name.lower() in NAMED]
    cands.sort(key=lambda f: (len(Path(str(f)).parts), str(f)))
    for f in cands[:4]:
        try:
            got = first_copyright(Path(d.locate_file(f)).read_text(errors="ignore"))
        except OSError:
            continue
        if got:
            return got
    # Nothing the wheel ships states one. Said plainly, with whoever the wheel
    # names as its author, rather than invented.
    who = [w for w in (m.get("Author") or m.get("Author-email") or "").splitlines() if w.strip()]
    return f"none in the wheel (author: {who[0].strip()})" if who else "none in the wheel"


def source_of(m) -> str:
    urls = {}
    for u in m.get_all("Project-URL") or []:
        k, _, v = u.partition(",")
        urls[k.strip().lower()] = v.strip()
    for k in ("source", "source code", "repository", "homepage", "home"):
        if urls.get(k):
            return urls[k]
    return (m.get("Home-page") or "").strip() or f"https://pypi.org/project/{m['Name']}/"



# Native libraries inside the wheels. A wheel's dist-info licence is the
# wheel's own; the .dylibs it vendors carry the licences of the projects they
# come from, and the table above never showed them. Two are copyleft outright
# and have nothing to do with video: LibRaw inside rawpy (LGPL-2.1 or
# CDDL-1.0) and libquadmath inside scipy (LGPL-2.1-or-later). Each library is
# keyed by its name without the version (libavcodec.61.19.101.dylib is
# libavcodec) and says the licence its project publishes. None means the
# library is the wheel's own code, under the wheel's licence. A library this
# table has never seen fails the build, for the same reason a wheel with no
# licence does: nobody has read it.
FFMPEG_LIBS = {"libavcodec", "libavdevice", "libavfilter", "libavformat",
               "libavutil", "libpostproc", "libswresample", "libswscale"}
NATIVE: dict[str, tuple[str, str] | None] = {
    "libIex": ("BSD-3-Clause", "https://openexr.com"),
    "libIlmThread": ("BSD-3-Clause", "https://openexr.com"),
    "libOpenEXR": ("BSD-3-Clause", "https://openexr.com"),
    "libOpenEXRCore": ("BSD-3-Clause", "https://openexr.com"),
    "libImath": ("BSD-3-Clause", "https://github.com/AcademySoftwareFoundation/Imath"),
    "libSDL2": ("Zlib", "https://www.libsdl.org"),
    "libSvtAv1Enc": ("BSD-3-Clause-Clear, with the AOM patent licence", "https://gitlab.com/AOMediaCodec/SVT-AV1"),
    "libX11": ("MIT and X11-style", "https://gitlab.freedesktop.org/xorg/lib/libx11"),
    "libXau": ("MIT", "https://gitlab.freedesktop.org/xorg/lib/libxau"),
    "libXdmcp": ("MIT", "https://gitlab.freedesktop.org/xorg/lib/libxdmcp"),
    "libxcb": ("MIT", "https://xcb.freedesktop.org"),
    "libxcb-shape": ("MIT", "https://xcb.freedesktop.org"),
    "libxcb-shm": ("MIT", "https://xcb.freedesktop.org"),
    "libxcb-xfixes": ("MIT", "https://xcb.freedesktop.org"),
    "libaom": ("BSD-2-Clause, with the AOM patent licence", "https://aomedia.googlesource.com/aom"),
    "libarchive": ("BSD-2-Clause", "https://www.libarchive.org"),
    "libaribb24": ("LGPL-3.0-or-later", "https://github.com/nkoriyama/aribb24"),
    "libass": ("ISC", "https://github.com/libass/libass"),
    "libavif": ("BSD-2-Clause", "https://github.com/AOMediaCodec/libavif"),
    "libb2": ("CC0-1.0 or OpenSSL or Apache-2.0", "https://github.com/BLAKE2/libb2"),
    "libbluray": ("LGPL-2.1-or-later", "https://www.videolan.org/developers/libbluray.html"),
    "libbrotlicommon": ("MIT", "https://github.com/google/brotli"),
    "libbrotlidec": ("MIT", "https://github.com/google/brotli"),
    "libbrotlienc": ("MIT", "https://github.com/google/brotli"),
    "libc++": ("Apache-2.0 WITH LLVM-exception", "https://libcxx.llvm.org"),
    "libcjson": ("MIT", "https://github.com/DaveGamble/cJSON"),
    "libcrypto": ("Apache-2.0", "https://www.openssl.org"),
    "libssl": ("Apache-2.0", "https://www.openssl.org"),
    "libdav1d": ("BSD-2-Clause", "https://code.videolan.org/videolan/dav1d"),
    "libdeflate": ("MIT", "https://github.com/ebiggers/libdeflate"),
    "libfontconfig": ("HPND-sell-variant", "https://www.freedesktop.org/wiki/Software/fontconfig/"),
    "libfreetype": ("FTL or GPL-2.0-or-later", "https://freetype.org"),
    "libfribidi": ("LGPL-2.1-or-later", "https://github.com/fribidi/fribidi"),
    "libgcc_s": ("GPL-3.0-or-later WITH GCC-exception-3.1", "https://gcc.gnu.org"),
    "libgfortran": ("GPL-3.0-or-later WITH GCC-exception-3.1", "https://gcc.gnu.org"),
    "libquadmath": ("LGPL-2.1-or-later", "https://gcc.gnu.org"),
    "libgif": ("MIT", "https://giflib.sourceforge.net"),
    "libglib": ("LGPL-2.1-or-later", "https://gitlab.gnome.org/GNOME/glib"),
    "libgmp": ("LGPL-3.0-or-later or GPL-2.0-or-later", "https://gmplib.org"),
    "libgnutls": ("LGPL-2.1-or-later", "https://gnutls.org"),
    "libgraphite2": ("LGPL-2.1-or-later or MPL-2.0 or GPL-2.0-or-later", "https://github.com/silnrsi/graphite"),
    "libharfbuzz": ("MIT", "https://harfbuzz.github.io"),
    "libhogweed": ("LGPL-3.0-or-later or GPL-2.0-or-later", "https://www.lysator.liu.se/~nisse/nettle/"),
    "libnettle": ("LGPL-3.0-or-later or GPL-2.0-or-later", "https://www.lysator.liu.se/~nisse/nettle/"),
    "libhwy": ("Apache-2.0 or BSD-3-Clause", "https://github.com/google/highway"),
    "libidn2": ("LGPL-3.0-or-later or GPL-2.0-or-later", "https://www.gnu.org/software/libidn/"),
    "libintl": ("LGPL-2.1-or-later", "https://www.gnu.org/software/gettext/"),
    "libjasper": ("JasPer-2.0", "https://jasper-software.github.io/jasper/"),
    "libjpeg": ("IJG and BSD-3-Clause and Zlib", "https://libjpeg-turbo.org"),
    "libjxl": ("BSD-3-Clause", "https://github.com/libjxl/libjxl"),
    "libjxl_cms": ("BSD-3-Clause", "https://github.com/libjxl/libjxl"),
    "libjxl_threads": ("BSD-3-Clause", "https://github.com/libjxl/libjxl"),
    "liblcms2": ("MIT", "https://www.littlecms.com"),
    "libleptonica": ("BSD-2-Clause", "http://www.leptonica.org"),
    "libllvmlite": ("BSD-2-Clause and Apache-2.0 WITH LLVM-exception", "https://github.com/numba/llvmlite"),
    "liblz4": ("BSD-2-Clause", "https://github.com/lz4/lz4"),
    "liblzma": ("0BSD or public domain", "https://tukaani.org/xz/"),
    "libmbedcrypto": ("Apache-2.0 or GPL-2.0-or-later", "https://www.trustedfirmware.org/projects/mbed-tls/"),
    "libmp3lame": ("LGPL-2.0-or-later", "https://lame.sourceforge.io"),
    "libogg": ("BSD-3-Clause", "https://xiph.org/ogg/"),
    "libomp": ("Apache-2.0 WITH LLVM-exception", "https://openmp.llvm.org"),
    "libonnxruntime": ("MIT", "https://onnxruntime.ai"),
    "libopencore-amrnb": ("Apache-2.0", "https://sourceforge.net/projects/opencore-amr/"),
    "libopencore-amrwb": ("Apache-2.0", "https://sourceforge.net/projects/opencore-amr/"),
    "libopenjp2": ("BSD-2-Clause", "https://www.openjpeg.org"),
    "libopus": ("BSD-3-Clause", "https://opus-codec.org"),
    "libp11-kit": ("BSD-3-Clause", "https://p11-glue.github.io/p11-glue/p11-kit.html"),
    "libpcre2": ("BSD-3-Clause WITH PCRE2-exception", "https://www.pcre.org"),
    "libpng16": ("libpng-2.0", "http://www.libpng.org/pub/png/libpng.html"),
    "libportaudio": ("MIT", "https://www.portaudio.com"),
    "librav1e": ("BSD-2-Clause", "https://github.com/xiph/rav1e"),
    "libraw_r": ("LGPL-2.1-only or CDDL-1.0", "https://www.libraw.org"),
    "librist": ("BSD-2-Clause", "https://code.videolan.org/rist/librist"),
    "librubberband": ("GPL-2.0-or-later", "https://breakfastquay.com/rubberband/"),
    "libsamplerate": ("BSD-2-Clause", "https://libsndfile.github.io/libsamplerate/"),
    "libsharpyuv": ("BSD-3-Clause", "https://chromium.googlesource.com/webm/libwebp"),
    "libsnappy": ("BSD-3-Clause", "https://github.com/google/snappy"),
    "libsodium": ("ISC", "https://libsodium.org"),
    "libsoxr": ("LGPL-2.1-or-later", "https://sourceforge.net/projects/soxr/"),
    "libspeex": ("BSD-3-Clause", "https://www.speex.org"),
    "libsrt": ("MPL-2.0", "https://github.com/Haivision/srt"),
    "libssh": ("LGPL-2.1-or-later", "https://www.libssh.org"),
    "libtasn1": ("LGPL-2.1-or-later", "https://www.gnu.org/software/libtasn1/"),
    "libtesseract": ("Apache-2.0", "https://github.com/tesseract-ocr/tesseract"),
    "libtheoradec": ("BSD-3-Clause", "https://www.theora.org"),
    "libtheoraenc": ("BSD-3-Clause", "https://www.theora.org"),
    "libtiff": ("libtiff", "https://libtiff.gitlab.io/libtiff/"),
    "libunibreak": ("Zlib", "https://github.com/adah1972/libunibreak"),
    "libunistring": ("LGPL-3.0-or-later or GPL-2.0-or-later", "https://www.gnu.org/software/libunistring/"),
    "libvidstab": ("GPL-2.0-or-later", "https://github.com/georgmartius/vid.stab"),
    "libvmaf": ("BSD-2-Clause-Patent", "https://github.com/Netflix/vmaf"),
    "libvorbis": ("BSD-3-Clause", "https://xiph.org/vorbis/"),
    "libvorbisenc": ("BSD-3-Clause", "https://xiph.org/vorbis/"),
    "libvpx": ("BSD-3-Clause", "https://www.webmproject.org/code/"),
    "libwebp": ("BSD-3-Clause", "https://chromium.googlesource.com/webm/libwebp"),
    "libwebpdemux": ("BSD-3-Clause", "https://chromium.googlesource.com/webm/libwebp"),
    "libwebpmux": ("BSD-3-Clause", "https://chromium.googlesource.com/webm/libwebp"),
    "libx264": ("GPL-2.0-or-later", "https://www.videolan.org/developers/x264.html"),
    "libx265": ("GPL-2.0-or-later", "https://www.x265.org"),
    "libz": ("Zlib", "https://github.com/zlib-ng/zlib-ng"),
    "libzimg": ("WTFPL", "https://github.com/sekrit-twc/zimg"),
    "libzmq": ("MPL-2.0", "https://zeromq.org"),
    "libzstd": ("BSD-3-Clause or GPL-2.0-only", "https://facebook.github.io/zstd/"),
    # The wheels' own code, under the wheel's own licence.
    "libc10": None, "libshm": None, "libtorch": None, "libtorch_cpu": None,
    "libtorch_global_deps": None, "libtorch_python": None, "libjax_common": None,
    "libarrow": None, "libarrow_acero": None, "libarrow_compute": None, "libarrow_dataset": None,
    "libarrow_flight": None, "libarrow_python": None, "libarrow_python_flight": None,
    "libarrow_python_parquet_encryption": None, "libarrow_substrait": None, "libparquet": None,
}
LICENCE_FILE = re.compile(r"(licen[cs]e|copying|notice)", re.I)


def stem(name: str) -> str:
    """libavcodec.61.19.101.dylib -> libavcodec, libIex-3_3.32.3.3.4.dylib ->
    libIex, libglib-2.0.0.dylib -> libglib, libopencore-amrnb.0.dylib keeps its
    hyphen because what follows it is a word, not a version."""
    return re.sub(r"-\d+(_\d+)?$", "", name.split(".")[0])


def native_rows(dists, site: Path, fflic: str = "") -> tuple[list[tuple[str, str, str, str, str]], list[str]]:
    """Every .dylib a wheel's RECORD lists, as (library, wheel, licence, project,
    where the licence text is), and the ones the table does not know.

    One file can be listed by two wheels: mediapipe pulls in
    opencv-contrib-python beside the pinned opencv-python-headless, both write
    cv2/.dylibs, and whichever installed last is the file on disk. The row
    names both rather than pretending to know which."""
    site = Path(site)
    claims: dict[str, list] = {}
    for d in dists:
        m = d.metadata
        files = [str(f) for f in (d.files or [])]
        libs = [f for f in files if f.endswith(".dylib") and (site / f).exists()]
        if not libs:
            continue
        # The wheel's own licence files: in its dist-info, or at the top of the
        # package it installs. Deeper ones (scipy/integrate/LICENSE_DOP) are a
        # vendored module's, not the text that covers these libraries.
        texts = [f for f in files if LICENCE_FILE.search(Path(f).name)
                 and not f.endswith((".py", ".pyc", ".dylib", ".so"))
                 and (".dist-info/" in f or len(Path(f).parts) <= 2)]
        texts = sorted(texts, key=lambda f: (".dist-info/" not in f, len(Path(f).parts), f))[:3]
        for f in libs:
            claims.setdefault(f, []).append((m, texts))
    rows, unknown = [], []
    for f in sorted(claims):
        owners = claims[f]
        m = owners[0][0]
        s = stem(Path(f).name)
        if s in FFMPEG_LIBS:
            lic = f"{fflic} (libavcodec's own statement)" if fflic else "LGPL-2.1-or-later, or GPL as configured"
            url = "https://ffmpeg.org"
        elif s in NATIVE:
            known = NATIVE[s]
            lic, url = known if known else (f"{licence_of(m)[0]} (the wheel's own)", source_of(m))
        else:
            unknown.append(f"{f} (from {m['Name']})")
            continue
        wheel = " and ".join(f"{o['Name']} {o['Version']}" for o, _ in owners)
        where = ", ".join(list(dict.fromkeys(f"`{x}`" for _, texts in owners for x in texts))[:4]) or "none in the wheel"
        rows.append((f, wheel, lic, url, where))
    return rows, unknown


def main(argv: list[str]) -> int:
    res, version, pyurl, out = Path(argv[1]), argv[2], argv[3], Path(argv[4])
    root = Path.cwd()
    site = next(res.glob("python/lib/python*/site-packages"))
    rows, unknown = [], []
    for d in sorted(Distribution.discover(path=[str(site)]), key=lambda d: d.metadata["Name"].lower()):
        m = d.metadata
        lic, whence = licence_of(m)
        if not lic:
            unknown.append(f"{m['Name']} {m['Version']}")
            continue
        rows.append((m["Name"], m["Version"], lic, whence, copyright_of(d, m), source_of(m)))
    if unknown:
        print("  refusing to build: no licence could be determined for " + ", ".join(unknown))
        print("  A dependency that will not say what its licence is cannot be listed in NOTICES.md,")
        print("  and a DMG that ships it hands out something nobody has read.")
        return 1

    # FFmpeg inside the OpenCV wheel, read out of the libraries rather than assumed:
    # their configure string and their own licence banner are in the binaries, and
    # the load commands that make them unremovable are in cv2's.
    ffver = fflic = ""
    ffopts: list[str] = []
    loads: list[str] = []
    ff = sorted(res.rglob("libavcodec*.dylib"))
    if ff:
        blob = ff[0].read_bytes()
        ffver = (re.search(rb"FFmpeg version ([ -~]{1,40})", blob) or [b"", b"unknown"])[1].decode()
        fflic = (re.search(rb"libavcodec license: ([ -~]{1,60})", blob) or [b"", b"unknown"])[1].decode()
        ffopts = sorted({g.decode() for g in re.findall(rb"--enable-(?:gpl|version3|nonfree)", blob)})
    # FFmpeg's libraries by name, not by a lib(av|sw) prefix: that prefix also
    # catches libavif, the AVIF image decoder, which has nothing to do with FFmpeg
    # and is not what the paragraph below is arguing about. It made the first
    # generated NOTICES.md claim six FFmpeg load commands where the binary has five.
    FFMPEG = ("libavcodec", "libavdevice", "libavfilter", "libavformat",
              "libavutil", "libpostproc", "libswresample", "libswscale")
    cv2so = sorted(res.rglob("cv2.abi3.so"))
    if cv2so:
        blob2 = cv2so[0].read_bytes()
        loads = [n for n in FFMPEG
                 if re.search(rb"@loader_path/\.dylibs/" + n.encode() + rb"\.", blob2)]
    GPL_LIBS = {"libx264": "GPL-2.0-or-later, https://www.videolan.org/developers/x264.html",
                "libx265": "GPL-2.0-or-later, https://www.x265.org"}
    refused = sorted({re.match(r"lib[a-z0-9-]+", p.name).group(0) for p in res.rglob("lib*")
                      if re.match(r"lib(x264|x265|bluray|vidstab|xvid|rubberband|opencore-amr)", p.name)})

    natives, strangers = native_rows(sorted(Distribution.discover(path=[str(site)]), key=lambda d: d.metadata["Name"].lower()),
                                     site, fflic)
    if strangers:
        print(f"  refusing to build: {len(strangers)} native libraries that app/notices.py has no licence for:")
        for s in strangers[:12]:
            print(f"    {s}")
        print("  Look each one up and add it to NATIVE in app/notices.py; a library nobody has read")
        print("  the licence of is not something to hand out inside a DMG.")
        return 1

    models = json.loads((root / "pipeline" / "models.json").read_text())["models"]
    pyroot = res / "python"
    pyver = subprocess.run([pyroot / "bin" / "python3", "-c", "import sys; print(sys.version.split()[0])"],
                           capture_output=True, text=True).stdout.strip()
    pylic = next(pyroot.glob("lib/python*/LICENSE.txt"), None)
    psf = re.search(r'"(Copyright \(c\)[^"]+?Python Software Foundation;[^"]*)"',
                    pylic.read_text(errors="ignore"), re.S) if pylic else None
    psf = re.sub(r"\s+", " ", psf.group(1)) if psf else "see the bundled LICENSE.txt"
    exif = root / "build" / "exiftool" / "exiftool"
    exiftext = exif.read_text(errors="ignore") if exif.exists() else ""
    exifver = (re.search(r"^my \$version = '([0-9.]+)'", exiftext, re.M) or ["", "unknown"])[1]
    exifcr = first_copyright(exiftext) or "unknown"

    L: list[str] = []
    add = L.append
    add("# Third-party notices")
    add("")
    add(f"First Edit {version} and everything it ships. `app/build.sh` writes this file from the")
    add("assembled bundle every time it builds one: the licence, the copyright line and a source URL")
    add("for each component are read out of that component's own files, and a dependency that will not")
    add("say what its licence is fails the build. First Edit itself is MIT; see `LICENSE`.")
    add("")
    add("## Read this before handing out a binary")
    add("")
    if refused:
        add(f"The `opencv-python-headless` wheel carries its own FFmpeg ({ffver}), configured with "
            + " and ".join(f"`{o}`" for o in ffopts) + ".")
        add(f"libavcodec in this bundle states its own licence as \"{fflic}\". The libraries it was built")
        add("against that `app/build.sh` refuses are here: " + ", ".join(f"`{r}`" for r in refused) + ".")
        add("Of those, " + "; ".join(f"**{k}** is {v}" for k, v in GPL_LIBS.items()) + ".")
        add("")
        add("They cannot simply be deleted. `cv2.abi3.so` names "
            + ", ".join(f"`{n}`" for n in loads) + " in its own load")
        add(f"commands ({len(loads)} of them), so removing the FFmpeg libraries breaks `import cv2`, and every")
        add("published headless wheel back to 4.10 carries them.")
        add("")
        add("Nothing in this pipeline decodes video; the libraries do nothing here except make a DMG a")
        add("distribution of GPL code with no source offer. **A binary intended for redistribution needs")
        add("OpenCV built with `-DWITH_FFMPEG=OFF`**, or a wheel that has no FFmpeg in it. `app/build.sh`")
        add("fails the build while they are present; `ALLOW_COPYLEFT=1` overrides that for a local build")
        add("that is handed to nobody. This states what is in the file; it is not legal advice.")
    else:
        # Counted, not claimed. This said "No copyleft library is in this
        # bundle" while its own table below listed four -- LibRaw and
        # libquadmath under the LGPL, libgcc_s and libgfortran under the GPL
        # with the runtime exception that exists precisely for this. What was
        # meant was "none that this may not hand out", and a document whose
        # first line is contradicted by its own table is worth nothing to the
        # person reading it to decide whether he may hand out the file.
        weak = sorted({f for f, _w, lic, _u, _x in natives if "GPL" in lic})
        if weak:
            add("There is no FFmpeg in this bundle at all, and no library in it is under the GPL without")
            add(f"an exception that covers this use. {len(weak)} carry the LGPL or the GCC runtime")
            add("exception — " + ", ".join(f"`{w}`" for w in weak) + " — each dynamically")
            add("linked, each replaceable, and each with its licence and its project named in the table")
            add("below. The OpenCV")
        else:
            add("No copyleft library is in this bundle, and there is no FFmpeg in it at all. The OpenCV")
        add("wheels here were built from source by `app/tools/build-opencv.sh`, from opencv-python at")
        add("the tag its published wheels carry, with `-DWITH_FFMPEG=OFF`; JPEG, PNG, TIFF, WEBP and")
        add("JPEG 2000 come from OpenCV's own bundled copies, and `cv2.abi3.so` links nothing outside")
        add("macOS itself. The wheels on PyPI are the reason: every release back to 4.10 carries an")
        add("FFmpeg configured `--enable-gpl` and linked against libx264, libx265, libbluray,")
        add("librubberband, libvidstab and libopencore-amr, all GPL-2.0-or-later, reached through hard")
        add("load commands in `cv2.abi3.so` that make them unremovable. Nothing in this pipeline decodes")
        add("video, so they did nothing here except make a DMG a distribution of GPL code with no source")
        add("offer. `app/build.sh` fails the build if any of them reappears, and `ALLOW_COPYLEFT=1`")
        add("overrides that only for a local build that is handed to nobody. This states what is in the")
        add("file; it is not legal advice.")
    add("")
    add("## Models")
    add("")
    add("Pinned by SHA-256 in `pipeline/models.json`, fetched by `pipeline/models.sh`, and shipped inside")
    add("the app.")
    add("")
    add("| Model | Licence | Copyright / attribution | Source |")
    add("|---|---|---|---|")
    for md in models:
        add(f"| `{md['file']}` | {md['licence']} | {md['attribution']} | {md['url']} |")
    add("")
    for md in models:
        if md.get("provenance_note"):
            add(f"**`{md['file']}`.** {md['provenance_note']}")
            add("")
    add("CLIP ViT-L/14 is **not** bundled: the app fetches it on first launch into the Hugging Face")
    add("cache. The runner is `open_clip_torch`, MIT, in the table below; the weights are OpenAI's")
    add("`ViT-L-14-quickgelu`/`openai`, released under MIT at https://github.com/openai/CLIP.")
    add("")
    add("## Interpreter and tools")
    add("")
    add(f"**CPython {pyver}**, PSF-2.0. {psf}.")
    add(f"The relocatable build is fetched from {pyurl};")
    add("its full licence travels with it at `Contents/Resources/python/lib/python*/LICENSE.txt`.")
    add("")
    add(f"**ExifTool {exifver}**, the same terms as Perl itself: Artistic-1.0-Perl or GPL-1.0-or-later,")
    add(f"at the recipient's choice. {exifcr}. https://github.com/exiftool/exiftool.")
    add("It is redistributed here under the Artistic Licence, which asks nothing of the rest of the")
    add("bundle; its own licence text travels with it in `Contents/Resources/exiftool`.")
    add("")
    add("## Python distributions")
    add("")
    add(f"The {len(rows)} wheels installed into the bundle's interpreter, read from their own `dist-info`.")
    add("`from` says which metadata field the licence came out of: `License-Expression` is an SPDX")
    add("expression by definition, `License` is free text that named a licence, and `Classifier` is the")
    add("Trove classifier, used where the `License` field held prose instead of a licence.")
    add("")
    add("The last column is the first line beginning `Copyright` and carrying a year in the LICENSE,")
    add("COPYING or NOTICE file that wheel ships. Where that file also carries the licences of software")
    add("the wheel bundles, the line is the bundled work's rather than the wheel's: matplotlib's reads")
    add("the AMS fonts, mediapipe's Lucent Technologies, jaxlib's the OpenSSL project, setuptools' the")
    add("FSF. Read it as a pointer into that file, not as the distribution's own notice.")
    add("")
    add("| Package | Version | Licence | from | First copyright line in its licence file | Source |")
    add("|---|---|---|---|---|---|")
    for name, ver, lic, whence, cr, url in rows:
        add(f"| {name} | {ver} | {lic} | {whence} | {cr} | {url} |")
    add("")
    add("## Native libraries inside the wheels")
    add("")
    add(f"The {len(natives)} `.dylib` files those wheels carry, each named with the wheel whose RECORD lists it.")
    add("The licence is the one the library's own project publishes; the licence text that travels with it")
    add("is the wheel's, in the file named in the last column. Where the licence is the wheel's own, the")
    add("library is that wheel's code. **LibRaw** (inside `rawpy`) is LGPL-2.1 or CDDL-1.0 and")
    add("**libquadmath** (inside `scipy`) LGPL-2.1-or-later: both are separate, replaceable files in")
    add("`Contents/Resources/python`, which is what the LGPL asks of a dynamically linked library. This")
    add("states what is in the bundle; it is not legal advice.")
    add("")
    add("| Library | Wheel | Licence | Project | Licence text in the wheel |")
    add("|---|---|---|---|---|")
    for f, wheel, lic, url, where in natives:
        add(f"| `{Path(f).name}` | {wheel} | {lic} | {url} | {where} |")
    add("")
    add("## In the repository, not in the app")
    add("")
    pets = sorted(p.name for p in (root / "tests" / "fixtures" / "pets").glob("*.jpg"))
    add(f"The {len(pets)} images in `tests/fixtures/pets` are from the Oxford-IIIT Pet dataset, CC BY-SA 4.0,")
    add("and are not covered by this project's MIT licence; `tests/fixtures/pets/ATTRIBUTION.md` says where")
    add("they come from, and they keep the dataset's own file names: " + ", ".join(f"`{n}`" for n in pets) + ".")
    add("The full Oxford-IIIT Pet set and the CEW blink crops that `./pl evaluate` measures against are")
    add("referenced by path on the machine that holds them and are never copied into the repo.")
    add("")
    out.write_text("\n".join(L) + "\n")
    print(f"  {len(rows)} Python distributions, {len(natives)} native libraries, {len(models)} models, CPython {pyver}, ExifTool {exifver}")
    print("  " + (f"refused libraries present: {', '.join(refused)}" if refused else "no refused libraries"))
    print(f"  wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
