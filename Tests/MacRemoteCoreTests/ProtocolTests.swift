import XCTest
@testable import MacRemoteCore

final class ProtocolTests: XCTestCase {
    func testOnlyAllowlistedCommandsCanBeDecoded() throws {
        let valid: [(String, RemoteCommand)] = [
            (#"{"action":"key","key":"space"}"#, .key(.space)),
            (#"{"action":"key","key":"previous"}"#, .key(.previous)),
            (#"{"action":"key","key":"danmaku"}"#, .key(.danmaku)),
            (#"{"action":"holdStart"}"#, .holdStart),
            (#"{"action":"holdHeartbeat"}"#, .holdHeartbeat),
            (#"{"action":"holdEnd"}"#, .holdEnd),
            (#"{"action":"media","media":"next"}"#, .media("next")),
            (#"{"action":"volume","value":0.65}"#, .volume(0.65)),
            (#"{"action":"volumeStep","value":-0.1}"#, .volumeStep(-0.1)),
            (#"{"action":"mute"}"#, .mute),
            (#"{"action":"clearNotifications"}"#, .clearNotifications)
        ]
        for (json, command) in valid { XCTAssertEqual(try decode(json), command) }
        for json in [#"{"action":"shell","value":"open -a Terminal"}"#,
                     #"{"action":"key","key":"commandQ"}"#, #"{"action":"key"}"#,
                     #"{"action":"volume","value":1.1}"#, #"{"action":"volume","value":-0.01}"#,
                     #"{"action":"volumeStep","value":0.5}"#, #"{"action":"media","media":"eject"}"#] {
            XCTAssertThrowsError(try decode(json), json)
        }
    }

    func testVirtualKeyMap() {
        XCTAssertEqual(RemoteKey.allCases.map(\.keyCode), [49, 124, 123, 126, 125, 53, 33, 30, 3, 2])
    }

    func testPairingRequiresTokenAndProducesIndependentSessions() throws {
        let store = PairingStore()
        XCTAssertNotNil(store.token.range(of: "^[0-9]{6}$", options: .regularExpression))
        XCTAssertNil(store.pair(token: "wrong"))
        let first = try XCTUnwrap(store.pair(token: store.token))
        let second = try XCTUnwrap(store.pair(token: store.token))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(store.session(from: "other=1; macremote=\(first)"), first)
        XCTAssertNil(store.session(from: "macremote=bad"))
        XCTAssertNil(store.session(from: "macremote=\(first); macremote=\(second)"))
    }

    func testResetRevokesEveryExistingSessionAndOldLink() throws {
        let store = PairingStore()
        let oldToken = store.token
        let session = try XCTUnwrap(store.pair(token: oldToken))
        store.rotate()
        XCTAssertNotEqual(store.token, oldToken)
        XCTAssertNil(store.pair(token: oldToken))
        XCTAssertNil(store.session(from: "macremote=\(session)"))
    }

    func testSessionExpiresAfter24Hours() throws {
        let store = PairingStore()
        let start = Date(timeIntervalSince1970: 1_000)
        store.now = { start }
        let session = try XCTUnwrap(store.pair(token: store.token))
        store.now = { start.addingTimeInterval(86_399) }
        XCTAssertNotNil(store.session(from: "macremote=\(session)"))
        store.now = { start.addingTimeInterval(86_400) }
        XCTAssertNil(store.session(from: "macremote=\(session)"))
    }

    func testPairingSwitchRevokesSessionsAndRequiresCodeAgain() throws {
        let store = PairingStore()
        XCTAssertTrue(store.isEnabled)
        XCTAssertNil(store.pair())
        let originalCode = store.token
        let protectedSession = try XCTUnwrap(store.pair(token: originalCode))
        store.setEnabled(false)
        XCTAssertFalse(store.isEnabled)
        XCTAssertNil(store.session(from: "macremote=\(protectedSession)"))
        let openSession = try XCTUnwrap(store.pair())
        XCTAssertEqual(store.session(from: "macremote=\(openSession)"), openSession)
        store.setEnabled(false)
        XCTAssertNotNil(store.session(from: "macremote=\(openSession)"), "重复设置不应断开设备")
        let unprotectedCode = store.token
        store.setEnabled(true)
        XCTAssertNil(store.session(from: "macremote=\(openSession)"))
        XCTAssertNil(store.pair())
        XCTAssertNotEqual(store.token, unprotectedCode)
        XCTAssertNotNil(store.pair(token: store.token))
    }

    func testSixDigitCodesStayNumericAndRotateWithoutReusingPreviousCode() {
        let store = PairingStore()
        for _ in 0..<100 {
            let previous = store.token
            store.rotate()
            XCTAssertNotNil(store.token.range(of: "^[0-9]{6}$", options: .regularExpression))
            XCTAssertNotEqual(store.token, previous)
        }
    }

    func testHoldIsOwnedAndExpiresWhenPhoneDisconnects() {
        var lease = HoldLease()
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(lease.begin(owner: "phone-a", now: start))
        XCTAssertFalse(lease.begin(owner: "phone-b", now: start))
        XCTAssertFalse(lease.end(owner: "phone-b"))
        XCTAssertFalse(lease.renew(owner: "phone-b", now: start))
        XCTAssertFalse(lease.isExpired(now: start.addingTimeInterval(1.49)))
        XCTAssertTrue(lease.isExpired(now: start.addingTimeInterval(1.5)))
        XCTAssertFalse(lease.renew(owner: "phone-a", now: start.addingTimeInterval(2)))
        XCTAssertTrue(lease.end())
        XCTAssertNil(lease.owner)
    }

    func testHoldHeartbeatsCannotExceed30Seconds() {
        var lease = HoldLease()
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(lease.begin(owner: "phone", now: start))
        for second in 1...29 { XCTAssertTrue(lease.renew(owner: "phone", now: start.addingTimeInterval(Double(second)))) }
        XCTAssertEqual(lease.deadline, start.addingTimeInterval(30))
        XCTAssertTrue(lease.isExpired(now: start.addingTimeInterval(30)))
        XCTAssertFalse(lease.renew(owner: "phone", now: start.addingTimeInterval(30)))
    }

    private func decode(_ json: String) throws -> RemoteCommand {
        try JSONDecoder().decode(RemoteCommand.self, from: Data(json.utf8))
    }
}
