import XCTest
@testable import AgentDeckBridge

final class TranscriptTests: XCTestCase {
    private func codexUserTurn(_ text: String) throws -> String {
        let object: [String: Any] = [
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": text]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func claudeUserTurn(_ text: String, isMeta: Bool? = nil) throws -> String {
        var object: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": text]
        ]
        if let isMeta { object["isMeta"] = isMeta }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func piEntry(type: String, role: String? = nil, text: String) throws -> String {
        var object: [String: Any] = ["type": type]
        if let role {
            object["message"] = ["role": role, "content": [["type": "text", "text": text]]]
        } else {
            object["summary"] = text
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func testRejectsInjectedAgentsInstructionsBlock() {
        let injected = """
        # AGENTS.md instructions

        <INSTRUCTIONS>
        ## Memory
        Store decisions in Mem0.
        </INSTRUCTIONS>
        """

        XCTAssertFalse(Transcript.isRealPrompt(injected))
    }

    func testRejectsStandaloneInjectedMem0Context() {
        let injected = """
        ## Mem0 context (code/agentdeck)
        - AgentDeck uses local model-generated titles.
        """

        XCTAssertFalse(Transcript.isRealPrompt(injected))
    }

    func testKeepsRealRequestsAboutAgentsInstructions() {
        XCTAssertTrue(Transcript.isRealPrompt(
            "Can you update the AGENTS.md instructions for this repository?"
        ))
    }

    func testKeepsRealRequestsAboutMem0() {
        XCTAssertTrue(Transcript.isRealPrompt(
            "Why are the Mem0 instructions appearing in the generated title?"
        ))
    }

    func testRejectsClaudeCompactionAndInterruptionWrappers() {
        XCTAssertFalse(Transcript.isRealPrompt(
            "This session is being continued from a previous conversation that ran out of context."
        ))
        XCTAssertFalse(Transcript.isRealPrompt("[Request interrupted by user]"))
        XCTAssertFalse(Transcript.isRealPrompt("[Request interrupted by user for tool use]"))
    }

    func testCodexOpeningSkipsInjectedInstructionsAndUsesActualRequest() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let injected = """
        # AGENTS.md instructions

        <INSTRUCTIONS>
        ## Mem0 context (code/agentdeck)
        Remember the memory protocol.
        </INSTRUCTIONS>
        """
        let actual = "Explain why these generated names are wrong."
        let transcript = try [codexUserTurn(injected), codexUserTurn(actual)]
            .joined(separator: "\n") + "\n"
        try transcript.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(Transcript.opening(agent: "codex", path: url.path), actual)
    }

    func testClaudeOpeningSkipsAllMetaAndCompactionEntries() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-claude-transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let transcript = try [
            claudeUserTurn("A plausible automated task that must not become the title.", isMeta: true),
            claudeUserTurn(
                "This session is being continued from a previous conversation that ran out of context.\n\nSummary:\nSynthetic history."
            ),
            claudeUserTurn("Diagnose the misleading generated session names.")
        ].joined(separator: "\n") + "\n"
        try transcript.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            Transcript.opening(agent: "claude", path: url.path),
            "Diagnose the misleading generated session names."
        )
    }

