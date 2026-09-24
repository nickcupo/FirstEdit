# The machine learning in First Edit

What every model does, every threshold and where it came from, what the
numbers say so far, what is known to fail, and the training that is planned
or that someone else could do better. This is the document to read before
changing a number or proposing a model.

**Status.** Four shoots, 1,705 frames, one camera, one photographer's
taste. Nothing here has been validated beyond that. Every rule was written
to fix a specific frame that was wrong and is stated below with that frame's
story, because the alternative, thresholds tuned by feel, is how a cull
quietly starts throwing out the best frame of the night.

## Principles

1. **Judge on real pixels.** Every face is read off the full-resolution
   decode (6024 px wide on the test camera), not the 1616 px camera preview.
   At preview size a blink, a mouth mid-word and a smear of motion blur all
   look like a face.
2. **A veto has to be provable.** Only a face the landmarker could read may
   throw a frame out. A dog, a lamp, the back of a head, a face too small
   to read: those can lower a score, never veto. This rule cost the
   photographer's best frames twice before it existed.
3. **Where the photographer stood outranks any score.** `--top N` gives
   every setup (one place, one light) picks in proportion to the time spent
   there. The score only orders frames within a setup.
4. **The last word is his.** The app shows the survivors a burst at a time
   and asks why a frame is dropped. Those answers are the training data the
   next version is built on; nothing else about taste is assumed.
5. **Nothing leaves the machine.** No telemetry, no upload; the models run
   locally and the only network use is downloading them once.

## The models

| Model | Task here | Source | Size | Licence |
|---|---|---|---|---|
| YuNet (2023mar) | Face detection, at three scales | OpenCV Zoo | 0.3 MB | MIT |
| YOLOX (2022nov) | Person and animal boxes, for subject focus and preset placement | OpenCV Zoo | 36 MB | Apache-2.0 |
| SFace (2021dec) | Face identity embeddings, clustered so `cull.csv` says who is in each frame | OpenCV Zoo | 37 MB | Apache-2.0 |
| MediaPipe Face Landmarker (float16) | 478 landmarks and 52 blendshapes: blink, smile, jaw, squint, pucker, cheek, brow, eye look | Google | 3.7 MB | Apache-2.0 |
| CLIP ViT-L/14 (OpenAI weights) | Zero-shot prompts for face expression, moments, scene subject, light, flaws; embeddings for grouping, clustering and the learned probes | open_clip, via the Hugging Face hub | 1.7 GB | MIT (open_clip), OpenAI weights |
| Improved aesthetic predictor (sac+logos+ava1, linear) | A linear head on the CLIP embedding, trained on about 176,000 human ratings; light and composition | Christoph Schuhmann | 3.7 MB | Apache-2.0 |
| Perceptual hash | Second opinion on "same picture" | `imagehash` | — | BSD |

Classical parts with no weights: libraw decoding (`rawpy`), edge-strength
sharpness, structure-tensor anisotropy for motion blur, a Hough transform
for tilt, and L\* statistics for exposure.

## The cull, pass by pass, with the numbers

### Pass 0: decode

Every RAW is decoded at full resolution (camera white balance, no
auto-brighten), a frame per core (three quarters of them by default,
`--workers`), and cached beside the cull. The camera's embedded JPEG preview
is extracted too and used for what the photographer would see: exposure,
thumbnails, the tiles in the app. A star set on the camera in playback (the
`Rating` tag) keeps the frame, whatever the cull thinks.

### Pass 1: focus, on the subject

- YuNet finds faces and YOLOX finds people and animals on the decode.
  Sharpness is measured inside the subject box only; a whole-frame score
  picks a tack-sharp fence over the person in front of it every time.
- Frames are grouped into **bursts** by capture time (`--burst-gap`, 2 s).
  How sharp a frame is against the sharpest of its burst is kept for the
  ranking. `--burst-floor` would reject below a fraction of it and **ships at
  0.0, off**: it was a quota that grew with the burst's length and cost 27 of
  an action shoot's keepers. A second floor, `--dup-floor`, sorted a frame
  last within its group of look-alikes when it was under 0.60 of the best
  one; as a rejection it cost four more action keepers, then it demoted
  instead, and it is gone entirely. The size of a sharpness gap says nothing
  about which of two frames the photographer keeps.
- More than 15% of pixels at the clip point: "blown highlights", rejected.
- Mean brightness under 10 (0–255) with no subject found: rejected as dark
  (`--dark-floor`). Dark frames with a subject are left to the face judge.

### Pass 2: every face, on real pixels (`faces.py`)

Sizes are stated at a reference width of 2400 px and scaled with the actual
decode (`unit = width / 2400`), so a threshold means the same thing on any
camera. Detection runs at 1600 px and at three scales so a face that fills
the frame is found as reliably as one across the room. A face is **main**
if it is at least 5% of the frame width, or 0.6 of the biggest face, and
at least 90 px wide at the reference scale; narrower than that and nothing
about it can be judged. The frame is judged on its worst main face: in a
photo of two people, one blink is a blink.

Per main face:

- **Sharpness**: the band across the eyes is resized so its longer side is
  160 px — a fixed size, not one scaled to the frame the way `MIN_JUDGE_PX`
  is — and edge strength is read over local contrast, so a dim face and a
  bright one are on the same scale and the number is scale-free. Below 1.9
  (`--face-floor`) is soft. Under 100 pixels of band there is nothing to run
  the operator over and no reading is taken: the face is noted "no sharpness
  to judge" and cannot be binned soft. Origin: `chihuahua_184` of the
  Oxford-IIIT Pet set, a head 12 px wide on a 204 px image, vetoed for a
  softness nobody had measured.
- **Motion blur**: the anisotropy of the gradients inside the face
  (structure tensor). Defocus blurs every direction alike, about 1.0; a
  smear has strong edges one way and none the other. It is measured and
  never flagged: over 1,977 main faces on the action shoot it tops out at
  1.61 (median 1.03), so no threshold on it ever fired. It lowers the face
  score from 1.3 up, and between 1.45 and 1.75 it marks the face as a close
  call for the review order.
- **Blink** from blendshapes, worst eye: at least 0.5 with a smile under
  0.45 is a blink; shut eyes with a big smile is a laugh and stays. Between
  0.45 and 0.72 with a smile under 0.5 is a close call the app puts in
  front of me first. A face the landmarker could not read gets a CLIP-only
  "blink?" at 0.7, which never vetoes.
- **Mid-word**: smile under 0.35 and jaw open at least 0.45, or CLIP's
  "caught mid-sentence" prompt above its threshold.
- **Grimace**: CLIP's grimace prompt at least 0.5, smile under 0.3, and a
  landmark cue agreeing (squint, pucker, cheek raise or brow down).
- **Not a face**: CLIP's "a lamp, a light fixture, a ceiling" prompt at
  0.4 removes the detection entirely. Origin: a floor lamp that YuNet
  read as a face and that vetoed a frame for "eyes closed".
- **Animal**: CLIP's "a dog's or a cat's face" at 0.45 marks every hard
  flag with a question mark, so it cannot veto. Origin: at full resolution
  the landmarker will read a dog's face as a face; a dog looking away
  was throwing out the photographer's pick.
- **Exposure**, on the camera's own rendering: nothing above L\* 35 on the
  face is "face in the dark"; below 65 is "dim" (a note, not a veto).
  At least 0.35 of skin pixels at the clip point is "blown face" (veto);
  at least 0.10 is "hot" (a note). Calibration: good faces measured 0 to
  0.07, blown ones 0.29 to 0.89.
- **Head cut**: the face box's top within 1.2% of the frame's top edge.
- **Gaze**: the eye-look blendshapes against head yaw from landmarks 1, 33
  and 263, giving a 0–1 "looking down the lens" number for the ranking.
