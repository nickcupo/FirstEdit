# Contributing

Thank you for reading this far. This started as a tool for my own
photographs and I would like it to work on other people's. The fastest way
to help is an issue with a frame it got wrong; the second fastest is a pull
request that moves a number in the README's tables and says how.

## Setting up

macOS on Apple silicon is what I run; the Python underneath does not care.

```bash
git clone https://github.com/nickcupo/first-edit
cd first-edit
./pl setup            # venv, five small models (about 80 MB), CLIP ViT-L/14 (1.7 GB)
./pl selftest         # half a minute; should end "9 of 9". Needs a library with photographs in it
```

`exiftool` (`brew install exiftool`) is needed for ingest and for the star
ratings. DxO PhotoLab is needed only to open what the presets step writes.

## Running the checks

| Check | Needs | Proves | Expected |
|---|---|---|---|
| `./pl selftest` | the venv, the models, and six RAWs of yours it keeps in the pipeline's support folder (seeded on its first run from the first shoot it finds with six whose bytes are on the disk) | the whole pipeline runs end to end on those six frames, and every flag the engine passes a script is a flag that script takes | 9 of 9. Says so and stops if there is no library |
| `./pl check tests/pets_truth.json` | a bare checkout | a cat's or dog's face can never veto a frame | 24 of 24 |
| `.venv/bin/ruff check pipeline app tests` | ruff (pinned in CI) | style, as configured in `ruff.toml` | All checks passed |
| `python -m compileall -q pipeline` | nothing | every module parses | silent |
| `swift test --package-path app` | full Xcode with an SDK of 26 or newer | the app: the key map's two rules and, in `KeyParityTests`, that a key means one thing on every page with photographs, the stacks, the decoders, the first launch's move, what the storage panel may claim | all pass |
| `python -m pytest tests -q` | the venv | the sidecar writer and what a Base may be built from, what each other editor's file carries and what it drops, that the answer key is found in `decisions/` with no symlink to help, the two rules that keep `archive expire` from destroying a frame, and what the storage panel is allowed to claim | all pass |
| `./pl check` | `~/photos/fixtures/faces` (my frames; not in the repo) | the face judge's verdicts on 94 frames settled by eye have not moved | 94 of 94 |
| `./pl bench` | shoots with a `selects.json` | how many of the frames you kept survive, and the ranking's precision | writes `tests/bench.md` |
| `./pl evaluate` | the above, plus CEW and Oxford-IIIT Pet where you have them | every measurement with its n, held out by shoot; rules that fired on nothing get a row saying so | writes `tests/eval.md` |

The last two need my photographs, so you cannot run them, and CI cannot
either. If your change touches `faces.py` or `cull.py`, say so in the pull
request and I will run them before merging. If you have shoots of your own
with an answer key, `./pl bench` on them is worth more than any of mine:
the README says which kinds of shoot have never been measured.

One of the self-test's nine checks is about agreement rather than output.

`selftest.buttons_agree` reads the command lists out of `studio.py` and asks
each script's own `--help` whether it knows every flag those lists pass it. It
exists because of one afternoon: a button said "Standardise the whole burst &
open in PhotoLab", the endpoint behind it passed neither flag, and the script
in the shipped bundle had neither to pass. Three copies of the same feature,
none agreeing, and the only symptom was a button that did nothing at all.

There were ten. The tenth ran `node --check` over the `<script>` blocks of
`pipeline/studio.html`, which was the browser page this engine used to serve
and is retired; both the page and the check are gone. Before that, this
paragraph described the check for months while `selftest.py` contained no
mention of node or of that file at all — which is the whole argument for
reading the code before writing the line about it.

## How the code hangs together

`docs/DESIGN.md` is the source of truth for the app, and the code cites it by
section number: a comment reading `DESIGN.md §2.5.4` means that section, and a
bare `§2.5.4` in a file under `app/` means the same document. The second screen
has its own, `docs/DESIGN-displays.md`, and a citation that means that one
names it. Section numbers are stable on purpose — nothing is renumbered, and a
part that stops existing keeps its heading and says so — because four hundred
comments point at them.

If you change behaviour the design describes, change the design in the same
commit. A document that disagrees with the code is worse than no document: it
is the code's own claim about itself, and it is wrong.

`pl` is a zsh launcher that picks the venv and hands the subcommand to a
module in `pipeline/`. Each module is a script with a `main()` and a
docstring at the top that says what it reads and writes; start there.

- `ingest.py` copies a card into `~/photos/shoots/<name>/raw/` and re-reads
  every byte.
