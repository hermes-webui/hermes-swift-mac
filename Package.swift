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
        .executableTarget(
            name: "HermesAgent",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/HermesAgent"
        ),
        .testTarget(
            name: "HermesAgentTests",
            dependencies: [],
            path: "Tests/HermesAgentTests"
        ),
    ]
)
