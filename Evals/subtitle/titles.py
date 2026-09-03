"""Generate the title each checkpoint would have carried.

The subtitle is generated with the current title in the prompt and is rejected
when it overlaps that title too far, so a subtitle eval that invents titles is
not measuring the shipped system. These come from the shipped title prompt
verbatim (Activity.swift generateTitle), cached into checkpoints.json.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from model import call, names_work, tidy  # noqa: E402

HERE = Path(__file__).parent

TITLE_PROMPT = """A user opened a working session with one request, then continued.

FIRST REQUEST:
{opening}

LATER REQUESTS:
{requests}

Decide which of these two is true:
(a) The later requests are follow-ups that serve the FIRST request — the session
    is still about the thing it opened with.
(b) The first request was answered or set aside early, and most later requests
    are about a DIFFERENT problem the session then settled on.

If (a), name the first request's goal. If (b), name that different problem.
Do not name whatever the most recent single request happens to be.

If there are only one or two later requests, there is not yet enough evidence
that the session has moved on — name the first request's goal.

Name the subject the user is working on, not the assistant's response to it.
Never describe replying, greeting, acknowledging, helping or answering.

Answer with only a 3 to 6 word imperative task name. No quotes. No trailing period.

NAME:"""


def main() -> None:
    path = HERE / "checkpoints.json"
    cps = json.loads(path.read_text())
    for i, c in enumerate(cps, 1):
        if c.get("title"):
            continue
        prompt = TITLE_PROMPT.format(opening=c["opening"][:400],
                                     requests=c["requests"][:1200])
        raw = call(prompt, max_tokens=40)
        s, _ = tidy(raw, max_chars=90)
        # The bridge keeps the previous title when generation is rejected; with no
        # previous title in a replay, record the failure rather than inventing one.
        c["title"] = s if (s and names_work(s)) else ""
        print(f"{i:3d}/{len(cps)} {c['id']:14s} {c['title']!r}", flush=True)
    path.write_text(json.dumps(cps, indent=1))


if __name__ == "__main__":
    main()
