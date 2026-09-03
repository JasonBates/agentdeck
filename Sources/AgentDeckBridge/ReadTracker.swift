import Foundation

// MARK: - Unread, and when work last landed
//
// "Unread" means: this agent has completed a reply since the last time you looked at it.
// Looking at it = the pane being focused in Herdr — which is the same signal whether the
// focus came from the desktop or from tapping a card here, so the two stay in step
// without the dashboard having to own a separate notion of "selected".
//
// State lives in the bridge rather than the browser so it's shared across every device
// pointed at the deck. It resets when the bridge restarts, which is the right default:
// a fresh process shouldn't claim you've read things it never saw.

final class ReadTracker {
    private struct Entry {
        var replyKey: Int = 0
        var repliedAt: Date?
        var focusedAt: Date?
        var seenReplyKey: Int = 0
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    struct Status {
        var unread: Bool
        var repliedSecondsAgo: Int?
    }

    /// Call once per poll per agent. `replyKey` is nil when there's no transcript.
    /// `writtenAt` is the transcript's mtime, used only to date a reply we didn't watch land.
    func update(pane: String, focused: Bool, replyKey: Int?, writtenAt: Date?) -> Status {
        lock.lock(); defer { lock.unlock() }
        var e = entries[pane] ?? Entry()
        let now = Date()

        if let key = replyKey, key != 0, key != e.replyKey {
            // A reply completed. First sighting of a pane doesn't count as new work,
            // otherwise every agent shows unread the moment the bridge starts.
            let firstSighting = e.replyKey == 0
            e.replyKey = key
            // Stamping `now` on a first sighting would make every card claim it replied
            // this instant for the first seconds after a bridge restart — the cards are
            // read for staleness, so that's the one lie that matters. The transcript's
            // mtime is the closest honest answer; without one, say nothing at all.
            e.repliedAt = firstSighting ? writtenAt : now
            if firstSighting { e.seenReplyKey = key }
        }

        if focused {
            e.focusedAt = now
            e.seenReplyKey = e.replyKey   // looking at it marks it read
        }

        entries[pane] = e
        return Status(
            unread: e.replyKey != 0 && e.replyKey != e.seenReplyKey,
            repliedSecondsAgo: e.repliedAt.map { Int(now.timeIntervalSince($0)) }
        )
    }

    func retain(panes: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { panes.contains($0.key) }
    }
}
