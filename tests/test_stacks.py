"""Frames that look alike are stacked, never hidden.

    .venv/bin/python -m pytest tests/test_stacks.py -q

The grouping this replaces hid all but one or two frames of every "same
picture" group, and 65 of his 773 keepers over six shoots were among the
hidden. It also chained: union-find over every pair let a moving subject join
45 frames over three bursts into one "picture". A stack is linked between
neighbours only, by the card's own median change, and the cull never writes
rating 1 again. These tests hold each of those properties on data small
enough to reason about by hand.
"""
from __future__ import annotations

import csv
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
import cull  # noqa: E402
import quality  # noqa: E402

HERE = Path(__file__).resolve().parents[1]


def _vec(angle: float) -> np.ndarray:
    """A unit vector whose cosine with _vec(0) is cos(angle), in 768 dims."""
    v = np.zeros(768)
    v[0], v[1] = np.cos(angle), np.sin(angle)
    return v


def _card(steps: list[float], flips: list[int], bursts: list[int], names=None, seqs=None):
    """A card whose frame i sits at angle sum(steps[:i]) and whose hash has
    flips[i] bits set, so both measures move a known amount between frames."""
    n = len(steps)
    ang = np.cumsum(steps)
    embs = np.stack([_vec(a) for a in ang])
    bits = []
    for k in flips:
        b = np.zeros(64, bool)
        b[:k] = True
        bits.append(b)
    names = names or [f"TSC{4300 + i:05d}.ARW" for i in range(n)]
    seqs = seqs or [1000.0 + 0.1 * i for i in range(n)]
    return embs, bits, bursts, seqs, names


def test_neighbours_stop_at_a_burst_a_gap_in_the_counter_and_a_missing_clock():
    names = ["A0001.ARW", "A0002.ARW", "A0003.ARW", "A0005.ARW", "A0006.ARW", "A0007.ARW"]
    seqs = [10.0, 10.1, 10.2, 10.3, 20.0, 20.1]
    bursts = [0, 0, 0, 0, 1, 1]
    pairs = quality.back_to_back(bursts, seqs, names)
    # 3 -> 5 skips a frame that is not here; 5 -> 6 crosses into another burst
    assert pairs == [(0, 1), (1, 2), (4, 5)]
    # no capture time at all (a cull of cached decodes): the counter decides
    timeless = quality.back_to_back([0, 1, 2, 3], [0.0] * 4, ["X0010.jpg", "X0011.jpg", "X0013.jpg", "X0014.jpg"])
    assert timeless == [(0, 1), (2, 3)]
    # and with neither a clock nor a counter, nothing says two frames are neighbours
    assert quality.back_to_back([0, 1], [0.0, 0.0], ["a.jpg", "b.jpg"]) == []


def test_a_stack_is_one_unbroken_run_inside_one_burst():
    """A slow drift links every neighbour, and still stops at the burst."""
    n = 40
    steps = [0.0] + [0.02] * (n - 1)
    flips = [0] * n
    # the second half of the card moves fast, so the median sits between the two
    steps[20:] = [0.3] * 20
    bursts = [0] * 10 + [1] * 10 + [2] * 20
    embs, bits, bursts, seqs, names = _card(steps, flips, bursts)
    ids, info = quality.similar_stacks(embs, bits, bursts, seqs, names)
    assert info["pairs"] >= quality.MIN_PAIRS
    stacks: dict[int, list[int]] = {}
    for i, s in enumerate(ids):
        if s >= 0:
            stacks.setdefault(s, []).append(i)
    assert stacks, "the still half of the card must stack"
    for mem in stacks.values():
        assert mem == list(range(mem[0], mem[0] + len(mem))), mem        # contiguous
        assert len({bursts[i] for i in mem}) == 1, mem                   # one burst
    # the two still bursts are two stacks, not one chain across the boundary
    assert ids[9] != ids[10]


def test_the_line_is_the_cards_own_median():
    """Half the pairs barely change, half change a lot: the half that barely
    changes is stacked, whatever --style would have said."""
    n = 30
    steps = [0.0] + [0.01 if i % 2 else 0.4 for i in range(1, n)]
    flips = [0] * n
    embs, bits, bursts, seqs, names = _card(steps, flips, [0] * n)
    ids, info = quality.similar_stacks(embs, bits, bursts, seqs, names)
    assert np.cos(0.4) < info["cos"] <= np.cos(0.01) + 1e-9
    # every small step links its pair and no large step does
    for i in range(1, n):
        linked = ids[i] >= 0 and ids[i] == ids[i - 1]
        assert linked == (steps[i] == 0.01), i


