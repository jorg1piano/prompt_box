// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PromptBox",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "PromptBoxCore"),
        .executableTarget(name: "PromptBox", dependencies: ["PromptBoxCore"]),
        .testTarget(name: "PromptBoxCoreTests", dependencies: ["PromptBoxCore"]),
    ],
    swiftLanguageModes: [.v5]
)
