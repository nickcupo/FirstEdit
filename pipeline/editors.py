#!/usr/bin/env python3
"""
editors.py - the same starting edit, written for whichever raw editor you use.

The cull measures a setup once: how far off the exposure is, how hard the light
is, whether the highlights are gone, what the subject is. Those measurements are
the same whatever opens the file afterwards, so they are held here in plain
terms (EV, kelvin, -100..100 sliders) and each editor's writer renders them into
its own sidecar.

    DxO PhotoLab   .dop        presets.py, the original and the most complete
    Lightroom      .xmp        crs: develop settings, also read by Camera Raw
    RawTherapee    .pp3        plain text, one section per tool
    darktable      .xmp        rating and colour label only, see below

Three things in here are the vendors' facts rather than this pipeline's choices,
so all three are held as DATA at the top of the file instead of as literals
inside a format string: what each sidecar declares itself to be (FORMATS), what
each writer can carry of the neutral Edit (CARRIES), and the five colour labels
(LABELS). Following a vendor forward is then one line in FORMATS and one line in
the test that pins it, not a hunt through f-strings.

WHAT THE DECLARED VERSION DOES. It is not decoration; RawTherapee branches on
it. Loading a profile, procparams.cc forces the 2 degree standard observer when
the file says 346 or less, forces the 10 degree observer when it says 347 to
349, and from 350 up leaves the observer RawTherapee itself defaults to
(2 degrees, colortemp.h DEFAULT_OBSERVER) -- 350 is where the observer was
introduced. This file used to declare Version=347, AppVersion=5.10, so every
kelvin the cull computed was rendered through the 10 degree observer while the
same kelvin typed into RawTherapee by hand used the 2 degree one. That is the
white balance work this pipeline exists to do, quietly wrong, with nothing in
the file to say so. The version now comes from the table, AND the observer is
written out explicitly beside the temperature, so the rendering no longer
depends on a version number being read the way we expect it to be.

darktable is the odd one out and deliberately partial. It stores each module's
parameters as a base64 blob of the module's C struct, versioned per module and
per release, so writing develop settings for it means reproducing struct layouts
that change between versions, and getting one field wrong produces a silently
wrong edit rather than an error. What is safe to write is the XMP that every
editor reads: the star rating and the colour label. A darktable user gets the
cull, the ratings and the grouping, and does their own developing.

Three darktable facts, all in src/common/exif.cc, all of which this file had
wrong. Colour labels are NUMBERS: the writer does snprintf("%d", colour), the
reader does toLong. A label written as the name "Yellow" therefore does not
fail loudly -- exiv2 cannot parse it, hands back 0, and the frame comes up RED.
xmp:Rating is read only when the file carries darktable:xmp_version or the user
has left the "ignore embedded rating" preference off, so a sidecar without that
key silently loses the cull's stars for anyone who has set it. And darktable
looks for the sidecar under the WHOLE file name, TSC03957.ARW.xmp, never
TSC03957.xmp: all 198 sidecars darktable itself wrote in the 2026-09-05 shoot
are named that way. Rating and label now also go to xmp:Label, which darktable
prefers over its own key and which Lightroom, Bridge and exiftool all read.

SOMEONE ELSE'S SIDECAR. The .dop path will not replace a file with the
photographer's hand in it, --force or not. These three writers replaced whatever
was there, so a user who edited eighty frames in Lightroom and re-ran presets
lost all eighty. There is no Overrides block to look in here, so the test runs
the other way round: what this file writes carries a stamp, and a file WITHOUT
that stamp belongs to someone else and is kept. The stamp is a comment, and each
of these editors rewrites its sidecar from its own state when the user saves, so
the first real edit takes the stamp out and the pipeline leaves the file alone
from then on. A sidecar hand-edited in a text editor that leaves the comment
line in place is the one case this does not catch.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from html import unescape
from pathlib import Path


@dataclass
class Edit:
    """One setup's starting edit, in terms no editor owns."""
    name: str = ""
    exposure: float = 0.0        # EV
    temperature: int = 0         # kelvin, 0 = leave the camera's
    tint: int = 0                # -150..150, green to magenta
    highlights: int = 0          # -100..100
    shadows: int = 0
    blacks: int = 0
    whites: int = 0
    contrast: int = 0
    vibrance: int = 0
    saturation: int = 0
    dehaze: int = 0
    vignette: int = 0            # negative darkens the corners
    skin_sat: int = 0            # orange, where skin lives
    red_sat: int = 0
    red_lum: int = 0
    # A DxO AI face mask is a prompt POINT and an exposure bias, not a box:
    # presets.face_masks writes {"x", "y", "ExposureBias"} in the sensor's
    # frame. Carried here in the same shape so the manifest can say what each
    # editor would have to invent to render one.
    masks: list = field(default_factory=list)
    notes: list = field(default_factory=list)


