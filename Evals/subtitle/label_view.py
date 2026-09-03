"""Print checkpoints in a compact form for hand-labelling gold subtitles."""

import json
import sys
import textwrap
from pathlib import Path

HERE = Path(__file__).parent
cps = json.loads((HERE / "checkpoints.json").read_text())

lo = int(sys.argv[1]) if len(sys.argv) > 1 else 0
hi = int(sys.argv[2]) if len(sys.argv) > 2 else len(cps)


def w(label: str, text: str, width: int) -> str:
    body = " ".join(text.split())[:width]
    return f"{label:<10}{body}"


for i, c in enumerate(cps):
    if not (lo <= i < hi):
        continue
    print(f"\n===== [{i}] {c['id']}  {c['domain']}  "
          f"(prompt {c['index']}/{c['total_prompts']}, {c['agent']})")
    print(w("TITLE:", c["title"] or "(none)", 100))
    print(w("OPENING:", c["opening"], 190))
    print(textwrap.fill(w("PROMPT:", c["last_prompt"], 700),
                        110, subsequent_indent=" " * 10))
    if c["prev_reply"]:
        print(textwrap.fill(w("PREV:", c["prev_reply"], 420),
                            110, subsequent_indent=" " * 10))
    if c["next_reply"]:
        print(textwrap.fill(w("DID:", c["next_reply"], 420),
                            110, subsequent_indent=" " * 10))
