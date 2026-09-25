#!/usr/bin/env python3
"""
grade.py - a colour grade per frame, solved from what the frame measures, on
every frame the starting edit is written for.

On each frame, how far to move the sliders that make a picture pop, and it is
a different amount on every frame, because every frame starts somewhere
different. A flat overcast frame is lifted toward the preferred chroma; one
that is already vivid is left alone; a sky that reads grey-blue is taken
toward the preferred sky and a lawn toward the preferred green, by as much as
each one is short; a face is never pushed past the published skin ceiling.

WHAT A SLIDER DOES IS AN ESTIMATE, AND SAID SO. The targets are published
(below); the step from a target to a slider value needs to know what, say,
+20 on DxO's Vibrancy does to a frame's chroma, and nothing can ask PhotoLab
to render and find out. PRIOR is that estimate: per unit of each slider, the
effect a grade expects, set so the published x1.15 lift on a flat frame lands
at a Vibrancy DxO's own vivid presets sit near, and stated as this file's, not
DxO's. Every frame's note says the scale is estimated. When his finished work
ever carries these sliders, the scale is to be fitted from it, not typed.

The effects are treated as linear in the slider over the range a grade uses
(CAP below). That is an approximation and it is said here rather than hidden.

WHAT A FRAME IS HELD TO (the targets; docs/COLOR.md for the sources):
  - chroma: lifted over the rendering by target(): x1.15 on a flat frame,
    x1.10 on a quite colourful one, nothing on one already "highly
    colourful" (Hasler & Susstrunk M3 >= 82) or already clipping in colour;
  - skin: the lift is cut back until a sure face's predicted chroma stays
    under max(its own, PUBLISHED.SKIN_C). Skin is never desaturated here: that
    is the edit the photographer turned down by name (presets.decide, 6);
  - sky and foliage: chroma toward the preferred centre (pop.MEMORY), never
    past it; foliage hue half the way toward it and at most MAX_HUE_MOVE
    degrees, because a lawn's hue varies with the grass and the preferred
    shift is small (Cao & Luo 2023). Sky hue is not moved: the preference
    evidence is about purity, not hue.
Every slider is also clamped to CAP: a guard on the slider, like presets'
BIAS_FLOOR, not a measurement.
"""

from __future__ import annotations

import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import pop as pop_scale  # noqa: E402

VIVID_M3 = 82.0                  # "highly colorful" (pop.M3_ANCHORS): already there
CLIPPING = 0.01                  # a frame with this much colour clipped gets no lift
MAX_HUE_MOVE = 5.0               # degrees a foliage hue may be moved on one frame
HUE_SHARE = 0.5                  # of the way to the preferred foliage hue
CAP = {"VibrancyIntensity": (0, 60), "HSL.Blue.Saturation": (0, 40), "HSL.Green.Saturation": (0, 40),
       "HSL.Green.Hue": (-30, 30)}
NATURAL_VIBRANCY = 5             # DxO's own "1 - DxO Style - Natural" (presets.SHIPPED_FALLBACK)


# ------------------------------------------------------------------ the sidecar

def _template_hsl() -> str:
    """The template's HSL table, every slice at zero, re-indented to a
    sidecar's Base (five tabs): the layout PhotoLab expects, with DxO's own
    fade bounds per slice."""
    import presets
    text = presets.TEMPLATE.read_text()
    m = re.search(r"\n(\s*)HSLHueSlices = \{\n.*?\n\1\},\n", text, re.S)
    block = m.group(0).strip("\n")
    ind = m.group(1)
    lines = []
    for ln in block.split("\n"):
        body = ln[len(ind):] if ln.startswith(ind) else ln.lstrip()
        depth = (len(body) - len(body.lstrip(" "))) // 2
        lines.append("\t" * (5 + depth) + body.strip())
    out = "\n".join(lines) + "\n"
    return re.sub(r"^(\t+)(Hue|Saturation|Luminance) = [^,]*,", r"\1\2 = 0,", out, flags=re.M)


def _slice_value(block: str, label: str, field: str) -> float:
    m = re.search(rf"{field} = ([-\d.]+),[^{{}}]*?Label = \"{label}\"", block, re.S)
    return float(m.group(1)) if m else 0.0


def _set_slice(block: str, label: str, field: str, value: float) -> str:
    pat = re.compile(rf"({field} = )([-\d.]+)(,[^{{}}]*?Label = \"{label}\")", re.S)
    return pat.sub(lambda m: f"{m.group(1)}{_num(value)}{m.group(3)}", block, count=1)


