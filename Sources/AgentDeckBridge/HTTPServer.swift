import Foundation
import Network

/// Which addresses the bridge answers API and event requests for.
///
/// The page is same-origin, so the only cross-origin callers are other web pages open in
/// the same browser — exactly the callers that must not read the deck. A request to a
/// protected path must carry a Host the bridge has been told about: its own loopback
/// address, `AGENTDECK_PUBLIC_HOST` (the hostname a TLS proxy such as Tailscale Serve
/// presents it as), or an `AGENTDECK_ALLOWED_ORIGINS` entry. An Origin header, when
/// present, must be one of those origins and agree with the Host. Anything else gets
/// 403 `origin_rejected`. The same check defeats DNS rebinding, where a hostile page
/// resolves its own name to 127.0.0.1 and reads the bridge as if it were same-origin.
struct OriginPolicy: Equatable {
    /// Lowercased `host[:port]` values, default ports stripped, as a browser sends Host.
    private(set) var authorities: Set<String> = []
    /// Lowercased `scheme://authority` values, as a browser sends Origin.
    private(set) var origins: Set<String> = []

    init(port: UInt16, publicHost: String?, allowedOrigins: [String]) {
        add(origin: "http://127.0.0.1:\(port)")
        add(origin: "http://localhost:\(port)")
        add(origin: "http://[::1]:\(port)")
        if let publicHost, !publicHost.isEmpty { add(origin: "https://\(publicHost)") }
        for origin in allowedOrigins { add(origin: origin) }
    }

    /// Accepts `http(s)://host[:port]`, ignoring anything malformed rather than failing
    /// startup: a bad entry should lose one address, not the whole deck.
    private mutating func add(origin raw: String) {
        guard let (scheme, authority) = Self.split(origin: raw) else { return }
        authorities.insert(authority)
        origins.insert("\(scheme)://\(authority)")
    }

    static func split(origin raw: String) -> (scheme: String, authority: String)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let r = s.range(of: "://") else { return nil }
        let scheme = String(s[..<r.lowerBound])
        guard scheme == "http" || scheme == "https" else { return nil }
        var authority = String(s[r.upperBound...])
        if let end = authority.firstIndex(where: { "/?#".contains($0) }) {
            authority = String(authority[..<end])
        }
        guard !authority.isEmpty, !authority.contains("@"), !authority.contains(" ") else { return nil }
        return (scheme, normalise(authority: authority, scheme: scheme))
    }

    /// Browsers omit a default port from both Host and Origin.
    static func normalise(authority: String, scheme: String) -> String {
        let a = authority.lowercased()
        if scheme == "http", a.hasSuffix(":80") { return String(a.dropLast(3)) }
        if scheme == "https", a.hasSuffix(":443") { return String(a.dropLast(4)) }
        return a
    }

    func allows(host: String?, origin: String?) -> Bool {
        guard let host = host?.trimmingCharacters(in: .whitespaces).lowercased(),
              authorities.contains(host) else { return false }
        guard let origin = origin?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return true
        }
        guard origins.contains(origin),
              let (_, authority) = Self.split(origin: origin) else { return false }
        return authority == host
    }
}

