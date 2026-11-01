import SwiftUI

@MainActor struct MenuBarView: View {
    @ObservedObject var model: AppModel
    private let accent = Color(red: 0.87, green: 0.31, blue: 0.16)
    private let connectedColor = Color(red: 40.0 / 255, green: 205.0 / 255, blue: 65.0 / 255)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                RemixIcon(name: "remote-control-line", size: 22).foregroundStyle(accent)
                Text("Mac Remote").font(.system(size: 16, weight: .semibold))
                Spacer()
                HStack(spacing: 9) {
                    Circle().fill(model.phoneConnected ? connectedColor : .orange).frame(width: 6, height: 6)
                    Text(model.phoneConnected ? "已连接" : "未连接")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .help(model.connectedDevicesDescription)
            }
            .padding(12)

            Divider().opacity(0.65)

            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(.white)
                    if let qr = model.qrCode() {
                        Image(nsImage: qr).interpolation(.none).resizable().scaledToFit().padding(14)
                    } else {
                        VStack(spacing: 10) {
                            RemixIcon(name: "wifi-off-line", size: 30)
                            Text(model.error == nil ? "未连接网络" : "服务未启动").font(.system(size: 11))
                        }
                        .foregroundStyle(.gray)
                    }
                }
                .frame(width: 180, height: 180)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.black.opacity(0.06), lineWidth: 1))

                if model.addresses.count > 1 {
                    Picker("网络接口", selection: $model.selectedAddress) {
                        ForEach(model.addresses) { address in Text(address.label).tag(address.address) }
                    }
                    .labelsHidden().controlSize(.small)
                    .padding(6)
                    .modifier(PopoverHoverBackground())
                }

                HStack(spacing: 10) {
                    Text("配对密钥").font(.system(size: 11))
                    Spacer()
                    if model.pairingEnabled {
                        Button(action: model.rotatePairing) {
                            Text(model.pairingCode)
                                .font(.system(size: 17, weight: .medium, design: .monospaced))
                        }
                        .buttonStyle(PopoverButtonStyle(horizontalPadding: 8))
                        .help("点击重置配对码并断开所有设备")
                        .accessibilityLabel("重置配对码").accessibilityValue(model.pairingCode)
                    }
                    Toggle("配对密钥", isOn: $model.pairingEnabled)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .padding(.horizontal, 5).padding(.vertical, 3)
                }
                .frame(height: 34)

                HStack(spacing: 4) {
                    Text(model.displayAddress).font(.system(size: 11, design: .monospaced)).lineLimit(1).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button(action: model.copyAddress) {
                        RemixIcon(name: model.copied ? "check-line" : "file-copy-line", size: 14)
                            .foregroundStyle(model.copied ? .green : .secondary)
                    }
                    .buttonStyle(PopoverButtonStyle(horizontalPadding: 8)).help("复制连接地址")
                    .accessibilityLabel("复制连接地址").disabled(model.connectionURL == nil)
                    Button(action: model.openRemote) {
                        RemixIcon(name: "external-link-line", size: 14).foregroundStyle(.secondary)
                    }
                    .buttonStyle(PopoverButtonStyle(horizontalPadding: 8)).help("打开网页")
                    .accessibilityLabel("打开网页").disabled(model.connectionURL == nil)
                }
                .padding(.leading, 12)
                .padding(.trailing, 5)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))

                if !model.accessibility {
                    Button(action: model.requestAccessibility) {
                        HStack(spacing: 8) {
                            RemixIcon(name: "lock-line", size: 15).foregroundStyle(accent)
                            Text("授予辅助功能权限").font(.system(size: 11, weight: .medium))
                            Spacer()
                            RemixIcon(name: "arrow-right-up-line", size: 13).foregroundStyle(.secondary)
                        }
                        .padding(22)
                        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(PopoverButtonStyle(horizontalPadding: 0, verticalPadding: 0, cornerRadius: 9))
                }

                if let error = model.error {
                    VStack(spacing: 7) {
                        Text(error).font(.system(size: 10)).foregroundStyle(.red).multilineTextAlignment(.center)
                        Button("重试", action: model.retry)
                            .font(.system(size: 11)).buttonStyle(PopoverButtonStyle())
                    }
                }
            }
            .padding(12)

            Divider().opacity(0.65)

            HStack {
                Text("v\(AppModel.version)").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button { NSApplication.shared.terminate(nil) } label: {
                    HStack(spacing: 5) {
                        RemixIcon(name: "logout-box-r-line", size: 13)
                        Text("退出").font(.system(size: 11))
                    }
                }
                .buttonStyle(PopoverButtonStyle()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .frame(width: 300)
        .background(.regularMaterial)
    }
}

private struct PopoverButtonStyle: ButtonStyle {
    var horizontalPadding: CGFloat = 12
    var verticalPadding: CGFloat = 6
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .modifier(PopoverHoverBackground(isPressed: configuration.isPressed, cornerRadius: cornerRadius))
    }
}

private struct PopoverHoverBackground: ViewModifier {
    var isPressed = false
    var cornerRadius: CGFloat = 6
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(isEnabled ? (isPressed ? 0.12 : isHovered ? 0.07 : 0) : 0),
                        in: RoundedRectangle(cornerRadius: cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onHover { isHovered = $0 }
    }
}
