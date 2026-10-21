import Foundation

/// An event-driven laptop feed. SSH uses the user's `laptop` alias; no second bridge or
/// background service is installed. Snapshot reads never block workspace commands. A failed read clears the window list and allowed destinations.
final class RemoteAeroSpace {
    typealias Run = (String) throws -> Data
    private static let profiling = ProcessInfo.processInfo.environment["AGENTDECK_AEROSPACE_PROFILE"] == "1"
    private static func profile(_ stage: String, since start: TimeInterval) {
        guard profiling else { return }
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        FileHandle.standardError.write(Data(String(format: "aero-profile %@ %.1fms\n", stage, elapsed).utf8))
    }
    private let run: Run
    private let queue = DispatchQueue(label: "agentdeck.aerospace.laptop")
    private var cached = AeroSpace.unavailable("Laptop: connecting…")
    private var refreshed = Date.distantPast
    private var names = Set<String>()

    var onChange: ((AeroSpaceFeed) -> Void)?
    var onFocus: ((String, UInt64) -> Void)?
    private let stateLock = NSLock()
    private var revision: UInt64 = 0
    private let useEvents: Bool
    private var eventsStarted = false
    private let processLock = NSLock()
    private var eventProcess: Process?
    private var stopped = false
    private var eventPending = false
    private let eventQueue = DispatchQueue(label: "agentdeck.aerospace.laptop.events")

