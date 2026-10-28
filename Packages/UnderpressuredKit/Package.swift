// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "UnderpressuredKit",
    defaultLocalization: "en",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .library(name: "UnderpressuredCore", targets: ["UnderpressuredCore"]),
        .library(name: "UnderpressuredApplication", targets: ["UnderpressuredApplication"]),
        .library(name: "MacPlatform", targets: ["MacPlatform"]),
        .library(name: "ImageEngine", targets: ["ImageEngine"]),
        .library(name: "LocalFileSystem", targets: ["LocalFileSystem"]),
        .library(name: "AppModel", targets: ["AppModel"])
    ],
    targets: [
        .binaryTarget(name: "UpJpegli", path: "../../Vendor/UpJpegli.xcframework"),
        .binaryTarget(name: "UpCodecs", path: "../../Vendor/UpCodecs.xcframework"),
        .target(
            name: "UnderpressuredCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "UnderpressuredApplication",
            dependencies: ["UnderpressuredCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MacPlatform",
            dependencies: ["UnderpressuredCore", "UnderpressuredApplication"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ImageEngine",
            dependencies: ["UnderpressuredCore", "UnderpressuredApplication", "UpJpegli", "UpCodecs"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .target(
            name: "LocalFileSystem",
            dependencies: ["UnderpressuredCore", "UnderpressuredApplication"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AppModel",
            dependencies: ["UnderpressuredCore", "UnderpressuredApplication"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Headless soak harness driven by scripts/soak.sh (plan 6.5). Not part of any test run.
        .executableTarget(
            name: "SoakHarness",
            dependencies: ["UnderpressuredCore", "UnderpressuredApplication", "MacPlatform", "ImageEngine", "LocalFileSystem"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "QueueBenchmark",
            dependencies: ["UnderpressuredCore", "UnderpressuredApplication"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "QueueTestSupport",
            dependencies: ["UnderpressuredCore", "UnderpressuredApplication", "LocalFileSystem"],
            path: "Tests/QueueTestSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AppModelTests",
            dependencies: ["AppModel", "UnderpressuredCore", "UnderpressuredApplication", "QueueTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LocalFileSystemTests",
            dependencies: ["LocalFileSystem", "UnderpressuredCore", "UnderpressuredApplication", "QueueTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "UnderpressuredCoreTests",
            dependencies: ["UnderpressuredCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "UnderpressuredApplicationTests",
            dependencies: ["UnderpressuredCore", "UnderpressuredApplication", "QueueTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MacPlatformTests",
            dependencies: ["UnderpressuredCore", "UnderpressuredApplication", "MacPlatform"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["UnderpressuredCore", "UnderpressuredApplication", "ImageEngine", "LocalFileSystem", "QueueTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ImageEngineTests",
            dependencies: ["ImageEngine", "UnderpressuredCore", "UnderpressuredApplication"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
