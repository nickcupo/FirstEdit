#!/usr/bin/env python3
"""
burstpack.py - a burst of RAWs kept as one frame and how the others differ.

    ./pl burstpack pack <out.roll> <raw>... [--key NAME]   pack a burst, then prove it unpacks
    ./pl burstpack unpack <archive.roll> <dir> [NAME...]   put the RAWs back, byte for byte
    ./pl burstpack export <shoot> <dir>                   every packed burst of a shoot, as RAWs, into <dir>
    ./pl burstpack verify <archive.roll>                   unpack in memory and check every checksum
    ./pl burstpack list <archive.roll>                     what is inside, and what each frame cost
    ./pl burstpack shoot <shoot> [--apply]                every burst into <shoot>/packed/; the Finish page's Pack Bursts
    ./pl burstpack bench <shoot> [--bursts N]             what it would save on a shoot. Writes nothing

A burst is ten frames of one moment. They share almost every pixel, and a file
compressor cannot use that: it sees each ARW on its own, and a Sony compressed
ARW is already packed tight enough that zstd or xz get a few percent at best.

This keeps one frame of a burst whole - the keeper, when one is named - and
every other frame as its difference from the frame next to it on the way back
to the keeper. Losslessly: what comes out of `unpack` is the file that went
in, every byte, and `pack` does not report success until it has unpacked the
whole archive in memory and matched every frame's SHA-256.

HOW
---
The sensor data of a compressed ARW (Sony's "cRAW", ARW 2.3) is 128-bit
blocks, each holding 16 same-colour pixels of one row: an 11-bit max and min,
the 4-bit positions of both, and fourteen 7-bit steps above the min, scaled by
a shift that depends on the block's range. Those 128 bits split into
(max, min, imax, imin, 14 steps) with no bit left over, so ANY block
round-trips through its fields, even one that does not follow the rules.

Each field is then predicted and only the surprise is coded:

  - every pixel is predicted from its same-colour neighbours already decoded
    (left, up, up-left, up-right) and, for a frame that has a reference, from
    the reference frame at the same place after motion is taken out: one
    integer (dy, dx) per tile, found by block matching, and a 3x3 same-colour
    window of the reference around it, so a fraction of a pixel of shake is
    absorbed by the weights rather than by a resampling
  - the weights are fitted by least squares for each tile and colour, on the
    frame being packed, and stored in it as integers. The frame is its own
    training set; nothing learned leaves the archive
  - a block's min and max are predicted from the predicted pixels, its imax
    and imin as a rank among them, and each step as the predicted pixel
    re-expressed in that block's own min and shift
  - what is left is coded with rANS against frequency tables counted on the
    frame itself and stored with it, in contexts chosen by how wrong the
    prediction has just been nearby

WHY INTEGERS
------------
An archive has to open on a Mac that does not exist yet, with a numpy that
does not exist yet. The decoder uses no floating point at all: predictions
are fixed-point sums with stored integer weights, the coder is integer rANS,
and the tables are stored rather than rebuilt. Floating point appears only in
the encoder, to fit weights and find motion, and whatever it decides is
written down as integers before anything depends on it.

Any file this cannot model - a DNG, an uncompressed ARW, anything whose
TIFF structure it does not recognise - is stored with lzma instead. It is
never refused and never guessed at; it is only compressed less.

WHAT IT WILL NOT DO
-------------------
  - delete, move or rename anything. It reads RAWs and writes an archive, or
    reads an archive and writes RAWs into an empty place. Wiring it into
    `./pl archive` so that a packed burst may stand in for its originals is a
    separate change, and a decision for its owner.
  - trust itself. `pack` unpacks every frame and compares checksums before it
    renames the archive into place; `unpack` checks every frame it writes
    against the checksum recorded when it was packed, and writes nothing
    under the final name that does not match.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import lzma
import os
import struct
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

MAGIC = b"FEBURST\x01"
# A roll: one burst, as a roll of film holds one run of frames. The name is
# only the name; what a file is is the MAGIC at its head.
EXT = ".roll"
VERSION = 1

# ------------------------------------------------------------------- rANS
#
# Interleaved rANS over numpy lanes. One lane per block of a row pair: the
# decoder handles a whole row pair's blocks at once, which is what makes
# a pure-numpy decoder fast enough to be useful, and every lane's words are
# interleaved into a single stream in the order the decoder will want them.
#
# 32-bit state, 16-bit renormalisation, 14-bit probabilities. A symbol with
# frequency f and cumulative c:  encode  x -> (x // f) << 14 | (x % f) + c
#                                 decode  x -> f * (x >> 14) + (x & mask) - c

PREC = 14
PMASK = (1 << PREC) - 1
RANS_L = 1 << 16
U64 = np.uint64


@dataclass
class Tables:
    """A frequency table per context for one kind of symbol."""
    freq: np.ndarray                      # (nctx, nsym) uint64, each row sums to 2**PREC or is all zero
    cum: np.ndarray = field(init=False)
    _lookup: np.ndarray | None = field(default=None, init=False, repr=False)

    def __post_init__(self):
        self.freq = self.freq.astype(U64)
        self.cum = np.zeros_like(self.freq)
        self.cum[:, 1:] = np.cumsum(self.freq, axis=1)[:, :-1]

    @property
    def lookup(self) -> np.ndarray:
        """slot -> symbol for each context; built the first time a decoder asks."""
        if self._lookup is None:
            nctx, nsym = self.freq.shape
            lk = np.zeros((nctx, 1 << PREC), np.int32)
            for c in range(nctx):
                if self.freq[c].sum():
                    lk[c] = np.repeat(np.arange(nsym, dtype=np.int32), self.freq[c].astype(np.int64))
            self._lookup = lk
        return self._lookup

    @classmethod
    def from_counts(cls, counts: np.ndarray) -> "Tables":
        """Quantise counts to 2**PREC per context. Every symbol that occurred keeps
        at least 1, so everything counted can be coded; a symbol that never
        occurred gets 0, because the tables are counted on the very symbols
        they will code."""
        counts = np.asarray(counts, np.int64)
        freq = np.zeros_like(counts)
        total = 1 << PREC
        for c in range(counts.shape[0]):
            row = counts[c]
            n = int(row.sum())
            if not n:
                continue
            f = row * total // n
            f[(row > 0) & (f == 0)] = 1
            diff = total - int(f.sum())
            order = np.argsort(-f, kind="stable")
            i = 0
            while diff < 0:
                j = order[i % len(order)]
                take = min(-diff, int(f[j]) - 1)
                f[j] -= take
                diff += take
                i += 1
            f[order[0]] += diff
            freq[c] = f
        return cls(freq)


class Recorder:
    """The encoder's side of a model run: it knows every symbol already, so it
    writes each one down, with the context it was coded in, for the tables and
    the rANS pass that follow."""

    def __init__(self):
        self.events: list[tuple] = []

    def sym(self, kind: str, ctx: np.ndarray, value: np.ndarray) -> np.ndarray:
        self.events.append((kind, ctx.astype(np.int64), value.astype(np.int64)))
        return value

    def bits(self, nbits: np.ndarray, value: np.ndarray) -> np.ndarray:
        self.events.append((None, nbits.astype(np.int64), value.astype(np.int64)))
        return value

    def counts(self, kinds: dict[str, tuple[int, int]]) -> dict[str, np.ndarray]:
        out = {k: np.zeros(shape, np.int64) for k, shape in kinds.items()}
        for kind, ctx, v in self.events:
            if kind is not None:
                nctx, nsym = kinds[kind]
                out[kind] += np.bincount(ctx * nsym + v, minlength=nctx * nsym).reshape(nctx, nsym)
        return out


def rans_encode(events: list[tuple], tables: dict[str, Tables], lanes: int) -> tuple[np.ndarray, np.ndarray]:
    """(final states, word stream). Events are encoded last first, as rANS must be,
    and the words come out in the order the decoder will read them."""
    x = np.full(lanes, RANS_L, U64)
    out: list[np.ndarray] = []
    for kind, a, v in reversed(events):
        n = len(v)
        if kind is None:
            sh = (PREC - a).astype(U64)
            f = np.left_shift(np.ones(n, U64), sh)
            c = np.left_shift(v.astype(U64), sh)
        else:
            t = tables[kind]
            f = t.freq[a, v]
            c = t.cum[a, v]
        if (f == 0).any():
            raise AssertionError(f"burstpack: a {kind} symbol has no probability")
        xs = x[:n]
        m = xs >= np.left_shift(f, U64(18))
        if m.any():
            out.append((xs[m] & U64(0xFFFF)).astype(np.uint16))
            xs[m] >>= U64(16)
        xs[:] = ((xs // f) << U64(PREC)) + xs % f + c
    words = np.concatenate(out[::-1]) if out else np.zeros(0, np.uint16)
    return x.astype(np.uint32), words


class Decoder:
    """The decoder's side of a model run: the same calls as Recorder, answered
    from the stream."""

    def __init__(self, states: np.ndarray, words: np.ndarray, tables: dict[str, Tables]):
        self.x = states.astype(U64)
        self.w = words.astype(U64)
        self.p = 0
        self.tables = tables

    def _advance(self, n: int, f: np.ndarray, c: np.ndarray, slot: np.ndarray) -> None:
        xs = self.x[:n]
        xs[:] = f * (xs >> U64(PREC)) + slot - c
        m = xs < U64(RANS_L)
        k = int(m.sum())
        if k:
            if self.p + k > len(self.w):
                raise ValueError("burstpack: the stream ends early")
            xs[m] = (xs[m] << U64(16)) | self.w[self.p:self.p + k]
            self.p += k

    def sym(self, kind: str, ctx: np.ndarray, value=None) -> np.ndarray:
        n = len(ctx)
        t = self.tables[kind]
        slot = self.x[:n] & U64(PMASK)
        s = t.lookup[ctx, slot.astype(np.int64)].astype(np.int64)
        f = t.freq[ctx, s]
        if (f == 0).any():
            raise ValueError("burstpack: the stream names a symbol its table does not have")
        self._advance(n, f, t.cum[ctx, s], slot)
        return s

    def bits(self, nbits: np.ndarray, value=None) -> np.ndarray:
        n = len(nbits)
        sh = (PREC - nbits).astype(U64)
        slot = self.x[:n] & U64(PMASK)
        v = slot >> sh
        self._advance(n, np.left_shift(np.ones(n, U64), sh), v << sh, slot)
        return v.astype(np.int64)

    def done(self) -> bool:
        return self.p == len(self.w) and bool((self.x == U64(RANS_L)).all())


DIRECT = 32          # below this a header residual is its own symbol


def _bitlen(z: np.ndarray) -> np.ndarray:
    """Bit length without floating point."""
    n = np.zeros_like(z)
    for b in range(24):
        n += (z >> b) > 0
    return n


def _code_int(coder, kind: str, ctx: np.ndarray, value: np.ndarray | None) -> np.ndarray:
    """A signed integer of any size: zigzagged, small ones as their own symbol,
    larger ones as a bit length from the table and the bits under the top one
    sent as they are."""
    top = _bitlen(np.int64(DIRECT - 1))
    if value is not None:
        z = np.where(value >= 0, value * 2, -value * 2 - 1)
        bl = _bitlen(z)
        big = z >= DIRECT
        nb = np.where(big, bl - 1, 0)
        coder.sym(kind, ctx, np.where(big, DIRECT + bl - top - 1, z))
        coder.bits(nb, np.where(big, z - (np.int64(1) << nb), 0))
        return value
    s = coder.sym(kind, ctx)
    big = s >= DIRECT
    nb = np.where(big, s - DIRECT + top, 0)
    mant = coder.bits(nb)
    z = np.where(big, (np.int64(1) << nb) + mant, s)
    return np.where(z & 1, -(z + 1) // 2, z // 2)


# ------------------------------------------------------------- cRAW blocks

def craw_fields(strip: np.ndarray, H: int, W: int) -> dict[str, np.ndarray]:
    """The 128-bit blocks of a cRAW strip, split into their fields. Bijective:
    craw_bytes() puts any set of fields back into the same 16 bytes."""
    B = W // 16
    words = strip[:H * W].view("<u8").reshape(H, B, 2).astype(U64)
    lo, hi = words[..., 0], words[..., 1]
    f = {"mx": (lo & U64(0x7FF)), "mn": (lo >> U64(11)) & U64(0x7FF),
         "ix": (lo >> U64(22)) & U64(0xF), "in": (lo >> U64(26)) & U64(0xF)}
    d = np.zeros((H, B, 14), U64)
    for k in range(14):
        b = 30 + 7 * k
        if b + 7 <= 64:
            d[..., k] = (lo >> U64(b)) & U64(0x7F)
        elif b >= 64:
            d[..., k] = (hi >> U64(b - 64)) & U64(0x7F)
        else:
            d[..., k] = ((lo >> U64(b)) | (hi << U64(64 - b))) & U64(0x7F)
    out = {k: v.astype(np.int64) for k, v in f.items()}
    out["d"] = d.astype(np.int64)
    return out


def craw_bytes(f: dict[str, np.ndarray]) -> bytes:
    lo = (f["mx"].astype(U64) | (f["mn"].astype(U64) << U64(11)) | (f["ix"].astype(U64) << U64(22))
          | (f["in"].astype(U64) << U64(26)))
    hi = np.zeros_like(lo)
    d = f["d"].astype(U64)
    for k in range(14):
        b = 30 + 7 * k
        if b + 7 <= 64:
            lo |= d[..., k] << U64(b)
        elif b >= 64:
            hi |= d[..., k] << U64(b - 64)
        else:
            lo |= d[..., k] << U64(b)
            hi |= d[..., k] >> U64(64 - b)
    return np.stack([lo, hi], axis=-1).astype("<u8").tobytes()


def _positions(ix: np.ndarray, iN: np.ndarray) -> np.ndarray:
    """(..., 15) positions 0-15 of the steps, in the order the bits hold them:
    every position but imax and imin. When the two are the same position there
    are fifteen; the fifteenth has no step in the block and is given the min."""
    a = np.minimum(ix, iN)[..., None]
    b = np.maximum(ix, iN)[..., None]
    k = np.arange(15)
    pos = k + (k >= a)
    pos = pos + ((pos >= b) & (a != b))
    # With two distinct extremes there are only fourteen; the fifteenth slot
    # then names imax, which is written last and so overrides it.
    pos[..., 14] = np.where(a[..., 0] == b[..., 0], pos[..., 14], ix)
    return pos


def craw_pixels(f: dict[str, np.ndarray]) -> np.ndarray:
    """(H, B, 16) the 11-bit values a block decodes to, before the camera's tone
    curve: max at imax, min at imin, min + step << shift elsewhere. This is only
    ever used to predict; nothing is written from it."""
    mx, mn, ix, iN, d = f["mx"], f["mn"], f["ix"], f["in"], f["d"]
    sh = _shift(mx - mn)
    pos = _positions(ix, iN)
    vals = np.concatenate([d, np.zeros(d.shape[:-1] + (1,), np.int64)], axis=-1)
    v = np.minimum((vals << sh[..., None]) + mn[..., None], 2047)
    v[..., 14] = mn
    p = np.zeros(d.shape[:-1] + (16,), np.int64)
    np.put_along_axis(p, pos, v, axis=-1)
    np.put_along_axis(p, iN[..., None], mn[..., None], axis=-1)
    np.put_along_axis(p, ix[..., None], mx[..., None], axis=-1)
    return p


def _shift(rng: np.ndarray) -> np.ndarray:
    """dcraw's: for (sh = 0; sh < 4 && 0x80 << sh <= max - min; sh++)."""
    sh = np.zeros_like(rng)
    for s in range(4):
        sh += (sh == s) & ((0x80 << s) <= rng)
    return sh


