"""How often does the thin-prompt case actually fire on the running deck?

The eval rests on hand-written labels, so it needs one measurement that does
not. Every shipped subtitle in ~/.local/state/agentdeck/headings.jsonl carries
its session path and promptsSeen, so the prompt it was generated from can be
recovered by replaying that transcript. The index needs an offset: the logged
count starts whenever the bridge first saw the pane, and a build predating the
injected-turn filters counts turns the current code drops. The offset is found
per session by the alignment that fits, and sessions where none fits are
reported rather than silently included.
"""

import json
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from digest import replay  # noqa: E402

LOG = Path.home() / ".local/state/agentdeck/headings.jsonl"
THIN = 8   # words

rows = [json.loads(l) for l in LOG.read_text().splitlines() if l.strip()]
subs = [r for r in rows if r["kind"] == "subtitle" and r.get("session")]

sessions: dict[str, list[dict]] = {}
for r in subs:
    sessions.setdefault(r["session"], []).append(r)

matched = Counter()
thin_hits: list[tuple[str, str]] = []
unaligned = 0

for path_s, rs in sessions.items():
    path = Path(path_s)
    if not path.exists():
        unaligned += len(rs)
        continue
    cps = replay(path, rs[0]["agent"])
    if not cps:
        unaligned += len(rs)
        continue
    # Try offsets 0..3; keep the one where the most logged indices land in range.
    best, best_n = 0, -1
    for off in range(4):
        n = sum(1 for r in rs if 1 <= r["promptsSeen"] - off <= len(cps))
        if n > best_n:
            best, best_n = off, n
    for r in rs:
        i = r["promptsSeen"] - best
        if not (1 <= i <= len(cps)):
            unaligned += 1
            continue
        prompt = cps[i - 1].last_prompt
        words = len(prompt.split())
        matched["thin" if words <= THIN else "full"] += 1
        if words <= THIN and r["accepted"]:
            thin_hits.append((" ".join(prompt.split())[:44], r["text"][:56]))

# Offset-independent, and the number to quote: what share of the prompts that
# trigger a subtitle at all are too thin to name work on their own.
dist = Counter()
for path_s, rs in sessions.items():
    path = Path(path_s)
    if not path.exists():
        continue
    for c in replay(path, rs[0]["agent"]):
        dist["thin" if len(c.last_prompt.split()) <= THIN else "full"] += 1
d_total = sum(dist.values())
print(f"Across the {len(sessions)} sessions the running deck has generated "
      f"subtitles for:")
print(f"  {d_total} intent-carrying prompts, of which {dist['thin']} "
      f"({100 * dist['thin'] / max(d_total, 1):.0f}%) are <={THIN} words\n")

total = sum(matched.values())
print(f"{len(subs)} shipped subtitle generations, {total} aligned to a prompt "
      f"({unaligned} unaligned). Alignment is +/-1 per row — the logged count "
      f"starts\nwhen the bridge first saw the pane — so read the pairs below as "
      f"illustration, not\nas per-row ground truth.")
print(f"  aligned to a <={THIN}-word prompt: {matched['thin']:4d}  "
      f"({100 * matched['thin'] / max(total, 1):.0f}%)")
print("\nsample of subtitles generated near a thin prompt:")
for p, s in thin_hits[:16]:
    print(f"  {p:46s} -> {s}")
