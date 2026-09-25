#!/usr/bin/env python3
"""What the photographer would do to a photograph, learned from what the photographer has already done.

Every sidecar the photographer has edited by hand is a labelled example: the photograph on one
side, the settings the photographer chose on the other. This reads them all, measures the
photographs, and fits one small model per setting. A setting keeps its model only
if it beats predicting the photographer's own median on frames it has never seen; otherwise the
median is the honest answer, and that is what gets used.

    ./pl taste                 # learn from every hand edit and report
    ./pl taste --report        # what it learned, without refitting
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
from pathlib import Path

import cv2
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from common import RAW_EXTS, decision_path, parse_shot_at, write_json_atomic  # noqa: E402
import library  # noqa: E402

# The neutral starting edit that ships beside this file: no venues, no ranker,
# so a checkout and a fresh install start from DxO's own camera-body rendering
# and learn from there. What HE has learned lives in the learned folder
# (learned.py), outside the repo and outside the signed app bundle, which is
# what lets the app learn at all.
SEED = HERE / "taste.json"


def model_path() -> Path:
    """The starting edit this run reads.

    PHOTO_TASTE for a dry run or a test that points at a scratch copy - frames
    are measured in spawned workers that read the file afresh, so a model
    patched in memory would never reach them - else the learned folder, seeded
    on first use from the bundled neutral edit."""
    env = os.environ.get("PHOTO_TASTE")
    if env:
        return Path(env)
    import learned
    return learned.seed_edit()
# The shoots live where PHOTOS_ROOT says, the way every other step reads it.
# This file used to hardcode ~/photos, so moving the root onto another volume
# left the learner looking at the old place: it found no hand edits, said so
# in one line, and went on predicting from the model it already had.
ROOT = Path(os.environ.get("PHOTOS_ROOT", Path.home() / "photos")).expanduser()
SHOOTS = ROOT / "shoots"

# The settings the photographer actually moves, from a count of the photographer's own edits.
NUMERIC = ["ExposureBias", "LightingV3BlackPoint", "LightingV3WhitePoint",
           "LightingV3Highlights", "LightingV3MidTones", "LightingV3Shadows",
           "LightingV3Intensity", "ColorModeContrast", "LightingV2LocalContrastAmount",
           "VibrancyIntensity", "WhiteBalanceRawTint", "DehazingValue",
           "GradeMasterHue", "GradeMasterSat"]
CATEGORICAL = ["LightingMode", "ColorRenderingType", "NoiseRemovalMethod",
               "ExposureAutoMode", "ColorGradingActive",
               "HazeRemovalActive", "ContrastEnhancementActive", "SelectiveTonalControlActive"]
# A look the photographer pastes onto a venue (the channel mixer on the gym) carries to
# that venue through shoot_overrides, never through a model or a constant.
LOOK_KEYS = ["ChannelMixerRed", "ChannelMixerOrange", "ChannelMixerYellow", "ChannelMixerGreen",
             "ChannelMixerCyan", "ChannelMixerBlue", "ChannelMixerPurple", "ChannelMixerMagenta", "ChannelMixerActive",
             "ColorModeSaturation", "ColorRenderingIntent"]
# What tells one venue from another, measured on the camera JPEG and the RAW:
# the light, not the face (a camera puts skin at 42-43 degrees in a bar and a
# gym alike). kelvin and cast_a alone separate the gym from the bar 9 times in
# 10; a distance over all seven, standardised, is the gate a look travels by.
VENUE_FEATS = ["kelvin", "cast_a", "cast_b", "frame_L", "light_chroma", "face_L", "face_C"]
# WhiteBalanceRawPreset is deliberately not in that list. A majority vote gives
# every frame AsShot (111 of 205) and can never say Fluo, which the photographer chose 92 times;
# it is decided per frame by learn_wb / predict_wb below.
# What a photograph looks like, in the numbers the cull already takes.
FEATS = ["frame_L", "range", "clip", "black", "cast_a", "cast_b",
         "light_chroma", "face_L", "face_rg", "subject_L", "subject_p90",
         "face_a", "face_b"]

MIN_SAMPLES = 25      # below this a key is left at its median
MIN_GAIN = 0.05       # a model must beat the median by this much to be used
# White balance. The photographer never types a temperature or a tint: the photographer leaves the camera's
# AsShot or switches to a named illuminant preset, Fluo on 92 of the photographer's 205 edits.
# That is a yes/no decision per frame and it is learned from the frames the photographer made
# it on, from the camera's own white balance reading and the cast on the neutral
# pixels, with the face colour when there is a face and without it when there is
# not. A model is kept only when it beats always-AsShot on frames from scenes it
# never saw.
#
# These eight are the LEGACY row, and they stay exactly as they are: every
# white balance model already stored - the one in use included - is ten
# weights against _wb_row over this list, in this order, and a model is
# nothing but its weights against its row.
WB_FEATS = ["kelvin", "cast_a", "cast_b", "light_chroma", "frame_L", "range", "face_hue", "face_L"]
# The camera's green-magenta reading of the light (presets.camera_wb_from_raw),
# which is the axis a Fluo decision is actually about and the one kelvin is
# blind to. It joins the eight above in a fit ONLY when every labelled frame
# that fit is made on carries it, and it has no missing-flag.
#
# Why all or nothing, when the face values get a flag and are used where
# they are present. A face is missing because nobody is in the frame, which
# is a fact about the frame. wb_green is missing because the frame was
# measured before it was kept: the store measures a frame again only when
# his sidecar changes or MEASURE_SCHEMA moves, and never once its RAW is
# archived. (MEASURE_SCHEMA is deliberately not bumped for it. A new key
# changes what no number already stored means, and a bump would mark every
# archived shoot's frames as older for nothing.) So which frames lack it is
# a fact about WHICH SHOOTS - and a shoot is a venue, and a venue is very
# nearly its class: the finished action venue holds 293 AsShot, one
# eyedropper and no Fluo. A flag, or a 0 where it is missing, would hand the
# fit a column that says "this came off an older or archived shoot", which
# predicts Fluo through the venue and not through the light, and holding out
# by scene cannot catch it, because a held-out scene carries the same flag
# as the rest of its shoot. So a fit uses it where it is on every frame and
# fits exactly as before where it is not; the model records which list it
# used (its "features"), and wb_call builds each frame's row from that list
# and nothing else.
WB_GREEN = "wb_green"
WB_MIN_AUC = 0.70     # held out by scene; below this the decision is not evidence, it is noise
# Decisions of one named preset before it is a class to learn from, and
# before a venue hands its frames to the per-frame model at all. The same
# floor learn_wb always had for a class, now also the gate a venue is
# consulted by: the finished action venue holds 293 AsShot and one
# eyedropper, so its frames keep AsShot; eight finished Fluo decisions there
# would hand them to the model, not the thirty the 90% unanimity rule needed.
WB_MIN_CLASS = 8
# What a shoot he has not named is called. It is a placeholder and not a
# name: every unnamed shoot in the library answers to it, so anything that
# puts it in a sentence about ONE of them (a reason the gate gives, a venue
# in the report) has to notice and say which shoot it means instead -- see
# venue_words.
UNNAMED_VENUE = "a finished shoot"
# The HSL slice fields PhotoLab writes per slice, read by name in any order.
SLICE_FIELDS = ("Hue", "Saturation", "Luminance", "Uniformity", "FadeInStart", "FadeInEnd", "FadeOutStart", "FadeOutEnd")
# A face the detector doubts, or a grey one, has no hue to speak of: a
# colour is read off the largest main face only when the detector
# is sure of it (presets.SURE_FACE) and its chroma clears this.
FACE_MIN_C = 10.0
# Exposure type: by hand, DxO's strong highlight recovery, or its medium.
#
# What writes it is presets.decide_exposure, and by default what decides it is
# the rule in presets.exposure_mode: the venue's own near-unanimous type where
# it has one, else Manual when nothing is saturated, else Medium where the
# face or the subject is dark and Strong where it is not.
#
# A POOLED learner was here and was retired: fitted on every finished frame
# but one shoot and asked for that shoot it was right on 12.5% of the gym's
# 351 frames (the gym's own type: 99.7%), 25.3% of 2026-09-19 (60.9%), 47.5%
# of the September portraits (53.0%) and 56.5% of 2026-09-21 (51.5%). His
# exposure type is a decision about a PLACE: the counts per venue (Manual /
# Strong / Medium) run 350/0/1 on the gym, 103/57/40 on 2026-09-21, 48/105/45
# on the portraits and 17/17/53 on 2026-09-19. One model over five venues
# scored 0.665 where the same model over two scored 0.757 on identical
# held-out frames; each venue's own commonest type scores 0.732; the venue's
# own fit where it beats that constant scores about 0.80. And a venue's fit is
# worth nothing to any OTHER venue: borrowing the nearest venue's answer for
# one it has not seen was worse than a flat constant on 3 of 4.
#
# So it is fitted per venue (venue_exposure), on that venue's own finished
# frames, held out by scene within the venue, and it is used only where it
# beats BOTH the venue's commonest type and the rule replayed on the same
# frames, each by enough frames that it is not luck (a one-sided sign test
# over the frames the fit and that baseline disagree on, at EXPO_P). And it is
# used only on the shoot that taught it. A venue is one finished shoot, so a
# new shoot that measures like it is a shoot the fit was never scored on -
# the same borrowing that lost to a constant on 3 of 4 - and it gets the rule.
# Everywhere else - a venue where the fit does not earn it, a shoot that
# borrows a venue, and a shoot that measures like no venue at all - the rule
# stands. learned.check_edit holds a candidate whose counts do not clear the
# same bar (expo_beats), naming the shoot.
EXPO_FEATS = ["kelvin", "frame_L", "range", "clip", "black", "cast_a", "cast_b", "light_chroma",
              "face_L", "face_rg", "subject_L", "subject_p90"]
EXPO_MODES = ("Manual", "StrongHighlightRecovery", "MediumHighlightRecovery")
EXPO_WORDS = {"Manual": "by hand", "StrongHighlightRecovery": "strong highlight recovery",
              "MediumHighlightRecovery": "medium highlight recovery"}
# A venue's own fit is not attempted below this many finished frames with a
# type on them, or in fewer groups than this to hold out (scenes; bursts only
# where the cull put the venue in fewer scenes than this): a fit that cannot
# be scored on frames it has not seen is not evidence.
EXPO_MIN_FRAMES = 30
EXPO_MIN_GROUPS = 3
# How sure "beats" has to be: a one-sided sign test over the frames the fit and
# each of the two baselines disagree on, both below this.
EXPO_P = 0.05
# The two things a venue's own fit would replace, as the page names them.
EXPO_BASES = {"rule": "the rule", "commonest": "its commonest type"}


# ----------------------------------------------------------------- reading

def _block(text: str, name: str) -> str:
    text = text.replace("\r\n", "\n")       # PhotoLab writes CRLF, the pipeline LF
    m = re.search(rf"\n(\t+){name} = \{{\n(.*?)\n\1\}},", text, re.S)
    return m.group(2) if m else ""


def flat_block(text: str, name: str) -> dict:
    """A block's depth-0 keys, as strings exactly as PhotoLab wrote them.

    Depth 0 only, for the reason final_settings gives: a mask's Corrections
    sub-table reuses the global slider names, and read at any depth one brush
    stroke votes for the whole frame."""
    out: dict = {}
    depth = 0
    for ln in _block(text, name).split("\n"):
        if depth == 0:
            mm = re.match(r"^\s*([A-Za-z0-9_]+) = ([^\n{]+?),\s*$", ln)
            if mm:
                out[mm.group(1)] = mm.group(2).strip()
        depth = max(0, depth + ln.count("{") - ln.count("}"))
    return out


def decided(ov: dict, base: dict) -> dict:
    """The Overrides keys that say something the frame's own Base did not.

    PhotoLab materialises the ACTIVE value of a control into Overrides when a
    frame is opened, so an Overrides key that merely repeats its own Base is
    not a decision -- it is the pipeline's own Base handed back. Audited over
    every hand sidecar under the shoots tree: ColorRenderingType echoes its
    Base 323 times and differs once, ChannelMixerActive and ChannelMixerRed
    echo 323 times and differ never. Those three are exactly the "look" the
    learner had been writing back onto the action venue: it was reading its
    own output and calling it his taste. By contrast NoiseRemovalMethod
    differs from its Base 202 times and echoes never, and the one
    ColorRenderingType that differs is another venue's DxOPortraitV2 -- both
    survive this gate, because they are real.

    PhotoLab re-serialises floats (-8.292 comes back as -8.2919999999999998),
    so numbers compare as numbers; booleans and names compare exactly."""
    out: dict = {}
    for k, v in ov.items():
        b = base.get(k)
        if b is None:
            out[k] = v
            continue
        if v == b:
            continue
        try:
            if abs(float(v) - float(b)) <= 1e-3:
                continue
        except ValueError:
            pass
        out[k] = v
    return out


def final_settings(text: str, his_choices_only: bool = False) -> dict:
    """Where a frame ended up: the preset's Base, with the photographer's Overrides on top.

    With his_choices_only, the Base is skipped and only what the photographer changed is
    returned. This matters more than it looks: the photographer's Base is DxO's own
    "1 - DxO Style - Natural", so learning from the merged result learns DxO's
    defaults back and calls them the photographer's taste. What the photographer actually decided is the
    delta, and the defaults already come free with the template."""
    out: dict = {}
    for block in (("Overrides",) if his_choices_only else ("Base", "Overrides")):
        b = _block(text, block)
        if not b:
            continue
        # Depth 0 only. The photographer's sidecars carry LocalParameters -> Corrections sub-tables
        # whose members reuse the global slider names, so a flat scan learns a
        # brush stroke on one region as though it were the whole photograph --
        # and the prediction is always written to the global slider.
        depth = 0
        for ln in b.split("\n"):
            if depth == 0:
                mm = re.match(r"^\s*([A-Za-z0-9_]+) = ([^,\n{]*),$", ln)
                if mm:
                    out[mm.group(1)] = mm.group(2).strip()
            depth = max(0, depth + ln.count("{") - ln.count("}"))
        g = re.search(r"ColorGradingParams_Master = \{(.*?)\}", b, re.S)
        if g:
            for kk, vv in re.findall(r"(Hue|Sat|Lum) = ([^,\n]*)", g.group(1)):
                out["GradeMaster" + kk] = vv.strip().rstrip(",")
    return out


def _shoot_of(raw: Path) -> Path:
    """The shoot a frame belongs to: raw/ and edit/ sit in it, cull/picks/ sits one deeper
    - or _cull/picks/, on an old flat shoot whose cull library.paths finds there."""
    d = raw.parent
    if d.name in ("raw", "edit"):
        return d.parent
    if d.name == "picks" and d.parent.name in ("cull", "_cull"):
        return d.parent.parent
    return d


class Exports(dict):
    """exported_at's answer: stem -> when its newest export was written, and
    `every`, stem -> when each of its exports was written. A camera reuses its
    numbers, so the newest export of a number can be a later frame's while an
    older one is this frame's (is_exported)."""

    def __init__(self, every: dict[str, list[float]] | None = None):
        self.every = {k: sorted(v) for k, v in (every or {}).items() if v}
        super().__init__({k: v[-1] for k, v in self.every.items()})


_EXPORTED: tuple[float, dict[str, float]] | None = None


def exported_at(max_age: float = 60.0) -> dict[str, float]:
    """Stem -> when its newest export was written, wherever the photographer
    exports to (EXPORTS), with every export's date beside it (Exports).
    Walking iCloud takes seconds and the studio asks once per shoot on its
    home page, so the answer is kept for a minute."""
    global _EXPORTED
    import glob as _g
    import os as _os
    import time as _t
    if _EXPORTED is None or _t.time() - _EXPORTED[0] > max_age:
        every: dict[str, list[float]] = {}
        for pat in EXPORTS:
            for f in _g.glob(str(pat), recursive=True):
                stem = Path(f).name.split("_DxO")[0]
                try:
                    every.setdefault(stem, []).append(_os.path.getmtime(f))
                except OSError:
                    continue
        _EXPORTED = (_t.time(), Exports(every))
    return _EXPORTED[1]


def exported_stems(max_age: float = 60.0) -> set[str]:
    return set(exported_at(max_age))


_SHOT_AT: dict[str, dict[str, float]] = {}


def shot_at_of(raw: Path) -> float:
    """When the camera took this frame, out of its shoot's own cull.csv.

    The shoot's record of its own frames outlives the frames: a delivered
    shoot's RAWs go to iCloud and cull.csv stays."""
    shoot = _shoot_of(raw)
    key = str(shoot)
    if key not in _SHOT_AT:
        out: dict[str, float] = {}
        import learned
        cc = learned.cull_dir(shoot) / "cull.csv"
        if cc.exists():
            import csv
            try:
                with cc.open() as fh:
                    for r in csv.DictReader(fh):
                        out[Path(r["file"]).stem] = parse_shot_at(r.get("shot_at", ""))
            except (OSError, ValueError, KeyError):
                out = {}
        _SHOT_AT[key] = out
    return _SHOT_AT[key].get(raw.stem, 0.0)


def frame_raw(shoot: Path, stem: str) -> Path | None:
    """This frame's RAW, found by its number whatever its extension, if it is
    still here. cull.csv can name the camera JPEG the cull decoded
    (2026-09-12-lounge's says TSC04015.jpg), and looking for raw/TSC04015.jpg
    found nothing beside raw/TSC04015.ARW.

    library.frame_raw's answer, and its cache: this was a second copy of the
    same index, kept under a second dict, looking in cull/picks/ where the
    library looks in whichever cull the shoot really has. It takes a stem
    where the library takes a name, so the stem is handed over as a name
    whose last suffix is only there to be stripped: a stem with a dot in it
    (DSC_0001.v2) would otherwise lose its last part to Path.stem and miss."""
    return library.frame_raw(shoot, f"{stem}.raw")


def shoot_day(shoot: Path) -> float:
    """The start of the day a shoot is named for (2026-09-12-lounge: midnight
    on 12 September); 0 for a shoot whose folder carries no date."""
    from datetime import datetime
    m = re.match(r"(\d{4}-\d{2}-\d{2})", Path(shoot).name)
    if not m:
        return 0.0
    try:
        return datetime.strptime(m.group(1), "%Y-%m-%d").timestamp()
    except ValueError:
        return 0.0


def frame_born(raw: Path) -> float:
    """When this frame existed by, to hold an export of its number to it: the
    earlier of when the camera took it (its shoot's cull.csv) and its RAW's own
    date, found by number. With no capture time recorded, the earlier of the
    RAW's date and the start of the shoot's own day - a RAW brought back from
    iCloud carries the day it came back, and 2026-09-16's came back on
    2026-09-22, after every export of it. 0 when none of them is known.

    The RAW is the first thing to go: a delivered shoot's RAWs are pushed to
    iCloud and dropped, and answering from the RAW alone lost a finished shoot
    its 154 exports, its Done card and its keepers the day it was archived.
    The capture time is the same fact, kept in the shoot's own cull.csv."""
    raw = Path(raw)
    shot = shot_at_of(raw)
    f = raw if raw.suffix.lower() in RAW_EXTS and raw.exists() else frame_raw(_shoot_of(raw), raw.stem)
    try:
        mt = f.stat().st_mtime if f is not None else 0.0
    except OSError:
        mt = 0.0
    known = [t for t in ((shot, mt) if shot else (mt, shoot_day(_shoot_of(raw)))) if t]
    return min(known) if known else 0.0


_HOLDERS: dict[str, tuple[float, dict[str, list[tuple[float, str]]]]] = {}


def _holders(shoots: Path, max_age: float = 60.0) -> dict[str, list[tuple[float, str]]]:
    """Number -> (when that frame was taken, its shoot), for every frame of
    every shoot in the library: what says when the camera next used a number.
    From each shoot's cull.csv - the capture time, else the shoot's day - and,
    on a shoot never culled, its RAWs' own dates. Kept for a minute, as the
    exports are."""
    import time as _t
    key = str(shoots)
    got = _HOLDERS.get(key)
    if got and _t.time() - got[0] <= max_age:
        return got[1]
    import csv
    import learned
    out: dict[str, list[tuple[float, str]]] = {}
    for sh in sorted(p for p in Path(shoots).iterdir() if p.is_dir()) if Path(shoots).is_dir() else []:
        day = shoot_day(sh)
        cc = learned.cull_dir(sh) / "cull.csv"
        seen: dict[str, float] = {}
        try:
            with cc.open() as fh:
                for r in csv.DictReader(fh):
                    seen[Path(r.get("file") or "").stem] = parse_shot_at(r.get("shot_at") or "") or day
        except (OSError, ValueError, KeyError):
            seen = {}
        if not seen:
            for folder in (sh / "raw", sh):
                if folder.is_dir():
                    for p in folder.iterdir():
                        if p.suffix.lower() in RAW_EXTS and p.stem not in seen:
                            try:
                                seen[p.stem] = day or p.stat().st_mtime
                            except OSError:
                                continue
        for stem, when in seen.items():
            if stem and when:
                out.setdefault(stem, []).append((when, sh.name))
    _HOLDERS[key] = (_t.time(), out)
    return out


def frame_until(raw: Path, born: float) -> float:
    """When the camera next took a frame with this number, in another shoot
    of the library: an export dated after that can be of that frame, not this
    one. Infinity when no later shoot holds the number."""
    shoot = _shoot_of(Path(raw))
    later = [when for when, name in _holders(shoot.parent).get(Path(raw).stem, [])
             if name != shoot.name and when > born]
    return min(later) if later else math.inf


def export_counts(raw: Path, dates, born: float | None = None) -> bool:
    """Whether any of these export dates is this frame's: after the frame
    existed (frame_born) and before the camera next took a frame with its
    number (frame_until). A camera reuses its numbers every ten thousand
    frames - he shoots about 1,500 a night - so an export of the same number
    from before this frame, or after the next one, is another frame's."""
    dates = [d for d in dates if d]
    if not dates:
        return False
    born = frame_born(raw) if born is None else born
    if not born:
        return False
    until = frame_until(raw, born)
    return any(born < d < until for d in dates)


def is_exported(raw: Path, at: dict[str, float] | None = None) -> bool:
    """Whether THIS frame was exported: an export of its number made after the
    frame existed and before the camera took another frame with that number
    (export_counts). `at` is exported_at()'s answer; a plain {stem: date}
    stands for one export each."""
    got = exported_at() if at is None else at
    every = getattr(got, "every", None)
    dates = every.get(raw.stem, []) if every is not None else [got.get(raw.stem) or 0.0]
    return export_counts(raw, dates)


def finished(raw: Path, exported: dict[str, float] | None = None) -> bool:
    """Whether an edit of this frame is finished work, and so evidence.

    A sidecar with the photographer's hand in it is protected either way; only a finished
    one teaches. Finished means the frame was exported, or its shoot was
    marked finished on the studio's Done card. Nothing else counts: a sidecar
    the photographer opened and tried three things on is not what the photographer wants, and seven of
    those on one shoot once outvoted everything the photographer had finished."""
    if is_exported(raw, exported):
        return True
    try:
        return bool(json.loads((_shoot_of(raw) / "shoot.json").read_text()).get("finished"))
    except Exception:  # noqa: BLE001
        return False


_HANDS: dict[str, tuple[tuple, dict[str, Path]]] = {}


