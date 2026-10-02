#!/usr/bin/env python3
"""Report Codex's session to its real Herdr pane.

Codex hooks can run in a shared app-server daemon whose HERDR_PANE_ID belongs to
an old pane. Match the rollout's start time and cwd to a live Codex process
instead of trusting the hook's inherited pane environment.
"""

import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

HERDR = Path.home() / ".local/bin/herdr"
ROLLOUT = re.compile(r"rollout-(\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d)-([0-9a-f-]+)\.jsonl$")


def herdr(*args):
    result = subprocess.run([str(HERDR), *args], capture_output=True, text=True, timeout=2)
    if result.returncode:
        return None
    if not result.stdout.strip():
        return {"ok": True}
    try:
        return json.loads(result.stdout).get("result")
    except json.JSONDecodeError:
        return None


def started(pid):
    result = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="],
                            capture_output=True, text=True, timeout=2)
    if result.returncode:
        return None
    try:
        return dt.datetime.strptime(" ".join(result.stdout.split()), "%a %b %d %H:%M:%S %Y")
    except ValueError:
        return None


def candidates(cwd, rollout_start):
    snapshot = herdr("api", "snapshot")
    if not snapshot:
        return []
    found = []
    for agent in snapshot["snapshot"].get("agents", []):
        if agent.get("agent") != "codex" or agent.get("cwd") != cwd:
            continue
        pane = agent.get("pane_id")
        info = herdr("pane", "process-info", "--pane", pane)
        if not info:
            continue
        processes = info["process_info"].get("foreground_processes", [])
        for process in processes:
            if process.get("name") != "codex":
                continue
            process_start = started(process["pid"])
            if process_start:
                delta = abs((process_start - rollout_start).total_seconds())
                if delta <= 8:
                    found.append((delta, pane))
    return sorted(found)


def main():
    if os.environ.get("HERDR_ENV") != "1":
        return 0
    try:
        payload = json.load(sys.stdin)
        session_id = payload["session_id"]
        path = Path(payload["transcript_path"])
        match = ROLLOUT.fullmatch(path.name)
        if not match or match.group(2) != session_id:
            return 0
        with path.open() as stream:
            meta = json.loads(stream.readline())
        if meta.get("type") != "session_meta" or meta.get("payload", {}).get("id") != session_id:
            return 0
        cwd = meta["payload"]["cwd"]
        rollout_start = dt.datetime.strptime(match.group(1), "%Y-%m-%dT%H-%M-%S")
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
        return 0

    for attempt in range(6):
        matches = candidates(cwd, rollout_start)
        if len(matches) == 1:
            pane = matches[0][1]
            if herdr("pane", "report-agent-session", pane, "--source", "herdr:codex",
                     "--agent", "codex", "--agent-session-id", session_id,
                     "--seq", str(time.time_ns())):
                return 0
        if attempt < 5:
            time.sleep(0.5)
    return 0  # Hooks must never interrupt Codex startup.


if __name__ == "__main__":
    sys.exit(main())
