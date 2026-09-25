# Releasing

Everything that has to happen before a version of FirstEdit is in
somebody else's hands, in order. Run it yourself, top to bottom; nothing here
is automated, because every step is one that cannot be taken back. A published
DMG cannot be unpublished, MIT cannot be revoked, and a pushed history is on
other people's machines before you have finished reading this sentence.

## The build, in short

On the release Mac, from a clean checkout at the release tag:

```sh
git status --short
IDENTITY="Developer ID Application: Nick Cupo (72BLQYHMTN)" NOTARY_PROFILE=AC_PASSWORD app/build.sh
```

`git status --short` should print nothing (an untracked file is left out of
the build, but read what it is). With no `SMOKE_LIBRARY` the smoke test runs
the app against an empty library it makes itself, which is enough to prove
the bundle. To also cull real photos, add `SMOKE_LIBRARY=` naming a scratch
copy of a photo library (a folder with `shoots/` in it) under `/private/tmp`,
never the repo and never `~/photos`. `AC_PASSWORD` is the notary profile
stored in this Mac's keychain. The DMG and its notices land in `dist/`.
Steps 5 to 7 below are the same thing in full, with the checks around it.

## Display branding: FirstEdit

Use **FirstEdit** in the release title and user-facing copy. The shipped bundle
is `FirstEdit.app`, its executable is `FirstEdit`, and its identifier remains
`com.nickcupo.firstedit`. On first launch, `Application Support/First Edit`
is migrated to `Application Support/FirstEdit`; photographs and saved work are
not moved or deleted. `Photo Pipeline Archive` retains its historical name.
The legacy packaging filenames and disk-image volume label are retained.
The earlier Photo Pipeline migration section below remains historical guidance.

## 0. Once, on the machine you release from

```sh
git config core.hooksPath .githooks
git config photopipeline.vocabfile /path/to/vocab.txt   # outside this repo
xcode-select -p && xcrun --show-sdk-version             # Xcode, and an SDK of 26 or newer
```

The second one is the word list the hooks scan for: the subject matter that
belongs to the private extension and not to a public repository (see
`.githooks/vocab.zsh`). Without it the hooks say the check is skipped, which is
right for a stranger's clone and wrong for yours. The key keeps the name it had
before the app was called First Edit, on purpose: the hooks and the scan read
exactly `photopipeline.vocabfile`, and a clone that set a renamed key instead
would pass every commit unchecked. `app/tools/vocabulary-scan.sh`
reads the same file, and `app/build.sh` runs that scan over every tracked file
before it builds anything and over the compiled string catalog once the app is
assembled.

The third is the toolchain. The app is a Swift package (`app/Package.swift`,
macOS 15) that uses a few macOS 26 APIs behind `#available`, so it compiles
only against an SDK of 26 or newer; `app/build.sh` also needs `actool` and
`xcstringstool`, which come with Xcode and not with the command-line tools
alone.

```sh
words=$(grep -vE '^[[:space:]]*(#|$)' "$(git config --get photopipeline.vocabfile)" | paste -sd'|' -)
```

Keep `$words` for the scans below. Every one of them prints nothing when it is
happy.

## 1. The checkout is clean

```sh
.venv/bin/python -m pytest -q tests
.venv/bin/ruff check pipeline app tests
swift test --package-path app                 # the app's own tests
STAGE=check app/build.sh                      # the gates, no build
app/tools/vocabulary-scan.sh                  # every tracked file, its name included
./pl selftest
```

`STAGE=check` reports what a public build would leave out (the symlinked
private modules), refuses a tree that has turned one of them into a real file,
checks `requirements.txt` against `app/requirements.lock`, and — when there is
an app in `build/` — says whether it is the one a gated run signed.

Static checks and a successful compile do not substitute for the tests or
the unsigned and signed app smoke checks. The standard build runs those
checks before writing the bundle fingerprint required by `STAGE=dmg`.
If the release session cannot run them, save the source and build evidence
and report the packaging constraint. Do not create or reuse a gate marker
to claim that a different bundle passed.