/// Minimal HTTP/1.1 server on Network.framework — no third-party dependencies.
///
/// Server-Sent Events rather than WebSocket, deliberately: the deck is a one-way
/// push of state, actions are ordinary POSTs, and EventSource reconnects on its
/// own. That removes an entire class of MVP bug. Swap in NWProtocolWebSocket only
/// if the native iPad app later needs bidirectional traffic.
final class HTTPServer {
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "agentdeck.http")
    /// Actions shell out to `herdr` and can take up to its 5s timeout. They used to run
    /// on `queue`, which also accepts connections and delivers every SSE frame, so one
    /// slow `tab create` froze every client's stream for its duration.
    private let actions = DispatchQueue(label: "agentdeck.http.actions")
    private var listener: NWListener?
    private var sseClients: [ObjectIdentifier: SSEClient] = [:]
    private var lastPayload: Data?
    private var lastTabCreate = Date.distantPast

    /// One event stream. `pending` counts frames handed to the connection whose
    /// completion has not fired: a peer that has stopped reading — an iPad asleep behind
    /// the Serve proxy — never acknowledges, and without the count its frames would
    /// accumulate in process memory for as long as it stayed asleep.
    private final class SSEClient {
        let conn: NWConnection
        var pending = 0
        init(_ conn: NWConnection) { self.conn = conn }
    }
    /// Six unacknowledged frames is thirty seconds of heartbeat with no reader behind it.
    static let maxPendingFrames = 6
    /// More streams than a household of devices could hold open.
    static let maxStreams = 32

    /// Handlers supplied by main.
    var onFocus: ((String) -> Bool)?
    var onWorkspace: ((String) -> Bool)?
    var onCreateTab: ((String) -> Bool)?
    /// Whether an id in a POST body names something in the last Herdr snapshot. Bodies
    /// used to go straight into `herdr` argv; the bridge already holds the snapshot, so
    /// anything it has not seen is refused before a subprocess is spawned.
    var isKnown: ((_ kind: String, _ id: String) -> Bool)?
    /// Called once the listener is genuinely bound — not merely constructed.
    var onReady: (() -> Void)?
    var snapshotJSON: (() -> Data)?
    /// Set by main before start(); the default answers loopback only.
    var policy = OriginPolicy(port: 9798, publicHost: nil, allowedOrigins: [])

    /// Larger than any action body by three orders of magnitude; anything bigger is a
    /// mistake or an attempt to make the bridge buffer it.
    static let maxBodyBytes = 64 * 1024

    init(port: UInt16) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only. Tailscale Serve proxies to 127.0.0.1:<port>, and the macOS
        // firewall drops direct external connections to this binary anyway, so a
        // wildcard bind buys nothing — and collides with Tailscale's userspace
        // listener on the same port, which never shows up in lsof.
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        // No `on: port` here — the port comes from requiredLocalEndpoint above, and
        // supplying both is rejected with EINVAL.
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        // start() is asynchronous and the initializer succeeds even when the port is
        // unavailable — without this handler a failed bind is completely silent and the
        // process sits there looking healthy while nothing is listening.
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
            case .failed(let err):
                FileHandle.standardError.write(Data((
                    "fatal: listener failed on port \(self.port): \(err)\n" +
                    "       something else is using it — try --port <n> or AGENTDECK_PORT=<n>\n"
                ).utf8))
                exit(1)
            case .cancelled:
                FileHandle.standardError.write(Data("fatal: listener cancelled\n".utf8))
                exit(1)
            default:
                break
            }
        }
        l.start(queue: queue)
        listener = l
    }

    /// Push a new payload to every connected client. No-op if unchanged.
    func broadcast(_ payload: Data) {
        queue.async {
            guard payload != self.lastPayload else { return }
            self.lastPayload = payload
            self.send(event: payload)
        }
    }

    /// Re-send the current payload even if unchanged. A comment frame (`: ping`) would
    /// keep the socket warm but never fires EventSource.onmessage, so the client could
    /// not tell "nothing is happening" from "the bridge died". A real frame does both.
    func republish() {
        queue.async {
            guard let latest = self.lastPayload else { return }
            self.send(event: latest)
        }
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || (isComplete && data == nil) {
                self.drop(conn)
                return
            }
            var buf = buffer
            if let d = data { buf.append(d) }

            guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if buf.count > 128 * 1024 { self.drop(conn); return }
                self.receive(conn, buffer: buf)
                return
            }

            let head = String(decoding: buf[..<headerEnd.lowerBound], as: UTF8.self)
            let body = buf[headerEnd.upperBound...]
            guard let expected = Self.contentLength(head) else {
                self.respond(conn, status: "400 Bad Request",
                             body: Data(#"{"ok":false,"error":"bad_content_length"}"#.utf8),
                             type: "application/json")
                return
            }
            if expected > Self.maxBodyBytes {
                self.respond(conn, status: "413 Content Too Large",
                             body: Data(#"{"ok":false,"error":"too_large"}"#.utf8),
                             type: "application/json")
                return
            }
            if body.count < expected {
                self.receive(conn, buffer: buf)
                return
            }
            self.route(conn, head: head, body: Data(body.prefix(expected)))
        }
    }

    private func drop(_ conn: NWConnection) {
        sseClients.removeValue(forKey: ObjectIdentifier(conn))
        conn.cancel()
    }

    /// Absent means zero. Anything present that isn't a non-negative integer is nil,
    /// and the request is refused: `Content-Length: -1` used to parse as -1, pass every
    /// size check, and trap in `prefix(-1)` — one request from anywhere on the tailnet
    /// took the bridge down, and launchd brought it straight back for the next one.
    static func contentLength(_ head: String) -> Int? {
        guard let raw = header("content-length", in: head) else { return 0 }
        guard let n = Int(raw), n >= 0 else { return nil }
        return n
    }

    /// Something Herdr could plausibly have issued: short, printable, and not a flag.
    static func plausibleId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && !id.hasPrefix("-")
            && id.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7f }
    }

    /// First header with this (lowercased) name, value trimmed. Only the request line
    /// is excluded; a duplicate header is ignored rather than merged.
    static func header(_ name: String, in head: String) -> String? {
        for line in head.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].lowercased() == name {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Everything that reads or changes state. The page itself is public: it holds no
    /// data of its own, and serving it lets the origin explanation reach the user.
    static func isProtected(_ path: String) -> Bool {
        path == "/events" || path.hasPrefix("/events?") || path.hasPrefix("/api/")
    }

    // MARK: - Routing

    private func route(_ conn: NWConnection, head: String, body: Data) {
        guard let requestLine = head.split(separator: "\r\n").first else { return drop(conn) }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return drop(conn) }
        let method = String(parts[0])
        let path = String(parts[1])

        if Self.isProtected(path),
           !policy.allows(host: Self.header("host", in: head),
                          origin: Self.header("origin", in: head)) {
            respond(conn, status: "403 Forbidden",
                    body: Data(#"{"ok":false,"error":"origin_rejected"}"#.utf8),
                    type: "application/json")
            return
        }

        switch (method, path) {
        case ("GET", "/"), ("GET", "/index.html"):
            respond(conn, body: Public.index(), type: "text/html; charset=utf-8")

        case ("GET", "/api/snapshot"):
            respond(conn, body: snapshotJSON?() ?? Data("{}".utf8), type: "application/json")

        case ("GET", "/events"):
            openStream(conn)

        case ("POST", "/api/focus"):
            act(conn, body: body, key: "paneId", kind: "pane", handler: onFocus)

        case ("POST", "/api/workspace"):
            act(conn, body: body, key: "workspaceId", kind: "workspace", handler: onWorkspace)

        case ("POST", "/api/tab"):
            // Creating tabs is the one action that leaves something behind, so it is
            // also the one worth pacing: a finger held on the button, or anything less
            // friendly, gets one tab a second rather than one per request.
            if Date().timeIntervalSince(lastTabCreate) < 1 {
                respond(conn, status: "429 Too Many Requests",
                        body: Data(#"{"ok":false,"error":"slow_down"}"#.utf8),
                        type: "application/json")
                return
            }
            lastTabCreate = Date()
            act(conn, body: body, key: "workspaceId", kind: "workspace", handler: onCreateTab)

        default:
            respond(conn, status: "404 Not Found", body: Data("not found".utf8), type: "text/plain")
        }
    }

    /// One shape for every action: a JSON body with one id, checked against the last
    /// snapshot, handed to `herdr` off the serving queue.
    private func act(_ conn: NWConnection, body: Data, key: String, kind: String,
                     handler: ((String) -> Bool)?) {
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        guard let id = obj?[key] as? String, Self.plausibleId(id),
              isKnown?(kind, id) ?? true, let handler else {
            respond(conn, status: "400 Bad Request",
                    body: Data(#"{"ok":false,"error":"unknown_id"}"#.utf8),
                    type: "application/json")
            return
        }
        actions.async { [weak self] in
            guard let self else { return }
            if handler(id) {
                self.respond(conn, body: Data(#"{"ok":true}"#.utf8), type: "application/json")
            } else {
                self.respond(conn, status: "400 Bad Request",
                             body: Data(#"{"ok":false}"#.utf8), type: "application/json")
            }
        }
    }

    private func openStream(_ conn: NWConnection) {
        if sseClients.count >= Self.maxStreams {
            respond(conn, status: "503 Service Unavailable",
                    body: Data(#"{"ok":false,"error":"too_many_streams"}"#.utf8),
                    type: "application/json")
            return
        }
        let headers = """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream\r
        Cache-Control: no-cache, no-store\r
        Connection: keep-alive\r
        \(Self.securityHeaders)\r
        \r

        """
        conn.send(content: Data(headers.utf8), completion: .idempotent)
        let client = SSEClient(conn)
        sseClients[ObjectIdentifier(conn)] = client
        // Send current state immediately so a reconnecting client never shows blank.
        if let latest = lastPayload ?? snapshotJSON?() {
            push(Self.frame(latest), to: client)
        }
        // Keep reading so we notice the client going away.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil { self?.queue.async { self?.drop(conn) } }
        }
    }

    private func send(event payload: Data) {
        let frame = Self.frame(payload)
        for (_, c) in sseClients { push(frame, to: c) }
    }

    /// Queue one frame on a client, and drop the client if it has stopped taking them.
    private func push(_ frame: Data, to client: SSEClient) {
        if client.pending >= Self.maxPendingFrames {
            drop(client.conn)
            return
        }
        client.pending += 1
        client.conn.send(content: frame, completion: .contentProcessed { [weak self, weak client] _ in
            self?.queue.async { client?.pending -= 1 }
        })
    }

    private static func frame(_ payload: Data) -> Data {
        var d = Data("data: ".utf8)
        d.append(payload)
        d.append(Data("\n\n".utf8))
        return d
    }

    private func respond(_ conn: NWConnection, status: String = "200 OK", body: Data, type: String) {
        let headers = """
        HTTP/1.1 \(status)\r
        Content-Type: \(type)\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        \(Self.securityHeaders)\r
        Connection: close\r
        \r

        """
        var out = Data(headers.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}

extension HTTPServer {
    /// No CORS headers at all: the page is same-origin and nothing else should read the
    /// deck. The CSP permits the page's own inline script and styles and nothing remote.
    static let securityHeaders = [
        "X-Content-Type-Options: nosniff",
        "Referrer-Policy: no-referrer",
        "X-Frame-Options: DENY",
        "Content-Security-Policy: default-src 'self'; connect-src 'self'; img-src 'self' data:; "
            + "script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
            + "object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
    ].joined(separator: "\r\n")
}

// MARK: - Static asset

enum Public {
    /// Read from disk on every request so index.html can be edited and reloaded
    /// on the iPad without rebuilding the bridge.
    static func index() -> Data {
        for candidate in searchPaths {
            if let d = FileManager.default.contents(atPath: candidate) { return d }
        }
        return Data("<h1>Public/index.html not found</h1><p>Set AGENTDECK_PUBLIC.</p>".utf8)
    }

    private static var searchPaths: [String] {
        var paths: [String] = []
        if let env = ProcessInfo.processInfo.environment["AGENTDECK_PUBLIC"] {
            paths.append("\(env)/index.html")
        }
        // Package root, resolved from this source file's location at build time.
        let pkgRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AgentDeckBridge
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // package root
        paths.append(pkgRoot.appendingPathComponent("Public/index.html").path)
        paths.append(FileManager.default.currentDirectoryPath + "/Public/index.html")
        return paths
    }
}
