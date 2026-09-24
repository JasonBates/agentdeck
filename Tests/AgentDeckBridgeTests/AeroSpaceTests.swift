import XCTest
@testable import AgentDeckBridge

/// Synthetic fixtures in the shape `aerospace list-* --json --format` prints.
final class AeroSpaceTests: XCTestCase {
    private let workspacesJSON = Data("""
    [
      {"monitor-id":1,"workspace":"1","workspace-is-focused":false,"workspace-is-visible":true},
      {"monitor-id":1,"workspace":"2","workspace-is-focused":false,"workspace-is-visible":false},
      {"monitor-id":1,"workspace":"3","workspace-is-focused":false,"workspace-is-visible":false},
      {"monitor-id":2,"workspace":"4","workspace-is-focused":false,"workspace-is-visible":false},
      {"monitor-id":2,"workspace":"5","workspace-is-focused":false,"workspace-is-visible":false},
      {"monitor-id":2,"workspace":"6","workspace-is-focused":true,"workspace-is-visible":true},
      {"monitor-id":3,"workspace":"7","workspace-is-focused":false,"workspace-is-visible":false},
      {"monitor-id":3,"workspace":"8","workspace-is-focused":false,"workspace-is-visible":true},
      {"monitor-id":3,"workspace":"9","workspace-is-focused":false,"workspace-is-visible":false},
      {"monitor-id":2,"workspace":"Q","workspace-is-focused":false,"workspace-is-visible":false}
    ]
    """.utf8)

    private let windowsJSON = Data("""
    [
      {"workspace":"6","app-name":"Obsidian","app-bundle-id":"md.obsidian","window-id":11},
      {"workspace":"6","app-name":"Ghostty","app-bundle-id":"com.mitchellh.ghostty","window-id":12},
      {"workspace":"6","app-name":"Obsidian","app-bundle-id":"md.obsidian","window-id":13},
      {"workspace":"1","app-name":"Spotify","app-bundle-id":"com.spotify.client","window-id":14},
      {"workspace":"Q","app-name":"Notes","app-bundle-id":"com.apple.Notes","window-id":15}
    ]
    """.utf8)

    private func feed() throws -> AeroSpaceFeed {
        AeroSpace.assemble(workspaces: try AeroSpace.parseWorkspaces(workspacesJSON),
                           windows: try AeroSpace.parseWindows(windowsJSON))
    }

    func testParsesHyphenatedKeys() throws {
        let ws = try AeroSpace.parseWorkspaces(workspacesJSON)
        XCTAssertEqual(ws.first?.monitorId, 1)
        XCTAssertEqual(ws.first { $0.workspace == "6" }?.focused, true)
        let wins = try AeroSpace.parseWindows(windowsJSON)
        XCTAssertEqual(wins.first?.bundleId, "md.obsidian")
        XCTAssertEqual(wins.first?.windowId, 11)
    }

    func testGroupsNineWorkspacesIntoThreeMonitorsAndDropsOthers() throws {
        let f = try feed()
        XCTAssertTrue(f.ok)
        XCTAssertEqual(f.monitors.map(\.id), [1, 2, 3])
        XCTAssertEqual(f.monitors.map { $0.workspaces.map(\.name) },
                       [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]])
        let apps = f.monitors.flatMap { $0.workspaces.flatMap { $0.apps.map(\.name) } }
        XCTAssertFalse(apps.contains("Notes"))
    }

    func testVisibleAndFocusedFlags() throws {
        let f = try feed()
        let all = f.monitors.flatMap(\.workspaces)
        XCTAssertEqual(all.filter(\.visible).map(\.name), ["1", "6", "8"])
        XCTAssertEqual(all.filter(\.focused).map(\.name), ["6"])
        XCTAssertEqual(f.focused, "6")
        XCTAssertEqual(f.monitors.map(\.visible), ["1", "6", "8"])
    }

    func testAppsCountedAndSorted() throws {
        let six = try feed().monitors[1].workspaces[2]
        XCTAssertEqual(six.apps.map(\.name), ["Ghostty", "Obsidian"])
        XCTAssertEqual(six.apps.first { $0.name == "Obsidian" }?.windows, 2)
        XCTAssertEqual(try feed().monitors[1].workspaces[0].apps, [])
    }

    func testDeterministicRegardlessOfWindowOrder() throws {
        // Compared as values, not bytes: JSONEncoder does not fix key order. The bridge
        // decides "changed" with Equatable for the same reason.
        let wins = try AeroSpace.parseWindows(windowsJSON)
        let ws = try AeroSpace.parseWorkspaces(workspacesJSON)
        XCTAssertEqual(AeroSpace.assemble(workspaces: ws, windows: wins),
                       AeroSpace.assemble(workspaces: ws.reversed(), windows: wins.reversed()))
    }

    func testUnavailableKeepsShapeWithNoApps() {
        let f = AeroSpace.unavailable("aerospace exited 1")
        XCTAssertFalse(f.ok)
        XCTAssertEqual(f.reason, "aerospace exited 1")
        XCTAssertEqual(f.monitors.flatMap(\.workspaces).count, 9)
        XCTAssertTrue(f.monitors.flatMap(\.workspaces).allSatisfy { $0.apps.isEmpty && !$0.visible })
    }

    func testEventName() {
        XCTAssertEqual(AeroSpaceEvents.eventName(line: Data(
            #"{"_event":"focused-workspace-changed","prevWorkspace":"2","workspace":"5"}"#.utf8)),
            "focused-workspace-changed")
        XCTAssertNil(AeroSpaceEvents.eventName(line: Data()))
        XCTAssertNil(AeroSpaceEvents.eventName(line: Data("not json".utf8)))
    }

    func testBundleIdValidation() {
        XCTAssertTrue(AeroSpace.plausibleBundleId("com.mitchellh.ghostty"))
        XCTAssertTrue(AeroSpace.plausibleBundleId("net.whatsapp.WhatsApp"))
        XCTAssertFalse(AeroSpace.plausibleBundleId(""))
        XCTAssertFalse(AeroSpace.plausibleBundleId("../etc/passwd"))
        XCTAssertFalse(AeroSpace.plausibleBundleId("a/b"))
        XCTAssertFalse(AeroSpace.plausibleBundleId("-flag"))
    }

    func testNothingSwitchableBeforeASnapshot() {
        XCTAssertFalse(AeroSpace.isSwitchable("4"))
        XCTAssertTrue(HTTPServer.plausibleId("4"))
    }
}