def _num(v: float) -> str:
    return str(int(round(v))) if abs(v - round(v)) < 1e-9 else f"{v:g}"


def current(text: str, key: str) -> float:
    """The value a slider has on this sidecar: Overrides over Base over
    DxO's Natural default."""
    import taste
    if key.startswith("HSL."):
        _, label, field = key.split(".")
        for name in ("Overrides", "Base"):
            blk = taste._block(text, name)
            if f'Label = "{label}"' in blk:
                return _slice_value(blk, label, field)
        return 0.0
    for name in ("Overrides", "Base"):
        m = re.search(rf"^\s*{key} = ([-\d.]+),", taste._block(text, name), re.M)
        if m:
            return float(m.group(1))
    return float(NATURAL_VIBRANCY if key == "VibrancyIntensity" else 0)


def apply(text: str, values: dict[str, float]) -> str:
    """A sidecar with these absolute slider values and nothing else changed.

    Flat keys are set wherever the sidecar names them and added to the Base
    where it does not. HSL slices are set in the Base's HSL table, which is
    added from the template (every slice zero, DxO's fade bounds) when the
    Base has none: a Base written on DxO's camera rendering is partial and
    carries no HSL table, and a slice written into a table that is not there
    was silently dropped (presets.write_dops caught the KeyError). A value the
    photographer set in Overrides stays his: Overrides win in PhotoLab, and
    this never writes there."""
    flat = {k: v for k, v in values.items() if not k.startswith("HSL.")}
    hsl = {k: v for k, v in values.items() if k.startswith("HSL.")}
    m = re.search(r"(\n(\t*)Base = \{\n)(.*?)(\n\2\},\n)", text, re.S)
    if not m:
        raise ValueError("no Base block")
    head, ind, body, tail = m.group(1), m.group(2), m.group(3), m.group(4)
    i = ind + "\t"
    for k, v in flat.items():
        body, n = re.subn(rf"^(\s*){k} = [^\n{{]*,$", lambda mm, k=k, v=v: f"{mm.group(1)}{k} = {_num(v)},", body, flags=re.M)
        if not n:
            body = f"{i}{k} = {_num(v)},\n" + body
    if hsl:
        if "HSLHueSlices = {" not in body:
            tab = "\n".join((i + ln[5:] if ln.startswith("\t" * 5) else ln) for ln in _template_hsl().split("\n"))
            body = f"{i}HSLActive = true,\n" + tab + body
        else:
            body = re.sub(r"^(\s*)HSLActive = false,", r"\1HSLActive = true,", body, flags=re.M)
        for k, v in hsl.items():
            _, label, field = k.split(".")
            body = _set_slice(body, label, field, v)
    return text[:m.start()] + head + body + tail + text[m.end():]


# ------------------------------------------------------------------ the scale

# Per unit of slider: the effects solve() plans with. chroma_log is the log of
# the frame's mean-chroma ratio; skin_dC, sky_dC, foliage_dC are CIELAB C*ab
# changes of those regions; foliage_dh is degrees of hue. Estimates (see the
# module docstring): Vibrancy spares skin and saturated colours, so its skin
# effect is a fraction of its effect elsewhere.
PRIOR = {"estimated": True, "sliders": {
    "VibrancyIntensity": {"chroma_log": {"per_unit": 0.004}, "skin_dC": {"per_unit": 0.04}},
    "HSL.Blue.Saturation": {"sky_dC": {"per_unit": 0.25}},
    "HSL.Green.Saturation": {"foliage_dC": {"per_unit": 0.25}},
    "HSL.Green.Hue": {"foliage_dh": {"per_unit": 0.15}},
}}


# ------------------------------------------------------------------ the solve

def _g(gains: dict, key: str, effect: str) -> float | None:
    e = ((gains.get("sliders") or {}).get(key) or {}).get(effect)
    return e["per_unit"] if e else None


def _clamp(key: str, v: float) -> float:
    lo, hi = CAP[key]
    return max(lo, min(hi, v))


def target(m3: float) -> float:
    """The chroma factor a frame of this colourfulness is lifted by.

    Inside the published preference range and nowhere outside it: the top of
    it (x1.15) for a frame at or under "moderately colorful" (M3 33), the
    bottom (x1.10) at "quite colorful" (59), and down to nothing at "highly
    colorful" (82), linearly between those anchors of Hasler & Susstrunk's
    scale. The anchors are theirs and the range is de Ridder's; joining them
    with straight lines is this file's choice, made so that a flat frame gets
    more and a vivid one less, rather than every frame the same."""
    lo, hi = pop_scale.CHROMA_PREFERRED
    if m3 <= 33.0:
        return hi
    if m3 <= 59.0:
        return hi + (lo - hi) * (m3 - 33.0) / 26.0
    if m3 < VIVID_M3:
        return lo + (1.0 - lo) * (m3 - 59.0) / (VIVID_M3 - 59.0)
    return 1.0


