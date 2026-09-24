# First Edit on two screens — the design

**This document is the companion to `DESIGN.md`.** That document is the app; this one is the same
app with a second screen attached. Everything in `DESIGN.md` still holds, and where this document
changes a number or a rule in it, the change is named in §8 with the reason.

**Section references.** Both documents number their sections, so: `DESIGN.md` §x.y always means the
main design; a three-level number (§2.5.9) or §2.7–§2.16 exists only there and means it too; every
other bare § number means this document.

**Evidence ids** (`LT-xx`, `NAT-xx`, `PERF-xx`, `DUP-xx`, `FLOW-xx`) come from the same measured
audit `DESIGN.md`'s preface describes — of the retired browser interface, and of the engine. The
audit is not published; every number it produced that this design rests on is quoted here.

**What is being added.** A second window — one photograph, as big as the glass allows — that lives
on the external display while the light table, the filmstrip and the two verdict buttons stay on the
laptop in front of his hands. It takes no keyboard focus, holds no decision of his, and can vanish
mid-burst without costing him a frame.

**The setup this is designed against.** A laptop plus a large external panel driven by a
third-party conversion board — a common way to keep a good display alive, and the hardest case the
app has to be right about. So: **mixed backing scale is the normal case** (Retina laptop at 2×,
external at 2× if the board drives the panel natively and 1× if it does not — the app has to be
right either way, and has to be able to say which it has); **different colour profiles are the
normal case** (a conversion board frequently presents no usable profile, so macOS assigns a generic
one); and **undocking mid-shoot is normal**, not an edge case.

---

## 0. The decision this replaces, and why it flips

Before this document, `DESIGN.md` §2.1 carried the call *"no second-display window in v1: real
value, real focus-management risk; it is named in §5 as a later phase rather than shipped
half-built."*

The value was right and the risk was real. The risk is also **entirely removed by one line**:

```swift
final class PictureWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
```

A window that cannot become key cannot take first responder, cannot steal K/D/N, and cannot make
NAT-01 (the blocker: "K/D/N are dead until the first click") come back through a side door. Every
other focus question in the feature — ⌘-tab, clicking the picture, the Tab ring, Full Keyboard
Access, the menu's `validateMenuItem` — collapses to the same answer: **the main window is the only
key window this app ever has.** That is cheaper to build and cheaper to test than the half-measure
that call was protecting against.

And the measured need is largest exactly where the second screen is:

- LT-04: in the retired page the decision picture filled 30–46 % of the window. §2.5.1 gets that to
  51–59 % on the laptop. On his external, the same design in its own window gets it to **77.9 %**, and in **3.83×
  the real pixels** of the laptop's stage (§1.6).
- LT-05: the frame is served an asset too small for the space it is drawn into. On a 5K the gap is
  worse, not better; §4.1 fixes it per window.
- DUP-7: on the 155-burst reference shoot, 81 of 156 close calls are sharpness calls, and the
  retired page had no side-by-side at all. Compare at 2 tiles of 1260 × 840 pt on the external
  against 538 × 359 pt in the default laptop window is not the same feature.

---

## 1. What the second screen is for

### 1.1 The one sentence

**The second screen shows the photograph. Everything that takes a decision stays on the laptop.**

He is not gaining a second workspace; he is gaining size. A burst is judged by looking, and the
looking is the part the laptop is worst at.

### 1.2 What Lightroom and Photo Mechanic do, and where they are wrong for him

| App | What it does | Where it is wrong here |
|---|---|---|
| Lightroom Classic, secondary display | Loupe (Normal / **Live** / **Locked**), Grid, Compare, Survey, Slideshow. The secondary window is a real window that takes focus. | **Live** follows the pointer — his cursor is the keyboard's, and a picture that changes when he reaches for the trackpad is a picture that changed for no reason. **Focus**: clicking the secondary window makes it key and the primary's keys stop working — the exact failure NAT-01 describes, shipped on purpose. **Locked** is the one idea worth keeping; it is §1.3's Hold. |
| Lightroom, "secondary shows Grid, primary shows Loupe" | The standard two-monitor layout | Backwards for him. The grid is an **aiming** tool and aiming needs the pointer, which is on the laptop. Putting the grid on the far screen means reaching across two displays to click a thumbnail. |
| Photo Mechanic | Multiple independent Contact Sheet windows and a Preview window, all real windows, all focusable | Many windows, each with its own selection, is a good fit for a wire-service editor filing from four cards at once. For one photographer culling one shoot it is four places a verdict can come from and four answers to "which frame is current" — and `DESIGN.md` rule 5 needs exactly one. |
| Final Cut viewer on a second display | The viewer goes to the second screen and the **whole interface** rearranges on the first | Rearranging the light table when a display appears moves the two verdict buttons. `DESIGN.md` principle 2 — "nothing moves under the cursor" — is not a styling preference; FLOW-04 measured a 212 pt jump and the complaint it answers is his own. |
| Apple Photos full screen | One picture, no chrome, arrow keys | This is the model for **Presentation** (§5.6) and nothing else. It has no verdicts and no burst. |

**The call this design makes and they do not: opening the second screen changes nothing about the
main window.** Not its layout, not its geometry, not what a key does, not where a button is. That is
what makes undocking mid-burst a non-event instead of a rearrangement.

### 1.3 The modes

Three modes, one flag (Hold), and Presentation. **Default: Follow the Light Table.**

| Mode | Menu title | Key | What is on the second screen | Why it exists |
|---|---|---|---|---|
| **Follow** *(default)* | Follow the Light Table | ⌃⌘1 | Whatever the light table is doing, bigger: Single → the frame; Compare → the same tiles, same synced zoom and aim; All Bursts → **the whole burst he is in** (not the cover grid — covers are for aiming and aiming is on the laptop) | Zero new state, nothing to remember, can never be showing something stale. This is the mode he will leave it in. |
| **The Frame** | Always the Frame | ⌃⌘2 | The current frame, always, even while the laptop is in Compare or All Bursts | For the pass where he wants the big screen never to change shape: he aims on the laptop, the frame is just *there*. |
| **The Whole Burst** | The Whole Burst | ⌃⌘3 | A contact sheet of the current burst — every frame in shutter order, nothing hidden, his marks and the cull's marks drawn exactly as §2.5.9 draws them, the cursor frame ringed, auto-scrolled to keep it visible | "How did that burst go" without leaving the frame he is on, and the right thing to have up when someone is standing behind him. |
| **Hold** *(a flag, not a mode)* | Hold This One on the Other Screen | **H** | Freezes whatever frame is there now — stem, zoom and aim — and the laptop keeps moving. The HUD says which frame is held. H again releases it; so does Esc, but only when the main window has nothing of its own to leave (Full Image, Compare, All Bursts and review mode come first, as §2.5.3 already orders them). | The one Lightroom idea worth keeping ("Loupe – Locked"), restated: *is this new one better than the one I already kept?* Through a 30-frame burst that question is asked constantly, and without this it can only be answered from memory. |
| **Presentation** | Presentation ▸ What I Kept | ⌃⌘P | His keepers across the whole shoot, one at a time, no chrome, pointer hidden, S F and the arrows only — on **its own cursor**, so the light table never moves and nothing can be recorded | Showing someone the shoot (§5.6). |

**Switching.** The three modes are menu items with ⌃⌘1/2/3 (rebindable in System Settings like every
other item, per §2.12's rule). Hold is the bare letter **H** and also sits in the Frame menu.
Presentation is ⌃⌘P and ends with Esc. Nothing switches itself except Follow, which is the point of
Follow.

The mode is remembered per screen, so the external can be "The Whole Burst" while a projector he
plugs in once is "The Frame", and neither disturbs the other.

### 1.4 What is on screen — the chrome, all of it

**In Frame and Follow, by default: nothing.** The photograph, the surround (§4.4), and two hairlines
at the window's outer edges:

| Hairline | Where | Colour | Means |
|---|---|---|---|
| Position in the burst | bottom edge, 2 pt, full width | `.primary` at 25 % | filled fraction = frame index / frames in burst. Tells him where he is without a number. |
| A job's progress | top edge, 2 pt, full width | accent | only while a job is running; §2.7's fraction. Disappears 5 s after it ends, like the toolbar item. |

Two hairlines, two edges, two meanings, never the same line saying two things.

**The HUD** is a Liquid Glass capsule (macOS 26; `.ultraThinMaterial` in the identical shape on 15)
centred, 44 pt tall, `.title3` and `.callout` — **on the surround, in the middle of the band under
the photograph, when that band can hold it**, the way his verdict badge is kept off the picture;
28 pt from the bottom edge, over the picture's foot, only when the frame fills the height of the
glass and there is no band (a 3:2 frame on a 16:9 panel). It used to sit 28 pt up whatever the
frame, over the photograph's bottom edge even on a panel with a band of surround under it:

```
   04330 · 2 of 7 in burst 3        ✓ you kept this
```

It appears when: the pointer moves inside that window (and hides again 1.5 s after it stops); the
burst changes (1.2 s, because a burst change is rare and orienting); Hold is turned on or off. It
**never** appears on a frame change — a capsule that flashes on every K press is 300 flashes an hour.

**A held frame says so for as long as it is held.** A pin over "holding" over the frame's number,
in the surround's own ink, top-left against the photograph — the verdict badge's corner mirrored,
by the same rule: the left band first, then the band above, then the window's corner — and never
over it. It was only "holding 05805" in the HUD, its faintest words, which shows only while the
pointer moves on that screen, so a screen holding a frame looked like a screen that had stopped
following.

**His verdict, on the other hand, is always echoed.** A press of K or D flashes the same filled badge
§2.5.9 uses — `checkmark.circle.fill` green / `xmark.circle.fill` red, 40 pt — in the **surround**,
bottom-left, 28 pt in from the picture's edge: 150 ms spring in, hold 900 ms, fade. In the surround,
never over the photograph. His eyes are on this screen when he presses; a silent verdict here would
be the app refusing to say what it just did.

**The cull's line is off on this screen by default** (`DESIGN.md` principle 4: the machine's words
are its own and they live where his controls are). Settings ▸ Choosing ▸ "Show the cull's line on the
other screen" turns it on; it then renders in the HUD's second line in `.footnote` secondary, and
still never over the photograph.

**Nothing else.** No toolbar, no title text, no filmstrip, no scrubber, no verdict buttons, no
tally, no close box — until the pointer enters the top 52 pt of the window, at which point the real
title bar fades in over 120 ms with the traffic lights, the shoot name and the subtitle "Burst 3 of
19", and fades out 1.5 s after the pointer leaves. QuickTime Player's pattern, and HIG-correct: a
window he cannot close from the keyboard is not acceptable, and a title bar permanently over a
photograph is not either.

### 1.5 When there is nothing to show

| State | What the second screen shows |
|---|---|
| A shoot is open but he is not on Choose Keepers | The surround, and one centred line in `.title3` at 40 % — `2026-09-13-dog · Cull`. After 60 s with no change it fades to nothing, and any change brings it back. (A line sitting on a panel for three hours is not something a photo app should do to a display.) |
| No shoot open at all | Same treatment, one line: `No shoot open.` |
| A job is running and there is no frame to show | The job's own stage words, centred, `.title2` — `Culling 2026-09-13-dog · looking at faces · 38 %` — plus the top hairline. The engine's words verbatim, as everywhere else. |
| The engine is down | Two lines, centred: the engine's own sentence — *"First Edit's engine stopped. Nothing you decided is lost."* — and under it, `.callout` secondary, **"The buttons are on the other screen."** No buttons here, because this window takes no clicks that do anything. |
| Its screen went to sleep | Nothing is drawn, the display link is stopped and prefetch for this window is paused (§3.8). Nothing is announced; a sleeping display is not an event. |
| Presentation, at the end of the deck | The last frame stays, with an 8 pt rubber-band on →. No end-of-burst line, no tally, nothing written for a guest to read. |

### 1.6 Geometry, measured

External assumed at 2560 × 1440 pt (the 5K panel at 2×), menu bar 24 pt, Dock on the laptop.
Inset 16 pt on every side, so the photograph never touches the bezel — a frame with no surround at
all cannot be judged for tone (§4.4).