def to_blocks(a: np.ndarray) -> np.ndarray:
    """(R, W) mosaic rows -> (R*B, 16) blocks: block 2j holds columns 32j, 32j+2 ...,
    block 2j+1 holds 32j+1, 32j+3 ..."""
    R, W = a.shape
    return a.reshape(R, W // 32, 16, 2).swapaxes(-1, -2).reshape(R * (W // 16), 16)


def from_blocks(b: np.ndarray, R: int, W: int) -> np.ndarray:
    return b.reshape(R, W // 32, 2, 16).swapaxes(-1, -2).reshape(R, W)


# --------------------------------------------------------------- the model

INTRA = ("W", "N", "NW", "NE")
INTER = ("R", "RW", "RE", "RN", "RS", "RNW", "RNE", "RSW", "RSE")
DELTA_T = np.array([0, 1, 2, 3, 4, 6, 8, 11, 16, 22, 32, 45, 64, 90, 128, 256], np.int64)
ROOM_T = np.array([0, 1, 2, 3, 4, 6, 8, 12, 16], np.int64)
ICTX_T = np.array([0, 16, 64, 256, 1024], np.int64)
HDR_T = np.array([0, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 128], np.int64)
KINDS = {"mn": (len(HDR_T), 48), "rng": (len(HDR_T), 48), "imax": (5, 16), "imin": (5, 16),
         "d": (len(DELTA_T) * len(ROOM_T), 255)}
TILE = 128          # mosaic pixels on a side, for motion and for weights
SEARCH = 24         # the furthest a tile is looked for from the burst's shift, in mosaic pixels
Q = 12              # fixed point of the weights


def _bucket(a: np.ndarray, t: np.ndarray) -> np.ndarray:
    return np.searchsorted(t, a, side="right") - 1


def pad_mosaic(a: np.ndarray, m: int) -> np.ndarray:
    """Edge-pad a Bayer mosaic by m (even) on every side without mixing colours."""
    H, W = a.shape
    out = np.zeros((H + 2 * m, W + 2 * m), a.dtype)
    for y in (0, 1):
        for x in (0, 1):
            out[y::2, x::2] = np.pad(a[y::2, x::2], m // 2, mode="edge")
    return out


@dataclass
class Frame:
    """What one frame's model knows before any of its symbols: the reference and
    the motion into it, and the fitted weights."""
    H: int
    W: int
    ref: np.ndarray | None = None          # (H, W) the reference's pixels
    mv: np.ndarray | None = None           # (ty, tx, 2) even mosaic offsets into the reference
    wfull: np.ndarray | None = None        # (ty, tx, 4, nfeat + 1) int, Q12, last is the bias
    wpre: np.ndarray | None = None         # (ty, tx, 4, nfeat) int, Q12, no W

    @property
    def feats(self) -> tuple[str, ...]:
        return INTRA + (INTER if self.ref is not None else ())

    def ntiles(self) -> tuple[int, int]:
        return -(-self.H // TILE), -(-self.W // TILE)


def _ref_padded(fr: Frame) -> tuple[np.ndarray, int]:
    m = int(np.abs(fr.mv).max()) + 4 if fr.mv is not None and fr.mv.size else 4
    m += m & 1
    return pad_mosaic(fr.ref, m), m


def _ref_feats(fr: Frame, Rp: np.ndarray, m: int, r0: int, r1: int) -> dict[str, np.ndarray]:
    """The reference around each pixel of rows r0..r1, after its tile's motion."""
    rows = np.arange(r0, r1)[:, None]
    cols = np.arange(fr.W)[None, :]
    ty = rows // TILE
    tx = cols // TILE
    dy = fr.mv[ty, tx, 0]
    dx = fr.mv[ty, tx, 1]
    y = rows + dy + m
    x = cols + dx + m
    off = {"R": (0, 0), "RW": (0, -2), "RE": (0, 2), "RN": (-2, 0), "RS": (2, 0),
           "RNW": (-2, -2), "RNE": (-2, 2), "RSW": (2, -2), "RSE": (2, 2)}
    return {k: Rp[y + oy, x + ox].astype(np.int64) for k, (oy, ox) in off.items()}


def _coef_rows(fr: Frame, w: np.ndarray, r0: int, r1: int) -> np.ndarray:
    """(r1-r0, W, n) weights for each pixel of those rows: by tile and colour."""
    rows = np.arange(r0, r1)[:, None]
    cols = np.arange(fr.W)[None, :]
    phase = (rows & 1) * 2 + (cols & 1)
    return w[rows // TILE, cols // TILE, phase]


def estimate_motion(cur: np.ndarray, ref: np.ndarray) -> np.ndarray:
    """One even (dy, dx) per tile, by block matching on a half-resolution
    brightness map: the whole frame's shift first, by phase correlation, then
    each tile searched around it. Only the encoder runs this, and only its
    answer is stored, so floating point here decides nothing about decoding.
    The search itself is in integers, so the C core finds the same vectors."""
    def half(a):
        a = a.astype(np.int32)
        return a[0::2, 0::2] + a[0::2, 1::2] + a[1::2, 0::2] + a[1::2, 1::2]
    c, r = half(cur), half(ref)
    h, w = c.shape
    # The burst's shift, on an eighth-size copy.
    s = 4
    cs = c[:h // s * s, :w // s * s].reshape(h // s, s, w // s, s).mean((1, 3), dtype=np.float64)
    rs = r[:h // s * s, :w // s * s].reshape(h // s, s, w // s, s).mean((1, 3), dtype=np.float64)
    cs -= cs.mean()
    rs -= rs.mean()
    X = np.fft.rfft2(cs) * np.conj(np.fft.rfft2(rs))
    X /= np.abs(X) + 1e-9
    corr = np.fft.irfft2(X, cs.shape)
    gy, gx = np.unravel_index(int(np.argmax(corr)), corr.shape)
    gy = gy - cs.shape[0] if gy > cs.shape[0] // 2 else gy
    gx = gx - cs.shape[1] if gx > cs.shape[1] // 2 else gx
    # cur(y) ~ ref(y - g): the reference is read at -g.
    gy, gx = -gy * s, -gx * s
    t = TILE // 2
    nty, ntx = -(-h // t), -(-w // t)
    R = SEARCH // 2
    pad = R + max(abs(gy), abs(gx)) + 2
    rp = np.pad(r, pad, mode="edge")
    best = np.full((nty, ntx), np.iinfo(np.int64).max, np.int64)
    mv = np.zeros((nty, ntx, 2), np.int64)
    Hp, Wp = nty * t, ntx * t
    cp = np.pad(c, ((0, Hp - h), (0, Wp - w)), mode="edge")
    cands = [(gy + dy, gx + dx) for dy in range(-R, R + 1) for dx in range(-R, R + 1)] + [(0, 0)]
    lib = core()
    if lib is not None:
        ca = np.ascontiguousarray(cands, np.int64)
        lib.bc_motion(_ptr(np.ascontiguousarray(cp, np.int32)), Hp, Wp, _ptr(np.ascontiguousarray(rp, np.int32)),
                      h, w, pad, t, _ptr(ca), len(cands), _ptr(mv))
        return mv * 2
    for dy, dx in cands:
        if abs(dy) > pad - 1 or abs(dx) > pad - 1:
            continue
        sh = rp[pad + dy: pad + dy + h, pad + dx: pad + dx + w]
        sh = np.pad(sh, ((0, Hp - h), (0, Wp - w)), mode="edge")
        sad = np.abs(cp.astype(np.int64) - sh).reshape(nty, t, ntx, t).sum((1, 3))
        better = sad < best
        best[better] = sad[better]
        mv[better] = (dy, dx)
    return mv * 2


def _features(fr: Frame, P: np.ndarray, r0: int, r1: int, ref) -> dict[str, np.ndarray]:
    """Every feature of rows r0..r1 as the decoder will see it, from the whole frame."""
    W = fr.W
    rows = np.arange(r0 - 2, r1)
    Pp = np.zeros((r1 - r0 + 2, W + 4), np.int64)
    ok = rows >= 0
    Pp[ok, 2:W + 2] = P[rows[ok]]
    Pp[:, 0:2] = Pp[:, 2:4]
    Pp[:, W + 2:] = Pp[:, W:W + 2]
    F = {"N": Pp[:-2, 2:W + 2], "NW": Pp[:-2, 0:W], "NE": Pp[:-2, 4:W + 4]}
    first = (np.arange(W) % 32) < 2
    F["W"] = np.where(first[None, :], F["N"], Pp[2:, 0:W])
    if ref is not None:
        F.update(_ref_feats(fr, ref[0], ref[1], r0, r1))
    return F


def _fit_sums(fr: Frame, P: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """X'X, X'y and the count for every tile and colour, over the features in
    fr.feats and then 1, in integers: exact, and so the same from C and numpy."""
    H, W = P.shape
    ref = _ref_padded(fr) if fr.ref is not None else None
    names = fr.feats
    nty, ntx = fr.ntiles()
    D = len(names) + 1
    xtx = np.zeros((nty, ntx, 4, D, D), np.int64)
    xty = np.zeros((nty, ntx, 4, D), np.int64)
    cnt = np.zeros((nty, ntx, 4), np.int64)
    lib = core()
    if lib is not None:
        Rp = np.ascontiguousarray(ref[0], np.int16) if ref else None
        mv = np.ascontiguousarray(fr.mv, np.int64) if ref else None
        lib.bc_fit(_ptr(np.ascontiguousarray(P, np.int16)), H, W, TILE, _ptr(Rp), ref[1] if ref else 0, _ptr(mv),
                   ntx, len(names), _ptr(xtx), _ptr(xty), _ptr(cnt))
        return xtx, xty, cnt
    for ty in range(nty):
        r0, r1 = ty * TILE, min(H, (ty + 1) * TILE)
        F = _features(fr, P, r0, r1, ref)
        X = np.stack([F[k].astype(np.int64) for k in names] + [np.ones((r1 - r0, W), np.int64)], axis=-1)
        y = P[r0:r1].astype(np.int64)
        for tx in range(ntx):
            xs = slice(tx * TILE, (tx + 1) * TILE)
            for ph in range(4):
                a, b = divmod(ph, 2)
                A = X[:, xs][a::2, b::2].reshape(-1, D)
                yt = y[:, xs][a::2, b::2].reshape(-1)
                xtx[ty, tx, ph] = A.T @ A
                xty[ty, tx, ph] = A.T @ yt
                cnt[ty, tx, ph] = len(yt)
    return xtx, xty, cnt


def fit_weights(fr: Frame, P: np.ndarray, ridge: float = 1.0) -> None:
    """Least-squares weights per tile and colour, on the frame's own pixels, for
    both predictors: with the left neighbour (for a step) and without it (for a
    block's header, which is decoded before any of its steps). The features are
    the ones the decoder will have, computed the same way. The sums are exact
    integers; one batched solve turns them into weights, which are stored."""
    names = fr.feats
    nf = len(names)
    xtx, xty, cnt = _fit_sums(fr, P)
    shape = cnt.shape
    xtx = xtx.reshape(-1, nf + 1, nf + 1).astype(np.float64)
    xty = xty.reshape(-1, nf + 1).astype(np.float64)
    cnt = cnt.reshape(-1)
    ok = cnt >= 4
    out = []
    for idx in (list(range(nf + 1)), [i for i, k in enumerate(names) if k != "W"] + [nf]):
        G = xtx[:, idx][:, :, idx].copy()
        y = xty[:, idx]
        d = len(idx)
        G[:, np.arange(d - 1), np.arange(d - 1)] += ridge    # no pull on the bias
        G[~ok] = np.eye(d)
        w = np.linalg.solve(G, y[..., None])[..., 0]
        wq = np.clip(np.round(w[:, :-1] * (1 << Q)), -(1 << 15), (1 << 15) - 1).astype(np.int64)
        # The bias that makes the rounded weights right on average: mean(y - X.wq / 2**Q), in Q.
        sums = xtx[:, idx[:-1], nf]          # each feature summed over the group
        mean = (xty[:, nf] - (sums * wq).sum(1) / (1 << Q)) / np.maximum(cnt, 1)
        bias = np.clip(np.round(mean * (1 << Q)), -(1 << 30), 1 << 30).astype(np.int64)
        wq = np.concatenate([wq, bias[:, None]], axis=1)
        wq[~ok] = 0
        out.append(wq.reshape(*shape, d))
    fr.wfull, fr.wpre = out


def run_craw(fr: Frame, coder, f: dict[str, np.ndarray] | None) -> dict[str, np.ndarray]:
    """One pass over a frame, row pair by row pair. With a Recorder and the
    frame's fields it writes down what to code; with a Decoder and no fields it
    reads them back. It is the same code both ways, which is what keeps the two
    ends of the archive in step."""
    H, W = fr.H, fr.W
    B = W // 16
    enc = f is not None
    out = f if enc else {"mx": np.zeros((H, B), np.int64), "mn": np.zeros((H, B), np.int64),
                         "ix": np.zeros((H, B), np.int64), "in": np.zeros((H, B), np.int64),
                         "d": np.zeros((H, B, 14), np.int64)}
    names = fr.feats
    iW = names.index("W")
    rest = [k for k in names if k != "W"]
    ifull = [names.index(k) for k in rest]
    Pp = np.zeros((H + 2, W + 4), np.int32)     # decoded pixels, two rows of zeros above
    Ep = np.zeros((H + 2, W + 4), np.int32)     # how wrong the header's prediction was
    ref = _ref_padded(fr) if fr.ref is not None else None
    for r0 in range(0, H, 2):
        r1 = min(H, r0 + 2)
        R = r1 - r0
        n = R * B
        feats = {"N": Pp[r0:r1, 2:W + 2].astype(np.int64), "NW": Pp[r0:r1, 0:W].astype(np.int64),
                 "NE": Pp[r0:r1, 4:W + 4].astype(np.int64)}
        if ref is not None:
            feats.update(_ref_feats(fr, ref[0], ref[1], r0, r1))
        cf = _coef_rows(fr, fr.wfull, r0, r1)
        cp = _coef_rows(fr, fr.wpre, r0, r1)
        pre = cp[..., -1].copy()
        part = cf[..., -1].copy() + (1 << (Q - 1))
        for j, k in enumerate(rest):
            pre += cp[..., j] * feats[k]
            part += cf[..., ifull[j]] * feats[k]
        pre = np.clip((pre + (1 << (Q - 1))) >> Q, 0, 2047)
        preb = to_blocks(pre)
        partb = to_blocks(part)
        wWb = to_blocks(cf[..., iW])
        Nb = to_blocks(feats["N"])
        eN = Ep[r0:r1, 2:W + 2].astype(np.int64)
        actb = to_blocks(eN + ((Ep[r0:r1, 0:W].astype(np.int64) + Ep[r0:r1, 4:W + 4]) >> 1))
        eNb = to_blocks(eN)

        # The header: min, range, and where the two extremes are.
        hctx = _bucket(eNb.sum(1) >> 4, HDR_T)
        mnh, mxh = preb.min(1), preb.max(1)
        sl = (slice(r0, r1),)
        mn = _code_int(coder, "mn", hctx, (out["mn"][sl].reshape(n) - mnh) if enc else None) + mnh
        rng = _code_int(coder, "rng", hctx, (out["mx"][sl].reshape(n) - mn - (mxh - mnh)) if enc else None) + mxh - mnh
        mx = mn + rng
        sh = _shift(rng)
        ictx = np.minimum(_bucket(mxh - mnh, ICTX_T), 4)
        desc = np.argsort(-preb, axis=1, kind="stable")
        asc = np.argsort(preb, axis=1, kind="stable")
        if enc:
            ix = out["ix"][sl].reshape(n)
            iN = out["in"][sl].reshape(n)
            coder.sym("imax", ictx, np.argmax(desc == ix[:, None], axis=1))
            coder.sym("imin", ictx, np.argmax(asc == iN[:, None], axis=1))
        else:
            lane = np.arange(n)
            ix = desc[lane, coder.sym("imax", ictx)]
            iN = asc[lane, coder.sym("imin", ictx)]
        pos = _positions(ix, iN)
        lane = np.arange(n)
        Pb = np.zeros((n, 16), np.int64)
        Pb[lane, pos[:, 14]] = mn
        Pb[lane, iN] = mn
        Pb[lane, ix] = mx
        Eb = np.abs(Pb - preb)
        half = (np.int64(1) << sh) >> 1
        lo = np.minimum(mn, mx)
        hi = np.maximum(mn, mx)
        dtrue = out["d"][sl].reshape(n, 14) if enc else None
        dall = np.zeros((n, 14), np.int64)
        # A step can only put its pixel between the block's min and max, so
        # its residual is bounded on both sides. The side with less room is
        # turned to face down and how much room it has is part of the
        # context, which is how the tables learn the truncation.
        dmax = np.clip((hi - mn) >> sh, 0, 127)

        # The fourteen steps, left to right, each predicted with its left
        # neighbour now that it is known.
        for k in range(14):
            p = pos[:, k]
            left = p - 1
            has = p > 0
            Wv = np.where(has, Pb[lane, np.maximum(left, 0)], Nb[:, 0])
            eW = np.where(has, Eb[lane, np.maximum(left, 0)], eNb[:, 0])
            ph = (partb[lane, p] + wWb[lane, p] * Wv) >> Q
            ph = np.clip(ph, lo, hi)
            dh = np.clip((ph - mn + half) >> sh, 0, 127)
            act = (2 * eW + actb[lane, p]) >> sh
            up = dmax - dh
            flip = dh > up
            ctx = _bucket(act, DELTA_T) * len(ROOM_T) + _bucket(np.maximum(np.minimum(dh, up), 0), ROOM_T)
            if enc:
                e = dtrue[:, k] - dh
                coder.sym("d", ctx, np.where(flip, -e, e) + 127)
                d = dtrue[:, k]
            else:
                e = coder.sym("d", ctx) - 127
                d = np.where(flip, -e, e) + dh
            dall[:, k] = d
            v = np.minimum((d << sh) + mn, 2047)
            Pb[lane, p] = v
            Eb[lane, p] = np.abs(v - preb[lane, p])
        Pb[lane, ix] = mx     # max wins where the two positions are one, as in dcraw
        Pp[r0 + 2:r1 + 2, 2:W + 2] = from_blocks(Pb, R, W)
        Ep[r0 + 2:r1 + 2, 2:W + 2] = from_blocks(Eb, R, W)
        for a in (Pp, Ep):
            a[r0 + 2:r1 + 2, 0:2] = a[r0 + 2:r1 + 2, 2:4]
            a[r0 + 2:r1 + 2, W + 2:] = a[r0 + 2:r1 + 2, W:W + 2]
        if not enc:
            out["mn"][r0:r1] = mn.reshape(R, B)
            out["mx"][r0:r1] = mx.reshape(R, B)
            out["ix"][r0:r1] = ix.reshape(R, B)
            out["in"][r0:r1] = iN.reshape(R, B)
            out["d"][r0:r1] = dall.reshape(R, B, 14)
    return out


def _pixels_mosaic(f: dict[str, np.ndarray], H: int, W: int) -> np.ndarray:
    """(H, W) int16: the pixels a later frame refers to. Eleven bits fit."""
    out = np.empty((H, W), np.int16)
    for r0 in range(0, H, 256):
        r1 = min(H, r0 + 256)
        part = {k: v[r0:r1] for k, v in f.items()}
        out[r0:r1] = from_blocks(craw_pixels(part).reshape((r1 - r0) * (W // 16), 16), r1 - r0, W)
    return out


# ---------------------------------------------------------------- the core
#
# burstcore.c is run_craw and the rANS coder written out per pixel: the same
# bytes, 20 to 50 times sooner. The app carries it built and signed beside this
# file; a checkout builds it the first time it is wanted, into the support
# folder, keyed by the source's hash. Without a compiler, or with
# BURSTPACK_PURE=1, everything here runs in numpy instead, byte for byte the
# same, only slower. The library is used only if the constants it reports
# are this file's own.

_CORE: dict = {}
EVENTS_PER_PAIR = 20        # min and its bits, range and its bits, imax, imin, fourteen steps


def _lib_name() -> str:
    return "libburstcore.dylib" if sys.platform == "darwin" else "libburstcore.so"


def _build_core(src: Path) -> Path | None:
    import shutil
    import subprocess
    try:
        from common import support_dir
        base = support_dir(create=True)
    except Exception:
        base = Path(tempfile.gettempdir())
    digest = hashlib.sha256(src.read_bytes()).hexdigest()[:16]
    out = base / "burstcore" / digest / _lib_name()
    if out.exists():
        return out
    cc = shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
    if not cc:
        return None
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(f".{out.name}.{os.getpid()}.tmp")
    try:
        r = subprocess.run([cc, "-O3", "-std=c99", "-shared", "-fPIC", "-o", str(tmp), str(src)],
                           capture_output=True, text=True, timeout=120)
        if r.returncode != 0:
            return None
        os.replace(tmp, out)
    except (OSError, subprocess.SubprocessError):
        return None
    finally:
        tmp.unlink(missing_ok=True)
    return out


def _expected_constants() -> list[int]:
    v = [1, Q, PREC, DIRECT]
    for t in (HDR_T, DELTA_T, ROOM_T, ICTX_T):
        v += [len(t)] + [int(x) for x in t]
    for nctx, nsym in KINDS.values():
        v += [nctx, nsym]
    return v


def core():
    """The C core, or None: then numpy does the same work."""
    if "lib" in _CORE:
        return _CORE["lib"]
    _CORE["lib"] = None
    if os.environ.get("BURSTPACK_PURE") == "1":
        return None
    import ctypes
    here = Path(__file__).resolve().parent
    cands = [here / _lib_name()]
    if not cands[0].exists() and (here / "burstcore.c").exists():
        built = _build_core(here / "burstcore.c")
        cands = [built] if built else []
    for c in cands:
        try:
            lib = ctypes.CDLL(str(c))
        except OSError:
            continue
        buf = (ctypes.c_int64 * 128)()
        n = lib.bc_constants(buf, 128)
        if n <= 0 or list(buf[:n]) != _expected_constants():
            continue
        P = ctypes.c_void_p
        lib.bc_pixels.argtypes = [P, ctypes.c_int, ctypes.c_int, P]
        lib.bc_craw.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, P, P, P, ctypes.c_int,
                                P, ctypes.c_int, P, P, ctypes.c_int, P, P, P, P, P, P, P, P, ctypes.c_int64]
        lib.bc_rans_encode.argtypes = [ctypes.c_int, ctypes.c_int, P, P, P, P, P, P, ctypes.c_int64]
        lib.bc_rans_encode.restype = ctypes.c_int64
        lib.bc_fit.argtypes = [P, ctypes.c_int, ctypes.c_int, ctypes.c_int, P, ctypes.c_int, P, ctypes.c_int,
                               ctypes.c_int, P, P, P]
        lib.bc_motion.argtypes = [P, ctypes.c_int, ctypes.c_int, P, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                  ctypes.c_int, P, ctypes.c_int, P]
        _CORE["lib"] = lib
        break
    return _CORE["lib"]


def _ptr(a: np.ndarray | None):
    return None if a is None else a.ctypes.data


_CORE_ERRORS = {-1: "the stream ends early", -2: "the stream names a symbol its table does not have",
                -3: "the stream did not end where it should", -4: "out of memory", -5: "a frame it cannot take"}


def _core_frame(lib, dec: bool, fr: Frame, strip: np.ndarray, tables=None, states=None, words=None):
    """bc_craw over one frame. Encoding returns (ctx, val, counts); decoding fills strip."""
    H, W = fr.H, fr.W
    B = W // 16
    P = np.zeros((H, W), np.int16)
    Rp = m = None
    if fr.ref is not None:
        Rp, m = _ref_padded(fr)
        Rp = np.ascontiguousarray(Rp, np.int16)
        mv = np.ascontiguousarray(fr.mv, np.int64)
    else:
        mv = None
    nty, ntx = fr.ntiles()
    wfull = np.ascontiguousarray(fr.wfull, np.int64)
    wpre = np.ascontiguousarray(fr.wpre, np.int64)
    nf = len(fr.feats)
    total = ((H + 1) // 2) * EVENTS_PER_PAIR * 2 * B
    if not dec:
        rctx = np.zeros(total, np.int32)
        rval = np.zeros(total, np.int32)
        counts = np.zeros(sum(a * b for a, b in KINDS.values()), np.int64)
        freq = cum = lookup = st = wd = None
        nw = 0
    else:
        rctx = rval = counts = None
        freq = np.concatenate([tables[k].freq.reshape(-1) for k in KINDS]).astype(np.uint32)
        cum = np.concatenate([tables[k].cum.reshape(-1) for k in KINDS]).astype(np.uint32)
        lookup = np.concatenate([tables[k].lookup.reshape(-1) for k in KINDS]).astype(np.uint8)
        st = np.ascontiguousarray(states, np.uint32)
        wd = np.ascontiguousarray(words, np.uint16)
        nw = len(wd)
    err = lib.bc_craw(1 if dec else 0, H, W, TILE, _ptr(strip), _ptr(P), _ptr(Rp), m or 0, _ptr(mv), ntx,
                      _ptr(wfull), _ptr(wpre), nf, _ptr(rctx), _ptr(rval), _ptr(counts),
                      _ptr(freq), _ptr(cum), _ptr(lookup), _ptr(st), _ptr(wd), nw)
    if err:
        raise ValueError(f"burstpack: {_CORE_ERRORS.get(err, err)}")
    return P, rctx, rval, counts


# ------------------------------------------------------------ frame codecs

def _blob(*parts: bytes) -> bytes:
    return b"".join(struct.pack("<Q", len(p)) + p for p in parts)


def _unblob(b: bytes) -> list[bytes]:
    out, i = [], 0
    while i < len(b):
        (n,) = struct.unpack_from("<Q", b, i)
        out.append(b[i + 8:i + 8 + n])
        i += 8 + n
    return out


def _arr(a: np.ndarray, dtype: str) -> bytes:
    return lzma.compress(json.dumps(list(a.shape)).encode() + b"\n" + a.astype(dtype).tobytes())


def _unarr(b: bytes, dtype: str) -> np.ndarray:
    raw = lzma.decompress(b)
    nl = raw.index(b"\n")
    return np.frombuffer(raw[nl + 1:], dtype).reshape(json.loads(raw[:nl])).astype(np.int64)


def encode_craw(strip: bytes, H: int, W: int, ref: np.ndarray | None) -> tuple[bytes, np.ndarray]:
    """The sensor data of one frame, and its pixels for the next frame to refer to."""
    lib = core()
    raw = np.frombuffer(strip, np.uint8)
    if lib is not None:
        P = np.zeros((H, W), np.int16)
        lib.bc_pixels(_ptr(np.ascontiguousarray(raw)), H, W, _ptr(P))
        f = None
    else:
        f = craw_fields(raw, H, W)
        P = _pixels_mosaic(f, H, W)
    fr = Frame(H, W)
    if ref is not None and ref.shape == P.shape:
        fr.ref = ref
        fr.mv = estimate_motion(P, ref)
    fit_weights(fr, P)
    if lib is not None:
        buf = np.array(raw[:H * W])
        _, rctx, rval, flat = _core_frame(lib, False, fr, buf)
        tables, i = {}, 0
        for k, (nctx, nsym) in KINDS.items():
            tables[k] = Tables.from_counts(flat[i:i + nctx * nsym].reshape(nctx, nsym))
            i += nctx * nsym
        freq = np.concatenate([tables[k].freq.reshape(-1) for k in KINDS]).astype(np.uint32)
        cum = np.concatenate([tables[k].cum.reshape(-1) for k in KINDS]).astype(np.uint32)
        states = np.zeros(2 * (W // 16), np.uint32)
        words = np.zeros(len(rctx), np.uint16)
        nw = lib.bc_rans_encode(H, W // 16, _ptr(rctx), _ptr(rval), _ptr(freq), _ptr(cum),
                                _ptr(states), _ptr(words), len(words))
        if nw < 0:
            raise AssertionError(f"burstpack: the coder refused a frame ({nw})")
        words = words[:nw]
    else:
        rec = Recorder()
        run_craw(fr, rec, f)
        counts = rec.counts(KINDS)
        tables = {k: Tables.from_counts(c) for k, c in counts.items()}
        states, words = rans_encode(rec.events, tables, 2 * (W // 16))
    head = json.dumps({"H": H, "W": W, "ref": fr.ref is not None, "tile": TILE, "q": Q}).encode()
    parts = [head, _arr(fr.wfull, "<i4"), _arr(fr.wpre, "<i4"),
             _arr(fr.mv if fr.mv is not None else np.zeros((0,)), "<i2")]
    parts += [_arr(tables[k].freq, "<u2") for k in KINDS]
    parts += [states.astype("<u4").tobytes(), words.astype("<u2").tobytes()]
    return _blob(*parts), P


def decode_craw(payload: bytes, ref: np.ndarray | None) -> tuple[bytes, np.ndarray]:
    parts = _unblob(payload)
    head = json.loads(parts[0])
    if head["tile"] != TILE or head["q"] != Q:
        raise ValueError("burstpack: this archive was made with a different tile or weight precision")
    H, W = head["H"], head["W"]
    fr = Frame(H, W, wfull=_unarr(parts[1], "<i4"), wpre=_unarr(parts[2], "<i4"))
    if head["ref"]:
        if ref is None:
            raise ValueError("burstpack: a frame's reference is missing")
        fr.ref = ref
        fr.mv = _unarr(parts[3], "<i2")
    tables = {k: Tables(_unarr(parts[4 + i], "<u2")) for i, k in enumerate(KINDS)}
    i = 4 + len(KINDS)
    states = np.frombuffer(parts[i], "<u4")
    words = np.frombuffer(parts[i + 1], "<u2")
    if len(states) != 2 * (W // 16):
        raise ValueError("burstpack: the stream's lanes do not match the frame")
    lib = core()
    if lib is not None:
        strip = np.zeros(H * W, np.uint8)
        P, *_ = _core_frame(lib, True, fr, strip, tables, states, words)
        return strip.tobytes(), P
    dec = Decoder(states, words, tables)
    f = run_craw(fr, dec, None)
    if not dec.done():
        raise ValueError("burstpack: the stream did not end where it should")
    return craw_bytes(f), _pixels_mosaic(f, H, W)


# ---------------------------------------------------------- the container

@dataclass
class Located:
    offset: int
    H: int
    W: int
    kind: str       # "craw"


def locate_raw(data: bytes) -> Located | None:
    """Where the sensor data of a Sony compressed ARW is, from its TIFF
    structure, or None for anything else. A wrong answer here costs space,
    never bytes: the whole file is still checked after unpacking."""
    if len(data) < 16 or data[:4] != b"II*\x00":
        return None
    le = "<"
    sizes = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4}

    def ifd(off: int) -> tuple[dict[int, list[int]], int]:
        if off + 2 > len(data):
            return {}, 0
        (n,) = struct.unpack_from(le + "H", data, off)
        tags: dict[int, list[int]] = {}
        for i in range(min(n, 512)):
            e = off + 2 + 12 * i
            if e + 12 > len(data):
                break
            tag, typ, cnt = struct.unpack_from(le + "HHI", data, e)
            size = sizes.get(typ, 1) * cnt
            vo = e + 8 if size <= 4 else struct.unpack_from(le + "I", data, e + 8)[0]
            if typ in (3, 4, 13) and vo + size <= len(data) and cnt <= 4096:
                fmt = "H" if typ == 3 else "I"
                tags[tag] = list(struct.unpack_from(le + fmt * cnt, data, vo))
        nxt_at = off + 2 + 12 * n
        nxt = struct.unpack_from(le + "I", data, nxt_at)[0] if nxt_at + 4 <= len(data) else 0
        return tags, nxt

    best: Located | None = None
    todo, seen = [struct.unpack_from(le + "I", data, 4)[0]], set()
    while todo and len(seen) < 64:
        off = todo.pop()
        if off in seen or off <= 0 or off >= len(data):
            continue
        seen.add(off)
        tags, nxt = ifd(off)
        todo += [nxt] + tags.get(330, [])
        if not all(t in tags for t in (256, 257, 259, 273, 279)):
            continue
        if len(tags[273]) != 1:
            continue
        W, H, comp, so, sb = tags[256][0], tags[257][0], tags[259][0], tags[273][0], tags[279][0]
        if comp == 32767 and sb == W * H and W % 32 == 0 and H >= 2 and so + sb <= len(data):
            if best is None or W * H > best.W * best.H:
                best = Located(so, H, W, "craw")
    return best


def encode_frame(data: bytes, ref: np.ndarray | None) -> tuple[dict, bytes, np.ndarray | None]:
    """(what the manifest records, the frame's bytes in the archive, its pixels)."""
    loc = locate_raw(data)
    if loc is None:
        return {"codec": "lzma"}, lzma.compress(data, preset=9), None
    end = loc.offset + loc.H * loc.W
    envelope = data[:loc.offset] + data[end:]
    sensor, P = encode_craw(data[loc.offset:end], loc.H, loc.W, ref)
    if len(sensor) >= loc.H * loc.W:
        # It parsed as cRAW and did not behave like it. Stored, not refused.
        return {"codec": "lzma"}, lzma.compress(data, preset=9), None
    return ({"codec": "craw", "offset": loc.offset, "H": loc.H, "W": loc.W},
            _blob(lzma.compress(envelope, preset=9), sensor), P)


def decode_frame(meta: dict, blob: bytes, ref: np.ndarray | None) -> tuple[bytes, np.ndarray | None]:
    if meta["codec"] == "lzma":
        return lzma.decompress(blob), None
    if meta["codec"] != "craw":
        raise ValueError(f"burstpack: unknown codec {meta['codec']!r}")
    env, sensor = _unblob(blob)
    envelope = lzma.decompress(env)
    strip, P = decode_craw(sensor, ref)
    o = meta["offset"]
    return envelope[:o] + strip + envelope[o:], P


def plan(names: list[str], key: str | None) -> tuple[int, list[int | None]]:
    """The keeper is stored whole; each other frame refers to its neighbour on the
    way back to the keeper, so restoring the keeper decodes one frame and restoring
    the frame k places away decodes k+1."""
    k = names.index(key) if key in names else 0
    refs: list[int | None] = [None] * len(names)
    for i in range(len(names)):
        if i < k:
            refs[i] = i + 1
        elif i > k:
            refs[i] = i - 1
    return k, refs


def _order(k: int, n: int) -> list[int]:
    order = [k]
    for d in range(1, n):
        for i in (k - d, k + d):
            if 0 <= i < n:
                order.append(i)
    return order


def pack(paths: list[Path], out: Path, key: str | None = None, log=print) -> dict:
    """Pack a burst into one archive, unpack it in memory, and only then move it
    into place. Returns the manifest."""
    paths = [Path(p) for p in paths]
    names = [p.name for p in paths]
    if len(set(names)) != len(names):
        raise ValueError("burstpack: two frames have the same name")
    if out.exists():
        raise FileExistsError(f"burstpack: {out} is already there; nothing was written")
    k, refs = plan(names, key)
    frames: list[dict] = [{} for _ in paths]
    blobs: list[bytes] = [b""] * len(paths)
    pixels: dict[int, np.ndarray | None] = {}
    for i in _order(k, len(paths)):
        data = paths[i].read_bytes()
        t = time.time()
        ref = pixels.get(refs[i]) if refs[i] is not None else None
        meta, blob, P = encode_frame(data, ref)
        if meta["codec"] == "craw" and ref is None and refs[i] is not None:
            refs[i] = None          # its neighbour could not be modelled; it stands alone
        st = paths[i].stat()
        meta.update(name=names[i], size=len(data), sha256=hashlib.sha256(data).hexdigest(),
                    mtime_ns=st.st_mtime_ns, ref=refs[i] if meta["codec"] == "craw" else None)
        frames[i], blobs[i], pixels[i] = meta, blob, P
        # A frame's pixels are kept only while a frame still to come refers to it.
        for j in list(pixels):
            if not any(refs[m] == j and not frames[m] for m in range(len(paths))):
                del pixels[j]
        log(f"  {names[i]}: {len(data):,} -> {len(blob):,} bytes ({len(blob) / len(data):.1%})"
            f"{'' if meta['ref'] is None else ' from ' + names[meta['ref']]}  {time.time() - t:.1f}s")
        # A frame whose data could not be modelled cannot be referred to.
        if P is None:
            for j in range(len(refs)):
                if refs[j] == i:
                    refs[j] = None
    manifest = {"version": VERSION, "key": names[k], "frames": frames}
    body = io.BytesIO()
    for i, b in enumerate(blobs):
        frames[i]["at"] = body.tell()
        frames[i]["length"] = len(b)
        body.write(b)
    head = json.dumps(manifest).encode()
    archive = MAGIC + struct.pack("<Q", len(head)) + head + body.getvalue()
    # Proof before the name: unpack all of it from the bytes about to be written.
    for name, data in _unpack_bytes(archive).items():
        if hashlib.sha256(data).hexdigest() != next(f["sha256"] for f in frames if f["name"] == name):
            raise AssertionError(f"burstpack: {name} did not come back identical; nothing written")
    out.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=out.parent, prefix=f".{out.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(archive)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, out)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise
    return manifest


def read_manifest(archive: bytes) -> tuple[dict, int]:
    if archive[:len(MAGIC)] != MAGIC:
        raise ValueError("burstpack: not a burstpack archive")
    (n,) = struct.unpack_from("<Q", archive, len(MAGIC))
    start = len(MAGIC) + 8
    return json.loads(archive[start:start + n]), start + n


def _unpack_bytes(archive: bytes, want: set[str] | None = None) -> dict[str, bytes]:
    manifest, base = read_manifest(archive)
    frames = manifest["frames"]
    need: set[int] = set()
    for i, f in enumerate(frames):
        if want is None or f["name"] in want:
            j: int | None = i
            while j is not None and j not in need:
                need.add(j)
                j = frames[j]["ref"]
    pixels: dict[int, np.ndarray | None] = {}
    done: set[int] = set()
    out: dict[str, bytes] = {}
    # The keeper first, then outwards: each frame's reference is decoded before it.
    order = sorted(need, key=lambda i: _depth(frames, i))
    for i in order:
        f = frames[i]
        blob = archive[base + f["at"]: base + f["at"] + f["length"]]
        if len(blob) != f["length"]:
            raise ValueError(f"burstpack: {f['name']} is cut short in the archive")
        try:
            data, P = decode_frame(f, blob, pixels.get(f["ref"]) if f["ref"] is not None else None)
        except (ValueError, IndexError, KeyError, lzma.LZMAError, struct.error) as e:
            # A damaged stream can send the model anywhere; all of it is one answer.
            raise ValueError(f"burstpack: {f['name']} cannot be decoded: {e}") from e
        pixels[i] = P
        done.add(i)
        if want is None or f["name"] in want:
            if hashlib.sha256(data).hexdigest() != f["sha256"]:
                raise ValueError(f"burstpack: {f['name']} does not match its checksum")
            out[f["name"]] = data
        for j in list(pixels):
            if not any(frames[m]["ref"] == j and m not in done for m in need):
                del pixels[j]
    return out


def _depth(frames: list[dict], i: int) -> int:
    d, j = 0, frames[i]["ref"]
    while j is not None:
        d, j = d + 1, frames[j]["ref"]
        if d > len(frames):
            raise ValueError("burstpack: the archive's references go round in a circle")
    return d


def unpack(archive: Path, dest: Path, names: list[str] | None = None, log=print) -> list[Path]:
    """Write frames out beside nothing: a name already in dest is refused, not replaced."""
    data = archive.read_bytes()
    manifest, _ = read_manifest(data)
    want = set(names) if names else None
    dest.mkdir(parents=True, exist_ok=True)
    for f in manifest["frames"]:
        if (want is None or f["name"] in want) and (dest / f["name"]).exists():
            raise FileExistsError(f"burstpack: {dest / f['name']} is already there; nothing was written")
    written = []
    for name, raw in _unpack_bytes(data, want).items():
        meta = next(f for f in manifest["frames"] if f["name"] == name)
        target = dest / name
        fd, tmp = tempfile.mkstemp(dir=dest, prefix=f".{name}.", suffix=".tmp")
        try:
            with os.fdopen(fd, "wb") as fh:
                fh.write(raw)
                fh.flush()
                os.fsync(fh.fileno())
            os.utime(tmp, ns=(meta["mtime_ns"], meta["mtime_ns"]))
            os.link(tmp, target)            # never over an existing name
        finally:
            Path(tmp).unlink(missing_ok=True)
        written.append(target)
        log(f"  {name}")
    return written


# --------------------------------------------------------------------- CLI

def groups_of(shoot: Path) -> tuple[list[tuple[str, list[Path], str | None]], list[tuple[str, str]]]:
    """Every RAW in the shoot, grouped for packing, and every one that cannot be.

    A group is a burst as the cull made it, frames in capture order, with the
    frame he kept from it if he kept one, named burst-<n>; a frame the cull put
    in no burst of its own, or never saw, is a group of one, named after the
    frame. Only frames whose bytes are on this Mac are packed: an evicted RAW
    would be read back over the network, and it is listed as left out, with
    why, so the count he is shown adds up to the count he shot."""
    sys.path.insert(0, str(_here()))
    import archive  # noqa: E402
    import library  # noqa: E402
    from common import RAW_EXTS  # noqa: E402
    where = library.paths(Path(shoot).expanduser().resolve())
    raw = library.raw_dir(where.shoot)
    frames = sorted(p for p in raw.iterdir()
                    if p.is_file() and not p.name.startswith(".") and p.suffix.lower() in RAW_EXTS)
    burst, when, kept = _cull_facts(where)
    skipped: list[tuple[str, str]] = []
    groups: dict[str, list[Path]] = {}
    for p in frames:
        if not archive.local(p):
            skipped.append((p.name, "in iCloud and not on this Mac; Bring Back from iCloud first"))
            continue
        gid = f"burst-{burst[p.stem]}" if p.stem in burst else f"frame-{p.stem}"
        groups.setdefault(gid, []).append(p)
    out = []
    for gid, files in groups.items():
        files.sort(key=lambda q: (when.get(q.stem, ""), q.name))
        key = next((q.name for q in files if q.stem in kept), None)
        out.append((gid, files, key))
    out.sort(key=lambda g: (when.get(g[1][0].stem, ""), g[1][0].name))
    return out, skipped


def _cull_facts(where) -> tuple[dict[str, str], dict[str, str], set[str]]:
    """(stem -> burst, stem -> when shot, the stems he kept), from the cull."""
    import csv
    from common import decision_path  # noqa: E402
    burst: dict[str, str] = {}
    when: dict[str, str] = {}
    csv_path = where.cull / "cull.csv"
    if csv_path.exists():
        with csv_path.open() as fh:
            for r in csv.DictReader(fh):
                stem = Path(r["file"]).stem
                when[stem] = r.get("shot_at", "")
                if r.get("burst") not in (None, ""):
                    burst[stem] = r["burst"]
    sel = decision_path(where.cull, "selects.json")
    kept = {Path(n).stem for n in json.loads(sel.read_text())} if sel.exists() else set()
    return burst, when, kept


def group_names(shoot: Path, names: set[str]) -> list[tuple[str, list[str], str | None]]:
    """Frame names grouped the way groups_of groups files, for frames that need
    not be on this Mac: a burst as the cull made it, else a group of one."""
    sys.path.insert(0, str(_here()))
    import library  # noqa: E402
    where = library.paths(Path(shoot).expanduser().resolve())
    burst, when, kept = _cull_facts(where)
    groups: dict[str, list[str]] = {}
    for n in sorted(names):
        stem = Path(n).stem
        groups.setdefault(f"burst-{burst[stem]}" if stem in burst else f"frame-{stem}", []).append(n)
    out = []
    for gid, ns in groups.items():
        ns.sort(key=lambda n: (when.get(Path(n).stem, ""), n))
        out.append((gid, ns, next((n for n in ns if Path(n).stem in kept), None)))
    out.sort(key=lambda g: (when.get(Path(g[1][0]).stem, ""), g[1][0]))
    return out


def bursts_of(shoot: Path) -> list[tuple[str, list[Path], str | None]]:
    """The groups of two or more: what `bench` measures a neighbour on."""
    return [g for g in groups_of(shoot)[0] if len(g[1]) >= 2]


PACKED = "packed"


def _count(n: int, one: str) -> str:
    return f"{n} {one if n == 1 else one + 's'}"


def pack_shoot(shoot: Path, apply: bool, log=print, only: set[str] | None = None) -> int:
    """Every RAW of a shoot: each burst into packed/burst-<n>.roll beside raw/,
    and each frame in no burst into packed/frame-<name>.roll.

    Without apply it only says what it would pack, and names every frame it
    would not, which is what the Finish page's list shows before he confirms.
    It removes nothing either way: the RAWs stay where they are, and a group
    already packed is left alone. `only` narrows it to the groups holding any
    of those frame names, which is how a copy to iCloud packs just what it is
    about to send."""
    sys.path.insert(0, str(_here()))
    import library  # noqa: E402
    from common import human  # noqa: E402
    where = library.paths(Path(shoot).expanduser().resolve())
    dest = where.shoot / PACKED
    groups, skipped = groups_of(where.shoot)
    if only is not None:
        groups = [g for g in groups if any(p.name in only for p in g[1])]
        skipped = [x for x in skipped if x[0] in only]
    todo = [(gid, files, key) for gid, files, key in groups if not (dest / f"{gid}{EXT}").exists()]
    packed = sum(len(f) for g, f, _ in groups if (dest / f"{g}{EXT}").exists())
    nf = sum(len(f) for _, f, _ in todo)
    size = sum(p.stat().st_size for _, f, _ in todo for p in f)
    nb = sum(1 for _, f, _ in todo if len(f) > 1)
    ns = len(todo) - nb

    def left_out() -> None:
        # Every frame of the shoot is accounted for: packed, to pack, or here.
        if skipped:
            log(f"{_count(len(skipped), 'frame')} will not be packed:")
            for name, why in skipped:
                log(f"  - {name}: {why}")
        if packed:
            log(f"{_count(packed, 'frame')} already packed, in {dest}")

    if not todo:
        log(f"nothing left to pack in {where.shoot.name}.")
        left_out()
        return 0
    if not apply:
        log(f"would pack {nf} frames in {nb} bursts and {_count(ns, 'single frame')}, {human(size)}, into {dest}")
        for gid, files, key in todo:
            if len(files) > 1:
                log(f"  {gid.replace('-', ' ')}: {len(files)} frames, {key or files[0].name} kept whole")
        if ns:
            log(f"  and {_count(ns, 'frame')} shot on {'its' if ns == 1 else 'their'} own, each packed alone")
        left_out()
        log("Nothing is removed: the RAWs stay where they are. Each burst is unpacked and checked "
            "against every frame's checksum before it is kept.")
        return 0
    done = failed = 0
    before = after = 0
    # What a stopped run left: its own temp files, never anything else.
    if dest.is_dir():
        for t in [*dest.glob(f".burst-*{EXT}.*.tmp"), *dest.glob(f".frame-*{EXT}.*.tmp")]:
            t.unlink(missing_ok=True)
    log(f"@@ pack 0 {nf}")

    def tick(line: str) -> None:
        nonlocal done
        log(line)
        if line.startswith("  ") and " -> " in line:
            done += 1
            log(f"@@ pack {done} {nf}")

    def ended(bid: str, b: int, a: int, err: str | None) -> None:
        nonlocal failed, before, after
        if err is not None:        # one burst's failure is said, and the rest go on
            failed += 1
            log(f"  {bid}: not packed: {err}")
            return
        before, after = before + b, after + a
        log(f"  {bid}: {human(b)} -> {human(a)} ({a / b:.0%}), every frame unpacked and matched")

    # The biggest bursts first, so the last worker is not left with the longest one.
    jobs = sorted(((gid, files, key, dest / f"{gid}{EXT}") for gid, files, key in todo),
                  key=lambda j: -sum(p.stat().st_size for p in j[1]))
    workers = _workers(len(jobs), max(p.stat().st_size for _, f, _ in todo for p in f))
    log(f"packing on {workers} {'core' if workers == 1 else 'cores'}"
        f"{'' if core() is not None else ', without the C core'}")
    if workers == 1:
        for job in jobs:
            ended(*_pack_one(job, tick))
    else:
        _pack_parallel(jobs, workers, tick, ended)
    if before:
        log(f"packed {human(before)} of RAWs into {human(after)} ({after / before:.0%}), in {dest}")
    if skipped:
        log(f"{_count(len(skipped), 'frame')} not packed:")
        for name, why in skipped:
            log(f"  - {name}: {why}")
    if failed:
        log(f"{failed} of the groups could not be packed; their RAWs are untouched")
        return 1
    return 0


def _workers(nbursts: int, file_bytes: int) -> int:
    """How many bursts to pack at once: three quarters of the cores, never more
    than the memory holds. A worker holds a burst's files, its archive and a
    few frame-sized buffers; a compressed ARW is a byte a pixel, so the file
    size is the pixel count, and the numpy path holds about twice what C does."""
    per = (48 if core() is not None else 96) * max(file_bytes, 1)
    cores = max(1, (os.cpu_count() or 2) * 3 // 4)
    try:
        ram = os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE")
    except (ValueError, OSError, AttributeError):
        ram = 8 << 30
    return max(1, min(nbursts, cores, int((ram - (3 << 30)) // per)))


def _pack_one(job: tuple, log) -> tuple[str, int, int, str | None]:
    """(burst, bytes in, bytes out, what went wrong) for one burst."""
    bid, files, key, out = job
    try:
        m = pack(files, out, key, log=log)
    except Exception as e:
        return bid, 0, 0, str(e)
    return bid, sum(f["size"] for f in m["frames"]), out.stat().st_size, None


_LINES = None


def _worker_start(q) -> None:
    global _LINES
    _LINES = q
    # The studio's Stop sends SIGTERM to the whole group; a worker just ends,
    # and the parent's pool, unwinding, takes the rest down.


def _worker_pack(job: tuple) -> tuple[str, int, int, str | None]:
    return _pack_one(job, _LINES.put)


def _pack_parallel(jobs: list[tuple], workers: int, tick, ended) -> None:
    """Bursts on separate processes. Each burst is one worker's from start to
    finish, so the frames of a burst are still packed in their order; only
    whole bursts run side by side. Every line a worker prints comes back here,
    so the progress bar and the log are the same as a run on one core."""
    import multiprocessing as mp
    import queue
    ctx = mp.get_context("spawn")
    q = ctx.Queue()
    with ctx.Pool(workers, initializer=_worker_start, initargs=(q,)) as pool:
        pending = [pool.apply_async(_worker_pack, (job,)) for job in jobs]
        while pending:
            try:
                tick(q.get(timeout=0.25))
            except queue.Empty:
                pass
            still = []
            for r in pending:
                if r.ready():
                    while True:            # its own lines first, then how it ended
                        try:
                            tick(q.get_nowait())
                        except queue.Empty:
                            break
                    ended(*r.get())
                else:
                    still.append(r)
            pending = still
    while True:
        try:
            tick(q.get_nowait())
        except queue.Empty:
            break


def check_shoot(shoot: Path, log=print) -> int:
    """Unpack every packed burst of a shoot in memory and check it: each frame
    against the checksum it was packed with, and against the RAW on this disk
    when that is here. Reads only; nothing is written anywhere."""
    sys.path.insert(0, str(_here()))
    import archive  # noqa: E402
    import library  # noqa: E402
    from common import human  # noqa: E402
    where = library.paths(Path(shoot).expanduser().resolve())
    files = archive.local_packed(where.shoot)
    if not files:
        log(f"{where.shoot.name} has no packed bursts to check.")
        return 0
    try:
        raw = library.raw_dir(where.shoot)
    except library.NotAShoot:
        raw = where.shoot / "raw"
    total = sum(len(read_manifest(q.read_bytes())[0]["frames"]) for q in files)
    good = bad = matched = 0
    done = 0
    log(f"@@ checkpacked 0 {total}")
    for q in files:
        try:
            got = _unpack_bytes(q.read_bytes())
        except ValueError as e:
            m, _ = read_manifest(q.read_bytes())
            n = len(m["frames"])
            bad += n
            done += n
            log(f"  - {q.name}: does not unpack: {e}")
            log(f"@@ checkpacked {done} {total}")
            continue
        for name, data in got.items():
            done += 1
            here = raw / name
            if archive.local(here):
                if hashlib.sha256(data).hexdigest() != archive.sha256(here):
                    bad += 1
                    log(f"  - {name}: unpacks whole, but differs from the RAW in {raw.name}/")
                    continue
                matched += 1
            good += 1
            log(f"@@ checkpacked {done} {total}")
        log(f"  {q.name}: {len(got)} frames unpacked and matched, {human(q.stat().st_size)}")
    said = (f"{good} of {total} frames unpack exactly as they were packed; "
            f"{matched} of them also match the RAW on this Mac.")
    if bad:
        said += f" {bad} do not, and are listed above."
    log(said)
    return 1 if bad else 0


def export_shoot(shoot: Path, dest: Path, log=print) -> int:
    """Every frame of a shoot's packed bursts, unpacked into `dest` as the RAW
    it was, with its own name and time: the shoot's own packed/ first, then any
    packed burst recorded in iCloud that is not here.

    Nothing is written over. A file already in `dest` with a frame's name is
    left alone: skipped when it is that frame, the same bytes, and named as
    refused when it is not. Every frame is checked against the checksum it
    was packed with before it is given its name."""
    sys.path.insert(0, str(_here()))
    import archive  # noqa: E402
    import library  # noqa: E402
    where = library.paths(Path(shoot).expanduser().resolve())
    dest = Path(dest).expanduser()
    sources: dict[str, Path] = {q.name: q for q in archive.local_packed(where.shoot)}
    for file in archive.load_manifest(where.shoot).get("packed") or {}:
        up = archive.packed_dest(where.shoot, file)
        if file not in sources and up.exists():
            sources[file] = up
    if not sources:
        log(f"{where.shoot.name} has no packed bursts, here or in iCloud.")
        return 0
    try:
        dest.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        log(f"cannot make {dest}: {e}")
        return 1
    total = 0
    for q in sources.values():
        try:
            total += len(read_manifest(q.read_bytes())[0]["frames"]) if archive.local(q) else 0
        except (OSError, ValueError):
            pass
    wrote = same = refused = bad = done = 0
    log(f"@@ unpack 0 {max(total, 1)}")
    for file, q in sorted(sources.items()):
        if not archive.local(q) and not archive.materialise(q):
            bad += 1
            log(f"  - {file}: iCloud did not hand it over")
            continue
        try:
            raw = q.read_bytes()
            manifest, _ = read_manifest(raw)
            got = _unpack_bytes(raw)
        except (OSError, ValueError) as e:
            bad += 1
            log(f"  - {file}: does not unpack: {e}")
            continue
        for f in manifest["frames"]:
            name, data = f["name"], got.get(f["name"])
            done += 1
            target = dest / name
            if data is None:
                continue
            if target.exists():
                if target.is_file() and hashlib.sha256(target.read_bytes()).hexdigest() == f["sha256"]:
                    same += 1
                else:
                    refused += 1
                    log(f"  - {name}: a different file of that name is already in {dest.name}; left alone")
                continue
            fd, tmp = tempfile.mkstemp(dir=dest, prefix=f".{name}.", suffix=".tmp")
            try:
                with os.fdopen(fd, "wb") as fh:
                    fh.write(data)
                    fh.flush()
                    os.fsync(fh.fileno())
                os.utime(tmp, ns=(f["mtime_ns"], f["mtime_ns"]))
                os.link(tmp, target)            # never over a name that appeared meanwhile
                wrote += 1
            except FileExistsError:
                refused += 1
                log(f"  - {name}: a file of that name appeared in {dest.name}; left alone")
            finally:
                Path(tmp).unlink(missing_ok=True)
            log(f"@@ unpack {done} {max(total, done)}")
        del got
    said = f"{wrote} RAWs unpacked into {dest}, each checked against the checksum it was packed with."
    if same:
        said += f" {same} were there already."
    if refused:
        said += f" {refused} were not written, because a different file had the name."
    if bad:
        said += f" {bad} packed bursts could not be read."
    log(said)
    return 1 if (refused or bad) else 0


def _here() -> Path:
    return Path(__file__).resolve().parent


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="pl burstpack", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pack")
    p.add_argument("out", type=Path)
    p.add_argument("raws", type=Path, nargs="+")
    p.add_argument("--key", help="the frame stored whole (default: the first)")
    u = sub.add_parser("unpack")
    u.add_argument("archive", type=Path)
    u.add_argument("dest", type=Path)
    u.add_argument("names", nargs="*")
    v = sub.add_parser("verify")
    v.add_argument("archive", type=Path)
    ls = sub.add_parser("list")
    ls.add_argument("archive", type=Path)
    sh = sub.add_parser("shoot")
    sh.add_argument("shoot", type=Path)
    sh.add_argument("--apply", action="store_true")
    ck = sub.add_parser("check")
    ck.add_argument("shoot", type=Path)
    ex = sub.add_parser("export")
    ex.add_argument("shoot", type=Path)
    ex.add_argument("dest", type=Path)
    b = sub.add_parser("bench")
    b.add_argument("shoot", type=Path)
    b.add_argument("--bursts", type=int, default=3)
    a = ap.parse_args(argv)

    if a.cmd == "pack":
        m = pack(a.raws, a.out, a.key)
        before = sum(f["size"] for f in m["frames"])
        after = a.out.stat().st_size
        print(f"{len(m['frames'])} frames, {before:,} -> {after:,} bytes ({after / before:.1%}), "
              f"every frame unpacked and matched")
    elif a.cmd == "unpack":
        unpack(a.archive, a.dest, a.names or None)
    elif a.cmd == "verify":
        data = a.archive.read_bytes()
        got = _unpack_bytes(data)
        print(f"{len(got)} frames, every one matches its checksum")
    elif a.cmd == "list":
        m, _ = read_manifest(a.archive.read_bytes())
        for f in m["frames"]:
            ref = "whole" if f["ref"] is None else "from " + m["frames"][f["ref"]]["name"]
            print(f"  {f['name']:<16} {f['size']:>12,} -> {f['length']:>12,}  {f['length'] / f['size']:6.1%}  {f['codec']} {ref}")
    elif a.cmd == "shoot":
        # Stop in the app is SIGTERM: unwind, so the pool of workers is ended
        # and a half-written archive is removed rather than left in packed/.
        sys.path.insert(0, str(_here()))
        from common import stop_cleanly_on_sigterm  # noqa: E402
        stop_cleanly_on_sigterm()
        return pack_shoot(a.shoot, a.apply, log=lambda line: print(line, flush=True))
    elif a.cmd == "check":
        return check_shoot(a.shoot, log=lambda line: print(line, flush=True))
    elif a.cmd == "export":
        sys.path.insert(0, str(_here()))
        from common import stop_cleanly_on_sigterm  # noqa: E402
        stop_cleanly_on_sigterm()
        return export_shoot(a.shoot, a.dest, log=lambda line: print(line, flush=True))
    elif a.cmd == "bench":
        bursts = bursts_of(a.shoot)[:a.bursts]
        if not bursts:
            print(f"{a.shoot.name}: no bursts of two or more frames with their RAWs on this Mac")
            return 1
        tot_in = tot_xz = tot_out = 0
        with tempfile.TemporaryDirectory() as td:
            for i, (_, files, key) in enumerate(bursts):
                print(f"burst {i + 1}: {len(files)} frames, {key or files[0].name} whole")
                out = Path(td) / f"b{i}{EXT}"
                m = pack(files, out, key)
                n_in = sum(f["size"] for f in m["frames"])
                n_xz = sum(len(lzma.compress(p.read_bytes(), preset=6)) for p in files)
                tot_in, tot_xz, tot_out = tot_in + n_in, tot_xz + n_xz, tot_out + out.stat().st_size
                out.unlink()
        print(f"\n{tot_in:,} bytes of RAW: xz {tot_xz / tot_in:.1%}, burstpack {tot_out / tot_in:.1%} "
              f"(every frame unpacked and matched)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
