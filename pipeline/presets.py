#!/usr/bin/env python3
"""
presets.py - one DxO PhotoLab preset per scene, from what the scene is and
what the light is doing.

The cull groups a shoot into scenes (same place, same light). For each scene
this reads the picks three ways and writes a starting preset:

  what it is     CLIP zero-shot over a list of subjects (a person, a dog, a
                 landscape, food, a building...) and YOLOX for where the
                 subject actually is in the frame.
  what the light CLIP again, over a list of lighting situations (hard sun,
                 overcast, golden hour, tungsten room, neon, backlit...),
                 checked against the camera's own white balance from the RAW
                 multipliers, the cast on the near-neutral pixels, clipping,
                 and the tonal range.
  how it sits    Face brightness (YuNet) for people, subject-box brightness
                 for everything else, in L* on the camera's rendering.

Then a rule table: each subject and each light adds its qualifiers (how much
of the cast to correct, whether to protect skin, ClearView or not, how far to
lift), the measurements set the numbers, and presets.md says what it saw and
what it did. It is meant to be 80% of the edit. Colour taste stays with the
photographer: casts are corrected only as far as the light warrants.

Usage:
    ./pl presets ~/photos/shoots/2026-10-04-lake/raw                # reads the shoot's cull/cull.csv
    ./pl presets ~/photos/shoots/2026-10-04-lake/raw --install      # also copy into DxO's preset folder
    ./pl presets ~/photos/shoots/2026-10-04-lake/raw --xmp          # tag each pick "Scene 03" in its XMP sidecar

The preset file is DxO's own Lua-table text format; the template is the hand-
built lounge preset with its scene-specific settings zeroed.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import statistics
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

import cv2
import taste
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import EXIFTOOL, decision_path, decisions_dir, write_atomic, write_json_atomic  # noqa: E402

# The template every full preset is built from, and where it came from, since
# a file shipped in a public repo has to be able to say. It is a preset SAVED
# OUT OF PhotoLab by the photographer, not a copy of one of DxO's: it declares
# IsSystem = false and carries one language, where every factory preset in
# PhotoLab's own Presets folder declares IsSystem = true and carries seven. It
# holds the same 224 flat keys as DxO's "1 - DxO Style - Natural", 211 of them
# at Natural's own values and 13 at his (an artistic vignette, ClearView off,
# the five Lighting sliders, DeepPRIME, vibrancy 10 and a 3800 K white
# balance), none of which reaches a sidecar: build_preset overwrites every
# flat key from preset_base_dict, which is DxO's shipped preset read at run
# time plus what is evidenced. What this file supplies is the LAYOUT -- the
# tables PhotoLab expects, the HSL slices and the tone-curve points -- which
# is why a saved preset is the right thing to ship and a transcription of
# DxO's own would not be.
TEMPLATE = Path(__file__).resolve().parent / "templates" / "base.preset"
DXO_PRESETS = Path.home() / "Library" / "DxO PhotoLab v10" / "Presets"
RAW_EXTS = {".arw", ".cr2", ".cr3", ".nef", ".dng", ".raf", ".orf", ".rw2"}
MAX_FRAMES = 12          # measured per scene; the rest of the scene gets the same preset
MIN_PICKS = 3            # a scene with fewer picks joins the nearest scene in time
MERGE_K, MERGE_EV = 300, 0.35   # adjacent scenes this close in white balance and exposure share a preset
# FACE_TARGET_L 36 and FACE_BRIGHT_L 52 stood here, both read off his own
# exports in one venue and both unused since the band became published
# (PUBLISHED.FACE_L_LO/HI, _band).

# ------------------------------------------------------------- what it is

# label, prompt, family. The family picks the rule set.
SUBJECTS = [
    ("person",      "a portrait photo of a person",                          "people"),
    ("people",      "a photo of a group of people together",                 "people"),
    ("combat sport", "a photo of two athletes competing in a combat sport",    "people"),
    ("dog",         "a photo of a dog",                                      "pet"),
    ("cat",         "a photo of a cat",                                      "pet"),
    ("bird",        "a photo of a bird or a parrot",                          "pet"),
    ("wildlife",    "a photo of a wild animal",                              "pet"),
    ("landscape",   "a landscape photo of nature, hills, fields or a lake",   "landscape"),
    ("beach",       "a photo of a beach, the sea or a river",                 "landscape"),
    ("city",        "a photo of a city street or buildings",                  "landscape"),
    ("building",    "an architectural photo of a building or an interior",    "landscape"),
    ("night sky",   "a photo of the night sky, stars or the moon",            "night"),
    ("food",        "a photo of a plate of food or a dish",                   "still"),
    ("product",     "a product photo of an object on a surface",              "still"),
    ("flowers",     "a close-up photo of flowers or plants",                  "still"),
    ("car",         "a photo of a car, truck or motorcycle",                  "still"),
    ("sport",       "an action photo of a sport being played",                "people"),
    ("event",       "a photo of a party, concert or crowd at an event",       "people"),
]

# label, prompt, how much of the measured cast to correct (0 keeps the light, 1 neutralises)
LIGHTS = [
    ("hard sun",     "a photo taken in bright direct sunlight with hard shadows",   0.6),
    ("overcast",     "a photo taken outdoors on an overcast, cloudy day",           0.7),
    ("shade",        "a photo taken outdoors in open shade",                        0.8),
    ("golden hour",  "a photo taken at sunset or sunrise in warm golden light",     0.2),
    ("blue hour",    "a photo taken at dusk in blue twilight",                      0.3),
    ("night lights", "a photo taken at night lit by street lights or signs",        0.4),
    ("tungsten",     "a photo taken indoors under warm tungsten lamps",             0.5),
    ("fluorescent",  "a photo taken indoors under fluorescent or office lighting",  1.0),
    ("window",       "a photo taken indoors lit by soft window light",              0.7),
    ("neon",         "a photo lit by coloured neon or stage lights",                0.3),
    ("backlit",      "a backlit photo with the subject in silhouette",              0.5),
    ("flash",        "a photo taken with a direct on-camera flash",                 0.9),
]

# ------------------------------------------------- where the Base comes from
#
# The Base a sidecar carries is DxO's own shipped preset, read from the
# installed PhotoLab at run time, plus the departures listed below and
# nothing else.
#
# It used to be a dict assembled here, and that dict was the second half of
# the same mistake the echo gate fixes in taste.shoot_overrides. Twelve of
# its thirty-one keys departed from the preset his sidecars actually name
# ("1 - DxO Style - Natural"), and eleven of those twelve had no evidence
# behind them at all -- six were rounded copies of the shipped file's own
# numbers (ColorModeContrast 10 for 9.7046410000000005, LightingV3Intensity
# 15 for 15.3526974, DehazingValue 9.73 for 9.727627, LightingV3Highlights
# -14.56 for -14.5605373, MidTones 18, Shadows 10) that had been read back
# out of his edits and recorded as his taste, when they were DxO's defaults
# arriving in his files the way defaults do. Three more were plain
# departures nobody sourced: ProfileGainMapIntensity 0 where DxO ships 100
# (and taste.OPENED already knows PhotoLab materialises that key on open, so
# its 174 votes were never votes), LightingV3BlackPoint -7.5 where DxO ships
# 0 (a pooled median of a per-frame number), and ColorGradingActive true
# where DxO ships false (inert, every grading parameter at zero, and shipped
# on no DxO preset). Reading the preset instead of restating it makes
# "nothing hard-coded by eye" a property of the code rather than a rule
# someone has to keep.
#
# A departure has to earn its place by evidence against the frame's OWN
# Base, which is the test decided() applies: NoiseRemovalMethod is the only
# key that passes it, differing from its Base on 202 sidecars and echoing it
# on none. It is already supplied by taste.travelling(), so DEPARTURES is
# empty, and that is the point.
DEPARTURES: dict = {}

# DxO's colour rendering for photographs of people. Chosen by the
# photographer over DxO's Original (the camera's own), DxO Natural, Fidelity
# and Portrait V2, each written to the same four frames with everything else
# held constant, and confirmed across eighteen frames of one burst.
PORTRAIT_RENDERING = "DxOPortraitV3"

# DxO's own "1 - DxO Style - Natural", frozen from PhotoLab 10, for a machine
# with no PhotoLab installed. shipped() prefers the installed copy.
SHIPPED_FALLBACK = {
    "1 - DxO Style - Natural": {
        "ArtisticVignettingActive": False, "ArtisticVignettingCornerAttenuation": 0,
        "ChannelMixerActive": False, "ChannelMixerRed": 0,
        "ColorGradingActive": False, "ColorModeContrast": 9.7046410000000005,
        "ColorRenderingActive": True, "ColorRenderingType": "DxONatural",
        "ContrastEnhancementActive": False, "ContrastEnhancementGlobalIntensity": 0,
        "DehazingValue": 9.727627, "ExposureActive": False, "ExposureAutoMode": "Manual",
        "ExposureBias": 0, "HazeRemovalActive": True, "LightingActive": True,
        "LightingMode": "V3Custom", "LightingV3BlackPoint": 0,
        "LightingV3Highlights": -14.5605373, "LightingV3Intensity": 15.3526974,
        "LightingV3MidTones": 18, "LightingV3Shadows": 10, "LightingV3WhitePoint": 0,
        "NoiseActive": True, "NoiseRemovalMethod": "standard",
        "OutputSaturatedColorsProtection": 50, "ProfileGainMapIntensity": 100,
        "SelectiveTonalControlActive": True, "VibrancyIntensity": 5,
        "WhiteBalanceRawPreset": "AsShot", "WhiteBalanceRawTint": 0,
        "WhiteBalanceRawTemperature": 5400, "WhiteBalanceRGBTemperature": 5200,
    },
}
_SHIPPED: dict = {}


def shipped(name: str) -> dict:
    """The flat Settings.Base of a preset DxO ships, from the newest PhotoLab
    in /Applications, else the frozen copy.

    Read the same way dxo_lens() reads the lens block, and for the same
    reason: a value DxO wrote is checkable against DxO, and a value typed
    here is not."""
    if name in _SHIPPED:
        return _SHIPPED[name]
    import glob as _g
    out: dict = {}
    for cand in sorted(_g.glob(f"/Applications/DXOPhotoLab*.app/Contents/SharedSupport/Presets/{name}.preset"), reverse=True):
        try:
            text = Path(cand).read_text(errors="ignore")
        except OSError:
            continue
        m = re.search(r"\n(\s*)Base = \{\n(.*?)\n\1\},", text, re.S)
        if not m:
            continue
        depth = 0
        for ln in m.group(2).split("\n"):
            if depth == 0:
                mm = re.match(r"^\s*([A-Za-z0-9_]+) = ([^\n{]+?),\s*$", ln)
                if mm:
                    out[mm.group(1)] = lua_value(mm.group(2))
            depth = max(0, depth + ln.count("{") - ln.count("}"))
        if out:
            break
    _SHIPPED[name] = out or dict(SHIPPED_FALLBACK.get(name) or SHIPPED_FALLBACK["1 - DxO Style - Natural"])
    return _SHIPPED[name]


def base_id(base: dict) -> str:
    """A short hash of the colour- and tone-relevant keys of a Base.

    Stamped onto every calibration measured THROUGH a Base -- the venue's
    render gain, the render's offset on face b*. Those are
    measured as the lift of DxO's render under the Base the pipeline wrote,
    so a Base change invalidates them, and nothing else in the file would
    notice. A calibration whose stamp does not match the Base in hand is not
    used; the pooled constant is, and the note says it is unmeasured here."""
    import hashlib
    keep = {k: v for k, v in base.items()
            if k.startswith(("Color", "Lighting", "Channel", "Vibrancy", "Dehazing", "HazeRemoval",
                             "Contrast", "Selective", "Profile", "Noise", "WhiteBalance", "Exposure", "Output"))
            # Exposure* and WhiteBalance* are per-FRAME decisions written into
            # the Base, so hashing them makes a stamp that identifies a frame
            # rather than a starting point: 21 distinct ids over 200 frames of
            # one venue, against 1 over the 198 of a venue where nothing was
            # decided per frame. A stamp that never matches silently discards
            # the venue's measured render lift and falls back to the pooled
            # constant, and on TSC04583 that is the difference between a face
            # rendering at L* 66.4 (inside the band, left alone) and 70.5
            # (above it, pulled). The starting point is what this identifies.
            and not k.startswith(("Exposure", "WhiteBalance"))}
    return hashlib.sha1(repr(sorted(keep.items())).encode()).hexdigest()[:12]


# What each subject family wants before the light and the numbers have their say.
FAMILY_RULES = {fam: {} for fam in ("people", "pet", "landscape", "night", "still")}
# Empty on purpose. These used to carry a rendering, a vibrancy, a vignette and
# a contrast per family, every one of them a number chosen by eye for subjects
# the photographer has no edits of. The photographer has never set a vignette (0 of 205 frames), never
# changed the rendering from DxO Natural (204 of 205), never moved vibrancy or
# saturated-colour protection (0 of 205). What a frame gets now is the photographer's own
# starting point, learned from the photographer's edits (taste.py), and the family is kept
# only to say in the notes what the scene was read as.
FAMILY_NOTE = {
    "people":    "the photographer's starting point",
    "pet":       "the photographer's starting point; no pet edits of the photographer's to learn from yet",
    "landscape": "the photographer's starting point; no landscape edits of the photographer's to learn from yet",
    "night":     "the photographer's starting point; no night edits of the photographer's to learn from yet",
    "still":     "the photographer's starting point; no still-life edits of the photographer's to learn from yet",
}

# What each light adds on top.
LIGHT_RULES = {
    # The light is read and named for the notes; it sets nothing. The
    # highlight, shadow and warmth numbers that used to sit here were chosen by
    # eye, and on every frame that gets a sidecar they were overridden anyway by
    # the per-frame model fitted to the photographer's own edits (frame_tone). The warmth
    # entries fed a white-balance temperature the photographer has never typed.
    "hard sun":    (dict(), "hard sun"),
    "overcast":    (dict(), "overcast"),
    "shade":       (dict(), "open shade"),
    "golden hour": (dict(), "golden hour"),
    "blue hour":   (dict(), "blue hour"),
    "night lights": (dict(), "night lights"),
    "tungsten":    (dict(), "tungsten"),
    "fluorescent": (dict(), "fluorescent"),
    "window":      (dict(), "window light"),
    "neon":        (dict(), "neon or stage light"),
    "backlit":     (dict(), "backlit"),
    "flash":       (dict(), "direct flash"),
}


# ------------------------------------------------------------- preset text

def lua(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, str):
        return f'"{v}"'
    if isinstance(v, float):
        return f"{v:g}"
    return str(v)


def lua_value(s: str):
    """A value as read out of a sidecar, typed: true/false, a number, or the
    string inside the quotes."""
    s = str(s).strip()
    if s in ("true", "false"):
        return s == "true"
    if s.startswith('"') and s.endswith('"'):
        return s[1:-1]
    try:
        return float(s) if "." in s or "e" in s.lower() else int(s)
    except ValueError:
        return s


def set_key(text: str, key: str, value) -> str:
    pat = re.compile(rf"^(\s*){re.escape(key)} = [^\n{{]*?,$", re.M)
    if not pat.search(text):
        raise KeyError(key)
    return pat.sub(lambda m: f"{m.group(1)}{key} = {lua(value)},", text, count=1)


def set_hsl(text: str, label: str, hue=0, sat=0, lum=0, bounds=None) -> str:
    """One HSL slice of a template-laid-out Base, rewritten. The slice keeps
    the template's key order (Fade*, Hue, Saturation, Luminance, Uniformity,
    Label); the four fade bounds are touched only when given, which is how
    the bounds the photographer set on his own Yellow move (12-78 on
    TSC04667, against DxO's 41-63) reach a Base, at PhotoLab's own precision."""
    if bounds is not None:
        pat = re.compile(rf"FadeInStart = [^,]*,\s*\n(\s*)FadeInEnd = [^,]*,\s*\n\s*FadeOutStart = [^,]*,\s*\n\s*FadeOutEnd = [^,]*,\s*\n\s*"
                         rf"Hue = [^,]*,\s*\n\s*Saturation = [^,]*,\s*\n\s*Luminance = [^,]*,(\s*\n\s*Uniformity = 0,\s*\n\s*Label = \"{label}\")")
        m = pat.search(text)
        if not m:
            raise KeyError(f"HSL {label}")
        ind = m.group(1)
        fis, fie, fos, foe = (repr(float(v)) for v in bounds)
        return (text[:m.start()] + f"FadeInStart = {fis},\n{ind}FadeInEnd = {fie},\n{ind}FadeOutStart = {fos},\n{ind}FadeOutEnd = {foe},\n"
                + f"{ind}Hue = {hue},\n{ind}Saturation = {sat},\n{ind}Luminance = {lum}," + m.group(2) + text[m.end():])
    pat = re.compile(rf"Hue = [^,]*,\s*\n(\s*)Saturation = [^,]*,\s*\n\s*Luminance = [^,]*,(\s*\n\s*Uniformity = 0,\s*\n\s*Label = \"{label}\")")
    m = pat.search(text)
    if not m:
        raise KeyError(f"HSL {label}")
    ind = m.group(1)
    return text[:m.start()] + f"Hue = {hue},\n{ind}Saturation = {sat},\n{ind}Luminance = {lum}," + m.group(2) + text[m.end():]


def set_grading(text: str, which: str, hue=0, sat=0, lum=0) -> str:
    pat = re.compile(rf"(ColorGradingParams_{which} = \{{)\s*Hue = [^,]*,\s*Sat = [^,]*,\s*Lum = [^,]*,(\s*\}})", re.S)
    if not pat.search(text):
        raise KeyError(f"grading {which}")
    return pat.sub(lambda m: f"{m.group(1)}\n        Hue = {hue},\n        Sat = {sat},\n        Lum = {lum},{m.group(2)}", text, count=1)


# The lens corrections are DxO's to make, per frame, from its own optics
# module for that body and lens: distortion, lens vignetting, chromatic
# aberration and lens softness. They are written into every Base exactly as
# DxO's own "2 - DxO Standard" preset carries them (every tool on, in Auto),
# read from the installed PhotoLab when there is one and otherwise from the
# copy below. They were left out of the sidecar for a while on the theory
# that a partial sidecar lets DxO fill them in; it does not: a sidecar
# without them opens with distortion correction OFF (the photographer's
# finding, 18 September), which is not "leaving them to DxO".
DXO_LENS_KEYS = re.compile(r"^(UnsharpMask|Distortion|Vignetting(?!Blur)|ChromaticAberration)\w*$")
DXO_LENS_DEFAULT = {
    "ChromaticAberrationActive": True, "ChromaticAberrationIntensity": 100, "ChromaticAberrationIntensityAuto": True,
    "ChromaticAberrationLateralActive": True, "ChromaticAberrationPurpleActive": False,
    "ChromaticAberrationSize": 4, "ChromaticAberrationSizeAuto": False,
    "DistortionActive": True, "DistortionAnamorphosisKeepEntireImage": False, "DistortionFocus": 128,
    "DistortionIntensity": 1, "DistortionKeepRatio": False, "DistortionType": "Auto", "DistortionTypeAuto": True,
    "UnsharpMaskActive": True, "UnsharpMaskActiveAuto": True, "UnsharpMaskIntensity": 100,
    "UnsharpMaskIntensityOffset": 0, "UnsharpMaskRadius": 0.5, "UnsharpMaskThreshold": 4,
    "VignettingActive": True, "VignettingClipping": 50, "VignettingClippingAuto": True, "VignettingIntensity": 100,
    "VignettingIntensityAuto": True, "VignettingMidFieldIntensity": 0, "VignettingType": "Auto", "VignettingTypeAuto": True,
}
_DXO_LENS: dict | None = None


def dxo_lens() -> dict:
    """DxO's own lens-correction block: the flat lens keys of the installed
    PhotoLab's "2 - DxO Standard" preset (the newest PhotoLab in
    /Applications), else the copy taken from PhotoLab 10."""
    global _DXO_LENS
    if _DXO_LENS is not None:
        return _DXO_LENS
    import glob as _g
    out: dict = {}
    for cand in sorted(_g.glob("/Applications/DXOPhotoLab*.app/Contents/SharedSupport/Presets/2 - DxO Standard.preset"), reverse=True):
        try:
            for k, v in re.findall(r"^\s*([A-Za-z0-9]+) = ([^{\n]*?),\s*$", Path(cand).read_text(errors="ignore"), re.M):
                if DXO_LENS_KEYS.match(k):
                    out[k] = lua_value(v)
        except OSError:
            continue
        if out:
            break
    _DXO_LENS = out if len(out) >= len(DXO_LENS_DEFAULT) else dict(DXO_LENS_DEFAULT)
    return _DXO_LENS


def legal_look(look: dict) -> tuple[dict, list[str]]:
    """A venue's stored look, reduced to what may still reach a sidecar, and
    a line per key that may not.

    A look learned before the echo gate can carry keys that are not his and
    were never checked -- taste.json is only rewritten when the learner runs,
    so a stored look outlives the rule that made it. Filtering it here means
    a stale model degrades to DxO's own starting point with a reason printed,
    instead of halting on check_dop's refusal at write time or, worse,
    writing the value.

    Three classes go, and all three are the standing invariants:

      ChannelMixer* -- DxO ships the channel mixer on 25 of its 373 presets
      and every one of them is monochrome; its own help calls it a
      black-and-white tool. On the action venue it was never his anyway: it
      echoes its own Base on 323 sidecars and differs on none.

      _grading -- a colour-grading table, which only an older learner wrote
      and which check_dop refuses on sight.

      ColorRenderingType -- which rendering to start from is decided by
      measuring DxO's output under each candidate (pl probe), not learned
      from finished edits and not carried by a stored look. Until a probe has
      run, the Base is the preset his own sidecars name."""
    # A rendering the PROBE elected is a different kind of thing from one a
    # look learned, and this is the one place that knows the difference. It
    # was measured off DxO's own exports under the pre-registered rule, so it
    # is put back in here after the learned one is taken out -- otherwise the
    # probe could run, announce a winner, and change nothing, which is where
    # this stood.
    elected = ((taste.load() or {}).get("render") or {}).get("rendering")
    keep, dropped = {}, []
    for k, v in look.items():
        if k == "_grading":
            # The learner stopped producing a colour-grading table (it reports
            # one under _not_a_target now), but a look learned by an older
            # build still carries it, and check_dop refuses every sidecar of
            # the shoot that would have received it. Dropped here with its
            # reason, like the channel mixer, so the shoot degrades to DxO's
            # own grading instead of to no sidecars at all.
            dropped.append("_grading: a color grade is not learned from finished edits any more; "
                           "a look from an older build carried one, and it is left out")
        elif k.startswith("_"):
            keep[k] = v
        elif k.startswith("ChannelMixer"):
            dropped.append(f"{k} {v}: DxO ships the channel mixer only on monochrome presets, and it echoes its own Base on every frame here")
        elif k == "ColorRenderingType":
            dropped.append(f"{k} {v}: a rendering is elected by measuring DxO's output (pl probe), not by a stored look")
        else:
            keep[k] = v
    if elected:
        keep["ColorRenderingType"] = elected
    return keep, dropped


def preset_base_dict(base_name: str | None = None, settings: dict | None = None) -> dict:
    """Everything the Base of a built preset carries, in the order it is
    layered: DxO's shipped preset, its own lens block, the evidenced
    departures, what may travel to any shoot, then this scene's settings."""
    return {**shipped(base_name or NATURAL), **dxo_lens(), **DEPARTURES, **taste.travelling(),
            **{k: v for k, v in (settings or {}).items() if not k.startswith("_")}}


