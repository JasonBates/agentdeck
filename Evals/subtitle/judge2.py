"""A binary re-judge of the candidates already in results.jsonl.

The three-point judge is reliable at the ends and noise in the middle: against a
41-pair hand set it put every hand-0 at 0 and most hand-2s at 2, but split
hand-1 evenly across all three grades. So the middle grade was carrying variance
without carrying information.

This asks one question instead — would a person doing the work call these the
same step — and adds the instruction the three-point judge most needed: that
wording, tense and specificity may differ. Calibrated against the same hand set
(`--calibrate`) before it is used on anything.

No regeneration: it re-scores stored candidate text, so it is judge-only cost.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from model import call  # noqa: E402

HERE = Path(__file__).parent

PROMPT = """A dashboard labels what a working session is doing right now.
Here are two labels for the same moment. The REFERENCE is correct.

REFERENCE: {gold}
CANDIDATE: {cand}

Would someone doing this work say these name the same step — the same action on
the same thing?

Wording, tense and word order may differ freely, and one may be more specific
than the other; that is not a difference. Answer no only when the candidate
names a different action, a different thing, or is so vague that it could
describe any part of the session.

Answer only yes or no.

ANSWER:"""


def same_step(cand: str, gold: str) -> int | None:
    raw = call(PROMPT.format(gold=gold, cand=cand), max_tokens=4,
               temperature=0.0).strip().lower()
    if raw.startswith("yes"):
        return 1
    if raw.startswith("no"):
        return 0
    return None


def main() -> None:
    rows = [json.loads(l) for l in (HERE / "results.jsonl").read_text().splitlines()
            if l.strip()]

    if "--calibrate" in sys.argv:
        hand = {k: v for k, v in json.loads((HERE / "hand.json").read_text()).items()
                if not k.startswith("_")}
        lookup = {f"{r['variant']}|{r['id']}|{r['rep']}": r for r in rows}
        agree = n = 0
        fp = fn = 0
        for k, h in hand.items():
            r = lookup.get(k)
            if not r or not r["text"]:
                continue
            v = same_step(r["text"], r["gold"])
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
        print(f"\n{n} pairs, binary agreement {100 * agree / n:.0f}% "
              f"(false same {fp}, false different {fn})")
        return

    out = HERE / "binary.jsonl"
    done = set()
    if out.exists():
        for line in out.read_text().splitlines():
            if line.strip():
                done.add(json.loads(line)["key"])
    with out.open("a") as fh:
        for i, r in enumerate(rows, 1):
            key = f"{r['variant']}|{r['id']}|{r['rep']}"
            if key in done:
                continue
            v = same_step(r["text"], r["gold"]) if r["text"] else 0
            fh.write(json.dumps({"key": key, "variant": r["variant"],
                                 "id": r["id"], "domain": r["domain"],
                                 "binary": v}) + "\n")
            fh.flush()
            if i % 100 == 0:
                print(f"{i}/{len(rows)}", flush=True)
    print("done", flush=True)


if __name__ == "__main__":
    main()
