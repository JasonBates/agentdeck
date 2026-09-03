# Security policy

## Reporting a vulnerability

Use [private vulnerability reporting](https://github.com/JasonBates/agentdeck/security)
on this repository. If that form is unavailable, open a minimal public issue saying only
that a private channel is needed; do not post exploit details, tokens, transcripts, or
local paths publicly.

Include the commit, macOS and Herdr versions, concise reproduction conditions, impact, and
any safe mitigation. Redact transcript or screen text, generated headings, pane and
workspace IDs, hostnames, and local paths.

## Supported versions

There are no tagged releases yet. The current `main` is the only supported revision.

## Security boundaries

- The bridge binds `127.0.0.1` only and answers `/api/*` and `/events` solely for the
  loopback address, `AGENTDECK_PUBLIC_HOST`, and `AGENTDECK_ALLOWED_ORIGINS`. Other
  hosts and origins receive `403 origin_rejected`. Responses carry no CORS headers.
- Anything Tailscale Serve publishes is reachable by every device in the tailnet, with no
  further authentication. The focus, workspace, and tab routes mutate Herdr state. The
  deck is designed for a single-user tailnet and must not be exposed with Funnel.
- The bridge reads local agent transcripts and sends bounded excerpts to Ollama on
  loopback only. It writes a heading log under `~/.local/state/agentdeck/`.
- The optional quota feature shells out to CodexBar, which reads browser cookies under
  Full Disk Access and calls undocumented provider endpoints. It is off until CodexBar is
  installed and FDA granted.
- Installed binaries are signed with a Developer ID when one is present and ad hoc
  otherwise; nothing is notarized or distributed as a prebuilt artifact.

## Disclosure

Please allow time to reproduce and fix before publishing details. Reports are
acknowledged after triage.
