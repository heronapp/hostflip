// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "hostflip",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "HostflipCore", targets: ["HostflipCore"]),
        .library(name: "HostflipXPC", targets: ["HostflipXPC"]),
        .executable(name: "Hostflip", targets: ["Hostflip"]),
        .executable(name: "hostflipd", targets: ["hostflipd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5"),
    ],
    targets: [
        .target(name: "HostflipCore"),
        .target(name: "HostflipXPC", dependencies: ["HostflipCore"]),
        .executableTarget(
            name: "Hostflip",
            dependencies: [
                "HostflipCore",
                "HostflipXPC",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .executableTarget(name: "hostflipd", dependencies: ["HostflipCore", "HostflipXPC"]),
        .testTarget(name: "HostflipCoreTests", dependencies: ["HostflipCore"]),
        .testTarget(name: "HostflipXPCTests", dependencies: ["HostflipCore", "HostflipXPC"]),
        .testTarget(name: "HostflipTests", dependencies: ["Hostflip", "HostflipCore", "HostflipXPC"]),
    ]
)
