// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Gnostic",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "GnosticCore", targets: ["GnosticCore"]),
        .executable(name: "gnostic-runner", targets: ["GnosticRunner"]),
        .executable(name: "gnostic", targets: ["GnosticCLI"]),
    ],
    dependencies: [
        // Temporary development override for GNO-advonce (#64): the public
        // discover-responder API is merged on Axoloty main but not released.
        .package(url: "https://github.com/phynics/Axoloty.git", revision: "f18e867c7ac4affd65f0c12708ed928afbeb475f"),
        .package(url: "https://github.com/phynics/PositronicKit.git", exact: "3.4.2"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    ],
    targets: [
        .target(
            name: "GnosticCore",
            dependencies: [
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "PositronicKit", package: "PositronicKit"),
                .product(name: "PKPrompt", package: "PositronicKit"),
                .product(name: "PKShared", package: "PositronicKit"),
                .product(name: "PKUtilities", package: "PositronicKit"),
            ]
        ),
        .testTarget(
            name: "GnosticCoreTests",
            dependencies: [
                "GnosticCore",
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "PositronicKit", package: "PositronicKit"),
                .product(name: "PKPrompt", package: "PositronicKit"),
                .product(name: "PKShared", package: "PositronicKit"),
            ]
        ),
        .executableTarget(
            name: "GnosticRunner",
            dependencies: [
                "GnosticCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "PositronicKit", package: "PositronicKit"),
                .product(name: "PKShared", package: "PositronicKit"),
            ]
        ),
        .testTarget(
            name: "GnosticRunnerTests",
            dependencies: [
                "GnosticRunner",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Axoloty", package: "Axoloty"),
            ]
        ),
        .executableTarget(
            name: "GnosticCLI",
            dependencies: [
                "GnosticCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "PositronicKit", package: "PositronicKit"),
                .product(name: "PKShared", package: "PositronicKit"),
                .product(name: "PKOpenAIProvider", package: "PositronicKit"),
                .product(name: "PKOpenRouterProvider", package: "PositronicKit"),
                .product(name: "PKOllamaProvider", package: "PositronicKit"),
                .product(name: "PKAnthropicProvider", package: "PositronicKit"),
            ]
        ),
        .testTarget(
            name: "GnosticCLITests",
            dependencies: [
                "GnosticCLI",
                "GnosticCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Axoloty", package: "Axoloty"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