- **Identity**: an SFace embedding, clustered across the shoot, in an order
  that is a property of the set and not of the card's directory listing. The
  clustering is greedy, so its answer used to depend on the order the files
  came off the card: on the action shoot's 2,950 faces, nine orders of the
  same embeddings gave nine partitions and between 50 and 61 people, and the
  "soft for this person" fault fired on between 5 and 10 frames with nothing
  else changed. Seeding by how like the rest of the card each face is (the sum
  of its cosine similarity to every other, rounded before sorting, ties broken
  on the embedding's bytes) gives one partition under every order tried: 12,
  27, 6 and 60 people on the four shoots, the fault down to 4 frames, recall
  unchanged. Connected components would also be order-independent and are
  worse: single linkage chains a whole card into one person, whereupon the
  fault took two frames the photographer had kept.
- **Close calls** are recorded per face so the app can show them first:
  blink in [0.45, 0.72) with no smile; sharpness between 0.9 and 1.15 of
  the floor; anisotropy in [1.45, 1.75]; blown in [0.22, 0.35).

Hard flags reject the frame when they come from a landmark-read, non-animal
face, and there are four of them (`faces.HARD_FACE_FLAGS`): blink, soft,
face in the dark, blown face. "Soft" as a fault means under
`faces.UNREADABLE`, 1.2, which no kept frame in 1,705 has been — not the
1.9 `--face-floor`, which is a note. Motion blur and mid-word were hard flags:
mid-word is a note now (`mid-word?`) and motion blur is not flagged at all,
only scored. Neither transfers between shoots, and set from
portraits they cost 43 of 152 readable-face action keepers. A fifth fault,
"soft for this person", is decided in `cull.py` rather than here because it
needs the whole card: a face under half the same person's sharpest frame in
the same burst. Two faces touching are a kiss and the blink rule is lifted.
The face score used by the ranking is 1.0 reduced by blink over 0.15,
anisotropy over 1.3, blown fraction and a cut head.

**The reprieve.** Pass 1's "softest in burst" comes from the subject box on
the decode; the face judge's eye-band read is the better number. A frame pass
1 rejected that way stays if the judge read a main face and found it sharp
(`sharp >= faces.UNREADABLE`, 1.2, not `--face-floor`) with no hard flag.
Origin: frame 03831 of the first benchmark shoot, one of the photographer's
twelve picks, lost as a soft duplicate. "soft duplicate" was in the reprieve
alongside it and has been deleted: nothing has set that reason since the dup
floor stopped rejecting, and the dup floor itself is gone.

With `--burst-floor` at its shipping 0.0, the branch cannot fire at all, and
`./pl evaluate` reports both strings on a row of their own reading zero rather
than leaving them out. They are worth keeping in mind for a different reason:
the three older shoots' `cull.csv` files still carry "softest in burst", "soft
duplicate", "motion blur" and "mid-word" rejections, and none of those rules
can produce one today. A `cull.csv` is a record of the rules of its own day,
which is why the evaluation harness recomputes instead of reading one.

### Pass 3: quality and selection (`quality.py`, `cull.py`)

CLIP ViT-L/14 embeds every surviving frame (about 15 s per 200 frames on
an M-series laptop). From the embedding:

- **Aesthetic**: the LAION linear head, normalised within the shoot.
- **Moments**: zero-shot over a small list (action, embrace, portrait,
  group, crowd, animal, place, food); `action` is also a feature. An
  extension may replace the list.
- **Flaw prompts**: zero-shot for the photographer's own shadow in the
  frame (two positive prompts, two clean ones). Weight −0.08; a frame at
  0.95 or above is marked `shadow?`. It never vetoes.
- **Learned flaw probes** (`flaws.py`): one logistic probe per drop reason
  the photographer has given, trained on CLIP embeddings against the same
  shoots' keepers, reported with a five-fold held-out AUC against shuffled
  labels and not written below 0.65, used only once a reason has twelve
  examples. Weight −0.25.
- **Stacks**: a run of frames, back to back inside one burst, where CLIP
  cosine similarity and the perceptual hash both say the card barely
  changed, measured against how much this card's own consecutive frames
  change (`quality.similar_stacks`). The best by score is the stack's top
  and is tiered; the rest stay on the page under it, set aside. Nothing is
  hidden for looking alike.
- **Setups**: clusters of embeddings, refined by capture time, one per
  place-and-light.

The ranking is a weighted sum over normalised features:

| Feature | Weight | What it is |
|---|---|---|
| aesthetic | 0.50 | LAION head |
| face_score | 0 | the judge's per-face quality; the right signal for the veto and the wrong one for the ranking (below) |
| action | 0.15 | the action moment prompt |
| sharp_rel | 0.10 | sharpness relative to the burst's best |
| gaze | 0.08 | looking down the lens |
| thirds | 0.05 | subject on a third |
| shadow | −0.08 | photographer's shadow prompt |
| flaw | −0.25 | learned probes, when they exist |
| eyes_open, smile, subj_area | 0 | measured, not used: each hurt precision on the benchmark |

`--learn` fitted these weights to a shoot's selects and is retired: on the
two benchmark shoots the fit was at chance, which is the honest finding, and
one shoot's weights were then applied to every later shoot of every kind.
The weights are `quality.DEFAULT_WEIGHTS`, and what learns now is a ranker
per venue that only reorders a burst (`docs/TRAINING.md` §1). `--top N --top-by scene` (the default) allocates N across
setups in proportion to frames shot there, at least one each; `quality` is
the plain best N with two caps so a burst cannot fill the set: at most two
per time burst and a quarter of N per setup.

## The presets: reading a setup (`presets.py`)

Before any slider moves, each setup is read three ways:

- **What it is.** CLIP zero-shot over eighteen subjects (a person, a group,
  a dog, a cat, a bird, wildlife, a beach, a city, a night sky, food, a car,
  an event, ...), each in a family: people, pet, landscape, night, still
  life. YOLOX gives where the subject sits.
- **What the light is.** CLIP over twelve situations (hard sun, overcast,
  golden hour, tungsten, fluorescent, neon, backlit, ...), checked against
  the camera's white balance from the RAW multipliers, the cast on the
  near-neutral pixels, the clipped fraction and the tonal range.
- **How it sits.** Face brightness (people) or subject-box brightness in
  L\* on the camera rendering.

None of that sets a number by rule any more. The table that turned
"tungsten" into a kelvin shift and "people" into a vignette is gone: every
entry was chosen by eye for subjects I have no edits of, and I have never
set a vignette on any of 205 frames. What a frame gets is my own starting
point, read out of those 205 hand-edited sidecars (`taste.py`): a setting I
apply the same way every time becomes the preset (DeepPRIME, DxO Natural,
ClearView 9.7, V3Custom lighting), and a setting I vary with the picture gets
a ridge model on the frame's measurements, kept only where it beats
predicting my own median on scenes it never saw. A categorical choice I make
by hand on a shoot (ClearView off in a gym) carries to that shoot once made
on most of the frames I corrected there; numbers never carry, because a
number is a per-frame decision, and neither do white balance or the exposure
type, which are decided per frame.
Exposure is one, and it is decided in two steps. First the type, and by
default it is **a rule**: `presets.exposure_mode` reads it off the sensor —
the venue's own type where that venue was near-unanimous about one, else by
hand when nothing is saturated, else DxO's medium recovery where the face or
the subject is dark and strong where it is not. A venue can replace that rule
with its own fitted type, but only where the fit has beaten it (below).

There was a pooled learner here — a pair of logistics on the frame's
measurements, fitted over every venue at once — and it is gone. Fitted on
every finished frame but one shoot and asked for that shoot, it got 12.5% of
the gym's 351 frames right where that venue's own type gets 99.7%; on
2026-09-19, 25.3% against 60.9%; on the-gals, 47.5% against 53.0%; on
2026-09-21, 56.5% against 51.5%. The reason is that the exposure type is a
decision about a place: my counts per venue (by hand / strong / medium) are
350/0/1 on the gym, 103/57/40 on 2026-09-21, 48/105/45 on the-gals and
17/17/53 on 2026-09-19, and one model over all of them is worse than one over
two on the same held-out frames.

What replaced it is **per venue** (`taste.venue_exposure`): a fit on that
venue's own finished frames, held out by scene inside the venue (by burst
only where the cull put it in fewer than three scenes, and then the page says
"bursts"), each held-out fit scaled on its own training frames. It is used
only where it is right on more frames than the rule replayed on the same
frames and more than the venue's commonest type, and beats each of the two by
more than a one-sided sign test over the frames they disagree on would give
to chance (p < 0.05). And it is used **only on the shoot that taught it**. A
venue is one finished shoot, so a new shoot that merely measures like it is a
shoot the fit was never scored on — that is the borrowing that was worse than
a flat constant on three of four — and it gets the rule, as does a shoot that
measures like no venue. In practice that means a fit changes only sidecars
made again on its own shoot; reaching a new shoot would take a venue that
spans several shoots and a fit that wins held out by shoot, which nothing
here measures yet. `learned.check_edit` holds a candidate whose counts do not
clear the same bar (`taste.expo_beats`: all three counts, both sign tests),
naming the shoot, and while a fit is in use the page's in-use line says where
and on what counts.

To replay the rule on a finished frame the store has to have kept what the
rule reads off the RAW: the share of saturated photosites and the subject's
luminance. It keeps them now (`clip_any`, `subject_Y`), and a frame measured
before it did is measured once more while its RAW is on this Mac. On my
library, 23 September (counts of finished frames, the fit held out by scene
on every venue — 29, 8, 31 and 42 scenes):

| Venue | Frames | His types (hand / strong / medium) | Own fit | The rule | Commonest | Used |
|---|---|---|---|---|---|---|
| 2026-09-05-the-gals | 198 | 48 / 105 / 45 | 164 | cannot be replayed on 168 (RAWs archived before the store kept the reading) | 105 | no — it wins 72 frames and loses 13 against the commonest type, so the page asks for `./pl archive pull 2026-09-05-the-gals --apply` once, then a learning run checks it against the rule |
| 2026-09-16 (the gym) | 351 | 350 / 0 / 1 | 336 | 350 (its own near-unanimous type) | 350 | no |
| 2026-09-19 | 87 | 17 / 17 / 53 | 44 | 25 | 53 | no — the fit does not beat always-medium |
| 2026-09-21 | 200 | 103 / 57 / 40 | 102 | 107 | 103 | no |

Those are counts of finished frames under the rule of 23 September, when every
frame of a finished shoot taught. Now only the frames I exported teach, and on
those alone the venues are smaller: 2026-09-16 155 of 351, 2026-09-19 82 of
87, 2026-09-21 198 of 200, and 2026-09-05-the-gals none, because no export of
it is recorded anywhere. It is not a venue at all until its exports are found,
and the fit that won there has nothing left to learn from. This table has not
been redone on exported frames alone.

2026-09-12-lounge is not a venue: it has one finished frame, and a venue
needs three. (Held out by burst, as a first version of this did on
2026-09-19, the fit there read 51: a burst's neighbours in the same scene
share its light, and the 7 frames between the two are what having seen the
scene was worth.)

So today it writes nothing different on any venue: the one venue where a fit
wins by a distance is the one the rule cannot yet be checked on. And one
thing this measured that it does not fix: on 2026-09-19 the rule is right on
25 of 87 where always-medium is right on 53. The rule's venue preference only
applies when a venue is two-thirds one type, and 2026-09-19 is 61% medium.

Then the amount: by hand means the per-frame ridge model fitted to my 52
manual biases, held inside the range I have actually set (never positive,
never below −2); auto means DxO's recovery at the strength the rule picked,
with no bias under it. My manual edits are all pull-downs of bright frames,
so a dark face is a look and is left alone.

White balance is a decision, not a number. I have never typed a temperature
or a tint; I leave the camera's AsShot or switch to `Fluo`, which I did on
92 of the 205. A logistic model on the camera's own white-balance reading,
the a\* and b\* cast on the neutral pixels, the frame's brightness and range,
and the face's hue and lightness when there is a face, predicts that switch
per frame: held out by scene (31 scenes), AUC 0.896, accuracy 0.793 against
0.547 for always-AsShot. On five action-shoot frames I corrected by hand at
4,000-4,300 K it says AsShot, which is what I did. No kelvin or tint is
written anywhere: a number in DxO's units cannot be checked without
rendering DxO, and two attempts at computing one from a hue delta are what
turned people red. Skin is measured and reported, never corrected.
`presets.md` records what was seen, with confidences, and what was measured.

## What the numbers say

