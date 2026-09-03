import Foundation
import Darwin

// MARK: - What the iPad actually receives.
//
// Deliberately flat and pre-formatted: the client should render, not compute.
// Every feed carries its own `ok`/`reason` so a dead source degrades loudly
// instead of showing a stale value that looks live.

/// No timestamp field, deliberately: the payload is compared byte-for-byte to
/// suppress no-op broadcasts, and a clock in it would make every tick a change.
/// The client derives "Xs ago" from when the frame arrived.
struct DeckPayload: Encodable {
    var herdr: FeedStatus
    var workspaces: [DeckWorkspace] // repository groups; name retained for wire compatibility
    var agents: [DeckAgent]
    var capacity: CapacityFeed
    var host: HostFeed
    var localModel: LocalModelSnapshot?
}

struct FeedStatus: Encodable {
    var ok: Bool
    var detail: String?
}

struct DeckWorkspace: Encodable {
    var id: String
    var label: String
    var newTabWorkspaceId: String // concrete Herdr workspace behind this project filter
    var number: Int
    var status: String
    var focused: Bool       // contains the Herdr workspace focused on the desktop
    var agentCount: Int
    var working: Int        // amber pill
    var unseenDone: Int     // green pill — finished cards you haven't looked at yet
    var unread: Int         // badge
}

struct DeckAgent: Encodable {
    var paneId: String
    var kind: String        // claude | codex | pi | …
    var status: String      // working | idle | unknown
    var focused: Bool
    var title: String       // model-written session name, or the Herdr-derived fallback
    var titleSource: String // "model" | "herdr"
    var focus: String?      // where the last five turns have got to
    var state: String?      // finished / next / waiting-on, from the latest reply
    var unread: Bool        // replied since you last had this pane focused
    var repliedAgo: Int?    // seconds since its last completed reply
    var projectId: String   // shared repo key, falling back to the Herdr workspace id
    var project: String     // repository name, falling back to basename of cwd
    var cwd: String
    var workspaceId: String
    var workspaceLabel: String
    var tabLabel: String    // empty when it was promoted into the title instead
    var phase: Phase?           // parsed from the agent's own status line
    /// "1 shell", "2 shells · 1 agent" — work still running, whatever the agent's own
    /// status. Pre-formatted: the client renders this string and counts nothing.
    var background: String?
    var activity: String?       // one clause from the local model
    var context: ContextUse?    // context-window fill; claude, pi and codex all report it
}

struct CapacityFeed: Encodable {
    var ok: Bool
    var reason: String?
    var providers: [CapacityProvider]
}

/// One quota window: a 5-hour rolling limit, a weekly one, and so on.
struct CapacityWindow: Encodable {
    var span: String        // "5h" | "wk"
    var used: Double
    /// Where usage *should* be if it were spent evenly up to the reset. CodexBar
    /// computes this in its `pace` block, so it isn't re-derived here.
    var expected: Double?
    var resets: String?
}

struct CapacityProvider: Encodable {
    var name: String
    var percentUsed: Double?
    var label: String
    var windows: [CapacityWindow]
    /// Set when this reading is carried over from an earlier refresh, or when the
    /// provider failed outright. The panel should never present either as current.
    var note: String?
}

struct HostFeed: Encodable {
    var ok: Bool
    var load1: Double
    var load5: Double
    var cores: Int
    var system: SystemSnapshot?
}

// MARK: - Assembly

enum Deck {
    /// "all" — the local model names every card (AGENTDECK_NAMES=all, the default).
    /// "fallback" — only cards whose Herdr title is generic, i.e. pi and codex.
    static var namingMode = ProcessInfo.processInfo.environment["AGENTDECK_NAMES"] ?? "all"
    static let readTracker = ReadTracker()
    static let sampler = SystemSampler()
    nonisolated(unsafe) static var localModel: LocalModelMonitor?
    /// Last parsed phase per pane. Only touched from the single poll queue.
    nonisolated(unsafe) static var phaseCache: [String: Phase?] = [:]
    /// Last background-work summary per pane, same contract as phaseCache.
    nonisolated(unsafe) static var backgroundCache: [String: String?] = [:]
    /// How often an *idle* pane's screen is read. Background work changes on the scale
    /// of minutes and every read is a subprocess, so this is far slower than the
    /// one-second phase read a working pane gets.
    static let backgroundInterval = Double(
        ProcessInfo.processInfo.environment["AGENTDECK_BACKGROUND_INTERVAL"] ?? "") ?? 5.0

