import XCTest
@testable import AgentDeckBridge

final class OutcomeTests: XCTestCase {
    func testThreeLinesParse() {
        let o = Summariser.parseOutcome("""
        DONE: Restored the Blindnesses note and moved the fovea point.
        NEXT: Seed a note for the patient double dissociation.
        ASK: Keep "reading rule" or "fovea rule" as the canon phrasing?
        """)
        XCTAssertEqual(o?.done, "Restored the Blindnesses note and moved the fovea point")
        XCTAssertEqual(o?.next, "Seed a note for the patient double dissociation")
        XCTAssertEqual(o?.ask, "Keep \"reading rule\" or \"fovea rule\" as the canon phrasing?")
    }

    /// tidy joins the model's lines with spaces before the parser sees them.
    func testOneLineParsesTheSame() {
        let o = Summariser.parseOutcome("DONE: Wired the reset time NEXT: - ASK: -")
        XCTAssertEqual(o?.done, "Wired the reset time")
        XCTAssertNil(o?.next)
        XCTAssertNil(o?.ask)
    }

    func testPlaceholdersAndAgentTalkAreDropped() {
        let o = Summariser.parseOutcome("""
        DONE: The agent identified five pending tasks.
        NEXT: none
        ASK: No decisions are pending.
        """)
        XCTAssertNil(o, "nothing useful should survive")
    }

    /// An ASK that is not phrased as a question is a statement the model made up.
    func testAskMustBeAQuestion() {
        let o = Summariser.parseOutcome("DONE: Drafted chapter 6\nNEXT: -\nASK: Feedback is required on the structure")
        XCTAssertEqual(o?.done, "Drafted chapter 6")
        XCTAssertNil(o?.ask)
        let q = Summariser.parseOutcome("DONE: Drafted chapter 6\nNEXT: -\nASK: Approve the five-beat structure before drafting?")
        XCTAssertEqual(q?.ask, "Approve the five-beat structure before drafting?")
    }

    func testSerialisedRoundTrips() {
        let o = Outcome(done: "Fixed the parser", next: nil, ask: "Ship it tonight?")
        XCTAssertEqual(Summariser.parseOutcome(o.serialised), o)
    }
}
