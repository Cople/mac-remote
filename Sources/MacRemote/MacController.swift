import AppKit
import ApplicationServices
import IOKit.hidsystem
import MacRemoteCore

@MainActor final class MacController: RemoteControlling {
    var beforeKeyboardInput: (() -> Void)?
    private let audio = AudioController()
    private let notifications = NotificationController()
    private var lease = HoldLease()
    private var holdTimer: Timer?
    private var nextRepeat = Date.distantFuture
    private var target: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var safetyObservers: [NSObjectProtocol] = []
    private let source = CGEventSource(stateID: .hidSystemState)
    private var preparingInput = false
    private var iconApp: String?
    private var cachedAppIcon: String?

    init() {
        rememberFrontmost()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.releaseAllKeys()
                self?.rememberFrontmost()
            }
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            safetyObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.releaseAllKeys() }
            })
        }
    }

    func state() -> RemoteState {
        let snapshot = audio.snapshot()
        let app = currentTarget
        return RemoteState(name: Host.current().localizedName ?? "Mac", version: AppModel.version,
                           accessibility: AXIsProcessTrusted(), volume: snapshot.volume, muted: snapshot.muted,
                           volumeControllable: snapshot.controllable, frontmostApp: app?.localizedName ?? "Mac",
                           holding: lease.owner != nil, frontmostAppIcon: appIcon(for: app),
                           shortcutLabels: RemoteKey.shortcutLabels(forApp: app?.bundleIdentifier),
                           frontmostWindowTitle: MenuShortcutReader.windowTitle(for: app))
    }

    private var currentTarget: NSRunningApplication? {
        let foreground = NSWorkspace.shared.frontmostApplication
        return foreground?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? target : foreground
    }

    private func appIcon(for app: NSRunningApplication?) -> String? {
        guard let app else { return nil }
        let identity = "\(app.processIdentifier):\(app.launchDate?.timeIntervalSince1970 ?? 0)"
        if identity == iconApp { return cachedAppIcon }
        iconApp = identity
        cachedAppIcon = nil
        guard let icon = app.icon,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        if let png = bitmap.representation(using: .png, properties: [:]) {
            cachedAppIcon = "data:image/png;base64," + png.base64EncodedString()
        }
        return cachedAppIcon
    }

    func perform(_ command: RemoteCommand, session: String) async throws -> RemoteState {
        var message: String?
        switch command {
        case .key(let key):
            try requireAccessibility()
            guard lease.owner == nil else { throw RemoteError("请先松开长按按钮", status: 409) }
            try await prepareKeyboardTarget()
            if key == .up { try audio.step(0.1) }
            else if key == .down { try audio.step(-0.1) }
            else { try postKey(key, down: true); try postKey(key, down: false) }
        case .holdStart:
            try requireAccessibility()
            guard lease.owner == nil else { throw RemoteError("已有设备正在长按", status: 409) }
            try await prepareKeyboardTarget()
            guard lease.begin(owner: session, now: Date()) else { throw RemoteError("长按操作冲突", status: 409) }
            do { try postKey(.right, down: true) }
            catch { lease.end(); throw error }
            nextRepeat = Date().addingTimeInterval(0.35)
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.lease.isExpired(now: Date()) || !AXIsProcessTrusted() {
                        self.releaseAllKeys()
                    } else if Date() >= self.nextRepeat {
                        try? self.postKey(.right, down: true, repeatEvent: true)
                        self.nextRepeat = Date().addingTimeInterval(0.08)
                    }
                }
            }
        case .holdHeartbeat:
            guard lease.renew(owner: session, now: Date()) else {
                if lease.isExpired(now: Date()) { releaseAllKeys() }
                throw RemoteError("长按已结束，请松开后重试", status: 409)
            }
        case .holdEnd:
            if lease.owner != nil && lease.owner != session { throw RemoteError("另一台设备正在长按", status: 409) }
            if lease.end(owner: session) { finishHold() }
        case .media(let key):
            try requireAccessibility()
            let codes: [String: Int32] = ["playPause": 16, "next": 17, "previous": 18]
            try postMediaKey(codes[key]!)
        case .volume(let value): try audio.setVolume(value)
        case .volumeStep(let value): try audio.step(value)
        case .mute: try audio.toggleMute()
        case .clearNotifications:
            try requireAccessibility()
            releaseAllKeys()
            message = try await notifications.clear()
        }
        var result = state()
        result.message = message
        return result
    }

    func releaseAllKeys() {
        if lease.end() { finishHold() }
    }

    private func finishHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        try? postKey(.right, down: false)
    }

    private func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw RemoteError("请在 Mac 菜单栏中点击「授予辅助功能权限」，开启 Mac Remote 后重试", status: 403)
        }
    }

    private func rememberFrontmost() {
        if let current = NSWorkspace.shared.frontmostApplication,
           current.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            target = current
        }
    }

    private func prepareKeyboardTarget() async throws {
        guard !preparingInput else { throw RemoteError("正在切换到目标应用，请重试", status: 409) }
        preparingInput = true
        defer { preparingInput = false }
        beforeKeyboardInput?()
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let target, !target.isTerminated {
            target.activate(options: [.activateIgnoringOtherApps])
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func postKey(_ key: RemoteKey, down: Bool, repeatEvent: Bool = false) throws {
        let shortcut = key.shortcut(forApp: currentTarget?.bundleIdentifier)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: down) else {
            throw RemoteError("无法创建键盘事件", status: 503)
        }
        let pressedShiftKey: CGKeyCode? = CGEventSource.keyState(.combinedSessionState, key: 56) ? 56
            : (CGEventSource.keyState(.combinedSessionState, key: 60) ? 60 : nil)
        event.flags = shortcut.eventFlags(pressedShiftKey: pressedShiftKey)
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatEvent ? 1 : 0)
        event.post(tap: .cghidEventTap)
    }

    private func postMediaKey(_ code: Int32) throws {
        for down in [true, false] {
            let flags: NSEvent.ModifierFlags = down ? .init(rawValue: 0xA00) : .init(rawValue: 0xB00)
            let data = (Int(code) << 16) | (down ? 0xA00 : 0xB00)
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                                context: nil, subtype: 8, data1: data, data2: -1)?.cgEvent else {
                throw RemoteError("无法创建媒体按键事件", status: 503)
            }
            event.post(tap: .cghidEventTap)
        }
    }
}
