"""Summarise results.jsonl.

Reports the two things separately: how often a variant produces anything the
bridge would show at all, and how close what it shows is to the gold step.
"""

import json
import sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).parent
rows = [json.loads(l) for l in (HERE / "results.jsonl").read_text().splitlines() if l.strip()]

by = defaultdict(list)
for r in rows:
    by[r["variant"]].append(r)


def pct(n: int, d: int) -> str:
    return f"{100 * n / d:5.1f}%" if d else "    - "


print(f"{len(rows)} generations\n")
print(f"{'variant':12s} {'n':>4s} {'shown':>7s} {'exact(2)':>9s} {'near(1)':>8s} "
      f"{'miss(0)':>8s} {'mean':>6s} {'words':>6s}  rejects")
print("-" * 88)

order = sorted(by, key=lambda v: -sum(
    r["score"] for r in by[v] if r["score"] is not None))
for v in order:
    rs = by[v]
    shown = [r for r in rs if r["text"]]
    scored = [r for r in shown if r["score"] is not None]
    s2 = sum(1 for r in scored if r["score"] == 2)
    s1 = sum(1 for r in scored if r["score"] == 1)
    s0 = sum(1 for r in scored if r["score"] == 0)
    # Mean over every generation, counting a rejected one as 0: a subtitle the
    # bridge would discard is worth exactly nothing on screen.
    mean = sum(r["score"] or 0 for r in scored) / len(rs)
    words = sum(r["words"] for r in shown) / max(len(shown), 1)
    rej = defaultdict(int)
    for r in rs:
        if r["reject"]:
            rej[r["reject"]] += 1
    rejs = " ".join(f"{k}:{n}" for k, n in sorted(rej.items(), key=lambda x: -x[1]))
    print(f"{v:12s} {len(rs):4d} {pct(len(shown), len(rs))} {pct(s2, len(scored))} "
          f"{pct(s1, len(scored))} {pct(s0, len(scored))} {mean:6.2f} {words:6.1f}  {rejs}")

# Domain split: one prompt serves code and prose, and they can pull apart.
print(f"\n{'variant':12s} {'technical':>10s} {'book':>10s}   (mean, rejects as 0)")
print("-" * 46)
for v in order:
    line = f"{v:12s}"
    for dom in ("technical", "book"):
        rs = [r for r in by[v] if r["domain"] == dom]
        m = sum(r["score"] or 0 for r in rs) / max(len(rs), 1)
        line += f" {m:10.2f}"
    print(line)

# Thin prompts: the case the shipped prompt cannot see, and the reason for the
# whole exercise. Flagged by length rather than by hand so it stays checkable.
thin = {r["id"] for r in rows
        if len(next(c for c in json.loads((HERE / "checkpoints.json").read_text())
                    if c["id"] == r["id"])["last_prompt"].split()) <= 8}
print(f"\nthin prompts (<=8 words): {len(thin)} of "
      f"{len({r['id'] for r in rows})} checkpoints")
print(f"{'variant':12s} {'thin':>10s} {'rest':>10s}")
print("-" * 34)
for v in order:
    a = [r for r in by[v] if r["id"] in thin]
    b = [r for r in by[v] if r["id"] not in thin]
    print(f"{v:12s} {sum(r['score'] or 0 for r in a) / max(len(a), 1):10.2f} "
          f"{sum(r['score'] or 0 for r in b) / max(len(b), 1):10.2f}")

if "--examples" in sys.argv:
    ids = sorted({r["id"] for r in rows})
    for cid in ids:
        print(f"\n=== {cid}")
        g = next(r for r in rows if r["id"] == cid)
        print(f"  gold  {g['gold']!r}")
        print(f"  title {g['title']!r}")
        for v in order:
            for r in by[v]:
                if r["id"] == cid and r["rep"] == 0:
                    print(f"  {v:12s} {r['score']}  "
                          f"{(r['text'] or 'REJECT:' + str(r['reject']))!r}")
