// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HermesAgent",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            from: "2.0.0"
        ),
    ],
    targets: [
        // WebKit-free policy so `swift test` exercises the real type, not a copy.
        .target(
            name: "HermesAgentCore",
            path: "Sources/HermesAgentCore"
        ),
        .executableTarget(
            name: "HermesAgent",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "HermesAgentCore",
            ],
            path: "Sources/HermesAgent"
        ),
        .testTarget(
            name: "HermesAgentTests",
            dependencies: ["HermesAgentCore"],
            path: "Tests/HermesAgentTests"
        ),
    ]
)
