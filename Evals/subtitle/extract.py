"""Pull labelling checkpoints out of the manifest's sessions.

Three checkpoints per session, spread across its length. A subtitle's job changes
as a session ages — early on it is close to the opening request, late on it is a
detail the title cannot contain — so sampling only the tail would grade the easy
half. Index 1 is skipped: at the first prompt the subtitle is the title by
construction and there is nothing to discriminate.
"""

import json
import sys
from dataclasses import asdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from digest import replay  # noqa: E402

HERE = Path(__file__).parent
ROOTS = {
    "claude": Path.home() / ".claude" / "projects",
    "pi": Path.home() / ".pi" / "agent" / "sessions",
    "codex": Path.home() / ".codex" / "sessions",
}
FRACTIONS = (0.25, 0.55, 0.85)


def find(kind: str, match: str) -> Path | None:
    hits = [p for p in ROOTS[kind].rglob("*.jsonl") if match in p.name]
    if not hits:
        return None
    return max(hits, key=lambda p: p.stat().st_size)


def sample(n: int) -> list[int]:
    """1-based checkpoint indices, spread, never index 1, never duplicated."""
    picks: list[int] = []
    for f in FRACTIONS:
        i = max(2, min(n, round(n * f)))
        if i not in picks:
            picks.append(i)
    return picks


def main() -> None:
    manifest = json.loads((HERE / "manifest.json").read_text())
    out = []
    for entry in manifest["sessions"]:
        path = find(entry["kind"], entry["match"])
        if path is None:
            print(f"MISSING {entry['kind']} {entry['match']}", file=sys.stderr)
            continue
        cps = replay(path, entry["kind"])
        if len(cps) < 2:
            print(f"THIN    {entry['match']} ({len(cps)} prompts)", file=sys.stderr)
            continue
        for i in sample(len(cps)):
            c = cps[i - 1]
            d = asdict(c)
            d["id"] = f"{entry['match'][:8]}#{i}"
            d["domain"] = entry["domain"]
            d["session_note"] = entry["note"]
            d["total_prompts"] = len(cps)
            out.append(d)
        print(f"ok      {entry['match'][:8]} {entry['kind']:6s} "
              f"{len(cps):3d} prompts -> {sample(len(cps))}", file=sys.stderr)

    (HERE / "checkpoints.json").write_text(json.dumps(out, indent=1))
    print(f"\n{len(out)} checkpoints -> checkpoints.json", file=sys.stderr)


if __name__ == "__main__":
    main()