    /// Herdr's `terminal_title_stripped` removes Claude's idle marker (✳) but not the
    /// working spinner, which cycles ◐ ◓ ◑ ◒. Left in, the title mutates on every poll
    /// and every tick counts as a state change. Drop any leading non-alphanumeric run.
    static func cleanTitle(_ raw: String?) -> String {
        var s = Substring(raw ?? "")
        while let c = s.first, !(c.isLetter || c.isNumber) { s = s.dropFirst() }
        let out = s.trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? "—" : out
    }

    /// A title carrying no information beyond what the project chip already shows.
    static func isGeneric(_ title: String, project: String) -> Bool {
        if title == "—" || title.isEmpty { return true }
        if title.caseInsensitiveCompare(project) == .orderedSame { return true }
        // "π - Trinity": glyph, separator, directory name. Note cleanTitle can't strip the
        // π — it's a letter, unlike the spinner glyphs — so match on the trailing segment.
        if let tail = title.split(separator: "-").last?.trimmingCharacters(in: .whitespaces),
           tail.caseInsensitiveCompare(project) == .orderedSame {
            return true
        }
        return false
    }

    static func payload(from snap: HerdrSnapshot,
                        herdrDetail: String?,
                        source: HerdrSource?,
                        summariser: Summariser?) -> DeckPayload {
        let wsById = Dictionary(uniqueKeysWithValues: snap.workspaces.map { ($0.workspaceId, $0) })
        let tabById = Dictionary(uniqueKeysWithValues: snap.tabs.map { ($0.tabId, $0) })

        let agents: [DeckAgent] = snap.agents.map { a in
            let ws = wsById[a.workspaceId]
            let tab = tabById[a.tabId]
            let cwdName = URL(fileURLWithPath: a.cwd).lastPathComponent
            // A parent checkout and all linked worktrees share repoKey. Keep Herdr's
            // workspace identity on the card, but use repository identity for the
            // top-level AgentDeck filter so worktree sessions stay under one project.
            let projectId = ws?.worktree?.repoKey ?? a.workspaceId
            let projectName = ws?.worktree?.repoName ?? cwdName

            // Only Claude writes a task summary into its terminal title. pi reports
            // "π - <dir>" and codex reports the bare directory, so two pi sessions in the
            // same vault render identically. Fall back to the tab label, which is the
            // only human-authored name those panes carry.
            var title = cleanTitle(a.terminalTitleStripped)
            var tabLabel = tab?.label ?? ""
            let titleWasGeneric = isGeneric(title, project: cwdName)
            var promotedTab = false
            if titleWasGeneric, !tabLabel.isEmpty {
                title = tabLabel
                promotedTab = true
            }

            // A working agent's screen is read every tick, because the phase timer
            // wants a second of resolution and each read is a subprocess we don't want
            // to pay for eight times a second.
            //
            // Idle panes used to be skipped entirely, on the reasoning that they have
            // nothing new to say. They do: an agent that starts a background shell or a
            // background agent hands the prompt straight back and goes idle while the
            // work carries on, so the one card with six research runs in flight was the
            // one card showing nothing at all. Those panes are read too, just rarely.
            // Claude and Codex only. pi3 was run through the same states and shows
            // nothing persistent for background work, so reading it while idle would
            // buy a subprocess per pane per tick and never return anything.
            var phase: Phase?
            var background: String?
            if a.agentStatus == "working" {
                if let screen = source?.visibleScreenThrottled(pane: a.paneId) {
                    phase = StatusLine.parse(screen)
                    background = BackgroundLine.summary(BackgroundLine.parse(screen))
                    Deck.phaseCache[a.paneId] = phase
                    Deck.backgroundCache[a.paneId] = background
                    summariser?.consider(pane: a.paneId, screen: screen)
                } else {
                    // Throttled tick: hold the last reading rather than blanking the
                    // line, which would flicker it on and off between reads.
                    phase = Deck.phaseCache[a.paneId] ?? nil
                    background = Deck.backgroundCache[a.paneId] ?? nil
                }
            } else {
                Deck.phaseCache[a.paneId] = nil
                if a.agent == "claude" || a.agent == "codex",
                   let screen = source?.visibleScreenThrottled(
                       pane: a.paneId,
                       minInterval: Deck.backgroundInterval,
                       lines: 16) {
                    background = BackgroundLine.summary(BackgroundLine.parse(screen))
                    Deck.backgroundCache[a.paneId] = background
                } else {
                    background = Deck.backgroundCache[a.paneId] ?? nil
                }
            }

            // Card names come from the transcript, for working and idle agents alike,
            // and regenerate only when the file has actually been written to.
            let transcript = ContextReader.path(agent: a.agent, session: a.agentSession, cwd: a.cwd)
            let wantsName = Deck.namingMode == "all" || titleWasGeneric
            var digest: TranscriptDigest?
            if let transcript {
                digest = Transcript.digest(agent: a.agent, path: transcript)
            }
            if wantsName, let summariser, let digest {
                summariser.setLogContext(pane: a.paneId, session: transcript, agent: a.agent)
                summariser.considerNames(pane: a.paneId, digest: digest)
            }
            let read = Deck.readTracker.update(pane: a.paneId,
                                               focused: a.focused,
                                               replyKey: digest?.lastReplyKey,
                                               writtenAt: digest?.stamp)
            let modelName = wantsName ? summariser?.name(for: a.paneId) : nil
            // A promoted tab label leaves the workspace:tab address only while it is
            // actually on show as the title. In the default naming mode the model names
            // every card, which puts the promoted label straight back out of sight — so
            // blanking it there would drop the tab from the address for no visible
            // reason, and two panes of one workspace would be addressed inconsistently.
            if promotedTab, modelName == nil { tabLabel = "" }
            // When AgentDeck has written its card title into Herdr, the address would
            // otherwise repeat the same words directly above itself.
            if let modelName, tabLabel == modelName { tabLabel = "" }
            // The subtitle is always useful, even where Herdr's own title is kept.
            let focus = transcript != nil ? summariser?.subtitle(for: a.paneId) : nil
            let state = transcript != nil ? summariser?.state(for: a.paneId) : nil

            return DeckAgent(
                paneId: a.paneId,
                kind: a.agent,
                status: a.agentStatus,
                focused: a.focused,
                // In "all" mode the model names every card. In "fallback" mode it only
                // names cards Herdr couldn't — i.e. pi and codex, whose terminal titles
                // are just a directory. Claude writes its own curated session title, and
                // a 3b model summarising the same transcript tends to do worse.
                title: modelName ?? title,
                titleSource: modelName != nil ? "model" : "herdr",
                focus: focus,
                state: state,
                unread: read.unread,
                // Quantised to 30s. As a raw second count this ticked every poll, so
                // every payload differed, every tick broadcast, and the client rebuilt
                // the whole grid once a second — which is what made the UI feel laggy.
                // Third time this exact bug has appeared: generatedAt, load1, now this.
                repliedAgo: read.repliedSecondsAgo.map { ($0 / 30) * 30 },
                projectId: projectId,
                project: projectName,
                cwd: a.cwd,
                workspaceId: a.workspaceId,
                workspaceLabel: ws?.label ?? a.workspaceId,
                tabLabel: tabLabel,
                phase: phase,
                background: background,
                activity: summariser?.label(for: a.paneId),
                context: ContextReader.read(agent: a.agent,
                                            session: a.agentSession,
                                            cwd: a.cwd)
            )
        }

        summariser?.retain(panes: Set(agents.map(\.paneId)))
        Deck.readTracker.retain(panes: Set(agents.map(\.paneId)))
        // The screen caches are pane-keyed too, and a pane dies with its tab. Left
        // alone they accumulate for the life of the process.
        let live = Set(agents.map(\.paneId))
        Deck.phaseCache = Deck.phaseCache.filter { live.contains($0.key) }
        Deck.backgroundCache = Deck.backgroundCache.filter { live.contains($0.key) }

        // No sorting, deliberately. Any server-side ordering rule moves a card exactly
        // when you're looking at it — on focus, on starting work. Herdr's own order is
        // passed through untouched and the client owns arrangement from here, so a card
        // only ever moves because you dragged it.
        let ordered = agents

        // Herdr worktrees are separate workspaces for terminal isolation, but the deck's
        // top level is a project switcher. Collapse workspaces that share repoKey while
        // retaining each original workspace label on its agent cards.
        let grouped = Dictionary(grouping: agents, by: \.projectId)
        let sortedWorkspaces = snap.workspaces.sorted { ($0.number ?? 0) < ($1.number ?? 0) }
        var projectOrder: [String] = []
        var projectMembers: [String: [HerdrWorkspace]] = [:]
        var projectLabels: [String: String] = [:]
        for workspace in sortedWorkspaces {
            let id = workspace.worktree?.repoKey ?? workspace.workspaceId
            if projectMembers[id] == nil { projectOrder.append(id) }
            projectMembers[id, default: []].append(workspace)
            if projectLabels[id] == nil {
                projectLabels[id] = workspace.worktree?.repoName
                    ?? workspace.label
                    ?? workspace.workspaceId
            }
        }

        let workspaces: [DeckWorkspace] = projectOrder.enumerated().map { offset, id in
            let members = projectMembers[id] ?? []
            let mine = grouped[id] ?? []
            // Project filters may group a parent checkout with several worktrees. Use
            // the focused member when it belongs to this project; otherwise fall back
            // to the first member in Herdr's stable workspace order.
            let newTabWorkspace = members.first {
                $0.workspaceId == snap.focusedWorkspaceId
            } ?? members.first {
                $0.focused ?? false
            } ?? members.first
            let status = mine.contains { $0.status == "working" }
                ? "working"
                : (members.first?.agentStatus ?? "unknown")
            return DeckWorkspace(
                id: id,
                label: projectLabels[id] ?? id,
                newTabWorkspaceId: newTabWorkspace?.workspaceId ?? id,
                number: members.compactMap(\.number).min() ?? (offset + 1),
                status: status,
                focused: members.contains { $0.focused ?? false },
                agentCount: mine.count,
                working: mine.filter { $0.status == "working" }.count,
                // A pill is green for exactly the reason a card is: it holds finished
                // work you haven't looked at. Counting "replied recently" instead kept
                // the pill green for the rest of the window after you had read the only
                // card behind it — the pill beckoned towards an empty errand.
                unseenDone: mine.filter {
                    $0.unread && $0.status != "working"
                }.count,
                unread: mine.filter(\.unread).count
            )
        }

        return DeckPayload(
            herdr: FeedStatus(ok: true, detail: herdrDetail),
            workspaces: workspaces,
            // Fixed positions, ordered the way the panes are laid out in Herdr.
            // Sorting by status or focus meant a card jumped across the grid the moment
            // you selected it or it started working — the two times you are looking
            // straight at it. Position is now stable and selection is shown, not moved.
            agents: ordered,
            capacity: Capacity.read(),
            host: HostFeed.read(),
            localModel: localModel?.read()
        )
    }