def from_dxo(name: str, s: dict, notes: list | None = None) -> Edit:
    """The DxO settings dict the scene reader already produces, read back out
    into plain terms. DxO's own colour rendering has no equivalent anywhere
    else and is dropped rather than approximated."""
    return Edit(
        name=name,
        exposure=float(s.get("ExposureBias", 0) or 0) if s.get("ExposureActive") else 0.0,
        temperature=int(s.get("WhiteBalanceRawTemperature", 0) or 0),
        tint=int(s.get("WhiteBalanceRawTint", 0) or 0),
        highlights=int(s.get("LightingV3Highlights", 0) or 0),
        shadows=int(s.get("LightingV3Shadows", 0) or 0),
        blacks=int(s.get("LightingV3BlackPoint", 0) or 0),
        whites=int(s.get("LightingV3WhitePoint", 0) or 0),
        contrast=int(s.get("ContrastEnhancementGlobalIntensity", 0) or 0) if s.get("ContrastEnhancementActive") else 0,
        vibrance=int(s.get("VibrancyIntensity", 0) or 0),
        dehaze=int(s.get("DehazingValue", 0) or 0) if s.get("HazeRemovalActive") else 0,
        vignette=int(s.get("ArtisticVignettingCornerAttenuation", 0) or 0) if s.get("ArtisticVignettingActive") else 0,
        skin_sat=int(s.get("_orange_sat", 0) or 0),
        red_sat=int(s.get("_red_sat", 0) or 0),
        red_lum=int(s.get("_red_lum", 0) or 0),
        # Only the per-frame settings carry masks (presets.py keeps them in the
        # per-frame tones and pops them in write_dops); a scene preset has none.
        masks=[{"x": float(m.get("x", 0.0) or 0.0), "y": float(m.get("y", 0.0) or 0.0),
                "exposure": float(m.get("ExposureBias", 0) or 0)} for m in (s.get("_masks") or [])],
        notes=list(notes or []),
    )


# ------------------------------------------------------- the vendors' numbers

# Every editor here numbers its five colour labels in this order. darktable
# counts them from 0 (exif.cc: Red -> 0 ... Purple -> 4), RawTherapee from 1,
# with 0 meaning no label (filebrowser.cc's icon list: empty, red, yellow,
# green, blue, purple). Adobe writes the name.
LABELS = ("Red", "Yellow", "Green", "Blue", "Purple")


@dataclass(frozen=True)
class Format:
    """What one editor's sidecar is called, what it declares itself to be, and
    where that number came from. The writers read their version strings out of
    here, so a vendor bump is this one line plus the test that pins it -- the
    alternative, a literal inside a format string, is how Version=347 sat in
    this file for a year after RawTherapee moved past it."""
    editor: str
    suffix: str
    whole_name: bool             # darktable and DxO: <file>.ARW.xmp, not <stem>.xmp
    declares: dict               # the version keys the written file carries
    apps: str                    # the releases that read it as written
    checked: str                 # when these numbers were last read off the vendor's own source
    source: str


