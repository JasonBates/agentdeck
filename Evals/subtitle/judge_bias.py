"""The two judges are wrong in opposite directions.

Swapping `qwen3.8:27b` in as an independent judge was meant to fix the weakest
joint in the eval — `gemma4:12b` grading candidates it wrote itself. It does not.
Against the same 41-pair hand set:

    judge          prompt              agreement   false same   false different
    gemma4:12b     judge2 PROMPT          71%         --             --
    qwen3.8:27b    judge2 PROMPT          59%          0             17
    gemma4:12b     PROMPT2 (below)        66%         10              4
    qwen3.8:27b    PROMPT2 (below)        68%          0             13

Neither clears ~70%, so neither is a reference. But the error is not shared.
Gemma waves through pairs that only look alike; qwen refuses pairs that are the
same act under different verbs — `shorten`/`simplify`, `rederive`/`redefine`,
`Install Corral and run its preflight` against `Install Corral via preflight and
installation scripts`. Across 82 qwen verdicts here, zero false sames.

PROMPT2 was written to fix exactly that: it states the wording tolerance as the
decision rule rather than as an aside, and names the verb-substitution case. It
moves qwen +9 points and costs gemma 5, which is the same finding from the other
side — the instruction gemma needed was never the missing one.

Two consequences worth keeping:

  - A strict judge with one-directional error still ranks variants, as long as
    the strictness is uniform. Absolute scores under qwen are not comparable to
    the numbers in RESULTS.md; the ordering is.
  - Where a lenient and a strict judge agree, the verdict is worth more than
    either alone. That agreement is the cheapest available proxy for a second
    hand pass over the disputed middle, where hand-1 split 5/5/5.

Overfitting caveat: 41 pairs, and both this prompt and judge2's were written
while looking at them. The set ranks judges; it does not validate one.

    python3 judge_bias.py            both models, both prompts
    python3 judge_bias.py --show     also print every disagreement
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from model import call  # noqa: E402
from judge2 import PROMPT as PROMPT1  # noqa: E402

HERE = Path(__file__).parent

PROMPT2 = """A dashboard labels what a working session is doing right now.
Here are two labels for the same moment. The REFERENCE is correct.

REFERENCE: {gold}
CANDIDATE: {cand}

Would someone doing this work say these name the same step?

Judge the underlying action and its object, not the words. Different verbs for
the same act ("shorten" / "simplify", "rederive" / "redefine"), different
phrasings of the same object, different tense, and extra detail on one side are
all the SAME step — answer yes.

Answer no only when the action is genuinely a different act, or the object is a
different thing, or the candidate is so vague it could describe any part of the
session.

Answer only yes or no.

ANSWER:"""

MODELS = ("gemma4:12b", "qwen3.8:27b")
PROMPTS = {"judge2": PROMPT1, "PROMPT2": PROMPT2}


def main() -> None:
    show = "--show" in sys.argv
    hand = {k: v for k, v in json.loads((HERE / "hand.json").read_text()).items()
            if not k.startswith("_")}
    rows = [json.loads(l) for l in (HERE / "results.jsonl").read_text().splitlines()
            if l.strip()]
    lookup = {f"{r['variant']}|{r['id']}|{r['rep']}": r for r in rows}

    print(f"{'judge':14s} {'prompt':9s} {'n':>4s} {'agree':>7s} "
          f"{'false same':>11s} {'false diff':>11s}")
    print("-" * 60)
    for model in MODELS:
        for pname, ptext in PROMPTS.items():
            agree = n = fp = fn = 0
            for k, h in hand.items():
                r = lookup.get(k)
                if not r or not r["text"]:
                    continue
                raw = call(ptext.format(gold=r["gold"], cand=r["text"]),
                           model=model, max_tokens=8,
                           temperature=0.0).strip().lower()
                v = 1 if raw.startswith("yes") else 0 if raw.startswith("no") else None
                want = 1 if h == 2 else 0
                n += 1
                if v == want:
                    agree += 1
                    continue
                if v == 1:
                    fp += 1
                else:
                    fn += 1
                if show:
                    verdict = "says-same" if v == 1 else "says-diff"
                    print(f"    {verdict}, hand {h}: {r['gold']!r} vs {r['text']!r}")
            print(f"{model:14s} {pname:9s} {n:4d} {100 * agree / n:6.0f}% "
                  f"{fp:11d} {fn:11d}")


if __name__ == "__main__":
    main()
