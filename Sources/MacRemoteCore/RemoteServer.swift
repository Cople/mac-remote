import Foundation
import Network

@MainActor public protocol RemoteControlling: AnyObject {
    func state() -> RemoteState
    func perform(_ command: RemoteCommand, session: String) async throws -> RemoteState
    func releaseAllKeys()
}

public struct RemoteError: LocalizedError {
    public let message: String
    public let status: Int
    public var errorDescription: String? { message }

    public init(_ message: String, status: Int = 400) {
        self.message = message
        self.status = status
    }
}

/// Listener, parser and controller callbacks all run on the main queue.
@MainActor public final class RemoteServer {
    public private(set) var port: UInt16 = 0
    public let pairing: PairingStore
    public var onChange: (() -> Void)?
    public var onError: ((String) -> Void)?
    public private(set) var running = false
    public private(set) var lastActivity: Date?
    private let controller: RemoteControlling
    private let webRoot: URL
    private var listener: NWListener?
    private var clients: [UUID: HTTPConnection] = [:]
    private var devicesBySession: [String: ConnectedDevice] = [:]
    private var pairingAttempts: [String: (count: Int, since: Date)] = [:]

    public init(controller: RemoteControlling, webRoot: URL, pairingEnabled: Bool = true) {
        self.controller = controller
        self.webRoot = webRoot
        self.pairing = PairingStore(enabled: pairingEnabled)
    }

    public func start(port: UInt16 = 18765, advertise: Bool = true) throws {
        guard listener == nil else { return }
        try listen(startingAt: port, advertise: advertise)
    }

    private func makeListener(startingAt port: UInt16) throws -> (NWListener, UInt16) {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        parameters.allowLocalEndpointReuse = false
        var candidate = port
        while true {
            do {
                return (try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: candidate) ?? .any), candidate)
            } catch let error as NWError {
                guard case .posix(.EADDRINUSE) = error, candidate > 0, candidate < UInt16.max else { throw error }
                candidate += 1
            }
        }
    }

    private func listen(startingAt port: UInt16, advertise: Bool) throws {
        let (listener, candidate) = try makeListener(startingAt: port)
        self.listener = listener
        if advertise {
            listener.service = NWListener.Service(name: "Mac Remote", type: "_macremote._tcp")
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            DispatchQueue.main.async {
                guard let self, let listener, self.listener === listener else { return }
                self.listenerStateChanged(state, requestedPort: candidate, advertise: advertise)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            DispatchQueue.main.async {
                guard let self, self.listener != nil else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        listener.start(queue: .main)
    }

    private func listenerStateChanged(_ state: NWListener.State, requestedPort: UInt16, advertise: Bool) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue ?? 0
            running = true
            onChange?()
        case .failed(let error):
            if tryNextPort(after: requestedPort, error: error, advertise: advertise) { return }
            stop()
            onError?("服务启动失败：\(error.localizedDescription)")
        case .waiting(let error):
            if tryNextPort(after: requestedPort, error: error, advertise: advertise) { return }
            running = false
            onChange?()
            onError?("等待网络访问：\(error.localizedDescription)")
        default: break
        }
    }

    private func tryNextPort(after port: UInt16, error: NWError, advertise: Bool) -> Bool {
        guard case .posix(.EADDRINUSE) = error, port > 0, port < UInt16.max else { return false }
        listener?.cancel()
        listener = nil
        do { try listen(startingAt: port + 1, advertise: advertise) }
        catch {
            stop()
            onError?("服务启动失败：\(error.localizedDescription)")
        }
        return true
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < 32 else { connection.cancel(); return }
        let client = HTTPConnection(connection: connection)
        clients[client.id] = client
        client.onClose = { [weak self, weak client] in
            guard let client else { return }
            self?.clients.removeValue(forKey: client.id)
        }
        client.onRequest = { [weak self, weak client] request in
            guard let self, let client else { return }
            Task { @MainActor in client.respond(await self.route(request, peer: client.peer)) }
        }
        client.start()
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        let active = Array(clients.values)
        clients.removeAll()
        active.forEach { $0.close() }
        controller.releaseAllKeys()
        devicesBySession.removeAll()
        lastActivity = nil
        running = false
        port = 0
        onChange?()
    }

    public func rotatePairing() {
        controller.releaseAllKeys()
        pairing.rotate()
        pairingAttempts.removeAll()
        devicesBySession.removeAll()
        lastActivity = nil
        onChange?()
    }

    public func setPairingEnabled(_ enabled: Bool) {
        guard enabled != pairing.isEnabled else { return }
        controller.releaseAllKeys()
        pairing.setEnabled(enabled)
        pairingAttempts.removeAll()
        devicesBySession.removeAll()
        lastActivity = nil
        onChange?()
    }

    public func connectedDevices(at date: Date = Date()) -> [ConnectedDevice] {
        devicesBySession = devicesBySession.filter { session, device in
            date.timeIntervalSince(device.lastSeen) < 10 && pairing.session(from: "macremote=\(session)") != nil
        }
        return devicesBySession.values.sorted {
            if $0.address != $1.address { return $0.address < $1.address }
            return $0.name < $1.name
        }
    }

    private func recordActivity(_ request: HTTPRequest, session: String, peer: String) {
        let now = Date()
        _ = connectedDevices(at: now)
        devicesBySession[session] = ConnectedDevice(address: peer, userAgent: request.headers["user-agent"] ?? "", lastSeen: now)
        lastActivity = now
        onChange?()
    }

    public func route(_ request: HTTPRequest, peer: String = "local") async -> HTTPResponse {
        guard validHost(request.headers["host"]) else { return .error("仅允许通过本机或局域网 IP 访问", status: 403) }
        if request.method == "GET" {
            let assets: [String: (String, String)] = [
                "/": ("index.html", "text/html; charset=utf-8"),
                "/app.css": ("app.css", "text/css; charset=utf-8"),
                "/app.js": ("app.js", "text/javascript; charset=utf-8"),
                "/icon.svg": ("icon.svg", "image/svg+xml"),
                "/manifest.webmanifest": ("manifest.webmanifest", "application/manifest+json; charset=utf-8"),
                "/icons/icon-192.png": ("icons/icon-192.png", "image/png"),
                "/icons/icon-512.png": ("icons/icon-512.png", "image/png"),
                "/icons/icon-maskable-512.png": ("icons/icon-maskable-512.png", "image/png"),
                "/icons/apple-touch-icon.png": ("icons/apple-touch-icon.png", "image/png")
            ]
            if let asset = assets[request.path] {
                guard let data = try? Data(contentsOf: webRoot.appendingPathComponent(asset.0)) else {
                    return .error("遥控页面资源缺失，请重新构建应用", status: 500)
                }
                return HTTPResponse(body: data, contentType: asset.1)
            }
            if request.path == "/api/state" {
                var newSession: String?
                let session: String
                if let existing = pairing.session(from: request.headers["cookie"]) {
                    session = existing
                } else {
                    guard !pairing.isEnabled, let created = pairing.pair() else {
                        return .error("请输入 Mac 菜单栏中的 6 位配对码，或扫描二维码", status: 401)
                    }
                    newSession = created
                    session = created
                }
                recordActivity(request, session: session, peer: peer)
                return stateResponse(newSession: newSession)
            }
            return .error("页面不存在", status: 404)
        }

        guard request.hasSameOrigin else { return .error("请求来源不匹配", status: 403) }
        guard request.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "application/json" else {
            return .error("需要 JSON 请求", status: 400)
        }
        if request.path == "/api/pair" {
            let now = Date()
            pairingAttempts = pairingAttempts.filter { now.timeIntervalSince($0.value.since) < 60 }
            let attempt = pairingAttempts[peer] ?? (count: 0, since: now)
            guard attempt.count < 10, pairingAttempts.count < 128 || pairingAttempts[peer] != nil else {
                return .error("配对尝试过多，请在一分钟后重试", status: 429)
            }
            pairingAttempts[peer] = (attempt.count + 1, attempt.since)
            struct PairRequest: Decodable { let token: String? }
            guard let payload = try? JSONDecoder().decode(PairRequest.self, from: request.body),
                  let session = pairing.pair(token: payload.token) else {
                return .error("配对码不正确或已失效", status: 401)
            }
            recordActivity(request, session: session, peer: peer)
            return stateResponse(newSession: session)
        }
        guard request.path == "/api/command" else { return .error("接口不存在", status: 404) }
        guard let session = pairing.session(from: request.headers["cookie"]) else {
            return .error("连接已失效，请重新扫描二维码", status: 401)
        }
        guard let command = try? JSONDecoder().decode(RemoteCommand.self, from: request.body) else {
            return .error("不支持的遥控指令", status: 400)
        }
        recordActivity(request, session: session, peer: peer)
        do {
            return .json(try await controller.perform(command, session: session))
        } catch let error as RemoteError {
            return .error(error.message, status: error.status)
        } catch {
            return .error(error.localizedDescription, status: 500)
        }
    }

    private func stateResponse(newSession: String? = nil) -> HTTPResponse {
        var response = HTTPResponse.json(controller.state())
        if let session = newSession {
            response.extraHeaders["Set-Cookie"] = "macremote=\(session); Path=/; HttpOnly; SameSite=Strict; Max-Age=86400"
        }
        return response
    }

    private func validHost(_ value: String?) -> Bool {
        guard let value, let url = URL(string: "http://\(value)"), let host = url.host,
              url.port == Int(port), url.path.isEmpty else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host == "::1"
            || LANAddress.current().contains(where: { $0.address == host })
    }
}