FORMATS = {
    "dxo": Format(
        editor="dxo", suffix=".dop", whole_name=True, declares={},
        apps="DxO PhotoLab",
        checked="2026-09-18",
        source="presets.write_dops writes the .dop; this row exists so the studio can name the file and "
               "compare what each editor carries."),
    "lightroom": Format(
        editor="lightroom", suffix=".xmp", whole_name=False,
        declares={"Version": "15.4", "ProcessVersion": "15.4"},
        apps="Camera Raw 15.4 and later, and the Lightroom Classic of the same release (12.4 and later)",
        checked="2026-09-18",
        source="Process version 6 arrived in Camera Raw 15.4 / Lightroom Classic 12.4 (June 2023) and is what "
               "reduced the banding in the color mixer -- the very controls this writer sets. Checked against 30 "
               "crs sidecars and presets published on GitHub: every file written by 16.0.1 through 18.2 still "
               "declares ProcessVersion 15.4, and the 15.0 / 11.0 pair this file used to write is what Camera Raw "
               "15.0 wrote in 2022. crs:Version names the release that wrote the file, and is set to the release "
               "that introduced the newest thing written here, so no reader is told the file uses a control it "
               "does not have."),
    "rawtherapee": Format(
        editor="rawtherapee", suffix=".pp3", whole_name=True,
        declares={"AppVersion": "5.13", "Version": "353"},
        apps="RawTherapee 5.10 and later (5.10 is where the standard observer arrived at PPVERSION 350); "
             "older builds ignore the keys they do not know",
        checked="2026-09-18",
        source="rtgui/ppversion.h at tag 5.13: '#define PPVERSION 353', whose own log dates 353 to 2025-07-22 and "
               "350 to 2023-03-05, 'introduced white balance standard observer'. The branch that acts on it is in "
               "procparams.cc, ProcParams::load."),
    "darktable": Format(
        editor="darktable", suffix=".xmp", whole_name=True,
        declares={"xmp_version": "5"},
        apps="darktable 4.x and 5.x (5.6.1 current)",
        checked="2026-09-18",
        source="src/common/exif.cc: '#define DT_XMP_EXIF_VERSION 5', and 198 of the 198 sidecars darktable itself "
               "wrote in the 2026-09-05 shoot carry xmp_version=\"5\"."),
}

# Kept as it was, for callers that only want the extension.
WRITERS = {k: f.suffix for k, f in FORMATS.items()}


def sidecar_path(editor: str, raw: Path | str) -> Path:
    """Where that editor looks for this frame's sidecar. Lightroom and Camera
    Raw read <stem>.xmp; darktable reads <whole file name>.xmp and RawTherapee
    <whole file name>.pp3. Writing a darktable sidecar to the Lightroom name,
    as this once did, puts a file where darktable will never look AND on top of
    the Lightroom one."""
    raw = Path(raw)
    f = FORMATS[editor]
    return Path(str(raw) + f.suffix) if f.whole_name else raw.with_suffix(f.suffix)


# ------------------------------------------------------ the capability manifest

# What a writer does with one field of the neutral Edit.
#   FULL     the number reaches the same control unchanged
#   APPROX   something moves, but rescaled or onto a different tool
#   DROPPED  nothing is written, and the note says why
# A dropped setting used to be an inline comment in this file, which meant the
# studio could not tell a user what their chosen editor would lose. These three
# words and the note beside them are that comment, made readable by a program.
FULL, APPROX, DROPPED = "full", "approximate", "dropped"

_DT_PARTIAL = ("darktable's develop settings are base64 module structs, versioned per release; "
               "see the note at the top of this file")

