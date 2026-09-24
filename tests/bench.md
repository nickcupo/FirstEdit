# Bench, 2026-09-18

The cull against every shoot the photographer has already chosen from. `survive` is the number that must
stay near 100%: a veto on a frame the photographer wanted is the worst thing the cull can do. `in top N`
is the cull's own pick set against chance. `P@k` is the ranking alone, at k = the number chosen, next to
the aesthetic head by itself and to random.

**This copy is out of date and has not been regenerated, because regenerating it needs the
photographs.** `./pl bench` now reports `shown` and `lost` in place of `survive`, and a
`under a top` column for keepers shown one key below the top of their stack, which are not
losses. The numbers below were also produced with a private extension installed, whose
`moments.json` replaces the generic moment prompts, so the `action` feature differs slightly
from a run without it. Run `./pl bench` before quoting any number here.

| shoot | frames | chosen | survive | in top N | chance | P@k | aesthetic only | random | minutes |
|---|---|---|---|---|---|---|---|---|---|
| portraits, two people, evening in town | 198 | 12 | 12 | 3 of 30 | 1.8 | 0.25 | 0.25 | 0.06 | 1.1 |
| a lounge, red light, two people | 296 | 25 | 25 | 6 of 30 | 2.5 | 0.40 | 0.40 | 0.09 | 0.7 |
| a dog, outdoors | 54 | 14 | 14 | 13 of 30 | 7.0 | 0.57 | 0.36 | 0.29 | 0.5 |
| an action shoot, indoors, bursts | 1157 | 154 | 152 (TSC05422.ARW: blink, TSC05664.ARW: blink) | 30 of 154 | 20.5 | 0.20 | 0.15 | 0.14 | 6.0 |
