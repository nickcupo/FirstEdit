/*
 * burstcore.c - burstpack's inner loop, in C.
 *
 * The same model as burstpack.run_craw and the same coder as rans_encode and
 * Decoder, written out per pixel instead of per numpy call. It must produce
 * the SAME BYTES as the numpy code: an archive packed by either is unpacked
 * by either. tests/test_burstpack.py packs with both and compares them byte
 * for byte, and burstpack.py refuses to load this library if the constants
 * it reports differ from its own.
 *
 * Integers only, as the numpy decoder is. A right shift of a negative number
 * is written as a floor (asr), not left to the compiler.
 *
 * Built by app/build.sh into the app, and by burstpack.py itself from a
 * checkout, the first time it is needed. Nothing here allocates more than a
 * few rows; the frame-sized buffers are the caller's.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define Q 12
#define PREC 14
#define PMASK ((1u << PREC) - 1)
#define RANS_L (1ull << 16)
#define DIRECT 32
#define DIRECT_TOP 5                 /* bit length of DIRECT - 1 */
#define NKINDS 5                     /* mn, rng, imax, imin, d */
#define NEVENTS 20                   /* per row pair: 6 header events, 14 steps */

static const int64_t HDR_T[] = {0, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 128};
static const int64_t DELTA_T[] = {0, 1, 2, 3, 4, 6, 8, 11, 16, 22, 32, 45, 64, 90, 128, 256};
static const int64_t ROOM_T[] = {0, 1, 2, 3, 4, 6, 8, 12, 16};
static const int64_t ICTX_T[] = {0, 16, 64, 256, 1024};
#define N_HDR (int)(sizeof HDR_T / sizeof *HDR_T)
#define N_DELTA (int)(sizeof DELTA_T / sizeof *DELTA_T)
#define N_ROOM (int)(sizeof ROOM_T / sizeof *ROOM_T)
#define N_ICTX (int)(sizeof ICTX_T / sizeof *ICTX_T)

static const int NCTX[NKINDS] = {N_HDR, N_HDR, N_ICTX, N_ICTX, N_DELTA * N_ROOM};
static const int NSYM[NKINDS] = {48, 48, 16, 16, 255};

enum { BC_OK = 0, BC_SHORT = -1, BC_NOSYM = -2, BC_NOEND = -3, BC_NOMEM = -4, BC_ARGS = -5 };

/* Everything the Python side checks before it trusts this library. */
int bc_constants(int64_t *out, int cap)
{
    int64_t v[128];
    int n = 0, i;
    v[n++] = 1;                      /* this layout's version */
    v[n++] = Q; v[n++] = PREC; v[n++] = DIRECT;
    v[n++] = N_HDR; for (i = 0; i < N_HDR; i++) v[n++] = HDR_T[i];
    v[n++] = N_DELTA; for (i = 0; i < N_DELTA; i++) v[n++] = DELTA_T[i];
    v[n++] = N_ROOM; for (i = 0; i < N_ROOM; i++) v[n++] = ROOM_T[i];
    v[n++] = N_ICTX; for (i = 0; i < N_ICTX; i++) v[n++] = ICTX_T[i];
    for (i = 0; i < NKINDS; i++) { v[n++] = NCTX[i]; v[n++] = NSYM[i]; }
    if (n > cap) return -n;
    memcpy(out, v, (size_t)n * sizeof *v);
    return n;
}

static inline int64_t asr(int64_t v, int s) { return v >= 0 ? (v >> s) : ~((~v) >> s); }
static inline int64_t clamp(int64_t v, int64_t lo, int64_t hi) { return v < lo ? lo : (v > hi ? hi : v); }
static inline int64_t imin64(int64_t a, int64_t b) { return a < b ? a : b; }
static inline int64_t imax64(int64_t a, int64_t b) { return a > b ? a : b; }
static inline int64_t iabs64(int64_t a) { return a < 0 ? -a : a; }

/* numpy.searchsorted(t, a, side="right") - 1 */
static inline int bucket(int64_t a, const int64_t *t, int n)
{
    int k = 0;
    while (k < n && t[k] <= a) k++;
    return k - 1;
}