| Where | Window box (pt) | Photograph 3:2 (pt) | % of the screen | Real pixels at 2× |
|---|---|---|---|---|
| **Filling the screen** *(default on an external)* | 2528 × 1384 | **2076 × 1384** | **77.9 %** | 4152 × 2768 = **11.49 Mpx** |
| True full screen (§3.6) | 2528 × 1408 | 2112 × 1408 | 80.7 % | 4224 × 2816 = 11.89 Mpx |
| Portrait 2:3, filling the screen | 2528 × 1384 | 923 × 1384 | 34.6 % | 1846 × 2768 |
| Compare, 2 tiles (8 pt gutter) | 2 × (1260 × 1384) | 2 × 1260 × 840 | — | 2520 × 1680 each |
| Compare, 4 tiles | 4 × (1260 × 688) | 4 × 1032 × 688 | — | 2064 × 1376 each |
| A floating window on the external, 1800 × 1100 | 1768 × 1068 | 1602 × 1068 | — | 3204 × 2136 |
| **For comparison — laptop stage**, 14" full screen (`DESIGN.md` §2.5.1) | 1496 × 707 | 1060 × 707 | 52.4 % of the laptop | 2120 × 1414 = 3.00 Mpx |
| **For comparison — laptop Full Image**, 14" full screen | — | 1417 × 945 | 93.7 % | 2834 × 1890 = 5.36 Mpx |

**The headline number: the same frame gets 3.83× the pixels of the laptop's stage, and 2.14× the
laptop's own Full Image.**

**If the conversion board is only driving the panel at 1×** (2560 × 1440 points at scale 1), the same
window gives **2076 × 1384 real pixels = 2.87 Mpx — fewer than the laptop's stage.** That is a
property of the panel's drive, not of this app, and the app must be able to say so rather than leave
anyone wondering why the big screen looks softer. Window ▸ These Screens… (§5.7) prints it:
name, point size, scale, real pixels, colour profile.

Portrait bursts get 34.6 % and there is no trick that fixes it — a 2:3 frame on a 16:9 panel wastes
the sides, in this app and in every other. It is also exactly where Compare and The Whole Burst earn
their place, and §2.5.1 already opens the inspector on portrait bursts for the same reason.

---

## 2. The division of labour

### 2.1 What lives where

| On the laptop (the main window, unchanged) | On the second screen |
|---|---|
| Sidebar, toolbar, title and subtitle | The photograph |
| The burst scrubber (18 pt) | Two edge hairlines |
| **The viewer** — still there, still 52.4 % of the window, still the same geometry | A HUD that appears on pointer movement |
| **The control bar** — Undo, ‹, **Drop**, the frame label, **Keep**, ›, Compare, **Next Burst** — in the same place at the same size, 160 pt of clear space between Drop and Keep | His verdict badge, echoed in the surround |
| The filmstrip, with his marks and the cull's | *(that is the complete list)* |
| The cull's line, the tally, every refusal and note | |
| The inspector | |

**The main window's viewer is not blanked when the second screen appears, and this is a call.** The
argument for blanking it — "the picture is redundant, give the space to a longer filmstrip" — costs
three things that are worth more: the control cluster would move (principle 2), undocking would
delete a surface and force a re-layout mid-burst, and his eyes go to the laptop at the moment of
pressing because that is where the badge, the tally and any refusal are. Redundancy here is the
feature.

### 2.2 The keyboard: one key window, always

- `PictureWindow.canBecomeKey == false`, `canBecomeMain == false`. AppKit will not make it key under
  any circumstance: not a click, not `makeKeyAndOrderFront(_:)`, not ⌘-tab, not window restoration.
- The main window is therefore always the app's key window, and `StageView` is always its first
  responder. NAT-01's fix (`makeFirstResponder(stage)` in `windowDidBecomeKey`) is untouched and
  gains one more caller: `applicationDidBecomeActive`, which asserts that if `NSApp.keyWindow == nil`
  the main window is made key. A unit test asserts `NSApp.keyWindow !== pictureWindow` after every
  operation the director can perform.
- Every single-letter key, every arrow, K/D/N/P/0/1–6/C/G/S/Space/Z/U/H, is handled exactly where
  `DESIGN.md` §2.5.3 already handles it: `StageView.keyDown(with:)` on the main window. **The second screen adds no key
  handler of any kind.** `KeyMap` gains one action (`.hold`) and one mode (`.presentation`, §5.6),
  and nothing else.
- `⌘W` targets the key window, which is always the main window, so ⌘W never closes the picture
  window by accident. ⌥⌘P and the revealed close button are its two ways out.
- ⌘` (cycle windows) skips it: `collectionBehavior` includes `.ignoresCycle`.
- **The one thing this breaks** is the macOS reflex "click a window to type in it". Mitigation: the
  first time the HUD is revealed in a launch it carries one extra line for 3 s — *"The keys stay on
  the other screen."* Once per launch, never again.

### 2.3 What happens when he clicks the picture window

Clicks and gestures go to the window under the pointer whether or not it is key, so all of this
works with no focus change at all:

| Input on the picture window | Result |
|---|---|
| Single click | In Frame, Follow-on-Single and Hold: nothing but activating the app. In Compare: moves the focus ring to that tile, as a click does in §2.5.12. In The Whole Burst: moves the cursor to that frame, as a filmstrip click does (§2.5.9). **Never a verdict, and never a change of key window** — the same rule as the stage (§2.5.8: "Click — select / focus the viewer, never a verdict"). |
| First click while PhotoLab is front | `contentView.acceptsFirstMouse(for:) == true`, so the click both activates First Edit and does its thing; the main window becomes key, not this one. |
| Double-click | Fit ⇄ 100 % at the click point — **on both windows**, because zoom and aim are shared (see below) |
| Pinch (`magnify(with:)`) | Shared zoom, 10 %–400 %, detents at Fit and 100 %, `.alignment` haptic at each detent |
| Two-finger double-tap (`smartMagnify(with:)`) | Fit ⇄ 100 % aimed at the face |
| Force click (`pressureChange(with:)`, stage 2) | Spring-loaded 100 % peek while held, on both windows |
| Two-finger scroll while zoomed | Shared pan with momentum and rubber-band |
| Two-finger swipe left / right | Previous / next frame — the same interactive `NSEvent.trackSwipeEvent` path, routed into the main window's `ViewerModel`, with the same `SwipeGate` rule (never lands on an undecoded frame) |
| Right-click | The stage's own context menu: Keep · Drop · Clear the Mark · Reason ▸ · Compare Similar Frames · Hold This One · Show in Finder · Copy Frame Number — the Frame menu's own words, never a second set. In Compare or The Whole Burst it first moves the focus / cursor to what was right-clicked, so the verdict items act on the frame the laptop now shows, through the normal display gate. **With Hold on, the verdict items are absent** — the held frame is not the frame at the cursor, and a Keep there would be a verdict on a frame he is not at; the menu offers Release the Hold · Show in Finder · Copy Frame Number. Off entirely in Presentation. |
| Drag from the picture | Drags the frame out as a file (§5.5) |
| Pointer in the top 52 pt | The title bar fades in |

**Zoom and aim are one piece of state, shared.** `ViewerModel`'s single `ZoomModel` drives both
windows; each renders it at its own pixel size. Two independent zoom levels would mean two answers to
"am I at 1:1", and §2.5.7's whole design — hold the aim relative to the face across a burst — only
works if there is one aim. The one exception is a **held** frame, which keeps a frozen copy of the
zoom it was held at; that is the point of holding it.

### 2.4 The cursor

- On the **main window**: never hidden. `DESIGN.md` §2.15 stands — magnifier at Fit, open hand at
  1:1.
- On the **picture window**: hidden after 1.5 s of stillness while the pointer is inside its content
  view and the window is in Frame/Follow/Hold, restored on the first movement. A `NSTrackingArea`
  with `[.mouseEnteredAndExited, .mouseMoved, .activeAlways]` drives a balanced
  `NSCursor.hide()` / `NSCursor.unhide()` pair, and the exit handler unhides unconditionally so the
  count can never go negative. Settings ▸ Choosing ▸ "Hide the pointer on the other screen when it
  sits still" (on). This is a **stated exception** to §2.15, and it is narrow: a pointer parked over
  a photograph he is judging is a black arrow in the frame.
- In **Presentation**: hidden on the presentation screen after 2 s, everywhere, every mode.

### 2.5 Verdict buttons on the second screen: no

Three reasons, in order of weight:

1. **Principle 2.** The two verdict buttons are "in the same place on every screen, at every window
   size, in every mode". A second pair on a second screen is a second place, and the complaint this
   whole design answers is *"how far apart the buttons to go to the next one are or how far apart
   they are to keep/discard an image"*. Two pairs makes that question have two answers.
2. **Reach.** Clicking Keep on the external means crossing 27" of desk with the pointer and coming
   back. K is 40 ms. There is no session in which the button on the far screen is the faster path.
3. **A button there sits one pixel from a gesture.** Double-click, force click and pinch all live on
   that surface. A 112 × 40 pt Keep button in the corner of it is a mis-click waiting for the moment
   his hand is moving fast.

**The mouse path is not lost** — it is the context menu (explicitly summoned, never under the
cursor), and the control bar on the laptop, which LT-01 / LIGHTTABLE-M01 required and §2.5.2 already
delivers.

### 2.6 Rule 5 with two windows: which screen counts as "displayed"

This is the single behaviour most likely to be lost, and two windows is exactly how it gets lost.

**The main window's `StageView` remains the sole authority for `isDisplayedFrameCurrent`.** Not the
picture window, not "either", not "both".

- Why not the picture window: its screen can be asleep, occluded by PhotoLab, disconnected, or in
  The Whole Burst mode showing a contact sheet. Gating his verdicts on a window that may not be
  drawing would make a verdict impossible to record for reasons he cannot see.
- Why not "both": the picture window asks for a larger asset than the laptop (§4.1), so it lands
  later. Requiring both would slow every verdict to the slower screen and would make the display
  gate depend on which display he happens to own.
- Why not "either": that is a hole. A frame that is up on the external but not yet on the laptop
  would pass the gate while the control bar's label still reads the previous frame — a verdict taken
  against a caption that names a different photograph.

The picture window still reports `didDisplay(stem:generation:)` from its own display link, but it
goes **only** to the signpost stream for §4.7's measurement and to the HUD. It never reaches
`ViewerModel.isDisplayedFrameCurrent`. A unit test asserts that the picture window's display report
cannot satisfy the gate: submit a verdict with the picture window displaying the current frame and
the stage displaying the previous one, and assert the refusal *"That frame isn't the one on
screen."* is raised and nothing was written.

---

## 3. Window behaviour

### 3.1 AppKit `NSWindow`, not a SwiftUI `Scene` + `openWindow` — and why

**[call] The picture window is an `NSWindow` subclass owned by an `NSWindowController`, with an
`NSHostingView` for its content. It is not a SwiftUI `Window`/`WindowGroup` scene.** The app itself
stays a SwiftUI `App` with its `main`, `activity` and `Settings` scenes exactly as `DESIGN.md` §2.1 describes.

Seven things this window needs that a SwiftUI scene cannot express on macOS 15 or 26:

| Need | AppKit | SwiftUI scene |
|---|---|---|
| `canBecomeKey == false` — the whole safety argument (§0) | override two vars | no equivalent at any level |
| Open on a **named** display | `setFrameOrigin` inside `screen.visibleFrame` | `defaultPosition`/`defaultSize` are screen-agnostic; `WindowPlacement` cannot name a display |
| Frame autosave **per display** | `setFrameAutosaveName` swapped on screen change (§3.5) | one `SceneStorage` per scene id, not per screen |
| `collectionBehavior` | direct | no API |
| Title bar that fades in and out over a photograph | `standardWindowButton(_:)`, `titlebarAppearsTransparent`, tracking area | no API |
| `acceptsFirstMouse`, `occlusionState`, per-window display link | direct | not exposed |
| Restore it **ourselves**, after the screen list is known | `isRestorable = false` + our own state | scene restoration runs before we know which displays are attached and will place it on the wrong one |

The content inside the hosting view is ordinary SwiftUI plus the light table's existing AppKit
`FrameImageView` / `CompareView` — no view is written twice.

### 3.2 The window, exactly

```swift
let w = PictureWindow(
    contentRect: .zero,                       // set from the chosen screen before ordering front
    styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
    backing: .buffered, defer: false)

