import XCTest
@testable import AgentDeckBridge

final class RemoteThreadsTests: XCTestCase {
    /// Claude Code 2.1.309 names a thread's transcript with a standard UUIDv5 of its
    /// --sdk-url; two pairs observed on a live install matched Python's `uuid.uuid5` under
    /// this namespace exactly. The ids here are made up (real ones belong to an account) and
    /// the expected values come from `uuid.uuid5`, an implementation independent of ours.
    func testTranscriptIdMatchesClaudeCode() {
        let base = "https://api.anthropic.com/v1/code/sessions/"
        XCTAssertEqual(RemoteThread.transcriptId(sdkURL: base + "cse_01AbCdEfGhJkLmNpQrStUvWx"),
                       "3eee581f-8df8-54dc-90d7-f78bc60e3931")
        XCTAssertEqual(RemoteThread.transcriptId(sdkURL: base + "cse_01ZyXwVuTsRqPnMkJhGfEdCb"),
                       "fc6e3b51-0e36-5f62-adc3-a6d6d6b52592")
    }

    func testParseFindsOnlyChildrenOfRemoteControlServers() {
        let ps = """
          100     1 claude remote-control --name vault --permission-mode bypassPermissions
          101   100 /x/claude/versions/2.1.309 --print --sdk-url https://api.anthropic.com/v1/code/sessions/cse_AAA --session-id cse_AAA
          200     1 claude rc
          201   200 /x/claude/versions/2.1.309 --print --sdk-url https://api.anthropic.com/v1/code/sessions/cse_BBB --session-id cse_BBB
          300     1 claude --dangerously-skip-permissions
          301   300 /x/claude/versions/2.1.309 --print --sdk-url https://api.anthropic.com/v1/code/sessions/cse_CCC
        """
        let found = RemoteThread.parse(ps: ps)
        XCTAssertEqual(found.map(\.sessionId), ["cse_AAA", "cse_BBB"])
        XCTAssertEqual(found.first?.pid, 101)
        XCTAssertEqual(found.first?.sdkURL, "https://api.anthropic.com/v1/code/sessions/cse_AAA")
    }

    func testURLUsesTheSessionTag() {
        let t = RemoteThread(sessionId: "cse_01AbCdEfGhJkLmNpQrStUvWx", transcriptId: "", cwd: "")
        XCTAssertEqual(t.url?.absoluteString,
                       "https://claude.ai/code/session_01AbCdEfGhJkLmNpQrStUvWx")
        XCTAssertEqual(t.appURL?.absoluteString,
                       "claude://code/session_01AbCdEfGhJkLmNpQrStUvWx")
        XCTAssertEqual(t.paneId, "rc:cse_01AbCdEfGhJkLmNpQrStUvWx")
    }

    func testStatusIsIdleOnlyAfterAnEndedTurn() throws {
        func status(_ lines: [String]) throws -> String {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("rc-\(UUID().uuidString).jsonl")
            defer { try? FileManager.default.removeItem(at: url) }
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return RemoteThread.status(transcript: url.path,
                                       size: (attrs[.size] as! NSNumber).intValue,
                                       mtime: attrs[.modificationDate] as! Date)
        }
        let user = #"{"type":"user","message":{"role":"user"}}"#
        let toolUse = #"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#
        let ended = #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#
        let trailer = #"{"type":"last-prompt"}"#
        XCTAssertEqual(try status([user]), "working")
        XCTAssertEqual(try status([user, toolUse]), "working")
        XCTAssertEqual(try status([user, ended, trailer]), "idle")
    }
}
