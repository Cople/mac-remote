import AppKit
import ApplicationServices
import Combine
import CoreImage.CIFilterBuiltins
import MacRemoteCore
import Network

@MainActor final class AppModel: ObservableObject {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    @Published var addresses = LANAddress.current()
    @Published var selectedAddress = ""
    @Published var running = false
    @Published var error: String?
    @Published var accessibility = AXIsProcessTrusted()
    @Published private(set) var connectedDevices: [ConnectedDevice] = []
    @Published var copied = false
    @Published var port: UInt16 = 0
    @Published private(set) var pairingRevision = 0
    @Published var pairingEnabled = UserDefaults.standard.object(forKey: "pairingEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(pairingEnabled, forKey: "pairingEnabled")
            server?.setPairingEnabled(pairingEnabled)
            pairingRevision += 1
            copied = false
        }
    }
    let controller = MacController()
    private var server: RemoteServer!
    private var timer: Timer?
    private let monitor = NWPathMonitor()

    var phoneConnected: Bool { !connectedDevices.isEmpty }

    var connectedDevicesDescription: String {
        connectedDevices.isEmpty ? "暂无连接设备" : connectedDevices.map(\.summary).joined(separator: "\n\n")
    }

    var connectionURL: String? {
        guard running, !selectedAddress.isEmpty else { return nil }
        let address = "http://\(selectedAddress):\(port)/"
        return pairingEnabled ? address + "#token=\(server.pairing.token)" : address
    }

    var pairingCode: String { server.pairing.token }

    var displayAddress: String { selectedAddress.isEmpty ? "等待网络连接" : "http://\(selectedAddress):\(port)" }

    init() {
        selectedAddress = addresses.first?.address ?? ""
        let webRoot = AppResources.bundle.url(forResource: "Web", withExtension: nil)!
        server = RemoteServer(controller: controller, webRoot: webRoot, pairingEnabled: pairingEnabled)
        server.onChange = { [weak self] in self?.refreshServer() }
        server.onError = { [weak self] message in self?.error = message }
        monitor.pathUpdateHandler = { [weak self] _ in DispatchQueue.main.async { self?.refreshAddresses() } }
        monitor.start(queue: DispatchQueue(label: "app.cople.MacRemote.path"))
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.accessibility = AXIsProcessTrusted()
                self.refreshAddresses()
                self.refreshServer()
            }
        }
        start()
    }

    func start() {
        error = nil
        do { try server.start() }
        catch { self.error = error.localizedDescription }
    }

    func retry() {
        server.stop()
        start()
    }

    func stop() {
        timer?.invalidate()
        monitor.cancel()
        server.stop()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        accessibility = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if !accessibility, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func copyAddress() {
        guard let connectionURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(connectionURL, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.copied = false }
    }

    func openRemote() {
        guard let connectionURL, let url = URL(string: connectionURL) else { return }
        NSWorkspace.shared.open(url)
    }

    func rotatePairing() {
        server.rotatePairing()
        pairingRevision += 1
        copied = false
    }

    func qrCode() -> NSImage? {
        guard let connectionURL else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(connectionURL.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 7, y: 7)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func refreshServer() {
        running = server.running
        port = server.port
        connectedDevices = server.connectedDevices()
        if running { error = nil }
    }

    private func refreshAddresses() {
        let current = LANAddress.current()
        if current != addresses { addresses = current }
        if !current.contains(where: { $0.address == selectedAddress }) { selectedAddress = current.first?.address ?? "" }
    }
}
