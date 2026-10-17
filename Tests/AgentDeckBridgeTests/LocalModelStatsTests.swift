import XCTest
@testable import AgentDeckBridge

final class LocalModelStatsTests: XCTestCase {
    // Ollama 0.34: /api/ps size covers the whole loaded model.
    static let psFullModel = Data(#"""
    {
      "models": [{
        "name": "gemma4:12b",
        "model": "gemma4:12b",
        "size": 8046205991,
        "size_vram": 8046205991,
        "digest": "4eb23ef187e2",
        "context_length": 4096
      }]
    }
    """#.utf8)

    // Ollama 0.40: /api/ps size is the KV cache and compute buffers only; the
    // memory-mapped weights are left out.
    static let psBuffersOnly = Data(#"""
    {
      "models": [{
        "name": "gemma4:12b",
        "model": "gemma4:12b",
        "size": 696401263,
        "size_vram": 696401263,
        "digest": "4eb23ef187e2",
        "context_length": 4096
      }]
    }
    """#.utf8)

    static let tags = Data(#"""
    {
      "models": [
        {"name": "qwen3.8:27b", "model": "qwen3.8:27b", "size": 17000000000, "digest": "aaaa"},
        {"name": "gemma4:12b", "model": "gemma4:12b", "size": 7556508396, "digest": "4eb23ef187e2"}
      ]
    }
    """#.utf8)

    func testOllamaPSReportsConfiguredModelResidency() {
        let monitor = LocalModelMonitor(model: "gemma4:12b")
        monitor.applyPS(data: Self.psFullModel)

        let snapshot = monitor.read()
        XCTAssertEqual(snapshot.name, "GEMMA4")
        XCTAssertEqual(snapshot.status, "ready")
        XCTAssertEqual(snapshot.residentGB, 8.0)
        XCTAssertFalse(snapshot.residentEstimated)
        XCTAssertEqual(snapshot.context, 4096)
    }

    func testWeightsAreAddedBackWhenOllamaReportsOnlyItsBuffers() {
        let monitor = LocalModelMonitor(model: "gemma4:12b")
        monitor.applyPS(data: Self.psBuffersOnly)

        // Before the size on disk is known the rail shows what Ollama said, unflagged.
        var snapshot = monitor.read()
        XCTAssertEqual(snapshot.residentGB, 0.7)
        XCTAssertFalse(snapshot.residentEstimated)

        monitor.applyTags(data: Self.tags)
        snapshot = monitor.read()
        XCTAssertEqual(snapshot.status, "ready")
        XCTAssertEqual(snapshot.residentGB, 8.3)   // 7.56 GB on disk + 0.70 GB buffers
        XCTAssertTrue(snapshot.residentEstimated)
    }

    func testWeightsAreNotCountedTwiceWhenOllamaAlreadyIncludesThem() {
        let monitor = LocalModelMonitor(model: "gemma4:12b")
        monitor.applyTags(data: Self.tags)
        monitor.applyPS(data: Self.psFullModel)

        let snapshot = monitor.read()
        XCTAssertEqual(snapshot.residentGB, 8.0)
        XCTAssertFalse(snapshot.residentEstimated)
    }

    func testSizeOnDiskForAnotherBuildOfTheModelIsIgnored() {
        let monitor = LocalModelMonitor(model: "gemma4:12b")
        monitor.applyTags(data: Data(#"""
        {"models": [{"name": "gemma4:12b", "model": "gemma4:12b",
                     "size": 7556508396, "digest": "stale"}]}
        """#.utf8))
        monitor.applyPS(data: Self.psBuffersOnly)

        let snapshot = monitor.read()
        XCTAssertEqual(snapshot.residentGB, 0.7)
        XCTAssertFalse(snapshot.residentEstimated)
    }

    func testUnloadedModelClearsTheFigure() {
        let monitor = LocalModelMonitor(model: "gemma4:12b")
        monitor.applyTags(data: Self.tags)
        monitor.applyPS(data: Self.psBuffersOnly)
        monitor.applyPS(data: Data(#"{"models": []}"#.utf8))

        let snapshot = monitor.read()
        XCTAssertEqual(snapshot.status, "unloaded")
        XCTAssertNil(snapshot.residentGB)
        XCTAssertFalse(snapshot.residentEstimated)
    }

    func testCallRingTracksBusyStateAndBoundsRecentEvents() {
        let monitor = LocalModelMonitor(model: "gemma4:12b")
        monitor.beginCall()
        XCTAssertEqual(monitor.read().status, "busy")

        for n in 0..<131 {
            monitor.finishCall(ms: 1_000 + n, ok: n != 130)
        }

        let calls = monitor.read().calls
        XCTAssertEqual(calls.count, 128)
        XCTAssertEqual(calls.first?.ms, 1_003)
        XCTAssertEqual(calls.last?.ms, 1_130)
        XCTAssertEqual(calls.last?.ok, false)
        XCTAssertGreaterThan(calls.last?.at ?? 0, 0)
    }
}
