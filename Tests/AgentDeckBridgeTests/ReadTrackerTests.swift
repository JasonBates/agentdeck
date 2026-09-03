import XCTest
@testable import AgentDeckBridge

/// The card's bottom row reads "replied 4m" straight off `repliedSecondsAgo`, so the
/// tracker has to be honest about the replies it never watched land — the ones already
/// in the transcript when the bridge started.
final class ReadTrackerTests: XCTestCase {
    func testFirstSightingDatesTheReplyFromTheTranscript() {
        let tracker = ReadTracker()
        let anHourAgo = Date(timeIntervalSinceNow: -3600)

        let read = tracker.update(pane: "p1", focused: false, replyKey: 7, writtenAt: anHourAgo)

        // Stamping "now" here is what made every card claim it had just replied for the
        // first seconds after a restart.
        XCTAssertEqual(read.repliedSecondsAgo ?? 0, 3600, accuracy: 5)
        XCTAssertFalse(read.unread, "a reply that predates the bridge isn't new work")
    }

    func testFirstSightingWithoutATranscriptReportsNoTime() {
        let tracker = ReadTracker()

        let read = tracker.update(pane: "p1", focused: false, replyKey: 7, writtenAt: nil)

        XCTAssertNil(read.repliedSecondsAgo, "silence beats inventing a time")
    }

    func testAReplyThatLandsWhileWatchingIsDatedNow() {
        let tracker = ReadTracker()
        let anHourAgo = Date(timeIntervalSinceNow: -3600)
        _ = tracker.update(pane: "p1", focused: false, replyKey: 7, writtenAt: anHourAgo)

        // The transcript mtime only ever seeds the first sighting: once the bridge has
        // seen one reply key change into another, it knows exactly when that happened.
        let read = tracker.update(pane: "p1", focused: false, replyKey: 8, writtenAt: anHourAgo)

        XCTAssertEqual(read.repliedSecondsAgo ?? 999, 0, accuracy: 2)
        XCTAssertTrue(read.unread)
    }

    /// A pane with no transcript yet holds replyKey 0, so the first real key it reports
    /// is still a first sighting even though the tracker has polled it many times.
    func testAPaneSeenBeforeItsTranscriptExistsStillCountsAsFirstSighting() {
        let tracker = ReadTracker()
        let anHourAgo = Date(timeIntervalSinceNow: -3600)
        _ = tracker.update(pane: "p1", focused: false, replyKey: nil, writtenAt: nil)

        let read = tracker.update(pane: "p1", focused: false, replyKey: 7, writtenAt: anHourAgo)

        XCTAssertEqual(read.repliedSecondsAgo ?? 0, 3600, accuracy: 5)
        XCTAssertFalse(read.unread)
    }
}
