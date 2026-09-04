import XCTest
@testable import AgentDeckBridge

final class ContextUsageTests: XCTestCase {
    func testClaudeTranscriptFallsBackToSessionUUIDWhenCWDContainsEmoji() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: home) }

        let uuid = "63033f4e-9143-41fe-b7d3-35b3e5b462e2"
        let storedProject = home
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(
                "-Users-jasonbates-Obsidian-VAULTS-Trinity-080-Projects----Subjectiv-Book",
                isDirectory: true
            )
        try fm.createDirectory(at: storedProject, withIntermediateDirectories: true)
        let transcript = storedProject.appendingPathComponent("\(uuid).jsonl")
        XCTAssertTrue(fm.createFile(atPath: transcript.path, contents: Data()))

        let resolved = ContextReader.path(
            agent: "claude",
            session: HerdrAgentSession(kind: "id", value: uuid),
            cwd: "/Users/jasonbates/Obsidian/VAULTS/Trinity/080 Projects/⭐️ Subjectiv/Book",
            home: home.path
        )

        XCTAssertEqual(resolved, transcript.path)
    }
}
