import Foundation

// MARK: - Wire types (subset of the Herdr socket API, protocol 19)
//
// Decoded from `herdr api snapshot`. Only the fields the deck actually renders are
// modelled; the full schema is 245KB and most of it is layout geometry we don't want.
// Generate the complete set later with `herdr api schema --json`.

struct HerdrEnvelope: Decodable {
    let result: HerdrResult
}

struct HerdrResult: Decodable {
    let snapshot: HerdrSnapshot
}

struct HerdrSnapshot: Decodable {
    let version: String
    let agents: [HerdrAgent]
    let workspaces: [HerdrWorkspace]
    let tabs: [HerdrTab]
    let focusedPaneId: String?
    let focusedWorkspaceId: String?
}

/// `kind` is "id" for Claude/Codex (a session UUID) and "path" for pi (a JSONL path).
struct HerdrAgentSession: Decodable {
    let kind: String?
    let value: String?
}

struct HerdrAgent: Decodable {
    let agent: String              // "claude" | "codex" | "pi" | ...
    let agentSession: HerdrAgentSession?
    let agentStatus: String        // "idle" | "working" | ...
    let cwd: String
    let focused: Bool
    let paneId: String
    let tabId: String
    let workspaceId: String
    let terminalTitleStripped: String?
    let stateChangeSeq: Int?
    let revision: Int?
}

struct HerdrWorkspace: Decodable {
    let workspaceId: String
    let label: String?
    let number: Int?
    let agentStatus: String?
    let focused: Bool?
    let paneCount: Int?
    let tabCount: Int?
    let worktree: HerdrWorktree?
}

/// Repository identity shared by a parent checkout and all of its linked worktrees.
/// Herdr workspaces remain separate terminal environments; AgentDeck uses this metadata
/// to present them as cards within one project rather than as unrelated top-level pills.
struct HerdrWorktree: Decodable {
    let repoKey: String?
    let repoName: String?
}

struct HerdrTab: Decodable {
    let tabId: String
    let workspaceId: String
    let label: String?
    let number: Int?
    let agentStatus: String?
}

// MARK: - Source

enum HerdrError: Error, CustomStringConvertible {
    case notFound
    case exec(Int32, String)
    case decode(String)

    var description: String {
        switch self {
        case .notFound: return "herdr not found on PATH"
        case .exec(let code, let err): return "herdr exited \(code): \(err.prefix(200))"
        case .decode(let m): return "could not decode snapshot: \(m)"
        }
    }
}

enum Shell {
    /// Runs a command and returns stdout. Throws on non-zero exit.
    /// Some tools report a non-zero status while still producing perfectly good output —
    /// `codexbar usage` exits 1 on a successful read. Pass allowFailure to keep stdout.
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 5,
                    allowFailure: Bool = false) throws -> Data {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()

        // A hung child used to hang the caller with it: this runs on the poll queue, so a
        // stuck `herdr` froze the whole deck with no error. Terminate on the deadline and
        // escalate to SIGKILL if it ignores that.
        let timedOut = TimeoutFlag()
        let watchdog = DispatchWorkItem {
            guard proc.isRunning else { return }
            timedOut.set()
            proc.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        // Read before waiting so a large snapshot can't deadlock on a full pipe buffer.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        if timedOut.isSet {
            throw HerdrError.exec(proc.terminationStatus,
                                  "timed out after \(Int(timeout))s: \(path) \(args.joined(separator: " "))")
        }
        guard proc.terminationStatus == 0 || (allowFailure && !outData.isEmpty) else {
            throw HerdrError.exec(proc.terminationStatus,
                                  String(data: errData, encoding: .utf8) ?? "")
        }
        return outData
    }

    private final class TimeoutFlag {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    /// Resolves a binary the way a login shell would, without sourcing one.
    static func which(_ name: String) -> String? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

struct HerdrSource {
    let binary: String

    init() throws {
        guard let bin = Shell.which("herdr") else { throw HerdrError.notFound }
        self.binary = bin
    }

    func snapshot() throws -> HerdrSnapshot {
        let data = try Shell.run(binary, ["api", "snapshot"])
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try dec.decode(HerdrEnvelope.self, from: data).result.snapshot
        } catch {
            throw HerdrError.decode(String(describing: error))
        }
    }

    /// `herdr agent focus <target>` — target is a pane id. Crosses workspaces on its
    /// own: focusing a pane in another workspace switches to it, verified against a
    /// live session (focused_workspace_id follows the pane).
    func focus(pane: String) throws {
        try Shell.run(binary, ["agent", "focus", pane])
    }

    /// `herdr workspace focus <workspace_id>` — switch without targeting a pane.
    func focus(workspace: String) throws {
        try Shell.run(binary, ["workspace", "focus", workspace])
    }

    /// Create an unnamed tab and move Herdr to it. The title synchroniser claims it
    /// later, once a single detected agent has an accepted model-written title.
    func createTab(workspace: String) throws {
        try Shell.run(binary, ["tab", "create", "--workspace", workspace, "--focus"])
    }

    /// Keep Herdr's visible tab label aligned with AgentDeck's accepted session title.
    func rename(tab: String, title: String) throws {
        try Shell.run(binary, ["tab", "rename", tab, title])
    }
}
