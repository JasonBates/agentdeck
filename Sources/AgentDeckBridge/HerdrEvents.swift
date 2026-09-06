import Foundation

// MARK: - Push events from Herdr's socket API
//
// Connects to ~/.config/herdr/herdr.sock, sends one events.subscribe, and reads NDJSON:
//
//   → {"id":"agentdeck","method":"events.subscribe","params":{"subscriptions":[{"type":"pane.focused"},…]}}
//   ← {"id":"agentdeck","result":{"type":"subscription_started"}}
//   ← {"data":{"pane_id":"wS:p6","type":"pane_focused","workspace_id":"wS"},"event":"pane_focused"}
//
// The events are used purely as a *trigger to re-poll*, not as a state model to fold
// into. Rebuilding state from an event stream means every missed or reordered event is
// a permanent drift bug; re-reading the snapshot keeps one source of truth and still
// removes the poll interval from the latency path. A tick costs ~21ms, and both the
// tick and the broadcast are already deduped, so a chatty event is harmless.

final class HerdrEvents {
    private let path: String
    private let onChange: () -> Void
    private var fd: Int32 = -1
    private var stopped = false
    private let queue = DispatchQueue(label: "agentdeck.events")
    private let statusLock = NSLock()
    private var current = FeedStatus(ok: false, detail: "not started")

    /// Whether the subscription is live, for the payload. Every other feed says when it
    /// is down; this one used to fall back to polling in silence.
    var status: FeedStatus {
        statusLock.lock(); defer { statusLock.unlock() }
        return current
    }

    private func report(ok: Bool, _ detail: String) {
        statusLock.lock(); current = FeedStatus(ok: ok, detail: detail); statusLock.unlock()
    }

    /// Only three subscriptions take a pane_id (output_matched, agent_status_changed,
    /// scroll_changed) and would need re-subscribing as panes come and go. These are
    /// all global, and pane.updated carries agent status changes anyway.
    private static let subscriptions = [
        "pane.focused", "workspace.focused", "tab.focused",
        "pane.created", "pane.closed", "pane.exited",
        "pane.agent_detected", "pane.updated",
        "workspace.created", "workspace.closed",
        "tab.created", "tab.closed", "tab.renamed",
    ]

    init(socketPath: String? = nil, onChange: @escaping () -> Void) {
        self.path = socketPath ?? "\(NSHomeDirectory())/.config/herdr/herdr.sock"
        self.onChange = onChange
    }

    func start() {
        queue.async { [weak self] in self?.runLoop() }
    }

    func stop() {
        stopped = true
        if fd >= 0 { close(fd) }
    }

    private func runLoop() {
        var backoff: UInt32 = 1
        while !stopped {
            if connectAndRead() {
                backoff = 1               // clean session; reconnect promptly
                report(ok: false, "socket closed, reconnecting")
            } else {
                // Herdr restarted or the socket went away. Back off to 8s so a stopped
                // Herdr doesn't spin, and keep polling in the meantime — the safety-net
                // timer is what carries the deck while events are unavailable.
                report(ok: false, "socket unavailable, polling; retry in \(backoff)s")
                sleep(backoff)
                backoff = min(backoff * 2, 8)
            }
        }
    }

    /// Returns true if the subscription was established at least once.
    private func connectAndRead() -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(s); return false
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }

        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(s, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { close(s); return false }
        fd = s
        defer { close(s); fd = -1 }

        let subs = Self.subscriptions.map { ["type": $0] }
        let req: [String: Any] = [
            "id": "agentdeck", "method": "events.subscribe",
            "params": ["subscriptions": subs],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: req) else { return false }
        var frame = body
        frame.append(0x0A)
        let sent = frame.withUnsafeBytes { write(s, $0.baseAddress, frame.count) }
        guard sent > 0 else { return false }

        var established = false
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)

        while !stopped {
            let n = read(s, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])

            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = buffer[buffer.index(after: nl)...]
                guard !line.isEmpty,
                      let obj = try? JSONSerialization.jsonObject(with: Data(line))
                        as? [String: Any] else { continue }

                if let err = obj["error"] {
                    Summariser.debug("events error: \(err)")
                    continue
                }
                if let result = obj["result"] as? [String: Any],
                   result["type"] as? String == "subscription_started" {
                    established = true
                    report(ok: true, "subscribed")
                    Summariser.debug("events: subscribed to \(Self.subscriptions.count) types")
                    continue
                }
                if obj["event"] != nil {
                    onChange()
                }
            }
            // Guard against a peer that never sends a newline.
            if buffer.count > 4 * 1024 * 1024 { buffer.removeAll() }
        }
        return established
    }
}
