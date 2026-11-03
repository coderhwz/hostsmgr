// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HostsMgr",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "HostsMgr", targets: ["HostsMgr"])],
    targets: [
        .target(name: "HostsCore"),
        .executableTarget(name: "HostsMgr", dependencies: ["HostsCore"]),
        .testTarget(name: "HostsCoreTests", dependencies: ["HostsCore"])
    ]
)
