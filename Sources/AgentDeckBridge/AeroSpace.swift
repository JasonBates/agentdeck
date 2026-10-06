import AppKit
import Foundation

// MARK: - AeroSpace workspaces
//
// The deck's workspace bar: nine AeroSpace workspaces, three per monitor, each listing the
// apps with windows on it. Read with two `aerospace list-*` calls (~60ms together, so off
// the Herdr tick, on this feed's own queue) and cached; the tick reads the cache for free,
// the way Capacity and HostFeed ride the payload.
//
// `aerospace subscribe` pushes focus and workspace changes, and on builds that have them
// window-detected, window-closed and window-moved. As with HerdrEvents every event is a
// trigger to re-read, never state to fold in, so the two list calls stay the one source of
// truth. That also covers what the events miss: a native tab that replaces a window under
// a new id, a minimised window, an accessory app's window becoming tracked, all of which
// move focus and so fire focus-changed. A slow backstop re-read catches anything else; it
// runs fast instead when the window events are unavailable (stock AeroSpace has no
// window-closed or window-moved) or the subscription is down.
//
// Unlike Capacity this feed never carries a last-good reading: a window list that looks
// live but isn't would send a tap to the wrong place. Unavailable keeps the nine-tile
// shape with every workspace empty and says why.

struct AeroSpaceFeed: Encodable, Equatable {
    var ok: Bool
    var reason: String?
    var focused: String?
    var monitors: [AeroSpaceMonitor]
}

struct AeroSpaceMonitor: Encodable, Equatable {
    var id: Int
    var visible: String?
    var workspaces: [AeroSpaceWorkspace]
}

struct AeroSpaceWorkspace: Encodable, Equatable {
    var name: String
    var visible: Bool
    var focused: Bool
    var apps: [AeroSpaceApp]
}

struct AeroSpaceApp: Encodable, Equatable {
    var name: String
    var bundleId: String
    var windows: Int
}

enum AeroSpace {
    /// Workspaces on the bar, three per monitor, left to right. Overridable, comma-separated,
    /// so the bar is not wired to one desk.
    static let shown: [String] = {
        let raw = ProcessInfo.processInfo.environment["AGENTDECK_AEROSPACE_WORKSPACES"] ?? ""
        let list = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return list.isEmpty ? (1...9).map(String.init) : list
    }()
    static let perMonitor = 3

    static let binary = Shell.which("aerospace")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached = unavailable("reading…")
    /// Names seen in the last successful snapshot: the only ones a tap may switch to.
    nonisolated(unsafe) private static var switchable = Set<String>()
    /// Set when the subscribe child is down but snapshots still work.
    nonisolated(unsafe) static var eventsNote: String?
    /// True while a subscription that includes window-closed and window-moved is live, so
    /// the backstop can slow down.
    nonisolated(unsafe) private static var windowEvents = false

    static var windowEventsLive: Bool {
        lock.lock(); defer { lock.unlock() }
        return windowEvents
    }

    static func setWindowEventsLive(_ live: Bool) {
        lock.lock(); windowEvents = live; lock.unlock()
    }

    /// Whether the backstop should re-read now: `fast` seconds after the last re-read while
    /// window changes would otherwise go unseen, `slow` while window events are pushed.
    static func backstopDue(sinceLast elapsed: TimeInterval, windowEventsLive: Bool,
                            slow: TimeInterval, fast: TimeInterval) -> Bool {
        // Half a second of slack so a timer firing marginally early still counts.
        elapsed >= (windowEventsLive ? slow : fast) - 0.5
    }