def test_too_few_pairs_or_no_picture_model_stacks_nothing_and_says_why():
    embs, bits, bursts, seqs, names = _card([0.0] + [0.01] * 9, [0] * 10, [0] * 10)
    ids, info = quality.similar_stacks(embs, bits, bursts, seqs, names)
    assert ids == [-1] * 10 and "too few" in info["why"]
    ids, info = quality.similar_stacks(None, bits, bursts, seqs, names)
    assert ids == [-1] * 10 and "picture model" in info["why"]


def test_similar_npz_gives_the_same_stacks_back(tmp_path):
    n = 30
    steps = [0.0] + [0.01 if i % 3 else 0.5 for i in range(1, n)]
    embs, bits, bursts, seqs, names = _card(steps, [i % 5 for i in range(n)], [0] * n)
    vec16 = embs.astype(np.float16)
    ids, info = quality.similar_stacks(vec16, bits, bursts, seqs, names)
    quality.write_similar(tmp_path / "similar.npz", names, vec16, np.array(bits), seqs, bursts, info)
    z = quality.read_similar(tmp_path / "similar.npz")
    assert list(z["files"]) == names and z["clip"].dtype == np.float16 and z["phash"].shape == (n, 64)
    again, info2 = quality.similar_stacks(z["clip"], list(z["phash"]), list(z["burst"]), list(z["seq"]), list(z["files"]))
    assert again == ids and info2["cos"] == pytest.approx(z["line"][0])
    assert quality.read_similar(tmp_path / "nothing.npz") is None


def _frame(name: str, quality_: float, sharp: float = 3.0, stack: int = -1) -> cull.Frame:
    f = cull.Frame(path=Path(name))
    f.quality, f.sharp, f.stack = quality_, sharp, stack
    return f


def test_the_top_is_the_best_score_and_sharpness_does_not_override_it():
    """In 9 of the 19 keepers the old rule hid on the action shoot, the keeper
    was the softer frame. The top is chosen by quality and nothing else."""
    soft_but_best = _frame("TSC04313.ARW", 1.2, sharp=1.0, stack=0)
    sharp = _frame("TSC04314.ARW", 0.4, sharp=9.0, stack=0)
    third = _frame("TSC04315.ARW", 0.1, sharp=8.0, stack=0)
    alone = _frame("TSC04320.ARW", 0.0)
    tiered = cull.stack_verdicts([sharp, soft_but_best, third, alone], keep_per_group=1)
    assert soft_but_best.stack_top and not sharp.stack_top
    assert {id(f) for f in tiered} == {id(soft_but_best), id(alone)}
    for f in (sharp, third):
        assert f.rating == 2 and f.reason == "similar to 04313"
        assert "duplicate" not in f.reason
    # with --style action two of the stack are tiered, top first
    for f in (soft_but_best, sharp, third):
        f.rating, f.reason, f.stack_top = 0, "", False
    tiered = cull.stack_verdicts([sharp, soft_but_best, third], keep_per_group=2)
    assert [f.path.stem for f in tiered] == ["TSC04313", "TSC04314"] and third.rating == 2


def test_a_run_the_faults_left_with_one_frame_is_no_stack():
    lone = _frame("A0001.ARW", 1.0, stack=3)
    tiered = cull.stack_verdicts([lone], keep_per_group=1)
    assert tiered == [lone] and lone.stack == -1 and not lone.stack_top


def test_nothing_under_a_top_is_shortlisted_above_it():
    top = _frame("A0001.ARW", 1.0, stack=0)
    under = _frame("A0002.ARW", 0.9, stack=0)
    top.stack_top = True
    top.rating, top.reason = 3, "maybe"
    under.rating, under.reason = 5, "clear win"       # a venue ranker can order them the other way
    cull.never_above_top([top, under])
    assert (under.rating, under.reason) == (3, "maybe")


