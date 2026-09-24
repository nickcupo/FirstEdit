# The extension host contract

FirstEdit can show steps it did not write. An extension declares its own steps, serves a whole
page for each one, and the app draws that page in the detail pane as if it had built it.

**FirstEdit is complete without one.** Nothing in this document is needed to use the app, and
with no extension installed none of the code behind it runs. This is the contract for anyone who
wants to add a step.

---

## 1. What an extension is

A folder the app is pointed at in **Settings ▸ Advanced**. The engine loads it and reports what it
declares on `GET /api/shoots`, under `ext`:

```json
"ext": {
  "kind":   "a-kind",
  "ask":    { "question": "", "yes": "", "no": "", "blurb": "", "badge": "", "other_badge": "" },
  "steps":  ["ingest", "cull", "keepers", "presets", "edit", "a-step", "reels", "done"],
  "labels": { "a-step": "An Added Step" },
  "every":  ["a-step"],
  "pages":  { "a-step": "http://127.0.0.1:9931/pages/grid?shoot={shoot}" }
}
```

| Field | What it is |
|---|---|
| `kind` | The kind of shoot this extension adds, if it adds one. |
| `ask` | The words the app uses when it asks about that kind. Every one of them is the extension's. |
| `steps` | The whole ordered step list, with the extension's own ids among the engine's seven. If it names only its own, they go in before `done`. |
| `labels` | Step id → the label the sidebar row and the window subtitle show. |
| `every` | Steps added to every kind of shoot, not only this extension's own. |
| `pages` | Step id → a URL template for the page that step shows. |

The engine's own seven step ids — `ingest`, `cull`, `keepers`, `presets`, `edit`, `reels`, `done` —
are never an extension's. Anything else in `steps`, `every` or `pages` is.

**Every string a person reads on an added step is the extension's**, fetched at runtime. None of them
is compiled into the app, and the app never invents one.

### The page URL

`pages[<step>]` is expanded with `{shoot}`, percent-encoded for the part of the URL it lands in, so a
shoot whose name has a space in it works. The template may be:

- **absolute** — the extension's own server, on its own port; or
- **relative** — resolved against the engine, e.g. `/ext/a-step?shoot={shoot}`.

Either way it must be `http` or `https` **on `127.0.0.1` or `localhost`**. A template that names
anywhere else is not served at all: a page that reached the open internet would carry a shoot's name
off this Mac.

With no `pages` map, a declared step falls back to the engine's own `GET /ext/<step>?shoot=<name>`.

---

## 2. How the page is loaded

Through a custom URL scheme, **`pipeline-ext://`**, handled inside the app. Not an iframe, not a
plain `http://` load.

```
your page          http://127.0.0.1:9931/pages/grid?shoot=a%20shoot
what the page sees pipeline-ext://page/pages/grid?shoot=a%20shoot
```

Only the scheme and the authority change. The path and the query are carried across byte for byte,
so a relative link, a root-relative path and a same-origin absolute URL all resolve to the same bytes
they would have on your own server. Write your page's links exactly as you would anywhere else.

### The key

The app adds **`X-Studio-Key`** to the page's own request *and to every subresource the page asks
for* — stylesheets, scripts, pictures, `fetch`, `XMLHttpRequest`. The key is a fresh 32 random bytes
per launch, handed to the engine in `PIPELINE_STUDIO_KEY` and to the extension in `ctx`.

**Your server must require it.** Refuse any request without it, with `403` and a plain sentence.

This is the whole reason the page is not loaded over `http://`. A page loading its own picture cannot
put a header on that load, so a server that demanded the key would break every picture on the page,
and a server that did not demand it is reachable by anything else on the machine. Going through the
scheme handler, the app puts the header on everything. Nothing inside the page can read the key: it
is not in the document, not in `window`, and not in any URL.

### Each visit

The page is loaded afresh every time the person comes to the step, so it always shows what is true
now. Two things make that cheap:

- **Say how long a thing stays good.** Subresources go through a memory cache that does exactly what
  your server's `Cache-Control` says, and nothing else. A picture served with `max-age` is fetched
  once and not again on the next visit; one served with nothing is fetched each time.