- `cull.py` is the three passes: decode (`faces.decode_to_file`), focus and
  bursts on the decode, every face through `faces.FaceJudge` at full
  resolution, then `quality.py` (CLIP, the aesthetic head, grouping,
  moments, flaws). It writes `cull/cull.csv`, one row per frame with every
  measurement and the verdict, and `cull/picks/` as hard links. `cull.csv`
  is the contract everything downstream reads.
- `studio.py` is the engine: JSON routes on 127.0.0.1, the jobs behind each
  step, and the list of work they wait on. It writes
  `decisions/organize.json` (your ratings), `labels.json` (drop reasons),
  `selects.json` (the answer key `bench` uses) and `shoot.json` (the kind
  of shoot, and `finished` once the shoot is marked finished). Every request
  carries a per-launch key, the Host and Origin headers are checked, and `..`
  is rejected. The last step's **Where this shoot lives** panel is
  `archive.py` and `reclaim.py` read-only, plus a plan-then-token flow for
  anything that removes a file; `NEVER_QUEUED` is the three kinds of work
  that flow may never be left on a list for. The derivatives it serves are
  `/thumb/`, `/large/`, `/preview/`, `/full/` and `/crop/` off the RAW, and
  `/exported/` off a finished JPEG for the Instagram step. `/full/` is capped
  at `FULL_PX` (2,600 px on the longest edge: 334,866 bytes against the
  2,295,531 of the 6,024 px decode it is made from, on one frame of the dog
  shoot), and
  `/crop/` is the loupe — a window cut out of that decode with no resampling
  at all, the box clamped server-side, so one source pixel can land on one
  device pixel. A row carries the measured size of each derivative that is
  actually on the disk — `tw`/`th` for the thumbnail, which is what lets a
  tile reserve its box before the picture arrives, and `dw`/`dh` for the
  decode, which is what the loupe sizes its crop from. A tier that is not
  there leaves its keys off the row rather than guessing a size, so after
  `./pl reclaim` has taken the decodes back no row carries `dw` at all and
  both the tile and the loupe fall back on purpose: a descriptor that lies is
  worse than none, because the browser believes it. A view that asks for more
  pixels than the decode holds is labelled with the ratio it really got,
  never "1:1".
- `library.py` says what every file in a shoot is (original, decision,
  cache, finished work) and where the RAWs are, so no command has to guess
  from whether a folder is spelled `raw`. `reclaim.py` answers what a shoot
  costs and what is safe to take back, and `archive.py` keeps a finished
  shoot's RAWs in iCloud Drive. `reclaim.py` deliberately imports nothing
  from `library.py`: it is the only thing here that can unlink a
  photograph's last rendering, and a second opinion reached independently is
  worth more than a shared one.
- `migrate.py` moved the decisions out of `cull/` into `decisions/` and
  left a symlink at each old name. `common.decision_path` is what makes
  those links a courtesy: an existing file wins wherever it is.
- `evaluate.py` is the measurement harness (`./pl evaluate`). It recomputes
  from pixels rather than reading a `cull.csv`, holds out by shoot, and
  writes `tests/eval.md`.
- `presets.py` measures each setup on the camera JPEG (`SceneReader`,
  `measure`) and each keeper's RAW in linear terms (`linear_measure`),
  decides exposure from the sensor (`decide_exposure`), places a mask per
  face that needs one (`face_masks`, `ai_mask`), and writes PhotoLab
  presets and sidecars: a partial Base on DxO's `2 - DxO Standard` when no
  finished venue matches, or the venue's own preset and look when one
  does. `lua_lines` lays tables out the way PhotoLab does.
- `taste.py` is what is learned from finished shoots (`./pl taste`): per
  venue, the measurement centre and spread, the preset it started from,
  what the photographer set the same way there (`shoot_overrides`), the
  face target implied by their exposures and the RAW (`learn_venues`), the
  AsShot-or-Fluo decision (`learn_wb`), and the vocabulary of string values
  PhotoLab has been seen to write (`check_dop` refuses anything else).
  `pipeline/taste.json` is committed and is the neutral seed: no venues and
  no ranker, so DxO's own camera-body rendering until something has been
  learned. What is learned goes to the learned folder (`learned.py`), never
  the repository and never the signed bundle. Every finished frame is
  measured (`taste.finished`: exported, or on a shoot marked finished), but
  only the ones the photographer exported teach (`learned.taught`): a keeper
  is where the editing starts, and the cull goes on in PhotoLab. The keeper
  check still counts every keeper.
- `learned.py` owns everything that learns: the one writable folder the
  models live in (`PIPELINE_LEARNED`, else `$PIPELINE_SUPPORT/learned`, else
  Application Support — never the repository, never the signed bundle), the
  measurements it keeps one line per finished frame in `measured.jsonl`, and
  the keeper check. A candidate is replayed against every keeper of every
  shoot that carries a verdict, through the live model and the candidate,
  dealing the tiers both ways with `common.deal_tiers`; it goes live only if
  no keeper moves out of sight, and is otherwise held with those frames
  named. Nothing a learner produces is used before it passes that.
