// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodeCat",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CodeCatCore"),
        .executableTarget(name: "CodeCatApp", dependencies: ["CodeCatCore"]),
        .executableTarget(name: "codecat-hook", dependencies: ["CodeCatCore"]),
        .testTarget(name: "CodeCatCoreTests", dependencies: ["CodeCatCore"]),
    ]
)