`./pl bench` runs the cull against every shoot with a `selects.json` (in
`decisions/` since `./pl migrate` ran, and read from either place), the frames
I actually kept, and writes [../tests/bench.md](../tests/bench.md). These are
my shoots and my choices, so the numbers say how it behaves for me and nothing
about how it would behave for anyone else. The current run is the file itself;
the table below is the run of 2026-09-15, kept because the rest of this
section argues from it, and the section at the end of this document is where
the rules stand now:

| Shoot | Frames | Chosen | Survive | In top 30 | Chance | P@k | Aesthetic alone | Random |
|---|---|---|---|---|---|---|---|---|
| portraits, two people, evening in town | 198 | 12 | 12 | 3 | 1.8 | 0.25 | 0.25 | 0.07 |
| a lounge, red light, two people | 296 | 25 | 23 | 7 | 2.5 | 0.43 | 0.39 | 0.10 |
| a dog, outdoors | 54 | 14 | 14 | 13 | 6.0 | 0.57 | 0.43 | 0.33 |

Read it this way. **Survive** is the only number that must be near 100%:
a veto on a frame the photographer wanted is the worst thing a cull can
do, and it is the number every threshold above was tuned to. Across the
three shoots, 49 of the 51 frames the photographer kept survive; the two
that do not are 04277, motion blur on the face, and 04308, a soft
duplicate, both in the lounge. **In top 30**
says whether the ranking would have found the picks without the
photographer; on the portraits it barely beats chance, because the picks
were taste (the wide, dim, purple underpass over the well-lit bench).
**P@k** matches the aesthetic head on the portraits and beats it on the
lounge and the dog. It was 0.17 on the portraits until `face_score` came
out of the ranking: a feature that is right for the veto was wrong for the
ranking, and with it at 0.20 the combined score lost to the head alone.
Three shoots and 51 keepers is still a small benchmark, and every number
here moves by several hundredths when one frame flips.

`./pl check` holds 94 frames whose verdicts were settled by eye against the
judge's own numbers (`tests/faces_truth.json`) and fails if any flips. It
covers blinks, laughs, kisses, blown faces, faces in the dark, dogs and cats
read as faces, nested detections, and clean passes across three shoots. `./pl selftest` runs the
whole machine on six frames it keeps for the purpose and asks each script's
own `--help` whether it takes every flag the engine passes it: nine checks,
half a minute, the night before a shoot.

## Heuristic or learned

| Part | Kind | Trained on | Confidence |
|---|---|---|---|
| Face and subject detection | pretrained models | public datasets | high |
| Blendshapes | pretrained model | Google's data | high for blink and smile; jaw and squint less so |
| Sharpness, motion, exposure, head cut | hand-written measurements with thresholds | the three shoots, frame by frame | medium; scale-invariant by construction, camera-invariant untested |
| Expression prompts | CLIP zero-shot | none here | low alone; used only where a landmark cue agrees |
| Aesthetic | pretrained linear head | 176k ratings of web images | medium; it prefers well-lit and centred |
| Moments, scene, light | CLIP zero-shot | none here | medium for subject, lower for light |
| Photographer's shadow | CLIP zero-shot | none here | low; ranks, never vetoes |
| Learned flaw probes | logistic on CLIP, from drop labels | your drops | one so far: expression, n=23, AUC 0.74 against 0.50 shuffled. It lives in the learned folder outside the repo, so a fresh checkout has none, and it is used only once the keeper check has passed it |
| Taste weights | least squares from selects | your selects | at chance so far |
| Starting edit (`taste.py`) | a median or a small model per setting, and a per-frame AsShot-or-Fluo classifier | 205 sidecars I edited by hand | the WB decision holds out by scene at AUC 0.90; each per-setting model is kept only where it beats my own median on unseen scenes |
| Exposure type, per venue (`taste.venue_exposure`) | two logistics per venue, on that venue's own finished frames | my finished sidecars, one venue at a time | used only on the shoot that taught it, and only where it beats the rule and the venue's commonest type held out by scene, each by a sign test; on 23 September that is no venue yet (see the presets section) |
| Burst order, per venue (the tier order) | a logistic on the cull's measurements per finished shoot | the keepers of one finished shoot | 0.61 held out by burst on the gym; held by the keeper check, which it has not passed |

## Review of 2026-09-15: what labelling every frame found

The whole corpus, 548 cached decodes across three shoots, went through the
judge, and every frame it flagged hard was checked by eye and then against
the judge's own per-face numbers. Three systematic errors came out, each
with the frames that exposed it, and each is fixed and guarded by the
fixture.

- **Laughs vetoed as blinks.** The rule vetoed at blink 0.72 regardless of
  smile, and a laugh with the eyes squeezed shut reads blink 0.73 to 0.76
  with smile 0.98. Real blinks read 0.57 to 0.72 with smile 0.13 or under,
  so blink magnitude cannot separate the two and only the smile can. The
  unconditional branch is gone; a blink is now blink at least 0.5 with smile
  under 0.45. Frames: 03944, 04012, 04011, 04010, 04249.
- **A dog read as a soft human face and vetoed the frame.** CLIP's animal
  prompt scored an open-mouthed dog at 0.33, under the 0.45 gate, and a white
  dog held close at 0.08. YOLOX already boxes dogs and cats in stage 1 and
  was throwing the class away. It keeps it now, the boxes reach the judge,
  and a face inside a dog or cat box may not veto. Frame: 03827.
- **A detection nested inside a larger face vetoed it.** YuNet suppresses by
  IoU at 0.3; a box covering part of a face can sit at 0.32 and survive, and
  on 04354 her face read sharp at 4.0 while a box nested in it read soft. A
  box more than 80% inside a larger face is now dropped as a part of it.

One hypothesis was tested and killed. Ten frames were flagged blown that
looked fine at 300 px, and the judge reads exposure off the camera JPEG, so
the guess was that Sony's tone curve clips skin the RAW still holds. Measured
on the decode, 03960 reads 0.85 blown, 03924 0.38, 03978 0.49: the RAW is
clipped, the judge was right, and the eye at 300 px was wrong. The
decode-side number is now stored on each face as `blown_raw` but changes no
verdict.

Two gaps stay open and are deliberately not in the fixture. 04246 is a laugh
in purple light whose smile reads 0.29, under any threshold that still
catches real blinks. 03983 is a face looking down at someone, lids lowered
not shut, reading blink 0.56 with no smile; `eyeLookDown` reads 0.5 to 0.8
on every shut eye, laughs and blinks alike, so it cannot distinguish the
two. Both need a signal the landmarker does not give.

Two things about the corpus itself. The lounge shoot's 296 decodes and
camera previews survived the RAWs being cleared, and with `--previews` it is
a third bench row for survival and ranking (see the lounge section below);
what it cannot carry is a burst or setup-allocation number, because a decode
has no capture time. And the flaw learner cannot be trained from this corpus
at all: the photographer's-shadow prompt fires on 3 frames in 548, against
the twelve it needs.

Two efficiencies were found in the model path. CLIP ViT-L/14 was loaded
twice in every `--presets` run, once by the cull and once by the preset
writer; the writer now takes the cull's instance. YuNet runs in stage 1 at
960 px and again in stage 2 at three scales, which is by design: the first
finds subjects for focus, the second finds faces to judge.

### Review of 2026-09-16: an action shoot, and the first labels

*(Written on the afternoon of 2026-09-16 at 70 overrides, and kept as a record
of that afternoon. The review finished the next morning at 293 explicit
ratings and 294 frames kept. Measured against that, 246 of the 294 survive:
83.7%, not the 97% below. 27 of the 48 are "softest in burst", of which 17
also carry a hard face flag, so the burst floor's own cost is 10; the rest
are the face judge on people who are moving.)*

1,157 frames of indoor action, and the first shoot where the photographer's own
corrections exist in quantity: 70 manual overrides and 38 reasons. That is
ground truth the project did not have before, and it settled five questions.

**The veto is in good shape.** Of the photographer's 252 keepers, 97% survive the cull's own
veto and grouping, and where the photographer kept something from a group, the cull's top
frame was one the photographer kept 95% of the time. The photographer took 12 frames back: 4 vetoed
mid-word, 3 as the softest in a burst, 3 as duplicates, 2 soft. Mid-word
vetoed 90 frames on a shoot full of open mouths and the photographer
disagreed with 4 of them, so it stays.

**The ranking is at its ceiling and reweighting will not move it.** Against
the photographer's keepers, the shipping weights score P@k 0.526, the aesthetic head alone
scores 0.526, and a least-squares fit on this very shoot, which is an
optimistic in-sample bound rather than a shippable number, reaches 0.570.
Raising the `action` weight, which looked promising because frames the photographer called
bad expression score 0.19 against 0.56 for the photographer's keepers, made the ranking
worse at every value tried.

**Three of the eleven ranking features are constant on this shoot.**
`eyes_open` and `smile` are only filled in when the face judge is off, so with
it on they sit at their defaults for every frame; `flaw` was zero because no
probe existed. Standardising a constant column divides by roughly zero, so
`fit_taste` now holds such columns at weight 0 and says which they were.

**The flaw learner's own metric could not fail.** It reported leave-one-out
recall on the positives, which at 768 dimensions and a few dozen examples is
1.00 whatever the data says: the bias simply sits low enough that nearly
everything scores positive. The expression probe it produced reported
"leave-one-out recall 1.00" while scoring the photographer's keepers +0.36 and the frames the photographer
had rejected +0.39. Shipping it would have put a penalty on the ranking that
knows nothing. The learner now measures held-out AUC and precision across
five folds of both classes, refuses to write a probe under AUC 0.65, and
refits on shuffled labels twenty times, refusing anything that chance reaches
more than 5% of the time.

**Under that standard the expression probe is real.** 23 examples, held-out
AUC 0.74 against 0.50 for shuffled labels, and in a 40-run permutation test
its 0.82 was beaten by chance 0 times. It is the first learned component in
the project to survive its own validation. What it is not is useful yet: added
to the ranking at its shipping weight it moves P@k from 0.526 to 0.530, which
is noise, and the bench is unchanged on all three shoots. It ships because it
costs nothing and ranks rather than vetoes, not because it earned its place.

### Sameness thresholds, swept against a photographer's own keepers

Grouping near-identical frames is the single biggest lever on how much work a
shoot is, and the first action profile was set by measuring one burst, which
was not enough. Swept properly against the photographer's 252 keepers, counting how many of
them a setting would merge out of sight:

| strict | loose | frames to review | the photographer's keepers lost |
|---|---|---|---|
| 0.975 / 12 | 0.960 / 4 (normal) | 511 | 4 |
| 0.968 / 14 | 0.955 / 8 | 393 | 10 |
| 0.960 / 14 | 0.950 / 8 | 329 | 16 |
| 0.950 / 16 | 0.940 / 10 (first try) | 219 | **66** |

The first action profile cut the work by more than half and took a quarter of
the photographer's keepers with it. Similar poses read as identical, and the movement between
them went too, which is exactly what the photographer reported.

Keeping two frames from each group instead of one changes the picture
completely, because over-merging stops being fatal:

| strict | loose | per group | frames to review | the photographer's keepers lost |
|---|---|---|---|---|
| 0.960 / 14 | 0.950 / 8 | 1 | 329 | 16 |
| 0.960 / 14 | 0.950 / 8 | **2** | **431** | **4** |
| 0.950 / 16 | 0.940 / 10 | 2 | 324 | 37 |

The action profile is now 0.960/14 and 0.950/8, keeping two per group: 431
frames to review out of 598 that passed the veto, losing 4 of 252 keepers.
Normal shoots are untouched at 0.975/12 and 0.960/4, one per group.

**Superseded (22 September).** No setting of these thresholds hides a frame
any more. A group that showed one frame and hid the rest had hidden 65 of 773
keepers over the shoots this was measured on, and the sweep above is the
argument that no threshold could have made that safe: the lowest keeper cost
on the table is still four frames the photographer wanted, and the profile
that halves the work costs sixty-six. So the hiding went instead of the
threshold. Frames that look alike are stacked and every member stays on the
page; what `--style action` still sets is `--keep-per-group`, which is how
many of a stack are tiered with everything else. The pairs of numbers in
these tables are gone too: stacks are linked from how much this card's own
consecutive frames change, measured per shoot.

### Named datasets: what public data can and cannot check

Asked whether outside data could stand in for more of the photographer's
own, the answer splits. The ranking side cannot use it: what makes a frame
a pick is one person's taste on one night, and no public set carries that.
The veto side can, because a blink is a blink and a dog is a dog in
anyone's photos. Two datasets were run through the judge on 2026-09-15.

**Oxford-IIIT Pet** (Parkhi et al. 2012, CC BY-SA 4.0): 3,686 of the 11,086
photos carry a head box drawn by the authors, and 3,671 of those have an
image in the parquet mirror the loader reads. A head the detector
reads as a human face is the case that vetoed the dog shoot before the gate
existed, so this measures the gate at scale. On all 3,671
(`pipeline/eval_pets.py`, or `./pl evaluate --pets 3686`):

| | |
|---|---|
| a YOLOX cat/dog box covers the head | 92.6% (3,400) |
| YuNet reads the head as a human face | 43.6% (1,601 of 3,671) |
| of those, gated by the box | 92.9% (1,488) |
| gated by CLIP's animal prompt at 0.45 | 85.6% (1,370) |
| gated by either | 98.2% (1,572) |
| ungated and carrying a hard flag, so the frame would be vetoed | 0 of 1,601 |

Cats gate at 96.2%, dogs at 98.5%; 29 heads slip both witnesses, mostly
Sphynx cats, Samoyeds and Newfoundlands with CLIP animal under 0.45 and no
YOLOX box at all. Eight of the 29 are landmark-read, which is the only state
in which a fault can veto, and none of the eight carries one. It took one
once: `chihuahua_184`, a head 12 px wide on a 204 px image, vetoed for a
softness that was never measured, which is the fault named under Sharpness
above and is fixed there rather than at the gate. Twenty-four of these
images, half cats and half dogs, all read
as faces, now ship in `tests/fixtures/pets` under the dataset's licence
(`tests/fixtures/pets/ATTRIBUTION.md`), and `./pl check
tests/pets_truth.json` is the first face check that runs on any checkout.

The gate has a cost, measured on the faces fixture: of 95 human faces with
landmarks, 9 sit inside a YOLOX cat/dog box and 11 score animal at 0.45 or
over, nearly all people holding or leaning on the dog. For them a veto
becomes a question, which is still shown; none of the 94 verdicts
changes.

**CEW, Closed Eyes in the Wild** (Song et al. 2014): the closed-eye half of
the set, 578 faces at about 200 px, licensed for research only, so nothing
from it ships and the numbers are the only thing kept. With the current
rule, blink at least 0.5 and smile under 0.45:

| | |
|---|---|
| face found and landmarks read | 98.0% |
| shut eyes that read blink at least 0.5 | 87.7% |
| recall on non-smiling shut eyes (the rule's target) | 91.2% |
| shut eyes exempted as a laugh (smile at or over 0.45) | 23.0% |

The laugh exemption is doing what it was written to do; CEW has plenty of
grinning shut-eyed faces that the rule deliberately keeps. Lowering the
threshold buys recall on CEW, 95.1% at 0.45 and 96.8% at 0.40, but the
faces fixture's open eyes read 0.44 at the 90th percentile, and at 0.40
a real open-eyed frame (03815) becomes a false blink. The threshold stays
at 0.5. A cost the set exposed: on these tight, low-resolution crops YOLOX
puts a cat/dog box on 11% of the human faces, which is the same
question-not-veto downgrade as above, and is not seen at that rate on
full frames.

### Two avenues to a better ranking, both tested and closed

Asked to make the ranking dramatically better with bigger models or a
smarter setup, two things were tried against all three shoots, 548 frames
and 51 keepers, with the lounge added as a ranking row (next section). Both
lost to the head already in the pipeline.

**Off-the-shelf aesthetic and quality models.** Seven, through `pyiqa`,
scored on the camera previews. P@k per shoot, against the LAION head the
pipeline already uses:

| model | trained on | portraits | dog | lounge |
|---|---|---|---|---|
| LAION head (current) | 176k ratings, on CLIP ViT-L/14 | **0.25** | **0.36** | **0.36** |
| NIMA, Inception | AVA | 0.00 | 0.29 | 0.16 |
| NIMA, VGG16 | AVA | 0.00 | 0.21 | 0.12 |
| MUSIQ | AVA | 0.08 | 0.14 | 0.04 |
| TOPIQ IAA | AVA | 0.00 | 0.21 | 0.20 |
| TOPIQ IAA, ResNet-50 | AVA | 0.08 | 0.21 | 0.08 |
| CLIP-IQA+ | KonIQ | 0.00 | 0.29 | 0.00 |
| LIQE, mixed | several IQA sets | 0.00 | 0.36 | 0.00 |
| random | | 0.07 | 0.26 | 0.08 |

On the portraits every alternative sits at or below random. That is not a
failure to find the picks; it is ranking them last. AVA rewards the bright,
centred, conventional frame, and the picks were the dim wide ones. Nothing
beats the current head on any shoot. Q-Align, an 8B language-vision rater
and the one model of a different kind in the sweep, could not be run on this
machine: its 4-bit build needs `bitsandbytes`, which has no Mac support, and
the full build fails inside its own vision module on a `transformers`
incompatibility. It needs a CUDA machine or an isolated environment, and
since it is trained on the same human-rating datasets as the seven that
scored below random on the portraits, that is not worth building for it.

**A taste direction learned from the photographer's own picks.** Embed every
frame with CLIP ViT-L/14, SigLIP SO400M and DINOv2-L; learn from two shoots'
keepers and non-keepers; score the third, so nothing is scored by its own
labels. Three methods: the centroid difference, a regularised logistic
regression, and a 15-nearest-neighbour vote.

| encoder | method | portraits | dog | lounge | mean |
|---|---|---|---|---|---|
| CLIP ViT-L/14 | centroid | 0.00 | 0.50 | 0.00 | 0.17 |
| CLIP ViT-L/14 | logistic | 0.00 | 0.57 | 0.00 | 0.19 |
| CLIP ViT-L/14 | 15-NN | 0.08 | 0.36 | 0.04 | 0.16 |
| SigLIP SO400M | centroid | 0.08 | 0.36 | 0.00 | 0.15 |
| SigLIP SO400M | logistic | 0.08 | 0.21 | 0.00 | 0.10 |
| SigLIP SO400M | 15-NN | 0.08 | 0.29 | 0.00 | 0.12 |
| DINOv2-L | centroid | 0.08 | 0.36 | 0.00 | 0.15 |
| DINOv2-L | logistic | 0.00 | 0.36 | 0.00 | 0.12 |
| DINOv2-L | 15-NN | 0.08 | 0.36 | 0.00 | 0.15 |
| LAION head (control) | | 0.25 | 0.36 | 0.36 | **0.32** |
| random | | 0.06 | 0.25 | 0.08 | 0.13 |

Every cell on the portraits and the lounge is at or below random. The one
good cell, CLIP with logistic regression on the dog at 0.57, was trained on
the two people shoots and is reading "sharp, centred, well exposed", which
describes the dog picks and is not a taste. The earlier finding with CLIP
alone now holds for two stronger encoders: three shoots this different,
with 51 keepers between them, carry no transferable taste direction. It
would take several shoots of the same kind before this is worth trying
again, and the answer keys written as I choose are how those accumulate.

**What this leaves.** On this data the LAION head is the ceiling of the
ranking, P@k 0.25 to 0.36, and the combined score matches or beats it once
`face_score` is out. The number that can be impressive is survival, the
veto side, and that is what the three-shoot bench above reports.

### The lounge as a third shoot

The lounge's RAWs were cleared after its first cull, but its 296 decodes and
its camera previews survived, and every stage after decoding reads those.
`./pl cull <decoded> --previews <previews>` culls a shoot from them:
exposure and aesthetics off the camera JPEG, as they should be, blur off the
decode. Two things had to change for the result to mean anything. `--eval`
matched selects by full filename, and the selects were recorded against
`.ARW` while the decodes are `.jpg`, so it matches on the stem now. And a
decode carries no capture time, so every frame parsed to the same instant,
the whole shoot became one burst, and "softest in burst" rejected a third
of it including ten keepers; a frame with no timestamp now stands as its
own burst. `./pl bench` finds such a shoot by itself. The lounge cannot
carry a burst or setup-allocation number, only the ranking and the judge's
own survival.

One lounge keeper the judge rejects: 04277, a face 146 px wide in red
light, sharp 1.75 against the 1.9 floor and motion 1.43. At three times
magnification the eye band has no crisp edge anywhere. The photographer
kept it for the expression, which is what `--keep` is for; the judge is
right that it is soft, and it is in the fixture as a reject with that note.

## Known failures

- **A blurred dog looks like a sharp dog.** The eye-band metric needs a
  human face. Hand-made focus metrics, CLIP blur prompts and a probe
  trained on synthetic blur all failed to separate real blurred from real
  sharp dog frames. Fur, hands and backs get the pass-1 subject-box
  check only.
- **The shadow prompt is right often enough to rank on, not to veto.**
- **Cross-shoot taste does not transfer** through these features; the
  learner has been at chance.
- **Camera coverage.** Only Sony `.ARW` from one body has been through the
  full path. The decode and the exposure reads should be camera-neutral;
  the preview extraction assumes an embedded JPEG.
- **Light reading** confuses tungsten with golden hour indoors more than
  it should; the white-balance check catches most of it.
- **Bursts at 10 fps** were not in the test data. Stacking may draw one
  bracket over a whole fast exchange, which costs nothing now that a stack
  hides none of its members, but it does mean a single frame of that
  exchange stands for it on the shortlist. `--style action` raises that to
  two; whether two is enough at 10 fps has not been measured.
- **The animal gate has two witnesses and 29 heads get past both.** Over all
  3,671 Oxford-IIIT Pet images that carry a head box and an image, YuNet reads
  1,601 of those heads as a main human face and the gate catches 1,572. Eight
  of the 29 are landmark-read, which is the only state in which a fault can
  veto, and none of the eight carries one, so the invariant holds at this
  scale. It is one bad head away from not holding: nothing downstream asks a
  second time before a frame is binned, and the gate cannot move, because pet
  heads read animal at p5 = 0.187 and his own faces on the three non-dog
  shoots at p99 = 0.765 (n = 1,674 against 2,492). `tests/pets_truth.json` is
  24 heads and holds on all 24; the 29 are the finding that needed more than
  the fixture.
- **Blink recall is bounded and cannot be checked for false positives here.**
  On the 1,192 closed-eye CEW crops the rule flags 654 of the 1,175 whose
  landmarks it could read. 332 of the misses are the smile gate doing what it
  was written to do; 133 are the landmarker not seeing shut eyes at all. This
  machine has no open-eye half of CEW, so the only open-eye set the
  photographer vouches for is his own keepers, and on those the rule fires on
  exactly the two frames he kept with a blink in them.

## Things I might do

My own list. "Data" means labelled shoots, which only shooting produces;
"model" means a day or more of work; "code" is a self-contained change.

1. **Labelled drops → real flaw detectors.** *Data, then model.* The
   app records why each frame was dropped (my shadow, cut off,
   expression, blur, exposure, composition). Twelve of one reason trains
   a CLIP probe today; a few hundred across shoots would justify a small
   fine-tuned head, and for shadow specifically a segmentation approach
   (find the shadow region, check it touches the bottom edge and points
   at the camera). Status: probe trainer built and waiting for data.
2. **Sharpness for anything without a human face.** *Model.* An animal
   keypoint model (or a body keypoint model for people turned away) would
   let the eye-band metric run on a dog's eyes. The dog shoot is the
   check. This is the one real hole in the cull. Model size is not a
   constraint: anything up to tens of gigabytes is acceptable, fetched on
   first launch the way CLIP is, since a release asset is capped at 2 GB.
   Candidates: a SuperAnimal-class keypoint model for the eyes, and a
   stronger image encoder such as SigLIP 2 or DINOv2 in place of CLIP
   ViT-L/14 for the aesthetic head and the groupings, benched against the
   same three shoots before it replaces anything.
3. **Calibrate on fast action.** *Data.* Everything was tuned on
   portraits and a dog. Faster motion, profiles, harder light and
   open mouths and fast movement will move the motion-blur and mid-word rules. Needs a shoot
   with 10 fps bursts and selects.
4. **Pose-aware bursts.** *Model.* Group a burst by pose (keypoints)
   and keep the peak of the action score, instead of treating fifteen
   frames as one picture.
5. **A trained blur classifier.** *Data, then model.* Synthetic blur did
   not transfer; real labelled blur from drops would.
6. **Expression beyond blendshapes.** *Model.* Grimace and mid-word are
   the weakest reads. A small classifier on the face crop, trained on
   labelled drops, would replace the CLIP prompt plus landmark cue.
7. **Learn preset deltas.** *Data.* With `.dop` sidecars carrying the
   photographer's finished edits over the generated ones, the difference
   per light family is their taste, learnable from a handful of shoots
   because every frame is an example.
8. **Verify the preset numbers in PhotoLab.** *One hour by hand.* The
   white-balance estimate and the face-exposure target are the two most
   likely to be off by a constant.
9. **Per-frame locals in sidecars.** *Code.* A face control point written
   from the face box would remove the largest manual step; needs one
   sidecar with a control point to copy the format from.
10. **Other editors.** *Code.* Lightroom and RawTherapee writers exist
    (`editors.py`), less complete than DxO's; Capture One does not.
11. **Other cameras.** *Data.* One card from anything but a Sony, with
    selects, would show what breaks.
12. **A licensed fixture set.** *Data.* The pets half exists:
    `tests/fixtures/pets`, 24 CC BY-SA frames, and `./pl check
    tests/pets_truth.json` runs on any checkout. The human half does not.
    Twenty or thirty frames of people with a licence to redistribute,
    blinks and laughs and mid-word among them, would let the whole of
    `./pl check` run for everyone; a public face-attribute set with a
    permissive licence was looked for and not found.

## A specialist per situation: pose on an action shoot

The natural next idea is a model per scenario rather than per shoot: a pose
model for an action shoot, with eyes and expression judged the way an action shoot needs, and
the same three for a dog. The veto already works that way and it is the half
that works. Every frame is routed by what was found in it: on the action
shoot 1,090 frames took the face path, where the eye band is measured and
blink, mid-word and expression are judged, and 67 took the body path, where
none of that applies because there is no face to judge. On the dog shoot it is
40 and 14.

What is missing from that router is a pose model, so it was added and measured.
MediaPipe's pose landmarker, up to four people, against the 72 frames on the
action shoot the photographer ruled on by hand:

| pose measurement | frames the photographer kept | frames the photographer dropped | separation |
|---|---|---|---|
| people found | 0.92 | 1.02 | 0.25σ |
| furthest reach, in torso lengths | 0.78 | 0.79 | 0.02σ |
| upright rather than on the ground | 0.92 | 0.93 | 0.04σ |
| landmark visibility | 0.82 | 0.82 | 0.03σ |
| how far apart the subjects are | 0.00 | 0.03 | 0.30σ |

Nothing reaches 0.4σ. An extended arm, an athlete on the mat, two subjects
apart rather than close together: none of it distinguishes the frames the photographer wanted from
the frames the photographer threw out. It also costs 91 ms a frame, a fifth of the cull, and
the model finds about one person per frame where YuNet finds 2.1, so it is
under-detecting in a cluttered gym as well as not helping. The model was
removed again.

The honest caveat is 13 positives, which cannot detect a small effect. But the
effects measured are 0.02 to 0.30σ, and a signal worth 91 ms a frame would not
hide at that size.

**What this says about specialists generally.** The architecture is right, and
the pipeline already has it where it pays. Each further specialist needs its
own labelled set, and the one that could be tested cheaply showed nothing. The
one worth building is the animal path: there is no dog eye detector anywhere in
the stack, which is why sharpness on an animal is a documented failure, and
unlike taste it has a public dataset behind it. That is a capability that does
not exist rather than a fit that is poor, and it is the only place on this page
where more model is the answer.

## The animal specialist, tested before it was built

The dog is the one place these notes said more model would help, because there
is no dog eye detector in the stack and sharpness on an animal cannot be
judged. Before building one, the cheap question: on the dog shoot, does
sharpness anywhere on the dog predict what the photographer kept? YOLOX boxes the dog; the
Laplacian was measured on the whole box, its top third, the front and back
halves of that, and its centre, against the photographer's 14 exported frames.

| where sharpness was measured | the photographer's keepers | the rest | separation | P@14 ranked alone |
|---|---|---|---|---|
| whole animal box | 72 | 77 | −0.16σ | 0.31 |
| top third | 73 | 80 | −0.17σ | 0.23 |
| top front | 29 | 37 | −0.24σ | 0.23 |
| top back | 50 | 71 | −0.45σ | 0.15 |
| centre | 40 | 50 | −0.33σ | 0.23 |
| the shipping cull score | | | | **0.54** |

Every region points the same way: **the frames the photographer kept are less sharp than the
ones the photographer did not.** Ranking by sharpness on the dog, wherever it is measured,
does worse than chance (0.33). On this shoot the photographer chose moments, and a dog
mid-leap is not the sharpest frame of the burst. A head localiser was prepared
from 3,531 Oxford pet crops and not trained, because a sharpness veto built on
it would have removed keepers, and the veto it was meant to fix is not failing:
14 of 14 dog keepers survive already. The known failure is real as a
measurement gap and turns out not to matter for the pictures.

## A creative sweep: sixteen signals, ranked alone

Everything that might carry taste that the ranking does not use, each ranked
on its own against the photographer's exports, on the three shoots that have them:

| signal, ranked alone | portraits | lounge | dog | mean |
|---|---|---|---|---|
| **the shipping cull score** | 0.25 | 0.42 | 0.57 | **0.413** |
| the aesthetic head | 0.25 | 0.38 | 0.43 | 0.351 |
| first in its burst | 0.33 | 0.04 | 0.36 | 0.244 |
| last in its burst | 0.17 | 0.04 | 0.43 | 0.212 |
| bigger subject | 0.00 | 0.12 | 0.50 | 0.208 |
| uniqueness, few near neighbours in CLIP space | 0.00 | 0.17 | 0.43 | 0.198 |
| more faces | 0.00 | 0.17 | 0.36 | 0.175 |
| chance | 0.07 | 0.10 | 0.33 | 0.167 |
| novelty, unlike the shoot's centroid | 0.00 | 0.00 | 0.50 | 0.167 |
| action score | 0.00 | 0.12 | 0.36 | 0.161 |
| rule of thirds | 0.08 | 0.25 | 0.07 | 0.135 |
| brighter frame | 0.00 | 0.04 | 0.36 | 0.133 |
| smaller subject, wider frame | 0.00 | 0.00 | 0.36 | 0.119 |
| darker frame | 0.00 | 0.00 | 0.36 | 0.119 |
| against the aesthetic head | 0.08 | 0.04 | 0.21 | 0.113 |
| later in the shoot | 0.00 | 0.12 | 0.14 | 0.089 |
| commonness, many near neighbours | 0.00 | 0.04 | 0.14 | 0.062 |

Nothing beats the score that ships, and most of it is below chance. Novelty,
uniqueness, burst position, subject size in either direction, brightness in
either direction, the aesthetic head inverted on the theory that the photographer's portrait
picks were the dim wide ones: none of it. The one number above the shipping
score anywhere is "first in its burst" on the portraits at 0.33 against 0.25,
which is one frame out of twelve, and the same signal is 0.04 on the lounge.

**What all of this says together.** A learned ranker, a bigger model, an
ensemble, a router, a pose model, an animal sharpness model and sixteen
hand-picked signals were each measured against the frames the photographer actually chose,
and the hand-set weights beat every one of them. The ranking is at the limit
of what 51 decisions can support, the veto is where the labels are and it
works, and the two things that moved the numbers this week were not models at
all: grouping thresholds swept against the photographer's keepers, and scenes split where the
light changes. The next gain comes from the next shoot the photographer culls to the end,
not from the next model.

## Using every label there is, and a series of models

The fair objection to the table below is that it used 51 labels when more
exist. So: every label on the machine, which is 51 exported frames across three
shoots plus 109 decisions made by hand on a fourth, 620 labelled frames and 64
the photographer wanted. Leave one shoot out, four ways:

| model | portraits | lounge | dog | action | mean |
|---|---|---|---|---|---|
| **hand-set weights** | 0.25 | 0.40 | 0.57 | 0.08 | **0.325** |
| logistic, trained on the other three | 0.17 | 0.28 | 0.29 | 0.00 | 0.183 |
| gradient boosting, trained on the other three | 0.00 | 0.04 | 0.21 | 0.23 | 0.121 |

Tripling the labels does not change the answer.

**Would a series of models do better than one?** Three versions of that were
tried. Averaging the ranks of the cull score, the aesthetic head and a fitted
logistic gives 0.410 against 0.407 for the weights alone, a wash. Routing by
scene, meaning a model per kind of shoot, has a ceiling of 0.47 when each model
is fitted on the very shoot it is then scored on, which is cheating; on the
portraits a model that has seen the answer key still scores 0.17 against 0.25
for the weights, so the eight measurements simply do not contain what made
those twelve frames the picks. And the cull is already a series: focus, then
subject, then the face judge, then the aesthetic head, then grouping. The
stages with enough labels behind them, the vetoes, work on subjects that
hold still (100% of the photographer's keepers survive) and lose 16% of them on action;
the face fixture is at 94 of 94.

**How much more data would it take?** The learning curve says +0.023 for each
shoot added, from 0.211 on one shoot to 0.234 on two. The gap to the hand-set
weights is 0.173. At that rate it is seven or eight more fully labelled shoots
just to draw level, and learning curves flatten rather than continue straight,
so the true number is higher. That is the honest price of replacing the weights
with a model, and it is the reason an answer key is written for every
shoot as I choose: not because the data is useful now, but because it is the only thing
that ever makes a model possible.

## Would a bigger model do better? Measured, and no

The obvious suspicion about a tool built from hand-set weights and small
models is that a real model would beat it. Tested properly: fit on two shoots,
predict the third, three times over, against the frames actually exported.
That is the only honest split, because fitting and testing inside one shoot
predicts the cull's own output rather than a person's taste.

| model | portraits | lounge | dog | mean P@k |
|---|---|---|---|---|
| chance | 0.06 | 0.08 | 0.26 | 0.135 |
| the aesthetic head alone | 0.25 | 0.36 | 0.36 | 0.322 |
| **the shipping hand-set weights** | 0.25 | 0.40 | 0.57 | **0.407** |
| logistic on 10 measurements | 0.17 | 0.32 | 0.21 | 0.234 |
| gradient boosting on 10 measurements | 0.00 | 0.00 | 0.29 | 0.095 |
| random forest on 10 measurements | 0.00 | 0.04 | 0.29 | 0.109 |
| logistic on 768-dim CLIP | 0.00 | 0.00 | 0.50 | 0.167 |
| a 2-layer net on 768-dim CLIP | 0.00 | 0.00 | 0.43 | 0.143 |

Every learned model loses to weights set by hand, and the capable ones lose to
chance. Gradient boosting, random forest and both CLIP models return **zero**
on two of the three shoots: not merely failing to find the picks, but ranking
every one of them below the cut.

The reason is not the models. It is 51 positive examples spread over three
shoots with nothing in common: an evening in town, a red-lit lounge, a dog on
grass. A model with enough capacity to learn taste learns the training shoots'
content instead, and content does not transfer between them. The hand-set
weights carry prior knowledge that 51 examples cannot supply, which is exactly
why they win.

This matches everything else tried. Seven off-the-shelf aesthetic and quality
models all scored at or below the LAION head. Taste transfer with SigLIP-SO400M
and DINOv2-L embeddings landed at or below random. The one learned component
that survived validation, the expression probe, moves the ranking by 0.004.

**Where more capacity would genuinely help is where there is no measurement at
all, not where the fit is poor.** Sharpness on an animal has no model behind it
because there is no animal-eye detector in the stack; a real animal keypoint
model would create a signal that does not currently exist. The same is true of
finding the photographer's own shadow, which is a zero-shot prompt firing on 3
frames in 548 where a segmentation model could actually do the job. Those are
capability gaps. The ranking is not.

## Where the time actually goes

Measured on 24-megapixel decodes, before touching anything, because the plan
was to move the detectors to CoreML and that turned out to be the wrong thing
to optimise:

| stage | ms/frame | share |
|---|---|---|
| YOLOX subject at 960 px | 39 | 7% |
| YuNet faces, three scales, full resolution | 117 | 21% |
| the judge | 398 | 72% |

Inside that 398 ms, the models were almost none of it. MediaPipe's blendshapes
were 10 ms, SFace 13 ms, CLIP's own call 5 ms. The rest was plain array work,
and one line of it was `img.max(axis=2)` over the whole decode: **141 ms a
frame**, about a quarter of the entire cull, spent reducing 73 MB to fill one
diagnostic number that is read on a few hundred pixels per face and changes no
verdict. Doing the reduction inside the face box instead takes the judge from
398 ms to 264 and the whole cull from 554 ms a frame to 420, a 24% cut, with
`./pl check` still at 94 of 94, the pets fixture at 24 of 24, and every bench
row identical.

Two conclusions worth keeping. **CoreML would have been a waste**: the models
are 8 to 12% of the judge, so moving all three to the Neural Engine could not
have bought what one line of numpy did. And **CLIP is genuinely compute-bound
on the GPU**, at about 16 ms per 224 px face crop on an M4 Max; batching across
frames instead of the one or two faces in each improves that by 21%, not by an
order of magnitude, so it is not worth restructuring the judge for. The only
real lever left there is a smaller image encoder, which would change every
score in the project and mean re-validating all of it.

**The lever was the cores (17 September).** Everything above was measured
one frame at a time, and one frame at a time is how every stage ran: on a
machine with twelve performance cores the cull used one, the sidecar step
used one, and the GPU sat at zero because nothing in those stages is GPU
work (LibRaw and four small CPU nets). Each per-frame stage now runs a
frame per process (three quarters of the cores by default; the first pass,
the face pass, RAW decoding, the sidecar measuring, the learner's refit),
and the judge is restructured after all, not for CLIP but so that CPU work
can leave the process that holds the GPU: CLIP then sees a whole shoot's
face crops in batches of 96. Measured on the 1,157-frame action shoot,
with the machine shared with other jobs: the cull 25 min to 6 min 3 s,
identical on every column of `cull.csv`; sidecars for 154 keepers 0.52 s a
frame to 0.10 s; the learner's refit 25 min to 2 min 48 s (its worst part
was a walk of iCloud per exported frame, now one walk). Workers that cannot
start fall back to one frame at a time.

## The rule I hold myself to

`tests/bench.md` survive stays at 100% on the shoots that have an answer key,
`./pl check` stays at 94 of 94, the pets check at 24 of 24, and the frame that
motivated a new threshold is written down next to it. A change that raises
precision and loses a frame I wanted is a worse change.

## Reproducing the numbers

```bash
./pl setup                 # once: venv, models, CLIP
./pl check                 # needs ~/photos/fixtures/faces (not in the repo)
./pl check tests/pets_truth.json          # runs anywhere; the fixture is in the repo
.venv/bin/python pipeline/eval_pets.py    # the animal gate on 600 Oxford-IIIT Pet images (see the docstring for the data)
./pl bench                 # needs a shoot with a decisions/selects.json
./pl evaluate              # every dataset with an answer key, each number with its n; writes tests/eval.md
./pl selftest              # runs anywhere with six RAWs
```

`./pl evaluate` is the wider instrument and the one a threshold argument
should be settled with. It measures recall per shoot, which rule threw each
frame out (rules that fired on nothing get a row saying so), the ranking
within a burst as well as pooled, blink recall against CEW's closed-eye crops
and the animal gate against the annotated Oxford-IIIT Pet heads, holds out by
shoot and never by frame, and says beside every number what its dataset cannot
answer. It writes nothing inside `~/photos`; its measurements are cached under
`~/.cache/first-edit/evaluate` (or `~/.cache/photo-pipeline/evaluate`, where
that one is already there), keyed by the frame and by the source of
the code that measures it, so changing a rule re-runs the verdicts in seconds
and changing a measurement re-reads every frame.

## The starting edit, measured again (17 September)

The first version of the starting edit was a regression from a frame's
measurements to the slider values in 198 hand-edited sidecars from one
evening. Applied to a gym it put that evening's recipe on every
frame and made everyone red. Four read-only investigations on the frames,
the sidecars, the exports and PhotoLab's own database replaced it. The
numbers, and what they changed.

**The recipe was DxO's factory preset.** The gym sidecars' Base differed
from `1 - DxO Style - Natural` in 12 of 204 keys, none a colour push; every
"learned constant" (V3Custom, MidTones 18, Highlights −14.56, Vibrancy 5)
was Natural's own value read back through the sidecars. The red was DxO
Natural's rendering of Sony files against Sony's JPEG engine, plus ClearView
(documented to raise saturation) and DxO's reading of as-shot white balance.
The photographer's own next-day edit of the gym confirmed it: one look
pasted to 291 frames, camera-body rendering (`ColorRenderingType Original`),
`ChannelMixerRed +4`, and every per-frame tonal value the pipeline had
written reset (153 auto-recovery frames back to Manual, 27 biases to 0, 24
highlight pulls to −14.56).

**Skin.** On the two other finished shoots (lounge, dog: 41 exports with
their camera JPEGs) the finished skin hue stays within ±5° of the camera
JPEG (+4.5° yellower under red light, −1.7° in daylight) and chroma goes
*up* by 6–9 C* on both; faces brighten by 4–7 L*. The camera JPEG is a valid
hue reference and a chroma floor. The published preferred skin centre is
hue ≈ 46–49° (Zeng & Luo, CIC18 2010 / CR&A 2013; Peng et al. CIC 2020:
C* 25, h 46° across ethnic groups; tolerance narrow in hue, wide in
chroma). The gym camera JPEG sits at 42.5°, inside that band; the earlier
36.1° "skin target" was the red-lit lounge. Nothing corrects skin.

**White balance.** A neutral solver on the RAW (Sony's own per-preset
multiplier sets give kelvin/tint on the camera's scale) against the one
DxO eyedropper reading on a gym neutral: solver 4320 K vs DxO 4742 K, tint
sign agreeing, 164 DxO tint units per ln-unit — one calibration point, so
DxO's scale is known to ±300 K and no kelvin is written. The gym's neutrals
disagree with AsShot by a median 11 mired: below what that scale can
place; AsShot stands, as the photographer left it on 291 of 291 frames. The photographer's
Fluo on portraits is per scene (0 of 29 scenes mixed): the three warmest
scenes, where AWB had neutralised tungsten street light, so Fluo puts
warmth *back* — a preference, learned as one. Held out by scene over 492
decisions from two venues: AUC 0.97, accuracy 0.91 against 0.81 for
always-AsShot. Skin as a WB target is refuted: dark faces give garbage
hue, and a 70° face cannot reach 36° without a magenta cast on everything.

**Exposure.** All 47 Manual biases on portraits are −1.9617, one paste, and
the modes were 29 scene-level decisions; the ridge that seemed to fit them
(MAE 0.18 vs 0.61) was fitting a constant. Replaced by measurement: each
keeper's RAW in linear terms (rawpy, camera WB, no auto-brighten, gamma
1,1; the ILCE-6500 saturates at 16372 of a nominal 16383, found as a spike),
the largest face's luminance, and the share of photosites at saturation.
DxO's rendering lifts a face 1.22–1.47 EV beyond the exposure slider under
the usual Smart Lighting (16 exports with RAW and sidecar; `RENDER_GAIN`
1.3). The camera JPEG's L* is a fixed function of raw luminance in the face
range (±0.1 EV); the RAW adds true clipping. Physical gates: under 0.2%
of photosites saturated, a highlight-recovery mode has nothing to act on
(the photographer's Manual scenes: 0.05%; auto scenes 0.24–0.78%), so the frame is
corrected by hand; among clipped frames a face or subject below linear
0.042 got Medium rather than Strong from the photographer (0.87 held out by scene,
AUC 0.93). Reference: ISO 12232's 18% grey at L* 50; preferred face
reproduction L* 58–67 by skin tone. The photographer's venues sit below that by a
consistent offset (gym/daylight ≈ 50, flash evening 38, lounge 24).

**What the photographer accepts is a band, not a target.** With the venue median as a
target the pipeline wanted −1.6 to +1.0 EV and 12 masks on 21 gym frames
the photographer had left at 0. The venue now stores the band of finished face lightness
the photographer's own exposures imply (`Lstar(face_Y × 2^(bias + gain))`, p5–p95: gym
21–69, gals 32–64); a face inside it is left alone, one outside is brought
to the edge, and a mask is placed only for a face still outside after the
global correction. On the same 21 frames: 19 at 0 as the photographer left them, two
nudged −0.08 and −0.22, no masks.

**Venues.** kelvin (gym 4087 K vs gals 3133 K, AUC 0.96), the cast on the
neutrals (`cast_a` −1.25 vs +1.72, 0.92), frame and face brightness and
the chroma of the light tell the venues apart; face hue does not (42.5°
vs 42.7°, AUC 0.54: the camera puts skin in the same place everywhere).
A finished venue is its centre and spread in those seven standardised
measurements, the preset its sidecars started from, what the photographer set the same
way on most of its frames, the accepted band, and the photographer's exposure type where
near-unanimous (Manual on 100% of the gym). A new shoot inherits a venue
only inside its spread; the selftest's six portrait frames, copied to a
temp folder, find the portrait venue by measurement alone. Only finished
edits teach: a frame exported, or a shoot marked Done. Seven sidecars the photographer
had opened and tried things on had been the gym's whole "look" until then.

**A sidecar is patched, never rebuilt.** A `.dop` that already exists is
edited in place: only the Base, the applied-preset label, the rating, the
keywords, the camera's orientation and the two dates this write records are
replaced, and every other byte passes through (`presets.patch_dop`). `--force`
used to rebuild the file from a template frozen at whatever PhotoLab wrote on
the day that template was copied, which threw away everything a later PhotoLab
had put in it: the `OutputItems` block recording where the frame had been
exported to, IPTC,
`ProcessingStatus`, and the two fields that are facts about the installation
rather than about the edit. PhotoLab 10 shipped three weeks before this was
written with 8 and 9 still in use, so which keys a sidecar may carry is not
something this code gets to know in advance. `--mine-too` is now the one
thing that throws a file away and starts from the template.

`Sidecar.Software` and `Source.CafID` are discovered rather than written from
a constant (`presets.dop_stamp`). Software is the `CFBundleVersion` of the
newest `DXOPhotoLab*.app` in `/Applications` — newest by the version each
bundle declares, never by its name, because a reverse sort of the names puts
`DXOPhotoLab9.app` above `DXOPhotoLab10.app` and would stamp every sidecar
with the oldest PhotoLab on the disk. Checked against the 98 sidecars
PhotoLab itself wrote in one folder, every one says `DxO PhotoLab 10.0.2.28`
beside an `Info.plist` `CFBundleVersion` of 10.0.2.28; that is one machine's
reading and it is the only one that matters, because the machine writing the
sidecar is the machine that will open it. CafID cannot come from the app: it
names a record in PhotoLab's own catalogue, so it is read out of the sidecars
PhotoLab has already written beside these frames, telling them apart by a
non-empty `Overrides` block. The vote is over every sidecar in the three
folders it reads — `raw/`, `cull/picks/`, `edit/` — and never a head of them:
on the action shoot that is 730 sidecars, 509 of them PhotoLab's own, and
those split `C52941d` 299 to `C45224d` 210, two catalogues on one shoot and
close enough that an alphabetical sample would have decided it. A folder where
every sidecar is PhotoLab's own reads `C45224d`. On the dog shoot not one
sidecar has been opened by PhotoLab, so nothing there is a reading of his
catalogue at all: the vote falls to what this tool wrote itself, which the run
says in `presets.md`. Neither id is a value this code could guess, and each
fallback to a shipped default is said once per run.

**Masks.** PhotoLab's AI masks are portable: a `SemanticMask` with a
`PositivePoint` prompt in normalized coordinates of the displayed frame
(the photographer's three masks on the lounge frame sit on the faces the pipeline's
detector finds there: prompt (0.504, 0.461) against a face centre at
(0.511, 0.470)), a `ReferenceColorPoint`, and `Corrections`. The pipeline
writes them in PhotoLab's own table layout (keys alphabetical, an
anonymous table's brace and entries at one depth). The coordinates are the
SENSOR's unrotated frame, not the displayed one: on a portrait-orientation
frame a prompt written in display coordinates landed, precisely, on a
ceiling tile (the photographer's finding on TSC04802, 17 September), and the
same numbers read in the sensor's frame are that tile. Faces are found on
the displayed preview and mapped through the RAW's flip code
(`presets.to_sensor`); the crop writer maps the same way. `CropRect` is
`{x, y, w, h}` — the crop writer had emitted `{x0, y0, x1, y1}`.

**Whose face.** The exposure is set on the subject's face and a mask goes
on the subject's face, so the question "whose face is this" is asked on
every frame, and three answers of the photographer's fixed it in one
evening: a mask on a spectator over the subject's shoulder (TSC04802), a
mask on a hand held up in front of the man behind (TSC05263), the wrong
face in a frame of two (TSC04865). The first rule tried — each face
belongs to the smallest person box containing it, and only people at
least half the size of the biggest box are the subject — fixed all three
and lost the only face on 26 of the same shoot's 154 exported keepers.
In a two-person action frame the biggest person is very often the one with
his back to the camera: no face, and the man facing the lens is 0.40–0.48
of him. The measure that holds (`presets.subject_faces`, `heads`) matches
each face to the person box it sits in *as a head* — on 130 faces the
landmarker read on this shoot a head is 0.13–0.39 of its box's width,
centred in the top 0.09–0.27 of its height, within 0.3 of a box width from
the centre line — one head per box, best fit first; the reference is then
the biggest person *with a head*, and people at least half that size are
the subject. A face inside someone's box that sits nowhere like a head is
not theirs (the raised hand, the spectator); a face no box contains is kept,
the person detector having missed a head cropped at the frame edge; when
no face sits in any box like a head (two people on the ground) the boxes
say nothing and every main face counts. Faces the detector is sure of
(YuNet ≥ 0.70) are settled first, the doubtful ones only when no sure face
qualified: the raised hand read 0.66 and the hood on TSC04865 0.64, and the
twelve keepers whose only face reads under 0.70 are all real faces. The
gate on whether the landmarker could *read* the face is gone: nine
keepers with a plain face between two raised hands were "no face" under it, and
readability says nothing about whether skin is there to measure. Result on
the 154 exported keepers: 151 have a subject face (the three left are wide
shots with faces under 40 px or none), against 128 before; masks 30 → 21,
the nine gone being spectators and non-faces.

**Yellow skin: which tool, decided by measurement (18 September).** The
photographer reported that "the only weird ones are the ones with the yellow
light" on the action venue, and read it as a light. Four measurements
answered the question of which correction is right, over all 1,157 frames:

1. *Not the room.* The camera's as-shot temperature is one distribution
   (p10 3800 K, p50 4200, p90 4330), and the neutrals sit at b\* +3.9 on
   average, +9.9 at worst; the frames above +7 are a hoodie filling the
   frame. Nothing is bimodal — Sarle's coefficient 0.21 to 0.46 across
   every colour metric, against the 0.555 threshold for two modes.
2. *Not a light on them.* On the 14 yellowest frames and 8 typical ones,
   the near-neutral pixels on a person's own clothing and gear sit +1.6 b\*
   from the room's on average (median +1.2, sd 4.2, negative in half of
   them) while the same person's face reaches +32.6. A light falling on
   someone carries their clothing with it; this does not.
3. *Not the camera's rendering.* The same faces measured on the RAW,
   demosaiced with the camera's white balance and no tone curve, are if
   anything yellower than the camera JPEG: hue shift JPEG minus RAW, median
   −3.2 degrees, and 14 of 22 RAW faces above the published skin range
   against 13 on the JPEG. DxO renders from the RAW, so the cast is real.
4. *It follows people.* One person reads yellow on 26% of his 117 frames
   and more so when he is brighter (b\* +25.8 at L\* 53 against +16.3 at
   L\* 46), another on 6 of 6, a third on 0 of 137; eleven of the twelve
   yellowest faces are the same man, and their bursts have the least yellow
   backgrounds of the shoot. The cast direction on faces is 114 degrees,
   green-yellow, the signature of overhead fluorescent panels landing on
   upward-facing surfaces while a vertical torso sees mostly bounce.

Together these say the camera's auto white balance has already neutralised
the room's average, and what stands out is what is lit unlike that average.
A global preset or temperature would move a background that is correct as
far as it moves the face. So the correction is colour-selective and local to
the cast: a cut on the Yellow HSL slice, which is also the only tool the
photographer has ever used on it there (Yellow saturation −19.03 and −46.4,
on two frames; white balance changed on 0 of 291).

The amount is bounded on all sides by their own work: the edge is the 90th
percentile of the b\* of their delivered faces on that venue (24.0 from 111
exports), the floor is the 10th percentile of those faces' chroma (14.3), the
cap is their largest finished cut (−19.03), and the slice bounds are the ones
they set on the frame that cap comes from (12.0–78.1, against DxO's default
41–63; under the default bounds the affected faces sit at a slice weight near
zero and the cut would do nothing). The gain that turns "b\* over the edge"
into a saturation number is measured from their own exports — face b\* on the
export against the preview, with the venue's render offset of +4.0 b\*
removed — and today rests on one pair, so it is known to about a factor of
two and the report says so. With no finished cut anywhere, nothing is
written at all.

Where their own HSL table is already in a sidecar's Overrides it shadows the
Base's, so no value is written there and the frame's note gives the number it
would have taken. On the action venue that is every one of the 11 keepers
past the edge, because a paste put a table on 153 of 154.

**The reader that saw none of it.** The slice reader expected
`Hue, Saturation, Luminance, Uniformity, Label`; PhotoLab writes a slice's
fields alphabetically, so the pattern matched none of the 438 sidecars that
carry a moved slice. Every HSL edit the photographer had ever made was
invisible to the learner. Slices are parsed by name in any order now, and a
value under half a point is not counted as a decision: a paste carries the
source frame's whole table, which is how a Red saturation of 0.334 reached
583 sidecars without a judgement.

Sources: Zeng & Luo, *Colour and Tolerance of Preferred Skin Colours*,
CIC18 (2010) and Color Res. Appl. (2013); Peng et al., CIC 2020; Wang et
al., CIC 2015 (measured skin hue 53–60° by group); DxO documentation on
colour rendering (camera body "will match the manufacturer's") and
ClearView; ISO 12232; the DxO forum threads on as-shot white balance and
on PL7+ renderings. Scripts and per-frame data live outside the repo.

## The cull, measured again (17 September): faults, notes and tiers

After a second pass through the action shoot in PhotoLab the answer key
there became the 154 frames that were exported. PhotoLab's pick and reject
flags are written nowhere on disk (no sidecar key, no database column), so
for a finished shoot the exports are the key: a frame taken into `edit/`
and not exported was thrown out. Against that key the cull as it stood had
vetoed 33 of the 154 keepers and kept 124 of the 137 frames that were
thrown out. Rescued vetoes were exported at 71%, the cull's own picks at
49%: the vetoes were hitting keepers preferentially.

**Which vetoes transfer.** Each rule's value was set on three shoots and
applied to the fourth, for all four. Three transfer at no keeper cost:
blink ≥ 0.5 with smile < 0.45 (folds give 0.5, 0.5, 0.5, 0.45), skin at
the clip point ≥ 0.35, nothing above L* 35. Three do not: the absolute
face floor (1.9 from portraits costs 26 action keepers; no keeper in 1,705
frames is under 1.2, so 1.2 is the one absolute that stands), mid-word (0.5
from portraits loses 43 of 152 readable-face action keepers, 0.7 from the
action shoot fires on nothing), and "softest in burst" (a quota that grows
with the burst's length: 27 keepers). Of 45 vetoed action keepers the
measurement was right on 42 and the decision wrong. So a **fault** vetoes
(blink with no smile, blown, dark, under 1.2, or under half the same
person's sharpest frame in the burst) and everything else is a **note**
that orders the review. A fault counts on the co-subjects (a readable face
at least half the area of the largest) and is a note on a face behind
them; a soft face in a frame whose subject box is at least half as sharp
as the burst's sharpest is a choice ("focus elsewhere"), not a miss. "Soft
duplicate" sorts a frame last in its same-picture group instead of
rejecting it.

| veto set, keepers lost / drops removed | portraits | lounge | dog | action |
|---|---|---|---|---|
| before (soft 1.9, blink, mid-word, dark, blown, motion) | 0 / 20 | 1 / 49 | 0 / 3 | 33 / 382 |
| now (the four faults, on the co-subjects) | 0 / 18 | 0 / 19 | 0 / 2 | 5 / 65 |

The fixture check was re-settled for it: 17 of 94 verdicts moved (soft
between 1.2 and the floor, mid-word, the old motion-blur label), each with
its reason in the entry; one of them is a lounge frame that had been a
keeper all along.

**What cannot be ranked.** Among the 291 frames reviewed twice, nothing
measured separates the 154 kept from the 137 thrown out: face score AUC
0.61, gaze (inverted) 0.60, the quality score 0.49, the aesthetic head
0.50, the frame-to-frame motion peak under 0.56; the cull's own top 154 of
those 291 holds 82 keepers, which is chance. The thrown-out frames are not
duplicates of the kept ones either: they sit a median 20 phash bits from
the nearest keeper in their burst, further than keepers sit from each
other (14); 12 of 137 share a same-picture group with a keeper. A logistic
on 17 per-frame measurements learned on that shoot's own verdicts reads
0.65 held out by burst; across shoots the same model is at chance
(0.45-0.56), with weights that flip sign between folds. CLIP prompts for
an occluded face, a no-reference IQA model and eye-aspect-ratio blink
detection were each tried and each did worse than what ships.

**Tiers.** A burst is one moment and about two frames of it are kept (154
over 85 bursts). So the survivors are tiered a burst at a time: the two
best clean frames are clear wins, the next two and any noted frame that
ranked among the best are maybes, the rest are probably not and folded;
duplicates and faults are hidden. The order comes from the venue's ranker
where the shoot measures like a finished one (`taste.learn_ranker`, kept
only above 0.60 held out by burst), else from the score. A note does not
gate a tier: on an action shoot nearly every frame carries one ("soft?"
against a portrait's floor, a mouth open, a dim face), and gating on them
left 2 clear wins in 1,157 frames. Run on the action shoot, ordered by the
score alone: 173 clear wins hold 42 of the 154 keepers (24%), 141 maybes
hold 27 (19%), 524 probably not hold 62 (12%), 258 duplicates hide 21
(each the same picture as a shown frame) and 61 faults hide 2; by chance a
survivor is a keeper 18% of the time. Ordered by the ranker learned from
that same shoot the clear wins hold 52 (30%) and the probably-nots 52,
in-sample; held out by burst the ranker reads 0.65. The bench under these rules: portraits 12 of 12, lounge 25 of
25, dog 14 of 14, action 152 of 154 (two blinks), and the venue's ranker
puts 36 of the 154 in its top 154 against 16 by chance. That is the
ceiling of a ranking there, and the docs say so rather than promise a
list of 200 with the keepers in it.

**Since the clustering became order-independent (19 September).** Recall has
not moved — `./pl evaluate` reads 12/12, 25/25, 14/14 and 152/154 today, the
same two blinks — but the action shoot's rejections are 64 of 1,157 where
`tests/eval.md` records 70. That file was written on 18 September, before the
seeding order above landed, and its per-rule table still shows "soft for this
person" firing on 10 action frames. Re-run `./pl evaluate` before quoting
section 2 of it.

**Since stacks replaced hiding (22 September).** The tier paragraph above is
the record of what was measured on 17 September, and two of its sentences are
no longer how the cull behaves. "Duplicates and faults are hidden" is now
faults only: the 258 frames it counts as hidden, and the 21 keepers among
them, stay on the page set aside under the top of their stack. And "the two
best clean frames are clear wins" is the best twelfth of the burst and never
fewer than two (`common.deal_tiers`), which also deals the tiers across the
whole shoot where most bursts hold a single frame. The per-tier counts here
have not been measured again under those rules; `./pl bench` and `./pl
evaluate` are what would do it, and the ranking numbers quoted in README.md
come from cull.py's own measurement of the same shoot.
