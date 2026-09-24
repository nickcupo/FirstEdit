# From the card to the last photo

The app (First Edit.app) walks these steps with one button each. The
commands are here because they are the same work, and because nothing in the
pipeline depends on the app: `./pl` does every step from a checkout.

Shoots live at `~/photos/shoots/<date-name>/`:

```
2026-10-04-lake/
  raw/       the RAWs and their sidecars. The pipeline writes sidecars here and
             nothing else, unless you pass --xmp to the cull.
  decisions/ the files that are yours and that no machine can rebuild:
             organize.json (your stars), labels.json (your drop reasons),
             selects.json (the answer key) and selects.prev.json (what it
             said before a re-read narrowed it), spread.json (which sidecars
             the machine wrote rather than you).
  cull/      cull.csv, the previews, thumbs, large and decoded caches (rebuilt
             from the RAWs; each carries a CACHEDIR.TAG), picks/ (hard links),
             presets/, presets.md.
  edit/      the frames you kept, hard-linked, each with its sidecar: what
             ./pl gather builds and what PhotoLab opens.
  export/    the JPEGs you export from PhotoLab
```

The decisions used to live inside `cull/`, which Finder reports as gigabytes
and which is named like a cache. `./pl migrate` moves an older shoot's out
(dry run by default, `--apply` to do it, `--undo` to put them back) and leaves
a symlink at each old name, so anything that still reads `cull/selects.json`
keeps finding it. Either layout reads correctly: an existing file wins wherever
it is.

## 0. Once, on a new machine

With the app: open it once; it fetches CLIP (1.7 GB) with a bar and is
ready. From a checkout:

```bash
./pl setup       # a venv, five small models, CLIP; about ten minutes and two gigabytes
./pl check       # the face judge gives the answers it gave on the frames settled by eye
./pl migrate     # only on a library made before the decisions moved out of cull/
```

## 1. Put the card in

```bash
./pl ingest /Volumes/CARD 2026-10-04-lake
```

Copies every RAW and JPEG to `~/photos/shoots/2026-10-04-lake/raw` and
flattens the camera's folders. The card is never written to; it stays the
backup until the photos are delivered. In the app, a card put in while the
front page is up appears in the list by itself.

The card is the slow end of this, so how hard the copy is checked is a
choice, in the app next to the card and on the command line as `--verify`:

| | what it does | passes over the card |
|---|---|---|
| `in-flight` (default) | hashes the bytes on the way past, then reads the copy back off the SSD | one |
| `end` | copies, then reads the card again and hashes both sides | two |
| `none` | checks the sizes match | one |

All three catch a bad write except `none`. Only `end` also catches a card
that hands back different bytes the second time, which is what a failing
card does. On a card reading at 95 MB/s, the second pass over a 27 GB shoot
costs about five minutes.

## 2. Cull

```bash
./pl cull ~/photos/shoots/2026-10-04-lake/raw --copy
```

Every RAW is decoded at full resolution first (a frame per core, three
quarters of them by default; about a minute per 100 frames on a laptop, more
for a big card, and that is fine: the review afterwards is what has to be
quick). What comes out, in `cull/`:

- `cull.csv`: every frame, its rating (5 a clear win, 3 a maybe, 2 probably
  not or set aside under the top of its stack, 0 a fault), the reason, the
  face flags, who is in it, its setup, its burst, and the stack it belongs
  to. A 1 appears only in a file written before stacks, where it meant a
  frame hidden for looking like another.
- `picks/`: the picks, as hard links, so they cost no disk.

Add `--top 150` to keep only the best 150 across every setup, in
proportion to the time spent at each; without it everything above the cut
is a pick.

Frames that look alike are **stacked**: a run of them, back to back inside
one burst, where CLIP and a perceptual hash both say the card barely changed.
A stack is drawn as a bracket and nothing under it is taken off the screen.
The cull's best guess is the stack's top and is tiered like any other frame;
the others sit under it, set aside, one key away. The rule this replaced hid
all but one frame of a group, and it hid 65 of 773 keepers across the shoots
it was measured against.