def hand_copies(shoot: Path) -> dict[str, Path]:
    """His copy of each frame's sidecar on this shoot, by frame name: beside
    the RAW, in cull/picks/ or in edit/, whichever is newest with his hand in
    it (the date PhotoLab wrote inside the file first, then the file's own,
    because a star the studio writes into raw/ bumps the mtime without any
    edit of his).

    One rule in one place. There were three - hand_edits took the newest by
    mtime, shoot_overrides and venue_base took whichever folder came first in
    their loop, and presets had this one - so "which copy is his" had three
    answers on the same frame, and the learner and the writer could disagree
    about what he had decided."""
    shoot = Path(shoot)
    # A flat shoot keeps its sidecars beside the RAWs in the shoot folder
    # itself. Looking only in raw/ found none of them, so every frame of one
    # read as untouched to the learner, and presets would have written over
    # the 98 edits of ducksAndDeadlifts once it asked this instead of its own
    # copy of the rule.
    where = library.paths(shoot)
    folders = [where.raw, where.edit, where.picks]
    key = str(shoot)
    stamp = tuple(p.stat().st_mtime_ns if p.is_dir() else 0 for p in folders)
    got = _HANDS.get(key)
    if got and got[0] == stamp:
        return got[1]
    best: dict[str, tuple[tuple[str, float], Path]] = {}
    for folder in folders:
        if not folder.is_dir():
            continue
        for f in sorted(folder.glob("*.dop")):
            text = f.read_text(errors="ignore")
            if not is_hand(_block(text, "Overrides")):
                continue              # empty, or only what PhotoLab writes on open
            m = re.search(r'^\s*ModificationDate = "([^"]+)"', text, re.M)
            try:
                mt = f.stat().st_mtime
            except OSError:
                mt = 0.0
            name = f.name[:-4]
            k = (m.group(1) if m else "", mt)
            if name not in best or k > best[name][0]:
                best[name] = (k, f)
    out = {k: v[1] for k, v in best.items()}
    _HANDS[key] = (stamp, out)
    return out


def newest_hand(raw_dir: Path, name: str) -> Path | None:
    """The same answer for one frame, for a caller that has a folder and a
    frame name (presets.write_dops)."""
    return hand_copies(library.shoot_root(raw_dir)).get(name)


def _raw_of(shoot: Path, name: str) -> Path | None:
    """Where this frame's RAW is, if it is still here: by the exact name its
    sidecar carries, in the folders library.paths names. Not by number
    (library.frame_raw): a stray TSC04016.jpg.dop is not the ARW's hand."""
    where = library.paths(shoot)
    for p in (where.raw / name, where.shoot / name, where.edit / name, where.picks / name):
        if p.exists():
            return p
    return None


def finished_count(shoot: Path) -> int:
    """How many frames of this shoot carry a finished edit of the photographer's."""
    exported = exported_at()
    seen: set[str] = set()
    for name, f in hand_copies(shoot).items():
        raw = _raw_of(shoot, name) or (shoot / "raw" / name)
        if is_copy(raw):
            continue
        if finished(raw, exported):
            seen.add(name)
    return len(seen)


def venue_base(shoot: Path, default: str = "1 - DxO Style - Natural", only: set[str] | None = None) -> str:
    """The preset the photographer's finished sidecars on this shoot say they started from.
    `only`, by stem, as shoot_overrides takes it."""
    from collections import Counter
    c: Counter = Counter()
    exported = exported_at()
    for name, f in hand_copies(shoot).items():
        if only is not None and Path(name).stem not in only:
            continue
        raw = _raw_of(shoot, name) or (shoot / "raw" / name)
        if is_copy(raw) or not finished(raw, exported):
            continue
        m = re.search(r'AppliedPresetUniqueName = "DEFAULTS/([^"]+)\.preset"', f.read_text(errors="ignore"))
        if m:
            c[m.group(1)] += 1
    return c.most_common(1)[0][0] if c else default


# The version of the measuring code below: photo_features/measure(), FEATS,
# VENUE_FEATS, the linear read off the RAW and the face read off the export.
# Bump it when any of those change what a number MEANS, and every kept
# measurement of the old version is re-measured where its RAW is still here and
# labelled as older where it is not. Do not bump it for a comment or a rename.
#
# Nor for reading the same number more finely. The colour readings moved
# from OpenCV's 8-bit Lab, rounded to whole units, to float Lab
# (presets.cielab), and that was checked against this rule before the
# version was left alone: on 4,000 synthetic skin patches the old and new
# face medians differ by at most 0.58 in a* and b* and by 0.01 on average,
# the hue by 0.3 degrees on a typical face but either way (0.0005 on
# average), and L* by 0.05 on average, an eighth of the old 0.39 step; over
# every 8-bit colour the neutral mask takes in, a* and b* move by under a
# thousandth on average. Same patch, same statistic, read to more
# places, so a row kept from before still means what a new one does, only
# coarser; its skin rows are read again whenever the export changes. The
# largest face's face_*_big and face_lit_L did change patch at the same time
# (presets.skin_patch), and that is not a bump either: the store keeps them,
# but nothing reads them back out of it.
MEASURE_SCHEMA = 1
# Nor for keeping a reading the store did not keep before. These are the
# RAW's readings a finished frame's row carries beside measure(): what the
# exposure rule decides from (clip_any, kept since venue_exposure), and what
# the tone model reads (the RAW's median luminance and highlight headroom,
# linear_measure's; the light level and ISO off its EXIF, exif_light's). Each
# is a new key that means what it means on the frame presets measures today,
# so a row without one is not measured differently, only less: learn_edit
# measures it once more where its RAW is on this Mac (the backfill), and
# where it is not the row keeps teaching with that reading flagged missing.
# The export's own tones (ex_L50, ex_spread; export_tones) are the same kind
# of addition on the export side.
RAW_READINGS = ("clip_any", "frame_Y", "headroom_ev", "lv", "iso")


def sidecar_mark(f: Path) -> str:
    """What his sidecar says, in sixteen characters.

    The store re-measures a frame when this changes, so it has to answer the
    question "is this still the edit I measured" and no other. A hash of the
    bytes and not the modification time: copying a library, restoring one, or
    opening a shoot in PhotoLab moves mtimes about without his changing a
    single slider, and every one of those would otherwise cost a full remeasure
    of everything he has ever finished."""
    import hashlib
    try:
        return hashlib.sha256(f.read_bytes()).hexdigest()[:16]
    except OSError:
        return ""


def export_mark(stem: str) -> str:
    """The same question about his export: size and date, or "" when there is
    none. The export is where the venue's face band and render lift are
    measured from, so a frame he exports again is worth measuring again -
    and that can happen long after the RAW has gone to iCloud."""
    f = export_path(stem)
    if not f:
        return ""
    try:
        st = os.stat(f)
    except OSError:
        return ""
    return f"{st.st_size}:{int(st.st_mtime)}"


def teaching(root: Path = SHOOTS) -> list[dict]:
    """Every finished edit of his under `root`, whether or not its photograph
    is still on this Mac.

    The pipeline writes into Base and leaves Overrides empty; PhotoLab writes
    the photographer's changes into Overrides. So a non-empty Overrides block is
    the photographer's hand, whether or not the file also carries the pipeline's
    Scene keyword: the sidecars the photographer corrected after the pipeline
    wrote them are the ones that show its mistakes, and skipping them hid
    exactly those. The same frame's sidecar can sit in raw/, edit/ and
    cull/picks/ at once (the photographer opens whichever folder); one frame is
    one edit, and which copy is his is hand_copies' answer, not a second rule
    here.

    A frame whose RAW has been archived is listed with `raw=None`. It is his
    finished work either way - the sidecar, the export and the shoot's own
    record of it all stay behind when the RAW goes - and what it taught is kept
    in the measurement store rather than dropped from the next fit."""
    exported = exported_at()
    out: list[dict] = []
    root = Path(root)
    if not root.is_dir():
        return out
    for shoot in sorted(p for p in root.iterdir() if p.is_dir()):
        for name, f in sorted(hand_copies(shoot).items()):
            raw = _raw_of(shoot, name)
            # Where the RAW would be, for the questions that are about the
            # frame rather than about its bytes: whether his spread wrote this
            # sidecar, and whether he finished it.
            probe = raw if raw is not None else shoot / "raw" / name
            if is_copy(probe):
                continue              # one edit carried across a burst is one decision, not many
            if not finished(probe, exported):
                continue
            stem = probe.stem
            pv = next(iter(shoot.glob(f"cull/previews/{stem}.jpg")), None) or \
                 next(iter(shoot.glob(f"**/previews/{stem}.jpg")), None)
            t = f.read_text(errors="ignore")
            fs = final_settings(t, his_choices_only=True)
            # The exposure the photographer settled on, whether the photographer set it or accepted the Base's.
            full = final_settings(t)
            for k in ("ExposureAutoMode", "ExposureBias", "ExposureActive", "WhiteBalanceRawPreset") + NOT_A_LOOK:
                if k in full and k not in fs:
                    fs[k] = full[k]
            out.append({"shoot": shoot, "name": name, "stem": stem, "dop": f, "raw": raw, "preview": pv,
                        "settings": fs, "sidecar": sidecar_mark(f), "export": export_mark(stem)})
    return out


def hand_edits(root: Path = SHOOTS) -> list[tuple[Path, Path, dict]]:
    """The finished edits that can be measured from scratch right now: the raw,
    a preview of it, and where he took it. `teaching` is the whole of his
    finished work; this is the part of it the measuring code can still read."""
    return [(t["raw"], t["preview"], t["settings"]) for t in teaching(root)
            if t["raw"] is not None and t["preview"] is not None]


def photo_features(pv: Path, judge, reader) -> dict | None:
    from presets import measure
    img = cv2.imread(str(pv))
    if img is None:
        return None
    h, w = img.shape[:2]
    if w > 1800:
        img = cv2.resize(img, (1800, int(h * 1800 / w)), interpolation=cv2.INTER_AREA)
    faces = [f for f in judge.detect(img) if f.main]
    return measure(img, faces, reader.subject_box(img))


# ----------------------------------------------------------------- fitting

def _design(ms: list[dict]) -> tuple[np.ndarray, dict]:
    """Features, with what is missing filled by the median and flagged as missing."""
    cols, fill = [], {}
    for f in FEATS:
        vals = [m.get(f) for m in ms]
        present = [v for v in vals if v is not None]
        med = float(np.median(present)) if present else 0.0
        fill[f] = med
        cols.append([float(v) if v is not None else med for v in vals])
        cols.append([0.0 if v is None else 1.0 for v in vals])
    return np.array(cols, dtype=float).T, fill


def _ridge(X: np.ndarray, y: np.ndarray, lam: float = 1.0) -> np.ndarray:
    X1 = np.hstack([X, np.ones((len(X), 1))])
    A = X1.T @ X1 + lam * np.eye(X1.shape[1])
    A[-1, -1] -= lam                       # never penalise the intercept
    return np.linalg.solve(A, X1.T @ y)


def _cv_gain(X: np.ndarray, y: np.ndarray, groups: np.ndarray, folds: int = 5) -> tuple[float, float, float]:
    """Held-out error of the model against simply predicting the median.

    Folds are split by GROUP, never by row. The photographer applies one decision to a whole
    run of frames -- 205 sidecars carry 22 distinct settings between them -- so
    splitting rows at random puts near-copies of a test frame in the training
    set and reports a gain that is not there. Grouping by the decision is the
    difference between measuring generalisation and measuring memorisation."""
    uniq = np.unique(groups)
    rng = np.random.default_rng(0)
    rng.shuffle(uniq)
    em, eb = [], []
    for k in range(folds):
        hold = set(uniq[k::folds].tolist())
        te = np.array([i for i, g in enumerate(groups) if g in hold], dtype=int)
        tr = np.array([i for i, g in enumerate(groups) if g not in hold], dtype=int)
        if len(te) == 0:
            continue
        if len(tr) < 8:
            continue
        mu, sd = X[tr].mean(0), X[tr].std(0)
        sd[sd < 1e-9] = 1.0
        w = _ridge((X[tr] - mu) / sd, y[tr])
        pred = np.hstack([(X[te] - mu) / sd, np.ones((len(te), 1))]) @ w
        em.append(np.abs(pred - y[te]).mean())
        eb.append(np.abs(np.median(y[tr]) - y[te]).mean())
    if not em:
        return 0.0, 0.0, 0.0
    model, base = float(np.mean(em)), float(np.mean(eb))
    return (base - model) / base if base > 1e-9 else 0.0, model, base


def learn(samples: list[tuple[dict, dict]]) -> dict:
    """samples: (photo features, the photographer's settings) -> a model per setting."""
    ms = [m for m, _ in samples]
    X, fill = _design(ms)
    # Frames the photographer gave identical settings are one decision, not many samples.
    sig = [tuple(s.get(k, "") for k in NUMERIC) for _, s in samples]
    order = {v: i for i, v in enumerate(dict.fromkeys(sig))}
    groups = np.array([order[v] for v in sig])
    mu, sd = X.mean(0), X.std(0)
    sd[sd < 1e-9] = 1.0
    out: dict = {"features": FEATS, "fill": fill, "groups": int(len(set(groups.tolist()))), "mu": mu.tolist(), "sd": sd.tolist(),
                 "n": len(samples), "numeric": {}, "categorical": {}}
    Zall = (X - mu) / sd
    for key in NUMERIC:
        rows = [(i, s[key]) for i, (_, s) in enumerate(samples) if key in s]
        vals = []
        for i, v in rows:
            try:
                vals.append((i, float(v)))
            except ValueError:
                pass
        if len(vals) < MIN_SAMPLES:
            continue          # too rarely the photographer's decision to assert as one
        ii = np.array([i for i, _ in vals])
        y = np.array([v for _, v in vals])
        med = float(np.median(y))
        entry = {"median": round(med, 4), "n": len(y), "spread": round(float(y.std()), 4)}
        # A slider the photographer moves on some frames and leaves on others is two decisions:
        # whether, then how much. The median below is the median of the frames
        # the photographer moved it on, and writing it onto every frame is how a -76
        # highlights pull the photographer uses on hot highlights landed on all of a gym. So,
        # where the photographer leaves it often enough to learn from, a logistic on the same
        # measurements says whether the photographer would move it on a frame like this; when
        # it beats the photographer's base rate on unseen groups it is kept, and a frame it
        # says no to keeps the preset's value. When it does not, the key is
        # written only if the photographer moves it on most frames.
        touched = np.zeros(len(samples))
        touched[ii] = 1.0
        entry["touch_rate"] = round(float(touched.mean()), 3)
        if (touched == 0).sum() >= MIN_SAMPLES:
            held = np.zeros(len(samples))
            for g in np.unique(groups):
                te = groups == g
                tr = ~te
                if touched[tr].min() == touched[tr].max():
                    held[te] = touched[tr].mean()
                    continue
                tw, tb = _logistic(Zall[tr], touched[tr])
                held[te] = 1 / (1 + np.exp(-(Zall[te] @ tw + tb)))
            acc = float(((held >= 0.5) == (touched > 0)).mean())
            base = float(max(touched.mean(), 1 - touched.mean()))
            entry.update(touch_accuracy=round(acc, 3), touch_base=round(base, 3))
            if acc > base:
                tw, tb = _logistic(Zall, touched)
                entry.update(touch_w=[round(float(v), 6) for v in tw], touch_b=round(tb, 6))
        if len(y) >= MIN_SAMPLES and y.std() > 1e-6:
            gain, mae, base = _cv_gain(X[ii], y, groups[ii])
            entry.update(gain=round(gain, 3), mae=round(mae, 3), median_mae=round(base, 3))
            if gain > MIN_GAIN:
                w = _ridge((X[ii] - mu) / sd, y)
                entry["w"] = [round(float(x), 6) for x in w]
        out["numeric"][key] = entry
    for key in CATEGORICAL:
        vals = [s[key] for _, s in samples if key in s]
        if len(vals) < MIN_SAMPLES:
            continue          # too rarely the photographer's decision to assert as one
        top = max(set(vals), key=vals.count)
        out["categorical"][key] = {"value": top.strip('"'), "share": round(vals.count(top) / len(vals), 3),
                                   "n": len(vals), "quoted": top.startswith('"')}
    return out


# ----------------------------------------------------------------- using

_CACHE: tuple[Path, int, dict] | None = None


def _wb_row(m: dict, feats: list[str] | None = None) -> list[float]:
    """One frame's white-balance evidence, in the order `feats` names it
    (WB_FEATS when none is given), with a flag for each face value that is
    missing, so a frame with nobody in it is judged on the light alone.

    Over WB_FEATS this is, value for value and in the same order, the row
    every model stored before wb_green existed was fitted on: ten numbers for
    eight names, each of the two face values followed by its flag. It has to
    stay that, because a stored model is ten weights and a mean and spread
    per position, and a row that moved one value would score a frame with
    the weights of another.

    wb_green, where a list names it, has no flag and no fill: it is read off
    the frame or this fails. A fit names it only when every frame carries it
    (_wb_feats), and wb_call asks a frame that lacks it nothing at all, so a
    failure here is a caller that skipped that check, which should be loud
    rather than scored as a frame whose camera read the light as exactly
    daylight-green."""
    fa, fb = m.get("face_a"), m.get("face_b")
    hue = math.degrees(math.atan2(fb, fa)) if fa is not None and fb is not None else None
    fl = m.get("face_L")
    row: list[float] = []
    for f in (WB_FEATS if feats is None else feats):
        if f == "face_hue":
            row += [hue if hue is not None else 0.0, 0.0 if hue is None else 1.0]
        elif f == "face_L":
            row += [fl if fl is not None else 0.0, 0.0 if fl is None else 1.0]
        elif f == WB_GREEN:
            row.append(float(m[WB_GREEN]))
        else:
            row.append(float(m.get(f) or 0.0))
    return row


def _has_green(m: dict) -> bool:
    """Whether this frame carries the camera's green reading: present, and a
    finite number. presets.camera_wb_from_raw stores None where it cannot
    read one (a JPEG, a sensor that is not RGB, a body libraw has no daylight
    balance for), and a row measured before it existed has no key at all;
    neither is a reading."""
    v = m.get(WB_GREEN)
    if v is None or isinstance(v, bool):
        return False
    try:
        return math.isfinite(float(v))
    except (TypeError, ValueError):
        return False


def _wb_feats(ms: list[dict]) -> list[str]:
    """The evidence a white balance fit over these frames may use: WB_FEATS,
    with wb_green beside it only when EVERY one of them carries it (WB_GREEN
    says why nothing less will do). Where it falls back it is the legacy
    list exactly, so a fit that cannot use the green is the fit it always
    was, down to the list it records."""
    if ms and all(_has_green(m) for m in ms):
        return WB_FEATS + [WB_GREEN]
    return WB_FEATS


def _logistic(X: np.ndarray, y: np.ndarray, l2: float = 1.0, iters: int = 3000, lr: float = 0.1) -> tuple[np.ndarray, float]:
    """Logistic regression on standardised inputs, classes balanced, L2 held."""
    w = np.zeros(X.shape[1])
    b = 0.0
    pos = max(y.mean(), 1e-6)
    sw = np.where(y == 1, 0.5 / pos, 0.5 / max(1 - pos, 1e-6))
    for _ in range(iters):
        p = 1 / (1 + np.exp(-(X @ w + b)))
        g = (p - y) * sw
        w -= lr * (X.T @ g / len(y) + l2 * w / len(y))
        b -= lr * g.mean()
    return w, float(b)


def _auc(scores: np.ndarray, y: np.ndarray) -> float:
    sp, sn = scores[y > 0], scores[y == 0]
    if not len(sp) or not len(sn):
        return 0.5
    return float((sp[:, None] > sn[None, :]).mean() + 0.5 * (sp[:, None] == sn[None, :]).mean())


def learn_wb(samples: list[tuple[dict, dict]]) -> dict:
    """Fluo or AsShot, per frame, from what the photographer did on frames that measured like it.

    Held out by scene, never by frame: frames from one scene share the light, and
    a random split would be marking the answer key. The model is written only if
    it beats always-AsShot on scenes it never saw; otherwise the honest answer is
    AsShot, and that is what predict_wb returns.

    The camera's green reading is part of the evidence only when every frame
    this fits on carries it (_wb_feats; WB_GREEN says why). Where one does
    not, the fit is the one this always made, row for row, and "features"
    says which of the two it was: that list is the model's row from then on."""
    kept, ys, grp = [], [], []
    for m, s in samples:
        wb = str(s.get("WhiteBalanceRawPreset", "AsShot")).strip('"')
        if wb not in ("AsShot", "Fluo") or not m.get("kelvin"):
            continue                      # Cloudy once, a typed temperature once: not a decision to learn
        kept.append(m)
        ys.append(1.0 if wb == "Fluo" else 0.0)
        grp.append(m.get("_group", "?"))
    # Chosen over the frames actually fitted on, after the filter above: a
    # JPEG with no kelvin, or a Cloudy frame, is not in the fit, and the
    # green it lacks is not a reason to leave the green out of it.
    feats = _wb_feats(kept)
    rows = [_wb_row(m, feats) for m in kept]
    n = len(rows)
    out: dict = {"n": n, "n_fluo": int(sum(ys)), "features": feats}
    if n < 25 or sum(ys) < WB_MIN_CLASS or n - sum(ys) < WB_MIN_CLASS:
        out["note"] = "too few decisions to learn from"
        return out
    X, y, groups = np.array(rows), np.array(ys), np.array(grp)
    mu, sd = X.mean(0), X.std(0)
    sd[sd < 1e-9] = 1.0
    Z = (X - mu) / sd
    held = np.zeros(n)
    for g in np.unique(groups):
        te = groups == g
        tr = ~te
        if y[tr].min() == y[tr].max():
            held[te] = y[tr].mean()
            continue
        w, b = _logistic(Z[tr], y[tr])
        held[te] = 1 / (1 + np.exp(-(Z[te] @ w + b)))
    auc = _auc(held, y)
    acc = float(((held >= 0.5) == (y > 0)).mean())
    base = float(max(y.mean(), 1 - y.mean()))
    out.update(scenes=int(len(np.unique(groups))), auc=round(auc, 3), accuracy=round(acc, 3), always_asshot=round(base, 3))
    if auc < WB_MIN_AUC or acc <= base:
        out["note"] = "does not beat always-AsShot on unseen scenes; not used"
        return out
    w, b = _logistic(Z, y)
    out.update(mu=mu.tolist(), sd=sd.tolist(), w=[round(float(v), 6) for v in w], b=round(b, 6))
    # The camera-kelvin range of the frames the photographer chose Fluo on
    # (2885-3282 K on the portrait venue): predict_wb writes the name only
    # inside it. The camera's kelvin orders frames the way DxO's scale does
    # and is never written; Fluo at DxO's nominal 4000 K warms a 3054 K
    # frame and would cool a 4145 K one, which is not the decision learned.
    # Read off the frames rather than off row[0]: the same numbers, and they
    # stay the kelvin whichever list the row was built from.
    ks = [float(m["kelvin"]) for m, yy in zip(kept, ys) if yy > 0]
    out["kelvin_range"] = [round(min(ks)), round(max(ks))]
    return out


# --------------------------------- what the gate is given to compare with
#
# Two measurements, made here because this is where the frames are, and read
# by learned.check_edit, which decides. Both are about the white balance,
# which is the one thing the starting edit learns that reaches a sidecar.


