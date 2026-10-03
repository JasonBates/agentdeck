import datetime as dt
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "codex_session_hook",
    Path(__file__).resolve().parents[2] / "Scripts/codex-session-hook.py",
)
hook = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hook)


class CodexSessionHookTests(unittest.TestCase):
    old = dt.datetime(2026, 10, 2, 23, 33, 43)
    launch = dt.datetime(2026, 10, 3, 9, 42, 20)
    arrival = launch + dt.timedelta(seconds=2)

    def setUp(self):
        self.agents = [{"agent": "codex", "cwd": "/work", "pane_id": "p1"}]
        self.processes = {"p1": [{"name": "codex", "pid": 1}]}
        self.starts = {1: self.launch}
        self.calls = []
        self.addCleanup(patch.stopall)
        patch.object(hook, "herdr", side_effect=self.herdr).start()
        patch.object(hook, "started", side_effect=self.starts.get).start()
        patch.object(hook.time, "sleep").start()

    def herdr(self, *args):
        self.calls.append(args)
        if args == ("api", "snapshot"):
            return {"snapshot": {"agents": self.agents}}
        if args[:2] == ("pane", "process-info"):
            return {"process_info": {"foreground_processes": self.processes[args[-1]]}}
        return {"ok": True}

    def resumed(self):
        return hook.candidates("/work", self.old, source="resume", hook_start=self.arrival)

    def test_fresh_launch_still_matches_rollout(self):
        self.assertEqual(hook.candidates("/work", self.arrival), [(2, "p1")])

    def test_resume_matches_current_launch_not_yesterdays_rollout(self):
        self.assertEqual(hook.candidates("/work", self.old), [])
        self.assertEqual(self.resumed(), [(2, "p1")])

    def test_resume_rejects_original_process_and_unrelated_cwd(self):
        self.starts[1] = self.old
        self.assertEqual(self.resumed(), [])
        self.starts[1] = self.launch
        self.agents[0]["cwd"] = "/other"
        self.assertEqual(self.resumed(), [])

    def test_resume_does_not_match_future_or_old_process(self):
        for start in (self.arrival + dt.timedelta(seconds=1),
                      self.arrival - dt.timedelta(seconds=31)):
            self.starts[1] = start
            self.assertEqual(self.resumed(), [])

    def test_deduplicates_processes_in_one_pane(self):
        self.processes["p1"].append({"name": "codex", "pid": 2})
        self.starts[2] = self.launch
        self.assertEqual(self.resumed(), [(2, "p1")])

    def invoke(self, source="resume", session_id="abc-123"):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rollout-2026-10-02T23-33-43-abc-123.jsonl"
            path.write_text(json.dumps({"type": "session_meta", "payload": {
                "id": "abc-123", "cwd": "/work"}}) + "\n")
            payload = {"session_id": session_id, "transcript_path": str(path), "source": source}
            with patch.dict(hook.os.environ, {"HERDR_ENV": "1", "HERDR_PANE_ID": "stale"}), \
                 patch.object(hook.sys, "stdin", io.StringIO(json.dumps(payload))), \
                 patch.object(hook.dt, "datetime", wraps=dt.datetime) as clock:
                clock.now.return_value = self.arrival
                self.assertEqual(hook.main(), 0)
        return [c for c in self.calls if c[:2] == ("pane", "report-agent-session")]

    def test_resume_reports_correct_session_despite_stale_environment(self):
        reports = self.invoke()
        self.assertEqual(len(reports), 1)
        self.assertEqual(reports[0][2], "p1")
        self.assertIn("abc-123", reports[0])

    def test_ambiguous_resume_never_reports_closest_pane(self):
        self.agents.append({"agent": "codex", "cwd": "/work", "pane_id": "p2"})
        self.processes["p2"] = [{"name": "codex", "pid": 2}]
        self.starts[2] = self.launch + dt.timedelta(seconds=1)
        self.assertEqual(self.invoke(), [])

    def test_rejects_mismatched_session_and_non_launch_events(self):
        self.assertEqual(self.invoke(session_id="wrong"), [])
        self.assertEqual(self.invoke(source="compact"), [])
        self.assertEqual(self.calls, [])

    def test_timeout_never_interrupts_codex(self):
        with patch.object(hook, "herdr", side_effect=subprocess.TimeoutExpired("herdr", 2)):
            self.assertEqual(self.invoke(), [])


if __name__ == "__main__":
    unittest.main()
