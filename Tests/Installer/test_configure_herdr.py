from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "configure_herdr", ROOT / "Scripts/configure_herdr.py"
)
assert SPEC and SPEC.loader
configure_herdr = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(configure_herdr)
FRAGMENT = (ROOT / "Config/herdr-sidebar.toml").read_text(encoding="utf-8")


class ConfigureHerdrTests(unittest.TestCase):
    def test_adds_managed_table_before_ui_toast(self) -> None:
        source = "onboarding = false\n\n[ui]\nagent_panel_sort = \"priority\"\n\n[ui.toast]\ndelivery = \"herdr\"\n"

        result = configure_herdr.render_apply(source, FRAGMENT)

        self.assertIn(configure_herdr.BEGIN, result)
        self.assertLess(result.index("[ui.sidebar.agents]"), result.index("[ui.toast]"))
        self.assertIn('{ token = "tab", bold = true, dim = false }', result)

    def test_replaces_existing_unmanaged_table_and_agent_row(self) -> None:
        source = """[ui]
agent_panel_sort = "priority"

[ui.sidebar.agents]
rows = [["state_icon", "workspace", "tab"], ["agent"]]

[ui.toast]
delivery = "herdr"
"""

        result = configure_herdr.render_apply(source, FRAGMENT)

        self.assertEqual(result.count("[ui.sidebar.agents]"), 1)
        self.assertNotIn('["agent"]', result)
        self.assertIn('{ token = "workspace", bold = false, dim = true }', result)

    def test_apply_is_idempotent(self) -> None:
        once = configure_herdr.render_apply("[ui]\n", FRAGMENT)
        twice = configure_herdr.render_apply(once, FRAGMENT)

        self.assertEqual(twice, once)

    def test_remove_drops_only_managed_block(self) -> None:
        applied = configure_herdr.render_apply(
            "[ui]\nagent_panel_sort = \"priority\"\n\n[theme]\nname = \"gruvbox\"\n",
            FRAGMENT,
        )

        result = configure_herdr.render_remove(applied)

        self.assertNotIn("ui.sidebar.agents", result)
        self.assertIn('agent_panel_sort = "priority"', result)
        self.assertIn('name = "gruvbox"', result)

    def test_atomic_write_preserves_first_backup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.toml"
            config.write_text("original\n", encoding="utf-8")
            configure_herdr.atomic_write(config, "first\n")
            configure_herdr.atomic_write(config, "second\n")

            self.assertEqual(config.read_text(encoding="utf-8"), "second\n")
            self.assertEqual(
                config.with_name("config.toml.before-agentdeck").read_text(encoding="utf-8"),
                "original\n",
            )


if __name__ == "__main__":
    unittest.main()