def _wb_labelled(samples: list[tuple[dict, dict]]) -> tuple[np.ndarray, np.ndarray, np.ndarray, list[int]]:
    """The frames learn_wb would learn from: rows, labels, scene groups, and
    where each came from in samples.

    The rows are built from the evidence learn_wb would use on these same
    frames (_wb_feats over all of them): with the camera's green where every
    one carries it, without it where any does not. One matrix for every arm
    a caller fits on it, so no arm can be handed evidence another was not."""
    kept, ys, grp, at = [], [], [], []
    for i, (m, s) in enumerate(samples):
        wb = str(s.get("WhiteBalanceRawPreset", "AsShot")).strip('"')
        if wb not in ("AsShot", "Fluo") or not m.get("kelvin"):
            continue
        kept.append(m)
        ys.append(1.0 if wb == "Fluo" else 0.0)
        grp.append(m.get("_group", "?"))
        at.append(i)
    feats = _wb_feats(kept)
    rows = [_wb_row(m, feats) for m in kept]
    return np.array(rows), np.array(ys), np.array(grp), at


def _wb_heldout(X: np.ndarray, y: np.ndarray, groups: np.ndarray,
                pool: np.ndarray, ev: np.ndarray) -> np.ndarray:
    """learn_wb's own protocol, with the training pool named separately from
    the frames being scored: for each scene group in ev, fit on pool minus
    that group and call the group. Every call is on a scene the fit never
    saw, whichever pool it was."""
    out = np.full(len(y), np.nan)
    mu, sd = X[pool].mean(0), X[pool].std(0)
    sd[sd < 1e-9] = 1.0
    Z = (X - mu) / sd
    for g in np.unique(groups[ev]):
        te = ev & (groups == g)
        tr = pool & (groups != g)
        if not tr.any() or y[tr].min() == y[tr].max():
            out[te] = y[tr].mean() if tr.any() else 0.0
            continue
        w, b = _logistic(Z[tr], y[tr])
        out[te] = 1 / (1 + np.exp(-(Z[te] @ w + b)))
    return out


def wb_against_live(samples: list[tuple[dict, dict]], shoots_of: list[Path], live: dict | None) -> dict | None:
    """The candidate's white balance against the one in use, ON THE SAME
    FRAMES, IN THE SAME FOLDS, BY THE SAME PROTOCOL, with only the training
    pool changing.

    Why this and not the obvious thing. Each model reports an accuracy from
    its own fit, on its own frames, in its own scene folds, and for a while
    the gate read those two numbers against each other. They are two
    different exams. The one in use was fitted on 527 frames of which 62%
    came off a single shoot that is 99.7% one class, so its exam is easy and
    its headline high; a candidate that has since learned three more shoots
    sits a harder exam and reads lower for it. Under that comparison a
    candidate can look worse for having seen more of his work, which is the
    opposite of what the gate is for.

    The other tempting comparison is worse. Both models are frozen, so it is
    easy to run each over the candidate's frames and count. But the one in
    use was FITTED on most of those frames and the candidate on all of them:
    every such score is in-sample, and in-sample scores flatter whichever
    model memorised more. Pairing a frozen model against a cross-validated
    one is the same mistake wearing a different hat. There is no set of
    frames on which both of these two are out of sample, because the
    candidate's pool contains the one in use's - so no honest comparison of
    the two FROZEN models exists, and one has to be built.

    What is real, and what this measures, is the only difference there
    actually is between them: the training pool. So both arms are refitted
    here. The frames scored are the ones the model in use was taught on (the
    only frames both pools contain); the folds are the same scene groups for
    both arms; both arms are held out by scene, so neither is ever asked
    about a scene it was fitted on. One arm trains on the pool behind the
    model in use, the other on the candidate's. The difference is then
    attributable to the pool and to nothing else, and it is paired frame by
    frame, so the two counts below say whether the difference is one real
    disagreement or noise moving in both directions.

    WHICH FRAMES TAUGHT THE MODEL IN USE. Its own dataset record names the
    shoots it was fitted on, exactly, and that is read first. Only where
    there is none - versions older than the dataset record carry no list of
    shoots, and his live model is one of them - does this fall back to its
    venues, and the fallback is not the same question. A venue is a PLACE:
    frames belong to it by where they were shot, not by whether the model in
    use ever saw them. It is right today because each of his venues was
    taught by one shoot and no venue has been shot in twice since. The next
    time he shoots a room the model in use already knows, that shoot's frames
    would be counted as having taught it, and the "live pool" arm would be
    trained on frames the live model never saw - which lends the live arm the
    candidate's own advantage and biases the comparison against the
    candidate, in the one clause that exists to hold a candidate back.

    THE EVIDENCE BOTH ARMS SEE. One matrix (_wb_labelled), so both arms are
    fitted on the same columns: the camera's green reading where every
    labelled frame here carries it, which is exactly when the candidate
    itself was fitted with it, and the legacy eight where any does not. The
    one in use may never have had the green - every model before it did not
    - and its arm is lent it all the same. That is deliberate, and it is the
    same rule as above: this measures what the POOL is worth, and a column
    that only one arm could see would be a second difference folded into
    the first. Whether the green earns its place is asked where the
    candidate is fitted, against always-AsShot on scenes it never saw
    (learn_wb), and per venue where it ships (wb_where_used). Here, lending
    it to the live arm is what keeps the green's worth, or its cost, from
    being credited to the pool.

    Returns None when the comparison cannot be made honestly - nothing in
    use, nothing recorded on it saying what taught it, or none of its frames
    still here.
    """
    shot = [str(s.get("shoot") or "") for s in (((live or {}).get("dataset") or {}).get("shoots") or [])]
    taught = {s for s in shot if s}
    ven = ((live or {}).get("venues") or {}).get("shoots") or {}
    if not taught and not ven:
        return None
    X, y, groups, at = _wb_labelled(samples)
    if not len(y):
        return None
    taught_live = np.array([shoots_of[i].name in taught if taught
                            else any(v in ven for v in venue_ids(shoots_of[i])) for i in at])
    if not taught_live.any() or taught_live.all():
        # All of them, or none: either the candidate learned nothing the one
        # in use had not, or the two pools share no frame. Neither is a
        # comparison of pools.
        return None
    every = np.ones(len(y), bool)
    was = _wb_heldout(X, y, groups, taught_live, taught_live)
    now = _wb_heldout(X, y, groups, every, taught_live)
    ev = taught_live
    was_ok, now_ok = (was[ev] >= 0.5) == (y[ev] > 0), (now[ev] >= 0.5) == (y[ev] > 0)
    return {"frames": int(ev.sum()), "scenes": int(len(np.unique(groups[ev]))),
            "now": round(float(was_ok.mean()), 3), "new": round(float(now_ok.mean()), 3),
            "always_asshot": round(float(max(y[ev].mean(), 1 - y[ev].mean())), 3),
            "now_right_new_wrong": int((was_ok & ~now_ok).sum()),
            "new_right_now_wrong": int((now_ok & ~was_ok).sum())}


def wb_where_used(mod: dict, samples: list[tuple[dict, dict]], shoots_of: list[Path]) -> list[dict]:
    """The candidate's white balance on each venue it would actually be asked
    about, against leaving every frame as the camera shot it.

    A model can clear every threshold pooled and still be worse than nothing
    where it ships. Tonight's candidate did: 0.889 against 0.850 over all 674
    labelled frames, and on the venue it had just learned - 9 Fluo decisions,
    one over WB_MIN_CLASS, which is where presets stops leaving the white
    balance alone and starts asking - right on 21 of that venue's 38 finished
    frames where AsShot on every one is right on 29.

    Scored in sample, deliberately: these are frames the candidate was fitted
    on, which flatters it. That makes a failure here conclusive rather than
    arguable - a model that cannot beat a constant on frames it has already
    seen will not beat it on frames it has not.

    Which venues those are is presets.consults_wb's question, asked THERE and
    answered once. This used to ask its own version of it, reading wb_counts
    and nothing else, and a venue carried over from an older build has no
    wb_counts at all: presets consulted the model on it and this skipped it,
    so the one clause that exists to catch a venue the model gets wrong was
    blind to exactly the venues nobody had counted.

    Each row carries the shoots that taught the venue, because the row
    becomes a sentence he reads, and two of his four venues have no label of
    their own - venue_label falls back to the words "a finished shoot", which
    tells him nothing he can act on."""
    wb = (mod or {}).get("wb") or {}
    if "w" not in wb:
        return []
    from presets import consults_wb
    out = []
    for vid, e in (((mod.get("venues") or {}).get("shoots")) or {}).items():
        if not consults_wb(e):
            continue                       # presets leaves this venue's white balance alone
        n = right = asshot = 0
        names: list[str] = []
        for (m, s), sh in zip(samples, shoots_of):
            if vid not in venue_ids(sh):
                continue
            truth = str(s.get("WhiteBalanceRawPreset", "AsShot")).strip('"')
            if truth not in ("AsShot", "Fluo") or not m.get("kelvin"):
                continue
            n += 1
            # Scored as what presets would write: a model with nothing to say
            # leaves the frame as the camera shot it (presets.frame_tones writes
            # a name only when there is one). Every frame here has a kelvin, and a
            # model fitted with the camera's green was fitted on these same
            # frames only because each carries it, so "nothing to say" does not
            # happen on the frames learn_edit hands this; the reading is here so
            # the count stays the sidecars' count if it ever does.
            right += (wb_call(wb, m) or "AsShot") == truth
            asshot += truth == "AsShot"
            if sh.name not in names:
                names.append(sh.name)
        if n:
            out.append({"venue": vid, "label": venue_words(e, vid, names),
                        "shoots": sorted(names), "frames": n, "right": right, "asshot": asshot})
    return out


def venue_words(entry: dict, vid: str, shoots: list[str] | None = None) -> str:
    """What to call this venue in a sentence he reads.

    His own label where he gave one. Where he did not, venue_label answers
    "a finished shoot" for every unnamed shoot in the library, and a reason
    reading `on "a finished shoot" it would set the white balance worse than
    leaving it alone` names nothing he can open - two of his four venues
    carry that fallback, so the sentence could not even say which of them it
    meant. The shoots that taught it are named instead: those are folders he
    can go and look in. The id is the last resort and should not be reachable
    while a venue is learned from frames.

    Two ways to know those shoots, and the caller's wins. wb_where_used has
    THIS run's frames in front of it and derives the names from them, which
    is what its own numbers were counted over - the row says "right on 21 of
    that shoot's 38 finished frames", so the name has to be the shoot those
    38 came from. Every other caller has an entry and nothing else, and reads
    the shoot learn_venues recorded on it.

    The recorded list is not a replacement for deriving. A venue carried from
    a build older than that record has none - _carry_venues keeps an entry
    exactly as it was learned - and that is precisely the venue presets
    consults and the gate now checks, so the derivation stays where the
    frames are."""
    label = str(entry.get("label") or "").strip()
    if label and label != UNNAMED_VENUE:
        return label
    names = sorted(shoots or [str(n) for n in (entry.get("shoots") or []) if str(n).strip()])
    if not names:
        # The id, deliberately, and never `label`: by here label is either
        # empty or the fallback itself, and returning it would put the very
        # words this exists to keep out of the sentence back into it. A hash
        # says nothing either, but it says nothing HONESTLY, and it cannot be
        # mistaken for one of the other unnamed venues.
        return vid
    return names[0] if len(names) == 1 else " and ".join((", ".join(names[:-1]), names[-1]))


def wb_call(wb: dict, m: dict) -> str | None:
    """What a white balance model - any version of it - would write on this
    frame, or None when it has nothing to say. predict_wb is this on the
    model in use; the gate needs it on a model that is not in use yet."""
    if "w" not in wb or not m.get("kelvin"):
        # No kelvin (a JPEG, a RAW libraw could not read): the strongest input
        # is missing, and standardised as 0 it reads as light warmer than any
        # the photographer shot, which called Fluo at p=1.0 whatever the frame showed.
        return None
    # The row is the one THIS model was fitted on, read off the model and
    # never assumed: a model stored before the camera's green existed names
    # the legacy eight (or, older still, names nothing) and is scored on
    # exactly the ten numbers it always was; one fitted with the green is
    # scored with it.
    feats = list(wb.get("features") or WB_FEATS)
    if any(f not in WB_FEATS and f != WB_GREEN for f in feats):
        # Evidence this code does not know how to read, from some other
        # version of it. A row built by guessing at it would be scored with
        # weights that mean something else.
        return None
    if WB_GREEN in feats and not _has_green(m):
        # Fitted with the green, asked about a frame that has none (measured
        # before it was kept, or off a RAW it cannot be read from). The same
        # case as no kelvin above: filled with anything, it is a reading the
        # camera never made, so the model says nothing, and the frame is left
        # as the camera shot it, which is what presets does with nothing.
        return None
    rng = wb.get("kelvin_range")
    if rng and not (float(rng[0]) <= float(m["kelvin"]) <= float(rng[1])):
        # Outside the camera-kelvin range of the frames the name was chosen
        # on (learn_wb), the model is not evidence: it has never seen the
        # photographer choose there, and the finished action venue at
        # 4100-4300 K sits well above the 2885-3282 K he chose Fluo in.
        return "AsShot"
    z = (np.array(_wb_row(m, feats)) - np.array(wb["mu"])) / np.array(wb["sd"])
    p = 1 / (1 + math.exp(-float(z @ np.array(wb["w"]) + wb["b"])))
    return "Fluo" if p >= 0.5 else "AsShot"


def predict_wb(m: dict) -> str | None:
    """\"Fluo\" or \"AsShot\" for this frame, or None when nothing has been learned."""
    return wb_call(((load() or {}).get("wb") or {}), m)


# ------------------------------------------------ the exposure type, per venue

def expo_mode(s: dict) -> str:
    """The exposure type he settled on in one finished sidecar, in the three
    the pipeline writes. Slight recovery is counted as Medium: DxO's Slight is
    the gentler neighbour of Medium, and the pipeline writes neither Slight
    nor anything between. '' when the sidecar says nothing about it."""
    mode = str(s.get("ExposureAutoMode", "")).strip('"')
    if mode == "SlightHighlightRecovery":
        mode = "MediumHighlightRecovery"
    if mode not in EXPO_MODES:
        # A bias with no mode written is a manual bias on the preset's default.
        mode = "Manual" if str(s.get("ExposureBias", "")).strip() not in ("", "0", "0.0") else ""
    return mode


def _expo_row(m: dict) -> list[float]:
    """One frame's evidence, off the camera JPEG the way presets.measure reads
    it, with a flag per value that is missing so a frame with nobody in it is
    judged on the light alone."""
    row: list[float] = []
    for f in EXPO_FEATS:
        v = m.get(f)
        row += [float(v) if v is not None else 0.0, 0.0 if v is None else 1.0]
    return row


def _expo_fit(Z: np.ndarray, ys: list[str]) -> dict:
    """Two decisions in sequence: by hand or by DxO; and if DxO, strong or
    medium. A decision with one side only is answered by that side."""
    y1 = np.array([1.0 if y == "Manual" else 0.0 for y in ys])
    auto = y1 == 0
    y2 = np.array([1.0 if y == "StrongHighlightRecovery" else 0.0 for y in ys])
    out: dict = {}
    if y1.min() == y1.max():
        out["manual"] = bool(y1[0])
    else:
        w, b = _logistic(Z, y1)
        out["w_manual"], out["b_manual"] = [round(float(v), 6) for v in w], round(b, 6)
    if not auto.any():
        out["strong"] = False
    elif y2[auto].min() == y2[auto].max():
        out["strong"] = bool(y2[auto][0])
    else:
        w, b = _logistic(Z[auto], y2[auto])
        out["w_strong"], out["b_strong"] = [round(float(v), 6) for v in w], round(b, 6)
    return out


def _expo_call(fit: dict, z: np.ndarray) -> str:
    if "manual" in fit:
        manual = fit["manual"]
    else:
        manual = float(z @ np.array(fit["w_manual"]) + fit["b_manual"]) >= 0
    if manual:
        return "Manual"
    if "strong" in fit:
        strong = fit["strong"]
    else:
        strong = float(z @ np.array(fit["w_strong"]) + fit["b_strong"]) >= 0
    return "StrongHighlightRecovery" if strong else "MediumHighlightRecovery"


def _sign_p(wins: int, losses: int) -> float:
    """One-sided sign test: the chance of at least `wins` of the disagreements
    going the fit's way if each were a coin toss."""
    n = wins + losses
    if n == 0:
        return 1.0
    return float(sum(math.comb(n, k) for k in range(wins, n + 1)) / 2 ** n)


def rule_mode(m: dict, prefer: str | None) -> str | None:
    """What presets.exposure_mode writes on a finished frame, replayed from
    what the measurement store kept of it. None where the sensor reading it
    needs was never kept (a frame measured before the store held `clip_any`,
    whose photograph is no longer on this Mac): the rule's answer there is
    unknown, and an unknown is not scored as either."""
    from presets import exposure_mode
    return exposure_mode({"clip_any": m.get("_clip_any"), "face_Y": m.get("_face_Y"),
                          "subject_Y": m.get("_subject_Y")}, prefer)


def expo_held_words(x: dict) -> str:
    """What a venue's fit was held out by, in the words the page and the note
    in a sidecar use: 'scenes' as a rule, 'bursts' only where the cull put
    the venue in too few scenes to hold any out."""
    return "bursts" if (x or {}).get("held_out") == "burst" else "scenes"


def expo_beats(x: dict) -> tuple[bool, str]:
    """Whether a venue's counts say its own fit has earned the right to
    replace the rule there, from the counts alone, and if not, why.

    The one statement of the bar, read by venue_exposure when it decides and
    by learned.check_edit when it checks a candidate that arrived by any
    door: right on more frames than the rule replayed on the same frames,
    right on more than the venue's commonest type, and each of those two
    wins by more than chance (a one-sided sign test over the frames the two
    disagree on, at EXPO_P). A count that is missing is a failure, not a
    pass: a fit measured against nothing has not beaten anything."""
    need = ("frames", "fit_right", "rule_right", "commonest_right")
    if any(x.get(k) is None for k in need):
        return False, "it carries no count of the rule and of its commonest type on the same frames"
    vs = x.get("vs") or {}
    for base in ("rule", "commonest"):
        c = vs.get(base) or {}
        if c.get("wins") is None or c.get("losses") is None:
            return False, f"it carries no count of the frames it wins and loses against {EXPO_BASES[base]}"
    fit, rule, com = int(x["fit_right"]), int(x["rule_right"]), int(x["commonest_right"])
    if fit <= rule:
        return False, f"it is right on {fit}, where the rule is right on {rule}"
    if fit <= com:
        return False, f"it is right on {fit}, where always {EXPO_WORDS.get(x.get('commonest'), 'its commonest type')} is right on {com}"
    for base in ("rule", "commonest"):
        c = vs[base]
        if _sign_p(int(c["wins"]), int(c["losses"])) >= EXPO_P:
            return False, (f"it beats {EXPO_BASES[base]} on too few frames to be sure "
                           f"({int(c['wins'])} won, {int(c['losses'])} lost)")
    return True, ""


def _held_groups(ms: list[dict]) -> tuple[list[str], str]:
    """The groups a venue's frames are held out by: scenes, whenever the cull
    put the venue in at least EXPO_MIN_GROUPS of them, because a burst's
    neighbours in the same scene share its light and a fit tested on them has
    seen the answer. Bursts only where there are too few scenes to hold any
    out, and the page says 'bursts' when that is what was done."""
    scenes = [str(m.get("_scene") or "") for m in ms]
    if len({s for s in scenes if s}) >= EXPO_MIN_GROUPS:
        # A frame the cull left out of every scene is held out with its burst.
        return [s or f"burst {m.get('_burst') or '?'}" for s, m in zip(scenes, ms)], "scene"
    return [str(m.get("_burst") or m.get("_scene") or "?") for m in ms], "burst"


def venue_exposure(samples: list[tuple[dict, dict]], prefer: str | None) -> dict:
    """One venue's own exposure type, fitted on that venue's finished frames
    only, and whether it has earned the right to replace the rule there.

    Held out by scene WITHIN the venue (by burst only where the cull put the
    venue in fewer than EXPO_MIN_GROUPS scenes, and then said so): every
    frame is called by a fit that never saw its scene, standardised on the
    frames that fit was trained on and nothing else. That call is scored
    against his own type on the frame, on the same frames as two things it
    would replace - the venue's commonest type, and the rule
    (presets.exposure_mode, with this venue's `prefer`) replayed on the
    sensor readings the store kept. It is used only when expo_beats says so.

    Used, it applies to the shoot that taught it and nowhere else
    (presets.frame_tones): a shoot that merely measures like this venue has
    never been scored against it.

    Every number is a count of his frames, so the page can say "right on 164
    of 198" rather than a decimal, and the gate (learned.check_edit) reads
    the same counts back."""
    rows, ys, ms, idx = [], [], [], []
    for i, (m, s) in enumerate(samples):
        mode = expo_mode(s)
        if not mode:
            continue
        rows.append(_expo_row(m))
        ys.append(mode)
        ms.append(m)
        idx.append(i)
    n = len(ys)
    counts = {k: ys.count(k) for k in EXPO_MODES}
    grp, held_out = _held_groups(ms)
    out: dict = {"frames": n, "counts": counts, "groups": len(set(grp)), "held_out": held_out,
                 "prefer": prefer, "used": False}
    if not n:
        out["why"] = "no exposure type on its finished frames"
        return out
    commonest = max(EXPO_MODES, key=lambda k: counts[k])
    out["commonest"] = commonest
    out["commonest_right"] = counts[commonest]
    rule = [rule_mode(samples[i][0], prefer) for i in idx]
    unknown = sum(1 for r in rule if r is None)
    out["rule_frames"] = n - unknown
    out["rule_right"] = sum(1 for r, y in zip(rule, ys) if r is not None and r == y) if not unknown else None
    words = expo_held_words(out)
    if n < EXPO_MIN_FRAMES or out["groups"] < EXPO_MIN_GROUPS:
        g = out["groups"]
        out["why"] = (f"{n} finished frame{'' if n == 1 else 's'} in {g} {words[:-1] if g == 1 else words} is too "
                      f"few to fit it on its own (it needs {EXPO_MIN_FRAMES} in {EXPO_MIN_GROUPS})")
        return out
    X = np.array(rows)
    groups = np.array(grp)
    held: list[str] = [""] * n
    for g in np.unique(groups):
        te = np.where(groups == g)[0]
        tr = groups != g
        # Standardised on the training frames only: scaled on every frame,
        # the held-out ones would be part of the fit that is scored on them.
        mu, sd = X[tr].mean(0), X[tr].std(0)
        sd[sd < 1e-9] = 1.0
        fit = _expo_fit((X[tr] - mu) / sd, [y for y, t in zip(ys, tr) if t])
        for k in te:
            held[k] = _expo_call(fit, (X[k] - mu) / sd)
    right = [h == y for h, y in zip(held, ys)]
    out["fit_right"] = int(sum(right))
    base_right = {"commonest": [y == commonest for y in ys]}
    if not unknown:
        base_right["rule"] = [r == y for r, y in zip(rule, ys)]
    out["vs"] = {}
    for base, br in base_right.items():
        wins = sum(1 for a, b in zip(right, br) if a and not b)
        losses = sum(1 for a, b in zip(right, br) if b and not a)
        out["vs"][base] = {"wins": wins, "losses": losses, "p": round(_sign_p(wins, losses), 5)}
    always = EXPO_WORDS[commonest]
    if unknown:
        out["why"] = (f"the rule it would replace cannot be replayed on {unknown} of its {n} finished frames: "
                      f"they were measured before the sensor reading it needs was kept")
        out["rule_unknown"] = unknown
        return out
    ok, short = expo_beats(out)
    said = (f"its own fit is right on {out['fit_right']} of {n} on {words} it had not seen, against "
            f"{out['rule_right']} for the rule and {out['commonest_right']} for always {always}")
    if not ok:
        out["why"] = said + (f": {short}" if "too few frames to be sure" in short else "")
        return out
    mu, sd = X.mean(0), X.std(0)
    sd[sd < 1e-9] = 1.0
    out.update(used=True, features=EXPO_FEATS, mu=[round(float(v), 6) for v in mu],
               sd=[round(float(v), 6) for v in sd], fit=_expo_fit((X - mu) / sd, ys), why=said)
    return out


