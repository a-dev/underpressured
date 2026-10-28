// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "upbench",
    platforms: [.macOS("27.0")],
    dependencies: [.package(path: "../../Packages/UnderpressuredKit")],
    targets: [
        .executableTarget(
            name: "upbench",
            dependencies: [
                .product(name: "ImageEngine", package: "UnderpressuredKit"),
                .product(name: "UnderpressuredCore", package: "UnderpressuredKit"),
                .product(name: "UnderpressuredApplication", package: "UnderpressuredKit")
            ],
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("StrictConcurrency")]
        )
    ]
)
