// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexSpeed",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CodexSpeed", targets: ["CodexSpeed"])
    ],
    targets: [
        .target(name: "CodexSpeedCore"),
        .executableTarget(name: "CodexSpeed", dependencies: ["CodexSpeedCore"]),
        .executableTarget(
            name: "CoreChecks",
            dependencies: ["CodexSpeedCore"],
            path: "Tests/CodexSpeedCoreTests"
        )
    ]
)
