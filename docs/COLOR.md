# Color: what is measured, what is known, and how "pop" gets in

The starting edit has held color to one standard so far: be right. Skin at
the published preferred hue, neutrals inside a proof's grey-balance
tolerance, a face in the published lightness band (`presets.PUBLISHED`), and
nothing written that cannot be checked against DxO. That standard stays. This
document is about the other half, which a frame can fail while passing every
check above: whether it looks good. It says what the literature supports,
how sure each number is, what the pipeline now measures, and the route by
which any of it may one day reach a sidecar.

## What is measured now

`pipeline/pop.py`, report only. No DxO key appears in it (a test holds
that).

| Reading | Scale | Source |
|---|---|---|
| `m3`, `m3_not_faces` | Hasler & Süsstrunk colorfulness on signed opponents, with the observers' words (15 slightly … 59 quite … 109 extremely) | Hasler & Süsstrunk, SPIE 5007, 2003 |
| `oklab_C_median`, `oklab_C_p90` | chroma in Oklab, the hue-linear space a saturation move would be made in | Ottosson 2020; why hue-linear: Hung & Berns 1995 |
| `sky`, `foliage` | where the pixels that read as sky or foliage sit, and how far from the preferred centre | centres computed from Luo's Preferred Memory Color chart, 2024 |

Two instrument fixes land with it. CIELAB is read at float precision rather
than off OpenCV's 8-bit conversion, which rounds a\* and b\* to whole units —
about 3° of skin hue at C\* 20, the size of the tolerance skin is judged to.
And the camera's as-shot white balance is read on its green–magenta axis as
well as red–blue, because that axis is what separates fluorescent and LED
light from tungsten. The white-balance model may use it only when every frame
it is fitted on carries it, and only after the existing held-out check.

The grey of the room is also read a second way, `grey_a`/`grey_b`: the
median of the near-neutral pixels with every face box left out, where
`cast_a`/`cast_b` are their mean with the faces in. On synthetic scenes the
mean reports about three quarters of a small cast, tops out near b\* +10 and
picks up a\* +1 to +3 from skin; the median without faces tracks the true
cast far better (R² 0.89 / 0.80 against 0.54 / 0.49). The scene notes read
the new one now. The models keep the old one until held-out frames of the
photographer's say the swap wins, because changing a model input means a
`MEASURE_SCHEMA` bump and archived shoots cannot be measured again.

## What the literature supports

Marked by how each number was checked. **[S]** seen at a primary source or a
mirror of its data; **[snip]** citation confirmed, number from an abstract or
search snippet; **[C]** computed here from published data; **[K]** from
general knowledge, not checked. Publisher sites were unreachable from the
machine that did this reading; everything below marked [snip] or [K] should be
read at source before it decides anything.

- **Preferred is more colorful than accurate, and the curve turns over.**
  Quality is an inverted U in chroma scaling, peaking about ×1.10–1.15 above
  the original. de Ridder et al., SPIE 2411, 1995, doi:10.1117/12.207555
  [snip]; Fedorovskaya, de Ridder & Blommaert, Color Res. Appl. 22(2), 1997
  [snip; the exact optimum K].
- **Memory colors are preferred only slightly away from natural:** about
  +2 C\*ab, +1 L\*, over 24 objects and 106 observers. Cao & Luo, Color Res.
  Appl. 48(2):178–200, 2023, doi:10.1002/col.22841 [snip].
- **Preferred sky is purer than real sky; preferred grass is as pure and
  slightly yellower.** Hunt, Pitt & Winter, J. Photogr. Sci. 22, 1974 [snip].
- **Centres** (CIELAB D65, 2° observer, from the PMC chart's reflectances)
  [C]: sky L\* 52.7, C\* 39.7, h 276.5°; summer grass L\* 48.0, C\* 42.5,
  h 137.4°; its skins h 46.9–48.2°, C\* 25.3–28.2 — on top of the
  Peng/Luo centre the pipeline already uses from a different paper, which is
  the check that the chart was read correctly. Against the ColorChecker's sky
  and foliage patches, preferred sky is about 1.8× the chroma and preferred
  grass 1.4–1.5×, a few degrees yellower.
- **Contrast and colorfulness go together.** Colorfulness rises with
  luminance (Hunt effect) and so does the brightness exponent (Stevens
  effect), so a print or a dim display loses both, and a boost to one alone
  looks wrong. Perceived contrast depends on lightness, chroma and sharpness
  together, and preference for it is an inverted U: Calabria & Fairchild,
  JIST 47(6), 2003 [snip]. Observers split into low, natural and high
  contrast camps with no single optimum: Cherepkova, Amirshahi & Pedersen,
  J. Imaging 10:25, 2024 [snip].
- **Local contrast helps until it haloes,** at a threshold that depends on
  the halo's width and the viewing distance: Trentacoste et al., CGF 31(2),
  2012 [snip].
- **Saturate along a hue-linear axis.** At constant CIELAB hue, blues drift
  purple by 30 ΔE or more: Hung & Berns 1995 [snip]. Oklab, IPT and
  CAM16-UCS are fitted to the data that shows it.
- **Colorfulness and aesthetics are not linearly linked overall;** links
  appear within categories such as landscape and macro. Amati, Mitra &
  Weyrich, CAe 2014 [snip]. An aesthetic score is a guard against
  oversaturation, not an objective: aesthetic models reward it, and
  `docs/ML.md` already shows AVA-trained models at or below chance on
  portraits.

**Not supported, and so not done:** a general preference for warm white
balance in portraits (Cao & Luo, Vision Research 2022, found skin preferred
captured under 6500–8000 K on mobile displays [snip]); and teal-and-orange
grading, which has no preference study behind it. Keeping some warmth under
tungsten is supported by incomplete chromatic adaptation at 2700–3200 K
[snip], which is what leaving tungsten AsShot already does.

## How "pop" reaches a sidecar

Per frame, automatically, in the starting edit `presets` writes: see
`pipeline/grade.py`. Comparing DxO's renderings by exporting them, and
previewing looks in the app, were both tried and removed: PhotoLab cannot be
asked to render, and a preview drawn outside it did not look like PhotoLab.

Beyond renderings, the open-source route that fits this design is a small
proxy renderer that behaves like DxO's sliders, calibrated against the
photographer's own sidecars and exports, with a target image fitted back to
slider values. The candidates for the target and what they may be used for:

| Candidate | License | Note |
|---|---|---|
| The camera's own JPEG (tone matched as RawTherapee's auto-matched curve does) | reimplemented, no code taken | already on disk; the camera's picture style is a tuned target |
| SepLUT / AdaInt / Image-Adaptive 3D LUT | Apache-2.0 | < 1M parameters, milliseconds on CPU; public weights are trained on FiveK / PPR10K, which are non-commercial |
| CURL (saturation-by-hue curves) | BSD-3 | maps onto DxO's HSL slices |
| StarEnhancer (style from a few examples) | MIT | suits "learn his look" |
| Hu et al., *Exposure* (white-box filters) | MIT | the filter set is nearly DxO's slider set: a template for the proxy |
| MIT-Adobe FiveK, PPR10K (slider data) | non-commercial | fine to study; anything shipped is retrained on his own edits |

