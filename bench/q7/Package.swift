// swift-tools-version: 6.0
import PackageDescription

// Header/library paths for jpegli are supplied by run.sh (-Xcc/-Xcxx -I, -Xlinker -L/-l).
let package = Package(
    name: "q7",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CJpegli", cxxSettings: [.unsafeFlags(["-std=c++17"])]),
        .executableTarget(
            name: "q7", dependencies: ["CJpegli"],
            swiftSettings: [.swiftLanguageMode(.v6)]),
    ],
    cxxLanguageStandard: .cxx17
)
