import Foundation

// MARK: - Reading the tail of a JSONL transcript
//
// Both the digest (Transcript) and the context gauge (ContextReader) read the same
// file's tail on the same trigger — a change in size or mtime — and both want only a
// handful of the newest objects. They used to carry identical readers that each parsed
// every line in the window before the caller took the first few, so a working agent
// paid two full JSON parses of a megabyte roughly once a second.
//
// One reader now. It reads the window once per (path, size, mtime), splits it into
// lines, and hands back a lazy newest-first sequence: lines are parsed only as the
// caller consumes them, and both consumers stop after a few objects.

enum JSONL {
    private static let lock = NSLock()
    private static var lines: [String: (stamp: Date, size: Int, lines: [Substring])] = [:]

    /// Newest-first JSON objects from the last `window` bytes of the file, parsed lazily.
    static func tailObjects(_ path: String, size: Int, mtime: Date,
                            window: Int = 1_024 * 1024) -> AnySequence<[String: Any]> {
        let lines = tailLines(path, size: size, mtime: mtime, window: window)
        return AnySequence(lines.lazy.compactMap { line -> [String: Any]? in
            guard line.hasPrefix("{"), let d = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        })
    }

    /// Newest-first lines of the tail window. The first line in file order is dropped
    /// when the window starts inside the file, because it is almost always torn.
    static func tailLines(_ path: String, size: Int, mtime: Date,
                          window: Int = 1_024 * 1024) -> [Substring] {
        lock.lock()
        if let hit = lines[path], hit.size == size, hit.stamp == mtime {
            lock.unlock()
            return hit.lines
        }
        lock.unlock()

        let result = read(path, size: size, window: window)
        lock.lock(); lines[path] = (mtime, size, result); lock.unlock()
        return result
    }

    private static func read(_ path: String, size: Int, window: Int) -> [Substring] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        let seeking = size > window
        if seeking { try? fh.seek(toOffset: UInt64(size - window)) }
        guard let data = try? fh.readToEnd() else { return [] }
        // Lossy on purpose. The strict initialiser returns nil whenever the window
        // starts on a UTF-8 continuation byte — transcripts are dense with box glyphs,
        // arrows and emoji, so on a large file that is a regular event — and a nil here
        // used to blank the title, subtitle, outcome and context gauge until the next
        // write. The torn first line is discarded below; the rest decodes cleanly.
        let text = String(decoding: data, as: UTF8.self)
        var out = text.split(separator: "\n", omittingEmptySubsequences: true)
        if seeking, !out.isEmpty { out.removeFirst() }
        out.reverse()
        return out
    }

    /// Drop cached windows for files no live pane reads any more.
    static func retain(paths: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        lines = lines.filter { paths.contains($0.key) }
    }
}
