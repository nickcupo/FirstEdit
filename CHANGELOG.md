# Changelog

## Unreleased

Every frame's starting edit now carries its own color: flatter frames get
more Vibrancy (toward the ×1.10–1.15 lift preference studies find), vivid or
clipping frames none, skies and foliage move toward their preferred colors,
and skin stays under its published ceiling. How far a DxO slider moves color
is an estimate, and each frame's note says so. A face mask now only nudges:
it is written for a face at least ¾ stop short and lifts it at most half a
stop.

Exposure now does something on every frame. A frame with no face has its
midtones taken toward middle grey in daylight and a lower target as the light
falls, so night stays night; a face under the published band is lifted
globally toward the band's middle, never past L* 58. Every lift stops at the
highlights' headroom measured on the RAW, at 1.5 EV, and before the noise at
the frame's ISO would double past 12,800; a face that still needs more gets a
gentle mask.

Where a frame's exposure and contrast aim is now learned from your finished
exports. Learning reads each export's median lightness, its tonal spread and
its largest face's lightness, and fits a small model for each of the three
from what the camera and the RAW show: the light level, ISO, how bright and
how spread the camera's frame is, whether there is a face and how light it
is, and the highlight headroom. A model is used only when, tested on shoots it
never saw, it lands at least 10% closer to your exports than the built-in
rules on the same frames, and closer on more frames than chance would give.
Otherwise the rules decide, as before. A frame with no face aims its midtones
at the predicted lightness. A face aims at its predicted lightness, held
inside the published band and never past L* 58. The S-curve's strength is
solved per frame to give the predicted spread. Every limit on a lift still
applies. Each frame's note says whether your exports or a rule set its aim,
with the held-out error beside the rule's. The learning report and the
learning page name what is learned, and the check holds a new version whose
model is worse than the one in use on the same frames. The first learning run
reads each export's tones once, and remeasures each finished frame whose RAW
is on this Mac once to record its light level and headroom.

Every frame's note now reports how colorful the camera's rendering is and
where any sky or foliage sits against preferred memory colors, and the scene
notes read the room's grey with faces left out. Skin and grey are measured at
full precision instead of whole CIELAB units, the camera frame and your
exports read a face on the same patch, and the white balance model can use
the camera's green–magenta reading once every frame it learns from has one.
Nothing else a sidecar carries changes.

Every command now finds a shoot's folders by one rule, and takes the shoot,
its `raw/` or its `cull/`: the RAWs in `raw/` or loose in the shoot, the cull
in whichever of `cull/` and an old `_cull/` holds cull.csv (anything new is
`cull/`). A frame the cull named by its camera JPEG gets its sidecar beside
its RAW (`TSC04016.ARW.dop`) rather than a `.jpg.dop` beside nothing; existing
orphans are counted and left in place.

## 0.1.5

The app now displays **FirstEdit** in its windows, menus and About panel.
The installed `First Edit.app`, support folder, settings identifiers and saved
work stay where they are; this spelling change performs no data migration.

Cull suggestions now stand out with a purple star and **Suggested** badge in the
filmstrip, beside the main photograph, in Compare and in the Full Image controls.
Your own Keep and Drop marks take precedence. Suggested stack members remain at
full brightness; the cull's choices and keeper rules are unchanged.

Keeper counts now distinguish explicit Keep marks from cull picks accepted while
reviewing. Sidebar progress names bursts, and the optional preset switch calls
unselected photographs the other frames instead of claiming you dropped them.
The preset headline describes the selection, including existing sidecars.

The learning-watch check now waits for the new watcher and its job title before
judging cancellation, avoiding a fixed-delay race on busy machines.

## 0.1.4

The source was published as one commit on 2026-09-24. The Mac installer and
its notices are distributed through the GitHub releases page. The older 0.1.3 section is a
historical record from before the rename.

Opening keepers now handles culls whose frame names refer to JPEG previews,
using a uniquely matching original and that original's own sidecar. Ambiguous
names or originals found only in the existing edit folder stop the rebuild
before it can change your work. Missing-file messages no longer assume there
is an archived copy.

The release checks now cover the factory white balance on machines without
PhotoLab, full process names on Linux, and icon asset compilation.

Apple silicon Macs, **macOS 15 or newer**: the app is a Swift package built
for `.macOS(.v15)`, and building it needs full Xcode with an SDK of 26 or
newer. A checkout needs Python 3.12 exactly; `setup.sh` refuses anything
else, because `requirements.txt` is pinned to it and mediapipe has no wheel
past it.

**Photo Pipeline is now First Edit.** The app's name in the menu bar, the
window, the About box and every sentence that names it; the bundle
(`First Edit.app`, identifier `com.nickcupo.firstedit`); the disk image and
its notices (`First-Edit-<version>.dmg`); the Swift executable target
(`FirstEdit`); the support folder (`~/Library/Application Support/First Edit`);
the evaluate cache (`~/.cache/first-edit`, or the old one where it already
is); the notary profile label in the docs (`first-edit`); and the GitHub
coordinates. The update check, Report an Issue, the security page and the two
OpenCV wheels in `app/requirements.lock` all name `nickcupo/first-edit`, with
the same hashes. The repository was renamed and made public under that name on 2026-09-24.