def predict_exposure(entry: dict | None, m: dict) -> str | None:
    """The venue's own exposure type for one frame, or None where the rule
    decides: the venue has no fit, or its fit did not earn its place.

    `entry` is the shoot's OWN venue: presets.frame_tones asks only when the
    venue it found is the shoot itself, never one the shoot merely measures
    inside the spread of. A venue's answer was scored on that venue's own
    frames and nothing else, and borrowed for a venue it had not seen it lost
    to a constant on 3 of 4."""
    e = ((entry or {}).get("exposure") or {})
    if not e.get("used") or not e.get("fit"):
        return None
    try:
        z = (np.array(_expo_row(m)) - np.array(e["mu"])) / np.array(e["sd"])
        return _expo_call(e["fit"], z)
    except (KeyError, ValueError, TypeError):
        return None


# ------------------------------------------------ brightness and contrast, per frame
#
# "These need to be dynamic based on ML models not just hard constants." The
# exposure and the tone curve used to aim every frame at a constant: a
# midtone L* by light level (presets.TARGET_BY_LV, a quarter stop darker in
# daylight), a face at the band's middle capped at L* 58, an S-curve of 0.10
# in daylight and 0.03 in low light. Those constants are inferences from the
# literature and from FirstEditMobile, and his finished exports are a direct
# record of where he actually puts each of the three on each frame. So each
# is now a small model of what he delivered, fitted on the readings the
# store keeps of his exports, and each replaces its constant only where it
# predicts his exports better than the constant does on shoots it had not
# seen, by a margin and by more than chance. The constants stay as the
# fallback prior; every limit on how far a frame may move stays as it is.
#
# Three targets, each one number per frame, read off the export:
#   L50          -- the median L* of the whole export (where his midtones sit);
#   face_L       -- the largest face's L* in the export (export_face_L_one,
#                   the reading the venues' face band was always made from);
#   spread_ratio -- the export's L* p95 - p5 over the camera JPEG's: how much
#                   wider (or flatter) he leaves the tones than the camera did,
#                   which is what the S-curve's amplitude is solved for.
# The evidence is what presets has on a new frame before anything is
# written: the light (LV, ISO, from EXIF), the camera JPEG (its median, its
# spread, its clipping, whether there is a face and how light it is) and the
# RAW (its median luminance, its highlight headroom). presets.tone_evidence
# builds it both here, from the store, and there, from the frame, so the two
# cannot mean different things.
TONE_TARGETS = ("L50", "face_L", "spread_ratio")
TONE_BASE = ["lv", "log2_iso", "frame_L", "range", "clip", "face_L", "log2_frame_Y", "headroom_ev"]
# Each reading and whether it was there: a frame with no face, or one whose
# RAW or EXIF was never read, is filled with the fit's median and flagged,
# so it is judged on what it has (face_L_known is "has a face").
TONE_FEATS = [f for b in TONE_BASE for f in (b, f"{b}_known")]
# Too few frames and a held-out MAE is noise; too few groups and "held out"
# means one shoot scored by a fit on one other.
TONE_MIN_FRAMES = 30
TONE_MIN_GROUPS = 3
# The bar, both halves of it. The held-out MAE must be at least 10% under
# the rule's on the same frames (a model that is only as good as the
# constants is a model nobody can read replacing a number anybody can), AND
# closer to his export than the rule on more frames than chance would give
# (the one-sided sign test venue_exposure uses, at the same 0.05): a lower
# mean can come from a few frames where the rule is badly wrong while the
# model is worse on most of them, and that is not a better target for the
# next frame.
TONE_MIN_GAIN = 0.10
TONE_P = 0.05
# How much worse than the one in use, on the frames that taught the one in
# use, a candidate's tone model may be before the gate holds it
# (learned._check_tone): the same frames and folds for both arms, so the
# tolerance is only for the refit's own jitter.
TONE_LIVE_TOL = 0.05
# What a prediction may be, whatever the weights say: an export's median
# between near-black and near-white, a face in the same, a spread between
# half and twice the camera's. The frame's own guards (headroom, noise,
# the band, TONE_C_MAX) bound it again downstream; these only stop a
# weight extrapolated off the edge of the data from naming an absurd target.
TONE_CLAMP = {"L50": (5.0, 95.0), "face_L": (5.0, 95.0), "spread_ratio": (0.5, 2.0)}
TONE_WORDS = {"L50": "brightness", "face_L": "face lightness", "spread_ratio": "contrast"}


def _tone_raw(ev: dict) -> dict:
    """The evidence in the units the model reads: stops for ISO and the RAW's
    luminance (a doubling is a doubling wherever it starts), the rest as
    measured. None where the reading is missing."""
    iso, fy = ev.get("iso"), ev.get("frame_Y")
    return {"lv": ev.get("lv"), "log2_iso": math.log2(iso) if iso and iso > 0 else None,
            "frame_L": ev.get("frame_L"), "range": ev.get("range"), "clip": ev.get("clip"),
            "face_L": ev.get("face_L"), "log2_frame_Y": math.log2(fy) if fy and fy > 0 else None,
            "headroom_ev": ev.get("headroom_ev")}


def _tone_row(ev: dict, fill: dict) -> list[float]:
    """One frame's row over TONE_FEATS, missing values at the fit's median
    and flagged."""
    raw = _tone_raw(ev)
    row: list[float] = []
    for b in TONE_BASE:
        v = raw.get(b)
        row += [float(v) if v is not None else float(fill.get(b, 0.0)), 0.0 if v is None else 1.0]
    return row


def _tone_clamp(key: str, v: float) -> float:
    lo, hi = TONE_CLAMP[key]
    return min(hi, max(lo, float(v)))


def _tone_target(m: dict, key: str) -> float | None:
    """His delivered value of one target on one finished frame, or None."""
    if key == "L50":
        v = m.get("_ex_L50")
        return None if v is None else float(v)
    if key == "face_L":
        v = m.get("_ex_face_L")
        return None if v is None else float(v)
    sp, rng = m.get("_ex_spread"), (m.get("_tone") or {}).get("range")
    if sp is None or rng is None or float(rng) <= 1.0:
        return None
    return float(sp) / float(rng)


def _tone_scored(ev: dict, key: str) -> bool:
    """Whether presets would use this target on this frame, which is where a
    model of it is scored: the midtones only decide a frame with no face on
    the RAW (a face frame is exposed for its face); a face on every frame
    that has one; the spread wherever a curve is written at all (not past
    presets.TONE_WIDE)."""
    from presets import TONE_WIDE
    if key == "L50":
        return not ev.get("face_Y")
    if key == "spread_ratio":
        rng = ev.get("range")
        return rng is not None and float(rng) <= TONE_WIDE
    return True


def _tone_design(samples: list[tuple[dict, dict]], shoots_of: list[Path], key: str) -> dict:
    """Every finished frame that carries this target, as the model sees it:
    rows, his values, the rule's values (presets.rule_tone), which frames it
    is scored on, and the shoot and scene of each."""
    from presets import rule_tone
    evs, ys, base, scored, shoot, scene = [], [], [], [], [], []
    for (m, _s), sh in zip(samples, shoots_of):
        y = _tone_target(m, key)
        ev = m.get("_tone")
        if y is None or not ev:
            continue
        r = rule_tone(ev).get(key)
        evs.append(ev)
        ys.append(y)
        base.append(np.nan if r is None else float(r))
        scored.append(r is not None and _tone_scored(ev, key))
        shoot.append(Path(sh).name)
        scene.append(str(m.get("_scene") or m.get("_burst") or Path(sh).name))
    fill = {}
    raws = [_tone_raw(ev) for ev in evs]
    for b in TONE_BASE:
        vals = [r[b] for r in raws if r.get(b) is not None]
        fill[b] = round(float(np.median(vals)), 6) if vals else 0.0
    X = np.array([_tone_row(ev, fill) for ev in evs], dtype=float).reshape(len(evs), len(TONE_FEATS))
    return {"X": X, "y": np.array(ys, dtype=float), "base": np.array(base, dtype=float),
            "scored": np.array(scored, dtype=bool), "shoot": np.array(shoot), "scene": np.array(scene),
            "fill": fill}


def _tone_groups(d: dict) -> tuple[np.ndarray, str]:
    """Held out BY SHOOT: a shoot is a venue and its light, and a fit asked
    about a frame from a shoot it was trained on has seen that room's answer.
    With fewer than TONE_MIN_GROUPS shoots, by scene (the cull's scene within
    a shoot, one light and one moment), and the record says so."""
    if len(set(d["shoot"].tolist())) >= TONE_MIN_GROUPS:
        return d["shoot"], "shoot"
    return d["scene"], "scene"


def _tone_heldout(X: np.ndarray, y: np.ndarray, groups: np.ndarray, pool: np.ndarray, ev: np.ndarray,
                  key: str) -> np.ndarray:
    """venue_exposure's protocol for a number: every frame in `ev` predicted
    by a ridge fitted on `pool` less that frame's group, standardised on
    those training frames only. NaN where too little is left to fit on."""
    out = np.full(len(y), np.nan)
    for g in np.unique(groups[ev]):
        te = ev & (groups == g)
        tr = pool & (groups != g)
        if tr.sum() < 8:
            continue
        mu, sd = X[tr].mean(0), X[tr].std(0)
        sd[sd < 1e-9] = 1.0
        w = _ridge((X[tr] - mu) / sd, y[tr])
        pred = np.hstack([(X[te] - mu) / sd, np.ones((int(te.sum()), 1))]) @ w
        out[te] = [_tone_clamp(key, v) for v in pred]
    return out


def _tone_one(d: dict, key: str) -> dict:
    """One target: fitted, held out, scored against the rule, and kept only
    if it clears the bar (TONE_MIN_GAIN and TONE_P)."""
    n = len(d["y"])
    groups, held_by = _tone_groups(d)
    shoots = sorted(set(d["shoot"].tolist()))
    out: dict = {"features": TONE_FEATS, "n": n, "shoots": len(shoots), "shoot_names": shoots,
                 "held_out": held_by, "groups": int(len(set(groups.tolist()))), "used": False}
    scored = d["scored"]
    if n < TONE_MIN_FRAMES or int(scored.sum()) < TONE_MIN_FRAMES:
        out["why"] = (f"{n} finished frame{'' if n == 1 else 's'} carry it, {int(scored.sum())} where it would "
                      f"decide: too few to learn from (it needs {TONE_MIN_FRAMES})")
        return out
    if out["groups"] < TONE_MIN_GROUPS:
        out["why"] = (f"its frames come from {out['groups']} {held_by}{'' if out['groups'] == 1 else 's'}: too few "
                      f"to hold any out (it needs {TONE_MIN_GROUPS})")
        return out
    X, y, base = d["X"], d["y"], d["base"]
    held = _tone_heldout(X, y, groups, np.ones(n, bool), scored, key)
    ok = scored & ~np.isnan(held)
    if int(ok.sum()) < TONE_MIN_FRAMES:
        out["why"] = f"only {int(ok.sum())} of its frames could be held out: too few to judge it"
        return out
    em, eb = np.abs(held[ok] - y[ok]), np.abs(base[ok] - y[ok])
    mae, bmae = float(em.mean()), float(eb.mean())
    wins, losses = int((em < eb).sum()), int((em > eb).sum())
    p = _sign_p(wins, losses)
    out.update(scored=int(ok.sum()), mae=round(mae, 4), baseline_mae=round(bmae, 4),
               wins=wins, losses=losses, p=round(p, 5))
    unit = "" if key == "spread_ratio" else "L* "
    fmt = (lambda v: f"{v:.2f}") if key == "spread_ratio" else (lambda v: f"{v:.1f}")
    said = (f"on {int(ok.sum())} frames, each predicted by a fit that had not seen its {held_by}, it is off his "
            f"exports by {unit}{fmt(mae)} where the rule is off by {unit}{fmt(bmae)}, closer on {wins} and further "
            f"on {losses}")
    if mae > (1.0 - TONE_MIN_GAIN) * bmae:
        out["why"] = said + f": not {TONE_MIN_GAIN:.0%} better than the rule, so the rule stands"
        return out
    if p >= TONE_P:
        out["why"] = said + f": closer on too few frames to be sure (sign test p {p:.3f}), so the rule stands"
        return out
    mu, sd = X.mean(0), X.std(0)
    sd[sd < 1e-9] = 1.0
    w = _ridge((X - mu) / sd, y)
    out.update(used=True, why=said, fill=d["fill"], mu=[round(float(v), 6) for v in mu],
               sd=[round(float(v), 6) for v in sd], w=[round(float(v), 6) for v in w[:-1]],
               b=round(float(w[-1]), 6))
    return out


def learn_tone(samples: list[tuple[dict, dict]], shoots_of: list[Path]) -> dict:
    """Per-frame brightness, face lightness and contrast, learned from his
    finished exports: {target: {mu, sd, w, b, fill, features, n, shoots,
    mae, baseline_mae, wins, losses, p, used, why}} over TONE_TARGETS.

    Each sample's m carries "_tone" (presets.tone_evidence off the store's
    row) and his delivered "_ex_L50", "_ex_spread", "_ex_face_L". A ridge on
    standardised evidence, held out by shoot (by scene with fewer than
    TONE_MIN_GROUPS shoots, and "held_out" says which), scored on the frames
    where presets would use that target against the rule replayed on the
    same frames (presets.rule_tone), and used only where it clears both
    halves of the bar. Where it does not, "why" says by how much it missed,
    and presets keeps the constant."""
    return {key: _tone_one(_tone_design(samples, shoots_of, key), key) for key in TONE_TARGETS}


def tone_call(entry: dict, ev: dict, key: str) -> float | None:
    """What one target's model predicts for a frame (presets.tone_evidence),
    or None where the model is not in use or was fitted on a row this code
    does not build: weights read with a row they were not fitted on score a
    frame with the meaning of another reading."""
    if not (entry or {}).get("used") or entry.get("w") is None:
        return None
    if list(entry.get("features") or []) != TONE_FEATS:
        return None
    try:
        z = (np.array(_tone_row(ev, entry.get("fill") or {})) - np.array(entry["mu"])) / np.array(entry["sd"])
        v = float(z @ np.array(entry["w"]) + float(entry["b"]))
    except (KeyError, ValueError, TypeError):
        return None
    if not math.isfinite(v):
        return None
    return _tone_clamp(key, v) if key in TONE_CLAMP else v


def tone_words(entry: dict, key: str, v: float) -> str:
    """Where a frame's target came from, in the words its note carries."""
    k = int(entry.get("shoots") or 0)
    by = "" if entry.get("held_out", "shoot") == "shoot" else ", held out by scene"
    if key == "spread_ratio":
        err = f"held-out error {float(entry.get('mae') or 0):.2f} vs rule {float(entry.get('baseline_mae') or 0):.2f}"
        head = f"contrast from your exports: tones spread x{v:.2f}"
    else:
        err = f"held-out error {float(entry.get('mae') or 0):.1f} vs rule {float(entry.get('baseline_mae') or 0):.1f}"
        head = f"{'brightness' if key == 'L50' else 'face'} from your exports: L* {v:.0f}"
    return (f"{head} (learned on {int(entry.get('n') or 0)} frames, {k} shoot{'' if k == 1 else 's'}{by}; {err})")


def tone_sentence(tone: dict | None) -> str:
    """One line for the run and the dataset record: which of the three his
    exports decide now, and for the rest, that the rule does."""
    if not tone:
        return ""
    got = [TONE_WORDS[k] for k in TONE_TARGETS if (tone.get(k) or {}).get("used")]
    rest = [TONE_WORDS[k] for k in TONE_TARGETS if not (tone.get(k) or {}).get("used")]
    if not got:
        return "Brightness, face lightness and contrast are still the rules': none learned from your exports beats them yet."
    s = f"From your exports, per frame: {', '.join(got)}."
    if rest:
        s += f" Still by rule: {', '.join(rest)}."
    return s


def tone_against_live(samples: list[tuple[dict, dict]], shoots_of: list[Path], live: dict | None,
                      tone: dict) -> dict | None:
    """The candidate's tone models against the ones in use, ON THE SAME
    FRAMES, IN THE SAME FOLDS, with only the training pool changing -- the
    white balance's comparison (wb_against_live, whose docstring says why
    nothing simpler is honest) made for a number instead of a class.

    Per target that BOTH use: the frames scored are the ones that taught the
    one in use (the shoots its dataset record names) where the target would
    decide; each is predicted by a fit that never saw its group, one arm
    trained on the one in use's pool and the other on the candidate's; the
    two held-out MAEs are what learned._check_tone reads. A target only one
    of them uses is not compared here: the candidate's own bar against the
    rule covers one it adds, and the gate says so when it drops one.

    None where no comparison can be made honestly: nothing in use, nothing
    recorded on it saying what taught it, or no frame of it here."""
    ltone = (live or {}).get("tone") or {}
    taught = {str(s.get("shoot") or "") for s in (((live or {}).get("dataset") or {}).get("shoots") or [])} - {""}
    if not ltone or not taught:
        return None
    out: dict = {}
    for key in TONE_TARGETS:
        if not (ltone.get(key) or {}).get("used") or not (tone.get(key) or {}).get("used"):
            continue
        d = _tone_design(samples, shoots_of, key)
        groups, _ = _tone_groups(d)
        was_pool = np.array([s in taught for s in d["shoot"].tolist()], dtype=bool)
        if not was_pool.any() or was_pool.all():
            continue                      # the candidate learned nothing the one in use had not, or they share nothing
        ev = was_pool & d["scored"]
        was = _tone_heldout(d["X"], d["y"], groups, was_pool, ev, key)
        now = _tone_heldout(d["X"], d["y"], groups, np.ones(len(d["y"]), bool), ev, key)
        ok = ev & ~np.isnan(was) & ~np.isnan(now)
        if not ok.any():
            continue
        out[key] = {"frames": int(ok.sum()), "now": round(float(np.abs(was[ok] - d["y"][ok]).mean()), 4),
                    "new": round(float(np.abs(now[ok] - d["y"][ok]).mean()), 4)}
    return out or None


# Written by PhotoLab 10 into Overrides when a file is merely opened,
# imported or saved: the gain map and the crop flags, and whatever the Base
# left out or holds in a form PhotoLab re-canonicalises: the white balance
# temperature and tint (the pipeline writes none), the lens-correction block
# (OPENED_RE; a sidecar imported without it came back with all four tools
# materialised OFF), and the HSL slice table with every slice at zero. None
# of it is the photographer's hand, and until this was understood a sidecar
# merely imported into PhotoLab counted as hand-edited and was kept whole,
# lens corrections off and all, by --force.
OPENED = {"ProfileGainMapIntensity", "CropAuto", "CropActive", "CropRect",
          "WhiteBalanceRawTemperature", "WhiteBalanceRawTint", "WhiteBalanceRGBTemperature"}
OPENED_RE = re.compile(r"^(UnsharpMask|Distortion|Vignetting(?!Blur)|ChromaticAberration)\w*$")


# What PhotoLab writes into Overrides for the four lens tools when it opens a
# sidecar whose Base does not carry them, read off the 380 sidecars on this
# library that have it (2026-09-16's reels/ and cull/picks/, the 09-18
# corrections). It is not "all four tools off": distortion stays ON, with its
# type no longer on Auto and the ratio kept, while lens softness, vignetting
# and chromatic aberration go off. A lens key whose value is one of these is
# PhotoLab restating its own state; a lens key at any other value is a choice
# somebody made, and this file has no business deleting it.
LENS_OPENED = {
    "ChromaticAberrationActive": "false", "ChromaticAberrationIntensity": "100",
    "ChromaticAberrationIntensityAuto": "true", "ChromaticAberrationLateralActive": "false",
    "ChromaticAberrationPurpleActive": "false", "ChromaticAberrationSize": "4",
    "ChromaticAberrationSizeAuto": "false", "DistortionActive": "true",
    "DistortionAnamorphosisKeepEntireImage": "false", "DistortionFocus": "128",
    "DistortionIntensity": "1", "DistortionKeepRatio": "true", "DistortionType": '"Auto"',
    "DistortionTypeAuto": "false", "UnsharpMaskActive": "false", "UnsharpMaskActiveAuto": "false",
    "UnsharpMaskIntensity": "100", "UnsharpMaskIntensityOffset": "0", "UnsharpMaskRadius": "0.5",
    "UnsharpMaskThreshold": "4", "VignettingActive": "false", "VignettingClipping": "50",
    "VignettingClippingAuto": "true", "VignettingIntensity": "0", "VignettingIntensityAuto": "true",
    "VignettingMidFieldIntensity": "0", "VignettingType": '"Auto"', "VignettingTypeAuto": "true",
}


def same_value(a: str | None, b: str | None) -> bool:
    """Two values as PhotoLab wrote them, compared as PhotoLab means them: it
    re-serialises floats (-8.292 comes back as -8.2919999999999998), so
    numbers compare as numbers and names exactly, the way taste.decided does."""
    if a is None or b is None:
        return False
    if a.strip() == b.strip():
        return True
    try:
        return abs(float(a) - float(b)) <= 1e-3
    except ValueError:
        return False


def opened_lens(k: str, v: str) -> bool:
    """Whether a lens key carries the value PhotoLab writes when it merely
    opens a file. Any other value of a lens key is a choice somebody made."""
    want = LENS_OPENED.get(k)
    return want is not None and same_value(v, want)


def hand_keys(ov: str) -> set[str]:
    """The depth-0 keys of an Overrides block that are the photographer's own:
    everything PhotoLab materialises on open (OPENED, and a lens key at the
    value PhotoLab writes for it, LENS_OPENED) left out, and
    the HSL slice table counted only when a slice was moved off zero."""
    out: set[str] = set()
    depth = 0
    lines = ov.replace("\r\n", "\n").split("\n")
    for i, ln in enumerate(lines):
        if depth == 0:
            mm = re.match(r"^\s*([A-Za-z0-9_]+) = (.*)$", ln)
            if mm:
                k, v = mm.group(1), mm.group(2).strip().rstrip(",").strip()
                if k == "HSLHueSlices":
                    # its slices sit at deeper depth: look ahead to the table's end
                    d, body = 0, []
                    for ln2 in lines[i:]:
                        body.append(ln2)
                        d += ln2.count("{") - ln2.count("}")
                        if d <= 0 and len(body) > 1:
                            break
                    vals = re.findall(r"(?:Hue|Saturation|Luminance) = ([^,\n]+)", "\n".join(body))
                    if any(abs(float(v)) > 1e-9 for v in vals if re.match(r"^-?[\d.]+(e-?\d+)?$", v.strip())):
                        out.add(k)
                elif k in OPENED:
                    pass
                elif OPENED_RE.match(k) and opened_lens(k, v):
                    # A lens key only at the value PhotoLab writes on open. The
                    # whole lens family used to be skipped, so a deliberate
                    # DistortionActive = false read as PhotoLab's and a frame
                    # whose one change was a lens tool counted as nobody's
                    # (presets.his_lens found the same). Measured on this
                    # library before the change: none of 3,511 sidecars moves.
                    pass
                else:
                    out.add(k)
        depth = max(0, depth + ln.count("{") - ln.count("}"))
    return out