    static func read() -> AeroSpaceFeed {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    static func isSwitchable(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return switchable.contains(name)
    }

    /// Re-reads AeroSpace. Returns true when the feed changed.
    @discardableResult
    static func refresh() -> Bool {
        var feed: AeroSpaceFeed
        var names = Set<String>()
        if let bin = binary {
            do {
                let ws = try Shell.run(bin, ["list-workspaces", "--all", "--json", "--format",
                                             "%{monitor-id} %{workspace} %{workspace-is-focused} %{workspace-is-visible}"],
                                       timeout: 3)
                let wins = try Shell.run(bin, ["list-windows", "--all", "--json", "--format",
                                               "%{workspace} %{app-name} %{app-bundle-id} %{window-id}"],
                                         timeout: 3)
                feed = assemble(workspaces: try parseWorkspaces(ws), windows: try parseWindows(wins))
                names = Set(feed.monitors.flatMap { $0.workspaces.map(\.name) })
                lock.lock(); let note = eventsNote; lock.unlock()
                feed.reason = note
            } catch {
                feed = unavailable(firstLine("\(error)"))
            }
        } else {
            feed = unavailable("aerospace not installed")
        }
        lock.lock(); defer { lock.unlock() }
        let changed = feed != cached
        cached = feed
        switchable = names
        return changed
    }

    static func setEventsNote(_ note: String?) {
        lock.lock(); eventsNote = note; lock.unlock()
    }

    // MARK: Parsing (pure, tested)

    struct WorkspaceRow: Decodable {
        var monitorId: Int
        var workspace: String
        var focused: Bool
        var visible: Bool
        enum CodingKeys: String, CodingKey {
            case monitorId = "monitor-id", workspace
            case focused = "workspace-is-focused", visible = "workspace-is-visible"
        }
    }

    struct WindowRow: Decodable {
        var workspace: String
        var appName: String
        var bundleId: String
        var windowId: Int
        enum CodingKeys: String, CodingKey {
            case workspace, appName = "app-name", bundleId = "app-bundle-id", windowId = "window-id"
        }
    }

    static func parseWorkspaces(_ data: Data) throws -> [WorkspaceRow] {
        try JSONDecoder().decode([WorkspaceRow].self, from: data)
    }

    static func parseWindows(_ data: Data) throws -> [WindowRow] {
        try JSONDecoder().decode([WindowRow].self, from: data)
    }

    /// Groups the shown workspaces into monitors of three, in `shown` order. A monitor is
    /// the bar's group, not AeroSpace's monitor id: the groups stay put if a display is
    /// unplugged, and a workspace's visibility still comes from AeroSpace.
    static func assemble(workspaces: [WorkspaceRow], windows: [WindowRow]) -> AeroSpaceFeed {
        let rows = Dictionary(workspaces.map { ($0.workspace, $0) }, uniquingKeysWith: { a, _ in a })
        var byWorkspace: [String: [String: (name: String, count: Int)]] = [:]
        for w in windows where shown.contains(w.workspace) {
            let key = w.bundleId.isEmpty ? w.appName : w.bundleId
            var apps = byWorkspace[w.workspace, default: [:]]
            apps[key, default: (w.appName, 0)].count += 1
            byWorkspace[w.workspace] = apps
        }
        let focused = workspaces.first { $0.focused }?.workspace
        let monitors = stride(from: 0, to: shown.count, by: perMonitor).enumerated().map { i, start in
            let names = shown[start..<min(start + perMonitor, shown.count)]
            let spaces = names.map { name -> AeroSpaceWorkspace in
                let apps = (byWorkspace[name] ?? [:])
                    .map { AeroSpaceApp(name: $0.value.name, bundleId: $0.key, windows: $0.value.count) }
                    .sorted { ($0.name.lowercased(), $0.bundleId) < ($1.name.lowercased(), $1.bundleId) }
                let visible = rows[name]?.visible ?? false
                return AeroSpaceWorkspace(name: name, visible: visible,
                                          focused: visible && name == focused, apps: apps)
            }
            return AeroSpaceMonitor(id: i + 1, visible: spaces.first { $0.visible }?.name,
                                    workspaces: spaces)
        }
        return AeroSpaceFeed(ok: true, reason: nil,
                             focused: shown.contains(focused ?? "") ? focused : nil,
                             monitors: monitors)
    }

    static func unavailable(_ reason: String) -> AeroSpaceFeed {
        let monitors = stride(from: 0, to: shown.count, by: perMonitor).enumerated().map { i, start in
            AeroSpaceMonitor(id: i + 1, visible: nil, workspaces:
                shown[start..<min(start + perMonitor, shown.count)].map {
                    AeroSpaceWorkspace(name: $0, visible: false, focused: false, apps: [])
                })
        }
        return AeroSpaceFeed(ok: false, reason: reason, focused: nil, monitors: monitors)
    }

    private static func firstLine(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        return String(line.prefix(160))
    }

    // MARK: Switching

    static func switchTo(_ name: String) -> Bool {
        guard let bin = binary else { return false }
        do {
            try Shell.run(bin, ["workspace", "--", name], timeout: 3)
            return true
        } catch {
            FileHandle.standardError.write(Data("aerospace workspace failed: \(error)\n".utf8))
            return false
        }
    }

    // MARK: App icons

    private static let iconLock = NSLock()
    nonisolated(unsafe) private static var icons: [String: Data] = [:]

    /// Reverse-DNS only: letters, digits, dot, hyphen, underscore.
    static func plausibleBundleId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && !id.hasPrefix(".") && !id.hasPrefix("-")
            && id.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0)
            }
    }

    /// The app's icon as a 64px PNG, or nil if no app has that bundle id.
    static func icon(bundleId: String) -> Data? {
        guard plausibleBundleId(bundleId) else { return nil }
        iconLock.lock()
        if let hit = icons[bundleId] { iconLock.unlock(); return hit }
        iconLock.unlock()
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        let px = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        iconLock.lock(); icons[bundleId] = png; iconLock.unlock()
        return png
    }
}

