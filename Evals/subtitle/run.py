"""Run every variant over every checkpoint and score against the gold labels.

Two kinds of score, kept separate on purpose:

  gates   deterministic, and exactly the bridge's — tidy, namesWork, distinct.
          A subtitle that fails these never reaches the screen at all, so a
          variant with a great average and a 30% rejection rate is not better.
  match   gemma4 judging the surviving subtitle against the hand-written gold:
          2 same step, 1 right area wrong grain, 0 wrong or just the project.
          The judge is checked against hand scores in judge_audit.py before any
          conclusion is drawn from it.

Results are appended to results.jsonl so a partial run is never lost.
"""

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from model import call, guard  # noqa: E402
from variants import VARIANTS  # noqa: E402

HERE = Path(__file__).parent
REPEATS = 3

JUDGE = """Two short labels describe what a working session is doing right now.
The REFERENCE is correct. Decide how well the CANDIDATE names the same step.

REFERENCE: {gold}
CANDIDATE: {cand}
(The session's overall goal, for context, is: {title})

Score:
2 = the same step — same action on the same thing, wording may differ
1 = the right area but the wrong grain: the goal or the topic restated, or a
    different step within the same session
0 = a different step, or too vague to identify one

Answer with only the digit.

SCORE:"""


def judge(cand: str, gold: str, title: str) -> int | None:
    raw = call(JUDGE.format(gold=gold, cand=cand, title=title or "unknown"),
               max_tokens=4, temperature=0.0)
    for ch in raw:
        if ch in "012":
            return int(ch)
    return None


def main() -> None:
    cps = json.loads((HERE / "checkpoints.json").read_text())
    gold = {k: v for k, v in json.loads((HERE / "gold.json").read_text()).items()
            if not k.startswith("_")}

    out = HERE / "results.jsonl"
    done = set()
    if out.exists():
        for line in out.read_text().splitlines():
            if line.strip():
                r = json.loads(line)
                done.add((r["variant"], r["id"], r["rep"]))

    total = len(VARIANTS) * len(cps) * REPEATS
    n = 0
    started = time.time()
    with out.open("a") as fh:
        for name, build in VARIANTS.items():
            for c in cps:
                for rep in range(REPEATS):
                    n += 1
                    if (name, c["id"], rep) in done:
                        continue
                    raw = call(build(c))
                    text, why = guard(raw, c["title"])
                    score = (judge(text, gold[c["id"]], c["title"])
                             if text else None)
                    rec = {
                        "variant": name, "id": c["id"], "rep": rep,
                        "domain": c["domain"], "agent": c["agent"],
                        "title": c["title"], "gold": gold[c["id"]],
                        "raw": raw[:300], "text": text, "reject": why,
                        "words": len(text.split()) if text else None,
                        "score": score,
                    }
                    fh.write(json.dumps(rec) + "\n")
                    fh.flush()
                    if n % 25 == 0:
                        rate = (time.time() - started) / max(n, 1)
                        print(f"{n}/{total}  {rate:.1f}s/call  "
                              f"eta {(total - n) * rate / 60:.0f}m", flush=True)
    print("done", flush=True)


if __name__ == "__main__":
    main()
