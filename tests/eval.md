# Evaluate, 2026-09-19

Everything on this machine that can say whether the cull is any good, each number with its
n and the dataset it came from. Run with `./pl evaluate`; it writes this file.

**This copy is out of date and has not been regenerated, because regenerating it needs the
photographs.** It was written on 19 September, and the cull has changed twice since. The
clustering became order-independent, which moved the action shoot's rejections from the 70
below to 64. And frames that look alike are stacked rather than hidden, so section 1 is
missing the two columns `./pl evaluate` writes today — `hidden by its cull.csv`, which is a
fault or, in an older file, a frame hidden for looking like another, and `under a top`,
which is a keeper shown one key below the top of its stack and is not a loss. Section 2's
per-rule table still shows `soft for this person` firing on 10 action frames. Run
`./pl evaluate` before quoting any number here.

The whole answer key is 4 shoots from one camera: 1705 frames, 205 of them kept. That is
small, and every number below should be read as measured on 4 shoots rather than as a property
of the cull. Held out by shoot, never by frame: frames of one burst are nearly the same
picture, and a model held out by frame is scored on frames it has all but seen.

## 1. Recall: the photographer's frames that survive the vetoes

The number that must stay at 100%. A veto on a frame the photographer wanted is the worst
thing the cull can do, and a change that raises precision and loses a keeper is a worse change.

| shoot | frames | kept | survive | lost to | source |
|---|---|---|---|---|---|
| portraits, two people, evening in town | 198 | 12 | 12/12 | - | 198 cached decodes at 6024x4024 with the camera previews beside them; no capture time survives, so every frame is its own burst |
| a lounge, red light, two people | 296 | 25 | 25/25 | - | 296 cached decodes at 2400x1603 with the camera previews beside them; no capture time survives, so every frame is its own burst |
| a dog, outdoors | 54 | 14 | 14/14 | - | 54 cached decodes at 6024x4024 with the camera previews beside them; capture time from the RAW EXIF |
| an action shoot, indoors, bursts | 1157 | 154 | 152/154 | TSC05422.jpg (blink), TSC05664.jpg (blink) | 1157 cached decodes at 4024x6024 with the camera previews beside them; no capture time survives, so every frame is its own burst |

Pooled: 203 of 205 keepers survive. The pooled number is here because it was asked for;
the per-shoot rows above are the ones to read, because a rule that costs nothing on three
shoots and ten keepers on the fourth is exactly the failure this harness exists to catch.

## 2. Which rule threw each frame out

Every rule in the cull that can reject a frame, with the number of frames it took and the
number of the photographer's own frames it took. A rule that fires on a keeper is a bug and is
named with the frame. A rule that fires on nothing at all is dead weight and gets a row saying so.

| rule | portraits, two people, evening in town | a lounge, red light, two people | a dog, outdoors | an action shoot, indoors, bursts | all | keepers lost | what it is |
|---|---|---|---|---|---|---|---|
| no preview | - | - | - | - | 0 | - | stage 1: nothing to measure; no decode and no camera JPEG |
| blown highlights | - | - | 5 | - | 5 | - | stage 1: clipped share of the camera JPEG over 0.15 |
| too dark | - | - | - | - | 0 | - | stage 1: mean brightness under --dark-floor 10 and no face or body found |
| softest in burst | - | - | - | - | 0 | - | stage 1: sharp_rel under --burst-floor, which ships at 0.0 (off) |
| blink | 4 | 5 | - | 41 | 50 | TSC05422.jpg, TSC05664.jpg | stage 1.5: eyes shut with no smile, on the largest readable face or a co-subject |
| soft | - | 5 | 1 | 18 | 24 | - | stage 1.5: a readable face under faces.UNREADABLE (1.2) |
| face in the dark | - | 8 | - | - | 8 | - | stage 1.5: nothing on the face above L* 35 |
| blown face | 9 | - | - | 1 | 10 | - | stage 1.5: a third of the skin at the clip point |
| soft for this person | - | - | - | - | 0 | - | stage 1.5: under half their own sharpest frame in the same burst |

Fired on none of the 1705 frames: `no preview`, `too dark`, `softest in burst`, `soft for this person`.
`softest in burst` is the per-burst quota. It is still in cull.py, behind `--burst-floor`,
which ships at 0.0; it cost 10 of 154 keepers on the action shoot when it was on.
It cannot fire as shipped at all, and it still has a reason string that a reader of a
cull.csv would take for a live rule. `soft duplicate` was a second such string and has
been deleted: no code set it once the dup floor began demoting instead of rejecting.
The rest of the dead list - `no preview`, `too dark`, `soft for this person` - is a fact about
these 4 shoots and not about the rules: they are waiting for a frame this camera has not
handed them yet, which is the right behaviour for a guard. They are dead weight only if
they stay at zero on a card that should have set them off.

