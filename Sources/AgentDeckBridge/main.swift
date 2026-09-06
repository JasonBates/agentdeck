import Foundation

// agentdeck-bridge — polls Herdr, serves the deck to any browser on the Tailnet.
//
//   swift run AgentDeckBridge [--port 9798] [--interval 1.0]
//   AGENTDECK_PORT / AGENTDECK_INTERVAL work too.
//
// 9798, not 9797 — see the port note below.

// Unbuffered: stdout is fully buffered when it isn't a terminal, which swallows the
// startup banner and any diagnostics under launchd or a redirect.
setvbuf(stdout, nil, _IONBF, 0)

let args = CommandLine.arguments
let env = ProcessInfo.processInfo.environment

/// Precedence: command-line flag → environment variable → default.
func flag(_ name: String, env envKey: String, _ fallback: String) -> String {
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return env[envKey] ?? fallback
}

// Internal port 9798, public port 9797. They must differ: Tailscale Serve binds
// <tailnet-ip>:9797 itself, and a bridge trying to take 9797 too fails with
// EADDRINUSE — invisibly, since lsof does not attribute tailscaled's listeners
// (netstat -an does). Serve proxies 9797 → 127.0.0.1:9798, so the URL is unchanged.
let port = UInt16(flag("--port", env: "AGENTDECK_PORT", "9798")) ?? 9798
// Safety net only. Herdr pushes the events that matter, so this exists to catch
// anything not covered by a subscription and to keep the deck alive if the event
// socket is down — it is no longer the path a focus change travels on.
let interval = Double(flag("--interval", env: "AGENTDECK_INTERVAL", "1.0")) ?? 1.0

let encoder = JSONEncoder()
encoder.outputFormatting = [.withoutEscapingSlashes]

var latest: Data = Data("{}".utf8)
/// Ids the last snapshot contained, so an action can be refused before it reaches
/// `herdr` — see HTTPServer.isKnown.
var knownPanes = Set<String>()
var knownWorkspaces = Set<String>()
let stateLock = NSLock()

func currentJSON() -> Data {
    stateLock.lock(); defer { stateLock.unlock() }
    return latest
}

