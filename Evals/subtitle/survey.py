"""List candidate sessions in a date window with their prompt counts.

Covers all three agents the deck reads, because the subtitle prompt is shared:
claude (~/.claude/projects), pi (~/.pi/agent/sessions), codex (~/.codex/sessions).
"""

import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from digest import replay  # noqa: E402

SOURCES = [
    ("claude", Path.home() / ".claude" / "projects"),
    ("pi", Path.home() / ".pi" / "agent" / "sessions"),
    ("codex", Path.home() / ".codex" / "sessions"),
]
START = datetime(2026, 8, 8).timestamp()
END = datetime(2026, 8, 17).timestamp()
MIN_PROMPTS = 3

rows = []
for kind, root in SOURCES:
    if not root.exists():
        continue
    for p in root.rglob("*.jsonl"):
        st = p.stat()
        if not (START <= st.st_mtime <= END) or st.st_size < 30_000:
            continue
        try:
            cps = replay(p, kind)
        except Exception as e:  # noqa: BLE001
            print(f"skip {p.name}: {e}", file=sys.stderr)
            continue
        if len(cps) < MIN_PROMPTS:
            continue
        rows.append((len(cps), st.st_mtime, kind, p, cps[0].opening))

rows.sort(key=lambda r: (r[2], -r[0]))
for n, mt, kind, p, opening in rows:
    day = datetime.fromtimestamp(mt).strftime("%m-%d %H:%M")
    # Claude slugs the cwd into the directory name; drop the home prefix for display.
    home_slug = str(Path.home()).replace("/", "-") + "-"
    label = p.parent.name.replace(home_slug, "").replace("--", "")[:40]
    print(f"{kind:6s} {n:3d}  {day}  {label:40s}  {p.name[:8]}  {opening[:80]!r}")
print(f"\n{len(rows)} sessions", file=sys.stderr)
