# First Edit for Mac — the design

**This document is the source of truth for the Mac app.** It says what the app is, what each screen
does, what each key does, and what has to be true of it. The code cites it by section number: a
comment that reads `§2.5.2` means the section numbered 2.5.2 here, and that numbering is stable.
`DESIGN-displays.md` is its companion — the same design on two screens — and cites into it the same
way.

**What is being built.** A native SwiftUI/AppKit macOS app. The Python engine and its local HTTP
server are the brains; the app starts that server as a child process, talks to it over JSON and
image routes, and loads every image itself.

**"The page".** An earlier version of this program put the whole interface in a browser page served
by the engine. That page is retired: the engine now answers `/` with four sentences saying which
program this is and that the app is where the work happens. Everything else in this document that
says "the page" means that retired interface. It is quoted rather than forgotten because every
number attached to it was measured against something that really ran, and those numbers are the
argument for most of the decisions below.

**Who it is for.** A photographer shooting events and action — 800–1,600 RAW frames a shoot, in
bursts of 100–300, into a RAW editor — who culls fast, holds keys down, and works on a laptop
trackpad and sometimes an external display. The loop is: copy a card → cull → choose keepers on a
light table → presets and sidecars → edit → export → reels and publishing → archive. The document
says "he" throughout because it was written for one such photographer; read it as the person the app
is for.

**The four complaints this design answers**, in the words they were made in: *"how far apart the
buttons to go to the next one are or how far apart they are to keep/discard an image"*; *"being able
to see a full image for certain situations"*; *"the retraining is confusing"*; *"the duplicate
detector isn't great"*. Everything in §2 that carries weight traces back to one of them. The last of
the four is why there is no duplicate detector in this design at all: similar frames are **stacked**
(§2.5.9), the stack is always fully visible, and nothing is ever hidden for looking like something
else.

**Evidence ids.** Claims tagged `LT-xx`, `FLOW-xx`, `NAT-xx`, `PERF-xx`, `SEC-xx`, `EXT-xx`,
`REL-xx`, `DOC-xx`, `R-x` and `DUP-x` come from a measured audit of the retired page and of the
engine. The audit itself is not published; every number it produced that this design rests on is
quoted here in full, which is what a reader needs.

**The extension.** The app can host an extension that adds steps of its own (§2.16, §3.7). No such
extension is published with this repository, none is required, and the public app is complete
without one. Its vocabulary appears nowhere here, in any form, and a scan over every tracked file
keeps it that way.

---

## 1. Principles

1. **Nothing waits.** A key press changes the picture in the same display frame. Cold RAW decode
   costs 650–720 ms (PERF-01), so the app never asks for a picture at the moment he needs it — it
   asked already. Prefetch is a subsystem, not a nicety.
2. **Nothing moves under the cursor.** The two verdict buttons are in the same place on every
   screen, at every window size, in every mode. Progress replaces a button inside that button's own
   box; it never pushes the page (FLOW-04 measured a 212 pt jump).
3. **He can never mistake Keep for Drop.** They are the same size and weight, 160 pt of clear space
   apart, with the frame's own label between them. In the page they were 16 px apart with a 10 px
   height mismatch (LT-07 / NAT-16).
4. **The machine and he never share a field.** A cull suggestion has a purple star and the word
   "Suggested"; other cull calls name the cull. His verdicts have green checks or red crosses and
   the words "you kept / you put out". Agreement is
   its own third state and never renders as a press he did not make. The one number that combines
   them is labelled for what it decides ("will get a preset"), never as anyone's opinion.
5. **A verdict is only ever taken on a frame that is actually on screen.** Not "loaded", not
   "requested": drawn. Key *repeat* never writes (LT-06: a held K wrote three unseen frames in
   90 ms).
6. **Nothing of his is lost or silently overwritten.** Every verdict is one named undo step. Every
   destructive action is planned by the engine, then applied against the engine's own re-derived
   fingerprint. The irreversible one asks him to type the number of photographs.
7. **A destructive action is never one click and never beside a frequent one.** It lives in its own
   group, below a rule, 32 pt clear of anything he presses in a normal shoot, and has no keyboard
   shortcut anywhere.
8. **Errors land where the action was.** One plain sentence under the control that raised it, with a
   Details disclosure for the technical text. Never a system alert, never a global banner, never a
   Python traceback (NAT-15). A refusal is only ever cleared by the thing that wrote it.
9. **No jargon.** The retired-words list in §2.13 is enforced by CI over the string catalog, the
   menu definitions and the test names.
10. **The app looks like the OS it is on.** System font, system materials, system accent, light and
    dark, full keyboard access, VoiceOver. No brand palette, no serif in a button (NAT-08).

### What "feels like Apple built it" means here, concretely

It is not a look. It is six checkable properties, every one of which the page broke:

- **It is ready the instant it opens.** The viewer is first responder before the first frame paints,
  so K/D/N work on the first press of every launch and every ⌘-tab back (NAT-01, the blocker).
- **Every convention is there.** ⌘W, full screen, ⌘+/−/0, a Help menu the system Help search can
  read, Dock progress, a notification when a long job ends, the Mac stays awake while it runs
  (NAT-02/03/04/06/07, NATIVE-M02).
- **The trackpad is a first-class input.** Pinch to zoom with detents and haptics, smart zoom, force
  click to peek at 1:1, two-finger swipe between frames, momentum pan. None of it existed in the
  page at any level (LT-11, NAT-10).
- **Every keyboard action has a mouse path and every mouse action has a key.** The page's stage had
  no Keep, no Drop, no Next Burst and no Undo you could click at all (LT-01, LIGHTTABLE-M01).
- **The picture is the app.** Half the window or more, up to 94 % on Space. The page gave it
  30–46 % (LT-04), and served an asset too small for the space it was drawn into (LT-05).
- **It tells the truth about itself.** The cull's guess is never dressed as his choice; "looked
  through" is never inferred from having scrolled past; the learning screen shows what a change
  would have cost him, frame by frame, before it is used.

---

## 2. The design

Two earlier drafts of this design disagreed about a number of things. Each of those decisions is
marked **[call]**, with the reason that settled it in one line. The drafts themselves are not
published; where a call names one — **speed** was the draft that optimised for presses per minute,
**clarity** the one that optimised for never being misread — the name tells you which way the
argument ran, and the sentence beside it is why that way won.

### 2.1 Window and structure

One window, one library, one job queue, no tabs. `NavigationSplitView` with two columns plus a
trailing `.inspector`.

**[call] Steps live in the sidebar under the shoot, not in a segmented toolbar picker (clarity).**
A segmented control cannot hold 7–9 items with extension-supplied labels of arbitrary length, and
the sidebar is the only place that answers "where am I and what is left" without a wizard.

**[call] Two columns plus inspector, not three (clarity).** A third permanent 220 pt column for
seven fixed rows comes straight out of the photograph.

```
Window "First Edit"  (id "main", restorable, no tabs)
  NavigationSplitView(.balanced) { Sidebar } detail: { StepDetail }
    .inspector(isPresented:) { InspectorHost }
Window "Activity"  (id "activity", ⌥⌘L)      — jobs, logs
Settings scene     (⌘,)
Sheets (never separate windows): first run, import, plans, confirmations, review-mode exits
```

**Sidebar** — 256 pt default, min 180, max 320, ⌃⌘S. (220 cut "What the Cull Has Learned" off mid-word; 240 did again once a long library brought in the classic scroller a Mac with a mouse draws, 15 pt of every row, and took the Keepers count with it.) `List(selection:)`, `.listStyle(.sidebar)`,
rows 28 pt, SF Symbols at `.body` with `.symbolRenderingMode(.hierarchical)`.

| Section | Row | Symbol | Subtitle | Notes |
|---|---|---|---|---|
| Library | All Shoots | `photo.on.rectangle.angled` | — | ⇧⌘0 |
| Library | What the Cull Has Learned | `graduationcap` | "Checked against 773 photographs you kept" | ⇧⌘L |
| Library | Storage | `externaldrive` | "226 GB free · 141 MB can be taken back" | ⇧⌘S; library-wide |
| Memory Card *(only while mounted)* | volume name | `sdcard.fill` | "1,212 photographs" *(not yet: the count is the card page's)* | trailing `eject.fill` on hover and while its page is open, on the card ⌘E means (the one on screen, else the first) and not while a copy needs the card; it runs File ▸ Eject the Memory Card |
| In Progress | shoot name | `photo.stack` | "54 frames · 14 keepers" (explicit keeps plus accepted cull picks, green); "Copy stopped at 412 of 1,558" when the copy's own log says it stopped — "412 frames" read like a whole night; "Copying the card…" while a copy into it is running or waiting on the list, with no count, since the row is only read again with the library | disclosure; expands when selected |
| ↳ | step rows | see §2.4 | current step shows "3/19 bursts" trailing, where it fits beside the whole step name (the name wins; the count stays in the row's help and VoiceOver value); before giving the count up the row closes the gap to 4 pt, because the selected row's heavier name at the 240 pt default otherwise lost the count on exactly the row he was on. A step the engine says is done has a `checkmark.circle.fill` in the same place, in the secondary colour, and "Done" in its help and VoiceOver value — every row looked the same done or not, so "what is left" meant opening steps; Choose Keepers counts until it is done, then has its check. Whether each is done is the library row's (§3.9-7), which is read again at every N, every job's end and on leaving a step, over the open session's, read when the shoot was opened | disabled steps say why on hover and in VoiceOver |
| Finished | shoot name | `photo.badge.checkmark` | — | the heading carries the count ("Finished 7"); collapsed beside work in progress, open when nothing is in progress, and as he last left it once he has opened or closed it (kept across launches) |
| footer | "Update to 0.2.0 available ›" | `arrow.down.circle` | — | only when there is one; a button that opens the update sheet (§7.9) |

Only the selected shoot is expanded; expanding another collapses the previous one. A shoot row's
context menu, the same in the sidebar and in All Shoots (`ShootContextMenu`): Show in Finder, Open My
Keepers in PhotoLab, Finish This Shoot (not on a finished shoot), Copy Path. The two that act
are judged by the shoot right-clicked, never by the one on screen — Open My Keepers when it is culled
and has keepers that would open, Finish This Shoot when it is culled — and each goes to that
shoot's step whose button it is (Edit in PhotoLab, Finish) and, where the Shoot menu's own row is
live there, runs it. They were greyed by whether the menu row was registered at all: greyed for good
where nothing registered it, and live for any shoot where something did. A broken shoot's menu is
Show the File and Copy Path. A row selected in All
Shoots is the shoot File ▸ Show the Shoot in Finder means (`Navigation.shootForCommands`). A shoot
whose decisions file will not parse draws a red row with the engine's own sentence, the offending
path in muted text, and a Show the File button — one bad shoot costs one row, never the list.

**All Shoots** is a `Table`, one row a shoot in the engine's order: Shoot · Up to · Frames · Keepers ·
The cull put forward · Where it is. **Up to** answers the question he opens it for — which shoots still
need keepers chosen or presets written: the first of the shoot's steps the engine says is not done and
can be started, under the sidebar's name for it, and on Choose Keepers the bursts looked through
("Choose Keepers 140/288 bursts", the count drawn as the sidebar's is and given up before the name when the
column is narrow, and kept in the help and VoiceOver as "140 of 288 bursts"); a finished shoot says
Finished. Done-ness is the engine's, from the steps it now sends on each row (§3.9-7); from an engine
that sends none the cell is empty rather than a guess. The steps are worked out inside the row's own
guard: a shoot whose steps raise sends none, and loses its Up to rather than the list — the whole list
failing was All Shoots and the sidebar saying his shoots could not be read. The three counts line up on their last digit,
under headings that do too (`.alignment(.numeric)`), where they sat left-aligned under their names.
The widths hold the whole table in the 644 pt the minimum window leaves beside the sidebar, with every
heading whole: each column's ideal is what its heading and its widest ordinary cell need, and the ideals
add up to the 644 less the table's 17 pt between columns — asking for more than that scrolled the table
sideways rather than narrowing a column, and the first widths for Up to cut "The cull put forward" to
"The cull put for…". Where it is takes what is left, and a phrase longer than that is whole in its help.

**Where the window opens.** On the shoot and the step he was on when he quit, with that shoot
expanded and selected in the sidebar, the Finished section opened if that is where it is, and the
row scrolled into view once — never All Shoots with the sidebar to expand and click down, and never
scrolled back to that row later when the light table hides and shows the sidebar. The app keeps
only the shoot, the step and the library folder the engine was reading when he was there
(`AppPaths.engineLibrary`: a `PHOTOS_ROOT` in the environment first, exactly as the engine is given
it, so a run against a scratch clone never files its shoot under his real library) (`LastPlace`,
`app.lastPlace`), written
each time he arrives at a shoot or a step, and apart from it the step he was last on in each shoot
("Clicking a shoot", below); a library page — All Shoots, What the Cull Has Learned,
Storage, a memory card — is a side trip, is never remembered and never overwrites it, so quitting
from one opens the shoot he was working in. Where to go inside Choose Keepers stays the engine's
answer (§2.5.13). The restore is a read and a selection: it never starts a job or opens a sheet,
and the detail shows "Starting" until the place is chosen, so the first page drawn is the right one.
The remembered shoot is asked for beside the library list, not after it, and opens as soon as its
own answer is here (the engine answering for it says it is there and readable; the step is kept when
the shoot still has it); when the list lands it holds the shoot to the list like any other, and a
step the extension renames takes the extension's name then, which the shoot opened ahead of the list
could not know. The list
reads every shoot's info — over a second on a cold engine with one shoot, more with every shoot — and
the step used to wait behind all of it. While the engine starts, the title names the shoot being
reopened, the subtitle says "Starting…" and nothing in the sidebar is lit: it said All Shoots, lit,
and then jumped. An engine that stopped instead is not starting: the title is the app's name with
nothing under it, and the page says what happened. Anything that no longer holds says nothing: nothing remembered, another
library folder, a shoot gone, renamed or broken → All Shoots; a step the shoot no longer has (the
engine cannot cut reels, an extension step whose extension is gone) → that shoot's own page. A click
he makes while the engine is starting wins. After an engine restart onto a library without the
shoot on screen, All Shoots. The step follows the selection and nothing else: a shoot's own page or
a library page has no step, so neither the title, the inspector, the Go menu's tick nor ⌘] carries
the last shoot's step with it.

**Clicking a shoot** — its row in the sidebar, or a double-click or Return in All Shoots — opens the
step he was last on in that shoot; in a shoot he has not been on a step of, the step it is up to (the
engine's first step not done that can be started, the one All Shoots' Up to names); with neither — an
engine that sent no steps — the shoot's own page, as before. It opened on the shoot's page every time:
five numbers and a folder path with nothing to press, so switching between two shoots was two clicks
each way and the sidebar had to be opened to find the step row. The row of the shoot he is already in
opens its own page, which is how the summary is reached (⌘[ from the first step also goes there). It
is a click that does this: a key moving through the sidebar — an arrow, or type-select — rests on each
shoot's own row as before, and Return there opens where he was in it, as it does in All Shoots
(`SidebarView.choose`, `openChosenShoot`). Sent the same way as a click, every shoot passed on the way
down opened its step page — Reels walking every export folder, Edit watching for exports, the light
table taking the keyboard — and the list could not rest on a shoot at all. A
remembered step the shoot no longer has counts as none, and a broken shoot's row opens its own page,
its one way in. `Navigation` keeps, per shoot, the step he was last on in it and the shoot he was last
in, for the run; across launches the steps are kept for the library folder they belong to
(`ShootSteps`, `app.shootSteps`), only for shoots the library holds, and read back with the place the
window reopens on. A library page is never a step of a shoot and is never kept as one.

The sidebar auto-hides on entering Choose Keepers when the window is narrower than 1280 pt and comes
back on leaving for a page that does not do the same. ⌃⌘S overrides and the override sticks for that
window width. Reels does the same, by the same rule and with the same memory: at 900 pt the sidebar,
the bursts list and the player left the frames two columns wide and below the fold, and at 1100 the
page's three regions squeezed its summary to a column of wrapped lines. The memory — whether a page put
the sidebar away, and the width it last acted at (`LightTableGeometry.SidebarAutoHider`) — is the
window's, kept once in `Navigation`; each page says it is up, at each width, and when it goes
(`putsTheSidebarAway`; Reels reads the window's `Navigation` from the environment `RootView` hands
the page), and the sidebar comes back only when the last such page has gone. Each page once kept its
own, and SwiftUI brings the next page in before the last one goes: between the two at 1100 pt the page
arriving found the sidebar already away and not its own doing, the page leaving then gave it back, and
the arriving page took that for his ⌃⌘S — so ⌘6 from the light table left it out on Reels, and the
light table lost its own auto-hide after any visit to Reels (`SidebarAcrossPagesTests`, in a real
split view). His ⌃⌘S on one of the two holds on the other at the same width. Where it shows beside
the light table, a click in it never keeps the keyboard: clicking the Choose Keepers row he is on, a
disclosure triangle or the Finished heading made the list first responder, so K and N went dead,
↑ and ↓ moved him to Cull or Presets mid-burst and type-select jumped to a row by its first letter.
Once the click has been handled — the first pass of the event loop with every button up
(`NSWindow.didUpdateNotification`) — `WindowChrome` gives the photograph the keyboard back while the
selection is still Choose Keepers; a click that leaves for another page leaves it with the list. It
answers a mouse press and nothing else (a local monitor notes the press, the next pass looks once):
Tab, Full Keyboard Access and VoiceOver's keyboard focus following its cursor reach the sidebar and
keep it there, where every pass used to take it back. In Compare and All Bursts, where no photograph
holds the keyboard, the window itself takes it from the list, so ↑ and ↓ can no longer move him off
the step; what those modes then do with a key is §2.5.3's (`SidebarKeysTests`).

**Window metrics.** Default content 1100 × 780 (his saved frame survives; `setFrameAutosaveName`
stays). Minimum **900 × 620** — at 800 × 560 the picture falls to 34.7 % of the window and the
753 pt control cluster (§2.5.2) has 3 pt of slack; at 900 × 620 the picture is 39.2 %, still four
times a filmstrip thumbnail, and the cluster has 54 pt each side. The 620 is the **window's** and
counts the 52 pt toolbar, as §2.5.1's arithmetic does; the root view is laid out inside the safe
area below the toolbar, so its own minimum is 620 − 52. It asked for the whole 620, which is 672 of
window: below that SwiftUI centred the root in the shorter safe area and the light table ran
(672 − height) / 2 pt off the bottom of the window, cutting the filmstrip's captions. The window's
minimum is SwiftUI's to set (`.windowResizability(.contentMinSize)`), so nothing else may ask for
one: `WindowChrome` sets `contentMinSize` and **not** the frame-based `minSize`, which made SwiftUI
ask for 640. `WindowMinimumTests` measures what the root asks for, the way SwiftUI measures it, and
holds it at 900 × 620. `titlebarAppearsTransparent` + `.fullSizeContentView` + unified `NSToolbar` (NAT-18).
The empty parts of that title bar are given their clicks back by a transparent strip of the app's
own, in front of the content and behind the bar's real controls: `titlebarAppearsTransparent` with
`.fullSizeContentView` makes `NSTitlebarContainerView` return nil over its own gaps, and the click
falls through to the content hosting view, which eats it. Measured on the real window at the middle
of the bar, Choose Keepers leaked **506 pt of 1100** — one run of 444 pt between the mode picker and
the inspector button — and every other screen leaked the 117 pt beside the traffic lights: strips
that neither acted nor dragged the window. The strip drags, double-clicks to whatever System
Settings ▸ Desktop & Dock says — Fill, Zoom (Maximize), Minimize or nothing; Fill used to zoom —
and accepts the first mouse.
**It claims a press and nothing else**: a scroll, a right click, a middle click, a moved pointer and
an accessibility probe all hit-test straight through it to whatever is drawn under the band, because
the strip is a behaviour attached to one event rather than a thing sitting on top of the window.
Claiming only in `mouseDown` is not the same: `NSResponder` hands an unhandled scroll or right click
to the **superview**, never to the sibling beneath, and with `.fullSizeContentView` a sidebar's
scroll view extends under the bar by design — so the sidebar stopped scrolling, and had no context
menu, whenever the pointer was in the top 52 pt. And the strip is put back in front on every pass of
the event loop (`NSWindow.didUpdateNotification`, one pointer comparison), not only on a resize:
SwiftUI replaces its hosting view for a sheet, for the inspector and for a split-view change, and a
strip that has fallen behind one stops working and says nothing.
The band is the top of the **window** whichever way the content view counts (`TitleBarStrip.frame(in:)`):
his window's content view is SwiftUI's hosting view, which is flipped, and a strip laid out as for an
ordinary view lay across the foot of the window instead, in front of every step page's action bar, and
took each click on a main button as the start of a window drag — Open My Keepers in PhotoLab did
nothing at all while Return and ⇧⌘E, which never pass through a hit test, still worked.
`collectionBehavior = [.fullScreenPrimary]` (NAT-03). Window title = shoot name; window subtitle =
the step and his count ("Presets · 14 keepers") — the native two-line title, which is where this
belongs. On Choose Keepers the bursts come first, with their unit, and the step's name is left out
("3 of 19 bursts · 14 keepers"; "been through" with no unit, beside "1 of 32 in burst 265", did not
say that 19 counts bursts): at the 900 pt minimum, or whenever the mode picker takes the middle of the
toolbar, the title bar cut the end off, and the end was the bursts count, the one number he watches
all evening, while the step's name is the page he is on. A library page is titled "First Edit"
with the page as the subtitle; the card page's subtitle is "Copy the Card · EOS_DIGITAL" (it had
none). The counts keep up with him: bursts looked through (here and the sidebar's "3/19 bursts") are the
open shoot's own, moving with each N the engine accepts; kept, frames and finished are the engine's
to count (his K, and the cull's call in a burst he has looked through), so the library is read again —
one read at a time — when the engine accepts an N (or its undo), when a job ends (including one that
ended before any poll saw it running) and when he leaves a shoot's step, never worked out here. So
"kept" and "bursts" move together at each N; a K inside a burst shows at that burst's N. It was read
once at launch, and every one of those numbers sat still all evening. A shoot's own page reads the
same two sources (the library's row, the open session's bursts), not the session's `info`, which is
read when the shoot is opened: it said 369 kept beside a sidebar row saying 368.

**[call] REVERSED — the second display is in v1.** This said "no second-display window in v1", on
the focus-management risk. `DESIGN-displays.md` is that design, worked through: one picture window
that can never become key, that owns nothing which can be lost, and that goes away without asking
him anything. Read it for §2.1, §3.5, §4.5 and §6; it is part of v1, not a later phase.

### 2.2 Type, spacing, materials, colour

- **Type:** system font only. `.largeTitle` 26 / `.title` 22 / `.title2` 17 / `.title3` 15 /
  `.headline` 13 semibold / `.body` 13 / `.callout` 12 / `.subheadline` 11 / `.footnote` 10.
  Counts use `.monospacedDigit()`; frame numbers use `.system(.caption, design: .monospaced)` so
  04330 and 04331 line up. The editorial serif the page put in every button survives nowhere
  (NAT-08).
- **Spacing:** 20 pt window margins, 16 pt between groups, 8 pt between related controls, 4 pt
  between a label and its value. Step pages are a centred column, max 680 pt, left-aligned inside.
  The column is the page's contents, never its scroll view: What the Cull Has Learned and Storage
  narrowed their whole `Form` to it, so the wheel did nothing over the margins either side and the
  scroller floated mid-window. They scroll across the whole pane now, with the column held by the
  scroll view's content margins, as the step pages always did. The storage panel is not a page: it
  is drawn inside Finish's scroll view, which already scrolls the whole pane, and it sizes to its
  own rows — measured against the pane instead, it came out a 10 pt sliver under the exports card.
- **Controls:** `.bordered` / `.borderedProminent` at `.controlSize(.regular)` in forms, `.large`
  for a step's primary. The two verdict buttons are the only custom controls in the app. Minimum hit
  target anywhere: 28 × 28 pt.
- **Colour:** system semantic colours only (`.primary`, `.secondary`, `Color.accentColor`, `.red`,
  `.green`). The user's system accent, not a brand gold. Verdict colour is always accompanied by a
  symbol *and* a word, so Differentiate Without Color loses nothing.
- **Materials:** system toolbar/sidebar materials. Liquid Glass (macOS 26+) is used for the Full
  Image HUD, the stack badge, the scrubber popover and the job popover, behind
  `#available(macOS 26, *)`, with `.ultraThinMaterial` in the same shapes as the fallback —
  identical geometry, so nothing reflows by OS version.
- **Light and dark:** the app follows the system, fully. The page hung a light native titlebar over
  a permanently dark body (NAT-12); that seam is gone, because the app is not permanently dark.
- **Viewer background** is its own thing, because a photographer judges tone against a known
  surround. View ▸ Viewer Background and Settings ▸ Choosing offer **Neutral Gray** (default, the
  same neutral in both appearances), **Match the Mac**, **Black**. **[call] default Neutral Gray
  (speed's intent, clarity's naming)** — a surround that changes with the OS theme changes how he
  reads exposure. Full Image always uses the darkest variant of the chosen option.

### 2.3 Toolbar grammar (one grammar, every screen)

| Placement | Content | Notes |
|---|---|---|
| `.navigation` | system sidebar toggle | free, standard |
| title | shoot name + subtitle | never changes position between steps |
| `.principal` *(Choose Keepers only)* | `Picker(.segmented)`: Single `rectangle` · Compare `rectangle.split.2x1` · All Bursts `square.grid.2x2` | keys Esc / C / G, also View menu. The segments are icons, so each one's help tag is its name and its key — "Compare (C)" — and VoiceOver calls the picker View. With nothing to compare from here, Compare's tag says why; a click on it bounces as C does and the picker stays on the mode he is in (`.disabled` on one segment never reaches the control). A view of its own, so a press that only moves the frame re-reads the picker's three segments and not the whole toolbar; the picker still reads whether Compare has anything to open, which the frame he is on decides |
| `.status` | Activity: 16 pt circular `ProgressView` + "Cull 2026-09-13-dog · about 4 minutes left" (the time left where it fits); after a job ends, its outcome — "Write the presets · Refused"; with nothing running and work on the list, "Up Next" or, held, a pause glyph and "3 held". On Choose Keepers in a window narrower than 1440 pt (`statusItemWholeFrom`) it is short — the ring and "Cull", or the outcome's symbol and "Refused" — with the shoot, the time left and the work that ended in its help tag, in VoiceOver and in the popover: the toolbar gives an item every point it asks for, so the whole line beside the mode picker cut the subtitle's count to "288 of 288 looked through ·…" for as long as a job ran, and all evening after a refusal | while a job runs; after it ends, 6 s for Done and Stopped, until clicked for Refused and Failed (the click opens Activity) or until the same work finishes when run again, 6 s for a storage plan refused on purpose; while the list has work. Click → popover |
| `.primaryAction` | a step's **second** action, never its primary: Cull Again… on a culled shoot, Write Them Again… once the presets are written — each asks first, carries only the key the command table gives the action it performs (Cull Again… culls the shoot, so it carries Shoot ▸ Cull It's ⌘R; Write Them Again… writes the presets, which the table gives no key, so it carries none), and is never the default | The page's main button is at its bottom right, once (§2.6). It was in the toolbar as well on every step — Copy, Cull It, Write Them Again…, Open, Finish This Shoot — two things to read for one action, and a greyed Finish This Shoot stayed there after finishing, reading as a status. Reels drew its Cut It in both places, and What the Cull Has Learned had Learn Now only in the toolbar's far corner; each is now in its page's own bottom-right bar (§2.6 Reels, §2.9), Shoot ▸ Cut a Reel still answering on Reels |
| `.primaryAction` (trailing-most) | inspector toggle `sidebar.trailing` | ⌥⌘I; only on a page with an inspector (today Choose Keepers), and ⌥⌘I is greyed elsewhere |

The inspector is drawn only on a page that registered one (`Navigation.hasInspector`); his pin is
kept for when he is back there. The pin was window-wide, so a column pinned open on the light table,
or opened there by a portrait burst, came with him to Presets, Reels and All Shoots as 280 pt of
"Nothing to show here yet."

Nothing in a toolbar ever writes a verdict. No destructive action is ever in a toolbar.
Toolbar customisation is on.

### 2.4 The steps

The engine's eight step ids stay exactly as they are — `ingest`, `cull`, `keepers`, `presets`,
`edit`, `instagram`, `reels`, `done` — because `Shoot.info()`, the done-ness table and the extension contract
(`STEPS`, `LABELS`, `EVERY`) are keyed on them. **[call] Presets is not folded into Edit (clarity,
against speed)**: folding them would change the extension's step vocabulary and the done-ness model
for no gain, and the Presets step is one button anyway.

| id | Label | Symbol | Done when | Primary |
|---|---|---|---|---|
| `ingest` | Copy the Card | `sdcard` | frames > 0, the copy's log does not say it stopped or failed, and no copy into it is running or waiting | Copy N Frames |
| `cull` | Cull | `line.3.horizontal.decrease.circle` | culled | Cull It; once culled, Choose Keepers (§2.6) |
| `keepers` | Choose Keepers | `checkmark.rectangle.stack` | reviewed | *(none — see §2.5)* |
| `presets` | Presets | `slider.horizontal.3` | presets > 0 and sidecars > 0 | Write the Presets |
| `edit` | Edit in PhotoLab | `arrow.up.forward.app` | exported > 0 | Open My Keepers in PhotoLab |
| `instagram` | Instagram | `crop` | a copy exists | Make N Copies (§2.17) |
| `reels` | Reels | `film` | reels > 0 | Cut It |
| `done` | Finish | `flag.checkered` | finished | Finish This Shoot |

The labels are the app's own, in this table, on every screen and whether or not the shoot has been
opened (`StepState.namedByTheApp`, applied where `ShootSession` takes the engine's list): the engine
sends labels of its own for the base steps ("Choose keepers", "Done"), and showing them once a shoot
was open renamed Finish to Done the moment he opened it and mixed sentence case into the Go menu. A
base step the extension names keeps the extension's name, as the engine does.

Extension steps are inserted at the positions the extension declares, with its own labels, carrying
a `puzzlepiece.extension` symbol at 60 % opacity on the row's trailing edge. The Reels step is
**absent entirely** when the engine reports it cannot encode (`can_cut_reels: false`) — no greyed-out
mystery (PERF-05).

Movement: click a sidebar step, ⌘1…⌘8, ⌘] / ⌘[, or the step's primary. ⌘] / ⌘[ walk the shoot's
own page and then its steps — the page comes before Copy the Card — and grey at either end (it went
forward from the page, and ⌘] on Finish was an enabled item that did nothing). A step whose prerequisite is
unmet is disabled with a help tag and VoiceOver hint saying why (FLOW-07); clicking it still selects
it and the detail pane explains the same thing in full. **Changing step resets scroll to the top and
moves focus to the step's first control** (FLOW-03). Scroll position and form state are not kept: a
step opens at its top with its form as the engine describes it, apart from the few choices that are
his habits and are kept app-wide (the copy's check and eject, §2.6; the editor, §2.11). What is kept is
the shoot and the step themselves (§2.1, "Where the window opens"). This said both were restored per
step, per shoot; nothing did that.

**[call] Leaving Choose Keepers never asks anything and never writes anything (clarity, against
speed).** The page's confirm was the only dialog guarding a non-destructive act (LT-12), and it
could write "reviewed" over bursts he never saw (LT-01). The honesty it was carrying moves to where
the consequence actually is — the Presets step states, before it acts:

> **23 frames selected for presets.** 14 you marked Keep · 9 cull picks you left unchanged in
> reviewed bursts.  ☐ Leave those 9 out *(drawn only where the engine can be told to leave
> them out, §2.7 — no engine can yet, so today the line ends at "reviewed bursts.")*

The three lines always add up to the headline. The engine's `agreed` is the cull's picks (rating 3 or
more) with no mark of his in a burst he has looked through — it counted every frame he left alone,
set-asides too, and printed 1,242 on a shoot whose cull had put forward 150. Its `kept` is gather's
rule, which already holds those picks, so the page takes `agreed` out of it rather than adding it
twice. The sidebar and overview call the combined number **keepers**; only the explicit subset
says **you marked Keep**. Burst progress names its unit, **9/9 bursts**, so it cannot be confused
with nine kept frames. The optional preset switch says **Also write presets for the other frames**:
those include the cull's set-asides and are not all explicit drops. The headline describes the
selection, not a promise that existing sidecars will be overwritten.

### 2.5 Choose Keepers — the light table

This section is complete enough to build from. Everything in it is fixed geometry or a stated rule.

#### 2.5.1 Regions and arithmetic

```
┌──────────────────────────────────────────────────────────── 52 pt  toolbar
│ ⧉  2026-09-13-dog          [ Single | Compare | All ]         ◔  ⧉
│    Choose Keepers · 14 kept · 3 of 19 bursts
├──────────────────────────────────────────────────────────── 18 pt  burst scrubber
│ ▮▮▮▮▮▮▮▮▯▯▯▯▯▯▯▯▯▯▯
├────────────────────────────────────────────────────────────
│                                                              viewer  (everything left)
│                    the photograph, fitted, 8 pt inset
│
├──────────────────────────────────────────────────────────── 56 pt  control bar
│ 04330 · burst 3       ↶ ‹ [ Drop ]  2 of 7  [ Keep ] ›  │ ⧉ ⏭       Kept 5 · Out 1 · 1 left
│ the cull: maybe — the face is softer than most here
├──────────────────────────────────────────────────────────── 96 pt  filmstrip
│ [▭][▭][▭][▭][▭][▭][▭]
└────────────────────────────────────────────────────────────
```

Fixed chrome: 52 + 18 + 56 + 96 = **222 pt**. Viewer = content height − 222, inset 8 pt each side.
Below 1100 pt of content width the control bar adds its 24 pt caption lane (§2.5.2), so the chrome
there is 246 pt — the two narrow rows of the table below.
Measured, for a 3:2 landscape frame:

| Where | Window | Viewer box | Photograph | % of window | the page |
|---|---|---|---|---|---|
| Default, sidebar hidden | 1100 × 780 | 1084 × 542 | **813 × 542** | **51.4 %** | 30.1 % |
| Same, inspector open (280 pt) | 1100 × 780 | 804 × 518 | 777 × 518 | 46.9 % | — |
| 14" full screen | 1512 × 945 | 1496 × 707 | **1060 × 707** | **52.4 %** | 37.7 % |
| 16" full screen | 1728 × 1080 | 1712 × 842 | **1263 × 842** | **57.0 %** | — |
| 27" full screen | 2560 × 1440 | 2544 × 1202 | **1803 × 1202** | **58.8 %** | — |
| Minimum window | 900 × 620 | 884 × 358 | 537 × 358 | 34.5 % | — |
| **Full Image**, default window | 1100 × 780 | — | **1100 × 733** | **94.0 %** | none exists |
| **Full Image**, 14" full screen | 1512 × 945 | — | **1417 × 945** | **93.7 %** | — |
| **Full Image**, 16" / 27" | — | — | 1620 × 1080 / 2160 × 1440 | 93.8 % / 84.4 % | — |

A portrait frame is height-bound the same way and leaves horizontal slack, so **the inspector opens
by default on a portrait shoot and is closed by default on a landscape one** (speed's observation;
it costs 0 pt for portrait and 6 pt of height for landscape at 1100 — before the control bar's
caption lane, which a column under 1100 pt now costs both shapes 24 pt more) — **but only where the 280 pt
it takes comes out of that slack rather than out of the control bar.** The inspector is 280 pt off
the content column and the bar measures itself from that column, so at 1100 a portrait burst left
820 pt: below the 1100 pt the two side captions need, which put the frame caption and the tally out
of the bar and onto the photograph as a full-width chip, and moved Keep and Drop 141 pt left of
where the same window puts them on a landscape burst. At the 900 pt minimum it left 620 pt and the
cluster was drawn off both ends of the bar. **The photograph does not move the furniture**: the
inspector opens itself only when what is left still holds the whole cluster **and both side
captions**, which is 1660 pt of content width and up — the 1380 pt the captions need beside a held
cluster with the inspector open (§2.5.2), plus the inspector's 280. It was 1380 while the cluster was
re-centred on whatever column was left. Below that it stays shut and ⌥⌘I opens it.

Both, not either, and not "the same as it would have shown anyway". Asking only that the remaining
column show the *same* captions as the whole one stops discriminating below 1100, where neither
does: then "it fits" alone decided, which needs 1073 pt, and in the 27 pt band from 1073 to 1099 the
inspector opened itself and left the bar 793–819 pt — a 753 pt cluster with 4 pt of room each side,
the captions on the photograph, and Keep 140 pt left of where the same window puts it on a landscape
shoot. Fitting is not slack. Where the inspector does open itself the bar keeps at least the 154 pt
each side it has at 1100.

It follows **the shoot**, not the frame under the cursor. Deciding it per frame made the inspector —
and with it the width of the bar's column — depend on where he happened to be standing when the step
appeared, and a shoot that mixes the two (his dog shoot is 16 portrait frames of 54) made it a coin
toss.

**What the inspector holds: what this frame is, never a way to decide it.** Two sections that never
merge — his call (the frame's place, his mark and his reason) and the cull's (its line, its focus
figure against the burst's, its stack with Compare) — and the frame's size and time. It carried
Keep, Drop and Clear the Mark as three plain buttons side by side, 8 pt apart, uncoloured and with no
key shown: the adjacency the control bar exists to avoid, and a second copy of controls the bar, the
keys and the right-click menu already are. They are gone.

⌥⌘I pins either choice and it sticks: once he has moved the inspector himself, the default is never
applied again — not for the life of the window, as this said, but across launches
(`view.inspectorPinned`, absent until his first ⌥⌘I). A launch used to hand the choice he had made
back to the portrait default. The pin from an earlier launch is taken up where the light table
would apply its default — on entering Choose Keepers — not at launch: Choose Keepers is the only page
with anything in the inspector, and applied at launch a pin to show it opened a 280 pt "Nothing to
show" column beside All Shoots and every overview.

#### 2.5.2 The control bar — where Keep and Drop live

56 pt, its own surface under the picture (never an overlay), **fixed**: it never wraps, never
scrolls, never moves. The page's equivalent row wrapped to two lines at its own default window size,
and the wrapped row was then clipped to a 26 px sliver (LT-03).

Leading, two lines, ending 16 pt before the cluster: `04330 · burst 3` (`.callout`) and
`the cull: maybe — the face is softer than most here` (`.footnote`, secondary). Where he is in the
burst, `2 of 7`, is the frame label's: said here as well, it pushed the burst number off the end at
1100 pt (`04330 · 2 of 7 in burst…`), and the burst number is said nowhere else on the screen. The
caption and the tally each have a box of at most 260 pt beside the cluster — at 1100 that is the
whole of each side down to the 20 pt margin; wider, they stay beside the controls they describe
rather than going out to the window's edges, where at 1920 they sat some 550 pt away. **Both are set
against the cluster**: the caption's lines end 16 pt before Undo as the tally starts 16 pt after
Next Burst. Set from its box's leading edge, a short caption on a wide window stood some 150 pt out
from Undo while the tally sat 16 pt from Next Burst, and lined up with nothing.

Centre cluster, centred on the **content column's** horizontal centre **as the column is with the
inspector shut** — the centre the photograph is fitted to, so the cluster is under the picture it
decides. **Opening the inspector does not move Keep or Drop.** ⌥⌘I takes 280 pt off the column, and
the cluster used to be re-centred on what was left, sliding Keep and Drop about 140 pt left under his
pointer, while this section said it did not. Now Drop — and with it the label and Keep, whose
distances are fixed — is held where the shut column puts it: what would then overrun the trailing
edge gives way first, in the order below (Compare, then the two step arrows; Undo is on the other
side of Drop and gains nothing), and what still overruns moves the cluster left only as far as it
must; should that put Undo past the leading edge, Undo and then the arrows go, and a column too
narrow even for that has the cluster centred in it as before. From 1145 pt of content (865 pt left
beside the inspector) nothing moves at all — on a 1440 laptop with the sidebar, on a desktop — with
Compare and the two arrows given up below 1265 pt, Compare alone below 1353, and nothing from 1353
on. At his own 1100 pt window the 820 pt left holds Drop 23 pt from where it was, not 140, with
Compare and the arrows waiting for the inspector to close; their keys work as ever. The
tally's side of the bar is the inspector's width shorter than the shut column's, so the two side
captions stay beside the cluster from 1100 pt **plus the inspector's 280** of column, and take the
lane below that. The inspector is taken at its ideal 280 pt; dragged wider, the bar holds against
280 and moves by half the difference. Nothing moves because a frame turned on its end (§2.5.1).

| # | Control | Size | Gap to next | Symbol / label | Key | Enabled when |
|---|---|---|---|---|---|---|
| 1 | Undo | 32 × 32 | 24 | `arrow.uturn.backward` | ⌘Z, Q, U | a verdict exists to take back |
| 2 | Previous frame | 36 × 36 | 16 | `chevron.left` | S, ← | not the shoot's first frame |
| 3 | **Drop** | **112 × 40** | **24** | `xmark` + "Drop" | D | always |
| 4 | Frame label | 112 × 40 | **24** | his mark + "2 of 7" + stack badge "4 similar" | — | — |
| 5 | **Keep** | **112 × 40** | 16 | `checkmark` + "Keep" | E, K | always |
| 6 | Next frame | 36 × 36 | 24 | `chevron.right` | F, → | not the shoot's last frame, once its last burst is finished |
| 7 | *divider* | 1 × 24 | 12 | — | — | — |
| 8 | Compare | 36 × 36 | 8 | `rectangle.split.2x1`, badge "4" | C | the frame is in a stack, he has ⌘-clicked two or more frames, or the invitation names a stack ahead of him in this burst |
| 9 | Next Burst | 128 × 40 | — | `forward.end.fill` + "Next Burst"; "On to Presets" on the last, except in All Bursts and while looking through a fault's frames (§2.6) | R, N | always, except in All Bursts once every burst has been looked through |

Cluster width **753 pt** (sum of the sizes and gaps above). Centred, it leaves 154 pt each side at
1100 pt of content width — enough for the caption and the tally. **Below 1100 pt of content width
the two side captions move to a 24 pt lane of the bar's own, above the cluster** — `04330 · burst 3`
and the cull's line at the leading margin, the tally at the trailing one — so the cluster itself never
shifts and nothing is drawn on the photograph; at the 900 pt minimum there is 54 pt each side and
the cluster still fits whole. They used to go onto the photograph, as a chip the width of the viewer
across its bottom edge: on a portrait frame it ran far past both sides of the picture, and on every
frame it covered the feet at the bottom of the picture, which is where "cut off" is
judged. The picture gives up 24 pt of height there instead (the minimum window's row in §2.5.1).
Which of the two the bar is follows from the width it is offered, so it is the right height from
its first frame; read back from a measurement, it started out as if it had 1100 pt and could draw a
frame without the lane before the answer came, the photograph above it then dropping by 24 pt. The Full Image HUD's copy of the bar never has the lane
(§2.5.7).

**When it cannot fit whole.** He can open the inspector by hand at the 900 pt minimum, which leaves
the bar 620 pt. Below 793 pt of content width the bar **gives controls up, in this order, and never
draws one where the pointer cannot reach it**: Undo first, then Compare, then the two step arrows
together. Drop, the frame's label, Keep and Next Burst are never given up — they are what this
section is about — **and neither is the rule between Keep and Next Burst**. What that rule separates
is the commit from the skip, which is the whole reason it is in the cluster; shedding it with
Compare left Keep ending at 430 and Next Burst beginning at 446 in the 620 pt column, sixteen points
of nothing between two 40 pt targets, which is the defect §2.5.2 exists to remove. It costs 13 pt.
Centre to centre falls to **149 pt** there and no further, with 29 pt of clear space and the rule
standing in the middle of it. Every one of the four has a key and a menu item, and so does
each of the four that go: ⌘Z, C, ← and →. The cluster's leading edge is clamped to the 20 pt margin,
so a control can only ever run off the trailing edge of the column, which a wider window brings back;
off the leading edge it was simply gone (at 900 pt with the inspector open the origin was −67 and
Undo sat entirely outside the window).

**The numbers that answer his complaint.** Drop's inner edge to Keep's inner edge is **160 pt of
clear space** — the frame label sits in that gap, so the two opposite controls are never adjacent
and are separated by something that names what is being decided. Centre to centre is **272 pt**.
Keep's centre to Next Burst's centre is **253 pt**, one short move, with a rule between them so they
never read as a pair. **[call] speed's separation, clarity's cluster inventory, and the label
between them is new to this document** — speed put the label between Keep and Reject, clarity put
Undo and Compare in the bar; both are right and they compose.

- Keep is on the right (affirmative right, HIG). Both buttons are the same size, shape and weight;
  only the symbol, the word and the tint differ. Keep is accent-tinted `.borderedProminent`; Drop is
  `.bordered` with a red-tinted symbol — **not** a red fill, because Drop is not destructive.
  Neither is the window's default button.
- **Both auto-advance to the next frame in shutter order, everywhere** — on the stage, in Full
  Image, in Compare. The page's loupe Keep/Drop did not advance at all, doubling the presses for
  the close calls (LT-02). **On the last frame of a burst they go on into the next**: K, D or a
  reason there finishes the burst and opens the next, exactly as → there does — the same write N
  makes, so it records the burst as looked through and is refused the same way. **It is one press,
  so it is one undo**: Q takes back the mark and the burst's record together and puts him back on
  that frame, unmarked (§2.5.5). The crossing used to take an undo step of its own, so at every
  burst's end the first Q only took him back to the frame, still kept, and a second was needed.
  He asked not to have to press N at the end of every burst, and the setting that did this sat
  switched off, so every burst of a 288-burst night cost one more press. Settings ▸ Choosing ▸ "After
  the last frame of a burst" ▸ Stay here puts the stop back. On the last frame of the **last** burst
  they record it and stay, as → does: what comes next is another page, and the line there offers it.
  A verdict that was refused, or that asks first (a reason on a kept frame), goes nowhere, and a held
  K never runs on out of the burst (rule 5).
- **→ off the last frame goes on into the next burst**, by the same write N makes (§7.4), and **in
  the press queue like N**: a K pressed straight after it lands on the next burst's first frame, and
  a second quick → moves on from there rather than finishing the same burst again. It used to be
  sent off on its own task, so the press behind it ran first — the K kept the frame he was leaving,
  and two taps of → wrote two finishes with two undo steps. **A held → stops at the end of the
  burst**, with the bounce, and the next press goes on: held forward it would have finished a burst
  a refresh, which is the held N rule 5 exists to rule out. A held ← goes on back across bursts,
  because going back records nothing, and stops at the start of the shoot. **One bounce answers a
  hold**: every repeat that met the edge used to bounce again, a fresh 120 ms shove and a haptic
  every 33 ms for as long as the key was down, so at the end of every burst he skimmed the
  photograph sat 8 pt off and shuddered. The first move to meet the edge — the press itself or its
  first repeat — bounces and drops whatever the stage still had pending; the rest of that hold is
  quiet, and the next press of its own may bounce again. The same holds for ↑ ↓, and for ← → ↑ ↓ in
  Compare and All Bursts.
- Trailing, 20 pt margin and a 16 pt gap clear of Next Burst: `Kept 5 · Out 1 · 1 left` for this
  burst, monospaced digits, **his tally only**. In a burst he has looked through, the frames he left
  alone are not work left but the cull's call agreed — the hollow mark in the strip — and the third
  figure says so: `Kept 5 · Out 1 · 1 agreed`. It shrinks a little (to 84 %) rather than being cut:
  at the default window its lane beside Next Burst is 137 pt, and `Kept 32 · Out 12 · 16 agreed` is
  162 — cut, it lost the word that says whose call those frames are. At 1100 pt the first ink of the
  tally is 19.5 pt from Next Burst's bezel. It measured 12.5: Next Burst's label was as wide as the
  button, and the bordered bezel adds 8 pt either side of its label, so the bezel was drawn 142 pt
  wide in its 128 pt place — 7 pt into the gap before the tally and 7 pt into the 8 pt after
  Compare, which it all but touched. The label is 16 pt narrower now and the bezel is the 128 pt the
  table says.
- **The caption says which burst, and only the tally says how many are left.** The caption was
  `04330 · 2 of 7 in burst 3`: at the default 1100 pt it was cut to "…in burs…", losing the one
  number nothing else on screen shows, while "2 of 7" was printed twice — it is the label between
  Drop and Keep. The tally said "1 to go" on the last frame, where there is nothing to go to, and
  started 2.5 pt from Next Burst, so it read as part of the button.
- **The label between Drop and Keep carries what he decided** about the frame on screen, in the
  filmstrip's own marks: the filled green check for kept, the filled red cross for out, nothing when
  he has not marked it. Nothing on the stage said so before — only a 14 pt mark under a thumbnail —
  and now that ← walks back across bursts he lands on frames he has decided all the time. In
  Compare the label reads "2 of 4 compared".
- ‹ and › go wherever S and F — ← and → — go, which is across bursts: they are greyed only at the
  two ends of the shoot — › at the very end only once the last burst is finished, since → records it
  first — and on a burst's last frame › says it finishes the burst, because there it does what R
  does: *"Finish this burst and open the next (F, →, R or N)"*. Their tags name the left hand's key
  first, read from the menu bar's table: "Previous frame (S or ←)", "Next frame (F or →)".
- Next Burst's help tag, because it is the one control that records something he did not press:
  *"Finishes this burst, as → on its last frame does. Frames you didn't press a key on keep the
  cull's call, marked as agreed — not as yours. (R or N)"*
- On the last frame of a burst, a quiet line appears at the bottom of the viewer:
  **"End of burst 3 — 2 kept, 4 out, 1 you haven't marked. Next burst: F or R (→, N)"** — the left
  hand's keys, then the ones he learned first ("1 agreed" in a
  burst he has looked through; with every frame marked, the counts alone), with a "Go to the one you
  haven't marked (↓)" link — "the first you haven't marked" when there are several — in a burst he
  has not looked through yet. In one he has, the frames he left are the cull's call agreed, which is
  what the line says, so there is no link calling them unmarked beside it. ↓ does go there: from the
  last frame nothing the cull put forward lies ahead, and ↓ used to bounce. → on the last frame goes
  on into the next burst and records this one, as N does (§7.4), so › is live there too; ‹ is live
  on a first frame, where ← goes back into the burst before. On the last frame of the **last** burst
  the first → records it, as N does, and after that → gives an 8 pt rubber-band bounce (120 ms) and a
  light haptic; no wrap. The invitation to compare the stack stands down on the last frame, so at the
  smallest window the bottom of the photograph carries one line over the caption instead of three.
- **One line at a time over the photograph**: a refused verdict about the frame on screen first,
  then the strip after D for its three seconds (§2.5.3), then the end-of-burst line, then a refusal
  still standing from a frame he has since left, then — while he is ⌘-clicking frames to compare —
  the line about those, then the invitation to Compare (§2.5.12). They used to stack up — on the
  last frame after a D the invitation, the strip and the end line covered the bottom of the picture
  together, and even with the others taken in hand the strip still stood on top of the end line. The
  line under the strip comes back the moment the strip's three seconds are up, not at the next
  press. A refusal records the frame that was on screen when it was said, and only its owner clears
  it (§7.7) — moving does not, except "Still opening this frame.", which moving answers — so ranked
  first wherever he went, a K refused on one frame hid the end-of-burst line on every frame after
  it, and on the shoot's last frame the only Continue to Presets on the screen.
- On the last frame of the last burst the line is **"That was the last burst. You kept 14 of 54."**
  with a Continue to Presets link right there — the sentence no longer names it as well; the link's
  help tag gives its keys, R, N and ⌘]. **On the last burst N goes on to Presets**: from any frame of
  it, it records the burst as looked through if it is not yet, exactly as Continue does, and opens
  Presets — there is no next burst to open, and what comes next is the next page. **Next Burst reads
  "On to Presets" there** (Continue to Presets is wider than the button), with the help tag *"Finishes
  this last burst, if you haven't, and goes on to Presets. …"*, and Frame ▸ Next Burst reads
  "Continue to Presets"; neither is ever greyed there. N used to finish the last burst and stay, and
  a second N only bounced, so the end of every shoot was one more trip to the link or ⌘]; before
  that, Next Burst was greyed on the last burst and only a bare N reaching the photograph could
  finish it, so his count stopped at 287 of 288. The first → off the very last frame records it as N
  does and stays — an arrow does not change the page — and after that → only bounces, as the end of
  the shoot does; nothing wraps. **Continue records it before going on** — it used to only go on, so
  Presets counted the last burst's picks as not looked through and the next launch reopened on it —
  and never records it twice. **⌘], Continue's key, does exactly what Continue does** there; it used
  to go straight on and leave the burst unrecorded. Anywhere else Go ▸ Next Step leaves and records
  nothing, because leaving a burst part way through is not going through it. In All Bursts the button
  keeps saying Next Burst, because N there goes to a burst not looked through and finishes nothing
  (§2.5.11), and it never leaves the page.

#### 2.5.3 Keys

Single-letter keys are live anywhere in the light table's window, whatever was clicked last — the
photograph, the filmstrip, the scrubber, the sidebar, the toolbar — and in every mode: Single, Full
Image, Compare and All Bursts. A text field that is being typed into always wins, and so does a
sheet in front of the window. Every one is a real menu item (§2.12), so it is discoverable, visible
to Full Keyboard Access, spoken by VoiceOver and re-bindable in System Settings. With Full Keyboard
Access on, Space and Return belong to a button or segmented control he has tabbed to — that is how
the setting presses one — and are the light table's again once the focus is anywhere else; the
light table's Space used to take them first, so no button in its window could be pressed from the
keyboard.

**One hand.** His right hand is on the mouse, so the cull lives under the left: **E keep · D drop ·
S previous frame · F next frame · R next burst · W previous burst · Q undo · X clear the mark**,
beside C compare, Z zoom, G all bursts, Space the whole picture and 1–6 after a drop. He had K for
keep — a hand's width right of D, so a cull took both hands — and said so: *"I hate k and being so
far i need 2 hands. it should all be close-ish on the keyboard."* The keys he had learned — K, N, P,
U, 0 and the arrows — go on working, and everything that teaches a key names the left-hand one first
and lists the old one as also working (§2.12). **Undo is the one exception**: Edit ▸ Undo is ⌘Z in
every Mac app and undoes typing in a text field too, where Q is only a letter, so its menu row, the
Shortcuts window and the Undo button's tag show ⌘Z and list Q and U as also working. S means one
thing in every view: the one before, beside F — the previous frame in Single and Full Image, the
ring in Compare, the previous cover in All Bursts. It was Single in All Bursts, so over the covers
forward was F and back was ←, which is the two-buttons-for-one-move he asked not to have; the way back
to one frame from there is Esc, Return on the ringed cover, or G again. A Presentation on the other
screen takes S and F as it takes ← and →, and R and W as it takes ↓ and ↑ (DESIGN-displays.md §5.6),
but the letters only while nothing is being typed into: the deck watches keys app-wide, and a letter
it took from a field would be a letter lost.

| Key | Action | Repeat held down |
|---|---|---|
| **E** (or K) | Keep, then the next frame in shutter order. On a burst's last frame it finishes the burst and opens the next, exactly as → there does; on the last burst's last frame it records it and stays. Settings ▸ Choosing ▸ "After the last frame of a burst" ▸ Stay here keeps it on the last frame | **ignored** |
| **D** | Drop, then the next frame (on a burst's last frame, as E); the reasons strip appears for 3 s, naming the frame it put out, unless Settings ▸ Choosing has it off | **ignored** |
| **X** (or 0) | Clear the mark (back to undecided) | ignored |
| **1–6** | Why it is out: shadow · cut off · face · blur · exposure · framing. While the strip after D is up, the reason goes to **the frame D put out** and nothing moves. Otherwise it is the frame on screen: on an undecided frame it also drops it (a reason implies out) and moves on as D does; on a kept frame it asks first: the same digit again puts it out, Return or Esc leaves it kept. E, X or an answered reason closes the strip | ignored |
| **S F** (or ← →) | Previous / next frame, shutter order; past the end of a burst F finishes it and opens the next, S goes back to the last frame of the one before. In Compare, the ring; in All Bursts, the previous / next cover | allowed, coalesced to one move per display refresh. A held F stops at the end of the burst with one bounce — leaving it forward records it as looked through, which takes a press of its own; a held S goes on back across bursts, which records nothing |
| **↑ ↓** | Previous / next frame the cull put forward; inside a stack, stack to stack; in All Bursts, a row. ⌥-scroll over the photograph does the same (§2.5.8) | allowed, coalesced |
| **R** (or N) | Finish this burst and open the next. **Leaving a burst forward — R, F off its last frame, E or D on its last frame, Continue on the last — is the only thing that records "looked through"** (§7.4). On the last burst: finish it if it is not finished, and go on to Presets | ignored |
| **W** (or P) | Previous burst. Records nothing | ignored |
| **Space** | Full Image — tap toggles, hold shows it while held. With Settings ▸ Choosing's Space set to the next burst, it is R instead. Nothing in All Bursts, which shows no frame | ignored |
| **Z** | 1:1, aimed at the face; Z at 1:1 goes back to Fit, so checking focus is Z, look, Z (⌘0 goes to 1:1 and stays). From a pinched in-between zoom Z goes to 1:1, not Fit. Nothing in All Bursts | ignored |
| **⌘9** | Fit | — |
| **⇧ ← → ↑ ↓** | Pan at 1:1 | allowed |
| **C** | Compare: the frames he ⌘-clicked in the filmstrip, else this frame's stack, else the stack the invitation names (§2.5.12); C again goes back. A plain click on a thumbnail, Esc, leaving Compare or moving to another burst puts a ⌘-click set down | ignored |
| **⇧E** (or ⇧K) | In Compare: keep only this one (drops the rest of the stack, one undo step), then back to one frame, on the first frame after the stack (on a ⌘-clicked set with gaps, the first unmarked frame between them) | ignored |
| **G** | All Bursts; G again goes back (§2.5.11) | ignored |
| **Return** or **Esc**, in All Bursts | Single frame, back to the ringed burst (G again too) | ignored |
| **Q** (or ⌘Z, U) | Take back the last verdict and go to that frame. A verdict that went on into the next burst comes back with the burst's record, in one press | ignored |
| **⇧⌘Z** | Put back what ⌘Z took back last, on its frame | ignored |
| **?** or **⌘/** | Keyboard Shortcuts window | — |
| **Esc** | Leave Full Image / Compare / All Bursts / review mode; with none of them up, put down the frames he ⌘-clicked to compare, and otherwise nothing — quietly, never the system beep | — |

None of the left hand's letters is the light table's with ⌘ held: ⌘Q quits, ⌘W closes, ⌘E ejects,
⌘R culls and ⌘F finds a burst, as they always did.

**One scheme, on every page with photographs.** He asked for it in so many words — *"make sure
there is control parity so same way you maneuver the other steps carries over and i'm not doing
different buttons for forward and backward etc"*. So the keys above are not the light table's alone.
Every place that shows photographs and takes keys reads the press with `KeyMap` and says only what
each of its actions does there; none has a key table of its own. A place may have keys of its own,
but only on keys the table leaves unused in every mode, so they can never shadow one of these.

| Keys | Choose Keepers | Instagram: wall · editor (§2.17) | Reels (§2.6) | The viewer: Reels' Space, a page's `viewFrames` (§2.16) | The learning review (§2.9) | A presentation (DESIGN-displays.md §5.6) |
|---|---|---|---|---|---|---|
| **S F** (← →) | previous / next frame; in Compare the ring, in All Bursts the cover | previous / next photograph | previous / next frame | previous / next frame | previous / next frame, in the grid or large | previous / next in the deck |
| **↑ ↓** | the cull's picks; in All Bursts a row | a row · — | a row; while the bursts list has the keyboard, the list's own | — | a row | previous / next burst in the deck |
| **W R** (P N) | previous / next burst; R records "looked through" | — | previous / next burst in the list | — | — | previous / next burst in the deck; nothing recorded |
| **E** (K) | keep, then the next frame | include, then the next | in the reel, then the next — staying on the burst's last frame | the mark a keep leaves (Reels: in), then the next | — | the light table's, refused |
| **D** | drop, then the next frame | leave out, then the next | out of the reel, then the next — staying on the burst's last frame | the mark a drop leaves (Reels: out), then the next | — | the light table's, refused |
| **X** (0) | clear the mark | clear, and stay | back in — a reel's frame starts in — and stay | no mark (Reels: back in), and stay | — | the light table's, refused |
| **Space** | Full Image | open the editor · close it | open the frame large | close it, as Space opened it | open large · put it back | — |
| **Z** (⌘0) | 1:1 | open at 1:1 · Fit ↔ 1:1 | — | — | — | — |
| **Esc** | leave the view | taken, nothing · save and close | taken, nothing | close | Done · back to the grid | end the show |
| **Q** (U, ⌘Z) · ⇧⌘Z | undo · redo | undo · redo | undo · redo, on the frame — and burst — it changed | undo the last mark made in the look — on Reels off the page's own undo, so its Q and Edit ▸ Undo agree | — | the light table's, refused |
| **Return** | in All Bursts, open the ringed burst | the step's primary · Done | Cut It, the step's primary | Done | — | — |
| its own | 1–6, C, G, ⇧E, H, ⇧-arrows, ⌘9, ⌘+ ⌘− | A T V − = in the editor | I and O: where the reel starts and ends | a page's own mark, on a letter the table leaves unused | — | Home, End |

"—" is a key the place does not take: it goes on as it would, and never means anything else there.
Two differences are deliberate. With Settings ▸ Choosing's Space set to finish the burst, Space is
the next burst on the light table only; every other place has no burst to finish, or opened large on
Space, and still opens and closes the photograph large (`spaceFinishingTheBurst` pins it). And E or D
on a burst's last frame goes on into the next burst on the light table unless Settings says stay,
where on Reels it stays on that frame: a reel is cut from one burst, and walking on into the next
would leave the frames he was trimming behind the grid. The next burst is R, as everywhere.
Choose Keepers, Instagram and Reels take their keys from anywhere in the window through one local
monitor each (`LightTableKeys`, `InstagramKeys.route`, `ReelsKeys.route`), standing aside for a text
field, a sheet and a button Full Keyboard Access has put its ring on; a presentation watches app-wide;
the viewer, a sheet, and the learning review read theirs while they have the keyboard.
The menu teaches the same: Frame ▸ Keep reads "Include 05901" on Instagram and "Include 06264" on
Reels, Drop "Leave Out …", and Clear the Mark, Next and Previous Frame, Next and Previous Burst,
Full Image and Edit ▸ Undo act on the page on screen (§2.12); the Keyboard Shortcuts window opens
on this scheme, one row a meaning, before the menus' own rows. `KeyParity.places` lists every place
with the function its key handling calls, and `KeyParityTests` writes the scheme out key by key, as
his rule and not read from `KeyMap` — the light table is one of the places held to it, not the judge
of it — then walks every place press by press, plain, shifted, with ⌘, ⌥ and ⌃. It fails when a key
means something else anywhere, when a place's own key is one the scheme uses, and when a place takes
a meaning by one of its keys and not by the others (← but not S, E but not K). It also registers
every step and library page the app has and fails on one that is neither a place there nor declared
to show no photograph a key acts on, so a new step cannot arrive with keys nobody held to the scheme.

Two deliberate changes from the page's bindings, both called out so they are decisions and not slips:

- **Space is no longer "next burst".** It is Full Image, as in Photos, Preview and Finder — and the
  docs of the time already promised it was a zoom toggle (DOC-02). The cost of the old binding is that a
  burst gets recorded as looked-through when he meant to look closer. N remains, alone and
  unambiguous. Mitigation: a one-time tip on first entry, and Settings ▸ Choosing ▸ Space key ▸
  "Finishes the burst and opens the next".
- **A reason goes to the frame he dropped, not the frame D moved him onto.** D moves on, so by the
  time the 4 the strip asked for arrives, the cursor is on the next frame — which he has not judged.
  The reason used to land there: that frame was put out and labelled "blur" without his knowing, the
  cull was taught blur from it, and the frame he meant kept no reason. The strip therefore names the
  frame it asks about ("04328 is out. Why?", each button the key and its word together), and while
  it is up a digit labels that frame only: no second drop, no move, one undo step of its own. It
  comes up only for a D that took — a refused D put nothing out — and goes on ⌘Z, on its answer,
  or after 3 s, after which a digit means the frame on screen again. The 3 s are counted to **the
  press**, not to the moment it is applied, so a digit pressed at 2.9 s behind a crossing still
  answers it. A digit that finds the D it answers refused while it waited goes nowhere and takes
  the strip down: that frame is not out, and labelling it put it out a second time unasked — or,
  on a frame he had kept, asked him about a frame already behind him. The same holds in Compare,
  where D has already moved the focus to the next undecided tile, and in Full Image, where the strip
  is drawn above the HUD for the same 3 s: without it there, the same D then 4 meant the frame he
  dropped on the table and the next one in Full Image.
- **On a kept frame, the same digit twice puts it out.** A reason implies out, so a digit on a frame
  he kept asks first ("This is one you kept. Marking it 'blur' puts it out. Do that?") under the line
  "Press 4 again to put it out. Return leaves it kept." He pressed 4 on purpose to change his mind,
  and Put It Out had no key, so doing what he had asked for took the mouse every time; now it is the
  reason's own digit, pressed afresh. Return and Esc still answer Leave It Kept, so a reflex keeps the
  frame, and the digit that raised the question, if it is still held down, is not a second press —
  its repeat reaches the sheet once the sheet is in front, and is dropped there by the same rule 5.
- **"Just no" is gone from the reasons.** Six reasons, 1–6, all of them nameable faults. A frame he
  simply does not like is Dropped with no reason, which was always expressible. A reason that is
  taste and not a fault trains the cull on nothing. The app's words map to the engine's
  existing label strings: "face" ↔ `expression`, "framing" ↔ `composition`.

**Key handling, precisely: one path.** Every key pressed in the light table's window goes to
`ViewerModel.key(_:at:)` by one route, a local event monitor (`LightTableKeys`) that exists for as
long as the light table is on screen and stands aside only for a text field being typed into, a
sheet, and a key another part of the app has first claim on (a presentation's arrows and Esc on the
other screen, DESIGN-displays.md). That one function is rule 5:

```
func key(_ press: KeyMap.Press, at time: TimeInterval) -> Bool {
    guard let action = KeyMap.action(for: press, mode: keyMode) else { return false }
    if press.isARepeat && !action.allowsRepeat { return true }   // rule 5: eaten, counted once
    if press.isARepeat, action is ← or → { stage.hold(±1); return true }   // one move per refresh
    if press.isARepeat { performHeld(action); return true }   // ↑ ↓ ⇧-arrows: held, one bump a hold
    perform(action)                         // the press queue; the display gate is in the session
    return true
}
```

Rule 5 is applied a second time where every press meets, in `ViewerModel.perform`: whatever route a
press arrives by — the key path below, a menu row, a button — a held key that is not movement is one
press, and the held-key line is said once. A K held down kept a frame per repeat when the bar's
buttons still carried keys, and — now that K on a burst's last frame goes on — would run on out of
the burst recording each one as looked through, as a held N did by itself.

There used to be two paths, and the wrong one won. Keep, Drop, Next Burst, Compare and Compare's
Single link carried bare SwiftUI `.keyboardShortcut`s, and AppKit offers a key to a window's key
equivalents before any view gets `keyDown` — so K, D, N and C went to the buttons, repeats and all:
a held K kept every frame it landed on as soon as each had been on screen for two refreshes, a held
N marked bursts he never looked at as looked through, and "Holding K keeps one frame only" never
appeared. The photograph's own `keyDown`, where the repeat rule lived, only saw the keys the buttons
did not take, and only while it had the keyboard — which it lost in Compare and All Bursts (no
photograph there), after every Full Image round trip, and after any click on the sidebar or a
thumbnail. **No button in the light table carries a key now.** Each names its key in its help tag
instead — "Keep (E or K)", "Next frame (F or →)", "Undo Keep 07179 (⌘Z, Q or U)" — read from the
menu bar's own table, the key the row shows and then the ones it also answers to, so a tag can never
name a key the menu does not.

One key it reads is not always its to take: ⇧⌘Z puts back what ⌘Z took back last on the light table
(§2.5.5); with nothing of his to redo it goes on to the Edit menu when there is something to redo
there, and is taken and dropped when there is not — passed on, it reached a greyed Redo and then the
system beep. Esc is always the light table's, even with nothing to leave: nothing else
in its window answers Esc, and passing it on only beeped, every time he pressed it once too often
after Space or Compare. The view still exists (`StageView`, an `NSView` inside an
`NSViewRepresentable`) because the same surface needs `magnify(with:)`, `pressureChange(with:)`,
`smartMagnify(with:)`, `scrollWheel(with:)` and the display link that spends held arrows.

`KeyMap` is pure and unit-tested: `(NSEvent-like descriptor, Mode) -> Action?`. Its tests assert
that every verdict action has `allowsRepeat == false` and that no single-letter action exists in
`.textEditing` mode, and that each left-hand key does in every mode exactly what the key it stands
beside does — E as K, X as 0, R as N, W as P, Q as U, F as →, and S as ← in every mode, All
Bursts' covers included.

**Arrow repeat** is coalesced in the display link: repeats accumulate a pending delta and one move
is applied per refresh. A held move that meets an edge bounces once for the whole hold and drops the
pending delta (§2.5.2). During a repeat run the viewer draws only what is already decoded (thumb or
large); the sharp upgrade is requested 80 ms after the last key.

#### 2.5.4 A verdict is only taken on a frame that is actually displayed

This is rule 5, and it is the single behaviour most likely to be lost in a rewrite.

- `StageView` reports `didDisplay(stem:generation:)` from its display-link callback, and only after
  a `CGImage` for that `(stem, generation)` has been committed to the layer *and* one refresh has
  passed. "Loaded", "requested" and "complete" do not count. `generation` increments on every cursor
  move, so a late image for a frame he has already left can never satisfy the check.
- `ViewerModel.isDisplayedFrameCurrent` is `displayed?.stem == cursor.stem &&
  displayed?.generation == cursor.generation`.
- A frame displayed at **any** tier counts as displayed — he can see a thumbnail well enough to
  reject an obviously wrong frame. A frame with **no** pixels at all does not.
- Three distinct refusals for three distinct causes, each shown in the alarm colour, whole, centred
  over Drop and Keep — over the single frame as the first of the viewer's notices while it is about
  the frame on screen (§2.5.2), in Compare and All Bursts just above the bar, in Full Image just over
  the bottom of the picture (§2.5.7) — and each tagged with its owner so the next unrelated success
  cannot wipe it. (The bar's second line, where this first put them, is 145 pt wide at 1100 and cut
  the no-pixels sentence in half; a fixed spot above the bar then drew the refusal across the middle
  of the end-of-burst line.)
  - not the current frame → *"That frame isn't the one on screen."*
  - no pixels at all → *"This frame's pixels are not on this Mac — its RAW is archived, or its
    rendering was taken back. Nothing can be decided here."*
  - still decoding → *"Still opening this frame."* plus a soft bump and a `.levelChange` haptic.
- These three are about the frame he pressed on, so **a move takes them down**: the session, which
  raised them, clears them whenever the cursor moves. *"Still opening this frame."* used to stay
  above Keep and Drop, untrue, while he arrowed through frames that were plainly open, until his next
  K or D went through. They are not taken down when the same frame finishes opening — his K still
  did not land, and a line that vanished 30 ms after it came would say neither. A write the engine
  refused is about the frame, not about where he is, and stays (§7.7).
- A verdict is also refused if the frame has been displayed for less than one refresh. In practice
  this never fires on a human press; it makes "a held key wrote things I never saw" impossible even
  if the OS changes repeat behaviour.

#### 2.5.5 Undo

`UndoManager` on the window, driven by a `VerdictLog` owned by the `ShootSession`. ⌘Z, ⇧⌘Z, U, the
Edit menu and the three-finger trackpad undo all work; so does the Undo button in the control bar
(LIGHTTABLE-M01: in the page there was no mouse path to undo at all).

- One press, one step. **Consecutive verdicts are never coalesced** — two presses folded into one
  undo is exactly how a way back was lost before. The one press that writes twice is a verdict on a
  burst's last frame that goes on (§2.5.2): the finish it makes **joins** the verdict's step
  (`VerdictStep.joins`), and one undo takes back both — the burst's record, then the mark — and
  leaves him on that frame; one redo puts both back and takes him on into the next burst again. It
  joins only while that verdict is still the newest step: one whose write the engine refused has
  already come off, and then the finish stands alone.
- Menu items name the thing: "Undo Keep 04330", "Undo Drop 04331", "Undo Keep Only 04330",
  "Undo Reason 'blur' on 04331", "Undo Leaving Burst 4" (N, or an arrow past the burst's last frame).
  A finish that joins a verdict is named for the verdict, which is what he pressed.
- Undo navigates to the frame it changed, changing burst if needed, and flashes its badge once.
- **Redo** (⇧⌘Z) puts back the step undone last, on its frame, writing exactly what the press
  first wrote by the same route — the same value, the same reason, the same burst recorded as looked
  through — and a refused redo stays ready to try again. Any new step of his clears what could be
  redone, as in every Mac app. `VerdictLog.redoName` names it ("Keep 04330"), as `undoName` does
  for Undo, and Edit ▸ Redo reads it (§2.12). Redo used to do nothing at all: a verdict undone once
  too often had to be found and pressed again.
- The stack is 200 deep, per shoot, and is **not** cleared by changing step.
- **Optimistic, but never a lie.** A press applies to the local model immediately, pushes a
  `VerdictLog` entry and enqueues the write. If the write is refused, the local model rolls back,
  that one log entry is removed (not the whole stack), and the refusal is shown on the control bar.
  ⌘Z pops the newest entry *immediately*, before its inverse write resolves, so two fast ⌘Z presses
  undo two different decisions rather than racing each other — once any verdict write still on its
  way has been answered, so the undo can never reach the engine before the thing it takes back.

#### 2.5.6 Writes: the verdict queue

The native equivalent of the page's `queueWrite`, and for the same measured reasons.

```
actor VerdictQueue {
    func submit(_ write: VerdictWrite) async -> Result<RatingResponse, StudioError>
}
```

- Serialised **per frame**. Two writes for the same frame never overlap; writes for different frames
  may.
- A write whose value equals the value already in flight or already committed for that frame is
  **dropped** (a doubled press is one press counted twice).
- A write with a different value is **queued behind** the in-flight one and applied in press order.
  Never "debounce", never "last write wins".
- `POST /api/rating` returns `{ok, key_note}`; a non-empty `key_note` is printed inline on the
  control bar, never as an alert — it is informational and must not break the rhythm.
- **His next press does not wait for the engine.** K, D and 0 change the model, push the undo step
  and move on at once (`ShootSession.take`), and the light table takes the next press straight away
  while the write goes on its own (`settle`). Every press used to wait for the engine to save the
  one before — 43–47 ms a rating on his 1,558-frame shoot with the engine idle, far longer while a
  job ran — arrows and Space included, so a quick K → felt sticky. What must not overtake a write
  waits for its answer: another verdict on the same frame (a refusal arriving after it would
  otherwise take back his newer press on screen while the engine held it), and a reason on that
  frame, each waiting for that frame's write only; ⌘Z, ⇧⌘Z and anything that decides several frames
  at once wait for every write still on its way. A write refused after he has moved on still takes
  back exactly its own step and says why on the control bar; a late success never takes down a
  display-gate line about the frame he is on now, nor the refusal of a press he made after it — K on
  one frame answered late used to take down the sentence saying why K on the next was refused. Only
  the success of a later press takes a refusal down.

#### 2.5.7 Zoom, Full Image, and how 1:1 stays on the face

**There is no modal loupe.** The viewer is the viewer. This deletes the whole class of bugs the
dialog carries (LT-03 wrapped buttons, keys that mean different things one screen apart).

| State | How you get there | What it is |
|---|---|---|
| **Fit** | default, ⌘9, pinch out past fit | whole frame, 8 pt inset |
| **Full Image** | Space (tap to stay, hold to peek), double-click a filmstrip thumb | toolbar, scrubber, control bar, filmstrip and sidebar all hidden; picture fills the window |
| **Zoomed** | Z, ⌘0, pinch, double-click the picture, force click, ⌘+ / ⌘− | continuous 10 %–400 %, anchored where he asked, detents at Fit and 100 %. Z toggles: pressed at 1:1 or closer it goes back to Fit, as the double-click does, so a focus check is Z, look, Z |

In **Full Image**, moving the pointer brings a HUD up from the bottom for 2 s carrying the same
cluster (Undo, ‹, Drop, label, Keep, ›, Next Burst) and the caption; it fades again. The caption is
the HUD's own pill, said once: its copy of the bar has no captions and no lane, where handed the
HUD's 793 pt it grew the lane, said the caption twice and stood 24 pt taller over the feet of the
frame. A refused K or D is said in Full Image too, just over the bottom of the picture, HUD or no
HUD — one left standing from another frame only while the HUD is up. The light table's notices are
under Full Image, so a refusal there was never shown at all. Every key still
works and K/D still auto-advance, so a whole burst can be judged in Full Image. Space again, Esc or
a click on the background returns to the same frame, same zoom, same filmstrip scroll. Space held
longer than 300 ms is momentary and returns on release. ⌃⌘F (window full screen) composes with it:
1620 × 1080 pt of photograph on a 16" with nothing else on screen.

**One photograph in charge at a time.** Full Image draws its own stage over the window. The table's
stays built underneath **keeping the picture it has, and waits** — which is also what keeps the
filmstrip's scroll and the zoom exactly as he left them: while it is covered it measures nothing into
the model, loads nothing, reports nothing to the display gate (§2.5.4), holds no arrows, says nothing
to VoiceOver and runs no display link. Which of the two is in charge is read from the model at the
moment of asking, so for the fifth of a second the overlay takes to fade out it is already the
covered one, and the table's stage takes all of that back as Full Image ends, first responder
included, so the arrows and Space work without a click. So Full Image fades in over the photograph
and back out to it. Two earlier versions were each wrong one way: both stages measuring themselves
into the one model, each write re-running the other's body, took turns in a loop that never let go
of the main thread (138,000 rounds in six seconds in an offscreen copy of the window) and loaded
every frame twice at two sizes; and taking the table's stage down instead made the switch jump — the
photograph vanished at once and Full Image faded in over the bare background, and on the way back the
rebuilt stage had no picture for the first frames of the fade. The HUD is put up by a pointer move
and taken down by one sleeping task; nothing runs while the pointer is still.

**What 100 % means:** one image pixel on one device pixel, computed from the frame's real `dw`/`dh`
and the screen's `backingScaleFactor`, so it is true on Retina and on a 27".

**Aim.** The zoom centres on, in order: the largest face (`face_x`, `face_y` from the row — the
`/crop` route already takes these, and the fallback is live in practice because some shoots carry
neither), else the subject box if the engine reports one, else the geometric centre. When the aim
came from a face, the aim point is placed at **0.38 of the viewport height** rather than the centre,
because he is checking eyes; on the geometric fallback it is centred. The zoom label in the control
bar always says which: `1:1 · on the face` / `1:1 · no face found, on the subject` /
`1:1 · centered`. A silent wrong aim is worse than a stated fallback.

**Staying there across a burst.** Zoom factor and pan are held **relative to the aim**, in
normalised frame units. Moving to the next frame re-resolves the aim from that frame's own
`face_x`/`face_y` and re-applies the same relative offset — so if he panned to the hands, it stays
on the hands, and through a 30-frame burst the eyes stay in the same place on the screen. A frame
with no face holds the previous absolute normalised position and the label becomes
`1:1 · held in place`. It never jumps to centre mid-burst.

**A new burst opens at Fit.** The hold is for the frames of one moment, where the eyes are in the
same place; the next burst is another moment and another framing, and the first thing he does there
is see the whole frame. So arriving in a burst by any road — N, → off the last frame, ← off the
first, P, the scrubber, a cover in All Bursts, an undo that lands in another burst, reopening the
light table — goes back to Fit. The zoom used to be carried on: after a focus check on the last
frames of a burst, the next burst opened at 1:1 on a face he had not yet seen whole.

**Tiles, not full-resolution bitmaps. [call] clarity's `/crop` tiles, against speed's `/decoded`
route.** Speed's own risk list flags a 24 MP decoded bitmap at ~96 MB each with an unmeasured
3-deep ring. At 1:1 the app fetches a `/crop` tile **1.6 × the viewport** around the current aim, so
small pans are local GPU work; a new cut is requested only as the pan approaches the tile edge,
throttled and cancellable, and while it is in flight the fitted image is shown scaled at the new
offset with a small "sharpening" indicator in the corner — never a blank frame, never a spinner over
the photograph. The next frame's tile at the same coordinates is prefetched, so arrowing through a
burst at 1:1 is instant instead of one 650 ms decode per frame (PERF-01).

#### 2.5.8 Trackpad and Magic Mouse

None of this existed in the page at any level (LT-11, NAT-10). In an AppKit viewer most of it is
the OS, not invention.

| Gesture | Does |
|---|---|
| Pinch (`magnify(with:)`) | continuous zoom 10 %–400 % anchored under the fingers, detents at Fit and 100 %, `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)` at each detent |
| Two-finger double-tap (`smartMagnify(with:)`) | Fit ⇄ 100 % at that point, aimed at the face |
| Two-finger swipe left / right (`NSEvent.trackSwipeEvent`) | previous / next frame, as ← → go — on across a burst's ends; honours System Settings ▸ Trackpad ▸ "Swipe between pages". When the swipe cannot be tracked — that setting off, a neighbour not decoded yet, a one-frame burst — one firm swipe is still one frame, pushed left the next; a tilt wheel is one frame a notch. It used to be dropped without a word |
| Wheel, or two-finger scroll up / down, at Fit | previous / next frame, **exactly as ← → go**: toward him the next, on off a burst's last frame into the next burst — recording the one he leaves, as → does — and back off its first into the one before. **With ⌥, the cull's picks** (↑ ↓) |
| Two-finger scroll when zoomed | pan, stopping at the picture's own edge |
| Drag when zoomed | pan, the picture following the hand exactly; the pointer closes to a fist. This is what the open hand has been promising, and it is the only pan a wheel mouse has |
| Force click on the picture (`pressureChange(with:)`, stage 2) | spring-loaded 100 % peek at that point while held; release returns to Fit. The fastest focus check that exists on a trackpad |
| Force click on a filmstrip thumbnail | peek: that frame large in a HUD over the strip while pressed |
| Click | select / focus the viewer — **never** a verdict |
| Double-click the picture | Fit ⇄ 100 % at the click point |
| Right-click | Keep · Drop · Clear the Mark · Why It Is Out ▸ · Compare Similar Frames · Full Image · Show in Finder · Copy Frame Number — the Frame menu's own rows, names and keys (the reasons showed ⌘1–⌘6, the Go menu's steps, under a submenu called "Reason"; Show in Finder and Copy Frame Number were missing) |
| Haptics | `.levelChange` on Keep, `.generic` on Drop, `.alignment` at a zoom detent and at the last frame of a burst (NATIVE-M01) |

The tracked swipe is not started if it could ever show an undecoded frame: a half-released swipe
that lands on a blank is worse than an arrow key (`SwipeGate`). Where it is not started the swipe
steps a frame instead, as an arrow does, sharpening in place.

**The pointer says what it does.** Fitted, it is the ordinary arrow: nothing is being targeted, and
a crosshair over a photograph says a click will place or measure something, which it will not.
Zoomed, it is the open hand, and the open hand pans. The cursor is invalidated on every change of
zoom — `resetCursorRects` is called only when cursor rects are invalidated, and none of pinch,
double-click, smart zoom or force click changes the view's frame, so it used to show whatever it had
shown last until he left the view and came back.

**A scroll is a frame, as an arrow is.** A notch used to jump to the next frame the cull put
forward and stop at the end of the burst, so on his four-frame bursts most notches found nothing
ahead and only shook the picture 8 pt with a haptic — the likeliest "the mouse moves weird". Now it
steps frame by frame, as ← and →, and the rules that make → safe hold for it: **the first step of a
gesture is a press**, which may cross into the next burst and record the one he leaves; **every step
after it in the same gesture is a key held down** — it runs through the burst and stops at its end
with one bounce, because recording a burst is a claim about his work, not about a wheel still
turning. A gesture ends at a quarter-second with nothing from the device, at a change of device, or
where a trackpad says a new one began; so a spin stops at the end of the burst, and the next notch
after it goes on. Momentum never steps. ⌥ keeps the old reading, the cull's picks, for when he wants
to skim what it put forward.

**A scroll means the same distance whatever sent it.** One wheel notch is 16 pt and counts; the same
movement of a hand on a trackpad is hundreds of points, so a trackpad step is 120. At most three
frames are acted on per event and **the surplus is carried, not thrown away**, so the same movement
of his hand moves the same distance however the device chops it up. The carry is forgotten after a
quarter-second gap, not only where a trackpad says a new gesture began, because a wheel mouse has no
phases at all and so never got a reset: up to a threshold of stale carry survived from the last
scroll and could double the first notch of the next. Sideways, on a trackpad, one swipe is one frame
however far the fingers went, as the swipe the system tracks gives; the rest of that swipe is spent,
not saved.
**A turn the other way starts from nothing.** The carry belongs to the direction it was carried in:
kept through a reversal, a fast spin toward him and one notch away stepped three more frames toward
him, and a long swipe left then a quick one right stepped forward, as a fresh press that could record
a burst. A wheel turned back is a new turn of the wheel, so its first step is a press; fingers that
turn back without lifting are the same gesture still going, and a trackpad's new gesture is the one
it says began. **While the system is tracking a swipe, no scroll also steps**: the swipe is the
whole of its gesture, so one swipe can never move two frames.

#### 2.5.9 The filmstrip

96 pt (12 pad + 60 thumb + 4 + 14 caption + 6). Thumbnails 90 × 60 pt at 3:2, 6 pt apart, **every
frame of the burst in shutter order, nothing hidden**, current frame centred with a 3 pt accent ring
and its number in accent. **[call] clarity's geometry, speed's implementation:** an
`NSCollectionView` inside an `NSViewRepresentable`, because a SwiftUI `LazyHStack` drops frames at
200+ items on scrub and the collection view recycles.

**The cell is 3:2; the frames in it are not always.** A frame whose shape is not the cell's is drawn
**whole and centred inside the cell** — a portrait frame comes out 40 × 60 with the cell's own
surface either side, not grey: the grey is the placeholder for a frame still on its way and goes
when the picture arrives (it filled every cell whole, so a portrait burst read as a row of frames
that had not loaded) — and the picture is clipped to the cell, so nothing of it reaches the bracket
lane above or the caption lane below. Aspect-fill would centre-crop 56 % of a portrait frame's
height away, and the one thing the strip is for is seeing what is in each frame of the burst. The
current-frame ring, the Compare dashes and both marks below go round the **picture**, not the cell,
because what they mean is "this frame". A 3:2 frame either way up still fills the cell exactly.

The 90 pt item is a **ceiling, not a promise**: `NSCollectionViewFlowLayout` insists the item be
strictly shorter than the view it is laid out in, so the item is measured against the clip view's
real height on every layout rather than against a guess about the chrome. Where that leaves less
than 90 pt, **the picture gives up the difference** — the 12 pt bracket lane above and the 14 pt
caption below keep their own, because a frame's run and a frame's number are writing and nothing in
this strip is ever hidden.

**The strip has no scroll bar.** It pages itself to wherever the cursor goes, a trackpad scrolls it
sideways, and a wheel mouse turns it a frame a notch — a wheel only goes up and down and the strip
only left and right. A scroller cost more than it gave, three times over. Drawn inside the band it
lay across the caption lane and painted over the bottom of every frame number whenever it showed;
moved to the band's last few points, the overlay knob still ran across the bottom of the numbers;
and on a Mac with a wheel mouse attached — his — AppKit hands every scroll view the legacy style
each time the preference changes, whose 11 pt track stayed for good under the numbers, came out of
the clip view, laid the 90 pt item out 5 pt above the band and sliced the top off the "4 similar"
over a run where the strip meets the control bar. The collection view turns its scroller back on
for a sideways flow, so the strip's scroll view refuses one outright, and fits the item to the band
again every time it re-tiles. The document still stops 5 pt short of the foot (`contentInsets`, set
by hand), which is the inequality the flow layout insists on.

Marks — his and the machine's never share a shape:

- **His verdict:** `checkmark.circle.fill` green / `xmark.circle.fill` red, **filled**, bottom-left.
- **The cull's suggestion:** a white star and **Suggested** on an opaque purple banner,
  17 pt high across the thumbnail cell. Both ratings 3 and 5 are suggestions, including frames
  left standing in reviewed bursts. Portrait cells use the same banner width. Suggested frames
  stay at full brightness even inside a stack. A personal Keep or Drop replaces the prominent
  suggestion with his own mark; clearing that verdict restores it. The frame number, stack
  bracket and current-frame ring remain. The banner follows Show the Cull's Marks in the Filmstrip.
- The same **Suggested** badge sits in the control bar beside the main photograph, in the
  Full Image caption when its controls are visible, and beside unmarked suggestions in Compare.
  It does not add an overlay to the main photograph. Its help explains that leaving the frame
  unchanged when finishing the burst keeps it, while D drops it. The cull's spoken/text line
  explicitly says "Suggested by the cull" rather than "maybe".
- Other cull marks stay top-right: `circle.dotted` for set aside, an amber
  `exclamationmark.triangle` for a named fault, and the smaller original circle where his explicit
  verdict has taken precedence over a suggestion. Outline marks sit on a 50 % black disc.
- **Marks are 14 pt, 3 pt in from the picture's corners.** Under Increase Contrast they are 16 pt
  and bold, the discs go to 85 %, and his filled marks sit on a white disc so the check or cross cut
  out of them is white rather than whatever the frame is there.
- **The frame number** is 11 pt in the label colour at 62 % — about 6:1 on the bar in either
  appearance, full label colour under Increase Contrast — and the current frame's in accent,
  semibold. It was 10 pt tertiary grey, 1.8:1 on the light bar and 1.6:1 on the dark one, and these
  are the numbers he copies into PhotoLab.
- **Agreed** (he went through the burst and left the cull's call standing): **hollow**, never filled,
  and the call he let stand — a hollow green check where the cull put the frame forward, a hollow
  red cross (`xmark.circle`) where it set it aside, which is the engine's own rule for the frames he
  kept. It was the green check on every frame he left alone, so a finished burst looked as if he
  had kept all of it. Help tag "You agreed with the cull here."
- **A named fault:** thumbnail at 50 % opacity with a two-word caption ("eyes closed", "too soft").
  It is *there*. Nothing is ever hidden for looking like something else. The fault is the cull's
  — its 0, with its reason in the report's words. The reason **he** gives a frame he put out is his:
  his red cross, his line and the help tag ("you put this out — shadow"), never the amber triangle.
  It used to be drawn as the cull's, and the cull's own faults never reached the strip at all.
- **Stacks:** members sit together under a 2 pt bracket with its count at its start ("4 similar",
  10 pt, drawn inside the 12 pt lane — 9 pt was hard to read); each member carries the bar across
  the gap after it and none before, because the bar is translucent and a gap painted by both
  neighbours was a darker blot between every pair of frames. The top frame
  at full opacity, the others at 70 %. No strike-through, no "dup", and **the word "duplicate" does
  not appear anywhere in the product** (DUP-5).

The strip scrolls only when the cursor would leave it, and then by whole pages — it does not slide
under the pointer on every arrow press. **The frame he is on is always in the strip, ringed**, however
he got there: where its thumbnail is comes from the flow's own arithmetic (the margin, then 96 pt a
frame), not from the layout's attributes, which do not exist straight after the strip is rebuilt or
before its first layout — so on the last frame of a burst reached with ←, on a light table reopened
on frame 20 and after ⌘Z into another burst, the reveal gave up and the strip showed its first page
with no ring anywhere. Into another burst the strip jumps rather than slides. **Every thumbnail is
its own frame's picture**: the strip recycles its cells, and turning to the cursor's page hands the
first page's cells to other frames while their pictures are still on the way — a picture that
arrives for a frame its cell no longer shows is not put on it. It was, and on the last frame of a
long burst the ringed thumbnail wore the picture of a frame from the first page. Every thumbnail is
drawn from the thumbnail tier; a bigger picture of the frame already decoded stands in until that
arrives. **A press draws again only the thumbnails it changed** — two, the frame he left and the one
he arrived on: the strip hands every visible thumbnail its marks on every press, and every one of
them used to draw itself again, symbols and picture — the stage's full-size decode among them —
and all. Click goes to the frame (never decides) — every click, the
same thumbnail twice included. Double-click = Full Image. ⌘-click / ⇧-click builds a Compare set,
drawn as dashes round each frame in it: the frame he is on starts the set, so one ⌘-click on
another is already a pair; ⌘ adds or takes away one frame, ⇧ takes in the run from the last one
pressed; eight at most; a plain click lets the set go. Drag-select is off: the strip is a place, not
a canvas.

**A click in the strip never takes the keyboard.** The thumbnails and the strip behind them refuse
first responder, and the photograph is handed it back after every press, so K, D, N, the arrows and
Space answer straight after a click. The strip used the collection view's own selection, which made
the strip the keyboard's at the first click — the arrows went to it and Space and the digits went
nowhere until he clicked the picture — and a thumbnail it still held selected ignored the next click
on it: click 5, arrow to 9, click 5 again, and he stayed on 9. Each thumbnail is a button to
VoiceOver, named by its frame's own sentence and selected when it is the one on screen.

#### 2.5.10 The burst scrubber

18 pt, under the toolbar, one segment per burst across the full width, **minimum 8 pt per segment**
with horizontal scrolling beyond that — in the page each burst was a 5.94 pt target on a 155-burst
shoot (LT-10). **When it scrolls, it keeps the current burst in view**, centred, from the moment it
appears and on every move; it used to stay at burst 1, so on a 288-burst night at burst 265 the map
showed bursts 1–122 and no marker anywhere. **[call] clarity's target size at speed's slimmer height, plus speed's drag-scrub.**

**The burst he is on is always in view.** Scrolled, the strip centres it on arrival; after that it
scrolls only when the burst he is on would leave it, and only as far as it takes, with no animation
so a run of N does not make it swim, and it holds still under the pointer while a drag scrubs. It
used to centre on every change of burst, which slid a segment he had just clicked out from under
the pointer the moment he let go. Past about burst 122 of a 288-burst night at the default window the
current burst used to be off the end, with no scroll bar to say so. **A segment is drawn from its
own values** — burst, frames, kept, looked through, current — and nothing else, so a press that moves
the frame and not the burst redraws none of the 288, and a change of burst redraws two; each segment
used to read the cursor, and every arrow, K and D re-ran all of them.

States: looked through (filled, accent 40 %) · current (2 pt accent outline) · has keepers (3 pt green
underline) · not looked through (grey 15 %). "Keepers" and "3 kept" are his, counted from his marks by
the tally's rule as they stand now — the engine's per-burst count, read once when the shoot opened,
went stale with his first K and also counts the cull's picks he left standing. Hover shows "Burst 41
· 12 frames · 3 kept" as a **help tag**, the ordinary place macOS puts a sentence about the thing
under the pointer. Press and drag scrubs through bursts live, and a click is the beginning of that
same drag, so a press that wobbles 2 pt cannot be routed down a different path from one that does
not. The index is read in the strip's own coordinate space, so a strip scrolled sideways still lands
on the burst under the pointer. Click jumps there and **records nothing** — only leaving a burst
forward (N, → off its last frame, Continue on the last) marks it as looked through (§7.4). ⌘F (Edit ▸
Find Burst…) asks for a burst number in a sheet on the window, the way Preview asks for a page: type
it, Return jumps there, recording nothing the same way (§2.12).

**[call] REVERSED — no hover popover here.** This said the hover showed a popover with the burst's
cover. A macOS popover is a transient `NSPopover`: it closes on the next click *and consumes it*,
and this band is the 18 pt directly under the toolbar, which the pointer crosses on the way to every
control up there. One per burst — 155 on the reference shoot — each bound to a constant, so
SwiftUI's write of `false` went nowhere and the popover, presented downward over its own segment,
flipped that segment's hover off, closed, uncovered the segment and presented itself again. Its
content hosted a frame view that asked the engine for a cold RAW decode, ahead of the photograph he
was actually looking at, once per burst crossed. The help tag says the same sentence and costs
nothing.

As an accessibility element the scrubber is a slider whose value reads "Burst 3 of 19, looked
through".

#### 2.5.11 All Bursts (G)

The viewer area becomes a grid of burst covers, 180 × 120 + 32 pt caption, `LazyVGrid` (4 columns at
1100, 9 on a 27"), each captioned "Burst 41 · 12 frames · 3 kept", the current one ringed, bursts
not looked through dimmed. "3 kept" is the tally's count (§2.5.10): the ringed cover used to say "14
kept" beside a tally saying "Kept 15". **It opens scrolled to the ringed burst**, centred — it used
to open on burst 1 whatever burst he was in, which on burst 265 of 288 put his own cover 22 screens
down. S F and ← → move a burst at a time and bounce at either end, as ↑ ↓ do (← on burst 1 did
nothing), ↑ ↓ a row, R or N jumps to the next burst not looked through, Q or ⌘Z still undoes, and
Return, G or Esc returns to the ringed burst. S was Single here, so forward over the covers was F
and back was ←; it is the previous cover now, as it is the previous frame everywhere else (§2.5.3).
Same data as the scrubber, for when he wants to see rather than aim.

Nothing is decided from here. The grid shows covers, not a frame, and the frame a verdict would land
on is hidden behind them: Keep and Drop are greyed, and E, D, X and the digits (K and 0 as well)
bump and write nothing — K used to keep that hidden frame. Space, Z, ⌘0, ⌘9 and the zoom keys are refused the same
way, as their greyed Frame and View rows already said; Space used to put up Full Image of that
hidden frame over the grid. The captions are written straight onto the surround, so they take its
dark or light rather than the app's appearance (Neutral Gray and Black never change); in Light they
were dark grey on #3A3A3A, 1.5 : 1.

#### 2.5.12 Compare

C opens Compare on, in this order: the frames he ⌘-clicked or ⇧-clicked in the filmstrip (2–8,
headed "Compare 2 frames", not "similar", because the cull never said they were); the stack he is
standing in; the stack the invitation below names, going to its top frame first. C used to read only
the middle one, so a ⌘-click set was thrown away and the invitation's own "Compare (C)" bounced on
any frame outside its stack. While he is picking, a line under the picture says "2 picked · C
compares them · Esc clears" ("1 picked · ⌘-click another to compare · Esc clears" for one) **in the
invitation's place** — one line there, never two stacked over the bottom of the photograph, and his
picks are what C opens — and the invitation comes back when Esc clears the set. A plain click is
never part of it: it goes to the frame and puts the set down, as Esc, closing Compare or a move to
another burst does, so C then opens the stack he is standing in and not a set he clicked past. The
menu row, the bar's button and the toolbar's segment are live exactly when one of those three
exists, so none of them offers a press that only bounces; for a picked set the button carries its
count on the badge and "Compare the frames you picked (C)" in its help tag. Compare is a **mode of
the viewer**, not a sheet: same toolbar, same control bar, and Esc, C again or the header's "Back
to One Frame" returns to the frame that had focus — S did too, and is the previous tile now, beside
F (§2.5.3). It shows frames of one burst, so **leaving the
burst leaves Compare** — N, P, an arrow, the scrubber, a cover — and clears a set he was picking; it
used to stay open on the burst he had left while the bar named the new one, and the next K kept a
frame back there and pulled him after it.

- Tiles at equal size, laid out to maximise tile area: 2 across for 2–3, 2 × 2 for 4, 3 × 2 for 5–6,
  scrolling 3 × 2 beyond with "7 of 9" in the header; 8 pt gutters. At 1100 × 780 two tiles are
  538 × 359; four are 396 × 264. On a 16" full screen two are 852 × 568, four are 626 × 418.
- **Synced zoom and pan:** one zoom factor and one pan offset for all tiles, each tile aligned on
  *its own* aim, so the same eye sits in the same place in every tile. Z, pinch, ⇧-arrows move all
  of them. This is the whole point: on the 155-burst reference shoot, 81 of 156 close calls are
  sharpness calls, and the page had no side-by-side at all (DUP-7).
- Under each tile: frame number, **where the cull's own focus figure puts it among the tiles**, and
  his verdict badge — written in the surround's own light or dark, not the app's, so they read in the
  Light appearance too. The tile it measures sharpest says so, "⌖ sharpest of 4", in the surround's
  full ink; every other tile says how far under it it measures, "62% softer" ("as sharp" within half
  a percent), in 12 pt secondary; the hover has the plain figures ("Focus 61, against 161 for 07179,
  the sharpest of these 4 by the cull's own measure"). Counted over every frame compared, not just
  the page in view; exactly one tile is named, the first shown of equals; a frame with no figure
  says nothing, and neither does a set with fewer than two figures. They used to be "focus 61" and
  "focus 161" in the same faint 10 pt grey, and sharpness is what he opens Compare to settle. It is
  the cull's measure, not a verdict, and it moves nothing. The inspector's focus row puts the figure
  against the middle of its burst's, "161 · most in this burst near 140"; both used to set it against
  the focus setting of the next cull, 1.9, printed as "near 1".
- **The hand works on every tile**: pinch zooms all of them anchored under the fingers, a scroll or a
  drag pans all of them once zoomed, and a double-click is Fit ⇄ 1:1 at that point. A click puts the
  ring, the frame, the filmstrip and the bar on that tile; the label between Drop and Keep reads
  "2 of 4 compared".
- Keys: S F (or ← →) move the focus ring; E / D (or K) decide the focused tile and move to the next
  **undecided** member; **⇧E (or ⇧K) keeps the focused one and drops the rest of the stack as *his*
  verdicts in one undo step, then closes Compare on the first frame after the stack** — every frame
  in it has just been decided, so there is nothing left to compare, and it used to stay open on the
  tiles it had just decided, the way on being Esc and then → over frames already judged. A stack that
  ends the burst leaves him on its last frame, where going on is what E does there (Settings ▸
  Choosing). A set he ⌘-clicked can have gaps, and a frame in a gap was never in Compare: with frames
  1 and 4 kept and dropped, landing on 5 left 2 and 3 unmarked behind him, and a later N counted them
  as the cull's call agreed. So **the first frame in a gap he has not marked comes first**, and only
  with none is it the frame after the set; a stack the cull found has no gaps and lands where it
  always did. A refused ⇧E leaves Compare open with the refusal over the buttons. Esc returns.
- Header: "Compare 4 similar frames · E keep · D drop · ⇧E keep only this one" on a stack, and
  "Compare 4 frames · …" on a set he chose, which nothing says look alike. The top frame is
  labelled **"the cull's guess"**, never "the best" — measured, the quality top holds a keeper in 30
  of 57 stacks against 25.7 by chance (DUP-11).

**[call] Compare never opens by itself (speed, against clarity's softened version).** A view change arriving under a moving hand is how a keystroke lands in the wrong place.
Instead, on first entry to a burst containing a stack of more than three, that stack is drawn
**expanded** in the filmstrip and a quiet line appears under the picture: "4 similar frames ·
Compare (C)". Clicked, or C pressed on a frame in no stack, it opens **the stack it names** from
wherever he is before it. It stays up only while he is before that stack or inside it: once he has
walked past it, it goes, because there it could only bounce. It stands down on the last frame of the
burst, where the end-of-burst line says what matters: at the minimum window the invitation, the
reasons strip, that line and the caption stacked up over the bottom of the photograph, where the
feet are and cut off is judged. Settings ▸ Choosing has "Open stacks of 4 or more in Compare", off
by default. On, arriving on a frame of such a stack by a press of his opens Compare on it, once per
stack for as long as he stays in that burst, so Esc or S out of it is not undone by his next arrow;
opening the light table is not a press, and never opens it.

#### 2.5.13 Resume, and what "looked through" means

Opening Choose Keepers goes to, in order:

1. The burst named in `review.at`, if it still exists in the current cull —
   *"Back where you left off: burst 4 of 19. 3 looked through, 16 to go."*
2. Otherwise the first burst not looked through —
   *"The burst you were in is not in this cull any more. Burst 1 of 19."*
3. Otherwise *"Every burst has been looked through. You kept 14."*
4. A fresh shoot: *"Burst 1 of 19. E keep, D drop, F next frame, R next burst. Press ? for the rest."*
   — the left hand's keys (§2.5.3); the engine writes this note, and the app's own copy says the same.

**"Looked through" is the one phrase for this fact on every screen** — the overview's "288 of 288
looked through", the scrubber's "Burst 3 of 19, looked through" / "not looked through yet", "Mark
this burst as not looked through", the Presets split, these notes, and the engine's refusal to
gather keepers from a shoot with none ("the cull has picked 9 frames in bursts you have not looked
through"), in the app, in the engine and in this document. It was "been through" on some and
"looked through" on others, one Presets card used both,
and "368 in" was a third word for kept that appeared nowhere else.

When `review.stale` is set, the note is prefixed with the engine's own sentence about the count
being worked out again from the frames he pressed a key on.

Inside a burst he has not looked through it opens on **the frame after the furthest one he marked** —
the last frame, if he marked that — and on its first frame when he marked nothing in it or has looked
through it. It used to be frame 1 every time, so a burst he quit on frame 25 of 32 reopened with 24
frames to walk back over; and not the first frame he left unmarked either, because he keeps with K
and walks past the rest, and on a burst like that — Kept 15 · Out 1 · 16 unmarked — the first
unmarked frame is near the start. The engine names the burst, not the frame; the frame is read off
his own marks, which are already in the snapshot.

**[call] the server resolves the resume target and the burst grouping, not the app.** The page
keyed bursts by `scene/burst`, which splits one time burst across several screens on 56 of 89 bursts
of the reference shoot (DUP-6), and made the resume key look under keys the page never wrote. Fixing it in
one place fixes it for both readers. See §3.9.

"Been through" is a narrower fact than "has a verdict", and only leaving a burst forward — N, →
off its last frame, K or D on its last frame, or the last burst's Continue — records it (§7.4). Going back, jumping from the
scrubber and opening All Bursts record nothing; a scroll over the photograph is an arrow, and records
exactly when → would (§2.5.8). A burst can be un-marked from the header link. This exists so the count can never be the
machine's flattery of work he did not do.

### 2.6 The other steps

Each is a `Form(.grouped)` in the 680 pt column with the step's primary at the bottom right of the
form, once, where Return presses it and a running job draws its progress, so it is never below the
fold — the page's ingest error rendered off-screen at every window size (FLOW-02). It is not
repeated in the toolbar, which holds only a second action once there is one (§2.3): the same button
twice was two things to read for one action, and at 900 pt the toolbar copy crowded the inspector
button. The intro sentence, the cards and the
action bar share the column's two edges: a grouped form insets its cards 20 pt from whatever holds
it, so the scaffold hands it the column plus that inset on each side (`StepMetric.formInset`).
Given only the column, the sentence and the bar's text started 20 pt left of the cards and the
button stuck out 20 pt past them, on every step. In the bar, the text beside the button sits on the
button's own line of text ("About a minute." level with "Cull It", the clock level with the
progress box's words) and a longer sentence grows upward from there, so the box never moves; the two
were bottom-aligned, which dropped the text 7 to 10 pt below the words it belongs to.

**Copy the Card.** Card picker (appears on `NSWorkspace.didMountNotification` for a volume with
DCIM) with "Eject after copying". The app watches for cards for as long as it is open, not only
while this page is on screen (`ImportModel`, owned by `AppModel`): the page is only reachable with a
card in, so a watcher of its own never saw a card go in while he was anywhere else, and ⌘N stayed
greyed until some unrelated read of the library happened to notice it. A mount or an unmount reads
the list again at once, so the Memory Card row and ⌘N follow the card; with the sidebar hidden (the
light table below 1280 pt) a line floats over the top of the page — "Untitled is in. ⌘N to copy
it." (⌘N opens the page; the copy is still his press there) — in the opaque chip the stack
invitation sits in, never a band of the window: as a safe-area inset it shrank and lowered the
photograph in Choose Keepers the moment a card went in, while he was pressing K and D, and held it
there until he clicked. On Choose Keepers it sits under the burst scrubber, which it covered for its
eight seconds, and under the engine's restart line when both are up — one column over the page, so
the two stack rather than print over each other. The light table's own "Back where you left off"
line goes down under that column while it is up: behind the restart line only a sliver of its edge
showed, and behind both it was gone. The line moves nothing else under it; it goes by
itself after eight seconds, when he goes to any page, or when the card comes out, and clicking it
opens the card's page. Nothing moves him off the page he is on. The card is read the moment it goes
in, whatever page he is on, not when he reaches its page: read on arrival, a quick ⌘N and "-night" on
a 1,558-frame card beat the read, and the shoot got the Mac's date. The page asking again waits for
the read already out. Name field
prefilled with the day the card's last evening started, read off its photographs rather than the
Mac's clock (a shoot that runs past midnight, or is copied the next morning, is still the 19th; a gap
of more than six hours between frames is another evening, because the card is the backup and often
still holds the last shoot), bare as his shoots are named — `2026-09-19` — or `2026-09-19-` when a
shoot of that day is already in the library, with a note under it showing what to add. Until the
card has been read the field is empty with the example in it, never the Mac's date for a moment
that his typing could keep; a card read with no day on it falls back to the Mac's date. The caret is
at the end, never the whole name selected, so what he types is added to the day rather than typed
over it. A space or a slash becomes a dash as he types, a dash, dot or underscore left at the end is
dropped when he presses Copy, and the rule is the engine's own (a letter or a digit first), with the
reason *under the field* once he has typed or pressed Copy — "Start with a letter or a number." for a
name the engine would refuse, where the app used to send it and print the engine's sentence at the
foot of the window. The button says "Copy 1,558 Frames" ("Copy 1 Frame") at one width,
before the card is counted and after; "Check the copy" picker — *While copying* (one pass over the card) / *Again at
the end* (two passes, catches a failing card) / *Don't check* (fastest, proves the least); a live
`PathControl` showing exactly where it will go, ending in "…" while the name will not do (with
`2026-09-19-` and nothing added it showed the folder of the shoot already called 2026-09-19); the
extension's kind question if one is installed, read from its config at runtime, directly under the
name and starting on the kind of his newest shoot (by the day its name starts with) until he answers
it — it started on "no" for every card, below the fold at the minimum window, and every shoot of his
is that kind. When a shoot already holds this card's photographs — counted by the engine off the
card (`GET /api/cards` `described`, asked when the card is read), frame by frame against each
shoot's raw/ by name, size and time, never by the path the card mounts at — it says so with the
count: "All 1,558 frames on this card are already in 2026-09-19.", "The copy of this card into
2026-09-19 stopped at 412 of 1,558." when that copy's log says it stopped, "This card is being
copied into 2026-09-19 now." while that copy is running or waiting in Up Next, or "900 of the 1,558
frames on this card are already in 2026-09-19." for a card shot on since. Nothing otherwise. A
copy in flight writes the same log as one that died — a "copying" line and no result — so the engine
asks its list of work first (`info.ingest.state` is `copying`, and `described[].copying` is true)
and only a log with no live job behind it counts as stopped: the sidebar and this page said "stopped
at 412" of a copy that was running while he worked on last night's shoot. (It matched the volume
path, and his camera formats every card as "Untitled": every new card from the second night on said
"already copied as 2026-09-19".)
"Eject after copying" and "Check the copy" come back as he last left them (`copying.ejectAfter`,
`copying.check`): they are his habits, not a card's, and were asked again every evening. *Don't
check* is never carried over: the next card opens on the check he last chose before it, or *While
copying* — one evening's shortcut must not become how every later card is copied and then
reformatted.
The page is one card's. The sidebar's Memory Card row and the page's picker are one choice —
choosing a card in either chooses it in both, where the picker used to keep its own and copy the
first card whichever row was selected — and the page is built afresh for each card that goes in
(`ImportModel.generation`): every card his camera formats mounts as /Volumes/Untitled, so the place a
card mounts cannot tell tonight's card from last night's, and a second card used to inherit the first
one's name, result and greyed Copy. A card that goes in while the card page is up becomes the page,
unless that page is watching a copy. The card is read the moment it goes in, and the engine is asked
for its count then too; with no engine to ask, "This memory card was already copied as
2026-09-13-dog." is said only when a shoot's own folder holds the card's newest photograph, same
name, size and time (the copy keeps the time); the card's name proves nothing, and the old test
said it of every new card. The count on the button is the photographs the
copy will take — the engine's own RAW and JPEG extensions, which a test reads out of `common.py` —
not every file on the card.
The copy belongs to the app, not the page (`ImportModel`). Pressed while something of his runs, it
goes on the list and says so; it never waits inside the page, which threw the request away when he
left. It goes there by the copy's own route with `queue`, so the extension's kind goes with it: the
list's general route reads `kind` as the kind of work. While it runs or waits, the form holds the copy's own name, check and folder, none of which can
be changed; "Eject after copying" stays live and is read when the copy ends. Leaving the page and
coming back shows the same copy in the same box, never a fresh Copy button for the same card. When it
ends, on whatever page he is, the card it copied — not whichever one the picker shows — comes out if
he asked, and when he is elsewhere the same floating line says how it went, in the copy's own
sentence, and goes the same way. After a copy that finished, the page is its result, not the form with a greyed button and a
red "already in your library" about the shoot he has just made: the copy's sentence as the headline,
"Nothing on the card was changed.", whether the card was ejected, where its cull is ("Its cull has
started by itself." or "Its cull is in Up Next and starts by itself."), the card, the frames and
"Copied to", and "Cull 2026-09-23-night ›" in the primary's place, which Return takes to the Cull step,
where that cull is running — except while an earlier card's copy into the shoot did not finish,
when it is a plain button under that copy's red sentence. **After a copy that finished, the cull of its shoot starts by itself**,
with his last shoot's settings (the Cull step, below): the copy is sent with `then_cull`, and when it
ends well the engine puts a cull of that shoot on the list — at once, or behind whatever he had
already put there, and held when the list is held. Never after a copy that stopped, failed or was
refused; never a second one for a shoot whose cull is already running or waiting, nor for a shoot
already culled, whose cull is his to ask for, nor for a shoot any copy into which stopped, failed or
ended unreadably — a card of it is still half there. It was three trips every evening for a step he never
skips — a small link, the two settings set back, Cull It — and the seven minutes only began once he
came back to the Mac. Beside Copy, and while it copies: "When the copy is done, the cull starts by
itself, set as your last shoot was culled." — and, before any shoot in the library has been culled,
only "When the copy is done, the cull starts by itself.": there is no last shoot, and the cull starts
on 1.9 and off. A copy that did not finish — he stopped it, the engine refused it, or the
card came out — says so above the form, or above "No memory card is in.": the copy's own sentence for
that shoot, what ended it, and what he can do now. If the card comes out while it runs, the form and
the bar stay, and say so in red. While it runs the form shows the copy's own answers — the name, the
check, and the extension's kind it was sent with, not the page's starting one.
The bar's Stop stops this copy and nothing else: it is there only while the engine says this copy is
running, and it sends the copy's number, because the engine's stop without one stops whatever is
running. The bar before the engine's first answer about the copy has no Stop. A copy the app loses
sight of — the engine restarted under it, or it ended between two reads while the list started the
next thing, so the engine never says that job ended — ends the moment the engine's one slot is seen
holding anything else, or nothing, and after a restart at once: the shoot's own note says how far it
got, with "The engine stopped while it copied." under it for a restart, and a copy whose own log
says it finished is a finished copy (a copy left running by an engine that crashed carries on by
itself). It used to say "Copying…" for the rest of the evening, and its Stop, the engine's stop with
no number, stopped whatever ran next — his cull. A copy still waiting on the list is left alone: the
list is kept on disk across a restart. A card put back in after a copy that did not finish keeps
that copy's sentence above the form, and **the copy finishes into the same shoot**: "Copy into" is
set to "2026-09-23-night, to finish the copy", with "Only what did not reach 2026-09-23-night is copied.
What did stays exactly as it is." under it, and the button reads "Finish Copying 1,146 Frames" —
the card's frames less those the engine counts already in that shoot ("Finish the Copy" when
every file arrived and the copy stopped in its check). It was refused, by the
page and by the engine, and the only way on was to copy all 1,558 again under a new name and bin the
half shoot by hand; the sentence said "Copying it again needs a new name", which is now said only of
a shoot that has since been culled. **A second camera's card can join the night's shoot until it is
culled**: "Copy into" lists, after the copy to finish, the shoots of the card's own day that have not
been culled and whose every copy finished ("2026-09-23-night, adding this card"), but not one that
already holds all of this card, and starts on "A new shoot" — a card is added to a
shoot only when he chooses it. A shoot whose cull is running is listed as "2026-09-23-night, being
culled now", with "… is being culled now, so a card is not added to it. Stop its cull in Activity to
add this one, or copy it into a new shoot." under it, and Copy waits: it was offered as "adding this
card" and the press refused. Adding one hides the name and the extension's kind (the shoot keeps
its own), says "Its frames join 2026-09-23-night. Nothing already in it is changed, and a frame
that shares a name with one there is kept beside it.", and the button reads "Add 986 Frames".
The engine takes it as `into` on the copy's route, and refuses a shoot that has been culled ("… has
been culled, so a card is not added to it now. Copy this card into a shoot of its own."), whose
cull is running ("… is being culled now. Stop its cull to add this card to it, …"), or into which a
copy stopped, failed its check or ended unreadably, to any card but that copy's own: "The copy of
another card into 2026-09-23-night did not finish. Put that card back to finish it, or copy this one
into a shoot of its own." That card is the one holding frames there, the same number of photographs
as the unfinished copy's card when its log says (`_copy_into`). A second card let into a shoot whose
first stopped at 412 of 1,558 wrote over the first copy's log, the shoot read "done", the cull
followed on half the night, and the first card could then no longer be finished into it — a card he
might format thinking the night was copied. All of it is asked again when a copy waiting in Up Next
gets its turn, so a card put on the list behind a copy that then stops is not copied. ingest.py was always written for this: it never overwrites,
skips a frame already there byte for byte, and keeps both of two frames that share a name. A cull of
the shoot waiting in Up Next moves behind the card added to it, so it is one cull over both cards,
and the cull that follows the copy is not asked for twice. Every earlier card's copy keeps its
log (`ingest-1.log`, beside the last), its only proof, and the shoot's Copy the Card step and the
result page say it under the last copy's sentence: "Before it, another card: 1,558 frames
copied, verified byte for byte, both sides." Only the run that finishes a copy writes over that
copy's log; should any other copy ever start over one that did not finish, the unfinished log is set
aside and kept like a finished one, and said in red under the last copy's sentence ("Before it,
another card's copy stopped after 412 of 1,558 frames. Put that card back to finish it."), so the shoot
never reads as copied while one card of it is half there. A finished copy's result goes when another card goes in.
While copying, progress replaces the button in the same box: files, bytes, throughput, "checking as
it copies". After: *"1,157 frames copied and checked. Nothing on the card was changed."* The
step's summary paragraph afterwards is built only from the copy's own log, never from a listing of
the folder — including the three honest failure sentences. A shoot's own Copy the Card step is that
record afterwards: the copy's sentence, the card, the frames and "Copied to" with its folder, and its
way on is "Cull ›" in the primary's own place at the bottom right, which Return takes. It sat in the
middle of the bar as a small link, because an `EmptyView` in the bar's leading slot takes no width.
Return takes it only when the copy's own log does not say it stopped part way, failed its check or
ended unreadably (the three sentences in the alarm colour), nor an earlier card's under it: then "Cull ›" is a plain button in the
same place, and Return does nothing, so he is not carried on to culling a shoot that holds 412 of
the card's 1,558 frames. A shoot copied before copies kept a log is not one of the three.

**Cull.** One slider, "How fussy about focus", from *Lenient* to *Strict*, with a live word and
the number beside it ("normal 1.9", the number held against the edge while the word
changes); a switch "People move between frames" for the engine's `style` flag, noted "Turn it on
for sport, dancing, anything that moves fast."; the time estimate; "Cull It". The slider is
continuous and follows his hand — a stepped one drew nineteen ticks and jumped from notch to notch —
and the value is rounded to one decimal where it is printed and where it is sent. Nothing on the
page takes the keyboard when he arrives: the slider did, so an arrow pressed out of habit from the
light table changed the next cull's setting. **On a shoot no cull was asked of yet, both start as his
last shoot was culled**, with "Both start as you culled 2026-09-19." above them: the engine answers
`style` and `focus` with that shoot's (`cull_from` names it) — the newest by the day its name starts
with, of the same kind when the shoot has one, and what cull.py recorded it ran with, else what was
last asked of it — and 1.9 and normal only when no shoot of his has been culled. The focus is the one
he set there: a card whose own scale is outside every card the floor was set on has its floor moved
for it, and cull.py keeps the number he set beside the one it used (`cull_ran_with.asked`), so a new
card does not start on a value he never chose and is moved for its own scale in turn. Every new shoot
opened on 1.9 and off, and nearly every shoot of his is of people moving fast: he set both back every
evening, and a cull he forgot to set ran seven minutes with the wrong ones. A cull started without settings of its own (the one after a
copy, below) runs with the same. Once a cull is asked of the shoot, its own are what the page shows. The note under the slider is the same every time: "A
face softer than this is marked soft and shown last. Nothing is removed. Lower for sport and
dancing, higher for posed portraits." While his cull starts, runs or waits on the list, the slider
and the switch are held still under "The cull that is running is using these. Stop it to change
them." ("The cull is starting with these." until it runs; "The cull in Up Next will run with
these. Remove it from Up Next to change them." while it waits) — they stayed live, and a nudge
mid-run changed nothing about that run and silently changed the next. While it waits in Up Next they
show what it was put there with, which the list sends with each item (`opts`), and not what the shoot
says, which after a relaunch is the last cull started and could read 1.9 over a cull added at 1.6.
A cull that crashes leaves "The cull stopped with an error. Nothing you have marked was changed." in
the alarm colour beside the button, with Show the Log; it used to fall back to the time estimate, so
a cull that died looked like one never started.
**[call] the "Fast action" checkbox stops controlling stacking (clarity/dupes).** Stacking uses the
shoot's own median frame-to-frame change and needs no setting (DUP-9); the flag survives only where
other stages still read it, and it is labelled in plain words.
After a cull, the same screen becomes the report — no separate card:

> **It put forward 150 of 1,558 frames.**
> ⚠ 283 with a fault it can name: eyes closed 131 · too soft to read 77 · blown highlights 70 · face in shadow 5
> ◌ 863 fine, not the best of their moment
> ◌ 262 stacked behind a similar frame
> You have marked 316 of the 1,558 frames yourself.
> Culled with focus 1.9 (normal), for people moving between frames.
> [What the Cull Has Learned ›]

Each row carries the mark the filmstrip draws for those frames (the orange triangle, the dotted
circle), so the report teaches what he is about to see. The faults (rating 0) and the fine frames
that were not shortlisted (rating 2) are never one number: "1,146 set aside" hid how many had
anything wrong with them. The faults line names at most four reasons and ends with "· N other", so
its counts always add up to the number in front. Each reason is held to its count with no-break
spaces, so a narrow window wraps the line only at a " · " — at 900 pt it broke "face in / shadow 5".
Reasons are said in his words — the engine's `blink` is "eyes closed", `face in the dark` is "face
in shadow", a `blown face` counts with blown highlights — and a rating-2 frame's reason (the tier's
own name) is never printed. His own count names the whole it is out of: "316 of them", straight
under "262 stacked behind a similar frame", read as 316 of the 262. The settings line is what the
cull whose results are on screen ran with, as `cull.py` records it beside the shoot only once it has
put `cull.csv` in place (`info.cull_ran_with`) — not what the slider says now, and not
`info.focus`/`info.style`. Those two are written when a cull *starts*, as what the next cull starts
from, and are 1.9 and normal when nothing was written: after a re-cull he stopped, or one that died,
they named settings nothing on screen came from, and on a shoot that recorded nothing they were
defaults printed as a fact. A shoot culled before the record was kept has no settings line. "Culled
20 Sep with what it had learned then" waits for the engine to send when it culled.

**Each fault and its count is a link to its frames.** Clicking "eyes closed 131" opens Choose
Keepers on the first of those 131 frames, in the order he shot them ("· N other" opens the rest of
the faulted frames), because the way to check that the cull was not too harsh on a frame caught
mid-blink used to be a walk through all 288 bursts. While he looks through them a line stands where
the resume note does, "Put aside for eyes closed · 12 of 131 · F or → the next · Esc stops" with a
Stop link, and on the single frame and over it in Full Image: F and S (or → and ←), and the wheel,
go to the next and the previous of them, across bursts (↑ ↓ and ⌥-scroll still go to the cull's
picks in the burst he is in); R and W (or N and P) to the first of them in the next and the previous
burst that has any; E, D and the digits decide the frame on screen exactly as they always do,
without waiting for the engine, the strip after D and the question on a kept frame included, and
then go on to the next of them, never on out of a burst (X clears the mark and stays, as it does
anywhere). **It records nothing as been through** (§7.4), however many bursts it crosses: it is a
way of looking, not of finishing. So an E on a burst's last frame there does not finish that burst
whatever Settings ▸ Choosing says; the end-of-burst line, whose "Next burst" and Continue would, is
not shown; the Next Burst button stays Next Burst on the last burst, never On to Presets; ⌘] on
the last frame of the shoot goes on to Presets and records nothing; and in Compare, where the
ordinary R finishes the burst, R and W close Compare and go to the first of them in the next and the
previous burst that has any. ⇧E there keeps the one and puts out the rest as always, then goes to
the next of them after the set. A frame he clicks to that is not one of them says "131 frames", and
F goes to the next of them after it. Otherwise Compare and All Bursts are what they always are, and
the list is there again when he is back on one frame; Esc, after Full Image and a ⌘-click set, stops
it where he is, and so does leaving Choose Keepers, so coming back by the sidebar or ⌘[ is ordinary
culling again. Another fault's click replaces it.

Under the report the slider and the switch are folded into one row, **Settings for Cull Again**,
shut until he opens it and then left as he left it for that shoot: at full size they took most of
the page and mattered only if he culled again.

Once the shoot is culled, the box at the bottom right holds **Choose Keepers**, on Return — what he
does next — and "Cull Again…" moves to the toolbar alone, with ⌘R. By habit he pressed Return after
every cull and got the re-cull sheet, and the way on was the second of two small links.
"Cull Again…" opens a sheet: *Cull this shoot again?* / "Your 14 keepers and every frame you have
marked stay exactly as they are. Only the cull's own suggestions are replaced, using focus 1.6 (a
little lenient), for people moving between frames. About 2 minutes." [Cancel] (default) [Cull
Again], or [Add to Up Next] when the press adds — ⌥ held, or his work running — as the page's
button then says; it read Cull Again and added. Not red: nothing of his is at risk. Cancel carries
the default action itself: an alert left to choose makes the button that is not Cancel the default,
and a reflex Return would start the re-cull. The pictures draw this sheet by hand rather than as AppKit's alert, so they cannot show
which button Return presses; one look in a real window settles it. The settings named are the page's, which are what the
run will use, so he never confirms without seeing them; the time is the page's own estimate, so a
small shoot reads "About a minute.", not "About 1 minutes."

**Presets.** The honest split shown in §2.4; "Written for" — the editor picker, one row with what
that editor gets under it (where it is installed is the picker's help, and "Not found on this Mac"
only when the disk has said so); "Also write the frames you put out" with its cost; the destination
`PathControl`; "Write the Presets", with "About 2 minutes." beside it before the first write (368
keepers took about two minutes on the 2026-09-19 shoot; keepers ÷ 200 a minute, said the way Cull
says its own). The form is disabled while the job runs: what is set there goes with the next run.
The "Leave those N out" toggle is drawn only where the engine can be told to — it sat disabled on
every shoot under a note blaming "this engine". After: what **the run** did, from the engine's own
counts (`presets_ran`, §3.9-8, read off the run's own log): *"Wrote a preset onto 285 frames · 83
you had changed in your editor kept your edit."* — "· 368 already had one" after a run that
refreshed nothing, and after Write Them Again *"Wrote a preset onto 368 frames · on the 14 you had
changed, your changes stay on top."* It counted the sidecars on the disk, so a run
that wrote nothing still read "12 presets written onto 368 files". Where the log cannot be that run
(none, one that did not finish, a cull that wrote the presets since, another editor's), what is on
the disk ("12 presets written for 368 frames."). The engine's note on how the looks were set is
DxO's own words ("Manual 23; AsShot 23") and is that line's help, not a sentence on the page.
**Once they are written, the box at the bottom right holds Open My Keepers in PhotoLab**, named for
the editor, on Return: it opens the keepers as the Edit page's Open does (`StepsModel.openKeepers`,
one action for both pages) and brings the Edit page up, which says it opened, or why not, and counts
the exports as they come. By habit he pressed Return after the job and got "Write the presets
again?", and a second Return started two minutes of the same work; the way on was a small "Edit in
PhotoLab ›" link, which is gone (⌘] still goes there without opening). **Write Them Again…** moves to
the toolbar alone, with no key, as Cull Again… does on Cull. It opens a sheet with [Write Them
Again] as the default ([Add to Up Next] when the press adds, as the Cull sheet's does): *"Every
frame gets its preset written again. On the 14 you have changed in your editor, your changes stay
on top of the new one."* That is what the rewrite does — it replaces
the starting preset under each of his edited frames and keeps his changes over it; a plain write is
the one that leaves them wholly alone. The count is the frames the last run found his: the ones a
plain write left alone, or the ones a rewrite wrote under his changes (a rewrite leaves none alone,
so after one the sheet said nothing of his had been found). It was "Skip the Frames You Changed",
which was never a choice, and then "keep your edit … every other frame gets its preset written
again", as if his were not touched. By either route — ⌥ or a running job makes it "Add It to the
List", which sent a plain write that skipped every frame already carrying a preset. The job's progress counts scenes ("reading the light: 12 of
180 scenes"), not "setups".

**Edit in PhotoLab.** Named for the editor the presets are written for (the shoot's own, else the
Settings default), and so is its button. Under the heading, what Open does: "Builds a folder of only
your 23 keepers and opens it in PhotoLab. The RAWs in it are hard links: it takes no disk space, and
deleting it deletes nothing." Then a real `List` with symbols, not prose: "23 keepers, each with its
preset beside it" / "A folder holding only those frames" + `PathControl` + Show / "0 of 23 exported
so far" / one "Where they are" row + `PathControl` + Show per folder the engine found exports in
(`export_dirs`: export/, edit/ or a folder in it — PhotoLab's own default is edit/edited), or, before
any, "Exports are looked for in" + export/ with no Show. With two or more folders each row is named
for its place in the shoot, "In export" and "In edit › edited": two rows both called "Where they
are", with the path control cutting exactly the part that tells them apart ("2026-0…"), read as one
folder shown twice. The export count is live from an
`FSEventStream` on the export folder, with the engine's `?light=1` poll as a backup. Footnote: "No
preset showing? Your editor knew this folder from before — in PhotoLab: File ▸ Sidecars ▸ Import."

Open is never the primary while the presets are not on disk, because that footnote is the trap:
PhotoLab keeps its own record of a folder it has opened, and presets written a minute later do not
show. With none written the first row reads "23 keepers, with no presets written for them yet" and
the primary is **Write the Presets, Then Open** (the Presets page's own settings); while they are
being written it reads "The presets for these 23 keepers are being written", the engine's progress
sits beside the button, and the primary is **Open When the Presets Are Written** — pressed, it
says "PhotoLab opens as soon as the presets are written, while this page is open.", because leaving
the page drops the request rather than open the editor over a screen he has moved to. Either way
"Open Without Presets" is a link beside it for the deliberate case. Shoot ▸ Open My Keepers (⇧⌘E)
presses it only while pressing it opens (now, or once the presets being written are on disk): with
no presets the same key started two minutes of writing under that name. Return on the page's own
primary, which says it writes first, still does. There is no toolbar copy of it (§2.3). When the presets job ends the page
reads the shoot again — the first row ticks without leaving the shoot — and opens the editor if he
asked; a stopped or failed run says so and opens nothing. After Open: "Opened in PhotoLab at 21:14."
while the editor takes its seconds to appear — only once macOS has said it is opening: the engine waits
for `open`'s answer (up to ten seconds) and a refusal is the page's line, "PhotoLab did not open: …".
A timeout says opening could not be confirmed; the launch helper is stopped and given a bounded wait
for cleanup, never treated as success. The sidebar's Open is available only with written or pending
presets, and its request names the right-clicked shoot before navigation. If the page reads a newer
state without presets, it explains why opening cannot proceed. Once something is exported, a "Finish ›" link. The
engine opens the keepers in the shoot's editor, found in the Applications folders by name — at the
top or one folder down, where Adobe puts Lightroom Classic — or in Finder with a sentence saying
which editor was not found — it only ever looked for PhotoLab, and
"Open My Keepers in Lightroom Classic" launched PhotoLab.

**Finish.** Exports, with one "Where they are" row + `PathControl` + Show per folder the engine
found them in, named "In export", "In edit › edited" when there are several (as on Edit; it was one
comma-joined sentence of paths that could not be opened);
"154 keepers recorded: the frames you exported" — where they came from (`recorded_from`), read off
the record itself: every recorded frame exported is "the frames you exported", some of them is "the
frames you exported and the ones you kept", none is "the frames you kept". It was the rule for a
finished shoot, and Finish records before it marks the shoot finished, so it named only the exports
over 368 keepers beside 356 exports; read off the record it is true of shoots finished before this
too; under it, "The cull learns only from the 356 you exported" (`taught`, below); the storage
panel (§2.8); "Finish This Shoot", which prints in place: *"Finished. The cull learns from the 356
you exported. [What the Cull Has Learned ›]"* and "Finished on 22 Sep." where the button was — what
it learns from, never when. Under the sentence, one line of what Finish did about learning, written
from the engine's answer and Settings ▸ Learning (`FinishStep.learningLine`): *"The cull is learning
from this shoot now."*, or the engine's own note when the run waits — *"Learning from it starts once
the Mac has been left alone for two minutes."* (only when idle), *"Learning from it starts when the
work running now is done."* — and nothing at all with automatic learning off. The sentence promised
learning "the next time the Mac is idle" whatever the switches said: with learning off, with learning
starting at once, and above the engine's note that said the same thing again. Read again later, the
page says only that it is finished and what it teaches from; what happened about learning then is
the learning page's. Return presses it only once something is exported. The note above it: "Finish
This Shoot records your keepers, and every later change to the cull is checked against all of them.
The cull learns only from the frames you exported." It said to press it before removing the RAWs;
Remove the Local RAWs now waits for it by itself (§2.8). One name for the step everywhere — Finish.
**What Finish teaches is the frames he exported, not every frame he kept.** His answer, when the
page said 368 kept beside 356 exported: "only train based on what i've exported. i tend to cull
further during editing." The two numbers are two things now, said on two rows. The recorded keepers
— the answer key, `selects.json` — are recorded exactly as before, all 368, and the keeper check
measures every candidate against every one of them: a frame he kept and threw out in PhotoLab is
still one no learned model may hide, so the check is exactly as strict as it was. What the learners
are given as his is `learned.taught`: the frames he exported, found now or written down the moment
he finishes (`exported.json` beside the answer key, which only grows, so a shoot whose export folder
moves later still teaches what it taught). It is written even when nothing exported is found, as an
empty list. **A finished shoot also teaches what the learning store recorded of its exports
(`learned.stored_exports`), beside those two, and never its keepers**: each finished frame's row
says whether it measured as exported and carries its export's size and date, and the skin readings
are one row for every export file the starting edit ever read, by path and date. One export found
today does not throw the rest away — the record only grows, and an export that has gone out of reach
is still one he delivered. **An export counts for a frame only inside the frame's own window**
(`taste.export_counts`, which `is_exported` uses too): after the frame existed — when the camera
took it, or its RAW's own date if earlier; with no capture time recorded, the start of the shoot's
own day, since a RAW brought back from iCloud is dated the day it came back — and before the camera
took another frame with its number in any later shoot of the library, because it reuses its numbers
every ten thousand frames and he shoots about 1,500 a night. The RAW is found by number, whatever
cull.csv calls the frame (2026-09-12-lounge's names the decoded JPEGs), and an export inside another
shoot's own folder is that shoot's. 2026-09-16's RAWs came back on 2026-09-22, after every export of
them; read against the capture time, its 155 exports read as exported again wherever they are in
reach. With nothing found, written down or recorded, the shoot teaches nothing ("Finished. Nothing
you exported was found, so the cull has nothing to learn from this shoot yet."). The keepers used
to stand in there, and a keeper is where he starts editing, not what he chose. The starting edit
fits on the edits of those frames — every finished frame is still measured once and kept, and the
ones he edited and did not export are counted apart on the learning page ("… do not teach: only
what you export does"); the tier order learns which frames of a burst are his from them; the drop
reasons take them as the frames that are not the fault, and a reason on any keeper of his is still
never an example of one. Measured on a copy of his learned folder and a clone of his library, with
three stand-ins for iCloud (empty; rebuilt from the store's own export records; the same with one
of 2026-09-16's exports touched today): the starting edit teaches 436 of 838 measured frames in all
three (2026-09-19 82 of 87, 2026-09-21 198 of 200, 2026-09-16 155 of 351, 2026-09-12-lounge 1 of 2,
2026-09-05-the-gals none of 198). The store holds no export of the-gals at all — its rows carry no
export and it has no skin reading — so the keepers' 12 are gone and nothing replaces them; the 838
cannot come back from what is on this Mac. The lounge teaches its 27 exports — the 25 read off
iCloud, which are its 25 keepers, and two more in its own export/ — where the first cut of this rule,
unable to date them, taught 7; 2026-09-13-dog teaches its 14; the tier order is unchanged where it
learns (2026-09-16 153, AUC 0.61). Three skin readings dated after a later shoot's frames with
the-gals' numbers are that shoot's and teach nothing on the-gals. The answer key, `ShootCheck`,
`keeper_check`, `shoots_with_verdicts`, `_check_for` and `check_edit` are untouched, and on those
copies every candidate's check is the same bytes before and after.
**The one in use is counted by the same rule (his decision, 2026-09-24).** The starting edit in use
came with the app and was counted as 527 frames when every finished frame taught, and `check_edit`
holds a version that learned from fewer frames than the one in use — which every version learned
from his exports did (436). Both counts are now made by one rule, `learned.edit_count` over
`taste.teaching_rows`, from what each version kept of where its frames came from. A version learned
from now on keeps the frames it was fitted on, by name (`taught_frames`, in the model and not in the
manifest), and is counted again frame by frame. One that kept only how many came off each shoot
(`dataset.shoots`), or only its kinds of light keyed by shoot id (the one that came with the app), is
counted shoot by shoot, and since which of a shoot's frames it drew is not known, the count is a bound
and always the strict one: the one in use at the most it could be (each shoot's share capped at what
that shoot teaches today), the version weighed against it at the least (each shoot's share less every
measured frame of that shoot that does not teach). A kind of light carried over from the version
before is not among a version's own frames and is not counted, and no count is ever above the
version's own: counted with its carried kinds of light, 20260922-180651 read "at most 435 of its 283".
The kinds of light of the one that came with the app are matched to shoots by the id each shoot
answered to before it carried one — the hash of where it sits in the library — worked out from the
shoot names the learning store keeps, so the match holds after the folders leave this Mac; the shoot
folders' own ids are asked after. One that kept nothing keeps its own count; when that is the version
weighed against the one in use, the one in use is not counted again either and both are compared as
they were learned, the old rule, because one count by today's rule against one by the old would favour
the version that cannot be counted. Frames nothing accounts for — a shoot the store never measured, a
frame on no kind of light — count as they were for the one in use and not at all for the version
weighed against it; a shoot he took out of the measurements teaches nothing. Reading the library for
the count never fails the check: `submit` and `back` read it before they lock the manifest, anything
that cannot be read counts both versions as learned, and the sentence says so — the check runs inside
the learning run's `submit`, outside the run's own guard, where an error threw away a starting edit
that had taken minutes to learn. The check's sentence says both numbers and how each was made — "(3
against 5, counting only what you exported for both; the one in use kept no list of its own frames, so
it was counted shoot by shoot: at most 5 of its 17 are frames you exported)" — and says them too when
the count was made again and holds nothing, because the row above it gives the one in use's own count.
The held row's paragraph about whose 527 they were and whose call it was is gone. **Going back is
weighed by the same rule, and is stricter for it:** once a version learned from his exports is in use,
going back to the one that came with the app is held on its count — at least 132 of its 527 against
436 — where the 527 it was learned with let it through. That is the rule applied to the version going
back, not a new one; Use It Anyway is still his. The white balance, the exposure type, the kinds of
light, the answer key, `ShootCheck`, `keeper_check` and `shoots_with_verdicts` are untouched: the
same source, and on a copy of his learned folder the drop-reason and tier-order checks are the same
bytes before and after. A check records rules 5, so the one held under 4 is worked out again on the
next run. Measured on a copy of his learned folder: today's rule teaches 436 (2026-09-19 82,
2026-09-21 198, 2026-09-16 155, 2026-09-12-lounge 1, 2026-09-05-the-gals 0); the one in use, counted
by its two kinds of light, is at most 156 of its 527 (none of the portraits' 198, 155 of the gym's 328,
and the one frame no kind of light accounts for, counted as it was); a version learned now counts 436,
frame by frame. The count no longer holds it, where before it was held "(436 against 527)", and its
white balance and exposure type decide. The version held since 2026-09-23, counted again shoot by
shoot at least 436 of its 838, is still held for its white balance on the shoot 2026-09-21: right on 21
of that shoot's 38 finished frames, where leaving it alone is right on 29. Those numbers were read with
iCloud Drive left out: an export there that the export index would find is not in them. On his Mac
2026-09-05-the-gals could teach more; that raises both counts, the one in use's by at most as much as
a new version's, so it cannot turn the result round.
**[call] "Re-read what I kept" is gone (clarity/retrain).** Exports are noticed on their own; if the
recorded count would shrink, a sheet asks where it fires, written by the app from the two numbers:
*"Record 3 keepers instead of 154?"* / "This shoot's recorded keepers are 154. Most of the frames
they came from cannot be found now, so recording what is on the disk would keep only 3. Nothing
changes until you choose." [Keep 154] (default) [Record 3]. That cause is given only for the refusal
that knows it — a finished shoot whose exports cannot be found. The other, a new list under half
the recorded one, can as well be his own changed marks, and says only "Recording your keepers as
they stand now would record only 3 in their place." The engine's sentence names no file and
no button ("Not recorded: this would replace 154 chosen frames with 3. Nothing was changed."); it
named selects.json, told him to press a Re-read button that is gone, or to delete the file by hand.

**Instagram.** Every build has it, after Edit in PhotoLab: one wall of the shoot's exported
photographs, each with the cut its Instagram copy will have drawn on it, worked out in the
background the moment the step opens; a tick chooses what is made, a click opens the cut to adjust,
and Make N Copies writes exactly the cuts shown. Its keys are Choose Keepers'. All of it is §2.17.

**Reels.** Present only when the engine reports it can encode. Three regions: bursts list (220 pt,
searchable, sortable by number or best first) | preview + frames | inspector. The frame grid's
**single click toggles a checkbox in the tile corner, and double-click, Space or force click opens
the frame large** — in the page any click on a 190 px tile both decided and was the only thing a
click could do (FLOW-01). A frame taken out is grey under a scrim and says Out; a frame not yet
exported is drawn as it is, with a small "Not exported" badge only when the burst is partly exported
(all or none, the draft line says it once; while the wait on PhotoLab watches the burst, its line
counts instead). Both used to be drawn by dimming, and a burst mostly not exported read as all out. Inspector: format (Push In / Sequence /
Loop / Boomerang / Timelapse) with one line each, speed, "crop follows" (**whatever is moving · the
people · nothing, locked off** — any further option is contributed by the extension at runtime),
"slow into the push-in", size, and the output `PathControl`. `AVPlayerView` at 9:16 shows the last cut.
As built, under it: "This shoot's last reel, Yesterday at 3:16 PM" (today and yesterday said so, the
year only when it is not this one) and its file name on one line, less the shoot's name in front of
it and cut from the front when it still does not fit — beside "Burst 93" the player read as burst 93's
reel, the raw "2026-09-20 15:16" and the name wrapped to four lines in the narrow layout, and cut in
the middle it kept the shoot's name every reel shares and lost the end that tells them apart. Which burst a reel is of is the reel maker's naming, which is private;
until the engine says it beside each reel, the page does not guess it from the name. The player does
not play when the page comes on screen, but a reel he cut from the page plays, muted and looping, as
it comes out (not under Reduce Motion) — it sat paused on the reel he had just asked for until he
found play — and its share button sends the file by AirDrop or Messages, where that was Show in
Finder and a drag.
The 250 pt of static explanation the page re-rendered on every visit moves behind a "?" (FLOW-05).

As built (`Steps/Reels*.swift`): the sidebar goes away while Reels is up in a window narrower than
1280 pt and comes back on leaving for a page that does not do the same, as on the light table and with
its one memory of it (§2.1); the bursts list's colour stops under
the title bar rather than cutting the window's title in two. The middle keeps at least 480 pt beside
the list and the inspector: with the sidebar gone the 900 pt window's page is wide enough for three
regions at 360, which squeezed the summary beside the player to "Leave Them…" and "Write Presets and
Open Pho…" and kept the frames two across below the fold; folded, they are four across under the
format row. The inspector is a 260 pt column **of the page**, not the shell's
`.inspector`, which is shut by default and would hide the format with it; when the page is narrower
than 220 + 260 + 480 pt the format becomes one row of five above the frames, where it is never
scrolled away, and the rest folds under them. Where the reel is saved is its `~` path as text, cut
from the front, not a `PathControl`: in 260 pt the control drew only folder icons. **The frames'
keys are Choose Keepers'** (§2.5.3, "One scheme"; `ReelsKeys`, which reads `KeyMap` and says what
each of its actions does here): S F and ← → move the ring, ↑ ↓ a row, **E puts the frame in the reel
and D leaves it out, each then going on to the next frame, and X clears what he did to it** — a
reel's frame starts in, so that is back in — and stays; R and W (or N and P) go to the next and
previous burst in the list, Space opens the frame large, Q (U, ⌘Z) takes back the last change on the
frame it was made on — going back to its burst if he has moved on — and ⇧⌘Z does it again; Esc is
taken and does nothing, and Return stays Cut It. A held D leaves one frame out, and E or D on the
burst's last frame stays there. The keys reach the page from anywhere in its window through one
local monitor (`ReelsKeys.route`), as on Choose Keepers and Instagram: they were read only while the
grid had the keyboard, so after ↓ down the bursts list — which keeps the keyboard there on purpose —
E, D, S, F, R, W, Q and Space did nothing while ↓ went to the next burst. ↑ and ↓ stay the list's
while it has the keyboard; any other key that acts on a frame hands the keyboard to the frames, so
the ring shows, and R and W leave it where it was. The grid had a key
list of its own: X ticked the frame in or out, where X clears everywhere else, E and D did nothing,
the bursts were N and P only, S and F did nothing, and nothing could be undone. The keys scroll the
ring into sight, and Frame ▸ Keep and Drop read "Include 06264" and "Leave Out 06264" while the page
is up, Clear the Mark, Next and Previous Frame, Next and Previous Burst and View ▸ Full Image act on
the frames, and Edit ▸ Undo names the change it takes back (`ReelsCommands`). A reel is
usually the peak of a burst, and trimming to it was one click per frame: a shift-click now gives every
frame from the last one clicked to it the clicked one's new state, I and O make the reel start and end
on the frame the keys are on (frames 4–9 of 13 is two presses) — they take out what falls outside and
bring in only what they add past the old start or end, so a soft frame he took out in the middle stays
out, where putting the whole run back brought it back unsaid — and Leave Them All Out sits beside Put
Them All Back — both under "9 of 13 frames in the reel", always laid out, the one with nothing to do
only hidden. Beside the one-line note above the frames it made the note wrap at the first frame taken
out and moved every tile 15 pt down under the pointer; the note says what each key does in one line at
1440 and is not drawn over an empty grid. Return in
the burst field is not Cut It: it goes to the burst typed — the exact number before one that only
contains it — and gives the whole list back around it; with nothing typed it goes nowhere and gives
the frames the keys (it went to the top of the list, off the burst he was on, and the next Return
cut that), and with a number that matches nothing the field keeps them; while the field has the
keyboard the step's primary gives up Return (`StepPrimary(returnKey:)`), because AppKit hands the
default button the key before the field sees it and 93 then Return cut whichever burst was already
chosen. Typing down to one burst chooses it; Escape empties the field; Edit ▸ Find Burst… (⌘F) puts
the keys in it — AppKit makes the field first responder, because setting the page's focus to it left
them on the frames; Shoot ▸ Cut a Reel is the same press as the button, through the page's own
answer to the row (`.answersMenu`, §2.12): it adds to Up Next while something of his runs or with ⌥
held, as the button does. Find Burst is the page's only while it is on screen (`ReelsCommands`): its
action goes in front of whatever answered the row before — the light table's ⌘F — and puts that back
when the page goes, where registering over it would take such an owner away for the rest of the run.
Cut a Reel has one owner, the shell's: a second one here pressed Cut It with ⌥ held. Cut It is the
bottom-right button, once: it was drawn in the toolbar as well (§2.3). The frames have the
keyboard when the page comes on screen and after a click on a burst in the list (arrowing down the list
leaves it there), with the keys on the burst's first frame, so E, D, Space and the arrows work without
the click on a tile that ticked it; R and W (or N and P) in the frames go to the next and previous burst in the
list as shown. Nothing hands the frames the keyboard when a burst's frames come in: the list is no
place of the page's focus, so it read as "nothing has it", and each burst's frames took the keys from
the list as they came, so the next ↓ moved the ring in the frames instead of going down the list. A
burst clicked in the list stays where it was under the pointer; one chosen from
elsewhere (N, P, the field, the lister's first pick) is scrolled into sight by as little as that takes,
and only the page's arrival centres it. Each answer of the lister is a process that walks every
export folder, and every burst change emptied the grid and asked it again, once per row as he held ↓:
a burst reached by the keys (the list's arrows, N, P) is asked about once he pauses on it (250 ms), an
answer is kept for the visit (by burst and folder) and forgotten when the page comes back, a spread or
a reel ends, or a wait stops, and while one is read the grid keeps the burst's places as blank tiles
and the summary keeps its trim row, so nothing below moves when the frames come. The engine keeps its
map of the exports for 5 s, so the thirteen tiles of a grid are one walk of the folders, not thirteen,
and forgets it whenever the lister answers: the lister is what tells the page a frame is exported, and
a map walked before it served that frame's RAW under the page's "exported" picture for the visit.
The frames he took out are about the frames, not the burst on screen: looking at
another burst and coming back finds them still out, and Put Them All Back puts back only the burst
on screen. "Slow into the push-in" is drawn for Push In only — the
engine eases no other shape. The format was "Cut", beside **Cut It**, which makes a reel of any
format, and a job titled "cutting burst 93 as a cut": the engine still calls it `cut`, and the
screen and the job's title say Push In, so "cut" means only making the reel — under the checkbox
too: "The last frames before the push-in are held a beat longer." Speed is 6 / 8 / 10 / 12 frames a second, remembered apart for bursts (8) and a
timelapse (12), as is what the crop follows (a timelapse follows the people). They survive a relaunch
(`ReelsMemory`): the speeds, the crop, the size and the list's order as his habits for every shoot,
and the format, the burst and the frames he took out as where he was in each shoot — the app reopens
on Reels, and it came back on the lister's top burst as a Push In at 8 a second in 1080 with every frame
back in. A remembered burst the lister no longer offers is let go for the one it ranks first.
**Arriving from Choose Keepers, the page opens on the burst he was on there** — the light table's
cursor, once it has been opened in the launch (before that it is the first burst of a shoot nobody
has looked at, and the burst remembered on Reels stays) — and the lister's first answer is asked about
that burst, so "reel this burst" from burst 93 is ⌘6 and one answer, where it opened on the lister's
top pick after two answers and then took the field, two digits, a click and a third answer. Only a
burst he has moved to on the light table since the page last took one: coming back to Reels without
moving there keeps the burst he chose on Reels (`ReelsModel.tookFromLightTable`). One the lister does
not offer — fewer than three frames — is let go for its first pick. For a timelapse the
bursts list becomes what to play: the whole day, or one name filed in the shoot. Beside the burst
the page says, before anything is pressed, whether the reel is cut from his exports or is **a draft
off the RAWs** (the engine decides over the whole burst and writes `draft-` in the file name). It
gives no running time for the reel: that is the reel maker's own arithmetic, which is private, and a
copy of it here would drift from it unseen — the lister's `seconds` is that figure, and the app does
not read it. **Each row of the bursts list says how long the burst itself lasted** — from its first
frame's capture time to its last's, off the shoot's own frames (`shot_at`, the camera's clock as the
cull read it; `BurstLength`) — at the end of the line with its number, "3 s", or "<1 s" for a burst
taken within one second: the cull writes capture times to the second, so that is all a length is
good to, and VoiceOver says "about 3 s" and "under 1 s" (a time with fractions would be said to the
tenth). **A green dot beside the number says he kept a frame of it**, by the rule "you kept" is
counted by everywhere else (`gather.verdicts`): the engine's count for the burst while nothing in it
has changed since the engine counted, and once he has marked a frame of it or pressed N on it since,
that rule over its frames as they are now — his mark where he made one, and in a burst he has been
through the cull's pick he left standing (`ShootSession.countedAsItIs`, `BurstFacts.keptOne`). The dot
once added the count read when the shoot was opened to what he had kept since, so un-keeping the only
frame he had kept left it saying he kept one until the shoot was read again. The lister's own count
stands only for a burst the shoot does not have. A row said "1 of 4 exported" and nothing
else, so which bursts ran long enough to be worth a reel, and which he had kept from, meant opening
them. The number wins the line: the length is short and in one form down the list, so "Burst 93"
and its dot are never cut. A burst with frames not exported offers
**Write Presets and Open PhotoLab** (`/api/spread`, which passes `--standard`: the shoot's own preset
beside every frame of the burst without a sidecar, exposure levelled down the burst; his edit is not
copied and a frame he edited is left as it is, and the label says so). Under it is one line —
what it does and that exporting cuts the reel — because the export count is the draft line's, and
the detail of what happens to his edits is the button's help and the "?": a five-line paragraph
under it on nearly every burst gave the same count three times. The press reads
`/api/reel/watch` once for the count to wait from — every folder an export can land in, not the
lister's `exported`, which counts only the folder "Exports from" names — and the count is watched
only once the spread has ended well; a spread refused, stopped or failed ends the wait with a
sentence saying so. It then polls every 5 s and cuts the reel itself one poll after every frame of the
burst is exported, or after 45 s with nothing new once some have come — two quiet polls, ten seconds,
was shorter than PhotoLab takes over one frame with its heaviest noise reduction and cut drafts from
four frames of thirteen — and the line says how many of the burst have come and, in a pause, when it
will cut ("Burst 93: 7 of 13 exported so far… Cutting from these in 40 s unless more arrive."). A reel
of some of the burst adds "Your reel is 6 of the 13: Cut Now once those are exported." The count is
the burst's, so the wait cannot tell his six from the rest and still waits for all thirteen or the
pause; a target of six more would cut, five seconds after any six came, a draft of the frames he had
not exported yet whenever PhotoLab exported the burst from its first frame. While it
watches, the burst's row counts what the wait counts and the draft line gives way to it, so the page
gives one number for one thing. The reel it cuts is frozen at the press (`ReelWait.request`: format,
frames, speed, crop, size, the slow-in), less "Exports from", because PhotoLab writes wherever it was
last pointed; browsing another burst or format meanwhile changes nothing about it, the page is never
moved back to the burst, and a frame named then that has gone is dropped. On the burst it waits on the
step's primary reads **Cut Now** — it ends the wait and cuts what has come, as frozen — rather than a
second Cut It that made a draft now and a finished reel later; changing that burst's frames or settings
while it waits says the reel will not have them. The wait is shown whichever burst he browses, naming
its own. **It never gives up by itself**: it watches for as long as the app is open, more slowly the
longer nothing new comes — every 5 s for the first two minutes, every 30 s until ten, then every
minute (`ReelWait.slowing`) — and anything new puts it back to 5 s; the line then adds "Nothing new for
25 min; it looks every 60 s now." It used to stop after twenty minutes with nothing new, so an export he
made after editing the burst for twenty-five cut nothing, and the only way back re-wrote the presets.
It ends when the reel is cut, when he presses Stop Waiting or Cut Now, or when the app quits. A wait belongs to its shoot:
opening another shoot's Reels leaves it polling its one burst — ending it there, without a word, meant
his export in PhotoLab cut nothing — and the same shoot opened afresh hands it to the new page (one
still writing presets cannot follow its job across, and says it stopped). A double-click is read in AppKit so a single click ticks at once; the second click puts
the tick back and opens the frame through `ExtViewer`, the viewer seam the light table fills, with
`source: .reel`: the large view draws `/reelthumb` again at its own size (`px`, in steps of 400,
clamped by the engine at 2400 and kept per size), so what he judges large is the export the tile
shows and the reel is cut from — not the camera's JPEG and then the unedited RAW, which is what
`.frame` draws and what the light table's own viewer takes over. Until the large picture is made
(the engine makes it from the full-size export on the first request) the view shows the 400 px
tile's, fetched first when even that is not here, and a large picture that cannot be made leaves
the tile: arrowing through a burst went blank on every frame for as long as each one took. A
further thing to follow is read from `follow: [{id, label, note}]` on `/api/reel/options`, which no
engine sends yet. Per-frame holds (the old page's "hold ×N", the `plan` body) are not built.

### 2.7 Long jobs

One queue in the engine, one presentation in the app.

- **In place.** The step that started the job shows progress **where the button was**, in the same
  box: determinate bar, the engine's own stage words ("reading the frames", "looking at faces",
  "judging the pictures"), the count, elapsed and remaining, and Stop. Nothing shifts (FLOW-04).
  When it ends other than finished, the same place says how (`JobEndedNote`, on Cull, Presets and
  Reels): *"Stopped. What it had already written stays…"*, *"Refused: "* and the engine's sentence,
  or — in the alarm colour, with its symbol and **Show the Log** — *"The last run failed with an
  error. The log says why."* (on Cull, *"The cull stopped with an error. Nothing you have marked was
  changed."*). A crash used to leave no line at all: the Cull page went back to "About a minute."
  and Cull It as if he had never pressed it.
  The time left is the engine's own `remaining_text`, the sentence the toolbar and the list print;
  the bar worked out "1:13 left" from the fraction while they said "about 4 minutes left".
  A card copy's bar counts the check he chose: with *Don't check* the copy is the whole bar (it sat
  at 70% and jumped to the end), with *Again at the end* the second pass over every byte is half of
  it (at 30% the time left ran short), and *While copying* keeps 70 for the copy and 30 for reading
  it back.
  Stop (and the × that takes back a waiting request) sits on the box's **leading** edge, a 28 pt
  target, and ignores a press for 0.8 s after it appears: the button he pressed is against the
  trailing edge and turns into the box within a double-click, so its second click stopped the cull
  it had just started.
  From the press until the engine has started it, the box says **Starting…** with a spinner and no
  Stop, the toolbar's copy of the button is greyed, and another press does nothing. The engine can
  take seconds to answer a start while it stands the idle learning run down, and the press again
  because it felt slow asked for the same cull twice and drew the engine's refusal beside his own
  cull. "Starting…" holds until the poll sees the job, so the button never flashes back between the
  answer and the first sight of it; a refusal gives the button back at once, and so does an answer
  after which nothing is seen running for two seconds.
- **Toolbar** `.status` item on every screen: ring + "Cull 2026-09-13-dog"; click → popover with
  the same facts, Stop and Show Activity (Show Up Next when work is waiting). The ring does not
  animate between polls: at 16 pt the ease is motion nobody can see, and SwiftUI redrew it every
  frame for the length of every job, on the thread his keys use. When a job ends while he is in the
  app, the item says how (`AppModel.justEnded`): Done and Stopped for 6 s, Refused and Failed until
  he clicks it, which opens Activity with the newest job selected — another job's success does not
  bury a failure, but the same work (its kind and its shoot) run again and finished takes its place
  and goes after 6 s, where "Cull · Failed" sat on after a good re-cull; a storage plan the engine
  turned down on purpose is said for 6 s like Done, because the Storage panel that asked already
  shows the refusal; and the machine's own homework finishing is not news. It used to vanish, so done,
  stopped and failed all looked the same. With nothing running and a list waiting it is the list:
  "Up Next" and a count, or a pause glyph and "3 held", and its popover names the next three with
  Continue (held) and Show Up Next. It was a made-up job titled "Up Next" with an empty ring — a job
  stuck at nought — whose popover offered a Stop that did nothing and no Continue.
- **Sidebar**: the running step's row carries a tiny circular progress.
- **Dock**: a real progress bar in `NSApp.dockTile`'s content view, cleared on completion, and **no
  badge while work runs**: a red "38 %" sat on top of the bar for the length of every job, and red
  on the Dock means "needs you" (NAT-07). The badge is for a failure of his work — the job he watched
  end, one the list wrote down as failed between two looks (`QueueDock.show`), or one the engine
  went down under (`JobModel.closeTheLost`, and the job a restart names) — and says "!" until he
  looks at Activity, where the failure is: it goes when the Activity window becomes his key window
  (`DockProgress.watchActivity`). One that lands while Activity is in front of him — the app active
  and the window key, or on screen and not covered — is read already and never badged. Open is not
  in front: it used to be keyed to the window's view existing, so a window left open behind
  PhotoLab, minimized or in a hidden app kept every overnight failure off the Dock, which is the
  one case the badge is for. The machine's homework failing is not news. The Dock
  menu carries "Cull · 2026-09-19 — 38%" and Stop while something runs, with the list behind it;
  with nothing running and the list held (a Stop from this menu holds it), "2 held", **Continue**
  and Up Next; and while a failure is badged, Show Activity. The harness draws the real tile view,
  not a copy of its drawing that could not catch a change to it.
- **Awake**: `ProcessInfo.processInfo.beginActivity(options: [.userInitiated,
  .idleSystemSleepDisabled], reason: "First Edit job running")` held for the life of the job
  (NAT-06). The display may sleep; the work does not.
- **Notification** (`UNUserNotificationCenter`) when a job ends and the app is not frontmost:
  *"Cull finished"*, the shoot under it once, *"23 of 54 frames put forward."* The title is the
  app's own word for the work — the list's (`Strings.Queue.what`) in title case, "Write the
  Presets", and a storage plan named for what it checks, "Check What Would Be Copied", as its row in
  Up Next and Activity is ("Check what would be copied"; all five plans were "Work out what would
  go", which read "Work out what would go finished" and is not what a copy to iCloud does) — and how it ended:
  *finished*, *failed*, *stopped*, *did not run* for a plan that said no on purpose (its sentence
  the body), and *did not finish* for a card copy that ended part way — pulled out, no room on the
  disk, a failed check — which is neither a crash nor what he did. It was "<the engine's title>
  finished · <shoot>" for every outcome, so a failed copy read "Copying the card into 2026-09-23
  finished · 2026-09-23", success and the shoot twice. A failure's body sends him to Activity, never
  a traceback's last line: an exception's own line (`FileNotFoundError: …`) is part of the traceback
  and never taken for the engine's sentence, and a crash is a failure however its log ends (below).
  A copy that did not finish says "It stopped part way. Click to see what reached the shoot and
  why."; a finished copy's body is "The card can come out.", how it was checked being the copy's own
  sentence's to say, on its page. Clicking it opens the shoot at the step the work leaves him on (a
  copy → Cull, a cull → Choose Keepers, the presets → Edit, a reel → Reels, anything of the storage
  panel's → Finish), and for work that failed or said no, at the step that started it with the
  Activity window over it — except a card copy, which opens the card's page, where what reached the
  shoot and why it stopped is said, or, when this session no longer knows the copy, the shoot's own
  Copy the Card step, which carries the copy's sentence from its log: Cull of a shoot holding 412 of
  the card's 1,558 frames, with nothing there to say so, is the half shoot he must not cull as if it
  were whole. An extension's work opens the shoot. It used to open Choose Keepers for everything.
  Getting a burst ready for PhotoLab is not announced — PhotoLab opening is the answer — and neither
  is the machine's own background work. The Dock menu names a job the same way, in title case
  ("Write the Presets · 2026-09-19 — 38%"), and VoiceOver in the list's words ("Cull failed").
  **Authorization is requested the first time this is about to happen, never at launch.** A job the
  list ran is never announced on its own: the list speaks for it. The engine says a job came off the
  list on every reading of it, the ones after it ended included (`queue_from_list`; it used to go
  false once the job was written down, so the list's last job had a banner beside the list's), and
  the app also takes the list's own record of it (`queue_done`) as saying so.
- **The list** speaks once, when it empties, and counts by outcome, worst first: *"1 failed,
  1 refused, 1 skipped, 3 done"*, never "4 finished" over a failed cull. The banner's body lists
  the lines in that order; clicking it opens the Activity window when anything failed, refused or
  was skipped, because the reason is only there. In the window, the finished pass is the same count
  — only the failures in the alarm colour — over one row a piece, worst first, each with the
  history's own word and symbol (`QueueState.tally`, `QueueDoneRow`). The engine writes down how
  each list job ended by the same rule the app uses on a job it watched (`ended_as`, `Job.crashed`):
  a script that said no on purpose is *refused*, not *failed* — every non-zero exit used to be
  "failed", so a check that found no manifest was "1 failed" in red beside a history row that
  said Refused.
- **Elapsed time freezes the instant a job stops** and is never recomputed from the wall clock.
- **A plan that refuses on purpose is "Refused", not "Failed"** — a first-class state, in the
  ordinary text colour, with the engine's one sentence. **A crash is never a refusal**: the engine
  refuses with `SystemExit("sentence")`, which prints no traceback, so a job ended by a signal
  (out of memory, killed), one whose last command printed a traceback, or one whose last line is an
  exception's own ("MemoryError", "OSError: [Errno 28] …") is Failed, in the alarm colour
  (`Job.crashed`). Read as a sentence, every crash's last line made it a calm grey "Refused:
  MemoryError".
- **Never blocking.** No modal progress. A second request while one runs goes **in Up Next** (the
  engine's list, so it survives his going to another shoot and quitting), and the box where the
  button was says so — "First in Up Next", "2nd in Up Next" — with "Waiting for Write the presets ·
  2026-09-13-dog to finish." beside it, the running work named as Up Next names it and never by the
  engine's title (past the first place, "Waiting for … and 1 more ahead of this in Up Next.", since
  the running job is not all it waits for; "Held. Nothing new starts until you continue…" while Up
  Next is held), on Cull and Presets alike, and a × that takes it off. It used to wait inside the
  page and was dropped without a word when he looked at another shoot. The card page puts its copy
  there too, by the copy's own route (§2.6). The same work for the same shoot is never added twice:
  a second press says it is already in Up Next (or running), and the toolbar's copy of the button is
  greyed while the step's own work runs or waits. A press made before the engine has answered the
  first add does nothing: the list the page checks is only brought up to date by that answer, so a
  double-click on "Add to Up Next" passed the check twice.
- ⌘W with a job running keeps the app alive and working. ⌘Q with a job running: an alert —
  *"A cull is running. Quit anyway? The cull stops where it is. Nothing you decided is lost, and
  it can be started again."* [Keep Working] (default) [Quit].

**Stop holds the rest of Up Next.** He presses Stop because he needs the machine, or to cull again
with another focus; the next piece starting the instant the cull died made the Mac busy again and
ran the presets against the cull he meant to redo. So a Stop of his own work with anything waiting
holds the list (`Jobs.stop`), and the list says why under its controls — *"Held because you
stopped Cull · 2026-09-19. Nothing new starts until you continue."* — as the toolbar's popover
does, because a hold he does not remember pressing is a list that looks broken. The reason is
written down with the list (`held_after`) and goes when he presses Continue or Hold himself. A Stop
over an empty list holds nothing: the next thing he adds, an hour later, would wait for a reason
he has forgotten — and for the same reason a hold his Stop or a crash made goes, with its line,
when he clears the list or takes its last row off (`Jobs._forget_an_empty_hold`); a Hold he pressed
himself stays. Standing the machine's homework down for his work is not a Stop and holds
nothing. The note under the controls is a line of its own that wraps; it sat in an overlay a fixed
15 points down, which a second line ran out of.

**An engine that stops under a job puts it back.** Every job is started in a session of its own so
Stop reaches its children, which also means it outlived an engine that crashed under it: the
restart banner said *"Nothing you decided was lost"*, the cull he had walked away from was not
mentioned, was not back on the list and was not reported as failed — and it went on writing while
the new engine resumed the list on top of it, two heavy jobs at once, with Cull It offered again.
Now the engine writes the running job down beside the list (`running.json`: its process, and for
the list's own kinds what it was asked for with) and forgets it when the job ends or when the
engine quits on purpose. A note found at the next start means the last engine went away under it
(`Jobs._cut_off`) — unless the engine that wrote it is still up, another process still running
studio.py (`_engine_up`: a second `./pl studio`, or the app's engine while an orphaned one still
serves), whose job is running as it should and is left alone; and an engine binds its port before
it reads the list back, so one that cannot serve never touches it. The process group is put down
first — only a group led by that number and still running the job's script, since a number can be
handed out again — and then work the list can rebuild goes back at the **top** of Up Next, marked
*"The engine stopped while this ran; it runs again when you continue."*, and the list is **held**
with *"Held because the engine stopped while Cull · 2026-09-19 ran…"*. It is his to start again,
not the machine's to rerun unasked. The line that says the engine restarted names it: *"The engine
stopped while Cull · 2026-09-19 ran, and was restarted. It is back at the top of Up Next, held.
Nothing you decided is lost."* What cannot be rebuilt — an extension's own work, an update, the
machine's homework, and any storage work that removes something (never on a list, §2.8) — is only
put down. Quitting stops what is running on purpose, as the quit alert says, and puts nothing back;
it now stops the whole group, where it stopped only the process at its head.

**A job that ended while nobody watched is written down as it ended.** The engine going down, a
restart failing twice and the app started again an hour later found the cull finished on its own
— and put it back, held, written down as failed: he was asked to run a finished cull, or a finished
push, again. Every job now runs under a small parent (`_JOB_PARENT`) that writes how the job ended
as the last line of its log — `@@ ended 0`, kept out of every log he reads like the other `@@`
marks — so a job that was not running any more is recorded done, refused or failed as that line
says (`ended_unwatched`) and not put back. Only a job with no such line, which the Mac went down
under, was cut off. The parent is also where a Stop goes (`_ask_to_stop`): it passes SIGTERM to the
whole group once — the same signal twice would land in the middle of the job's own cleanup — and
waits for the job to put itself down, and a Stop that lands before the job has even started is
held until it has.

**A card copy goes back to finish into its shoot.** Put back as it was asked for — a copy into a
new shoot — it could only ever say "Can't run yet" and be skipped, since a shoot that already holds a
frame refuses that; so it goes back at the top as the copy that finishes into the same shoot
(`into`, the way a card put back after a stopped copy finishes it, §2.6), and with the card in,
Continue copies only what did not arrive and leaves what did exactly as it is, followed by the cull
if the copy asked for one. The card out, its row says so, as any copy's does. The crash's copy is
written down with where it stopped (*"The copy stopped at 412 of 1,558 frames."* under its log), the
line after the restart says so — *"The engine stopped while Copy the Card · 2026-09-19 ran, at 412
of 1,558 frames, and was restarted. It is back at the top of Up Next, held, and finishes the copy
when you continue with the card in. Nothing you decided is lost."* — and the list is held with
*"Held because the engine stopped while Copy the Card · 2026-09-19 ran, at 412 of 1,558 frames. It
is back at the top; continue, with the card in, to finish the copy."* It was not put back while a
copy could not be finished into a shoot, and a list an engine of that time held still says only
where it stopped (`put_back: false` in `held_after`).

**The list's controls** are not hazards. Clear sits away from Hold (Hold last, where the hand goes
when the phone rings) and asks *"Remove all 6 from Up Next?"* whenever it would take more than one;
what is running is never touched. Hold is never greyed: an empty list can be held, so he can line
up the evening while he is still culling and none of it starts until he presses Continue — it was
greyed until something was on the list, and the first thing he added started at once. A
double-click on "Add to Up Next" is one add: an add of the same work with the same options while
the first is on its way is dropped, and the first one's answer is what the page says; one within a
second after it is answered with the first (`QueueModel.add`) — the engine takes duplicates, and a
bounced click made two culls.

A waiting row can be picked, and then moved from the keyboard: ⌥⌘↑ and ⌥⌘↓ one place, ⌥⌘Home to the
top (**Do Next**, also on the row's menu and as an arrow that appears under the pointer), Delete to
take it off. VoiceOver offers only the moves that can do something. The list is as tall as the list
itself laid its rows out, read off its own table (`ListHeightProbe`): rows added up with guessed
insets came out a few points short, so even three rows showed a scroller. It has no cap of its own.
It is laid out first, and the history under it gives way — the log, then the table, which is as
tall as its rows up to six — down to their least; only then does the list scroll. The window's
least height (480) holds every part at its least, with room for a refusal over the list: at 440
the parts came to more than the window, and its heading ran into the title bar. A row that cannot
run says "Can't run yet" in the ordinary colour, not red: the engine looked and said not yet,
which is a refusal, not a failure.

**Activity window** (⌥⌘L): the last few days' jobs — the work with its shoot in grey beside it, the
outcome second at a width of its own, started (to the minute) and elapsed — with the selected job's
log in a monospaced text view, Copy Log and Show Log File in Finder. **The history outlives a
quit.** It lived only in the app's memory, so after a quit, or a Mac that restarted overnight, the
window said nothing had run and which of last night's jobs failed could not be found from the app.
The engine writes each job down as it ends — its work, shoot, start, time taken, outcome and the
log as the app reads it — in `jobs.jsonl` beside the list, and keeps three days of it, two hundred
rows at most (`HISTORY_DAYS`, trimmed at each start); a job a crash cut off is written down as
failed, with *"The engine stopped while this ran."* under its log. At launch the app reads the
earlier runs' jobs once (`GET /api/jobs/history`, `JobModel.readEarlier`) and puts them before
this session's, which it follows as they happen. A row from an earlier day says the day in its
Started column ("Tue 10:55 PM"), and is never news: it was there to be seen when it happened. The log has a home of its own,
instead of a `<details>` inside a card. The row picked when the window opens
(`ActivityWindow.firstToRead`) is the newest piece of news he has not yet had in front of him in
this window — a failure, or a no the list got while he was away — because that is what the banner
and Show the Log send him here to read, and the list has usually started its next piece by then;
otherwise what is running; otherwise the newest. It was always the newest, unpicked, so after a
failed cull and a good presets run the log under the table was the presets' two lines, belonging to
no row that said so; and then, for a while, the newest failure or refusal whatever he had read, so a
no he had seen under the button that raised it was shown again over a cull he had come to watch.
Rows that had ended while the window was open count as read (`JobModel.readInActivity`). A row is
always selected: a new job's row is picked when he was following the newest, and a row he picked to
read stays picked. Over the log, for a job that was stopped, refused or failed, one line — its
outcome and the engine's last sentence — because that is what he opened the window to read; the `$`
command line the engine ran is held back under Details (Copy the Log still copies all of it). When
that sentence is the whole log — a plan turned down — nothing is printed under the line: it said the
same sentence twice, over and under it. The work is named once, the same way everywhere it is named
(`Job.what`): his word for the kind of work (`Strings.Queue.what`, the list's own), and the engine's
title, first letter up, only for work the app has no word for — the same cull was "Cull" on the
list, "culling 2026-09-13-dog" in the history beside a Shoot column that said it again, and a
lowercase headline in the toolbar's popover. Outcome is the second column, beside what it is about,
and the columns fit the window's least width (560) without scrolling sideways: at its old 720 pt
default five columns cut Outcome to "Stopp" behind a horizontal scroller. The window opens at 760 ×
640. Before anything has run the history is one line, not a panel that took half the window and said
"Nothing has run" under a job that was running. A row is also a way back to where its work is done:
a double-click, or Show the Step on its menu, brings the main window forward on the step whose
button starts that work (Finish for the storage work its panel starts, the shoot's own page for work
no one step owns, What the Cull Has Learned for the machine's homework), and the menu has Copy the
Log for that row. Run Again is not offered: the history does not hold the options the work ran with,
so it could only run it with different ones. A row is a job by the engine's own number within one
run of the engine, not by kind and shoot: the presets written again, and failing, is a row of its
own, not the first run's "Done" left standing. Started is the engine's time, not when the app first
looked. A row never stays "Running" once its job is gone: one the list replaced with its next
between two polls closes with the outcome the list wrote down (`queue_done`), or "Ended" when
nothing says how; one whose engine went away is Failed, with "The engine stopped while this ran."
under its log.

### 2.8 Storage, and destructive actions

The storage panel lives on Finish, and there is deliberately no separate per-shoot storage screen.
The engine already produces every sentence, glyph pair and count (`/api/storage`); the app renders
them, it does not recompute them. The two-cell glyph is always "this Mac" then "iCloud", in that
fixed order, with the state's exact sentence beside it. The panel's one line groups its digits as the
rows under it do ("1,558 originals · 36.3 GB here · nothing in iCloud"), and says "one copy" only in
the state row, not a second time at the end of the line. That clause is dropped only when every
original is here; with nothing in iCloud and some not here either, the line ends on how many are
("· 1,200 of 1,558 on this Mac.").

The frequent actions come first: **Copy the RAWs to iCloud…**, **Bring the RAWs Back…**, **Check Every
Original**, **Take Back the Cache…**. Then a rule, 32 pt of space, and a group headed **Remove and
delete** holding **Remove the Local RAWs…** and **Let Go of the RAWs in iCloud…** — in the page the
destructive control sat 12 px above the button he presses at the end of nearly every shoot
(FLOW-06). The frame-by-frame table stays a lazy disclosure, fetched only on first expand.

**A button that can do nothing on this shoot is off, and says why.** Each one is read against the
engine's own counts in `/api/storage` — `archive.todo`, `pullable`, `droppable`, `up`, and the
retention lock's `finished` / `due` / `due_in_days` — and the reason is in its help and in a footnote
under its group ("Bring the RAWs Back: Nothing of this shoot is in iCloud."). Where the way on is a
button on the same page, the reason names it: Remove the Local RAWs on a shoot not yet finished says
"… Press Finish This Shoot first." **Copy the RAWs to iCloud works before Finish**, the same night,
when he presses it: it copies and reads back and takes nothing away, here or there, and a backup
before the card is formatted for the next shoot is the point of it. It refused any shoot not marked
finished, days before he had finished editing, and the refusal pointed at the retired studio and a
`--force` the app has no way to send. The rule it kept — a shoot he has not finished is still going
to be read — now holds where something would go: `archive.drop` refuses such a shoot, dry run or not,
with "… is not finished yet, so its RAWs are still going to be read. Nothing was removed.", and the
plan sheet lists that line. With iCloud Drive turned off the copy refuses before it reads a frame,
makes no folder and records nothing, and says so in the app's words, with no path: "iCloud Drive is
not turned on on this Mac, so nothing was done. Turn it on in System Settings, then try again." On a finished shoot
that was never archived, his commonest case, three of the six buttons each used to start a dry run,
wait, and come back with one line: "has no archive manifest". A button that would do something
carries the engine's figure for what it would move: **Copy the RAWs to iCloud (36.3 GB)…**.

A three-rung ladder, chosen by what cannot be undone:

| Rung | Examples | Treatment |
|---|---|---|
| Replaces the machine's own work | Cull Again, Write the Presets Again | Sheet naming what is kept. Cancel is the default button. No red. |
| Removes a copy, keeps a checked one | Remove the Local RAWs, Take Back the Cache | Own group below the rule, label ends in "…". Sheet shows **the engine's own plan verbatim** in a monospaced list. The confirm button reads the consequence — **"Remove 1,558 Originals from This Mac"** — `.destructive` role, red, **not** the default. |
| Deletes photographs | Let Go of the RAWs in iCloud | All of the above, plus: a separate unticked checkbox for "including the frames with no other copy", the doomed names listed verbatim, the keepers-protected count **frozen at the value the list was drawn against**, and a text field — *"Type the number of photographs to let go: 1558"* — with the red button disabled until it matches. Title: *"Let go of 1,558 photographs?"* Body: "They are in iCloud and nothing on this Mac will hold them afterwards. This cannot be undone." |

Rules that hold everywhere: no destructive action in a toolbar, in a context menu's first group, or
within 32 pt of a frequent button; **no destructive action has a keyboard shortcut and the Delete
key is not bound to anything, anywhere**; Escape cancels every plan sheet, and on the two rungs
that take something away Return presses nothing — it used to be Cancel, so on Let Go the number he
had just typed went with the sheet at the key that ends typing. Copying up and bringing back are
off the ladder and take nothing away, so there Return is the button he opened the sheet for. On the
rung that deletes photographs the number is typed under the list, after the names it counts; destructive menu items live at the bottom of Shoot ▸
Storage in their own section; the engine's refusals are shown as the engine wrote them, with the
button disabled and the reason beside it, never a disabled button with no reason.

The plan → token → apply round trip is reproduced exactly: the app never computes a plan, never
re-uses a token, and on `stale: true` it silently redraws the list rather than acting on a
confirmation that no longer describes what would happen. The sheet is titled by what the list is of
— "This is what would be copied to iCloud", "… brought back", "This is what would go". "The engine's
own plan verbatim" is the command's list, not its terminal footers: the engine drops "nothing was
removed. Add --apply…" and "nothing was copied. Add --apply…" — which sat right above a red Remove —
and puts the rest in the app's words (`plan_words`): "Tick "Including the frames with no other copy"
to include them." for `--yes-delete-originals`. The same goes for a storage job's log, whose last
line is what a refused job says. The commands still print their own words at a terminal, and the
token does not depend on the lines.

**The panel follows the job it started.** An apply and Check Every Original each start a job, and
the panel keeps the number the engine gave it and asks `GET /api/job` about that job until it
stops — with no deadline, because a 36 GB copy takes as long as it takes. While it runs, a row at
the top of the panel carries the engine's title, stage words, time left and bar, and every button
on the panel waits for it (one slot: a second press would only be told about his own job). When
it stops, one line says how it ended, with the last line the command printed ("54 unchanged · 0
drifted · 0 not recorded yet · 0 gone"), and the panel is read again **before** the job's number is
let go: that number keys the task following the job, and letting go of it first had SwiftUI cancel
the read, so the panel said "Finished copying…" over "nothing in iCloud · one copy" with Remove the
Local RAWs still off on the old counts. Until the fresh counts land every button still waits, so
none is judged on the figures from before the job. A job it follows that is neither running nor
waiting any more lets the panel go. A storage job of the shoot already running when he opens the
page is picked up the same way. The panel used to load once, on appear: a finished copy still read
"nothing in iCloud · one copy" until he left and came back.

**The line after a job is its result, in the app's words.** The studio marks every job it starts
(`PIPELINE_FOR_APP`), and archive.py and reclaim.py then end on one line that says what happened and
names the next button, never a command or a path: "54 copied and verified, 0 failed. iCloud still
has to upload them, and Remove the Local RAWs takes none until it has.", "Removed 54 originals and
their links; 1.1 GB back. Bring the RAWs Back brings them down again.", "Removed 164 files, 140.8 MB.
The next cull makes the cache again." Check Every Original ends on its count, not on the `--record`
flag it does not use. They ended on `./pl archive drop` with his home path, `./pl archive pull …
--apply`, and "…this command works again." in lower case. Typed in a terminal, the same commands
keep their hints for a typist.

**One name for each place.** The panel says *iCloud* for the copy up there, so the rung that deletes
is **Let Go of the RAWs in iCloud…**, in the panel and in Shoot ▸ Storage, and the lock above it is
"Let go of the RAWs in iCloud after"; it was "the Archived RAWs", a third word for the same place.
The engine's job titles follow ("letting go of the RAWs of 2026-09-19 in iCloud", "taking back
2026-09-19's cache"). The red button in its sheet still reads the consequence — **Destroy 40
photographs** — because that is what it does.

**One noun, one figure, for the cache.** The panel's group is *The cache*: "Made from the originals"
(`cache.derived_text`) and "Can be taken back now" (`cache.bytes_text`), which is the figure on
**Take Back the Cache (840 KB)…** and on its sheet's button. The row there used to be "Can be made
again 10.0 GB" — true, and not what the button takes — under a heading of *Renderings*, beside a
library page saying "Can be taken back" and a sheet saying "derived": four names and two figures for
one thing. The engine's reasons it will not run on a shoot sit in that group under "Take Back the
Cache won't run on this shoot:", and say where it looked ("no original on this Mac or in iCloud")
rather than "no surviving original" beside a line counting frames in iCloud. The sheet's list of
what it will not take is headed "left in place:", not "cache left in place:" over lines saying
they are not cache, and the tag that licenses a folder is "the note that allows this folder to be
cleaned" on the sheet and on the library page alike. A frame recorded as
archived and found nowhere is said in lower case — "not found in iCloud", beside the red glyph that
is the alarm, not "NOT FOUND" — with a footnote under it naming the next thing to press: "Check
Every Original, below, looks for each of them again and names the ones that are gone."

**The retention lock is a number, not a timer.** "Let go of the RAWs in iCloud after N days" only
decides when Let Go of the RAWs in iCloud… stops refusing, and the line under it names that button. "Use this
for new shoots too" starts ticked when the shoot's number is the library's (`retain.library_days`),
and ticking it sends the number there at once; it used to send nothing until the number was changed
afterwards, and came back unticked on every visit. Unticking takes nothing back.

**Every way back names the command that copies.** Where the engine tells him how to bring RAWs back —
Edit in PhotoLab on an archived shoot, after Remove the Local RAWs, in the cache sheet, in Check Every
Original — it names the shoot, not its path, and `--apply`: the plain `./pl archive pull` it used
to name is a dry run, printed his whole home path, and in two places named no shoot at all. Where the
line reaches the app it names Bring the RAWs Back on the shoot's Finish page first.

**The library's Storage page is a way into each panel.** It lists every shoot with its glyph, what
it holds on this disk (the engine's `storage.bytes_here_text` on each `/api/shoots` row) and the
engine's phrase, largest first, so the shoot to clear first is at the top. A row has a chevron and a
fill under the pointer, and goes to that shoot's Finish page with the panel brought into view. It
used to open the shoot's overview, with the panel a sidebar click and a scroll away, and gave no
size to choose by.

**The app never deletes a shoot folder.** Finder does that, and the app says so.

**"Drop" is not destructive and is never dressed as if it were.** First-use tip: *"Nothing is
deleted. Out means it does not go to PhotoLab, and ⌘Z takes it back."*

### 2.9 What the Cull Has Learned

One sidebar item, one detail pane, built on `GET /api/learned` and
`POST /api/learned/run|back|stop|use-anyway`. Toolbar: title, subtitle "Checked against 773
photographs you kept on 6 shoots". Its primary, **Learn Now** (`arrow.triangle.2.circlepath`), is at
the bottom right in the page's own action bar, once, as on every step (§2.3): prominent while a
finished shoot is waiting to be learned from, a plain button of the same size when none is, off while
a run is going or the record will not read.

```
It learns only from shoots you have finished. Nothing new is used until it has
been checked against every photograph you kept.

 ⏸ Why you drop frames                                             ⋯
   Not in use: the cull ranks frames by its own built-in judgement of the picture alone.
   ⏸ Held back: the version that came with the app (from before it kept its
     own record) is not used. It would stop putting forward 16 of the photos
     you kept (2026-09-21 and 3 more).
   ⌛ Not enough yet to learn your own:
     Blur: 6 more drops (6 of the 12 it needs).
     Face: 1 more drop on another finished shoot (24 so far, all on 2026-09-16).
   [See All 48 It Would Change]

 ⏸ Which frames of a burst you keep                                ⋯
   Not in use: each burst is ordered by the cull's own built-in judgement.
   ⏸ Held back: a version (learned when you finished 2026-09-13-dog) is not
     used. It would show 81 of the photos you kept later in their burst and
     35 earlier (2026-09-21 and 4 more).
   ⌛ Not learned from:
     2026-09-05-the-gals: 12 of your keepers, 18 short of the 30 it needs.
     2026-09-13-dog: finish some of its keepers in PhotoLab, then learn again.
     An order is tied to a shoot through the light measured on the frames
     you finished there.
     [Open 2026-09-13-dog]
   [See All 116 It Would Change]

 ✓ Your starting edit                                              ⋯
   In use since Sep 22. Learned from 527 finished frames, in 2 kinds of
   light (portraits, two people, evening in town; an action shoot, indoors,
   bursts).
   ⏸ Held back: a newer version, learned from 837 finished frames on 5
     shoots, is not used. On "2026-09-21" it would set the white balance
     worse than leaving it alone: right on 21 of that shoot's 38 finished
     frames, where leaving every one as the camera shot it is right on 29.
     Bringing photographs back does not settle this.
   ⌛ Waiting on you:
     On 2026-09-05-the-gals, its own exposure type is right on 164 of 198
     finished frames it had not seen; its commonest type, on 105.
     Bring back the photographs of 168 of those frames once, then learn
     again, and it can be checked against the rule it would replace.
     Until then the rule decides there.
     [Bring 2026-09-05-the-gals Back…]

 ● Picture judgement — built in, not trained on your photographs.
 ● Face checks — fixed rules (eyes closed, soft, caught mid-word), checked against faces judged by eye.

Last checked Sep 22, 2:10 PM · Ready to learn from 2026-09-19        [Learn Now]
```

**Three lines, three questions, all the engine's words.** A row says what is **in use** (`sentence`
— and when nothing is, what happens instead), what is **waiting beside it** (`candidate_sentence`:
"Held back: …" for a version that was checked and would cost him something, "Waiting: …" for one
nothing has been able to measure yet), and what it is **short of** (`needs_sentence`, as things he
could do: "6 more frames dropped for blur"). The row's status is the in-use state: a starting edit
that is writing his sidecars is **In use** even while a newer one is held beside it. The page once
said "Not in use" over exactly that, because the held candidate's state won; and it said "Not in
use" in the same words over a version held for doing harm and a learner that had never had enough
to learn, which are opposite situations with opposite remedies. The candidate and needs lines carry
their own symbol (`pause.circle.fill` / `exclamationmark.triangle.fill` / `hourglass`) so the two
never read as one. **See All N It Would Change** counts every keeper the check is about — the ones it would move down (hidden or
not) and the ones it would bring forward — so it can be larger than the number in the sentence
above it: 48 under "stop putting forward 16" is 36 moved down, 16 of them out of sight, and 12
brought forward. The label says so — it was "See the 48", and he had to work out that 48 was not
the 16 in the sentence.

**The engine's sentences use the app's words.** A reason he gave is said as the key he pressed —
*face* and *framing*, not the engine's labels *expression* and *composition* — and the way to give one
is "press 1–6 after D on Choose Keepers", not a "reasons menu in the cull". Nothing on the page says
*score*: the built-in ranking is the cull's "built-in judgement of the picture", and the face rules
are "eyes closed, soft, caught mid-word". Each learner's line under its title is a sentence of its
own, in the app's words ("the frames the cull puts forward", "the first preset of a new shoot"). A date
the engine writes into a sentence and also sends as data (`live.since`) is shown in the footer's form.

**What a learner is short of is a fact to a line, with a button where he can act.** The engine sends
the needs twice from one set of facts: `needs_sentence`, one sentence for the terminal and the record,
and `needs_lines`, the same a fact to a line for the page, with `needs_do` — the shoots a line asks
him to act on, and what to do there. The page draws the lines, and beside them one button per shoot:
**Bring 2026-09-05-the-gals Back…** opens that shoot's own bring-back list in place (the storage
panel's sheet, its Return bringing them back), and **Open 2026-09-13-dog** goes to its Edit in
PhotoLab. The sentence ran four to seven lines chained with semicolons, and the one asking him to
bring a shoot back ended in `./pl archive pull … --apply`, which from the app meant leaving the page,
finding the shoot, opening Finish, scrolling to storage and coming back. The clause saying a pull
would not settle a version held for something else is on that version's own line now, not the last
clause of the paragraph about the download. VoiceOver reads the row's lines too, not the sentence
they replaced, which still carried the command. The action bar names the shoots waiting — "Ready to learn
from 2026-09-19" — with **Learn Now** beside it, rather than "1 new shoot to learn from" with the
button in the far corner of the toolbar and a second Learn Now in the footer; while a run is going it
says only when it last looked, since the running row names the shoot.

**A check that could not reach a shoot for want of its picture vectors carries Measure.** Six of
his shoots were culled before the cull kept the vectors the keeper check reads, and the line said
*"2026-09-16 has no picture vectors kept; ./pl learned vectors 2026-09-16 measures them off the
previews…"* — the one learning gap only a terminal could close. The line now says what is short and
what fixes it, *"…has no picture vectors kept; measured off its previews, it can be checked"*, and
the row carries **Measure 2026-09-16** under it (`check_do`, one per shoot, from the check on the
version waiting and the one in use), whose help says nothing in the shoot changes and to press Learn
Now afterwards. It starts the command as his own job (`POST /api/learned/vectors`, kind
`learn-vectors`, its own stage "measuring the picture vectors: 412 of 1,087 frames"), with the
toolbar, Stop and the Dock following it; it reads the shoot's previews and writes the vectors beside
the models, and touches nothing of the shoot. It takes a shoot's own name and nothing else (`..` is a
folder too, and it is the library). Without the picture model it measures nothing and ends as a
refusal that says so — *"2026-09-16: nothing was measured. The cull's picture model is not on this
Mac yet; download it in Settings ▸ Advanced, then press Measure again."* — where it ended on a
traceback. A kept check is said in today's words, worked out again
from the facts it kept (`learned._said`) — nothing is measured again and the check is as strict as it
was — so a check written before this does not go on naming the command. The terminal prints the
command under the line instead.

**A change to what his sidecars say is always on the in-use line.** When the starting edit in use
chooses the exposure type itself on a shoot (its own fit beat the rule there; ML.md, *The presets*), the in-use line
says so for as long as it does — the shoot, and the counts it won on — not only in the check's
sentence on the day it passed. A needs line that asks him to bring photographs back carries the
button that does it (and, for the terminal, names the command that actually copies, `--apply`), and
does not promise that doing it puts a version in use when that version is held for something else.

A row reads in the order he asks: what the learner changes (a sentence, capitalised), what the
version in use read, whether it is in use, what waits beside it, what it is short of — and the
measurement store's "All 837 are measured and kept…" last, as a footnote, where it used to open the
row above the line saying what the learner does. The held line's pause symbol is drawn the way the
title's is. While a run is going, its note says only "Stopping it loses only the time it has spent.":
the line above it already says nothing new is used until it is checked, and the note said it again.

Status is a `Label` with a symbol, never colour alone: **In use** `checkmark.circle.fill` (green) ·
**Not in use** `pause.circle.fill` (orange) · **Not enough yet** `hourglass` (grey) ·
**Couldn't check** `exclamationmark.triangle.fill` (yellow). The `⋯` menu
(`ellipsis.circle`): "Go Back to the Version Before" (which runs the same check first) and "Stop
Using This" (keeps the data).

**[See them] opens Compare in a read-only review mode** — the affected keepers side by side, each
captioned "Now: the cull puts it forward · New version: set aside — looks like 'face'". K/D are
disabled with a line saying why. Until the light table registers that mode (`learning.review`), the
review sheet draws it itself, grouped by what would change: one section per change, headed once with
the engine's two words and its count ("Now: shown · New version: out of sight — 14"), the moves down
before the moves up and the one that lands lowest first — read off the frames' own moves, not a list
of the engine's words. Inside a group the frames stay together by shoot, and where more than one shoot
lent frames each tile names its shoot. S F and ← → walk the tiles, as they move everywhere else, ↑ ↓ a
row; Space or a double-click opens the frame large (the same pump, asked for a photograph), Space or
Esc puts it back — Done gives Esc up while one is open — and S, F and the arrows move on without
closing it (`ReviewKeys`, which reads `KeyMap`). The arrows alone moved here. E, D and X are not
bound: nothing is decided in a review. The sheet ends with **Done**, not Cancel: nothing is being cancelled. It used to
be 48 tiles 130 pt tall in the engine's flat order, every one repeating the same caption, the 16 out
of sight mixed in among the rest, with no way to enlarge one and no word of which shoot it came from. **Use It Anyway…** exists only on that screen, with the frames in
front of him, and its sheet says what the version would do in the engine's own sentence for that
check — *"The new version would stop putting forward 16 of the photos you kept (2026-09-21 and 3
more)."*, or for the burst order *"It would show 81 of the photos you kept later in their burst and
35 earlier …"* — then the app's tail for that learner: *"Your keepers stay kept — the cull just
shows them less. You can go back to the version before at any time."* for the one that ranks by his
reasons, *"Your keepers stay kept — only where they come in their burst changes. …"* for the burst
order, and for the starting edit, whose check is about white balance and which never touches the
cull, *"Only a new shoot starts from it, and nothing you have exported is rendered again. …"*
[Cancel] (default) [Use It Anyway]. The one fixed tail used to follow the starting edit's sentence
too, telling him a preset would show his keepers less. It once composed "stop putting forward N"
from `hidden` for every learner, and told him the burst order would stop putting forward 0
photographs while it moved 81 of them down.

While learning runs the row shows "Learning from 2026-09-19… checking against your 773 keepers" with
a determinate bar and the rest of the app stays usable. When it lands, a one-line banner at the top of
the page says what it did, read off the panel before and after the run — which version is in use,
which is waiting: "The cull learned from 2026-09-19. Why you drop frames: a new version is in use,
and none of your keepers is hidden by it." (only a version that hid none goes into use from a run),
"Your starting edit: a new version is in use, and new shoots start from it." (a preset hides nothing,
so it is not said to), "…: a new version was held back.", or "Nothing new went into use." **What Changed** scrolls to the first
row the run changed and lights it for a moment; ✕ dismisses. A run his own work stood down says "Paused
while you were working. It picks up when the Mac is idle."; one he stopped says so. The page keeps
asking while a run is queued behind other work, and the queued line names that work by the engine's
own title ("Waiting for culling 2026-09-21 to finish. Then it learns."). It asks only while the page
is open: the watch is the page's own task and ends when he leaves it, and Learn Now hands the
watching to that task rather than starting a watch of its own, which went on asking every two
seconds for as long as the run waited behind his work — hours of culling — after the page was gone. Nothing ever set this banner:
the running row disappeared after six minutes and the page re-rendered without a word, and the page
stopped asking the moment a run was queued, so it never showed it start. There is no notification
yet; that belongs to the app's notification owner.

**Before anything is learned.** The engine always sends its three learners, so a page that waited for
an empty list to show its empty state never showed it: the first time he opened this page he got a
header, three rows and a footer that each said "Nothing", with the shoot he had just finished
unnamed in "1 new shoot to learn from". When every learner has learned nothing, the page is one short
section — "Nothing learned yet" and the headline (or, with nothing finished, "Mark a shoot finished
and the cull can start learning from it"), with "Ready to learn from 2026-09-19" and Learn Now in the
bar below — then one
line for each thing it will learn, with how to give it something where the engine says ("Say why when
you drop one — press 1–6 after D on Choose Keepers — on a shoot you then finish."). An engine that
sends no learners at all still gets the designed empty state.

**When the record will not read.** The engine says so with a flag (`unreadable`, and the file as
`record`) rather than leaving it to be inferred from an empty list: it still sends three rows built
from a blank record, and the page read those as "Nothing learned yet" and offered Learn Now over a
record it could not write. The page shows the engine's sentence — capitalised, with no path in it;
it used to begin with his home folder — the parser's reason under Details, the file as a path whose
parts show themselves in Finder when double-clicked (a single click does nothing, on every path
row in the app, so a stray one never takes him to Finder), and **Show in Finder** beside it. Learn Now is off,
its help saying it waits until the record reads again: a run would only refuse for the same reason.

This is the concrete answer to *"the retraining is confusing"*: one place, plain words, every
per-frame decision visible, one button to go back.

### 2.10 First run

A sheet over the main window, 560 × 440, four pages, a Continue button per page, dismissible. The
footer is Skip (Esc) on the left, Back and Continue (Start on the last page) on the right, and the
page dots drawn over its centre, so they stay put when Back appears and Continue becomes Start —
they sat between two spacers and moved 25 pt from page to page. On the last page Skip would do what
Start does, so it is not drawn there and takes no click (it was only transparent, so the footer's
empty corner finished the sheet); Esc still closes the sheet. While the engine takes the folder from
page two, Skip and Esc wait with Back and Continue — Skip then started a second restart of the same
folder. A held Return steps one page: its key repeats are not passed to the sheet.

1. **Welcome to First Edit.** Three rows, symbol + title + one line:
   `sdcard` *Copy the card, checked.* · `line.3.horizontal.decrease.circle` *The cull suggests. You
   decide.* · `folder` *Your photographs stay where you can see them.*
2. **Where your photographs live.** `PathControl` + Choose…, pre-filled if `~/photos/shoots` exists
   ("We found 7 shoots in ~/photos. Use this library."). The app never moves anything. With nothing
   found and nothing chosen it says where Continue puts them: "Shoots will go in ~/photos/shoots.
   Choose… to use another folder." Choose… is **the one folder picker** Settings and the empty
   library use too (`LibraryFolderPicker`), so the three cannot disagree: it opens on the library in
   use, has New Folder, takes an empty folder to start a library in — "No shoots here yet. New
   shoots will be made in …/shoots.", said the same in all three — and turns down, with a sentence,
   a folder that holds other things and no shoot. The folder chosen here reaches the engine **as he
   leaves this page**, by **the one restart** (`EngineRestart`, §2.11) that Settings and the empty
   library's Choose Another Folder… use as well — Continue waits for it, with a small spinner beside
   it ("Opening the library in this folder…"), a second or two cold — so page three's Download Now
   goes to the engine that will keep it. Handed over at Start instead, the restart came after the
   download began and asked about stopping it; saved only at Start and never restarted, the sidebar
   named the folder he had picked and said nothing was in it until the next launch. **Never over his
   work unasked:** with a job of his running — the picture model's download, when he pressed
   Download Now on page 3 and came back; a cull, when the pages were shown again from Settings ▸
   Advanced — the restart asks, naming the job, and waits for it by default; the pages and the foot
   of the sidebar then say where the library goes and when, with Don't Wait beside it. It used to
   kill the job at once, with none of the question ⌘Q asks. The engine makes no `shoots/` when it
   starts: the one it starts on before he has picked is ~/photos, and that start left an empty
   ~/photos/shoots in his home for a library on another drive. A missing `shoots/` reads as an empty
   library, and the copy makes it for the first shoot.
3. **The picture model.** "The cull uses a picture model, 1.7 GB, fetched once. Everything else is
   already here. You can copy a card while it downloads; the cull waits for it."
   [Download Now] — the primary and the page's Return: Continue, which is what a Later beside it
   did, steps aside while the offer stands, so the key his hand goes to fetches the model rather
   than passing it by. It takes Return only once the page has been up 300 ms, so the Return that
   left page two, or a second one right behind it, does not start a 1.7 GB fetch. While it
   downloads the page says the toolbar shows how far it has got — until another job runs or the
   engine numbers one after it, since one job runs at a time; it read only the fetch's own record,
   so after a failed fetch every offer said "Downloading…", with no button, for as long as a cull
   ran. A refused press is said under the button that was pressed, where it used to be dropped,
   and only there and only until the job it was refused over has moved on: it stayed under all
   three offers until the next press. Whether the model is here
   is the **engine's** answer (`ready` on the library read), never a look at a folder: the engine
   copies its small bundled models into the same `models/` at every start, so the listing said
   "already on this Mac" over a model that was not. Passed by with Continue or Skip, it stays in
   reach — only ever as a press: the Cull step of a shoot not yet culled, and Settings ▸ Advanced,
   say the model is not on this Mac yet and offer [Download It] for as long as the engine says so.
4. **Your editor.** Every editor the Presets step writes for, as a radio group, the ones on this Mac
   marked "on this Mac" with their real icons; chosen is the one he already picked in Settings, else
   the first on this Mac, else PhotoLab. With none found, "None of these was found on this Mac.
   Choose the one you will use." When PhotoLab is the only one found and is the one chosen it is
   said, not asked: "Keepers open in DxO PhotoLab 10. [Change…]". On a first run Start and Skip save
   the editor that is shown chosen — pre-selected and saved were two things, so a Mac with only
   Lightroom showed it chosen and started shoots on PhotoLab. Shown again from Settings, they save
   only an editor he picks on this page: preferring the first installed over his own choice, and
   saving on Skip from any page, quietly moved Settings ▸ General ▸ Open keepers in. The editors are found by the one lookup the Presets step uses
   (`Editors.find`): LaunchServices by identifier — PhotoLab's carries its major version,
   `com.dxo.PhotoLab6` to `12` — then the Applications folders by name in any of DxO's spellings
   (`DxO PhotoLab 8.app`, `DXOPhotoLab10.app`), and the newest copy by the version it declares, never
   the last name in order; the page's own list missed PhotoLab 10 and offered an editor the step
   cannot write for. Each is named as the Finder names it: PhotoLab 10's bundle gives "DXOPhotoLab10" as its
   display name, which the page printed. "You can change this later in Settings."

Then the main window with a `ContentUnavailableView` (`EmptyLibrary`): `sdcard` "No shoots yet" /
"Put a memory card in to copy your first shoot." with the folder the engine looked in — "Nothing was
found in ~/photos/shoots. It looks for folders with a raw/, a cull/, or photographs in them." — and
[Choose Another Folder…] under it. (It pointed at File ▸ Add a Folder of Photographs…, which is
greyed: §2.12.) When that folder is a library he has just started (empty, or holding only the empty
`shoots/` the engine makes) it says the shared sentence instead, "No shoots here yet. New shoots
will be made in …/shoots.": it kept the failure wording over an empty folder he had just chosen from
that same button. What it says is looked up off the main actor, once for each engine the app talks
to; it was a directory walk in the view's body. A folder that holds other things and no shoot is
turned down there in a sentence. With a card in, it says so instead — "EOS_DIGITAL is in" / "Copy it
to make your first shoot." [Copy the Card], the default button, which opens the card's page as ⌘N
does. The sidebar says "No shoots yet" in one line and nothing more: it said "Put a memory card in"
under the card, five lines deep at 220 pt with the path broken over two, and held the page's only
button.

Permissions are asked **in context**: the removable-volume prompt the first time he opens a card
(preceded by one line: "macOS will ask to let First Edit read the card"), notification
permission the first time a job is about to finish while the window is not frontmost.

There are no first-use tips. Three were designed — Keep/Drop on first entry to Choose Keepers, the
stack badge the first time a stack appears, the Activity item the first time a job runs — and their
store was written, but nothing ever drew one, so Settings ▸ Advanced's "Show the first-use tips
again" handed back nothing, then or later. The button and the unused code are gone; the welcome
pages are the way in, and Advanced can show them again.

### 2.11 Settings (⌘,)

`Settings { TabView }`, five tabs, each a `Form(.grouped)`.

- **General** — library folder (`PathControl` + Choose…, "Nothing is moved"; the one picker of
  §2.10, so an empty folder starts a library and says where new shoots will go), with the count
  alone under it ("7 shoots"): the control above it is already the resolved folder, and the line
  spelled the same path out a second time; default editor, a picker of the editors the Presets step
  writes for, which a shoot with no editor of its own starts on; check for updates automatically.
- **Choosing** — Viewer background (Neutral Gray / Match the Mac / Black — "Match the Mac", as
  Appearance says it, one phrase for one thing), with the one note about it: "With Neutral Gray behind
  the photograph, exposure reads the same in light and dark." (General no longer repeats it under
  Appearance, where it said "in both" of three choices). Read by every viewer — the second screen's
  picture window too — through `LiveSettings`, which follows the defaults whoever writes them, so a
  choice here or in View ▸ Viewer Background repaints the surround at once and this picker follows
  the menu — each viewer read the setting when it last drew and was never told it changed; "Space shows the whole
  picture" (on) vs "Finishes the burst and opens the next", under "Space key"; "After the last frame
  of a burst: stay here / go to the next burst" (go to the next burst — he asked not to press N at
  the end of every burst, and it shipped set to stay) — what K, D or a reason does on a burst's last
  frame, since → there always goes on; "Show the reasons strip after a Drop" (on); "Open stacks of 4
  or more in Compare" (off); "Show the cull's marks in the filmstrip" (on). The light table reads its
  four at the press (`ViewerModel.settings`), so a change counts from his next key; they used to be
  written and never read. The fifth is the filmstrip's, and it was still written and never read:
  off, no thumbnail carries the cull's top-right mark, and the strip gives it no fault either — no
  half strength, no two words under it — while his own marks and the hollow "agreed" ones stay,
  because they are his. The strip draws it again the moment it changes, not at his next press
  (`FilmstripView` follows the defaults).
- **Storage** — default retention days, a 70 pt field and then the word "days", or "day" beside 1
  (it said the number twice; its empty label then took the field's width and it drew 38 pt wide).
  The number is **the library's, on the engine** (`GET`/`POST /api/storage/default-retain`,
  `EngineSettings`): `retain_days` in library.json, the one a shoot's Storage panel sets with "Use as
  default", shows for a shoot with none of its own, and archive.py reads. Settings kept a number of
  its own in the defaults that nothing read — 90 here, and every shoot's panel still said 365. The
  field is empty and greyed until the engine has said its number, rather than guessing one, and is
  asked again the moment an engine restarts under an open Settings; a refusal is said under it. Under it "Nothing is scheduled by this. It only decides when Let Go of the Archived RAWs…
  stops refusing." — the storage panel's sentence under its own lock, word for word, where the two
  had said it two ways. "Copy new shoots to iCloud" is gone: nothing read it, so he could turn it on
  and believe each night's card was backed up while nothing was, and nothing uploads by itself. A
  copy up is his press of Copy the RAWs to iCloud, which works the night of the shoot (§2.8). The "Archived
  copies go to" row is gone: its Choose… saved nothing and nothing read it, under "Not set. The
  engine uses its own default." It comes back when the engine takes a destination from the app.
- **Learning** — "Learn from finished shoots automatically" (on); "Only when the Mac is idle" (on);
  [Open What the Cull Has Learned]. Both go to the engine, which is what decides when learning runs:
  in its environment at start (`PIPELINE_LEARN_AUTO`, `PIPELINE_LEARN_IDLE_ONLY`) and to the running
  engine the moment either changes (`POST /api/learned/settings`, no restart). They were written and
  read by nothing, so learning started after every Finish and two minutes after any job — in the
  middle of Choose Keepers — whatever they said. **Automatically off**: Finish asks for no run, and a
  finished shoot's ask already waiting is taken back rather than run; Learn Now is his and still runs,
  and so does a Learn Now his work stood down. **Only when idle on**: a run waits, after the two
  quiet minutes that follow his own work, for two minutes with no key pressed and the pointer still,
  read off the HID system's idle time, and looks again when they could have passed; Finish says
  *"Learning from it starts once the Mac has been left alone for two minutes."* A Mac whose idle time
  cannot be read is not held back for ever: the quiet stretch alone decides. Learn Now never waits.
  An engine started by hand, with no app to say, learns as it always did.
- **Advanced** — Show the Log; Show the Support Folder; Extension: found / not found with its path,
  as the running engine answers it (it was the Settings value alone, and said "Not found" beside an
  extension whose steps were in the sidebar);
  "Allow Web Inspector on the built-in pages" (off, sets `isInspectable`; NAT-17); the cull's
  picture model, on this Mac or not yet, with [Download It] when it is not (§2.10), drawn once the
  engine has said which.

Changing the library folder needs the engine restarted, because `PHOTOS_ROOT` is read from the
child's environment at start — and a restart stops whatever the engine is running. Settings, the
first run and the empty library's Choose Another Folder… all go through **one restart**
(`EngineRestart`); a second path that only waited, and never asked, is gone. With nothing of his
running (the machine's own background work stands down and comes back) it restarts at once and asks
nothing. With a job of his running it asks, in the alert ⌘Q uses, naming the job in his words — the
cull of a shoot, the copy of the card into it, the picture model's download (not the engine's title,
"getting the picture model, once"), a listed piece of work by its name in Up Next: *"Restarting the
engine stops the cull of 2026-09-19. Or it can wait, and restart once that and anything waiting in
Up Next are done. Nothing you decided is lost, and a stopped job can be started again."* [Restart
When It Finishes] (default, rightmost) [Stop It and Restart] [Cancel]. Waiting is said under the
folder in General and at the foot of the sidebar, each with [Don't Wait] — it was said in Settings
alone, so with Settings closed the engine restarted on another library with no word anywhere. It
waits for the list as well as the job — the list is not held and resumed, because its work names
shoots in the folder being left — and then, if he is in Choose Keepers, for him to leave it: a
restart there would land between two presses, send the next verdict to an engine being stopped and
take the window to All Shoots of the other library under his hand. The line then reads "The engine
restarts on … when you leave Choose Keepers." When a restart that waited happens, the window's quiet
line — the one a crash-restart uses — says so: "Now that the cull of 2026-09-19 is done, the engine
reads …." A restart that did not wait says nothing: he is looking at it happen. Choosing the
folder the engine is on while a restart waits drops the wait, as Don't Wait does: the early return
for "already there" came before the wait was dropped, so the wait went on and, when the job ended,
put the engine and the saved folder on the one he had backed out of. Choosing the folder already
waited for keeps the wait and asks nothing again, and Cancel over a third folder leaves the wait as
it was — Cancel changes nothing. The folder is saved **only when the restart happens**, so the app is never pointed one way while the engine reads another:
the old sheet's "Not Yet" left Settings on the new folder and the sidebar on the old one until the
next launch, its "Restart the Engine" killed a card copy half-way under "Nothing you have decided is
lost", the sidebar restarted without asking, and the first run saved the folder and never restarted,
so the sidebar named the new folder over the old library.

### 2.12 The menu bar

Single-letter equivalents are real menu key equivalents with an empty modifier mask, so they appear
in the menus, work with Full Keyboard Access and are re-bindable in System Settings.
`validateMenuItem` returns false for every bare-letter item whenever the first responder is a text
field, so typing "k" into a search box types a k — or anywhere inside an extension's page, whose
single letters are its own (§2.16-6): Hold This One (bare H) used to fire from a caption field
there while the other screen was open, so every "h" held a picture and never reached the text. An item is enabled by whatever registers an action
against its id in the command table, so the menu is honest about what is available: the app-wide rows
at launch, and the Frame and View rows by the light table for as long as it is on screen
(`LightTableCommands`) — they were registered by nothing, so both menus were greyed top to bottom
while K and D worked, and ⌥⌘C and ⌥⌘R did nothing at all. A clicked row is the same `perform` the
key and the button use. **A row whose key has no ⌘, ⌃ or ⌥ and is one the light table reads for
itself declines that key when it arrives as a key press**, so E, D, X, S, F, R, W, the digits,
Space and ⇧E still go to the stage and the control bar with the repeat rule, the held-key line and
the display gate; taken by the menu, a held E would keep every frame it passed and a typed capital
E would keep a frame. H, which has no reader but its row, keeps it. The light table's ⌘ keys (⌘0,
⌘9, ⌘+, ⌘−) are the menu's: its rows take them first and run the same action the stage would.
While the Instagram step is on screen it answers the rows Choose Keepers does for the same meanings
(`InstagramCommands`, §2.17): Frame ▸ Keep reads "Include 05901", Drop "Leave Out 05901", Clear the
Mark and Next and Previous Photograph act on the wall or the editor; View ▸ Full Image is "Adjust
the Cut", or "Back to the Photographs" in the editor, and Actual Size and Zoom to Fit are the
editor's; Edit ▸ Undo and Redo name the mark or cut they take back. The Frame and View rows are
attached again on the next turn of the main queue, because the light table's detach can arrive after
the step's appear; Undo and Redo go back to the app's own owner when the step goes. The Reels page
does the same for its frames (`ReelsCommands`, §2.6): Frame ▸ Keep reads "Include 06264", Drop
"Leave Out 06264", Clear the Mark puts the frame back in, Next and Previous Frame move the ring,
Next and Previous Burst walk the list, View ▸ Full Image opens the frame large, and Edit ▸ Undo and
Redo name the change they take back — all greyed while a frame is open large, whose viewer has the
keys. A page answering a row can give it its own help tag as well as its own title, where the
table's would be untrue there: Next Burst's says it marks the burst as looked through, which on
Reels it does not, so there it says "Opens the next burst in the list."
File ▸ New Shoot from a Memory Card (⌘N) goes to the page of the card that is in — the copy is still
his press there — and is never greyed: with no card in it opens that page, which shows the copy this
session last ended with (its result, or why it did not finish) or, when there has been none, "No
memory card is in.", and which changes the moment a card goes in. Eject the Memory Card (⌘E) ejects it, greyed while a copy is running or
waiting its turn on the list, and while an eject he asked for has not answered; the unmount runs off
the main thread (as does "Eject after copying"), because a busy card takes seconds to let go; both were
rows with nothing behind them. Ejected from its own page straight after a copy of that card (the
engine records each shoot's card), ⌘E goes on to the new shoot's Cull, where the page's Open the Shoot
goes; it used to go to All Shoots, throwing the copy's result and the way to the new shoot away. A
second card, not copied, ejected from its page goes to All Shoots, not to the first card's shoot. A refused library-wide command (Show the Shoot in Finder, Eject) is
said at the foot of the sidebar, cleared by the next one that works — and not by the background
re-reads of the list after an N or a job, which neither say nor unsay anything there once the list
has been read (one failed read of them is not news; the next one tries again); a list that could not be read
at all is said on All Shoots with Look Again, where it used to spin "Looking for your shoots…" for
ever. Add a Folder of Photographs (⇧⌘N) is not in the bar: the engine copies only from a card it can
see, so there is nothing yet for it to do, and a row that is grey for ever is a promise the Keyboard
Shortcuts window repeats. **A submenu is grey while nothing in it can run** — Why It Is Out was live
with all six reasons grey inside it. **A row that arrives in sentence case is drawn in title case**:
the engine's step labels in Go ("Copy the Card", "Choose Keepers") and the reasons ("Cut Off"); a word
that already has a capital (PhotoLab, iCloud) is left as written. R is **Next Burst** in the Frame
menu, the button's own name — **Continue to Presets** on the last burst, where it goes there — with
"Marks this burst as looked through and opens the next one." in its help tag, and the undo it leaves
is "Undo Leaving Burst 3" — an arrow past the last frame leaves the same one; ↓ and ↑ are
**Next/Previous Frame the Cull Put Forward**. **Help ▸ First Edit Help is
there only when a help book ships**: without one it opened the Keyboard Shortcuts window, the row
below it.

**Edit ▸ Undo (⌘Z) over Choose Keepers is his newest verdict, named** — "Undo Keep 04330" — and
runs the same press ⌘Z and U make on the stage; it is greyed with nothing to take back. In a text
field, and on every other page, it is the responder chain's, as it always was. It used to be the
responder chain's alone, and nothing in the chain knows about a verdict: the row was grey while ⌘Z
and U undid them, and nothing said what the next undo would take back. A held ⌘Z undoes one verdict,
as a held key does on the stage; in a text field it repeats, as the system's Undo always did — the
one-press rule was asked before the row was handed to the field, so a held ⌘Z there undid once and
beeped. **Edit ▸ Redo (⇧⌘Z) is the same for what ⌘Z took back** — "Redo Keep 04330", the press
⇧⌘Z makes on the stage — greyed with nothing to put back, and the responder chain's in a text field
and on every other page. It was the chain's alone, grey while ⇧⌘Z put verdicts back.

**Edit ▸ Find Burst… (⌘F)** is a sheet over Choose Keepers — "Find Burst", "Type a burst number, 1
to 288.", the number he is on filled in and selected, Go and Cancel — and Go is greyed while the
field names no burst. Return jumps there through the light table's own jump, which records nothing.
Return on the number it opened with — the burst he is in — changes nothing: the jump lands on a
burst's first frame, and it used to take him from frame 12 of the burst he was in back to frame 1.
Three presses from anywhere in the shoot, where the scrubber's segments take a steady hand and N a
hundred presses. It is greyed on every other page. **Show/Hide the Filmstrip (⌥⌘F) and Show/Hide the
Burst Map (⌥⌘B) are not in the bar:** the light table cannot hide either yet, and the two rows —
with Find Burst — had nothing behind them, greyed on every page while the Keyboard Shortcuts window
promised their keys. They come back with the thing they toggle.

**Back to Where I Left Off (⌘J) goes to Choose Keepers and moves nothing.** The light table keeps
its own place for as long as the app is open — the burst and frame he was on when he stepped away —
and only the first time it opens in a launch does it go where the engine says (§2.5.13). ⌘J used to
move him to the engine's answer as well, which is read once, when the shoot is loaded: 120 bursts
into a long night, a look at Presets and ⌘J put him back on the burst the shoot had opened on, while the
sidebar and ⌘3 kept his place. **From a library page** — All Shoots, What the Cull Has Learned,
Storage, a card's page — ⌘J goes back to the shoot he was last in, on the step he was last on there,
as a click on its row does (§2.1): it was greyed on exactly the pages he takes a side trip to and wants
the way back from. The shoot he was last in is remembered from the last launch too; with none, or one
no longer in the library, the row is greyed (`CommandHost.backToHisShoot`).

**A Shoot menu row is its step page's own button, pressed from wherever he is** (`PagePresses`). The
row goes to its page and the page presses its button — the same closure, so Cull Again… and Write
Them Again… still ask first, ⌥ held while choosing the row still puts the work in Up Next (after the
same question: with ⌥ or while his work ran, Cull Again… added a seven-minute re-cull without it),
and a busy page ignores the press the way its busy button would. The row says what the press will
do, as the button does: while something of his runs, "Add Cull It to Up Next", "Add Cull Again to
Up Next…", "Add Write the Presets to Up Next", and Cut a Reel on Reels likewise; once the presets
are written, "Write the Presets Again…", since the press asks first. The rows said Cull It and
added. The menu never starts work itself: work
started behind a page he cannot see has no progress box, no Stop and nowhere to say it was refused.
⇧⌘E from the light table opens his keepers in PhotoLab in one press, by way of the Edit page. Each
row is enabled when its page's button would be, read from the session or, before it has been read,
the library's row: Cull It before a cull, Cull Again… after one, Write the Presets while anything
would get a preset, Open My Keepers in PhotoLab while the Edit page's button opens — presets
written, or being written or waiting in Up Next — since without them that button writes them first,
two minutes of work a row named Open must not start (§2.6), Finish This Shoot until it is — and
never while the engine greys the page itself (Reels kept on a Mac that cannot cut one for the reels
already in the folder), which would be a trip to a button that cannot be pressed. **Cull It, Cull
Again… and Write the Presets are grey while that shoot's own cull or presets is running or waiting
in Up Next** (`PagePresses.inHand`), the page ignores a press that arrives anyway, and the Cull and
Presets pages' toolbar buttons are grey while their own job runs, as the box is: the row stayed live
during the shoot's own cull and "a busy page" still added to Up Next, so a second ⌘R queued a second
cull of the shoot being culled, which the engine accepts. **Cut a Reel** cuts only on Reels, where
the burst and its frames are chosen; from any other page it goes there and cuts nothing. **Storage
▸** goes to Finish, where the storage panel is, and opens the same list first that the panel's
button would; Check Every Original starts the same check its button does. A press whose page he
leaves before it comes up is dropped, never saved for his next visit. These rows were registered by
nothing: every Shoot row but Stop What Is Running and all six Storage rows were grey on every page
while the Shortcuts window promised ⌘R and ⇧⌘E — and the snapshot harness registered do-nothing
stand-ins for them, so its pictures of the menus showed them live. The harness now registers only
what the app does, and a test fails for any ordinary row nothing in the app registers.

**First Edit** — About First Edit · Check for Updates… · Settings… ⌘, · Services ▸ ·
Hide ⌘H · Hide Others ⌥⌘H · Show All · Quit ⌘Q

**File** — New Shoot from a Memory Card… ⌘N · — ·
Eject the Memory Card ⌘E · — · Show the Shoot in Finder ⌥⌘R · Show the Export Folder ⌥⌘X · — ·
Close Window ⌘W

**Edit** — Undo ⌘Z · Redo ⇧⌘Z · — · Cut ⌘X · Copy ⌘C · Paste ⌘V · Select All ⌘A · — ·
Find Burst… ⌘F · — · Emoji & Symbols ⌃⌘Space · Start Dictation

**Frame** — Keep E · Drop D · Clear the Mark X · — · Why It Is Out ▸ (Shadow 1 · Cut Off 2 ·
Face 3 · Blur 4 · Exposure 5 · Framing 6) · — · Compare Similar Frames C · Keep Only This One ⇧E ·
— · Next Frame F · Previous Frame S · Next Frame the Cull Put Forward ↓ · Previous Frame the Cull Put
Forward ↑ · — · Next Burst R · Previous Burst W · — · Show in Finder ⇧⌥⌘R ·
Copy Frame Number ⌥⌘C

*The left hand's keys (§2.5.3). A row shows one key, so it shows that one; the key he learned first
— K, 0, ⇧K, →, ←, N, P — still works and is the row's second key, "or K" in the Keyboard Shortcuts
window and "E or K" in a help tag. Undo's are Q and U.*

**View** — Single Frame · Compare C · All Bursts G · — · Full Image Space · Enter Full Screen ⌃⌘F
· — · Actual Size (1:1) ⌘0 · Zoom to Fit ⌘9 · Zoom In ⌘+ · Zoom Out ⌘− · — · Show/Hide Sidebar ⌃⌘S ·
Show/Hide Inspector ⌥⌘I · — · Viewer Background ▸ (Neutral Gray · Match the Mac · Black)

**Go** — All Shoots ⇧⌘0 · What the Cull Has Learned ⇧⌘L · Storage ⇧⌘S *(the third library row had no
key and no menu item, and only the mouse reached it)* · — · Copy the Card ⌘1 · Cull ⌘2 ·
Choose Keepers ⌘3 · Presets ⌘4 · Edit in PhotoLab ⌘5 · Reels ⌘6 · Finish ⌘7 *(numbered by position
in the open shoot's own list, under its own labels: a step the extension adds takes its place in
the order and the steps after it move down a number, up to ⌘8 — ⌘9 is Zoom to Fit, so a ninth step
is reached with ⌘] or a click)* · — · Next Step ⌘] · Previous Step ⌘[ · Back to Where I Left Off ⌘J

**Shoot** — Cull It ⌘R · Cull Again… · — · Write the Presets · Open My Keepers in PhotoLab ⇧⌘E ·
Cut a Reel · — · Finish This Shoot · — · Stop What Is Running ⌘. · — · Storage ▸ (Copy the RAWs to
iCloud… · Bring the RAWs Back… · Check Every Original · Take Back the Cache… · — ·
Remove the Local RAWs… · Let Go of the RAWs in iCloud…)

**Window** — Minimize ⌘M · Zoom · Fill · Center · — · Activity ⌥⌘L · — · First Edit ·
Bring All to Front

**Help** — Search · First Edit Help *(only when a help book ships; without one it opened
Keyboard Shortcuts, the next item, so it is left out)* · Keyboard Shortcuts ⌘/ (and `?`) · Show the
Log · Report a Problem… (the new-issue page, with the app's own version, which a built app always
has, before the updater's) — with `NSApp.helpMenu` set, so the system Help search finds every menu
item by name (NATIVE-M02).

**A key belongs to one action, and the table above is where it is written.** A button in the window
that carries a key takes it off the menu item that owns it — a focused control beats a menu command,
and the menu item does not change, or dim, or say anything about it. So a step's toolbar button
**reads its key from this table, for the very action the button performs**, and carries none where
the table gives that action none: Shoot ▸ Cull It has ⌘R, and Cull Again…, the Cull page's toolbar
button, culls the same shoot again and carries that ⌘R; Write the Presets has no key, and Write Them
Again… carries none. Cull It itself is the page's bottom-right button, on Return, not in the toolbar
(§2.3). Written into the shared button instead, ⌘R wrote the presets on the Presets
step while the menu it came from said it culled.

The **Keyboard Shortcuts** window (⌘/ or ?) is a real window, not a modal — it opens where he last
left it, centred only the first time, and Esc clears its search or, with nothing typed, closes it: a
two-column searchable
list grouped **The Same on Every Page With Photographs** / Deciding / Moving Around / Looking Closer /
Everything Else — with Print. The first group is the one scheme (§2.5.3), one row a meaning, each
read from the menu row that carries its keys: Keep, or Include E (or K) · Drop, or Leave Out D · Clear
the Mark X (or 0) · Undo Q (or ⌘Z, U) · Previous and Next Photograph S F (or ← →) · Previous and Next
Burst W R (or P N) · The Photograph Large, and Back Space · Actual Size Z (or ⌘0) · Go Back ⎋ · The
Page's Main Button ↩, each "Everywhere" in the place column. E and D are what he opens
the window for, so they head it, as they head Deciding, and under Moving Around they were below the
fold. The footer says it in a line: "A key does the same on every page with photographs, and nothing
while you are typing."
Each row's key cap is the left hand's key, and the key he learned before it stands beside it as "or
K" ("or Q, U" beside Undo's ⌘Z). Single Frame has no key cap: its column says "Esc, or Return on a
cover" — S is the one before in every view. It
lists this app's own rows and the Mac rows the table put in a group (Undo, with "or U"; Enter Full
Screen); the standard Mac rows it contributes untouched (Cut, Copy, Paste, Emoji & Symbols, Hide,
Quit, Minimize, and Window ▸ Fill and Centre, which the app draws only so they work on its windows)
are left out, as they work as they do everywhere. A submenu's rows carry its name ("Why It Is Out:
Shadow", "Viewer Background: Black"). A row with no key leaves the key column blank, at the height
of a row with one, so a run of them does not close up; the two that delete say "None, on purpose". The Go rows are the open shoot's own steps, with
the labels and numbers the Go menu has right now. The light table's keys with no menu row of their
own are listed too: Pan at 1:1 ⇧←→↑↓, Leave Full Image, Compare or All Bursts ⎋, Open the Burst ↩;
and, under Instagram, the editor's own: Move the Cut ⇧←→↑↓, Make the Cut Smaller − and Larger =,
Back to the Automatic Cut A, Cut or Whole T, Result V (§2.17); and, under Reels, Start the Reel Here I
and End the Reel Here O (§2.6). Actual Size carries "or Z". One character typed in the search asks what that key does, and is
answered with the rows that key is, rather than every title with the letter in it — the old key as
well as the new: "k" answers Keep, and "s" answers Previous Frame and Single Frame. The
always-visible one-line legend in the light table is retired — the page truncated it at every window
size below 1728 px (LT-08), and the control bar's buttons carry their key in the help tag.

### 2.13 Copy

| Where | String |
|---|---|
| Step names | Copy the Card · Cull · Choose Keepers · Presets · Edit in PhotoLab · Instagram · Reels · Finish |
| An engine refusal | A sentence, capitalised at the source: `{"error": …}` goes out through `sentence_case`, which capitalises a first word that is a plain lower-case word — the whole word up to a space or colon, so "lake-night already exists" keeps its name — and not a shoot's name or a name always written in lower case such as ffmpeg or darktable ("That shoot's folder is not there any more"), and a step's `why_disabled` is written as one ("Cull the shoot first.") |
| Verdict buttons | **Keep** · **Drop** (help tag: "Drop doesn't delete anything. It records that this frame is out.") |
| His verdict line | "you kept this" · "you put this out" · "you put this out — shadow" (the reason he gave) · "you agreed with the cull here" · "you haven't marked this" |
| The cull's line | "the cull: clear win — only frame" · "the cull: maybe" · "the cull: set aside" · "the cull: eyes closed" (a fault it named, straight after the colon: "a fault it can name — " in front of it filled the caption's 146 pt at the default window, and the fault was the part cut off). Read only from the cull's own rating and reason, in the report's words; **his reason is never printed as the cull's**. Never "AI", never "score", never "confidence" |
| Stack badge | "4 similar" — hover: "These frames were taken back to back and look alike. The one on top is the cull's guess. Press C to compare them." |
| After D | "07187 is out. Why? 1 shadow · 2 cut off · 3 face · 4 blur · 5 exposure · 6 framing" — the frame D put out, by number, and each button its key and its word; help tag "Optional. A reason helps the cull spot this fault." (3 s, blocks nothing, on the table and in Full Image) |
| Held key | "Holding a key marks one frame only. Press it again for the next." — E, K and D alike |
| End of burst | "End of burst 3 — 2 kept, 4 out, 1 you haven't marked. Next burst: F or R (→, N)" |
| End of shoot | "That was the last burst. You kept 14 of 54." and a Continue to Presets link (§2.5.2) |
| Keepers, honestly | "23 frames will get a preset: 14 you marked Keep, 9 the cull put forward in bursts you looked through and did not mark." |
| Cull summary | "It put forward 150 of 1,558 frames." / "283 with a fault it can name: eyes closed 131 · too soft to read 77 · blown highlights 70 · face in shadow 5" / "863 fine, not the best of their moment" / "262 stacked behind a similar frame" |
| No pixels | "This frame's pixels are not on this Mac — its RAW is archived, or its rendering was taken back. Nothing can be decided here." |
| Zoom label | "1:1 · on the face" · "1:1 · no face found, on the subject" · "1:1 · centered" · "1:1 · held in place" |
| Finished | "Finished. Your 154 keepers are recorded — the frames you exported." and under it what Finish did about learning: "The cull is learning from this shoot now." / the engine's note when it waits / nothing when automatic learning is off |
| Learning header | "It learns only from shoots you have finished. Nothing new is used until it has been checked against every photograph you kept." |
| Remove local RAWs | "Remove 1,558 originals from this Mac? Each one has a copy in iCloud that has been read back and checked. You can bring them down again at any time." |
| Let go | "Let go of 1,558 photographs? They are in iCloud and nothing on this Mac will hold them afterwards. This cannot be undone. Type 1558 to confirm." |
| Quit during a job | "A cull is running. Quit anyway? The cull stops where it is. Nothing you decided is lost, and it can be started again." |
| Offline update | "Could not reach the releases page. You're offline, or GitHub is." |
| Engine down | "First Edit's engine stopped. Nothing you decided is lost. [Restart the Engine] [Show the Log]" |
| Engine restarted | "The engine stopped and was restarted. Nothing you decided is lost." |
| The one reassurance | "Nothing you decided is lost." — the same words wherever it is said; there were three versions of it |
| Empty library | "No shoots yet. Put a memory card in to copy your first shoot." |
| Card already copied | "All 1,558 frames on this card are already in 2026-09-13-dog." |
| The list of work | One name, **Up Next**: the heading, the toolbar's button to it, "Add to Up Next" on a step's button (with ⌥, or while something of his runs; on Cull and Presets a line beside it says why, naming the work in the way as the list does and never by the engine's title, which brought back retired words: "Happening now: Write the presets · 2026-09-13-dog. This goes after it in Up Next." or "Up Next is held; …") and on the busy notice, "Cull is in Up Next.", "Remove from Up Next". The window it lives in stays **Activity**, because the history is there too. A row's word is what its button promised: "Build the PhotoLab folder", "Write presets for the burst". A row that cannot run says "Can't run yet" over the engine's reason, not "This will be skipped". |

**One word for one shot: frame.** The copy's button said "Copy 1,558 Photographs", its bar
"copying: 412 of 1,157 files", the sidebar then "1,558 frames", and Reels "Pictures from": four
names for the thing the light table steps through. It is a **frame** wherever a count or a sentence
means one shot — on the card's page, the copy's bar and its last line, an empty Cull, Finish's
exports and Reels' ("Exports from", "12 exported frames found"). **RAWs** and **originals** stay
where the kind of file is the point (Storage), and "your photographs" stays where it means his work
as a whole.

**US spelling, as the Mac's own menus spell it.** Window ▸ Center sat under the system's Minimize
spelled "Centre", Settings offered "Neutral Grey", and the zoom label read "1:1 · centred": every
word on screen is spelled the American way now — Center, Gray, centered, color. That includes the
engine's lines the app shows as they were written: a presets note ("colored light sources in
frame"), an editor's line ("the color mixer", "no color label"), an Instagram copy's ("its color
profile could not be read"), and what a cull, a presets run or a learning run prints into the log
Activity shows ("center crops only", "protect saturated colors"). Keys in the engine's own files
keep their names. This document is written in the British spelling it always was; the words it
quotes from the screen are the screen's.

**Retired words, enforced in CI**: *answer key, bench, taste, weights, probe, venue, AUC, held out,
duplicate, dup, tier, CSV, sidecar (in a control label), rating, veto, embedding, `./pl`*. Several of
them are the engine's own field names and have to be spelled in code to decode it; they are banned
from a label a person reads, and `app/tools/vocabulary-scan.sh` enforces that over the string catalog
and every strings file. The same scan enforces a second list — an extension's domain vocabulary —
over every tracked file, so it appears nowhere in this repository in any form, including identifiers,
test names, comments, file names and sample data.

### 2.14 Motion

- **Frame to frame by key: no animation.** An instant swap is the fastest read and the least tiring
  at 300 presses an hour. By swipe: the frame follows the fingers and settles — interactive, 1:1
  with the gesture, never a canned slide.
- Verdict badge: 150 ms spring in, no bounce out. Zoom: 180 ms spring, interruptible. Full Image
  in/out: 200 ms. Compare open/close: 220 ms. Step change: 120 ms crossfade. Stack expansion in the
  filmstrip: 180 ms ease-out on width only.
- **No animation ever delays input**: a key pressed mid-animation acts on the final state.
- **Nothing animates while a key is held** — and the way that is kept is that the light table has no
  implicit animation to hold back. Every animation in it names the value it belongs to, and none of
  those values is the frame. It was **not** kept for a while: `StepDetail` set the step crossfade as
  a *transaction* on the whole detail column, which rewrites the animation on every update flowing
  into the subtree rather than on the identity change it was written for, so the caption, the tally
  and the frame label eased on every K, D and arrow — and a `keyIsDown` flag was carried on the
  viewer model to guard against exactly that and read by nothing. The flag is gone with the
  transaction; a written-but-unread flag standing in for a documented rule is worse than neither.
- **A progress bar fills over its own poll interval**, not a fifth of it. The engine is asked every
  1.2 s and the fraction only moves when an answer arrives, so a 200 ms ramp lurched a sixth of the
  way and then sat still for a second, in four different bars. `.linear` is also the one curve
  macOS's own controls never use.
- **Reduce Motion**: all of the above become 100 ms crossfades, the swipe becomes an instant change,
  the rubber-band bounce becomes a static flash, a progress bar does not animate at all, the
  filmstrip and the second screen's contact sheet move to the cursor without sliding, and the Full
  Image bar fades in rather than rising from the bottom (it only shortened its slide to 100 ms).

### 2.15 Accessibility

- **Full Keyboard Access**: every control reachable by Tab with the system focus ring; the sidebar,
  scrubber, filmstrip and Compare grid are focusable lists with arrow-key movement. The page's step
  bar was unlabelled `<span>`s, invisible to Tab and to VoiceOver (NAT-05).
- **VoiceOver**: each frame announces *"Frame 04330, 2 of 7 in burst 3. You kept it. The cull's
  guess: maybe, the face is softer than most frames here. In a stack of 4 similar frames."* Custom
  actions on a frame: Keep, Drop, Clear the Mark, Compare. Progress is announced at start and finish
  only, `.polite`. The control bar is a group named "Frame controls", so its name is said before its
  first button; it was a group with no name.
- **Colour is never the only signal**: keep/drop/agreed differ by shape (filled check / filled x /
  hollow check or hollow x) as well as colour; a fault carries a triangle.
- **Increase Contrast** thickens the verdict badges, the current-frame ring and the stack bracket to
  3 pt and puts 1 pt borders around the control bar; in the filmstrip the marks grow to 16 pt, bold,
  on opaque discs, and the frame numbers take the full label colour (§2.5.9). **Reduce Transparency** swaps every glass and
  material surface for an opaque one.
- **Text size**: all type is semantic, so the system text-size setting scales the interface; the
  control bar grows and the viewer shrinks, never the other way. The picture is never scaled by it.
- **Voice Control**: every button's accessibility label is its visible text, so "Click Keep" works.
- **Pointer**: a magnifier at Fit, an open hand at 1:1, never hidden — with two stated exceptions
  on the second screen (`DESIGN-displays.md`): it is hidden on the picture window when it has sat
  still, which is a setting and on by default, and it is hidden throughout Presentation,
  where there is nothing on screen to point at.

### 2.16 The extension host

Extension steps appear as ordinary sidebar rows under a shoot, with the labels the extension
declares. Their content is a `WKWebView` filling the detail pane. **No iframe anywhere** — the page squeezed an
extension's whole screen into an 865 × 587 box that then rendered two columns (EXT-01).

Seven host rules, so the seam is invisible:

1. **Custom scheme, not http.** The web view loads `pipeline-ext://step/<id>?shoot=…` through a
   `WKURLSchemeHandler` that proxies to the engine, or to the extension's own port, adding
   `X-Studio-Key`. Nothing inside the page can read the key, no other local process can reach those
   pages, and the whole class of forgeries closes for extension pages including their images, which
   cannot carry a custom header when the page loads them itself (SEC-02/03/04).
2. **The host's look is injected, not re-implemented.** A `WKUserScript` at document start sets CSS
   variables from the live `NSColor` semantic colours and `-apple-system`, and re-sets them on
   appearance change — so an extension page is light in Light Mode and dark in Dark Mode with the
   app, never a third palette (EXT-02).
3. **Native viewer bridge**: `pipeline.viewFrames([stems], startAt, {actions, marks})` opens the app's
   own viewer over the page with Compare, 1:1 and the face aim. Every extension grid gets a full-size
   look for free and no extension has to build a loupe (EXT-04, EXT-05). As built: `ExtViewer`, with
   ‹ ›, and Choose Keepers' keys over Full Image (`ExtViewerKeys`, §2.5.3 "One scheme"): S F and ← →
   move, Q takes back the last mark made in the look, and Return, Space or Escape close it (only
   Return did). It moved on the arrows alone. It answers when he closes
   it, not when it opens, with `{index, stem, marks}`: fired and forgotten, the page never knew which
   frame he stopped on, so every frame he decided about was an open, a close, a scroll back to its card
   and a click. A page may offer up to four marks (`actions: [{id, label, key}]`, its own words, one
   letter each); they are checkboxes in the viewer's bar, a key toggles its mark on the frame on screen
   (once a press, never on repeat), a frame has one mark at most, and `marks` hands back and forth as
   `{stem: id}`. **E (or K) and D are a mark's only letters from the scheme**: a page that gives a
   mark E or K has made it what a keep leaves, and D what a drop leaves; each then goes on to the next
   frame, and X takes the mark off (`ExtViewerVerdicts`). Every other letter the scheme reads — S, F,
   X, Q, R, W, Z, C, G, N, P, U — asked for by a page goes to nothing, so no page can make one of
   them mean something else; the letters the scheme leaves free toggle the page's own marks as
   before. The Reels grid uses the same seam with one mark, "In the reel", and no letter of its own:
   E puts the frame on screen in, D leaves it out and X puts it back, as on the grid, applied as he
   presses them, and closing leaves the grid's keys on the frame he was looking at. It was X alone,
   toggling. A second look asked
   for while one is open ends the first where it began.
4. **Native confirmation bridge**: `pipeline.confirmDestructive(title, body, confirmLabel)` returns
   a promise and draws the app's own sheet, so anything of the extension's that goes out to the
   world is confirmed exactly like everything else (EXT-06). A question asked while another is up —
   this, or the page's own `confirm()` — waits its turn and is put up when he answers the
   one before; it was answered no unseen, so items asked about one after another were skipped. The
   contract asks for a batch to be confirmed once. **The page's `alert()` asks nothing and is not a
   sheet**: its sentence is one line under the page (`ExtSaidBar`), in the secondary colour with an
   info symbol — never the alarm colour — spoken to VoiceOver, and `alert()` returns at once. It goes
   after six seconds, at his next click on the page, when the page loads again and at the next thing
   the page asks of the app. A line said less than a second before the page loads again stays and goes
   by itself, and a second said within that second joins the first (the newest three at most): with
   nothing waiting for an OK, `alert('Published'); location.reload()` showed its sentence for no time
   at all, and two alerts in a row showed only the second (`ExtStepModel.saidTogether`). It was a sheet
   with an OK to click every time a page said "Six photographs are ready."
5. **Native state bridge**: `pipeline.state.get(key)` / `.set(key, value)`, replacing the
   per-shoot `localStorage` an extension's pages used before.
6. **Keys**: the app's menu shortcuts (with modifiers) always win; single-letter keys belong to the
   focused view, so inside an extension page they are the page's. The contract asks extensions to
   use the scheme's keys with the app's meanings or not at all (EXT-03, §2.5.3): S F and ← → move,
   ↑ ↓ a row, W R (P N) the burst before and after, E (K) keep or include, D drop or leave out, X
   (0) clear, Space large, Z 1:1, Esc back, Q (U) undo, Return the page's main button. The app
   cannot hold a page to it — its keys are its own script's — so that is the contract's to say and the
   page's to keep. The page has the keyboard once it has
   loaded — unless he is typing in a field elsewhere in the window — so its keys work on arrival;
   nothing made it first responder, and the first key after every visit went nowhere until a click
   inside the page. A field inside the page is a field to the menu (`TypingResponder`): the shim
   tells the host when he goes into or out of one, and the bare-letter rows stand aside as they do
   for the app's own fields — a web view is not an `NSTextView`, so with the picture on the other
   screen H (Hold) took the letter out of a caption as he typed it.
7. The context menu inside an extension page is the app's, never WebKit's (NAT-09); `isInspectable`
   is off unless Settings ▸ Advanced turns it on. Inside a field it keeps WebKit's spelling guesses
   (with Ignore and Learn Spelling), Cut and Paste — it offered Copy, Select All and Reload there, and
   a caption could not be pasted. WebKit names Copy and Paste but neither Cut nor a guess, so those are
   found where WebKit puts them: Cut just before Copy, the guesses in the groups above that name nothing
   (`ExtWebView.fieldItems`); matching them by names WebKit never sets kept Paste and lost the rest.
   Reload This Page is ⇧⌘R and only while the page has the keyboard: on ⌘R, a key equivalent reaches
   the page before the menu, so Shoot ▸ Cull's key reloaded the page and lost what was half done.

An added step's page is loaded afresh on every visit (the step view is rebuilt for each), so it is
never a stale picture of the shoot; keeping one alive across visits would need the page to refresh
itself when shown, which no page has promised. What made the reload cost: its subresources went
through `.studio` — no cache, four connections shared with the app's own pictures — and it came back
at its top. Now they go through `URLSession.extensionPages` (six connections, a memory cache that
honours the server's `Cache-Control`, nothing on disk, no cookies), and the page is scrolled back to
where he left it (`ExtPlaces`, noted as he scrolls by the shim) once it has grown tall enough, unless
he scrolls, clicks or types first.

**A link he clicks to the web opens in his browser** — "View on Instagram", "open the post". A link,
activated within a second of his own press on the page (a click, counted again as the button comes
up, or Return or Space on the link the keyboard is on — never one typed into the page's own fields),
to an `http` or `https` address that is not this Mac's, is handed to `NSWorkspace.open` — in the
page's own frame or as a window of its own alike — and the page stays where it is. Only the link's
own address goes: no key, no shoot name. It was refused with the red line, and he copied the address
by hand. Everything else a page does to leave its origin is still refused: a script moving
`location`, a window it opens by itself, a form sent off the Mac, an iframe, and a link to this Mac —
`localhost` and anything under it, all of 127.0.0.0/8, `0.0.0.0`, `::1`, `::`, the IPv4 ones written
as IPv6, and a `.local` name — which is an extension page that belongs in the app with its key rather
than in a browser without it (`ExtensionHost.goesToHisBrowser`, `isThisMac`). The press counted for
three seconds, and a Space typed into a caption counted as one, so a script's own `a.click()` in that
time, or one fired after a quick fetch set off by his click on something else, opened his browser as
if he had clicked the link.

What the host refuses is one sentence in a bar under the page (`ExtRefusalBar`), as tall as the
sentence at the width it is drawn at and never more than 96 pt — bounded alone it took the whole
bound, 112 pt for one line — with an × to put it away. It also goes when the page next loads and at
the next thing the page asks of the app; before, it stayed for the rest of the visit.

**The public side stays free of an extension's vocabulary by construction**: every string an
extension contributes — its question, its yes/no words, its badges, its step labels, its extra
option names — is fetched at runtime from `ExtConfig` and never compiled in, never in a string
catalog, never in a test fixture.

### 2.17 Instagram

**What it is for.** Instagram-sized copies of the shoot's finished photographs: 1080 wide, a portrait
cut to 3:4 or 4:5 around its subject, a landscape left whole or cut too. It is a step of the core
app, in every build, after Edit in PhotoLab and before Reels — it was a page of the private
extension, and three things about that page are why it was rebuilt rather than moved:

- *"when i do the instagram cut it doesnt actually show the cut lines on the image preview, i need
  to go in and select the cut option then hit escape for it to show in the preview."* The lines
  were drawn only after a photograph had been opened in its editor and closed again.
- *"why do i have 2 of the same lists of images one wiht cut lines one without?"* The page had a
  list to tick and a second wall of the same photographs to look at.
- *"Why not just render all the potential cut lines, let me select and adjust what i want to
  save?"* That is the step: one wall, every cut drawn on it, a tick for what is made, and a click
  to adjust.

**The wall.** One region under a two-line header, and the action bar every step has
(`InstagramStep`). The wall is a grid of square tiles, 150 pt at the least, three columns at the
900 × 620 minimum, one tile per exported photograph — the photographs Edit in PhotoLab counts as
exported (`Shoot.exported`), each by its finished file: export/ or edit/, the newest there; else
iCloud; and reels/ or upload/ only for a frame with no other export (`exports.files`). A burst frame
exported again for a reel, later and with another edit, is not his finished photograph, and neither
is a reel frame he never finished as a still. Each tile is the export itself, from
`/exported/` at 400 px — never the camera's JPEG, never the cull's decode — fitted in the square,
with the cut drawn on it in fractions of the frame (`InstagramCutLines`):

- **the clear line** is the cut Make writes now: a 2 pt white line with a dark hairline outside it,
  and a 35 % scrim over what the copy loses;
- **the faint line** is the option not taken, 1 pt dashed at half strength: for a photograph being
  cut, the other portrait shape's window; for one left whole, the cut at the shoot's shape. Both
  options show at a glance, and changing between them is one press in the editor.

If the picture that arrives is not the shape the record describes (he exported it again at another
crop), no line is drawn over it: a line in the wrong place is worse than none. Top-left of the tile
is its box; top-right a triangle when the profile grid would lose the subject and a pencil when the
cut is his; under it the frame's number and one line of state.

The **order** is the engine's: photographs whose cut the profile grid would lose the subject in come
first, then the rest by number. It is taken when the step opens and when a pass working out cuts
ends — never while a pass fills the wall in, so a tile does not move under his eyes as cuts fill in.
When a pass's end takes it while the ring is shown, the ring stays on its photograph and the wall
scrolls to it. A photograph the answer adds goes at the end; one it drops goes.

| State | What it means | The tile says |
|---|---|---|
| not worked out | no record of it yet | "working out…" with a spinner while a pass runs, else "not worked out yet"; no lines |
| worked out | a record, from the export that is there now | "cut to 3:4", "left whole", with "· your cut", "· made", "· made at 4:5" |
| exported again | a record from an earlier export | "exported again", or "exported again since it was made"; the old lines at half strength; never made until worked out again |
| made | a copy is in the folder | "made" when the copy is exactly the cut shown, "made at 4:5" when it is another size |
| a grid miss | the profile grid's middle 3:4 would lose the subject | "the grid cuts the subject", in orange, and first on the wall |

**Shapes.** Two pickers in the header: Portraits [3:4 | 4:5] and Landscapes [Whole | Cut]. A change
is one `POST /api/instagram/shape`, and every tile redraws from its answer at once. The record keeps
the shape, so the next make uses it; a cut he set by hand — Cut or Whole chosen in the editor — is
never moved by a picker. While copies of this shoot are being made the engine refuses a shape
change with its sentence, which is shown beside the pickers and leaves them as they were.

**Choosing what is made.** The box on a tile includes it; a second click takes it back to
unmarked. E or K includes and D leaves out, as Keep and Drop do; X or 0 clears. **Nothing ticked
means all of them**: with any tile included, only those are made and the rest dim; with none, every
one not left out is. A tile left out is grey under a scrim that says Left out. Marks are kept per
shoot for as long as the app is open.

What Make writes is exactly the cuts shown (§7.14): what he chose, whose cut is worked out from the
export that is there now, and whose copy is not already that cut. A photograph not worked out yet,
or exported again, is never sent — its cut is not the one on the screen — and a copy that is already
the cut shown is not made twice. The line beside the primary says what it will do: "Makes 353 — all
but the 3 you left out.", "Makes 5 — the ones you included.", "Makes 316 — every one not made yet.",
with "40 are already made as shown." and "12 still being worked out are not included." as they
apply — "still being worked out" only while a pass runs or is about to be asked for; after a Stop, a
failure, or while a job of his holds the slot it is "12 not worked out yet are not included." — and
with nothing to make, why: "You left every photograph out.", "Still working out these cuts." (or
"These cuts are not worked out yet."), "All 40 are made as shown. A cut you change is made again at once." ("It is made as shown."
when the one chosen is), or before anything is exported, "Nothing is exported yet. The copies are
cut from your finished photographs, so export from PhotoLab first."

**Keys: Choose Keepers' own.** He asked for it in so many words — *"make sure there is control
parity so same way you maneuver the other steps carries over and i'm not doing different buttons
for forward and backward etc"*. So the step has **no key table of its own**: one local monitor
(`InstagramKeySink`, the `LightTableKeys.route` pattern, guard for guard) reads every press with
`KeyMap.action(for:mode:spaceShowsWholePicture:)` — the wall in Single's mode, the editor in Full
Image's — and one total function, `InstagramKeys.meaning(of:in:)`, says what each of Keepers'
actions does here. The left-hand keys (E D S F X Q) came to `KeyMap` with the one-handed layout
and worked here with no change to this step. `InstagramKeysTests` walks every press `KeyMap` knows
and holds the two tables to each other, and pins his left hand's keys one by one; `KeyParityTests`
holds the wall and the editor to the one scheme with every other place that shows photographs
(§2.5.3).

| Keepers' action (its keys) | On the wall | In the editor |
|---|---|---|
| Next / Previous Frame (F, → / S, ←) | the ring to the next / previous tile, scrolled into view; stops at the ends | the cut saved, then the next / previous photograph in the wall's order |
| ↓ / ↑ | the ring a row down / up | — |
| Keep (E, K) | include the ringed tile, then on to the next (Keep then next) | include this one, then the next photograph |
| Drop (D) | leave it out, then on to the next | leave it out, then the next photograph |
| Clear the Mark (X, 0) | unmarked, and stay | unmarked, and stay |
| Full Image (Space) | open the editor on the ringed tile, at Fit | save and close (Space toggles, as Full Image does) |
| Z / ⌘0 / ⌘9 | open the editor at 1:1 / at 1:1 / — | Fit ↔ 1:1 / 1:1 / Fit |
| ⇧ arrows | — | move the cut 0.005 of the frame a press; repeats |
| Undo (Q, U, ⌘Z) / Redo (⇧⌘Z) | undo / redo, the ring on the photograph it changed; always taken, never a beep | the same, the editor opening on the photograph it changed, as Q puts him back on the frame in Keepers; a draft is thrown away first, and Redo waits while a draft is open |
| Esc | taken, and nothing happens, as on Keepers with nothing to leave | save and close |
| ? | the Keyboard Shortcuts window | the same |
| everything else Keepers has (1–6, N/R, P/W, C, ⇧K, G, Return in All Bursts, ⌘+ ⌘−) | not taken | not taken |
| Return (Keepers has none here) | not taken: the step's primary makes the copies, as on every step | Done |

The repeat rule is Keepers': a held key that is not movement is one press, and its repeats are
taken and do nothing; a held arrow moves on every repeat. **The one shift of meaning** is ⇧-arrows:
in Keepers they move the view at 1:1; here they move the cut, and at 1:1 the view goes with it.

Four meanings have no key in Keepers, so the editor takes four keys `KeyMap` leaves unused in every
mode, all under the left hand or beside it: **A** back to the automatic cut, **T** Cut ↔ Whole,
**V** Result on and off, **− and =** the cut smaller and larger by 4 % (pinch does the same). They
are read only when `KeyMap` returns nothing and no ⌘, ⌥ or ⌃ is held, they are named in each
control's help tag, in the editor's keys line, and in the Keyboard Shortcuts window under Instagram
with Move the Cut ⇧←→↑↓ (`InstagramKeys.shortcutRows`, §2.12), and a test asserts `KeyMap` has none
of them and that each listed key is the one the editor reads. A, T and V sit under the left hand;
− and = do not — they are the Mac's own pair for smaller and larger, and a size is usually set with
the mouse his right hand is already on, by a corner of the cut. The extension editor's `,` `.` `1`
`2` `R` and plain-arrow nudges are gone, and so is its wheel-resize.

**The scroll is Keepers' too.** At Fit and at Result a scroll over the photograph steps photographs
exactly as a scroll over the fitted frame steps frames in Choose Keepers (§2.5.8): the same stepper
(`ScrollInput.FrameScroll`), so one wheel notch or one firm flick of a trackpad is one photograph,
toward him the next, never on momentum, and ⌥ — Keepers' picks — does nothing here. It is read by a
view behind the photograph that no click reaches (`InstagramScrollArea`), so every drag and pinch
stays the cut's. At 1:1 a scroll pans, as it does there. On the wall a scroll scrolls the wall.

Return on a tile opens it only when Full Keyboard Access has put its focus there — the tile is a
button, so Space and Return press it — and otherwise it is Make, as Return is the primary on every
step. Space opens the editor and closes it whatever Settings ▸ Choosing's Space says: that setting
chooses between the whole picture and the next burst, and this step has no bursts, so it reads the
table with Space as the whole picture (`InstagramKeys.keepersAction`).

The menu rows follow (`InstagramCommands`, §2.12): while the step is on screen, Frame ▸ Keep reads
"Include 05901", Drop "Leave Out 05901", Clear the Mark, Next and Previous Photograph; View ▸ Full
Image reads "Adjust the Cut", or "Back to the Photographs" in the editor, and Actual Size and Zoom to
Fit are the editor's; Edit ▸ Undo names what it takes back — "Undo Include 05901", "Undo Cut
05901".

**The editor.** A click on a tile — or Space, Z, or Return on a tile he tabbed to — opens it over the
whole step, action bar included (`InstagramEditor`, modal to VoiceOver). A bar of what can be done:
‹ ›, the frame's number and "3 of 40", [Cut to 3:4 | Whole], [Fit | 1:1 | Result], Automatic, Done;
below about 760 pt it is two rows. The photograph with its draft cut, four corner handles, the
thirds, the faint window, a dot at the subject, and — when the post is wider than 3:4 — the strip
the profile grid shows, the rest of the cut shaded and the strip's edges dotted. A bar of what the
cut comes to: "1080 × 1440 · keeps 64% of the frame · your cut · not made yet", the grid warning in
orange when the subject falls outside the strip, [Include] [Leave Out] (neither on when unmarked),
and the keys line.

A drag inside the cut moves it; a drag at a corner sizes it about its centre, keeping its shape;
pinch sizes it. Every move goes through the engine's own window arithmetic and back
(`InstagramWindow.windowOf`, then `fromRect`, rounded as the engine keeps it), so the cut stays
inside the frame exactly where the engine will put it. Whole draws the frame as a post would take
it and does not drag; a window he moved before pressing Whole is kept with it, and is the faint line
on the tile as it was in the editor. 1:1 is one pixel of the export to one of the screen, loaded at its own size,
centred on the cut and following it when a key moves it; scrolling pans. Result is the export cut
to the draft and fitted at the size it will be written — always there, made or not.

The cut is **saved when he leaves it**: the next or previous photograph, Done, Esc, Space, or undo.
The tile takes the draft at that moment — the same arithmetic the engine does, so it does not wait
— and the engine's answer replaces it; a refusal puts the tile back and says why. A copy already
made is made again with the cut in the same request, so a made copy always shows his latest cut;
one not made stays for the primary. Undo takes back marks locally and a cut by sending the cut
that was there before (`restore`).

**Working out the cuts.** Automatic, in the background, the moment the step opens: when any
photograph has no cut, the step asks the engine (`POST /api/instagram/plan`), which starts one pass
over exactly those photographs as the machine's own homework. A pass writes the record and **no
photograph**; tiles fill in as it goes, and the header shows the engine's words and a bar. There is
one pass at a time — the engine holds one lock from "is a pass of this shoot running?" to the pass
started, so two asks in the same moment start one — and it is stood down by any press of his, like
the learning run: his job takes the slot, the header says "The cuts are worked out when making 5
Instagram copies is done.", and when the slot is free again the step asks again, at most once every
five seconds. The engine says which passes it stood down (`stood_down` on the job), and only a pass
that ended stopped without it is his Stop: a pass he stops stays stopped — "Stopped." [Work Out the
Rest] — and one that fails says its last line with [Try Again]; neither asks again by itself. A
shape change stands a running pass down (it would write the old shape back) and starts it again in
the same request over what it had not reached; the step asks itself if that start found the slot
taken. Nothing is asked while this shoot's copies are being made.

One export that will not read — PhotoLab still writing it while the step works the cuts out — is
that photograph's problem, not the pass's: it is skipped with a line in the log, no record is
written for it, and the next pass tries it again. A pass that could read none of its photographs
fails with the first one's reason and "If it is still being exported, wait for it to finish;
otherwise export it again." An export written in the last 8 s (`IG_SETTLE`) is left for the next ask
rather than read half-written.

**Making the copies.** The primary is **Make N Copies** (Make 1 Copy; Make Copies, greyed, with the
line saying why), in the step's box, and its progress is drawn in the same box (`StepPrimary`,
`JobInPlace`, §2.7). ⌥ puts it on Up Next, and while something of his runs it goes there by itself;
the list item carries the stems, so what the list makes later is what he chose now. When it is done
the sidebar's step is done (a copy exists). When the item is built — at the press, or at its turn
on Up Next — only the photographs whose cut is still the one he was shown are kept: one exported
again since would have its subject looked for again and a copy cut that he never saw, so it is left
out and named in the item's line ("F0002 was exported again since and is left for you to look at.").
Show the Folder opens `<shoot>/instagram` and never creates it (§7.10).

**The engine's half.**

| Route | Answers | Does |
|---|---|---|
| `GET /api/instagram?name=` | at once | the wall: the shape, the counts, a pass or make running, the job he is waited on, and every exported frame with its clear cut, faint cut, automatic window, whole cut, copy and whether the copy is current |
| `GET /exported/<shoot>/<stem>.jpg?px=&v=` | at once | the export, upright, at 200–2400 px, cached beside the cull's pictures; `px=full` is the export's own bytes |
| `POST /api/instagram/plan` | at once | starts a background pass over the photographs with no cut, or says it already is, that there is nothing to do, or which job of his holds the slot |
| `POST /api/instagram/make` | a job | makes exactly the stems named, at the shape they were worked out at; on Up Next it is kind `instagram` |
| `POST /api/instagram/crop` | at once | saves one frame's mode and window, or puts one back; a made copy is made again in the request |
| `POST /api/instagram/shape` | at once | the shoot's shape; every cut the engine chose moves, his do not; a pass it stood down starts again (`replanned`); the whole wall again |

**Made** is a copy in the folder. **Current** is a copy whose size is the cut's and which is newer
than the export: exactly the cut shown, because a cut he changes on a made copy is made again the
moment it is saved. A shape change makes a copy not current (its size differs), and so does
exporting the photograph again.

**Accessibility and the minimum window.** A tile is one button: its label the frame's number, its
value only what is true ("cut to 3:4, 1080 by 1440, keeps 64 percent; your cut; the profile grid
would cut the subject; made; included", or "working out its cut"), its hint "Space adjusts the
cut", and Include, Leave Out, Clear and Adjust the Cut as actions. The wall is labelled "Instagram
cuts". In the editor the cut is one adjustable element — increment and decrement size it — with
Move Left, Right, Up and Down, Automatic, and Cut or Whole as actions, and bar two's line as its
value. At 900 × 620 the header keeps to two lines (the warning shortens, then the pass's words move
to the bar's help tag), the wall has three columns, the action bar holds the 320 pt box, and the
editor's bars fold to two rows; the `instagram-min`, `instagram-planning-min` and
`instagram-editor-min` scenes are the gate.

---

## 3. Architecture

### 3.1 Deployment target

**macOS 15.0**, built with the macOS 27 SDK on Xcode 27 / Swift 6.4, strict concurrency on.
`LSMinimumSystemVersion` moves from 14.0 to 15.0.

Why 15 and not 14: Swift 6 strict-concurrency behaviour and `@Observable` are materially better on
15; `ToolbarItem` title/subtitle and the unified toolbar/sidebar parity this design leans on land
there; and it is two releases behind the build machine, which covers every Mac Apple still ships
updates to at release. Why not 26 or 27: the app is a public MIT project and there is no feature in
§2 that needs it.

Everything load-bearing exists on 15: `NavigationSplitView`, `.inspector`, `Table`,
`ContentUnavailableView`, `@Observable`, `UndoManager`, `NSView.displayLink(target:selector:)`,
`NSEvent.trackSwipeEvent`, `smartMagnify`, pressure/force click, `NSHapticFeedbackManager`,
`beginActivity`, `NSDockTile` progress, `UNUserNotificationCenter`, `WKURLSchemeHandler`,
`ImageRenderer`.

Used **behind `#available(macOS 26, *)`**, always with a same-geometry fallback so nothing reflows
by OS version:

| macOS 26+ | Where | Fallback on 15 |
|---|---|---|
| `.glassEffect(in:)`, `GlassEffectContainer` | Full Image HUD, stack badge, scrubber popover, job popover | `.background(.ultraThinMaterial, in: <same shape>)` |
| `.buttonStyle(.glass)` / `.glassProminent` | verdict buttons, step primaries | `.bordered` / `.borderedProminent`, identical frames |
| `ToolbarSpacer(.flexible)` and 26 toolbar grouping | toolbar | `Spacer()` inside a `ToolbarItemGroup` |
| `.backgroundExtensionEffect()` | picture bleeding under the sidebar in Full Image | plain background; the picture stops at the split |
| `.scrollEdgeEffectStyle` | filmstrip and table edges | a hairline separator |
| SwiftUI `WebView` / `WebPage` | extension step views | `WKWebView` in an `NSViewRepresentable` |

Nothing macOS 27-only is used.

### 3.2 Project layout — a Swift package

No Xcode project. `app/` becomes the package root so the repo root stays Python, and `build.sh`
stays a shell script that he or CI can run.

```
app/
  Package.swift                       # swift-tools-version: 6.0, platforms: [.macOS(.v15)]
  Sources/
    FirstEdit/                        # executable target — thin, 3 files
      main.swift  FirstEditApp.swift  AppDelegate.swift
    PipelineKit/                      # library target — everything else, all testable
      Engine/      EngineHost.swift  StudioKey.swift  ServerProcess.swift  UpdateCoordinator.swift
      API/         StudioClient.swift  Routes.swift  Models/*.swift  StudioError.swift
      Images/      ImagePump.swift  ImageCache.swift  Downsampler.swift  TileFetcher.swift  Budget.swift
      Design/      Tokens.swift  Symbols.swift  Motion.swift  Strings.swift  Materials.swift
      State/       Library.swift  ShootSession.swift  JobModel.swift  Navigation.swift  SettingsStore.swift
      Shell/       RootView.swift  SidebarView.swift  StepDetail.swift  InspectorHost.swift
                   EngineDownView.swift  ActivityWindow.swift  RefusalRow.swift
      LightTable/  …                  # §5.1
      Steps/       …                  # §5.2
      Storage/  Learning/  FirstRun/  SettingsUI/    # §5.3
      Commands/  Help/                # §5.4
      ExtensionHost/                  # §5.5
      Media/                          # §5.8 (the Reels step itself is Steps/Reels*.swift)
    SnapshotHarness/                  # executable target — renders screens to PNG
      main.swift  Harness.swift  Scenes/<Area>/*.swift
  Tests/
    PipelineKitTests/
      Fixtures/*.json                 # captured from the real server
      Decoding/  Engine/  Images/  LightTable/  Steps/  Storage/  Commands/  Strings/
  Resources/     Info.plist  entitlements.plist  AppIcon/  Localizable.xcstrings
  tools/         capture-fixtures.sh  bench.swift  smoke.sh  vocabulary-scan.sh
  build.sh
```

SwiftPM includes every file under a target's directory, so **`Package.swift` is written once and
never edited** — a new feature is a new file in its own folder. That removes the one guaranteed
merge conflict from any work done in parallel.

### 3.3 App lifecycle and the engine

`EngineHost` does what the old `app/main.swift` shim did (start the bundled Python, read `PORT n`
from stdout, SIGTERM on quit and wait up to 3 s before SIGKILL, watch stdout for the `QUIT` sentinel
the updater prints), plus the per-launch key.

- **The key**: 32 bytes from `SecRandomCopyBytes`, base64url. Passed to the child in
  `PIPELINE_STUDIO_KEY`. Sent as `X-Studio-Key` on **every** request including images. Never written
  to disk, never in a URL, never in the log — `Log.redact` strips it from any captured text.
- **Environment** handed to the child (extending the set the shim passed): `PIPELINE_MODELS`,
  `PIPELINE_BUNDLED_MODELS`, `PIPELINE_CLIP_CACHE`, `PIPELINE_EXIFTOOL`, `PIPELINE_SUPPORT`,
  `PIPELINE_APP_PATH`, `PIPELINE_APP_VERSION`, `PIPELINE_APP_PID`, `PYTHONUNBUFFERED=1`,
  `PYTHONDONTWRITEBYTECODE=1`, `PYTHONNOUSERSITE=1`, a fixed `PATH`, the ffmpeg lookup unchanged
  (until §3.10 replaces it), plus **`PIPELINE_STUDIO_KEY`**, **`PHOTOS_ROOT`** (from Settings) and
  **`PIPELINE_EXT`** (from Settings, when set).
- **Arguments**: `pipeline/studio.py --app --no-open --port 0` — unchanged.
- **Failed start**: `EngineDownView` (`ContentUnavailableView`, `exclamationmark.triangle`,
  "First Edit's engine stopped", one sentence, [Restart the Engine] [Show the Log]).
  It restarts in place without losing which shoot he was on. The last line of the log is read
  (`EngineFailure`), never printed as the sentence: a missing module or no interpreter says *"Part
  of First Edit is missing. Install it again from the disk image — your photographs and
  decisions are untouched."* with Restart offered but not the default, because it fails the same
  way every time; the host's own sentences (no port, an exit code) are shown as they are; anything
  else says it stopped on an error of its own. Where restarting can help, what to do follows
  "Nothing you marked is lost.": *"Restart it. If it stops again, choose Help ▸ Report a Problem…
  and attach the log."*, and Show the Log selects the file in Finder, as Settings' does. The engine's own words go in
  a Details disclosure, monospaced and selectable — never a traceback in the body. The child's exit is reported only once
  both of its pipes have been read to the end (bounded at 2 s, for a grandchild that kept one open),
  because the exit and the last bytes of stderr arrive on different queues in no fixed order: reported
  as it came, the exit put the line before the real reason — or nothing, and "exit 1" — under the
  title. An exit from a child a restart has already replaced is logged and otherwise ignored.
- **Crash while running**: one automatic restart, then a non-modal banner — *"The engine stopped and
  was restarted. Nothing you decided is lost."* It lies over the top of the page rather than
  pushing it down — on Choose Keepers under the burst scrubber, which it covered, not over it — has a
  close button, and goes by itself after 8 s or when he moves to another
  page: cleared only by a click on it that nothing invited, it sat over the light table for the
  rest of the evening. A second crash within 60 s goes to `EngineDownView` instead of looping.
- **Quit**: `applicationShouldTerminate` asks the running-job question (§2.7); `applicationWill
  Terminate` terminates the child exactly as the shim did.
- **Updates**: kept as they are — a background check populates the sidebar footer row; download and
  install are two separate explicit actions; install prints `QUIT`, which `EngineHost` watches for
  and terminates cleanly. Sparkle is explicitly **not** adopted in v1: the engine already verifies
  codesign and notarization before installing, and adding Sparkle changes the signing story for no
  user-visible gain. Presented natively: no banner that pushes content (FLOW-04), a plain sentence in
  the sidebar footer and in About, and a small sheet when he asks (§7.9). With "Check for updates
  automatically" off, the app starts the engine with `PIPELINE_NO_UPDATE_CHECK=1` and the engine does
  not ask GitHub at launch; before, the switch changed nothing.

### 3.4 The API client

```swift
public struct Route<Response: Decodable & Sendable>: Sendable {
    public let method: Method, path: String, query: [String: String]
}

public actor StudioClient {
    public init(endpoint: EngineHost.Endpoint, session: URLSession = .studio)
    public func get<R>(_ route: Route<R>) async throws -> R
    public func post<B: Encodable & Sendable, R>(_ route: Route<R>, _ body: B) async throws -> R
    public nonisolated func imageRequest(_ image: ImageRoute) -> URLRequest   // carries the key
}

public enum StudioError: Error, Sendable, Equatable {
    case refused(String)                  // {"error": …} — the engine's own sentence, shown as-is
    case http(status: Int, body: String)
    case offline
    case decoding(route: String, detail: String)
    case engineDown
}
```

Every response is decoded as a union of the route's success shape and `{"error": String?}`, because
that is how the server behaves; `/api/rating`, `/api/kind` and `/api/storage/apply`
carry both at once and their models keep both fields. `StudioError.refused` text is **never
rewritten** — the engine writes in his words and the app prints them.

#### Codable models — every route

```swift
// GET /api/shoots
struct ShootsResponse: Decodable { let shoots: [ShootRow]; let cards: [String]
    let ext: ExtConfig?; let ready: Bool; let app: Bool; let update: UpdateInfo }

enum ShootRow: Decodable {                       // discriminated on `broken`
  case ok(ShootRowOK), broken(ShootRowBroken) }

struct ShootRowOK: Decodable {
  let name, path, raw, export: String
  let kind: String?
  let reviewed, culled, raws_cleared, finished, thumbs: Bool
  let keepers, picks, cull_picks, kept, dropped, bursts, seen: Int
  let card, style, editor, export_where, at, review_stale, verify, presets_note: String
  let focus: Double
  let frames, raws, sidecars, reels, presets, exported: Int
  let sidecar_kinds: [String: Int]
  let reel_dir: String
  let ingest: IngestNote
  let storage: StorageHome?
  let can_cut_reels: Bool                        // NEW (§3.9-5)
  let steps: [StepState]?                        // NEW (§3.9-7): the page's own steps, on the row
  let extra: [String: JSONValue]                 // an extension's fields, never named in this repo
}
struct ShootRowBroken: Decodable {
  let name, path, broken, broken_where: String; let broken_file: String?; let frames: Int }

struct StorageHome: Decodable { let frames: Int; let phrase: String
    let cells: [StorageCell]; let bad: Bool; let lost: Int?; let error: String? }
enum StorageCell: String, Decodable { case full, hollow, none, gone, some }

struct ExtConfig: Decodable { let kind: String; let ask: ExtAsk
    let steps: [String]; let labels: [String: String]; let every: [String]
    let pages: [String: String] }                // NEW (§3.9-9): step id -> URL template
struct ExtAsk: Decodable { let question, yes, no, blurb, badge, other_badge: String }

struct UpdateInfo: Decodable { let newer: Bool?; let current: String; let latest, url, page: String?
    let installed: Bool?; let staged: Bool; let error: String? }

// GET /api/cards — the paths, and what is on each card (read off the card, so asked for by the card
// page and not on every re-read of the library the way /api/shoots' `cards` is)
struct CardsResponse: Decodable { let cards: [String]; let described: [CardContents] }
struct CardContents: Decodable { let path, name: String; let photographs, bytes, first, last: Int
    let copied_as: String; let held: Int; let stopped: Bool }  // copied_as "" when no shoot holds any

// GET /api/shoot?name=&full=&light=
struct ShootResponse: Decodable {
  let info: ShootInfo
  let rows: [Row]
  let presets: [PresetRun]
  let review: Review
  let bursts: [Burst]         // NEW (§3.9-6)
  let steps: [StepState]      // NEW (§3.9-7)
  let resume: Resume          // NEW (§3.9-6)
}
struct ShootLightResponse: Decodable { let info: ShootInfo }

struct ShootInfo: Decodable {                    // Shoot.info(), field for field
  let name, path, raw, export: String
  let kind: String?
  let reviewed, culled, raws_cleared, finished, thumbs: Bool
  let keepers, picks, cull_picks, kept, dropped, bursts, seen: Int
  let will_be_edited: Int                        // NEW (§3.9-4) — what gets a sidecar, nobody's opinion
  let agreed: Int                                // NEW (§3.9-4)
  let card, style, editor, export_where, at, review_stale, verify, presets_note, reel_dir: String
  let export_dirs: [String]   // the folders in the shoot holding exports; editor "" when none of its own
  let focus: Double
  let frames, raws, sidecars, reels, presets, exported: Int
  let sidecar_kinds: [String: Int]
  let ingest: IngestNote
  let can_cut_reels: Bool                        // NEW
  let extra: [String: JSONValue]
}

struct Row: Decodable {                          // ROW_KEEP, plus the new columns
  let file, stem: String
  let rating: Int                                // the cull's own 0/1/2/3/5 — the machine
  let override: Int?                             // his — never merged with `rating` in this app
  let reason, face_flags: String?
  let face_score, quality, borderline, focus, aesthetic: Double?
  let group, scene, burst, moment, shot_at: String?
  let face_x, face_y: Double?
  let face_w, face_h: Double?                    // NEW (§3.9-3)
  let subject: [Double]?                         // NEW (§3.9-3) [x,y,w,h] normalised
  let stack: String?                             // NEW — stack id
  let stack_top: Int?                            // NEW — 1 on the cull's guess
  let label, edit_note: String
  let tw, th, lw, lh, dw, dh: Int?
}

struct Burst: Decodable {                        // NEW — the server groups, not the app
  let id: String; let index: Int; let scene: String?; let started_at: String?
  let frames: [String]; let cover: String?
  let seen: Bool; let kept: Int; let out: Int; let cull_picks: Int; let undecided: Int }

struct StepState: Decodable {                    // NEW — one table, not two
  let id, label: String; let done, enabled: Bool
  let why_disabled: String?; let source: StepSource }
enum StepSource: String, Decodable { case base, extensionProvided = "extension" }

struct Resume: Decodable { let burst_id: String?; let kind: ResumeKind; let note: String }
enum ResumeKind: String, Decodable { case left_off, moved, all_seen, fresh }

struct Review: Decodable { let at: String; let bursts: [String: ReviewBurst]; let stale: String }
struct ReviewBurst: Decodable { let seen: String; let from: String? }
struct PresetRun: Decodable { let notes: [String]?; let decided: [String: String]?
    let left_alone: [String]? }                  // NEW (§3.9-8)

enum IngestNote: Decodable {                     // decoded on `state`
  case none, failed(detail: String), stopped(files: Int, of: Int)
  case done(files: Int, proof: String), unclear(log: String) }

// GET /api/jobs/history — the last few days' finished work, every run of the engine's (§2.7)
struct EarlierJobs: Decodable { let run: String; let jobs: [EarlierJob] }
struct EarlierJob: Decodable { let run: String; let id: Int; let kind, title, shoot, why, log: String
    let background, from_list: Bool; let started: Double; let elapsed: Int; let outcome: String }

// GET /api/job
struct Job: Decodable { let running, stopped: Bool
  let id: Int                                    // NEW (§3.9-10) — monotonic
  let queued: Bool                               // NEW
  let kind, shoot, title, stage, label, log: String
  let fraction: Double; let elapsed: Int; let code: Int?
  let started: Double?                           // epoch seconds; the history's Started
  let queue_done: [QueueDone] }                  // closes a job the list replaced unseen

// GET /api/storage?name=
struct Storage: Decodable { let name: String; let archive: StorageArchive
  let states: [String: Int]; let order: [String]; let words: [String: String]
  let glyphs: [String: [StorageCell]]; let line: String
  let cache: StorageCache; let retain: Retain
  let icloud: String?; let free: Int; let free_text: String }
struct StorageArchive: Decodable { let frames, here, up, up_evicted, todo, pullable, droppable,
  drop_evicted, missing, lost, bytes_here, bytes_up: Int
  let here_text, up_text, todo_text, pullable_text, droppable_text: String }
struct StorageCache: Decodable { let bytes: Int; let bytes_text: String; let files: Int
  let derived_text, rebuildable_text: String; let refusals: [String]; let last_copy: LastCopy }
struct LastCopy: Decodable { let count: Int; let bytes_text: String; let with: [String] }
struct Retain: Decodable { let days: Int; let source: String; let finished: Bool
  let age_days, due_in_days, keepers: Int?; let due: Bool; let archived: Int }

// GET /api/storage/frames
struct StorageFrames: Decodable { let rows: [StorageFrameRow] }
struct StorageFrameRow: Decodable { let name: String; let bytes: Int; let bytes_text, state: String
  let cells: [StorageCell]; let words: String }

// GET|POST /api/storage/plan, POST /api/storage/apply
struct Plan: Decodable { let what: String; let counts: [String: Int]
  let bytes_text, label, why: String; let refusals, names, lines: [String]
  let ready: Bool; let token: String?; let error: String?; let stale: Bool? }

// GET /api/storage/library
struct LibraryLine: Decodable { let free_text, reclaimable_text, strays_text, root: String
  let files: Int; let strays: [Stray] }
struct Stray: Decodable { let name, bytes_text: String }

// GET /api/reel/options, /api/reel/watch
struct ReelOptions: Decodable { let sequences, cuts: [BurstOption]
  let frames: [ReelFrame]; let sources: [ReelSource]; let exports_found: Int
  let exports_dir: String; let tags: [ReelTag]?; let visible: Int?
  let reels: [ReelFile]; let reel_dir: String; let error: String? }
struct BurstOption: Decodable { let burst: String; let frames, exported: Int; let lands_on: String? }
struct ReelFrame: Decodable { let stem: String; let exported: Bool }
struct ReelSource: Decodable { let path: String; let frames: Int }
struct ReelTag: Decodable { let name: String; let frames: Int }
struct ReelFile: Decodable { let name: String; let bytes: Int; let at: String }
struct ReelWatch: Decodable { let jpegs: Int; let burst: String }

// GET /api/instagram, POST /api/instagram/plan|make|crop|shape  (§2.17)
struct InstagramStatus: Decodable { let shoot: String; let folder: String; let folder_exists: Bool
  let ratio, landscape: String; let ratios: [String]
  let exported, planned, unplanned, stale, made, grid_misses: Int
  let planning, making: InstagramProgress?; let waiting_for: InstagramWaitingFor?
  let frames: [InstagramFrame] }              // shoot and frames required; the shape answer is this too
struct InstagramFrame: Decodable { let stem: String; let file: String; let export_mtime: Int
  let state: InstagramFrameState               // unplanned | planned | stale, required
  let frame: PixelSize?; let mode, mode_by: String?; let adjusted: Bool
  let manual: InstagramManual?; let subject: InstagramSubject?
  let cut, other, whole: InstagramCut?; let auto: PixelRect?
  let copy: InstagramCopy?; let copy_current: Bool }
struct InstagramPlanAnswer: Decodable { let ok, planning, already, nothing: Bool; let id, count: Int
  let waiting_for: InstagramWaitingFor?; let error: String? }
struct InstagramCropAnswer: Decodable { let ok: Bool; let frame: InstagramFrame?; let remade: Bool
  let error: String? }                         // "Saved, but the copy could not be made again: …"
// ImageRoute.exported(shoot:stem:px:version:) -> /exported/<shoot>/<stem>.jpg?px=&v=
// InstagramWindow: the engine's window_of / auto / grid_ok, to the pixel (§7.14)

// GET /api/learned  (NEW, §3.9-11)
struct Learned: Decodable { let headline: String; let keepers, shoots: Int
  let last_checked: String?; let new_shoots: Int; let running: Bool
  let learners: [Learner] }
struct Learner: Decodable { let id, title, learned_from, plain_metric: String
  let status: LearnerStatus; let detail: String          // what is IN USE (§2.9)
  let candidate_sentence: String; let candidate_status: LearnerStatus?   // what waits beside it
  let needs_sentence: String                             // what it is short of, as things to do
  let check_do: [LearnerNeed]      // shoots its check could not reach for want of vectors: Measure
  let check: LearnerCheck?; let live_since, previous: String? }
enum LearnerStatus: String, Decodable { case in_use, not_in_use, not_enough, could_not_check, fixed }
struct LearnerCheck: Decodable { let keepers, checked, hidden, moved_down, moved_up: Int
  let shoot: String?; let frames: [LearnerFrame] }
struct LearnerFrame: Decodable { let shoot, stem, now, candidate, why: String }

// POST bodies and responses
struct IngestBody: Encodable { let card, name: String; let kind: String?; let verify: String }
struct OKName: Decodable { let ok: Bool; let name: String; let error: String? }
struct OK: Decodable { let ok: Bool; let error: String? }
struct ReviewBody: Encodable { let name: String; let at: String?; let seen, unseen: [String]? }
struct ReviewResult: Decodable { let ok: Bool; let seen: Int; let at: String }
struct KindBody: Encodable { let name: String; let kind: String?
  let reviewed, finished: Bool?; let style: String? }
struct KindResult: Decodable { let ok: Bool; let error: String? }   // both at once, deliberately
struct OpenBody: Encodable { let name, what: String
    let path: String?      // what: "exported" — one of the shoot's export_dirs, and nothing else
    let editor: String? }  // what: "photolab" — the editor to open the keepers in
struct OpenResult: Decodable { let ok: Bool; let folder: String?; let app, note, missing, error: String? }
struct CullBody: Encodable { let name: String; let style: String?; let focus: Double?
  let presets: Bool?; let top: Int? }
struct PresetsBody: Encodable { let name: String; let force, picks_only: Bool?; let editor: String? }
struct SelectsBody: Encodable { let name: String; let confirm: Bool? }
struct SelectsResult: Decodable { let n: Int?; let error: String?; let confirm: Bool? }
struct LabelBody: Encodable { let name, file, label: String }
struct RatingBody: Encodable { let name, file: String; let rating: Int? }
struct RatingResult: Decodable { let ok: Bool; let key_note: String }
struct RetainBody: Encodable { let name: String; let days: Int; let `default`: Bool? }
struct RetainResult: Decodable { let ok: Bool; let days: Int?; let error: String? }
// GET|POST /api/storage/default-retain — the library's let-go days, Settings ▸ Storage (§2.11)
struct RetainDefaultBody: Encodable { let days: Int }
struct RetainDefault: Decodable { let days: Int; let set: Bool; let error: String? }
// POST /api/learned/settings — Settings ▸ Learning's switches, no restart (§2.11)
struct LearningSwitchesBody: Encodable { let auto, idle_only: Bool }
// POST /api/learned/vectors — Measure, beside a check that could not reach a shoot (§2.9)
struct MeasureVectorsBody: Encodable { let shoot: String }         // answers OK, or the busy job
struct StorageCheckBody: Encodable { let name: String; let record: Bool? }
struct PlanBody: Encodable { let name, what: String
  let force, keepers, originals: Bool?; let after: Int? }
struct ApplyBody: Encodable { let name, what, token: String; let typed: String?
  let force, keepers, originals: Bool?; let after: Int? }
struct ApplyResult: Decodable { let ok: Bool?; let stale: Bool?; let plan: Plan?; let error: String? }
struct ReelBody: Encodable { /* format, burst|id, frames, fps, follow, size, ramp, exports, plan, tag, every */ }
struct SpreadBody: Encodable { let name, burst: String }
struct LearnedRunBody: Encodable { let learner: String? }
struct LearnedActionBody: Encodable { let learner: String }

// Image routes
enum ImageRoute {
  case thumb(shoot: String, stem: String)
  case large(shoot: String, stem: String)
  case preview(shoot: String, stem: String)
  case full(shoot: String, stem: String, px: Int)                       // px is NEW (§3.9-2)
  case crop(shoot: String, stem: String, cx: Double, cy: Double, px: Int, ar: Double)
  case reelThumb(shoot: String, stem: String, src: String?, px: Int = 400)  // px: the large view (§2.6)
  case ext(shoot: String, kind: String, name: String)
}
```

`JSONValue` is a small enum used only to carry extension-supplied fields through without naming
them; nothing in `PipelineKit` ever pattern-matches on a key from it.

### 3.5 The image pipeline

```swift
public actor ImagePump {
    public struct Key: Hashable, Sendable { let shoot, stem: String; let tier: Tier }
    public enum Tier: Hashable, Sendable { case thumb, large, full(px: Int), crop(CropBox) }
    // `tileBytes`, not a count: a count cannot tell eight 4096 px tiles
    // (358 MB) from eight whole-width tiles on a 5K (631 MB).
    // DESIGN-displays.md §4.5 and §7.2.
    public struct Budget: Sendable { var thumbBytes: Int; var decodedCount: Int; var tileBytes: Int
        var secondaryDecodedCount: Int
        public static let automatic: Budget }    // scales with ProcessInfo.physicalMemory

    public init(client: StudioClient, budget: Budget = .automatic)
    public func image(_ key: Key, priority: TaskPriority = .userInitiated) async throws -> CGImage
    public nonisolated func cached(_ key: Key) -> CGImage?
    public func prefetch(_ keys: [Key], priority: TaskPriority)
    public func cancelPrefetch(keeping: Set<Key>)
    public func report() -> Report                // for the bench harness
}
```

- **Transport**: `URLSession` with `httpMaximumConnectionsPerHost = 4`, every request carrying
  `X-Studio-Key`. Images are never loaded by a web view.
- **Decode off the main actor**: `CGImageSourceCreateWithData` +
  `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailFromImageAlways`,
  `kCGImageSourceShouldCacheImmediately: true` and
  `kCGImageSourceThumbnailMaxPixelSize = ceil(pointSize × backingScale)` — i.e. downsampled to the
  size it will be drawn at, never full size into a small view (the page handed a 1440 px asset to an
  1157 pt tile, and a 7.5 MB decode to a 1105 pt view).
- **Size tiers** so URLs stay cacheable: the client rounds the needed pixel width up to the next of
  `{1440, 2048, 2600, 3200, 4096}` and asks `/full?px=`. At 58.8 % of a 27" the picture is 1803 pt =
  3606 device px, which is past the fixed 2600 cap the page lived with (LT-05).
- **Progressive, never blank**: on any move the viewer shows whichever tier it already has —
  thumb → large → full — and upgrades in place with **no crossfade** (a crossfade on every keystroke
  is noise). The viewer is never empty and never waits.
- **One brightness for every tier of a frame, the camera's** (`DisplayTone`). `/thumb` and `/large`
  are the camera's JPEG; `/full` and `/crop` are the engine's RAW decode, made with the camera's
  white balance and no brightening, because the cull reads faces and focus on those pixels. On his
  2026-09-19 night the decode's mean brightness was 0.56–0.66 of the JPEG's, so every frame appeared
  at the camera's brightness and went about 40 % darker, with more contrast, when the sharp tier
  landed — while the filmstrip never did, and he calls exposure (reason 5) on that picture. So the
  pump redraws every `/full` and `/crop` it hands out through a per-frame tone curve that lays the
  decode's brightness distribution over the frame's own thumbnail's (17 quantiles, anchored at black
  and white, never falling), applied alike to red, green and blue so the decode's colour is kept, and
in the colour space the picture came in, so a profile an engine embeds one day is kept too. A
  curve, not a gain: a gain matching the average blew out 1.9 × the JPEG's highlights. On sixteen
  frames of that night it put the average within 1.9 levels of the camera's 1440 px JPEG and the
  blown highlights within 0.75 % of the frame. The curve is measured once per frame from its first
  `/full` (reading the thumbnail, which the filmstrip and every view climb through on the way up, or
  fetching it: nothing yet asks for a whole shoot's thumbnails as it opens, whatever the ladder below
  says), kept for the open shoot, and a `/crop` uses its frame's curve — never one measured on
  the window it cuts. A picture whose wait for that thumbnail was cancelled is not kept in the ring,
  and a request for it that arrives while that cancelled fetch is still ending — the stage, as he
  comes back to a frame whose prefetch was let go — starts a fetch of its own rather than joining
  the one being cancelled, which handed it the cancellation and left the soft camera JPEG up. A
  frame whose thumbnail cannot be fetched at all has no curve: its `/full` is drawn as it comes, and
  its 1:1 tiles are too, rather than each asking for a `/full` to measure with, a 1440 px RAW
  decode that only failed the same way; its next `/full` of another size tries again.
  **On screen only**: `cull/decoded` and every figure the cull wrote are untouched; a `/full` the
  engine served from the camera's preview measures as the identity and is left as it is.
- **Which views climb to `/full` is a question about what a box is *for*, never about how big it
  is.** `/large` and `/full?px=1440` are the same 1440 px on the long edge and are not the same
  picture: `/large` is the camera's embedded JPEG resized, which `common.py` says is "too soft to
  call a missed focus on", and `/full` is the RAW decode. So a **cover, a cell or a list thumbnail**
  stops at `/large` — a 90 pt filmstrip cell needs 180 px and was asking for 1440, a 180 pt burst
  cover 360, and scrolling All Bursts queued one 650–720 ms cold decode per cover crossed, ahead of
  the photograph he was looking at. Every view he **judges a frame in** — the stage, Compare, a full
  look — climbs to `/full` at whatever size it draws, 1440 included. A cap that asked only about
  size left the stage on the camera's JPEG at the 900 × 620 minimum (a 573 pt picture is 1146 device
  px, which rounds to 1440), on every window up to roughly 1010 × 730, and on every window at all on
  a 1× display — in Fit, which is the state he culls in.
- **The prefetch ladder** (priority queue; the frame under the cursor always jumps it, and
  outstanding prefetches for other frames are cancelled):

| When | What |
|---|---|
| shoot opens | every `/thumb` for the shoot, lowest priority, 4 at a time |
| burst opens | `/large` for every frame of the burst; `/full` for the cursor frame ± 2 |
| cursor moves | `/full` for the next 3 frames in the direction of travel |
| 1:1 engaged | the `/crop` tile for the cursor frame, then the same box on the next 2 frames |
| **burst is 3 frames from its end, or N is pressed** | **`/full` for the first frame of the next burst** — the single biggest wait the page had: PERF-01 measured ~1.8 minutes of pure waiting per 155-burst session, all of it at the first frame of a new burst |
| idle ≥ 2 s | the rest of the next burst |

- **In-flight cap**: the client allows at most 2 concurrent cold `/full` requests, mirroring the
  server's own decode gate, so prefetch can never queue behind itself and stall the frame he is on.
- **Memory**: compressed thumb data in an `NSCache` cost-limited to 96 MB; decoded `CGImage`s for
  the current burst in a ring capped at 24 or 512 MB, whichever is smaller; at most 8 `/crop` tiles.
  All caps scale with `ProcessInfo.processInfo.physicalMemory / 16`. A
  `DispatchSource.makeMemoryPressureSource` handler halves the thumb cache and drops the ring to 4.
- **Cancellation**: every fetch is a `Task`; leaving a burst cancels its outstanding prefetches
  with `URLSessionTask.cancel()`.
- **Frame budget**: `NSView.displayLink(target:selector:)` drives the viewer at the display's rate
  (120 Hz on ProMotion).

### 3.6 State

Four `@Observable` classes, all `@MainActor`:

```swift
@MainActor @Observable public final class Library {           // one, app-lifetime
    public private(set) var shoots: [ShootRowOK]
    public private(set) var broken: [ShootRowBroken]
    public private(set) var cards: [String]
    public private(set) var ext: ExtConfig?
    public private(set) var ready: Bool
    public private(set) var update: UpdateInfo
    public func refresh() async
    public func session(for name: String) async throws -> ShootSession
}

@MainActor @Observable public final class ShootSession {      // one per open shoot, cached
    public let name: String
    public private(set) var info: ShootInfo
    public private(set) var rows: [String: Row]               // by stem
    public private(set) var bursts: [Burst]
    public private(set) var steps: [StepState]
    public var cursor: Cursor                                 // burst index, frame index, generation
    public let undo: VerdictLog
    public func keep() / drop() / clear() / reason(_:) / finishBurst() async
}

@MainActor @Observable public final class JobModel { … }      // one, app-lifetime
@MainActor @Observable public final class Navigation { … }    // selection, step, modes, inspector
```

`ShootSession` is the only writer of verdicts and the only owner of the `VerdictQueue`. Views read;
they never mutate a row directly.

**The job poll**: one `Task` owned by `JobModel`. It polls `GET /api/job` every **1.2 s** while
`running`, continues for **5 s** after a job ends so the "Done" state is seen, then stops entirely.
It backs off to 3 s when the app is not frontmost. It starts on any job-starting POST and on app
launch (in case a job survived a window close). There is **no** unconditional heartbeat — the app
does not use `--idle-exit`. The task is cancelled on scene disappearance and on engine restart.

**The list's poll** (`QueueModel`, `GET /api/queue`, 1.5 s) is paired with it: whichever of the two
reads work running wakes the other, unless the other is already alive (`keepWatching`, never a
restart — a restart asks again at once, and two polls restarting each other run flat out). The
engine starts the list's next piece of work by itself, and he starts work by hand; when only one
poll was running, the other half of the app never heard. Work the list started ran with no toolbar
item, the step's idle button, ⌘. greyed, an empty Dock menu and no lock keeping the Mac awake — all
five read the job poll — and work he started by hand left every step's button saying "Cull It"
instead of adding, because that is the list's poll's to say.

### 3.7 The extension host, in code

```swift
final class ExtSchemeHandler: NSObject, WKURLSchemeHandler {   // "pipeline-ext"
    // pipeline-ext://step/<id>?shoot=… → proxies to ExtConfig.pages[id] expanded with shoot,
    // or to the extension's own origin, adding X-Studio-Key on every subresource.
}
public struct ExtensionHost: NSViewRepresentable {
    public init(step: String, shoot: String, config: ExtConfig, key: String, bridge: ExtBridge)
}
public protocol ExtBridgeDelegate: AnyObject {                  // the JS bridge, §2.16
    func viewFrames(_ stems: [String], startAt: Int)
    func confirmDestructive(title: String, body: String, confirmLabel: String) async -> Bool
    func state(get key: String) -> String?
    func state(set key: String, _ value: String?)
}
```

**What an extension has to do** (the contract; nothing in this repository implements it, and
nothing in this repository needs one):

1. Serve a whole page per step and declare it: a module-level `PAGES: dict[str, str]` (step id → URL
   template with `{shoot}`) or a `page(step, shoot) -> str | None`. The older splice contract, which
   injected an extension's markup and script into the retired page, goes away — there is no page to
   splice into.
2. **Every HTTP server an extension runs must require `X-Studio-Key`** (the engine passes it in
   `ctx`). SEC-04 measured an extension server with no origin check of any kind, and a forged
   request was proved to overwrite a whole night's work.
3. Its pages must use the host's injected CSS variables and font and follow light/dark (EXT-02), and
   must not bind single letters that collide with the host's meanings (EXT-03).
4. Its pick grids must call `pipeline.viewFrames` instead of deciding from a 168 px thumbnail
   (EXT-05); its own loupe goes away (EXT-04).
5. Anything that goes to the public internet must go through `pipeline.confirmDestructive`, and must
   not be styled like a routine action or sit 16 px from one (EXT-06).
6. Per-shoot UI state moves from `localStorage` to `pipeline.state`.
7. Fix what the audit found in its own pages: a count that counts cache folders as photographs
   (EXT-08), a panel with no keys and no spacing (EXT-07), a header that wraps (EXT-09), missing
   keys in its help bar (EXT-10), and a 1.2 s blank frame on open (EXTENSION-M01).

### 3.8 Settings storage

`SettingsStore` wraps `UserDefaults` with typed keys. `PHOTOS_ROOT` and the extension path are also
passed to the child process, so changing the library folder restarts the engine (§2.11). The editor
is not: it is sent with each Presets request, and a shoot with none of its own starts on it — the
engine sends `editor: ""` for such a shoot (it sent "dxo", so the Settings and first-run choice was
never read). One key is not a preference: `app.lastPlace`, the shoot and step the window reopens on
(§2.1, "Where the window opens"); the smoke run neither reads nor writes it. The window frame uses AppKit's own autosave. The inspector's pin
(§2.5.1) is in the settings store; the sidebar's visibility is not remembered, because the light
table hides and shows it by window width. What is the engine's is not kept here: the days before
archived RAWs may be let go are the library's (`EngineSettings`, §2.11).

**The move from Photo Pipeline, once.** The app was Photo Pipeline, `com.nickcupo.photo-pipeline`,
until 2026-09-23, and its settings and its support folder were keyed to that name. The first launch
of First Edit (`com.nickcupo.firstedit`) moves them before the engine starts, under four rules:
never delete, never copy his data, never write to the old app's defaults, and write down how to undo
it. It does nothing when `PIPELINE_SUPPORT` is set (a scratch run, the smoke test, the tests), and
nothing while Photo Pipeline is still running, which it says in one sentence, because two engines on
one `learned/` and one `queue.json` is the failure to avoid; for the same reason, Photo Pipeline
opened while First Edit runs gets an alert that offers to quit it, and `FirstEdit --check` refuses
to start an engine while it is open. Settings are imported once from the old domain: the old value
wins over anything a smoke run put in the new one, what it replaces is kept aside, and the old
domain is never written, so it stays the rollback. The folder `Application Support/Photo Pipeline`
becomes `Application Support/First Edit` by one `renamex_np(RENAME_SWAP)`, which exchanges it with a
link made a moment before under the new name, so the 1.7 GB of models moves without a copy and the
old path names the folder at every instant, before the swap and after it: a writer going through the
old path never finds it missing, and never makes a second, empty folder there. `MIGRATED.json` in
the new folder records what moved, the steps to undo it and what an undo does not put back; a launch
that stopped after the swap and before the record writes it at the next one. If both folders are
real, nothing is merged: the new one is used, Settings ▸ Advanced says where the other is, and when
the new one lacks the models or the learned store the old one has, an alert says so once. The
engine's own fallback, for a checkout run with no environment, is one resolver that tries `First
Edit` and then `Photo Pipeline`. The iCloud archive keeps its folder name, `Photo Pipeline Archive`,
because the archive manifests store frame names and rebuild every path from that folder.

### 3.9 Engine and server changes this design needs

Three changes are assumed here because they landed alongside this design: **(a)** `X-Studio-Key` on
every route including images, **(b)** `stack` / `stack_top` in the cull's own table, **(c)**
`/api/learned` plus `run|back|stop|use-anyway`. Everything below is additional, belongs to the engine
(§5.6), and is small — no route is removed and every existing field stays.

1. **`X-Studio-Key` accepted on `/ext/…` too**, and passed to the extension in `ctx` so its own
   servers can require it.
2. **`GET /full/<shoot>/<stem>.jpg?px=<1024…4096>`** — a size tier. Clamp; default stays 2600 so
   nothing breaks. The URL fully determines the bytes, so the existing `immutable` caching is still
   correct. Reason: 2600 is short of a 27" fit view (3606 device px) — LT-05.
3. **`/crop` `px` clamp raised from 3000 to 4096**, so a 1.6× viewport tile fits on a large display.
   `_decoded()` must acquire `_FRAME_GATE` around the whole body including `decode_to_file` — the
   gate was taken after the expensive part, and eight concurrent cold decodes were measured running
   in parallel (PERF-01); and `decode_to_file` must write via temp + `os.replace` like every
   other decision-grade file, with a per-(shoot, stem) lock so a second request waits instead of
   redoing 650 ms of work (PERF-02).
4. **Two-author counts, never one.** `Shoot.info()` and the home rows gain `will_be_edited` (the
   count that decides what gets a sidecar — the `keepers`/`picks` pair, which is the *sum* and was
   labelled as his) and `agreed` (the cull's picks — rating 3 or more — with no override inside a
   burst he has looked through; it counted every frame he left alone, set-asides too, and printed
   1,242 "the cull put forward" on a shoot whose cull had put forward 150). `kept` is his by
   gather's rule, which counts a pick he left standing as his, so the Presets page prints
   `kept − agreed` as "you marked Keep" (the sidebar's "you kept" is `kept` itself, the larger
   number) and the three lines add up to `will_be_edited`; `cull_picks` stays
   the machine's. The app never adds two fields together. Also: `keepers` should mean the recorded keeper set (what every check measures
   against), not the sum — "you kept N" and the recorded keepers disagreed on every shoot measured
   (R11).
5. **`can_cut_reels: Bool`** on `/api/shoots` and `Shoot.info()`, so the Reels step is absent rather
   than broken where there is no encoder (PERF-05).
6. **`bursts` and `resume` on `GET /api/shoot`.** The server groups frames into **time bursts**
   (not `scene/burst`, which splits one burst across several screens on 56 of 89 bursts of the
   reference shoot — DUP-6) and returns the array in §3.4 plus the resolved resume target and its note. This
   moves one subtle, twice-implemented rule into one place.
7. **`steps` on `GET /api/shoot`**: id, label, done, enabled, why_disabled, source. The done-ness
   table existed twice, once in Python and once in JavaScript, with an extension's own `done`
   predicates in a third file. Copy the Card is done when there are frames, the copy's own log
   (`info.ingest`) does not say it stopped or failed, and no copy into the shoot is running or waiting
   (`copying`) — a card pulled at 412 of 1,558 read as copied, with Cull its only way on. A shoot copied before the log existed has only its frames to go on.
   The labels are the §2.4 names letter for letter — Copy the Card, Choose Keepers, Finish — and a
   test reads them out of the app's `Strings.Steps` (they were "Copy the card", "Choose keepers" and
   "Done", so a shoot's rows re-lettered as it loaded and the last step had two names); the Edit
   step is named for the shoot's editor once it has one ("Edit in Lightroom Classic").
   The same list rides on every `/api/shoots` row, so All Shoots' Up to and a click on a shoot not yet
   opened (§2.1) read the one table rather than a copy of it in the app; an extension's own `done` is
   asked once a shoot at each read of the list.
8. **Presets result**: `left_alone: [stem]` in `presets.json` / `/api/shoot`'s `presets`, so
   "Nothing you had already changed in PhotoLab was touched" is a fact and not a promise. With it,
   `Shoot.info()` gives `presets_ran: {wrote, changed, already, under}`, so the page reports the run
   and not the sidecars lying on the disk. It is read off the presets job's own log, which already
   says it for him — each look's line ends "; 12 sidecars", "30 of 42 frames already carry a
   sidecar" is what a plain write skipped, "5 sidecars carry your own edits" is what a rewrite wrote
   under his changes — and off `left_alone`; presets.py's output is not changed for it. Null when
   the log cannot be the run that wrote presets.json: no log, no final `@@ presets n n`, a look it
   does not name, a presets.json newer than the log (a cull wrote them since), or an editor other
   than DxO, whose run does not say what it skipped.
9. **`ExtConfig.pages`** (step id → URL), as in §3.7.
10. **`GET /api/job`** gains a monotonic `id` and `queued: Bool`, so the app can queue a second job
    honestly instead of refusing it.
11. **`GET /api/learned`** shaped as `Learned` in §3.4 — per learner: title, status, what it learned
    from, a plain-words metric, the check (keepers / checked / hidden / moved down / moved up, and
    the affected frames), when it went live, and what the previous version was. The engine writes
    three sentences per learner and the app shows each once: `sentence` (what is in use),
    `candidate_sentence` with `candidate_state` (`held` or `couldnt_check`: what waits beside it),
    and `needs_sentence` (what it is short of) — §2.9.
12. **Validation the app cannot do for the server** (and must not be relied on to):
    `/api/rating`'s `file` against `[A-Za-z0-9._-]+` and `rating` clamped 0–5 (SEC-01, SEC-06);
    `/api/ingest`'s `card` resolved against `cards()` (SEC-05); `--port` defaulting to 0 from a
    checkout (SEC-07).
13. **`update.error` in plain language** instead of a raw decoder string (NAT-15).
14. **Reel encode contract** (needed by §5.8): `/api/reel` gains a mode that writes the JPEG
    sequence, returns `{dir, in_fps, out_fps, size, out_path}` and does **not** shell out, so the
    app can encode with AVFoundation. This also removes the GPL dependency from the public build.
15. **The Instagram step** (§2.17): `instagram` is a base step between `edit` and `reels`, done
    when a copy exists, disabled until something is exported, and put after `edit` in an
    extension's own step list that does not name it; `Shoot.info()` counts the copies without
    creating the folder; `/api/open` knows `instagram`. The routes in §2.17's table, with
    `instagram.describe` beside `figure` so a tile's cut and the copy `make` writes are one
    function apart; `/exported/` for the export itself, upright; a background kind,
    `instagram-plan`, that `make_room_for` stands down without asking for learning, printing
    `@@ planning`, and `instagram` jobs weighed on their own stage so the bar moves. `/api/job`
    says `stood_down` for a background job the engine stopped to make room, so the step can tell
    that from his Stop.

**Not needed from the server**, deliberately: the storage panel's sentences and glyphs (already
server-side, and they encode invariants the app must not re-derive); the ingest note (already
server-side); the cull's per-frame words (the app composes them from structured fields so VoiceOver
and localisation work).

### 3.10 What `app/build.sh` must change

1. **Build the package, not a file.** Replace
   `swiftc -O -o "$C/MacOS/First Edit" app/main.swift -framework Cocoa -framework WebKit`
   with `swift build --package-path app -c release --arch arm64` and copy
   `app/.build/release/FirstEdit` to `$C/MacOS/First Edit`. Fail the build if the binary is
   missing, as it already does.
2. **Resources**: copy `app/Resources/Localizable.xcstrings` (compiled) and the asset catalog output
   into `$R`. The icon moves from `app/make_icon.py` to an asset catalog compiled by
   `actool` with `--minimum-deployment-target 15.0`; keep `make_icon.py` as the source generator so
   the build stays scriptable without Xcode's UI.
3. **`Info.plist`**: `LSMinimumSystemVersion` 14.0 → **15.0**; add `NSSupportsAutomaticTermination`
   false, `NSSupportsSuddenTermination` false, `NSRemovableVolumesUsageDescription`
   ("First Edit reads photographs from your memory card."), `UNUserNotificationCenter` needs no
   key but the usage string for removable volumes is required for the card prompt;
   `CFBundleDocumentTypes` none. Keep `NSAppTransportSecurity / NSAllowsLocalNetworking`.
4. **Entitlements**: unchanged (`cs.allow-unsigned-executable-memory`,
   `cs.disable-library-validation` — the bundled CPython and torch need them). The app is not
   sandboxed; note in `RELEASING.md` that sandboxing is incompatible with spawning the bundled
   interpreter.
5. **The Python child's environment** is set by the app, not the build — but `build.sh` must keep
   shipping `pipeline/`, `python/`, `models/` and `exiftool/` exactly as it does, and must keep
   `PYTHONDONTWRITEBYTECODE` working by never writing into the bundle.
6. **Invert the public-build default (REL-01, blocking).** `PUBLIC_BUILD` left unset copied private
   source through a symlink into the bundle, and the script's own usage block never mentioned the
   flag — so the documented release command shipped private source in a public DMG. Unset has to
   mean *public and safe*; `PRIVATE_BUILD=1` is what opts into a build carrying it. Add a
   symlink-resolution abort: if any file about to be copied resolves outside the repo, stop.
7. **`ALLOW_COPYLEFT`** must test `= "1"`, not `-n` (REL-06); `STAGE=dmg` must refuse unless
   `build/.copyleft-clean` exists and is newer than the app bundle (REL-07).
8. **`NOTICES.md`** stops being tracked; it is written into `dist/` and the bundle and uploaded as a
   release asset (REL-04).
9. **New**: `swift test --package-path app` runs before assembly; `tools/vocabulary-scan.sh` runs
   over the compiled string catalog, the menu definitions and the test names and fails the build on
   a hit; `tools/smoke.sh` runs the assembled app with `--check` before signing.
10. **CI** (`.github/workflows/check.yml`): add a `swift build && swift test` job on macOS, and the
    Python `pytest` job that was missing (REL-03: 100 tests pass in 2.63 s and need only two pip
    installs).

---

## 4. Testing and QA

### 4.1 Fixtures captured from the real server

`app/tools/capture-fixtures.sh` starts the engine against a **scratch clone** of a library
(`PHOTOS_ROOT` pointed at it, `--port 0`, the key from the environment), walks every route in §3.4
including one shoot of each interesting shape (culled, not culled, broken decisions file, archived
RAWs, an extension kind if one is installed), and writes
`app/Tests/PipelineKitTests/Fixtures/<route>.json`. It never touches a real library. Fixtures are
committed; re-capturing is a one-command job when the engine changes.

### 4.2 Unit tests (`swift test`)

- **Decoding**: one test per route asserting the fixture decodes into the model with no missing
  field, plus a test that an `{"error": …}` body decodes into `StudioError.refused` with the
  sentence preserved byte for byte, plus a test that an unknown extension-supplied key survives in
  `extra` and does not break decoding.
- **`KeyMap`**: every verdict action has `allowsRepeat == false`; no bare-letter action resolves in
  `.textEditing` mode; every key in the §2.5.3 table maps to exactly one action per mode; every
  action in the table has a menu item (cross-checked against the `Commands` table, so the menu and
  the keys can never drift).
- **Control parity** (`KeyParityTests`): the one scheme of §2.5.3 written out key by key, and every
  place that shows photographs and takes keys walked press by press against it — each key means the
  scheme's meaning or nothing, a place's own keys are ones the scheme leaves free, a meaning taken
  by one key is taken by all of its keys, and every registered step and library page is a place or
  declared to have no photograph a key acts on.
- **`VerdictQueue`**: same-value repeat is dropped; different-value is serialised in press order;
  10 interleaved writes across 3 frames land in the right final state; a refused write rolls the
  model back and removes exactly one log entry.
- **`VerdictLog` / undo**: N presses produce N steps, never coalesced; two immediate ⌘Z presses undo
  two different decisions; undo names the frame.
- **Display gate**: a verdict submitted while `displayed.generation != cursor.generation` is refused
  with the right one of the three messages, and nothing is written.
- **`ImagePump`**: the tier ladder picks the right `px` for a given point size and backing scale;
  the cold-`/full` in-flight cap is never exceeded; cancelling a burst cancels its prefetches; the
  budget shrinks under simulated memory pressure.
- **Burst/step models**: `Burst` and `StepState` round-trip; the app never computes done-ness.
- **Strings**: `tools/vocabulary-scan.sh` as a test — the retired-word list over the string catalog
  and the strings files, and the extension's list over every tracked file. `StringCatalogTests`:
  every value in `Localizable.xcstrings` is the default its key has in the code (§5, rules).

### 4.3 Snapshot harness

`SnapshotHarness` is an executable target: `swift run SnapshotHarness --out snapshots/` renders
every registered scene with fixture data and writes a PNG per scene per appearance (light, dark) and
per size (1100 × 780, 1512 × 945, 900 × 620), so the whole app can be looked at without a library.

- SwiftUI-only screens render with `ImageRenderer` (`scale = 2`).
- The viewer, filmstrip and scrubber are AppKit views and `ImageRenderer` cannot render them;
  they render with `NSView.bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:to:)` behind the
  same `Scene` protocol, so the harness's caller does not care which.
- Each area of the app registers its scenes under `Sources/SnapshotHarness/Scenes/<Area>/`. A scene
  is `struct Scene { let name: String; let size: CGSize; func make(_ fixtures: Fixtures) -> Snapshotted }`.
- The scenes each area owes are listed with it in §5, and they are read against this document.
- The Instagram step's are under `Scenes/Instagram/`: the wall planned (`instagram`), filling in
  (`instagram-planning`), with some left out and some included, at 4:5, a make running, a refused
  shape, a stopped pass, nothing exported, and the editor at Fit, 1:1, Result, whole and mid-drag —
  each at 1440 × 900 — and the wall, the wall filling in and the editor at 900 × 620. They are drawn
  from the `instagram-*` answers, with the pictures read from `--library` by stem.

### 4.4 Smoke test

`app/tools/smoke.sh` builds the app, points `PHOTOS_ROOT` at a scratch library, and runs the
executable with `--check`: the app starts the real engine, waits for the port, sends one
authenticated `GET /api/shoots`, prints `OK <n> shoots`, and exits 0 — with a non-zero exit and the
last log lines on any failure. A second mode, `--check --deep`, additionally opens the first shoot,
loads one `/thumb`, one `/full?px=2048` and one `/crop`, and asserts each returned image bytes.
This is what catches "the bundle is signed but the interpreter cannot start" before a DMG exists.

### 4.5 Performance budgets, and how each is measured

`app/tools/bench.swift` (run by `swift run bench --shoot <name>`) drives the real app against a
scratch library with synthesised key events and `os_signpost` intervals, then prints p50/p95 per
budget. Any regression past a budget fails the bench.

| Budget | Target | Measured by |
|---|---|---|
| Frame-to-frame swap, image already decoded | **≤ 16 ms** p95, key-down to the display-link callback that presents it | signpost `frame.swap` |
| Frame-to-frame swap, thumb only | ≤ 120 ms | signpost `frame.swap.cold` |
| First frame of a **prefetched** next burst | ≤ 250 ms to sharp | signpost `burst.open` after N |
| First frame of a **cold** burst | thumb ≤ 150 ms, sharp ≤ 900 ms (server decode is 650–720 ms) | signpost `burst.open.cold` |
| 1:1 tile after a pan to the tile edge | ≤ 200 ms, and never a blank frame | signpost `tile.fetch` + a blank-frame assertion in `StageView` |
| Arrow held at OS repeat rate for 200 frames | no dropped display frame, exactly 0 verdicts written | bench counts `/api/rating` calls |
| K held for 2 s | exactly **1** verdict written | bench counts `/api/rating` calls |
| Memory after browsing 500 frames incl. 100 at 1:1, one window | **≤ 1.2 GB** footprint | `mach_task_basic_info` sampled by the bench; `ImagePump.report()` cross-check |
| The same, with the picture window filling a 5K | **≤ 1.5 GB** footprint | the same bench, two windows (DESIGN-displays.md §4.5) |
| Launch to first shoot list | ≤ 1.2 s warm | signpost `launch` |
| Sidebar/step change | ≤ 1 frame of jank | signpost `step.change` |

Server-side budgets (PERF-01…04) belong to the engine and are measured by its own harness; the
app's budgets above assume the `_FRAME_GATE` and atomic-write fixes in §3.9-3 have landed, and are
re-measured after they do.

### 4.6 Manual QA checklist

Per screen, per appearance, at 900 × 620 / 1100 × 780 / 1512 × 945 full screen: nothing below the
fold; nothing wraps; the control cluster is in the same place; Increase Contrast, Reduce
Transparency, Reduce Motion and the largest system text size all render; VoiceOver reads every
control; Tab reaches every control; the retired words appear nowhere. Plus the four scenarios the
four complaints ask for: click Keep 50 times fast on the trackpad and never hit Drop; hold K and check
exactly one frame changed; press Space on a composition call and get 94 % of the window; open the
learning screen and understand it without a glossary.

---

## 5. The parts, and what has to be true of each

This section was written as a build plan: twelve numbered parts, handed out so they could be built
side by side. The scheduling is gone — who built what, in what order, against which branch, is not
what the app *is*. The numbers stay, because the source cites them, and under each number is what
that part of the app is, where its code lives, and the properties it has to satisfy. Those
properties are the valuable half: most of them are assertions a test can make.

**Rules that hold across all of it.**

- No part of the app writes outside the library the engine was pointed at, and the app never removes
  a photograph except through the engine's plan → token → apply path (§2.8).
- Every string a person reads is written once, as the default value at its call site in a
  `*Strings.swift` file, and that sentence is the English the app shows. `Localizable.xcstrings`
  holds a copy of some of them for the compiled bundle, where a key it has wins over the code, so
  `StringCatalogTests` fails on any value there that is not the code's sentence word for word: a
  stale copy is how a built app said "368 kept" and pointed at a greyed menu item while every run
  from a checkout said the corrected thing. A key the catalog does not have shows the code's
  sentence, which is the same English. No string contains a retired word (§2.13) or a word from
  the extension's vocabulary, and `app/tools/vocabulary-scan.sh` fails the build over any that
  does.
- Every part carries its own fixtures (§4.1) and its own snapshot scenes (§4.3).
- `Package.swift` is written once. SwiftPM includes every file under a target's directory, so a new
  feature is a new file in its own folder and the manifest never changes.

---

### 5.0 The foundation — what everything else is built on

**What it is.** The engine host, the API client and its models, the image pipeline, the design
tokens, the observable state, the window shell, and the two harnesses. Nothing user-facing beyond a
shell that opens, starts the engine, lists shoots and can show a step.

**Where it lives**
```
app/Package.swift
app/Sources/FirstEdit/**
app/Sources/PipelineKit/{Engine,API,Images,Design,State,Shell}/**
app/Sources/SnapshotHarness/{main.swift,Harness.swift}
app/Tests/PipelineKitTests/{Fixtures,Decoding,Engine,Images}/**
app/tools/{capture-fixtures.sh,bench.swift,smoke.sh,vocabulary-scan.sh}
app/Resources/Localizable.xcstrings
```

**The public interfaces everything else codes against.** These signatures are the seam; a feature
can be written against them before the implementation behind them is finished.

```swift
// Engine ───────────────────────────────────────────────────────────────────
public actor EngineHost {
    public struct Endpoint: Sendable { public let base: URL; public let key: String }
    public enum State: Sendable, Equatable { case starting, running(Endpoint), failed(String), stopped }
    public init(bundle: Bundle, support: URL, settings: SettingsStore)
    public func start() async throws -> Endpoint
    public func restart() async throws -> Endpoint
    public func stop() async
    public var state: State { get }
    public nonisolated var states: AsyncStream<State> { get }
    public nonisolated var logURL: URL { get }
}

// API ──────────────────────────────────────────────────────────────────────
public actor StudioClient {
    public init(endpoint: EngineHost.Endpoint, session: URLSession = .studio)
    public func get<R: Decodable & Sendable>(_ r: Route<R>) async throws -> R
    public func post<B: Encodable & Sendable, R: Decodable & Sendable>(_ r: Route<R>, _ b: B) async throws -> R
    public nonisolated func imageRequest(_ i: ImageRoute) -> URLRequest
}
public enum Routes {                                   // one static per route in §3.4
    public static func shoots() -> Route<ShootsResponse>
    public static func shoot(_ name: String, full: Bool = false) -> Route<ShootResponse>
    public static func shootLight(_ name: String) -> Route<ShootLightResponse>
    public static func job() -> Route<Job>
    public static func storage(_ name: String) -> Route<Storage>
    public static func storageFrames(_ name: String) -> Route<StorageFrames>
    public static func storagePlan(_ name: String, what: String, opts: PlanOptions) -> Route<Plan>
    public static func storageLibrary() -> Route<LibraryLine>
    public static func reelOptions(_ name: String, burst: String?, src: String?) -> Route<ReelOptions>
    public static func reelWatch(_ name: String, burst: String) -> Route<ReelWatch>
    public static func cards() -> Route<CardsResponse>
    public static func update(force: Bool) -> Route<UpdateInfo>
    public static func learned() -> Route<Learned>
    public static let rating: Route<RatingResult>      // POST …
    public static let review: Route<ReviewResult>
    public static let kind: Route<KindResult>
    public static let label: Route<OK>
    public static let open: Route<OpenResult>
    public static let cull: Route<OK>
    public static let presets: Route<OK>
    public static let selects: Route<SelectsResult>
    public static let ingest: Route<OKName>
    public static let reel: Route<OK>
    public static let spread: Route<OK>
    public static let setup: Route<OK>
    public static let jobStop: Route<OK>
    public static let updateDownload: Route<OK>
    public static let updateInstall: Route<OK>
    public static let storageRetain: Route<RetainResult>
    public static let storageCheck: Route<OK>
    public static let storageApply: Route<ApplyResult>
    public static let learnedRun: Route<OK>
    public static let learnedBack: Route<OK>
    public static let learnedStop: Route<OK>
    public static let learnedUseAnyway: Route<OK>
    public static func ext(_ name: String) -> Route<JSONValue>
}

// Images ───────────────────────────────────────────────────────────────────
public actor ImagePump { /* exactly as §3.5 */ }
public struct FrameImageView: NSViewRepresentable {     // draws a CGImage in a CALayer, no chrome
    public init(shoot: String, stem: String, fit: Fit, pump: ImagePump,
                onDisplay: @escaping (String, Int) -> Void)
}

// Design ───────────────────────────────────────────────────────────────────
public enum Tokens {
  public enum Metric { public static let toolbar, scrubber, controlBar, filmstrip: CGFloat
                       public static let verdictButton: CGSize      // 112 × 40
                       public static let verdictClearGap: CGFloat    // 160
                       public static let column: CGFloat }           // 680
  public enum Palette { public static var viewerBackground: Color { get } }
  public enum Motion { public static func step(_ a: Animation) -> Animation }   // honours Reduce Motion
  public enum Sym { public static let keep, drop, undo, compare, nextBurst, fullImage: String }
}
public struct RefusalRow: View { public init(_ message: String, owner: RefusalOwner) }
public struct PathRow: NSViewRepresentable { public init(_ url: URL) }   // real NSPathControl; a double-click reveals the part in Finder

// State ────────────────────────────────────────────────────────────────────
@MainActor @Observable public final class Library { /* §3.6 */ }
@MainActor @Observable public final class ShootSession { /* §3.6 */ }
@MainActor @Observable public final class JobModel {
    public private(set) var job: Job?
    public func start(_ run: @Sendable () async throws -> Void) async
    public func stop() async
    public var isRunning: Bool { get }
}
@MainActor @Observable public final class Navigation {
    public var selection: SidebarSelection?
    public var step: String?
    public var viewerMode: ViewerMode          // .single, .compare, .allBursts, .review(Learner)
    public var inspectorShown: Bool
}
public final class SettingsStore { /* typed UserDefaults + the child's env */ }

// Shell ────────────────────────────────────────────────────────────────────
public protocol StepView: View { init(session: ShootSession, client: StudioClient, pump: ImagePump) }
public struct StepRegistry {                 // a step view registers itself here
    public static func register(_ id: String, _ make: @escaping (ShootSession) -> AnyView)
}

// Snapshot ─────────────────────────────────────────────────────────────────
public struct SnapshotScene: Sendable {
    public let name: String; public let size: CGSize
    public init(name: String, size: CGSize, make: @escaping @MainActor (Fixtures) -> Snapshotted)
}
public enum SnapshotRegistry { public static func register(_ s: SnapshotScene) }
```

**What has to be true**
- `swift build -c release` and `swift test` green; every §4.2 decoding, engine and image test passes
  against captured fixtures.
- The app launches, starts the real engine with a per-launch key, and lists shoots from a scratch
  library. `tools/smoke.sh` passes.
- **The viewer is first responder before the first frame paints**, asserted by a test that the
  window's first responder is the stage after `applicationDidFinishLaunching` and again after
  `windowDidBecomeKey`. NAT-01 has to be impossible by construction.
- `swift run SnapshotHarness` renders the shell, the sidebar, the library table and the engine-down
  view in light and dark at all three sizes.
- `tools/bench.swift` compiles and reports the launch budget.
- `tools/vocabulary-scan.sh` runs clean.

---

### 5.1 The light table

**What it is.** §2.5 in full: viewer, control bar, filmstrip, scrubber, All Bursts, Compare, Full
Image, zoom and aim, gestures, key handling, verdict queue and undo. This is the app.

**Where it lives**
```
app/Sources/PipelineKit/LightTable/**
    StageView.swift  ViewerModel.swift  ControlBar.swift  VerdictButtons.swift
    Filmstrip.swift  FilmstripItem.swift  BurstScrubber.swift  AllBurstsGrid.swift
    CompareView.swift  FullImageOverlay.swift  ZoomModel.swift  AimResolver.swift
    KeyMap.swift  VerdictQueue.swift  VerdictLog.swift  TilePanner.swift  Gestures.swift
    ReasonStrip.swift  FrameInspector.swift  ChooseKeepersStep.swift
app/Tests/PipelineKitTests/LightTable/**
app/Sources/SnapshotHarness/Scenes/LightTable/**
```

**What has to be true**
- Geometry matches §2.5.1 exactly at all six measured sizes, asserted by a layout test over the band
  heights and the cluster's measured width and gaps (Drop→Keep clear space **= 160 pt**).
- Keys: every row of §2.5.3 works; K/D/N/P/0/1–6/C/G/S/Space/Z ignore repeats; arrows repeat and
  coalesce. `KeyMap`'s tests green.
- A verdict cannot be written for a frame that is not displayed; all three refusals render on the
  control bar and only their owner clears them.
- ⌘Z/U named undo, 200 deep, survives a step change, navigates to the frame; two fast ⌘Z presses
  undo two decisions.
- Compare: synced zoom and pan across 2–8 tiles; ⇧K is one undo step; Compare never opens by itself.
- Full Image reaches ≥ 93 % of the window at 1100 × 780 and 1512 × 945.
- 1:1 aims from `face_x`/`face_y`, states its fallback, and holds the aim across a burst.
- Pinch, smart zoom, force click, two-finger swipe and momentum pan all work; detents give haptics.
- Bench: frame-to-frame ≤ 16 ms p95 from cache; a held K writes exactly one verdict; 200 arrow
  repeats write zero.
- Snapshots: Single (light/dark), Compare 2-up and 4-up, All Bursts, Full Image with HUD, the
  end-of-burst line, each of the three refusals, a stack in the filmstrip, Increase Contrast.

Where §3.9-2/3/6 (the large-display asset, the `/crop` clamp, server-side bursts) have not landed,
the light table uses client-side grouping behind one `BurstSource` protocol with two
implementations, so the switch is one line. §3.9-2 and §3.9-3 have landed — the engine serves
`/full` up to 4096 and cuts `/crop` up to 6144 — and the light table asks for them: the picture at
the tier it is drawn at, and a 1:1 tile of up to 4096. It went on capping them at 2600 and 3000 after
the engine stopped, which stretched Full Image on a laptop (2834 px) and the fit view on a 27"
(3606 px) from 2600. The cost is in the shoot's `cull/full/` cache: a size other than 2600 is kept
in a tagged folder of its own (`cull/full/3200/`, `cull/full/4096/`), about 1.2 MB a frame against
0.8 at 2600, for every frame opened in Full Image on a laptop or fitted on a large screen. **Owed:**
the storage survey (`library._cache_shape`) names a cache file's writer by its parent folder, and
`3200` is not a folder name it knows, so it files these copies — and the `1600` and `2048` ones a
small window has always asked for — as "nothing here wrote it": held as decisions, never offered
for reclaim. Until the survey knows `cull/full/<px>/`, and its pixels-of-record ladder ranks those
sizes, they are disk nothing takes back.

---

### 5.2 The workflow steps

**What it is.** §2.4 and §2.6 for Copy the Card, Cull, Presets, Edit in PhotoLab and Finish (minus
the storage panel, which is §5.3), plus §2.7's job presentation in its "in place" form.

**Where it lives**
```
app/Sources/PipelineKit/Steps/**
    ImportStep.swift  CullStep.swift  PresetsStep.swift  EditStep.swift  FinishStep.swift
    StepScaffold.swift  JobInPlace.swift  ExportWatcher.swift  CardWatcher.swift
app/Tests/PipelineKitTests/Steps/**
app/Sources/SnapshotHarness/Scenes/Steps/**
```

**What has to be true**
- Each step is a 680 pt `Form(.grouped)`; the primary exists once, at the bottom right of the form,
  and the toolbar holds only a second action (§2.3); no error can render below the fold at any of the
  three sizes (FLOW-02).
- Progress replaces the primary **inside the primary's own box**; a snapshot pair proves nothing
  else moved (FLOW-04).
- The ingest summary is built only from the copy's own log, and reproduces all six of its sentences
  including the three that report an unproved copy in red.
- The Presets step shows the two-author split — and the "leave those out" checkbox where the engine
  can be told to — and never prints a combined number as his.
- The export count is live from `FSEventStream` and falls back to `?light=1`.
- Changing step resets scroll and moves focus (FLOW-03); per-step state is restored on return.
- Snapshots: each step before and after its action, each step mid-job, Cull's report, the Cull Again
  sheet, the Presets re-write sheet, the finished state of Finish.
- Instagram (§2.17, `Steps/Instagram*`) draws every cut on one wall, makes exactly the cuts shown,
  and answers to Choose Keepers' keys and no others, which `InstagramKeysTests` holds to `KeyMap`.
- Reels' frames answer to Choose Keepers' keys too — E in, D out, X back in, S F move, R W the
  bursts, Q undo — with I and O its own (§2.6, `ReelsKeys`), and every step that shows photographs
  is held to the one scheme by `KeyParityTests` (§2.5.3).

Until §3.9-5/7 land, `can_cut_reels` and `steps` are read from the older fields behind one
`StepSource` adapter.

---

### 5.3 Storage, learning and onboarding

**What it is.** §2.8's storage panel and its three-rung destructive ladder; §2.9's learning screen
and the host of its read-only review mode (the grid itself is the light table's `CompareView`,
consumed through `Navigation.viewerMode = .review(…)`); §2.10 first run; §2.11 Settings; and the
library-wide Storage item in the sidebar.

**Where it lives**
```
app/Sources/PipelineKit/Storage/**      StoragePanel.swift  StateGlyph.swift  PlanSheet.swift
                                        ExpireSheet.swift  FrameByFrameTable.swift  LibraryStorage.swift
app/Sources/PipelineKit/Learning/**     LearnedView.swift  LearnerRow.swift  ReviewModeHost.swift
app/Sources/PipelineKit/FirstRun/**     FirstRunSheet.swift  Tips.swift
app/Sources/PipelineKit/SettingsUI/**   SettingsView.swift  Tabs/*.swift
app/Tests/PipelineKitTests/Storage/**
app/Sources/SnapshotHarness/Scenes/StorageLearning/**
```

**What has to be true**
- The panel renders every state the engine can report, using **only** the engine's own words, glyphs
  and order; nothing is recomputed client-side. One fixture per state.
- The destructive group is below a rule with ≥ 32 pt of clear space; no destructive action has a
  keyboard shortcut; the Delete key is bound to nothing (a test asserts it over the whole command
  table).
- Plan → token → apply is exact: the app never draws a plan, a token is used once, `stale: true`
  redraws silently, letting go requires the typed count, and the keepers-protected count is frozen
  at the value the list was drawn against.
- The learning screen renders all five learner statuses with a symbol and a word; a learner in use
  with a version held beside it reads **In use**, with the held version on its own line; "held back"
  and "not enough yet" are two lines with two symbols; **Use It Anyway** exists only inside review
  mode; "Go Back to the Version Before" runs the check first.
- First run works with no library, with an existing library folder, and with the model absent;
  permissions are asked in context, never on page 1.
- Changing the library folder restarts the engine with the sheet in §2.11.
- Snapshots: the panel in four storage states, the plan sheet, the let-go sheet with the gate ticked
  and the field empty, the learning screen with a held learner, review mode, each first-run page,
  each settings tab.

---

### 5.4 Commands and access

**What it is.** §2.12's whole menu bar; the Keyboard Shortcuts window; Help and `NSApp.helpMenu`;
the Activity window; Dock progress and menu; notifications; `beginActivity`; full keyboard access;
VoiceOver labels and custom actions; and Increase Contrast / Reduce Transparency / Reduce Motion /
text-size behaviour across the app.

**Where it lives**
```
app/Sources/PipelineKit/Commands/**   CommandTable.swift  AppCommands.swift  MenuValidation.swift
                                      Shortcuts.swift  DockProgress.swift  Notifications.swift
                                      ActivityAssertion.swift
app/Sources/PipelineKit/Help/**       ShortcutsWindow.swift  HelpBook.swift
app/Sources/PipelineKit/Shell/ActivityWindow.swift
app/Tests/PipelineKitTests/Commands/**
app/Sources/SnapshotHarness/Scenes/Commands/**
```

**What has to be true**
- Every menu in §2.12 exists with the stated key equivalents; `validateMenuItem` returns false for
  bare letters while a text field is first responder (a test types "k" into a search field and
  asserts a "k" arrived and no verdict was written).
- A test asserts that the command table and `KeyMap` agree: every key action has a menu item and
  every bare-letter menu item has a key action.
- ⌘W, ⌃⌘F, ⌘+/−/0, ⌘/ and the Help search all work (NAT-02/03/04, NATIVE-M02).
- The Dock shows a real progress bar and a percentage while a job runs, and its menu carries Stop.
- A notification fires only when the app is not frontmost, authorization is requested the first time
  it is about to be needed, and clicking it opens the right shoot at the right step.
- `beginActivity` is held for exactly the life of a job (a test asserts the token is released).
- VoiceOver: every control has a label; the frame announcement matches §2.15 word for word; the
  scrubber is a slider with the stated value.
- Snapshots: the Shortcuts window, the Activity window, every menu open — rendered from the command
  table, not screenshotted.

The light table contributes its actions into `CommandTable`, which is the only coupling between the
two.

---

### 5.5 The extension host

**What it is.** §2.16 and §3.7: the scheme handler, the appearance injection, the three bridges, the
sidebar rows, and the contract an extension is written against.

**Where it lives**
```
app/Sources/PipelineKit/ExtensionHost/**
    ExtensionHost.swift  ExtSchemeHandler.swift  ExtBridge.swift  ExtAppearance.swift
    ExtStepView.swift  ExtContract.md
app/Tests/PipelineKitTests/ExtensionHost/**
app/Sources/SnapshotHarness/Scenes/ExtensionHost/**
```

**What has to be true**
- With **no** extension installed, nothing in the app changes and no code path referencing one runs
  — asserted by a test that runs the whole app model with `ext == nil`.
- A stub extension (a fixture serving two trivial pages on its own port) loads through
  `pipeline-ext://`, receives `X-Studio-Key` on the page **and on its subresources**, and is refused
  without it.
- The injected CSS variables change with the system appearance while the page is open.
- `pipeline.viewFrames` opens the app's own viewer; `pipeline.confirmDestructive` draws the app's
  own sheet and resolves the promise; `pipeline.state` persists per shoot.
- No page is ever loaded in an iframe; the context menu is the app's; `isInspectable` follows the
  setting.
- **`tools/vocabulary-scan.sh` passes over everything here**, including `ExtContract.md`.
- Snapshots: an extension step pane in light and dark with the stub extension.

---

### 5.6 The engine and the server *(Python)*

**What it is.** Every item in §3.9, plus the two server-side performance fixes the app's budgets
assume.

**Where it lives**
```
pipeline/studio.py      — /full?px=, the /crop clamp, bursts+resume+steps on /api/shoot,
                          the will_be_edited/agreed/keepers split, can_cut_reels, job id+queued,
                          ext pages, the SEC validations, update.error, presets left_alone,
                          the reel encode contract
pipeline/faces.py       — decode_to_file atomic write (PERF-02)
pipeline/common.py      — the per-(shoot, stem) decode lock
app/tools/capture-fixtures.sh   — extended as routes change
tests/test_studio_panel.py, tests/test_storage.py  — new cases
```

**What has to be true**
- Every new field appears in `tools/capture-fixtures.sh` output and the Swift decoding tests pass
  against the re-captured fixtures.
- `_FRAME_GATE` wraps the whole of `_decoded()` including `decode_to_file`; eight concurrent cold
  requests to eight distinct frames no longer run in parallel (the PERF-01 reproduction re-run, now
  serialising at 2).
- Two concurrent requests for the same undecoded frame produce one decode and one atomic write.
- Bursts are keyed by **time burst**; a test asserts that no stack and no burst is split across two
  groups on a fixture that reproduces DUP-6.
- `/api/rating` refuses a `file` with a path separator or `..`, and clamps `rating` (SEC-01/06);
  `/api/ingest` refuses a `card` that is not in `cards()` (SEC-05). One regression test each,
  written from the proofs in the audit.
- `pytest -q tests` green, and CI runs it.

The Swift side consumes this through the `BurstSource` / `StepSource` adapters, so neither side
blocks the other.

---

### 5.7 Build and release

**What it is.** §3.10 in full, plus the release hygiene the audit calls blocking.

**Where it lives**
```
app/build.sh
app/Resources/{Info.plist,entitlements.plist,AppIcon/**}
app/make_icon.py
app/dmg_settings.py
.github/workflows/check.yml
RELEASING.md
.gitignore
```

**What has to be true**
- `app/build.sh` builds the package, assembles the bundle, signs every Mach-O and the app, verifies
  the hardened runtime and the Developer ID, and builds and notarizes the DMG — end to end.
- **Unset `PUBLIC_BUILD` produces a public-safe bundle**; `PRIVATE_BUILD=1` is what opts into a
  build carrying private source; a symlink resolving outside the repo aborts the build (REL-01).
- `ALLOW_COPYLEFT` accepts only `1`; `STAGE=dmg` refuses without a fresh `build/.copyleft-clean`
  (REL-06, REL-07).
- `NOTICES.md` is untracked, written to `dist/` and into the bundle, and uploaded as a release asset
  (REL-04).
- `swift test`, `pytest`, `tools/vocabulary-scan.sh` and `tools/smoke.sh` all run inside the build
  and fail it on a hit.
- `RELEASING.md` carries the checklist: the public build command, the vocabulary scan over the
  repository's own description and homepage and over every release body (REL-02), the CHANGELOG
  entry, the fixture re-capture, and the history-rewrite procedure (REL-05).
- `Info.plist` matches §3.10-3, and the app runs on a clean macOS 15 machine.

---

### 5.8 Reels and media

**What it is.** §2.6's Reels step, and the AVFoundation encoder that lets a public build cut a reel
at all.

**Where it lives**
```
app/Sources/PipelineKit/Steps/Reels*.swift   ReelsStep  ReelsModel (the wait on PhotoLab is ReelWait
                                    in it)  ReelsBurstList  ReelsCentre  ReelsFrameGrid
                                    ReelsInspector  ReelsPreview  ReelsThumbs  ReelsStrings
app/Sources/PipelineKit/Media/**    SequenceEncoder.swift  EncoderSettings.swift
app/Tests/PipelineKitTests/Reels/**
app/Sources/SnapshotHarness/Scenes/Reels/**
```

**What has to be true**
- A single click toggles a tile's checkbox; double-click, Space and force click open the frame large
  through the light table's viewer (FLOW-01).
- The step is absent when `can_cut_reels` is false, and nothing anywhere mentions it.
- `SequenceEncoder` writes an MP4 from a JPEG sequence with `AVAssetWriter` + VideoToolbox H.264:
  explicit full-range → limited-range tagging (so blacks are not crushed, matching the older
  `scale=in_range=pc:out_range=tv,format=yuv420p`), manual presentation timestamps to retime
  `in_fps → out_fps`, and `shouldOptimizeForNetworkUse = true`. A quality comparison against `crf 18`
  output on the same sequence is part of being done, not an afterthought.
- No option name in the public app comes from an extension's domain; an extension contributes its
  own at runtime.
- Snapshots: the step with and without exports, the frame grid, the inspector, the preview.

Needs §3.9-14, the encode contract.

---

### 5.9 Integration

**What it is.** Making the parts one app: wiring `StepRegistry`, resolving the adapters back to the
real server fields, removing every fixture fallback, and running the full budget suite against a
real library clone.

**Where it lives**
```
app/Sources/PipelineKit/Shell/**
app/Sources/FirstEdit/**
app/Tests/PipelineKitTests/Integration/**
```

**What has to be true**
- Every step renders in the real app against a scratch library; every adapter is gone.
- The end-to-end walk in §5.11 passes by hand and in `tools/smoke.sh --deep`.
- Every budget in §4.5 is measured on a 1,157-frame shoot and recorded.
- Engine restart, engine death, a job running across a step change, a broken shoot and an absent
  extension are all exercised.
- Memory after the full walk is under the ceiling.

---

### 5.10 Looking at it

**What it is.** The pass that looks at the built app against this document and says where it is
wrong. It writes no product code: it files what it finds with a screenshot, the section of this
document the screen violates, and the window size.

**What has to be true**
- Every screen in §2 reviewed at 900 × 620, 1100 × 780 and 1512 × 945 full screen, in light and
  dark, with Increase Contrast, Reduce Transparency, Reduce Motion and the largest system text size.
- The §4.6 checklist completed, including the four scenarios that come from the four complaints.
- The vocabulary scan run by hand over every rendered screenshot's visible text.
- A written verdict per section: matches, or differs with the difference named.

---

### 5.11 The walk that says it is done

Card in. The sidebar grows a Memory Card row. ⌘N, the name is already the card's own day,
`2026-09-22`, with the caret at its end; he types `-lake`, or nothing, and Return. Copying, with a bar in place and the Dock filling; the Mac stays awake; a notification
says "Copying the card into 2026-09-22-lake finished" and "The card can come out." The cull has
already started by itself, set as his last shoot was culled (§2.6). He clicks the notification, it
opens the card's page, which says the cull is running, and Return takes him to Cull. Two
minutes, and the same screen reads what the cull did in his own words.

⌘3. The sidebar slides away, the photograph is half the window, the strip under it, the burst map
across the top. K K D — the frames come instantly, the badge flips green, red. He holds K a beat too
long: nothing extra is written, and the app says so once. He reaches a stack: "4 similar", C, four
frames side by side, Z, all four at 1:1 on the same eye, ⇧K on the sharp one and he is past the
stack, N. He puts the
laptop on his knee: Drop and Keep are 160 pt apart in the same place they always are, Next Burst is
one short move to the right, two fingers swipe him back a frame, a pinch brings the face up close. A
composition call: Space, the frame fills the screen, D, Space.

Last burst: *"That was the last burst. You kept 174 of 1,157. Continue to Presets (⌘])"*. Presets
says 174 of his and 39 of the cull's and lets him leave the cull's out. Edit opens the editor; the
export count climbs as he works. Finish records his keepers, and that night the cull learns from the
shoot, checks itself against every photograph he has ever kept, holds the change back because it
would have hidden ten of them — and says so, with the ten, in one screen, with one button to look at
them.

---

## 6. Decisions worth revisiting

Nothing below is blocking; each has a default in this document and can be changed later without
rework. They are here because each one is a judgement rather than a measurement, and the next person
to read this document deserves to know which is which.

1. **Space means Full Image, not Next Burst.** It is the right binding (Photos, Preview, Finder) and
   the older docs already promised it, but it is the one piece of muscle memory this design rewrites.
   Default: changed, with a one-time tip and a Settings switch back.
2. **"Just no" is gone from the drop reasons.** Six nameable faults remain. A frame he simply does
   not like is Dropped with no reason. If the seventh comes back it has to be excluded from training,
   because taste is not a fault.
3. **macOS 15 as the floor**, up from 14. Anyone on macOS 14 cannot run the app.
4. **The second-display viewer is in v1**, designed in `DESIGN-displays.md`. An earlier draft of this
   document had it as a later phase; §2.1 and that document's §0 say why it flipped.
5. **Sparkle is not adopted**; updates stay engine-managed.
6. **The engine's `style` flag ("fast action")** stops controlling stacking. It survives, plainly
   worded, only where other stages still read it, and which those are is worth confirming before the
   flag is touched again.
7. **The cull never hides a frame for looking like another one.** It always stacks, the stack is
   always open, and the top frame is called a guess. That is a deliberate change in what the cull
   claims to know, and it is the direct answer to the fourth complaint in the preface.

---

## 7. The behaviours that are easy to lose

Thirteen rules, each of which fixed a failure that was actually measured, and each of which looks
from the outside like an implementation detail rather than a design decision. That is exactly why
they are collected here: a rewrite that re-derives the interface from first principles will drop
them one at a time and silently reintroduce the bug each one ended.

Everything above says what the app *is*. This section says what it must not stop doing. Each entry
gives the behaviour, where it lives in this app, the failure it prevents, and why the obvious
simpler thing is wrong. Where a behaviour has changed since it was first written down, the entry
says so plainly rather than describing the old one as current.

Two changes run through several of them. The first: **the cull no longer hides anything.** Frames
that look alike used to be folded away and only one of them shown; they are now stacked, the stack
is always open, and nothing is hidden for resembling something else (§2.5.9, and the seventh item of
§6). The second: **the engine no longer serves an interface.** The measurements below were taken
against the retired page, which is gone; where an entry names a failure the failure is real, but the
mechanism that caused it is not a mechanism this app has.

### 7.1 A verdict is only ever recorded against a frame that has actually drawn

**The rule.** A Keep or a Drop is refused unless a picture of *that* frame, at the cursor's current
generation, has been committed to the layer and one refresh has passed. "Requested", "loaded" and
"complete" do not count, and a late picture for a frame he has already left can never satisfy the
check.

**Where it lives.** `StageView` reports `didDisplay(stem:generation:)` from its display link;
`ShootSession.didDisplay`, `displayedTiles` and `isDisplayedFrameCurrent` hold the fact;
`ShootSession.displayRefusal()` is the gate every verdict path goes through, including
`keepOnly(_:dropping:)` from Compare. §2.5.4 is the full specification.

**The failure.** The page gated the loupe on the browser's own decode promise, and that promise was
measured to never settle on an image the browser already reported as complete — every key press was
silently refused with no visible symptom at all, and the photographer had no way to tell a refusal
from a key that did nothing. The gate has to be a fact the drawing code reports, not a promise the
decoder makes.

**Why the simpler thing is wrong.** One generic "loading…" state collapses three different causes
into one unactionable sentence. `displayRefusal()` keeps them apart because the answer to each is
different: *"That frame isn't the one on screen"* means press again; *"This frame's pixels are not
on this Mac"* means the RAW is archived and nothing can be decided here at all; *"Still opening this
frame"* means wait. Gating on network completion instead of on drawing reopens the original bug,
where a K committed a verdict on a photograph that was never visible.

### 7.2 The verdict queue is per frame, ordered, and reads its guard after the write in flight

**The rule.** Writes for one frame never overlap; writes for different frames may. A write whose
value equals the one already in flight or already committed for that frame is **dropped** — a
doubled press is one press counted twice. A write with a *different* value is **queued behind** the
one in flight and applied in the order the keys were pressed.

**Where it lives.** `VerdictQueue`, an actor in `State/Verdicts.swift`. `ShootSession` is its only
caller. The light table no longer waits for a single-frame write before taking his next press
(§2.5.6), so `ViewerModel` waits instead wherever a press could race one: a second verdict or a
reason on a frame waits for the answer to the write on that frame, and ⌘Z, ⇧⌘Z and anything that
decides several frames at once wait for every write still on its way. That is what keeps the raced Undo
below from coming back.

**The failure.** Three distinct bugs, reproduced three separate ways before the queue existed: a
raced Undo left a frame KEPT on disk with no undo step left to fix it; two fast K presses landed
both on the same frame instead of advancing between them; a K-then-D at 1:1 left the interface
saying KEPT while the disk said DROPPED. A finger held a fraction too long is the common cause of
all three.

**Why the simpler thing is wrong.** "Debounce" throws away the second of a genuine K-then-D, which
is a real correction and not a stutter. "Last write wins" applies the two in whatever order the
network returns them. The semantics that are correct are specifically *same value repeats are
dropped, different values serialise* — and the guard has to be read **after** awaiting the write
already in flight, or the comparison is made against a value that is about to be replaced.

### 7.3 Resume is a three-step fallback, keyed by the whole burst identity

**The rule.** Opening Choose Keepers goes to the burst he was last in if this cull still has it;
else the first burst he has not looked through; else, when every burst has been looked through, the
first — and it says which of the three it did.

**Where it lives.** The **engine** resolves it: `Shoot.resume()` in `pipeline/studio.py` returns the
target and the sentence, and the app renders what it is handed (`LightTableSeams.resume(for:)`,
`ViewerModel.goToResume()`). §2.5.13 has the four sentences; §3.9 says why the engine owns the
grouping and the resume target rather than the app.

**The failure.** The page keyed bursts by scene *and* burst number, and burst numbers restart inside
every scene. Seeding the been-through record under half a key wrote 99 bursts under keys nothing
ever looked under, so the most-worked shoot in the library opened reading *"0 of 155 bursts
through."* The cull hands both numbers out afresh on every run, which is the other half of the same
problem: a record that outlives a re-cull has to be tied to the cull it was written against
(`Shoot.cull_stamp()`), or his voice is printed over a shoot that no longer exists.

**Why the simpler thing is wrong.** A single resume pointer with no fallback strands him on a burst
that a re-cull removed. Resolving it in the app means resolving it twice, once per reader, and the
two answers drift.

### 7.4 "Been through" is a narrower fact than "has a verdict"

**The rule.** Leaving a burst **forward** is the only thing that records it: N, the Continue at the
end of the last burst (and N there, which is Continue), a press of → off the last frame, or K, D or
a reason on the last frame — unless Settings ▸ Choosing says stay — each going through the same
call N does.
A held → never does: it stops at the end of the burst, as a held N is one press. A scroll over the
photograph is an arrow: the first step of a gesture off the last frame records, as a press of →
does, and the rest of that gesture stops at the end like a held one (§2.5.8). Going back, jumping
from the scrubber, opening All Bursts and scrolling All Bursts through all record nothing — and that
includes ← off the first frame of a burst, which lands on the last frame of the burst before and
writes nothing at all.

**Where it lives.** `ShootSession.finishBurst()` is the single writer — it POSTs `/api/review` and
only then marks the burst locally; `markSeen` is private to it. Undo of that step un-marks it and
takes him back to the frame he finished it from. The burst, its number and that frame are read before
the write goes, and a burst whose finish is already on its way is not finished again.

**→ off the last frame is awaited, exactly as N is**, so every press after it waits in the queue
until he is in the next burst. It used to run beside the queue: a second → finished the same burst
again (two writes, two undo steps, the second named after the burst he had arrived in), and a K
pressed straight after the → was taken on the frame he was leaving. **A held arrow never crosses.**
It runs through the frames of a burst one per refresh and stops at either end with one bounce;
crossing is a fresh press, for the same reason a held N counts once — recording a burst is a claim
about his work, not about a key that was still down.

**Taking it back.** `ShootSession.unmarkBurst(_:)` posts `unseen` and only then un-marks locally,
the same way round as the write that put the mark on. It is offered from the scrubber — right-click
any segment, or the same action through VoiceOver — and only on a burst he has actually looked
through, because on any other one there is nothing to take back. Undo reaches the most recent
Continue and nothing further back, which is why this exists: an N pressed by mistake an hour ago had
nothing that could correct it. It is deliberately not an undo step of its own; undo is for a run of
verdicts he is working through, and this is a correction to a fact about a burst he may have left
long ago. Pressing N again is how it goes back on.

**The failure.** This is not a bug fix, it is a standing rule with a name: the count of bursts he
has looked through can never be a machine's flattery of work he did not do. A rewrite that infers
"seen" from visibility — the frame scrolled past, the burst was on screen — reintroduces exactly the
disease the rule was built to end.

**Why the simpler thing is wrong.** Inferring it from "has a verdict" would mean a burst where he
pressed one key and walked away counts the same as one he worked through, and a burst he agreed with
entirely counts as untouched. They are two different facts and the interface reports them as two.

### 7.5 The cull's verdict and his verdict never share a field

**The rule.** `rating` (the cull's, out of `cull.csv`) and `override` (his) are two separate
numbers, always under two separate labels, never merged, never falling back to one another, and
never written into one another's field. Anything that has to combine them does so in exactly one
place, and that place is never relabelled as either author's opinion alone.

**Where it lives.** `Row.rating` and `Row.override` in `API/Models/Shoot.swift` — `override` is
settable only inside `PipelineKit` and only by `ShootSession`. `CullReport` in
`Steps/CullStep.swift` counts the cull's column and nothing else; `StepsTests.hisVerdictsDoNotCount`
changes every verdict of his and asserts that not one number in the report moves. In the engine the
sum lives in `Shoot.stars()` and is used only to decide what gets a sidecar and what gets exported.

**The failure.** A shoot with no decisions on it at all used to report 313 of his keepers. The
report after a cull used to fold his corrections into the machine's own summary, which is the
machine taking credit for his eye.

**Since changed.** The cull's tier 1 used to be reported as *"folded N as duplicates"* — frames the
cull had hidden. It now reads *"262 stacked behind a similar frame"*, on a line of its own beside the
faults and the fine frames, and `CullReport.stacked` counts frames that are every one of them still
on screen.
The separation of the two authors is unchanged; what tier 1 *means* is not.

**Why the simpler thing is wrong.** One field with a precedence rule is smaller and reads the same
most of the time. It is wrong the moment anything asks "who said this" — and the interface asks that
on every frame, in the verdict line, in the report and in what the cull is allowed to learn from.

### 7.6 A refusal renders where the action was taken

**The rule.** A refusal is one plain sentence in a dedicated row under the control that raised it,
in the alarm colour, with the technical text behind a disclosure. Never a system alert, never a
toast, never one global error banner.

**Where it lives.** `RefusalRow` in `Shell/RefusalRow.swift`, tagged with a `RefusalOwner` (§7.7).
Principle 8 states the rule; principle 2 is why the row's height is reserved whether or not there is
anything in it, so a refusal arriving never moves the verdict buttons. The engine answers in
fragments ("a job is already running", "cull the shoot first"); the row, a disabled step's page note
and its help tag show them as sentences (`String.asSentence`: first letter up, a closing full stop),
leaving a first word that is a name — a shoot, a file, a path — exactly as the engine wrote it: a
word with a digit, a dot, a dash or a slash in it, a word with a capital after its first letter
("iCloud", "macOS", which read "ICloud"), and the name of a shoot in his library as last read
(`ShootNames`), so "lounge already exists" about the shoot he typed as lounge does not read "Lounge". This
agrees with an engine that capitalises its own refusals and leaves a shoot's name alone.

**The failure.** A refusal routed through an alert interrupts a fast keyboard rhythm and is
dismissed without being read. That is also why the genuinely destructive storage actions do **not**
use a dialog: a dialog with a focused OK button is a thing a person dismisses. They use the plan and
the typed confirmation instead (§7.8, §2.8).

**Why the simpler thing is wrong.** A single global banner cannot say which of two controls refused,
and a refusal that is legible only at the top of the window is a refusal he does not connect to the
key he just pressed.

### 7.7 A refused write clears only the note it wrote

**The rule.** Every message on screen carries the identity of whatever put it there, and only that
same owner may clear it. An unrelated success elsewhere can never wipe it.

**Where it lives.** `RefusalOwner` in `API/StudioError.swift` and `RefusalBoard` in
`State/Verdicts.swift`, which is keyed by owner. `LearnedModel`, `JobModel`, `StorageModel` and
`DisplayNoteRow` each hold or write into one — the display note deliberately carries its own owner
so an unplugged screen can neither wipe a live verdict refusal nor be wiped by one.

The job's slot (`.job`) is one for every step page, because a step's press goes through the app's
one `JobModel` and the one list. So what the engine said to a press there — the refusal, the job in
the way, the homework note, a refused add to the list — is taken down when he leaves that page
(`JobModel.leftThePage`, `QueueModel.leftThePage`, from `CommandHost`), rather than following him
in red to every other step until some job next started. The list's own controls (an order, a
removal, Hold, Clear) refuse into `.list`, which only the Activity window prints.

**The failure.** The keepers screen had one status line that the next *successful* keystroke wiped,
whatever it was reporting. A refused star write — a read-only decisions folder, say — was
overwritten and lost the instant the next K happened to work, so the one thing he needed to read was
the one thing guaranteed to disappear.

**Why the simpler thing is wrong.** "Clear the message on the next action" is one line of code and
it is correct only while there is exactly one thing that can raise a message.

### 7.8 Every destructive storage action is planned, then applied, against a fingerprint the engine recomputed

**The rule.** Draw a plan, get a token that fingerprints the exact state the plan was drawn from,
apply with that token. The app never computes a plan and never re-uses a token. If the shoot has
moved since the list was drawn, the engine says `stale` and the app **redraws the list** rather than
acting on a confirmation that no longer describes what would happen. Letting go of photographs
additionally requires typing the doomed count as text.

**Where it lives.** `StorageModel` in `Storage/StorageModel.swift` drives the round trip; `Plan` in
`API/Models/Storage.swift` carries `token`, `stale`, `doomed` and `protectedKeepers`; `PlanSheet`
and `ExpireSheet` present it; `RoundTripTests` is a test per rule, each naming the bug it prevents.
§2.8 is the screen.

**The failure.** This is the single most safety-critical path in the app, against the standing rule
that nothing of his is ever lost or silently overwritten. One fixed bug inside it is worth naming on
its own: the count of keepers the plan protects used to be recomputed live, so ticking a checkbox
made the protected count silently drop to zero *before* the number meant what its label said. It is
now frozen to the value the list was actually drawn against — `Plan.protectedKeepers` reads the
plan's own counts and never recomputes.

**Why the simpler thing is wrong.** Confirming a number the app worked out itself confirms the app's
arithmetic, not the disk's. The only state worth confirming is the state the engine read, and the
only way to know it has not moved is to have the engine check the fingerprint at the moment of
applying.

### 7.9 An update is two explicit actions and a clean hand-off

**The rule.** A background check populates a plain sentence — never a banner that pushes content
down. Downloading and installing are two separate, explicit actions of his. The installer prints a
`QUIT` sentinel on its own line, the app terminates cleanly on it and hands off to the staged build,
and the engine shuts itself down immediately after answering that one request.

**Where it lives.** `UpdateCoordinator` in `Engine/UpdateCoordinator.swift`; `ServerProcess` watches
stdout for a line that is exactly `QUIT` — the whole-line match is deliberate, so the word appearing
inside some other sentence can never close the app — and `EngineHost` turns it into a clean
termination. Sparkle is not adopted (§3.3, and the fifth item of §6).

**What he sees.** First Edit ▸ Check for Updates… asks GitHub and always answers, on
`UpdateSheet`: *"You have the latest version, 0.1.2."*, *"Version 0.2.0 is ready to download. You
have 0.1.2."* [Later] [Download], or *"First Edit could not find out whether there is a newer
version."* over the engine's own reason. The sidebar's *"Update to 0.2.0 available ›"* is a button
that opens the same sheet. Download is a job like any other — the toolbar shows it, the sheet shows
its bar and can be closed — and when it ends the sheet looks again (a look at the staged folder, not
a second question to GitHub) and offers [Install and Relaunch]. Install is greyed, with a line
saying why, while work of his is running. A refused Download or Install says the engine's sentence
under the buttons and leaves the version and the button in place. The menu item used to check and
say nothing, whatever the answer, and the footer's › went nowhere.

**Why it is here.** This is the one entry of the thirteen that records a mechanism rather than a
fixed bug. Without the sentinel there is no moment at which the app knows it is safe to be replaced,
and an app replaced underneath itself while a job is running loses that job's output. If the update
flow ever moves to Sparkle or the App Store, an equivalent signal-and-hand-off has to move with it.

**Why the simpler thing is wrong.** A one-click "update now" collapses download and install into a
single action that cannot be interrupted, on a machine that may be in the middle of a cull.

### 7.10 Nothing writes a folder as a side effect of being asked to show it

**The rule.** A button that says it will show a folder must never create one. If the folder is not
there, the answer is a refusal naming the path, not an empty folder.

**Where it lives.** `/api/open` in `pipeline/studio.py` refuses rather than `mkdir`-ing, and returns
the sentence the app prints. In the app, `StepPathRow` and `EditStep.open(_:)` always ask the engine
to open a path rather than resolving one locally, because the engine is the only thing that knows
where a given shoot's exports really are.

**The failure.** "Show the export folder" used to create `export/` inside a shoot whose real exports
lived in `edit/edited/`, after which the Finish step confidently pointed at the empty folder it had
just made.

**Why the simpler thing is wrong.** `mkdir(parents=True, exist_ok=True)` before opening is the
shortest way to make the button never fail, and it makes the button lie instead.

### 7.11 A job's elapsed time freezes the instant it stops

**The rule.** Elapsed is whatever the engine last reported. It is never recomputed from `now −
started`, so a finished job's card does not go on ageing for as long as it happens to stay on
screen.

**Where it lives.** The engine freezes it; `JobModel.Record.elapsed` and `ActivityRow.elapsed` hold
what it froze, and `JobTiming` in `Steps/JobInPlace.swift` prints it. §2.7 states the rule for every
surface a job appears on.

**The failure.** A finished job's card went on visibly ageing for as long as it happened to stay on
screen, so the time beside a finished piece of work was a different number every time he looked at
it, and none of them was how long it took.

**Why the simpler thing is wrong.** A wall-clock timer is what a progress view does by default, and
for a running job it is right. The moment the job ends it becomes a number that keeps changing and
means nothing.

### 7.12 The decisions files are read whole, modified and written whole, under one lock

**The rule.** A shoot's decisions — `organize.json`, `labels.json`, `review.json` — are read whole,
modified, and written whole under one process-wide **re-entrant** lock, with an atomic rename on
every write. Nothing here is a database.

**Where it lives.** `_DECIDE_LOCK` in `pipeline/studio.py`, and `write_atomic` / `write_json_atomic`
in `pipeline/common.py`. It is re-entrant because recording a verdict also writes the shoot's record
of the frames he has chosen, and that write takes the same lock on its own.

**The failure.** Measured before the lock existed: twenty overlapping verdict writes left **five**
verdicts on disk and answered "ok" to all twenty. The window is not theoretical here either — §7.2
serialises writes per frame and deliberately lets writes for *different* frames overlap, and the
engine also answers a second client and its own background work. An atomic rename makes each write
all-or-nothing; it cannot make a read-modify-write a transaction.

**Why the simpler thing is wrong.** Moving this to a database or to per-field writes is allowed, and
may well be right. What is not allowed is losing the guarantee: two concurrent verdict writes must
never silently lose one of them, and neither may report success for a write that did not land.

### 7.13 A broken shoot costs one row, and that row is a way in

**The rule.** A shoot whose decisions file will not parse costs exactly one row on the library list,
never the whole list — and that row names the exact file, carries the engine's own sentence about
it, and offers to open the folder that holds it.

**Where it lives.** `/api/shoots` wraps every single shoot's `info()` call independently, and
`_broken_file()` in `pipeline/studio.py` reads each decision file in turn to find which one raised
and hand back its path. In the app, `ShootRow` is a discriminated case and `BrokenShootLine` in
`Shell/LibraryTable.swift` draws it. `/api/open` resolves such a row to the folder that actually
holds the broken file rather than confidently opening the wrong one.

**The failure.** One unreadable `cull.csv` used to take the entire library list with it. The first
fix left the row carrying the parser's complaint alone — *"Unterminated string starting at: line 1
column 13"* — naming no file, no folder and no way in, which is the same dead end one step further
on. A shoot missing from the list is a shoot he cannot open to repair.

**Why the simpler thing is wrong.** One try/except around the whole listing is smaller and turns a
one-shoot problem into a library that will not paint. Per-shoot isolation is what makes one corrupt
file survivable instead of catastrophic.

**The same failure, in the app.** The engine kept its promise and the window still lost everything:
`BrokenShootLine`'s sentence was `.fixedSize(vertical:)` under All Shoots' `Table`, which takes all
the height it is offered, so the split view found no height it could settle on and drew nothing —
no table, no sidebar, not the red row — with one broken shoot beside good ones or alone. The
sentence now wraps to the width it is given, three lines at most, with the whole of it in the help
tag. `BrokenShootWindowTests` lays out the real root view in a window that is never shown and holds
both the sidebar's rows and the table's height to the window. The red row in the sidebar is a way in
too: clicking it opens a page with the same line — the sentence, the file, Show the File — where it
opened a page asking the engine for the shoot and printing only its refusal.

### 7.14 What the wall draws is what is written

**The rule.** The clear line on an Instagram tile is the copy Make will write, to the pixel, and Make
writes exactly the tiles whose clear line is on the screen.

**Where it lives.** The engine's `instagram.describe` gives each frame's `cut` from `instagram.rect`,
the function `make` itself calls, and `POST /api/instagram/make` is sent the stems in `makeSet`:
what he chose, worked out from the export that is there now, and not already a copy of that cut.
The editor moves a window only through `InstagramWindow.windowOf` and back, the engine's own
arithmetic with its halves rounded up, and a tile takes a saved cut from the same arithmetic until
the engine's answer replaces it. A cut saved on a made copy makes that copy again in the same
request (`POST /api/instagram/crop`), so a copy on disk is always the cut shown or says it is not.
`InstagramWindowTests` holds the app's windows to the engine's vectors and to every cut in the
fixtures.

**The failure.** The page this replaces drew no lines until a photograph had been opened and closed,
kept a list to tick apart from the wall to look at, and made from a second decision taken when the
button was pressed: the shape could change between the look and the make, and a window placed by
hand could be overwritten by a run that had read the record before it was saved.

**Why the simpler thing is wrong.** Sending "make the shoot" and letting the engine decide again is
one line shorter and is how a photograph exported again since he looked, or one not worked out when
he pressed, comes out cut in a way he never saw.