For a build that stays MIT and fit for paid work, every learned piece is
retrained on the photographer's own edits, which are the only data both
license-clean and on his taste.

## Exposure, per frame

`presets._expose`, with the constants beside it. A frame with no face has its
midtones taken to a target for its light level (EV100 of the camera's
settings): L\* 50 in daylight (middle grey, as RawTherapee's auto levels,
darktable's filmic grey 18.45% and Mertens' well-exposedness all put it),
falling to about 42 at LV 7, 36 at LV 5 and 22 at LV 2 so a night frame still
reads as night (an inference from Krawczyk et al. 2005's key model; Night
Sight's stated aim). A face under the published band is lifted globally toward
the band's middle, never past L\* 58 (FirstEditMobile's cap). Every lift stops
at the highlights' headroom (the 99.95th percentile of the RAW's photosites,
less 0.15 EV), at ±1.5 EV, and where ISO × 2^lift would pass 12,800; what a
face still lacks goes to its mask, which moves at most half a stop. Under a
third of a stop nothing is written. Where FirstEditMobile measured the
same rules against his own exports, its numbers win: in low light a frame is
lifted only toward L\* 40, at most a stop at LV 7 falling to none at LV 2, and
left as shot between L\* 40 and 50; in daylight a face lifts the whole frame at
most a stop and not past a frame median of L\* 55 (a face needing more is
backlit, and the rest is its mask's). Yuan & Sun (ECCV 2012) is the published
case for lifting globally within the headroom and leaving the rest to local
tools: preferred to the input 70% to 6% in their study. The LV targets, the
noise cap and the margins are inferences, not published numbers.


### Aims learned from his exports; the constants are the prior

Every number above that says *where* a frame goes (the target L\* by light
level and the quarter-stop daylight trim, the face aim at the band's middle
capped at 58, the S-curve's 0.10 and 0.03) is now the fallback prior. Each
is also predicted per frame from his finished exports, and the prediction
takes over where it has earned it (`taste.learn_tone`, read by
`presets.predicted_tone`):

| Target | His export's reading | Where presets uses it | The rule it must beat, on the same frames |
|---|---|---|---|
| `L50` | median L\* of the export (float CIELAB, ≤ 1800 px) | a frame with no face: its midtones' aim | `rule_frame_target`: the LV target and daylight trim, the low-light key |
| `face_L` | the largest face's L\* (`export_face_L_one`) | the face aim, held inside the band and ≤ `FACE_PREFERRED_MAX` | where `_expose` leaves the face: lifted to the aim, else as shot inside the band |
| `spread_ratio` | export L\* p95−p5 ÷ the camera JPEG's | the S-curve amplitude, bisected in [0, 0.2] on the frame's own p5/p95 | the spread the rule's S gives the same p5/p95 (1.0 past `TONE_WIDE`) |

The evidence is what presets has before it writes anything: LV (and whether
it was read), log2 ISO, the camera JPEG's median, spread and clipping,
whether there is a face and its L\*, log2 of the RAW's median luminance, and
the highlight headroom. The model is a ridge on standardised evidence. Each
frame is predicted by a fit that never saw its shoot, and by its scene where
fewer than three shoots carry the target. A model is used only when its
held-out MAE is at least 10% under the rule's, and a one-sided sign test over
the frames where the two disagree gives p < 0.05. Otherwise the record says
by how much it missed, and the constant decides. On synthetic exports that
follow the light, all three models are used. On exports that are the rule
plus noise, none is (`tests/test_tone_model.py`). `learned.check_edit` holds a
candidate whose tone model fails that bar, one that would drop a model the
version in use has, and one more than 5% worse than the version in use on the
frames that taught it. Both are refitted in the same folds for that test.

Nothing learned moves a limit. The headroom, the noise cap, `AUTO_EV_MAX`,
the daylight and low-light lift limits, the deadband, `BIAS_FLOOR` and
`TONE_WIDE` bound a learned aim as they bound a constant one, and a face is
still never darkened inside the band. Each frame's note says which one
decided. A learned aim reads `brightness from your exports: L* 47 (learned
on N frames, K shoots; held-out error X vs rule Y)`, and a constant reads
`rule: …`.