CARRIES: dict[str, dict[str, tuple[str, str]]] = {
    # presets.write_dops, not this file: described here so the studio can compare.
    "dxo": {
        "exposure": (FULL, "the preset's own exposure, auto mode and bias"),
        "temperature": (FULL, "WhiteBalanceRawTemperature"),
        "tint": (FULL, "WhiteBalanceRawTint"),
        "highlights": (FULL, "LightingV3Highlights"),
        "shadows": (FULL, "LightingV3Shadows"),
        "blacks": (FULL, "LightingV3BlackPoint"),
        "whites": (FULL, "LightingV3WhitePoint"),
        "contrast": (FULL, "ContrastEnhancementGlobalIntensity"),
        "vibrance": (FULL, "VibrancyIntensity"),
        "saturation": (FULL, "the HSL tables the look learner writes"),
        "dehaze": (FULL, "DehazingValue"),
        "vignette": (FULL, "ArtisticVignettingCornerAttenuation"),
        "skin_sat": (FULL, "the orange HSL table"),
        "red_sat": (FULL, "the red HSL table"),
        "red_lum": (FULL, "the red HSL table"),
        "masks": (FULL, "PhotoLab's own AI masks, one per face, prompt point and exposure bias"),
        "name": (FULL, "AppliedPresetDisplayName"),
        "notes": (FULL, "keywords on the frame"),
        "rating": (FULL, "the sidecar's Rating, with the cull's clear wins as a keyword"),
        "label": (DROPPED, "the .dop writer writes keywords and a rating and no color label"),
    },
    "lightroom": {
        "exposure": (FULL, "crs:Exposure2012, EV for EV"),
        "temperature": (FULL, "crs:Temperature in kelvin with WhiteBalance=Custom; each vendor puts its own camera "
                              "profile behind that kelvin, so the frame starts in the same place, not an identical one"),
        "tint": (APPROX, "crs:Tint is green to magenta like DxO's raw tint but not on the same scale; the number is "
                         "carried across as it stands"),
        "highlights": (FULL, "crs:Highlights2012, the same -100..100 slider"),
        "shadows": (FULL, "crs:Shadows2012"),
        "blacks": (FULL, "crs:Blacks2012"),
        "whites": (FULL, "crs:Whites2012"),
        "contrast": (FULL, "crs:Contrast2012"),
        "vibrance": (FULL, "crs:Vibrance"),
        "saturation": (FULL, "crs:Saturation"),
        "dehaze": (FULL, "crs:Dehaze"),
        "vignette": (APPROX, "crs:PostCropVignetteAmount is a post-crop vignette, not DxO's corner attenuation"),
        "skin_sat": (FULL, "crs:SaturationAdjustmentOrange, the color mixer process version 6 fixed the banding in"),
        "red_sat": (FULL, "crs:SaturationAdjustmentRed"),
        "red_lum": (FULL, "crs:LuminanceAdjustmentRed"),
        "masks": (DROPPED, "a radial over the face would be the nearest thing Lightroom has, but the mask this "
                           "pipeline computes is a prompt point and an exposure bias with no extent, and a radial "
                           "needs one: inventing a size would put an edit on the frame that nothing measured. The "
                           "frame still gets the global exposure the mask was correcting around"),
        "name": (FULL, "dc:description"),
        "notes": (FULL, "dc:subject, one keyword per note"),
        "rating": (FULL, "xmp:Rating"),
        "label": (FULL, "xmp:Label"),
    },
    "rawtherapee": {
        "exposure": (FULL, "[Exposure] Compensation, EV for EV"),
        "temperature": (FULL, "[White Balance] Temperature with Setting=Custom, and the standard observer named "
                              "explicitly so the kelvin does not depend on the declared version"),
        "tint": (APPROX, "RawTherapee has no tint slider: the tint becomes the Green channel multiplier, 1 + tint/1000"),
        "highlights": (APPROX, "only a negative highlights value maps, onto HighlightCompr, and it turns on "
                               "highlight reconstruction past -20"),
        "shadows": (APPROX, "only a positive shadows value maps, onto ShadowCompr, which is a different curve"),
        "blacks": (APPROX, "only a negative black point maps: RawTherapee's is in raw levels, not -100..100, so the "
                           "value is scaled by 40 and clamped at the tool's floor. DxO's positive black point, which "
                           "22 of the 1,190 .dop sidecars on this machine carry, is not written at all"),
        "whites": (DROPPED, "RawTherapee's exposure tool has no white point slider"),
        "contrast": (FULL, "[Exposure] Contrast"),
        "vibrance": (APPROX, "[Vibrance] Pastels and Saturated, with skin protection on"),
        "saturation": (FULL, "[Exposure] Saturation"),
        "dehaze": (FULL, "[Dehaze] Strength"),
        "vignette": (APPROX, "[Vignetting Correction] Amount, with a radius this pipeline does not measure"),
        "skin_sat": (DROPPED, "RawTherapee's HSV equaliser is a curve, not a per-color slider; nothing here draws one"),
        "red_sat": (DROPPED, "as skin_sat"),
        "red_lum": (DROPPED, "as skin_sat"),
        "masks": (DROPPED, "RawTherapee's local edits are its own spot and local-lab shapes; nothing here draws one"),
        "name": (DROPPED, "a .pp3 has nowhere to put a caption; the preset name only reaches the comment at the top"),
        "notes": (DROPPED, "as name"),
        "rating": (FULL, "[General] Rank"),
        "label": (FULL, "[General] ColorLabel, counted from 1"),
    },
    "darktable": {
        "exposure": (DROPPED, _DT_PARTIAL),
        "temperature": (DROPPED, _DT_PARTIAL),
        "tint": (DROPPED, _DT_PARTIAL),
        "highlights": (DROPPED, _DT_PARTIAL),
        "shadows": (DROPPED, _DT_PARTIAL),
        "blacks": (DROPPED, _DT_PARTIAL),
        "whites": (DROPPED, _DT_PARTIAL),
        "contrast": (DROPPED, _DT_PARTIAL),
        "vibrance": (DROPPED, _DT_PARTIAL),
        "saturation": (DROPPED, _DT_PARTIAL),
        "dehaze": (DROPPED, _DT_PARTIAL),
        "vignette": (DROPPED, _DT_PARTIAL),
        "skin_sat": (DROPPED, _DT_PARTIAL),
        "red_sat": (DROPPED, _DT_PARTIAL),
        "red_lum": (DROPPED, _DT_PARTIAL),
        "masks": (DROPPED, _DT_PARTIAL),
        "name": (FULL, "dc:description"),
        "notes": (DROPPED, "darktable reads dc:subject as its tag list, and the cull's notes are not tags"),
        "rating": (FULL, "xmp:Rating, with darktable:xmp_version beside it so the rating is read even when the "
                         "user has set 'ignore embedded rating'"),
        "label": (FULL, "xmp:Label, which darktable prefers, and darktable:colorlabels as the integer it expects"),
    },
}


