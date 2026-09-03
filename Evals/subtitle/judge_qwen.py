"""Re-judge the stored candidates with an independent model.

`gemma4:12b` generated every candidate in results.jsonl and then graded them.
A model marking its own homework is the weakest joint in the eval — judge_audit
put it at 66% exact agreement with the hand set, "enough to rank seven variants
and not enough to separate 1.22 from 1.14". This swaps in `qwen3.8:27b`, which
wrote none of the candidates, and asks the same two questions with the same two
prompts. Only the judge changes.

No regeneration: it re-scores the candidate text already in results.jsonl, so
the variants, the checkpoints and the gold labels are all untouched.

  --calibrate         3-point judge against hand.json, same report as judge_audit
  --calibrate-binary  binary judge against hand.json, same report as judge2
  --three             all 1260 candidates, 3-point  -> results_qwen.jsonl
  --binary            all 1260 candidates, binary   -> binary_qwen.jsonl

Both full passes are resumable; a partial run is never lost.
"""

import json
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from model import call  # noqa: E402
from run import JUDGE  # noqa: E402
from judge2 import PROMPT as BINARY_PROMPT  # noqa: E402

HERE = Path(__file__).parent
MODEL = "qwen3.8:27b"

# The bridge's own 4-token cap is a property of the subtitle generator, not of
# the judge. Qwen occasionally prefixes a space or a word before the digit, so
# the budget is loosened and the parse stays strict — an unreadable verdict is
# recorded as None rather than coerced.
JUDGE_MAX_TOKENS = 8


def three_point(cand: str, gold: str, title: str) -> int | None:
    raw = call(JUDGE.format(gold=gold, cand=cand, title=title or "unknown"),
               model=MODEL, max_tokens=JUDGE_MAX_TOKENS, temperature=0.0)
    for ch in raw:
        if ch in "012":
            return int(ch)
    return None


def binary(cand: str, gold: str) -> int | None:
    raw = call(BINARY_PROMPT.format(gold=gold, cand=cand), model=MODEL,
               max_tokens=JUDGE_MAX_TOKENS, temperature=0.0).strip().lower()
    if raw.startswith("yes"):
        return 1
    if raw.startswith("no"):
        return 0
    return None


def rows() -> list[dict]:
    return [json.loads(l) for l in (HERE / "results.jsonl").read_text().splitlines()
            if l.strip()]


def key(r: dict) -> str:
    return f"{r['variant']}|{r['id']}|{r['rep']}"


# --- calibration -------------------------------------------------------------

def calibrate(mode: str) -> None:
    hand = {k: v for k, v in json.loads((HERE / "hand.json").read_text()).items()
            if not k.startswith("_")}
    lookup = {key(r): r for r in rows()}

    if mode == "three":
        pairs = []
        for k, h in hand.items():
            r = lookup.get(k)
            if not r or not r["text"]:
                continue
            j = three_point(r["text"], r["gold"], r["title"])
            if j is None:
                print(f"  unparsed: {r['text']!r}")
                continue
            pairs.append((h, j))
            if h != j:
                print(f"  hand {h} judge {j}: {r['gold']!r} vs {r['text']!r}")
        exact = sum(1 for h, j in pairs if h == j)
        within1 = sum(1 for h, j in pairs if abs(h - j) <= 1)
        bias = sum(j - h for h, j in pairs) / len(pairs)
        print(f"\n{MODEL} as 3-point judge, {len(pairs)} hand-scored pairs")
        print(f"exact agreement  {100 * exact / len(pairs):.0f}%")
        print(f"within one point {100 * within1 / len(pairs):.0f}%")
        print(f"judge bias       {bias:+.2f}  (positive = judge more generous)")
        c = Counter(pairs)
        print("\nconfusion (hand -> judge):")
        print("        judge 0  judge 1  judge 2")
        for h in (0, 1, 2):
            print(f"hand {h}  " + "".join(f"{c[(h, j)]:8d} " for j in (0, 1, 2)))
        return

    agree = n = fp = fn = 0
    for k, h in hand.items():
        r = lookup.get(k)
        if not r or not r["text"]:
            continue
        v = binary(r["text"], r["gold"])
        want = 1 if h == 2 else 0
        n += 1
        if v == want:
            agree += 1
        elif v == 1:
            fp += 1
            print(f"  says-same, hand {h}: {r['gold']!r} vs {r['text']!r}")
        else:
            fn += 1
            print(f"  says-diff, hand {h}: {r['gold']!r} vs {r['text']!r}")
    print(f"\n{MODEL} as binary judge, {n} pairs, agreement "
          f"{100 * agree / n:.0f}% (false same {fp}, false different {fn})")


# --- full passes -------------------------------------------------------------

def full(mode: str) -> None:
    rs = rows()
    out = HERE / ("results_qwen.jsonl" if mode == "three" else "binary_qwen.jsonl")
    done = set()
    if out.exists():
        for line in out.read_text().splitlines():
            if line.strip():
                done.add(json.loads(line)["key"])
    with out.open("a") as fh:
        for i, r in enumerate(rs, 1):
            k = key(r)
            if k in done:
                continue
            if not r["text"]:
                # A gate rejection never reaches the screen; it scores zero
                # under both judges, exactly as run.py and judge2.py have it.
                v = None if mode == "three" else 0
            elif mode == "three":
                v = three_point(r["text"], r["gold"], r["title"])
            else:
                v = binary(r["text"], r["gold"])
            rec = {"key": k, "variant": r["variant"], "id": r["id"],
                   "domain": r["domain"], "text": r["text"],
                   "reject": r["reject"]}
            rec["score" if mode == "three" else "binary"] = v
            fh.write(json.dumps(rec) + "\n")
            fh.flush()
            if i % 50 == 0:
                print(f"{i}/{len(rs)}", flush=True)
    print("done", flush=True)


if __name__ == "__main__":
    if "--calibrate" in sys.argv:
        calibrate("three")
    elif "--calibrate-binary" in sys.argv:
        calibrate("binary")
    elif "--three" in sys.argv:
        full("three")
    elif "--binary" in sys.argv:
        full("binary")
    else:
        print(__doc__)
