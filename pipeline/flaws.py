#!/usr/bin/env python3
"""
flaws.py - learn what the photographer drops, from the reasons they gave.

The studio asks why a frame was dropped (my shadow, cut off, expression,
blur, exposure, composition) and keeps the answers in each shoot's
`decisions/labels.json`. This trains one small probe per reason on CLIP
embeddings of the frames: the dropped frames with that reason against the
keepers of the same shoots. The cull then scores every frame with the
probes and uses the strongest as a penalty, never a veto.

    ./pl learn            # train a new version from every finished shoot, and check it
    ./pl learn --min 20   # refuse to train a reason with fewer examples
    ./pl learn --dry-run  # what it would learn from, with nothing written

What this trains is a candidate, never the model in use. It goes into the
learned folder (learned.py) and the cull uses it only once the keeper check
has scored it against every photo he kept, on every shoot, and found none of
them hidden. The probe's own held-out AUC is not that check: a retrain on one
shoot's 44 reasons scored 0.90 and 0.97 and would still have hidden 15 of his
keepers on the next two shoots.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
ROOT = Path(os.environ.get("PHOTOS_ROOT", Path.home() / "photos")).expanduser()
from common import decision_path, MODELS  # noqa: E402

# Where `./pl learn` used to write, and where a checkout's culls read it from.
# Nothing reads it any more; learned.py takes it in once as a candidate, so the
# model that was in use is checked like any other instead of vanishing.
LEGACY = MODELS / "flaws.json"
LEARNER = "drop-reasons"
# A reason that is taste rather than a fault. His rule is that the cull throws
# out only what can be measured, so "just no" is kept on the frame and never
# becomes a detector.
NOT_A_FAULT = {"just no"}


def fit(X: np.ndarray, y: np.ndarray, l2: float = 3e-2, iters: int = 3000, lr: float = 0.5) -> tuple[np.ndarray, float]:
    """Logistic regression, positives up-weighted so a dozen drops count."""
    w = np.zeros(X.shape[1])
    b = 0.0
    pw = (len(y) - y.sum()) / max(1.0, y.sum())
    for _ in range(iters):
        p = 1 / (1 + np.exp(-(X @ w + b)))
        g = (p - y) * np.where(y > 0, pw, 1.0)
        w -= lr * (X.T @ g / len(y) + l2 * w)
        b -= lr * g.mean()
    return w, float(b)


def _json(p: Path, default):
    try:
        return json.loads(p.read_text()) if p.exists() else default
    except (OSError, ValueError):
        return default


def gather(root: Path | None = None) -> tuple[list[tuple[str, Path, str, str | None, bool]], dict]:
    """(shoot, cull folder, stem, drop reason or None, is a keeper) for every
    shoot that teaches, and a count of what was left out and why. A keeper
    here is a frame he exported (learned.taught).

    A reason teaches only while the frame's own verdict is OUT by HIS verdict:
    he pressed D on it (an override of 2 or less) and it is not among his
    keepers. A reason on a frame he never decided about is a note, not a
    verdict, and it is left as one. The
    learner used to take every labelled frame as an example of its flaw, which
    made a reason left on a frame he then kept (TSC04557, "expression", in his
    keepers on 2026-09-16) into evidence that frames like his keeper are bad,
    and a cleared reason into a reason called "other". Nothing is deleted from
    labels.json: what does not count is left where he put it and counted here.

    Only shoots that teach are read (learned.teaches: marked finished, or with
    frames he exported). A shoot still being culled has verdicts he has not
    settled."""
    import learned
    root = Path(root or ROOT)
    out: list[tuple[str, Path, str, str | None, bool]] = []
    left_out = {"cleared": 0, "on a frame you kept": 0, "not out by your verdict": 0, "not a fault": 0,
                "on a shoot not finished yet": 0}
    base = root / "shoots"
    if not base.is_dir():
        return out, left_out
    for shoot in sorted(p for p in base.iterdir() if p.is_dir()):
        cull = learned.cull_dir(shoot)
        labels = _json(decision_path(cull, "labels.json"), {})
        st = _json(decision_path(cull, "organize.json"), {})
        over = {Path(k).stem: v.get("rating") for k, v in (st.get("photos") or {}).items()
                if isinstance(v, dict) and v.get("rating") is not None}
        key = _json(decision_path(cull, "selects.json"), [])
        keepers = {Path(f).stem for f in key} if isinstance(key, list) else set()
        keepers |= {s for s, r in over.items() if r >= 3}
        if not learned.teaches(shoot):
            left_out["on a shoot not finished yet"] += sum(1 for w in labels.values() if w)
            continue
        # What stands for "not this fault" is the frames he exported
        # (learned.taught), not every frame he kept: he culls further in
        # PhotoLab, and a keeper he did not export may well be one he threw
        # out for the fault being learned. A reason on any keeper of his is
        # still left out, below, as it always was.
        mine, _ = learned.taught(shoot)
        keepers |= mine
        labelled = set()
        for f, w in labels.items():
            stem = Path(f).stem
            labelled.add(stem)
            if not w:
                left_out["cleared"] += 1
                continue
            if w in NOT_A_FAULT:
                left_out["not a fault"] += 1
                continue
            if stem in keepers:
                left_out["on a frame you kept"] += 1
                continue
            if (over.get(stem) if stem in over else 9) > 2:
                left_out["not out by your verdict"] += 1
                continue
            out.append((shoot.name, cull, stem, w, False))
        for stem in sorted(mine - labelled):
            out.append((shoot.name, cull, stem, None, True))
    return out, left_out


AUC_FLOOR = 0.65          # below this a probe is noise and is not written


def held_out(X: np.ndarray, y: np.ndarray, groups: np.ndarray | None = None) -> tuple[float, float]:
    """Held out by SHOOT: every shoot is scored by a probe trained on the
    others. Area under the ROC curve over both classes, and precision at the
    probe's own threshold. Both can fail, which is the point of them.

    This used to shuffle frames into five folds, so frames of one burst sat on
    both sides of the split and the probe was marked on near-copies of what it
    was taught; evaluate.py already says why that is not honest. With every
    positive on one shoot there is nothing to hold out, and train() does not
    ask."""
    groups = np.asarray(groups if groups is not None else np.zeros(len(y)))
    scores = np.zeros(len(y))
    seen = np.zeros(len(y), bool)
    for g in np.unique(groups):
        te = groups == g
        tr = ~te
        if y[tr].sum() == 0 or (y[tr] == 0).sum() == 0:
            continue
        w, b = fit(X[tr], y[tr], iters=800)
        scores[te] = X[te] @ w + b
        seen[te] = True
    sp, sn = scores[seen & (y > 0)], scores[seen & (y == 0)]
    if not len(sp) or not len(sn):
        return 0.5, 0.0
    # AUC as the chance a random positive outranks a random negative.
    auc = float((sp[:, None] > sn[None, :]).mean() + 0.5 * (sp[:, None] == sn[None, :]).mean())
    picked = seen & (scores > 0)
    prec = float(y[picked].mean()) if picked.any() else 0.0
    return auc, prec


def permutation_auc(X: np.ndarray, y: np.ndarray, groups: np.ndarray | None = None, n: int = 20) -> np.ndarray:
    """The same fit on shuffled labels. A probe has to beat what chance produces
    on this many examples in this many dimensions, which at a few dozen positives
    and 768 dimensions is a good deal more than 0.5."""
    rng = np.random.default_rng(1)
    out = []
    for _ in range(n):
        yp = y.copy()
        rng.shuffle(yp)
        out.append(held_out(X, yp, groups)[0])
    return np.array(out)


def vectors(rows: list[tuple[str, Path, str, str | None, bool]]) -> tuple[np.ndarray | None, str]:
    """A unit CLIP vector per training row: from each shoot's cull/similar.npz
    where the cull left one, from the learned folder where one was measured off
    the previews before, else measured off cull/previews now - and what is
    measured now is kept, so it is measured once and not once a run.

    The previews outlive the RAWs, so nothing here decays when a shoot is
    archived; what it used to do was pay 805 CLIP passes again on every run.
    Returns the vectors (None when CLIP is not here) and a note."""
    import learned
    E: list[np.ndarray | None] = [None] * len(rows)
    by_shoot: dict[tuple[str, Path], list[int]] = {}
    for i, (shoot, cull, _, _, _) in enumerate(rows):
        by_shoot.setdefault((shoot, cull), []).append(i)
    kept = 0
    for (shoot, cull), idx in by_shoot.items():
        got = {**(learned.cached_vectors(shoot) or {}), **(learned.similar_vectors(cull) or {})}
        for i in idx:
            v = got.get(rows[i][2])
            if v is not None:
                E[i] = v
                kept += 1
    todo = [i for i, v in enumerate(E) if v is None]
    todo = [i for i in todo if (rows[i][1] / "previews" / f"{rows[i][2]}.jpg").exists()]
    note = f"{kept} vectors already measured"
    if todo:
        from quality import Quality
        q = Quality()
        if not q._load_clip():
            keep = [i for i, v in enumerate(E) if v is not None]
            if not keep:
                return None, "CLIP not available, and no shoot carries its vectors"
        else:
            _, emb = q.aesthetic_batch([rows[i][1] / "previews" / f"{rows[i][2]}.jpg" for i in todo])
            fresh: dict[str, dict[str, np.ndarray]] = {}
            for i, v in zip(todo, emb):
                E[i] = np.asarray(v, dtype=np.float64)
                fresh.setdefault(rows[i][0], {})[rows[i][2]] = E[i]
            for shoot, got in fresh.items():
                learned.keep_vectors(shoot, got)
            note += f", {len(todo)} measured off the previews and kept"
    return E, note


def train(min_examples: int = 12, root: Path | None = None) -> dict:
    """A candidate model and a report of what it was learned from. The model's
    "reasons" is empty when nothing is ready, and report says why per reason
    ("needs" is how many more examples it wants)."""
    rows, left_out = gather(root)
    report: dict = {"reasons": {}, "left_out": left_out, "shoots": sorted({r[0] for r in rows if r[3]}),
                    "keepers": sum(1 for r in rows if r[4]), "min": min_examples}
    model: dict = {"reasons": {}, "n": 0}
    if not any(r[3] for r in rows):
        report["note"] = "no reasons on a frame you dropped, on a finished shoot"
        return {**model, "report": report}
    E, note = vectors(rows)
    report["vectors"] = note
    if E is None:
        report["note"] = note
        return {**model, "report": report}
    use_rows = [i for i, v in enumerate(E) if v is not None]
    X_all = np.array([E[i] for i in use_rows], dtype=np.float64)
    X_all = X_all / (np.linalg.norm(X_all, axis=1, keepdims=True) + 1e-9)
    R = [rows[i][3] for i in use_rows]
    K = np.array([rows[i][4] for i in use_rows], dtype=float)
    G = np.array([rows[i][0] for i in use_rows])
    model["n"] = len(use_rows)
    for r in sorted({x for x in R if x}):
        y = np.array([1.0 if rr == r else 0.0 for rr in R])
        use = (y > 0) | (K > 0)
        n_pos = int(y.sum())
        shoots_with = sorted(set(G[y > 0].tolist()))
        # Which shoots it is on, so the page can say "all on 2026-09-16" and
        # he knows which shoot the next examples must NOT come from.
        e = {"examples": n_pos, "shoots": len(shoots_with), "needs": max(0, min_examples - n_pos),
             "on": shoots_with}
        report["reasons"][r] = e
        if n_pos < min_examples or K.sum() < min_examples:
            e["state"] = "too few"
            print(f"  {r}: {n_pos} examples, need {min_examples}; skipped")
            continue
        # Held out by shoot needs the reason on two shoots at least: a probe
        # that has only ever seen one shoot's light and one shoot's people has
        # shown nothing about the next shoot, which is the only one it is for.
        if len(shoots_with) < 2:
            e["state"] = "one shoot"
            print(f"  {r}: {n_pos} examples, all on {shoots_with[0]}; it needs a second finished shoot to be checked across shoots")
            continue
        X, yy, gg = X_all[use], y[use], G[use]
        auc, prec = held_out(X, yy, gg)
        e["auc"] = round(auc, 3)
        # Recall on held-out positives was the old number and it could not fail:
        # with 768 dimensions and a few dozen positives the bias sits low enough
        # that nearly everything scores positive, so recall reads 1.00 while the
        # probe separates nothing. Measured on a real shoot, a probe with
        # "leave-one-out recall 1.00" scored the photographer's own keepers +0.36
        # and the frames the photographer had rejected +0.39. AUC over both classes can fail,
        # so it is what decides whether a probe is written at all.
        if auc < AUC_FLOOR:
            e["state"] = "chance"
            print(f"  {r}: {n_pos} examples, held-out AUC {auc:.2f} — no better than chance, not written")
            continue
        null = permutation_auc(X, yy, gg)
        beat = float((null >= auc).mean())
        e["shuffled_auc"] = round(float(null.mean()), 3)
        if beat > 0.05:
            e["state"] = "chance"
            print(f"  {r}: {n_pos} examples, AUC {auc:.2f} but shuffled labels reach it {beat:.0%} of the time — not written")
            continue
        w, b = fit(X, yy)
        e["state"] = "learned"
        model["reasons"][r] = {"w": w.tolist(), "b": b, "n": n_pos, "auc": round(auc, 3),
                               "precision": round(prec, 3), "shuffled_auc": round(float(null.mean()), 3),
                               "shoots": len(shoots_with)}
        print(f"  {r}: {n_pos} examples on {len(shoots_with)} shoots, held out by shoot AUC {auc:.2f} against "
              f"{null.mean():.2f} for shuffled labels, precision {prec:.2f}")
    return {**model, "report": report}


def score(embs: np.ndarray, model: dict) -> tuple[np.ndarray, list[str]]:
    """Per frame: the strongest flaw probability and its name ('' when none passes 0.5)."""
    n = embs.shape[0]
    best = np.zeros(n, dtype=np.float32)
    names = [""] * n
    if not model.get("reasons"):
        return best, names
    E = np.asarray(embs, dtype=np.float64)
    E = E / (np.linalg.norm(E, axis=1, keepdims=True) + 1e-9)
    for r, m in model["reasons"].items():
        p = 1 / (1 + np.exp(-(E @ np.array(m["w"]) + m["b"])))
        for i in range(n):
            if p[i] > best[i]:
                best[i] = p[i]
                names[i] = r if p[i] >= 0.5 else names[i]
    return best, names


def load() -> dict:
    """The drop-reason model in use, from the learned folder: {} when none is,
    because he stopped it, because nothing has passed the keeper check yet, or
    because the file cannot be read (describe() says which)."""
    import learned
    return learned.live_model(LEARNER) or {}


def describe() -> str:
    """One line for the cull's log: which version of the drop-reason model
    this cull is using, or why it is using none."""
    import learned
    return learned.describe(LEARNER)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--min", type=int, default=12, help="examples a reason needs before it is trained")
    ap.add_argument("--dry-run", action="store_true", help="say what it would learn from, and write nothing")
    a = ap.parse_args()
    m = train(a.min)
    rep = m.pop("report")
    left = {k: v for k, v in rep["left_out"].items() if v}
    if left:
        print("  left out of training (still in labels.json): " + ", ".join(f"{v} {k}" for k, v in left.items()))
    if a.dry_run:
        print("  dry run: nothing written")
        return 0
    if not m.get("reasons"):
        print("  nothing new to use: " + (rep.get("note") or "not enough reasons of one kind yet; keep tagging in the studio"))
        return 0
    import learned
    res = learned.submit(LEARNER, m, source="./pl learn", data=rep)
    print("  " + res["sentence"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