# What a presets run does not decide for these three, whatever their writers
# could carry. Both are per-frame decisions and both are measured against DxO:
# the exposure is the stops between the subject's face and the published band
# after DxO's own render lift (presets.RENDER_GAIN, measured on DxO exports),
# and a mask is PhotoLab's AI mask. Lightroom's and RawTherapee's renderings
# lift a raw file by a different amount, so writing that EV into their
# sidecars would be a number measured through one renderer and applied under
# another. These three are written once per scene, and the scene decides no
# exposure at all (presets.decide step 3): it is reported, never set.
NOT_DECIDED = {
    "exposure": ("decided per frame, in stops measured through DxO's own rendering, and written into the .dop only; "
                 "the scene's sidecar here starts at 0 EV and the measurement is in the notes"),
    "masks": ("decided per frame, as PhotoLab's AI masks over the faces the global move leaves short; "
              "the scene's sidecar here carries none"),
}


def not_decided(editor: str) -> dict:
    """The fields a presets run leaves at rest in this editor's sidecar, as
    against the fields its writer could not carry (CARRIES). The .dop is
    where the per-frame decisions go."""
    return {} if editor == "dxo" else dict(NOT_DECIDED)


def manifest(editor: str) -> dict:
    """What this writer does with a neutral Edit, in a form a program can read.
    The studio can then say 'Lightroom: the whole edit, the face masks become
    nothing' instead of quietly writing a worse file."""
    f = FORMATS[editor]
    c = CARRIES[editor]
    return {
        "editor": editor,
        "suffix": f.suffix,
        "declares": dict(f.declares),
        "apps": f.apps,
        "checked": f.checked,
        "full": sorted(k for k, (lv, _) in c.items() if lv == FULL),
        "approximate": {k: why for k, (lv, why) in c.items() if lv == APPROX},
        "dropped": {k: why for k, (lv, why) in c.items() if lv == DROPPED},
        "not_decided": not_decided(editor),
    }