static inline int64_t bitlen(int64_t z)
{
    int64_t n = 0;
    int b;
    for (b = 0; b < 24; b++) n += (z >> b) > 0;
    return n;
}

static inline int64_t shift_of(int64_t rng)
{
    int64_t sh = 0;
    int s;
    for (s = 0; s < 4; s++) sh += (sh == s) && ((0x80 << s) <= rng);
    return sh;
}

/* ------------------------------------------------------------ the blocks */

typedef struct { int64_t mx, mn, ix, in, d[14]; } Fields;

static inline uint64_t le64(const uint8_t *p)
{
    uint64_t v = 0;
    int i;
    for (i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}

static inline void put64(uint8_t *p, uint64_t v)
{
    int i;
    for (i = 0; i < 8; i++) { p[i] = (uint8_t)v; v >>= 8; }
}

static void read_block(const uint8_t *p, Fields *f)
{
    uint64_t lo = le64(p), hi = le64(p + 8);
    int k;
    f->mx = (int64_t)(lo & 0x7FF);
    f->mn = (int64_t)((lo >> 11) & 0x7FF);
    f->ix = (int64_t)((lo >> 22) & 0xF);
    f->in = (int64_t)((lo >> 26) & 0xF);
    for (k = 0; k < 14; k++) {
        int b = 30 + 7 * k;
        uint64_t v;
        if (b + 7 <= 64) v = lo >> b;
        else if (b >= 64) v = hi >> (b - 64);
        else v = (lo >> b) | (hi << (64 - b));
        f->d[k] = (int64_t)(v & 0x7F);
    }
}

static void write_block(uint8_t *p, const Fields *f)
{
    uint64_t lo = ((uint64_t)f->mx & 0x7FF) | (((uint64_t)f->mn & 0x7FF) << 11)
                | (((uint64_t)f->ix & 0xF) << 22) | (((uint64_t)f->in & 0xF) << 26);
    uint64_t hi = 0;
    int k;
    for (k = 0; k < 14; k++) {
        int b = 30 + 7 * k;
        uint64_t d = (uint64_t)f->d[k] & 0x7F;
        if (b + 7 <= 64) lo |= d << b;
        else if (b >= 64) hi |= d << (b - 64);
        else { lo |= d << b; hi |= d >> (64 - b); }
    }
    put64(p, lo);
    put64(p + 8, hi);
}

/* The step positions of a block: burstpack._positions, fifteen of them. */
static void positions(int64_t ix, int64_t in, int64_t *pos)
{
    int64_t a = imin64(ix, in), b = imax64(ix, in);
    int k;
    for (k = 0; k < 15; k++) {
        int64_t p = k + (k >= a);
        p += (p >= b) && (a != b);
        pos[k] = p;
    }
    if (a != b) pos[14] = ix;
}

/* burstpack.craw_pixels for one block. */
static void block_pixels(const Fields *f, int64_t *px)
{
    int64_t pos[15], sh = shift_of(f->mx - f->mn);
    int k;
    positions(f->ix, f->in, pos);
    for (k = 0; k < 16; k++) px[k] = 0;
    for (k = 0; k < 15; k++) {
        int64_t v = k < 14 ? imin64(f->d[k] * ((int64_t)1 << sh) + f->mn, 2047) : f->mn;
        px[pos[k]] = v;
    }
    px[f->in] = f->mn;
    px[f->ix] = f->mx;
}

static inline int64_t col_of(int b, int i) { return (int64_t)(b >> 1) * 32 + 2 * i + (b & 1); }

/* The pixel mosaic a strip decodes to, (H, W) int16. */
int bc_pixels(const uint8_t *strip, int H, int W, int16_t *P)
{
    int B = W / 16, r, b, i;
    if (W % 32) return BC_ARGS;
    for (r = 0; r < H; r++)
        for (b = 0; b < B; b++) {
            Fields f;
            int64_t px[16];
            read_block(strip + ((int64_t)r * B + b) * 16, &f);
            block_pixels(&f, px);
            for (i = 0; i < 16; i++) P[(int64_t)r * W + col_of(b, i)] = (int16_t)px[i];
        }
    return BC_OK;
}

/* ------------------------------------------------------------- the coder */

typedef struct {
    int dec;
    /* recording */
    int32_t *rctx, *rval;
    int64_t rpos;
    int64_t *counts;                 /* each kind's (nctx, nsym), one after another */
    /* decoding */
    uint64_t *x;
    const uint16_t *w;
    int64_t nw, p;
    const uint32_t *freq, *cum;      /* each kind's (nctx, nsym) */
    const uint8_t *lookup;           /* each kind's (nctx, 1 << PREC): every symbol fits a byte */
    int err;
} Coder;

static int64_t TOFF[NKINDS], LOFF[NKINDS];

static void offsets(void)
{
    int64_t t = 0, l = 0;
    int k;
    for (k = 0; k < NKINDS; k++) {
        TOFF[k] = t; LOFF[k] = l;
        t += (int64_t)NCTX[k] * NSYM[k];
        l += (int64_t)NCTX[k] << PREC;
    }
}

static inline void advance(Coder *c, int lane, uint64_t f, uint64_t cm, uint64_t slot)
{
    uint64_t x = f * (c->x[lane] >> PREC) + slot - cm;
    if (x < RANS_L) {
        if (c->p >= c->nw) { c->err = BC_SHORT; return; }
        x = (x << 16) | c->w[c->p++];
    }
    c->x[lane] = x;
}

static inline int64_t code_sym(Coder *c, int kind, int lane, int64_t ctx, int64_t v)
{
    if (!c->dec) {
        c->rctx[c->rpos] = (int32_t)ctx;
        c->rval[c->rpos] = (int32_t)v;
        c->rpos++;
        c->counts[TOFF[kind] + ctx * NSYM[kind] + v]++;
        return v;
    }
    if (c->err) return 0;
    {
        uint64_t slot = c->x[lane] & PMASK;
        int64_t s = c->lookup[LOFF[kind] + (ctx << PREC) + (int64_t)slot];
        uint64_t f = c->freq[TOFF[kind] + ctx * NSYM[kind] + s];
        if (!f) { c->err = BC_NOSYM; return 0; }
        advance(c, lane, f, c->cum[TOFF[kind] + ctx * NSYM[kind] + s], slot);
        return s;
    }
}

static inline int64_t code_bits(Coder *c, int lane, int64_t nb, int64_t v)
{
    if (!c->dec) {
        c->rctx[c->rpos] = (int32_t)nb;
        c->rval[c->rpos] = (int32_t)v;
        c->rpos++;
        return v;
    }
    if (c->err) return 0;
    {
        int sh = PREC - (int)nb;
        uint64_t slot = c->x[lane] & PMASK, got = slot >> sh;
        advance(c, lane, 1ull << sh, got << sh, slot);
        return (int64_t)got;
    }
}

static inline void zig(int64_t v, int64_t *sym, int64_t *nb, int64_t *mant)
{
    int64_t z = v >= 0 ? v * 2 : -v * 2 - 1, bl = bitlen(z);
    int big = z >= DIRECT;
    *nb = big ? bl - 1 : 0;
    *sym = big ? DIRECT + bl - DIRECT_TOP - 1 : z;
    *mant = big ? z - ((int64_t)1 << *nb) : 0;
}

static inline int64_t unzig(int64_t s, int64_t mant)
{
    int big = s >= DIRECT;
    int64_t nb = big ? s - DIRECT + DIRECT_TOP : 0;
    int64_t z = big ? ((int64_t)1 << nb) + mant : s;
    return (z & 1) ? -(z + 1) / 2 : z / 2;
}

static inline int64_t unzig_nb(int64_t s) { return s >= DIRECT ? s - DIRECT + DIRECT_TOP : 0; }

/* ------------------------------------------------------------- the model */

/*
 * burstpack.run_craw. dec = 0: `strip` is read and every symbol is recorded
 * into rctx/rval (NEVENTS events of n lanes per row pair, event by event)
 * and counted. dec = 1: symbols come from the stream and the strip is
 * written. Either way P gets the pixels.
 */
int bc_craw(int dec, int H, int W, int tile,
            uint8_t *strip, int16_t *P,
            const int16_t *Rp, int m, const int64_t *mv, int ntx,
            const int64_t *wfull, const int64_t *wpre, int nf,
            int32_t *rctx, int32_t *rval, int64_t *counts,
            const uint32_t *freq, const uint32_t *cum, const uint8_t *lookup,
            uint32_t *states, const uint16_t *words, int64_t nwords)
{
    const int B = W / 16, W4 = W + 4, Wm = W + 2 * m;
    const int inter = Rp != NULL;
    int32_t *Pp, *Ep;
    int64_t *row, *blk, *Eb_all, *lbase;
    int *txof;
    Coder c;
    int r0, l, i, k, j;
    if (W % 32 || (inter ? nf != 13 : nf != 4) || H < 1) return BC_ARGS;
    offsets();
    memset(&c, 0, sizeof c);
    c.dec = dec;
    c.rctx = rctx; c.rval = rval; c.counts = counts;
    c.freq = freq; c.cum = cum; c.lookup = lookup;
    c.w = words; c.nw = nwords;
    Pp = calloc((size_t)(H + 2) * W4, sizeof *Pp);
    Ep = calloc((size_t)(H + 2) * W4, sizeof *Ep);
    /* per row pair, mosaic layout: pre, part, wW, N, eN, act */
    row = malloc(sizeof *row * 6 * 2 * (size_t)W);
    /* per lane, 64 slots: 0 mnh, 1 mxh, 2 hctx, 3 mn, 4 mx, 5 ix, 6 in, 7 sh, 8 ictx, 9 lo,
       10 hi, 11 half, 12 dmax, 15-17 scratch, 18-32 pos, 33-48 Pb, 50-63 the steps */
    blk = malloc(sizeof *blk * (size_t)(2 * B) * 64);
    /* per lane: how wrong the header's prediction was at each of its 16 pixels */
    Eb_all = malloc(sizeof *Eb_all * (size_t)(2 * B) * 16);
    /* where each lane's first pixel is in the row pair's buffers (pixel i is 2i
       further on), and each column's tile: no division in the loops below */
    lbase = malloc(sizeof *lbase * (size_t)(2 * B));
    txof = malloc(sizeof *txof * (size_t)W);
    if (dec) c.x = malloc(sizeof *c.x * (size_t)(2 * B));
    if (!Pp || !Ep || !row || !blk || !Eb_all || !lbase || !txof || (dec && !c.x)) {
        free(Pp); free(Ep); free(row); free(blk); free(Eb_all); free(lbase); free(txof); free(c.x);
        return BC_NOMEM;
    }
    if (dec) for (l = 0; l < 2 * B; l++) c.x[l] = states[l];
    for (l = 0; l < 2 * B; l++) lbase[l] = (int64_t)(l / B) * W + col_of(l % B, 0);
    for (l = 0; l < W; l++) txof[l] = l / tile;

    for (r0 = 0; r0 < H; r0 += 2) {
        const int R = H - r0 < 2 ? H - r0 : 2, n = R * B;
        int64_t *pre = row, *part = row + 2 * W, *wWr = row + 4 * W, *Nr = row + 6 * W;
        int64_t *eNr = row + 8 * W, *actr = row + 10 * W;
        int rr, cc;
        for (rr = 0; rr < R; rr++) {
            const int r = r0 + rr, ty = r / tile;
            const int32_t *pr = Pp + (int64_t)r * W4, *er = Ep + (int64_t)r * W4;
            for (cc = 0; cc < W; cc++) {
                const int tx = txof[cc], ph = (r & 1) * 2 + (cc & 1);
                const int64_t *cf = wfull + ((int64_t)(ty * ntx + tx) * 4 + ph) * (nf + 1);
                const int64_t *cp = wpre + ((int64_t)(ty * ntx + tx) * 4 + ph) * nf;
                int64_t f[12], a, b;
                const int64_t idx = (int64_t)rr * W + cc;
                f[0] = pr[cc + 2]; f[1] = pr[cc]; f[2] = pr[cc + 4];
                if (inter) {
                    const int64_t dy = mv[(ty * ntx + tx) * 2], dx = mv[(ty * ntx + tx) * 2 + 1];
                    const int64_t y = r + dy + m, x = cc + dx + m;
                    const int16_t *q = Rp + y * Wm + x;
                    f[3] = q[0]; f[4] = q[-2]; f[5] = q[2];
                    f[6] = q[-2 * Wm]; f[7] = q[2 * Wm];
                    f[8] = q[-2 * Wm - 2]; f[9] = q[-2 * Wm + 2];
                    f[10] = q[2 * Wm - 2]; f[11] = q[2 * Wm + 2];
                }
                a = cp[nf - 1];
                b = cf[nf] + (1 << (Q - 1));
                for (j = 0; j < nf - 1; j++) { a += cp[j] * f[j]; b += cf[j + 1] * f[j]; }
                pre[idx] = clamp(asr(a + (1 << (Q - 1)), Q), 0, 2047);
                part[idx] = b;
                wWr[idx] = cf[0];
                Nr[idx] = f[0];
                eNr[idx] = er[cc + 2];
                actr[idx] = (int64_t)er[cc + 2] + (((int64_t)er[cc] + er[cc + 4]) >> 1);
            }
        }
#define LB(l) (blk + (int64_t)(l) * 64)
#define IDX(l, i) (lbase[l] + 2 * (i))
        /* the header's predictions, and in encoding the true fields */
        for (l = 0; l < n; l++) {
            int64_t *s = LB(l), mnh = 1 << 30, mxh = -(1 << 30), hs = 0;
            for (i = 0; i < 16; i++) {
                int64_t v = pre[IDX(l, i)];
                mnh = imin64(mnh, v); mxh = imax64(mxh, v);
                hs += eNr[IDX(l, i)];
            }
            s[0] = mnh; s[1] = mxh; s[2] = bucket(hs >> 4, HDR_T, N_HDR);
            if (!dec) {
                Fields fl;
                read_block(strip + ((int64_t)(r0 + l / B) * B + l % B) * 16, &fl);
                s[3] = fl.mn; s[4] = fl.mx; s[5] = fl.ix; s[6] = fl.in;
                for (k = 0; k < 14; k++) s[50 + k] = fl.d[k];     /* the true steps, 50..63 */
            }
        }
        /* mn: category, then bits */
        for (l = 0; l < n; l++) {
            int64_t *s = LB(l), sym, nb, mant;
            if (!dec) { zig(s[3] - s[0], &sym, &nb, &mant); s[16] = nb; s[17] = mant; }
            else sym = 0;
            s[15] = code_sym(&c, 0, l, s[2], sym);
        }
        for (l = 0; l < n; l++) {
            int64_t *s = LB(l);
            if (!dec) code_bits(&c, l, s[16], s[17]);
            else s[3] = unzig(s[15], code_bits(&c, l, unzig_nb(s[15]), 0)) + s[0];
        }
        /* rng: category, then bits */
        for (l = 0; l < n; l++) {
            int64_t *s = LB(l), sym, nb, mant;
            if (!dec) { zig(s[4] - s[3] - (s[1] - s[0]), &sym, &nb, &mant); s[16] = nb; s[17] = mant; }
            else sym = 0;
            s[15] = code_sym(&c, 1, l, s[2], sym);
        }
        for (l = 0; l < n; l++) {
            int64_t *s = LB(l), rng;
            if (!dec) { code_bits(&c, l, s[16], s[17]); rng = s[4] - s[3]; }
            else { rng = unzig(s[15], code_bits(&c, l, unzig_nb(s[15]), 0)) + s[1] - s[0]; s[4] = s[3] + rng; }
            s[7] = shift_of(rng);
            s[8] = imin64(bucket(s[1] - s[0], ICTX_T, N_ICTX), 4);
        }
        /* imax as a rank among the predictions, highest first, then imin, lowest first */
        for (j = 0; j < 2; j++) {
            for (l = 0; l < n; l++) {
                int64_t *s = LB(l), rank = 0, want;
                int64_t pv[16];
                for (i = 0; i < 16; i++) pv[i] = pre[IDX(l, i)];
                if (!dec) {
                    int64_t at = j ? s[6] : s[5];
                    for (i = 0; i < 16; i++)
                        rank += j ? (pv[i] < pv[at] || (pv[i] == pv[at] && i < at))
                                  : (pv[i] > pv[at] || (pv[i] == pv[at] && i < at));
                    code_sym(&c, 2 + j, l, s[8], rank);
                } else {
                    want = code_sym(&c, 2 + j, l, s[8], 0);
                    for (k = 0; k < 16; k++) {
                        rank = 0;
                        for (i = 0; i < 16; i++)
                            rank += j ? (pv[i] < pv[k] || (pv[i] == pv[k] && i < k))
                                      : (pv[i] > pv[k] || (pv[i] == pv[k] && i < k));
                        if (rank == want) break;
                    }
                    s[j ? 6 : 5] = k < 16 ? k : 0;
                }
            }
        }
        /* the block's pixels so far */
        for (l = 0; l < n; l++) {
            int64_t *s = LB(l), *pos = s + 18, *Pb = s + 33;
            int64_t mn = s[3], mx = s[4], lo, hi;
            positions(s[5], s[6], pos);
            for (i = 0; i < 16; i++) Pb[i] = 0;
            Pb[pos[14]] = mn; Pb[s[6]] = mn; Pb[s[5]] = mx;
            lo = imin64(mn, mx); hi = imax64(mn, mx);
            s[9] = lo; s[10] = hi;
            s[11] = ((int64_t)1 << s[7]) >> 1;
            s[12] = clamp(asr(hi - mn, (int)s[7]), 0, 127);
        }
        /* The fourteen steps, left to right. */
        {
            for (l = 0; l < n; l++) {
                int64_t *s = LB(l), *Pb = s + 33;
                for (i = 0; i < 16; i++) Eb_all[l * 16 + i] = iabs64(Pb[i] - pre[IDX(l, i)]);
            }
            for (k = 0; k < 14; k++) {
                for (l = 0; l < n; l++) {
                    int64_t *s = LB(l), *pos = s + 18, *Pb = s + 33, *Eb = Eb_all + l * 16;
                    const int64_t p = pos[k], mn = s[3], sh = s[7];
                    int64_t Wv, eW, ph, dh, act, up, room, ctx, d, v;
                    int flip;
                    const int64_t ip = IDX(l, p);
                    if (p > 0) { Wv = Pb[p - 1]; eW = Eb[p - 1]; }
                    else { Wv = Nr[IDX(l, 0)]; eW = eNr[IDX(l, 0)]; }
                    ph = asr(part[ip] + wWr[ip] * Wv, Q);
                    ph = clamp(ph, s[9], s[10]);
                    dh = clamp(asr(ph - mn + s[11], (int)sh), 0, 127);
                    act = asr(2 * eW + actr[ip], (int)sh);
                    up = s[12] - dh;
                    flip = dh > up;
                    room = imax64(imin64(dh, up), 0);
                    ctx = (int64_t)bucket(act, DELTA_T, N_DELTA) * N_ROOM + bucket(room, ROOM_T, N_ROOM);
                    if (!dec) {
                        int64_t e = s[50 + k] - dh;
                        code_sym(&c, 4, l, ctx, (flip ? -e : e) + 127);
                        d = s[50 + k];
                    } else {
                        int64_t e = code_sym(&c, 4, l, ctx, 0) - 127;
                        d = (flip ? -e : e) + dh;
                        s[50 + k] = d;
                    }
                    v = imin64(d * ((int64_t)1 << sh) + mn, 2047);
                    Pb[p] = v;
                    Eb[p] = iabs64(v - pre[ip]);
                }
            }
            /* max wins where the two positions are one, as in dcraw; then the rows */
            for (l = 0; l < n; l++) {
                int64_t *s = LB(l), *Pb = s + 33, *Eb = Eb_all + l * 16;
                const int r = r0 + l / B;
                const int64_t c0 = lbase[l] - (int64_t)(l / B) * W;
                Pb[s[5]] = s[4];
                for (i = 0; i < 16; i++) {
                    const int64_t cc2 = c0 + 2 * i;
                    Pp[(int64_t)(r + 2) * W4 + cc2 + 2] = (int32_t)Pb[i];
                    Ep[(int64_t)(r + 2) * W4 + cc2 + 2] = (int32_t)Eb[i];
                    P[(int64_t)r * W + cc2] = (int16_t)Pb[i];
                }
                if (dec) {
                    Fields fl;
                    fl.mn = s[3]; fl.mx = s[4]; fl.ix = s[5]; fl.in = s[6];
                    for (k = 0; k < 14; k++) fl.d[k] = s[50 + k];
                    write_block(strip + ((int64_t)r * B + l % B) * 16, &fl);
                }
            }
        }
        for (rr = 0; rr < R; rr++) {
            int32_t *pp = Pp + (int64_t)(r0 + rr + 2) * W4, *ep = Ep + (int64_t)(r0 + rr + 2) * W4;
            pp[0] = pp[2]; pp[1] = pp[3]; pp[W + 2] = pp[W]; pp[W + 3] = pp[W + 1];
            ep[0] = ep[2]; ep[1] = ep[3]; ep[W + 2] = ep[W]; ep[W + 3] = ep[W + 1];
        }
        if (c.err) break;
#undef LB
#undef IDX
    }
    if (dec && !c.err) {
        if (c.p != c.nw) c.err = BC_NOEND;
        for (l = 0; l < 2 * B && !c.err; l++)
            if (c.x[l] != RANS_L) c.err = BC_NOEND;
    }
    free(Pp); free(Ep); free(row); free(blk); free(Eb_all); free(lbase); free(txof); free(c.x);
    return c.err;
}

/* ------------------------------------------------------------- rANS out */

/*
 * burstpack.rans_encode over what bc_craw recorded. Returns the number of
 * words written, or a negative error. `words` must hold one per symbol.
 */
int64_t bc_rans_encode(int H, int B, const int32_t *rctx, const int32_t *rval,
                       const uint32_t *freq, const uint32_t *cum,
                       uint32_t *states, uint16_t *words, int64_t cap)
{
    static const int KIND_OF[NEVENTS] = {0, -1, 1, -1, 2, 3, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4};
    const int npairs = (H + 1) / 2;
    uint64_t *x = malloc(sizeof *x * (size_t)(2 * B));
    int64_t nw = 0, lo, hi;
    int p, j, l;
    if (!x) return BC_NOMEM;
    offsets();
    for (l = 0; l < 2 * B; l++) x[l] = RANS_L;
    for (p = npairs - 1; p >= 0; p--) {
        const int R = H - 2 * p < 2 ? H - 2 * p : 2, n = R * B;
        const int64_t base = (int64_t)p * NEVENTS * 2 * B;
        for (j = NEVENTS - 1; j >= 0; j--) {
            const int kind = KIND_OF[j];
            for (l = n - 1; l >= 0; l--) {
                const int64_t at = base + (int64_t)j * n + l;
                uint64_t f, cm;
                if (kind < 0) {
                    const int sh = PREC - rctx[at];
                    f = 1ull << sh;
                    cm = (uint64_t)rval[at] << sh;
                } else {
                    const int64_t t = TOFF[kind] + (int64_t)rctx[at] * NSYM[kind] + rval[at];
                    f = freq[t]; cm = cum[t];
                }
                if (!f) { free(x); return BC_NOSYM; }
                if (x[l] >= (f << 18)) {
                    if (nw >= cap) { free(x); return BC_SHORT; }
                    words[nw++] = (uint16_t)(x[l] & 0xFFFF);
                    x[l] >>= 16;
                }
                x[l] = ((x[l] / f) << PREC) + x[l] % f + cm;
            }
        }
    }
    for (l = 0; l < 2 * B; l++) states[l] = (uint32_t)x[l];
    /* Written last event first and last lane first; the decoder reads the other way. */
    for (lo = 0, hi = nw - 1; lo < hi; lo++, hi--) {
        uint16_t t = words[lo];
        words[lo] = words[hi];
        words[hi] = t;
    }
    free(x);
    return nw;
}

/* ------------------------------------------------- the encoder's helpers */

/*
 * burstpack.fit_weights' sums: for every tile and colour, X'X, X'y and the
 * count, over the features the decoder will see (W, N, NW, NE, then the nine
 * of the reference, then 1). Integers, so numpy's sums and these are equal.
 */
int bc_fit(const int16_t *P, int H, int W, int tile,
           const int16_t *Rp, int m, const int64_t *mv, int ntx, int nf,
           int64_t *xtx, int64_t *xty, int64_t *cnt)
{
    const int D = nf + 1, Wm = W + 2 * m;
    int r, cc, a, b;
    if ((Rp != NULL) != (nf == 13) || (nf != 4 && nf != 13)) return BC_ARGS;
    for (r = 0; r < H; r++) {
        const int ty = r / tile;
        const int16_t *up = r >= 2 ? P + (int64_t)(r - 2) * W : NULL, *pr = P + (int64_t)r * W;
        for (cc = 0; cc < W; cc++) {
            const int tx = cc / tile, g = (ty * ntx + tx) * 4 + (r & 1) * 2 + (cc & 1);
            int64_t f[14], y = pr[cc];
            int64_t *X = xtx + (int64_t)g * D * D, *Y = xty + (int64_t)g * D;
            f[1] = up ? up[cc] : 0;
            f[2] = up ? up[cc >= 2 ? cc - 2 : cc] : 0;
            f[3] = up ? up[cc + 2 < W ? cc + 2 : cc] : 0;
            f[0] = (cc % 32) < 2 ? f[1] : pr[cc - 2];
            if (nf == 13) {
                const int64_t dy = mv[(ty * ntx + tx) * 2], dx = mv[(ty * ntx + tx) * 2 + 1];
                const int16_t *q = Rp + (r + dy + m) * Wm + (cc + dx + m);
                f[4] = q[0]; f[5] = q[-2]; f[6] = q[2];
                f[7] = q[-2 * Wm]; f[8] = q[2 * Wm];
                f[9] = q[-2 * Wm - 2]; f[10] = q[-2 * Wm + 2];
                f[11] = q[2 * Wm - 2]; f[12] = q[2 * Wm + 2];
            }
            f[nf] = 1;
            for (a = 0; a < D; a++) {         /* the upper half; mirrored below */
                const int64_t fa = f[a];
                int64_t *row = X + (int64_t)a * D;
                for (b = a; b < D; b++) row[b] += fa * f[b];
                Y[a] += fa * y;
            }
            cnt[g]++;
        }
    }
    {
        const int64_t groups = (int64_t)((H + tile - 1) / tile) * ntx * 4;
        int64_t g;
        for (g = 0; g < groups; g++)
            for (a = 0; a < D; a++)
                for (b = 0; b < a; b++)
                    xtx[(g * D + a) * D + b] = xtx[(g * D + b) * D + a];
    }
    return BC_OK;
}

/*
 * burstpack.estimate_motion's search: for each tile of the half-size frame,
 * the candidate offset with the least sum of absolute differences, the first
 * one found on a tie. `cur` is padded to whole tiles; `ref` is padded by
 * `pad` on every side; both by repeating their edges, as numpy.pad does.
 */
int bc_motion(const int32_t *cur, int Hp, int Wp, const int32_t *ref, int h, int w, int pad,
              int t, const int64_t *cands, int ncand, int64_t *mv)
{
    const int nty = Hp / t, ntx = Wp / t, Wr = w + 2 * pad;
    int ty, tx, k, y, x;
    for (ty = 0; ty < nty; ty++)
        for (tx = 0; tx < ntx; tx++) {
            int64_t best = -1;
            mv[(ty * ntx + tx) * 2] = 0;
            mv[(ty * ntx + tx) * 2 + 1] = 0;
            for (k = 0; k < ncand; k++) {
                const int64_t dy = cands[2 * k], dx = cands[2 * k + 1];
                int64_t sad = 0;
                if (dy > pad - 1 || -dy > pad - 1 || dx > pad - 1 || -dx > pad - 1) continue;
                for (y = ty * t; y < (ty + 1) * t; y++) {
                    const int ys = y < h ? y : h - 1;
                    const int32_t *cr = cur + (int64_t)y * Wp;
                    const int32_t *rr = ref + (int64_t)(pad + dy + ys) * Wr + pad + dx;
                    for (x = tx * t; x < (tx + 1) * t; x++) {
                        const int32_t d = cr[x] - rr[x < w ? x : w - 1];
                        sad += d < 0 ? -d : d;
                    }
                    if (best >= 0 && sad >= best) break;   /* already no better */
                }
                if (best < 0 || sad < best) {
                    best = sad;
                    mv[(ty * ntx + tx) * 2] = dy;
                    mv[(ty * ntx + tx) * 2 + 1] = dx;
                }
            }
        }
    return BC_OK;
}