def build_preset(name: str, settings: dict, base_name: str | None = None) -> str:
    text = TEMPLATE.read_text()
    text = re.sub(r'DisplayName = "[^"]*"', f'DisplayName = "{name}"', text, count=1)
    for k, v in preset_base_dict(base_name, settings).items():
        text = set_key(text, k, v)
    text = set_hsl(text, "Orange", sat=settings.get("_orange_sat", 0))
    text = set_hsl(text, "Red", sat=settings.get("_red_sat", 0), lum=settings.get("_red_lum", 0))
    text = set_grading(text, "Shadows", 0, 0, 0)
    return text


# ------------------------------------------------------------- reading the scene

class SceneReader:
    """CLIP zero-shot for subject and light, YOLOX for where the subject is."""

    def __init__(self, quality=None):
        from quality import Quality
        from cull import SubjectDetector, SUBJECT_MODEL
        self.q = quality if quality is not None else Quality()   # the cull hands its own in: CLIP loads once, not twice
        self.ok = self.q._load_clip()
        self.subj = SubjectDetector(SUBJECT_MODEL) if SUBJECT_MODEL.exists() else None
        self._text = None

    def _texts(self):
        if self._text is None:
            import torch
            import open_clip
            tok = open_clip.get_tokenizer("ViT-L-14-quickgelu")
            with torch.no_grad():
                t = self.q._clip.encode_text(tok([p for _, p, _ in SUBJECTS] + [p for _, p, _ in LIGHTS]).to(self.q._dev))
                t = t / t.norm(dim=-1, keepdim=True)
            self._text = t.float().cpu().numpy()
        return self._text

    def classify(self, imgs: list[np.ndarray]) -> tuple[np.ndarray, np.ndarray]:
        """Per image: probabilities over SUBJECTS and over LIGHTS."""
        if not self.ok or not imgs:
            return np.zeros((len(imgs), len(SUBJECTS))), np.zeros((len(imgs), len(LIGHTS)))
        import torch
        from PIL import Image
        with torch.no_grad():
            x = torch.stack([self.q._pre(Image.fromarray(cv2.cvtColor(im, cv2.COLOR_BGR2RGB))) for im in imgs]).to(self.q._dev)
            e = self.q._clip.encode_image(x)
            e = (e / e.norm(dim=-1, keepdim=True)).float().cpu().numpy()
        sims = e @ self._texts().T * 100.0
        ns = len(SUBJECTS)

        def softmax(z):
            z = z - z.max(axis=1, keepdims=True)
            p = np.exp(z)
            return p / p.sum(axis=1, keepdims=True)
        return softmax(sims[:, :ns]), softmax(sims[:, ns:])

    def subject_box(self, img: np.ndarray) -> tuple[int, int, int, int] | None:
        if self.subj is None:
            return None
        boxes = self.subj.detect(img)
        return max(boxes, key=lambda b: b[2] * b[3]) if boxes else None


def Y(L: float) -> float:
    """CIE L* to relative luminance."""
    return ((L + 16) / 116) ** 3


def Lstar(y: float) -> float:
    """Relative luminance to CIE L*."""
    return 116.0 * max(y, 1e-6) ** (1.0 / 3.0) - 16.0


# --------------------------------------------------------- published targets
#
# Where a skilled edit puts a face and a neutral, in numbers a program can
# hit. These are the targets; his finished frames are the envelope around
# them and the evidence of what he will not tolerate, not the aim.
#
# Every entry names the STATISTIC it was measured on, and a target may only
# ever be compared against its own statistic. That rule is not pedantry: the
# same broadcast faces read 15-23 cd/m2 as whole segmented skin and 49 cd/m2
# as a forehead-and-cheek patch (BT.2408-8 Annex 1 against Annex 4), about
# 1.1 stop apart, so mixing the two invents a stop of error that is not in
# the picture.
#
# The one result that matters most across all of it: hue is the tight
# coordinate and chroma is the loose one. Observers agree on skin hue to a
# few degrees and disagree widely on chroma -- Zeng & Luo's 85% tolerance
# ellipse has its major axis tilted 62 degrees off a*, i.e. it runs along
# chroma. Hold hue; let the rest float.
class PUBLISHED:
    # Preferred skin centre. Peng, Luo et al., CIC28 (2020), "Preferred skin
    # reproduction centres for different skin groups": 90 observers, 10
    # models across four skin-colour types, 52,920 judgements, chromaticities
    # at D65 / CIE 1964 10 deg -- the directly comparable illuminant, because
    # measure() reads sRGB Lab, which is D65. Zeng & Luo (CIC18 2010; Color
    # Res. Appl. 38(1):30-45, 2013) give hue 48.8 at D50, and its tone groups
    # reach 49.5, so the union of every published centre is 46 to 49.7.
    # STATISTIC: a face-region mean over a skin mask.
    SKIN_HUE = 46.0
    # SKIN_HUE_TOL is NOT a published figure and says so here rather than in
    # a comment that rounds it off. No paper states a tolerance in degrees.
    # It is read off Zeng & Luo's 85% tolerance ellipse: observer variance is
    # about 4 delta-E*ab with the major axis tilted 62 degrees off a*, so the
    # short (hue) semi-axis of that ellipse subtends roughly 3 degrees at
    # C*ab 25. An inference from a published measurement, not a measurement.
    SKIN_HUE_TOL = 3.0
    # The band an arm or a face is judged against: the union of the published
    # centres, widened by that tolerance at each end, so neither paper is
    # privileged. 46 - 3 = 43 at one end and 49.7 + 3 = 52.7 at the other.
    # It lives here rather than being reassembled at each call site: probe.py
    # was recomputing it by hand and the comment above claimed 46 +/- 3 spans
    # 46-49.7, which it does not.
    SKIN_HUE_LO = 43.0
    SKIN_HUE_HI = 52.7
    # Peng's C*ab 25. A CEILING to cut toward, never a floor to raise to:
    # no DxO control in this pipeline raises skin chroma, and 74% of his
    # delivered faces already read under 25, so a saturation cut can only
    # move a face further from this centre. Zeng & Luo give 31.9 at D50; the
    # two disagree and CIC28 attributes the gap to makeup, so chroma is the
    # coordinate to hold loosely.
    SKIN_C = 25.0
    # Preferred L* by skin-colour type (Peng): 67.3, 65.1, 58, 39.8. Used as
    # a RANGE and never as a single value: naming one of the four means
    # classifying a subject's skin type, which this pipeline does not do and
    # should not learn to do. A 27-unit spread, and dark skin is supposed to
    # stay dark.
    # STATISTIC: face region, the same one _band and decide_exposure use.
    FACE_L_LO = 39.8
    FACE_L_HI = 67.3
    # Report ITU-R BT.2408-8 (11/2024) Annex 4: 713 faces from 387 images
    # across 8 broadcasters, forehead and cheek with specular shine
    # excluded, 61-82 %SDR through BT.1886. REPORTED, NEVER ACTUATED --
    # it is a lit-patch statistic and nothing here corrects toward it.
    LIT_L_LO = 62.1
    LIT_L_HI = 83.0
    # A neutral surface reads a* = b* = 0 against the encoding white by
    # construction; the only question is how much cast is visible. 1.5 is
    # ISO 12647-7's contract-proof grey-balance average delta-H, the
    # tightest documented grey-axis tolerance. For comparison the
    # illuminant-estimation literature calls 1 degree of angular error
    # unnoticeable, 2 "good enough for complex images" (Hordley) and 3
    # "noticeable but acceptable" (Funt).
    NEUTRAL_C_MAX = 1.5
    # The just-noticeable difference between two candidate renderings is
    # 0.06 x the larger angular error (Gijsenij, Gevers & Lucassen, JOSA A
    # 26(10):2243, 2009). A probe arm must beat the incumbent by this much
    # to be called a difference at all.
    JND_FRAC = 0.06


# ----------------------------------------------------- the sensor, in stops
#
# ISO 12232 renders an 18% grey at L* 50. This is the anchor for a frame with
# no face, not a target for one with a face: where a face goes is
# PUBLISHED.FACE_L_LO..FACE_L_HI.
ZONE_V = 50.0
# DxO's rendering lifts a face beyond the exposure slider: measured on the 16
# finished exports that still have their RAW and sidecar, 1.22-1.47 EV under
# the photographer's usual Smart Lighting (median 1.40; the camera JPEG's own lift at the same
# raw luminance is 0.97-1.49). One global offset, calibrated outside the shoot
# the rest was learned on; re-measure it from any export + sidecar + RAW.
#
# 1.3 and not the 1.40 median, on purpose, until it is measured again. The
# number moves the exposure written on every frame of every shoot by the same
# amount, so it is only changed against the frames it is fitted to, and those
# are his finished exports with their RAWs beside them, which a run pointed at
# a copy of the library does not have. The one venue with its own figure (the
# action shoot's 1.51 EV) keeps it only while the Base it was measured through
# is the Base being composed (gain_base below); its RAWs are archived, so it
# cannot be re-measured, and the pooled constant stands for it too. Moving
# 1.3 to 1.4 is 0.1 EV brighter everywhere at once: a real change of look that
# should be made from a fresh measurement on his machine, not from a comment.
RENDER_GAIN = 1.3
# Below this share of photosites at saturation a highlight-recovery mode has
# nothing to act on (the photographer's Manual scenes: 0.05% of photosites; the auto scenes
# 0.24-0.78%), so the frame is corrected by hand from the face.
CLIP_FLOOR = 0.002
# Among clipped frames, a face or subject this dark in linear terms got Medium
# recovery from the photographer rather than Strong (0.87 held out by scene, AUC 0.93).
DARK_Y = 0.042
# A face narrower than this share of the frame is not worth a mask.
MASK_MIN_FRAC = 0.03
# A face this far from target after the global correction gets its own mask.
MASK_MIN_EV = 0.5
# The furthest down one global exposure move goes here, and so the furthest
# down any frame's written bias may sit: a guard on the slider, not a
# measurement. decide_exposure clamps to it and so does the levelling that
# runs after it, so the two cannot add up to a bias neither would write alone.
BIAS_FLOOR = -2.0


def to_sensor(x: float, y: float, flip: int) -> tuple[float, float]:
    """A point in the DISPLAYED frame (normalized) to the sensor's unrotated
    frame, which is where PhotoLab reads mask prompts and crops. On a
    landscape frame the two coincide; on a portrait frame a prompt written in
    display coordinates landed, precisely, on a ceiling tile. libraw flip
    codes: 6 = the display is the sensor turned 90 degrees clockwise, 5 =
    counter-clockwise, 3 = upside down."""
    if flip == 6:
        return y, 1.0 - x
    if flip == 5:
        return 1.0 - y, x
    if flip == 3:
        return 1.0 - x, 1.0 - y
    return x, y


def to_sensor_rect(x: float, y: float, w: float, h: float, flip: int) -> tuple[float, float, float, float]:
    """A rectangle {x, y, w, h} in the displayed frame to the sensor's frame."""
    if flip == 6:
        return y, 1.0 - (x + w), h, w
    if flip == 5:
        return 1.0 - (y + h), x, h, w
    if flip == 3:
        return 1.0 - (x + w), 1.0 - (y + h), w, h
    return x, y, w, h


def exif_flip(orientation: int) -> int:
    """EXIF Orientation (1, 3, 6, 8) to the libraw flip code used above."""
    return {3: 3, 6: 6, 8: 5}.get(int(orientation or 1), 0)


def _rot(a: np.ndarray, flip: int) -> np.ndarray:
    """Sensor array to the orientation rawpy's render and the camera JPEG use
    (libraw flip codes; 6 verified bit-exact against rawpy's own rotation)."""
    if flip == 6:
        return np.rot90(a, -1)
    if flip == 5:
        return np.rot90(a, 1)
    if flip == 3:
        return np.rot90(a, 2)
    return a


# A person box at least this share of the largest one's area is a subject
# too (the second subject); smaller ones are people behind the subject.
SUBJECT_BODY = 0.5
# A face the detector is this sure of is taken at its word; below it, the face
# counts only when no surer face is a subject. The two non-faces YuNet has
# passed as main faces on a gym's 154 keepers were a raised hand (0.66, TSC05263)
# and a hood (0.64, TSC04865); the twelve keepers whose only face sits under
# 0.70 are real faces, so a doubtful face is still measured when it is all
# there is.
SURE_FACE = 0.70
# Where a head sits in its person box, measured on 130 faces the landmarker
# read on the same shoot: width 0.13-0.39 of the box's (5th-95th percentile),
# centre in the top 0.09-0.27 of its height, within 0.3 of its width from the
# box's centre line. A face that sits nowhere like that in any box that
# contains it is something inside a person's box that is not their head.
HEAD_W = (0.13, 0.5)
HEAD_Y = 0.35
HEAD_X = 0.3


def heads(faces: list, boxes: list) -> dict:
    """Face index -> the person box it is the head of (one head per box, the
    best fit first), -1 for a face no box contains (the detector missed a
    person cropped at the frame edge), None for a face inside a box that
    does not sit in it like a head."""
    cand: list[tuple[float, int, int]] = []
    contained: set[int] = set()
    for i, f in enumerate(faces):
        x, y, w, h = f.box
        cx, cy = x + w / 2, y + h / 2
        for j, b in enumerate(boxes):
            if not (b[0] <= cx <= b[0] + b[2] and b[1] <= cy <= b[1] + b[3]):
                continue
            contained.add(i)
            wr, yo, xo = w / b[2], (cy - b[1]) / b[3], abs(cx - (b[0] + b[2] / 2)) / b[2]
            if wr > HEAD_W[1] or yo > HEAD_Y or xo > HEAD_X:
                continue
            cand.append((xo + max(0.0, yo - 0.2) + 3 * max(0.0, HEAD_W[0] - wr), i, j))
    own: dict[int, int | None] = {}
    taken: set[int] = set()
    for _, i, j in sorted(cand):
        if i in own or j in taken:
            continue
        own[i] = j
        taken.add(j)
    for i in range(len(faces)):
        if i not in own:
            own[i] = None if i in contained else -1
    return own


def subject_faces(faces: list, boxes: list | None) -> list:
    """The faces that belong to the subject.

    Each face is matched to the person box it is the head of (heads), and
    the subject is the largest person with a head; faces of people at least
    SUBJECT_BODY of that size count, the rest are spectators. The biggest
    person in a two-person action frame is often the one with his back to the
    camera, so the reference is the biggest person with a FACE, never the
    biggest box: anchored on the box alone, 26 of a gym's 154 keepers lost
    their only face. A face inside someone's box that does not sit there
    like a head (a hand held up, a spectator over a shoulder) is not that
    person's and is dropped; a face no box contains at all is kept, the
    detector having missed the person, not the face. When no face sits in
    any box like a head (two people on the ground) the boxes say nothing and
    every main face counts, as when there are no boxes. Faces the detector
    is sure of (SURE_FACE) are settled first; the doubtful ones count only
    when no sure face qualified."""
    faces = [f for f in faces if not getattr(f, "in_animal", False)]
    if not boxes:
        return list(faces)
    area = lambda b: b[2] * b[3]  # noqa: E731
    for tier in ([f for f in faces if f.conf >= SURE_FACE], [f for f in faces if f.conf < SURE_FACE]):
        if not tier:
            continue
        own = heads(tier, boxes)
        fitted = [i for i, j in own.items() if j is not None and j >= 0]
        if not fitted:
            out = list(tier)
        else:
            ref = max(area(boxes[own[i]]) for i in fitted)
            out = [f for i, f in enumerate(tier) if own[i] == -1 or (own[i] is not None and area(boxes[own[i]]) >= SUBJECT_BODY * ref)]
        if out:
            return out
    return []


