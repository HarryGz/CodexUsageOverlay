// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexUsageOverlay",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CodexUsageCore", targets: ["CodexUsageCore"]),
        .executable(name: "CodexUsageOverlay", targets: ["CodexUsageOverlay"])
    ],
    targets: [
        .target(name: "CodexUsageCore"),
        .executableTarget(name: "CodexUsageOverlay", dependencies: ["CodexUsageCore"]),
        .testTarget(name: "CodexUsageCoreTests", dependencies: ["CodexUsageCore"])
    ],
    swiftLanguageVersions: [.v5]
)