`--style action` is for anything where the subject moves between frames. It
used to decide what counted as the same picture, and so what was hidden; now
it decides that two frames of each stack reach the shortlist rather than one,
because the frames of one exchange differ more than they look. Measured
against the keepers of an action shoot, one per stack lost 66 of 252 and two
lost 4.

Presets are deliberately not part of this step. Reading the light in every
setup and writing a sidecar per frame is the slowest thing the pipeline
does, and before you have said what you are keeping, most of that work is
spent on frames that are about to be thrown away. Pass `--presets --dop`
to fold it back into the cull if you would rather have it in one go.

## 3. Choose your keepers

The cull's picks are a suggestion. Reviewing them happens a burst at a
time, because a burst is one press of the shutter and so it is the unit you
actually choose in: of these eight frames of the same exchange, which one
worked.

The step opens on one burst's frames, where you left off. `G` shows every
burst in the shoot instead, in the order you shot it, each as a cover frame
with the time, how many frames it holds and how many are kept; `Return`,
`Esc` or `G` again goes back into the burst the ring is on, and its frames
fill the window.

Everything a cull needs sits under the left hand, so the right can stay on
the mouse. The keys learned before that — `K`, `N`, `P`, `U`, `0` and the
arrows — still work beside them.

| | |
|---|---|
| `S` / `F`, or left and right | the previous and next frame, on across bursts |
| up and down | move along the cull's shortlist, or stack to stack |
| `E` / `D` (or `K` / `D`) | keep or drop the frame you are on |
| `1`–`6` | the reason you dropped it |
| `X` (or `0`) | clear the mark |
| `R` / `W` (or `N` / `P`) | the next burst, the one before |
| space | the frame full size, decoded from the RAW |
| `Z` or `⌘0`, `⌘9` | 1:1, or the whole frame |
| shift-arrows or a drag, at 1:1 | move the box; the centre stays where you put it |
| `C` | the frames of a stack side by side |
| `⇧E` | keep only this one of its stack |
| `G` | every burst of the shoot at a glance |
| `Q` (or `U`, `⌘Z`) | undo the last verdict; `⇧⌘Z` puts it back |
| `?` | every shortcut, in a window |

Leaving a burst forward — `R`, or `F` off its last frame — is what records it
as looked through; going back records nothing. A Keep or Drop on a burst's
last frame goes on into the next burst, unless Settings ▸ Choosing says to
stay. A scroll over the photograph steps one frame a notch, as the arrows do.
No key that writes a verdict repeats while it is held: a held `K` once wrote
three frames that had never been on the screen, in 90 ms.

A cull turns on whether the eye is sharp, and a whole frame drawn into a
window cannot answer that: a 6,024 px frame in a 1,105 px slot is an 18%
view, and every close call was going to PhotoLab to be settled. At 1:1 the
box is cut out of the full-resolution decode with no resampling at all, so
one source pixel lands on one device pixel; the centre survives the arrow
keys, so flipping through a burst compares the same eye on every frame. On a
wide screen the slot can ask for more pixels than the decode holds, and the
caption then says what the ratio really is instead of claiming 1:1. Keep and
drop act only on the picture actually on the screen: the label changes the
instant you press an arrow and the picture takes about 60 ms to arrive, and
an arrow-then-`K` used to keep a frame you had not looked at.

Under every frame is its verdict and a row of reasons: shadow, cut off, face,
blur, exposure, framing. One click, or one digit, sets one; another clears it.
Nothing opens, nothing to confirm. Those reasons are the training data the
cull does not otherwise have; `./pl learn` turns them into a candidate model
once one reason has twelve examples, and that candidate has to pass the keeper
check before anything uses it.

What the cull decided and what you decided are two different facts and are
never added together on the screen. The cull's tier comes straight out of
`cull.csv`; a keeper is your word and is never printed over a machine
verdict. Leaving the step asks nothing and writes nothing.

`G` is the shoot at a glance: every burst as a cover, the ones you have not
looked through dimmed, the one you are on ringed, and `R` or `N` jumping to
the next one you have not looked through.

Stars go straight to the sidecar PhotoLab reads. From the command line the
equivalent is `--keep TSC01234.ARW` on the cull, or a star in PhotoLab.

## 4. Presets