The first launch moves an existing install across. It swaps the old
support folder's name for the new one with a link at the old path in a
single step, so nothing is copied and nothing writing through the old path
at that instant finds it missing; it imports Photo Pipeline's settings once
and never writes to them; it writes `MIGRATED.json` with the steps to undo
it and what an undo does not put back. It does nothing while Photo Pipeline
is still open (and says so), says so again and offers to quit it if Photo
Pipeline is opened while First Edit runs, and does nothing when
`PIPELINE_SUPPORT` is set. If both folders exist it merges nothing and says
where the other one is, in an alert as well when First Edit's has no models
or nothing learned and the other has. A checkout run with no environment
finds the folder through one resolver, new name first, where six places used
to spell out the old path. Lightroom, RawTherapee and darktable sidecars
written under the old name are still recognised as ours and refreshed.
Extension commands are now handed `PIPELINE_PUBLIC`, the engine's own
`pipeline/` folder; nothing set it before, so an extension found the engine
by guessing at a checkout beside it. The first First Edit build has to be
installed by hand: the updater refuses an app whose bundle identifier
differs, and this one does (`RELEASING.md`, "Once: from Photo Pipeline to
First Edit").

Kept on purpose: the iCloud Drive folder `Photo Pipeline Archive`, through
which every archived RAW is found; the git config key
`photopipeline.vocabfile`, because a renamed key would switch the vocabulary
check off without a word; `PipelineKit`, `pipeline/`, `./pl` and the
`PIPELINE_*` variables, which name the engine and not the product; the
extension contract (`window.pipeline`, `pipeline-ext://`); the `Info.plist`
key `PhotoPipelineBuild`; and the folder names on disk.

**The app is the product, and the browser page is retired.** First Edit is a
native Mac app, not a window around an HTML page. `pipeline/studio.py` is the
engine behind it: JSON routes on 127.0.0.1, the jobs behind each step, and
the list of work they wait on. `./pl studio` still starts it and prints the
address it chose; what answers at that address is a few sentences saying to
open the app, and the key is no longer handed out there. An extension's own
step is drawn by loading its page through a scheme handled inside the app,
which is what lets the app put the per-launch key on every subresource that
page asks for.

**Nothing is hidden for looking alike.** A group of near-identical frames used
to show one frame and hide the rest, and 65 of 773 keepers over the shoots it
was measured on were among the hidden. Frames that look alike are stacked
instead: a contiguous run inside one burst, linked from how much this card's
own consecutive frames change rather than from a fixed threshold. A stack is
drawn as a bracket, its top is the cull's guess and is tiered like any other
frame, and every other member stays on the page set aside under it, one key
away. `--style action` no longer decides what is hidden; it decides that two
frames of a stack reach the shortlist instead of one. Only a fault the cull
can name is hidden now, and `cull.csv` writes no rating of 1.

**Choosing keepers is one burst on one screen, under one hand.** The right
hand is on the mouse, so everything a cull needs sits under the left: E
keeps, D drops, S and F step back and forward through the frames and on
across bursts, R and W go to the next and previous burst, Q undoes, X clears
a mark, C compares the frames of a stack, Z is 1:1, G is every burst at a
glance, Space is the whole picture, ⇧E keeps only this one and 1–6 say why a
frame is out. K, N, P, U, 0 and the arrows go on working beside them, and
every place that teaches a key — the menus, the Keyboard Shortcuts window,
the help tags, the line at the end of a burst — names the left-hand key
first. A Keep or Drop on a burst's last frame goes on into the next burst
unless Settings ▸ Choosing says stay, and Next Burst on the last burst reads
On to Presets and goes there. A scroll over the photograph steps frame by frame as the
arrows do, one notch or one flick a frame, and ⌥-scroll steps the cull's
picks. No key that writes a verdict repeats while it is held: a held K wrote
three frames that had never been on the screen, in 90 ms. What the cull
decided and what the photographer decided are kept apart everywhere and
never added together. A second display holds the frame at full size and can
never take the keyboard, so the verdict keys cannot go dead because the
picture window has focus.

**One key, one meaning, on every page with photographs.** The keys above are
not the light table's alone: Instagram, Reels, the viewer a frame opens in,
the learning review and a presentation on the other screen read the same
table and say only what each key does there. On Reels, E puts a frame in the
reel and D leaves it out, each moving on, X puts it back, S and F move, R and
W change burst and Q, U or ⌘Z undoes, where the grid used to tick with X and
had no undo; its keys work from anywhere in the window, the bursts list
included, with ↑ and ↓ left to the list while it has the keyboard; and Q in a
frame opened large takes the mark back off the page's own undo. S is the
previous cover in All Bursts. The viewer, the review and a presentation move
on S and F as they did on the arrows, and a presentation steps only on a
plain arrow. The Keyboard Shortcuts window opens on the one scheme, a row a
meaning, and `KeyParityTests` fails the build when any page reads a key
differently.

**A shoot keeps teaching after its RAWs are gone.** Fitting the starting edit
needs numbers off each finished frame, and those need the RAW on the disk, so
they are measured once and kept, one line per frame, in `measured.jsonl` in
the learned folder. Before this, the first run after an archive learned from
283 finished frames where the model in use had 527, and was rightly held for
being smaller. Everything learned lives in one writable folder — never the
repository, never the signed bundle, which is how the app came to read a
starting edit baked in at build time and learn nothing for as long as it was
installed.

**Only what you exported teaches.** The starting edit, the tier order and the
drop reasons take their examples of your taste from the frames you exported,
not from every frame you kept, because the cull goes on in PhotoLab: a keeper
is where the editing starts. The keeper check is unchanged and still counts
every keeper, so a frame you kept and then passed over in PhotoLab is still
one no learned model may hide. **Finish This Shoot** writes down what you
exported (`exported.json` beside the answer key, a record that only grows);
a finished shoot teaches that, what is found today, and what the learning
store recorded of its exports when it measured them, and never its keepers.
An export counts for a frame only between the frame being taken and the
camera next using that number, because the camera reuses its numbers. On the
author's library that is 436 exported frames of the 838 the starting edit
has measured, over four shoots; the fifth, a 198-frame portrait shoot, has
no export recorded anywhere and teaches nothing until its exports are found.
The check still holds a starting edit that learned from fewer frames than the
one in use, and now counts the one in use by the same rule: the one that came
with the app counts 527 from when every frame of a finished shoot taught, and
at most 156 of them are frames you exported, so a version learned from your
436 is no longer held on its count. A starting edit keeps the frames it was
fitted on, so the next one can be counted again frame by frame; an older one
is counted shoot by shoot, the one in use at the most it could be and the
version weighed against it at the least. One that kept nothing to count by is
weighed by the old rule on both sides, and a count that cannot be made falls
back to that rule instead of failing the learning run. Going back to the edit
that came with the app is weighed the same way, and is held on its count once
a version learned from your exports is in use. The check's sentence says both
numbers and how each was counted, and the learning page no longer asks you to
settle the count yourself.

**Nothing learned is used until it has been checked against every keeper.**
A new model is a candidate. It is replayed against every keeper of every shoot
that carries a verdict, through the live model and the candidate, dealing the
tiers both ways with the same code the cull deals them with, and it goes live
only if no keeper moves out of sight. Anything else is held with those frames
listed one by one. A candidate's own score is not that check: a drop-reason
model retrained on 44 reasons scored AUC 0.90 and 0.97 held out, and would
have hidden 15 keepers.

**Up Next.** Every step's button says whether it does the work now or adds it
to Up Next, the list of work, and ⌥ always adds. Up Next, in the Activity
window, holds what is running and what is waiting, in an order that can be
dragged, held or emptied; it is written to `queue.json` and read back at
launch, so a list filled at midnight is there in the morning. Each item is
built again from what was asked for in the instant before it starts, so an
item that can no longer run is skipped with the engine's own sentence and the
rest carries on. Stop holds what is still waiting instead of starting the
next item at once; a job the engine went down under goes back to the top,
held, where it used to disappear; an empty list can be held, so an evening
can be stacked up before it starts; the Activity window keeps three days of
finished work across quits and opens on what you have not read; and the Dock
shows a bar while work runs, with a badge only when something has failed.
Nothing that removes photographs may go on it — `archive drop`, `archive
expire`, `reclaim` — and the refusal is a sentence rather than a hidden
control, because each of those runs against a list that was read a moment
before.

**`./pl cull --learn` and `--taste` are retired.** They fitted one set of
ranking weights to one shoot's picks and applied them to every later shoot of
every kind, and taste does not carry between shoots that way. Both exit with a
sentence saying so. The weights are `quality.DEFAULT_WEIGHTS`; what learns
now is a ranker per venue that reorders a burst and nothing else, and it has
to pass the keeper check like everything else.

**The bundle ships no GPL library.** The published OpenCV wheels carry an
FFmpeg configured `--enable-gpl` and linked against libx264, libx265 and four
more GPL-2.0-or-later libraries through load commands that cannot be removed,
so `app/tools/build-opencv.sh` builds the same version of
`opencv-python-headless` and `opencv-contrib-python` from source with
`-DWITH_FFMPEG=OFF`, and `app/requirements.lock` names those two wheels by URL
and by SHA-256. A checkout's own `.venv` keeps the PyPI wheels, and the two
builds are proved to cull a shoot to the same byte-for-byte `cull.csv`. The
wheels themselves are not uploaded anywhere yet (`TODO.md`).

**Instagram is a step of the app.** Every build has it, between Edit in
PhotoLab and Reels; it used to be a page of the private extension. It is one
wall of the shoot's exported photographs — the ones Edit in PhotoLab counts
as exported, each cut from the finished still rather than from a later reel
export of the same frame — with every cut drawn on it: the cut clearly, the
other shape faintly. The cuts are worked out in the background the moment the
step opens, one pass at a time, standing aside for any work of yours and
picking up again after it; the photographs the profile grid would lose the
subject in come first. Portraits are cut to 3:4 at 1080 × 1440 or to 4:5, and
landscapes left whole or cut, from two pickers. The keys are Choose Keepers'
own, read from the same table with no second one: S and F or the arrows to
move, E or K to include, D to leave out, X to clear, Space to open the editor
and close it, Z for 1:1, Q or ⌘Z to undo and Esc to go back, and a scroll over
the open photograph steps photographs as it steps frames there. The editor
adds A (the automatic cut), T (cut or whole), V (the result) and − and =
(smaller, larger) for what Choose Keepers has no key for, and the Keyboard
Shortcuts window lists them. With nothing included, every photograph not left
out is made. Make N Copies writes exactly the cuts shown, into
`<shoot>/instagram`, and goes on Up Next with ⌥ like every step's; an item
left there skips any photograph exported again since, and names it, rather
than making a cut you never saw. A cut changed on a copy already made is made
again at once. From a checkout, `./pl instagram <shoot> --all --plan` works
out every cut and writes the record without making a photograph, and a run
given no `--ratio` and no `--landscape` then makes what was worked out rather
than falling back to 3:4 with landscapes whole.

**It opens where you left off.** Quitting from a step and launching again
comes back to that shoot and that step, with the shoot expanded and scrolled
into view in the sidebar; the first page drawn is already the right one, and
the restore only reads — it starts no job and opens no sheet. A shoot that
has gone, a library folder that has changed or a step the build no longer has
lands on All Shoots or the shoot's own page and says nothing. The library
pages are never saved as the place, so quitting from the learning page
reopens the shoot you were working in. Clicking a shoot opens the step you
were last on in it, ⌘J goes back to Choose Keepers from any page, a step the
engine says is done carries a check in the sidebar, All Shoots has an Up to
column naming the step each shoot is up to, and Go ▸ Storage is ⇧⌘S.

**The counts keep up.** Frames, kept and finished in the title, the sidebar
and All Shoots were read once at launch and stood still all evening. They are
read again from the engine at each N, when a job ends and when you leave a
step, one read at a time; the app never works them out itself, because the
engine's "kept" counts the cull's call in bursts you have been through.

**The Frame and View menus work.** Nothing had ever registered their rows, so
both menus were grey from top to bottom. Every row is live while Choose
Keepers is on screen and greyed when it would do nothing, and a row whose key
the light table reads itself (every plain letter, digit and arrow in its key
table, Space, ⇧E) leaves that key to the light table, so the repeat rule and
the on-screen check still hold.

**The whole evening, gone over for use.** Twelve passes, one per part of the
app, each measured against what a real evening asks of it. A card is read the
moment it goes in, and its copy carries on from any page and waits on Up Next
behind other work; a copy that did not finish says so and opens the card's
page. The cull's report gives faults, fine frames and stacks a line each, and
a cull that crashed says in red that nothing you marked was changed. On the
light table Keep and Drop no longer wait for the engine, ⇧⌘Z puts back what
⌘Z took and Edit ▸ Redo names it, a reopened burst lands after the furthest
frame you marked, every key reaches the light table by one path in every
view, Full Image fades in and out, a held arrow stops at the end of a burst
with one bounce, only one line sits over the photograph at a time, and a click
in the filmstrip goes to its frame every time. The Presets, Edit in PhotoLab
and Finish pages say what their last run did and what a press will do; every
Shoot menu row presses its page's own button from anywhere, and a button that
will only add to Up Next says Add to Up Next. The sidebar, the toolbar, the
Activity window and the page shown while the engine is down say what is
happening in plain words, and a right-click on a shoot offers its own rows.
What the Cull Has Learned and the storage panel follow the job they started
until it ends. Settings, the welcome pages and an empty library choose a
folder through one picker, and a restart asks before it stops your work.

**Twelve questions, answered.** A review of the app in use set aside
sixty-nine findings, and they came down to twelve questions for the author;
the answers are in this release. The ones that belong to a part described
above are said there: the keys and what a Keep on a burst's last frame does,
learning only from exports, Up Next, and where the app opens. The rest: a
frame's sharp picture comes up at the camera's brightness on screen, where it
went about 40% darker, and the cull's own reading is unchanged. A new burst
opens at Fit; Compare marks its sharpest frame, and Keep Only This One there
closes it and moves past the stack; a reason's digit pressed twice on a kept
frame puts it out; Keep and Drop stay where they are when the inspector opens,
which has no Keep or Drop of its own any more; and a fault in the cull report
— eyes closed 131, say — opens those frames to look through. After a card
copy the cull starts by itself with the focus and People move settings of
your last shoot; a copy that stopped finishes into the same shoot, copying
only what did not arrive; and a second camera's card can join the night's
shoot until it is culled. Return on Presets opens your keepers in PhotoLab,
and each page's main button is at its bottom right, once. Copying a shoot's
RAWs to iCloud works any night, finished or not, and nothing uploads by
itself: "Copy new shoots to iCloud" is gone, and removing the local RAWs
still waits for Finish. The Settings rows that did nothing work — the cull's
own marks in the filmstrip, the let-go days, both learning switches — and the
switch for tips that were never drawn is gone. Every word on screen is
spelled the American way, as the Mac's own menus are; one picture is a frame
everywhere; drop reason 3 is "face"; and the reel format that pushes in on
the moment is called Push In.

**Smaller things that were wrong.** The window can be made as small as the
documented 900 × 620 and the light table fits it (it ran 26 pt off the
bottom); the frame numbers under the filmstrip are no longer painted over by
its scroller; ⌘J goes to Choose Keepers even before the shoot has loaded; ⌘N
opens the card's page; ⌘E ejects off the main thread and is greyed while a
copy is running or waiting; a refused Eject or Show in Finder is said at the
foot of the sidebar instead of nowhere; a library that cannot be read says
why with a Look Again button instead of spinning. Choices made once are kept:
the editor chosen at first run is the default for a new shoot, Settings picks
the editor by name, "Eject after copying" is remembered, and so is how the
copy is checked — except "Don't check", which is never carried to the next
card.

**The Reels step has a page.** A build that carries a reel maker shows a
Reels step: the bursts on the left (searchable, by number or best first, each
saying how long it lasted and with a dot if you kept a frame of it), the last
reel playing beside the burst it was cut from, every frame of the burst under
it to tick in or out, and format, speed, crop, size and source on the right.
It opens on the burst you were on in Choose Keepers, and in a window narrower
than 1280 points it puts the sidebar away. Frames not exported yet are dimmed
and labelled, and the page says before anything is pressed whether the reel
will be cut from your exports or be a draft off the RAWs. **Write Presets and
Open PhotoLab** writes the shoot's own preset beside every frame of the burst
that has no sidecar — your edit is not copied, and a frame you edited is left
alone — then waits for your exports and cuts the reel itself once they have
arrived and stopped arriving; it counts from what was already exported at the
press, so frames that were there before cannot set it off. It stops with a
sentence if the presets are refused; otherwise it keeps watching — every 5
seconds, then every 30, then every minute the longer nothing new comes —
until the reel is cut, you stop it, or the app quits. The public build carries
no reel maker (the author's is private), so the step does not appear in it.

**The learning page says what is true.** Each learner says what is in use
and what it was learned from; beside it, a newer version held back and the
check's reason; and under that, what it is short of, as things you can do —
"6 more frames dropped for blur", or a Measure button for a shoot whose
picture vectors were never kept, where the page used to name a terminal
command. It used to print "Not in use" over a starting edit that was in use,
and the held version's source over the wrong row.

**Exposure type is learned per venue, and used only where it was learned.**
One model of which exposure mode to use, pooled over five venues, was right
on 0.665 of held-out frames, worse than knowing which shoot you are in
(0.732), and it was retired. What replaced it is a fit per venue, held out
by scene inside the venue, used only where it beats both the rule and the
venue's commonest type, each by a sign test, and only on the shoot that
taught it: a new shoot that merely measures like a venue is one the fit was
never scored on. On the author's library no venue clears that bar yet. The
one where the fit clearly beat the commonest type is the portrait shoot with
no recorded exports, so under the rule above it has nothing to teach until
they are found. `RULES_VERSION` is 4, so every check made under an older bar
is made again.

**The burst order learns from the score the check uses.** Its flaw feature
read exactly zero on the three newest shoots — 723 of 774 keepers — because
those were culled by an installed app whose bundle carried no drop-reason
model. Training now reads the same recomputed score the keeper check does, and
the burst order takes its venues from the newest starting edit, so a starting
edit held for its white balance no longer stops it learning.

**`./pl selftest` asks the scripts themselves.** One of its checks reads the
command lists out of the engine and asks each script's own `--help` whether
it takes every flag those lists pass it. It exists because a button once said
"Standardise the whole burst & open in PhotoLab", the endpoint passed neither
flag, and the script in the shipped bundle had neither to pass. The check
that ran `node --check` over the browser page went with the page, so the
self-test is nine checks, 9 of 9.

## 0.1.3

Tagged on 18 September and never released: there is no GitHub release behind
this tag, and the app was rewritten as a native one afterwards. What follows
is the record of what the tag held.

Apple silicon Macs, macOS 14 or newer. Signed and notarized. Drag Photo
Pipeline into Applications and open it; on first launch it fetches the
picture model (CLIP, 1.7 GB) once. From this version the app offers updates
itself.

**The starting edit is measured, not guessed.** Each keeper's RAW is read
in linear terms: the largest face's luminance, the subject's, the frame's,
and the share of photosites at saturation. Exposure follows from that
(nothing saturated: by hand, the stops between the face and the band the
photographer accepts, after the 1.3 EV DxO's rendering itself adds;
something saturated: the auto mode, Medium for a dark face, Strong
otherwise), and any face the global correction leaves outside the band
gets its own AI mask, written the way PhotoLab writes them. The regression
from image features to slider values is gone: on the one shoot it was
learned from every manual bias was a single paste, and on the next venue
the photographer reset every value it wrote.

**Finished shoots are venues.** `./pl taste` learns only from finished
edits (a frame exported, or a shoot marked finished on the studio's new
Done card): per venue, its measurement centre and spread, the preset its
sidecars started from, what was set the same way on most frames (a
rendering, ClearView off, a channel-mixer nudge pasted across the shoot),
the band of face lightness accepted there, and the exposure type where
near-unanimous. A new shoot inherits a venue's look only if it measures
inside that venue's spread; otherwise it starts from DxO's own camera-body
rendering (`2 - DxO Standard`) with a partial sidecar carrying only what
was decided. A sidecar merely opened and tried on teaches nothing.

**The rendering is chosen for the subject, not copied from the camera.** A
shoot with faces starts from DxO's own portrait colour rendering. Until now
every sidecar carried `Original`, which instructs DxO to reproduce the
camera's own colour — learned from 291 finished edits, and the reason skin
under a gym's lights came back warm. Put side by side on four frames with
everything else held constant, the photographer chose Portrait V3 over
Original, Natural, Fidelity and Portrait V2, then confirmed it across
eighteen frames of a burst. A pet or a landscape keeps the preset's own
rendering. The channel mixer no longer travels either: DxO ships it on 25 of
its 373 presets and every one is monochrome.

**A burst is levelled so the subject matches the frames beside it.** Lamps on
mains are a different brightness in every frame: at 1/500 the shutter is open
about 2 ms of an 8.3 ms half cycle, and one 48-frame burst measured 1.57 EV
peak to peak with the direction reversing on three steps in four, the camera
answering by moving its ISO between 2500 and 6400. The exposure decided from
the face did not touch it, because a frame inside the accepted band is left
alone and two neighbours 0.9 EV apart can both be inside. Each face is now
brought to the median of its own burst, clamped to that burst's own spread:
face lightness across that burst goes from a spread of 44 to 9. A shoot whose
light holds still measures no spread and gets no correction.

**White balance is left to the camera, on measurement.** Across that same
burst the camera's own per-frame decision holds the room's near-neutrals to a
spread of 1.46 b\*; one fixed temperature on the same frames spreads them
4.58. The camera is compensating for the flicker, not fighting it. A
computed per-frame value is not available either: an estimate from a frame's
own pixels inverts when a warm subject fills it, and the kelvin a face's
colour implies varies 58 to 200 K per b\* between frames of one shoot.

**The HSL slices the photographer moved are read at last.** The reader
expected the fields in the order the preset template writes them; PhotoLab
writes them alphabetically, so every slice the photographer had ever moved
was invisible to the learner — 438 sidecars' worth. A slice is read by name
in any order now, and a value under half a point is not a decision (a paste
carries the source frame's whole table).

**White balance is a decision, AsShot or a named preset, per frame**,
learned from 492 decisions across two venues (AUC 0.97 held out by scene,
by burst where a shoot is one scene), and written only inside the range of
camera as-shot temperatures where the photographer actually chose it, so a
venue where they never did is never given one.
No kelvin or tint is written: DxO's temperature scale is not the camera's
(one eyedropper calibration point, 420 K apart), and computing one is what
turned people red. Skin is measured and reported against the published
preferred range, never corrected.

**Lens corrections are DxO's, and they are on.** Every Base carries the
lens-correction block exactly as DxO's own `2 - DxO Standard` preset does
(distortion, lens vignetting, chromatic aberration and lens softness, each
on and in Auto, from the optics module), read from the installed PhotoLab
when there is one. For a while they were left out on the theory that a
partial sidecar lets DxO fill them in; a sidecar imported without them
opened with distortion correction off. What PhotoLab writes into
Overrides on merely opening or importing a file (the gain map, crop flags,
the lens block, temperature and tint, an untouched HSL table) is no longer
mistaken for your hand, so `--force` refreshes such a file instead of
keeping it whole; and where it kept a file of yours, `--force` now takes
the materialised lens keys out of your Overrides (nothing else) so the
optics module applies there too, and says how many.

**Nothing of yours is destroyed by a re-run.** Hand-edited sidecars survive
a cull; `--force` refreshes only the pipeline's Base under your Overrides
(`--mine-too` replaces the file), carrying the exposure you ended up with
into the new Base and taking the newest of your copies by the date
PhotoLab wrote inside it, not the file's; a copy in picks/ or edit/ that
holds a different edit of yours is left alone; every other copy of a
frame's sidecar is kept identical; `gather` carries edits made in `edit/`
back beside the RAW; the answer key (`selects.json`) writes itself from
your stars and exports and refuses to shrink by more than half in one
write. The crop writer now emits DxO's `{x, y, w, h}`; it had written
`{x0, y0, x1, y1}`, twice too wide. Masks and crops are written in the
sensor's unrotated frame, which is where PhotoLab reads them; on a
portrait-orientation frame the displayed frame's coordinates put a face
mask on the ceiling. Only the subject's faces drive exposure or get a
mask. Each face is matched to the person it is the *head* of (where a
head sits in a person box was measured on 130 read faces), one head per
person; the subject is the biggest person with a head, and people at
least half that size. So a spectator over the subject's shoulder, a hand
held up in front of the man behind, and a hood the detector half-took for
a face get no mask, while the man facing the lens keeps his even when the
back of the person he is squared up to fills more of the frame. Whether the
landmarker could read a face no longer decides whether it is measured:
on the finished action shoot 151 of 154 exported keepers now have a
measured subject face, against 128 under the first rule. What was decided
on each frame ("face at L* 27 in the raw, 44 rendered: inside 38–66, left
alone") is written to `cull/presets.json` and shown under the frame in
the studio.

**The cull throws out faults and ranks the rest in tiers.** A fault is a
blink with no smile, skin at the clip point, nothing above L* 35, or a
face unreadably soft (under 1.2, or under half the same person's sharpest
frame in the burst): each transfers between shoots at no keeper cost, set
on any three of four and tested on the fourth. Everything that does not
transfer (soft for a portrait at 1.9, a mouth caught open, the burst
quota) is now a note that orders the review and never bins; a fault on a
face behind the subject is a note too, and a soft face in a frame whose
subject is sharp is "focus elsewhere", a choice. On an action shoot that
is 5 keepers lost instead of 33. The survivors are tiered a burst at a
time (clear wins, maybes, probably not; duplicates and faults hidden),
ordered by a ranker learned from what was exported on a finished shoot
that measures like this one, when there is one (never its own, under
`--eval`, so the bench is not in-sample). Where bursts are one frame each
the tiers are cut across the shoot instead. "Focus elsewhere" excuses a
soft face only when the first pass measured something other than the face
and there are burst mates to be relative to; the same-person rule
measures against the person's sharpest frame still standing. For a
finished shoot the exports are the answer key, wherever they were written
(`export/`, a folder inside `edit/`, iCloud), and an export counts for a
frame only when it is newer than the RAW, the camera reusing its numbers.
The cull's "clear win" is a tier, never five stars: the studio, `--xmp`
and the other editors' files write it as 3, as the sidecars already did.

**The cull, mechanics.** Decodes are cached in `cull/decoded/`
(`--keep-decoded` controls whether they survive); `--copy` hard-links
instead of copying; thumbnails come from the camera JPEG (the decode read
16 L* dark); `--decode half` works again; `--burst-floor` is off by
default.

**The machine is used.** The cull's first pass, its face pass, the
sidecar step's measuring and the learner's refit each ran one frame at a
time on one core; they now run a frame per core (three quarters of the
cores by default), CLIP sees a whole shoot's face crops in large batches
instead of two or three per frame, and RAW decoding uses the same pool.
An action shoot of 1,157 frames culls in about a third of the time with
frame-for-frame identical verdicts; sidecars for 154 keepers take seconds
instead of minutes. Workers that cannot start fall back to one frame at a
time rather than to no output.

**The self-test no longer empties PhotoLab's preset folder.** Installing
presets replaces every `Cull ...` preset there, and the self-test's run on
six fetched frames was doing it on every run, taking the scene presets of
real shoots with it. `./pl cull --presets --no-install` leaves the folder
alone, and the self-test passes it.

**The studio** answers only its own page (Host and Origin checked), rejects
`..`, uses the bundled exiftool, puts the frames the face judge was least
sure about at the top of the review, shows what the presets step decided
(per setup, and per frame under its thumbnail), counts a shoot's sidecars
against its keepers rather than every sidecar in the folder (frames thrown
out after a presets run left more sidecars than keepers), counts duplicates
in the cull summary, and has a Done card that marks a shoot finished. A keep,
drop, undo or Done that the server did not record is said so, not painted
as saved; "Re-read what I kept" asks before shrinking the answer key by
more than half. A client dropping a connection no longer prints a stack
trace in the app's log. The updater refuses a release that needs a newer
macOS than the Mac runs.

**Fixed since the tag was first cut:** the studio page failed to load (a
duplicate declaration in the script); the app bundle was missing the
learned-edit file; a frame with no readable white-balance reading was
always sent to Fluo; two settings could be written outside DxO's slider
range; `Id` and `Uuid` were treated as a controlled vocabulary.

**Your decisions are out of the cache folder.** The stars, the drop reasons,
the answer key and the spread ledger live in `<shoot>/decisions/` now, not
inside `cull/`, which Finder reports as gigabytes and which is named and
treated like a cache. `./pl migrate` moves an existing library (dry run by
default, `--undo` to put it back) and leaves a symlink at each old name;
either place is read, so a half-migrated library works. Every file in a shoot
that no machine can rebuild is now written through a temp file, an fsync and a
rename, so a kill, a sleep or a full disk part-way through leaves the old file
whole instead of half a new one. That write resolves a symlink and writes
*through* it: renaming over the link would have put a second, divergent copy
of your stars back inside the cache folder.

**What a shoot costs, and where it lives.** `./pl reclaim report` splits every
shoot into originals, decisions, derived caches and finished work, charging a
frame with four names once. `./pl reclaim reclaim` takes back derived bytes
only, and only when three independent things are true of the file and two more
of the shoot; where the RAWs are gone and the only surviving pixels are a
cached decode, those pixels are originals and are never taken back.
`./pl reclaim verify` reads every original against a checksum recorded beside
it. `./pl archive push|drop|pull` keeps a finished shoot's RAWs in iCloud
Drive: push copies and verifies and deletes nothing, drop removes only frames
it has proved are readable up there, and it removes every name the shoot has
for that inode, because a RAW with four names frees nothing when one is
unlinked. Nothing here trusts `Path.exists()`: macOS evicts a file by leaving
it dataless, with its path, its size and its existence intact and its bytes
gone, so only the allocated blocks are allowed to answer "is this file here".
The studio's Done card shows all of it as a bar with a cell per copy in seven
states, and anything destructive is a plan with a token first.

**`./pl evaluate`.** One command for every measurement this machine can make
about the cull, each with its n and each said with what its data cannot
answer: recall per shoot, which rule threw each frame out (with a row for the
rules that fired on nothing), the ranking within a burst as well as pooled,
blink recall against CEW's closed-eye crops, and the animal gate against every
annotated Oxford-IIIT Pet head. It holds out by shoot, never by frame, writes
nothing inside a shoot, and recomputes from pixels rather than reading a
`cull.csv`, which is only ever a record of the rules of its own day. It found
two things the fixtures could not: one pet head in 3,671 was being thrown out
on a sharpness the judge had never measured, which is fixed, and the blink
rule's misses on CEW split into the smile gate doing its job and the
landmarker not seeing shut eyes at all.

**Who is in a frame no longer depends on the order the card was read.** The
identity clustering is greedy, so its answer was a function of the order the
files arrived in: nine orders of one shoot's 2,950 faces gave nine partitions
and between 50 and 61 people, and the "soft for this person" fault fired on
between 5 and 10 frames with nothing else changed. The faces are now seeded in
an order computed from the embeddings themselves, which gives one partition
under every order tried and the fault on 4 frames, with recall unchanged.

**A sidecar is patched, never rebuilt.** `--force` used to regenerate the file
from a template frozen at one day's PhotoLab, throwing away everything a later
version had put in it. It now replaces the Base, the preset label, the rating,
the keywords, the camera's orientation and this write's dates, and leaves
every other byte alone; `--mine-too` is the only flag that starts from the
template. `Sidecar.Software`
and `Source.CafID` are discovered rather than stamped from a constant: the
version off the newest PhotoLab installed (by the version each bundle
declares, never by its name — a reverse sort of the names puts 9 above 10),
and the catalogue id off the sidecars PhotoLab has already written beside
these frames. Each fallback to a shipped default is reported once per run.

**Third-party notices.** `app/build.sh` generates `NOTICES.md` from the bundle
it has just assembled and fails the build if a dependency will not say what
its licence is. It states plainly that the PyPI OpenCV wheel carries an FFmpeg
built against libx264 and libx265, that those are GPL, that they cannot be
removed without breaking `import cv2`, and that a binary meant for
redistribution needs OpenCV built with `-DWITH_FFMPEG=OFF`. The build now
refuses to proceed while they are there, and says in writing why;
`ALLOW_COPYLEFT=1` is for a local build you hand to nobody.

**The viewer answers the question it exists for.** A cull stands or falls on
whether the eye is sharp, and the page could not ask it: a 6,024 px frame was
drawn into about 1,100 px of window, an 18% view, with no way to get closer
anywhere in the file, so every close call went to PhotoLab to be settled — one
gym shoot has 156 of them and 81 turn on sharpness. The full view has two stops
now: the whole frame, and 1:1, where the box is cut out of the full-resolution
decode with no resampling at all and one source pixel lands on one device pixel
(`Z` or the space bar; shift-arrows or a drag move it, and the centre survives
the arrow keys, so flipping a burst compares the same eye on every frame). Where
the screen asks for more pixels than the decode holds, the caption says the ratio
it actually got rather than printing 1:1 over an interpolation. The cap that was
meant to keep the fit view small was dead code — the decoded file itself was
being sent — and is real: 334,866 bytes at 2,600 px where it was 2,295,531 at
6,024, measured on one frame of the dog shoot. Tiles are served their own
dimensions, so the grid reserves a frame's box before the picture arrives instead
of growing under the cursor mid-burst, and the Size slider no longer quietly
switches the whole grid to full-resolution frames. And the viewer says which
frame it is showing: the label changed on the keypress while the picture took
about 60 ms to arrive, so an arrow then `K` kept a frame that was never on the
screen. Keep, drop and tag wait for the picture to be the one they would act on.

**The self-test checks the page.** `studio.html` is one file with one script in
it and nothing compiles it, so a syntax error there takes the whole app down
silently; a redeclared `const` did exactly that. CONTRIBUTING.md has said since
it was written that `./pl selftest` ran `node --check` over the page, and it did
not — there was no mention of node or of `studio.html` anywhere in
`selftest.py`. It is the ninth check now, every `<script>` block in the page
through `node --check`, passing rather than failing where node is not installed,
and the documented checks are the checks that exist: `./pl selftest` 9 of 9,
`./pl check` 94 of 94, the pets fixture 24 of 24.

**Measured and not shipped:** a larger CLIP, a learned ranker, an
ensemble, a pose model, a dog-sharpness probe, sixteen extra signals, a
per-frame exposure ridge, skin as a white-balance target. `docs/ML.md`
has the numbers.

Contributions are welcome. CONTRIBUTING.md says how to run the checks and
where things are.

## 0.1.2

First notarized release of the Mac app.