- **The page comes back where the person left it.** The app notes how far the page was scrolled and
  scrolls it back there once the page is tall enough — after your cards are drawn — unless the
  person scrolls, clicks or presses a key first.

### What a page may not do

- **Leave its origin.** A navigation to anything but `pipeline-ext://` is cancelled and a refusal
  appears under the page. Nothing is opened. The one exception is a link the person clicks to an
  `http` or `https` address that is not this Mac's: it opens in their own browser, and your page
  stays where it is. Only the link's address goes — write it with nothing in it you would not
  print. A script setting `location`, a form, or a link to any address of this Mac — `localhost`,
  `127.x.x.x`, `0.0.0.0`, `::1` or a `.local` name — is still refused, and so is a link your own code
  follows more than about a second after the person's last press on the page; a key typed into one of
  your fields is not a press. Let the person's click on the link be what follows it, not a fetch
  first.
- **Open a window.** `window.open` is refused. A `target="_blank"` link the person clicks to the
  web opens in their browser, as above.
- **Use an iframe.** A page is never loaded in a frame — not by the app, and not by itself.
- **Keep anything in `localStorage`.** The web view's storage is thrown away when the pane closes.
  Use `pipeline.state` (§4).

`alert()` asks the person nothing, so it is not a sheet: its sentence is one line under the page, in
the secondary colour, and `alert()` returns at once. The line goes after a few seconds, at the
person's next click on the page, when the page loads again and at the next thing the page asks of
the app. A line said within a second of the page loading again stays up through the load, so
`alert('Saved'); location.reload()` is still read; two said within a second of each other are shown
together. `confirm()` is drawn as the app's own sheet rather than WebKit's, and as *ordinary*: two
plain buttons with the yes as the default. It is not red, because it is not dangerous. The red
button, the hand's width of clearance and Cancel-as-the-default belong to
`pipeline.confirmDestructive` (§4) and to nothing else — that is what makes them mean something when
he sees them. Use `confirm()` for an ordinary question and `pipeline.confirmDestructive` for one
that cannot be taken back; do not reach for `confirm()` to avoid writing a consequence down.

---

## 3. The look

At document start — before any of your own code runs — the app sets CSS custom properties on
`:root` from the live system colours, for the appearance the pane is actually drawn in. It sets them
**again** whenever that appearance changes while the page is open, and fires a
`pipelineappearance` event on `window`.

Use them and your page is light in Light Mode and dark in Dark Mode with the app, in the user's own
accent, in the system font. Hard-code a colour and it will be wrong half the time.

### Colour

| Property | What it is |
|---|---|
| `--pp-text` | Body text. |
| `--pp-text-secondary` | Supporting text. |
| `--pp-text-tertiary` | Text that is barely there. |
| `--pp-text-disabled` | A control that cannot be used. |
| `--pp-link` | A link. |
| `--pp-background` | The page's own surface. |
| `--pp-background-secondary` | A card or a row on that surface. |
| `--pp-control` | A control's own fill. |
| `--pp-control-text` | Text on a control. |
| `--pp-separator` | A hairline. |
| `--pp-accent` | The user's system accent. Never a colour of your own. |
| `--pp-accent-text` | Text on the accent. |
| `--pp-selection` | A selected row. |
| `--pp-kept` | Something the person kept. |
| `--pp-alarm` | Something wrong, or something that cannot be taken back. |
| `--pp-fault` | A fault in a frame. |

Colour is never the only thing that says what a state is: put a word and a symbol with it, so
Differentiate Without Color loses nothing.

### Type and space

| Property | Value |
|---|---|
| `--pp-font` | The system font. |
| `--pp-font-mono` | The system monospaced font, for frame numbers. |
| `--pp-text-large-title` … `--pp-text-footnote` | `26px` / `22px` / `17px` / `15px` / `13px` / `13px` / `12px` / `11px` / `10px` |
| `--pp-text-headline-weight` | `600` |
| `--pp-space-window` `--pp-space-group` `--pp-space-related` `--pp-space-label` | `20px` / `16px` / `8px` / `4px` |
| `--pp-column` | `680px` — the width a column of text is read at. |
| `--pp-radius` | `6px` |
| `--pp-hit-target` | `28px` — nothing clickable is smaller than this. |

