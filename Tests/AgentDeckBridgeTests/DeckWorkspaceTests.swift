import XCTest
@testable import AgentDeckBridge

final class DeckWorkspaceTests: XCTestCase {
    func testNewTabTargetsFocusedMemberOfGroupedProject() {
        let parent = workspace(id: "w1", number: 1, focused: false)
        let worktree = workspace(id: "w2", number: 2, focused: true)
        let payload = Deck.payload(
            from: snapshot(workspaces: [parent, worktree], focusedWorkspaceId: "w2"),
            herdrDetail: nil,
            source: nil,
            summariser: nil
        )

        XCTAssertEqual(payload.workspaces.count, 1)
        XCTAssertEqual(payload.workspaces.first?.newTabWorkspaceId, "w2")
    }

    func testNewTabTargetsFirstMemberWhenGroupedProjectIsNotFocused() {
        let parent = workspace(id: "w1", number: 1, focused: false)
        let worktree = workspace(id: "w2", number: 2, focused: false)
        let payload = Deck.payload(
            from: snapshot(workspaces: [worktree, parent], focusedWorkspaceId: "elsewhere"),
            herdrDetail: nil,
            source: nil,
            summariser: nil
        )

        XCTAssertEqual(payload.workspaces.count, 1)
        XCTAssertEqual(payload.workspaces.first?.newTabWorkspaceId, "w1")
    }

    /// The green pill used to mean "a reply landed here in the last ten minutes", so it
    /// stayed green after you had already read the only card behind it. It now tracks the
    /// cards: green only while finished work is still unseen.
    func testGreenPillClearsOnceTheFinishedCardHasBeenRead() {
        let pane = "pane-unread"
        // Two sightings: the first establishes the pane, the second lands a new reply.
        _ = Deck.readTracker.update(pane: pane, focused: false, replyKey: 1, writtenAt: nil)
        _ = Deck.readTracker.update(pane: pane, focused: false, replyKey: 2, writtenAt: nil)

        let snap = snapshot(workspaces: [workspace(id: "w1", number: 1, focused: false)],
                            focusedWorkspaceId: "w1",
                            agents: [agent(paneId: pane, workspaceId: "w1", focused: false)])
        let unseen = Deck.payload(from: snap, herdrDetail: nil, source: nil, summariser: nil)
        XCTAssertEqual(unseen.workspaces.first?.unseenDone, 1)
        XCTAssertEqual(unseen.workspaces.first?.unread, 1)

        // Focusing the pane is what "looking at it" means, from the desktop or a tap here.
        let read = Deck.payload(
            from: snapshot(workspaces: [workspace(id: "w1", number: 1, focused: true)],
                           focusedWorkspaceId: "w1",
                           agents: [agent(paneId: pane, workspaceId: "w1", focused: true)]),
            herdrDetail: nil, source: nil, summariser: nil
        )
        XCTAssertEqual(read.workspaces.first?.unseenDone, 0)
        XCTAssertEqual(read.workspaces.first?.unread, 0)
    }

    /// Amber outranks green on the pill, so a working pane never counts towards it even
    /// while its previous reply is still unread.
    func testWorkingAgentIsNotCountedAsUnseenDone() {
        let pane = "pane-working"
        _ = Deck.readTracker.update(pane: pane, focused: false, replyKey: 1, writtenAt: nil)
        _ = Deck.readTracker.update(pane: pane, focused: false, replyKey: 2, writtenAt: nil)

        let payload = Deck.payload(
            from: snapshot(workspaces: [workspace(id: "w1", number: 1, focused: false)],
                           focusedWorkspaceId: "w1",
                           agents: [agent(paneId: pane, workspaceId: "w1",
                                          focused: false, status: "working")]),
            herdrDetail: nil, source: nil, summariser: nil
        )
        XCTAssertEqual(payload.workspaces.first?.working, 1)
        XCTAssertEqual(payload.workspaces.first?.unseenDone, 0)
    }

    private func agent(paneId: String,
                       workspaceId: String,
                       focused: Bool,
                       status: String = "idle") -> HerdrAgent {
        HerdrAgent(
            agent: "claude",
            agentSession: nil,
            agentStatus: status,
            cwd: "/tmp/agentdeck-test",
            focused: focused,
            paneId: paneId,
            tabId: "t1",
            workspaceId: workspaceId,
            terminalTitleStripped: "Reviewing the pill state",
            stateChangeSeq: nil,
            revision: nil
        )
    }

    private func workspace(id: String, number: Int, focused: Bool) -> HerdrWorkspace {
        HerdrWorkspace(
            workspaceId: id,
            label: "AgentDeck",
            number: number,
            agentStatus: "idle",
            focused: focused,
            paneCount: 0,
            tabCount: 0,
            worktree: HerdrWorktree(repoKey: "agentdeck", repoName: "AgentDeck")
        )
    }

    private func snapshot(workspaces: [HerdrWorkspace],
                          focusedWorkspaceId: String?,
                          agents: [HerdrAgent] = []) -> HerdrSnapshot {
        HerdrSnapshot(
            version: "test",
            agents: agents,
            workspaces: workspaces,
            tabs: [],
            focusedPaneId: nil,
            focusedWorkspaceId: focusedWorkspaceId
        )
    }
}
