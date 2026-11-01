import AppKit
import ApplicationServices
import MacRemoteCore

@MainActor enum MenuShortcutReader {
    struct Item: Encodable {
        let path: [String]
        let character: String?
        let keyCode: Int?
        let modifiers: Int?
        let glyph: Int?
    }

    struct Snapshot: Encodable {
        let application: String
        let bundleIdentifier: String?
        let fullScreenButtonAvailable: Bool
        let zoomButtonAvailable: Bool
        let fullScreen: Bool?
        let shortcuts: [Item]
    }

    private static func value(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &result) == .success else { return nil }
        return result
    }

    private static func element(_ parent: AXUIElement, _ name: CFString) -> AXUIElement? {
        guard let result = value(parent, name), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(result, to: AXUIElement.self)
    }

    static func snapshot() throws -> Snapshot {
        guard AXIsProcessTrusted() else { throw RemoteError("当前命令进程没有辅助功能权限，无法读取应用菜单", status: 403) }
        guard let running = NSWorkspace.shared.frontmostApplication else { throw RemoteError("没有前台应用") }
        let application = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        guard let menu = element(application, kAXMenuBarAttribute as CFString) else {
            throw RemoteError("当前应用没有公开可读取的菜单栏")
        }
        var shortcuts: [Item] = []
        var visited = 0
        func walk(_ item: AXUIElement, path: [String], depth: Int) {
            guard depth < 8, visited < 500 else { return }
            visited += 1
            let title = value(item, kAXTitleAttribute as CFString) as? String ?? ""
            let currentPath = title.isEmpty ? path : path + [title]
            if value(item, kAXRoleAttribute as CFString) as? String == kAXMenuItemRole as String {
                let character = value(item, kAXMenuItemCmdCharAttribute as CFString) as? String
                let key = (value(item, kAXMenuItemCmdVirtualKeyAttribute as CFString) as? NSNumber)?.intValue
                let glyph = (value(item, kAXMenuItemCmdGlyphAttribute as CFString) as? NSNumber)?.intValue
                if character?.isEmpty == false || (key ?? 0) > 0 || (glyph ?? 0) > 0 {
                    shortcuts.append(Item(path: currentPath, character: character, keyCode: key,
                                          modifiers: (value(item, kAXMenuItemCmdModifiersAttribute as CFString) as? NSNumber)?.intValue,
                                          glyph: glyph))
                }
            }
            for child in value(item, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? [] {
                walk(child, path: currentPath, depth: depth + 1)
            }
        }
        walk(menu, path: [], depth: 0)
        let window = element(application, kAXFocusedWindowAttribute as CFString)
        return Snapshot(application: running.localizedName ?? "未知应用", bundleIdentifier: running.bundleIdentifier,
                        fullScreenButtonAvailable: window.flatMap { element($0, kAXFullScreenButtonAttribute as CFString) } != nil,
                        zoomButtonAvailable: window.flatMap { element($0, kAXZoomButtonAttribute as CFString) } != nil,
                        fullScreen: window.flatMap { value($0, "AXFullScreen" as CFString) as? Bool },
                        shortcuts: shortcuts)
    }
}
