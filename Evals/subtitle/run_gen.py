"""Re-run the whole eval with a different model writing the subtitles.

run.py answers "which prompt is best for gemma4:12b". This answers the question
that comes after it: whether a single larger model can do the bridge's heading
work at all, so the deck does not need a second model resident just to write
eight words.

Everything except the generator is held fixed — same seven variants, same 60
checkpoints, same gold labels, same Activity.swift gates via model.guard, same
temperature 0.1 / num_ctx 4096 / num_predict 32. So a difference here is the
generator and only the generator.

One thing improves by accident. In run.py the judge was `gemma4:12b` grading
candidates `gemma4:12b` had written, which judge_audit exists to apologise for.
Here gemma judges text it did not write, so the headline comparison is no longer
self-marking. Its leniency still applies (judge_bias: 10 false sames in 41), and
it applies to both sides equally, which is what a fixed judge is for.

    python3 run_gen.py                       qwen3.8:27b generating
    python3 run_gen.py --model <tag>         some other generator
    python3 run_gen.py --judge <tag>         some other judge

Resumable; a partial run is never lost.
"""

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from model import call, guard  # noqa: E402
from run import JUDGE  # noqa: E402
from variants import VARIANTS  # noqa: E402

HERE = Path(__file__).parent
REPEATS = 3

GEN_MODEL = "qwen3.8:27b"
JUDGE_MODEL = "gemma4:12b"

# The generator is pinned to the bridge's 4-token equivalent through model.call;
# the judge is not part of that contract, so it gets room for a stray prefix and
# a strict parse. Same allowance judge_qwen.py makes.
JUDGE_MAX_TOKENS = 8


def arg(flag: str, default: str) -> str:
    return sys.argv[sys.argv.index(flag) + 1] if flag in sys.argv else default


def judge(cand: str, gold: str, title: str, model: str) -> int | None:
    raw = call(JUDGE.format(gold=gold, cand=cand, title=title or "unknown"),
               model=model, max_tokens=JUDGE_MAX_TOKENS, temperature=0.0)
    for ch in raw:
        if ch in "012":
            return int(ch)
    return None


def main() -> None:
    gen_model = arg("--model", GEN_MODEL)
    judge_model = arg("--judge", JUDGE_MODEL)
    slug = gen_model.replace(":", "_").replace(".", "-")
    out = HERE / f"results_gen_{slug}.jsonl"

    cps = json.loads((HERE / "checkpoints.json").read_text())
    gold = {k: v for k, v in json.loads((HERE / "gold.json").read_text()).items()
            if not k.startswith("_")}

    done = set()
    if out.exists():
        for line in out.read_text().splitlines():
            if line.strip():
                r = json.loads(line)
                done.add((r["variant"], r["id"], r["rep"]))

    total = len(VARIANTS) * len(cps) * REPEATS
    print(f"generator {gen_model}, judge {judge_model}, {total} generations "
          f"({len(done)} already done) -> {out.name}", flush=True)

    n = 0
    started = time.time()
    with out.open("a") as fh:
        for name, build in VARIANTS.items():
            for c in cps:
                for rep in range(REPEATS):
                    n += 1
                    if (name, c["id"], rep) in done:
                        continue
                    raw = call(build(c), model=gen_model)
                    text, why = guard(raw, c["title"])
                    score = (judge(text, gold[c["id"]], c["title"], judge_model)
                             if text else None)
                    fh.write(json.dumps({
                        "variant": name, "id": c["id"], "rep": rep,
                        "domain": c["domain"], "agent": c["agent"],
                        "title": c["title"], "gold": gold[c["id"]],
                        "raw": raw[:300], "text": text, "reject": why,
                        "words": len(text.split()) if text else None,
                        "score": score,
                        "gen_model": gen_model, "judge_model": judge_model,
                    }) + "\n")
                    fh.flush()
                    if n % 25 == 0:
                        rate = (time.time() - started) / max(n - len(done), 1)
                        print(f"{n}/{total}  {rate:.1f}s/gen  "
                              f"eta {(total - n) * rate / 60:.0f}m", flush=True)
    print("done", flush=True)


if __name__ == "__main__":
    main()
