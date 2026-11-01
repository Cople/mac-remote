import XCTest
import CoreGraphics
@testable import MacRemoteCore

final class RemoteShortcutTests: XCTestCase {
    func testPlayerSpecificShortcuts() {
        let tencent = RemoteKey.fullscreen.shortcut(forApp: "com.tencent.tenvideo")
        XCTAssertEqual(tencent.keyCode, 3)
        XCTAssertEqual(tencent.modifiers, .maskSecondaryFn)
        XCTAssertEqual(tencent.label, "fn F")
        let iqiyi = RemoteKey.fullscreen.shortcut(forApp: "com.iqiyi.player")
        XCTAssertEqual(iqiyi.keyCode, 3)
        XCTAssertEqual(iqiyi.modifiers, .maskCommand)
        XCTAssertEqual(iqiyi.label, "⌘ F")
        let previous = RemoteKey.previous.shortcut(forApp: "com.youku.mac")
        let next = RemoteKey.next.shortcut(forApp: "com.youku.mac")
        XCTAssertEqual(previous.keyCode, 123)
        XCTAssertEqual(next.keyCode, 124)
        XCTAssertEqual(previous.modifiers, .maskAlternate)
        XCTAssertEqual(next.modifiers, .maskAlternate)
        XCTAssertEqual(RemoteKey.shortcutLabels(forApp: "com.youku.mac"), ["previous": "⌥ ←", "next": "⌥ →", "fullscreen": "F"])
    }

    func testOtherCommandsKeepTheirOriginalKeyCodesAndModifiers() {
        for bundle in [nil, "com.apple.Safari", "com.tencent.tenvideo", "com.iqiyi.player", "com.youku.mac"] as [String?] {
            for key in [RemoteKey.space, .right, .left, .up, .down, .escape, .danmaku] {
                let shortcut = key.shortcut(forApp: bundle)
                XCTAssertEqual(shortcut.keyCode, key.keyCode)
                XCTAssertEqual(shortcut.modifiers, [])
            }
        }
        XCTAssertEqual(RemoteKey.shortcutLabels(forApp: "com.apple.Safari"), ["previous": "[", "next": "]", "fullscreen": "F"])
    }
}
