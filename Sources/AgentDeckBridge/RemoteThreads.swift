import CryptoKit
import Foundation

// MARK: - Phone threads behind `claude remote-control`
//
// `claude remote-control` runs as a long-lived server in a Herdr pane, and every thread
// started from the Claude app or claude.ai/code is a child process of that server:
//
//   claude --print --sdk-url https://api.anthropic.com/v1/code/sessions/cse_… --session-id cse_… …
//
// Herdr sees one agent per pane, so all it shows is the server, which says nothing about
// the work. With AGENTDECK_REMOTE_WORKSPACE set to the label of the Herdr workspace that
// holds those servers, the server cards are dropped and each live thread becomes a card in
// that workspace instead. Tapping one opens the thread in the Claude desktop app, or on
// claude.ai/code in the desktop's browser if the app isn't there, since there is no pane
// to focus.
//
// A thread writes an ordinary Claude transcript whose session id is a UUIDv5 of its
// --sdk-url under a fixed namespace. That is undocumented Claude Code behaviour (found in
// 2.1.309, October 2026), so a thread whose transcript can't be found is left off the deck
// rather than guessed at. Threads with an empty transcript are left off too: each server
// pre-creates one on start, and until something is said there it is just noise.

struct RemoteThread {
    let sessionId: String   // cse_…
    let transcriptId: String
    let cwd: String

    static let panePrefix = "rc:"
    var paneId: String { Self.panePrefix + sessionId }

    /// claude.ai's address for the thread: the same id with a `session_` tag.
    var url: URL? {
        URL(string: "https://claude.ai/code/session_" + sessionId.dropFirst("cse_".count))
    }

    /// The Claude desktop app's link for the thread. Its `claude://code/<id>` handler takes
    /// a `session_` or `cse_` id and opens the thread in the app (found in the app's
    /// claudeURLHandler, October 2026). `open` fails when nothing handles `claude://`,
    /// which is the cue to fall back to `url`.
    var appURL: URL? {
        URL(string: "claude://code/session_" + sessionId.dropFirst("cse_".count))
    }

    private static let namespace = UUID(uuidString: "3ab19d7e-9f35-45c2-926e-75e271cc60b3")!

    static func transcriptId(sdkURL: String) -> String {
        var bytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        bytes += Array(sdkURL.utf8)
        var h = Array(Insecure.SHA1.hash(data: bytes).prefix(16))
        h[6] = (h[6] & 0x0f) | 0x50
        h[8] = (h[8] & 0x3f) | 0x80
        let u = UUID(uuid: (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7],
                            h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]))
        return u.uuidString.lowercased()
    }

    /// Threads in `ps -axo pid=,ppid=,command=` output whose parent is a remote-control
    /// server. Interactive sessions with Remote Control enabled have their own panes and
    /// cards already; they are not children of a server, so they are not matched here.
    static func parse(ps: String) -> [(pid: Int32, sessionId: String, sdkURL: String)] {
        var commands: [Int32: Substring] = [:]
        var rows: [(pid: Int32, ppid: Int32, command: Substring)] = []
        for line in ps.split(separator: "\n") {
            // ps right-aligns the numeric columns, so runs of spaces separate them.
            var rest = line.drop { $0 == " " }
            guard let a = rest.firstIndex(of: " "), let pid = Int32(rest[..<a]) else { continue }
            rest = rest[a...].drop { $0 == " " }
            guard let b = rest.firstIndex(of: " "), let ppid = Int32(rest[..<b]) else { continue }
            let command = rest[b...].drop { $0 == " " }
            commands[pid] = command
            rows.append((pid, ppid, command))
        }
        func isServer(_ command: Substring) -> Bool {
            let sub = command.split(separator: " ").dropFirst().first
            return sub == "remote-control" || sub == "rc"
        }
        return rows.compactMap { row in
            guard let parent = commands[row.ppid], isServer(parent),
                  let flag = row.command.range(of: "--sdk-url ") else { return nil }
            let sdkURL = row.command[flag.upperBound...].prefix { $0 != " " }
            guard let tag = sdkURL.range(of: "/sessions/cse_") else { return nil }
            let sessionId = "cse_" + sdkURL[tag.upperBound...]
            return (row.pid, String(sessionId), String(sdkURL))
        }
    }

    /// "working" until the newest turn is an assistant message that ended its turn.
    static func status(transcript path: String, size: Int, mtime: Date) -> String {
        for obj in JSONL.tailObjects(path, size: size, mtime: mtime, window: 256 * 1024) {
            guard let type = obj["type"] as? String, type == "user" || type == "assistant" else {
                continue
            }
            let stop = (obj["message"] as? [String: Any])?["stop_reason"] as? String
            return type == "assistant" && stop == "end_turn" ? "idle" : "working"
        }
        return "idle"
    }
}

