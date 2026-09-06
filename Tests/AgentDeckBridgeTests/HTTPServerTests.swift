import XCTest
@testable import AgentDeckBridge

final class HTTPServerTests: XCTestCase {
    private func head(_ lines: String...) -> String {
        (["POST /api/focus HTTP/1.1"] + lines).joined(separator: "\r\n")
    }

    func testMissingContentLengthMeansEmptyBody() {
        XCTAssertEqual(HTTPServer.contentLength(head("Host: x")), 0)
    }

    func testContentLengthParses() {
        XCTAssertEqual(HTTPServer.contentLength(head("Content-Length: 42")), 42)
        XCTAssertEqual(HTTPServer.contentLength(head("content-length:  7 ")), 7)
        XCTAssertEqual(HTTPServer.contentLength(head("Content-Length: 0")), 0)
    }

    /// `Content-Length: -1` used to reach `prefix(-1)` and trap the process.
    func testNegativeOrMalformedContentLengthIsRefused() {
        XCTAssertNil(HTTPServer.contentLength(head("Content-Length: -1")))
        XCTAssertNil(HTTPServer.contentLength(head("Content-Length: -9999999")))
        XCTAssertNil(HTTPServer.contentLength(head("Content-Length: abc")))
        XCTAssertNil(HTTPServer.contentLength(head("Content-Length: 1e3")))
        XCTAssertNil(HTTPServer.contentLength(head("Content-Length: ")))
    }

    func testPlausibleIdsLookLikeHerdrIds() {
        XCTAssertTrue(HTTPServer.plausibleId("w1S:pR"))
        XCTAssertTrue(HTTPServer.plausibleId("w1S"))
        XCTAssertFalse(HTTPServer.plausibleId(""))
        XCTAssertFalse(HTTPServer.plausibleId("--workspace"))
        XCTAssertFalse(HTTPServer.plausibleId("w1 S"))
        XCTAssertFalse(HTTPServer.plausibleId("w1\nS"))
        XCTAssertFalse(HTTPServer.plausibleId(String(repeating: "p", count: 65)))
    }
}
