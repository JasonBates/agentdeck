import XCTest
@testable import AgentDeckBridge

final class CapacityTests: XCTestCase {
    private func entry(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// `codexbar usage --provider claude --json`, 10 Sep 2026. The Fable-only weekly
    /// arrives as an extra window with the weekly's length; it belongs on the weekly bar.
    func testClaudeFoldsFableWeeklyOntoTheWeeklyBar() throws {
        let e = try entry("""
        {"provider":"claude","usage":{"identity":{"providerID":"claude"},
         "secondary":{"resetsAt":"2026-09-17T05:00:00Z","usedPercent":0,"windowMinutes":10080,
                      "resetDescription":"ResetsSep17at6am(Europe/London)"},
         "dataConfidence":"percentOnly",
         "extraRateWindows":[{"window":{"resetDescription":"ResetsSep17at6am(Europe/London)",
                                        "usedPercent":1,"windowMinutes":10080,
                                        "resetsAt":"2026-09-17T05:00:00Z"},
                              "id":"claude-weekly-scoped-fable","title":"Fable only"}],
         "primary":{"resetsAt":"2026-09-11T02:40:00Z","usedPercent":2,"windowMinutes":300,
                    "resetDescription":"Resets3:40am(Europe/London)"},
         "tertiary":null,"updatedAt":"2026-09-10T22:02:19Z"},
         "pace":{"secondary":{"expectedUsedPercent":10},"primary":{"expectedUsedPercent":7}},
         "source":"claude"}
        """)
        let p = try XCTUnwrap(Capacity.parseProvider(e))
        XCTAssertEqual(p.name, "claude")
        XCTAssertEqual(p.label, "5h 2% wk 0%")
        XCTAssertEqual(p.windows.map(\.span), ["5h", "wk"])

        let five = p.windows[0], week = p.windows[1]
        XCTAssertEqual(five.used, 2)
        XCTAssertEqual(five.expected, 7)
        XCTAssertNil(five.scoped, "no 300-minute scoped window was reported")

        XCTAssertEqual(week.used, 0)
        XCTAssertEqual(week.expected, 10)
        XCTAssertEqual(week.scoped, 1)
        XCTAssertEqual(week.scopedLabel, "Fable")
    }

    /// Codex's extra windows are Spark's own allowances, not a share of the weekly, and
    /// its primary is null on this login — one bar, no tick.
    func testCodexIgnoresSparkWindows() throws {
        let e = try entry("""
        {"provider":"codex","usage":{"dataConfidence":"exact",
         "secondary":{"usedPercent":29,"windowMinutes":10080,"resetsAt":"2026-09-15T08:16:50Z",
                      "resetDescription":"Sep 15 at 9:16 AM"},
         "primary":null,
         "extraRateWindows":[
           {"id":"codex-spark","title":"Codex Spark 5-hour",
            "window":{"windowMinutes":300,"resetsAt":"2026-09-11T03:02:41Z","usedPercent":0}},
           {"id":"codex-spark-weekly","title":"Codex Spark Weekly",
            "window":{"windowMinutes":10080,"resetsAt":"2026-09-17T22:02:41Z","usedPercent":0}}]}}
        """)
        let p = try XCTUnwrap(Capacity.parseProvider(e))
        XCTAssertEqual(p.label, "wk 29%")
        XCTAssertEqual(p.windows.count, 1)
        XCTAssertNil(p.windows[0].scoped)
        XCTAssertNil(p.windows[0].scopedLabel)
    }

    func testNoWindowsMeansNoProvider() throws {
        XCTAssertNil(Capacity.parseProvider(try entry("""
        {"provider":"claude","usage":{"primary":null,"secondary":null}}
        """)))
    }
}
