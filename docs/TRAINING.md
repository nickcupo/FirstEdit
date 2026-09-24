# Retraining the parts that learn

Notes to myself, mostly. Everything here runs on my own shoots. There is no
training run to schedule and no GPU to rent: the models that can learn are
small, they fit in seconds, and the whole cost is culling normally and
pressing one button at the end.

Three things learn, and they all live in one folder: why you drop frames
(`flaws.py`), which frames of a burst you keep (the tier order), and the
starting edit (`taste.py`). `learned.py` owns that folder — `PIPELINE_LEARNED`
if it is set, else `$PIPELINE_SUPPORT/learned`, else the app's Application
Support folder — so the app and a checkout read and write the same models,
and never the repository or the signed bundle. None of the three can throw a
frame out; each of them only reorders what the cull shows.

## The one rule

Nothing is trusted because it trained. A change to any model has to keep
`./pl bench` at 100% survive on every shoot that has an answer key, and
`./pl check` at 94 of 94 with the pets fixture at 24 of 24. A model that
raises precision and loses a frame you wanted is a worse model.

The machine holds itself to that rule now, and it is called the **keeper
check**. Anything the three learners produce is a candidate, never the model
in use. Before it goes live it is scored against every keeper of every shoot
that carries your verdicts — from each shoot's `cull.csv` and the vectors
the cull cached, in seconds, without re-culling anything — through the live
model and through the candidate, and the tiers are dealt both ways by the
same `common.deal_tiers` the cull uses. It goes live only if no keeper of
yours drops out of sight on any shoot and every keeper was found. Anything
else is held, with the frames it would have moved listed one by one.