If the engine's routes have changed since the last release, re-capture the
fixtures the app's tests decode, against a **scratch clone** of a library and
never `~/photos`:

```sh
app/tools/capture-fixtures.sh --library /path/to/scratch/library
git status --short app/Tests/PipelineKitTests/Fixtures     # review every changed byte
swift test --package-path app
```

## 2. Nothing private is in the tree, in a name, or in a message

```sh
git ls-files -z | xargs -0 grep -inE "\b(${words})\b"       # file contents
git ls-files | tr '_' ' ' | grep -inE "\b(${words})\b"      # file names
git log --format='%H%n%B' | grep -inE "\b(${words})\b"      # every message in this history
grep -rinE "\b(${words})\b" docs/*.md README.md CHANGELOG.md CONTRIBUTING.md
```

The pre-commit and commit-msg hooks catch this a commit at a time. These four
lines are the whole history and the whole tree, which is what actually goes
public.

## 3. The public history: one commit, no ancestors

The working branch's history is yours: dozens of messages written while
thinking out loud, and some of them name the private subject matter (step 2's
third line finds them). Rewriting a published history is not a real option, so
the public repository gets a history that was never anything else.

Use the reviewed integration branch in a separate publication checkout. Check its tip before creating the release commit; do not switch a checkout another agent is using.

```sh
REL=final                                  # the branch you have actually reviewed
git log --oneline -1 "$REL"                # read it. Is this the work you mean to publish?
git describe --tags "$REL"
git ls-files "$REL" >/dev/null 2>&1; git -c core.quotepath=off ls-tree -r --name-only "$REL" | wc -l
```

```sh
git checkout --orphan public-main "$REL"   # that branch's tree and index, with no parent commit
git status --short                         # every tracked file as added, and nothing else: the symlinks stay ignored
$EDITOR release-message.txt                # one message for the whole thing, in the repo's voice
grep -inE "\b(${words})\b" release-message.txt        # silence, before it is a commit
PUBLIC_EMAIL=$(gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"')   # GitHub's private address
git -c user.email="$PUBLIC_EMAIL" commit -F release-message.txt   # the commit-msg hook scans it again
git log --format='%an <%ae> | %cn <%ce>' public-main   # the address the world will see, twice
git log --oneline public-main              # must be exactly one commit
```

The one commit carries an author and a committer address, and a published
commit keeps them for good. Every commit on the working branch is authored with
the personal address in this clone's `user.email`. The author chose, on
2026-09-24, to publish with GitHub's private address instead,
`ID+username@users.noreply.github.com`, which the `PUBLIC_EMAIL` line above
asks GitHub for. Read the line after the commit before going on: both
addresses on it must be that one, and neither the personal one.

Then prove the tree, three ways. The first is about what was swept in, the
second about what the tree IS, and the third about what is in the bytes.

```sh
git diff --stat "$REL" public-main         # must print nothing at all: the same tree, a different history

# It is the app as well as the engine. An orphan always matches its own start
# point, so the line above cannot tell you the start point was wrong; these can.
for f in app/Package.swift app/build.sh app/tools/vocabulary-scan.sh pipeline/studio.py README.md LICENSE; do
  git cat-file -e "public-main:$f" || echo "MISSING $f"
done
test "$(git ls-tree -r --name-only public-main | grep -c '^app/Sources/')" -gt 50 || echo "the app's sources are not in this tree"

git ls-tree -r --name-only public-main | grep -E 'pipeline/(reel|spread)\.py|^docs/ml/|^NOTICES\.md|^app/main\.swift'   # must print nothing
git ls-tree -r public-main | grep -v '^100644\|^100755' # must print nothing: no symlink (120000) in the tree
git ls-tree -r --name-only public-main | tr '_' ' ' | grep -inE "\b(${words})\b"   # every name in the tree
git archive public-main | tar -x -O | grep -inE "\b(${words})\b" | head   # every byte of the tree
git archive public-main | tar -x -O | grep -noE '/Users/[A-Za-z0-9._-]+' | grep -vE '/Users/(someone|somebody|photographer|you|your-name|x)$' | head
```

