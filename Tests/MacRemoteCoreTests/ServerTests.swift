import XCTest
import Network
@testable import MacRemoteCore

private final class RecordingController: RemoteControlling {
    var commands: [RemoteCommand] = []
    var released = false
    func state() -> RemoteState {
        RemoteState(name: "测试 Mac", version: "1.0.0", accessibility: true, volume: 0.5, muted: false,
                    volumeControllable: true, frontmostApp: "测试播放器", holding: false)
    }
    func perform(_ command: RemoteCommand, session: String) async throws -> RemoteState {
        commands.append(command)
        return state()
    }
    func releaseAllKeys() { released = true }
}

final class ServerTests: XCTestCase {
    @MainActor
    func testConnectedDevicesRequireAuthenticationAndFollowSessionLifecycle() async throws {
        let server = RemoteServer(controller: RecordingController(), webRoot: FileManager.default.temporaryDirectory)
        let android = "Mozilla/5.0 (Linux; Android 10; K) Chrome/147.0.0.0 Mobile Safari/537.36"
        let iphone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Version/18.0 Mobile/15E148 Safari/604.1"
        func call(_ path: String = "/api/state", body: String? = nil, cookie: String? = nil,
                  peer: String = "192.168.1.10", agent: String? = nil) async throws -> HTTPResponse {
            var raw = "\(body == nil ? "GET" : "POST") \(path) HTTP/1.1\r\nHost: 127.0.0.1:0\r\nUser-Agent: \(agent ?? android)\r\n"
            if let body { raw += "Origin: http://127.0.0.1:0\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n" }
            if let cookie { raw += "Cookie: \(cookie)\r\n" }
            let request = try XCTUnwrap(try HTTPRequest.parse(Data((raw + "\r\n" + (body ?? "")).utf8)))
            return await server.route(request, peer: peer)
        }
        func cookie(_ response: HTTPResponse) throws -> String {
            String(try XCTUnwrap(response.extraHeaders["Set-Cookie"]).split(separator: ";")[0])
        }
        let unauthenticated = try await call()
        XCTAssertEqual(unauthenticated.status, 401)
        let failedPair = try await call("/api/pair", body: #"{"token":"wrong"}"#)
        XCTAssertEqual(failedPair.status, 401)
        XCTAssertTrue(server.connectedDevices().isEmpty)

        let body = "{\"token\":\"\(server.pairing.token)\"}"
        let firstPair = try await call("/api/pair", body: body)
        let firstCookie = try cookie(firstPair)
        XCTAssertEqual(server.connectedDevices().first?.summary, "Android · Chrome\n192.168.1.10")
        _ = try await call(cookie: firstCookie)
        _ = try await call("/api/command", body: #"{"action":"mute"}"#, cookie: firstCookie)
        XCTAssertEqual(server.connectedDevices().count, 1, "轮询和命令应更新同一设备")
        _ = try await call("/api/pair", body: body, peer: "192.168.1.20", agent: iphone)
        let devices = server.connectedDevices()
        XCTAssertEqual(devices.map(\.address), ["192.168.1.10", "192.168.1.20"])
        XCTAssertEqual(devices.map(\.name), ["Android · Chrome", "iPhone · Safari"])
        let latest = try XCTUnwrap(devices.map(\.lastSeen).max())
        XCTAssertEqual(server.connectedDevices(at: latest.addingTimeInterval(9)).count, 2)
        XCTAssertTrue(server.connectedDevices(at: latest.addingTimeInterval(10)).isEmpty)
        _ = try await call(cookie: firstCookie)
        XCTAssertEqual(server.connectedDevices().count, 1, "在线设备的新轮询应恢复显示")
        server.rotatePairing()
        XCTAssertTrue(server.connectedDevices().isEmpty)
        let revoked = try await call(cookie: firstCookie)
        XCTAssertEqual(revoked.status, 401)
        XCTAssertTrue(server.connectedDevices().isEmpty)

        _ = try await call("/api/pair", body: "{\"token\":\"\(server.pairing.token)\"}")
        XCTAssertEqual(server.connectedDevices().count, 1)
        server.setPairingEnabled(false)
        XCTAssertTrue(server.connectedDevices().isEmpty)
        _ = try await call()
        XCTAssertEqual(server.connectedDevices().count, 1, "免密访问也应记录设备")
        server.setPairingEnabled(true)
        XCTAssertTrue(server.connectedDevices().isEmpty)
        server.setPairingEnabled(false)
        for index in 1...17 { _ = try await call(peer: "192.168.2.\(index)") }
        XCTAssertEqual(server.connectedDevices().count, 16)
        XCTAssertFalse(server.connectedDevices().contains { $0.address == "192.168.2.1" }, "被淘汰的会话不应继续显示")
        server.stop()
        XCTAssertTrue(server.connectedDevices().isEmpty)
    }

    @MainActor
    func testManifestAndHomeScreenIconsAreAvailableBeforePairing() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let web = project.appendingPathComponent("Sources/MacRemote/Web")
        let server = RemoteServer(controller: RecordingController(), webRoot: web)
        func get(_ path: String) async throws -> HTTPResponse {
            let request = try XCTUnwrap(try HTTPRequest.parse(Data("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:0\r\n\r\n".utf8)))
            return await server.route(request)
        }
        let manifestResponse = try await get("/manifest.webmanifest")
        XCTAssertEqual(manifestResponse.status, 200)
        XCTAssertEqual(manifestResponse.contentType, "application/manifest+json; charset=utf-8")
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: manifestResponse.body) as? [String: Any])
        let icons = try XCTUnwrap(manifest["icons"] as? [[String: String]])
        XCTAssertTrue(icons.contains { $0["sizes"] == "192x192" })
        XCTAssertTrue(icons.contains { $0["sizes"] == "512x512" })
        XCTAssertTrue(icons.contains { $0["purpose"] == "maskable" })
        let paths = try icons.map { try XCTUnwrap($0["src"]) } + ["/icons/apple-touch-icon.png"]
        for path in paths {
            let response = try await get(path)
            XCTAssertEqual(response.status, 200, path)
            XCTAssertEqual(response.contentType, "image/png", path)
            XCTAssertEqual(response.body.prefix(8), Data([137, 80, 78, 71, 13, 10, 26, 10]), path)
        }
    }

    @MainActor
    func testRealHTTPPairingCommandAndRevocation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("<!doctype html><title>Mac Remote</title>".utf8).write(to: directory.appendingPathComponent("index.html"))
        let driver = RecordingController()
        let server = RemoteServer(controller: driver, webRoot: directory)
        try server.start(port: 0, advertise: false)
        defer { server.stop() }
        for _ in 0..<200 {
            if server.running { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(server.running, "本地监听器应成功启动")
        let base = "http://127.0.0.1:\(server.port)"
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        let client = URLSession(configuration: config)
        defer { client.invalidateAndCancel() }

        func call(_ path: String, body: String? = nil, cookie: String? = nil, origin: String? = nil) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: URL(string: base + path)!)
            if let body {
                request.httpMethod = "POST"
                request.httpBody = Data(body.utf8)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(origin ?? base, forHTTPHeaderField: "Origin")
            }
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            let (data, response) = try await client.data(for: request)
            return (data, try XCTUnwrap(response as? HTTPURLResponse))
        }

        let home = try await call("/")
        XCTAssertEqual(home.1.statusCode, 200)
        XCTAssertTrue(String(decoding: home.0, as: UTF8.self).contains("Mac Remote"))
        let unauthenticated = try await call("/api/state")
        XCTAssertEqual(unauthenticated.1.statusCode, 401)
        let badToken = try await call("/api/pair", body: #"{"token":"wrong"}"#)
        XCTAssertEqual(badToken.1.statusCode, 401)
        let pairBody = "{\"token\":\"\(server.pairing.token)\"}"
        let crossOrigin = try await call("/api/pair", body: pairBody, origin: "http://attacker.example")
        XCTAssertEqual(crossOrigin.1.statusCode, 403)
        let pair = try await call("/api/pair", body: pairBody)
        XCTAssertEqual(pair.1.statusCode, 200)
        XCTAssertEqual(server.connectedDevices().map(\.address), ["127.0.0.1"], "设备 IP 应来自实际 TCP 连接")
        let setCookie = try XCTUnwrap(pair.1.value(forHTTPHeaderField: "Set-Cookie"))
        XCTAssertTrue(setCookie.contains("HttpOnly; SameSite=Strict"))
        let cookie = String(setCookie.split(separator: ";")[0])
        let state = try await call("/api/state", cookie: cookie)
        XCTAssertEqual(try JSONDecoder().decode(RemoteState.self, from: state.0).name, "测试 Mac")
        let command = try await call("/api/command", body: #"{"action":"key","key":"space"}"#, cookie: cookie)
        XCTAssertEqual(command.1.statusCode, 200)
        XCTAssertEqual(driver.commands, [.key(.space)])
        let forged = try await call("/api/command", body: #"{"action":"mute"}"#, cookie: cookie, origin: "http://evil.example")
        XCTAssertEqual(forged.1.statusCode, 403)
        let invalid = try await call("/api/command", body: #"{"action":"key","key":"delete"}"#, cookie: cookie)
        XCTAssertEqual(invalid.1.statusCode, 400)
        XCTAssertEqual(driver.commands.count, 1)
        server.rotatePairing()
        XCTAssertTrue(driver.released)
        let revoked = try await call("/api/command", body: #"{"action":"mute"}"#, cookie: cookie)
        XCTAssertEqual(revoked.1.statusCode, 401)
        XCTAssertEqual(driver.commands.count, 1)
    }

    @MainActor
    func testRejectsDNSRebindingHostAndTraversal() async throws {
        let server = RemoteServer(controller: RecordingController(), webRoot: FileManager.default.temporaryDirectory)
        let request = try XCTUnwrap(try HTTPRequest.parse(Data("GET / HTTP/1.1\r\nHost: attacker.example:0\r\n\r\n".utf8)))
        let response = await server.route(request)
        XCTAssertEqual(response.status, 403)
    }

    @MainActor
    func testKeylessAccessAndEnablingCodeRevokesOpenDevices() async throws {
        let driver = RecordingController()
        let server = RemoteServer(controller: driver, webRoot: FileManager.default.temporaryDirectory, pairingEnabled: false)
        func request(_ path: String, body: String? = nil, cookie: String? = nil, origin: String = "http://127.0.0.1:0") throws -> HTTPRequest {
            let data = body.map { Data($0.utf8) } ?? Data()
            var raw = "\(body == nil ? "GET" : "POST") \(path) HTTP/1.1\r\nHost: 127.0.0.1:0\r\n"
            if body != nil { raw += "Origin: \(origin)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\n" }
            if let cookie { raw += "Cookie: \(cookie)\r\n" }
            return try XCTUnwrap(try HTTPRequest.parse(Data((raw + "\r\n").utf8) + data))
        }
        let openState = await server.route(try request("/api/state"))
        XCTAssertEqual(openState.status, 200, "关闭密钥时打开页面即可自动连接")
        let cookie = String(try XCTUnwrap(openState.extraHeaders["Set-Cookie"]).split(separator: ";")[0])
        let command = await server.route(try request("/api/command", body: #"{"action":"mute"}"#, cookie: cookie))
        XCTAssertEqual(command.status, 200)
        XCTAssertEqual(driver.commands, [.mute])
        let csrf = await server.route(try request("/api/command", body: #"{"action":"mute"}"#, cookie: cookie, origin: "http://attacker.example"))
        XCTAssertEqual(csrf.status, 403, "关闭密钥仍应阻止跨站控制")
        server.setPairingEnabled(true)
        XCTAssertTrue(driver.released, "切换密钥开关必须松开按键")
        let gated = await server.route(try request("/api/state", cookie: cookie))
        XCTAssertEqual(gated.status, 401)
        let revoked = await server.route(try request("/api/command", body: #"{"action":"mute"}"#, cookie: cookie))
        XCTAssertEqual(revoked.status, 401)
        XCTAssertEqual(driver.commands.count, 1)
        let pair = await server.route(try request("/api/pair", body: "{\"token\":\"\(server.pairing.token)\"}"))
        XCTAssertEqual(pair.status, 200)
        let protectedCookie = String(try XCTUnwrap(pair.extraHeaders["Set-Cookie"]).split(separator: ";")[0])
        server.setPairingEnabled(false)
        let reconnect = await server.route(try request("/api/state", cookie: protectedCookie))
        XCTAssertEqual(reconnect.status, 200)
        XCTAssertNotEqual(reconnect.extraHeaders["Set-Cookie"].map { String($0.split(separator: ";")[0]) }, protectedCookie)
    }

    @MainActor
    func testPairingCodeGuessingIsRateLimited() async throws {
        let server = RemoteServer(controller: RecordingController(), webRoot: FileManager.default.temporaryDirectory)
        let wrong = server.pairing.token == "000000" ? "000001" : "000000"
        let body = "{\"token\":\"\(wrong)\"}"
        let raw = "POST /api/pair HTTP/1.1\r\nHost: 127.0.0.1:0\r\nOrigin: http://127.0.0.1:0\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let request = try XCTUnwrap(try HTTPRequest.parse(Data(raw.utf8)))
        for _ in 0..<10 {
            let response = await server.route(request, peer: "test-phone")
            XCTAssertEqual(response.status, 401)
        }
        let limited = await server.route(request, peer: "test-phone")
        XCTAssertEqual(limited.status, 429)
        server.rotatePairing()
        let afterReset = await server.route(request, peer: "test-phone")
        XCTAssertNotEqual(afterReset.status, 429)
    }

    @MainActor
    func testOccupiedPortsAreSkippedInOrder() async throws {
        let first = RemoteServer(controller: RecordingController(), webRoot: FileManager.default.temporaryDirectory)
        try first.start(port: 0, advertise: false)
        defer { first.stop() }
        try await waitUntilReady(first)
        guard first.port < UInt16.max - 1 else { throw XCTSkip("临时端口过高，无法保留连续测试端口") }
        let second = RemoteServer(controller: RecordingController(), webRoot: FileManager.default.temporaryDirectory)
        try second.start(port: first.port + 1, advertise: false)
        defer { second.stop() }
        try await waitUntilReady(second)
        guard second.port == first.port + 1 else { throw XCTSkip("相邻测试端口已被其他进程占用") }
        let candidate = RemoteServer(controller: RecordingController(), webRoot: FileManager.default.temporaryDirectory)
        try candidate.start(port: first.port, advertise: false)
        defer { candidate.stop() }
        try await waitUntilReady(candidate)
        XCTAssertEqual(candidate.port, second.port + 1)
    }

    @MainActor
    private func waitUntilReady(_ server: RemoteServer) async throws {
        for _ in 0..<300 {
            if server.running { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("本地监听器没有在限定时间内准备好")
        throw RemoteError("监听器启动超时")
    }
}
