# Burstpack

A burst's RAWs kept as the keeper and how the others differ. Lossless: what
`unpack` writes is the file that was packed, every byte, with its modified
time. It ships with the engine like every other module in `pipeline/`.

On Finish, the storage panel's **Pack Bursts…** shows which bursts would be
packed, and packs them when confirmed: each into `packed/burst-<n>.fbp` in the
shoot folder, with a progress bar and Stop like any storage job. Nothing is
removed; the RAWs stay in `raw/`. The same thing from a terminal:

    ./pl burstpack shoot <shoot> [--apply]               what Pack Bursts… does
    ./pl burstpack bench <shoot> [--bursts N]             what it would save. Writes nothing
    ./pl burstpack pack <out.fbp> <raw>... [--key NAME]   pack, then prove it unpacks
    ./pl burstpack unpack <archive.fbp> <dir> [NAME...]   put the RAWs back; refuses to overwrite
    ./pl burstpack verify <archive.fbp>                   unpack in memory, check every SHA-256
    ./pl burstpack list <archive.fbp>                     what each frame cost

`bench` groups frames by the cull's `burst` column, takes the frame you kept
from each burst (`selects.json`) as the one stored whole, and skips any RAW
whose bytes are not on this Mac.

## How

Built for Sony compressed ARW (cRAW, the a6500's "Compressed"). Each 128-bit
block of the sensor data splits exactly into max, min, the positions of both
and fourteen 7-bit steps, so any block round-trips, even a malformed one.
Each field is predicted and only the surprise is coded:

- each pixel from its decoded same-colour neighbours and, for a frame with a
  reference, from the neighbouring frame after per-tile motion (block
  matching, 128-pixel tiles), through a 3x3 window of the reference so part
  of a pixel of shake is absorbed by the weights
- weights fitted by least squares per tile and colour on the frame itself,
  stored as integers
- min and max from the predicted pixels; the extremes' positions as a rank;
  each step re-expressed in its block's min and shift, in contexts of how
  wrong the prediction just was and how much room the block leaves
- rANS coding against tables counted on the frame and stored with it

The decoder uses integers only, so it cannot come out differently on another
Mac or numpy. Frames reference their neighbour on the way to the keeper:
restoring the keeper decodes one frame. Anything it cannot model (DNG,
uncompressed ARW) is stored with xz.

## Measured

No a6500 files were available when this was written. The numbers are five
real hand-held bursts from Google's HDR+ dataset (Pixel sensor, 12 MP, 5
frames each, 310 MB), their sensor data put into Sony's cRAW block format by
the tests' encoder (`tests/burstpack_hdrplus.py` reproduces them).

| Burst | xz -9 | each frame alone | whole burst |
|---|---|---|---|
| 0006 | 57.7% | 44.3% | 40.4% |
| 0047 | 54.2% | 41.5% | 40.2% |
| 0382 | 86.7% | 67.8% | 66.2% |
| 0919 | 89.2% | 71.7% | 63.6% |
| 33TJ | 81.9% | 65.9% | 64.8% |
| **All** | **74.0%** | **58.3%** | **55.1%** |

Most of the saving comes from modelling cRAW. Using the neighbour adds 1 to
11 points: each frame's sensor noise is new information that no lossless
method can predict, and on these dark bursts the codec is within about 0.1
bit per pixel of that noise floor. Brighter base-ISO frames should gain more
from the neighbour; `bench` on a real shoot is the measurement that says.

## Speed

The inner loop, the rANS coder, the weight fit's sums and the motion search
are in C (`pipeline/burstcore.c`). The format is the numpy code's: the tests
pack with both and require the same bytes, and either unpacks what the other
packed. `app/build.sh` builds the library into the app and stops if the
bundle's Python cannot load it; a checkout builds it on first use into the
support folder. Without a compiler, or with `BURSTPACK_PURE=1`, the numpy
code runs instead, identically and about five times slower.

Pack Bursts packs several bursts at once, one burst to a process, on three
quarters of the cores and no more than the memory holds (about 48 bytes a
pixel each).

Measured on the five HDR+ bursts above (12 MP), in a 4-core Linux container:

| | numpy | C |
|---|---|---|
| pack a frame alone | ~13 s | 1.1 s |
| pack a frame from its neighbour | ~16 s | 2.8 s |
| unpack a frame | ~8 s | 1.3 s |
| the 25 frames, packed and checked, from Pack Bursts | ~10 min (est.) | 117 s on one core, 41 s on three |

A 24 MP frame is about twice the work. An Apple silicon core is faster than
this container's, and has more of them beside it; that has not been measured.

## In iCloud

A packed burst is a second form a frame's copy in iCloud can take, beside its
ARW (`archive.py`, "packed bursts"):

- **Copy the RAWs to iCloud** sends a shoot's packed bursts in place of their
  frames' ARWs, to `packed/` in the shoot's archive folder. Each is unpacked
  in memory and every frame matched to the RAW on this Mac before it is
  copied, and the copy is read back. A burst that does not match goes up as
  its ARWs instead. `archive.json` records each file's checksum and each
  frame's.
- **Remove the Local RAWs** takes a frame on the strength of its packed copy
  only when that copy is in iCloud, downloaded, vouched for by iCloud, matches
  its record, and unpacks - that very copy - to the exact bytes of the RAW
  about to be removed. Every other rule of drop still applies.
- **Bring the RAWs Back** unpacks a frame from the shoot's own `packed/` when
  that file is the one recorded, else from the copy in iCloud, and checks it
  before it takes the RAW's name.
- **Check the Packed Bursts** unpacks every packed burst in memory and checks
  each frame against its checksum and the RAW on this Mac. It reads only.
- **Let Go of the RAWs in iCloud** never touches a packed burst.

## Not done

- The panel's "in iCloud" size counts a packed frame at its RAW's size.
- Uncompressed ARW and DNG are only xz'd.