### State

| Property | Value | Also on `document.documentElement.dataset` |
|---|---|---|
| `--pp-appearance` | `light` or `dark` | `appearance` |
| `--pp-reduce-motion` | `1` or `0` | `reduceMotion` |
| `--pp-increase-contrast` | `1` or `0` | `increaseContrast` |

**Honour them.** When `--pp-reduce-motion` is `1`, do not animate. When `--pp-increase-contrast` is
`1`, draw your borders.

```css
.card {
  background: var(--pp-background-secondary);
  border: 1px solid var(--pp-separator);
  border-radius: var(--pp-radius);
  padding: var(--pp-space-related);
  color: var(--pp-text);
}
```

```js
window.addEventListener("pipelineappearance", (e) => {
  // e.detail.appearance, e.detail.reduceMotion, e.detail.increaseContrast
});
```

---

## 4. What the page can ask the app for

`window.pipeline` exists before your own code runs. It is frozen: a page cannot replace it. Every
call answers a promise.

### `pipeline.viewFrames(stems, startAt, options) → Promise<{index, stem, marks}>`

Opens the app's own viewer over the page, at `stems[startAt]`, and resolves **when the person closes
it** — with the frame they were looking at and every mark as it then stood.

```js
const look = await pipeline.viewFrames(["TSC04313", "TSC04314", "TSC04315"], 1, {
  actions: [{ id: "yes", label: "Yes", key: "y" }],
  marks: { TSC04313: "yes" },
});
// look.index, look.stem: where they stopped — scroll your grid to it.
// look.marks: { stem: id } for every frame that has a mark.
```

`options` is optional. `actions` are up to four marks, in your own words, each with one letter for
its key; the viewer draws them as checkboxes beside the frame's number. A frame has one mark at most,
a held key marks once, and `marks` is what is already marked when it opens; a mark naming no action
is dropped. The viewer's own keys are the app's (§5): S F and ← → move, Q takes back the last mark
made in the look, and Space, Esc or Return close it. So a mark's letter means what that letter means
everywhere else or nothing:

- `E` (or `K`) makes the mark what a keep leaves, and `D` what a drop leaves: the key sets it on the
  frame on screen and goes on to the next frame, and `X` takes the mark off.
- Any other letter of §5 — `S`, `F`, `X`, `Q`, `R`, `W`, `Z`, `C`, `G`, `N`, `P`, `U` — is dropped:
  no key.
- A letter §5 leaves free toggles its mark on the frame on screen.

A key already taken by an earlier action (`E` and `K` count as one), or that is not a letter, is
dropped too.

**Use it.** A grid of small pictures is not something to decide from, and the app already has a
viewer that does this properly. Do not build a loupe of your own. If the person decides something
about each frame, offer it as a mark, so the decision is made at full size, one key a frame, and
comes back to you in one answer — not an open, a close and a click on the card for every frame.

Rejects when the list is empty. A refusal appears under the page. A second call while a viewer is
open ends the first where it began and resolves it.

### `pipeline.confirmDestructive(title, body, confirmLabel) → Promise<boolean>`

Draws the app's own sheet and answers `true` only if the person pressed the confirm button.

```js
const said = await pipeline.confirmDestructive(
  "Send 14 photographs out of FirstEdit?",
  "They leave this Mac. FirstEdit cannot take them back afterwards.",
  "Send 14 Photographs");
if (!said) return;
```

**Anything that goes out to the world goes through this.** The sheet is the one the rest of the app
uses: Cancel is the default button, the confirm button carries the consequence in its own words, is
red, is not the default, and is a hand away from Cancel.

Write `title` as the question, `body` as what will actually happen, and `confirmLabel` as the
consequence — *"Send 14 Photographs"*, never *"OK"*. Both `title` and `confirmLabel` are required.

