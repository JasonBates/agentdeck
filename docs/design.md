# AgentDeck design notes

How the Swift bridge works and why it works that way. This is the material that used
to live in the README; the README now covers installing and running it. Nothing here is
needed to use AgentDeck, but most of it was learned the hard way and is worth having
before changing the bridge or the page.

## Model choice

**Why this model.** Benchmarked against `llama3.2:3b`, `qwen3:4b-instruct` and
`gemma3:4b` on ten real mid-conversation snapshots with five repeats per cell:

| | title vs references | subtitle violations | outcome violations |
|---|---|---|---|
| **gemma4:12b** | **~8/10** | **0.0%** | **0.0%** |
| qwen3:4b-instruct | ~6/10 | 20.0% | 10.0% |
| llama3.2:3b | — | 14.7% style violations overall | |
| gemma3:4b | — | 14.7% style violations overall | |

It is ~2.5× slower (outcome median 1.61s), which costs nothing: headings are
background jobs and focus/status still arrive by push event in ~25ms.

Smaller alternatives, if 8 GB resident is too much:

```bash
AGENTDECK_MODEL=qwen3:4b-instruct        # 3.17 GB, noticeably weaker headings
AGENTDECK_TITLE_MODEL=gemma4:12b         # …or split: big model for titles only
AGENTDECK_MODEL=off                      # no LLM at all
```

By default `AGENTDECK_NAMES=all` gives every card a transcript-derived title. Set
`AGENTDECK_NAMES=fallback` to generate titles only where Herdr has no useful one (normally
pi and Codex); subtitles and outcomes still generate for every readable transcript.
Titles regenerate frequently while a session is young, then less often as its purpose
settles. Subtitles key off real user prompts and outcomes key off completed replies;
harness-injected context, tool output and resumed-session metadata are filtered out.

An accepted model title also becomes the Herdr tab label. AgentDeck claims only a
default-labelled tab (shown by Herdr as its number) containing one detected agent,
follows later title improvements, and stops managing the tab if you rename it yourself.
Clearing a manual label makes the tab eligible again. Ownership survives bridge restarts in
`~/.local/state/agentdeck/tab-titles.json`; set `AGENTDECK_TAB_TITLES=off` to keep Herdr
labels entirely manual.

All generation attempts, including rejected outputs, are appended as JSONL to
`~/.local/state/agentdeck/headings.jsonl`. The log rolls to `.1` at 20 MB. Generation is
serialised off the bridge tick; activity reads only working panes, ignores unchanged
screens, and has a 20-second per-pane cooldown.

> [!warning] Two traps, both cost hours to find
> **`num_ctx` matters more than model size.** Ollama allocates KV cache for the model's
> *declared* window unless told otherwise. `llama3.2:3b` declares 131072 tokens, so a
> 2 GB model pinned **17.2 GB** and pushed the machine into swap. Every prompt here is
> under 1k tokens; the bridge sends `num_ctx: 4096`.
>
> **Gemma 4 is a thinking model by default.** On `/api/generate` it spends the entire
> token budget on a hidden reasoning block and returns empty content — 27 of 30 calls in
> testing. The bridge uses `/api/chat` with `think: false`, which also applies each
> model's own chat template.

## Design notes

**SSE, not WebSocket.** The deck is a one-way push of state; actions are ordinary POSTs.
EventSource reconnects by itself. Swap in `NWProtocolWebSocket` only if a native iPad app
later needs bidirectional traffic.

**Every feed degrades loudly.** `herdr`, `capacity` and `host` each carry their own
`ok`/`reason`. A dead source renders as an explicit "unavailable", never a stale value
that still looks live. The client goes visibly stale after 12s of silence.

**Change-detected broadcasts, with a 5s liveness floor.** Payloads are compared
byte-for-byte and identical ones are suppressed. Three fields had to be tamed to make
that work at all — see below. The floor exists so the client can distinguish "nothing is
happening" from "the bridge died".

