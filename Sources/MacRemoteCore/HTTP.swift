import Foundation

public enum HTTPParseError: Error, Equatable {
    case malformed
    case tooLarge
}

public struct HTTPRequest {
    public static let maximumHeaderSize = 8_192
    public static let maximumBodySize = 4_096
    public let method: String
    public let target: String
    public let headers: [String: String]
    public let body: Data

    public var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }

    /// One bounded HTTP/1.1 request per connection; returns nil until the body is complete.
    public static func parse(_ data: Data) throws -> HTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter) else {
            if data.count > maximumHeaderSize { throw HTTPParseError.tooLarge }
            return nil
        }
        guard headerRange.lowerBound <= maximumHeaderSize else { throw HTTPParseError.tooLarge }
        guard let text = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            throw HTTPParseError.malformed
        }
        let lines = text.components(separatedBy: "\r\n")
        let start = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard start.count == 3, ["HTTP/1.1", "HTTP/1.0"].contains(start[2]),
              ["GET", "POST"].contains(start[0]), start[1].hasPrefix("/"),
              !start[1].hasPrefix("//"), !start[1].contains("#") else { throw HTTPParseError.malformed }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw HTTPParseError.malformed }
            let key = line[..<colon].lowercased()
            guard key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  headers[key] == nil else { throw HTTPParseError.malformed }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let host = headers["host"], !host.isEmpty, !host.contains("/"),
              !host.contains("@"), !host.contains(" "), headers["transfer-encoding"] == nil else {
            throw HTTPParseError.malformed
        }
        let length: Int
        if let rawLength = headers["content-length"] {
            guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
                  let parsed = Int(rawLength) else { throw HTTPParseError.malformed }
            length = parsed
        } else {
            length = 0
        }
        guard length <= maximumBodySize else { throw HTTPParseError.tooLarge }
        let end = headerRange.upperBound + length
        guard data.count >= end else { return nil }
        guard data.count == end else { throw HTTPParseError.malformed }
        return HTTPRequest(method: String(start[0]), target: String(start[1]), headers: headers,
                           body: Data(data[headerRange.upperBound..<end]))
    }

    public var hasSameOrigin: Bool {
        guard let host = headers["host"], let origin = headers["origin"] else { return false }
        return origin == "http://\(host)" && headers["sec-fetch-site"] != "cross-site"
    }
}

public struct HTTPResponse {
    public let status: Int
    public let body: Data
    public let contentType: String
    public var extraHeaders: [String: String]

    public init(status: Int = 200, body: Data, contentType: String = "application/json; charset=utf-8",
                headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.contentType = contentType
        self.extraHeaders = headers
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
    }

    public static func error(_ message: String, status: Int) -> HTTPResponse {
        .json(["error": message], status: status)
    }

    public var data: Data {
        let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                       404: "Not Found", 409: "Conflict", 413: "Content Too Large", 429: "Too Many Requests",
                       500: "Internal Server Error", 503: "Service Unavailable"]
        var lines = ["HTTP/1.1 \(status) \(reasons[status] ?? "Error")",
                     "Content-Length: \(body.count)", "Content-Type: \(contentType)",
                     "Connection: close", "Cache-Control: no-store", "X-Content-Type-Options: nosniff",
                     "Referrer-Policy: no-referrer", "X-Frame-Options: DENY",
                     "Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"]
        lines += extraHeaders.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
    }
}
