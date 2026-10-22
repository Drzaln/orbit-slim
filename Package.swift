// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrbitSlim",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OrbitSlim", targets: ["OrbitSlim"]),
        .executable(name: "orbitslimctl", targets: ["orbitslimctl"]),
        .library(name: "OrbitSlimCore", targets: ["OrbitSlimCore"]),
    ],
    targets: [
        .target(
            name: "OrbitSlimCore",
            path: "Sources/OrbitSlimCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "OrbitSlim",
            dependencies: ["OrbitSlimCore"],
            path: "Sources/OrbitSlim",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "orbitslimctl",
            dependencies: ["OrbitSlimCore"],
            path: "Sources/orbitslimctl",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