w.title                       = shoot.name                  // e.g. "2026-09-13-dog"
w.subtitle                    = "Burst 3 of 19"             // macOS 11+, the native two-line title
w.titlebarAppearsTransparent  = true
w.titleVisibility             = .hidden                     // shown only while the chrome is revealed
w.isMovableByWindowBackground = false                       // a background drag must pan, not move
w.collectionBehavior          = [.managed, .fullScreenPrimary, .ignoresCycle]
w.tabbingMode                 = .disallowed                 // never absorbed into the main window's tabs
w.isRestorable                = false                       // we restore it, after the screens are known
w.animationBehavior           = .none                       // no genie on a photograph
w.isExcludedFromWindowsMenu   = false                       // it appears in the Window menu by title
w.hasShadow                   = true
w.backgroundColor             = Tokens.Palette.surroundNS   // §4.4, sRGB, never deviceWhite
w.minSize                     = NSSize(width: 480, height: 360)
w.delegate                    = controller
```

No `.miniaturizable`: a minimised picture window is an invisible feature with no way back except the
Dock, and the Window menu already carries Minimize for the main window.

`level` stays `.normal`. **It never floats.** A picture window that stays above PhotoLab is a
nuisance in the one workflow that mixes them, and the case it would serve — comparing a PhotoLab edit
against the frame — is better served by putting PhotoLab on the laptop, which is where his hands are
anyway. Rejected in §5.8.

### 3.3 Which display it opens on

Opening is always his action (⌥⌘P or the menu). The screen is chosen in this order:

1. The screen it was last open on, if that `ScreenKey` (§3.4) is attached now.
2. Otherwise the largest attached **non-built-in** screen by point area, ties broken by the one the
   pointer is on.
3. Otherwise the built-in screen. With one display, ⌥⌘P still works and opens a floating window at
   `visibleFrame` inset 80 pt on every side, not filling — the menu item reads **"Show the Picture in
   Its Own Window"** in that case, because "the other screen" would be a lie. This is how he tests
   the feature without docking, and it is genuinely useful for Compare in a pinch.

It **never** opens by itself, with two exceptions, both of which he taught it:

- **At launch**, if it was open at quit and that exact screen is attached.
- **On reconnect**, if it was open on that exact screen when the screen went away (§3.7).

A display it has never been opened on — a projector, a TV at someone's house, a borrowed monitor —
never gets a window thrown onto it. That rule is why "reopen automatically" is safe.

### 3.4 Screen identity across reconnects

`NSScreen` objects and `CGDirectDisplayID`s are **not stable across a disconnect**; the id can and
does change when a display is re-attached, and the array order changes when the arrangement changes.
So identity is computed, once, per screen:

```swift
public struct ScreenKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: String
    public var isBuiltIn: Bool { raw.hasPrefix("builtin:") }
}
```

Built from, in order, taking the first that yields a distinguishing value:

1. `CGDisplayIsBuiltin(id)` → `"builtin:<vendor>-<model>"`. There is only ever one built-in screen;
   it must match itself across sleep, lid close and arrangement changes and nothing else.
2. `CGDisplayVendorNumber(id)` / `CGDisplayModelNumber(id)` / `CGDisplaySerialNumber(id)`, when the
   serial is non-zero → `"ext:<vendor>-<model>-<serial>"`.
3. **Serial 0 — the conversion-board case.** A third-party driver board usually reports the board's
   vendor and model and a serial of 0. Fall back to a composite that is still stable across a reconnect:
   `"ext:<vendor>-<model>-<mmW>x<mmH>-<ptW>x<ptH>@<scale>"`, where the millimetres come from
   `CGDisplayScreenSize(id)` and the points and scale from `NSScreen.frame` /
   `backingScaleFactor`.
4. If even that is degenerate (some boards report 0 × 0 mm), append
   `CGDisplayUnitNumber(id)` and `NSScreen.localizedName`, and accept that two identical panels on
   two identical boards will be told apart by unit number, which is stable for as long as both stay
   plugged in.

`localizedName` is used for **display to him** (the menu, the These Screens panel) and never as
identity, because it is localised, can be duplicated, and changes when macOS changes how it names a
panel.

Notes for whoever builds it:

- `CGDisplayVendorNumber`/`ModelNumber`/`SerialNumber` are old CoreGraphics API and have carried
  deprecation warnings in newer SDKs before. If they are deprecated in the macOS 27 SDK, **step 3's
  composite is already the fallback and needs no new API** — that is why identity is a ladder and
  not one call.
- A change of **resolution or scale** on the same physical panel changes the step-3 key. That is
  deliberate: a frame saved for a 2560 × 1440 arrangement is wrong for a 3840 × 2160 one, and
  AppKit's own autosave behaves the same way. The mode and the fill flag are stored under a second,
  coarser key (`vendor-model-serial` only) so those survive a resolution change even when the frame
  does not.

### 3.5 Remembering where it was, per display

Everything per-screen lives in one `Codable` dictionary in `UserDefaults` under
`displays.perScreen`:

```swift
struct ScreenMemory: Codable, Sendable {
    var mode: DisplayDirector.Mode      // follow / frame / wholeBurst
    var fills: Bool                     // filling the screen, or a floating frame
    var wasOpen: Bool                   // it was open when this screen last went away
    var lastSeen: Date
}
```

The window **frame** is not in there; AppKit owns that, because AppKit already constrains a restored
frame to a visible screen and handles the arrangement maths:

- One autosave name per screen: `"picture.\(key.raw.sanitised)"`.
- When the window moves to a different screen (`windowDidChangeScreen`), the controller calls
  `w.setFrameAutosaveName("")` on the old name first and then `w.setFrameAutosaveName(newName)` —
  **`setFrameAutosaveName` returns `false` and does nothing if the name is already in use**, and
  swapping without clearing is the classic way this silently stops saving.
- On open, `w.setFrameUsingName(name)`; if that returns false (never opened on this screen),
  the frame is computed from §3.3 and §3.6.
- `displays.perScreen` entries older than 180 days are pruned at launch, so a hotel monitor does not
  live in his defaults forever.

### 3.6 Filling the screen, and true full screen

Two sizes, one toggle, and a third thing he can ask for explicitly.

**Filling the screen** — the default on any non-built-in display. `w.setFrame(screen.visibleFrame,
display: true)`: the menu bar and (if it is there) the Dock keep their strip, and the window covers
everything else. Nothing is hidden, no Space is created, Mission Control behaves normally, and
`⌘-tab` to PhotoLab covers it like any other window. **Window ▸ Fill That Screen** is a checkmark
item; the green button does the same (`windowWillUseStandardFrame(_:defaultFrame:)` returns
`screen.visibleFrame`).

**True full screen** — `toggleFullScreen(_:)`, allowed by `.fullScreenPrimary`. Worth the extra
24 pt of height (80.7 % vs 77.9 %) and worth having, but it carries one trap that must be handled
rather than discovered:

```swift
guard NSScreen.screensHaveSeparateSpaces else {
    director.note = "Full screen would darken the other screen while “Displays have separate "
                  + "Spaces” is off in System Settings. Filling this screen instead."
    fillScreen(true); return
}
```

With that System Settings option off (it is on by default, but he may have turned it off for the
window-dragging behaviour), entering full screen on one display **blanks every other display** — the
laptop, with his control bar on it, goes dark. So the app checks, refuses in one plain sentence shown
in the picture window's own HUD for 4 s, and does the thing he actually wanted. Never an alert
(principle 8).

Entering full screen is a menu item under Window with **no keyboard shortcut**: ⌃⌘F belongs to the
main window and must keep belonging to it, because the key window is always the main window and a
shortcut that means "full screen" but acts on a different window than the focused one is exactly the
kind of two-screen confusion this design exists to avoid.

**After every full-screen transition** (`windowDidEnterFullScreen`, `windowDidExitFullScreen`) the
controller asserts `NSApp.keyWindow === mainWindow` and, if the Space switch has left the app with no
key window, calls `mainWindow.makeKey()` — `makeKey()`, not `makeKeyAndOrderFront(_:)`, so the
laptop's window becomes key without being dragged into view over anything. A picture window that
cannot be key, alone in a full-screen Space, is the one arrangement in which keys could otherwise go
nowhere.

### 3.7 A display appears or goes away, mid-burst

The rule, stated first: **the second screen owns nothing that can be lost.** The cursor, every
verdict, the undo stack, the zoom, the aim, the filmstrip scroll and the "looked through" set live in
`ShootSession` and `ViewerModel`, both owned by the main window. The picture window is a view. The
only state it holds is its own mode, its fill flag and its frame, all of which are on disk before
they can be lost, plus the held stem, which lives in the app-level `DisplayDirector` and therefore
survives the window.

**How it is detected.** `NSApplication.didChangeScreenParametersNotification` is the single source of
truth: it is delivered on the main thread, it coalesces, and it covers connect, disconnect,
resolution change, scale change, arrangement change and wake-from-sleep re-enumeration. It is
debounced by 250 ms with a trailing edge, because macOS emits three to five of them during one dock
event.

`CGDisplayRegisterReconfigurationCallback` is registered **as well**, but only for one job: the
`kCGDisplayBeginConfigurationFlag` edge, which arrives *before* the mode change. On that edge, the
director freezes the picture window's layer contents and pauses its prefetch, so the 1–3 s a mode
change takes does not produce a stretched frame, a flash of the wrong size, or a burst of image
requests at a size that is about to be wrong. The callback fires on an arbitrary thread; it does
nothing but `MainActor.assumeIsolated`-hop a flag.

**Disconnect.**

1. The window is closed and released, with its state written under its `ScreenKey` and
   `wasOpen = true`.
2. The main window's control bar's second line shows, in ordinary text (not the alarm colour, this
   is not a refusal), owned by `RefusalOwner.displays`:
   > **The other screen went away. Everything you decided is here.**

   It clears after 6 s, or on his next key press, whichever comes first. It carries its own owner
   (`DESIGN.md` §2.5.4), so it cannot wipe a live verdict refusal and a later unrelated success
   cannot wipe it.
3. `ImagePump.cancelPrefetch(for: .picture)` — the big-tier requests in flight are cancelled
   immediately so they do not queue ahead of the laptop's next frame.
4. **Nothing else happens.** No alert, no sheet, no confirmation, no re-layout, no scroll, no focus
   change, no navigation. He is mid-burst and the next K must land on the same frame it would have
   landed on a second earlier.
5. If Presentation was running, it ends and the main window says so in the same one-line place —
   *"The screen showing the pictures went away. Presentation is off."* — and verdicts become
   possible again.

**Connect.**

1. If the new screen's `ScreenKey` has `wasOpen == true`, the window reopens on it in the remembered
   mode, with the remembered frame and fill flag, showing the frame he is on now (**not** the frame
   he was on when it vanished). One line on the control bar: **"The other screen is back."**
2. Otherwise nothing happens at all. A screen it has never been used on is not a screen to throw a
   window at.
3. Either way, every window re-reads `backingScaleFactor` and the screen's colour space, and the
   image tiers are recomputed (§4.2).

**Arrangement or resolution change with the window open.** The window stays where it is if its screen
still exists; AppKit will have constrained it into the new bounds. The tier is recomputed, the new
size is requested, and **the image already on screen keeps drawing until the new one lands** — the
progressive rule from `DESIGN.md` §3.5, extended: there is never a blank picture window, in any transition.

### 3.8 Sleep, wake, occlusion

| Event | What happens |
|---|---|
| The external sleeps (energy saver) — it stays in `NSScreen.screens` | `NSWorkspace.screensDidSleepNotification`, plus `CGDisplayIsAsleep(id)` checked on every screen change. The window's display link is stopped, prefetch for `.picture` is paused, its decoded ring drops to 1. Nothing is announced. |
| Screens wake | `screensDidWakeNotification` → re-read backing properties and colour space (both can change), rebuild the display link, re-request the current frame at the right size, resume prefetch. |
| The Mac sleeps and wakes | `NSWorkspace.didWakeNotification` → the same path, plus one `didChangeScreenParameters` that usually follows; the debounce makes the two collapse into one rebuild. |
| PhotoLab goes full screen over the picture window | `NSWindow.didChangeOcclusionStateNotification`; `occlusionState` loses `.visible` → display link stopped, ring to 1, prefetch paused. Restored the moment it is visible again. **This is the cheap win that keeps two windows from costing two windows' worth of memory and power for the 80 % of a session where one of them is covered.** |
| The lid closes with the external attached (clamshell) | The built-in leaves `NSScreen.screens`; the main window is moved by macOS to the external. The picture window is then on the **same** screen as the main window. The director notices (`main.screen == picture.screen`), does not close anything, and shows one line: *"One screen now. The picture is in a window on it."* and un-fills the picture window to a floating frame so the main window is reachable. |
| The Mac is on battery and the external is attached | No behaviour change. The display link's rate follows each screen; nothing is polled. |

### 3.9 Mission Control, Spaces, Stage Manager, tabs

- `.managed` and **not** `.canJoinAllSpaces`: the window belongs to one Space on one display. With
  "Displays have separate Spaces" on (the default), switching Spaces on the laptop leaves the
  external untouched, which is the behaviour he wants when he ⌘-tabs to PhotoLab.
  `.canJoinAllSpaces` is offered nowhere — a picture window that follows him into every Space is a
  picture window in the way.
- Mission Control shows it as an ordinary window with its title. Nothing special is done.
- `tabbingMode = .disallowed`: without it, macOS's "prefer tabs when opening documents" setting can
  absorb the picture window into the main window's tab bar — which would put it on the laptop,
  silently, and delete the feature. `DESIGN.md` §2.1 already says "no tabs"; this is the line that
  makes it true for the second window.
- Stage Manager: the window is `.managed`, so Stage Manager groups it with the main window. That is
  correct — they are one task.
- macOS 15 window tiling: left alone. Tiling the picture window next to something on the external is
  a reasonable thing for him to want and nothing here gets in its way.

### 3.10 The menu bar and the shortcuts

Fitted into `DESIGN.md` §2.12 with no collisions. Checked against every existing equivalent in that
section: ⌘, ⌘N ⌘E ⌥⌘R ⌥⌘X ⌘W ⌘Z ⇧⌘Z ⌘X ⌘C ⌘V ⌘A ⌘F ⌃⌘Space, K D 0 1–6 C ⇧K → ← ↑ ↓ N P ⌥⌘C,
S G Space ⌃⌘F ⌘0 ⌘9 ⌘+ ⌘− ⌃⌘S ⌥⌘I, ⇧⌘0 ⇧⌘L ⌘1–⌘7 ⌘] ⌘[ ⌘J, ⌘R ⇧⌘E ⌘., ⌘M ⌥⌘L, ⌘/. (⇧⌘N, ⌥⌘F and
⌥⌘B are held for Add a Folder, the filmstrip and the burst map, which are not in the bar until they
can do something.)
Free before this design, and now taken by it: **⌥⌘P**, **⌃⌘P**, **⌃⌘1 / ⌃⌘2 / ⌃⌘3**, and the bare letter **H**.

**Window** — Minimize ⌘M · Zoom · Fill · Centre · — ·
**Show the Picture on the Other Screen ⌥⌘P** *(title becomes "Take the Picture Off the Other Screen"
while it is open; with one display, "Show the Picture in Its Own Window" / "Close the Picture
Window")* · **Put the Picture On ▸** *(one item per attached screen, by `NSScreen.localizedName`,
checkmark on the current one, whole submenu hidden with one display)* · **Fill That Screen**
*(checkmark)* · **Enter Full Screen on That Screen** · **Presentation ▸** *(What I Kept ⌃⌘P · This
Burst, Every Frame · The Whole Shoot, Every Frame)* · **These Screens…** ·
— · Activity ⌥⌘L · — · First Edit · Bring All to Front

**View** — Single Frame S · Compare C · All Bursts G · — · **On the Other Screen ▸** *(Follow the
Light Table ⌃⌘1 · Always the Frame ⌃⌘2 · The Whole Burst ⌃⌘3)* · — · Full Image Space · Enter Full
Screen ⌃⌘F · — · *(the rest of §2.12's View menu, unchanged)*

**Frame** — … · Compare Similar Frames C · Keep Only This One ⇧K · **Hold This One on the Other
Screen  H** · — · *(the rest, unchanged)*

Rules that carry over unchanged: `H` is a real menu key equivalent with an empty modifier mask, so it
shows in the menu, works with Full Keyboard Access and is rebindable in System Settings;
`validateMenuItem` returns false for it while a text field is first responder; every item is enabled
by what registers an action against its id in the command table (`DisplayRegistration`, DESIGN.md
§2.12) with an `isEnabled` of `director.isOpen`, so all of them are greyed with no second screen
attached, and `H` does nothing rather than doing something invisible. (This said `.focusedSceneValue`,
which nothing in the app uses.)

**One collision this design refuses to add to, flagged because it is already in `DESIGN.md` §2.12:**
Go uses **⌘9** for the second extension-supplied step while View uses **⌘9** for Zoom to Fit. That is
a real duplicate, and whichever menu is checked second wins. It is not this document's to fix, but
nothing here is allowed to land on top of it — hence ⌃⌘1/2/3 rather than the ⌘-number range.

---

## 4. Image quality and performance across two screens

### 4.1 Asking each window for its own pixels

Every window computes, for itself, every time its size, screen or scale changes:

```swift
let needed = ceil(pictureSizeInPoints.width * window.backingScaleFactor)   // device pixels
let px     = PixelTier.px(forPointWidth: pictureSizeInPoints.width, scale: window.backingScaleFactor)
```

`PixelTier.ladder = [1440, 2048, 2600, 3200, 4096]` (`DESIGN.md` §3.5's ladder, unchanged) and
`px` rounds `needed` **up** to the next rung, capped at 4096. `ImagePump.Key` already carries the
size, so two windows at different sizes are two cache entries and two windows at the same size are
one — the coalescing is free and needs no new API.

Worked, for the hardware above:

| Window | Picture (pt) | Scale | Device px needed | Asked for | Error |
|---|---|---|---|---|---|
| Picture window filling the 5K at 2× | 2076 | 2.0 | 4152 | **4096** | drawn 1.4 % large — invisible on a fitted view |
| Picture window on the same panel at 1× | 2076 | 1.0 | 2076 | 2600 | exact |
| Laptop stage, 14" full screen | 1060 | 2.0 | 2120 | 2600 | exact |
| Laptop stage, default 1100 × 780 window | 813 | 2.0 | 1626 | 2048 | exact |
| Compare tile, 4-up on the 5K | 1032 | 2.0 | 2064 | 2600 | exact |
| The Whole Burst cell, 240 pt | 240 | 2.0 | 480 | `/large` (1440) | exact |
| The Whole Burst cell, ≤ 220 pt | 220 | 2.0 | 440 | `/thumb` | exact |

**The 4096 cap is enough for a fitted view on a 5K and `/full?px=` needs no change from `DESIGN.md` §3.9-2.** The
1.4 % upscale on a fitted frame is below any threshold a person can see; the place true pixels matter
is 1:1, and 1:1 does not go through `/full` at all (§4.6).

### 4.2 Mixed backing scale — the four traps

1. **Use `window.backingScaleFactor`, not `screen.backingScaleFactor`.** A window straddling a 2×
   and a 1× screen is composited at the higher scale for its whole surface. Reading the screen gives
   the wrong answer for exactly the case — a window being dragged between his two displays — where
   the wrong answer is visible.
2. **`viewDidChangeBackingProperties()` is the hook, and it fires for both scale and colour space.**
   Every image-bearing view implements it; it recomputes the size, sets
   `layer.contentsScale = window.backingScaleFactor`, and requests the new size **without clearing
   the current contents**. `windowDidChangeScreen` and `windowDidChangeBackingProperties` are
   belt-and-braces for the window-level bookkeeping (the autosave-name swap of §3.5).
3. **Never clear on a scale change.** The old image keeps drawing at the new scale (slightly soft for
   200–600 ms) and is replaced in place with no crossfade. A blank window during a drag between
   displays reads as a crash.
4. **`layer.magnificationFilter = .trilinear`, `layer.minificationFilter = .trilinear`,
   `layer.contentsGravity = .resizeAspect`, `layer.isOpaque = true`.** The default
   `.linear` minification on a 4096 px image drawn into a 2076 pt box on a 1× screen aliases visibly
   on high-frequency detail — hair, netting, fabric — which is precisely what he is judging.

`NSView.displayLink(target:selector:)` (macOS 14+, already used by `StageView` per `DESIGN.md` §3.5) retargets
itself when the view's window moves to another screen, so the per-window frame clock is correct on
both displays with no extra work. Each window gets its own.

### 4.3 Colour: what macOS does for you, and what it does not

**What the engine sends.** The image routes serve JPEGs produced by rawpy's `postprocess()` (sRGB
primaries by default) and written by OpenCV's `imwrite`, **which embeds no ICC profile.** So the
bytes are sRGB and the file is untagged.

**What macOS does for you.** If a `CGImage` carries a colour space, Core Animation converts it to
each display's profile when it composites — per display, correctly, for free, including a window
straddling two screens. That is the whole of the automatic behaviour and it is enough.

**What macOS does not do.** It does not guess. `CGImageSourceCreateThumbnailAtIndex` on an untagged
JPEG can hand back a `CGImage` whose `colorSpace` is nil or a generic device space; assigned to a
layer, an untagged image is treated as **already in the display's space** and no conversion happens.
On a P3 panel that means sRGB numbers shown as P3 numbers: reds and greens roughly 25 % more
saturated than they should be, skin tones pushed orange, and — the part that would actually cost him
— **the same frame looking different in First Edit than in his editor, in Preview, or on the
web.** He would trust the wrong one.

**So the app tags, explicitly, once, at the boundary:**

```swift
// Images/Downsampler.swift, right after the CGImage is created
let tagged: CGImage = image.colorSpace == nil
    ? (image.copy(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? image)
    : image                                    // an engine that starts tagging is honoured, not overridden
```

The contract, written down so a future engine change cannot break it silently: **every image route
returns sRGB bytes; if it ever returns anything else it must embed the profile, and the app will
honour it.** A Python test asserts the current bytes are sRGB. A Swift test asserts the tagging
branch: an untagged fixture comes out `sRGB`, a Display P3-tagged fixture comes out `displayP3`
untouched.

**Other specifics:**

- `NSScreen.colorSpace` (`NSColorSpace?`) is used for exactly two things: telling him what each panel
  is set to, in the These Screens panel — `Display P3` / `sRGB IEC61966-2.1` / `Generic RGB Profile`
  / the name of whatever a conversion board presents — and nothing else. It decides nothing about
  the pixels.
- `NSWindow.colorSpace` is **never set**. Forcing a window's space defeats the per-display conversion
  that is the one thing being relied on here.
- **No EDR.** `wantsExtendedDynamicRangeContent` is not set, no `CAMetalLayer`, no
  `maximumExtendedDynamicRangeColorComponentValue`. A photograph being judged for print and for the
  web is SDR, and the two panels must agree with each other more than either must be bright.
- **Never draw through a bitmap context you made in a device space.** Anything that renders a frame
  to pixels — the snapshot harness, a future export — creates its context with an explicit
  `CGColorSpace(name: CGColorSpace.sRGB)`, or the conversion happens twice and the snapshot PNGs
  stop being comparable between machines.
- **What he would notice if this is got wrong**, in the order he would notice it: the surround grey
  is a different grey on the two screens (§4.4 — this is the tell, and it is visible in two seconds);
  the same frame is more saturated on the external; a frame he judged as "just warm enough" exports
  cooler than he remembers.

### 4.4 The surround, measured

`DESIGN.md` §2.2 already made the call — **Neutral Grey by default, the same in both appearances,
because a surround that changes with the OS theme changes how he reads exposure.** This design gives
it numbers and extends it to the second screen.

| Option | Window surround | Full Image / picture window filling a screen / Presentation |
|---|---|---|
| **Neutral Grey** *(default)* | sRGB `#3A3A3A` (58, 58, 58) | sRGB `#1A1A1A` (26, 26, 26) |
| Match the Mac | the system's window background | its darkest variant |
| Black | sRGB `#000000` | sRGB `#000000` |

Three rules on top:

1. **Defined in sRGB, never in a device space.** `NSColor(srgbRed:green:blue:alpha:)` or an asset
   catalog colour — **never** `NSColor(deviceWhite:)`, `NSColor(calibratedWhite:)` or a raw
   `CGColor` in `deviceRGB`. A device grey renders as a *different grey on each panel*, which is the
   single most visible two-screen bug available and the one that would make him distrust the colour
   of the photograph next to it.
2. **The same value on both screens**, always, whatever each panel's profile is. ColorSync does the
   per-display conversion; the appearance matches as closely as the two panels can. And at the same
   moment: the picture window follows a change of the setting through `LiveSettings`, as the main
   window's viewers do, instead of at the next frame he moves to.
3. **It does not follow light/dark, and it does not follow Increase Contrast.** The reason is the
   same reason in both cases and it is worth writing in the code comment: his eye adapts to the
   surround, and every exposure and tone call he makes is made relative to it. A surround that flips
   when macOS switches to Dark Mode at sunset would mean the frames he judged at 4 pm and the frames
   he judged at 7 pm were judged against two different references — on the same shoot, with no
   indication it happened. Chrome *around* the surround (the HUD, the title bar, the hairlines)
   honours Increase Contrast and Reduce Transparency normally.

If the two panels still do not match to his eye after all of this, that is a calibration fact about a
conversion board, not something the app should "fix" by shifting pixels. The These Screens panel
names both profiles so he can see which one is the odd one out.

### 4.5 Memory: how `DESIGN.md` §3.5's budget changes

`DESIGN.md` §3.5's caps are **counts** (24 decoded images, 8 crop tiles). Counts stop working the moment two
windows ask for sizes that differ by 4× in area. The budget becomes bytes where bytes are what is
scarce:

```swift
public struct Budget: Sendable {
    public var thumbBytes: Int            // unchanged: 96 MB of compressed thumb data in an NSCache
    public var decodedCount: Int          // unchanged: the main stage's ring, 24 or 512 MB
    public var secondaryDecodedCount: Int // NEW: the picture window's own ring — 3
    public var tileBytes: Int             // REPLACES tileCount: clamp(physicalMemory / 64, 96 MB, 512 MB)
    public static let automatic: Budget
}
```

Worked, for the 5K at 2×, a 24 MP frame (6000 × 4000) and a 48 GB Mac:

| Consumer | Size | Each | Count | Total |
|---|---|---|---|---|
| Thumb data (shared) | compressed | — | — | 96 MB |
| Laptop stage ring | 2120 × 1414 × 4 B | 12.0 MB | 24 | 288 MB |
| **Picture window ring** | 4096 × 2731 × 4 B | 44.7 MB | **3** (current, previous, next) | **134 MB** |
| Held frame, when Hold is on | 4096 × 2731 × 4 B | 44.7 MB | 1, pinned, exempt from eviction | 45 MB |
| 1:1 tiles (whole-width on the 5K, §4.6) | 6000 × 3285 × 4 B | 78.8 MB | LRU inside `tileBytes` (512 MB → 6) | ≤ 512 MB |
| **Ceiling with both windows open** | | | | **≈ 1.08 GB of images; ≤ 1.5 GB footprint** |

So `DESIGN.md` §4.5's budget line **"Memory after browsing 500 frames incl. 100 at 1:1 ≤ 1.2 GB"
becomes two lines**: ≤ 1.2 GB with one window (unchanged), **≤ 1.5 GB with the picture window open
and filling a 5K**. On a 16 GB Mac `tileBytes` is 256 MB (three whole-width tiles: the current frame and the next
two, which is exactly `DESIGN.md` §3.5's 1:1 prefetch), so images come to ≈ 0.82 GB — which matters, because PERF-03 measured the *engine* alone sitting at 3.2 GB after
browsing twenty full-resolution frames, and PhotoLab is usually open too.

Three rules that keep it there:

- **Picture ring = 3, not 24.** He does not arrow backwards through fifteen frames at 4096; he moves
  forward. Three covers the cursor and one in each direction, and the thumb and `/large` tiers are
  still there underneath for anything further (progressive, never blank).
- **Occluded or asleep → ring 1, display link stopped, prefetch paused** (§3.8).
- **Memory pressure** (`DispatchSource.makeMemoryPressureSource`) halves `thumbBytes`, drops the main
  ring to 4, drops the **picture ring to 1**, and drops `tileBytes` to 96 MB — in that order, so the
  window he is pressing keys against is the last thing degraded.

### 4.6 1:1 across two screens, and the one engine change this needs

At 1:1 the tile is sized from the **viewer box**, not the fitted picture. In the default laptop
window the box is 1084 pt = 2168 device px wide and §2.5.7's 1.6× tile is 3469 px, inside `DESIGN.md`
§3.9-3's raised 4096 clamp. At 14" full screen the box is 2992 device px and the tile is **4787 px — already
over 4096 on the laptop alone.**

At 1:1 on the 5K the viewport is **5056 × 2768 device px** — 84 % of the frame's whole width. Three
things follow:

1. **The tile request becomes, in effect, the whole frame.** `TileFetcher` gets a stated threshold:
   when 1.6 × the viewport would be ≥ 80 % of the frame's width, ask for the frame's full width at
   the viewport's aspect instead (6000 × 3285 here, 78.8 MB decoded), in one request, and pan
   locally on the GPU. One fetch instead of a re-cut on every pan. The rule applies only when
   `tileBytes` holds at least three such tiles (the current frame and the next two); below that —
   a Mac with less than 16 GB — tiles stay at 4096 and rule 3 applies.
2. **`/crop`'s `px` clamp must be 6144, not 4096.** This is the one server number this whole document
   changes. `DESIGN.md` §3.9-3 raises the clamp from 3000 to 4096; it should go to **6144**, which
   covers the laptop's own 4787 px full-screen tile, covers the 5056 px viewport on the external,
   covers a 24 MP sensor's own 6000 px long edge (so the whole-frame case is served by the same
   route), and leaves headroom for a larger arrangement.
   `/full?px=` keeps its 1024…4096 clamp: fitted views only, true-pixel views go through `/crop`.
   Cost on the server: none — `_decoded()` already holds a full-resolution decode and a 6144 resize
   of a 6000 px frame is a no-op.
3. **At 1:1 the app never scales the photograph.** If the affordable tile is narrower than the
   viewport (a Mac with less than 16 GB, or a future frame bigger than the clamp), the picture is drawn at **true
   size, centred, with the surround around it** — he sees less of the frame, not a softer frame. 1:1
   exists to answer one question and a 0.81 : 1 picture answers it wrong. The zoom label in the
   control bar already names what it is doing (§2.5.7) and needs no new string.

### 4.7 Prefetch with two windows, and the swap budget

**The ladder, per `DESIGN.md` §3.5, with a consumer attached to every entry:**

| When | What | Consumer | Priority |
|---|---|---|---|
| shoot opens | every `/thumb` | `.strip` | lowest |
| burst opens | `/large` for every frame; the cursor's own size ± 2 | `.stage` | normal |
| burst opens, picture window open | the picture window's size for the cursor frame ± 1 | `.picture` | **after `.stage`** |
| cursor moves | the next 3 in the direction of travel, at the stage's size | `.stage` | high |
| cursor moves, picture window open | the next 2 in the direction of travel, at the picture window's size | `.picture` | after `.stage` |
| 1:1 engaged | the tile / whole frame at the **larger** of the two windows' needs, shared | both | high |
| 3 frames from the end of a burst, or N | the first frame of the next burst, **both sizes** | both | high |
| idle ≥ 2 s | the rest of the next burst | `.stage` then `.picture` | lowest |

`ImagePump` gains a `Consumer` on prefetch and cancel:

```swift
public enum Consumer: Hashable, Sendable { case stage, picture, strip, tile }
public func prefetch(_ keys: [Key], for c: Consumer, priority: TaskPriority)
public func cancelPrefetch(for c: Consumer)
public func cancelPrefetch(keeping: Set<Key>)     // unchanged, now a union across consumers
```

Two rules:

- **The laptop is always served first.** The stage's size is smaller and lands sooner; issuing it
  first means the display gate (§2.6) is satisfied at the earliest possible moment and the picture
  window catches up a frame-time later, which is exactly the ordering a person cannot see.
- **`.picture` requests never occupy the last cold slot.** `DESIGN.md` §3.5's "at most 2 concurrent cold `/full`
  requests" becomes: **at most 2 concurrent cold requests in total, of which at most 1 may be
  `.picture`.** Otherwise a pair of 4096 px decodes on the far screen can sit in front of the one
  frame he is about to press a key on — the exact stall PERF-01 measured at 650–720 ms.

**The swap budget, and the honest version of "within one display refresh".**

The two displays have different clocks. A 120 Hz ProMotion laptop and a 60 Hz external cannot present
in the same refresh, ever, and any budget that claims they do is untestable. What is achievable and
what is required:

> **Both windows commit the new frame inside one `CATransaction` on the main actor, and each presents
> on its own next refresh. The visible skew is bounded by one period of the slower display.**

```swift
CATransaction.begin()
CATransaction.setDisableActions(true)     // no implicit animation on a key press (§2.14)
stageLayer.contents  = stageImage
pictureLayer.swap(to: pictureImage)       // see below
CATransaction.commit()
```

`pictureLayer` is a **double buffer**: two sublayers, A visible and B hidden, where B's `contents`
were assigned when the prefetch landed — so it has already been composited once and its texture is
already resident. The swap at key-down is two `opacity`/`zPosition` changes, not a 44.7 MB upload on
the critical path. Without this, an upload of the 4096 px image on the external's compositor is the
one plausible way to miss the budget; with it, the swap is property changes.

| Budget | Target | Measured by |
|---|---|---|
| `frame.swap.both` — key-down to `CATransaction` commit, both images already decoded | **≤ 8 ms p95** | `os_signpost` interval in `ViewerModel.perform` |
| Skew between the two screens — the two windows' display-link callbacks that actually present | **≤ one period of the slower display** (≤ 16.7 ms at 60 Hz) | each window's `CADisplayLink.targetTimestamp` logged at `didDisplay`, differenced by `tools/bench.swift` |
| `frame.swap.big.cold` — the picture window has only a smaller size decoded | ≤ 250 ms to sharp, **never blank** | signpost + a blank-frame assertion in the picture window's layer, same as `StageView`'s |
| Arrow held at OS repeat rate for 200 frames, both windows open | no dropped display frame on **either** screen, exactly 0 verdicts written | per-window display-link drop counters + the existing `/api/rating` count |
| Footprint after 500 frames incl. 100 at 1:1, both windows open, 5K at 2× | **≤ 1.5 GB** | `mach_task_basic_info` + `ImagePump.report()` |
| Opening / closing the picture window mid-burst | ≤ 1 dropped frame on the main window; 0 verdicts written; cursor unchanged | signpost `picture.open` / `picture.close` + a model assertion |

---

## 5. Quality of life beyond the viewer

Ranked by what it is worth to him, with the arithmetic where there is any.

### 5.1 Compare on the big screen while the strip stays on the laptop *(the biggest one after the viewer itself)*

DUP-7: on the 155-burst reference shoot, 81 of 156 close calls are sharpness calls, and §2.5.12's
synced-zoom Compare is the feature built for them. Two tiles in the default laptop window are 538 × 359 pt. Two
tiles on the external are **1260 × 840 pt** — 5.5× the area on screens of the same 2× scale — and four
tiles go from 396 × 264 to 1032 × 688, 6.8× the area. That is the difference
between "I think that one" and "that one".

Each tile's caption — the frame number and his verdict — grows with the tile: `.title2` under a tile
1000 pt wide or more, `.title3` from 700, `.callout` below that. At `.callout` under a 1260 pt tile
on a 27" panel it was the size of a menu's small print, read from where he sits, and the frame
number is the thing he is choosing between.

**When the picture window is open, `C` opens Compare on it and leaves the main window in Single.**
The focus ring, ← →, K, D and ⇧K all still come from the laptop and all still work identically; the
control bar, the filmstrip and the tally do not move. Esc returns exactly as §2.5.12 says.
Settings ▸ Choosing ▸ "Compare on the other screen when it's open" (on). With it off, or with no
picture window, `C` behaves exactly as `DESIGN.md` describes and the main window becomes Compare.

### 5.2 Long jobs and the Activity window

- **Progress does not move.** §2.7's in-place progress, toolbar `.status` item, sidebar ring and Dock
  bar are all unchanged and all on the laptop. Nothing about a second display changes where a job
  reports.
- **The Activity window (⌥⌘L) remembers its own screen**, through the same `ScreenKey` machinery:
  autosave name `"activity.\(key)"`, and it reopens on the screen it was last used on if that screen
  is attached. One edit elsewhere in the app (§7.2).
- **The picture window shows a job only when there is no photograph to show** (§1.5) — the engine's
  own stage words, large, plus the top hairline. It never covers a frame with a progress bar.
- **Rejected:** putting the Activity window or the log on the second screen by default. The second
  screen is the only large surface he has; a log on it is the worst possible use of it.

### 5.3 The extension's pages

The extension's steps are `WKWebView`s in the detail pane (§2.16) and they **stay on the laptop**.
They are tick-grids: they need the pointer and the keyboard, and the picture window has neither.

What they get instead is better: **`pipeline.viewFrames([stems], startAt:)` opens the picture window
when one is available**, rather than an overlay on the laptop. EXT-05 measured an extension's grids
asking for a decision from a 168 × 199 px thumbnail with no way to see the frame large; this hands
every one of those grids a 2076 pt picture for free, with the ticking still under his hand on the
laptop. One edit in `ExtensionHost/ExtBridge.swift` (§7.2).

The same bridge serves two other callers for free:

- **Reels** (FLOW-01): double-click, Space or force click on a frame tile opens it on the picture
  window when it is open, instead of the laptop overlay.
- **What the Cull Has Learned** (§2.9): "[See the 10]" opens the read-only review Compare on the
  picture window — his keepers six at a time at 837 × 558 pt instead of 356 × 237, which is a much
  better way to answer "would this change have cost me anything".

### 5.4 Opening PhotoLab or Finder without losing the app's place

- **The picture window stays visible when First Edit is not the active app.** It is not hidden on
  `resignActive`, it does not float, and PhotoLab simply covers it if PhotoLab is on that screen.
  When PhotoLab is on the laptop and the frame stays up on the external, that is a genuinely useful
  arrangement and it costs nothing to allow.
- While it is covered, `occlusionState` has already stopped its display link and dropped its ring
  (§3.8), so a covered window costs no power.
- Coming back: `applicationDidBecomeActive` asserts the main window is key and `StageView` is first
  responder, so **K works on the first press after every ⌘-tab** — NAT-01's fix, now with a second
  window in the app that can never take that focus away.
- Shoot ▸ Open My Keepers in PhotoLab ⇧⌘E, File ▸ Show the Shoot in Finder ⌥⌘R and Show the Export
  Folder ⌥⌘X are unchanged; none of them touches the picture window, the cursor or the step.

### 5.5 Dragging a frame out to Finder or into another app

From the filmstrip, from the All Bursts grid, from the picture window in Frame mode, and from The
Whole Burst's cells. Never from Presentation.

```swift
// Displays/FrameDrag.swift  (and used by the light table's Filmstrip through one shared type)
func pasteboardWriter(for stem: String, in session: ShootSession) -> NSPasteboardWriting
```

What is on the pasteboard, in order of preference:

1. **The exported JPEG's file URL**, if one exists in the export folder. This is what another app
   actually wants, it is a finished file, and dragging it copies it.
2. Otherwise an `NSFilePromiseProvider` for `UTType.jpeg`, which on drop writes a JPEG fetched from
   `/full?px=4096` into the destination the receiver chose, named `<stem>.jpg`.
3. Alongside either: `.string` carrying the frame number, so dropping into a text field or a message
   types `04330`.

**The RAW is never on the pasteboard.** Dragging a RAW out of the library is one Finder gesture away
from moving it out of the library, and `DESIGN.md` §2.8 is explicit that the app never removes
photographs except through the engine's plan-token-apply path.
`draggingSession(_:sourceOperationMaskFor:)` returns `.copy` for every destination outside the app
and `[]` inside it, so a drag can never be interpreted as a move and can never re-order the strip
(§2.5.9: "the strip is a place, not a canvas"). A drag never changes the cursor and never writes a
verdict.

### 5.6 Presentation

For showing someone the shoot — across the desk, or with the laptop closed and the external turned
towards them. A slideshow that **cannot change anything**, by construction rather than by care.

- **What it walks.** Window ▸ **Presentation ▸** — **What I Kept ⌃⌘P** *(default)* · This Burst,
  Every Frame · The Whole Shoot, Every Frame. "What I Kept" is his filled-green verdicts across the
  whole shoot, in shutter order, starting at the kept frame nearest the one he is on. If he has kept
  nothing yet, it starts This Burst, Every Frame instead and the laptop says so in one line.
- **It has its own cursor.** A `PresentationDeck` (`stems: [String]`, `index: Int`) owned by the
  director. **The light table's cursor, burst, filmstrip scroll and zoom never move during
  Presentation**, so there is nothing to restore when it ends and nothing that could be recorded
  while it runs. Walking across bursts in the deck is free precisely because the light table is not
  walking anywhere.
- **Keys:** Choose Keepers' for the same moves (`DESIGN.md` §2.5.3, "One scheme"): S F and ← →
  previous / next frame in the deck, across bursts; W R (or P N) and ↑ ↓ previous / next burst in the
  deck; Home / End first / last; Esc ends it; **that is all**. The deck took the arrows alone, so F went
  on to the light table's frame behind the show while → stepped the show. Esc ends the show whatever
  else is held; everything else is the deck's only while nothing is being typed into
  (`PresentationKey.from`): it watches keys app-wide, and a key it took from a field would be a key
  lost. The arrows are read by the same table as the letters, so a plain arrow steps the deck and
  ⇧, ⌘, ⌥ or ⌃ with it does not — they were taken by key code with anything held, ⌘← and ⌘→ in a
  text field included. E, D, X, 1–6, ⇧E, Q and ⌘Z — and the K, 0, ⇧K
  and U they stand beside — are refused while it runs, and the refusal is shown on the laptop's
  control bar, once:
  > **Presentation is on. Nothing can be decided while it is.**

  **R steps the deck and never the light table, because leaving a burst forward there is the only
  thing that records "looked through"** (`DESIGN.md` §2.5.13, §7.4) — and Presentation moves its own
  cursor, never the light table's. A shoot must never come back from being shown to someone with
  bursts newly marked as looked through. With its own cursor, and R, W, N and P its own, there is no
  path by which Presentation writes anything — which is the whole reason it is a mode and not just
  "hide the chrome".
- **Entering, two screens:** the picture window goes to true full screen on its display if
  `NSScreen.screensHaveSeparateSpaces` (which hides the menu bar on that display only, by the
  system's own doing), and otherwise fills the screen (§3.6).
  `NSApplication.presentationOptions` is **not** touched with two screens attached: it is
  application-wide, and `.autoHideMenuBar` would take the menu bar off the laptop too, where he still
  needs it.
- **Entering, one screen:** the picture window covers `screen.frame` **in the current Space** (not a
  full-screen Space, see below), and for the duration only,
  `NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]`, restored exactly on exit. With
  one screen there is no other menu bar to protect, so this is the one place the option is right.
- **On screen:** the photograph, the surround's darkest variant, and nothing else. No HUD, no
  hairlines, no title bar, no badge, no context menu, no drag. The pointer hides after 2 s.
- **On the laptop, during:** the ordinary light table, frozen at his place; the two verdict buttons
  disabled with a help tag saying why; one line under them — *"Presentation is on — Esc ends it."*
- **Leaving:** **Esc**. Like every key it arrives at the main window, which is still key — but a Space
  switch (true full screen on the external, or a Mission Control gesture mid-show) can leave an app
  with **no** key window at all, and then no key arrives anywhere. So for the life of Presentation
  the director also installs `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` that catches
  Esc, ← → ↑ ↓, Home and End app-wide before dispatch, and removes it on exit. **A guest can never be
  stuck in a chrome-less window with no way out.** The mode also ends by itself if its display goes
  away (§3.7) or the app quits. A hint capsule — *"Esc to come back"* — shows for 3 s on entry and
  for 2 s whenever the pointer moves after being hidden.

### 5.7 These Screens…

Window ▸ These Screens… opens a 420 × 280 utility panel, non-modal, one row per attached screen:

```
  Built-in Display          1512 × 945 pt · 2× · 3024 × 1890 real · Color LCD
  External 5K Panel         2560 × 1440 pt · 2× · 5120 × 2880 real · Generic RGB Profile   ← the picture
```

It answers, in one look, the two questions a converted panel raises: *is this thing actually running
at its real resolution* (the "real" column), and *what profile has macOS given it* (the last
column). The example row is the case worth catching: a board that presents no profile, so macOS has
fallen back to a generic one. Neither fact is discoverable in one place anywhere in System Settings.
No control on it changes anything. The panel's words say "size" and "real", never the retired word
for an image size (§7.4).

### 5.8 Considered and rejected

| Rejected | Why |
|---|---|
| A pointer-following loupe on the second screen (Lightroom "Loupe – Live") | His cursor is the keyboard's. A picture that changes because he reached for the trackpad is a picture that changed for no reason. Hold (§1.3) is the useful half of the idea. |
| Keep / Drop buttons on the second screen | §2.5 — three reasons, principle 2 first. |
| Moving the filmstrip or the scrubber to the second screen | His hands, the strip and the decision cluster must be on one surface; and undocking would then delete a control surface mid-burst. |
| Blanking or shrinking the main window's viewer when the second screen appears | Moves the control cluster (principle 2, FLOW-04's measured 212 pt) and makes undocking a re-layout. |
| A second, fully independent light table (two shoots at once) | Two places a verdict can come from, two answers to "which frame is current", and "looked through" becomes ambiguous. `DESIGN.md` §2.1's "one window, one library, one job queue" is load-bearing. |
| Mirroring the whole interface on both screens | Two control bars; the display gate (§2.6) loses its single authority. |
| `level = .floating` — keeping the picture above PhotoLab | A window that will not go behind anything is a nuisance in the one workflow that mixes them; put PhotoLab on the laptop instead. |
| `.canJoinAllSpaces` | The picture window would follow him into PhotoLab's Space and every other Space. |
| Auto-opening on any new display | A projector at someone's house is not an invitation. Only a screen it has been opened on before reopens (§3.3). |
| The Activity window or the log on the second screen by default | The only big surface he has, spent on text. |
| The cull's line drawn over the photograph on the big screen | Principle 4. The machine's words live where his controls are, and a judgement written across a frame changes how the frame looks. |
| `.backgroundExtensionEffect()` (macOS 26) behind the photograph | It invents pixels by mirroring and blurring the picture's own edges, immediately beside the one thing he is judging. Off in this window, permanently. See §8. |
| Rendering a preview of what PhotoLab will do | The app never re-renders his exports. His rule, and it is right. |
| A "both screens show the same frame at two zoom levels" split | That is Hold, with fewer moving parts. |

---

## 6. Accessibility, HIG, and light/dark across two screens

- **Full Keyboard Access.** The Tab ring never enters the picture window, because the window cannot
  become key. That is the correct behaviour — every control the ring could reach is on the laptop —
  and a test asserts that tabbing through the whole app never lands a focus ring on the second
  screen.
- **VoiceOver.** The picture window is reachable through VO's window chooser (VO-F2-F2) and through
  the Window menu. In Frame, Follow-on-Single and Hold it is one accessibility element; in Compare and
  The Whole Burst it has one child element per tile or cell, each labelled the same way. The label is the same sentence §2.15 specifies for
  a frame — *"Frame 04330, 2 of 7 in burst 3. You kept it…"* — followed by **"Controls are in the
  main window."** It exposes no custom actions: Keep, Drop, Clear the Mark and Compare are custom
  actions on the *main* window's frame element, where they already are, and duplicating them here
  would give VoiceOver two routes to the same verdict with two different display gates.
  Mode changes and Hold are announced `.polite` once: *"The other screen is holding frame 04330."*
- **Voice Control.** Every menu item's title is its spoken name, so "Show the Picture on the Other
  Screen", "Hold This One on the Other Screen" and "Presentation" all work. The only click targets on
  the second screen are Compare tiles and The Whole Burst's cells; each carries its frame number as
  its accessibility label, so "Click 04331" moves the focus there, and none of them decides anything.
- **Increase Contrast** thickens the HUD's border to 1 pt and the hairlines to 3 pt; it does **not**
  change the surround (§4.4, rule 3) and does not change the photograph.
- **Reduce Transparency** swaps the HUD's glass or material for an opaque `#1A1A1A` capsule in the
  identical shape and position.
- **Reduce Motion** removes the HUD's fade (it appears and disappears instantly), removes the title
  bar's 120 ms fade, and removes the verdict badge's spring (it flashes). The frame change was never
  animated (§2.14). The contact sheet moves to the cursor without sliding; it used to scroll there
  animated whatever the setting.
- **Larger text** scales the HUD's caption and the These Screens panel; the photograph is never
  scaled by it and neither is the surround inset.
- **Light and dark.** The app follows the system fully, on both screens, for all chrome. **The
  surround does not, on either screen, and the reason is in §4.4** — his eye adapts to the surround
  and every tone judgement is made relative to it, so a surround that flips at sunset means the same
  shoot was judged against two references. This is the one deliberate departure from "the app looks
  like the OS it is on" (`DESIGN.md` §2.2), it is already made in `DESIGN.md`, and the second screen makes it
  more important rather than less, because two screens flipping together is twice the change.
- **HIG conformance checks:** the window appears in the Window menu by title; it has a standard
  close control (revealed on hover, §1.4); it has a title and subtitle; it is resizable with a
  sensible minimum; it does not minimise (and so never hides where he cannot find it); it never
  blocks the main window; it has no modal state; every action that drives it is a real menu item; and
  nothing about it is destructive, so §2.8's rules — no destructive action in a toolbar, none with a
  shortcut, Delete bound to nothing — are satisfied trivially and asserted by the existing
  command-table test.

---

## 7. What it adds to the app

This is built as one area alongside the parts in `DESIGN.md` §5. It rests on the foundation (§5.0)
and on nothing else: it adds files of its own, and makes a short and fully listed set of edits
elsewhere.

### 7.1 Files it adds

```
app/Sources/PipelineKit/Displays/
    DisplayDirector.swift          the one @MainActor @Observable object; open/close, mode, hold,
                                   presentation, per-screen memory, the note
    ScreenKey.swift                stable identity (§3.4) — pure, no AppKit in the hot path
    ScreenWatcher.swift            didChangeScreenParameters + the CG reconfiguration callback +
                                   sleep/wake, debounced into a ScreenSet
    ScreenSet.swift                ScreenInfo, ordering, best(), externals
    PictureWindow.swift            the NSWindow subclass (canBecomeKey == false) + its controller
    PictureChrome.swift            the fade-in title bar, the HUD capsule, the two hairlines
    PictureRootView.swift          SwiftUI root; switches on BigPictureContent
    BigFrameLayer.swift            the double-buffered CALayer pair (§4.7) + per-window display link
    ContactSheet.swift             The Whole Burst — NSCollectionView, recycled, lazy
    PresentationMode.swift         entering, the refusals, the pointer, the exit hint
    ScreensPanel.swift             Window ▸ These Screens…
    FrameDrag.swift                NSFilePromiseProvider + pasteboard (§5.5)
    PixelTier.swift                point size + backing scale → the size to ask for; the tile /
                                   whole-frame rule (§4.6) — pure, unit-tested
    DisplayCommands.swift          rows contributed into Commands/CommandTable.swift
    DisplayStrings.swift           keys under "displays." in Localizable.xcstrings

app/Tests/PipelineKitTests/Displays/**
app/Sources/SnapshotHarness/Scenes/Displays/**
```

Nothing here shares a file with another area of the app.

### 7.2 The exact edits it makes elsewhere in the app

File by file. Every one of them is a handful of lines, and the list is exhaustive — which is the
point of writing it as a table rather than describing it.

| File | The edit |
|---|---|
| `Images/ImagePump.swift` | Add `public enum Consumer { case stage, picture, strip, tile }`; `prefetch(_:for:priority:)` and `cancelPrefetch(for:)`; the cold-request rule becomes "≤ 2 total, ≤ 1 `.picture`" (§4.7). |
| `Images/Budget.swift` | `tileCount` → `tileBytes`; add `secondaryDecodedCount = 3`; extend the memory-pressure ladder to drop `.picture` before `.stage` (§4.5). |
| `Images/TileFetcher.swift` | The ≥ 80 %-of-frame-width whole-frame rule; the px clamp constant 4096 → **6144**; "never scale at 1:1 — draw true size, centred" (§4.6). |
| `Images/Downsampler.swift` | Tag an untagged `CGImage` as sRGB; honour an existing tag (§4.3). Six lines, and the single most important line in this document for how the photographs look. |
| `Design/Tokens.swift` | `Palette.viewerBackground` and a new `Palette.surroundDark` defined with `NSColor(srgbRed:…)` / asset-catalog colours, **never** `deviceWhite`/`calibratedWhite`; add `Metric.pictureInset = 16`, `Metric.pictureHUD = 44`, `Metric.hairline = 2`. |
| `Shell/RefusalRow.swift` | Add `enum Severity { case refusal, note }` (a note renders in the ordinary text colour and self-clears after 6 s) and `RefusalOwner.displays`, so a screen note and a verdict refusal can never overwrite each other (`DESIGN.md` §2.5.4). |
| `Shell/ActivityWindow.swift` | Autosave name becomes `"activity.\(ScreenKey)"` and it reopens on the screen it was last on (§5.2). |
| `Commands/CommandTable.swift` | Insert the `DisplayCommands` group into Window, View and Frame exactly as §3.10 lists it; the existing "every key action has a menu item" test then covers `H` for free. |
| `LightTable/ViewerModel.swift` | (a) `cursor`, `mode`, `compareSet`, `zoom`, `aim` become `public private(set)` on the `@Observable` so the director can read them. (b) `perform(.compare)` asks `director.compareTarget` whether Compare opens here or there (§5.1). (c) `perform(.hold)` — one new case, forwarded to the director. (d) `perform` asks `director.allows(action)` first, so Presentation's refusals live in one place. |
| `LightTable/ChooseKeepersStep.swift` | Two lines: `.onAppear { director.attach(viewer, session: session) }` / `.onDisappear { director.detach() }`. |
| `LightTable/KeyMap.swift` | One new action, `.hold`, bound to `H`, `allowsRepeat == false`, absent in `.textEditing`; and one new mode, `.presentation`, in which ← → ↑ ↓ Home End drive the Presentation deck and K / D / 0 / 1–6 / ⇧K / U / ⌘Z / N / P all resolve to the one refusal (§5.6). The existing KeyMap tests extend to it unchanged. |
| `SettingsUI/Tabs/Choosing.swift` | Four rows: "Bring the picture back when a screen I've used comes back" (on) · "Compare on the other screen when it's open" (on) · "Show the cull's line on the other screen" (off) · "Hide the pointer on the other screen when it sits still" (on). |
| `ExtensionHost/ExtBridge.swift` | `viewFrames(_:startAt:)` routes to `DisplayDirector.present(...)` when the picture window is open, and to the existing laptop overlay otherwise (§5.3). |
| `Reels/FrameGrid.swift` | The same one-line routing for double-click / Space / force click (§5.3). |
| `Learning/ReviewModeHost.swift` | The same one-line routing for "[See the 10]" (§5.3). |
| `FirstEdit/AppDelegate.swift` | Create the `DisplayDirector`, start the `ScreenWatcher`, restore the window after the screen list is known, and assert the main window is key in `applicationDidBecomeActive`. |
| `pipeline/studio.py` | `/crop`'s `px` clamp 4096 → **6144** (§4.6). Nothing else. |
| `tests/test_studio_panel.py` | One case: a served `/full` and `/crop` JPEG decodes as sRGB (§4.3). |
| `DESIGN.md` §2.1, §3.5, §4.5, §6 | Replace the "no second-display window in v1" call and the later-phase item with a pointer to this document; update the two memory-budget lines (§8). |

### 7.3 The interfaces the light table codes against

```swift
// Displays/DisplayDirector.swift
@MainActor @Observable
public final class DisplayDirector {

    public enum Mode: String, CaseIterable, Codable, Sendable { case follow, frame, wholeBurst }
    public enum Presence: Equatable, Sendable { case closed, open(ScreenKey), presenting(ScreenKey) }
    public enum CompareTarget: Sendable { case mainWindow, pictureWindow }

    public init(settings: SettingsStore, pump: ImagePump, jobs: JobModel, screens: ScreenWatcher)

    // read by the light table
    public private(set) var presence: Presence
    public var isOpen: Bool { get }                 // open or presenting
    public var isPresenting: Bool { get }
    public var compareTarget: CompareTarget { get } // §5.1; .mainWindow when closed or switched off
    public private(set) var heldStem: String?
    public private(set) var note: String?           // one plain sentence for the control bar; nil when clear

    // called by the light table, twice
    public func attach(_ viewer: ViewerModel, session: ShootSession)
    public func detach()

    // called from the menu
    public func toggleWindow()
    public func open(on key: ScreenKey?)            // nil = §3.3's choice
    public func close()
    public func setMode(_ m: Mode)
    public func toggleHold()                        // H
    public func fillScreen(_ on: Bool)
    public func enterFullScreen()                   // refuses politely per §3.6
    public func beginPresentation(_ deck: PresentationDeck.Kind = .whatIKept)   // .whatIKept / .thisBurst / .wholeShoot
    public func endPresentation()

    // called by anyone with frames to show large (§5.3)
    public func present(_ content: BigPictureContent, from source: BigPictureSource)

    /// True only if the action is allowed right now. Presentation refuses every verdict,
    /// every reason, undo, N and P (§5.6). The light table asks before it acts.
    public func allows(_ action: Action) -> Bool
}

public enum BigPictureContent: Equatable, Sendable {
    case nothing(line: String?)                                       // §1.5
    case frame(stem: String, caption: FrameCaption, zoom: ZoomState)
    case tiles([CompareTile], focus: Int, zoom: ZoomState)            // Compare, and Learning's review
    case burst(id: String, cells: [BurstCell], cursor: Int)           // The Whole Burst
    case job(title: String, stage: String, fraction: Double)
    case engineDown(sentence: String)
}

public protocol BigPictureSource: AnyObject {
    var shoot: String { get }
    var content: BigPictureContent { get }
}
```

```swift
// Displays/ScreenKey.swift and ScreenSet.swift — pure enough to unit-test with no displays attached
public struct ScreenKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: String
    public var isBuiltIn: Bool { get }
    public init(_ screen: NSScreen)
    public static func make(displayID: CGDirectDisplayID, isBuiltIn: Bool,
                            vendor: UInt32, model: UInt32, serial: UInt32, unit: UInt32,
                            physicalMM: CGSize, points: CGSize, scale: CGFloat,
                            name: String) -> ScreenKey      // the testable seam
}

public struct ScreenInfo: Hashable, Sendable {
    public let key: ScreenKey, name: String
    public let frame: CGRect, visibleFrame: CGRect
    public let backingScale: CGFloat
    public let colorSpaceName: String?
    public let isBuiltIn: Bool, isAsleep: Bool, hasMenuBar: Bool
}

public struct ScreenSet: Hashable, Sendable {
    public let screens: [ScreenInfo]
    public var externals: [ScreenInfo] { get }
    public func best(preferring: ScreenKey?) -> ScreenInfo?           // §3.3's ladder
    public subscript(_ key: ScreenKey) -> ScreenInfo? { get }
}
```

```swift
// Displays/PixelTier.swift — pure
public enum PixelTier {
    public static let ladder = [1440, 2048, 2600, 3200, 4096]
    public static func px(forPointWidth w: CGFloat, scale: CGFloat) -> Int
    public static func request(viewportDevice: CGSize, frameNative: CGSize,
                               aim: CGPoint, budget: Budget) -> TileRequest
}
public enum TileRequest: Equatable, Sendable {
    case crop(cx: Double, cy: Double, px: Int, ar: Double)
    case wholeFrame(px: Int)                       // the ≥ 80 % rule
    case trueSizeCentred(px: Int)                  // the budget cannot cover the viewport (§4.6-3)
}
```

### 7.4 Unit tests (`swift test`)

**Screen identity — `Displays/ScreenKeyTests.swift`.** Every case is a struct of numbers through
`ScreenKey.make(...)`, so it runs on a build machine with one display or none:

- The same panel re-enumerated with a **different `CGDirectDisplayID`** produces the **same** key.
- The built-in screen matches itself across a scale change, a lid close and a rearrangement.
- **Serial 0 (a conversion board)**: two panels with identical vendor/model/serial-0 but different
  physical millimetres produce different keys; the same one across a reconnect produces the same key.
- A resolution change on the same panel produces a **different** frame key and the **same** coarse
  key (so the mode survives and the frame does not, §3.4).
- A localised `localizedName` change alone does not change the key.
- Degenerate input (0 × 0 mm, empty name, unit 0) still yields a unique, stable, non-crashing key.

**Scale and size — `PixelTierTests.swift`.** The whole of §4.1's table asserted row by row, plus:
2076 pt @ 2× → 4096 (capped, 1.4 % over); 2076 pt @ 1× → 2600; a straddling window uses the window's
scale not the screen's; §4.6's three `TileRequest` branches at 8 GB, 16 GB and 48 GB budgets; 1:1 never
returns a request that would be drawn scaled.

**The director — `DisplayDirectorTests.swift`.**

- Disconnect: mode, hold and fill flag are preserved; the cursor, the verdict log and the "looked
  through" set are byte-identical before and after; `note` is set once; **zero** writes reach
  `VerdictQueue`.
- Reconnect of a remembered key reopens in the remembered mode; reconnect of an unknown key opens
  nothing.
- `compareTarget` is `.pictureWindow` only when the window is open **and** the setting is on.
- Presentation refuses E, D, X, 1–6, ⇧E, Q, ⌘Z, **R and W**, and K, 0, ⇧K, U, N and P; walking a
  174-frame "What I Kept" deck across 40 bursts leaves the light table's cursor, the verdict log and every `ReviewBurst`
  byte-identical — the "looked through" regression test. With the key window forced to nil, Esc still
  ends Presentation (the local monitor).
- `allows(_:)` returns true for every action the moment Presentation ends.
- Closing the window while Hold is on releases the hold and writes nothing.
- 500 synthetic screen-change notifications in 200 ms produce exactly one rebuild (the debounce).

**Focus — `PictureWindowFocusTests.swift`.** After open, after a synthetic click, after
`makeKeyAndOrderFront`, after a mode change, after full screen, after Presentation:
`NSApp.keyWindow === mainWindow` and `mainWindow.firstResponder === stageView`. And: the Tab ring
never yields a responder inside the picture window.

**The display gate — `DisplayGateTwoWindowsTests.swift`.** The picture window displaying the current
frame while the stage displays the previous one must **not** satisfy `isDisplayedFrameCurrent`; the
refusal raised is *"That frame isn't the one on screen."*; nothing is written.

**Colour — `ColorTaggingTests.swift`.** An untagged JPEG fixture comes back tagged sRGB; a
Display P3-tagged fixture comes back untouched; `Tokens.Palette.viewerBackground` and `surroundDark`
resolve through a named colour space and are byte-identical when resolved against an sRGB screen
descriptor and a P3 one **in appearance** (the test compares the converted values, not the raw ones).
A test that greps the whole `Displays/` and `Design/` source for `deviceWhite`, `deviceGray`,
`calibratedWhite` and `deviceRGB` and fails on a hit.

**Budget — `TwoWindowBudgetTests.swift`.** Two consumers at two sizes never exceed the ceiling; the
memory-pressure ladder drops `.picture` before `.stage`; `tileBytes` evicts LRU; the cold-request
rule never lets two `.picture` requests be in flight.

**Strings — the existing `tools/vocabulary-scan.sh`** runs over `DisplayStrings.swift`, the new menu
rows and every test name in `Tests/PipelineKitTests/Displays/`. Note for whoever writes them:
**"tier" is on §2.13's retired list.** It may live in code and in this document; it may not appear in
a menu title, a HUD caption, the These Screens panel or a test name — say "size", or say the number.

### 7.5 Snapshot scenes

Registered under `Sources/SnapshotHarness/Scenes/Displays/`, rendered at **1512 × 945** (the laptop
at 14" full screen, for the main-window-with-a-note scenes) and **2560 × 1440** (the external), each
in light and dark, each with Neutral Grey and with Black:

1. `picture.frame.landscape` — the default, no chrome, both hairlines.
2. `picture.frame.portrait` — 34.6 %, so the waste is visible and agreed to rather than discovered.
3. `picture.frame.hud` — the HUD revealed, with and without the cull's line.
4. `picture.frame.verdict` — the badge mid-flash in the surround.
5. `picture.compare.2up` and `picture.compare.4up` — synced zoom, focus ring, tile captions.
6. `picture.wholeBurst` — 34 cells, his marks and the cull's, a stack bracket, the cursor ring.
7. `picture.hold` — held frame, the hold badge in the surround, and the HUD line naming it.
8. `picture.nothing`, `picture.job`, `picture.engineDown` — §1.5's three.
9. `picture.presentation` — nothing but the frame, plus the 3 s exit hint as a second variant.
10. `picture.chromeRevealed` — the title bar faded in over the photograph.
11. `picture.increaseContrast` — the HUD and hairlines thickened, the surround unchanged.
12. `main.noteScreenWentAway` and `main.noteScreenIsBack` — the control bar's second line, at
    1512 × 945, proving the note does not move the cluster.
13. `screensPanel` — two rows, one of them a 1× external, laid out as §5.7 shows.

The harness renders the AppKit-backed ones through `bitmapImageRepForCachingDisplay(in:)` +
`cacheDisplay(in:to:)` behind the same `Scene` protocol, exactly as §4.3 of `DESIGN.md` already
specifies for the viewer and the filmstrip, and **creates its bitmap context in sRGB** so the PNGs
compare across machines.

### 7.6 By hand, on two displays — the short checklist

Only these twelve need real hardware. Ten minutes, in order:

1. Dock the external. ⌥⌘P. The picture lands on the external, fills it, and **nothing on the laptop
   has moved by a pixel** — check Keep and Drop against the previous screenshot.
2. K, K, D with your eyes on the external. Each press changes both pictures at once; the badge
   flashes in the surround; the tally on the laptop agrees; no lag you can name.
3. Hold K down for two seconds. **One** frame changes, **one** verdict is written, and the same
   one-time line appears.
4. **Undock mid-burst.** The window goes; the laptop shows one sentence; the frame, the cursor, the
   zoom and every verdict are exactly where they were; nothing was asked.
5. Re-dock. The picture comes back on the same screen, in the same mode, showing the frame you are
   on now.
6. Drag the picture window onto the laptop and back. It is sharp in both places within half a second
   and never goes blank.
7. Sleep the Mac with it open; wake it. The picture is still right — not stretched, not blank, not
   the wrong size.
8. Put the same frame up on both screens and look at the **grey surround**. It is the same grey. Then
   look at the photograph: as close as the two panels can manage. Open Window ▸ These Screens… and
   read both profiles.
9. Press Z on the external at 1:1 and pan around. It is genuinely 1:1 (the picture does not get
   softer as you pan), and arrowing to the next frame stays on the same eye.
10. `C` on a stack of four. Four tiles on the external, the strip and the buttons still on the
    laptop, Z zooms all four on the same eye, ⇧K is one undo step.
11. ⌃⌘P. It walks your keepers across bursts; S F and the arrows only, R and W a burst; the pointer disappears; K does nothing
    and says so once; Esc comes back to the light table exactly where you left it — and none of the
    bursts you walked through is marked as looked through.
12. Open PhotoLab. The picture stays up on the external. ⌘-tab back and press K: it works on the
    **first** press.

### 7.7 Acceptance

- `swift build -c release` and `swift test` green; every test in §7.4 passes with no display attached
  on the build machine.
- `NSApp.keyWindow` is never the picture window, asserted across every operation the director
  exposes.
- A verdict can never be satisfied by the picture window's display report (§2.6's test).
- Geometry matches §1.6 at 2560 × 1440: photograph 2076 × 1384 pt filling the screen, 2112 × 1408 in
  full screen, 16 pt inset on every side, asserted by a layout test.
- The image asked for matches §4.1's table row for row, at 1× and at 2×, including the straddling
  case.
- No source file under `Displays/` or `Design/` contains `deviceWhite`, `deviceGray`,
  `calibratedWhite` or a `deviceRGB` context.
- Disconnect and reconnect, run 50 times in a loop against a fake `ScreenWatcher` mid-burst: zero
  verdicts written, zero cursor moves, zero navigation, the undo stack unchanged, exactly 50 notes.
- Presentation cannot record "looked through": asserted directly against `ReviewBurst`.
- `tools/bench.swift` reports `frame.swap.both` ≤ 8 ms p95 and a two-window footprint ≤ 1.5 GB on a
  1,157-frame shoot with the picture window filling a 5K.
- `tools/vocabulary-scan.sh` clean over everything here, including the menu rows.
- All thirteen snapshot scenes render in light and dark at both sizes.
- The §7.6 checklist run on two real displays, with a yes against each line.

### 7.8 macOS 15 versus macOS 26

**Nothing in this document requires macOS 26.** Everything load-bearing — `NSScreen.localizedName`,
`NSScreen.colorSpace`, `NSScreen.screensHaveSeparateSpaces`, the `deviceDescription` screen number,
`CGDisplayVendorNumber`/`ModelNumber`/`SerialNumber`/`UnitNumber`/`ScreenSize`/`IsBuiltin`/`IsAsleep`,
`CGDisplayRegisterReconfigurationCallback`, `NSApplication.didChangeScreenParametersNotification`,
`NSWorkspace.screensDidSleep/DidWake/didWake`, `NSWindow.setFrameAutosaveName`/`setFrameUsingName`,
`collectionBehavior`, `occlusionState`, `canBecomeKey`, `acceptsFirstMouse`,
`viewDidChangeBackingProperties`, `NSView.displayLink(target:selector:)`, `NSFilePromiseProvider`,
`CGImage.copy(colorSpace:)`, `CATransaction` — exists on macOS 15, which `DESIGN.md` §3.1 sets as the
floor. `NSView.displayLink(target:selector:)` is the newest of them, at macOS 14.

Three places take a macOS 26 path when it is there, each with the same geometry on 15 so nothing
reflows by OS version, exactly as `DESIGN.md` §3.1's table requires:

| macOS 26+ | Where | Fallback on 15 |
|---|---|---|
| `.glassEffect(in:)` | the HUD capsule, the Presentation exit hint | `.background(.ultraThinMaterial, in: Capsule())` — identical frame |
| `.scrollEdgeEffectStyle` | The Whole Burst's top and bottom edges | a 1 pt hairline separator |
| `.buttonStyle(.glass)` | the two controls in the revealed title bar | `.bordered`, identical frames |

And one macOS 26 API this design **refuses** on this window: `.backgroundExtensionEffect()`. See §8.

---

## 8. Where this disagrees with `DESIGN.md`

The section number that opens each item is `DESIGN.md`'s; any later bare § in an item is this
document's.

1. **§2.1's "no second-display window in v1", and the §6 item that made it a later phase —
   superseded.** The reason given was "real focus-management risk". That risk is two overridden
   properties (§0), and the measured value (LT-04, LT-05, DUP-7) is larger on the external than
   anywhere else in the app.
2. **§3.5's memory caps are counts; two of them must become bytes.** `tileCount: 8` cannot survive
   tiles that range from 3392 px to 6144 px wide; it becomes `tileBytes` (§4.5). This is a real bug
   waiting in the one-window design too — eight 4096 px tiles at 3:2 are 358 MB, eight whole-width
   tiles on the external are 631 MB, and a count cannot tell the two apart.
3. **§4.5's "Memory ≤ 1.2 GB" becomes two lines**: ≤ 1.2 GB with one window, ≤ 1.5 GB with the
   picture window filling a 5K. A single number that is silently wrong in his actual setup is worse
   than two numbers that are both right.
4. **§3.9-3's `/crop` clamp of 4096 should be 6144.** The arithmetic is in §4.6: a 1:1 viewport on
   a 5K external is 5056 device px wide, and even the laptop's own 1.6× tile at 14" full screen is
   4787 px. At 4096 the app would either lie about 1:1 or show 81 % of the width it could. One
   integer, in a line that is already being edited.
5. **§2.15's "Pointer: never hidden" gains two stated exceptions** — the picture window after 1.5 s
   of stillness, and Presentation — both settable, both with the pointer returning on the first
   movement. A black arrow parked in the middle of a photograph he is judging is not an
   accessibility win.
6. **§3.1's use of `.backgroundExtensionEffect()` "picture bleeding under the sidebar in Full Image"
   is refused on the picture window, and I would reconsider it in Full Image too.** The effect works
   by mirroring and blurring the content's own edges to fill the space beside it. Placed immediately
   beside a photograph, it invents pixels that look like the photograph, next to the one thing in the
   app he is being asked to judge — and it does it in colours taken from the frame, which is the
   opposite of a known neutral surround (§4.4). On this window: off, permanently.
7. **§2.12 already contains a shortcut collision that is not mine to fix but is worth naming**: Go
   assigns **⌘9** to the second extension-supplied step while View assigns **⌘9** to Zoom to Fit.
   Whichever is installed second wins, silently. Nothing in this document lands anywhere near the
   ⌘-number range; the fix is probably to move the extension steps to ⇧⌘1…, and the command-table
   test that already exists should assert that no key equivalent appears twice.
8. **§5 gains a part.** It rests only on the foundation (§5.0), and its only couplings to the rest
   of the app are the nineteen small edits in §7.2 — which is why they are listed as a table rather
   than described.

---

## 9. What is left to decide

Six things, all with a default that ships, none of them blocking. They are written to the person the
app is for, which is who has to answer them.

1. **Does the big screen follow the laptop, or stay pinned to the frame?** Default: it follows — when
   you press C on the laptop the big screen shows the four frames side by side, when you press G it
   shows the whole burst. The other choice is that it only ever shows the one frame you are on, and
   nothing else ever changes it. *(You can change this from the View menu at any time and it is
   remembered per screen.)*
2. **When the big screen is there, should C put the four side-by-side frames on it instead of on the
   laptop?** Default: yes — four frames side by side each get nearly seven times the area they have on
   the laptop, and the buttons and the strip stay under your hand. Settings has a switch.
3. **Should the picture come back on its own when you plug the screen back in?** Default: yes, but
   only for a screen you have used it on before — so plugging into a TV at someone's house never
   throws a window onto it.
4. **The grey behind the photograph is one fixed grey on both screens and it does not change when
   macOS goes dark.** That is deliberate: your eye judges exposure against whatever is around the
   frame, and a surround that changes at sunset means the frames you picked in the afternoon and the
   ones you picked in the evening were judged against two different things. Say if you would rather
   it followed the system.
5. **1:1 on the big screen needs one number changed in the engine** (the largest cut it will hand
   out, 4096 → 6144 pixels). Without it, a 1:1 check on the 27" is either not really 1:1, or shows
   about four fifths of the width it could. It costs nothing on the server. Worth doing.
6. **Presentation shows what you kept, and nothing you do during it counts.** It walks your keepers
   across the whole shoot with the arrow keys, on its own place-keeping, so the light table does not
   move and no burst gets marked as looked through while you show someone. Every key that decides
   anything is switched off until Esc. The other choice is every frame of the shoot, which is in the
   same menu — say if you would rather that were the default.

One more, which is not a decision so much as something to look at: **check what your external panel
is actually running at.** Window ▸ These Screens… will tell you. If a 2560 × 1440 panel reports 1×,
the picture on the big screen has fewer real pixels than the picture on your laptop, and that is the
cable or the board, not the app.
