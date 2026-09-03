import XCTest
@testable import AgentDeckBridge

/// Every fixture is a verbatim tail captured from a live pane with
/// `herdr agent read <pane> --source visible --format text`, from a session that ran
/// pi3, Codex and Claude side by side and drove each into the states below.
final class BackgroundLineTests: XCTestCase {

    // MARK: Claude

    /// Idle at the prompt with a background shell still going. The original bug.
    func testClaudeCountsBackgroundShellsFromTheHintLine() {
        let screen = """
        ✻ Brewed for 2m 0s · 1 shell still running

        ─────────────────────────────────────────
        ❯
        ─────────────────────────────────────────
          ⏵⏵ bypass permissions on · 1 shell · ← for agents · ↓ to manage
        """
        XCTAssertEqual(BackgroundLine.parse(screen),
                       [BackgroundWork(kind: "shell", count: 1)])
        XCTAssertEqual(BackgroundLine.summary(BackgroundLine.parse(screen)), "1 shell")
    }

    /// The decisive case, and the one a count-only parser misses entirely: `done`, no
    /// shell, no status line, no tree — a single countless hint segment is the whole
    /// evidence that a subagent is still running.
    func testClaudeReportsSubagentsWithNoCountWhenThatIsAllItSays() {
        let screen = """
        ─────────────────────────────────────────
        ❯
        ─────────────────────────────────────────
          ⏵⏵ bypass permissions on (shift+tab to cycle) · /tasks to see subagents · ← for agents
        """
        XCTAssertEqual(BackgroundLine.parse(screen),
                       [BackgroundWork(kind: "subagent", count: 0)])
        // Not "1 subagent" — Claude never said how many, and inventing a number here
        // would be the deck making a claim of its own.
        XCTAssertEqual(BackgroundLine.summary(BackgroundLine.parse(screen)), "subagents")
    }

    /// Both at once, which is what the hint line looks like mid-turn.
    func testClaudeReportsShellsAndSubagentsTogether() {
        let screen = "  ⏵⏵ bypass permissions on · 1 shell · /tasks to see subagents"
            + " · esc to interrupt · ← for agents · ↓ to manage"
        XCTAssertEqual(BackgroundLine.summary(BackgroundLine.parse(screen)),
                       "1 shell · subagents")
    }

    /// While Claude actually waits on subagents the hint segment goes away and the count
    /// moves to the status line, with the agent tree drawn below the footer. That tree
    /// is what pushes the status line far enough up to need a 14-line tail.
    func testClaudeTakesTheCountFromTheWaitingStatusLine() {
        let screen = """
          The second agent, summarizing the full repo, is still running.

        ✻ Waiting for 1 background agent to finish

        ─────────────────────────────────────────
        ❯
        ─────────────────────────────────────────
          ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents · ↓ to manage

          ⏺ main
          ◯ Explore  Describe agentdeck Swift architecture        3m 5s · ↓ 143.4k tokens
        """
        XCTAssertEqual(BackgroundLine.parse(screen),
                       [BackgroundWork(kind: "subagent", count: 1)])
        XCTAssertEqual(BackgroundLine.summary(BackgroundLine.parse(screen)), "1 subagent")
    }

    /// "← for agents" is a keybinding hint and sits on every Claude pane there is.
    /// Counting it would have painted the chip on the whole deck.
    func testAKeybindingHintIsNotBackgroundWork() {
        let screen = """
        ─────────────────────────────────────────
        ❯
        ─────────────────────────────────────────
          ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt · ← for agents
          ⧉  report · report
        """
        XCTAssertEqual(BackgroundLine.parse(screen), [])
        XCTAssertNil(BackgroundLine.summary(BackgroundLine.parse(screen)))
    }

    // MARK: Codex

    /// Codex keeps its own live line above the composer. Verified live rather than
    /// assumed: killing the process made the line disappear, so it is not scrollback.
    func testCodexCountsItsBackgroundTerminals() {
        let screen = """
        • Started both background commands.

          2 background terminals running · /ps to view · /stop to close

        › Write tests for @filename

          gpt-5.6-sol xhigh fast · /private/tmp/scratchpad/bgtest
        """
        // Reported as shells, not terminals: the chip is a deck-level idea, and one word
        // per agent would read as different things happening on adjacent cards.
        XCTAssertEqual(BackgroundLine.summary(BackgroundLine.parse(screen)), "2 shells")
    }

    func testCodexSingularReadsAsOneShell() {
        let screen = "  1 background terminal running · /ps to view · /stop to close"
        XCTAssertEqual(BackgroundLine.summary(BackgroundLine.parse(screen)), "1 shell")
    }

    // MARK: pi3

    /// pi3 was driven through a delegated worker subagent and a background sleep. Its
    /// footer carries mode, model and context and nothing else, and the delegation note
    /// is ordinary scrollback. There is nothing to read, so nothing is claimed.
    func testPi3OffersNothingToRead() {
        let screen = """
        ✓ Delegating worker  1/1 completed · Worker 55 B
         • Reporting started background sleeps

         Started both background sleeps, including one delegated (PIDs 2993 and 3415).

        ─────────────────────────────────────────
                          Manual  ·  GPT-5.6 Sol  ·  Max  ·  15k / 272k (5%)
        """
        XCTAssertEqual(BackgroundLine.parse(screen), [])
    }

    // MARK: Staleness

    /// A finished turn leaves "· 1 shell still running" in the scrollback, where it stays
    /// true-looking forever. Only a whole segment counts, so the prose never matches.
    func testProseInTheScrollbackIsNotACount() {
        let stale = """
        ✻ Brewed for 9m 4s · 2 shells still running
          Ran 2 shell commands
          ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt · ← for agents
        """
        XCTAssertEqual(BackgroundLine.parse(stale), [])
    }

    /// Everything read lives in a region the agent redraws. Anything further up is
    /// history, and history is what made the old turn-summary line unusable.
    func testOnlyTheTailOfTheScreenIsConsidered() {
        let old = "  ⏵⏵ bypass permissions on · 4 shells · ← for agents\n"
            + String(repeating: "\n", count: 18)
            + "  ⏵⏵ bypass permissions on · esc to interrupt · ← for agents"
        XCTAssertEqual(BackgroundLine.parse(old), [])
    }
}
