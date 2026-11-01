import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var model: AppModel!
    private var popoverFocusObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model = AppModel()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = RemixIcon.image("remote-control-line")
            button.setAccessibilityLabel("Mac Remote")
            button.toolTip = "Mac Remote"
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuBarView(model: model))
        model.controller.beforeKeyboardInput = { [weak self] in self?.popover.performClose(nil) }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            if #available(macOS 14, *) { NSApp.activate() }
            else { NSApp.activate(ignoringOtherApps: true) }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverDidShow(_ notification: Notification) {
        guard let window = popover.contentViewController?.view.window else { return }
        window.makeKey()
        popoverFocusObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in self?.popover.performClose(nil) }
    }

    func popoverWillClose(_ notification: Notification) {
        if let observer = popoverFocusObserver {
            NotificationCenter.default.removeObserver(observer)
            popoverFocusObserver = nil
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        if popover?.isShown == true { popover.performClose(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { model?.stop() }
}

if CommandLine.arguments.contains("--list-shortcuts") {
    Task { @MainActor in
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(MenuShortcutReader.snapshot())
            FileHandle.standardOutput.write(data + Data("\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("读取快捷键失败：\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
