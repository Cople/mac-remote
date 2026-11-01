import XCTest
@testable import MacRemoteCore

final class HTTPTests: XCTestCase {
    func testPartialHeaderAndBodyAreBuffered() throws {
        let head = "POST /api/command HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nContent-Length: 2\r\n\r\n"
        XCTAssertNil(try HTTPRequest.parse(Data("POST /api".utf8)))
        XCTAssertNil(try HTTPRequest.parse(Data((head + "{").utf8)))
        let request = try XCTUnwrap(try HTTPRequest.parse(Data((head + "{}").utf8)))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/command")
        XCTAssertEqual(request.body, Data("{}".utf8))
    }

    func testRejectsRequestSmugglingAndAmbiguousHeaders() {
        let cases = [
            "Content-Length: -1", "Content-Length: +1", "Content-Length: 1\r\nContent-Length: 1",
            "Transfer-Encoding: chunked", "Content-Length: 0\r\n Content-Length: 1",
            "Content-Length: 0\r\nHost: other", "Content-Length: 1.0"
        ]
        for header in cases {
            XCTAssertThrowsError(try HTTPRequest.parse(Data("POST / HTTP/1.1\r\nHost: localhost:1\r\n\(header)\r\n\r\n".utf8)), header)
        }
        XCTAssertThrowsError(try HTTPRequest.parse(Data("GET / HTTP/1.1\r\nHost: localhost:1\r\n\r\nGET / HTTP/1.1\r\n\r\n".utf8)))
    }

    func testRejectsOversizedHeadersAndBody() {
        XCTAssertThrowsError(try HTTPRequest.parse(Data(repeating: 65, count: 8_193))) {
            XCTAssertEqual($0 as? HTTPParseError, .tooLarge)
        }
        XCTAssertThrowsError(try HTTPRequest.parse(Data("POST / HTTP/1.1\r\nHost: localhost:1\r\nContent-Length: 4097\r\n\r\n".utf8))) {
            XCTAssertEqual($0 as? HTTPParseError, .tooLarge)
        }
    }

    func testRequiresSameOriginForMutations() throws {
        func request(_ extra: String) throws -> HTTPRequest {
            try XCTUnwrap(try HTTPRequest.parse(Data("POST /api/pair HTTP/1.1\r\nHost: 192.168.1.2:8765\r\n\(extra)\r\n".utf8)))
        }
        XCTAssertTrue(try request("Origin: http://192.168.1.2:8765\r\n").hasSameOrigin)
        XCTAssertFalse(try request("Origin: http://evil.example\r\n").hasSameOrigin)
        XCTAssertFalse(try request("").hasSameOrigin)
        XCTAssertFalse(try request("Origin: http://192.168.1.2:8765\r\nSec-Fetch-Site: cross-site\r\n").hasSameOrigin)
    }

    func testResponseHasCorrectUTF8LengthAndSecurityHeaders() {
        let response = HTTPResponse.json(["message": "已连接"])
        let text = String(decoding: response.data, as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Length: \(response.body.count)\r\n"))
        XCTAssertTrue(text.contains("frame-ancestors 'none'"))
        XCTAssertTrue(text.contains("Referrer-Policy: no-referrer"))
        XCTAssertTrue(text.contains("Connection: close"))
    }
}