```bash
./pl presets ~/photos/shoots/2026-10-04-lake/raw --install --dop --picks-only
```

Now that the keepers are settled, this reads the light in each setup that
survived and writes:

- `presets/` and `presets.md`: one PhotoLab preset per setup, installed,
  with a page saying what each setup was read as and what was set.
- A `.dop` sidecar per keeper, so PhotoLab opens the folder edited and
  rated. Each one carries what the sensor decided for that frame (exposure:
  which correction and how much, from the largest face's luminance in the
  RAW; a mask on any face the global correction leaves short) on top of
  either the look you gave a venue like this one, if you have finished
  frames of one, or DxO's own camera-body rendering if you have not.
  `presets.md` says which, and why.

`--picks-only` writes sidecars for the frames you kept and nothing else,
which is what the app does. Drop it to cover the rejects too, worth it
only if you expect to go back through them in PhotoLab. Your own stars from
the app win over the cull's: a frame you rescued is written as a keeper.
Existing sidecars are not overwritten unless you pass `--force`, which the
app does when you ask it to write them again; even then a sidecar with
your own edits keeps them, and only the pipeline's Base underneath is
refreshed (`--mine-too` replaces those too).

## 5. Edit in PhotoLab

Press **Open My Keepers in PhotoLab** in the app (Return on the Presets page
does the same once the presets are written), or run `./pl gather <shoot>`: it
builds `edit/`, a folder holding only the frames you kept (hard links, no
extra disk), each with its sidecar, and opens it. Every frame in it already
carries its preset and its stars. A sidecar you edit in `edit/` is promoted
back beside its RAW before the folder is ever rebuilt. Spot-check a few across
the setups: the preset is a starting point, so what it leaves to you is
exposure to taste, a control point on the face, and the crop.
`cull/presets.md` says per setup what it measured and what it left.

If a frame shows no preset, PhotoLab had the folder in its database from
before: File → Sidecars → Import.

Export the starred frames as JPEG, full size, sRGB, quality 90, to
`export/`. That folder is the finished shoot.

Then press **Finish This Shoot** on the last step. It records your keepers,
which every later change to the cull is checked against, and writes down the
frames you exported, which are what the shoot teaches: the look you gave
this venue, where you put faces, what you set the same way on most frames.
Only exported frames teach, because the cull goes on in PhotoLab and a
keeper you passed over there is not your taste; the keeper check still
counts it. The app then learns by itself unless Settings ▸ Learning says not
to (`./pl taste` does the same from a checkout), and once what it learned
passes the keeper check the next shoot that measures like this one starts
there. A sidecar you merely opened and tried things on teaches nothing.

## 6. Instagram

```bash
./pl instagram ~/photos/shoots/2026-10-04-lake --all --plan   # work every cut out, make nothing
./pl instagram ~/photos/shoots/2026-10-04-lake --all          # make what was worked out
```

In the app this is the step after Edit in PhotoLab: one wall of the shoot's
exported photographs, each with its cut drawn on it, worked out in the
background as soon as the step opens. A portrait is cut to 3:4 at 1080 ×
1440 by default (4:5 from the picker) around the faces the detector finds; a
landscape is left whole, 1080 wide, or cut too. The photographs whose
subject the profile grid's middle strip would lose come first, marked in
orange.

It moves the way Choose Keepers does, with the same keys: `S` and `F` along
the wall, `E` to include a photograph, `D` to leave it out, `X` to clear,
space to open the cut and close it again, `Q` to undo. In the editor a drag
moves the cut, a corner or a pinch sizes it, shift-arrows nudge it, and `A`,
`T` and `V` are the automatic cut, cut or whole, and the result. With
nothing included, every photograph not left out is made. **Make N Copies**
writes exactly the cuts on the screen into `<shoot>/instagram/`, a crop and
a resize of each export with no sharpening and no tone added; ⌥ puts it on
Up Next.

## 7. Put the shoot away

A finished shoot is tens of gigabytes that will not be culled again. The last
step grows a **Where this shoot lives** panel once there is something to say,
and the same answers are commands:

```bash
./pl reclaim report                  # every shoot: originals, decisions, caches, finished work
./pl reclaim reclaim <shoot>         # take back derived bytes only (--apply to do it)
./pl archive push <shoot> --apply    # the RAWs up to iCloud Drive, read back and verified
./pl archive drop <shoot> --apply    # remove the local RAWs of frames proved to be up there
./pl archive pull <shoot> --apply    # bring them back down
./pl reclaim verify <shoot>          # the originals against their stored checksums
```

`push` copies and verifies and deletes nothing, finished shoot or not, so a
card's RAWs can be backed up the night they are copied. `drop` is the one
that frees space: it refuses a shoot that is not marked finished, because an
unfinished shoot's RAWs are about to be read again, and it refuses any frame
it cannot prove is readable up there.

Two things here are not what they look like. A file iCloud has evicted still
has its path, its size and `Path.exists() == True`, and the bytes are gone
until something reads it and waits for the network; only the allocated blocks
tell the truth, and the panel's "evicted" states are that reading. And a RAW
has up to four names in a shoot — `raw/`, a pick, `edit/`, a reel — so
removing one frees nothing; `drop` removes them all and says how many it took
to free one frame.

The panel shows a cell per copy, this Mac then iCloud, in seven states: here
and up, iCloud only, evicted there, evicted here, here only, no bytes behind
the name, missing. The last two are holes rather than untidiness and they
colour the heading. Nothing destructive happens on a click: the app asks the
command for its plan, shows the list, and carries that plan's token into the
button, so a list that changed underneath is refused rather than applied.

## 8. Doing it all at once

Most of these steps take minutes you do not have to sit through. In the app,
every step's button says whether it does the work now or adds it to the
list, and ⌥ on the button always adds; **Up Next** in the Activity window
(⌥⌘L) holds what is running and what is waiting, in an order you can drag,
with hold and remove. So a card of 1,500 frames can be stacked up in one
pass — copy it, cull it, write the presets, gather the keepers, push the
RAWs — and left.

The list is written to `queue.json` in the app's support folder and read
back at launch, so it survives a quit. Nothing on it is checked until the
instant before it starts, and then it is built again from what you asked
for: an item that can no longer run is skipped with the engine's own
sentence, and the rest of the list carries on. You are told once, when it
empties.

The three storage steps that remove photographs — `archive drop`, `archive
expire` and `reclaim reclaim` — can never go on it. Each runs against a list
you read a moment before, and an hour later that list is about a shoot
nobody has looked at since, so the answer is no rather than a confirmation
nobody measured.

## Timing, 300 frames

| Step | Minutes |
|---|---|
| Copy the card | 3 |
| Cull | 3 |
| Choose keepers | 5 |
| Presets and sidecars, keepers only | 1 |
| PhotoLab: open, look, export | 15 |

Copying scales with the card, not the frame count: the cards read at about
95 MB/s, so 27 GB is roughly five minutes a pass.

## If something goes wrong

| Problem | Do |
|---|---|
| "no preview" for frames | The RAW's embedded preview is missing; rare. Those frames still export if rated by hand. |
| A frame the judge rejected that you want | Keep it in the light table, or `--keep TSC01234.ARW` on the cull. |
| PhotoLab shows no preset on any frame | File → Sidecars → Import. |
| Sidecars exist from an earlier session and you want the pipeline's | `./pl presets <raw> --dop --force`. Sidecars with your own edits keep them, with the pipeline's Base refreshed underneath; `--mine-too` replaces those too, so be sure. |
| Card not detected on ingest | Pass the DCIM folder directly: `./pl ingest /Volumes/CARD/DCIM name`. |
| A shoot's stars or answer key seem to have gone | They are in `decisions/` now. `./pl migrate <shoot>` (dry run) says what it would move and what is already moved; the old `cull/` names are symlinks. |
| PhotoLab opens an archived shoot and hangs on the first frame | Its RAWs are in iCloud and evicted. `./pl archive pull <shoot> --apply` brings them down first, rather than downloading them one blocked read at a time. |

## Extensions

A folder beside this one (or wherever `PIPELINE_EXT` points) can add one
more kind of shoot with steps of its own and its own list of moments for
the third pass. The app picks it up when it is there and asks one
question at the start of a shoot; without it, nothing is different. The
contract is in the README under Extensions.