**Event-driven, with polling as a safety net.** The bridge holds a Unix-socket
subscription to Herdr (`events.subscribe`, 13 global event types) and re-polls the
snapshot when one arrives. Events trigger a re-read rather than being folded into a
state model — that keeps one source of truth, since rebuilding state from a stream makes
every missed or reordered event a permanent drift bug. A focus change made on the desktop
reaches the panel in **24–87 ms**, versus ~550 ms when this polled at 1 Hz. The 1 s poll
remains as a reconciliation backstop and to carry the deck if the socket drops.

**Projects, not worktrees, own the top-level filters.** Herdr correctly gives every
linked worktree a separate workspace, but its snapshot also gives the parent checkout
and all linked worktrees the same `worktree.repo_key`. AgentDeck groups on that repository
identity, so their sessions render as distinct cards under one project pill; the original
Herdr workspace label stays on each card to identify the worktree.

**Expensive work lives off the tick.** A tick averages ~15 ms. Transcript digests are
cached against file size and mtime, screen reads are throttled to 1/sec per pane, machine
stats sample on their own 5 s timer (CPU percentages only exist between two samples), and
`codexbar` — which takes ~47 s — refreshes on a 5-minute timer. Calling that inline would
have hammered it several times a second once ticks became event-driven.

### Three things that quietly broke dedupe

Worth knowing if you extend the payload — anything that drifts per-tick makes every
poll look like a state change:

1. `terminal_title_stripped` still contains Claude's **animating** spinner glyph
   (◐ ◓ ◑ ◒). Herdr strips the idle marker `✳` but not the working one. `Deck.cleanTitle`
   drops any leading non-alphanumeric run.
2. A `generatedAt` timestamp in the payload. Removed — the client derives "Xs ago" from
   frame arrival instead.
3. The raw load average. Rounded to 1dp; at 2dp it still changed every second or two.

## Card anatomy and attention

**Title** — a 3–6 word session name generated from the opening and later real user
requests. It names the overall job rather than whichever exchange happened most recently.
Herdr's terminal title (or the tab label for generic pi and Codex titles) is the fallback.

**Subtitle** — the immediate task from the latest real user prompt, regenerated once per
prompt and rejected when it merely repeats the title.