    static func failed(_ reason: String) -> DeckPayload {
        DeckPayload(
            herdr: FeedStatus(ok: false, detail: reason),
            workspaces: [], agents: [],
            capacity: Capacity.read(),
            host: HostFeed.read(),
            localModel: localModel?.read()
        )
    }
}

extension HostFeed {
    static func read() -> HostFeed {
        var avg = [Double](repeating: 0, count: 3)
        let n = getloadavg(&avg, 3)
        // Rounded, not raw: an unrounded load average drifts on every sample and would
        // make the payload differ every tick, defeating change-detection entirely.
        func r(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        return HostFeed(
            ok: n == 3,
            load1: r(avg[0]),
            load5: r(avg[1]),
            cores: ProcessInfo.processInfo.activeProcessorCount,
            system: Deck.sampler.read()
        )
    }
}

enum Capacity {
    /// Optional feed, and installed here (`brew install --cask codexbar`). Where it is
    /// absent this reports unavailable rather than inventing numbers — see README for the
    /// caveat about the undocumented endpoints it reads.
    private static let lock = NSLock()
    private static var cached = CapacityFeed(ok: false, reason: "reading…", providers: [])
    /// Last successful reading per provider, so one bad probe doesn't empty the bar.
    /// Persisted, because in memory alone it was lost on every restart — which is
    /// exactly when a flaky provider looks permanently missing rather than merely stale.
    nonisolated(unsafe) private static var lastGood: [String: CapacityProvider] = loadLastGood()

