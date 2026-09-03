# AgentDeck

A glanceable dashboard for your [Herdr](https://herdr.dev/) coding-agent sessions,
served from a Mac to any browser on your Tailscale network. Put an old iPad next to the
keyboard and it shows every Claude Code, Codex and pi session at once: which one is
working, which one finished while you were looking elsewhere, and what each one is
actually doing, in a title, a subtitle and an outcome written by a local model from the
session's own transcript. Tap a card to focus that pane in Herdr.

```
Herdr (Unix socket)  →  agentdeck-bridge (Swift, macOS)  →  SSE  →  browser
                              ↑                                        │
                    herdr focus / create tab  ←───────── POST actions ─┘
```

This is the macOS-native original, built around launchd, Tailscale Serve, Herdr's
sidebar and CodexBar. A portable Rust version for macOS, Linux and Windows lives at
[JasonBates/agentdeck-rs](https://github.com/JasonBates/agentdeck-rs). The idea started
as a retarget of [spencerbull/xeneon-edge-agents](https://github.com/spencerbull/xeneon-edge-agents)
from Omarchy/Quickshell to macOS.

## What it does

- One feed for Claude, Codex and pi sessions, grouped by repository. Linked worktrees
  stay under one project pill and keep their own workspace label on the card.
- Live state pushed over Server-Sent Events. A focus change on the desktop reaches the
  panel in 25 to 90 ms; a one-second poll remains as a reconciliation backstop.
- Per card: a stable session title, the step now underway, the latest outcome, the
  agent's own phase line, context-window fill, background shells and subagents still
  running, and whether the reply landed since you last looked.
- **Next** cycles through blocked agents and unread finished replies. **+** opens a new
  Herdr tab in the selected project. Long-press and drag arranges the board per device.
- An accepted title also becomes the Herdr tab label, so the sidebar and the deck agree.
- Machine load, memory, the local model's residency and latency, and optionally your
  Claude and Codex quota windows in the footer.

Every feed degrades loudly: a dead source renders as "unavailable", never as a stale
value that still looks live. The design behind all of this, including the traps found
along the way, is in [docs/design.md](docs/design.md).

## What it reads on your machine

Read this before installing. AgentDeck is local-first, but it reads more than most
dashboards do, because that is where the useful signal is.

- **Herdr state** through `herdr api snapshot` and the event socket, plus the visible
  screen of working panes (and idle Claude and Codex panes every 5 s) to parse phase and
  background-work lines.
- **Agent transcripts on disk**: `~/.claude/projects`, `~/.codex/sessions`, and the pi
  session path Herdr reports. Bounded excerpts of your own prompts and the agent's
  replies are sent to **Ollama on 127.0.0.1** to generate headings. Nothing is sent
  anywhere else. Set `AGENTDECK_MODEL=off` and no transcript text leaves the process.
- **A heading log** at `~/.local/state/agentdeck/headings.jsonl`: every generated
  heading, accepted or rejected, with the pane and transcript path. It rolls at 20 MB.
  Delete it whenever you like.
- **Claude and Codex quota**, only if you install CodexBar and grant Full Disk Access.
  CodexBar reads Safari's cookie jar and calls undocumented provider endpoints. The last
  good reading is cached at `~/.cache/agentdeck/capacity.json`.

There is no telemetry, no account and no cloud model. The bridge binds `127.0.0.1` only.
Tailscale Serve, if you use it, makes the deck reachable by every device in your tailnet
and nothing outside it. There is no login on top of that, so treat the deck as visible to
everyone in the tailnet, actions included, and never expose it with `tailscale funnel`.

## Requirements

| | Why | Check |
|---|---|---|
| macOS 14+ with Xcode 16 | Swift 6 toolchain to build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift --version` |
| **Herdr** ≥ 0.8.0 | the whole data model | `herdr status` |
| Ollama with `gemma4:12b` | generated card headings (recommended) | `ollama list` |
| Tailscale | reach the deck from other devices (optional) | `tailscale status` |
| Developer ID identity | keeps the Full Disk Access grant across rebuilds (optional) | `security find-identity -v -p codesigning` |
| CodexBar | quota in the footer (optional) | `brew install --cask codexbar` |

Without Ollama the deck still runs; cards fall back to Herdr's terminal titles. Without
Tailscale it stays on `127.0.0.1`. Without a Developer ID it is signed ad hoc, which only
matters for the quota feature. `gemma4:12b` is 7.6 GB on disk and about 8 GB resident;
smaller alternatives and the reasons for the default are in
[docs/design.md](docs/design.md#model-choice).

## Install

```bash
git clone https://github.com/JasonBates/agentdeck.git
cd agentdeck
./Scripts/setup
```

`setup` checks the prerequisites, reports which optional ones are missing, pulls the
heading model if Ollama is running, then hands over to the installer. For every later
update:

```bash
./Scripts/install.sh
```

The installer builds a release binary, installs it to `~/.local/bin/agentdeck-bridge`,
signs it, writes a LaunchAgent (`com.agentdeck.bridge`) with `KeepAlive` and
`RunAtLoad`, starts it, merges the sidebar fragment in
[`Config/herdr-sidebar.toml`](Config/herdr-sidebar.toml) into `~/.config/herdr/config.toml`
(keeping the first pre-change file as `config.toml.before-agentdeck`), and, when
Tailscale is connected, publishes the deck as described in the next section. No
machine-specific file is checked in; everything is derived from the current account.

```bash
./Scripts/install.sh --uninstall             # stop the agent, remove plist, binary, routes, sidebar table
./Scripts/install.sh --uninstall --dry-run   # print what that would remove
```

Uninstalling preserves every other Herdr setting and keeps `~/Library/Logs/agentdeck.log`
deliberately: it is the only record of why a bridge was misbehaving before it was removed.

Service commands, should you need them:

```bash
launchctl kickstart -k gui/$(id -u)/com.agentdeck.bridge   # restart
launchctl bootout   gui/$(id -u)/com.agentdeck.bridge      # stop
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.agentdeck.bridge.plist
```

For a foreground run instead of the service:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run AgentDeckBridge
```

Then open <http://127.0.0.1:9798>.

## Reach it from another device

The bridge never leaves loopback. Tailscale Serve puts TLS in front of it and makes it
reachable from every device in your tailnet, with a certificate Safari accepts for
Add-to-Home-Screen. The installer does this for you when Tailscale is connected:

```
https://<machine>.<tailnet>.ts.net/deck
https://<machine>.<tailnet>.ts.net:9797/
```

Before this can work, your tailnet needs **MagicDNS** and **HTTPS certificates** enabled
(admin console, DNS page); `tailscale serve` names the missing setting if they are not.
`tailscale status` shows the machine's name. Two things then have to agree, and the
installer sets both:

1. **Serve routes.** `tailscale serve --bg --set-path=/deck http://127.0.0.1:9798` and
   `tailscale serve --bg --https=9797 http://127.0.0.1:9798`. Remove them with the same
   commands and `off` in place of the target.
2. **The addresses the bridge will answer for.** The bridge refuses `/api/*` and
   `/events` for any `Host` it has not been told about, which is what stops other web
   pages in your browser from reading the deck. The installer discovers the tailnet name
   and stores `AGENTDECK_PUBLIC_HOST=<machine>.<tailnet>.ts.net` (covers the `/deck`
   path) and `AGENTDECK_ALLOWED_ORIGINS=https://<machine>.<tailnet>.ts.net:9797` (the
   port form) in the LaunchAgent. If you front the bridge with something else, set those
   yourself. When they are missing the page loads, then tells you exactly which variable
   to set.

### Setting it up by hand

If you install with `AGENTDECK_CONFIGURE_TAILSCALE=off`, front the bridge with a
different TLS proxy, or want only one of the two URL forms, do the installer's two steps
yourself. Take the hostname from `tailscale status --json | grep -m1 DNSName` (drop the
trailing dot).

```bash
# 1. Tell the bridge which addresses to answer for, then reinstall so the LaunchAgent
#    carries them. Use only the line(s) for the form(s) you will publish.
AGENTDECK_PUBLIC_HOST=studio.tail1234.ts.net \
AGENTDECK_ALLOWED_ORIGINS=https://studio.tail1234.ts.net:9797 \
AGENTDECK_CONFIGURE_TAILSCALE=off ./Scripts/install.sh

# 2. Publish. Path form on the standard HTTPS port, port form on its own port, or both.
tailscale serve --bg --set-path=/deck http://127.0.0.1:9798
tailscale serve --bg --https=9797 http://127.0.0.1:9798
tailscale serve status
```

For a foreground run, put the same two variables in front of `swift run AgentDeckBridge`.
`AGENTDECK_PUBLIC_HOST` covers an address with no port; anything with a port, or without
TLS, goes in `AGENTDECK_ALLOWED_ORIGINS` as a full `scheme://host:port` origin,
comma-separated. Check the result with
`curl -s https://studio.tail1234.ts.net/deck/api/snapshot`: JSON means both steps agree,
`403 origin_rejected` means step 1 does not match the address you used. Undo with
`tailscale serve --set-path=/deck off` and `tailscale serve --https=9797 off`.

The bridge port and the Serve port must differ: Serve binds `<tailnet-ip>:9797` itself,
and a bridge on the same port fails with `EADDRINUSE`, invisibly, because `lsof` does not
attribute tailscaled's listeners (`netstat -an` does).

**A direct `IP:port` will not work** and is not worth fighting. macOS's firewall runs in
stealth mode and never prompts for a CLI binary launched from a shell, so direct
connections are dropped on every interface but loopback. Serve sidesteps that entirely.

On the iPad: Share, **Add to Home Screen** for a standalone full-screen app; then
Settings, Display & Brightness, Auto-Lock, Never; and Guided Access to pin it.

## Configuration

Runtime settings are environment variables, or flags for the first four. The installer
persists any of these that are set when it runs.

| Environment | CLI | Default | Purpose |
|---|---|---|---|
| `AGENTDECK_PORT` | `--port` | `9798` | loopback HTTP port |
| `AGENTDECK_INTERVAL` | `--interval` | `1.0` | reconciliation poll, in seconds |
| `AGENTDECK_MODEL` | `--model` | `gemma4:12b` | heading model; `off` disables all generation |
| `AGENTDECK_TITLE_MODEL` | `--title-model` | same as model | separate model for titles only |
| `AGENTDECK_NAMES` | | `all` | `all`: the model names every card; `fallback`: only cards whose Herdr title is generic (pi, Codex) |
| `AGENTDECK_TAB_TITLES` | | `on` | write accepted titles into Herdr tab labels; `off` keeps labels manual |
| `AGENTDECK_PUBLIC_HOST` | | none | hostname a TLS proxy presents the bridge as |
| `AGENTDECK_ALLOWED_ORIGINS` | | none | further `scheme://host[:port]` origins to answer for, comma-separated |
| `AGENTDECK_PUBLIC` | | package `Public/` | directory containing `index.html` |
| `AGENTDECK_BACKGROUND_INTERVAL` | | `5` | seconds between screen reads of idle Claude and Codex panes |
| `AGENTDECK_DEBUG` | | unset | `1` logs generation decisions to stderr |

Installer-only variables: `AGENTDECK_IDENTITY`, `AGENTDECK_DEST`, `AGENTDECK_PLIST`,
`AGENTDECK_LOG`, `AGENTDECK_PATH`, `AGENTDECK_LABEL`, `AGENTDECK_PUBLIC_PORT`,
`AGENTDECK_PUBLIC_PATH`, `AGENTDECK_HERDR_CONFIG_PATH`, and
`AGENTDECK_CONFIGURE_HERDR` / `AGENTDECK_CONFIGURE_TAILSCALE` (`auto`, `on`, `off`).
Overriding the label or port installs a secondary bridge that leaves the production
sidebar and routes alone unless those two are set to `on`.

Tab-title ownership is conservative: only a default-numbered tab with one detected agent
is claimed, a manual rename releases it, and ownership survives restarts in
`~/.local/state/agentdeck/tab-titles.json`.

`Public/index.html` is read from disk on every request, so HTML and CSS changes need only
a reload; Swift changes need a rebuild.

## Full Disk Access

Needed only for Claude quota in the footer. The bridge shells out to `codexbar`, which
reads Safari's cookie jar; a headless process without FDA fails with "No Claude session
key found in browser cookies". Add both to System Settings, Privacy & Security, Full Disk
Access, then restart each:

- `~/.local/bin/agentdeck-bridge`
- `CodexBar.app` (menu-bar-only, no Dock icon)

macOS keys the grant to the binary's code identity. A Developer ID signature keeps that
identity stable across rebuilds; an ad-hoc signature changes it on every build, and TCC
then drops the grant silently, so quota goes quietly stale until you re-grant it.

## Development

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
python3 -m unittest Tests/Installer/test_configure_herdr.py
```

Pinning `DEVELOPER_DIR` keeps compiler and SDK from the same Xcode; the standalone
Command Line Tools can drift to a different Swift. Browser-visible changes are tested
with an on-demand preview that never touches the installed service; see
[AGENTS.md](AGENTS.md). Heading-model evaluations and their results are under
[`Evals/subtitle`](Evals/subtitle/README.md).

Security reports: see [SECURITY.md](SECURITY.md). Licence: [MIT](LICENSE).
