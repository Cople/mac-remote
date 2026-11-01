import CoreGraphics

public struct RemoteShortcut: Equatable {
    public let keyCode: UInt16
    public let modifiers: CGEventFlags
    public let label: String
}

extension RemoteKey {
    public func shortcut(forApp bundleIdentifier: String?) -> RemoteShortcut {
        if self == .fullscreen {
            if bundleIdentifier == "com.tencent.tenvideo" {
                return RemoteShortcut(keyCode: 3, modifiers: .maskSecondaryFn, label: "fn F")
            }
            if bundleIdentifier == "com.iqiyi.player" {
                return RemoteShortcut(keyCode: 3, modifiers: .maskCommand, label: "⌘ F")
            }
        }
        if bundleIdentifier == "com.youku.mac" {
            if self == .previous {
                return RemoteShortcut(keyCode: 123, modifiers: .maskAlternate, label: "⌥ ←")
            }
            if self == .next {
                return RemoteShortcut(keyCode: 124, modifiers: .maskAlternate, label: "⌥ →")
            }
        }
        let labels = ["space": "Space", "right": "→", "left": "←", "up": "↑", "down": "↓",
                      "escape": "Esc", "previous": "[", "next": "]", "fullscreen": "F", "danmaku": "D"]
        return RemoteShortcut(keyCode: keyCode, modifiers: [], label: labels[rawValue]!)
    }

    public static func shortcutLabels(forApp bundleIdentifier: String?) -> [String: String] {
        Dictionary(uniqueKeysWithValues: [RemoteKey.previous, .next, .fullscreen].map {
            ($0.rawValue, $0.shortcut(forApp: bundleIdentifier).label)
        })
    }
}
