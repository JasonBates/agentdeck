import Foundation

// MARK: - The local model behind AgentDeck's generated card copy
//
// Ollama exposes residency through /api/ps. Query latency is recorded at the call site
// with its completion time rather than inferred from process CPU. The client bins these
// events into a moving five-second timeline, so idle intervals still advance the graph.

struct LocalModelCall: Encodable {
    var at: Int
    var ms: Int
    var ok: Bool
}

struct LocalModelSnapshot: Encodable {
    var name: String
    var status: String       // ready | busy | unloaded | offline
    var residentGB: Double?
    var context: Int
    var calls: [LocalModelCall]
}

final class LocalModelMonitor {
    private let lock = NSLock()
    private let model: String
    private let context: Int
    private let psEndpoint: URL

    private var reachable = false
    private var resident = false
    private var residentGB: Double?
    private var activeCalls = 0
    private var recentCalls: [LocalModelCall] = []

    /// Enough raw events to fill the whole time window even during a burst. The client
    /// bins them into five-second ticks; this ring only bounds the wire payload.
    private let historyLimit = 128

    init(model: String, context: Int = 4096,
         endpoint: String = "http://127.0.0.1:11434") {
        self.model = model
        self.context = context
        self.psEndpoint = URL(string: endpoint + "/api/ps")!
    }

    func read() -> LocalModelSnapshot {
        lock.lock(); defer { lock.unlock() }
        let status: String
        if activeCalls > 0 {
            status = "busy"
        } else if !reachable {
            status = "offline"
        } else if resident {
            status = "ready"
        } else {
            status = "unloaded"
        }
        return LocalModelSnapshot(
            // The configured tag is gemma4:12b; the compact rail names the family and
            // leaves the operationally useful size to the memory line below it.
            name: String(model.split(separator: ":").first ?? Substring(model)).uppercased(),
            status: status,
            residentGB: residentGB,
            context: context,
            calls: recentCalls
        )
    }

    func beginCall() {
        lock.lock(); activeCalls += 1; lock.unlock()
    }

    func finishCall(ms: Int, ok: Bool) {
        lock.lock()
        activeCalls = max(0, activeCalls - 1)
        recentCalls.append(LocalModelCall(
            at: Int(Date().timeIntervalSince1970), ms: ms, ok: ok))
        if recentCalls.count > historyLimit {
            recentCalls.removeFirst(recentCalls.count - historyLimit)
        }
        lock.unlock()
    }

    /// Sampled away from the deck tick. A stopped Ollama process should make the dot
    /// red, while an available server with no loaded model is the quieter unloaded state.
    func sample() {
        var request = URLRequest(url: psEndpoint)
        request.timeoutInterval = 3

        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return }
            result = data
        }.resume()
        _ = semaphore.wait(timeout: .now() + 4)

        guard let result else {
            lock.lock()
            reachable = false
            resident = false
            residentGB = nil
            lock.unlock()
            return
        }
        applyPS(data: result)
    }

    /// Kept separate from the network probe so the exact Ollama payload can be tested.
    func applyPS(data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            lock.lock()
            reachable = false
            resident = false
            residentGB = nil
            lock.unlock()
            return
        }

        let configured = model.lowercased()
        let match = models.first { item in
            let name = (item["name"] as? String ?? "").lowercased()
            let value = (item["model"] as? String ?? "").lowercased()
            return name == configured || value == configured
        }
        let bytes = match.flatMap {
            ($0["size_vram"] as? NSNumber)?.doubleValue
                ?? ($0["size"] as? NSNumber)?.doubleValue
        }

        lock.lock()
        reachable = true
        resident = match != nil
        // Ollama and its model catalogue describe this in decimal GB (8.05 GB), so the
        // rail does too; on Apple silicon it is allocated from unified memory.
        residentGB = bytes.map { ($0 / 1_000_000_000 * 10).rounded() / 10 }
        lock.unlock()
    }
}
