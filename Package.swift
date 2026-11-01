// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacRemote",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MacRemote", targets: ["MacRemote"])],
    targets: [
        .target(name: "MacRemoteCore"),
        .executableTarget(
            name: "MacRemote",
            dependencies: ["MacRemoteCore"],
            resources: [.copy("Web"), .copy("Resources")]
        ),
        .testTarget(name: "MacRemoteCoreTests", dependencies: ["MacRemoteCore"])
    ]
)
