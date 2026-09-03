"""Compare the two judges over the same 1260 stored candidates.

Nothing was regenerated, so any difference between the columns is the judge and
only the judge: `gemma4:12b` grading candidates it wrote itself, against
`qwen3.8:27b`, which wrote none of them.

A rejected candidate counts as 0 throughout — on screen a discarded subtitle
and a wrong one are the same thing — which is exactly how report.py has it.
"""

import json
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).parent


def load(name: str) -> list[dict]:
    p = HERE / name
    return ([json.loads(l) for l in p.read_text().splitlines() if l.strip()]
            if p.exists() else [])


gem = load("results.jsonl")
qwen = {r["key"]: r for r in load("results_qwen.jsonl")}
gem_bin = {r["key"]: r for r in load("binary.jsonl")}
qwen_bin = {r["key"]: r for r in load("binary_qwen.jsonl")}

thin_ids = {c["id"] for c in json.loads((HERE / "checkpoints.json").read_text())
            if len(c["last_prompt"].split()) <= 8}


def key(r: dict) -> str:
    return f"{r['variant']}|{r['id']}|{r['rep']}"


by = defaultdict(list)
for r in gem:
    by[r["variant"]].append(r)


def mean(rs: list[dict], get) -> float:
    vals = [get(r) for r in rs]
    vals = [v for v in vals if v is not None]
    return sum(vals) / len(rs) if rs else 0.0


def g3(r):
    return r["score"] or 0


def q3(r):
    o = qwen.get(key(r))
    return (o["score"] or 0) if o else None


def gb(r):
    o = gem_bin.get(key(r))
    return o["binary"] if o else None


def qb(r):
    o = qwen_bin.get(key(r))
    return o["binary"] if o else None


order = sorted(by, key=lambda v: -mean(by[v], q3) if qwen else -mean(by[v], g3))

print(f"{len(gem)} stored candidates, re-judged\n")
print(f"{'variant':14s} {'gemma 3pt':>10s} {'qwen 3pt':>10s} {'gemma same':>11s} "
      f"{'qwen same':>10s}")
print("-" * 60)
for v in order:
    rs = by[v]
    b1, b2 = mean(rs, gb), mean(rs, qb)
    print(f"{v:14s} {mean(rs, g3):10.2f} {mean(rs, q3):10.2f} "
          f"{100 * b1:10.1f}% {100 * b2:9.1f}%")

print(f"\nthin prompts (<=8 words): {len(thin_ids)} of "
      f"{len({r['id'] for r in gem})} checkpoints\n")
print(f"{'variant':14s} {'gemma thin':>11s} {'qwen thin':>10s} {'gemma rest':>11s} "
      f"{'qwen rest':>10s}")
print("-" * 60)
for v in order:
    a = [r for r in by[v] if r["id"] in thin_ids]
    b = [r for r in by[v] if r["id"] not in thin_ids]
    print(f"{v:14s} {mean(a, g3):11.2f} {mean(a, q3):10.2f} "
          f"{mean(b, g3):11.2f} {mean(b, q3):10.2f}")

# How often the two judges land on the same grade at all. A high mean
# correlation with low per-item agreement means they rank variants alike for
# different reasons, which is worth knowing before either is trusted.
if qwen:
    pairs = [(g3(r), q3(r)) for r in gem if qwen.get(key(r))]
    exact = sum(1 for a, b in pairs if a == b)
    within1 = sum(1 for a, b in pairs if abs(a - b) <= 1)
    bias = sum(b - a for a, b in pairs) / len(pairs)
    print(f"\njudge-vs-judge over {len(pairs)} items: exact "
          f"{100 * exact / len(pairs):.0f}%, within one {100 * within1 / len(pairs):.0f}%, "
          f"qwen bias {bias:+.2f}")