// Local model for titles, subtitles and outcomes. Set AGENTDECK_MODEL=off to disable
// the LLM pass entirely.
//
// gemma4:12b, one model for all three jobs. The previous default was qwen3:4b-instruct
// (the non-thinking 2507 build — not plain qwen3:4b, whose hybrid thinking mode echoes
// the instruction back), which had itself beaten llama3.2:3b and gemma3:4b on six real
// transcripts. Gemma 4 then beat qwen on the same ten real mid-conversation snapshots,
// 5 repeats each:
//
//   title     ~8/10 vs ~6/10 against hand-written references
//   subtitle   0.0% constraint violations vs 20.0%
//   outcome    0.0% vs 10.0%
//
// It is ~2.5x slower (outcome median 1.61s vs 0.66s), which costs nothing: these are
// background jobs, and focus/status still arrive by push event in ~25ms. Running one
// model rather than two also drops resident memory from 11.2GB to 8.05GB.
//
// Gemma 4 is a thinking model by default — see Summariser.call, which uses /api/chat
// with think:false. On the raw endpoint it spends the whole budget reasoning and
// returns empty content.
let modelName = flag("--model", env: "AGENTDECK_MODEL", "gemma4:12b")
let titleModelName = flag("--title-model", env: "AGENTDECK_TITLE_MODEL", modelName)
let publicHost = env["AGENTDECK_PUBLIC_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines)
// Further `scheme://host[:port]` origins the bridge answers for, comma-separated. The
// installer adds the Tailscale Serve port form here; AGENTDECK_PUBLIC_HOST alone covers
// the path form on 443. See OriginPolicy.
let allowedOrigins = (env["AGENTDECK_ALLOWED_ORIGINS"] ?? "")
    .split(separator: ",").map { String($0) }

let modelMonitor: LocalModelMonitor? = modelName == "off"
    ? nil
    : LocalModelMonitor(model: modelName)
Deck.localModel = modelMonitor

let summariser: Summariser? = modelName == "off"
    ? nil
    : Summariser(model: modelName, titleModel: titleModelName,
                 modelMonitor: modelMonitor)

let server = HTTPServer(port: port)
server.snapshotJSON = { currentJSON() }
server.isKnown = { kind, id in
    stateLock.lock(); defer { stateLock.unlock() }
    return kind == "pane" ? knownPanes.contains(id) : knownWorkspaces.contains(id)
}
server.policy = OriginPolicy(port: port, publicHost: publicHost, allowedOrigins: allowedOrigins)

var source: HerdrSource?
do {
    source = try HerdrSource()
} catch {
    FileHandle.standardError.write(Data("warning: \(error)\n".utf8))
}

// Model titles become Herdr tab labels by default. Ownership is conservative: only
// unnamed, single-agent tabs are claimed, and a manual rename releases them. `off` is
// useful for a read-only bridge or when Herdr's labels should remain entirely manual.
let tabTitleSync: TabTitleSync? = {
    guard env["AGENTDECK_TAB_TITLES"]?.lowercased() != "off", let src = source else {
        return nil
    }
    return TabTitleSync { tab, title in try src.rename(tab: tab, title: title) }
}()

server.onFocus = { pane in
    guard let src = source else { return false }
    do { try src.focus(pane: pane); return true }
    catch {
        FileHandle.standardError.write(Data("focus failed: \(error)\n".utf8))
        return false
    }
}

server.onWorkspace = { ws in
    guard let src = source else { return false }
    do { try src.focus(workspace: ws); return true }
    catch {
        FileHandle.standardError.write(Data("workspace focus failed: \(error)\n".utf8))
        return false
    }
}

server.onCreateTab = { ws in
    guard let src = source else { return false }
    do { try src.createTab(workspace: ws); return true }
    catch {
        FileHandle.standardError.write(Data("tab creation failed: \(error)\n".utf8))
        return false
    }
}

// Banner prints from the listener's ready state, never before it — see HTTPServer.
server.onReady = {
    print("agentdeck-bridge listening on 127.0.0.1:\(port)")
    print("  local   → http://127.0.0.1:\(port)")
    if let publicHost, !publicHost.isEmpty {
        print("  tailnet → https://\(publicHost)/deck")
        print("            https://\(publicHost):9797/")
    }
    print("  answers for \(server.policy.authorities.sorted().joined(separator: ", "))")
    print("polling herdr every \(interval)s — ctrl-C to stop")
}

do {
    try server.start()
} catch {
    FileHandle.standardError.write(Data((
        "fatal: could not bind port \(port): \(error)\n" +
        "       something else is listening — try --port <n> or AGENTDECK_PORT=<n>\n"
    ).utf8))
    exit(1)
}

// Poll loop. Subprocess-per-tick is fine at 1s and completely robust. It is no longer
// the path a change travels on — the socket subscription below is — so this is the floor
// that catches anything no subscription covers.
var tickCount = 0
var tickTotalMs = 0.0
// Declared ahead of the tick so the payload can carry the socket's health; assigned
// once the tick exists, since the subscription's callback is what triggers one.
var events: HerdrEvents?
let poller = DispatchQueue(label: "agentdeck.poll")
let timer = DispatchSource.makeTimerSource(queue: poller)
timer.schedule(deadline: .now(), repeating: interval)
func runTick() {
    let tickStart = DispatchTime.now()
    let payload: DeckPayload
    var panes = Set<String>(), workspaces = Set<String>()
    let eventStatus = events?.status ?? FeedStatus(ok: false, detail: "not started")
    if let src = source {
        do {
            let snap = try src.snapshot()
            payload = Deck.payload(from: snap, herdrDetail: "herdr \(snap.version)",
                                   source: src, summariser: summariser, events: eventStatus)
            tabTitleSync?.reconcile(snapshot: snap, deckAgents: payload.agents)
            panes = Set(snap.agents.map(\.paneId))
            workspaces = Set(snap.workspaces.map(\.workspaceId))
        } catch {
            payload = Deck.failed("\(error)", events: eventStatus)
        }
    } else {
        payload = Deck.failed("herdr not found on PATH", events: eventStatus)
    }

    guard let data = try? encoder.encode(payload) else { return }
    stateLock.lock()
    latest = data
    knownPanes = panes
    knownWorkspaces = workspaces
    stateLock.unlock()
    server.broadcast(data)

    // A tick that overruns its interval is the whole latency budget: focus changes
    // can't reach the screen faster than one full poll.
    let ms = Double(DispatchTime.now().uptimeNanoseconds - tickStart.uptimeNanoseconds) / 1e6
    tickCount += 1
    tickTotalMs += ms
    if ms > interval * 1000 { Summariser.debug(String(format: "slow tick: %.0fms", ms)) }
    if tickCount % 50 == 0 {
        Summariser.debug(String(format: "tick avg %.1fms over %d polls",
                                tickTotalMs / Double(tickCount), tickCount))
    }
}

timer.setEventHandler { runTick() }
timer.resume()

// Push events remove the poll interval from the latency path: a focus change on the
// desktop triggers a tick immediately instead of waiting for the next one.
// Bursts are coalesced — one action emits pane_focused + workspace_focused +
// tab_focused + pane_updated together, and they should cost a single tick.
var tickPending = false
events = HerdrEvents {
    poller.async {
        guard !tickPending else { return }
        tickPending = true
        poller.asyncAfter(deadline: .now() + 0.03) {
            tickPending = false
            runTick()
        }
    }
}
events?.start()

// Machine stats on their own 5s timer: CPU percentages only exist as a delta between
// two samples, so this needs a steady cadence independent of when ticks happen.
let statsQueue = DispatchQueue(label: "agentdeck.stats")
let statsTimer = DispatchSource.makeTimerSource(queue: statsQueue)
statsTimer.schedule(deadline: .now(), repeating: 5)
statsTimer.setEventHandler { Deck.sampler.sample() }
statsTimer.resume()

// Ollama residency is a cheap local HTTP read, but still does not belong in the Herdr
// tick. The monitor also receives individual call timings directly from Summariser.
let modelQueue = DispatchQueue(label: "agentdeck.modelstats")
let modelTimer = DispatchSource.makeTimerSource(queue: modelQueue)
modelTimer.schedule(deadline: .now(), repeating: 5)
modelTimer.setEventHandler { modelMonitor?.sample() }
modelTimer.resume()

// Quota is a slow network read, so it lives on its own 5-minute timer well away from
// the tick path. Provider windows move on the order of minutes, not milliseconds.
let capacityQueue = DispatchQueue(label: "agentdeck.capacity")
let capacityTimer = DispatchSource.makeTimerSource(queue: capacityQueue)
capacityTimer.schedule(deadline: .now() + 1, repeating: 300)
capacityTimer.setEventHandler { Capacity.refresh() }
capacityTimer.resume()

// Liveness floor: resend state every 5s even when nothing changed, so the client's
// "Xs ago" reflects bridge health rather than agent activity. Client goes stale at 12s.
let beat = DispatchSource.makeTimerSource(queue: poller)
beat.schedule(deadline: .now() + 5, repeating: 5)
beat.setEventHandler { server.republish() }
beat.resume()

dispatchMain()