`git checkout --orphan <new> <start>` takes the index and the tree from the
branch you have already reviewed, so nothing untracked can be swept in and
nothing tracked can be left out. The last four lines are the point of the whole
step: the scan is over the **tree**, not over a diff, because a diff only shows
what changed and this commit is everything. Never `git add -A` here.

### Existing repository

The existing repository was renamed to `nickcupo/first-edit` and made public on
2026-09-24 with the owner's approval. Main contains one reviewed root commit.
Replacing a branch does not erase old objects from GitHub caches, forks or
clones; the owner accepted retaining the existing repository. This is not a
claim that historical objects were purged.

When replacing the public commit, first read the remote main SHA and use an
explicit `--force-with-lease=main:<observed-sha>`. Keep release tags on the
reviewed public tree, never the working branch's history. Confirm the remote
branches and tags after publication.

## 4. Repository metadata and release notes

Review the GitHub description, homepage, release notes and assets separately
from the source scan. They are not checked by commit hooks. The owner has
approved the existing homepage URL. Publish only public build artifacts;
private installers and personal learned models do not belong in a public
release.

## 5. Version, changelog, tag

`git describe --tags` is where the build gets its version, so the tag comes
first and the build second. A notarized build refuses a version that is not a
plain tag.

```sh
$EDITOR CHANGELOG.md                       # a section for this version, in the voice of the others
grep -inE "\b(${words})\b" CHANGELOG.md    # silence
git tag v0.1.5                             # on the commit that is going out
```

Version 0.1.4 is the previous published release. Keep `CHANGELOG.md`,
`docs/ROADMAP.md` and the release notes consistent with the artifact actually
published.

## 6. Build, sign, notarize

### First, only when the OpenCV wheels have changed

The bundle does not install OpenCV from PyPI. The published
`opencv-python-headless` and `opencv-contrib-python` wheels carry their own
FFmpeg, configured `--enable-gpl` and linked against libx264, libx265,
libbluray, librubberband, libvidstab and libopencore-amr, all
GPL-2.0-or-later, through load commands in `cv2.abi3.so` that make them
unremovable. `app/build.sh` refuses a bundle with any of them in it; with
`ALLOW_COPYLEFT=1` it builds, but the DMG is named `-local` and notarization
is refused. **With the PyPI wheels there is no notarized public release.**
`app/tools/build-opencv.sh` builds the same version of both packages from
source with `-DWITH_FFMPEG=OFF`, and `app/requirements.lock` names the two
wheels it makes by URL and by SHA-256.

An ordinary release does not run it: the wheels are published as a release
asset of their own and `app/build.sh` fetches them by hash. Run it when the
OpenCV pin in `requirements.txt` moves, when the bundled interpreter or the
minimum macOS changes, or the first time on a machine that has never had
them. It needs `cmake` and takes 40 to 90 minutes.