def linear_measure(raw_path: Path, faces: list, sbox, pv_wh: tuple[int, int], boxes: list | None = None) -> dict | None:
    """What the sensor recorded, in stops: every main face's luminance (largest
    first), the subject's, the frame's, and the share of photosites at
    saturation. The camera JPEG's L* is a fixed function of this in the face
    range (within 0.1 EV); the RAW adds true clipping, which is what decides
    whether a highlight-recovery mode has anything to do."""
    try:
        import rawpy
        with rawpy.imread(str(raw_path)) as r:
            flip = int(r.sizes.flip)
            raw = r.raw_image_visible.astype(np.float32)
            black = float(np.mean(r.black_level_per_channel))
            white = float(r.white_level)
            # Sony bodies saturate a few counts under the nominal white level
            # (16372 of 16383 on the ILCE-6500): the spike is the true ceiling.
            hi = raw[raw >= 0.95 * white]
            sat = white
            if hi.size > 1000:
                vals, counts = np.unique(hi, return_counts=True)
                if counts.max() >= 100:
                    sat = float(vals[np.argmax(counts)])
            n = _rot((raw - black) / max(sat - black, 1.0), flip)
            rgb = r.postprocess(half_size=True, use_camera_wb=True, no_auto_bright=True, gamma=(1, 1), output_bps=16)
    except Exception:  # noqa: BLE001
        return None
    lin = rgb.astype(np.float32) / 65535.0
    Yl = 0.2126 * lin[..., 0] + 0.7152 * lin[..., 1] + 0.0722 * lin[..., 2]
    pw, ph = pv_wh
    s = Yl.shape[1] / pw                               # preview -> render
    out: dict = {"clip_any": float((n >= 0.999).mean()), "frame_Y": float(np.median(Yl)), "faces": [], "flip": flip}
    # The subject's faces (subject_faces): the detector's word, arbitrated by
    # the person boxes, and nothing about whether the landmarker could read
    # the face. Readability once gated this, and nine of a gym's keepers with
    # a plain face between two raised hands measured nothing. A face's own clipping
    # is skin at the clip point on all three channels; a saturated red object
    # or a white wall inside the box saturates one channel and once put
    # "skin at 250" on seven frames of clean skin.
    readable = subject_faces(faces, boxes)
    for f in sorted(readable, key=lambda f: -f.box[2] * f.box[3]):
        x, y, bw, bh = f.box
        x0, x1, y0, y1 = x + 0.2 * bw, x + 0.8 * bw, y + 0.2 * bh, y + 0.85 * bh
        patch = Yl[max(0, int(y0 * s)):int(y1 * s), max(0, int(x0 * s)):int(x1 * s)]
        if patch.size < 100:
            continue
        rgb_patch = lin[max(0, int(y0 * s)):int(y1 * s), max(0, int(x0 * s)):int(x1 * s)]
        blown = float((rgb_patch.min(axis=2) >= 0.98).mean()) if rgb_patch.size else 0.0
        out["faces"].append({"Y": float(np.median(patch)), "cx": (x + bw / 2) / pw, "cy": (y + bh / 2) / ph,
                             "frac": bw / pw, "clip": blown})
    if out["faces"]:
        out["face_Y"] = out["faces"][0]["Y"]
    if sbox is not None:
        x, y, bw, bh = sbox
        patch = Yl[max(0, int(y * s)):int((y + bh) * s), max(0, int(x * s)):int((x + bw) * s)]
        if patch.size:
            out["subject_Y"] = float(np.median(patch))
    # A grey-world illuminant estimate stood here: the least-chromatic quarter
    # of the mid-tones, averaged, divided by the camera's own multipliers and
    # pushed through rgb_xyz_matrix into XYZ, so that a Planckian search could
    # turn it into a temperature. It is removed, and nothing replaces it.
    #
    # Two reasons, and either alone is enough. It is a solved kelvin: the
    # temperature came out of camera space and reached a sidecar through one
    # body-wide scale ratio measured on a single frame, which is the thing
    # this pipeline is not allowed to do, and the one published method that
    # estimates an illuminant from an image's own skin is wrong by 4-12% on
    # its own controlled set (5000 K read as 4456; Wang, Zhu, Liu & Luo,
    # CIC31 2023). And the estimator itself is the frame average: the same
    # table puts grey-world last of every method tested, at skin-pixel
    # delta-E 45.58 against 8.46 for a skin-driven estimate, because
    # neutralising the average puts the error onto the faces, which is the
    # one place it is least tolerated.
    #
    # Measured here before it came out, on five frames of one room: it solved
    # 5241 to 5796 K, a 554 K spread, and 5516 K on the very frame whose
    # neutral he read at 4742 K with DxO's own eyedropper.
    return out


# Kept for the no-face anchor only: _band no longer uses it, because the
# band a face is held to is published and does not need a tolerance invented
# around a midpoint.
TOLERANCE_EV = 0.5


def _band(target_L: float, band: tuple | None) -> tuple[float, float]:
    """The lightness a face may render at without being corrected.

    The published range, on every venue: preferred L* by skin-colour type is
    39.8 to 67.3 (PUBLISHED.FACE_L_LO/HI), and a face inside it is left
    alone. It used to be the p10-p90 of his own delivered faces per venue,
    which made his placement the standard to hit; it is now the envelope
    that gets reported beside the decision, not the aim.

    Nothing in the published work licenses a single band per venue -- every
    source that addresses lightness conditions it on skin type, not on the
    room. The one venue band this replaces that was never checked against a
    delivered face at all is the portraits venue's target_L of 33.7, which
    sits 6.1 L* below the darkest published preferred lightness.

    A face's OWN statistic decides: this is the face-region reading, which
    is what Peng measured and what decide_exposure works in. The lit-patch
    reading is reported against BT.2408 and never corrected toward."""
    del target_L, band                   # both were his placement, not a target
    return PUBLISHED.FACE_L_LO, PUBLISHED.FACE_L_HI


def _stops_to_band(y: float, lo: float, hi: float, gain: float) -> float:
    """EV to bring a face of linear luminance y, after the renderer's lift, to
    the nearer edge of the band; 0 inside it."""
    rendered = Lstar(y * 2 ** gain)
    if lo <= rendered <= hi:
        return 0.0
    edge = lo if rendered < lo else hi
    return math.log2(Y(edge) / max(y, 1e-4)) - gain


# ------------------------------------------------ one frame per core
#
# Everything a sidecar decision needs from a frame is measured here, in a
# worker process: faces and landmarks on the camera JPEG, the subject and
# animal boxes, measure(), the camera's kelvin, and the RAW in linear terms.
# None of it touches a GPU (LibRaw and four small CPU nets), and done one
# frame at a time it used one core of a twelve-core machine; decode and
# landmarks scale nearly linearly across processes.
_WORKER: dict = {}


def _worker_models() -> tuple:
    if not _WORKER:
        from faces import FaceJudge
        from cull import SubjectDetector, SUBJECT_MODEL
        cv2.setNumThreads(1)          # one frame per core; OpenCV's own threads would contend for them
        _WORKER["judge"] = FaceJudge()
        _WORKER["subj"] = SubjectDetector(SUBJECT_MODEL) if SUBJECT_MODEL.exists() else None
    return _WORKER["judge"], _WORKER["subj"]


def measure_frame(job: tuple) -> tuple[str, dict | None]:
    """(name, preview path or "", decoded-fallback path or "", raw path or "") ->
    (name, {"m": measure() + kelvin, "lin": linear_measure() or None}) or (name, None)."""
    name, preview, fallback, raw = job
    judge, subj = _worker_models()
    img = cv2.imread(preview) if preview else None
    if img is None and raw and fallback:
        from faces import decode
        img = decode(Path(raw), Path(fallback))
    if img is None:
        return name, None
    h, w = img.shape[:2]
    if w > 1800:
        img = cv2.resize(img, (1800, int(h * 1800 / w)), interpolation=cv2.INTER_AREA)
        h, w = img.shape[:2]
    faces = [f for f in judge.detect(img) if f.main]
    pairs = subj.detect_classes(img) if subj is not None else []
    judge.judge(img, faces, render=img, animal_boxes=[b for b, c in pairs if c in (15, 16)])   # landmarks; a dog's face is not a face to expose for
    boxes = [b for b, _ in pairs]
    people = [b for b, c in pairs if c == 0]           # a face's owner is a person, never the dog beside him
    sbox = max(boxes, key=lambda b: b[2] * b[3]) if boxes else None
    is_raw = bool(raw) and Path(raw).suffix.lower() in RAW_EXTS
    m = dict(measure(img, faces, sbox), kelvin=kelvin_from_raw(Path(raw)) if is_raw else None)
    return name, {"m": m, "lin": linear_measure(Path(raw), faces, sbox, (w, h), boxes=people) if is_raw else None}


def measure_frames(jobs: list[tuple], progress=None) -> dict:
    """measure_frame over many frames, a frame per core (common.pool_map)."""
    from common import pool_map
    return dict(pool_map(measure_frame, jobs, progress=progress))


AUTO_MODES = ("StrongHighlightRecovery", "MediumHighlightRecovery")


def exposure_mode(lin: dict, prefer: str | None = None) -> str | None:
    """The exposure type the rule writes, and nothing else: the one place the
    choice between by-hand and DxO's two highlight recoveries is made.

    A venue where he was near unanimous about the type (Manual on 289 of 291
    gym frames, the gym's lights blowing out being nothing he corrects) keeps
    his type. Otherwise: nothing saturated, Manual - a highlight-priority mode
    has nothing to act on; something saturated, Medium where the face or the
    subject is dark and Strong where it is not.

    decide_exposure asks this; so does the starting edit's learner
    (taste.venue_exposure), which replays the rule on his finished frames to
    see whether a venue's own fit beats it there. None when the sensor
    reading the rule needs was never taken (a frame measured before the
    learner kept `clip_any`, whose RAW has since gone) - unknown, not Manual."""
    if prefer == "Manual":
        return "Manual"
    clip = lin.get("clip_any")
    if clip is None:
        return None
    if clip < CLIP_FLOOR:
        return "Manual"
    y = lin.get("face_Y")
    ref = y if y else lin.get("subject_Y")
    return "MediumHighlightRecovery" if (ref is not None and ref < DARK_Y) else "StrongHighlightRecovery"


def decide_exposure(lin: dict, target_L: float, gain: float = RENDER_GAIN, prefer: str | None = None, band: tuple | None = None,
                    mode: str | None = None, why: str = "") -> tuple[dict, float, str]:
    """WHICH correction and HOW MUCH, from what the sensor recorded.

    Nothing saturated: DxO's highlight-priority modes have nothing to act on,
    so the frame is corrected by hand, by the stops between the largest face
    and the target after the renderer's own lift. Something saturated: the
    auto mode, Medium where the face or subject is dark, Strong otherwise,
    and no bias under it. Returns the keys, the global EV, and a note.

    WHICH is exposure_mode's, unless `mode` says otherwise: the venue's own
    fitted exposure type (taste.predict_exposure), used only on the shoot
    that taught it, where it beat both the rule and the venue's commonest
    type on scenes it had not seen, and only once the starting edit carrying
    it passed the check. `why` is what the note says about where that answer
    came from. HOW MUCH is always the sensor's."""
    if mode not in ("Manual",) + AUTO_MODES:
        # A reading with no clip_any never reaches here from frame_tones
        # (linear_measure always takes it); Manual is the branch that writes
        # the least when it somehow does.
        mode, why = exposure_mode(lin, prefer) or "Manual", ""
    keys, ev, note = _expose(lin, target_L, gain, band, mode)
    return keys, ev, (f"{note}; {why}" if why else note)


def _expose(lin: dict, target_L: float, gain: float, band: tuple | None, mode: str) -> tuple[dict, float, str]:
    """HOW MUCH, once decide_exposure has said which."""
    y = lin.get("face_Y")
    lo, hi = _band(target_L, band)
    if mode == "Manual":
        if not y:
            return {"ExposureActive": False, "ExposureAutoMode": "Manual", "ExposureBias": 0}, 0.0, "no face of the subject to measure: exposure left as it is"
        # The true shortfall and the value that may be WRITTEN are two
        # different numbers, and the note prints the true one. The clamp is a
        # guard on the slider, not a measurement: printing the clamped figure
        # said "+1.00 EV short" on frames that were +2.24, +2.23 and +2.22
        # short (TSC05274, TSC05275, TSC05396), which is wrong by up to 1.24
        # EV on exactly the frames where the decision is hardest, and the
        # comment below says the decision is his.
        want = _stops_to_band(y, lo, hi, gain)
        ev = round(max(BIAS_FLOOR, min(1.0, want)), 2)
        clipped = abs(want - ev) > 0.005
        where = f"face at L* {Lstar(y):.0f} in the raw, {Lstar(y * 2 ** gain):.0f} rendered"
        if ev > 0:
            # A face under the band while the rest of the frame is where it
            # should be is a LOCAL problem, and the published order of
            # operations gives a local problem a local tool: primary
            # contrast, primary colour, qualification, shapes (Van Hurkman,
            # Color Correction Handbook); profile, white balance, exposure,
            # HSL, local masks in raw teaching. So it goes to the face's own
            # mask, and the frame keeps its exposure.
            #
            # This branch used to be sourced to habit -- "he has never typed
            # a positive bias, 0 of 496 frames" -- which is not a reason,
            # and the instruction to edit like someone skilled puts exactly
            # that kind of rule in question. It survives on the argument
            # above and not on the count. What is NOT decided here is
            # whether a frame that is dark everywhere should get a positive
            # global lift: measured against the published band that would
            # ask a median +0.89 EV of 114 of 152 delivered frames, which is
            # the largest change anything here could make, so the EV is
            # printed and the decision is his.
            return {"ExposureActive": False, "ExposureAutoMode": "Manual", "ExposureBias": 0}, 0.0, f"{where}: under {lo:.0f}, {want:+.2f} EV short, left to a face mask"
        if ev == 0:
            return {"ExposureActive": False, "ExposureAutoMode": "Manual", "ExposureBias": 0}, 0.0, f"{where}: inside {lo:.0f}-{hi:.0f}, left alone"
        return ({"ExposureActive": True, "ExposureAutoMode": "Manual", "ExposureBias": ev}, ev,
                f"{where}; by hand {ev:+.2f} EV to {lo:.0f}-{hi:.0f}"
                + (f" (the face is {want:+.2f} EV out; {ev:+.2f} is as far as one exposure move goes here)" if clipped else ""))
    word = "Medium" if mode.startswith("Medium") else "Strong"
    return ({"ExposureActive": True, "ExposureAutoMode": mode}, 0.0,
            f"{float(lin.get('clip_any') or 0) * 100:.2f}% of photosites saturated: {word} highlight recovery"
            + (f" (face at L* {Lstar(y):.0f} in the raw)" if y else ""))


def face_masks(lin: dict, target_L: float, ev_global: float, gain: float = RENDER_GAIN, band: tuple | None = None) -> list[dict]:
    """One AI mask per face the global correction leaves more than MASK_MIN_EV
    from target, lifting or lowering that face alone. The largest face set the
    global EV, so this is for the second face in a different light, and for
    every face under an auto mode. Prompted at the face's centre in the
    displayed frame, which is how PhotoLab stores its own AI masks."""
    masks = []
    lo, hi = _band(target_L, band)
    for i, f in enumerate(lin.get("faces") or []):
        if f["frac"] < MASK_MIN_FRAC or f["Y"] <= 0.003:
            continue
        resid = _stops_to_band(f["Y"] * 2 ** ev_global, lo, hi, gain)
        if abs(resid) < MASK_MIN_EV:
            continue
        sx, sy = to_sensor(f["cx"], f["cy"], int(lin.get("flip") or 0))   # PhotoLab reads the prompt in the sensor's frame
        ev = round(max(-1.0, min(1.0, resid)), 2)
        # "short" carries what the mask could NOT do. A mask is clamped to one
        # stop, and 18 of the 37 the action venue gets sit exactly at it, 16
        # of them genuinely clipped: a note that says "1 face mask" and
        # nothing else reads as a solved frame when the face is still short.
        masks.append({"name": f"Face {i + 1}", "x": round(sx, 6), "y": round(sy, 6),
                      "ExposureBias": ev, "short": round(resid - ev, 2)})
    return masks


def _uid() -> str:
    return str(uuid.uuid4()).upper()


def ai_mask(m: dict) -> dict:
    """PhotoLab's AI mask, as it writes one: a positive prompt point and the
    reference colour at the same spot, selectivity off. Only the numbers and
    the ids differ from the photographer's own."""
    x, y = m["x"], m["y"]
    return {"UIParams": {"Name": m["name"]},
            # "short" is what the clamp cost, carried for the note only: it is
            # not a DxO key and must never reach Corrections.
            "Corrections": {k: v for k, v in m.items() if k not in ("name", "x", "y", "short")},
            "Options": {"Disabled": False, "Opacity": 100}, "Id": _uid(),
            "Geometry": [{"MaskValue": 0, "Type": "Background"},
                         {"Type": "Group", "UIParams": {"Id": _uid(), "Name": "AI Mask", "Negate": False},
                          "ChildGeometry": [{"ChrominanceSelectivity": 50, "Complement": False, "Disabled": False,
                                             "FeatherIntensity": 0, "LuminanceSelectivity": 50, "MaskValue": 1, "Opacity": 1,
                                             "Prompts": [{"Type": "PositivePoint", "Value": [x, y]}],
                                             "ReferenceColorPoint": [x, y], "Type": "SemanticMask",
                                             "UIParams": {"Id": _uid(), "MaskSelectivityActive": False}}]}]}


def lua_lines(v, depth: int) -> list[str]:
    """A value laid out as PhotoLab lays it out: keys in alphabetical order,
    a named table's entries one tab deeper, an anonymous table's brace and
    entries at the same depth."""
    ind = "\t" * depth
    out: list[str] = []
    if isinstance(v, dict):
        for k in sorted(v):
            if isinstance(v[k], (dict, list)):
                out.append(f"{ind}{k} = {{")
                out += lua_lines(v[k], depth + 1)
                out.append(f"{ind}}},")
            else:
                out.append(f"{ind}{k} = {lua(v[k])},")
    elif isinstance(v, list):
        for e in v:
            if isinstance(e, dict):
                out.append(f"{ind}{{")
                out += lua_lines(e, depth)
                out.append(f"{ind}}},")
            else:
                out.append(f"{ind}{lua(e)},")
    else:
        out.append(f"{ind}{lua(v)},")
    return out


def partial_base(settings: dict) -> str:
    """A Base block carrying what the pipeline decided and DxO's own lens
    corrections; everything else comes from the preset the sidecar names.
    Partial sidecars are how DxO's own presets work, and how a camera-body
    rendering is left to DxO; the lens block cannot be left out (dxo_lens)."""
    settings = {**dxo_lens(), **settings}          # every Base carries DxO's own lens corrections, on and in Auto
    return "\t\t\t\tBase = {\n" + "\n".join(lua_lines(settings, 5)) + "\n\t\t\t\t},\n"


# DxO's own names for these, from its string table
# (DXFEngine.framework/.../en.lproj/ColorRenderingType.strings): "Original" is
# "DxO camera profile", category "Generic rendering", menu "From camera (%@)"
# -- DxO's own profile for that body, not the manufacturer's rendering, which
# is what the comment here used to claim. "Fidelity" is DxO's "Neutral color",
# shipped as the partial preset "4 - Neutral colors".
STANDARD = "2 - DxO Standard"
NATURAL = "1 - DxO Style - Natural"    # the preset every one of his 968 sidecars names
NEUTRAL_COLORS = "4 - Neutral colors"  # ColorRenderingType "Fidelity", and no white-balance key

# DxO's own rendering block out of "2 - DxO Standard", frozen from PhotoLab
# 10.0.2's copy for a machine with no PhotoLab installed. standard_rendering()
# prefers the installed copy, the same way shipped() and dxo_lens() do.
STANDARD_RENDERING = {
    "ColorRenderingActive": True, "ColorRenderingDCPMode": "DxO", "ColorRenderingDCPProfile": "",
    "ColorRenderingICCProfile": "", "ColorRenderingIntensity": 100, "ColorRenderingIntent": 25,
    "ColorRenderingType": "Original",
    # LocalParameters and LocalParametersActive are set per frame; this is the
    # third key DxO writes beside them and never omits.
    "LocalParametersVersion": 2,
}


def standard_rendering() -> dict:
    """The rendering keys of the preset a no-venue sidecar NAMES.

    The sidecar says AppliedPresetUniqueName = "DEFAULTS/2 - DxO Standard.
    preset" and the scene line announces "DxO camera-body rendering", but the
    Base written on that path carried neither ColorRenderingActive nor
    ColorRenderingType: it was taste.travelling() (one key, the noise method)
    and DxO's lens block, so the rendering was a label and nothing else. This
    file's own rule is that the Base carries every setting explicitly and the
    applied-preset name is only a label, and that rule was not being kept
    here. Read off the installed preset, never typed.

    The fallback is checked rather than trusted: shipped() answers an unknown
    name with the Natural block, whose ColorRenderingType is DxONatural, so
    taking its rendering unchecked would quietly write the wrong one on a
    machine with no PhotoLab."""
    got = {k: v for k, v in shipped(STANDARD).items()
           if k.startswith("ColorRendering") or k == "LocalParametersVersion"}
    return got if got.get("ColorRenderingType") == "Original" else dict(STANDARD_RENDERING)


