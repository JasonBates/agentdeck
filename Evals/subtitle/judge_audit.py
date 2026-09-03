"""Sample judged pairs for hand-checking, then score the judge against them.

The judge is the same model being judged, so its verdicts are worth nothing
until they are checked against a human pass. `--sample N` prints a stratified
sample as a blank scoring sheet; fill it into hand.json as {"variant|id|rep": s}
and run again with no flag to get agreement.
"""

import json
import random
import sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).parent
rows = [json.loads(l) for l in (HERE / "results.jsonl").read_text().splitlines() if l.strip()]
scored = [r for r in rows if r["score"] is not None]


def key(r: dict) -> str:
    return f"{r['variant']}|{r['id']}|{r['rep']}"


if "--sample" in sys.argv:
    n = int(sys.argv[sys.argv.index("--sample") + 1])
    rng = random.Random(7)
    # Stratify by judge score so the sample cannot miss a systematic bias at
    # one end — a judge that is only wrong about 0s looks fine in a random draw.
    buckets = {s: [r for r in scored if r["score"] == s] for s in (0, 1, 2)}
    sample = []
    for s, rs in buckets.items():
        rng.shuffle(rs)
        sample += rs[:max(1, round(n * len(rs) / len(scored)))]
    rng.shuffle(sample)
    for r in sample:
        print(f'\n"{key(r)}": ,')
        print(f"#   goal      {r['title']}")
        print(f"#   gold      {r['gold']}")
        print(f"#   candidate {r['text']}")
    sys.exit()

hand = {k: v for k, v in json.loads((HERE / "hand.json").read_text()).items()
        if not k.startswith("_")}
lookup = {key(r): r for r in scored}
pairs = [(hand[k], lookup[k]["score"]) for k in hand if k in lookup]

exact = sum(1 for h, j in pairs if h == j)
within1 = sum(1 for h, j in pairs if abs(h - j) <= 1)
bias = sum(j - h for h, j in pairs) / len(pairs)
print(f"{len(pairs)} hand-scored pairs")
print(f"exact agreement  {100 * exact / len(pairs):.0f}%")
print(f"within one point {100 * within1 / len(pairs):.0f}%")
print(f"judge bias       {bias:+.2f}  (positive = judge more generous)")
print("\nconfusion (hand -> judge):")
c = Counter(pairs)
print("        judge 0  judge 1  judge 2")
for h in (0, 1, 2):
    print(f"hand {h}  " + "".join(f"{c[(h, j)]:8d} " for j in (0, 1, 2)))