**Order matters here, and it is not obvious.** `gh release create` with no
`--target` makes its tag point at the remote default branch's HEAD. On the
renamed repository that is the OLD history until step 7's first line has run,
and publishing the wheels first would leave every one of those commits
reachable from a tag in a repository that is about to be public, which step 3
exists precisely to prevent; on a new, empty one there is no branch for the
tag to point at. So: push the squashed history first (step 7's first line),
then create this release on `first-edit`, and pass `--target main` so the tag
is pinned to the commit you meant rather than to whatever HEAD happened to be.
The `opencv-5.0.0.93-nogpl` release was published on 2026-09-24. Its two
assets match the locked hashes. Existing builds can download them; rebuilding
the wheels is needed only when their version or configuration changes. They
are installed inside the app bundle, so people using the DMG need no separate
OpenCV download.

```sh
app/tools/build-opencv.sh /path/to/wheels     # outside this repo; prints each SHA-256
gh release create opencv-5.0.0.93-nogpl /path/to/wheels/*.whl -R nickcupo/first-edit --target main \
  --title 'OpenCV 5.0.0.93, built without FFmpeg' --notes-file opencv-notes.md
$EDITOR app/requirements.lock                 # the two `name @ https://…` lines and their hashes
STAGE=lock app/build.sh                       # keeps those two, rewrites the rest from pip
OPENCV_WHEELHOUSE=/path/to/wheels STAGE=check app/build.sh
```

Those two lines are the only ones in `app/requirements.lock` that are not
pip's answer, and `STAGE=lock` keeps them rather than resolving them back to
PyPI; it refuses if the version behind the URL and the version
`requirements.txt` asks for have parted. Until the asset is actually
published, `OPENCV_WHEELHOUSE=` points the build at the folder the script
wrote — the SHA-256 in the lock still has to match, so the wheel you tested is
the wheel that goes in the DMG. `requirements.txt`, which is what a checkout's
`.venv` installs, keeps the PyPI wheels: a developer venv is handed to nobody.

Prove a new wheel before you publish it: run the tests against it, then cull a
shoot with the old wheel and with the new one on a **scratch clone** of a
library and diff `cull.csv` byte for byte.

```sh
SMOKE_LIBRARY=/path/to/scratch/library \
IDENTITY="Developer ID Application: … (TEAMID)" NOTARY_PROFILE=first-edit app/build.sh
```

That is the public build: the default. In order it checks the tree and the
vocabulary, installs the wheels **by SHA-256** from `app/requirements.lock`,
fetches the models and exiftool, runs `swift test`, builds the package release
for arm64, assembles the bundle (interpreter, pipeline, models, exiftool, the
compiled string catalog, the compiled icon, `Info.plist`, the binary), writes
`NOTICES.md` from the bundle itself, runs every gate on the assembled app,
runs the smoke test, signs every Mach-O and then the app, runs the smoke test
again on the signed app — the hardened runtime refusing the bundled
interpreter is a failure that exists only after signing — records
`build/gate.json`, and notarizes and staples the DMG.

`SMOKE_LIBRARY` must name a **local clone under `/private/tmp`**. Symbolic
links, hard-linked files and dataless files are refused before the engine starts.
With a populated clone the smoke script also fetches a thumb, a `/full` and a
`/crop` from every culled shoot and checks each bitmap. Without a library,
`app/build.sh` creates an empty temporary one; this does not prove photo decoding.

Release smoke is now offscreen. `app/tools/smoke.sh --offscreen` runs both
`FirstEdit --check --smoke-offscreen` and `FirstEdit --smoke-offscreen`. The latter
hosts the real `RootView` and real engine in a window pinned at (-30000, -30000),
using SnapshotHarness's unconstrained, non-key/non-main window technique. It
sets activation policy to prohibited before launch, never starts the SwiftUI App
scenes, and disables frame restoration. No desktop window or Dock activation is
requested. It still requires drawn AppKit sidebar rows, navigation of every shoot
through the real window title, real engine PIDs and confirmed shutdown. The
legacy `--smoke` command remains visible and is not used by release packaging.

The script creates fresh state under `/private/tmp/first-edit-smoke.*`, discards
inherited engine overrides, sets a scratch CF preferences home and caches, and
uses in-memory app settings. It bypasses migrations, notification setup, and
external-display restoration; it does not bypass engine, RootView, sidebar,
navigation or shutdown checks. State/log paths are printed and retained for
inspection. An old binary lacking the offscreen entry point is refused before
execution, because unknown flags previously opened the ordinary app.

Unsigned and signed smoke checks still run in their original build stages.
Missing smoke tooling or failed checks block signing/packaging. The exact-bundle
`gate.json` is still written only after the signed app's smoke succeeds. Static
checks, compilation, or an offscreen probe alone are not full release validation.

`PRIVATE_BUILD=1` is your own copy — it carries the symlinked private modules,
is named `-private`, and notarizing it is refused.

Check what came out:

```sh
ls dist/                                   # First-Edit-0.1.5.dmg and its NOTICES
codesign --verify --deep --strict --verbose=2 "build/FirstEdit.app"
codesign -dv --verbose=4 "build/FirstEdit.app" 2>&1 | grep -E 'Authority|flags|Identifier'
xcrun stapler validate dist/First-Edit-0.1.5.dmg
spctl --assess --type open --context context:primary-signature -v dist/First-Edit-0.1.5.dmg
hdiutil attach dist/First-Edit-0.1.5.dmg -nobrowse   # then open the app from the image once, and quit it
```

And the two questions a person actually asks of a bundle:

```sh
/usr/libexec/PlistBuddy -c 'Print :PhotoPipelineBuild' "build/FirstEdit.app/Contents/Info.plist"   # public
find "build/FirstEdit.app" -name 'reel.py' -o -name 'spread.py'   # nothing
```

Install it over the previous version on a second Mac if there is one: the
update path (`pipeline/update.py`) is the part no test can prove.

## 7. Publish

The push of `main` comes FIRST. Every tag and every release created before it
points into whatever history was there, and a tag is a reference: it keeps
those commits reachable after the branch no longer does.

```sh
git push public public-main:main           # the renamed repository needs --force-with-lease here
git push public v0.1.5                     # this one tag, never --tags
gh release create v0.1.5 dist/First-Edit-0.1.5.dmg dist/First-Edit-0.1.5-NOTICES.md \
  -R nickcupo/first-edit --target main --notes-file release-notes.md   # scanned with step 2's regex first
```

On the renamed repository the tags already there were made on the old history.
Before it is public, delete them (`git push --delete public v0.1.2 v0.1.3`, and
`gh release delete` for anything published against them) or re-point them at
commits that exist in the new one; a tag left behind is the whole of step 3
undone, since `git log v0.1.2` would read every message it was written to keep
private. A new repository has none, and holds only what is pushed to it by
name, which is why the tag above is pushed alone.

That first line is the irreversible one, and it goes when steps 2 to 4 have
all been silent. Never push the working branch to `public`. Its history is the
one step 3 exists to replace.

## 8. After

- `gh repo view nickcupo/first-edit --json visibility` — flipping it to
  public is done in the web interface, deliberately, after step 4's scans and,
  for the renamed repository, after GitHub has said the purge is done.
- The app on your own Mac checks the releases page at launch. A copy you built
  yourself with `PRIVATE_BUILD=1` can be replaced by the public one, which has
  no reel or spread step: rebuild it after updating, or keep your own build
  outside `/Applications`.
- Keep `dist/` — a `-private` or `-local` DMG in there is not for anyone else,
  and the suffix is the only thing saying so.

## Once: from Photo Pipeline to First Edit

The app was called Photo Pipeline until 2026-09-23. These steps happen once,
by hand, and none of them is automated.

- **The repository.** Every coordinate in the tree (`pipeline/update.py`,
  `app/requirements.lock`, the Report an Issue link, `SECURITY.md`) names
  `nickcupo/first-edit`. On 2026-09-24 the author chose the second way below:
  the private `nickcupo/photo-pipeline` was renamed to `nickcupo/first-edit`
  and its `main` replaced by the one commit, so it stays private until GitHub
  has purged the old objects. Step 3 is the choice of what `first-edit` is — a new repository that never
  held the old objects, or the old one renamed and purged — because a rename
  alone serves every old object under the new name. Until it exists, a build
  that fetches the OpenCV wheels by URL fails the fetch, and
  `OPENCV_WHEELHOUSE=` builds from the local folder instead. If it is the
  renamed one, GitHub sends clones, fetches, issues and API requests for the
  old name to the new one; never create another repository called
  `photo-pipeline` under this account then, which ends that redirect. Nothing
  here relies on it.
- **Point your checkout at it** with the `public` remote of step 3. `origin`
  stays where the working history is. The folder on disk keeps its name: the
  checkout, `photo-pipeline-extension` beside it and the private repo find one
  another by folder name, and the venv's scripts have the path written into
  them.
- **The notary profile** is `first-edit` in the lines above. A profile already
  stored under another label keeps working if `NOTARY_PROFILE` names that
  label. It is only the name of a keychain item.
- **The first First Edit build is installed by hand, after a backup.** The
  updater refuses an app whose bundle identifier differs from the running
  one's, and the identifier went from `com.nickcupo.photo-pipeline` to
  `com.nickcupo.firstedit`, so Photo Pipeline's Check for Updates cannot
  install it. In this order:
  1. Make a Time Machine backup, or check that one has finished since Photo
     Pipeline last ran. The first launch renames the support folder that
     holds the models and everything learned; `MIGRATED.json` says how to
     put it back, and the backup is for whatever that does not foresee.
  2. Quit Photo Pipeline.
  3. Run `ditto` to copy the app to `/Applications/First Edit
     (installing).app`, run `codesign --verify --deep --strict` on it, and
     rename it to `FirstEdit.app`.
  4. Keep `Photo Pipeline.app`, out of `/Applications` and out of the Trash:
     `~/Applications/Photo Pipeline (old).app`, for example. It is the undo,
     and the last step in `MIGRATED.json` is to open it. Leave its settings
     as they are, "Check for updates automatically" included: First Edit
     copies them on its first launch, so a switch turned off there comes
     across off. If it is ever opened again and its update check reaches
     First Edit's release, as it would through a renamed repository's
     redirect, it offers it and cannot install it (the bundle identifier
     again), so leave the offer alone.
  5. Open First Edit. On its first launch it renames the support folder and
     copies the old settings, as the README says. Never have both open at
     once: they share one folder, and First Edit says so if Photo Pipeline
     is opened while it runs.

  From then on the identifier never changes again: every later release is
  checked against `com.nickcupo.firstedit`. Once First Edit has run cleanly
  for a while, the kept copy of Photo Pipeline can go.
- **What keeps the old name on purpose:** the archive folder in iCloud Drive
  (`Photo Pipeline Archive`, which locates every archived RAW), the git config
  key `photopipeline.vocabfile` (step 0), `PipelineKit`, `pipeline/`, `./pl`,
  the `PIPELINE_*` variables and the extension bridge (`window.pipeline`,
  `pipeline-ext://`). The extension contract is public, and renaming it breaks
  every extension's pages.

## Why the app is not sandboxed

There is no `com.apple.security.app-sandbox` in `app/Resources/entitlements.plist`
and there cannot be one. The app's whole job is to start the CPython it ships
and hand it a folder of RAW files: a sandboxed app may not execute another
interpreter out of its own bundle with the entitlements that interpreter needs
(`cs.allow-unsigned-executable-memory` and `cs.disable-library-validation`,
which torch and the bundled extension modules require), and the library it
works on is an arbitrary folder the person picks, read and written by a child
process that has no way to inherit a security-scoped bookmark.

What it has instead: the hardened runtime, a Developer ID signature,
notarization, a Python child that listens on 127.0.0.1 only and answers
nothing without the per-launch key, and a bundle nothing writes into. The
consequence is that this app can never go in the Mac App Store, which is not
where it was going.

## What CI does and does not do

`.github/workflows/check.yml` runs three jobs on every push. The first
compiles and lints the Python and parses every shell script, including the
hooks. The second runs `pytest` on Linux, with the learned folder pointed at
the runner's temp directory so nothing of a model's reaches the checkout, and
with the one test that renders every sidecar on the machine it runs on
deselected. The third, on macOS, refuses a runner whose SDK is older than 26,
builds the package release for arm64, runs `swift test`, compiles the string
catalog and the icon the way `app/build.sh` compiles them, and runs
`STAGE=check app/build.sh` — the gates that need no interpreter and no bundle.
It does **not** run the rest of `app/build.sh`: a release downloads an
interpreter and five models, signs and notarizes, and is a thing a person does
on purpose.

If that ever changes, the checkout needs `fetch-depth: 0` and its tags. Without
them `git describe --tags` quietly fails, the version falls back to
`0.1.0-<sha>`, and every installed copy stops seeing updates because
`update.py` compares version tuples.