def build_partial_preset(name: str, settings: dict) -> str:
    """A preset with only these keys set, on top of whatever the user applies."""
    return ("Preset = {\n  Version = \"12.0\",\n  IsRAWOnly = false,\n  IsSystem = false,\n  LocalizedInfo = {\n    en = {\n"
            f"      DisplayName = \"{name}\",\n    }},\n  }},\n  Settings = {{\n    Version = \"21.0\",\n    Base = {{\n"
            + "".join("      " + ln.lstrip("\t") + "\n" for ln in lua_lines({**dxo_lens(), **settings}, 0)) + "    },\n  },\n}\n")


def export_face_L(shoot: Path, judge, quiet: bool = True) -> float | None:
    """Where the photographer put faces on the frames of this shoot the photographer has
    exported: the median finished L* of the largest face. The first frame the photographer
    finishes in a venue sets that venue's target.

    CACHED, because it reads and runs a face detector over every finished JPEG
    of the shoot: 356 exports on the September card, 215 seconds. Nothing that
    calls it needs it fresh more than once, and one caller -- the studio's
    "standardise this burst" button -- pays it before printing its first word,
    so every burst he prepared cost him three and a half silent minutes for an
    answer that had not changed since the last one.

    The key is the set of exports it measured: their count and the newest
    mtime among them. Export one more frame and it measures again; open a
    second burst and it does not."""
    import glob as _g
    stems = {p.stem for p in shoot.glob("*") if p.suffix.lower() in RAW_EXTS}
    if not stems:
        return None
    found = []
    for pat in taste.EXPORTS:
        for f in _g.glob(str(pat), recursive=True):
            if Path(f).name.split("_DxO")[0] in stems:
                try:
                    found.append((f, Path(f).stat().st_mtime))
                except OSError:
                    pass
    if not found:
        return None
    key = {"n": len(found), "newest": round(max(m for _, m in found), 3)}
    here = shoot.parent if shoot.name == "raw" else shoot
    cache = (here / "cull" if (here / "cull").is_dir() else here / "_cull") / "face_L.json"
    try:
        was = json.loads(cache.read_text())
        if was.get("key") == key:
            return was.get("target_L")
    except (OSError, ValueError):
        pass
    if not quiet:
        print(f"  reading the faces on your {len(found)} finished exports, to put this burst's "
              f"faces where you put theirs. Measured once per export, then remembered.", flush=True)
    vals = []
    for pat in taste.EXPORTS:
        for f in _g.glob(str(pat), recursive=True):
            if Path(f).name.split("_DxO")[0] not in stems:
                continue
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
                continue
            x, y, bw, bh = [int(v) for v in faces[0].box]
            inner = img[y + int(0.2 * bh):y + int(0.85 * bh), x + int(0.2 * bw):x + int(0.8 * bw)]
            if inner.size < 100:
                continue
            vals.append(float(np.median(cv2.cvtColor(inner, cv2.COLOR_BGR2LAB)[..., 0]) * (100 / 255)))
    out = float(np.median(vals)) if vals else None
    try:
        write_json_atomic(cache, {"key": key, "target_L": out})
    except Exception:  # noqa: BLE001
        pass            # a cache that cannot be written is slow, not wrong
    return out


def kelvin_from_raw(path: Path) -> float | None:
    """The camera's as-shot multipliers against its daylight ones, on a mired
    scale. Within a few hundred kelvin of what DxO shows for as-shot."""
    try:
        import rawpy
        with rawpy.imread(str(path)) as r:
            cw, dw = r.camera_whitebalance, r.daylight_whitebalance
        k = (cw[0] / cw[2]) / (dw[0] / dw[2])
        mired = 182.0 * (1.0 / k) ** 0.567
        return 1e6 / mired
    except Exception:  # noqa: BLE001
        return None


