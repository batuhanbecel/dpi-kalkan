// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DPIKalkan",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "KalkanCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DPIKalkan",
            dependencies: ["KalkanCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "kalkan-cli",
            dependencies: ["KalkanCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KalkanCoreTests",
            dependencies: ["KalkanCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
