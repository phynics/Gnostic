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
        .library(name: "GnosticPositronicAtlas", targets: ["GnosticPositronicAtlas"]),
        .executable(name: "gnostic-runner", targets: ["GnosticRunner"]),
        .executable(name: "gnostic", targets: ["GnosticCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/phynics/Axoloty.git", exact: "0.6.2"),
        .package(url: "https://github.com/phynics/PositronicKit.git", exact: "5.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    ],
    targets: [
        .target(
            name: "GnosticCore",
            dependencies: [
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "PositronicKit", package: "PositronicKit"),
                .product(name: "PKContracts", package: "PositronicKit"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "GnosticPositronicAtlas",
            dependencies: [
                "GnosticCore",
                .product(name: "PositronicKit", package: "PositronicKit"),
            ]
        ),
        .testTarget(
            name: "GnosticCoreTests",
            dependencies: [
                "GnosticCore",
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "PositronicKit", package: "PositronicKit"),
                .product(name: "PKContracts", package: "PositronicKit"),
            ]
        ),
        .executableTarget(
            name: "GnosticRunner",
            dependencies: [
                "GnosticCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Axoloty", package: "Axoloty"),
            ]
        ),
        .testTarget(
            name: "GnosticRunnerTests",
            dependencies: [
                "GnosticRunner",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "PKContracts", package: "PositronicKit"),
            ]
        ),
        .executableTarget(
            name: "GnosticCLI",
            dependencies: [
                "GnosticCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "PositronicKit", package: "PositronicKit"),
                .product(name: "PKContracts", package: "PositronicKit"),
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
                .product(name: "PKContracts", package: "PositronicKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