def summary(editor: str) -> str:
    """One line of it, for a person."""
    m = manifest(editor)
    total = len(CARRIES[editor])
    say = lambda ks: ", ".join(sorted(k.replace("_", " ") for k in ks))  # noqa: E731
    parts = [f"{len(m['full'])} of {total} settings carried"]
    if m["approximate"]:
        parts.append("approximated: " + say(m["approximate"]))
    if m["dropped"]:
        parts.append("not carried: " + say(m["dropped"]))
    if m["not_decided"]:
        parts.append("not decided for this editor: " + say(m["not_decided"]))
    return f"{editor} ({m['suffix']}): " + "; ".join(parts)


# --------------------------------------------------------- someone else's file

# The words that make a sidecar this tool's to replace. A new file carries
# MARK. Every Lightroom, RawTherapee and darktable sidecar written before the
# app was called First Edit carries the old words, and is just as much ours:
# is_ours() accepts both, for good. Dropping the old words would turn each of
# those files into someone else's, never to be refreshed again.
MARK = "first-edit sidecar"
FORMER_MARKS = ("photo-pipeline sidecar",)


def _stamp(editor: str, what: str = "") -> str:
    """The line that says this file is the pipeline's to replace. No double
    hyphen anywhere in it: it goes inside an XML comment. `what` names what
    the file carries where that is not the whole starting edit, so a sidecar
    of keywords does not claim a process version it does not have."""
    f = FORMATS[editor]
    v = what or ", ".join(f"{k} {x}" for k, x in f.declares.items())
    return (f"{MARK} for {editor}" + (f" ({v})" if v else "")
            + ". A later run may replace this file while this line is in it. Your editor rewrites the file from its "
              "own state when you save, which takes this line out, and the pipeline then leaves the file alone.")


def is_ours(text: str) -> bool:
    """A sidecar this pipeline wrote and nothing has saved over since, under
    the app's name today or the one it had before."""
    return any(m in text for m in (MARK, *FORMER_MARKS))


def render(editor: str, e: Edit, rating: int = 0, label: str = "", existing: str = "") -> str | None:
    """The sidecar text for one frame, or None when the file already sitting
    there is someone else's and must be kept -- the same discipline as the .dop
    path, where --force replaces what the pipeline wrote and never what the
    photographer wrote. Callers pass the existing file's text, or "" when there
    is none."""
    if existing.strip() and not is_ours(existing):
        return None
    if editor == "lightroom":
        return lightroom_xmp(e, rating=rating, label=label)
    if editor == "rawtherapee":
        return rawtherapee_pp3(e, rating=rating, label=label)
    if editor == "darktable":
        return darktable_xmp(rating=rating, label=label, name=e.name)
    raise KeyError(f"{editor}: the .dop is written by presets.write_dops, not here")


def _x(s) -> str:
    """The free text that reaches an XMP -- the scene name, the cull's notes, a
    colour label -- escaped for the document it is going into. An XMP that does
    not parse is a frame the editor refuses, and one ampersand in a scene name
    is all it takes: the test that looked as though it covered this took the
    ampersand and the angle brackets out of its own probe first."""
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;"))


def _label_index(label: str) -> int | None:
    """Which of the five colours a label names, or None for a label this
    pipeline cannot map to a number. An unmappable label still travels as
    xmp:Label, which is free text; it just gets no integer beside it."""
    for i, name in enumerate(LABELS):
        if label.strip().lower() == name.lower():
            return i
    return None