**Against the cull's own record.** The veto chain above is a second copy of the one inside
cull.py's main(), so it is checked frame by frame against the cull.csv each shoot already
carries. Where the file is older than the current rules the disagreement is the age of the
file, and that is exactly why this harness recomputes instead of reading it. The date is the
file's mtime and not the age of its rules: a bench run rewrites and restores it. The reason
strings are what date it.

| shoot | frames compared | cull.csv rejected | here | same call | same reason | that file last touched |
|---|---|---|---|---|---|---|
| portraits, two people, evening in town | 198 | 28 | 13 | 183 | 13 | 2026-09-18 |
| a lounge, red light, two people | 296 | 58 | 18 | 256 | 16 | 2026-09-18 |
| a dog, outdoors | 54 | 12 | 6 | 48 | 6 | 2026-09-18 |
| an action shoot, indoors, bursts | 1157 | 70 | 60 | 1147 | 60 | 2026-09-18 |

portraits, two people, evening in town, first disagreements: TSC03714: cull.csv soft, here kept; TSC03721: cull.csv soft, here kept; TSC03759: cull.csv mid-word, here kept; TSC03768: cull.csv soft duplicate, here kept; TSC03815: cull.csv mid-word, here kept; TSC03832: cull.csv softest in burst, here kept; and 9 more.
a lounge, red light, two people, first disagreements: TSC04016: cull.csv motion blur, here kept; TSC04017: cull.csv soft, here kept; TSC04018: cull.csv motion blur, here soft; TSC04020: cull.csv motion blur, here soft; TSC04051: cull.csv soft, here kept; TSC04052: cull.csv soft, here kept; and 36 more.
a dog, outdoors, first disagreements: TSC04316: cull.csv soft duplicate, here kept; TSC04318: cull.csv soft duplicate, here kept; TSC04326: cull.csv softest in burst, here kept; TSC04327: cull.csv softest in burst, here kept; TSC04359: cull.csv softest in burst, here kept; TSC04361: cull.csv softest in burst, here kept.
an action shoot, indoors, bursts, first disagreements: TSC04606: cull.csv soft for this person, here kept; TSC04813: cull.csv soft for this person, here kept; TSC05048: cull.csv soft for this person, here kept; TSC05066: cull.csv soft for this person, here kept; TSC05359: cull.csv soft for this person, here kept; TSC05366: cull.csv soft for this person, here kept; and 4 more.

## 3. Ranking: within a burst, and pooled

The pooled keep/reject number is confounded and has been reported without that caveat. The
photographer keeps 1.0 frames from each burst that yields anything, so a frame's label depends on
which burst it landed in as much as on the frame: a good frame in a burst of 50 is a reject and
a middling one shot alone is a keeper. The within-burst pairwise number asks the question the
pooled one was meant to ask - of two frames of the same moment, does the measurement prefer the
one that was kept - and the pooled AUC stays in the table beside it rather than being replaced
by it. Published work on within-series photo preference sits at about 0.70-0.73 pairwise; that
is the bar, not 0.5.

Every number is one measurement the cull already makes, with 'higher is better' fixed in
advance. A number under 0.5 means the measurement ranks the keepers LAST, and it is printed
that way rather than flipped to look good.

One denominator warning. docs/ML.md's "best AUC 0.61" was measured on the 291 frames of the
action shoot that were reviewed twice, 154 kept against 137 thrown out. The pooled column here is
over every scored frame of each shoot, keepers against everything else, so it is a different
quantity and a lower number here is not a regression against that one. The within-burst
column is the one to compare across rows, because its denominator is a pair of frames of the
same moment and does not depend on how many frames the shoot has.

**portraits, two people, evening in town** - n=198 frames, 12 kept, 198 bursts, 0 of them with a keeper and a reject in the same burst.

No burst here holds both a keeper and a reject, so there is no pair to score: no capture time survives, so every frame is its own burst.
This shoot can answer the pooled question and cannot answer the within-burst one at all;
the row is left out rather than filled with the pooled number under another name.

| measurement | pooled AUC | n |
|---|---|---|
| face score | 0.535 | 198 |
| focus | 0.543 | 198 |
| focus vs burst | 0.500 | 198 |
| gaze | 0.635 | 198 |
| lead face width | 0.370 | 198 |
| lead face read | 0.406 | 198 |
| frame brightness | 0.523 | 198 |
| level | 0.484 | 198 |

**a lounge, red light, two people** - n=296 frames, 25 kept, 296 bursts, 0 of them with a keeper and a reject in the same burst.

No burst here holds both a keeper and a reject, so there is no pair to score: no capture time survives, so every frame is its own burst.
This shoot can answer the pooled question and cannot answer the within-burst one at all;
the row is left out rather than filled with the pooled number under another name.