_SPREAD: dict = {}


def spread_written(shoot: Path) -> set[str]:
    """Frames whose Overrides are a COPY of another frame's, not their own.

    One edit carried across a burst leaves sidecars that are byte-for-byte
    his hand and are indistinguishable on disk from it, so without a record
    the learner reads a burst's worth of copies as a burst's worth of
    decisions and the venue converges on whichever frame was the source.
    The tool that writes them keeps that record (decisions/spread.json,
    asked for through decision_path: a record that cannot be found reads as
    a burst with no copies in it, which is the state this guard exists to
    prevent)."""
    key = str(shoot)
    if key not in _SPREAD:
        names: set[str] = set()
        try:
            rec = json.loads(decision_path(library.paths(shoot).cull, "spread.json").read_text())
            for burst in rec.values():
                for n in (burst.get("written") or []):
                    names.add(Path(str(n)).name)
        except Exception:  # noqa: BLE001
            pass
        _SPREAD[key] = names
    return _SPREAD[key]


def is_copy(raw: Path) -> bool:
    """Whether this frame's sidecar was written by carrying another frame's
    edit onto it."""
    return raw.name in spread_written(_shoot_of(raw))


def is_hand(ov: str) -> bool:
    """Whether an Overrides block carries the photographer's hand at all."""
    return bool(ov.strip()) and bool(hand_keys(ov))


def hsl_slices(block: str) -> dict[str, dict[str, float]]:
    """The HSL slice table of a Base or Overrides block, label by label, each
    slice's fields (SLICE_FIELDS) read by name in whatever order they come.

    PhotoLab writes a slice's keys alphabetically (FadeInEnd, FadeInStart,
    FadeOutEnd, FadeOutStart, Hue, Label, Luminance, Saturation,
    Uniformity); the template, and so every Base the pipeline writes, has
    them as Fade*, Hue, Saturation, Luminance, Uniformity, Label. The
    pattern this replaces expected the template's order and so matched 0 of
    the 584 sidecars of the photographer's that carry a moved slice: his one
    finished Yellow move (TSC04667, Saturation -19.03 on bounds he widened to
    12-78) and the Red 0.33 paste on 153 keepers were both invisible to the
    learner. Only the block's own table at its own depth: a mask's
    Corrections can carry a slice table of its own, and that is a stroke on
    a region, not the frame."""
    lines = block.replace("\r\n", "\n").split("\n")
    out: dict[str, dict[str, float]] = {}
    # The block's own depth is where its keys sit; a table deeper than that
    # is a mask's, and a block whose only table is a mask's has none.
    own, depth = None, 0
    for ln in lines:
        if re.match(r"^\s*[A-Za-z0-9_]+ = ", ln) and (own is None or depth < own):
            own = depth
        depth += ln.count("{") - ln.count("}")
    if own is None:
        return out
    depth, i = 0, 0
    while i < len(lines):
        ln = lines[i]
        if depth == own and re.match(r"^\s*HSLHueSlices = \{\s*$", ln):
            d, body = 0, []
            for ln2 in lines[i:]:
                body.append(ln2)
                d += ln2.count("{") - ln2.count("}")
                if d <= 0 and len(body) > 1:
                    break
            cur: dict[str, float] = {}
            label = None
            for ln2 in body[1:]:
                mm = re.match(r"^\s*([A-Za-z]+) = ([^,\n{]*),\s*$", ln2)
                if mm:
                    k, v = mm.group(1), mm.group(2).strip()
                    if k == "Label":
                        label = v.strip('"')
                    elif k in SLICE_FIELDS:
                        try:
                            cur[k] = float(v)
                        except ValueError:
                            pass
                elif re.match(r"^\s*\},?\s*$", ln2):
                    if label:
                        out[label] = cur
                    cur, label = {}, None
            i += len(body)
            continue
        depth = max(0, depth + ln.count("{") - ln.count("}"))
        i += 1
    return out


def moved(v) -> bool:
    """Whether a slice value is a move on PhotoLab's own slider. The display
    log stores the value the photographer saw as an integer, so the
    0.33363970588233816 a paste put on Red Saturation on 153 of a venue's 154
    keepers is 0 on his screen; read as a move it would have been that
    venue's HSL look."""
    try:
        return abs(float(v)) >= 0.5
    except (TypeError, ValueError):
        return False


# The keys the pipeline decides from the image itself (presets.decide,
# decide_exposure, and the per-frame models of earlier versions). A value of
# one of these in a Base is the pipeline's measurement of that frame; pasted
# by the photographer across a shoot it is still not a judgement of theirs.
# Every other key in a Base (a rendering, a channel mixer, ClearView) is there
# only because it was learned from the photographer, and is theirs.
PIPELINE_DECIDES = {"ExposureActive", "ExposureAutoMode", "ExposureBias", "LightingV3Highlights", "LightingV3WhitePoint",
                    "LightingV3BlackPoint", "LightingV3Shadows", "LightingV3MidTones", "LightingV3Intensity",
                    "ContrastEnhancementActive", "ContrastEnhancementGlobalIntensity"}


def _written_by_pipeline(value: str, written: set[str]) -> bool:
    """Whether a value the photographer's sidecars carry is one the pipeline
    wrote. PhotoLab re-serialises floats (-8.292 comes back as
    -8.2919999999999998), so numbers compare as numbers."""
    if value in written:
        return True
    try:
        v = float(value)
    except ValueError:
        return False
    for w in written:
        try:
            if abs(float(w) - v) <= 1e-3:
                return True
        except ValueError:
            continue
    return False


def shoot_overrides(shoot: Path, min_n: int = 3, only: set[str] | None = None) -> dict:
    """What the photographer has done by hand on THIS shoot, key by key, wherever the photographer did it
    at least min_n times: the majority for a categorical, the median for a
    number. The photographer's hand on this venue outranks the median of every other venue,
    which is how a look the photographer only makes here (ClearView off in a dim gym, a stop
    down on a bright subject) reaches every frame of the shoot without anyone
    writing a rule for it.

    `only`, by stem, is the frames whose edits count, where the caller says:
    the starting edit's learner passes the ones he exported (learned.taught),
    because a frame he edited and did not export is one he threw out. The
    presets step reads this shoot's own edits live and passes nothing."""
    seen: set[str] = set()
    vals: dict[str, list[str]] = {}
    exported = exported_at()
    hands = hand_copies(shoot)
    if only is not None:
        hands = {k: v for k, v in hands.items() if Path(k).stem in only}
    for name, f in sorted(hands.items()):
        raw = _raw_of(shoot, name) or (shoot / "raw" / name)
        text = f.read_text(errors="ignore")
        # A frame with nothing but what PhotoLab writes on open (is_hand) was
        # not corrected, and does not count toward the majorities below.
        if is_copy(raw) or not finished(raw, exported):
            continue
        seen.add(name)
        # Only the block's own lines. A control point or a brush stroke
        # carries its own ExposureBias inside a nested LocalParameters
        # table, and read at any depth those counted as votes for the
        # whole shoot: one frame's strokes gave a lounge +0.44 EV everywhere.
        # And only the keys that say something this frame's OWN Base did
        # not (decided): a key that merely repeats its Base is PhotoLab
        # materialising the active value on open, not a correction.
        for k, v in decided(flat_block(text, "Overrides"), flat_block(text, "Base")).items():
            if (k in NUMERIC or k in CATEGORICAL or k in LOOK_KEYS) and k not in OPENED:
                vals.setdefault(k, []).append(v.strip())
    # The second gate, and it is not the same as the first. PhotoLab's paste
    # copies the source frame's WHOLE state, including the numbers the
    # pipeline had written into that frame's Base: one hand edit put
    # TSC04534's black point and highlights on 289 frames without a
    # judgement. Those land in Overrides while the RECEIVING frame's Base
    # still holds its own measurement, so they pass the per-frame echo test
    # and are still not his hand. Measured on the action venue:
    # LightingV3BlackPoint reads -8.292 in the Overrides of 322 frames and
    # differs from its own frame's Base on 176 of them, so decided() alone
    # admits 176 votes for one pasted number. A value the pipeline wrote as a
    # Base value ANYWHERE in this folder is therefore not his hand, however
    # many frames carry it.
    #
    # This now applies to every key, not only the ones the pipeline decides
    # per frame, and the venue's own learned look is no longer spared it.
    # That exemption was the loop itself: once --force had written a look
    # into the Bases, the look exempted itself from the rule that would have
    # caught it, and the learner re-elected its own output every refit.
    # Checked against the risk of over-rejecting his real hand: on the
    # portraits venue every override key tests false here, NoiseRemovalMethod
    # "DeepRaw2RGBv7" on 198 frames and his 92 Fluo decisions included, so
    # what he actually chose there survives both gates intact.
    pipeline_wrote: dict[str, set[str]] = {}
    rawdir = library.paths(shoot).raw
    for f in sorted(rawdir.glob("*.dop"))[:400]:
        base = _block(f.read_text(errors="ignore"), "Base")
        for k, v in re.findall(r"^\s*([A-Za-z0-9_]+) = ([^\n{]+?),\s*$", base, re.M):
            pipeline_wrote.setdefault(k, set()).add(v.strip())
    out: dict = {}
    not_a_target: dict = {}
    # Keys with a per-frame decision of their own are never a venue choice:
    # white balance and the exposure type are decided frame by frame from
    # the frame, and a venue majority would overrule them. And a venue choice
    # needs a majority of the frames the photographer corrected there, not just a count: an
    # override is only written when the photographer changed something, so the frames the photographer
    # left alone are invisible here, and 92 Fluo with 106 silent AsShot would
    # otherwise read as "always Fluo".
    per_frame = {"WhiteBalanceRawPreset", "WhiteBalanceRawTemperature", "WhiteBalanceRawTint",
                 "ExposureAutoMode", "ExposureBias", "ExposureActive"}
    corrected = max(1, len(seen))
    for k, vs in vals.items():
        if k in per_frame or len(vs) < min_n or len(vs) < corrected / 2:
            continue
        top_v = max(set(vs), key=vs.count)
        if _written_by_pipeline(top_v, pipeline_wrote.get(k, set())):
            not_a_target[k] = {"value": top_v, "n": len(vs), "why": "the pipeline wrote this value into a Base in this folder"}
            continue                      # the paste carried the pipeline's own number
        if k in NUMERIC or (k in LOOK_KEYS and k != "ChannelMixerActive"):
            # A number the photographer varies is a per-frame decision and never travels:
            # pasting one exposure onto every frame is not analysis. A number
            # the photographer set to the SAME value on nearly every frame the photographer finished here
            # is the venue's look (the channel mixer the photographer pasted across a gym)
            # and does travel, to frames that measure like this venue.
            try:
                fv = [float(x) for x in vs]
            except ValueError:
                continue
            med = float(np.median(fv))
            if sum(abs(x - med) <= 0.05 for x in fv) < 0.9 * len(fv):
                continue
            out[k] = round(med, 4)
        else:
            top = max(set(vs), key=vs.count)
            out[k] = top.strip('"') if top.startswith('"') else {"true": True, "false": False}.get(top, top)
    # The photographer's colour edits live in nested tables, not flat keys: an HSL channel
    # (Hue/Saturation/Luminance under a Label) and the colour-grading zones.
    # Same rule: a channel or zone the photographer set on at least min_n frames of this
    # shoot gets the median of what the photographer set, per field.
    hsl: dict[str, dict[str, list[float]]] = {}
    grad: dict[str, dict[str, list[float]]] = {}
    for name, f in sorted(hands.items()):
        raw = _raw_of(shoot, name) or (shoot / "raw" / name)
        text = f.read_text(errors="ignore")
        ov = _block(text, "Overrides")
        if is_copy(raw) or not finished(raw, exported):
            continue
        # The same two gates the flat keys get. A slice table that merely
        # repeats the frame's own Base is PhotoLab materialising it on
        # open, and a table pasted from another frame carries whatever
        # the pipeline had written there.
        base_sl = hsl_slices(_block(text, "Base"))
        # Read by name, in PhotoLab's own key order (hsl_slices): the
        # pattern here matched 0 of his sidecars. A frame votes for a
        # slice only where it moved it (moved): a full table with every
        # slice at 0.33 or 0, which is what a paste leaves, is no vote.
        for lab, sl in hsl_slices(ov).items():
            if not any(moved(sl.get(k, 0.0)) for k in ("Hue", "Saturation", "Luminance")):
                continue
            bs = base_sl.get(lab) or {}
            if all(abs(float(sl.get(k, 0.0)) - float(bs.get(k, 0.0))) <= 1e-3 for k in ("Hue", "Saturation", "Luminance")):
                continue              # the frame's own Base already said this
            ch = hsl.setdefault(lab, {"Hue": [], "Saturation": [], "Luminance": []})
            for k in ch:
                ch[k].append(float(sl.get(k, 0.0)))
        for m in re.finditer(r"ColorGradingParams_(\w+) = \{\s*Hue = ([^,]+),\s*Sat = ([^,]+),\s*Lum = ([^,]+),", ov):
            z = grad.setdefault(m.group(1), {"Hue": [], "Sat": [], "Lum": []})
            z["Hue"].append(float(m.group(2)))
            z["Sat"].append(float(m.group(3)))
            z["Lum"].append(float(m.group(4)))
    # The same majority a flat key needs: a channel set on three frames of a
    # shoot where the photographer corrected ninety is not the shoot's look.
    for lab, ch in hsl.items():
        if len(ch["Hue"]) >= max(min_n, corrected / 2) and any(any(v != 0 for v in vs) for vs in ch.values()):
            out.setdefault("_hsl", {})[lab] = {k: round(float(np.median(vs)), 3) for k, vs in ch.items()}
    # A colour-grading zone is found and reported, never written. check_dop
    # refuses a grading zone with no measured gain behind it - rightly: nothing
    # here measures what one does - and a look that carried one therefore
    # stopped the whole presets run for the shoot with a refusal, sidecar by
    # sidecar. His own graded frames are DxO presets applied whole and one
    # hand-dialled Master, which is a thing he did to a frame rather than a
    # thing this shoot's light asks for.
    for z, ch in grad.items():
        if len(ch["Hue"]) >= max(min_n, corrected / 2) and any(any(v != 0 for v in vs) for vs in ch.values()):
            not_a_target[f"ColorGradingParams_{z}"] = {
                "value": ", ".join(f"{k} {float(np.median(vs)):.2f}" for k, vs in ch.items()),
                "n": len(ch["Hue"]),
                "why": "a color-grading zone is not written from a look: nothing here measures what it does to the render"}
    # What had a majority and was still not taken as a target, so report()
    # can say what was found and why it is not written. A key here is not a
    # judgement about him; it is a statement that these files cannot show
    # whether the value was ever his.
    if not_a_target:
        out["_not_a_target"] = not_a_target
    return out


_EXPORT_INDEX: dict[str, str] | None = None


def export_path(stem: str) -> str | None:
    """Where this frame's export is, from one walk of EXPORTS, not one per frame."""
    global _EXPORT_INDEX
    if _EXPORT_INDEX is None:
        import glob as _g
        _EXPORT_INDEX = {Path(f).name.split("_DxO")[0]: f for pat in EXPORTS for f in _g.glob(str(pat), recursive=True)}
    return _EXPORT_INDEX.get(stem)


def export_face_L_one(stem: str, judge) -> float | None:
    """The largest readable face's L* in this frame's export, if one exists."""
    for f in [export_path(stem)]:
        if f is None:
            return None
        if True:
            img = cv2.imread(f)
            if img is None:
                continue
            h, w = img.shape[:2]
            if w > 1800:
                img = cv2.resize(img, (1800, int(h * 1800 / w)), interpolation=cv2.INTER_AREA)
            faces = [x for x in judge.detect(img) if x.main]
            judge.judge(img, faces, render=img)
            faces = sorted([x for x in faces if x.read and not x.in_animal], key=lambda x: -x.box[2] * x.box[3])
            if not faces:
                return None
            x, y, bw, bh = [int(v) for v in faces[0].box]
            inner = img[y + int(0.2 * bh):y + int(0.85 * bh), x + int(0.2 * bw):x + int(0.8 * bw)]
            if inner.size < 100:
                return None
            return float(np.median(cv2.cvtColor(inner, cv2.COLOR_BGR2LAB)[..., 0]) * (100 / 255))
    return None


def export_tones(stem: str) -> dict:
    """Where his export of this frame put its tones: {"ex_L50": the median
    L*, "ex_spread": L* p95 - p5}, or {} where there is no export to read.

    Read the way presets.measure reads the camera JPEG those numbers are set
    beside -- float CIELAB (presets.cielab) on the image at no more than
    1800 px wide -- so the spread ratio learn_tone learns is one instrument
    over two renderings, and not two instruments. These are the targets of
    the tone model (learn_tone): what he delivered, frame by frame."""
    f = export_path(stem)
    if not f:
        return {}
    img = cv2.imread(f)
    if img is None:
        return {}
    h, w = img.shape[:2]
    if w > 1800:
        img = cv2.resize(img, (1800, int(h * 1800 / w)), interpolation=cv2.INTER_AREA)
    from presets import cielab
    L = cielab(img)[0]
    p5, p50, p95 = (float(v) for v in np.percentile(L, (5, 50, 95)))
    return {"ex_L50": round(p50, 4), "ex_spread": round(p95 - p5, 4)}


# What a frame carries into the venue's ranker: the cull's own measurements
# per frame plus where it sits in its burst. Nothing here is a face target
# or a threshold; the weights come from what he kept on a finished shoot.
RANK_FEATS = ["face_score", "gaze_inv", "aesthetic", "quality", "subj_area", "thirds", "mean_luma", "sharp_rel", "focus",
              "action", "faces", "eyes_open", "smile", "pos_in_burst", "burst_len", "lead_read", "lead_frac"]
RANK_MIN_AUC = 0.60      # held out by burst; under this the ranker is not evidence and the score stands
RANK_MIN_KEEPERS = 30


def rank_features(row: dict, pos_in_burst: float, burst_len: int) -> list[float]:
    def num(k, default=0.0):
        v = row.get(k)
        if v is None or v == "":
            return default                 # missing; a measured 0.0 is a value
        try:
            return float(v)
        except (TypeError, ValueError):
            return default
    return [num("face_score"), 1.0 - num("gaze", 0.5), num("aesthetic"), num("quality"), num("subj_area"), num("thirds"), num("mean_luma"),
            num("sharp_rel", 1.0), num("focus"), num("action"), num("faces"), num("eyes_open", 0.5), num("smile"), pos_in_burst, float(burst_len),
            num("lead_read"), num("lead_frac")]


def learn_ranker(shoot: Path, quality: dict[str, float] | None = None,
                 kept: set[str] | None = None) -> dict | None:
    """Which frames of a burst he keeps, learned from a finished shoot's own
    cull.csv and answer key: a small logistic on RANK_FEATS, held out by
    burst. Kept only when it beats chance held out (RANK_MIN_AUC), and used
    on the next shoot that measures like this venue. On the action shoot it
    was learned from it reads 0.65 held out; the top two frames of each
    burst then hold 39% of his keepers at 36% precision, against 30% by
    chance: what a ranker can do there, said plainly.

    `quality`, by stem, replaces cull.csv's own picture score where given:
    learned.train_tier_order passes the score as the cull would work it out
    today (learned._replayed_quality), because the file's column carries the
    drop-reason score of whatever model the cull that wrote it had, and the
    ranker is served the one in use now.

    `kept`, by stem, is the frames to learn as his: learned.train_tier_order
    passes the ones he exported (learned.taught), because he culls further in
    PhotoLab and a frame he kept and did not export is one he threw out.
    Without it, the answer key, as this always read."""
    import csv
    # cull.csv stays in cull/: a cull rebuilds it. The answer key does not,
    # so it is asked for through decision_path and found in decisions/ after
    # `pl migrate`, symlink or no symlink.
    # And both in the cull library.paths names, not a literal cull/: a flat
    # shoot culled into _cull/ has no cull/cull.csv and taught the ranker
    # nothing.
    cull = library.paths(shoot).cull
    cc, sel = cull / "cull.csv", decision_path(cull, "selects.json")
    if not cc.exists() or (kept is None and not sel.exists()):
        return None
    rows = list(csv.DictReader(cc.open()))
    kept = ({s.split(".")[0] for s in json.loads(sel.read_text())} if kept is None
            else {str(s).split(".")[0] for s in kept})
    bursts: dict[str, list[dict]] = {}
    # The frames the cull ranks: a fault is hidden for a measured reason and no
    # order changes that. Position in the burst is counted over exactly these,
    # which is what the cull hands the ranker when it uses one - counted over
    # every frame instead, the ranker was trained on one number and used with
    # another.
    for r in rows:
        if (r.get("rating") or "0") != "0":
            bursts.setdefault(r.get("burst", ""), []).append(r)
    X, y, bl = [], [], []
    for b, rs in bursts.items():
        rs.sort(key=lambda r: r.get("shot_at", ""))
        for i, r in enumerate(rs):
            stem = r["file"].split(".")[0]
            if quality and stem in quality:
                r = dict(r, quality=quality[stem])
            X.append(rank_features(r, i / max(1, len(rs) - 1), len(rs)))
            y.append(1.0 if stem in kept else 0.0)
            bl.append(b)
    X, y = np.array(X, dtype=float), np.array(y, dtype=float)
    if not len(X) or y.sum() < RANK_MIN_KEEPERS or (1 - y).sum() < RANK_MIN_KEEPERS:
        return None
    mu, sd = X.mean(0), X.std(0) + 1e-9
    Z = (X - mu) / sd
    def fit(Zt, yt, l2=1.0, it=400, lr=0.1):
        w = np.zeros(Zt.shape[1])
        b = 0.0
        pw = (1 - yt.mean()) / max(yt.mean(), 1e-6)
        for _ in range(it):
            p = 1 / (1 + np.exp(-(Zt @ w + b)))
            g = (p - yt) * np.where(yt == 1, pw, 1.0)
            w -= lr * (Zt.T @ g / len(yt) + l2 * w / len(yt))
            b -= lr * g.mean()
        return w, b
    ub = sorted(set(bl))
    rng = np.random.default_rng(0)
    rng.shuffle(ub)
    blarr = np.array(bl)
    scores = np.zeros(len(y))
    for k in range(5):
        te = np.isin(blarr, ub[k::5])
        if te.sum() == 0 or (~te).sum() == 0:
            continue
        w, b = fit(Z[~te], y[~te])
        scores[te] = Z[te] @ w + b
    auc = _auc(scores, y)
    w, b = fit(Z, y)
    return {"features": RANK_FEATS, "mu": mu.tolist(), "sd": sd.tolist(), "w": w.tolist(), "b": float(b),
            "auc": round(float(auc), 3), "n_kept": int(y.sum()), "n": int(len(y))}


