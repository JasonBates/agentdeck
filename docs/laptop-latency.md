# Laptop workspace latency

Measured 21 October 2026 against a foreground preview, with the normal model enabled.

## Cause and fix

Workspace commands used the same serial queue as full laptop snapshots. A command
could wait behind multiple SSH reads before it even started. Commands now validate
cached state under a short lock and run independently of snapshot I/O. Incoming
events are coalesced before entering the read queue, so an event burst can schedule
at most one read behind the currently running read. Revision checks discard snapshots
that overlap a later command or focus event. Confirmed focus events still go directly
to the browser independently of the full snapshot.

## Measurements

Each run sent 24 sequential HTTP requests for the already focused laptop workspace,
with 80 ms between responses and the next request. This exercises the command and
post-command snapshot paths without repeatedly changing the visible workspace.
The HTTP client ran on the bridge host; these figures exclude browser rendering and
the browser-to-bridge network leg.

| Metric | Before | After |
| --- | ---: | ---: |
| Median request acknowledgement | 538.5 ms | 349.85 ms |
| Maximum request acknowledgement | 971.0 ms | 380.2 ms |
| Maximum measured wait behind snapshots | 626.7 ms | <0.1 ms |

A separate switch to a different workspace delivered its confirmed focus event over
the live HTTP stream in 247 ms after the request started; the original workspace was
restored. These bounded samples demonstrate removal of the read-queue delay, not a
guarantee against delays elsewhere in SSH, AeroSpace, Wi-Fi or the browser.

## Profiling

Set `AGENTDECK_AEROSPACE_PROFILE=1` when starting the foreground preview. The bridge
writes `aero-profile snapshot`, `aero-profile action-queue`, and `aero-profile command`
timings to stderr. Profiling is off by default. `action-queue` measures admission to
RemoteAeroSpace, not time queued behind other HTTP actions.

Regression tests deliberately block a snapshot and verify that a command still runs,
and send 100 refresh events during a blocked snapshot to verify one trailing read.
