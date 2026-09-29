# Burstpack

A burst's RAWs kept as the keeper and how the others differ. Lossless: what
`unpack` writes is the file that was packed, every byte, with its modified
time. It ships with the engine like every other module in `pipeline/`.

On Finish, **Copy to iCloud…** asks which form: *RAW files*, or *Packed,
about half the size*. Packed packs each burst the copy is about to send into
`packed/burst-<n>.fbp` in the shoot (a frame in no burst into
`packed/frame-<name>.fbp`), checks it, and sends those files instead of the
ARWs. From a terminal:

    ./pl archive push <shoot> --as packed [--apply]      what Copy to iCloud, Packed, does
    ./pl burstpack shoot <shoot> [--apply]               only the packing, into packed/
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

Packing packs several bursts at once, one burst to a process, on three
quarters of the cores and no more than the memory holds (about 48 bytes a
pixel each).

Measured on the five HDR+ bursts above (12 MP), in a 4-core Linux container:

| | numpy | C |
|---|---|---|
| pack a frame alone | ~13 s | 1.1 s |
| pack a frame from its neighbour | ~16 s | 2.8 s |
| unpack a frame | ~8 s | 1.3 s |
| the 25 frames, packed and checked | ~10 min (est.) | 117 s on one core, 41 s on three |

A 24 MP frame is about twice the work. An Apple silicon core is faster than
this container's, and has more of them beside it; that has not been measured.

## In iCloud

A packed burst is a second form a frame's copy in iCloud can take, beside its
ARW (`archive.py`, "packed bursts"). The storage panel on Finish, top to bottom:

- **Copy to iCloud…**, *RAW files* or *Packed*. Packed packs what is to go,
  unpacks each file in memory and matches every frame to its RAW here, copies
  it to `packed/` in the shoot's archive folder and reads the copy back. A
  burst that does not match goes up as its ARWs. A frame already up in either
  form is not sent again. `archive.json` records each file's checksum and
  each frame's.
- **Bring Back from iCloud…** puts the RAWs back whichever form is up there:
  a packed frame is unpacked from the shoot's own `packed/` when that file is
  the one recorded, else from the copy in iCloud, and checked before it takes
  the RAW's name.
- **Unpack to a Folder…**, beside it, asks for a folder and unpacks every
  frame of the shoot's packed bursts - from `packed/`, or from iCloud - into
  it as the RAW it was, with its name and time (`burstpack.py export`). It
  never writes over a file, and changes nothing in the shoot or in iCloud.
- **Check the Packed Bursts**, shown once a shoot has packed bursts, unpacks
  each in memory and checks every frame against its checksum and the RAW on
  this Mac. It reads only.
- **Remove from This Mac…** takes a RAW on the strength of its packed copy
  only when that copy is in iCloud, downloaded, vouched for by iCloud, matches
  its record, and unpacks - that very copy - to the exact bytes of the RAW
  about to be removed. It also takes the shoot's own packed bursts whose
  identical file is up there. Every other rule of drop still applies.
- **Remove Copies from iCloud…**, *RAW copies*, *Packed copies* or *Both*
  (`archive.py trim`), removes a copy up there only when this Mac holds every
  frame in it as its RAW, the same bytes, checked again just before the copy
  goes. No frame is left without a copy.
- **Let Go of the RAWs in iCloud…** never touches a packed burst, and keeps
  their record when it rewrites `archive.json` (it used to rewrite the file
  from its ARW records alone).

## Not done

- The panel's "in iCloud" size counts a packed frame at its RAW's size.
- Uncompressed ARW and DNG are only xz'd.