**Phase** — when available, parsed from the agent's own visible status line (`✻
Incubating… (2m 20s · ↓ 6.1k tokens · thought for 17s)`) into verb / elapsed /
tokens / thinking. It updates about once a second. The bridge reads
`herdr agent read --source visible` because `--source recent` refuses on a working agent
(`agent_not_idle`).

**Background** — a teal chip reading `1 shell`, `2 shells · 1 subagent` or bare
`subagents`. A separate axis from status, and the reason it exists: an agent that starts
background work hands the prompt straight back and goes **idle**, so the card with six
research runs in flight was the one card showing nothing at all.

The three agents were run side by side and driven through every state; they agree on
nothing, so each surface is read on its own terms.

| Agent | Surface | Counted? |
|---|---|---|
| Claude | hint-line segment `· 1 shell ·` | yes |
| Claude | hint-line segment `· /tasks to see subagents ·` | **no** |
| Claude | status line `✻ Waiting for 1 background agent to finish`, shown with the agent tree while the main loop waits | yes |
| Codex | its own live line `2 background terminals running · /ps to view · /stop to close` | yes |
| pi3 | none — footer is mode, model and context only; a delegated worker leaves no persistent mark | — |

The decisive case is a Claude pane at `done` with a subagent still running, where the
whole evidence is one countless segment. A count is reported where one is offered and
presence alone where it is not, so the chip says `subagents` rather than inventing `1
subagent`. Codex's terminals are reported as shells: the chip is a deck-level idea, and
one word per agent would read as different things happening on adjacent cards.

Working panes get this free from the phase read. Idle Claude and Codex panes are read
every 5s of their own (`AGENTDECK_BACKGROUND_INTERVAL`); pi3 is never read while idle,
since there would be nothing to find.

**Activity** — a short present-tense label generated from the visible screen for a working
agent. It is shown only as a temporary fallback when no outcome is available, so a card
does not repeat two descriptions of the same work.

**Context** — transcript-derived context-window fill for Claude, pi and Codex. It sits
above the outcome because it describes session pressure, not the work itself.

**Outcome** — up to three short sentences generated from the latest completed reply:
what finished, what comes next, and whether a decision is waiting. A new user prompt
clears the old outcome immediately rather than presenting completed work as current.

Cards also carry Herdr status, agent kind, workspace/worktree label and foreground
directory. A reply becomes unread when it lands after that pane was last focused; blocked
and unread-finished cards enter the **Next** queue. Repeated presses cycle the queue while
preserving the device's chosen card order.

## Context gauge

All three agents write transcripts to disk, in three different shapes. Nothing here
touches an API or a credential.

| Agent | Transcript | Context reading |
|---|---|---|
| claude | `~/.claude/projects/<cwd-slug>/<uuid>.jsonl` | last `message.usage`: `input + cache_read + cache_creation` |
| pi | path handed over by Herdr (`agent_session.kind == "path"`) | last `type:"message"`: `usage.input + usage.cacheRead` |
| codex | `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl` | last `event_msg`/`token_count`: `info.last_token_usage.total_tokens` |

Codex is the only one that states its own window — `info.model_context_window` (258400
here) — so it needs no guessing. Its rollout also carries a full `rate_limits` block
(`used_percent`, `window_minutes`, `resets_at`, `plan_type`), which is a local,
credential-free replacement for part of the codexbar capacity feed. Not wired up yet.

Gotchas found the hard way:

- **Use `last_token_usage`, not `total_token_usage`.** The latter is a lifetime counter
  — 8.8M tokens on a live session — and would read as wildly over 100%.
- **pi's `usage.totalTokens` includes output**, which isn't resident context. Sum the
  input side only.
- **Claude slugifies spaces as well as slashes**: `…/000 Daily Notes` →
  `…-000-Daily-Notes`. Replacing only slashes silently drops those sessions.
- **Claude has no 400k tier.** Transcripts record `claude-opus-5` whether or not the
  session is the 1M variant, so where the window isn't stated the reader escalates
  through real per-family tiers (claude 200k→1M, gpt 400k, gemini 1M) rather than a
  generic ladder — which had invented a 400k Opus window.

Codex rollouts reach 66MB, so every reader seeks to the tail and caches against file
size and mtime.

## Not done yet

- **Provider quota depends on undocumented endpoints.** CodexBar reads OAuth credentials
  and Keychain items, and the Claude and Codex quota endpoints it uses are reverse
  engineered — they can break without notice. The feed carries the last good reading per
  provider (persisted to `~/.cache/agentdeck/capacity.json`) and labels it rather than
  blanking, so a failed probe degrades visibly instead of silently.
- No native app targets yet. When they land, the models and subscription logic move to a
  `HerdrKit` package with two transports (Unix socket on macOS, network on iPadOS) and the
  bridge becomes a thin republisher.
- **No auth.** The bridge binds loopback only, but anything Tailscale Serve publishes is
  reachable by every device on the tailnet. `POST /api/focus`, `/api/workspace` and
  `/api/tab` can all mutate Herdr state. Fine for a single-user tailnet; not fine if that
  ever changes.
- Card arrangement is per-device `localStorage` (`agentdeck.slots`, a paneId → cell map)
  keyed by `paneId`, and pane ids do not survive a Herdr restart — sessions do, panes
  don't. A Herdr restart scrambles a saved layout. Keying on session id would survive it,
  at the cost of losing the arrangement when a session is resumed into a new pane.
- A slot is a position along the grid flow, not a row and column, so a rotate keeps every
  gap but reflows where it falls. Storing a column would hold the shape at one width and
  break at the other — the iPhone landscape layout is a different number of cards across.
- A new pane takes the first cell with no card in it, which is the top-most gap because
  slots run along the flow. A pane that exits holds its cell for a few payloads so a Herdr
  hiccup can't move cards, but the cell reads as empty to a new pane from the moment the
  card goes: skipping it would drop the new card into the gap *below* the visible one.
  The cost is that a pane which blinks out and comes back can find its cell taken and be
  moved on, which needs a hiccup and a new tab inside the same few seconds.
- Filtering to a project packs the cards up instead of showing the other projects' empty
  cells. A drag there trades two cards' slots, which means the same thing in both views,
  but you can only place a card into free space from **All**.
- Outcome text is clamped to three lines in CSS and the model sometimes writes past it,
  so a third sentence can be cut mid-phrase.
