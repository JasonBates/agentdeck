import Foundation

// MARK: - The local model behind AgentDeck's generated card copy
//
// Ollama exposes residency through /api/ps. Query latency is recorded at the call site
// with its completion time rather than inferred from process CPU. The client bins these
// events into a moving five-second timeline, so idle intervals still advance the graph.
//
// The memory figure needs one correction. Ollama 0.34 reported the whole loaded model
// in /api/ps (8.1 GB for gemma4:12b); 0.40 reports only what it allocates itself, the
// KV cache and compute buffers (0.7 GB), and leaves out the weights, which llama.cpp
// memory-maps straight from the blob. The weights are still resident — the runner
// process holds them — so the rail adds the model's size on disk back when Ollama's
// figure is smaller than the weights alone, and flags that figure as an estimate. When
// Ollama's figure already covers the weights it is shown as reported, so a version that
// counts them never has them counted twice.

struct LocalModelCall: Encodable {
    var at: Int
    var ms: Int
    var ok: Bool
}

struct LocalModelSnapshot: Encodable {
    var name: String
    var status: String       // ready | busy | unloaded | offline
    var residentGB: Double?
    /// true when residentGB is the weights on disk plus Ollama's reported buffers rather
    /// than a figure Ollama measured itself.
    var residentEstimated: Bool
    var context: Int
    var calls: [LocalModelCall]
}

final class LocalModelMonitor {
    private let lock = NSLock()
    private let model: String
    private let context: Int
    private let psEndpoint: URL
    private let tagsEndpoint: URL

    private var reachable = false
    private var resident = false
    private var residentGB: Double?
    private var residentEstimated = false
    private var activeCalls = 0
    private var recentCalls: [LocalModelCall] = []

    /// What /api/ps says is resident for the configured model, and which build of it.
    private var reportedBytes: Double?
    private var reportedDigest: String?
    /// The model's size on disk from /api/tags, keyed by digest so a re-pulled model is
    /// measured again rather than carrying the old figure.
    private var weightBytes: Double?
    private var weightDigest: String?

    /// Enough raw events to fill the whole time window even during a burst. The client
    /// bins them into five-second ticks; this ring only bounds the wire payload.
    private let historyLimit = 128

    init(model: String, context: Int = 4096,
         endpoint: String = "http://127.0.0.1:11434") {
        self.model = model
        self.context = context
        self.psEndpoint = URL(string: endpoint + "/api/ps")!
        self.tagsEndpoint = URL(string: endpoint + "/api/tags")!
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
            residentEstimated: residentEstimated,
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
        guard let result = fetch(psEndpoint) else {
            lock.lock()
            reachable = false
            resident = false
            reportedBytes = nil
            reportedDigest = nil
            recompute()
            lock.unlock()
            return
        }
        applyPS(data: result)

        // The size on disk only changes when the model is re-pulled, which shows as a
        // new digest, so /api/tags is read once per build of the model rather than on
        // every five-second tick. A failed read is retried on the next tick.
        let wantsWeights: Bool = {
            lock.lock(); defer { lock.unlock() }
            return resident && (weightBytes == nil || weightDigest != reportedDigest)
        }()
        if wantsWeights, let tags = fetch(tagsEndpoint) {
            applyTags(data: tags)
        }
    }

    private func fetch(_ url: URL) -> Data? {
        var request = URLRequest(url: url)
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
        return result
    }

    /// Kept separate from the network probe so the exact Ollama payload can be tested.
    func applyPS(data: Data) {
        guard let models = Self.models(in: data) else {
            lock.lock()
            reachable = false
            resident = false
            reportedBytes = nil
            reportedDigest = nil
            recompute()
            lock.unlock()
            return
        }

        let match = models.first { Self.names(of: $0).contains(model.lowercased()) }
        // `size` is the whole loaded model across CPU and GPU; `size_vram` is the part on
        // the GPU. The weights comparison in recompute() needs the whole, otherwise a
        // model partly on the CPU under an older Ollama would read as under-reported
        // and have its weights added a second time. On Apple silicon the two are equal.
        let bytes = match.flatMap {
            ($0["size"] as? NSNumber)?.doubleValue
                ?? ($0["size_vram"] as? NSNumber)?.doubleValue
        }

        lock.lock()
        reachable = true
        resident = match != nil
        reportedBytes = bytes
        reportedDigest = match?["digest"] as? String
        recompute()
        lock.unlock()
    }

    /// The /api/tags listing: `size` there is the model's blobs on disk, which is what
    /// llama.cpp memory-maps, so it stands in for the weights' share of memory.
    func applyTags(data: Data) {
        guard let models = Self.models(in: data) else { return }
        let match = models.first { Self.names(of: $0).contains(model.lowercased()) }
        lock.lock()
        weightBytes = (match?["size"] as? NSNumber)?.doubleValue
        weightDigest = match?["digest"] as? String
        recompute()
        lock.unlock()
    }

    /// Caller holds the lock.
    private func recompute() {
        guard let reported = reportedBytes else {
            residentGB = nil
            residentEstimated = false
            return
        }
        // A residency figure smaller than the weights on disk cannot be the whole model:
        // Ollama has left the memory-mapped weights out. Add them back and say so.
        if let weights = weightBytes, weightDigest == reportedDigest, reported < weights {
            residentGB = Self.gigabytes(weights + reported)
            residentEstimated = true
        } else {
            residentGB = Self.gigabytes(reported)
            residentEstimated = false
        }
    }

    /// Ollama and its model catalogue describe this in decimal GB (8.05 GB), so the
    /// rail does too; on Apple silicon it is allocated from unified memory.
    private static func gigabytes(_ bytes: Double) -> Double {
        (bytes / 1_000_000_000 * 10).rounded() / 10
    }

    private static func models(in data: Data) -> [[String: Any]]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root["models"] as? [[String: Any]]
    }

    private static func names(of item: [String: Any]) -> [String] {
        [(item["name"] as? String ?? "").lowercased(),
         (item["model"] as? String ?? "").lowercased()]
    }
}
