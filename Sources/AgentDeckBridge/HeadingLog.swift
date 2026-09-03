import Foundation

// MARK: - Append-only record of every heading the model produces
//
// Headings live in memory and vanish on restart, so there was no way to ask the
// questions that matter: does a title improve as a session continues, which guard
// rejects most often, did changing a prompt help. Every evaluation so far has been run
// against transcripts reconstructed after the fact, which cannot show how a heading
// *changed over time* — only what it would be now.
//
// One JSONL line per generation, rejects included. Rejects are the interesting half:
// a heading discarded for being too long or too close to the title never reaches the
// screen, so without logging it the failure is invisible.
//
//   ~/.local/state/agentdeck/headings.jsonl
//
// Fire-and-forget and best-effort: a logging failure must never affect the deck.

struct HeadingRecord: Encodable {
    var ts: String
    var pane: String
    var session: String?      // transcript path — the stable key across pane changes
    var agent: String         // claude | codex | pi
    var kind: String          // title | subtitle | outcome | activity
    var model: String
    var promptsSeen: Int      // how much history existed when this was generated
    var ms: Int
    var accepted: Bool
    var reason: String?       // why it was rejected, when it was
    var text: String
}

enum HeadingLog {
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "agentdeck.headinglog", qos: .utility)
    nonisolated(unsafe) private static var handle: FileHandle?

    static var path: String {
        "\(NSHomeDirectory())/.local/state/agentdeck/headings.jsonl"
    }

    /// 20MB is months of headings; past that the oldest are rolled to .1 and dropped.
    private static let maxBytes = 20 * 1024 * 1024

    static func record(_ r: HeadingRecord) {
        queue.async {
            guard var line = try? JSONEncoder().encode(r) else { return }
            line.append(0x0A)
            lock.lock(); defer { lock.unlock() }
            guard let fh = open() else { return }
            fh.seekToEndOfFile()
            fh.write(line)
            if (try? fh.offset()).map({ $0 > UInt64(maxBytes) }) == true { roll() }
        }
    }

    private static func open() -> FileHandle? {
        if let h = handle { return h }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: path)
        return handle
    }

    private static func roll() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(atPath: path + ".1")
        try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
    }

    static func stamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