def rank_score(ranker: dict, feats: list[float]) -> float:
    z = (np.array(feats, dtype=float) - np.array(ranker["mu"])) / np.array(ranker["sd"])
    return float(z @ np.array(ranker["w"]) + ranker["b"])


# Settings that are not a look: which engine denoises is a choice about the
# camera and the patience, not about a room. Only these may travel to a shoot
# that matches no venue, and only when every finished venue agrees.
NOT_A_LOOK = ("NoiseRemovalMethod",)


def travelling() -> dict:
    """What goes onto a shoot whatever its venue: a NOT_A_LOOK setting that
    has the same final value on nearly every finished frame of EVERY finished
    venue. Everything else the photographer has set belongs to the venue it
    was set in; a pooled majority once put one gym's rendering and black
    point on a dog in daylight."""
    ven = ((load() or {}).get("venues") or {}).get("shoots") or {}
    out: dict = {}
    for key in NOT_A_LOOK:
        vals = {(e.get("finals") or {}).get(key) for e in ven.values()}
        if len(vals) == 1 and None not in vals:
            out[key] = vals.pop()
    return out


def venue_id(shoot: Path) -> str:
    """An opaque name for a shoot's venue. taste.json is committed and ships
    inside the app, so it carries no folder, no user name and no shoot name:
    a venue is known to its own shoot by this id and to everyone else by its
    measurements.

    The id was sha1 of the shoot's ABSOLUTE PATH, which made a venue's
    identity a fact about where the folder happened to sit. Renaming
    2026-09-16 to 2026-09-16-gym, or pointing PHOTOS_ROOT at another volume,
    changed the hash and orphaned that venue's 328 learned samples in
    silence: no error, just a shoot the model had never seen. It is now the
    id the shoot carries in its own shoot.json, which travels with the
    folder.

    library.shoot_id falls back to that same path hash for a shoot carrying
    no id, so the two venues in the committed taste.json (6656edcbeffa and
    ebd2907e56f1) keep matching with nothing relearned."""
    from library import shoot_id
    return shoot_id(Path(shoot))


def venue_ids(shoot: Path) -> list[str]:
    """Every id this shoot may be filed under in taste.json: the one it
    answers to now, then the path hash it was filed under before it carried
    one. Lookup tries both, so stamping a shoot with an id migrates its
    venue instead of orphaning it."""
    from library import legacy_shoot_id, shoot_id
    out = [shoot_id(Path(shoot))]
    old = legacy_shoot_id(Path(shoot))
    if old not in out:
        out.append(old)
    return out


def stamp_venue_id(shoot: Path) -> str | None:
    """Write the id a shoot already answers to into its own shoot.json, once,
    so that from here on its venue survives a rename or a move of the whole
    library.

    Called only from the learner: recording a venue is the one moment the
    write means anything, and a shoot with no learned venue is left alone
    (the lounge, whose RAWs were cleared by hand, is never written to by
    this). The value written is the shoot's current path hash, not a fresh
    id, so taste.json keeps matching bit for bit and nothing is relearned --
    the 18-byte migration library.shoot_id describes. Every other key in
    shoot.json is preserved; a shoot that cannot be written to keeps working
    exactly as it does today."""
    from library import legacy_shoot_id, meta
    sj = Path(shoot) / "shoot.json"
    m = meta(shoot)
    # meta() answers {} for a shoot with no shoot.json AND for one whose file
    # will not parse -- a half-written copy, a stray byte, anything hand-typed
    # with a comma out of place. Writing on the second reading would replace
    # his kind, label, style, focus, reviewed and finished with one id and
    # nothing else: a machine's reading of his file standing in for his file,
    # which is the selects.json mistake exactly. An 18-byte migration is not
    # worth that, so only an absent file or one that actually parsed to a
    # table is written over, and the shoot otherwise keeps resolving by its
    # path hash the way it does today.
    if not isinstance(m, dict) or (sj.exists() and not m):
        return None
    if m.get("id"):
        return None
    m["id"] = legacy_shoot_id(shoot)
    try:
        write_json_atomic(sj, m)
    except OSError:
        return None
    return str(m["id"])


def venue_label(shoot: Path) -> str:
    try:
        return str(json.loads((shoot / "shoot.json").read_text()).get("label") or UNNAMED_VENUE)
    except Exception:  # noqa: BLE001
        return UNNAMED_VENUE


def sidecar_base_id(shoot: Path) -> str | None:
    """The stamp of the Base the pipeline actually wrote on this shoot: the
    commonest base_id across its sidecars.

    Every calibration in this file is measured THROUGH a Base. The venue's
    render gain is log2(Y(export L*) / (face Y x 2^bias)) -- the lift of
    DxO's render under the Base that produced the export. A
    Base change invalidates it and nothing else here would notice,
    so the Base they were measured under is recorded beside them and checked
    before they are used."""
    from presets import base_id
    rawdir = library.paths(shoot).raw
    seen: dict[str, int] = {}
    for f in sorted(rawdir.glob("*.dop"))[:200]:
        b = flat_block(f.read_text(errors="ignore"), "Base")
        if not b:
            continue
        bid = base_id({k: lua_value(v) for k, v in b.items()})
        seen[bid] = seen.get(bid, 0) + 1
    return max(seen, key=seen.get) if seen else None


def lua_value(s: str):
    """A Lua scalar as Python, for hashing a Base read back out of a file."""
    s = s.strip()
    if s in ("true", "false"):
        return s == "true"
    if s.startswith('"') and s.endswith('"'):
        return s[1:-1]
    try:
        return int(s) if re.fullmatch(r"-?\d+", s) else float(s)
    except ValueError:
        return s


def _spread_distance(Z: np.ndarray, centre: np.ndarray) -> np.ndarray:
    """How far each row sits from a venue's centre, counted over the features
    it actually has.

    A plain nansum over standardised features rewards a frame for missing one:
    a shoot with nobody in it has no face lightness and no face chroma, so it
    was compared on five dimensions against a spread measured on seven, came
    out closer than it is, and borrowed a venue's look. Scaling by the share
    present puts a five-dimensional distance on the same scale as a
    seven-dimensional one; a row with fewer than half its features present is
    not comparable at all and comes back as infinity."""
    Z = np.atleast_2d(Z)
    diff = (Z - centre) ** 2
    have = np.isfinite(diff).sum(1)
    total = diff.shape[1]
    d = np.sqrt(np.nansum(diff, 1) * total / np.maximum(have, 1))
    return np.where(have * 2 >= total, d, np.inf)


def learn_venues(samples: list[tuple[dict, dict]], shoots: list[Path], gain: float,
                 taught: dict[Path, set[str]] | None = None) -> dict:
    """One entry per finished shoot: where its frames sit in VENUE_FEATS
    (centre and the spread its own frames fall within), the preset the photographer's
    sidecars there started from, the face target the photographer's own exposure decisions
    imply once the renderer's lift is taken off, and the exposure type the photographer
    chose when the photographer was near unanimous about it. samples carry "_face_Y" (the
    largest face's linear luminance from the RAW) where a RAW was read."""
    from presets import Lstar, Y as Y_
    rows = []
    for (m, s), sh in zip(samples, shoots):
        v = [m.get(f) for f in VENUE_FEATS[:-1]] + [math.hypot(float(m.get("face_a") or 0), float(m.get("face_b") or 0)) if m.get("face_a") is not None else None]
        rows.append(v)
    X = np.array([[np.nan if x is None else float(x) for x in r] for r in rows], dtype=float)
    mu = np.nanmean(X, 0)
    sd = np.nanstd(X, 0)
    sd[~np.isfinite(sd) | (sd < 1e-9)] = 1.0
    mu[~np.isfinite(mu)] = 0.0
    out: dict = {"features": VENUE_FEATS, "mu": mu.tolist(), "sd": sd.tolist(), "shoots": {}}
    for sh in sorted(set(shoots), key=str):
        idx = [i for i, x in enumerate(shoots) if x == sh]
        if len(idx) < 3:
            continue
        # About to become a venue, so give it an id of its own first: a venue
        # keyed on where its folder sits is one a rename silently orphans.
        stamped = stamp_venue_id(sh)
        if stamped:
            print(f"  {venue_label(sh)}: id {stamped} written into its own shoot.json, so its venue survives a rename or a move")
        Z = (X[idx] - mu) / sd
        centre = np.nanmean(Z, 0)
        d = _spread_distance(Z, centre)
        types = [str(samples[i][1].get("ExposureAutoMode", "")).strip('"') for i in idx]
        types = [t for t in types if t]
        top = max(set(types), key=types.count) if types else ""
        # The band comes from the frames he delivered when there are enough of
        # them: on the gym he edited 291 and exported 154, and the 137 he
        # threw out say nothing about where he wants a face.
        delivered = [i for i in idx if samples[i][0].get("_exported")]
        # The renderer's lift on this venue, measured where an export exists:
        # the export's face L* against the RAW's luminance and his bias. The
        # gym measures 1.47 where the pooled constant says 1.3.
        lifts, finals = [], []
        for i in delivered:
            m, s = samples[i]
            y, L = m.get("_face_Y"), m.get("_export_L")
            if not y or not L or str(s.get("ExposureAutoMode", "")).strip('"') != "Manual":
                continue
            try:
                bias = float(s.get("ExposureBias", 0) or 0) if str(s.get("ExposureActive", "true")).lower() != "false" else 0.0
            except ValueError:
                bias = 0.0
            lifts.append(math.log2(Y_(float(L)) / max(float(y) * 2 ** bias, 1e-6)))
            finals.append(float(L))
        venue_gain = round(float(np.median(lifts)), 2) if len(lifts) >= 5 else gain
        pool = delivered if len(delivered) >= 10 else idx
        targets = []
        if len(finals) >= 10:
            targets = finals        # where his exports actually put the faces
        else:
            for i in pool:
                m, s = samples[i]
                y = m.get("_face_Y")
                if not y or str(s.get("ExposureAutoMode", "")).strip('"') != "Manual":
                    continue
                try:
                    bias = float(s.get("ExposureBias", 0) or 0) if str(s.get("ExposureActive", "true")).lower() != "false" else 0.0
                except ValueError:
                    bias = 0.0
                targets.append(Lstar(float(y) * 2 ** (bias + venue_gain)))
        # His white balance on this venue, counted, not voted: a venue with
        # fewer than WB_MIN_CLASS decisions of a named preset keeps its
        # finals (AsShot on 293 of 294 finished frames of the action venue,
        # one eyedropper); at eight it hands its frames to predict_wb.
        wb_counts: dict[str, int] = {}
        for i in idx:
            v = str(samples[i][1].get("WhiteBalanceRawPreset", "AsShot")).strip('"') or "AsShot"
            wb_counts[v] = wb_counts.get(v, 0) + 1
        prefer = top if types and types.count(top) >= (2 / 3) * len(types) else None
        out["shoots"][venue_id(sh)] = {
            "wb_counts": wb_counts,
            "label": venue_label(sh),
            # The shoot this venue was learned from, so anything that has to
            # NAME the venue later has something he can open. venue_label
            # answers "a finished shoot" for every shoot he has not named, and
            # two of his four venues carry it, so a sentence built on the label
            # alone could not even say which of the two it meant. This loop
            # runs once per shoot path and keys on venue_id(sh), so a venue is
            # built from exactly one shoot and this is the whole of it. A
            # folder name and nothing more: dataset.shoots already ships the
            # same names, and an absolute path or a user name would not.
            "shoots": [sh.name],
            # What was set the same way on most of its finished frames, kept
            # here so the look travels without the folder it came from.
            # Off the same frames the fit above was given (`taught`): the
            # edits of the frames he exported, not every sidecar he touched.
            "look": shoot_overrides(sh, only=(taught or {}).get(sh)),
            "n": len(idx), "base": venue_base(sh, only=(taught or {}).get(sh)),
            "centre": [None if not np.isfinite(c) else round(float(c), 4) for c in centre],
            # The same centre in the features' own units, so a later refit can
            # carry this venue over: mu and sd are measured afresh from
            # whatever was finished this time, and a centre standardised under
            # the old ones would put the venue somewhere it never was.
            "centre_raw": [None if not np.isfinite(c) else round(float(c), 4)
                           for c in (centre * np.asarray(sd) + np.asarray(mu))],
            "spread": round(float(np.nanpercentile(d[np.isfinite(d)], 90)), 4) if np.isfinite(d).any() else 0.0,
            "target_L": round(float(np.median(targets)), 1) if len(targets) >= 3 else None,
            # The band the photographer accepted: on a gym the photographer left every frame at 0 EV with
            # faces rendering anywhere from L* 24 to 74, so a face inside this
            # band is not corrected; one outside it is brought to the edge.
            "face_lo": round(float(np.percentile(targets, 10)), 1) if len(targets) >= 10 else None,
            "face_hi": round(float(np.percentile(targets, 90)), 1) if len(targets) >= 10 else None,
            "face_targets": sorted(round(float(x), 1) for x in targets),
            "target_n": len(targets),
            "delivered": len(delivered),
            "gain": venue_gain,
            "gain_n": len(lifts),
            # The Base this gain was measured under. presets.frame_tones
            # refuses to use it under any other one (see sidecar_base_id).
            "gain_base": sidecar_base_id(sh) if len(lifts) >= 5 else None,
            "finals": {k: v for k in NOT_A_LOOK + ("WhiteBalanceRawPreset",)
                       for v, c in [max(((val, sum(1 for i in idx if str(samples[i][1].get(k, "")).strip('"') == val))
                                         for val in {str(samples[i][1].get(k, "")).strip('"') for i in idx} - {""}), key=lambda vc: vc[1], default=(None, 0))]
                       if v and c >= 0.9 * len(idx)},
            "targets_from": "exports" if len(finals) >= 10 else "hand edits",
            "type": prefer,
            "type_share": round(types.count(top) / len(types), 2) if types else None,
            # This venue's own exposure type, and whether it has earned the
            # right to replace the rule here (venue_exposure). Read by
            # presets.frame_tones through predict_exposure, and gated by
            # learned.check_edit on the counts it carries.
            "exposure": venue_exposure([samples[i] for i in idx], prefer),
        }
    return out


def venue_for(shoot: Path, m: dict | None = None, table: dict | None = None) -> tuple[str, dict] | None:
    """The finished venue a shoot draws its look from: the shoot itself when
    it is one; otherwise the nearest finished venue whose own spread the
    frame's measurements fall inside; otherwise none, and the frame gets
    DxO's own rendering and the sensor's decisions only.

    `table` asks the same question of another set of venues: the cull asks it
    of the tier order's own table (learned.tier_order_table), which carries
    the same geometry beside each ranker so that a tier order keeps working
    when the starting edit is turned off."""
    mod = load() or {}
    ven = table if table is not None else (mod.get("venues") or {})
    shoots = ven.get("shoots") or {}
    # Under the id it answers to now, else under the path hash it was filed
    # under before it had one. Reported under the current id either way:
    # every caller compares this against venue_id() to tell a shoot's own
    # look from a look borrowed off a venue that measures like it, and that
    # comparison must not start failing the day a shoot is stamped.
    for vid in venue_ids(shoot):
        if vid in shoots:
            return venue_id(shoot), shoots[vid]
    if not m or not shoots:
        return None
    feats = ven.get("features") or VENUE_FEATS
    mu, sd = np.array(ven["mu"]), np.array(ven["sd"])
    v = [m.get(f) for f in feats[:-1]] + [math.hypot(float(m.get("face_a") or 0), float(m.get("face_b") or 0)) if m.get("face_a") is not None else None]
    z = (np.array([np.nan if x is None else float(x) for x in v]) - mu) / sd
    best = None
    for name, e in shoots.items():
        c = np.array([np.nan if x is None else x for x in e["centre"]], dtype=float)
        # Counted over the features both of them have, and put back on the
        # scale the venue's own spread was measured on (_spread_distance): a
        # shoot with no faces in it used to be measured on five dimensions
        # against a spread measured on seven, and so borrowed the look of a
        # venue it is not in.
        d = float(_spread_distance(z, c)[0])
        if d <= e["spread"] and (best is None or d < best[0]):
            best = (d, name, e)
    return (best[1], best[2]) if best else None


def load() -> dict | None:
    """The starting edit in use, or None when there is none to read.

    Kept per file and per change, not for the life of the process: the studio
    can swap a newly learned edit in while it is running, and a reader that
    cached the first answer would go on writing sidecars from the model that
    was replaced."""
    global _CACHE
    p = model_path()
    try:
        mt = p.stat().st_mtime_ns
    except OSError:
        return None
    if _CACHE and _CACHE[0] == p and _CACHE[1] == mt:
        return _CACHE[2]
    try:
        mod = json.loads(p.read_text())
    except Exception:  # noqa: BLE001
        return None
    _CACHE = (p, mt, mod)
    return mod


def report(mod: dict) -> str:
    L = [f"Learned from {mod['n']} of the photographer's hand edits, which carry {mod.get('groups', '?')} distinct decisions", ""]
    L.append("  setting                            n   the photographer's median   held-out MAE   vs median   used")
    for k, e in sorted(mod["numeric"].items(), key=lambda kv: -kv[1].get("gain", -9)):
        used = "model" if "w" in e else "median"
        if "touch_w" in e:
            used += f", when predicted (moves it on {e['touch_rate']:.0%}; {e['touch_accuracy']:.2f} vs {e['touch_base']:.2f})"
        elif e.get("touch_rate", 1.0) < 0.5:
            used += f", never (moves it on {e['touch_rate']:.0%})"
        g = f"{e['gain']:+.0%}" if "gain" in e else "     -"
        mae = f"{e['mae']:.2f}" if "mae" in e else "    -"
        bm = f"{e['median_mae']:.2f}" if "median_mae" in e else "  -"
        L.append(f"  {k:<32}{e['n']:>4}   {e['median']:>10.2f}   {mae:>12}   {g:>6} of {bm:<6} {used}")
    c = mod.get("colour") or {}
    if c:
        L.append("")
        L.append(f"  color, measured off {c['files']} finished exports ({c['faces']} faces):")
        L.append(f"     the photographer's skin lands at   a* {c['skin_a']:+.1f}  b* {c['skin_b']:+.1f}  L* {c['skin_L']:.1f}")
        L.append(f"     the photographer's skin hue        {c['skin_hue']:.1f} deg (+/-{c['skin_hue_mad']:.1f}), measured, not corrected")
        for lab, d in (c.get("by_lightness") or {}).items():
            L.append(f"        {lab:<10}{d['n']:>4} faces   L* {d['L']:>5.1f}   hue {d['hue']:>5.1f} deg")
        L.append(f"     the photographer's neutrals        a* {c['neutral_a']:+.2f}  b* {c['neutral_b']:+.2f}")
    L.append("")
    for k, e in mod["categorical"].items():
        L.append(f"  {k:<32}{e['n']:>4}   {e['value']!r} ({e['share']:.0%} of the photographer's edits)")
    tone = mod.get("tone") or {}
    if tone:
        # Where each frame's brightness, face and contrast come from: his
        # exports where that beat the rule held out, the rule where not, and
        # why, in the numbers the gate used.
        L.append("")
        L.append("  per frame, from the photographer's exports (held-out error against the rule's, on the same frames):")
        for k in TONE_TARGETS:
            e = tone.get(k) or {}
            if not e:
                continue
            fmt = "{:.2f}" if k == "spread_ratio" else "{:.1f}"
            err = (f"{fmt.format(e['mae'])} vs {fmt.format(e['baseline_mae'])}"
                   if e.get("mae") is not None and e.get("baseline_mae") is not None else "-")
            L.append(f"     {TONE_WORDS[k]:<16}{int(e.get('n') or 0):>5} frames {int(e.get('shoots') or 0):>3} shoots   "
                     f"{err:<14} {'used' if e.get('used') else 'rule'}")
            if e.get("why"):
                L.append(f"        {e['why']}")
    return "\n".join(L)


def teaching_rows(table: dict[str, dict], here: set[str],
                  root: Path = SHOOTS) -> tuple[dict[str, dict], dict[Path, set[str]]]:
    """The measured frames that teach the starting edit, and what each shoot
    on this Mac teaches as his, by stem.

    Every finished frame of his is measured and kept - measured once - and
    only the ones he exported teach (learned.taught): "i tend to cull further
    during editing", and a frame he edited in PhotoLab and did not export is
    one he threw out there. A shoot on this Mac is asked, and one whose
    exports are not found answers with what the store recorded of them, never
    with its keepers; one that is not here at all, with no capture time to
    hold an export's date to, answers with whether each row was measured as
    exported."""
    import learned
    root = Path(root)
    taught_of: dict[Path, set[str]] = {}
    for sh in sorted({str(r.get("shoot") or "") for r in table.values()}):
        if sh in here:
            taught_of[root / sh] = learned.taught(root / sh, table=table)[0]

    def teaches_now(r: dict) -> bool:
        mine = taught_of.get(root / str(r.get("shoot") or ""))
        if mine is None:
            return bool(r.get("exported"))
        return str(r.get("stem") or Path(str(r.get("frame") or "")).stem) in mine

    return {k: r for k, r in table.items() if teaches_now(r)}, taught_of


