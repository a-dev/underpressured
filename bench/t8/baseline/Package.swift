// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "QueueBaseline",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "QueueBaseline", targets: ["QueueBaseline"])],
    targets: [
        .target(name: "UnderpressuredCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "QueueBaseline", dependencies: ["UnderpressuredCore"], swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
