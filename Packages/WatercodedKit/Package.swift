// swift-tools-version: 6.2
import PackageDescription

// Module graph (arrows point at dependencies):
//
//   WatercodedUI ─┬─► WatercodedDesign ─► Meniscus
//                 ├─► Orchestrator ─┬─► AgentKit ─► ProcessKit ─► WatercodedCore
//                 │                 ├─► ProcessKit (refreshes the login-shell PATH)
//                 │                 └─► GitKit ───► ProcessKit
//                 └─► WatercodedCore
//
//   Providers (one module each, depend only on AgentKit + WatercodedCore):
//     ClaudeCodeProvider, ReplayProvider
//
//   Services plugged into the Orchestrator through protocols:
//     OnDeviceIntelligence (titles and summaries with Apple's on-device model)
//
// The app target is the composition root: it registers providers with a
// `ProviderRegistry` and hands it to the `Workspace`. Nothing else imports a provider.

let strictness: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny")
]

/// UI modules default to the main actor (SE-0466).
let uiSettings: [SwiftSetting] = strictness + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "WatercodedKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WatercodedCore", targets: ["WatercodedCore"]),
        .library(name: "ProcessKit", targets: ["ProcessKit"]),
        .library(name: "AgentKit", targets: ["AgentKit"]),
        .library(name: "GitKit", targets: ["GitKit"]),
        .library(name: "Orchestrator", targets: ["Orchestrator"]),
        .library(name: "Meniscus", targets: ["Meniscus"]),
        .library(name: "WatercodedDesign", targets: ["WatercodedDesign"]),
        .library(name: "WatercodedUI", targets: ["WatercodedUI"]),
        .library(name: "ClaudeCodeProvider", targets: ["ClaudeCodeProvider"]),
        .library(name: "ReplayProvider", targets: ["ReplayProvider"]),
        .library(name: "OnDeviceIntelligence", targets: ["OnDeviceIntelligence"]),
        .executable(name: "watercoded-relay", targets: ["watercoded-relay"])
    ],
    targets: [
        // MARK: Foundation layers

        .target(name: "WatercodedCore", swiftSettings: strictness),
        .target(name: "ProcessKit", dependencies: ["WatercodedCore"], swiftSettings: strictness),
        .executableTarget(name: "watercoded-relay", dependencies: ["ProcessKit"], swiftSettings: strictness),
        .target(name: "AgentKit", dependencies: ["WatercodedCore", "ProcessKit"], swiftSettings: strictness),
        .target(name: "GitKit", dependencies: ["WatercodedCore", "ProcessKit"], swiftSettings: strictness),
        .target(
            name: "Orchestrator",
            dependencies: ["WatercodedCore", "ProcessKit", "AgentKit", "GitKit"],
            swiftSettings: strictness
        ),

        // MARK: Providers

        .target(
            name: "ClaudeCodeProvider",
            dependencies: ["WatercodedCore", "AgentKit", "ProcessKit"],
            swiftSettings: strictness
        ),
        .target(name: "ReplayProvider", dependencies: ["WatercodedCore", "AgentKit"], swiftSettings: strictness),

        // MARK: Services

        .target(name: "OnDeviceIntelligence", dependencies: ["Orchestrator"], swiftSettings: strictness),

        // MARK: Presentation

        .target(
            name: "Meniscus",
            resources: [.process("Resources")],
            swiftSettings: strictness
        ),
        .target(
            name: "WatercodedDesign",
            dependencies: ["WatercodedCore", "Meniscus"],
            swiftSettings: uiSettings
        ),
        .target(
            name: "WatercodedUI",
            dependencies: ["WatercodedCore", "AgentKit", "GitKit", "Orchestrator", "Meniscus", "WatercodedDesign"],
            swiftSettings: uiSettings
        ),

        // MARK: Tests

        .testTarget(name: "WatercodedCoreTests", dependencies: ["WatercodedCore"]),
        .testTarget(name: "ProcessKitTests", dependencies: ["ProcessKit", "watercoded-relay"]),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit", "ProcessKit"]),
        .testTarget(
            name: "ClaudeCodeProviderTests",
            dependencies: ["ClaudeCodeProvider", "AgentKit", "WatercodedCore", "ProcessKit", "watercoded-relay"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "OrchestratorTests",
            dependencies: ["Orchestrator", "ReplayProvider", "AgentKit", "GitKit", "WatercodedCore"]
        ),
        .testTarget(name: "MeniscusTests", dependencies: ["Meniscus"]),
        .testTarget(name: "OnDeviceIntelligenceTests", dependencies: ["OnDeviceIntelligence"])
    ]
)