def learn_edit(root: Path = SHOOTS, progress=None) -> dict:
    """The starting edit, learned from every finished sidecar under `root`.

    The tier order that used to be fitted here and stored beside each venue is
    its own learner now (learned.py): it changes what the cull shows and has to
    be checked against every photo he kept, and the starting edit never touches
    the cull at all. Returns the model; writing it is learned.submit's job, so
    that nothing goes into use without being looked at first.

    `progress(stage, done, total)` is how the studio's bar follows this from
    the outside: the two long stretches in here are measuring the frames and
    reading the exports, and without a mark from each the bar stands still for
    minutes at a time. Called with the same `@@ stage done total` vocabulary
    the job runner reads. None (the CLI) keeps the plain print this always
    had.

    MEASURED ONCE. A frame's measurements are kept in the learned folder
    (learned.measured_*) and this fits from ALL of them, not from the ones that
    happen to be measurable today. It measures a frame it has never measured,
    and one whose sidecar he has edited since; everything else it reads back.
    That is what stops his teaching decaying as his library ages: 2026-09-16
    taught 730 sidecars and 155 exports, its RAWs went to iCloud, and the next
    fit saw 283 finished frames where the model in use had 527."""
    import learned

    def mark(stage: str, done: int, total: int) -> None:
        if progress:
            progress(stage, done, total)
        else:
            print(f"@@ {stage} {done} {total}", flush=True)

    root = Path(root)
    frames = teaching(root)
    store, _rows = learned.measured_read("frame")
    here = {p.name for p in root.iterdir() if p.is_dir()} if root.is_dir() else set()
    # Shoots he has taken out of the measurements by hand stay out: they are
    # not measured, and their rows were removed when he asked.
    dropped = set(learned.dropped_shoots())
    want = {f"{t['shoot'].name}/{t['name']}": t for t in frames if t["shoot"].name not in dropped}

    # Three piles: measure it properly, read its export again, or leave it
    # exactly as it was measured.
    todo: list[tuple[str, dict]] = []
    again = 0
    export_again: list[tuple[str, dict]] = []
    stale: list[str] = []          # his sidecar changed and the RAW is not here
    never: list[str] = []          # never measured, and the photograph has gone
    for key, t in sorted(want.items()):
        old = store.get(key)
        same = bool(old) and old.get("schema") == MEASURE_SCHEMA and old.get("sidecar") == t["sidecar"]
        can = t["raw"] is not None and t["preview"] is not None
        # Measured again only for what it lacks, and only off bytes that are
        # actually on this Mac: a RAW that is a name in a folder with its bytes
        # in iCloud would be downloaded by the read, which a run he did not
        # ask to fetch anything must never do.
        backfill = bool(same) and can and any(k not in old for k in RAW_READINGS) and _bytes_here(t["raw"])
        # The export's own tones (export_tones), which the tone model learns
        # from, read once for a row kept before they were, while the export
        # is on this Mac: that needs the JPEG and nothing else, so it goes by
        # the export pile and never costs a RAW read. A row that has the key
        # -- even as None, an export that could not be read -- is not asked
        # again, so this happens once.
        tones_missing = bool(same) and "ex_L50" not in old and export_path(t["stem"]) is not None
        if same and old.get("export") == t["export"] and not backfill and not tones_missing:
            continue
        if backfill:
            again += 1
            # Measured before the store kept the sensor readings the exposure
            # rule decides from (clip_any) or the tone model reads (the RAW's
            # median and headroom, the light off its EXIF). While the RAW is
            # here it is measured once more, so the rule can be replayed on
            # it and the model can learn from it for good; once the RAW has
            # gone it stays as it was: its venue's exposure is left to the
            # rule (venue_exposure says so, and why), and the tone model
            # reads it with those readings flagged as missing.
            todo.append((key, t))
        elif same:
            export_again.append((key, t))
        elif can:
            todo.append((key, t))
        elif old is not None:
            # Kept, and said out loud. Never silently mixed in as though it had
            # been measured the way the rest were.
            stale.append(key)
        else:
            # Finished work of his that nothing ever measured, and the
            # photograph is not here to measure now. This store fixes the decay
            # from here on; it cannot reach back into a run that kept nothing.
            never.append(key)
    print(f"{len(want)} finished frames of yours, {len(store)} already measured, {len(todo)} to measure")
    if again:
        # Said before it starts, because it is the one run that is slow for a
        # reason he did not cause: on his library 388 frames, about seven
        # minutes where a run is otherwise about one. It reads his RAWs and
        # writes nothing beside them, and a frame measured once is not
        # measured again for this.
        print(f"  {again} of those were measured before the store kept the sensor readings the exposure rule "
              f"decides from and the brightness model learns from, and are measured once more while their "
              f"photographs are on this Mac; this happens once")
    if len(want) < 20 and len(store) < 20:
        # Before the detectors are loaded: a machine with nothing finished on
        # it yet should not spend a minute of model loading to say so.
        print("not enough finished frames to learn a starting edit from")
        return {}

    fresh: list[dict] = []
    if todo or export_again:
        from faces import FaceJudge
        judge = FaceJudge()
        exported_set = exported_at()
        scene_of: dict[Path, dict] = {}

        def scene_burst(shoot: Path, stem: str) -> tuple[str, str]:
            if shoot not in scene_of:
                scene_of[shoot] = {}
                cc = learned.cull_dir(shoot) / "cull.csv"
                if cc.exists():
                    import csv
                    with cc.open() as fh:
                        scene_of[shoot] = {Path(r["file"]).stem: (r.get("scene", ""), r.get("burst", ""))
                                           for r in csv.DictReader(fh)}
            sc, bu = scene_of[shoot].get(stem, ("", ""))
            return f"{shoot.name}/{sc}", f"{shoot.name}/b{bu}"

        # Every frame is measured the way the presets step measures it (faces and
        # landmarks on the camera JPEG, measure(), the camera's kelvin, the RAW in
        # linear terms), a frame per core. One at a time this took 25 minutes.
        from presets import measure_frames
        jobs = [(str(i), str(t["preview"]), "", str(t["raw"])) for i, (_k, t) in enumerate(todo)]
        measured = measure_frames(jobs, progress=lambda d, n: mark("measuring", d, n) if d % 25 == 0 or d == n else None) \
            if jobs else {}
        # Reading the exports below is the longest unmarked stretch there was: one
        # face detection per finished frame, off the JPEG on disk, and on his
        # library it is four minutes. The bar sat at 65% throughout, with the label
        # still reading "288 of 288" from the last measuring mark, which is a
        # screen that says the machine has hung.
        total = len(todo) + len(export_again)
        # The light each frame was taken in, off its RAW's EXIF, the way
        # presets.frame_tones reads it for a new frame: one exiftool call for
        # the lot, and a frame it cannot read simply has none.
        from presets import exif_light
        light = exif_light([str(t["raw"]) for _k, t in todo]) if todo else {}
        mark("exports", 0, max(1, total))
        for i, (key, t) in enumerate(todo):
            if i and (i % 25 == 0):
                mark("exports", i, total)
            got = measured.get(str(i))
            if not got:
                continue
            m = got["m"]
            face_Y = (got["lin"] or {}).get("face_Y")
            exported = is_exported(t["raw"], exported_set)
            # The same face in the export: with the RAW's luminance and the
            # bias this is the renderer's lift on this venue, and the finished
            # L* itself, which is the venue's band.
            export_L = export_face_L_one(t["stem"], judge) if (exported and face_Y) else None
            sc, bu = scene_burst(t["shoot"], t["stem"])
            lin = got["lin"] or {}
            lit = light.get(str(t["raw"])) or {}
            # What he delivered, for the tone model (learn_tone): None where
            # there is no export to read, and kept as a key either way so the
            # backfill never asks again.
            tones = export_tones(t["stem"]) if exported else {}
            fresh.append({"key": key, "kind": "frame", "shoot": t["shoot"].name, "frame": t["name"], "stem": t["stem"],
                          "at": _stamp_now(), "schema": MEASURE_SCHEMA,
                          "sidecar": t["sidecar"], "export": t["export"],
                          "m": _round_measure(m), "settings": t["settings"],
                          "scene": sc, "burst": bu, "exported": bool(exported),
                          "face_Y": face_Y, "export_L": export_L,
                          # What the exposure rule reads off the RAW, kept so
                          # the rule can be replayed on this frame after the
                          # RAW has gone (venue_exposure).
                          "clip_any": _round6((got["lin"] or {}).get("clip_any")),
                          "subject_Y": _round6((got["lin"] or {}).get("subject_Y")),
                          # What the tone model reads off the RAW and its
                          # EXIF (RAW_READINGS), and what it learns from the
                          # export (export_tones).
                          "frame_Y": _round6(lin.get("frame_Y")), "headroom_ev": _round6(lin.get("headroom_ev")),
                          "lv": _round6(lit.get("lv")), "iso": _round6(lit.get("iso")),
                          "ex_L50": tones.get("ex_L50"), "ex_spread": tones.get("ex_spread")})
        for j, (key, t) in enumerate(export_again):
            mark("exports", len(todo) + j, total)
            old = dict(store[key])
            face_Y = old.get("face_Y")
            # Asked afresh, so an export he has deleted takes its answer with
            # it. The probe is where the RAW would be; is_exported falls back
            # to the shoot's own record of when the frame was taken when it is
            # not there, which is the whole reason an archived shoot can still
            # say what it exported.
            exported = is_exported(t["raw"] or t["shoot"] / "raw" / t["name"], exported_set)
            old["exported"] = bool(exported)
            old["export_L"] = export_face_L_one(t["stem"], judge) if (exported and face_Y) else None
            tones = export_tones(t["stem"]) if exported else {}
            old["ex_L50"], old["ex_spread"] = tones.get("ex_L50"), tones.get("ex_spread")
            old["export"] = t["export"]
            old["at"] = _stamp_now()
            fresh.append(old)
        mark("exports", total, max(1, total))
        learned.measured_add(fresh)

    # A frame he has un-finished, or whose sidecar he has emptied, on a shoot
    # that is still here to say so. Written as a row of its own rather than
    # deleted: the file is the record of what taught this, and a shoot that is
    # merely off the disk today must never be mistaken for one he retracted.
    gone = [k for k in store
            if k not in want and k.split("/", 1)[0] in here and k.split("/", 1)[0] not in dropped]
    if gone:
        learned.measured_add([{"key": k, "kind": "frame", "shoot": k.split("/", 1)[0], "at": _stamp_now(), "gone": True,
                               "why": "it is no longer a finished edit of yours"} for k in gone])
        print(f"  {len(gone)} frames are no longer finished edits of yours; they no longer teach")
    if fresh or gone:
        learned.measured_compact()
    table, _rows = learned.measured_read("frame")
    measured_all = len(table)
    table, taught_of = teaching_rows(table, here, root)
    left_out = measured_all - len(table)
    if left_out:
        print(f"  {left_out} of your finished frames were edited and not exported; they are kept and do not teach")

    samples: list[tuple[dict, dict]] = []
    shoots_of: list[Path] = []
    for key in sorted(table):
        r = table[key]
        m = dict(r.get("m") or {})
        m["_face_Y"] = r.get("face_Y")
        # The sensor readings presets.exposure_mode decides from, so the rule
        # can be replayed on this frame when a venue's own fit is weighed
        # against it. Absent on a row measured before the store kept them.
        m["_clip_any"], m["_subject_Y"] = r.get("clip_any"), r.get("subject_Y")
        m["_exported"] = bool(r.get("exported"))
        m["_export_L"] = r.get("export_L")
        m["_scene"], m["_burst"], m["_stem"] = r.get("scene") or "", r.get("burst") or "", r.get("stem") or ""
        # The tone model's evidence and what he delivered (learn_tone). The
        # evidence is built by presets.tone_evidence from the store's row
        # exactly as presets builds it from a new frame; the face target is
        # export_L, the export's largest face as export_face_L_one reads it,
        # which the store has always kept.
        from presets import tone_evidence
        m["_tone"] = tone_evidence(r.get("m") or {}, {k: r.get(k) for k in ("lv", "iso", "face_Y", "frame_Y", "headroom_ev")})
        m["_ex_L50"], m["_ex_spread"], m["_ex_face_L"] = r.get("ex_L50"), r.get("ex_spread"), r.get("export_L")
        samples.append((m, r.get("settings") or {}))
        shoots_of.append(root / str(r.get("shoot") or ""))
    # Held out by scene where the cull split the shoot into scenes, by burst
    # where it did not. A cull once put 1141 of the finished action venue's
    # 1157 frames in one scene: held out by scene that venue was one group,
    # a class learned there could never pass, and its bursts (89 of them,
    # one light and one moment each) are the unit then. A shoot with fewer
    # than three scenes of eight or more samples is grouped by burst; the
    # same venue's current cull has four such scenes and is held out by them.
    per_shoot: dict[Path, dict[str, int]] = {}
    for (m, _), sh in zip(samples, shoots_of):
        per_shoot.setdefault(sh, {})
        per_shoot[sh][m["_scene"]] = per_shoot[sh].get(m["_scene"], 0) + 1
    for (m, _), sh in zip(samples, shoots_of):
        by_scene = sum(1 for c in per_shoot[sh].values() if c >= 8) >= 3
        m["_group"] = m["_scene"] if by_scene else m["_burst"]
    if len(samples) < 20:
        print("not enough measurable frames to learn from")
        return {}
    mod = learn(samples)
    mod["wb"] = learn_wb(samples)
    # Where his exports put each frame's midtones, face and tonal spread,
    # learned per frame and used in place of the constants only where it
    # beats them on shoots it had not seen (learn_tone).
    mod["tone"] = learn_tone(samples, shoots_of)
    mod["colour"] = learn_colour(mark)
    from presets import RENDER_GAIN
    # A venue's look, its base and the Base its render gain was measured under
    # are read off that shoot's own sidecars, which stay behind when its RAWs
    # go. A shoot that is not on this Mac at all cannot answer them, so its
    # frames still teach the fit above and its venue is carried over whole
    # (_carry_venues) rather than half-rebuilt from nothing.
    mine = [(s, sh) for s, sh in zip(samples, shoots_of) if sh.name in here]
    mod["venues"] = learn_venues([s for s, _ in mine], [sh for _, sh in mine], RENDER_GAIN, taught=taught_of)
    mod["vocab"] = learn_vocab(root)
    carried = _carry_venues(mod)
    for label in carried:
        print(f"  venue \"{label}\": kept exactly as it was learned; none of its frames could be measured this time")
    mod["dataset"] = dataset(table, here, measured_now=len(fresh), stale=stale, never=never, root=root,
                             not_exported=left_out)
    # The frames it was fitted on, by name, so that when a later version is
    # weighed against this one its count can be made again frame by frame
    # under whatever the rule is then (learned.edit_count). Kept in the model
    # only: the manifest keeps the dataset's numbers, not the frames.
    mod["taught_frames"] = learned.frames_by_shoot(table.values())
    print("  " + mod["dataset"]["this_run"])
    # Which of brightness, face lightness and contrast his exports now
    # decide, kept with the dataset so the page that reads it back can say
    # it for as long as this model stands, and printed for the run.
    mod["dataset"]["tone"] = tone_sentence(mod["tone"])
    print("  " + mod["dataset"]["tone"])
    # The tone models against the ones in use, on the same frames in the
    # same folds (tone_against_live), for learned._check_tone.
    tone_live = tone_against_live(samples, shoots_of, learned.live_model("edit"), mod["tone"])
    if tone_live:
        mod["tone"]["against_live"] = tone_live
    # The two measurements learned.check_edit weighs this against the one in
    # use. Made here because this is the only place both the frames and the
    # finished model exist at once; the deciding is still in learned.py, and
    # a candidate that arrives without them is held there rather than passed.
    #
    # Marked as "edit", which is the stage the run is actually in: this is the
    # last of the work that produces the starting edit, and learned.run sends
    # `edit 1 1` the moment it returns. It said "checking" for one night, and
    # "checking" is the LAST stage of the learning run - studio.Jobs.status
    # fills every earlier stage in once a later one has spoken, so naming the
    # last stage here drove the bar to 100% in the middle of the run and then
    # back to 96% when the next mark named "edit". A stage name is not a label
    # for what this code is doing; it is a position in the run.
    if "w" in mod["wb"]:
        mark("edit", 0, 3)
        mod["wb"]["where_used"] = wb_where_used(mod, samples, shoots_of)
        mark("edit", 1, 3)
        against = wb_against_live(samples, shoots_of, learned.live_model("edit"))
        if against:
            mod["wb"]["against_live"] = against
        mark("edit", 2, 3)
    return mod


def _stamp_now() -> str:
    from datetime import datetime
    return datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


def _bytes_here(p: Path) -> bool:
    try:
        import archive
        return archive.local(Path(p))
    except Exception:  # noqa: BLE001
        return Path(p).exists()


def _round6(v):
    return None if v is None else round(float(v), 6)


def _round_measure(m: dict) -> dict:
    """The same numbers, kept to six figures. The store is his, it grows one
    row per finished frame for as long as he shoots, and a float printed to
    seventeen digits costs a third of the file to say nothing."""
    out = {}
    for k, v in m.items():
        if isinstance(v, float):
            out[k] = round(v, 6)
        elif isinstance(v, (int, str, bool)) or v is None:
            out[k] = v
        else:
            try:
                out[k] = round(float(v), 6)
            except (TypeError, ValueError):
                continue
    return out


def dataset(table: dict, here: set, measured_now: int, stale: list, never: list | None = None,
            root: Path | None = None, not_exported: int = 0) -> dict:
    """What the fit was actually learned from, in numbers he can check.

    His question was "how did it have less than it started with", and the
    answer has to be on the screen: how many frames, how many measured this
    time, how many came off shoots whose photographs are no longer on this Mac,
    and which shoots they were."""
    import learned
    by_shoot: dict[str, dict] = {}
    for r in table.values():
        sh = str(r.get("shoot") or "")
        e = by_shoot.setdefault(sh, {"shoot": sh, "frames": 0, "where": "", "older": 0})
        e["frames"] += 1
        if int(r.get("schema") or 0) != MEASURE_SCHEMA:
            e["older"] += 1
    for sh, e in by_shoot.items():
        e["where"] = ("not on this Mac" if sh not in here
                      else "here" if _has_raw(sh, root) else "photographs archived")
    shoots = sorted(by_shoot.values(), key=lambda e: (-e["frames"], e["shoot"]))
    away = sum(e["frames"] for e in shoots if e["where"] != "here")
    older = sum(e["older"] for e in shoots)
    size = learned.measured_size()
    named = ", ".join(f"{e['shoot']} ({e['frames']})" for e in shoots[:6])
    if len(shoots) > 6:
        named += f", and {len(shoots) - 6} more"
    one = "1 shoot" if len(shoots) == 1 else f"{len(shoots)} shoots"
    frm = f"Learned from {len(table)} finished frames on {one}: {named}."
    # Two sentences, because this is read in two places at two times. The run
    # prints what it just did; the model KEEPS this dict and the learning page
    # reads it back for as long as that model stands, so a line that says
    # "measured this time" is true for one minute and a lie for a fortnight --
    # it said "639 measured this time" on a run that measured nothing.
    measured_now = min(measured_now, len(table))
    now = (f"{measured_now} measured this time; {len(table) - measured_now} were measured before and kept."
           if measured_now else f"Nothing new to measure: all {len(table)} were measured before and kept.")
    met = (f"All {len(table)} are measured and kept, so they teach whether or not their photographs are here."
           if len(table) else "Nothing is measured yet.")
    extra = ""
    if away:
        extra += (f" {away} of them are from shoots whose photographs are no longer on this Mac, "
                  f"and they still teach.")
    if older:
        extra += (f" {older} were measured by an older version of the measuring code and could not be measured "
                  f"again, so they are counted apart.")
    if stale:
        extra += (f" {len(stale)} have a sidecar you have changed since, with no photograph here to measure "
                  f"again; what they taught is what they taught before.")
    if never:
        # The one thing this cannot fix by itself, said plainly rather than
        # left as a smaller number on the screen. Those frames were measured by
        # runs that kept nothing, and their RAWs went to iCloud afterwards.
        miss = sorted({k.split("/", 1)[0] for k in never})
        extra += (f" {len(never)} more finished frames of yours on {', '.join(miss)} have never been measured and "
                  f"their photographs are not on this Mac; bring one back once (./pl archive pull <shoot> --apply) and "
                  f"learn again, and it teaches for good.")
    if not_exported:
        # His rule, said where the numbers are: edited is not chosen.
        extra += (f" {not_exported} more you edited and did not export are measured and kept, and do not teach: "
                  f"only what you export does.")
    met += extra
    now += extra
    return {"frames": len(table), "measured_now": measured_now, "kept_from_before": len(table) - measured_now,
            "not_exported": not_exported,
            "away": away, "older_schema": older, "unmeasurable_changes": len(stale),
            "never_measured": len(never or []),
            "never_measured_shoots": sorted({k.split("/", 1)[0] for k in (never or [])}),
            # Per shoot, because this is what decides whether bringing a shoot
            # back from iCloud could teach anything: a count of 0 means the
            # photographs arriving changes nothing, and the run that would
            # follow would measure nothing.
            "never_measured_by_shoot": {sh: sum(1 for k in (never or []) if k.split("/", 1)[0] == sh)
                                        for sh in sorted({k.split("/", 1)[0] for k in (never or [])})},
            "shoots": shoots, "schema": MEASURE_SCHEMA,
            "store": {"bytes": size["bytes"], "per_frame": size["per_frame"], "rows": size["rows"],
                      "exports": size.get("exports", 0), "words": learned.measured_words(size),
                      "path": size["path"]},
            "learned_from": frm, "plain_metric": met, "sentence": f"{frm} {met}",
            "this_run": f"{frm} {now}"}


def _has_raw(shoot_name: str, root: Path | None = None) -> bool:
    """Whether this shoot's photographs are still on the disk, by the same rule
    the rest of the pipeline uses: a name is not bytes."""
    base = Path(root) if root is not None else SHOOTS
    d = library.paths(base / shoot_name).raw
    if not d.is_dir():
        return False
    try:
        import archive
        return any(p.suffix.lower() in RAW_EXTS and archive.local(p) for p in d.iterdir())
    except Exception:  # noqa: BLE001
        return any(p.suffix.lower() in RAW_EXTS for p in d.iterdir())


def _carry_venues(mod: dict) -> list[str]:
    """Venues the model in use has and this refit could not measure are kept as
    they were learned.

    A finished shoot's RAWs go to iCloud once it is delivered, and a frame with
    no RAW cannot be measured: without this, the first refit after an archive
    would drop that venue's look, its face band and its measured render lift,
    and the next shoot in that room would start from DxO's defaults with
    nothing saying why. The centre is re-standardised through the fresh mu and
    sd, because those are measured again from whatever was finished this
    time."""
    prev = load() or {}
    pven = (prev.get("venues") or {})
    had = pven.get("shoots") or {}
    ven = mod.setdefault("venues", {"features": VENUE_FEATS, "shoots": {}})
    have = ven.setdefault("shoots", {})
    carried = []
    mu, sd = np.array(ven.get("mu") or []), np.array(ven.get("sd") or [])
    pmu, psd = np.array(pven.get("mu") or []), np.array(pven.get("sd") or [])
    for vid, e in had.items():
        if vid in have:
            continue
        e = dict(e)
        raw = e.get("centre_raw")
        if raw is None and len(pmu) and e.get("centre") is not None:
            raw = [None if c is None else float(c) * float(psd[i]) + float(pmu[i]) for i, c in enumerate(e["centre"])]
            e["centre_raw"] = raw
        if raw is not None and len(mu) == len(raw):
            e["centre"] = [None if c is None else round((float(c) - float(mu[i])) / float(sd[i]), 4) for i, c in enumerate(raw)]
        e["carried"] = "kept as it was learned: none of its frames could be measured this time"
        have[vid] = e
        carried.append(str(e.get("label", vid)))
    return carried


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", type=Path, default=SHOOTS)
    ap.add_argument("--report", action="store_true", help="print the starting edit in use, without refitting")
    a = ap.parse_args()
    if a.report:
        mod = load()
        print(report(mod) if mod else "nothing learned yet; run ./pl taste")
        return
    mod = learn_edit(a.root)
    if not mod:
        return
    print()
    print(report(mod))
    wb = mod["wb"]
    if "w" in wb:
        print(f"\n  white balance: Fluo or AsShot learned from {wb['n']} decisions ({wb['n_fluo']} Fluo) across {wb['scenes']} groups; "
              f"held out by scene (by burst where a shoot is one scene) AUC {wb['auc']:.2f}, accuracy {wb['accuracy']:.2f} against {wb['always_asshot']:.2f} for always-AsShot: used"
              + (f"; Fluo written only at {wb['kelvin_range'][0]}-{wb['kelvin_range'][1]} K camera as-shot, where he chose it" if wb.get("kelvin_range") else "")
              # Which evidence it read, since the camera's green joins only
              # when every frame carries it and he cannot otherwise tell.
              + ("; reads the camera's green as well as its kelvin" if WB_GREEN in (wb.get("features") or [])
                 else "; the camera's green not read: not every one of these frames carries it "
                      "(measured before it was kept, or off a RAW it cannot be read from)"))
    else:
        print(f"\n  white balance: {wb.get('note', '')} (n={wb['n']}" + (f", AUC {wb['auc']:.2f}" if "auc" in wb else "") + "); every frame stays AsShot")
    for v in wb.get("where_used") or []:
        print(f"  white balance on \"{v['label']}\", where it is consulted: right on {v['right']} of "
              f"{v['frames']} finished frames, against {v['asshot']} for leaving every one as the camera shot it")
    ag = wb.get("against_live")
    if ag:
        print(f"  white balance against the one in use, on the {ag['frames']} frames that taught it, same "
              f"{ag['scenes']} scene folds, both held out: {ag['new']:.3f} against {ag['now']:.3f} "
              f"(baseline {ag['always_asshot']:.3f}); {ag['now_right_new_wrong']} frames the one in use gets "
              f"and this does not, {ag['new_right_now_wrong']} the other way")
    print("  exposure type: the rule in presets.exposure_mode (the venue's own type where it has one, else the "
          "sensor's clipped fraction and the subject's brightness), except on a venue whose own fit beat it")
    for name, e in (mod["venues"].get("shoots") or {}).items():
        if e.get("carried"):
            print(f"  venue \"{e.get('label', name)}\": {e['carried']}")
            continue
        print(f"  venue \"{e.get('label', name)}\": {e['n']} finished frames on {e['base']}; faces accepted at L* {e['face_lo']}-{e['face_hi']} (median {e['target_L']}"
              f", from {e['target_n']} {e['targets_from']}); renderer lift {e['gain']} EV ({e['gain_n']} exports); exposure type {e['type'] or 'per frame'}"
              + (f" ({e['type_share']:.0%})" if e['type_share'] else "")
              + "; white balance " + ", ".join(f"{k} {n}" for k, n in sorted((e.get("wb_counts") or {}).items(), key=lambda kv: -kv[1])))
        x = e.get("exposure") or {}
        if x:
            print(f"    its own exposure type: {'used' if x.get('used') else 'not used'} - {x.get('why', '')}")
    # Which frames of a burst he keeps is learned beside this, from the same
    # finished shoots, and checked against every photo he kept before it is
    # used: ./pl learned.
    import learned
    res = learned.submit("edit", mod, source="./pl taste", data=learned.edit_data(mod))
    print("\n" + res["sentence"])




