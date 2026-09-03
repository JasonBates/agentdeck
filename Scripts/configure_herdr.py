#!/usr/bin/env python3
"""Install or remove AgentDeck's owned Herdr sidebar table without touching other config."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shutil
import tempfile


BEGIN = "# BEGIN AGENTDECK: HERDR SIDEBAR"
END = "# END AGENTDECK: HERDR SIDEBAR"
TABLE = "[ui.sidebar.agents]"
HEADER = re.compile(r"(?m)^[ \t]*\[\[?[A-Za-z0-9_.-]+(?:\.[A-Za-z0-9_.-]+)*\]?\][ \t]*(?:#.*)?$")


def managed_block(fragment: str) -> str:
    return f"{BEGIN}\n{fragment.strip()}\n{END}\n"


def remove_managed(text: str) -> tuple[str, bool]:
    pattern = re.compile(
        rf"(?ms)^[ \t]*{re.escape(BEGIN)}\n.*?^[ \t]*{re.escape(END)}[ \t]*\n?"
    )
    updated, count = pattern.subn("", text)
    return updated, count > 0


def remove_unmanaged_table(text: str) -> tuple[str, int | None]:
    table = re.search(rf"(?m)^[ \t]*{re.escape(TABLE)}[ \t]*(?:#.*)?$", text)
    if table is None:
        return text, None

    next_header = HEADER.search(text, table.end())
    end = next_header.start() if next_header else len(text)
    start = table.start()
    while start > 0 and text[start - 1] == "\n":
        start -= 1
        if start == 0 or text[start - 1] != "\n":
            break
    return text[:start] + text[end:], start


def insert_block(text: str, block: str, preferred_offset: int | None = None) -> str:
    if preferred_offset is not None:
        offset = min(preferred_offset, len(text))
    else:
        following = re.search(r"(?m)^[ \t]*\[ui\.toast\][ \t]*(?:#.*)?$", text)
        offset = following.start() if following else len(text)

    before = text[:offset].rstrip()
    after = text[offset:].lstrip("\n")
    pieces = [before, block.rstrip(), after.rstrip()]
    return "\n\n".join(piece for piece in pieces if piece) + "\n"


def render_apply(text: str, fragment: str) -> str:
    without_markers, had_markers = remove_managed(text)
    without_table, table_offset = remove_unmanaged_table(without_markers)
    preferred = table_offset if table_offset is not None else None
    if had_markers and preferred is None:
        # A managed block was removed before table detection could see its inner header.
        marker_offset = text.find(BEGIN)
        preferred = min(marker_offset, len(without_table))
    return insert_block(without_table, managed_block(fragment), preferred)


def render_remove(text: str) -> str:
    updated, _ = remove_managed(text)
    return updated.rstrip() + ("\n" if updated.strip() else "")


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    previous_mode = path.stat().st_mode & 0o777 if path.exists() else 0o600
    if path.exists():
        backup = path.with_name(path.name + ".before-agentdeck")
        if not backup.exists():
            shutil.copy2(path, backup)

    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, prefix=path.name + ".", delete=False
    ) as handle:
        handle.write(text)
        temporary = Path(handle.name)
    os.chmod(temporary, previous_mode)
    os.replace(temporary, path)


def main() -> int:
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("apply", "remove"))
    parser.add_argument(
        "--config",
        type=Path,
        default=Path.home() / ".config/herdr/config.toml",
    )
    parser.add_argument(
        "--fragment",
        type=Path,
        default=repo / "Config/herdr-sidebar.toml",
    )
    args = parser.parse_args()

    original = args.config.read_text(encoding="utf-8") if args.config.exists() else ""
    if args.action == "apply":
        updated = render_apply(original, args.fragment.read_text(encoding="utf-8"))
    else:
        updated = render_remove(original)

    if updated == original:
        print(f"Herdr config unchanged: {args.config}")
        return 0
    atomic_write(args.config, updated)
    print(f"Herdr config updated: {args.config}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
