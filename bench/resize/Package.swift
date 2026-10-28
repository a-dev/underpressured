// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "resize",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "resize",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("StrictConcurrency")]
        )
    ]
)