// MARK: - Push events from `aerospace subscribe`

final class AeroSpaceEvents {
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "agentdeck.aerospace.events")
    private var proc: Process?
    private var stopped = false

    /// Everything the bar renders. window-closed and window-moved exist only on newer
    /// builds; an older CLI refuses the whole subscription, so `legacyEvents` is the fallback.
    static let events = ["focus-changed", "focused-monitor-changed", "focused-workspace-changed",
                         "window-detected", "window-closed", "window-moved"]
    static let legacyEvents = ["focus-changed", "focused-monitor-changed",
                               "focused-workspace-changed", "window-detected"]

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    func start() {
        guard AeroSpace.binary != nil else { return }
        queue.async { [weak self] in self?.runLoop() }
    }

    func stop() {
        stopped = true
        proc?.terminate()
    }

    /// The `_event` name of one subscribe line, or nil for anything else.
    static func eventName(line: Data) -> String? {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        return obj["_event"] as? String
    }

    /// True when the CLI rejected an event name, e.g.
    /// `ERROR: Can't parse 'window-closed'.` from a build without window events.
    static func rejectedEventName(stderr: String) -> Bool {
        stderr.contains("Can't parse '")
    }

    private func runLoop() {
        var backoff: UInt32 = 1
        while !stopped {
            let started = Date()
            // Try the window events on every connect: `aerospace-switch` can swap the build
            // underneath us in either direction.
            var (status, rejected) = runOnce(Self.events, windowEvents: true)
            if rejected && !stopped {
                (status, _) = runOnce(Self.legacyEvents, windowEvents: false)
            }
            AeroSpace.setWindowEventsLive(false)
            if stopped { break }
            // A session that lasted a while was healthy; reconnect promptly.
            if Date().timeIntervalSince(started) > 30 { backoff = 1 }
            AeroSpace.setEventsNote("events down, polling; retry in \(backoff)s (\(status))")
            onChange()
            sleep(backoff)
            backoff = min(backoff * 2, 8)
        }
    }

    /// Runs one subscribe child until it exits; returns a short description of why, and
    /// whether the CLI refused an event name before sending anything.
    private func runOnce(_ events: [String], windowEvents: Bool) -> (String, rejected: Bool) {
        guard let bin = AeroSpace.binary else { return ("not installed", false) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["subscribe"] + events
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return ("\(error)", false) }
        proc = p
        defer { proc = nil }

        let handle = out.fileHandleForReading
        var buffer = Data()
        var live = false
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = buffer[buffer.index(after: nl)...]
                if Self.eventName(line: Data(line)) != nil {
                    if !live {
                        live = true
                        AeroSpace.setEventsNote(nil)
                        AeroSpace.setWindowEventsLive(windowEvents)
                    }
                    onChange()
                }
            }
            if buffer.count > 1024 * 1024 { buffer.removeAll() }
        }
        p.waitUntilExit()
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let first = errText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return ("exited \(p.terminationStatus)" + (first.isEmpty ? "" : ": \(first.prefix(120))"),
                !live && Self.rejectedEventName(stderr: errText))
    }
}