| measurement | pooled AUC | n |
|---|---|---|
| face score | 0.694 | 296 |
| focus | 0.415 | 296 |
| focus vs burst | 0.500 | 296 |
| gaze | 0.446 | 296 |
| lead face width | 0.617 | 296 |
| lead face read | 0.525 | 296 |
| frame brightness | 0.578 | 296 |
| level | 0.568 | 296 |

**a dog, outdoors** - n=54 frames, 14 kept, 13 bursts, 8 of them with a keeper and a reject in the same burst.

| measurement | pooled AUC | within-burst pairwise | pairs | shuffled | p | top-k per burst | chance |
|---|---|---|---|---|---|---|---|
| face score | 0.568 | 0.632 | 38 | 0.484 | 0.255 | 0.643 | 0.471 |
| focus | 0.552 | 0.947 | 38 | 0.497 | 0.000 | 0.857 | 0.471 |
| focus vs burst | 0.643 | 0.829 | 38 | 0.500 | 0.010 | 0.714 | 0.471 |
| gaze | 0.487 | 0.461 | 38 | 0.494 | 0.585 | 0.429 | 0.471 |
| lead face width | 0.502 | 0.579 | 38 | 0.496 | 0.530 | 0.643 | 0.471 |
| lead face read | 0.512 | 0.539 | 38 | 0.506 | 0.585 | 0.500 | 0.471 |
| frame brightness | 0.484 | 0.684 | 38 | 0.489 | 0.150 | 0.571 | 0.471 |
| level | 0.500 | 0.500 | 38 | 0.500 | 1.000 | 0.429 | 0.471 |

**an action shoot, indoors, bursts** - n=1157 frames, 154 kept, 1157 bursts, 0 of them with a keeper and a reject in the same burst.

No burst here holds both a keeper and a reject, so there is no pair to score: no capture time survives, so every frame is its own burst.
This shoot can answer the pooled question and cannot answer the within-burst one at all;
the row is left out rather than filled with the pooled number under another name.

| measurement | pooled AUC | n |
|---|---|---|
| face score | 0.591 | 1157 |
| focus | 0.542 | 1157 |
| focus vs burst | 0.500 | 1157 |
| gaze | 0.483 | 1157 |
| lead face width | 0.547 | 1157 |
| lead face read | 0.523 | 1157 |
| frame brightness | 0.424 | 1157 |
| level | 0.498 | 1157 |

And the same measurements fitted together, held out by shoot: trained on 3 shoots, scored
on the one left out, which is the only honest way to ask whether any of this transfers.

| held-out shoot | n | keepers | pooled AUC | within-burst pairwise | pairs | shuffled | p | top-k | chance |
|---|---|---|---|---|---|---|---|---|---|
| a dog, outdoors | 54 | 14 | 0.586 | 0.553 | 38 | 0.482 | 0.635 | 0.500 | 0.471 |
| a lounge, red light, two people | 296 | 25 | 0.716 | n/a | 0 | n/a | n/a | n/a | n/a |
| an action shoot, indoors, bursts | 1157 | 154 | 0.502 | n/a | 0 | n/a | n/a | n/a | n/a |
| portraits, two people, evening in town | 198 | 12 | 0.520 | n/a | 0 | n/a | n/a | n/a | n/a |

`shuffled` is the same statistic with the labels shuffled inside each burst, 200 times: the burst
sizes and the number kept per burst stay exactly as they are, and only which frame was chosen is
randomised. `p` is the share of those shuffles at least as far from 0.5 as the real
number. At this n a pairwise number inside about 0.05 of 0.5 is not distinguishable from
chance, whatever it reads.

## 4. Blink recall

`$PHOTOS_ROOT/datasets/cew/dataset_B_FacialImages_highResolution` holds 1192 crops and every one of them is a CLOSED eye: filenames
`closed_eye_NNNN.jpg_face_N.jpg`, and no open-eye half was ever copied onto this machine. So
this dataset bounds RECALL and cannot say one word about false positives. It is
research-licensed: it is referenced by path, never copied into the repo, and nothing
trained on it may ship.

| what | n | of the sample |
|---|---|---|
| crops read | 1192 | sampled from 1192 with random.seed(0) |
| a main face found at all | 1191 | 99.9% |
| landmarks read | 1175 | 98.7% of those found |
| flagged `blink` (the flag that vetoes) | 654 | 55.7% of those read |
| flagged `blink?` by CLIP, no landmarks | 62 | never vetoes; a note only |
| shut eyes held back by the smile gate | 332 | 28.3% of those read |
| the landmarker did not see shut eyes | 133 | 11.3% of those read |

