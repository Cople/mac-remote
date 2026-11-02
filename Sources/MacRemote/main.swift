import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}

@MainActor struct MacRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: delegate.model)
        } label: {
            Image(nsImage: RemixIcon.image("remote-control-line"))
                .accessibilityLabel("Mac Remote")
                .help("Mac Remote")
        }
        .menuBarExtraStyle(.window)
    }
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
    MacRemoteApp.main()
}
