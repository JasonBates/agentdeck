import XCTest
@testable import AgentDeckBridge

final class OriginPolicyTests: XCTestCase {
    private let host = "studio.tail1234.ts.net"

    func testLoopbackIsAlwaysAnswered() {
        let policy = OriginPolicy(port: 9798, publicHost: nil, allowedOrigins: [])
        XCTAssertTrue(policy.allows(host: "127.0.0.1:9798", origin: nil))
        XCTAssertTrue(policy.allows(host: "localhost:9798", origin: "http://localhost:9798"))
        XCTAssertTrue(policy.allows(host: "[::1]:9798", origin: nil))
        XCTAssertFalse(policy.allows(host: "127.0.0.1:9797", origin: nil))
        XCTAssertFalse(policy.allows(host: nil, origin: nil))
    }

    func testAProxiedHostNeedsToBeDeclared() {
        let bare = OriginPolicy(port: 9798, publicHost: nil, allowedOrigins: [])
        XCTAssertFalse(bare.allows(host: host, origin: nil))

        let declared = OriginPolicy(port: 9798, publicHost: host, allowedOrigins: [])
        XCTAssertTrue(declared.allows(host: host, origin: nil))
        XCTAssertTrue(declared.allows(host: host, origin: "https://\(host)"))
        XCTAssertTrue(declared.allows(host: host.uppercased(), origin: nil))
        // public_host covers the default HTTPS port only; the port form is a distinct origin.
        XCTAssertFalse(declared.allows(host: "\(host):9797", origin: nil))
    }

    func testAllowedOriginsCoverThePortForm() {
        let policy = OriginPolicy(port: 9798, publicHost: nil,
                                  allowedOrigins: [" https://\(host):9797 ", "not a url", "ftp://x"])
        XCTAssertTrue(policy.allows(host: "\(host):9797", origin: "https://\(host):9797"))
        XCTAssertFalse(policy.allows(host: host, origin: nil))
        XCTAssertEqual(policy.authorities.count, 4)
    }

    func testDefaultPortsAreNormalised() {
        let policy = OriginPolicy(port: 9798, publicHost: nil,
                                  allowedOrigins: ["https://\(host):443", "http://example.test:80"])
        XCTAssertTrue(policy.allows(host: host, origin: "https://\(host)"))
        XCTAssertTrue(policy.allows(host: "example.test", origin: "http://example.test"))
    }

    func testAForeignOriginIsRefusedEvenWithAGoodHost() {
        let policy = OriginPolicy(port: 9798, publicHost: host, allowedOrigins: [])
        XCTAssertFalse(policy.allows(host: host, origin: "https://evil.example"))
        XCTAssertFalse(policy.allows(host: host, origin: "null"))
        // A known origin that does not match the Host is a rebinding or proxy mix-up.
        XCTAssertFalse(policy.allows(host: "127.0.0.1:9798", origin: "https://\(host)"))
    }

    func testProtectedPathsAndHeaderParsing() {
        XCTAssertTrue(HTTPServer.isProtected("/events"))
        XCTAssertTrue(HTTPServer.isProtected("/api/snapshot"))
        XCTAssertFalse(HTTPServer.isProtected("/"))
        XCTAssertFalse(HTTPServer.isProtected("/index.html"))
        let head = "GET /api/snapshot HTTP/1.1\r\nHost: studio.tail1234.ts.net\r\nOrigin:  https://x\r\nContent-Length: 12"
        XCTAssertEqual(HTTPServer.header("host", in: head), "studio.tail1234.ts.net")
        XCTAssertEqual(HTTPServer.header("origin", in: head), "https://x")
        XCTAssertEqual(HTTPServer.header("content-length", in: head), "12")
        XCTAssertNil(HTTPServer.header("cookie", in: head))
    }
}
