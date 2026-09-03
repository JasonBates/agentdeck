import XCTest
@testable import AgentDeckBridge

final class TabTitleSyncTests: XCTestCase {
    private var directory: URL!
    private var stateURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-tab-title-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        stateURL = directory.appendingPathComponent("tab-titles.json")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testClaimsHerdrsDefaultNumberedTabAndFollowsLaterTitleImprovements() {
        var renames: [(String, String)] = []
        let sync = makeSync { renames.append(($0, $1)) }

        // Herdr shows an unnamed first tab as "1" in its snapshot and UI.
        sync.reconcile([tab(label: "1", title: "Connect AgentDeck titles")])
        sync.reconcile([tab(label: "Connect AgentDeck titles",
                            title: "Sync AgentDeck and Herdr titles")])

        XCTAssertEqual(renames.map(\.0), ["w1:t1", "w1:t1"])
        XCTAssertEqual(renames.map(\.1), [
            "Connect AgentDeck titles",
            "Sync AgentDeck and Herdr titles",
        ])
    }

    func testManualRenameReleasesTabAndLaterTitlesDoNotOverwriteIt() {
        var renames: [(String, String)] = []
        let sync = makeSync { renames.append(($0, $1)) }
        sync.reconcile([tab(label: "", title: "Generated title")])

        sync.reconcile([tab(label: "A manual title", title: "Improved generated title")])
        sync.reconcile([tab(label: "A manual title", title: "Another generated title")])

        XCTAssertEqual(renames.count, 1)
        XCTAssertEqual(renames.first?.1, "Generated title")
    }

    func testOwnershipSurvivesBridgeRestart() {
        var renames: [(String, String)] = []
        makeSync { renames.append(($0, $1)) }
            .reconcile([tab(label: "", title: "Initial title")])

        let restarted = makeSync { renames.append(($0, $1)) }
        restarted.reconcile([tab(label: "Initial title", title: "Settled title")])

        XCTAssertEqual(renames.map(\.1), ["Initial title", "Settled title"])
    }

    func testDoesNotClaimNamedOrMultiAgentTabs() {
        var renames: [(String, String)] = []
        let sync = makeSync { renames.append(($0, $1)) }

        sync.reconcile([
            tab(label: "Manual", title: "Generated"),
            tab(id: "w1:t2", label: "", title: "Ambiguous", agentCount: 2),
        ])

        XCTAssertTrue(renames.isEmpty)
    }

    func testFailedRenameIsRetriedWithoutTakingOwnership() {
        var attempts = 0
        let sync = makeSync { _, _ in
            attempts += 1
            if attempts == 1 { throw TestError.renameFailed }
        }

        let observation = tab(label: "", title: "Generated title")
        sync.reconcile([observation])
        sync.reconcile([observation])

        XCTAssertEqual(attempts, 2)
    }

    private enum TestError: Error { case renameFailed }

    private func makeSync(rename: @escaping TabTitleSync.Rename) -> TabTitleSync {
        TabTitleSync(stateURL: stateURL, rename: rename, report: { _ in })
    }

    private func tab(id: String = "w1:t1",
                     label: String,
                     title: String?,
                     agentCount: Int = 1) -> TabTitleSync.Observation {
        TabTitleSync.Observation(tabId: id,
                                 currentLabel: label,
                                 modelTitle: title,
                                 agentCount: agentCount)
    }
}
