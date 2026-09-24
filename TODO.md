# What is not done

Written down because a repository that only says what works is not honest about
what it is. Each of these is something known to be missing or wrong, not an
idea. Where there is a measurement behind it, the measurement is here.

## Nothing learned on this Mac has passed the check yet

Three things are meant to be fitted to the person using it, and since this
release they learn only from the frames that person exported: a keeper is
where the editing starts, and the author culls further in PhotoLab. The
keeper check still counts every keeper. **Nothing learned here has been put
into use**, and the learning page says why for each, in the check's own words.

- **The starting edit.** No version learned from exports alone has been fitted
  on the author's Mac yet; the next learning run fits one. Its count no longer
  holds it: 436 exported frames against at most 156 of the 527 the version in
  use was counted with, both by the same rule. The last version fitted, under
  the old rule, was held on 2026-09-23 for its white balance on the shoot
  2026-09-21: right on 21 of that shoot's 38 finished frames, where leaving it
  alone is right on 29.
- **2026-09-05-the-gals teaches nothing.** It is the 198-frame portrait shoot
  of the README's table. No export of it is recorded anywhere: none was found
  when it was measured, and the learning store holds none. Under the old rule
  it taught all 198 of its finished frames; under this one it gives the
  starting edit no look, no face target and no exposure type, and its 12
  keepers do not stand in. Finding its exports — in its own `export/`, or in
  iCloud Drive and newer than its RAWs — is what would put it back, and
  finishing it again then writes them down for good. Bringing its RAWs back
  from iCloud does not, on its own.
- **Why a frame was dropped.** It cannot train yet: a reason needs twelve
  examples across at least two finished shoots, and the labels so far are six
  for blur, and twelve for framing and twenty-four for face all on one shoot
  (`composition` and `expression` in `labels.json`). The only candidate is the
  seed in `models/flaws.json`, and the keeper check holds it because it would
  stop putting sixteen keepers forward. Starved, not wrong: more labelled
  drops on more shoots is the fix.
- **Which frames of a burst come forward.** Held: it would show 81 keepers
  later in their burst and 35 earlier, none hidden. It has rankers for two
  shoots (0.61 and 0.66 held out by burst); a third is at chance and is not
  kept. It still only changes when a shoot is culled again, because it reads
  `cull.csv` and the keepers rather than the measured store.
- **Exposure type per venue** is built and used nowhere yet. It may only be
  used on the shoot that taught it, after beating both the rule and that
  venue's commonest type held out by scene; `docs/ML.md` has the table. The
  one venue where it clearly won (the portrait shoot above, 72 frames to 13
  against its commonest type) was measured on its finished frames under the
  old rule, and with no exports it now has nothing to teach. Letting a fit
  reach a **new** shoot would take venues that span several shoots and a fit
  that wins held out by shoot; nothing measures that yet.

What already works: what the pipeline measures is kept beside the models, so a
shoot goes on teaching after its RAW files are archived; a finished shoot's
exports are written down when it is finished, so it goes on teaching after they
move; a candidate is replayed over every keeper before it is used; and the page
no longer says "Not in use" over a model that is.

## Checked only where no window opens

Every one of these was tested and rendered offscreen, and none of them has
been looked at in a real window, with a real pointer, trackpad and keyboard.
They need a person at the Mac.

- **The move from Photo Pipeline.** The author's installed copy has migrated
  to First Edit, with the old support path retained as a link and a backup
  kept before the move. The temporary-folder migration tests cover refusal
  while the old app is open and conflicting support folders; those edge
  cases still need checking on a separate clean Mac. `RELEASING.md` records
  the installation and rollback procedure.
- **The Instagram editor.** Dragging and sizing a cut by its corners, pinch,
  the scroll that steps photographs, Space, Esc and Return, 1:1 following a
  cut the keys move, and the editor's bars folding at the minimum window have
  been driven through the step's model, its key table's tests and the
  `instagram-*` snapshot scenes, never by hand.
- **Reels from the keyboard.** The page now reads its keys from anywhere in
  its window, as Choose Keepers and Instagram do; that path is driven in the
  tests through the monitor's own handler, never by a real key in a real
  window. Two things there need a person at the Mac: E, R and Space pressed
  while the bursts list has the keyboard, with ↓ still walking the list; and
  ⌘Z in a frame opened large, where Q and U are known to work but ⌘Z depends
  on AppKit handing the key past Edit ▸ Undo, which the page greys while the
  frame is open.
- **The rest of what is new since v0.1.3.** The reopen-where-you-left-off,
  the Frame and View menus, the window minimum and the Reels page were checked
  with tests and offscreen renders; the Reels player has never been seen
  playing a frame offscreen, and the window's real minimum size has not been
  read off a real window.

## The app

- **The private extension's organizer page.** Its shared one-handed keys are
  implemented and checked. Real-window verification remains for the People
  card's focus ring and whether Command-Z reaches the page before the native
  Edit menu; Q and U use the page's undo directly.
- **Reels:** the page gives no running time for the reel, because that is the
  private reel maker's own arithmetic; the lister already returns it as
  `seconds` and the app does not read it. The wait on PhotoLab walks the
  export folders on every poll, and that walk is in the private module.
- The light table's snapshot scenes are not deterministic — the same scene name
  renders a different burst run to run, which makes before/after image diffs
  useless for them.

## Publishing

- **Public source and build dependencies are published.** The repository is
  public as `nickcupo/first-edit`, with a single source commit on main. Both
  locked OpenCV wheels are published under `opencv-5.0.0.93-nogpl`; their
  SHA-256 values match the dependency lock. The source release does not include
  the experimental edit models or mask enhancements.
- The first First Edit install on a Mac that had Photo Pipeline is made by
  hand from the GitHub release; updates across the bundle identifier change
  are deliberately refused. `RELEASING.md` covers signing and notarization.

## Measurement

- Everything is measured on four shoots, all the author's, all one camera body
  and one editor. Nothing here shows a threshold transfers to another body,
  another lens, or another person's taste. `tests/eval.md` and `tests/bench.md`
  are those measurements and cannot be regenerated without the photographs.
- The face checks are measured against 94 verdicts settled by eye. That is a
  small answer key.