def constants() -> dict:
    """What the photographer applies the same way, frame after frame: the preset's share.

    A numeric slider belongs here only when the photographer moves it on most frames AND
    nothing per frame decides otherwise (no touch model): then the photographer's median of
    those moves is the preset value. A slider with a touch model, or one the photographer
    leaves alone more often than not, stays at the preset's base value and is
    written per frame only where the frame earns it (predict). Categoricals
    are the photographer's majority. This used to hand over every touched-only median, which
    put a -76 highlights pull the photographer uses on hot highlights onto every frame."""
    mod = load()
    if not mod:
        return {}
    out: dict = {}
    for key, e in mod.get("numeric", {}).items():
        if "touch_w" in e or e.get("touch_rate", 1.0) < 0.5:
            continue
        out[key] = e["median"]
    for key, e in mod.get("categorical", {}).items():
        out[key] = e["value"] if e["quoted"] else {"true": True, "false": False}.get(e["value"], e["value"])
    return out

# Wherever he exports to: the shoot's export/, any folder he makes inside
# edit/ (PhotoLab's default is a subfolder beside the RAWs), and iCloud.
#
# The iCloud entry was one "**" glob, so every walk of it crossed the whole
# drive - source trees, app containers, scanned documents, everything anyone
# has ever put in iCloud - and handed cv2.imread whatever came back. Reading
# a person's entire cloud drive to learn a skin tone is not a thing this
# should do without being asked, and on a drive whose files have been evicted
# the walk also pulls them down again. Exports land in CloudDocs itself or one
# folder in (an "edited", a date), so three levels reaches every one of them
# and stops. PHOTO_ICLOUD_DEEP=1 puts the whole-drive walk back for exports
# kept deeper than that - the exact "1", so that setting it to 0 to turn the
# whole-drive walk off does not turn it on.
# PIPELINE_ICLOUD, the same name archive.py reads, so a test or a scratch run
# points every part of the pipeline at the same stand-in folder. Without it
# this walked the real iCloud drive whatever the rest of the run was pointed
# at, which is not a thing a test should do to somebody's cloud drive.
ICLOUD = Path(os.environ.get("PIPELINE_ICLOUD", Path.home() / "Library/Mobile Documents/com~apple~CloudDocs")).expanduser()
EXPORTS = ([ICLOUD / "**/*_DxO.jpg"] if os.environ.get("PHOTO_ICLOUD_DEEP") == "1" else
           [ICLOUD / "*_DxO.jpg", ICLOUD / "*/*_DxO.jpg", ICLOUD / "*/*/*_DxO.jpg"]) + [
           ROOT / "shoots/*/export/**/*_DxO.jpg",
           ROOT / "shoots/*/edit/**/*_DxO.jpg"]


def _read_export_skin(f: str, judge) -> dict:
    """One finished photograph of his, read for skin and for neutral: the rows
    a colour reading is made of, and nothing else. Separate from learn_colour
    below because this is the part that costs a decode and a face pass, and so
    the part worth keeping.

    Lab at float precision (presets.cielab) and each face through
    presets.skin_patch, the one patch and guard the camera JPEG's largest
    face is read by too, because frame_tones sets that face beside what
    this reads and a statistic is only compared against itself."""
    from presets import cielab, skin_patch
    out: dict = {"neutral": None, "skin": []}
    img = cv2.imread(f)
    if img is None:
        return out
    h, w = img.shape[:2]
    if w > 1800:
        img = cv2.resize(img, (1800, int(h * 1800 / w)), interpolation=cv2.INTER_AREA)
    L, A, B = cielab(img)
    n = (np.hypot(A, B) < 18) & (L > 25) & (L < 85)
    if n.mean() > 0.005:
        out["neutral"] = [round(float(A[n].mean()), 4), round(float(B[n].mean()), 4)]
    for fc in [x for x in judge.detect(img) if x.main]:
        got = skin_patch(L, A, B, fc.box)      # None: too small, or not skin (hair, a sleeve, the floor)
        if got is not None:
            out["skin"].append([round(v, 4) for v in got])
    return out


def learn_colour(mark=None) -> dict:
    """Measured off the photographs the photographer has actually finished and sent out.

    Skin occupies a narrow band of colour in any photograph; a face outside it
    reads as wrong to anyone, which makes this checkable rather than a matter of
    opinion. What the photographer's finished work fixes is *where in that band* the photographer sits.

    Each export is read ONCE and its two readings kept beside the frame
    measurements (learned.measured_*), keyed by the file's size and date. He has
    1,300 finished photographs and this used to decode and face-detect every one
    of them on every run, whether or not he had exported anything since."""
    import glob as _g
    import learned
    files = sorted({f for pat in EXPORTS for f in _g.glob(str(pat), recursive=True)})
    store, _ = learned.measured_read()
    judge = None
    add: list[dict] = []
    rows: list[dict] = []
    for i, f in enumerate(files):
        try:
            st = os.stat(f)
            # By the whole path, not the file's name: he exports the same
            # frame to iCloud and into the shoot, and two rows keyed on
            # "TSC05274_DxO.jpg" would overwrite each other turn and turn
            # about and be re-read on every run for ever.
            key = f"skin/{f}"
            m = f"{st.st_size}:{int(st.st_mtime)}"
        except OSError:
            continue
        old = store.get(key)
        if old and old.get("mark") == m and old.get("schema") == MEASURE_SCHEMA:
            rows.append(old)
            continue
        if mark and (i % 25 == 0 or i == len(files) - 1):
            mark("exports", i + 1, len(files))
        if judge is None:
            from faces import FaceJudge
            judge = FaceJudge()
        got = _read_export_skin(f, judge)
        row = {"key": key, "kind": "skin", "mark": m, "schema": MEASURE_SCHEMA, "at": _stamp_now(), **got}
        add.append(row)
        rows.append(row)
    if add:
        learned.measured_add(add)
        print(f"  read {len(add)} of your {len(files)} finished photographs for skin color; the rest were read before")
    sa, sb, sl, na, nb = [], [], [], [], []
    for r in rows:
        if r.get("neutral"):
            na.append(float(r["neutral"][0]))
            nb.append(float(r["neutral"][1]))
        for li, a, b in (r.get("skin") or []):
            sl.append(float(li))
            sa.append(float(a))
            sb.append(float(b))
    if len(sa) < 8:
        return {}
    sa_a, sb_a, sl_a = np.array(sa), np.array(sb), np.array(sl)
    hues = np.degrees(np.arctan2(sb_a, sa_a))
    bands = {}
    for lo, hi, lab in ((0, 25, "darkest"), (25, 45, "mid"), (45, 100, "lightest")):
        sel = (sl_a >= lo) & (sl_a < hi)
        if sel.sum() >= 4:
            bands[lab] = {"n": int(sel.sum()), "hue": round(float(np.median(hues[sel])), 1),
                          "L": round(float(np.median(sl_a[sel])), 1)}
    return {"files": len(files), "faces": len(sa),
            "skin_hue": round(float(np.median(hues)), 2),
            "skin_hue_mad": round(float(np.median(np.abs(hues - np.median(hues)))), 2),
            "by_lightness": bands,
            "skin_a": round(float(np.median(sa)), 2), "skin_b": round(float(np.median(sb)), 2),
            "skin_L": round(float(np.median(sl)), 2),
            "skin_a_mad": round(float(np.median(np.abs(np.array(sa) - np.median(sa)))), 2),
            "skin_b_mad": round(float(np.median(np.abs(np.array(sb) - np.median(sb)))), 2),
            "neutral_a": round(float(np.median(na)), 2) if na else 0.0,
            "neutral_b": round(float(np.median(nb)), 2) if nb else 0.0}


def sure_face(m: dict) -> bool:
    """Whether a frame's largest main face is one to read a colour off: the
    detector sure of it (presets.SURE_FACE), skin-lit (measure() keeps the
    face only at L* 12-85) and coloured enough for a hue (FACE_MIN_C)."""
    from presets import SURE_FACE
    return (m.get("face_b_big") is not None and float(m.get("face_conf_big") or 0) >= SURE_FACE
            and float(m.get("face_C_big") or 0) >= FACE_MIN_C)


# Keys whose value is free text (a name, a date, a UUID), not a vocabulary.
FREE_TEXT = ("Name", "Path", "Date", "CreationDate", "ModificationDate", "ShotDate",
             "Uuid", "Id", "Software", "CafID", "Albums", "contentDescription", "Version",
             "AppliedPresetDisplayName", "AppliedPresetUniqueName", "DisplayName")


_DXO_VOCAB: dict | None = None


def dxo_vocab() -> dict:
    """Every string value DxO's own installation declares, per key: the flat
    string values of every shipped .preset, and the localisation tables that
    enumerate a control's whole vocabulary.

    His folder is not the vocabulary. It holds four ColorRenderingType values
    and four white-balance names out of the 264 and 16 DxO's own tables
    declare, so check_dop refused "Fidelity" -- DxO's own "Neutral color" --
    and every fluorescent name but one, purely because he had not happened to
    use them. What DxO ships is a fact about DxO; what he has used is a fact
    about him, and only the first belongs in a safety check."""
    global _DXO_VOCAB
    if _DXO_VOCAB is not None:
        return _DXO_VOCAB
    import glob as _g
    vocab: dict = {}
    for f in _g.glob("/Applications/DXOPhotoLab*.app/Contents/SharedSupport/Presets/**/*.preset", recursive=True):
        try:
            text = Path(f).read_text(errors="ignore")
        except OSError:
            continue
        for k, v in re.findall(r'^\s*([A-Za-z0-9_]+) = "([^"]*)",\s*$', text, re.M):
            vocab.setdefault(k, set()).add(v)
    # The .strings tables enumerate what a preset never has to mention.
    res = sorted(_g.glob("/Applications/DXOPhotoLab*.app/Contents/Frameworks/DXFEngine.framework/Versions/*/Resources/en.lproj/*.strings"), reverse=True)
    for f in res:
        key = Path(f).stem
        try:
            text = Path(f).read_text(errors="ignore", encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        names = re.findall(r'^"([^"]+)" = "[^"]*";', text, re.M)
        if names:
            vocab.setdefault(key, set()).update(names)
    for k in FREE_TEXT:
        vocab.pop(k, None)
    _DXO_VOCAB = {k: sorted(v) for k, v in vocab.items()}
    return _DXO_VOCAB


def learn_vocab(root: Path = SHOOTS) -> dict:
    """Every string value DxO itself has ever written, per key: what DxO's own
    installation declares (dxo_vocab), plus anything PhotoLab has written into
    a sidecar here.

    A value outside this is one nobody has seen PhotoLab produce. Two such
    values shipped in the preset template for weeks; one of them, a bare string
    where a table belonged, took the whole application down.

    The size cutoff applies only to what was read off the sidecars: a key DxO
    itself enumerates is a controlled vocabulary however long it is, and
    ColorRenderingType's own table runs to 264 entries."""
    vocab: dict = {}
    for f in root.glob("**/*.dop"):
        t = f.read_text(errors="ignore")
        if re.search(r'"Scene \d+"', t):    # ours; only what PhotoLab wrote into it counts
            t = _block(t, "Overrides")
        for k, v in re.findall(r'^\s*([A-Za-z0-9_]+) = "([^"]*)",$', t, re.M):
            vocab.setdefault(k, set()).add(v)
    # Keys whose value is free text rather than a controlled vocabulary.
    for k in FREE_TEXT:
        vocab.pop(k, None)
    out = {k: sorted(v) for k, v in vocab.items() if len(v) <= 12}
    for k, vs in dxo_vocab().items():
        out[k] = sorted(set(out.get(k, [])) | set(vs))
    return out


_DXO_KELVINS: dict | None = None
WB_NUMBERS = ("WhiteBalanceRawTemperature", "WhiteBalanceRawTint",
              "WhiteBalanceRGBTemperature")


def dxo_kelvins() -> dict[str, set[float]]:
    """Every white-balance number DxO's own shipped presets carry.

    DxO's "1 - DxO Style - Natural" and "2 - DxO Standard" both hold
    WhiteBalanceRawTemperature 5400, WhiteBalanceRawTint 0 and
    WhiteBalanceRGBTemperature 5200, and every full sidecar the pipeline
    writes carries them because it starts from a shipped preset. A guard that
    did not know this refused DxO's own default and took every full preset
    down with it, the probe's six arms included. A number DxO ships is
    checkable against DxO by definition."""
    global _DXO_KELVINS
    if _DXO_KELVINS is not None:
        return _DXO_KELVINS
    import glob as _g
    out: dict[str, set[float]] = {k: set() for k in WB_NUMBERS}
    for f in _g.glob("/Applications/DXOPhotoLab*.app/Contents/SharedSupport/Presets/**/*.preset", recursive=True):
        try:
            text = Path(f).read_text(errors="ignore")
        except OSError:
            continue
        for k in WB_NUMBERS:
            for v in re.findall(rf"^\s*{k} = ([-\d.]+),\s*$", text, re.M):
                try:
                    out[k].add(round(float(v), 1))
                except ValueError:
                    continue
    # DxO's own defaults, for a machine with no PhotoLab installed. Read off
    # the two full system presets, not typed from memory.
    if not any(out.values()):
        out = {"WhiteBalanceRawTemperature": {5400.0}, "WhiteBalanceRawTint": {0.0},
               "WhiteBalanceRGBTemperature": {5200.0}}
    _DXO_KELVINS = out
    return out


def measured_kelvins() -> dict[str, set[float]]:
    """Every temperature and tint check_dop will accept: the values DxO's own
    shipped presets carry.

    That is what a number can be checked against. A shipped preset's value is
    DxO's by construction; a number arrived at any other way is a solved
    kelvin -- DxO's scale is not the camera's, and the one published method
    that solves an illuminant from an image's own skin is wrong by 4-12% on
    its own controlled set."""
    return {k: set(v) for k, v in dxo_kelvins().items()}


def check_remarks(text: str) -> list[str]:
    """Things worth saying about a sidecar that are nobody's business to
    refuse. A remark is about whether a setting will do what its author
    expects; a refusal is about whether PhotoLab can open the file. Mixing
    the two makes a validator that vetoes the photographer's own edits."""
    out: list[str] = []
    if re.search(r"^\s*ChannelMixerActive = true,", text, re.M) and not re.search(
            r'ColorModeStyle = "(SepiaTerra|BlackAndWhite)"|ColorRenderingType = "DefaultBW"', text):
        out.append("the channel mixer is on with a color rendering: DxO ships that tool on 25 of its 373 presets "
                   "and every one is monochrome, so it may be doing nothing here")
    return out


def check_structure(text: str) -> list[str]:
    """Only what would make PhotoLab refuse or crash on this file, whoever
    wrote it: the checks that apply as much to a copy of his own edit as to
    something the pipeline composed."""
    return [b for b in check_dop(text, measuring=True) if "is neither a value DxO ships" not in b]


def check_written(text: str) -> list[str]:
    """What must hold in the bytes this tool is about to write, whoever wrote
    the rest of the file.

    check_dop is a question about settings, and on the patch path the
    settings outside the Base are his. Counted over 2026-09-16's 730
    sidecars and the 54 he corrected by hand on 2026-09-18, check_dop has
    something to say about 48 of the 784 that it would not say about their
    Base, and all 48 are the same thing: a white balance he chose is not a
    number DxO ships. 43 carry a temperature in their Overrides, 3 of those
    also a local white balance in a mask, and one is the ManualTemp he
    dialled on TSC04881. Asking check_dop about the whole patched file would
    refuse to write all 48 and leave those edits stranded under a stale
    recipe rather than protect anything. That is why the patch path asks it
    about the composed Base alone -- but the Base is 12 KB of a 16 KB
    sidecar (median over
    2026-09-16's 730), so asking about it alone stopped anything at all being
    checked in the other 3.4 KB the patch had just spliced by regex, which is
    a narrowing nobody asked for.

    These three are what the patch itself can break and what PhotoLab cannot
    survive. It rewrites a Base, a Keywords block, a rating, an orientation,
    two dates and two preset names into a file it did not write; a
    substitution that runs long takes a brace with it, and PhotoLab reads
    every sidecar beside the RAWs at launch and aborts
    on an unbalanced one before there is a window to say which of 1,157 files
    is at fault. None of the three says anything about a setting, so none of
    them can refuse a file for carrying his own edit."""
    bad: list[str] = []
    if re.search(r'AppliedPresetUniqueName = "USER/', text):
        bad.append("references a USER preset, which goes stale and takes PhotoLab down with it")
    m = re.search(r"\n(\t+)Keywords = \{\n((?:.*?\n)*?)\1\},", text)
    if m and re.match(r'^\s*"', m.group(2) or ""):
        bad.append("a keyword is a bare string; DxO writes each one as its own table")
    if text.count("{") != text.count("}"):
        bad.append("unbalanced braces")
    return bad


def check_dop(text: str, measuring: bool = False) -> list[str]:
    """Everything that would make PhotoLab refuse, or crash, on this sidecar.

    measuring=True is for the probe and nothing else. A probe arm is an
    instrument, not a delivery: its whole job is to render a candidate and
    measure what DxO does with it, and an arm that cannot be written cannot
    be measured. The incumbent arm is the look his 443 delivered sidecars
    were actually rendered under, channel mixer and all, so refusing to write
    it would mean the incumbent could never be beaten by evidence -- the
    answer asserted instead of measured.

    It relaxes exactly one rule, the channel mixer's, and nothing else. A
    temperature is still refused under it: the point of the probe is to
    render numbers that can be checked, and a solved kelvin cannot be
    checked however it is rendered. pl build never sets it."""
    bad: list[str] = []
    mod = load() or {}
    # The stored vocabulary is whatever the last refit saw; DxO's own tables
    # are read live beside it, so a name DxO ships is legal the moment DxO
    # ships it and not one refit later. Without this a probe could not write
    # the rendering DxO itself calls "Neutral color".
    vocab = dict(mod.get("vocab") or {})
    dxo = dxo_vocab()
    for k, v in re.findall(r'^\s*([A-Za-z0-9_]+) = "([^"]*)",$', text, re.M):
        allowed = set(vocab.get(k, ())) | set(dxo.get(k, ()))
        if k in vocab and k not in FREE_TEXT and v not in allowed:
            bad.append(f"{k} = {v!r} is not a value DxO has been seen to write ({', '.join(sorted(allowed)[:12])})")
    bad += check_written(text)
    # A local white balance exists in DxO's engine ("Temperature (local)",
    # "Tint (local)" in LocalCorrections.bundle) and occurs in 0 of his 968
    # sidecars. It is the one local control that would put a kelvin back in,
    # on a scale that is not the camera's, with no precedent to check it
    # against. It stays out.
    for k in ("LocalWhiteBalanceRawTemperature", "LocalWhiteBalanceRawTint"):
        if re.search(rf"^\s*{k} = ", text, re.M):
            bad.append(f"{k} is a local white balance: a kelvin on DxO's scale with nothing to check it against, and in 0 of his own sidecars")
    # A global temperature may only be one DxO itself ships, or one HE
    # measured with DxO's own eyedropper. Both are readings of DxO's output
    # and so checkable. A temperature from anywhere else is a solved kelvin:
    # DxO's scale is not the camera's, and the one published method that
    # solves an illuminant from skin is wrong by 4-12% on its own controlled
    # test set (5000 K read as 4456). Three attempts at it here -- from a
    # skin-hue delta, from a camera-scale solver, and from a grey-world
    # estimate of each frame's own light -- made people red or swung 554 K
    # across one room.
    #
    # Shipped values are in the allow-list for a reason that took a build to
    # find: DxO's own "1 - DxO Style - Natural" carries
    # WhiteBalanceRawTemperature 5400, so every full preset the pipeline
    # writes carries it, and a guard that knew only his eyedropper refused
    # DxO's own default and stopped every build and all six probe arms.
    known = measured_kelvins()
    for k in WB_NUMBERS:
        for v in re.findall(rf"^\s*{k} = ([-\d.]+),", text, re.M):
            f = float(v)
            if f == 0.0 and k.endswith("Tint"):
                continue
            if not any(abs(f - x) <= 0.5 for x in known.get(k, ())):
                bad.append(f"{k} = {v} is neither a value DxO ships nor one he measured off a neutral with DxO's own eyedropper "
                           f"({', '.join(str(x) for x in sorted(known.get(k, ()))) or 'none recorded'}): a computed kelvin is not checkable against DxO")
    # The channel mixer on a colour frame used to be refused here. It is not
    # a refusal: it is a remark about a setting, and the photographer's own
    # finished sidecars carry it on every frame of one venue. A validator
    # that rejects his own delivered work is broken, and it broke the tool
    # that carries one of his edits across a burst. Whether the mixer does
    # anything on a colour frame is his to find out and ours to say
    # (check_remarks), never ours to veto.
    # A grading zone with no measured gain behind it is a colour move nobody
    # can account for. His own 17 graded frames are 16 DxO presets applied
    # verbatim and one hand-dialled Master.
    for z, h, s, lm in re.findall(r"ColorGradingParams_(\w+) = \{\s*Hue = ([-\d.]+),\s*Sat = ([-\d.]+),\s*Lum = ([-\d.]+),", text):
        if any(abs(float(x)) > 1e-6 for x in (h, s, lm)):
            bad.append(f"ColorGradingParams_{z} is non-zero with no measured gain behind it")
    return bad


if __name__ == "__main__":
    main()