def test_every_keeper_the_page_would_not_show_is_lost(tmp_path):
    """The bench counted rejections alone, so a keeper hidden as a duplicate
    was a 'missed' line and never in the number."""
    old = tmp_path / "cull.csv"
    old.write_text("file,rating,reason,group\n"
                   "TSC00001.ARW,5,clear win,0\nTSC00002.ARW,1,duplicate,0\n"
                   "TSC00003.ARW,0,blink,1\nTSC00004.ARW,2,probably not,2\n")
    rows = list(csv.DictReader(old.open()))
    lost, under = cull.unseen_keepers(rows, {"TSC00001", "TSC00002", "TSC00003", "TSC00004"})
    assert lost == [("TSC00002.ARW", "duplicate"), ("TSC00003.ARW", "blink")]
    assert under == []
    new = [{"file": "TSC00010.ARW", "rating": "5", "reason": "clear win", "stack": "4", "stack_top": "1"},
           {"file": "TSC00011.ARW", "rating": "2", "reason": "similar to 00010", "stack": "4", "stack_top": "0"},
           {"file": "TSC00012.ARW", "rating": "0", "reason": "soft", "stack": "4", "stack_top": "0"},
           {"file": "TSC00013.ARW", "rating": "2", "reason": "probably not", "stack": "", "stack_top": "0"}]
    lost, under = cull.unseen_keepers(new, {"TSC00011", "TSC00012", "TSC00013"})
    assert lost == [("TSC00012.ARW", "soft")]
    assert under == [("TSC00011.ARW", "00010")]


def test_learn_is_retired_and_says_where_learning_lives(tmp_path):
    picks = tmp_path / "picks.json"
    picks.write_text(json.dumps(["TSC00001.ARW"]))
    r = subprocess.run([sys.executable, str(HERE / "pipeline" / "cull.py"), str(tmp_path), "--learn", str(picks)],
                       capture_output=True, text=True)
    assert r.returncode == 2
    assert "retired" in r.stderr and "What the cull has learned" in r.stderr
    assert not (tmp_path / "_cull").exists() and not (tmp_path / "cull").exists()


# ------------------------------------------------ one tier rule, not two

def test_the_tiers_are_dealt_per_burst_and_across_the_shoot_when_bursts_are_single():
    import common
    # Two bursts of four: the best two of each are clear wins, the next two maybes.
    bursts = [[0, 1, 2, 3], [4, 5, 6, 7]]
    score = {0: .9, 1: .1, 2: .5, 3: .7, 4: .2, 5: .3, 6: .8, 7: .6}.__getitem__
    t, across = common.deal_tiers(bursts, list(range(8)), score)
    assert not across
    assert (t[0], t[3], t[2], t[1]) == (5, 5, 3, 3) and (t[6], t[7], t[5], t[4]) == (5, 5, 3, 3)
    # Mostly lone frames: one lane across the shoot, or every one of them would be a clear win.
    t, across = common.deal_tiers([[0], [1], [2], [3, 4]], list(range(5)), {0: 5, 1: 4, 2: 3, 3: 2, 4: 1}.__getitem__)
    assert across and [t[i] for i in range(5)] == [5, 5, 3, 3, 2]


def test_the_keeper_check_replays_a_stack_the_way_the_cull_split_it():
    """keep_per_group frames of a stack are tiered and the rest wait under its
    top, set aside. The replay used to tier every member of every stack, a
    shortlist a third longer than the cull's own, so a candidate was checked
    against a cull nobody ran."""
    import learned

    class Shoot:
        stacked, kpg = True, 1
        rows = [{"file": f"F{i}.ARW", "burst": "0", "stack": "1" if i < 3 else "", "shot_at": f"{i:02d}"}
                for i in range(6)]
        alive = list(range(6))

    score = {0: .2, 1: .9, 2: .5, 3: .8, 4: .1, 5: .7}
    t = learned._tiers(Shoot(), score)
    # The stack's top (1) is tiered with the loners; 0 and 2 wait under it.
    assert t[0] == 2 and t[2] == 2
    tiered, under, tops = __import__("common").stack_tiers([[0, 1, 2]], 1, score.__getitem__)
    assert tiered == [1] and sorted(under) == [0, 2] and tops == [1]
    assert {t[i] for i in (1, 3, 5)} <= {5, 3}