    private static var cachePath: String {
        "\(NSHomeDirectory())/.cache/agentdeck/capacity.json"
    }

    private static func loadLastGood() -> [String: CapacityProvider] {
        guard let data = FileManager.default.contents(atPath: cachePath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var out: [String: CapacityProvider] = [:]
        for (name, raw) in obj {
            guard let d = raw as? [String: Any] else { continue }
            let windows = (d["windows"] as? [[String: Any]] ?? []).compactMap {
                w -> CapacityWindow? in
                guard let span = w["span"] as? String, let used = w["used"] as? Double
                else { return nil }
                return CapacityWindow(span: span, used: used,
                                      expected: w["expected"] as? Double,
                                      resets: w["resets"] as? String)
            }
            out[name] = CapacityProvider(name: name,
                                         percentUsed: d["percentUsed"] as? Double,
                                         label: d["label"] as? String ?? "",
                                         windows: windows, note: nil)
        }
        return out
    }

    private static func saveLastGood() {
        var obj: [String: Any] = [:]
        for (name, p) in lastGood {
            obj[name] = [
                "percentUsed": p.percentUsed as Any,
                "label": p.label,
                "windows": p.windows.map { w -> [String: Any] in
                    var d: [String: Any] = ["span": w.span, "used": w.used]
                    if let e = w.expected { d["expected"] = e }
                    if let r = w.resets { d["resets"] = r }
                    return d
                },
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? FileManager.default.createDirectory(
            atPath: (cachePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: cachePath))
    }

    /// Free — hands back whatever the last background refresh produced. This used to
    /// shell out inline on every tick, which was survivable at one poll a second and
    /// is not now that ticks are event-driven: `codexbar usage` talks to claude.ai and
    /// the OpenAI dashboard and takes seconds.
    static func read() -> CapacityFeed {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    static func refresh() {
        guard let bin = Shell.which("codexbar") else {
            store(CapacityFeed(ok: false, reason: "codexbar not installed", providers: []))
            return
        }
        do {
            // ~47s: it scrapes the provider dashboards. Fine on a 5-minute timer, and
            // exit 1 with valid JSON on stdout is its normal success path.
            let data = try Shell.run(bin, ["usage", "--provider", "both", "--json"],
                                     timeout: 120, allowFailure: true)
            // stdout is prefixed with lines like "[codex notify] remoteControl/status/changed",
            // so the JSON does not start at byte zero.
            guard let start = data.firstIndex(of: UInt8(ascii: "[")),
                  let arr = try JSONSerialization.jsonObject(with: Data(data[start...]))
                    as? [[String: Any]]
            else {
                store(CapacityFeed(ok: false, reason: "unexpected codexbar output", providers: []))
                return
            }

            var out: [CapacityProvider] = []
            for entry in arr {
                let name = entry["provider"] as? String ?? "?"

                // Providers fail independently and intermittently — Claude's probe times
                // out fairly often. Carry the last good reading rather than blanking the
                // meter, but say that it's carried.
                if let err = entry["error"] as? [String: Any] {
                    let msg = (err["message"] as? String) ?? "unavailable"
                    if var prev = lastGood[name] {
                        prev.note = "last good — \(msg)"
                        out.append(prev)
                    } else {
                        out.append(CapacityProvider(name: name, percentUsed: nil,
                                                    label: "", windows: [], note: msg))
                    }
                    continue
                }

                guard let usage = entry["usage"] as? [String: Any] else { continue }
                let pace = entry["pace"] as? [String: Any]

                // primary is the short rolling window (300 min on Claude), secondary the
                // weekly one (10080). Either may be null depending on the provider.
                var parts: [String] = []
                var windows: [CapacityWindow] = []
                var headline: Double?
                for key in ["primary", "secondary"] {
                    guard let w = usage[key] as? [String: Any],
                          let pct = w["usedPercent"] as? Double else { continue }
                    let mins = w["windowMinutes"] as? Int ?? 0
                    let span = mins >= 10080 ? "wk" : (mins >= 60 ? "\(mins / 60)h" : "\(mins)m")
                    let expected = (pace?[key] as? [String: Any])?["expectedUsedPercent"] as? Double
                    windows.append(CapacityWindow(span: span, used: pct, expected: expected,
                                                  resets: w["resetDescription"] as? String))
                    parts.append(String(format: "%@ %.0f%%", span, pct))
                    if headline == nil { headline = pct }
                }
                guard !windows.isEmpty else { continue }
                let p = CapacityProvider(name: name, percentUsed: headline,
                                         label: parts.joined(separator: " "),
                                         windows: windows, note: nil)
                lastGood[name] = p
                saveLastGood()
                out.append(p)
            }
            store(out.isEmpty
                  ? CapacityFeed(ok: false, reason: "no quota windows reported", providers: [])
                  : CapacityFeed(ok: true, reason: nil, providers: out))
        } catch {
            store(CapacityFeed(ok: false, reason: "codexbar failed", providers: []))
        }
    }

    private static func store(_ f: CapacityFeed) {
        lock.lock(); cached = f; lock.unlock()
    }
}