The last two rows are the whole of the miss, split because they are different faults. The
smile gate is deliberate - a laugh shuts the eyes too, real blinks read 0.13 and under on
smile and laughs 0.47 and up, and the photographer keeps laughs - so those misses are the
price of a rule that exists to protect keepers. The rows where the landmarker did not see shut
eyes are the measurement failing, and they are the ones worth working on.

These are tight crops of a face, so the detector meets a nearly face-filling image and
never has to find the face in a frame. Read the recall as the blink test's own ceiling,
not as what the cull does on a card.

**The negatives, and exactly how they were chosen.** With no open-eye half, the only
open-eye set on this machine whose eyes the photographer vouched for is the keeper set. The
negatives are the largest readable face on each frame the photographer kept and exported, 129 of the 205
keepers having one at all. They are overwhelmingly open-eyed because they were chosen, which is
the whole argument for using them; the known exceptions are the two frames on the action
shoot kept with a blink in them, so a perfect blink rule scores 2 here and not 0.

On that set the blink rule fires on 2: TSC05422.jpg, TSC05664.jpg.
This is the same count as the `blink` row of section 2 restricted to keepers, and that is
where it belongs: a blink false positive IS a lost keeper, and section 1 is the line that
refuses to let one pass.

## 5. The animal gate

A dog, a cat, a lamp or the back of a head may lower a frame's score and may never throw
the frame out. YuNet reads a pet's head as a human face often enough for that to matter,
and a 'face' that reads soft or blinking would veto the frame. Sampled 600 of the
3686 Oxford-IIIT Pet images that carry a head box drawn by the dataset's authors, shuffled
with random.seed(0) by `pipeline/eval_pets.py`'s own loader; the full folder is 11,086 files
and most carry no box, so the gate can only be scored on the annotated ones. CC BY-SA 4.0,
referenced by path and never copied into the repo.

| what | n | share |
|---|---|---|
| images measured | 600 | of 600 drawn |
| a YOLOX cat/dog box covers the head | 557 | 92.8% |
| YuNet read the head as a main human face | 248 | 41.3% |
| of those, gated as an animal | 244 | 98.4% |
| **ungated AND carrying a vetoing fault** | **0** | 0.0% of the heads read |

The last row is the invariant, and it must be 0. It counts a pet head that the gate did not
catch AND that carries one of the four faults that veto, which is a frame thrown out on an
animal's face as soon as that head is the largest readable face in the picture.

It is 0 of the 248 heads read as a face, and that is the invariant holding rather
than a guard: 4 heads got past both witnesses, 1 of them landmark-read, which is the
only state in which a fault can veto. None of those happens to carry one. At 24 fixtures
it also read 0, which is why the number is taken over the whole annotated set.

`pipeline/eval_pets.py` is the fuller report on the same data, broken down by breed; this
row is the invariant alone.

## 6. The face judge against the verdicts settled by eye

`./pl check` is called here, not reimplemented: the kiss rule and the verdict rule exist once.

| what | result | command |
|---|---|---|
| frames settled by eye | 94 of 94 | `./pl check` |
| pet heads the detector reads as faces | 24 of 24 | `./pl check tests/pets_truth.json` |

## What is not measured here

- **One camera, one photographer, 4 shoots.** 1705 frames with an answer key and 205
  keepers. Nothing here shows a threshold transfers to another body, another lens or another
  person's taste, and the per-shoot columns exist because the pooled number hides exactly the
  failure that cost 33 keepers.
- **`$PHOTOS_ROOT/shoots/ducksAndDeadlifts`** is 98 loose ARW with no answer key and no
  shoot.json: a genuinely unseen shoot. It is a smoke test and not a score, and it has no
  cull/decoded, so measuring it would mean decoding RAWs into that shoot folder. This harness
  writes nothing inside ~/photos, so it has no row here; run `./pl cull` on it by hand.
- **False positives on blinks** cannot come from CEW on this machine; see section 4.
- **Recall is measured on the cached decodes**, which is what the fixture check runs on and
  what the lounge has left. A cull of the RAWs decodes at full resolution; on three of the
  four shoots the cache IS that full-resolution decode, and on the lounge it is 2400 px wide.
- **The veto chain is re-expressed in this file**, because cull.py holds it inline in main()
  and running the cull would rewrite the cull.csv you work from. Section 2 prints the rule
  behind every rejection so a disagreement with a fresh `./pl cull` shows up frame by frame.

Run: 0.7 minutes for this one, 200 permutations, pets sample 600, cew sample 1192.
Measurements are cached under `~/.cache/first-edit/evaluate`, keyed by the frame and by
the source of the code that measures it: change a rule and the verdicts re-run in seconds,
change a measurement and every frame is read again. `--refresh` ignores the cache.
