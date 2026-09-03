import XCTest
@testable import AgentDeckBridge

final class LocalModelStatsTests: XCTestCase {
    func testOllamaPSReportsConfiguredModelResidency() {
        let monitor = LocalModelMonitor(model: "gemma4:12b")
        monitor.applyPS(data: Data(#"""
        {
          "models": [{
            "name": "gemma4:12b",
            "model": "gemma4:12b",
            "size": 8046205991,
            "size_vram": 8046205991,
            "context_length": 4096
          }]
        }
        """#.utf8))

        let snapshot = monitor.read()
        XCTAssertEqual(snapshot.name, "GEMMA4")
        XCTAssertEqual(snapshot.status, "ready")
        XCTAssertEqual(snapshot.residentGB, 8.0)
        XCTAssertEqual(snapshot.context, 4096)
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