def measure(img: np.ndarray, faces: list, box) -> dict:
    lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB).astype(np.float32)
    L, A, B = lab[..., 0] * (100 / 255), lab[..., 1] - 128, lab[..., 2] - 128
    h, w = L.shape
    m: dict = {"frame_L": float(np.median(L)), "range": float(np.percentile(L, 95) - np.percentile(L, 5))}
    mx = img.max(axis=2)
    m["clip"] = float((mx >= 250).mean())
    m["black"] = float((mx <= 3).mean())
    neutral = (np.hypot(A, B) < 18) & (L > 25) & (L < 85)
    if neutral.mean() > 0.005:
        m["cast_a"], m["cast_b"] = float(A[neutral].mean()), float(B[neutral].mean())
        # The same reading in polar form, which is how the tolerance is
        # published: a neutral surface reads a* = b* = 0 by construction, and
        # ISO 12647-7 allows a contract proof an average delta-H of 1.5 on
        # its grey-balance patches (PUBLISHED.NEUTRAL_C_MAX). The distance is
        # what says whether a cast is visible; the angle says which way it
        # runs, and a green-yellow fluorescent cast runs near 120 degrees.
        m["neutral_C"] = float(math.hypot(m["cast_a"], m["cast_b"]))
        m["neutral_h"] = float(math.degrees(math.atan2(m["cast_b"], m["cast_a"])) % 360.0)
    # Coloured light sources: chroma of the bright pixels.
    bright = L > 80
    if bright.mean() > 0.002:
        m["light_chroma"] = float(np.hypot(A[bright], B[bright]).mean())
    fl, rg, fa, fb = [], [], [], []
    for f in faces:
        x, y, fw, fh = [int(v) for v in f.box]
        inner = img[y + int(0.2 * fh):y + int(0.85 * fh), x + int(0.2 * fw):x + int(0.8 * fw)]
        if inner.size < 100:
            continue
        ilab = cv2.cvtColor(inner, cv2.COLOR_BGR2LAB).astype(np.float32)
        li = ilab[..., 0] * (100 / 255)
        fl.append(float(np.percentile(li, 50)))
        fa.append(float(np.median(ilab[..., 1] - 128)))
        fb.append(float(np.median(ilab[..., 2] - 128)))
        b, g, r = inner.reshape(-1, 3).mean(axis=0)
        rg.append(float(r / max(g, 1.0)))
    if fl:
        m["face_L"], m["face_rg"] = min(fl), max(rg)   # the darkest face and the reddest decide
        # Where the skin actually sits in colour, which is checkable against the
        # locus skin occupies in every photograph ever taken, not against taste.
        m["face_a"], m["face_b"] = float(np.median(fa)), float(np.median(fb))
    # The largest main face on its own, which is where yellow light shows
    # (the medians above pool every face). Kept only when it is skin-lit
    # (L* 12-85, as learn_colour reads his exports).
    big = max(faces, key=lambda f: f.box[2] * f.box[3]) if faces else None
    if big is not None:
        x, y, fw, fh = [int(v) for v in big.box]
        inner = img[y + int(0.2 * fh):y + int(0.85 * fh), x + int(0.2 * fw):x + int(0.8 * fw)]
        if inner.size >= 100:
            ilab = cv2.cvtColor(inner, cv2.COLOR_BGR2LAB).astype(np.float32)
            Lb = float(np.median(ilab[..., 0]) * (100 / 255))
            if 12 <= Lb <= 85:
                Ab, Bb = ilab[..., 1] - 128, ilab[..., 2] - 128
                ab, bb = float(np.median(Ab)), float(np.median(Bb))
                m.update(face_L_big=Lb, face_a_big=ab, face_b_big=bb, face_C_big=math.hypot(ab, bb),
                         face_hue_big=math.degrees(math.atan2(bb, ab)), face_conf_big=float(getattr(big, "conf", 1.0)))
                # The SECOND face statistic, from the same patch, because the
                # published lightness numbers are not all measured the same
                # way. face_L_big above is the median of the face box, which
                # is what Peng's preferred L* is comparable to. This one is
                # the lit diffuse patch the broadcast work measures: ITU-R
                # BT.2408-8 Annex 4 reads forehead and cheek with specular
                # shine excluded, and its own Annex 1 reads whole segmented
                # skin on the same faces about 1.1 stop lower. A specular
                # highlight is bright AND desaturated (it takes the
                # illuminant's colour), so both conditions have to hold
                # before a pixel is dropped as shine; dropping on lightness
                # alone also throws away bright diffuse skin, and the two
                # definitions differ by about 4 L* on his delivered faces.
                # This is REPORTED against PUBLISHED.LIT_L_LO/HI and never
                # corrected toward -- no decision in this file reads it.
                Lp = ilab[..., 0] * (100 / 255)
                Cp = np.hypot(Ab, Bb)
                shine = (Lp >= np.percentile(Lp, 97)) & (Cp <= np.percentile(Cp, 25))
                lit = Lp[~shine]
                if lit.size:
                    # The MEAN, because that is the statistic the number it
                    # gets printed beside was measured as: BT.2408-8 Annex 4
                    # averages 50x50 px forehead-and-cheek patches over 713
                    # faces. It was a p75, which is a different instrument
                    # and read a median 59.8 where the mean of the same
                    # pixels read 47.2, flipping the "inside the broadcast
                    # band" verdict on 14 of 40 faces on the choice of
                    # statistic alone. It is still not the same PATCH -- this
                    # is the whole face box less shine, not forehead and
                    # cheek -- so the note reports the two side by side and
                    # no longer says "inside" or "outside".
                    m["face_lit_L"] = float(np.mean(lit))
                    m["face_lit_from"] = ("mean of the face box with shine dropped (pixels both in the top 3% of L* "
                                          "and the bottom quartile of chroma); BT.2408 reads forehead and cheek, so "
                                          "the statistic matches and the patch does not")
    # The subject, whatever it is: its box, or the middle of the frame.
    if box is not None:
        x, y, bw, bh = box
        sub = L[max(0, y):min(h, y + bh), max(0, x):min(w, x + bw)]
    else:
        sub = L[h // 4:3 * h // 4, w // 4:3 * w // 4]
    if sub.size:
        m["subject_L"], m["subject_p90"] = float(np.median(sub)), float(np.percentile(sub, 90))
    return m


def decide(ms: list[dict], kelvins: list[float], isos: list[int], subject: str, light: str) -> tuple[dict, list[str]]:
    """Measurements plus what the scene is -> preset settings, and the notes that explain them."""
    s: dict = {}
    notes: list[str] = []
    med = lambda k: statistics.median(m[k] for m in ms if k in m)  # noqa: E731
    have = lambda k: any(k in m for m in ms)  # noqa: E731
    family = next((fam for lab, _, fam in SUBJECTS if lab == subject), "still")
    with_faces = sum(1 for m in ms if "face_L" in m)
    faces = family == "people" and with_faces >= max(1, len(ms) // 2)
    switched = False
    if with_faces >= max(1, len(ms) // 2) and family != "people":
        faces, family, switched = True, "people", True   # faces in most frames: they are the subject, whatever else is in it

    # 1. The subject family sets the base.
    s.update(FAMILY_RULES[family])
    notes.append(f"{subject}" + (", but faces in most frames, so people rules" if switched else "") + f" → {FAMILY_NOTE[family]}")

    # 2. The light adds to it.
    lrule, lnote = LIGHT_RULES.get(light, (dict(), ""))
    for k, v in lrule.items():
        s[k] = v
    if lnote:
        notes.append(lnote)
    cast_frac = next((c for lab, _, c in LIGHTS if lab == light), 0.5)
    s["_family"], s["_faces"], s["_cast_frac"] = family, faces, cast_frac

    # 3. Exposure: reported, never set here. On 198 of the photographer's 205 edits it is
    #    either the auto highlight-recovery mode with no bias (149) or a manual
    #    bias with auto off (48); the preset carries DxO's own auto mode (shipped),
    #    and a scene bias written under it was stacked on top of it or ignored,
    #    and aimed at targets (a face at L* 36, under 52) chosen by eye from one
    #    evening. What the faces measure is still said, for the notes.
    if faces:
        cur = med("face_L")
        notes.append(f"faces sit at L* {cur:.0f} across the setup; each frame decides its own exposure, type and amount, from what it measures")
    elif have("subject_L"):
        notes.append(f"subject sits at L* {med('subject_L'):.0f}")

    # 4. Highlights, blacks and contrast: measured and reported, never set
    #    here, for the reason step 3 gives for exposure. What stood here was
    #    a highlights slider of -(20 + 4000 x the clipped share), a white
    #    point of -6 above 1% clipped and fine contrast +15 under an L* spread
    #    of 35, every one of them chosen by eye; and on the learned path the
    #    scene preset's Base is re-indented into every sidecar, so they
    #    reached every frame of the scene on top of DxO's own starting point.
    #    Clipping is acted on per frame instead, from the RAW's own count of
    #    saturated photosites (decide_exposure picks DxO's highlight
    #    recovery), which is a measurement of the thing itself.
    clip = med("clip")
    if clip > 0.002:
        notes.append(f"{clip * 100:.1f}% of the camera JPEG's pixels clipped; the tone sliders stay at the starting "
                     "point's, and each frame chooses highlight recovery from its own RAW")
    if med("black") > 0.12 and family in ("night", "people") and not faces:
        notes.append(f"{med('black') * 100:.0f}% of the frame is black; left alone, it is a night scene")
    if have("range") and med("range") < 35 and family in ("landscape", "still", "pet"):
        notes.append(f"flat tonal range (L* spread {med('range'):.0f}); contrast left at the starting point's")

    # 5. White balance. The scene preset leaves it AsShot; the frame decides
    #    (frame_tone) whether it switches to Fluo, the way the photographer does. No
    #    temperature is written anywhere: the photographer has never typed one, and the number
    #    that used to be computed here from the neutral cast, in DxO's units
    #    with a coefficient nobody could check, was one of the two things that
    #    turned skin red. What was measured is still said, for the notes.
    s.pop("_warm", None)
    if kelvins:
        k = statistics.median(kelvins)
        notes.append(f"camera as-shot about {k:.0f} K; left as shot, each frame switches to Fluo on its own evidence")
    if have("cast_b"):
        cb = med("cast_b")
        if abs(cb) > 4:
            notes.append(f"neutrals read {'yellow' if cb > 0 else 'blue'} (b* {cb:+.0f})")
    if have("cast_a"):
        ca = med("cast_a")
        if abs(ca) > 5:
            notes.append(f"neutrals read {'magenta' if ca > 0 else 'green'} (a* {ca:+.0f})")

    # 6. Skin under coloured light: measured and reported, never corrected.
    #    On 205 hand-edited frames the photographer has moved no HSL channel and never touched
    #    saturated-colour protection, and desaturating the red in skin is the
    #    edit the photographer turned down by name. So the red is the photographer's. What is measured goes
    #    in the notes, for the frames where the photographer will want to look.
    if faces:
        rg = med("face_rg")
        if rg > 2.4:
            notes.append(f"skin is red-channel-only (R/G {rg:.1f}): the light, left as the photographer leaves it")
        elif rg > 1.7:
            notes.append(f"skin runs warm (R/G {rg:.1f})")
    elif have("light_chroma") and med("light_chroma") > 25:
        notes.append("colored light sources in frame")

    if isos:
        iso = int(statistics.median(isos))
        notes.append(f"ISO {iso}: DeepPRIME" + (", worth it" if iso >= 1600 else ", could be plain HQ to save export time"))
    # The rendering, for a shoot of people. DxO ships colour renderings built
    # for skin and the pipeline used to start from the camera's own instead,
    # which is what "reproduce the camera" means: the warm skin the camera
    # made is faithfully kept. Put side by side on four frames of a room that
    # had been reading yellow -- the camera's Original, DxO Natural, Fidelity,
    # Portrait V2 and Portrait V3, everything else held constant -- the
    # photographer chose Portrait V3, then confirmed it over eighteen frames
    # of a burst ("none look disgustingly yellow", 18 September). It is keyed
    # on the SUBJECT and not on the room: a portrait rendering is a statement
    # about photographing people, so it travels to any shoot of people and to
    # no shoot without them. A pet, a landscape or a still life keeps the
    # preset's own rendering, DxO having published nothing to prefer there.
    if faces:
        s["ColorRenderingType"] = PORTRAIT_RENDERING
        notes.append(f"{PORTRAIT_RENDERING}: DxO's own portrait rendering, chosen over the camera's own and three others side by side")
    s["_faces"], s["_family"] = faces, family
    return s, notes


# ------------------------------------------------------------- main

def default_out(folder: Path) -> Path:
    """A shoot laid out as <shoot>/raw keeps its cull beside the RAWs, not inside
    them, so PhotoLab never indexes the picks twice."""
    return folder.parent / "cull" if folder.name == "raw" else folder / "_cull"


def load_rows(cull_csv: Path) -> list[dict]:
    """The cull's own verdict per frame, with the photographer's last word on
    top of it. The studio keeps star overrides in organize.json; a frame
    kept or dropped by hand has to reach the sidecar as kept or dropped, or
    PhotoLab opens showing the machine's opinion instead of the person's.

    Asked for through decision_path, because that file moved to decisions/
    and a read of the old name that found nothing would not fail: it would
    write every sidecar to the machine's opinion and say nothing."""
    with cull_csv.open() as fh:
        rows = list(csv.DictReader(fh))
    over = decision_path(cull_csv.parent, "organize.json")
    if over.exists():
        try:
            photos = json.loads(over.read_text()).get("photos", {})
        except (OSError, ValueError):
            photos = {}
        for r in rows:
            v = photos.get(r["file"], {}).get("rating")
            if v is not None:
                r["rating"] = str(int(v))
    return rows


def tag(probs: np.ndarray, table: list) -> tuple[str, float, list[str]]:
    """Scene-level label from per-frame probabilities: the mean, plus runners-up over 0.2."""
    if probs.size == 0:
        return table[0][0], 0.0, []
    p = probs.mean(axis=0)
    order = np.argsort(-p)
    top = table[int(order[0])][0]
    others = [f"{table[int(i)][0]} {p[i]:.2f}" for i in order[1:3] if p[i] > 0.2]
    return top, float(p[order[0]]), others


def write_for_editor(shoot: Path, rows: list[dict], name: str, settings: dict, notes: list,
                     editor: str, force: bool = False, quiet: bool = False) -> int:
    """The same starting edit, in another editor's sidecar. DxO is handled by
    write_dops, which has to splice PhotoLab's own preset format; these three are
    written from the neutral Edit in editors.py.

    The name and the rule both come from editors.py rather than from here. This
    function used to work out the path itself and send every .xmp to <stem>.xmp,
    which is the Lightroom name: darktable reads <whole file name>.xmp, so the
    cull's stars reached darktable for none of the 198 frames in the 2026-09-05
    shoot, and the file landed on top of the Lightroom sidecar besides. It also
    replaced whatever was already there under --force, which is the one thing
    the .dop path will not do."""
    import editors as ed
    e = ed.from_dxo(name, settings, notes)
    wrote = kept = 0
    for r in rows:
        raw = shoot / r["file"]
        rating = min(3, int(r.get("rating") or 0))    # the cull's 5 is a tier, never five stars
        out = ed.sidecar_path(editor, raw)
        if out.exists() and not force:
            continue
        text = ed.render(editor, e, rating=rating,
                         existing=out.read_text(errors="ignore") if out.exists() else "")
        if text is None:
            kept += 1                                 # someone else's sidecar; --force is not for his files
            continue
        # Whole or not at all, for the same reason as the .dop below: a
        # sidecar cut off half way is a file the editor chokes on, and the
        # frame it belongs to is the one thing it will not name.
        write_atomic(out, text)
        wrote += 1
    if kept and not quiet:
        print(f"  {kept} sidecar{'s' if kept != 1 else ''} your editor wrote: left as {'they are' if kept != 1 else 'it is'}")
    return wrote


def build(shoot: Path, out_dir: Path, install: bool = False, xmp: bool = False, dop: bool = False, force: bool = False, quiet: bool = False, quality=None,
          crop: str | None = None, level: bool = False, picks_only: bool = False, editor: str = "dxo", mine_too: bool = False) -> list[dict]:
    rows = load_rows(out_dir / "cull.csv")
    previews = out_dir / "previews"
    from faces import FaceJudge, decode
    judge = FaceJudge()
    reader = SceneReader(quality=quality)
    scenes: dict[str, list[dict]] = {}
    for r in rows:
        scenes.setdefault(r["scene"], []).append(r)
    preset_dir = out_dir / "presets"
    preset_dir.mkdir(parents=True, exist_ok=True)
    for old in preset_dir.glob("*.preset"):
        old.unlink()

    # 1. Read every scene.
    measured: list[dict] = []
    ordered = sorted(scenes.items(), key=lambda kv: min(r["shot_at"] for r in kv[1]))
    for si, (scene_id, rs) in enumerate(ordered, 1):
        print(f"@@ presets {si - 1} {len(ordered)}", flush=True)
        picks = [r for r in rs if r["rating"] in ("3", "5")] or [r for r in rs if r["rating"] == "2"] or [r for r in rs if r["rating"] != "0"]
        if not picks:
            continue
        sample = sorted(picks, key=lambda r: -float(r["quality"]))[:MAX_FRAMES]
        ms, kelvins, imgs = [], [], []
        for r in sample:
            stem = Path(r["file"]).stem
            pv = previews / f"{stem}.jpg"
            img = cv2.imread(str(pv)) if pv.exists() else decode(shoot / r["file"], out_dir / "decoded" / f"{stem}.jpg")
            if img is None:
                continue
            h, w = img.shape[:2]
            if w > 1800:
                img = cv2.resize(img, (1800, int(h * 1800 / w)), interpolation=cv2.INTER_AREA)
            faces = [f for f in judge.detect(img) if f.main]
            ms.append(measure(img, faces, reader.subject_box(img)))
            imgs.append(img)
            if (shoot / r["file"]).suffix.lower() in RAW_EXTS:
                k = kelvin_from_raw(shoot / r["file"])
                if k:
                    kelvins.append(k)
        if not ms:
            continue
        ps, pl = reader.classify(imgs)
        isos: list[int] = []
        try:
            ex = json.loads(subprocess.run([EXIFTOOL, "-j", "-ISO", *[str(shoot / r["file"]) for r in sample]],
                                           capture_output=True, text=True).stdout or "[]")
            isos = [int(e["ISO"]) for e in ex if str(e.get("ISO", "")).isdigit()]
        except Exception:  # noqa: BLE001
            pass
        measured.append({"scene": scene_id, "rows": rs, "picks": picks, "ms": ms, "kelvins": kelvins, "isos": isos,
                         "ps": ps, "pl": pl, "start": min(r["shot_at"] for r in picks)})

    def settle(g: dict) -> None:
        g["subject"], g["subject_p"], g["subject_also"] = tag(g["ps"], SUBJECTS)
        g["light"], g["light_p"], g["light_also"] = tag(g["pl"], LIGHTS)
        g["settings"], g["notes"] = decide(g["ms"], g["kelvins"], g["isos"], g["subject"], g["light"])

    def absorb(g: dict, m: dict) -> None:
        for k in ("rows", "picks", "ms", "kelvins", "isos"):
            g[k] = g[k] + m[k]
        g["ps"] = np.vstack([g["ps"], m["ps"]]) if len(m["ps"]) else g["ps"]
        g["pl"] = np.vstack([g["pl"], m["pl"]]) if len(m["pl"]) else g["pl"]
        g["scenes"] += m["scenes"]
        g["start"] = min(g["start"], m["start"])
        settle(g)

    # 2. Merge: small scenes join their neighbour, and adjacent scenes that read
    #    the same (subject family, light, white balance, exposure) share a preset.
    groups: list[dict] = []
    for m in measured:
        m["scenes"] = [m["scene"]]
        settle(m)
        small = len(m["picks"]) < MIN_PICKS
        if groups:
            g = groups[-1]
            same = (m["settings"]["_family"] == g["settings"]["_family"] and m["light"] == g["light"]
                    and abs(m["settings"].get("WhiteBalanceRawTemperature", 0) - g["settings"].get("WhiteBalanceRawTemperature", 0)) <= MERGE_K
                    and abs(m["settings"].get("ExposureBias", 0) - g["settings"].get("ExposureBias", 0)) <= MERGE_EV)
            if same or (small and len(g["picks"]) >= MIN_PICKS and m["settings"]["_family"] == g["settings"]["_family"]) or (small and len(g["picks"]) < MIN_PICKS):
                absorb(g, m)
                continue
        groups.append(m)
    changed = True
    while changed and len(groups) > 1:
        changed = False
        for i, g in enumerate(groups):
            if len(g["picks"]) >= MIN_PICKS:
                continue
            j = i - 1 if i > 0 else i + 1
            absorb(groups[j], g)
            del groups[i]
            changed = True
            break

    # 3. Write.
    if install:
        DXO_PRESETS.mkdir(parents=True, exist_ok=True)
        for old in DXO_PRESETS.glob("Cull *.preset"):
            old.unlink()
        # And write_atomic's leftovers from a killed run. This folder belongs to
        # PhotoLab, not to us, so anything of ours that a crash left behind has
        # to be swept by the pattern that made it: the sweep above only knows
        # the finished name.
        for old in DXO_PRESETS.glob(".Cull *.preset.*.tmp"):
            old.unlink()
    report: list[dict] = []
    xmp_tagged = xmp_kept = 0
    # With finished edits of the photographer's on this shoot the look is learned from them;
    # without, a shoot gets DxO's own camera-body rendering and only what the
    # sensor decides. The first frame the photographer finishes here sets the face target.
    top = shoot.parent if shoot.name == "raw" else shoot
    venue = taste.venue_for(top) if dop and editor == "dxo" else None
    if venue is None and dop and editor == "dxo" and measured:
        # Not a finished venue itself: the nearest finished venue this shoot
        # measures like, judged on its median frame (feature by feature over
        # every sampled frame, each carrying its scene's kelvin), if that
        # frame is inside the venue's own spread.
        pool = []
        for g in measured:
            k = statistics.median(g["kelvins"]) if g["kelvins"] else None
            pool += [dict(m, kelvin=k) for m in g["ms"]]
        mid = {}
        for f in taste.VENUE_FEATS[:-1] + ["face_a", "face_b"]:
            vals = [float(m[f]) for m in pool if m.get(f) is not None]
            if vals:
                mid[f] = statistics.median(vals)
        venue = taste.venue_for(top, mid)
    learned = venue is not None
    target_L = (venue[1].get("target_L") if venue else None) or (export_face_L(shoot, judge) if dop and editor == "dxo" else None)
    # The shipped preset every Base is built on, named once here so the
    # preset text, the frame decisions and the sidecar all agree about it.
    # A rendering probe elects this (taste.json "render"); until one has run
    # it is the preset his own sidecars name.
    base_name = ((taste.load() or {}).get("render") or {}).get("preset") or (venue[1].get("base") if venue else None) or taste.venue_base(top)
    if dop and editor == "dxo" and not quiet:
        print("  " + (f"the look learned from your finished edits on {'this shoot' if venue[0] == taste.venue_id(top) else 'a venue that measures like it (' + taste.venue_words(venue[1], venue[0]) + ')'}, on {venue[1]['base']}" if venue
                      else f"no finished venue like this one: DxO camera-body rendering ({STANDARD}), exposure from the sensor, a mask per face that needs one")
              # Where a face is actually held is the published range on every
              # venue (_band); target_L is his own placement and is carried
              # for the report only. This line used to announce it as the aim,
              # which stopped being true when the band became published.
              + f"; faces held to L* {PUBLISHED.FACE_L_LO:.0f}-{PUBLISHED.FACE_L_HI:.0f}, preferred lightness by skin type (Peng et al. CIC28 2020)"
              + (f", against L* {target_L:.0f} where your own finished frames here sit" if target_L else ""))
    elif dop and not quiet:
        # And what this path does NOT decide, said once, rather than left to
        # be worked out from a slider at rest: the exposure and the face masks
        # are per-frame decisions measured through DxO's own rendering, and
        # the scene sidecar these editors get carries neither (editors.NOT_DECIDED).
        import editors as ed
        print(f"  {editor}: " + "; ".join(f"{k.replace('_', ' ')} {why}" for k, why in sorted(ed.not_decided(editor).items())))
    for i, g in enumerate(groups, 1):
        hhmm = g["start"][11:16].replace(":", "") if len(g["start"]) >= 16 else ""
        # Named by what decided it: a portrait shoot CLIP read as "dog" got
        # people rules because faces were in most frames, and should say so.
        what = "people" if g["settings"].get("_faces") else g["subject"]
        name = f"Cull {i:02d} {what} {g['light']} {hhmm} ({len(g['picks'])})"
        path = preset_dir / f"{name}.preset"
        text = build_preset(name, g["settings"], base_name=base_name) if learned else build_partial_preset(name, taste.travelling())
        write_atomic(path, text)
        if install:
            # Atomic, like every other write: a preset half copied into
            # PhotoLab's own folder is a file PhotoLab will try to parse. The
            # sweep above knows this function's temp pattern, so a killed run
            # leaves nothing behind either.
            write_atomic(DXO_PRESETS / path.name, text)
        if dop:
            # Normally every frame in the scene, not just the picks: the rating
            # tells them apart in PhotoLab. With picks_only, the frames that were
            # thrown out get nothing, because a sidecar for a frame you will never
            # open is time spent on the shoot's slowest step for no return.
            targets = [r for r in g["rows"] if int(r["rating"] or 0) >= 3] if picks_only else g["rows"]
            if not targets:
                wrote = 0
            elif editor == "dxo":
                # Only the frames that will be written are measured: without
                # --force a frame with a sidecar (the pipeline's or the
                # photographer's) is skipped by write_dops, and measuring it
                # first was a minute of RAW decoding for nothing on a re-run.
                need = targets if force else [r for r in targets
                                              if not (shoot / f"{r['file']}.dop").exists() and (mine_too or newest_hand(shoot, r["file"]) is None)]
                if len(need) < len(targets) and not quiet:
                    print(f"  {len(targets) - len(need)} of {len(targets)} frames already carry a sidecar: left as they are (--force refreshes them)")
                tones = frame_tones(shoot, out_dir, need, g["settings"], g["light"], judge, reader, quiet=quiet, learned=learned, target_L=target_L, venue=venue, base_name=base_name) if need else {}
                # What was decided on each frame, for the studio to show under it.
                g["decided"] = {Path(f).stem: t.get("_note", "") for f, t in tones.items() if t.get("_note")}
                kinds = {}
                for v in tones.values():
                    kinds[v.get("ExposureAutoMode", "-")] = kinds.get(v.get("ExposureAutoMode", "-"), 0) + 1
                wbs: dict[str, int] = {}
                for v in tones.values():
                    wbs[v.get("WhiteBalanceRawPreset", "AsShot")] = wbs.get(v.get("WhiteBalanceRawPreset", "AsShot"), 0) + 1
                g["notes"].append(("starting from your finished edits here" if learned else f"starting from DxO's {STANDARD}") + "; exposure per frame from the sensor: "
                                  + ", ".join(f"{k.replace('HighlightRecovery', ' recovery')} {n}" for k, n in sorted(kinds.items()))
                                  + f"; {sum(len(v.get('_masks') or []) for v in tones.values())} face masks"
                                  + (("; white balance " + ", ".join(f"{k} {n}" for k, n in sorted(wbs.items(), key=lambda kv: -kv[1]))) if learned else ""))
                g["left_alone"] = []
                wrote = write_dops(shoot, out_dir, targets, name, text, [f"Scene {i:02d}"], force=force, crop=crop, level=level,
                                   judge=judge if crop else None, tones=tones, mine_too=mine_too, base_name=base_name,
                                   left_alone=g["left_alone"])
            else:
                wrote = write_for_editor(shoot, targets, name, g["settings"], g["notes"], editor, force=force, quiet=quiet)
            g["dops"] = wrote
        if xmp:
            t, k = tag_xmp(shoot, [Path(r["file"]).stem for r in g["picks"]], f"Scene {i:02d}")
            xmp_tagged, xmp_kept = xmp_tagged + t, xmp_kept + k
        report.append({"scene": i, "name": name, "subject": (g["subject"], g["subject_p"], g["subject_also"]),
                       "light": (g["light"], g["light_p"], g["light_also"]),
                       "frames": [Path(r["file"]).stem for r in sorted(g["picks"], key=lambda r: r["shot_at"])],
                       "all": len(g["rows"]), "settings": g["settings"], "notes": g["notes"], "decided": g.get("decided", {}),
                       # The frames whose sidecar he had already changed, left
                       # exactly as they were (write_dops). Empty for another
                       # editor, which is never handed a frame of his to skip.
                       "left_alone": sorted(g.get("left_alone") or [])})
        if not quiet:
            print(f"  {name}: " + "; ".join(g["notes"][:3]) + (f"; {g['dops']} sidecar{'s' if g['dops'] != 1 else ''}" if dop else ""))
    print(f"@@ presets {len(ordered)} {len(ordered)}", flush=True)
    # Nothing is said when nothing changed: a second run over the same shoot
    # finds the scene keyword already where it put it.
    if xmp and not quiet and (xmp_tagged or xmp_kept):
        print("  " + "; ".join(
            ([f"{xmp_tagged} XMP sidecar{'s' if xmp_tagged != 1 else ''} tagged with the scene"] if xmp_tagged else [])
            + ([f"{xmp_kept} your editor wrote: left as {'they are' if xmp_kept != 1 else 'it is'}"] if xmp_kept else [])))
    write_md(out_dir, report, install)
    return report


# Said, and said out loud, only when discovery finds nothing. These two stood
# in the template as literals: "DxO PhotoLab 10.0.0.23" and "C52941d" are
# facts about one installation on one day, not constants. PhotoLab 10 shipped
# on 2026-09-01 and 8, 9 and 10 are all in use, so a literal is wrong on most
# machines -- and it was already wrong on this one, where the installed app is
# 10.0.2.28 while the 111 sidecars the pipeline wrote on the action shoot
# still say 10.0.0.23.
DOP_SOFTWARE_DEFAULT = "DxO PhotoLab 10.0.0.23"
DOP_CAFID_DEFAULT = "C52941d"
_STAMP: dict[Path, tuple[str, str, list[str]]] = {}


def photolab_app() -> tuple[Path, str] | None:
    """The newest PhotoLab installed here, as (bundle path, CFBundleVersion).

    The bundle is named DXOPhotoLab10.app -- no spaces, and DXO in capitals,
    which is not how DxO writes its own name anywhere else, including inside
    the sidecars that application writes. Anything that goes looking for
    "DxO PhotoLab 10.app" finds nothing on a machine that has it installed.

    Newest is decided on the version each bundle DECLARES, never on the
    bundle's name. A reverse sort of the NAMES puts DXOPhotoLab9.app above
    DXOPhotoLab10.app -- "9" sorts after "1" -- so on a machine with 8, 9 and
    10 side by side it would pick the oldest."""
    import glob as _g
    import plistlib
    best: tuple[tuple[int, ...], Path, str] | None = None
    for app in _g.glob("/Applications/DXOPhotoLab*.app"):
        try:
            with (Path(app) / "Contents" / "Info.plist").open("rb") as fh:
                info = plistlib.load(fh)
        except (OSError, ValueError):
            continue
        ver = str(info.get("CFBundleVersion") or "").strip()
        if not ver:
            continue
        key = tuple(int(x) for x in re.findall(r"\d+", ver))
        if best is None or key > best[0]:
            best = (key, Path(app), ver)
    return (best[1], best[2]) if best else None


def installed_photolab() -> str | None:
    """The Software string the PhotoLab on this machine writes, from the
    newest DXOPhotoLab*.app in /Applications.

    PhotoLab writes "DxO PhotoLab " and then its CFBundleVersion. Checked
    against the 98 sidecars PhotoLab itself wrote in ducksAndDeadlifts, every
    one of which says "DxO PhotoLab 10.0.2.28" beside an Info.plist
    CFBundleVersion of 10.0.2.28. One installation, so that is a reading of
    one machine and not a fact about DxO; it is also the only reading anyone
    needs, because the machine writing the sidecar is the machine that will
    open it.

    Which bundle that is, and why it is chosen on declared version rather
    than name, is photolab_app() above; this only names it the way PhotoLab
    names itself in a sidecar."""
    found = photolab_app()
    return f"DxO PhotoLab {found[1]}" if found else None


def dop_stamp(shoot: Path) -> tuple[str, str, list[str]]:
    """Sidecar.Software and Source.CafID for this shoot, discovered, with a
    line per fact that had to fall back to a default.

    Software comes off the installed app. CafID cannot: it names a record in
    PhotoLab's own catalogue and there is nothing in the app bundle to derive
    it from, so it is read out of the sidecars PhotoLab has already written
    beside these frames. A file PhotoLab has opened has something in its
    Overrides block -- PhotoLab materialises the active values there on open
    -- and a file only this pipeline has written has an empty one, which is
    what tells the two apart. Neither id is a value this file could guess.

    What that reading is worth is not the same on every shoot. Counted on
    2026-09-19 over raw/, cull/picks/ and edit/ together, which is the three
    folders below:

      2026-09-16        730 sidecars, 509 of them opened by PhotoLab, and
                        those split C52941d 299 to C45224d 210. Two
                        catalogues on one shoot; the vote decides it.
      2026-09-05        198 sidecars, every one opened, every one C52941d.
      2026-09-12        2 sidecars, both opened, both C52941d. Two files.
      ducksAndDeadlifts 98 sidecars, every one opened, every one C45224d.
      2026-09-13-dog    54 sidecars and not one of them opened by PhotoLab.
                        Nothing there is a reading of his catalogue at all:
                        the vote falls through to the unopened bucket, which
                        holds 54 copies of DOP_CAFID_DEFAULT this file wrote
                        itself. The note below is what says so, and saying
                        "read off the sidecars PhotoLab has opened there" of
                        all four shoots, as an earlier write-up of this
                        function did, is wrong on exactly this one."""
    shoot = Path(shoot)
    if shoot in _STAMP:
        software, cafid, _ = _STAMP[shoot]
        return software, cafid, []        # a fallback is said once per run, not once per scene
    notes: list[str] = []
    software = installed_photolab()
    if not software:
        notes.append(f"no DxO PhotoLab in /Applications: sidecars are stamped {DOP_SOFTWARE_DEFAULT}, "
                     "the version this file shipped knowing about; PhotoLab rewrites it the first time it opens one")
        software = DOP_SOFTWARE_DEFAULT
    top = shoot.parent if shoot.name == "raw" else shoot
    seen: dict[str, int] = {}
    fallback: dict[str, int] = {}
    for d in (shoot, top / "cull" / "picks", top / "edit"):
        if not d.is_dir():
            continue
        # Every sidecar in the folder, not the first 500 by name. The cap
        # read like a budget, but CafID is settled by a MAJORITY VOTE over
        # what was read, so an alphabetical head is not a sample of the
        # folder: 2026-09-16 splits 299 to 210 between two catalogue ids, and
        # which one won would have turned on where in the alphabet the cut
        # fell. The budget bought nothing either. His largest shoot is 730
        # sidecars across these three folders and reads in 36 ms once the
        # folder is in the page cache and 106 ms on the first read of a run
        # when it is not. The cost is linear in the count: 46-56 us a file
        # over two runs out to 20,000 copies of a real 16 KB sidecar, about a
        # second at that size (0.99 s and 1.12 s). The spread is the machine's
        # load on the day, not the count, which is why a range is quoted and
        # not a figure. And it runs once per shoot per run (_STAMP).
        for p in sorted(d.glob("*.dop")):
            try:
                text = p.read_text(errors="ignore")
            except OSError:
                continue
            m = re.search(r'^\s*CafID = "([^"]+)"', text, re.M)
            if not m:
                continue
            ov = re.search(r"\n(\t+)Overrides = \{\n(.*?)\n\1\},", text, re.S)
            bucket = seen if (ov and ov.group(2).strip()) else fallback
            bucket[m.group(1)] = bucket.get(m.group(1), 0) + 1
    counted = seen or fallback
    if counted:
        # sorted() before max() is the other half of removing the cap: max
        # keeps the first of equal counts, so without it a dead heat would be
        # broken by whichever id this happened to see first, which is the
        # order the three folders were walked in. With it a tie answers the
        # same way every run -- the id's own alphabet -- and the stamp on a
        # shoot does not change under the tool's feet.
        cafid = max(sorted(counted), key=lambda k: counted[k])
        if not seen:
            notes.append(f"no sidecar here has been opened by PhotoLab yet: Source.CafID {cafid} is taken from what this tool wrote before")
    else:
        cafid = DOP_CAFID_DEFAULT
        notes.append(f"nothing here names a PhotoLab catalog: Source.CafID falls back to {cafid}, "
                     "which is one machine's id and not this one's; PhotoLab replaces it when it first opens the folder")
    _STAMP[shoot] = (software, cafid, notes)
    return _STAMP[shoot]


DOP_HEAD = """Sidecar = {
\tDate = "{date}",
\tSoftware = "{software}",
\tSource = {
\t\tCafID = "{cafid}",
\t\tItems = {
\t\t\t{
\t\t\tAlbums = "",
\t\t\tCreationDate = "{date}",
\t\t\tIPTC = {
\t\t\t},
\t\t\tKeywords = {
{keywords}\t\t\t},
\t\t\tModificationDate = "{date}",
\t\t\tName = "{name}",
\t\t\tOrientation = {orientation},
\t\t\tOutputItems = {
\t\t\t},
\t\t\tProcessingStatus = 0,
\t\t\tRating = {rating},
\t\t\tSettings = {
\t\t\t\tAppliedPresetDisplayName = "{preset_display}",
\t\t\t\tAppliedPresetUniqueName = "DEFAULTS/{preset_display}.preset",
"""
# The Base block below carries every setting explicitly, so the applied-preset
# name is only a label. It must never name a USER preset: the preset file may be
# absent or renamed later, and PhotoLab's DOPSidecar framework aborts the whole
# app on a dangling reference. A DEFAULTS style always exists.
DOP_TAIL = """\t\t\t\tOverrides = {
\t\t\t\t},
\t\t\t\tVersion = "21.0",
\t\t\t},
\t\t\tShotDate = "{shot}",
\t\t\tShouldProcess = 0,
\t\t\tUuid = "{item_uuid}",
\t\t\t},
\t\t},
\t\tUuid = "{source_uuid}",
\t},
\tVersion = "21.0",
}
"""


def frame_edits(shoot: Path, out_dir: Path, row: dict, crop: str | None, level: bool, judge=None, orientation: int | None = 1) -> dict:
    """Per-frame settings that the preset cannot carry: a crop placed from the
    faces, and a horizon from the cull's tilt reading. Opt-in; both are taste.

    orientation None means nothing could say how the body was held, and then
    no crop is placed and "_no_crop" says so. The crop is found on the
    displayed frame and written in the sensor's, so on a portrait frame a
    guessed 1 puts it a quarter turn out: a crop that is wrong is worse than
    none."""
    out: dict = {}
    if level:
        try:
            t = float(row.get("tilt") or 0)
            if 1.5 <= abs(t) <= 8:
                out["KeystoningHorizon"] = round(-t, 2)
                out["KeystoningHorizonActive"] = True
                out["KeystoningHorizonAuto"] = False
        except ValueError:
            pass
    if crop and judge is not None:
        try:
            aw, ah = (int(v) for v in crop.split(":"))
        except ValueError:
            return out
        if orientation is None:
            out["_no_crop"] = True
            return out
        # The cull's own output folder, not a guess at where it is: a shoot
        # laid out as <folder>/_cull has no <shoot>/../cull, so the guess read
        # nothing and --crop silently placed no crop at all.
        pv = cv2.imread(str(out_dir / "previews" / f"{Path(row['file']).stem}.jpg"))
        if pv is None:
            pv = cv2.imread(str(out_dir / "decoded" / f"{Path(row['file']).stem}.jpg"))
        if pv is None:
            return out
        h, w = pv.shape[:2]
        faces = [f for f in judge.detect(pv) if f.main]
        if faces:
            xs = [f.box[0] for f in faces] + [f.box[0] + f.box[2] for f in faces]
            ys = [f.box[1] for f in faces] + [f.box[1] + f.box[3] for f in faces]
            cx, fy = (min(xs) + max(xs)) / 2 / w, min(ys) / h
        else:
            cx, fy = 0.5, 0.33
        # the widest crop of that aspect that fits, faces on the upper third
        target = aw / ah
        if target < w / h:
            cw, ch = target * h / w, 1.0
        else:
            cw, ch = 1.0, (w / h) / target
        x0 = min(max(0.0, cx - cw / 2), 1.0 - cw)
        y0 = min(max(0.0, fy - ch / 3), 1.0 - ch)
        # DxO's CropRect is {x, y, width, height}, read off the photographer's own
        # crops (0.261, 0.194, 0.332, 0.761 on a frame exported at 2:3). This
        # once wrote {x0, y0, x1, y1}: every crop came out twice too wide.
        x0, y0, cw, ch = to_sensor_rect(x0, y0, cw, ch, exif_flip(orientation))   # PhotoLab's frame is the sensor's
        out["CropRect"] = [round(x0, 4), round(y0, 4), round(cw, 4), round(ch, 4)]
        out["CropActive"], out["CropAuto"], out["CropRatio"] = True, False, 0
    return out



def look_line(local: dict, mine: bool, label: str) -> str | None:
    """What to say about the look these frames start from, or None when there
    is nothing to say.

    legal_look keeps the underscore keys, and _not_a_target is one of them --
    it is what had a majority and was still not taken as a target, and it is
    printed on its own, above. A look holding nothing else made this print a
    sentence that ended at its colon."""
    flat = {k: v for k, v in (local or {}).items() if not k.startswith("_")}
    hsl, grading = (local or {}).get("_hsl"), (local or {}).get("_grading")
    if not (flat or hsl or grading):
        return None
    return (("from your own corrections on this shoot: " if mine
             else f"the look of a finished venue this shoot measures like ({label}): ")
            + ", ".join(f"{k} {v}" for k, v in sorted(flat.items()))
            + (f"; HSL {sorted(hsl)}" if hsl else "") + (f"; grading {sorted(grading)}" if grading else ""))


def consults_wb(entry: dict | None) -> bool:
    """Whether this venue's white balance is handed to the learned model, or
    left to the venue's own finals and the camera.

    White balance is his per-frame decision, AsShot or a named preset, and a
    venue hands its frames to predict_wb only once he has made the contrary
    decision there taste.WB_MIN_CLASS times: 293 AsShot and one eyedropper on
    the finished action venue keep AsShot on every frame; eight finished Fluo
    decisions there would consult the model, where the old 90% unanimity rule
    needed thirty. A venue learned before those counts were kept (no
    wb_counts) keeps the old rule: its finals if it has one, else the model.

    It lives here, and taste.wb_where_used calls it, because the gate has to
    check the venues that are actually consulted and nothing else. Written
    out twice, the two copies did not agree for long: the gate's read only
    wb_counts, so a venue carried over from an older build with no wb_counts
    at all - which _carry_venues is the very path that preserves - was
    consulted by this file and skipped by the gate, which is exactly the
    venue the per-venue clause exists for."""
    e = entry or {}
    wb_counts = e.get("wb_counts")
    if wb_counts is None:
        return not (e.get("finals") or {}).get("WhiteBalanceRawPreset")
    return int(wb_counts.get("Fluo", 0) or 0) >= taste.WB_MIN_CLASS


def frame_tones(shoot: Path, out_dir: Path, rows: list[dict], settings: dict, light: str,
                judge, reader, quiet: bool = False, learned: bool = True, target_L: float | None = None, venue=None,
                base_name: str | None = None) -> dict:
    """Measure every frame that gets a sidecar, so each one is tuned to itself.

    Two things per frame, whatever the path. Exposure from the sensor: which
    correction and how much, toward where the photographer's finished faces sit in this
    venue (target_L) or the L* 50 reference. A mask on any face the global
    correction leaves short. Then the look: with finished edits of the photographer's on
    this shoot, the starting edit learned from them on top of the preset
    those edits started from; without, nothing but DxO's own camera-body
    rendering, the sidecar named to it and the Base left partial."""
    previews = out_dir / "previews"
    # The venue's look: what the photographer set the same way on the frames the photographer finished
    # there. The per-frame slider models fitted across the photographer's edits are not
    # applied any more: on the one shoot they were learned from every manual
    # bias was one paste, and on the next venue the photographer reset every value they
    # wrote. What varies per frame is decided from the sensor below.
    here = shoot.parent if shoot.name == "raw" else shoot
    if not learned:
        local = {}
    elif venue is None or venue[0] == taste.venue_id(here):
        local = taste.shoot_overrides(here)               # this shoot's own finished frames, read live
    else:
        local = dict(venue[1].get("look") or {})          # another venue's look, as it was learned
    # Whatever its source, a look only reaches a sidecar through this filter.
    local, dropped = legal_look(local)
    if dropped and not quiet:
        for d in dropped:
            print(f"  not written: {d}")
    prefer = (venue[1].get("type") if venue else None)
    # The venue's own exposure type, where it earned its place over the rule
    # (taste.venue_exposure) and the starting edit carrying it passed the
    # check - and only on the shoot that taught it. A shoot that merely
    # measures like a venue borrows its look, never its exposure type: the fit
    # was scored on that venue's own frames and on nothing else, and nothing
    # has measured it on this one. A shoot like no venue gets the rule too.
    own = bool(venue) and venue[0] == taste.venue_id(here)
    vexp = ((venue[1].get("exposure") or {}) if (venue and learned and own) else {})
    vwhy = (f"exposure type from this shoot's own finished frames: right on {vexp.get('fit_right')} of "
            f"{vexp.get('frames')} on {taste.expo_held_words(vexp)} it had not seen, where the rule is right "
            f"on {vexp.get('rule_right')}" if vexp.get("used") else "")
    # What had a majority and was still not taken as a target, said out loud.
    # It was recorded so it could be reported and then never read: on the
    # action venue it holds the two facts most worth knowing -- that
    # LightingV3BlackPoint -8.292 and LightingV3WhitePoint -0.353 are on 176
    # frames each and are the pipeline's own paste coming back.
    nat = (local or {}).get("_not_a_target") or {}
    if nat and not quiet:
        for k, e in sorted(nat.items()):
            print(f"  found on {e.get('n', 0)} frames here and not taken as a target: "
                  f"{k} = {e.get('value')} -- {e.get('why')}")
    line = look_line(local, venue is None or venue[0] == taste.venue_id(here),
                     (venue[1].get("label", "unnamed") if venue else ""))
    if line and not quiet:
        print("  " + line)
    target = target_L if target_L else ZONE_V
    # His envelope, carried for the report only. The band a face is actually
    # held to is published and the same on every venue (_band), so these are
    # no longer read as a target; frame_tones prints them beside the decision
    # so the difference between where he put a face and where the published
    # work puts one is visible per frame.
    his_band = (venue[1].get("face_lo"), venue[1].get("face_hi")) if venue else (None, None)
    band = None
    # The venue's measured render lift, but ONLY under the Base it was
    # measured through. The gain is the lift of DxO's render under the Base
    # the pipeline wrote (taste.learn_venues), and the Base has just changed
    # from a hand-assembled dict to DxO's shipped preset, so a stamp that
    # does not match means the number describes a rendering that is no
    # longer in use. The pooled constant stands in, and the scene line says
    # the lift is unmeasured here rather than pretending to a precision it
    # has lost.
    want = base_id(preset_base_dict(base_name))
    gain, gain_note = RENDER_GAIN, ""
    if venue and venue[1].get("gain"):
        if venue[1].get("gain_base") == want:
            gain = venue[1]["gain"]
        else:
            gain_note = (f"render lift unmeasured under this starting point: the venue's {venue[1]['gain']:.2f} EV "
                         f"(n {venue[1].get('gain_n', 0)}) was measured through a different Base, so the pooled {RENDER_GAIN} stands")
            if not quiet:
                print(f"  {gain_note}")
    # Whether this venue's white balance is the model's to set. One rule, in
    # consults_wb above, which taste.wb_where_used calls too so the gate
    # checks the venues this step actually asks the model about.
    finals = (venue[1].get("finals") or {}) if venue else {}
    venue_wb = finals.get("WhiteBalanceRawPreset")
    consult = consults_wb(venue[1] if venue else None)
    colour = (taste.load() or {}).get("colour") or {}
    out: dict = {}
    jobs = []
    for r in rows:
        stem = Path(r["file"]).stem
        pv = previews / f"{stem}.jpg"
        jobs.append((r["file"], str(pv) if pv.exists() else "", str(out_dir / "decoded" / f"{stem}.jpg"), str(shoot / r["file"])))
    measured = measure_frames(jobs, progress=None if quiet else (lambda d, n: print(f"@@ tone {d} {n}", flush=True) if d % 25 == 0 or d == n else None))
    for r in rows:
        got = measured.get(r["file"])
        if got is None:
            continue
        m, lin = got["m"], got["lin"]
        per: dict = dict(local) if learned else {}
        notes: list[str] = []
        if learned:
            # The one per-frame colour decision the photographer makes: the
            # camera's AsShot or a named preset, learned from the frames it was
            # made on, and kept only while it beats always-AsShot held out.
            wb = taste.predict_wb(m) if consult else venue_wb
            if wb and wb != "AsShot":
                per["WhiteBalanceRawPreset"] = wb
            # A face more than a MAD yellower than his finished skin, said
            # A face yellower than the delivered ones, said with the number,
            # whether or not the white balance above already answered it.
            hue, mad = colour.get("skin_hue"), colour.get("skin_hue_mad")
            if taste.sure_face(m) and hue is not None and mad and m["face_hue_big"] > hue + mad:
                notes.append(f"face hue {m['face_hue_big']:.0f} deg on the camera JPEG, "
                             f"{(m['face_hue_big'] - hue) / mad:.1f} MAD above your delivered skin ({hue:.1f} +/- {mad:.1f})"
                             + (f"; the room's neutrals read b* {m['cast_b']:+.1f}" if m.get("cast_b") is not None else ""))
        if lin is not None:
            vmode = taste.predict_exposure(venue[1], m) if vexp.get("used") else None
            expo, ev, note = decide_exposure(lin, target, gain=gain, prefer=prefer, band=band,
                                             mode=vmode, why=vwhy if vmode else "")
            per.update(expo)
            masks = face_masks(lin, target, ev, gain=gain, band=band)
            if masks:
                per["_masks"] = masks
            if not masks and note.endswith("left to a face mask"):
                # The face is under the band but too small in frame for a mask
                # to be worth it (MASK_MIN_FRAC): said so, not promised.
                note = note[: -len("left to a face mask")] + f"no face large enough for a mask ({MASK_MIN_FRAC:.0%} of the frame), left as it is"
            clipped = [m for m in masks if abs(m.get("short", 0.0)) > 0.005]
            per["_note"] = note + (f"; {len(masks)} face mask{'s' if len(masks) != 1 else ''}"
                                   + (f", {len(clipped)} of them at the one-stop limit and still "
                                      + ", ".join(f"{m['short']:+.2f} EV out" for m in clipped) if clipped else "")
                                   if masks else "")
            per["_face_L"] = Lstar(lin["face_Y"]) if lin.get("face_Y") else None
            # Where the target came from, said on the frame itself, with his
            # own envelope beside it so the difference is visible rather than
            # argued. The lit patch is printed against the broadcast band and
            # nothing corrects toward it: it is a different statistic from
            # the one the correction uses, and the two are about 1.1 stop
            # apart on the same faces.
            lo, hi = _band(target, band)
            # The band is quoted only where it was actually consulted. A frame
            # with no face to measure, and a frame routed to DxO's automatic
            # highlight recovery, never reach _band, and printing it on them
            # claimed a target that decided nothing.
            consulted = per.get("ExposureAutoMode") == "Manual" and per.get("_face_L") is not None
            bits = ([f"face band {lo:.0f}-{hi:.0f}, preferred L* by skin type (Peng et al. CIC28 2020), used as a range because naming one value means classifying a subject"]
                    if consulted else [])
            if consulted and his_band[0] is not None and his_band[1] is not None:
                bits.append(f"your delivered faces here run {his_band[0]:.0f}-{his_band[1]:.0f}")
            if m.get("face_lit_L") is not None:
                # Reported beside the broadcast band, never judged against it.
                # The statistic matches (a mean of non-shine skin) but the
                # patch does not (a face box, not forehead and cheek), so an
                # "inside"/"outside" verdict would be a number with no source
                # ruling on one with a source -- the mismatch PUBLISHED's own
                # docstring warns about.
                bits.append(f"lit skin L* {m['face_lit_L']:.0f}, beside the broadcast {PUBLISHED.LIT_L_LO:.0f}-{PUBLISHED.LIT_L_HI:.0f} "
                            f"(BT.2408-8 Annex 4, forehead and cheek; this is the whole face box less shine, so they are "
                            f"the same statistic on different patches -- reported, not corrected toward)")
            if gain_note:
                bits.append(gain_note)
            per["_targets"] = {"face_band": [lo, hi] if consulted else None,
                               "face_band_source": "Peng et al. CIC28 2020, preferred L* by skin-colour type, face-region statistic" if consulted else "not consulted on this frame",
                               "his_band": list(his_band), "lit_L": m.get("face_lit_L"), "lit_source": m.get("face_lit_from"),
                               "gain": gain, "gain_stamped": not gain_note}
            if bits:
                per["_note"] += "; " + "; ".join(bits)
        elif not learned:
            per["_note"] = "no RAW to measure: exposure left to DxO"
        if notes:
            per["_note"] = "; ".join(([per["_note"]] if per.get("_note") else []) + notes)
        per["_base"] = "learned" if learned else "standard"
        per["_burst"] = r.get("burst")
        out[r["file"]] = per
    level_frames(out, quiet=quiet)
    return out


# How far a frame may be moved to match the ones beside it. Nothing here is
# a number chosen by eye: a burst is levelled only where the frames really do
# differ, and never further than the burst's own measured spread.
LEVEL_MIN_FRAMES = 4          # fewer than this and a median is not a level
LEVEL_MIN_EV = 0.08           # below this the difference is not visible and not worth a line in the file


def _face_after(per: dict) -> float:
    """The subject's face as it will render once what was already decided for
    the frame is applied: its raw luminance, moved by the global bias and by
    the main face's own mask, which rides on top of the global move."""
    ev = float(per.get("ExposureBias") or 0.0) if per.get("ExposureActive") else 0.0
    ev += next((float(m.get("ExposureBias") or 0.0) for m in (per.get("_masks") or []) if m.get("name") == "Face 1"), 0.0)
    return Y(float(per["_face_L"])) * 2 ** ev


def level_frames(out: dict, quiet: bool = False) -> None:
    """Put the frames of a burst on the same light.

    The subject is brought to the same brightness as in the frames beside it.
    The lamps of a room on mains are a different brightness in every frame:
    at 1/500 the shutter is open about 2 ms of an 8.3 ms half cycle, so each
    frame samples a different phase, and one burst of 48 frames measured 1.57
    EV peak to peak with the direction reversing on three steps in four. The
    camera answers by moving its ISO, which records the swing rather than
    removing it, and the exposure decided from the face leaves it in place:
    two neighbours 0.9 EV apart can both sit inside the band and neither
    moves. So after every frame has been measured, each one is brought to the
    light level of its own burst, which is what makes a run look like one
    run. The amount is the frame's face, as already decided, against its
    burst's median, clamped to the spread of the OTHER frames of the burst,
    and it is nothing at all on a shoot whose light holds still: in daylight
    or on flash the frames measure the same and the correction is zero.

    It moves only what decide_exposure itself would have written: a frame
    set by hand, never one under DxO's highlight recovery, and a bias that
    stays between BIAS_FLOOR and zero."""
    bursts: dict = {}
    held = 0
    for name, per in out.items():
        fl = per.get("_face_L")
        b = per.get("_burst")
        if fl is None or b in (None, "", "-1"):
            continue
        # Only a frame whose exposure is set by hand can be levelled by hand.
        # Under DxO's highlight recovery the exposure is DxO's to choose, and
        # this used to rewrite such a frame to Manual with a bias of its own,
        # while the frame's note still said Strong highlight recovery: the
        # decision made from the sensor, overturned in silence.
        if per.get("ExposureAutoMode") != "Manual":
            held += 1
            continue
        bursts.setdefault(str(b), []).append(name)
    moved = 0
    for b, names in bursts.items():
        if len(names) < LEVEL_MIN_FRAMES:
            continue
        # The subject, not the frame. A whole-frame brightness is the
        # CONTENT: measured that way a daylight shoot reads as 1.88 EV of
        # "flicker" and a flash shoot 6.04, which is a subject crossing the
        # frame, not the sun going out. The face is what has to match from
        # one frame to the next, and it is already measured.
        #
        # And the face as already decided, not as the sensor put it. Read
        # off the raw alone, a frame decide_exposure had pulled down to the
        # band's edge was pulled again by its whole raw difference from the
        # burst and landed darker than the frames it was matched to, and a
        # face its own mask had lifted was lowered by the move under it.
        levels = np.array([_face_after(out[n]) for n in names])
        ref = float(np.median(levels))
        evs = np.log2(np.clip(levels, 1e-9, None) / max(ref, 1e-9))
        swing = float(evs.max() - evs.min())
        for i, name in enumerate(names):
            # The clamp is the spread of the OTHER frames. Taken over the
            # whole burst, the frame that is out is the one that sets it: in
            # a burst of four, p95 of |ev| is that frame's own |ev|, so it
            # was moved nearly all the way to the median whatever had put it
            # there -- and a face turned into shadow is not the lamps.
            span = float(np.percentile(np.delete(np.abs(evs), i), 95))
            fix = float(np.clip(-evs[i], -span, span))
            per = out[name]
            was = float(per.get("ExposureBias") or 0.0) if per.get("ExposureActive") else 0.0
            # No further than decide_exposure would go on its own: never
            # under BIAS_FLOOR, and never a positive global lift, which it
            # refuses -- a face under the band is its mask's to lift, and a
            # frame that is dark all over is the photographer's decision. What
            # that ceiling costs is said on the frame, not dropped.
            now = round(min(0.0, max(BIAS_FLOOR, was + fix)), 3)
            applied = now - was
            short = fix - applied
            bits = []
            if abs(applied) >= LEVEL_MIN_EV:
                per["ExposureActive"] = now != 0.0
                per["ExposureBias"] = now
                bits.append(f"{applied:+.2f} EV so the face matches the {len(names)} frames of its burst "
                            f"(they swing {swing:.2f} EV)")
                moved += 1
            if abs(short) >= LEVEL_MIN_EV:
                bits.append(f"{short:+.2f} EV {'more ' if bits else ''}would match its burst, and "
                            + ("a positive global lift is yours to make" if short > 0
                               else f"that is past {BIAS_FLOOR:+.1f} EV, as far as one exposure move goes here"))
            if bits:
                per["_note"] = (per.get("_note", "") + "; " + "; ".join(bits)).lstrip("; ")
    if moved and not quiet:
        print(f"  {moved} frames levelled so the subject matches the frames beside it"
              + (f"; {held} under DxO's highlight recovery left to it" if held else ""))


def write_dops(shoot: Path, out_dir: Path, rows: list[dict], preset_name: str, preset_text: str, keywords: list[str], force: bool = False,
               crop: str | None = None, level: bool = False, judge=None, tones: dict | None = None, mine_too: bool = False,
               base_name: str | None = None, measuring: bool = False, left_alone: list | None = None) -> int:
    """One <name>.dop per pick, carrying the scene preset and the cull's star
    rating, so PhotoLab opens the folder with the edit already on every frame.
    Never overwrites a sidecar that exists (that is where your own edits live)
    unless force is set.

    `left_alone`, when given, is filled with the stem of every frame skipped
    because a copy of its sidecar carries his hand, so "nothing you had changed
    was touched" is a list in presets.json rather than a promise on a card."""
    # The learned path re-indents the preset's Base into each sidecar. The
    # DxO-Standard path builds its own partial Base per frame and needs none
    # of it: with nothing learned yet the partial preset's Base is empty, and
    # returning on "no Base found" meant a new user got no sidecars at all.
    m = re.search(r"\n(\s*)Base = \{\n(.*?)\n\1\},\n", preset_text, re.S)
    base = None
    if m:
        base_lines = m.group(2).split("\n")
        strip = len(m.group(1))
        base = "\n".join(("\t\t\t\t\t" + ln[strip + 2:]) if ln.startswith(m.group(1) + "  ") else ln for ln in base_lines)
        # No temperature or tint travels from the template: the preset name
        # carries the white balance, and a kelvin on DxO's scale cannot be
        # checked without rendering through DxO.
        base = re.sub(r"^\t+WhiteBalance(RawTemperature|RawTint|RGBTemperature) = [^\n]*(\n|$)", "", base, flags=re.M).rstrip("\n")
        base = "\t\t\t\tBase = {\n" + base + "\n\t\t\t\t},\n"
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.0000000Z")
    # Which PhotoLab, and which catalogue, this machine has: discovered, not typed.
    software, cafid, stamp_notes = dop_stamp(shoot)
    for note in stamp_notes:
        print(f"  {note}")
    try:
        ex = {e["SourceFile"]: e for e in json.loads(subprocess.run(
            [EXIFTOOL, "-j", "-Orientation#", "-DateTimeOriginal", "-OffsetTimeOriginal", *[str(shoot / r["file"]) for r in rows]],
            capture_output=True, text=True).stdout or "[]")}
    except Exception:  # noqa: BLE001
        ex = {}
    n = 0
    kept_edits = 0
    lens_fixed = 0
    no_crop = 0
    kept_elsewhere = 0
    aside: list[Path] = []
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    # The preset a learned look starts from: the one the photographer's finished sidecars name.
    preset_base = base_name or taste.venue_base(shoot.parent if shoot.name == "raw" else shoot)
    for r in rows:
        dop = shoot / f"{r['file']}.dop"
        hand = None if mine_too else newest_hand(shoot, r["file"])
        if not force and (dop.exists() or hand is not None):
            if hand is not None and left_alone is not None:
                left_alone.append(Path(r["file"]).stem)
            continue                      # his copy in edit/ or cull/picks/ counts as existing
        # --force replaces what the pipeline wrote, never what the photographer wrote.
        # PhotoLab puts the photographer's changes in the Overrides block and the pipeline
        # leaves it empty, so a non-empty one has the photographer's hand in it. The photographer's copy may
        # sit beside the RAW, in cull/picks/ or in edit/ (the photographer opens whichever
        # folder); the newest is the one that counts, and it is kept whole
        # with only its Base block, the pipeline's part, replaced. Skipping
        # the file, as this once did, left the old recipe under the photographer's edits.
        # --mine-too replaces every copy of it, each one copied aside first.
        hand_text = hand.read_bytes().decode("utf-8", errors="ignore") if hand is not None else ""
        e = ex.get(str(shoot / r["file"]), {})
        # Read once: the crop placement, the template and the patch all have
        # to be told the same thing about how the body was held.
        #
        # A reading and a guess are not the same thing on this line. exiftool
        # returns nothing at all for a frame it could not open -- the RAW
        # archived to iCloud and evicted, the volume not mounted, the file
        # moved -- and the 1 this used to fall back to was then spliced into
        # his sidecar as though the camera had said it. 350 of 2026-09-16's
        # 730 sidecars carry Orientation = 6, and not one of the RAWs that
        # folder names is on disk today, so a --force over it would have
        # turned all 350 portraits landscape in PhotoLab. A template has no
        # previous line to keep and 1 is the only value a new file can have;
        # the patch is given None instead, which leaves the line he already
        # has standing (patch_dop).
        read_orient = e.get("Orientation")
        orient = int(read_orient or 1)
        patch_orient = int(read_orient) if read_orient else None
        # The crop is the other thing that has to know, and it had been given
        # the guess: the portrait was cut in its display frame and PhotoLab
        # read the rectangle in the sensor's, a quarter turn out. With no
        # reading from exiftool, the sidecar already on disk carries the one
        # written the last time the RAW could be opened (the template writes
        # it from exiftool, PhotoLab keeps it) -- but only where that is not
        # 1, because 1 is exactly what the template writes when it has
        # nothing to go on, and a 1 read back may be this file's own guess
        # coming round again. A landscape whose RAW has gone then gets no
        # crop, which is the safe side of the same question.
        was = sidecar_orientation(hand_text or (dop.read_bytes().decode("utf-8", errors="ignore") if dop.exists() else ""))
        crop_orient = patch_orient or (was if was and was != 1 else None)
        shot = str(e.get("DateTimeOriginal", "")).replace(":", "-", 2).replace(" ", "T")
        shot = (shot + ".0000000" + str(e.get("OffsetTimeOriginal", "Z"))) if shot else now
        # The cull's own tier (rating 5, a clear win) is written as 3 with a
        # keyword, never as 5: a 5 in a sidecar came back as "his 28 best"
        # once, a machine verdict wearing his hand.
        rating = {"5": 3, "3": 3, "2": 2, "1": 1}.get(r["rating"], 0)
        # Each keyword is a hierarchical path, so it is its own table. A bare
        # string here makes PhotoLab fast-enumerate a string and abort the app.
        kw_list = list(keywords) + (["Clear win"] if r["rating"] == "5" else [])
        kw_frame = "".join(f"\t\t\t\t{{\n\t\t\t\t\t\"{k}\",\n\t\t\t\t}},\n" for k in kw_list)
        b = base
        # The scene preset is the look; these are this frame's own numbers.
        per = dict((tones or {}).get(r["file"], {}))
        if (crop or level) and rating >= 3:
            per.update(frame_edits(shoot, out_dir, r, crop, level, judge, orientation=crop_orient))
            no_crop += 1 if per.pop("_no_crop", False) else 0
        if hand is not None:
            # PhotoLab keeps his Overrides as deltas against the Base he edited
            # on: a manual frame carries only his bias there. A refreshed Base
            # that switched the mode would put his bias under an auto mode, so
            # the exposure he ended up with is carried into the new Base.
            fin = taste.final_settings(hand_text)
            for k in ("ExposureActive", "ExposureAutoMode", "ExposureBias"):
                if k in fin:
                    per[k] = lua_value(fin[k])
        # The white balance a frame was DELIVERED with is carried whatever a
        # model says now -- but only when it was his decision. It used to read
        # the frame's final setting, Base included, from any sidecar sitting
        # beside an exported frame. On his own tree that Base is one the
        # pipeline wrote, so the rule handed the pipeline its own white
        # balance back and called it the delivered one: rebuilding the six
        # test frames carried "ManualTemp" forward out of the previous run's
        # sidecars, with no temperature beside it, which would have rendered
        # them at the Base's 5400 K. Same loop as the look learner's, one
        # function further down.
        #
        # decided() is the gate: an Overrides key that merely repeats its own
        # Base is PhotoLab materialising the active value on open. TSC05405 --
        # the case this rule exists for, a Base of Fluo with his AsShot over
        # it -- is a real decision and survives. A frame where he chose
        # nothing keeps whatever the new Base gives it, which for DxO's own
        # preset is AsShot, and 154 of 154 delivered keepers rendered AsShot.
        delivered = hand_text or (dop.read_text(errors="ignore") if dop.exists() and taste.is_exported(shoot / r["file"]) else "")
        if delivered:
            wb_was = taste.decided(taste.flat_block(delivered, "Overrides"),
                                   taste.flat_block(delivered, "Base")).get("WhiteBalanceRawPreset")
            if wb_was:
                per["WhiteBalanceRawPreset"] = lua_value(wb_was.strip('"'))
        standard = per.pop("_base", "learned") == "standard"
        if not standard and base is None:
            continue                      # a learned look needs the preset's Base to sit on
        masks = [ai_mask(x) for x in (per.pop("_masks", None) or [])]
        hsl_tables, grading_tables = per.pop("_hsl", None) or {}, per.pop("_grading", None) or {}
        per = {k: v for k, v in per.items() if not k.startswith("_")}
        if standard:
            # DxO's camera-body rendering, and only what was decided here on top.
            # The rendering is written, not merely named: see standard_rendering.
            keep = standard_rendering()
            keep.update(taste.travelling())
            keep.update(per)
            if masks:
                keep["LocalParameters"], keep["LocalParametersActive"] = masks, True
            b = partial_base(keep)
            per = {}
        elif masks:
            # The preset's Base already carries an empty LocalParameters table
            # and LocalParametersActive = false: those are replaced, never
            # joined by a second copy (PhotoLab reads the first).
            mm = re.search(r"(\t+)LocalParameters = \{\n\s*\},\n", b)
            if mm:
                b = b[:mm.start()] + "\n".join(lua_lines({"LocalParameters": masks}, len(mm.group(1)))) + "\n" + b[mm.end():]
                b = re.sub(r"(\t+)LocalParametersActive = false,", r"\1LocalParametersActive = true,", b, count=1)
            else:                         # a template without the table: appended once
                b = b.replace("\n\t\t\t\t},\n", "\n" + "\n".join(lua_lines({"LocalParameters": masks, "LocalParametersActive": True}, 5)) + "\n\t\t\t\t},\n", 1)
        # The photographer's colour edits on this shoot, as tables (taste.shoot_overrides).
        for lab, f in hsl_tables.items():
            try:
                b = set_hsl(b, lab, hue=f.get("Hue", 0), sat=f.get("Saturation", 0), lum=f.get("Luminance", 0), bounds=f.get("bounds"))
            except KeyError:
                pass
        for z, f in grading_tables.items():
            try:
                b = set_grading(b, z, f.get("Hue", 0), f.get("Sat", 0), f.get("Lum", 0))
            except KeyError:
                pass
        for k, v in per.items():
            if isinstance(v, list):
                b = re.sub(rf"(\t+){k} = \{{.*?\}},\n", lambda m, k=k, v=v: f"{m.group(1)}{k} = {{\n" + "".join(f"{m.group(1)}\t{x},\n" for x in v) + f"{m.group(1)}}},\n", b, count=1, flags=re.S)
                continue
            b, hits = re.subn(rf"(\t+){k} = [^\n]*,\n", lambda m, k=k, v=v: f"{m.group(1)}{k} = {lua(v)},\n", b, count=1)
            if not hits:
                # A key the preset's Base does not already carry. Substitution
                # alone dropped it in silence, which is how a measured white
                # balance reached a sidecar as a preset name with no
                # temperature beside it. PhotoLab reads the block as a Lua
                # table, so position does not matter; it goes in first.
                b = re.sub(r"(Base = \{\n)(\t+)", lambda m, k=k, v=v: f"{m.group(1)}{m.group(2)}{k} = {lua(v)},\n{m.group(2)}", b, count=1)
        display = STANDARD if standard else preset_base
        # A file that already exists is PATCHED, never rebuilt from the
        # template: see patch_dop. His own copy was already treated this way
        # (replace_base); --force used to treat the pipeline's own copy as
        # disposable and rebuild it, which threw away whatever the PhotoLab
        # that had since opened it had added. --mine-too is still the one
        # thing that throws a file of his away and starts from the template.
        old = ""
        if hand is None and dop.exists():
            old = dop.read_bytes().decode("utf-8", errors="ignore")
            if mine_too and is_his(old):
                aside.append(set_aside(shoot, dop, stamp))
                old = ""              # started again from the template, with his own copy kept aside
        patched = None
        if hand is not None:
            # His file: the Base under his edits, and the label over it, and
            # nothing else. A partial Base takes whatever it leaves out from
            # the preset the label names, so a Base that changed while the
            # label stood still was a recipe resolved against the wrong
            # preset. His star, his keywords and his dates stay his.
            patched = patch_dop(hand_text, b, display, orientation=patch_orient) or replace_base(hand_text, b)
            kept_edits += 1
        elif old:
            patched = patch_dop(old, b, display, rating=rating, keywords=kw_list, when=now, orientation=patch_orient)
        if patched is not None:
            text, gone = lens_to_dxo(patched)
            lens_fixed += 1 if gone else 0
        else:
            text = (DOP_HEAD.replace("{date}", now).replace("{software}", software).replace("{cafid}", cafid)
                    .replace("{keywords}", kw_frame).replace("{name}", r["file"])
                    .replace("{preset_display}", display)
                    .replace("{orientation}", str(orient)).replace("{rating}", str(rating))
                    + b
                    + DOP_TAIL.replace("{shot}", shot).replace("{item_uuid}", str(uuid.uuid4()).upper()).replace("{source_uuid}", str(uuid.uuid4()).upper()))
        # The settings check goes to what the pipeline composed, not to the
        # whole of a file it only patched: his own mask carries a local white
        # balance that check_dop refuses, and refusing to write would leave
        # his edit stranded under a stale recipe rather than protect
        # anything. The Base is the 12 KB of a 16 KB sidecar, though (median
        # over 2026-09-16's 730), and that narrowing left the other 3.4 KB
        # unread with the patch's substitutions just spliced through it --
        # the rating, the keywords, the orientation, the two dates and the
        # two preset names. check_written is the part of the validator that
        # does not depend on whose settings these are, so those splices are
        # checked where they land and not only in the Base.
        #
        # What the narrowing still gives up is the settings verdict on the
        # bytes outside the Base, and that was counted rather than assumed:
        # over 2026-09-16's 730 sidecars and the 54 he corrected by hand on
        # 09-18, the full check says something the narrowed one does not on
        # 48 of the 784, and on every one of the 48 the thing it would have
        # said is that a white balance HE chose is not a number DxO ships.
        # 5 of those are on 09-16 -- TSC04881's ManualTemp at 4741.97 with
        # its tint, and a 3800 in the Overrides of TSC04688 and TSC04690,
        # each counted twice because raw/ and cull/picks/ both hold a copy --
        # and the other 43 are 09-18 corrections carrying 4200 in their
        # Overrides, 3 of those also carrying a local white balance in a
        # mask. All 48 are taste.is_hand. An earlier count of this put it at
        # 4: that scan looked for a LOCAL white balance only and so missed
        # the plain temperature PhotoLab materialises into Overrides on open,
        # which is the common case by ten to one.
        bad = taste.check_dop(b if patched is not None else text, measuring=measuring)
        if patched is not None:
            bad += taste.check_written(text)
        if bad:
            raise SystemExit(f"refusing to write {dop.name}: " + "; ".join(bad))
        # The one file here that must never be written by halves. PhotoLab
        # reads every sidecar beside the RAWs at launch, and one with an
        # unbalanced brace in it aborts the launch before there is any window
        # to say which of 1,157 files is at fault. A kill, a sleep or a full
        # disk part way through write_text is exactly how a brace goes
        # missing, so this lands whole or the old file stays.
        write_atomic(dop, text)
        # Every copy of this frame's sidecar says the same thing afterwards.
        # The test is whose the copy is (is_his), not whether its Overrides
        # block has anything in it: PhotoLab materialises its own state there
        # on open, and a copy carrying only that was being left behind
        # holding the previous run's recipe.
        top = shoot.parent if shoot.name == "raw" else shoot
        for other in (top / "cull" / "picks" / dop.name, top / "edit" / dop.name):
            if not other.exists() or other.resolve() == dop.resolve():
                continue
            theirs = other.read_text(errors="ignore")
            if is_his(theirs) and taste._block(theirs, "Overrides").strip() != taste._block(hand_text, "Overrides").strip():
                # A different edit of his lives in that folder. Without
                # --mine-too it is not ours to replace. WITH it, leaving it
                # was what made the flag a half measure: raw/ was rebuilt,
                # this copy kept the edit, and gather promotes the newest
                # copy with his hand in it on the very next run, so the file
                # he asked to be rid of came straight back.
                if not mine_too:
                    kept_elsewhere += 1
                    continue
                aside.append(set_aside(shoot, other, stamp))
            write_atomic(other, text)
        n += 1
    if kept_edits:
        print(f"  {kept_edits} sidecar{'s carry' if kept_edits != 1 else ' carries'} your own edits: {'those were' if kept_edits != 1 else 'it was'} kept, with the starting edit under {'them' if kept_edits != 1 else 'it'} refreshed (--mine-too replaces {'them' if kept_edits != 1 else 'it'})")
    if aside:
        print(f"  {len(aside)} sidecar{'s of yours were' if len(aside) != 1 else ' of yours was'} replaced (--mine-too): "
              f"the old {'ones are' if len(aside) != 1 else 'one is'} in {aside[0].parent.parent}")
    if kept_elsewhere:
        print(f"  {kept_elsewhere} cop{'ies' if kept_elsewhere != 1 else 'y'} in cull/picks/ or edit/ carr{'y' if kept_elsewhere != 1 else 'ies'} "
              f"a different edit of yours: left as {'they are' if kept_elsewhere != 1 else 'it is'} (--mine-too replaces {'them' if kept_elsewhere != 1 else 'it'})")
    if no_crop:
        print(f"  {no_crop} frame{'s' if no_crop != 1 else ''} got no crop: nothing could say which way the camera was held "
              "(the RAW would not open, and no sidecar here records it), and a crop placed a quarter turn out is worse than none")
    if lens_fixed:
        print(f"  {lens_fixed} of those had the lens corrections switched off in their own settings (PhotoLab writes that when it opens a sidecar without the lens block): those lines were removed, so DxO's optics module applies")
    return n


def set_aside(shoot: Path, path: Path, stamp: str) -> Path:
    """A copy of a sidecar of the photographer's, kept before anything
    replaces it.

    --mine-too is the one flag in this file that throws an edit of his away,
    and it used to do it with nothing kept: the file was rebuilt from the
    template and what PhotoLab had recorded of his hand was gone. The copy
    goes under <shoot>/decisions, beside the stars and the answer key -- the
    files no machine can rebuild -- in a folder named for the run that
    replaced it, keeping the folder it came from so the three copies of one
    frame stay apart."""
    top = shoot.parent if shoot.name == "raw" else shoot
    try:
        rel = path.resolve().relative_to(top.resolve())
    except ValueError:
        rel = Path(path.name)
    dest = decisions_dir(top / "cull") / "replaced" / stamp / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    write_atomic(dest, path.read_bytes())
    return dest


def newest_hand(raw_dir: Path, name: str) -> Path | None:
    """The photographer's copy of this frame's sidecar, if there is one: beside the RAW, in
    cull/picks/ or in edit/, whichever is newest with the photographer's hand in it.

    taste.newest_hand's answer, which is the learner's: one rule for which
    copy is his, so the writer and the learner cannot disagree about what he
    decided on the same frame. It is cached per shoot there (hand_copies)."""
    return taste.newest_hand(raw_dir, name)


# PhotoLab's own lens values when it opens a sidecar, and how two of its values
# compare: taste.LENS_OPENED and taste.same_value, where the learner reads them
# too. Named here as well because this file has always exported them.
LENS_OPENED = taste.LENS_OPENED
_same_value = taste.same_value


def his_lens(text: str) -> dict:
    """The lens-correction keys in this sidecar's Overrides that are a choice
    of the photographer's.

    Every lens key used to be treated as PhotoLab's own materialisation and
    deleted, on the strength of the pattern PhotoLab writes on open
    (LENS_OPENED). A deliberate DistortionActive = false went with the rest,
    and a frame whose only change was a lens tool counted as nobody's and had
    its whole Overrides block emptied. So a key only counts as PhotoLab's when
    it carries PhotoLab's own materialised value, or merely repeats the Base
    it sits over, which is the echo taste.decided describes.

    On the 3,511 sidecars in this library that leaves not one key: the
    narrowing changes nothing that exists and only protects the value that
    does not exist yet."""
    ov = taste.flat_block(text, "Overrides")
    base = taste.flat_block(text, "Base")
    return {k: v for k, v in ov.items()
            if taste.OPENED_RE.match(k) and not _same_value(v, LENS_OPENED.get(k)) and not _same_value(v, base.get(k))}


def is_his(text: str) -> bool:
    """Whether a whole sidecar carries the photographer's hand: what
    taste.is_hand reads in the Overrides block, plus a lens value of his that
    hand_keys still counts as PhotoLab's (his_lens).

    In that order, and the cheap question first: his_lens has to read the
    Base as well as the Overrides to tell a decision from an echo, and this
    is asked of three copies of every frame of the shoot."""
    ov = taste._block(text, "Overrides")
    if taste.is_hand(ov):
        return True
    return bool(ov.strip()) and bool(his_lens(text))


def lens_to_dxo(text: str) -> tuple[str, int]:
    """The photographer's sidecar with PhotoLab's own lens-correction keys
    taken out of its Overrides block, so the Base's DxO block (every tool on,
    in Auto) applies. PhotoLab wrote those keys there itself when it opened a
    sidecar whose Base lacked them (LENS_OPENED); they then rode along with
    whatever the photographer changed and beat the corrected Base. A lens
    value of the photographer's own stays (his_lens), and so does every mask,
    slider and table. Returns the text and how many lines went."""
    nl = "\r\n" if "\r\n" in text else "\n"
    t = text.replace("\r\n", "\n")
    m = re.search(r"\n(\t+)Overrides = \{\n(.*?)\n\1\},\n", t, re.S)
    if not m:
        return text, 0
    mine = his_lens(text)
    depth = m.group(1) + "\t"
    kept, gone = [], 0
    for ln in m.group(2).split("\n"):
        mm = re.match(rf"^{depth}([A-Za-z0-9_]+) = [^{{\n]*,\s*$", ln)
        if mm and taste.OPENED_RE.match(mm.group(1)) and mm.group(1) not in mine:
            gone += 1
            continue
        kept.append(ln)
    if not gone:
        return text, 0
    body = "\n".join(kept)
    t = t[:m.start(2)] + body + t[m.end(2):]
    t = t.replace("Overrides = {\n\n" + m.group(1) + "},", "Overrides = {\n" + m.group(1) + "},")   # a block emptied by this stays well-formed
    return (t.replace("\n", nl) if nl != "\n" else t), gone


def patch_dop(text: str, base: str, preset_display: str, rating: int | None = None,
              keywords: list[str] | None = None, when: str | None = None,
              orientation: int | None = None) -> str | None:
    """An existing sidecar with only the keys this tool owns replaced and
    every other byte of it left alone. None when the file carries no Base
    block, which means it is not one this can be trusted to patch and the
    caller should build a fresh file instead.

    rating, keywords and when are left alone when they are not given, which
    is how a sidecar of HIS is patched: the Base under his edits is refreshed
    and the label over it corrected, but his star, his keywords and his dates
    are not this tool's to move. Bumping the date on his file in particular
    could make PhotoLab prefer the sidecar over an edit of his that lives
    only in its own database.

    orientation is not in that company, but it is given only when exiftool
    actually read one. It is the camera's reading of how the body was held,
    which the template writes from exiftool and which the patch used to leave
    standing at whatever the file was born with, so --force silently stopped
    correcting a frame whose EXIF had since been rewritten. PhotoLab records
    no rotation of his on this line: across the 730 sidecars of 2026-09-16 --
    509 of them opened by PhotoLab and 507 carrying his own edits
    (taste.is_hand) -- Source.Items.Orientation holds two values, 380 of them
    1 and 350 of them 6, and both are readings a camera writes.

    Which is exactly why it must not be guessed at. The RAWs that folder
    names are not on disk today, exiftool returns nothing for a frame it
    cannot open, and the fallback 1 that used to fill in for it would have
    been spliced over all 350 of those sixes, turning his portraits landscape
    in PhotoLab. write_dops passes None in that case and the line he already
    has stands. A file carrying no Orientation line at all is likewise left
    without one rather than given a guessed one; all 730 carry exactly one.

    --force used to rebuild the file from DOP_HEAD and DOP_TAIL, a template
    frozen at whatever PhotoLab wrote on the day it was captured. Everything
    a later PhotoLab had put in the file went out with the rebuild: the
    OutputItems block recording where the frame had been exported to, IPTC,
    ProcessingStatus, and Source.CafID and Software, which are facts about
    the installation rather than about the edit. PhotoLab 10 shipped three
    weeks ago with 8 and 9 still in use, so which keys a sidecar may carry is
    not something this file gets to know in advance.

    What this tool owns is the Base, the applied-preset label, the rating and
    the keywords, plus the two dates that record this write. An unknown key
    from a newer PhotoLab now passes straight through instead of being
    dropped.

    The dates are not sentiment: PhotoLab reconciles a sidecar against its
    own database by date, so a file whose Base changed while its Date stood
    still is one PhotoLab may decide it already knows better than.

    PhotoLab writes CRLF; that is kept."""
    nl = "\r\n" if "\r\n" in text else "\n"
    t = text.replace("\r\n", "\n")
    if not re.search(r"\n(\t+)Base = \{\n.*?\n\1\},\n", t, re.S):
        return None
    # An Overrides block with nothing of his in it is PhotoLab's own
    # materialisation of the Base that WAS there: the gain map, the crop
    # flags, the lens block, a temperature the Base did not carry
    # (taste.OPENED). Left standing over a replaced Base it would beat it,
    # and the frame would keep the previous run's numbers under a new recipe.
    # The rebuild this replaces dropped all of it by starting from an empty
    # block; so does this. A block with his hand in it DOES reach here -- a
    # sidecar of his is patched on this same path -- and the is_hand test
    # below is the only thing that keeps it. It is not a belt over the
    # caller's braces: take it out and his edits go with it.
    if not is_his(text):
        t = re.sub(r"\n(\t+)Overrides = \{\n.*?\n\1\},\n",
                   lambda m: f"\n{m.group(1)}Overrides = {{\n{m.group(1)}}},\n", t, count=1, flags=re.S)
    t = replace_base(t, base)
    # The depth of one entry in Source.Items, read off the file rather than
    # assumed: Rating, Keywords and ModificationDate all sit at it, and
    # OutputItems carries a ModificationDate of its own one level deeper that
    # must not be touched.
    mr = re.search(r"^(\t+)Rating = (\d+),$", t, re.M)
    ind = mr.group(1) if mr else "\t\t\t"
    if mr and rating is not None:
        t = t[:mr.start()] + f"{ind}Rating = {rating}," + t[mr.end():]
    if keywords is not None:
        kw = "".join(f"{ind}\t{{\n{ind}\t\t\"{k}\",\n{ind}\t}},\n" for k in keywords)
        t = re.sub(rf"\n{ind}Keywords = \{{\n(?:.*?\n)??{ind}\}},\n", f"\n{ind}Keywords = {{\n{kw}{ind}}},\n", t, count=1, flags=re.S)
    if orientation is not None:
        t = re.sub(rf"^{ind}Orientation = \d+,$", f"{ind}Orientation = {orientation},", t, count=1, flags=re.M)
    if when is not None:
        t = re.sub(r'^\tDate = "[^"]*",$', f'\tDate = "{when}",', t, count=1, flags=re.M)
        t = re.sub(rf'^{ind}ModificationDate = "[^"]*",$', f'{ind}ModificationDate = "{when}",', t, count=1, flags=re.M)
    t = re.sub(r'^(\s*)AppliedPresetDisplayName = "[^"]*",$', rf'\g<1>AppliedPresetDisplayName = "{preset_display}",', t, count=1, flags=re.M)
    t = re.sub(r'^(\s*)AppliedPresetUniqueName = "[^"]*",$', rf'\g<1>AppliedPresetUniqueName = "DEFAULTS/{preset_display}.preset",', t, count=1, flags=re.M)
    return t.replace("\n", nl) if nl != "\n" else t


def sidecar_orientation(text: str) -> int | None:
    """The Orientation a sidecar already records for its frame, or None when
    it records none. It is a camera's reading (see patch_dop), so it stands in
    for exiftool when the RAW cannot be opened; it is never a guess."""
    m = re.search(r"^\t+Orientation = (\d+),\r?$", text, re.M)
    return int(m.group(1)) if m else None


def replace_base(text: str, base: str) -> str:
    """The photographer's sidecar, whole, with only its Base block replaced by the pipeline's.
    PhotoLab writes CRLF; that is kept."""
    nl = "\r\n" if "\r\n" in text else "\n"
    t = text.replace("\r\n", "\n")
    m = re.search(r"\n(\t+)Base = \{\n.*?\n\1\},\n", t, re.S)
    if not m:
        return text
    t = t[:m.start() + 1] + base.replace("\r\n", "\n") + t[m.end():]
    return t.replace("\n", nl) if nl != "\n" else t


# The keyword a scene puts on its picks, and the shape of one from an earlier
# run: they are renumbered when the scenes are read again, so the one this run
# decided replaces the one that was there rather than joining it.
SCENE_KEYWORD = re.compile(r"^Scene \d+$")


def tag_xmp(shoot: Path, stems: list[str], keyword: str) -> tuple[int, int]:
    """The scene's keyword in each pick's XMP sidecar, at the name Lightroom
    and Camera Raw read. Returns how many were tagged and how many were left
    alone.

    A sidecar somebody else wrote is left alone, the same rule the .dop path
    and write_for_editor keep: <stem>.xmp is where Lightroom keeps a person's
    develop settings, and this used to run exiftool over it in place, adding
    a keyword to a file of theirs -- and adding it again on every run, since
    exiftool's += does not ask whether the keyword is already in the bag.
    What is ours is rewritten whole, with the scene keyword this run decided
    in place of the one an earlier run left."""
    import editors as ed
    tagged = kept = 0
    for st in stems:
        side = shoot / f"{st}.xmp"
        text = side.read_text(errors="ignore") if side.exists() else ""
        if text.strip() and not ed.is_ours(text):
            kept += 1
            continue
        keywords = [k for k in ed.keywords_of(text) if not SCENE_KEYWORD.match(k)] + [keyword]
        new = ed.with_keywords(text, keywords)
        if new != text:
            write_atomic(side, new)
            tagged += 1
    return tagged, kept


def write_md(out_dir: Path, report: list[dict], installed: bool) -> None:
    L = ["# Presets, one per scene", "",
         "Each scene the cull found was read for what it is and what the light is doing, and",
         "got a starting preset from that plus what was measured: white balance, exposure,",
         "highlight protection, skin under colored light, rendering. It is 80% of the edit,",
         "not the edit. Under each one is what is left for your hands.", "",
         "## Applying them", "",
         "In PhotoLab: select the frames listed for a scene, right-click, **Apply preset**, pick",
         "the `Cull ..` entry. " + ("They are installed in PhotoLab's preset folder; restart it if they are not in the list."
                                    if installed else "Import them from `_cull/presets/` (Presets panel, Import) or run again with `--install`."),
         "Then the usual three: exposure to taste, a control point on the subject, crop.", "",
         "The frame lists are the picks; the preset fits the rest of the scene too.", ""]
    for r in report:
        s = r["settings"]
        sub, sp, salso = r["subject"]
        li, lp, lalso = r["light"]
        L += [f"## {r['name']}", "",
              f"Frames ({len(r['frames'])} pick{'s' if len(r['frames']) != 1 else ''} of {r['all']} in the scene): " + ", ".join(f[-5:] if f.startswith("TSC") else f for f in r["frames"]), "",
              f"What it saw: **{sub}** ({sp:.2f}" + (", also " + ", ".join(salso) if salso else "") + f") in **{li}** ({lp:.2f}" + (", also " + ", ".join(lalso) if lalso else "") + ").", "",
              "Measured, and what was set:", ""]
        L += [f"- {n}" for n in r["notes"]]
        set_lines = []
        if s.get("ExposureActive"):
            set_lines.append(f"exposure {s['ExposureBias']:+.2f}")
        if s.get("LightingV3Highlights"):
            set_lines.append(f"highlights {s['LightingV3Highlights']}")
        if s.get("LightingV3Shadows"):
            set_lines.append(f"shadows +{s['LightingV3Shadows']}")
        if s.get("HazeRemovalActive"):
            set_lines.append(f"ClearView {s['DehazingValue']}")
        if s.get("ContrastEnhancementActive"):
            set_lines.append(f"fine contrast +{s['ContrastEnhancementGlobalIntensity']}")
        if s.get("OutputSaturatedColorsProtection", 50) != 50:
            set_lines.append(f"protect saturated colors {s['OutputSaturatedColorsProtection']}")
        set_lines.append(f"vibrancy {s.get('VibrancyIntensity', 5)}")
        set_lines.append(f"{s.get('ColorRenderingType', shipped(NATURAL).get('ColorRenderingType'))} rendering")
        if s.get("ArtisticVignettingActive"):
            set_lines.append(f"vignette {s['ArtisticVignettingCornerAttenuation']}")
        by_hand = "crop"
        if s.get("_faces"):
            by_hand = "control point on each face (+0.3 to +0.6, contrast +10), crop, and check the eyes at 100%"
        elif s.get("_family") == "pet":
            by_hand = "control point on the eyes (+0.3, microcontrast +10), crop; check the fur at 100% for noise"
        elif s.get("_family") == "landscape":
            by_hand = "horizon (Geometry → Horizon, auto), graduated filter on the sky if it still runs hot, crop"
        L += ["", "Preset: " + ", ".join(set_lines) + ", DeepPRIME.", "", f"By hand: {by_hand}.", ""]
        if r.get("decided"):
            L += ["Per frame:"] + [f"- {stem}: {note}" for stem, note in sorted(r["decided"].items())] + [""]
    write_atomic(out_dir / "presets.md", "\n".join(L))
    # default=str, so write_json_atomic is no use here: the report carries
    # datetimes. Serialised first all the same, so a value json cannot take
    # fails before the old report is touched.
    write_atomic(out_dir / "presets.json", json.dumps([{k: v for k, v in r.items()} for r in report], indent=1, default=str))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", type=Path, help="the shoot (folder of RAWs)")
    ap.add_argument("--out", type=Path, default=None, help="the cull output folder (default <folder>/_cull)")
    ap.add_argument("--install", action="store_true", help="copy the presets into PhotoLab's preset folder")
    ap.add_argument("--xmp", action="store_true",
                    help="tag each pick's XMP sidecar with its scene keyword, at the name Lightroom and Camera Raw "
                         "read; a sidecar your own editor wrote is left alone")
    ap.add_argument("--dop", action="store_true", help="write a PhotoLab .dop sidecar per frame with the scene preset and star rating applied")
    ap.add_argument("--force", action="store_true", help="with --dop: overwrite sidecars the pipeline wrote before; one with your own edits in it is still left alone")
    ap.add_argument("--mine-too", action="store_true",
                    help="with --force: overwrite even the sidecars that carry your own edits, every copy of them "
                         "(beside the RAW, in cull/picks/ and in edit/, so nothing puts the old one back); each one is "
                         "copied into <shoot>/decisions/replaced/<time>/ first")
    ap.add_argument("--crop", default=None, help="with --dop: place a crop of this aspect (4:5, 1:1, 16:9) on every pick, faces on the upper third")
    ap.add_argument("--level", action="store_true", help="with --dop: straighten picks the cull flagged as tilted")
    ap.add_argument("--editor", choices=["dxo", "lightroom", "rawtherapee", "darktable"], default="dxo",
                    help="which editor's sidecar to write. dxo is the full preset; lightroom and rawtherapee get the same starting edit in their own format; darktable gets the rating and label only (see editors.py for why)")
    ap.add_argument("--picks-only", action="store_true", help="with --dop: write sidecars for kept frames only, not for the ones thrown out (what the studio does once you have chosen your keepers)")
    a = ap.parse_args()
    out = a.out or default_out(a.folder)
    if not (out / "cull.csv").exists():
        print(f"no cull.csv in {out}; run the cull first (./pl cull {a.folder} --keep-previews)")
        return 1
    rep = build(a.folder, out, install=a.install, xmp=a.xmp, dop=a.dop, force=a.force, crop=a.crop, level=a.level,
                picks_only=a.picks_only, editor=a.editor, mine_too=a.mine_too)
    print(f"\n  {len(rep)} presets in {out / 'presets'}; notes in {out / 'presets.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
