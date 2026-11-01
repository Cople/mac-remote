import Foundation
import Security

public enum RemoteKey: String, Codable, CaseIterable {
    case space, right, left, up, down, escape, previous, next, fullscreen, danmaku

    public var keyCode: UInt16 {
        switch self {
        case .space: return 49
        case .right: return 124
        case .left: return 123
        case .up: return 126
        case .down: return 125
        case .escape: return 53
        case .previous: return 33
        case .next: return 30
        case .fullscreen: return 3
        case .danmaku: return 2
        }
    }
}

public enum RemoteCommand: Decodable, Equatable {
    case key(RemoteKey)
    case holdStart
    case holdHeartbeat
    case holdEnd
    case media(String)
    case volume(Double)
    case volumeStep(Double)
    case mute
    case clearNotifications

    private struct Payload: Decodable {
        let action: String
        let key: RemoteKey?
        let value: Double?
        let media: String?
    }

    public init(from decoder: Decoder) throws {
        let payload = try Payload(from: decoder)
        switch payload.action {
        case "key":
            guard let key = payload.key else { throw Self.invalid(decoder) }
            self = .key(key)
        case "holdStart": self = .holdStart
        case "holdHeartbeat": self = .holdHeartbeat
        case "holdEnd": self = .holdEnd
        case "media":
            guard let media = payload.media, ["playPause", "previous", "next"].contains(media) else {
                throw Self.invalid(decoder)
            }
            self = .media(media)
        case "volume":
            guard let value = payload.value, value.isFinite, (0...1).contains(value) else {
                throw Self.invalid(decoder)
            }
            self = .volume(value)
        case "volumeStep":
            guard let value = payload.value, [-0.1, 0.1].contains(value) else { throw Self.invalid(decoder) }
            self = .volumeStep(value)
        case "mute": self = .mute
        case "clearNotifications": self = .clearNotifications
        default: throw Self.invalid(decoder)
        }
    }

    private static func invalid(_ decoder: Decoder) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "无效的遥控指令"))
    }
}

public struct RemoteState: Codable {
    public var name: String
    public var version: String
    public var accessibility: Bool
    public var volume: Double?
    public var muted: Bool?
    public var volumeControllable: Bool
    public var frontmostApp: String
    public var frontmostAppIcon: String?
    public var holding: Bool
    public var message: String?
    public var shortcutLabels: [String: String]

    public init(name: String, version: String, accessibility: Bool, volume: Double?, muted: Bool?,
                volumeControllable: Bool, frontmostApp: String, holding: Bool,
                frontmostAppIcon: String? = nil, message: String? = nil, shortcutLabels: [String: String] = [:]) {
        self.name = name
        self.version = version
        self.accessibility = accessibility
        self.volume = volume
        self.muted = muted
        self.volumeControllable = volumeControllable
        self.frontmostApp = frontmostApp
        self.frontmostAppIcon = frontmostAppIcon
        self.holding = holding
        self.message = message
        self.shortcutLabels = shortcutLabels
    }
}

public final class PairingStore {
    public private(set) var token = PairingStore.randomPairingCode()
    public private(set) var isEnabled: Bool
    private var sessions: [String: Date] = [:]
    private let lifetime: TimeInterval = 24 * 60 * 60
    public var now: () -> Date = Date.init

    public init(enabled: Bool = true) { isEnabled = enabled }

    public func rotate() {
        let previous = token
        repeat { token = Self.randomPairingCode() } while token == previous
        sessions.removeAll()
    }

    public func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        rotate()
    }

    public func pair(token candidate: String? = nil) -> String? {
        if isEnabled {
            guard let candidate, Self.constantTimeEqual(candidate, token) else { return nil }
        }
        sessions = sessions.filter { now().timeIntervalSince($0.value) < lifetime }
        // Keep a small bounded set; re-pairing the oldest phone is always possible.
        if sessions.count >= 16, let oldest = sessions.min(by: { $0.value < $1.value })?.key {
            sessions.removeValue(forKey: oldest)
        }
        let session = Self.randomToken()
        sessions[session] = now()
        return session
    }

    public func session(from cookie: String?) -> String? {
        guard let cookie else { return nil }
        let candidates = cookie.split(separator: ";").compactMap { item -> String? in
            let parts = item.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            return parts.count == 2 && parts[0] == "macremote" ? String(parts[1]) : nil
        }
        guard candidates.count == 1, let session = candidates.first, let created = sessions[session],
              now().timeIntervalSince(created) < lifetime else { return nil }
        return session
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomPairingCode() -> String {
        var number: UInt32 = 0
        // Rejection sampling keeps every six-digit code equally likely, including leading zeroes.
        let limit = UInt32.max - UInt32.max % 1_000_000
        repeat {
            precondition(SecRandomCopyBytes(kSecRandomDefault, MemoryLayout.size(ofValue: number), &number) == errSecSuccess)
        } while number >= limit
        return String(format: "%06u", number % 1_000_000)
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// The key is leased to one phone; a lost connection must never leave it pressed.
public struct HoldLease {
    public private(set) var owner: String?
    public private(set) var deadline: Date?
    public private(set) var startedAt: Date?
    public let heartbeatTimeout: TimeInterval = 1.5
    public let maximumDuration: TimeInterval = 30

    public init() {}

    public mutating func begin(owner: String, now: Date) -> Bool {
        guard self.owner == nil else { return false }
        self.owner = owner
        startedAt = now
        deadline = now.addingTimeInterval(heartbeatTimeout)
        return true
    }

    public mutating func renew(owner: String, now: Date) -> Bool {
        guard self.owner == owner, !isExpired(now: now) else { return false }
        deadline = min(now.addingTimeInterval(heartbeatTimeout), startedAt!.addingTimeInterval(maximumDuration))
        return true
    }

    public func isExpired(now: Date) -> Bool {
        guard let deadline else { return false }
        return now >= deadline
    }

    @discardableResult
    public mutating func end(owner: String? = nil) -> Bool {
        guard self.owner != nil, owner == nil || self.owner == owner else { return false }
        self.owner = nil
        deadline = nil
        startedAt = nil
        return true
    }
}
