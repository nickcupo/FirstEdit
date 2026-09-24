# Security

## Reporting something

Open a [private security advisory](https://github.com/nickcupo/first-edit/security/advisories/new),
or a normal issue if it is not sensitive. This is a one-person project: expect a
reply in days, not hours. Please say what you did, what happened, and which
version (the app's About box, or `git describe --tags`).

## What the app is, in ten lines

1. It is a local program. The only things it fetches are the model weights, the
   CLIP weights from Hugging Face, and its own updates from this repository's
   releases page. Nothing about your photographs leaves the machine.
2. The engine behind the app is an HTTP server bound to 127.0.0.1 on a port
   of its own, chosen at launch.
3. Anything else on the same Mac can reach that port, so every request must
   carry a secret made at launch — 32 random bytes, handed to the engine in
   `PIPELINE_STUDIO_KEY` — as an `X-Studio-Key` header, or in the cookie an
   extension's own port sets for the pages it serves, and the server checks
   the Host and Origin headers as well. Without that, any page you have open
   could post to `/api/cull`. `GET /` is the one address that answers without
   the key, and it hands out nothing: a few sentences saying to open the app.
   An extension's own page is loaded through a scheme handler inside the app
   for the same reason: the app can then put the header on the page's
   subresources, which a page loaded over `http://` cannot do for itself.
4. The endpoints act on the folders you point the pipeline at, as you. The
   destructive ones (`archive drop`, `archive expire`, `reclaim`) ask for a
   confirmation that names what will go, and carry a token from the list you
   were shown, so a list that changed underneath is refused rather than
   applied. None of the three may be left on the list of work, because a
   confirmation held for an hour is a confirmation of something nobody
   measured.
5. The Mac app runs the bundled Python with a `PATH` of system folders only.
6. Updates: the DMG must be signed and notarized by the same Apple Team ID as
   the copy asking for it, it is downloaded over https from GitHub at every hop
   of the redirect, and `spctl` has to accept both the disk image and the app
   inside it. Anything that fails is deleted, not kept (`pipeline/update.py`).
   No release has been published yet, so there is nothing for this to find.
7. The model weights are pinned by SHA-256 in `pipeline/models.json` and a file
   that does not hash correctly is deleted rather than used.
8. The app is signed with a hardened runtime. It has the entitlements a bundled
   CPython and torch need (unsigned executable memory, library validation off),
   which is what lets it load its own wheels.
9. Nothing here asks for a password, a keychain item or a token, and nothing is
   ever uploaded.
10. Third-party code in the app is listed in the `NOTICES.md` inside the
    bundle and beside each release, generated from the bundle itself at
    build time. It is not a file in this repository.

## Not in scope

Anything that needs an attacker already running code as you on your Mac. At
that point they can read the photographs directly.