- `gather.py` builds `edit/` (keepers hard-linked beside their sidecars) and
  carries edits made there back beside the RAW.
- `exports.py` is the one answer to where a frame's finished JPEG is, and
  `instagram.py` cuts Instagram-sized copies from it: `--plan` works every cut
  out and writes the record without a photograph, and the app's Instagram
  step reads and changes that record through `studio.py`.
- `editors.py` translates the same edit for Lightroom and RawTherapee.
- `common.py` holds file types, thumbnails, the XMP packet and where the
  extension lives; `fetch_models.py` (via `models.sh`) gets the five small
  models and proves each one against the SHA-256 in `pipeline/models.json`,
  and `fetch_clip.py` gets CLIP. Everything irreplaceable is
  written through `common.write_atomic`: a temp file on the same volume,
  fsync, then `os.replace`. It resolves a symlink first and writes *through*
  it, because `os.replace` swaps the name, and against the compatibility
  links `migrate` leaves behind that would put a second, divergent copy of
  your stars back inside the cache folder.
- `app/` is the Mac app: a Swift package (`Package.swift`, `Sources/` —
  `FirstEdit` is the executable, `PipelineKit` is everything worth
  testing, `SnapshotHarness` renders the screens offscreen), `build.sh` (a
  relocatable CPython plus the pipeline, signed and, when asked, notarized),
  `dmg_settings.py`. Nothing in `Package.swift` names a file, so a target's
  new source is picked up without editing it. The app drives the engine over
  its JSON routes and draws every screen itself.

Two files are called `taste.json`. `pipeline/taste.json` is the neutral
starting edit that ships with the code and is in git. `models/taste.json`
held the ranking weights `./pl cull --learn` fitted; that flag is retired,
nothing writes the file any more, and the weights are
`quality.DEFAULT_WEIGHTS`. A third place matters more than either: the
learned folder, outside both the repository and the bundle, which is where
`learned.py` keeps every candidate and every live model.

## Numbers are measured, not chosen

Every number in `faces.py` and `cull.py` came from frames it got wrong, and
they are written down beside it. A number may *veto* a frame only if it
transfers: set on any three of the four shoots it lands on the same value
and costs no keeper on the fourth (a blink at 0.5 with the smile gate, skin
at the clip point at 0.35, nothing above L* 35, a face under 1.2). A number
that does not transfer is a tolerance, and becomes a note that orders the
review instead: "soft" at 1.9 is right for a posed portrait and threw out
26 keepers of an action shoot; mid-word set from portraits cost 43 of 152.
If you change a number, change it the same way: name the frames, run the
checks, show it held out by shoot, put the before and after in the pull
request. [docs/ML.md](docs/ML.md) records every threshold and the things
measured and rejected, so a proposal that was already tried can be found
there first. `tests/faces_truth.json` guards the measurements; when a rule
changes on purpose its verdicts are re-settled one by one, each with its
reason in the entry's note.

The same goes for the editing side, with a stricter rule: nothing written
into a sidecar may be a value somebody liked. It is physical (stops, from
the RAW), read off finished edits, or left to DxO. The three calibration
constants in `presets.py` (`RENDER_GAIN`, `CLIP_FLOOR`, `DARK_Y`) each say
what they were measured on and how to re-measure them; a pull request that
re-measures one on a different camera is welcome. The same goes for the
numbers that say whose face is the subject's (`HEAD_W`, `HEAD_Y`,
`HEAD_X`, `SURE_FACE`, `SUBJECT_BODY`): they were measured on the 130
faces the landmarker read on one action shoot and checked against every
one of its 154 exported keepers, and a shoot of another kind (a wedding,
a stage) may move them. If you change one, run the rule over every
exported keeper of the shoots you have and put the before and after
counts (frames with a subject face, masks) in the pull request.

The fixtures pin three kinds of shoot (portraits, a red-lit lounge, a dog)
and no action shoot; that is a known gap, and rows for one are welcome.

## Adding a camera

Three places know about a RAW format: `common.py` `RAW_EXTS` (the
extensions the cull and the engine accept), `cull.py` where the embedded
preview is read (the tag names differ by maker), and `presets.py`
`kelvin_from_raw` and `linear_measure` (the as-shot multipliers and the
saturation level via rawpy; Sony bodies saturate a few counts under the
nominal white level, which `linear_measure` finds as a spike). Sony `.ARW`
is what I shoot; Nikon and Canon previews are read but unmeasured. A pull
request for a new camera should come with `./pl selftest` passing on six
of its frames.

