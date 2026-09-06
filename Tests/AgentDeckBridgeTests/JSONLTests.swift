import XCTest
@testable import AgentDeckBridge

final class JSONLTests: XCTestCase {
    private func write(_ text: String) throws -> (path: String, size: Int, mtime: Date) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-jsonl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("t.jsonl")
        try Data(text.utf8).write(to: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (url.path, attrs[.size] as! Int, attrs[.modificationDate] as! Date)
    }

    func testObjectsComeNewestFirstAndSkipNoise() throws {
        let f = try write("""
        {"n":1}
        not json
        {"n":2}

        {"n":3}
        """)
        let objs = Array(JSONL.tailObjects(f.path, size: f.size, mtime: f.mtime))
        XCTAssertEqual(objs.map { $0["n"] as? Int }, [3, 2, 1])
    }

    /// A window that starts on a UTF-8 continuation byte used to decode to nil and blank
    /// every heading and the context gauge for that file until its next write.
    func testWindowStartingMidCharacterStillYieldsTheTail() throws {
        // Each line is 24 bytes: the "─" box glyph is three bytes, so a window of any
        // size not a multiple of the line length starts inside one on most alignments.
        var lines: [String] = []
        for i in 0..<200 { lines.append("{\"n\":\(String(format: "%03d", i)),\"t\":\"──────\"}") }
        let text = lines.joined(separator: "\n") + "\n"
        let f = try write(text)
        for window in [50, 51, 52, 53, 100, 257] {
            let objs = Array(JSONL.tailObjects(f.path, size: f.size, mtime: f.mtime, window: window))
            XCTAssertFalse(objs.isEmpty, "window \(window) produced nothing")
            XCTAssertEqual(objs.first?["n"] as? Int, 199, "window \(window) lost the newest line")
            // The torn head line is discarded, everything after it is intact.
            for o in objs { XCTAssertEqual(o["t"] as? String, "──────") }
        }
    }

    func testTailIsCachedAgainstSizeAndMtime() throws {
        let f = try write("{\"n\":1}\n")
        XCTAssertEqual(JSONL.tailLines(f.path, size: f.size, mtime: f.mtime).count, 1)
        try Data("{\"n\":1}\n{\"n\":2}\n".utf8).write(to: URL(fileURLWithPath: f.path))
        // Same stamp: served from cache, so the second line is not seen yet.
        XCTAssertEqual(JSONL.tailLines(f.path, size: f.size, mtime: f.mtime).count, 1)
        // New stamp: re-read.
        XCTAssertEqual(JSONL.tailLines(f.path, size: f.size + 8, mtime: f.mtime).count, 2)
    }
}