    func testPiOpeningIgnoresHarnessToolAndCompactionEntries() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-pi-transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let transcript = try [
            piEntry(type: "compaction", text: "Synthetic compacted task summary."),
            piEntry(type: "message", role: "toolResult", text: "Contents of SKILL.md"),
            piEntry(
                type: "message", role: "user",
                text: "<skill name=\"plex\" location=\"/tmp/plex/SKILL.md\">\nInjected skill body\n</skill>"
            ),
            piEntry(
                type: "message", role: "user",
                text: "<file name=\"/tmp/reference.md\">\nInjected attachment contents\n</file>"
            ),
            piEntry(type: "message", role: "user", text: "Review the chapter structure.")
        ].joined(separator: "\n") + "\n"
        try transcript.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            Transcript.opening(agent: "pi", path: url.path),
            "Review the chapter structure."
        )
    }

    // MARK: - Pleasantries

    func testWholeTurnPleasantriesCarryNoIntent() {
        for turn in ["good morning", "Good morning!", "morning Claude", "hi there",
                     "hey", "thanks", "Thank you!", "ok", "yep", "sounds good",
                     "no worries", "got it", "carry on", "continue", "perfect",
                     "Nice one 🎉"] {
            XCTAssertFalse(Transcript.carriesIntent(turn), "should not carry intent: \(turn)")
        }
    }

    func testRequestsWrappedInPleasantriesStillCarryIntent() {
        for turn in ["good morning, can you check the deploy?",
                     "thanks — now fix the heading generator",
                     "ok do the same for the subtitle",
                     "no, use the second approach instead",
                     "morning report on the overnight research run"] {
            XCTAssertTrue(Transcript.carriesIntent(turn), "should carry intent: \(turn)")
        }
    }

    func testOpeningSkipsGreetingForTheFirstRealRequest() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-greeting-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        // The shape that produced "Greet user and start conversation": a daily-notes
        // session opening with a hello, the real substance arriving next.
        let substance = "no 8am gym this morning, I went to bed late after working on agent deck"
        let transcript = try [
            claudeUserTurn("good morning"),
            claudeUserTurn(substance)
        ].joined(separator: "\n") + "\n"
        try transcript.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(Transcript.opening(agent: "claude", path: url.path), substance)
    }

    func testOpeningFallsBackToGreetingWhenNothingElseExistsYet() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-greeting-only-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        try (try claudeUserTurn("good morning") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(Transcript.opening(agent: "claude", path: url.path), "good morning")

        // The fallback must not be cached, or the hello would pin the session's name for
        // the rest of its life once the real request arrives.
        let substance = "check whether the overnight research run landed"
        try (try [claudeUserTurn("good morning"), claudeUserTurn(substance)]
            .joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(Transcript.opening(agent: "claude", path: url.path), substance)
    }

    func testDigestPrefersRequestsOverGreetings() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-digest-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let substance = "no 8am gym this morning, I went to bed late after working on agent deck"
        try (try [claudeUserTurn("good morning"), claudeUserTurn(substance), claudeUserTurn("thanks")]
            .joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)

        let digest = Transcript.digest(agent: "claude", path: url.path)
        XCTAssertEqual(digest?.opening, substance)
        // "thanks" is the newest turn but names nothing, so the subtitle must not be
        // built from it — and it must not count as a new prompt.
        XCTAssertEqual(digest?.lastPrompt, substance)
        XCTAssertEqual(digest?.requests, "- \(substance)")
    }

    // MARK: - Slash commands

    func testSlashCommandArgumentsBecomeTheRequest() {
        let envelope = """
        <command-name>/goal</command-name>
                    <command-message>goal</command-message>
                    <command-args>agentdeck wont let me drag a card to the third row when there is only one row of cards. can you fix that please, test, ship and restart it</command-args>
        """

        XCTAssertEqual(Transcript.unwrapCommand(envelope), "agentdeck wont let me drag a card to the third row when there is only one row of cards. can you fix that please, test, ship and restart it")
    }

    func testSlashCommandWithoutArgumentsStaysFiltered() {
        let envelope = """
        <command-name>/endday</command-name>
                    <command-message>endday</command-message>
                    <command-args></command-args>
        """

        // Nothing was typed beyond the command itself, so there is no request to lift
        // and the turn is filtered exactly as before.
        XCTAssertEqual(Transcript.unwrapCommand(envelope), envelope)
        XCTAssertFalse(Transcript.isRealPrompt(Transcript.unwrapCommand(envelope)))
    }

    func testSessionOpenedWithASlashCommandStillHasARequest() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-slash-transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        // The exact shape that produced a card headed "Claude Code": the request is
        // typed as `/goal …`, echoed straight back as command stdout, then quoted by the
        // Stop-hook injection. One envelope, one echo, one isMeta entry — and before the
        // envelope was unwrapped, not a single usable request among the three.
        let transcript = try [
            claudeUserTurn("""
            <command-name>/goal</command-name>
                        <command-message>goal</command-message>
                        <command-args>agentdeck wont let me drag a card to the third row when there is only one row of cards. can you fix that please, test, ship and restart it</command-args>
            """),
            claudeUserTurn("<local-command-stdout>Goal set: agentdeck wont let me drag a card to the third row when there is only one row of cards. can you fix that please, test, ship and restart it</local-command-stdout>"),
            claudeUserTurn(
                "A session-scoped Stop hook is now active with condition: \"agentdeck wont let me drag a card to the third row when there is only one row of cards. can you fix that please, test, ship and restart it\".",
                isMeta: true
            )
        ].joined(separator: "\n") + "\n"
        try transcript.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(Transcript.opening(agent: "claude", path: url.path), "agentdeck wont let me drag a card to the third row when there is only one row of cards. can you fix that please, test, ship and restart it")
        let digest = Transcript.digest(agent: "claude", path: url.path)
        XCTAssertEqual(digest?.requests, "- agentdeck wont let me drag a card to the third row when there is only one row of cards. can you fix that please, test, ship and restart it")
        XCTAssertEqual(digest?.lastPrompt, "agentdeck wont let me drag a card to the third row when there is only one row of cards. can you fix that please, test, ship and restart it")
    }

    // MARK: - Headings that describe the assistant instead of the work

    func testRejectsHeadingsDescribingTheAssistantsReply() {
        for heading in ["Greet user and start conversation",
                        "Acknowledge user update and personal reflections",
                        "Respond to the user's morning message",
                        "Helping the user plan their day",
                        "Answer questions about the deck"] {
            XCTAssertFalse(Summariser.namesWork(heading), "should be rejected: \(heading)")
        }
    }

    func testKeepsHeadingsThatNameRealWork() {
        for heading in ["Log morning conditions and mood",
                        "Fix misleading AgentDeck session headings",
                        "Discuss chapter four structure",
                        "Confirm the preview port lease",
                        "Plan tomorrow's writing block"] {
            XCTAssertTrue(Summariser.namesWork(heading), "should be kept: \(heading)")
        }
    }
}