    // Private per-bridge control socket: command channels reuse one authenticated
    // connection, without touching the user's SSH configuration.
    private static let socketDirectory: String = {
        let path = "/tmp/agentdeck-ssh-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return path
    }()
    static var sshArguments: [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3",
         "-o", "ServerAliveInterval=2", "-o", "ServerAliveCountMax=1",
         "-o", "ControlMaster=auto", "-o", "ControlPersist=no",
         "-o", "ControlPath=\(socketDirectory)/mux", "laptop"]
    }

    init(run: Run? = nil) {
        useEvents = run == nil
        self.run = run ?? { command in
            try Shell.run("/usr/bin/ssh", Self.sshArguments + [command], timeout: 6)
        }
    }

    // A subscription only starts once a laptop view asks for data. Its events are
    // triggers to reread, not partial state; bursts collapse into one snapshot.
    private func startEvents() {
        guard useEvents, !eventsStarted else { return }
        eventsStarted = true
        eventQueue.async { self.subscribe() }
    }

    func receivedEvent(line: Data? = nil) {
        if let line, let workspace = Self.focusedWorkspace(line: line) {
            // Publish directly from the event reader, ahead of slow snapshot work.
            stateLock.lock()
            revision += 1
            onFocus?(workspace, revision)
            stateLock.unlock()
        }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        // Coalesce before entering the read queue, including events received while
        // a slow snapshot is running. At most one trailing refresh may be queued.
        stateLock.lock()
        guard !eventPending else { stateLock.unlock(); return }
        eventPending = true
        stateLock.unlock()
        queue.asyncAfter(deadline: .now() + 0.02) {
            self.stateLock.lock()
            self.eventPending = false
            self.stateLock.unlock()
            _ = self.refresh(force: true)
        }
    }

    static func focusedWorkspace(line: Data) -> String? {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let kind = event["_event"] as? String,
              ["focus-changed", "focused-workspace-changed", "focused-monitor-changed"].contains(kind),
              let workspace = event["workspace"] as? String else { return nil }
        return workspace
    }

    func stop() {
        processLock.lock()
        stopped = true
        if let process = eventProcess, process.isRunning { process.terminate() }
        processLock.unlock()
    }

    private func subscribe() {
        var failures = 0
        while true {
            processLock.lock()
            let shouldStop = stopped
            processLock.unlock()
            if shouldStop { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            // Fall back on stock AeroSpace builds that lack the extra window events.
            let prefix = "export PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin\"; "
            let full = "aerospace subscribe " + AeroSpaceEvents.events.joined(separator: " ")
            let legacy = "aerospace subscribe " + AeroSpaceEvents.legacyEvents.joined(separator: " ")
            process.arguments = Self.sshArguments + [prefix + full + " || " + legacy]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                processLock.lock()
                if stopped { processLock.unlock(); return }
                do { try process.run() } catch { processLock.unlock(); throw error }
                eventProcess = process
                processLock.unlock()
                receivedEvent() // refresh after reconnect even before the next event
                var buffer = Data()
                while true {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let line = Data(buffer[..<nl])
                        buffer.removeSubrange(...nl)
                        if AeroSpaceEvents.eventName(line: line) != nil {
                            failures = 0
                            receivedEvent(line: line)
                        }
                    }
                    if buffer.count > 1024 * 1024 { buffer.removeAll() }
                }
                process.waitUntilExit()
            } catch {}
            processLock.lock()
            eventProcess = nil
            let didStop = stopped
            processLock.unlock()
            if didStop { return }
            invalidate("Laptop event connection lost; reconnecting…")
            failures = min(failures + 1, 4)
            Thread.sleep(forTimeInterval: Double(failures * 2))
        }
    }

    private struct Snapshot: Decodable {
        var workspaces: [AeroSpace.WorkspaceRow]
        var windows: [AeroSpace.WindowRow]
    }

    // Fixed command; the browser never chooses a host, executable, or shell fragment.
    static let snapshotCommand = """
    export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin";
    printf '{"workspaces":';
    aerospace list-workspaces --all --json --format '%{monitor-id} %{workspace} %{workspace-is-focused} %{workspace-is-visible}' &&
    printf ',"windows":' &&
    aerospace list-windows --all --json --format '%{workspace} %{app-name} %{app-bundle-id} %{window-id}' &&
    printf '}'
    """

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func refresh(force: Bool = false) -> AeroSpaceFeed {
        stateLock.lock()
        if !force && Date().timeIntervalSince(refreshed) < 2 {
            let feed = cached
            stateLock.unlock()
            return feed
        }
        let startedRevision = revision
        stateLock.unlock()
        let readStarted = ProcessInfo.processInfo.systemUptime
        defer { Self.profile("snapshot", since: readStarted) }
        var feed: AeroSpaceFeed
        var newNames = Set<String>()
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: run(Self.snapshotCommand))
            feed = AeroSpace.assemble(workspaces: snapshot.workspaces, windows: snapshot.windows)
            newNames = Set(snapshot.workspaces.map(\.workspace)).intersection(AeroSpace.shown)
        } catch {
            feed = AeroSpace.unavailable("Laptop asleep, disconnected, or AeroSpace unavailable")
        }
        stateLock.lock()
        defer { stateLock.unlock() }
        // An event that arrived during the read is newer than this snapshot. Its
        // queued refresh will supply the app lists; never roll its highlight back.
        guard revision == startedRevision else { return cached }
        feed.revision = revision
        let changed = feed != cached
        cached = feed
        names = newNames
        refreshed = Date()
        if changed { onChange?(cached) }
        return cached
    }

    func read(_ completion: @escaping (AeroSpaceFeed) -> Void) {
        queue.async {
            completion(self.refresh())
            self.startEvents()
        }
    }

    private func invalidate(_ reason: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        revision += 1
        cached = AeroSpace.unavailable(reason)
        cached.revision = revision
        names.removeAll()
        refreshed = .distantPast
        onChange?(cached)
    }

    func switchTo(_ name: String) -> Bool {
        let submitted = ProcessInfo.processInfo.systemUptime
        // Only inspect state under the lock. SSH and AeroSpace work must never run
        // on the snapshot queue or while holding the state lock.
        stateLock.lock()
        let allowed = cached.ok && names.contains(name)
        stateLock.unlock()
        Self.profile("action-queue", since: submitted)
        guard allowed else { return false }
        let commandStarted = ProcessInfo.processInfo.systemUptime
        defer { Self.profile("command", since: commandStarted) }
        do {
            _ = try run("export PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin\"; aerospace workspace -- " + Self.quote(name))
            stateLock.lock()
            // Invalidate an overlapping pre-command snapshot even when no focus
            // event is emitted (e.g. switching to the already focused workspace).
            revision += 1
            refreshed = .distantPast
            stateLock.unlock()
            scheduleRefresh()
            return true
        } catch {
            invalidate("Laptop workspace switch failed")
            return false
        }
    }
}
