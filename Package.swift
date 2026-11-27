// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacVPN",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MacVPNCore"),
        .executableTarget(name: "MacVPN", dependencies: ["MacVPNCore"]),
        .executableTarget(name: "MacVPNTunnelHelper", dependencies: ["MacVPNCore"])
    ]
)