# ------------------------------------------------------------------ keywords

# dc:subject as this file writes it: a Bag of rdf:li, which is what Lightroom,
# Camera Raw, Bridge and exiftool all read as the keyword list.
_BAG = re.compile(r"(<dc:subject>\s*<rdf:Bag>)(.*?)(\s*</rdf:Bag>\s*</dc:subject>)", re.S)


def keywords_of(text: str) -> list[str]:
    """The keywords an XMP of this pipeline's carries."""
    m = _BAG.search(text)
    return [unescape(k) for k in re.findall(r"<rdf:li>(.*?)</rdf:li>", m.group(2), re.S)] if m else []


def with_keywords(text: str, keywords: list[str]) -> str:
    """The same sidecar with exactly these keywords in it, or a new one when
    there is no file yet.

    Only ever called on a file this pipeline wrote (is_ours). A sidecar of
    someone else's is the editor's own record of their edit, and the rule
    here is the .dop path's: what is not ours is not ours to rewrite."""
    if not text.strip():
        return keyword_xmp(keywords)
    m = _BAG.search(text)
    if not m:
        return text                     # ours, but not a shape this can add to
    return text[:m.start(2)] + "".join(f"\n         <rdf:li>{_x(k)}</rdf:li>" for k in keywords) + text[m.end(2):]


def keyword_xmp(keywords: list[str]) -> str:
    """A sidecar carrying keywords and nothing else, at the name Lightroom and
    Camera Raw read. It carries the stamp, so a later run knows the file as
    this pipeline's and may add to it; the first time your editor saves over
    it the stamp goes with the rest and the file is left alone from then on."""
    why = "".join(f"\n         <rdf:li>{_x(k)}</rdf:li>" for k in keywords)
    return f"""<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <!-- {_stamp("lightroom", "keywords only")} -->
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:dc="http://purl.org/dc/elements/1.1/">
   <dc:subject><rdf:Bag>{why}
   </rdf:Bag></dc:subject>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
"""


# ------------------------------------------------------------------ Lightroom

def lightroom_xmp(e: Edit, rating: int = 0, label: str = "") -> str:
    """An XMP sidecar in Adobe's crs: namespace, which Lightroom Classic and
    Camera Raw both read. Written next to the RAW as <stem>.xmp."""
    f = FORMATS["lightroom"]
    crs = {
        "Version": f.declares["Version"], "ProcessVersion": f.declares["ProcessVersion"],
        "Exposure2012": f"{e.exposure:+.2f}",
        "Contrast2012": e.contrast, "Highlights2012": e.highlights,
        "Shadows2012": e.shadows, "Whites2012": e.whites, "Blacks2012": e.blacks,
        "Vibrance": e.vibrance, "Saturation": e.saturation, "Dehaze": e.dehaze,
        "PostCropVignetteAmount": e.vignette,
        "SaturationAdjustmentOrange": e.skin_sat,
        "SaturationAdjustmentRed": e.red_sat,
        "LuminanceAdjustmentRed": e.red_lum,
        "HasSettings": "True",
    }
    if e.temperature:
        crs["Temperature"] = e.temperature
        crs["Tint"] = e.tint
        crs["WhiteBalance"] = "Custom"
    attrs = "\n      ".join(f'crs:{k}="{v}"' for k, v in crs.items())
    extra = ""
    if rating:
        extra += f'\n      xmp:Rating="{rating}"'
    if label:
        extra += f'\n      xmp:Label="{_x(label)}"'
    why = "".join(f"\n         <rdf:li>{_x(n)}</rdf:li>" for n in e.notes)
    return f"""<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <!-- {_stamp("lightroom")} -->
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
      {attrs}{extra}>
   <dc:description>
    <rdf:Alt><rdf:li xml:lang="x-default">{_x(e.name)}</rdf:li></rdf:Alt>
   </dc:description>
   <dc:subject><rdf:Bag>{why}
   </rdf:Bag></dc:subject>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
"""


# ---------------------------------------------------------------- RawTherapee