@MainActor private final class HTTPConnection {
    let id = UUID()
    var onRequest: (@MainActor (HTTPRequest) -> Void)?
    var onClose: (@MainActor () -> Void)?
    let peer: String
    private let connection: NWConnection
    private var received = Data()
    private var finished = false
    private var closed = false
    private var timeout: DispatchWorkItem?

    init(connection: NWConnection) {
        self.connection = connection
        if case let .hostPort(host, _) = connection.endpoint { peer = "\(host)" } else { peer = "unknown" }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                if case .failed = state { self?.close() }
                if case .cancelled = state { self?.close() }
            }
        }
        connection.start(queue: .main)
        let timeout = DispatchWorkItem { [weak self] in DispatchQueue.main.async { self?.close() } }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, complete, error in
            DispatchQueue.main.async {
                self?.received(data, complete: complete, error: error)
            }
        }
    }

    private func received(_ data: Data?, complete: Bool, error: NWError?) {
        guard !finished, !closed else { return }
        if let data { received.append(data) }
        do {
            if let request = try HTTPRequest.parse(received) {
                finished = true
                onRequest?(request)
            } else if complete || error != nil { close() }
            else { receive() }
        } catch {
            finished = true
            respond(.error("无效或过大的 HTTP 请求", status: error as? HTTPParseError == .tooLarge ? 413 : 400))
        }
    }

    func respond(_ response: HTTPResponse) {
        guard !closed else { return }
        connection.send(content: response.data, completion: .contentProcessed { [weak self] _ in
            DispatchQueue.main.async { self?.close() }
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        timeout?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?()
    }
}