## Adding an editor

`editors.py` has a small `Edit` dataclass and `from_dxo()` that fills it
from the PhotoLab settings. A new editor is four things: a row in `FORMATS`
(the suffix, whether the sidecar is named after the whole file or the stem,
what it declares itself to be, and the vendor file and line that number came
from), a row in `CARRIES` saying what your writer does with every field of
the `Edit` and why, a writer function, and a branch in `render()`. `./pl
presets --editor <name>` then uses it. The manifest test renders every field
at rest and moved, so a field you call carried has to reach the file and one
you call dropped has to leave it alone: that is the pull request's answer to
"which fields does your format have no home for".

## Adding a kind of shoot

Two ways. A subject or lighting prompt that a general photographer would
recognise belongs in `presets.py` `SUBJECTS` / `LIGHTS` (CLIP zero-shot
labels). Anything with steps of its own, its own prompts or its own
organisation belongs in an extension, a folder beside the repo (the
README's Extensions table is the contract), so that a domain only one
person cares about never has to be in this repo. The README's Extensions
table is what the engine expects of one; what the app expects of a step's
page — the scheme it is loaded through, the key every request carries, what
the page may not do and the colours it inherits — is in
[the extension host contract](app/Sources/PipelineKit/ExtensionHost/ExtContract.docc/ExtContract.md).
Extensions also replace the third pass's moment prompts through
`moments.json`, so a bench run with an extension installed differs slightly
from one without; say which you ran.

A kind of light needs no code at all: export a few frames of it from
PhotoLab, press Finish This Shoot, and learn (the app does it by itself
unless Settings ▸ Learning says not to; `./pl taste` from a checkout). Once
that passes the keeper check it is a venue the next shoot like it inherits
from.

## What makes a good pull request

- One change, with the frames and numbers that motivated it.
- The checks table above, before and after, in the description.
- Nothing personal in it: no shoot folders, no photographs, no names. The
  fixtures that ship are CC BY-SA images with attribution.
- Comments say why, with the number and the frame; the README and
  `docs/ML.md` updated if a number they print has moved.
- First person is the repository's voice, and it is the author's. Write
  comments and docs as "the photographer" or "you", not "he" or "I".

## Code style

`ruff.toml` (E, F, W, B at 160 columns). Python 3.12, which is what
`setup.sh` insists on and what `requirements.txt` is pinned to. No type
checker is run; type hints where they help. The app is Swift 6 and SwiftUI
in one package with no dependencies, and there will not be any: a
third-party package is one more thing to audit, notarize and explain in the
notices.

## Releases

`app/build.sh` builds, signs and notarizes the app, and names the DMG after
`git describe --tags`. A release is a tag `vX.Y.Z`, a full GitHub release
(not a draft or a pre-release; the app's updater reads `/releases/latest`)
with the DMG as its one `.dmg` asset, and an entry in `CHANGELOG.md`. macOS
15 or newer: `Package.swift` builds for `.macOS(.v15)` and the `Info.plist`
promises 15.0, and `app/build.sh` checks the assembled binary against that
number. Nothing has been released from the native app yet: v0.1.3 is a tag
with no release behind it. [RELEASING.md](RELEASING.md) is the procedure.

Two gates sit between the assembled bundle and the signature. The first
writes `NOTICES.md` from the bundle itself — every wheel's licence,
copyright line and source URL out of its own `dist-info`, the models out of
`pipeline/models.json`, CPython and exiftool out of their own files — and
stops the build if any dependency will not say what its licence is. That
file is not in the repository and must not be committed: `.gitignore` keeps
it out, because a generated file committed beside its generator goes stale
one commit later with nothing to say so. The build stamps it with the
version and writes it into the bundle and beside the DMG. The second refuses
to build while any
GPL FFmpeg library is in the bundle; `ALLOW_COPYLEFT=1` overrides it for a
local build you hand to nobody, and the build prints that it must not be
distributed. The bundle gets past that gate because it does not install
OpenCV from PyPI: the published wheels carry an FFmpeg configured
`--enable-gpl` and linked against libx264, libx265 and four more
GPL-2.0-or-later libraries, so `app/tools/build-opencv.sh` builds the same
version of `opencv-python-headless` and `opencv-contrib-python` from source
with `-DWITH_FFMPEG=OFF`, and `app/requirements.lock` names those two wheels
by URL and by SHA-256. `requirements.txt`, which is what your checkout's
`.venv` installs, keeps the PyPI wheels — a developer venv is handed to
nobody, and the two builds are proved to cull a shoot to the same
byte-for-byte `cull.csv`. RELEASING.md says when the wheels have to be built
again; `NOTICES.md` states the whole position.