def solve(m: dict, gains: dict | None = None, now: dict | None = None) -> tuple[dict, list[str]]:
    """(absolute slider values for this frame, what was decided and why).

    m is the frame as measured (presets.measure_frame: pop_* keys, and the
    largest face's face_C_big / face_hue_big). now is the slider values the
    frame already has (current()); a grade adds to them. Only sliders that
    move are returned, so a frame that needs nothing gets nothing."""
    import taste
    from presets import PUBLISHED
    gains = gains or PRIOR
    now = now or {}
    out: dict = {}
    why: list[str] = []
    m3, clip = m.get("pop_m3"), m.get("pop_sat_clip") or 0.0

    # 1. Global chroma, by vibrancy (DxO's own skin- and saturation-protecting lift).
    gv = _g(gains, "VibrancyIntensity", "chroma_log")
    lift = 0.0
    if gv and gv > 0 and m3 is not None:
        if m3 >= VIVID_M3:
            why.append(f"already {pop_scale.colourfulness_words(m3)} (M3 {m3:.0f}): no lift")
        elif clip >= CLIPPING:
            why.append(f"{clip:.1%} already clipped in colour: no lift")
        else:
            want = target(m3)
            dv = math.log(want) / gv
            base = now.get("VibrancyIntensity", NATURAL_VIBRANCY)
            # Skin: cut the lift back until a sure face stays under its ceiling.
            gs = _g(gains, "VibrancyIntensity", "skin_dC")
            if taste.sure_face(m) and gs and gs > 0:
                room = max(float(m["face_C_big"]), PUBLISHED.SKIN_C) - float(m["face_C_big"])
                if dv * gs > room:
                    dv = max(0.0, room / gs)
                    why.append(f"lift held to keep skin under C* {max(float(m['face_C_big']), PUBLISHED.SKIN_C):.0f}")
            v = _clamp("VibrancyIntensity", base + dv)
            if v - base > 0.5:
                out["VibrancyIntensity"] = round(v)
                lift = math.exp(gv * (out["VibrancyIntensity"] - base)) - 1.0
                why.append(f"vibrancy {base:.0f}->{out['VibrancyIntensity']} for x{1 + lift:.2f} chroma "
                           f"(M3 {m3:.0f}, {pop_scale.colourfulness_words(m3)}: target x{want:.2f})")

    # 2. Memory colours: chroma toward the preferred centre, never past it.
    for region, key, centre in (("sky", "HSL.Blue.Saturation", pop_scale.MEMORY.SKY),
                                ("foliage", "HSL.Green.Saturation", pop_scale.MEMORY.FOLIAGE)):
        C = m.get(f"pop_{region}_C")
        if C is None:
            continue
        after = C * (1.0 + lift)
        short = centre[1] - after
        g = _g(gains, key, f"{region}_dC")
        if short > 1.0 and g and g > 0:
            v = _clamp(key, now.get(key, 0.0) + short / g)
            if abs(v - now.get(key, 0.0)) >= 1:
                out[key] = round(v)
                why.append(f"{region} C* {after:.0f}->{min(centre[1], after + g * (out[key] - now.get(key, 0.0))):.0f} "
                           f"toward the preferred {centre[1]:.0f}")
    h = m.get("pop_foliage_h")
    gh = _g(gains, "HSL.Green.Hue", "foliage_dh")
    if h is not None and gh:
        gap = (pop_scale.MEMORY.FOLIAGE[2] - h + 180.0) % 360.0 - 180.0
        move = max(-MAX_HUE_MOVE, min(MAX_HUE_MOVE, HUE_SHARE * gap))
        if abs(move) >= 1.0:
            v = _clamp("HSL.Green.Hue", now.get("HSL.Green.Hue", 0.0) + move / gh)
            if abs(v - now.get("HSL.Green.Hue", 0.0)) >= 1:
                out["HSL.Green.Hue"] = round(v)
                why.append(f"foliage hue {h:.0f}->{h + move:.0f} deg, half way to the preferred {pop_scale.MEMORY.FOLIAGE[2]:.0f}")
    return out, why
