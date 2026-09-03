# AgentDeck Development

## Worktree preview

Browser previews are on-demand and must not replace or restart the installed production
service. Corral gives each worktree a stable port and a `server` tab. When browser-visible
UI or live bridge behavior needs testing, run this in that tab:

```bash
hwt dev
```

The command stays in the foreground, builds the current worktree with Xcode's matching
Swift toolchain, runs its bridge with the normal `gemma4:12b` heading model, and publishes
the Corral port through Tailscale as `/test1`, `/test2`, and so on. Press Ctrl-C when
testing is finished; that stops the worktree bridge and removes only its Tailscale route.
Do not install a watcher or an always-running preview service.

The heading model is `AGENTDECK_MODEL`, default `gemma4:12b` (`main.swift:64`), and it
drives titles, subtitles and state summaries alike. Before changing it, read
`Evals/subtitle/MODEL-SWITCH.md` — it measures `qwen3.8:27b` against the shipped
setup and says what to change and, more usefully, what not to.

Set `AGENTDECK_PREVIEW_MODEL=off hwt dev` only when a lightweight, non-LLM preview is
explicitly wanted. Use `hwt status` to see the worktree's leased port and whether it is
listening. Outside Corral, the low-level equivalent is
`./Scripts/preview run --port <a free 4100-4199 port>`.

`Public/index.html` is loaded from the worktree on each request, so HTML and CSS changes
need only a browser refresh. Swift changes require Ctrl-C followed by `hwt dev` to rebuild.

Production remains the signed binary at `~/.local/bin/agentdeck-bridge`, listening on
`127.0.0.1:9798` and published at `/deck` and port `9797` under the launchd label
`com.agentdeck.bridge`.

Corral and `hwt` are one maintainer's worktree tooling, not a requirement. Without them,
`./Scripts/preview run --port <4100-4199>` is the whole preview path; it needs Tailscale
for the `/testN` route, so on a machine without Tailscale run the bridge directly with
`swift run AgentDeckBridge --port <n>` and open it on loopback.
