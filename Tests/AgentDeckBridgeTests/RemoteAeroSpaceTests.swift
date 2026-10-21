import XCTest
@testable import AgentDeckBridge

final class RemoteAeroSpaceTests: XCTestCase {
    private final class Commands {
        private let lock = NSLock()
        private var values: [String] = []
        func record(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private let snapshot = Data(#"{"workspaces":[{"monitor-id":1,"workspace":"1","workspace-is-focused":true,"workspace-is-visible":true}],"windows":[{"workspace":"1","app-name":"Laptop App","app-bundle-id":"test.app","window-id":1}]}"#.utf8)

    private func read(_ remote: RemoteAeroSpace) -> AeroSpaceFeed {
        let done = expectation(description: "remote read")
        var result: AeroSpaceFeed!
        remote.read { feed in result = feed; done.fulfill() }
        wait(for: [done], timeout: 2)
        return result
    }

    func testReadCachesLaptopSnapshot() {
        var calls = 0
        let remote = RemoteAeroSpace { _ in calls += 1; return self.snapshot }
        let feed = read(remote)
        XCTAssertTrue(feed.ok)
        XCTAssertEqual(feed.monitors[0].workspaces[0].apps[0].name, "Laptop App")
        XCTAssertEqual(read(remote), feed)
        XCTAssertEqual(calls, 1)
    }

    func testSwitchOnlyAcceptsNamesActuallyPresentOnLaptop() {
        let recorded = Commands()
        let remote = RemoteAeroSpace { command in recorded.record(command); return self.snapshot }
        _ = read(remote)
        XCTAssertFalse(remote.switchTo("2"))
        XCTAssertFalse(remote.switchTo("1'; touch /tmp/unwanted"))
        XCTAssertTrue(remote.switchTo("1"))
        _ = read(remote)
        let commands = recorded.all
        XCTAssertEqual(commands.filter { $0.contains("aerospace workspace --") }.count, 1)
        XCTAssertTrue(commands.contains { $0.hasSuffix("aerospace workspace -- '1'") })
    }

    func testDisconnectClearsSuccessfulSnapshotAndRejectsSwitch() {
        var offline = false
        let remote = RemoteAeroSpace { _ in
            if offline { throw HerdrError.notFound }
            return self.snapshot
        }
        XCTAssertTrue(read(remote).ok)
        offline = true
        XCTAssertFalse(remote.switchTo("1"))
        let feed = read(remote)
        XCTAssertFalse(feed.ok)
        XCTAssertTrue(feed.monitors.flatMap(\.workspaces).allSatisfy { $0.apps.isEmpty })
    }

    func testWarmSwitchSkipsPreRead() {
        let recorded = Commands()
        let remote = RemoteAeroSpace { command in recorded.record(command); return self.snapshot }
        _ = read(remote)
        XCTAssertTrue(remote.switchTo("1"))
        _ = read(remote)
        let commands = recorded.all
        XCTAssertGreaterThanOrEqual(commands.count, 2)
        XCTAssertTrue(commands[1].contains("aerospace workspace --"))
    }

    func testEventRefreshPushesChangedFeed() {
        var offline = false
        let remote = RemoteAeroSpace { _ in
            if offline { throw HerdrError.notFound }
            return self.snapshot
        }
        _ = read(remote)
        let changed = expectation(description: "push unavailable")
        remote.onChange = { feed in
            XCTAssertFalse(feed.ok)
            changed.fulfill()
        }
        offline = true
        remote.receivedEvent()
        wait(for: [changed], timeout: 2)
        XCTAssertFalse(remote.switchTo("1"))
    }

    func testInvalidJSONIsUnavailable() {
        let remote = RemoteAeroSpace { _ in Data("broken".utf8) }
        XCTAssertFalse(read(remote).ok)
    }

    func testFocusEventsExcludeWindowMoves() {
        XCTAssertEqual(RemoteAeroSpace.focusedWorkspace(line: Data(
            #"{"_event":"focused-workspace-changed","workspace":"3"}"#.utf8)), "3")
        XCTAssertEqual(RemoteAeroSpace.focusedWorkspace(line: Data(
            #"{"_event":"focus-changed","workspace":"2"}"#.utf8)), "2")
        XCTAssertNil(RemoteAeroSpace.focusedWorkspace(line: Data(
            #"{"_event":"window-moved","workspace":"3"}"#.utf8)))
    }

    func testFocusPushDoesNotWaitForSnapshotAndOldSnapshotIsDiscarded() {
        let reading = expectation(description: "slow read started")
        let pushed = expectation(description: "focus pushed immediately")
        let reconciled = expectation(description: "new snapshot published")
        let release = DispatchSemaphore(value: 0)
        var calls = 0
        let remote = RemoteAeroSpace { _ in
            calls += 1
            if calls == 2 {
                reading.fulfill()
                _ = release.wait(timeout: .now() + 2)
            }
            if calls >= 3 {
                return Data(String(decoding: self.snapshot, as: UTF8.self)
                    .replacingOccurrences(of: #""workspace":"1""#, with: #""workspace":"2""#).utf8)
            }
            return self.snapshot
        }
        _ = read(remote)
        remote.onFocus = { workspace, revision in
            XCTAssertEqual(workspace, "2")
            XCTAssertEqual(revision, 1)
            pushed.fulfill()
        }
        remote.onChange = { feed in
            XCTAssertEqual(feed.focused, "2")
            XCTAssertEqual(feed.revision, 1)
            reconciled.fulfill()
        }
        remote.receivedEvent()
        wait(for: [reading], timeout: 1)
        remote.receivedEvent(line: Data(#"{"_event":"focused-workspace-changed","workspace":"2"}"#.utf8))
        wait(for: [pushed], timeout: 0.1)
        release.signal()
        wait(for: [reconciled], timeout: 2)
    }

    func testCommandBypassesBlockedSnapshot() {
        let blocked = expectation(description: "snapshot blocked")
        let switched = expectation(description: "command bypassed snapshot")
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var reads = 0
        let remote = RemoteAeroSpace { command in
            if command.contains("aerospace workspace --") {
                switched.fulfill()
                return Data()
            }
            lock.lock(); reads += 1; let n = reads; lock.unlock()
            if n == 2 {
                blocked.fulfill()
                _ = release.wait(timeout: .now() + 2)
            }
            return self.snapshot
        }
        _ = read(remote)
        remote.receivedEvent()
        wait(for: [blocked], timeout: 1)
        DispatchQueue.global().async { XCTAssertTrue(remote.switchTo("1")) }
        // This would time out with the previous shared read/action queue.
        wait(for: [switched], timeout: 0.2)
        release.signal()
        _ = read(remote)
    }

    func testEventBurstQueuesOnlyOneTrailingSnapshot() {
        let blocked = expectation(description: "snapshot blocked")
        let trailing = expectation(description: "one trailing snapshot")
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var reads = 0
        let remote = RemoteAeroSpace { _ in
            lock.lock(); reads += 1; let n = reads; lock.unlock()
            if n == 2 {
                blocked.fulfill()
                _ = release.wait(timeout: .now() + 2)
            }
            if n == 3 { trailing.fulfill() }
            return self.snapshot
        }
        _ = read(remote)
        remote.receivedEvent()
        wait(for: [blocked], timeout: 1)
        for _ in 0..<100 { remote.receivedEvent() }
        release.signal()
        wait(for: [trailing], timeout: 1)
        _ = read(remote)
        lock.lock(); let total = reads; lock.unlock()
        XCTAssertEqual(total, 3)
    }

    func testControlSocketFitsUnixPathLimit() {
        let path = RemoteAeroSpace.sshArguments.first { $0.hasPrefix("ControlPath=") }!
        XCTAssertLessThan(path.dropFirst("ControlPath=".count).utf8.count, 104)
    }

    func testShellQuoting() {
        XCTAssertEqual(RemoteAeroSpace.quote("a'b"), "'a'\\''b'")
    }
}