A candidate's own held-out score is not that check and is no substitute for
it: a drop-reason model retrained on 44 reasons scored AUC 0.90, and 0.97
held out, and would still have hidden 15 of 773 keepers and moved 35 down a
level. `./pl learned --check` runs the check frame by frame and changes
nothing; `./pl learned` says, per learner and in three separate lines, what
is in use and what it was learned from, what is held back beside it and what
it would do, and what it is short of in things you could do ("6 more frames
dropped for blur"). A version held back for what it would do to your keepers
and a learner that has not been given enough to learn are opposite
situations with opposite remedies, and the page no longer says them in the
same words.

```bash
./pl bench                          # the cull against every shoot you have chosen from
./pl check                          # the face judge against frames settled by eye
./pl check tests/pets_truth.json    # animal heads that must not veto
./pl evaluate                       # all of the above and the public sets, each number with its n
```

`./pl evaluate` is the one to run when a threshold is in question. It writes
[../tests/eval.md](../tests/eval.md), recomputes from the pixels rather than
reading a `cull.csv` (a `cull.csv` is a record of whatever rules were in force
the day it was written), holds out by shoot and never by frame, and prints a
row for every rule including the ones that fired on nothing. It writes nothing
inside a shoot.

## Where the training data comes from

You make it by working. Nothing here asks for anything you would not do
anyway.

| What you do | What it becomes | Where it lands |
|---|---|---|
| Cull a shoot and choose keepers | which frames you wanted | `decisions/organize.json` |
| Choose keepers; the answer key writes itself | the shoot's answer key | `decisions/selects.json` |
| Press **Finish This Shoot** after exporting | what the shoot teaches: the frames you exported | `decisions/exported.json` |
| Click a reason chip under a dropped frame | why that frame failed | `decisions/labels.json` |
| Export the keepers from PhotoLab | a stronger answer key than stars | `export/*.jpg` |

**The answer key writes itself.** Every keep and drop in the light table rewrites
`decisions/selects.json` from your stars and anything you have exported, and
that file is what every future change to the cull is measured against. (It
lived in `cull/` until `./pl migrate` moved it; an existing file is read
wherever it is, so both layouts work, and every write of one goes through a
temp file and a rename so a kill part-way through cannot leave half an answer
key under its own name.) A write that would throw away more than half of an
existing key is refused, and the app puts both numbers to you before it
narrows one. Keep the RAWs until you have looked at the key once.

**Only what you export teaches.** The answer key is every keeper, and every
check is measured against all of them. What the learners take as your taste
is narrower: the frames you exported, because the cull goes on in PhotoLab
and a keeper you passed over there is where you started editing, not what
you chose. **Finish This Shoot** on the last step writes down the frames
exported so far (`decisions/exported.json`, a record that only grows, so a
shoot whose export folder moves later still teaches what it taught), and a
finished shoot also teaches the exports the learning store recorded when it
measured them. An export counts for a frame only between the frame being
taken and the camera next using that number. A shoot with none of these
teaches nothing, and the Finish page says so.

The reason chips matter more than they look. The cull can tell a blurred
frame from a sharp one on its own; it cannot tell that you drop frames where
your own shadow falls across the mat, or that you hate a particular crop.
Those are the labels no public dataset contains.

## 1. The tier order — learned per venue, and retired as one set of weights

The ranking is a weighted sum of eleven measurements: aesthetic, sharpness,
eyes open, smile, subject area, rule of thirds, action, face score, shadow,
learned flaw, gaze. Those weights are `quality.DEFAULT_WEIGHTS`, a considered
guess, and they are no longer fitted to anything.

`./pl cull --learn` used to fit them by least squares to one shoot's
`selects.json` and write `models/taste.json`, which every later cull of every
kind then picked up. It is retired and the flag now refuses with a sentence
saying why: taste measured on one shoot did not carry to the next. `--taste`,
which loaded such a file, is retired with it. `--eval <selects.json>` is
still there and still changes nothing — it reports how this cull agrees with
your picks, and names every frame of yours it would not have shown you.

What replaced it is narrower on purpose. `./pl learned run` fits a ranker per
**venue**, from the frames you kept on a finished shoot that measures like
the one in hand, held out by burst, and uses it only where it beats chance
(above 0.60 held out). It reorders clear wins and maybes inside a burst and
nothing else, and like every learner here it has to pass the keeper check
first.

**What it ranks on, and where its venues come from.** The ranker reads the
cull's picture score, and that score carries the drop-reason score of
whatever model the cull that wrote `cull.csv` happened to have. Three shoots
(2026-09-16, 2026-09-19, 2026-09-21) were culled by the installed app, whose
bundle carried no drop-reason model, so their `flaw` column is exactly zero
on every frame; the three before were culled from a checkout that read
`models/flaws.json`. The keeper check never used that column — it replays
the score under the drop-reason model in use now, from the picture vectors
kept for every shoot — but the ranker was trained on the file's column,
so what it learned meant different things on different shoots and would
have been served a different number the day a drop-reason model went live.
It now trains on the same replayed score the check and the next cull use
(`learned._replayed_quality`). Nothing needs re-culling for this. On his
library today it changes no number, because nothing is in use for drop
reasons and the one shoot its ranker was learned from was a zero-column
shoot anyway: the dead column was a hazard, not the reason for the hold.
The check also no longer stands in the file's column for a missing picture
vector when a drop-reason model is in use: that shoot is named instead, with
the command that measures its vectors off the previews it already has
(`./pl learned vectors <shoot>`) — not a re-cull, which would be an evening's
work and not the fix.

Its venues come from the newest starting edit (the one held beside the one
in use, if there is one), not only the one in use. The tier order takes the
geometry of the light from it and nothing else; while the newer starting
edit was held for its white balance, 2026-09-19 and 2026-09-21 could not
teach the tier order at all, and learning again could not change that.

The honest state on 23 September: rankers for 2026-09-16 (0.61 held out by
burst) and 2026-09-19 (0.66); 2026-09-21 at 0.57 is no better than chance
and is not kept; the-gals has 12 keepers, 18 short. The check applies every
venue's ranker to every other shoot and keeps the worst, and it would show
81 of his keepers later in their burst and 35 earlier, none hidden — held,
by the rule that a shoot must lift at least as many as it pushes down. A
ranker learned on one venue moves keepers on others more than it helps them;
that is the measurement, not a defect in the check.

**What made the old way fail.** Taste transfer across shoots was measured
and failed: fitting on two shoots and testing on the third landed at or
below random, with CLIP ViT-L/14, SigLIP-SO400M and DINOv2-L, and with
centroid, logistic and 15-nearest-neighbour heads. Your picks on a lounge
night do not predict your picks on a dog. That is the whole argument for
learning per venue rather than once for everything, and for leaving
`face_score` at 0.00: it cost precision on every shoot it was measured on.

## 2. Flaw probes — real, and waiting on you

One small logistic probe per reason, trained on CLIP embeddings: the frames
you dropped for that reason against the keepers of the same shoots. The cull
then scores every frame with the probes and uses the strongest as a penalty.
It never vetoes, because a probe trained on a few dozen frames has no
business throwing a picture away.

```bash
./pl learn              # every shoot under ~/photos/shoots that has labels
./pl learn --min 20     # refuse to train a reason with fewer than 20 examples
./pl learn --dry-run    # what it would learn from, writing nothing
```

What that writes is a candidate in the learned folder, not the model in use.
It is used only once the keeper check has scored it against every photo you
kept on every shoot and found none of them hidden. `models/flaws.json` is
where older builds wrote; nothing reads it any more, and `learned.py` takes
an existing one in once, as a candidate, so the model that was in use is
checked like any other rather than vanishing.

"Just no" is a reason you can give a frame and is never trained into a
detector: the cull throws out only what it can measure.

**How a probe is judged now.** Held-out AUC and precision across five folds
of both classes, then twenty refits on shuffled labels. A probe is written
only if it clears AUC 0.65 and chance reaches its number less than 5% of the
time. The metric before this was recall on held-out positives, which at 768
dimensions cannot fail: a probe that separated nothing reported 1.00. If you
see a perfect score, distrust it.

**Twelve examples of one reason, on two finished shoots, is the floor.** A
probe is held out by shoot, so a reason whose every example is on one shoot
has nothing to be checked on; and a reason only teaches from a frame that is
out by your verdict on a shoot you have finished. On 23 September: 43
reasons, nearly all on 2026-09-16 — expression 24 and composition 12, each
all on that one shoot, and blur 6 of the 12. That is not a bug in the
learner, it is a shortage of clicks, and the page says exactly which ones:
at least one more expression or composition drop on another finished shoot,
six more for blur. The only candidate there is today is the probe older
builds used (`models/flaws.json`), held because it would stop putting
forward 16 of your keepers.

The fastest way to get there: when you drop a frame for a reason the cull
did not catch, say which reason. It takes one click and it is the only
training signal the project cannot get anywhere else.

## 3. The aesthetic head — leave it alone for now

The ranking's biggest single input is a linear head over CLIP ViT-L/14,
trained by LAION on 176,000 human ratings. It is pretrained and frozen.

Seven off-the-shelf replacements were measured against it on three shoots,
scored on the camera previews, at the number of frames you actually chose:

| model | trained on | portraits | dog | lounge |
|---|---|---|---|---|
| LAION head (current) | 176k ratings | **0.25** | **0.36** | **0.36** |
| NIMA, Inception | AVA | 0.00 | 0.29 | 0.16 |
| MUSIQ | AVA | 0.08 | 0.14 | 0.04 |
| CLIP-IQA+ | KonIQ | 0.00 | 0.29 | 0.00 |
| LIQE, mixed | several IQA sets | 0.00 | 0.36 | 0.00 |
| random | | 0.07 | 0.26 | 0.08 |

Every alternative sits at or below random on the portraits. They are not
failing to find your picks, they are ranking them last: the sets they were
trained on reward the bright, centred, conventional frame, and your picks
were the dim wide ones.

**If you want to fine-tune it anyway**, the head is 768 inputs to one output
through four layers, so it is small enough to fit on a laptop. What stops it
is data, not compute: a few hundred of your own ratings would move it, and a
few dozen would only overfit. The path that makes sense is to keep choosing
keepers until several thousand frames across many shoots carry a
verdict, then fit the head on that and check it against the bench. Until
then the frozen head is the better model.

## 4. The face judge — thresholds, not training

Blink, motion, mid-word and the rest are measurements with thresholds, not
learned models, and they are deliberately not trained. Every number in
`faces.py` came from a specific frame that was judged wrong, and the frame is
written down next to it.

**To move a threshold:**

1. Find the frame that is wrong and add it to `tests/faces_truth.json` with
   the verdict it should get and a note saying why.
2. Change the number.
3. `./pl check` must stay at 94 of 94, `./pl check tests/pets_truth.json` at
   24 of 24, and `./pl bench` survive at 100%.
4. Write the frame that motivated the change into the comment beside it.

Thresholds measured this way are in `docs/ML.md`, including the ones that
were lowered and put back: at 0.45 the blink rule catches more of CEW's
closed-eye faces and at 0.40 more again, but at 0.40 a real open-eyed frame in
the fixture becomes a false blink, so it stays at 0.5. On the set as
`./pl evaluate` reads it today — 1,192 closed-eye crops, all of
`dataset_B_FacialImages_highResolution` — the rule flags 654 of the 1,175
crops whose landmarks it could read. Of the misses, 332 are shut eyes over a
smile, which the rule keeps on purpose, and 133 are the landmarker not seeing
shut eyes at all; those 133 are the ones worth working on. This copy of CEW
has no open-eye half, so it bounds recall and can say nothing about false
positives.

**What 23 expression labels bought.** Held-out AUC 0.74 against 0.50 for
shuffled labels, and in a permutation test its 0.82 was never reached by
chance in 40 runs. Real signal. Its effect on the ranking was +0.004, which is
noise. Both of those are true at once, and the second is the one that decides
whether it was worth the evening. Labels pay off slowly.

## 5. Shoot style — a setting that no longer hides anything

This section used to be the most important one on the page, because a fixed
similarity threshold decided which frames were the same picture and therefore
which were hidden, and the threshold was calibrated on subjects that hold
still. Consecutive frames of one exchange on an action shoot read 0.947 where
the rule wanted 0.975, so nothing grouped and a burst of thirty near-identical
frames survived whole; set the other way, the first action profile merged
similar poses as identical and lost 66 of one photographer's 252 keepers.

Neither failure can happen now, because nothing is hidden for looking alike.
Frames that look alike are stacked, the stack is drawn as a bracket, and every
member stays on the page. The thresholds are not fixed either: stacks are
linked by how much this card's own frames change from one to the next
(`quality.similar_stacks`), which is measured per shoot.

What `--style action` still decides is `--keep-per-group`: how many frames of
one stack reach the shortlist, two instead of one. Against that action
shoot's keepers, one lost 66 of 252 and two lost 4. If you ever retune it,
sweep it the same way — the metric is how many frames you wanted that the
setting keeps off the shortlist, and it needs a shoot you have already chosen
from. `./pl learned --check` is the same question asked of a model.

## 6. The starting edit — learned from finished shoots, per venue

This is the other learner, and it needs no labels: only frames you have
exported. `./pl taste` reads every sidecar with your hand in it (PhotoLab
writes your changes into the `Overrides` block; the pipeline leaves it
empty), measures the finished ones — a frame you exported, or any frame of a
shoot you marked finished — and learns only from the ones you exported. A
sidecar you opened and tried three things on teaches nothing; seven of those
once outvoted everything that had been finished. On the author's library that
is 436 exported frames of the 838 finished frames measured, over four shoots.
The check holds a version that learned from fewer of them than the one in
use, and counts the one in use by the same rule (`learned.edit_count`): frame
by frame where it kept the frames it was fitted on, which every version
learned from now on does, else shoot by shoot. Counted shoot by shoot the
count is a bound, and the strict one: the one in use at the most it could be,
the version weighed against it at the least. A version that kept nothing to
count by keeps its own count, and then so does the one it is weighed against.
The version in use came with the app and counts 527 from when every finished
frame taught; counted by what was exported it is at most 156, so 436 is not
held on its count, and the check's sentence says both numbers and how each
was counted. Going back to it once a version learned from exports is in use
is weighed the same way, at least 132 against 436, and held.

What it learns is kept per venue, because a look does not travel between
kinds of light. For each venue (`venues` in the starting edit):

- where its frames sit in the measurements that tell one venue from
  another (kelvin, the cast on the neutrals, frame and face brightness, the
  chroma of the light), and the spread its own frames fall inside;
- the preset your sidecars there started from;
- what you set the same way on most of its frames (`taste.shoot_overrides`:
  a rendering, ClearView off, a channel-mixer nudge pasted across the
  shoot); a number you varied from frame to frame never travels;
- where you put faces: for each frame you exposed by hand, the largest
  face's linear luminance from the RAW, times your bias, times the
  renderer's own lift, is a finished L*; the median is the venue's target;
- the exposure type: the one you were near-unanimous about, if any (the
  rule's venue preference), and the venue's own fitted type
  (`taste.venue_exposure`) — used only on the shoot that taught it, and
  only where, held out by scene inside the venue, it is right on more of
  your finished frames than both the rule replayed on the same frames and
  the venue's commonest type, and beats each by more than chance (a
  one-sided sign test at 0.05). The gate holds a candidate whose counts do
  not clear that bar, and names the shoot; while one is in use, the page's
  in-use line says where. A new shoot that measures like a venue borrows
  its look, never its exposure type, and a shoot like no venue gets the
  rule. See ML.md, *The presets*, for the per-venue numbers: on 23
  September no venue uses its own fit yet. The one that clearly won
  (2026-09-05-the-gals, 164 of 198 against 105 for its commonest type) was
  measured when every finished frame taught; no export of it is recorded, so
  now that only exports teach it has nothing to teach until its exports are
  found, and bringing its RAWs back from iCloud does not change that.

A new shoot inherits a venue's look only if its median frame measures
inside that venue's spread; otherwise it gets DxO's own camera-body
rendering and only what the sensor decides. So the way to teach it a kind
of light is to export a few frames of it, press Finish This Shoot, and let it
learn (by itself unless Settings ▸ Learning says not to; `./pl taste` from a
checkout).

The white-balance decision (AsShot or a named preset per frame) is learned
the same way, across venues, from the camera's own reading of the light and
the cast on the neutrals, and is used only while it beats always-AsShot
held out by scene.

**Measured once.** Fitting this needs numbers off each finished frame — its
light, its faces, the face in the export, and the share of the sensor at
saturation that the exposure rule reads — and those need the RAW on the
disk. So they are measured once and kept, one line per frame, in the learned
folder beside the models (`measured.jsonl`; never in the library, never in
the repo, never in the app bundle). A run measures a frame it has never
measured and one whose sidecar you have edited since; everything else it
reads back, and it fits from all of it. A frame keeps teaching after its RAW
has gone to iCloud, which is the whole point: before this, the first run
after an archive learned from 283 finished frames where the model in use had
527, and was rightly held for being smaller.

**One slow run, once.** The share of the sensor at saturation was not kept
before 23 September. The first learning run after that measures once more
every finished frame that lacks it and whose RAW is actually on this Mac
(never one whose bytes are only in iCloud — nothing is downloaded): on the
library copy that was 388 frames, about seven minutes where a run is
otherwise about one. The run says how many before it starts. It only reads
the RAWs, and a frame measured once is not measured again for this.

`./pl learned dataset` lists what taught it, shoot by shoot, with which
shoots' photographs are still on this Mac and what the store costs (about 5
KB a frame). `./pl learned --forget <shoot>` takes a shoot back out and it
stays out; `--teach-again` puts it back. Nothing does either by itself.

Frames finished before this existed and archived since were never measured:
there is nothing on disk to measure them from. `./pl archive pull <shoot>
--apply` once, then learn, and they are kept for good.

What it does not learn, on purpose: any number toward an external norm.
Skin is measured and reported against the published preferred range; the
correction, if you want one, is yours.

## What a good week of training data looks like

- Two or three shoots culled to the end, keepers chosen, exported, and
  **Finish This Shoot** pressed on each after the export, which writes down
  what was exported; the key itself writes itself as you choose.
- The frames you dropped that the cull wanted, each with a reason chip.
- `./pl bench` run afterwards so the row is written down.

Do that for a month and there is enough to fit taste weights per kind of
shoot and to train a second flaw probe.