final class RemoteThreads {
    private let lock = NSLock()
    private var threads: [RemoteThread] = []
    private var scannedAt = Date.distantPast
    private var cwds: [Int32: String] = [:]
    private var opened: Set<String> = []
    private let interval: TimeInterval = 5

    /// Live threads with something in their transcript, rescanning `ps` at most every
    /// few seconds: thread processes come and go on human timescales.
    func current() -> [RemoteThread] {
        lock.lock(); defer { lock.unlock() }
        guard Date().timeIntervalSince(scannedAt) >= interval else { return threads }
        scannedAt = Date()
        guard let data = try? Shell.run("/bin/ps", ["-axo", "pid=,ppid=,command="]),
              let ps = String(data: data, encoding: .utf8) else { return threads }
        let found = RemoteThread.parse(ps: ps)
        cwds = cwds.filter { pid, _ in found.contains { $0.pid == pid } }
        threads = found.compactMap { t in
            guard let cwd = cwds[t.pid] ?? Self.cwd(of: t.pid) else { return nil }
            cwds[t.pid] = cwd
            return RemoteThread(sessionId: t.sessionId,
                                transcriptId: RemoteThread.transcriptId(sdkURL: t.sdkURL),
                                cwd: cwd)
        }
        return threads
    }

    /// Tapping a card opens the thread in a browser; count that as looking at it.
    func markOpened(pane: String) {
        lock.lock(); opened.insert(pane); lock.unlock()
    }

    func takeOpened(pane: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return opened.remove(pane) != nil
    }

    private static func cwd(of pid: Int32) -> String? {
        guard let data = try? Shell.run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]),
              let out = String(data: data, encoding: .utf8) else { return nil }
        return out.split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }
}

extension HerdrSnapshot {
    /// The snapshot with the agents of the workspace labelled `label` (the remote-control
    /// servers) replaced by one agent per thread. Done before the payload is built, so the
    /// threads get titles, subtitles, read state and pill counts like any other card.
    func replacingRemoteServers(workspaceLabel label: String?, threads: [RemoteThread],
                                opened: (String) -> Bool) -> HerdrSnapshot {
        guard let label, let ws = workspaces.first(where: { $0.label == label }) else {
            return self
        }
        let threadAgents: [HerdrAgent] = threads.compactMap { t in
            let session = HerdrAgentSession(kind: "id", value: t.transcriptId)
            guard let path = ContextReader.path(agent: "claude", session: session, cwd: t.cwd),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.intValue, size > 0,
                  let mtime = attrs[.modificationDate] as? Date else { return nil }
            return HerdrAgent(
                agent: "claude",
                agentSession: session,
                agentStatus: RemoteThread.status(transcript: path, size: size, mtime: mtime),
                cwd: t.cwd,
                focused: opened(t.paneId),
                paneId: t.paneId,
                tabId: t.paneId,
                workspaceId: ws.workspaceId,
                terminalTitleStripped: nil,
                stateChangeSeq: nil,
                revision: nil
            )
        }
        return HerdrSnapshot(
            version: version,
            agents: agents.filter { $0.workspaceId != ws.workspaceId } + threadAgents,
            workspaces: workspaces,
            tabs: tabs,
            focusedPaneId: focusedPaneId,
            focusedWorkspaceId: focusedWorkspaceId
        )
    }
}