def rawtherapee_pp3(e: Edit, rating: int = 0, label: str = "") -> str:
    """A .pp3 profile, written next to the RAW as <name>.ARW.pp3. Plain INI,
    which is why this is the easiest of the four to be sure about."""
    # RawTherapee's exposure compensation is in EV, its tone sliders 0..100 or
    # -100..100 depending on the tool, so the mapping is stated rather than guessed.
    f = FORMATS["rawtherapee"]
    lines = [
        f"# {_stamp('rawtherapee')}", "",
        "[Version]", f"AppVersion={f.declares['AppVersion']}", f"Version={f.declares['Version']}", "",
        "[Exposure]", "Auto=false", f"Compensation={e.exposure:.2f}",
        f"Black={max(-16384, min(0, e.blacks * 40))}",
        f"HighlightCompr={max(0, -e.highlights)}",
        f"ShadowCompr={max(0, e.shadows)}",
        f"Contrast={e.contrast}", f"Saturation={e.saturation}", "",
        "[HLRecovery]", f"Enabled={'true' if e.highlights < -20 else 'false'}", "Method=Blend", "",
        "[Vibrance]", f"Enabled={'true' if e.vibrance else 'false'}",
        f"Pastels={e.vibrance}", f"Saturated={max(0, e.vibrance - 5)}",
        "ProtectSkins=true", "AvoidColorShift=true", "",
    ]
    if e.temperature:
        # StandardObserver is named rather than left to the version branch: a
        # computed kelvin has to render as the same kelvin typed in by hand,
        # and RawTherapee's own default is the 2 degree observer.
        lines += ["[White Balance]", "Enabled=true", "Setting=Custom",
                  f"Temperature={e.temperature}", f"Green={1.0 + e.tint / 1000.0:.4f}",
                  "StandardObserver=TWO_DEGREES", ""]
    if e.dehaze:
        lines += ["[Dehaze]", "Enabled=true", f"Strength={e.dehaze}", ""]
    if e.vignette:
        lines += ["[Vignetting Correction]", f"Amount={e.vignette}", "Radius=50", "Strength=1", ""]
    colour = _label_index(label)
    if rating or colour is not None:
        lines += ["[General]"]
        if rating:
            lines += [f"Rank={rating}"]
        if colour is not None:
            lines += [f"ColorLabel={colour + 1}"]     # RawTherapee counts from 1; 0 is no label
        lines += [""]
    lines += ["[Directional Pyramid Denoising]", "Enabled=true", "Method=Lab", ""]
    return "\n".join(lines)


# ------------------------------------------------------------------ darktable

def darktable_xmp(rating: int = 0, label: str = "", name: str = "") -> str:
    """Rating and colour label only, and on purpose: see the note at the top of
    this file. darktable reads this on import and the frames arrive starred.

    xmp_version and auto_presets_applied are the shape darktable itself writes
    for a frame it has imported and nobody has developed: with xmp_version
    present the rating survives the "ignore embedded rating" preference, and
    with auto_presets_applied=0 darktable still applies the user's own automatic
    presets the first time the frame is opened. Claiming 1 there would open
    every frame with no modules at all."""
    f = FORMATS["darktable"]
    extra = f'\n   darktable:xmp_version="{f.declares["xmp_version"]}"\n   darktable:auto_presets_applied="0"'
    if rating:
        extra += f'\n   xmp:Rating="{rating}"'
    if label:
        extra += f'\n   xmp:Label="{_x(label)}"'
    colour = _label_index(label)
    lab = "" if colour is None else f"""
   <darktable:colorlabels><rdf:Seq><rdf:li>{colour}</rdf:li></rdf:Seq></darktable:colorlabels>"""
    return f"""<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <!-- {_stamp("darktable")} -->
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:darktable="http://darktable.sf.net/"{extra}>
   <dc:description>
    <rdf:Alt><rdf:li xml:lang="x-default">{_x(name)}</rdf:li></rdf:Alt>
   </dc:description>{lab}
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
"""
