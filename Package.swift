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
        // The app product is named HostflipApp (not Hostflip) so its build artifact cannot
        // collide with the `hostflip` CLI binary on case-insensitive APFS; the bundle still
        // ships the binary as Contents/MacOS/Hostflip (renamed by scripts/build-app.sh).
        .executable(name: "HostflipApp", targets: ["Hostflip"]),
        .executable(name: "hostflip", targets: ["HostflipCLI"]),
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
        .executableTarget(name: "HostflipCLI", dependencies: ["HostflipCore", "HostflipXPC"]),
        .executableTarget(name: "hostflipd", dependencies: ["HostflipCore", "HostflipXPC"]),
        .testTarget(name: "HostflipCoreTests", dependencies: ["HostflipCore"]),
        .testTarget(name: "HostflipCLITests", dependencies: ["HostflipCLI", "HostflipCore", "HostflipXPC"]),
        .testTarget(name: "HostflipXPCTests", dependencies: ["HostflipCore", "HostflipXPC"]),
        .testTarget(name: "HostflipTests", dependencies: ["Hostflip", "HostflipCore", "HostflipXPC"]),
    ]
)