A second question asked while one is on screen waits its turn: it is put up when the first is
answered, in the order asked, never swapped in under the person's hand and never answered for them.
**Confirm a batch once** — *"Send 14 Photographs"* — never item by item: fourteen sheets in a row is
fourteen clicks for one decision.

### `pipeline.state`

Somewhere to keep what the page chose, per shoot. It replaces `localStorage`, survives the pane
being closed and the app being restarted, and is the app's to clear when a shoot goes.

```js
await pipeline.state.set("sort", "by time");
const sort = await pipeline.state.get("sort");   // "by time", or null
await pipeline.state.remove("sort");
```

Values are strings. `get` answers `null` — never `undefined` — for a key that was never set and for
one that was cleared.

**Keep only the page's own choices in it.** A verdict, a count, a decision — anything the person made
— belongs in the engine's files, and a second copy of it somewhere else is a second answer to a
question that may only have one.

---

## 5. Keys

The app's menu shortcuts — anything with ⌘ — always win. Single letters belong to whichever view has
the keyboard, so inside your page they are yours. Your page has the keyboard as soon as it has
loaded, unless the person is typing in a field elsewhere in the window, so a key works on arrival
without a click first. While a field of yours has focus — an `input` that takes text, a `textarea`,
anything `contenteditable` — no menu key without a modifier takes a letter from it: the host notes
focus moving in and out of fields itself, and you need do nothing.

These keys mean one thing on every page of the app that shows photographs. Use them with these
meanings or do not bind them:

| Keys | Mean |
|---|---|
| `S` `F`, ← → | the previous and next photograph |
| ↑ ↓ | a row up and down |
| `W` `R` (or `P` `N`) | the previous and next group — a burst, a set |
| `E` (or `K`) | keep, or include |
| `D` | drop, or leave out |
| `X` (or `0`) | clear the mark |
| Space | the photograph large, and back |
| `Z` | 1:1 |
| Esc | back |
| `Q` (or `U`) | undo |
| Return | the page's main button |

The other letters are yours.

Every action on your page needs a keyboard path as well as a mouse one. ⇧⌘R reloads the page while
it has the keyboard (⌘R is the app's Cull); the context menu inside it is the app's, not WebKit's,
and keeps Cut, Paste and the spelling guesses inside a field.

---

## 6. What a good added step does

1. Serves a whole page per step and declares it in `pages`.
2. Requires `X-Studio-Key` on every request to every server it runs.
3. Draws itself entirely out of the injected properties, and follows the appearance while it is open.
4. Calls `pipeline.viewFrames` instead of asking someone to decide from a thumbnail.
5. Puts anything that leaves this Mac behind `pipeline.confirmDestructive`, and never styles it like
   a routine action or puts it next to one.
6. Keeps per-shoot choices in `pipeline.state`.
7. Counts photographs, not folders.
8. Says what it is doing in plain words, and shows a refusal where the action was taken rather than
   in a dialog.

---

## 7. What the app does when something is wrong

Never an alert. One plain sentence in a bar under the page, in the alarm colour, with a **Details**
disclosure for the technical text. It goes when the person closes it, when the page next loads, and
at the next thing the page asks of the app:

| When | What it says |
|---|---|
| The step declared no page | This step has no page to show. |
| The page asked for something outside the origin it was served from | This page asked for something it is not being served. |
| The page tried to navigate off this Mac, or open a window, by anything but a link the person clicked | This page tried to open something outside FirstEdit. Nothing was opened. |
| A bridge call the app does not understand | FirstEdit did not understand what this page asked for. |
| `viewFrames` with no frames | This page asked to show frames and named none. |
| `confirmDestructive` with no title or no button label | FirstEdit will not ask a question with no words in it. |

A refusal from your own server is shown as your server wrote it. Write in sentences.

---

## 8. Settings

**Settings ▸ Advanced ▸ Web Inspector** turns `isInspectable` on for extension pages. It is off by
default, and the app never offers an inspector item in a context menu.
