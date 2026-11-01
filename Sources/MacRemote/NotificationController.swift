import AppKit
import ApplicationServices
import MacRemoteCore

@MainActor final class NotificationController {
    private let queue = DispatchQueue(label: "app.cople.MacRemote.notifications", qos: .userInitiated)
    private var busy = false

    func clear() async throws -> String {
        guard !busy else { throw RemoteError("正在清理通知，请稍候", status: 409) }
        busy = true
        defer { busy = false }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try Self.clearOnQueue()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    nonisolated private static func clearOnQueue() throws -> String {
        guard AXIsProcessTrusted() else { throw RemoteError("请先在 Mac 上授予 Mac Remote 辅助功能权限", status: 403) }
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
            throw RemoteError("未找到 macOS 通知中心", status: 503)
        }
        let root = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.4)
        let deadline = Date().addingTimeInterval(6)
        var cleared = 0

        // Banners and Notification Center expose clear/close buttons or custom AX actions.
        // Re-read after every action: clearing a group invalidates its old AX elements.
        while Date() < deadline, cleared < 80 {
            guard let candidate = findClearAction(root, deadline: deadline) else { break }
            guard AXUIElementPerformAction(candidate.element, candidate.action as CFString) == .success else { break }
            cleared += 1
            Thread.sleep(forTimeInterval: 0.08)
        }
        if cleared > 0 { return "已清除可访问的通知（\(cleared) 次清除操作）" }
        // Deliberately report unsupported layouts instead of claiming notifications were cleared.
        throw RemoteError("未找到可清除的通知。若通知仍存在，请在 Mac 上展开通知中心后重试；当前系统布局可能不支持自动清除。", status: 409)
    }

    nonisolated private static func findClearAction(_ root: AXUIElement, deadline: Date) -> (element: AXUIElement, action: String)? {
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while let (element, depth) = pending.popLast(), visited < 600, Date() < deadline {
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.2)
            let role = string(element, kAXRoleAttribute)
            let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].map { string(element, $0) }
            let clearLabels = ["clear all", "clear all notifications", "close", "close notification", "clear", "dismiss",
                               "清除全部", "全部清除", "清除所有通知", "清除全部通知", "清除", "关闭", "关闭通知",
                               "清除所有通知事項", "清除全部通知事項", "全部清除通知", "關閉", "關閉通知"]
            if role == kAXButtonRole as String, labels.contains(where: { clearLabels.contains($0.lowercased()) }) {
                return (element, kAXPressAction as String)
            }
            var rawActions: CFArray?
            if AXUIElementCopyActionNames(element, &rawActions) == .success, let actions = rawActions as? [String] {
                for action in actions {
                    var description: CFString?
                    AXUIElementCopyActionDescription(element, action as CFString, &description)
                    let label = (description as String? ?? "").lowercased()
                    if clearLabels.contains(label) || ["clear all", "clear all notifications", "清除全部", "全部清除", "清除所有通知"].contains(where: { label.hasPrefix($0) }) {
                        return (element, action)
                    }
                }
            }
            if depth < 14 {
                var rawChildren: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &rawChildren) == .success,
                   let children = rawChildren as? [AXUIElement] {
                    pending += children.reversed().map { ($0, depth + 1) }
                }
            }
        }
        return nil
    }

    nonisolated private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }
}
