// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "agentdeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AgentDeckBridge",
            path: "Sources/AgentDeckBridge",
            // Swift 5 language mode: strict concurrency isn't worth fighting in an MVP.
            // Revisit when this becomes HerdrKit and gets shared with app targets.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AgentDeckBridgeTests",
            dependencies: ["AgentDeckBridge"],
            path: "Tests/AgentDeckBridgeTests"
        )
    ]
)
