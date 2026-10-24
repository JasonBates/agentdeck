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

    /// Herdr keeps the session id a pane started with; Claude may continue the
    /// conversation in a new file and leave only a `continued-in` link in the old one.
    func testClaudeTranscriptFollowsContinuedInLinks() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: home) }

        let cwd = "/Users/someone/repo"
        let project = home.appendingPathComponent(".claude/projects/-Users-someone-repo",
                                                  isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let (a, b, c) = ("aaaaaaaa-0000-0000-0000-000000000001",
                         "bbbbbbbb-0000-0000-0000-000000000002",
                         "cccccccc-0000-0000-0000-000000000003")
        func link(_ from: String, to: String) -> Data {
            Data("""
            {"type":"user","message":{"role":"user","content":"fix the deck"}}
            {"type":"continued-in","sessionId":"\(from)","continuedInSessionId":"\(to)"}

            """.utf8)
        }
        fm.createFile(atPath: project.appendingPathComponent("\(a).jsonl").path,
                      contents: link(a, to: b))
        fm.createFile(atPath: project.appendingPathComponent("\(b).jsonl").path,
                      contents: link(b, to: c))
        let live = project.appendingPathComponent("\(c).jsonl").path
        fm.createFile(atPath: live, contents: Data("{\"type\":\"user\"}\n".utf8))

        func resolve(_ id: String) -> String? {
            ContextReader.path(agent: "claude", session: HerdrAgentSession(kind: "id", value: id),
                               cwd: cwd, home: home.path)
        }
        XCTAssertEqual(resolve(a), live)
        XCTAssertEqual(resolve(c), live)
    }

    /// A link to a file that doesn't exist keeps the original, rather than losing the card.
    func testClaudeTranscriptIgnoresADanglingContinuation() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: home) }

        let project = home.appendingPathComponent(".claude/projects/-Users-someone-repo",
                                                  isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let id = "dddddddd-0000-0000-0000-000000000004"
        let path = project.appendingPathComponent("\(id).jsonl").path
        fm.createFile(atPath: path, contents: Data("""
        {"type":"continued-in","sessionId":"\(id)","continuedInSessionId":"missing"}

        """.utf8))

        XCTAssertEqual(ContextReader.path(agent: "claude",
                                          session: HerdrAgentSession(kind: "id", value: id),
                                          cwd: "/Users/someone/repo", home: home.path), path)
    }
}
