# Contributing

Issues and pull requests are welcome. Before opening a PR:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
python3 -m unittest Tests/Installer/test_configure_herdr.py
bash -n Scripts/install.sh Scripts/setup Scripts/preview
```

Never commit real transcripts, prompts, replies, session or pane IDs, hostnames, or paths
under your home directory. Test fixtures are synthetic. The evaluation corpus under
`Evals/subtitle` is regenerated locally and stays gitignored for that reason.

Browser-visible changes are checked with an on-demand preview that never replaces the
installed service; see [AGENTS.md](AGENTS.md). Keep design rationale in
[docs/design.md](docs/design.md) and user-facing instructions in the README.
