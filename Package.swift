// swift-tools-version: 6.4

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
        .library(name: "GnosticRLM", targets: ["GnosticRLM"]),
        .library(name: "GnosticLettaBackend", targets: ["GnosticLettaBackend"]),
        .library(name: "GnosticACPAscendant", targets: ["GnosticACPAscendant"]),
        .library(name: "GnosticRLMGuile", targets: ["GnosticRLMGuile"]),
        .library(name: "GnosticRLMChibi", targets: ["GnosticRLMChibi"]),
        .executable(name: "gnostic-rlm-benchmark", targets: ["GnosticRLMBenchmark"]),
        .executable(name: "gnostic-rlm-scenario", targets: ["GnosticRLMScenario"]),
        .executable(name: "gnostic-runner", targets: ["GnosticRunner"]),
        .executable(name: "gnostic", targets: ["GnosticCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/phynics/Axoloty.git", exact: "0.7.0"),
        .package(url: "https://github.com/phynics/PositronicKit.git", exact: "6.1.0-rc.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/aptove/swift-sdk.git", exact: "0.1.16"),
    ],
    targets: [
        .target(
            name: "GnosticCore",
            dependencies: [
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "AxolotyMQTT", package: "Axoloty"),
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
                .product(name: "PKContracts", package: "PositronicKit"),
            ]
        ),
        .target(
            name: "GnosticRLM"
        ),
        .target(
            name: "GnosticLettaBackend",
            dependencies: [
                "GnosticCore",
            ]
        ),
        .target(
            name: "GnosticACPAscendant",
            dependencies: [
                "GnosticCore",
                .product(name: "ACP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "GnosticACPAscendantTests",
            dependencies: [
                "GnosticACPAscendant",
                "GnosticCore",
            ]
        ),
        .target(
            name: "GnosticLettaTestSupport",
            dependencies: [
                "GnosticCore",
                "GnosticLettaBackend",
            ],
            path: "Tests/Support/GnosticLettaTestSupport"
        ),
        .target(
            name: "GnosticRLMProcessWorker",
            dependencies: [
                "GnosticRLM",
            ]
        ),
        .target(
            name: "GnosticRLMGuile",
            dependencies: [
                "GnosticRLM",
                "GnosticRLMProcessWorker",
            ],
            resources: [.copy("Resources/worker.scm")]
        ),
        .target(
            name: "GnosticRLMChibi",
            dependencies: [
                "GnosticRLM",
                "GnosticRLMProcessWorker",
            ],
            resources: [.copy("Resources/worker.scm")]
        ),
        .executableTarget(
            name: "GnosticRLMBenchmark",
            dependencies: [
                "GnosticRLM",
                "GnosticRLMGuile",
                "GnosticRLMChibi",
                "GnosticRLMProcessWorker",
            ]
        ),
        .executableTarget(
            name: "GnosticRLMScenario",
            dependencies: [
                "GnosticRLM",
                "GnosticRLMGuile",
                "GnosticRLMChibi",
                "GnosticRLMProcessWorker",
            ]
        ),
        .testTarget(
            name: "GnosticRLMScenarioTests",
            dependencies: [
                "GnosticRLM",
            ]
        ),
        .testTarget(
            name: "GnosticRLMBenchmarkTests",
            dependencies: [
                "GnosticRLMBenchmark",
            ]
        ),
        .testTarget(
            name: "GnosticPositronicAtlasTests",
            dependencies: [
                "GnosticPositronicAtlas",
                "GnosticCore",
                .product(name: "PositronicKit", package: "PositronicKit"),
                .product(name: "PKContracts", package: "PositronicKit"),
            ]
        ),
        .testTarget(
            name: "GnosticCoreTests",
            dependencies: [
                "GnosticCore",
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "AxolotyWire", package: "Axoloty"),
                .product(name: "PositronicKit", package: "PositronicKit"),
                .product(name: "PKContracts", package: "PositronicKit"),
            ]
        ),
        .testTarget(
            name: "GnosticRLMTests",
            dependencies: [
                "GnosticRLM",
            ]
        ),
        .testTarget(
            name: "GnosticLettaBackendTests",
            dependencies: [
                "GnosticLettaBackend",
                "GnosticCore",
                "GnosticLettaTestSupport",
            ]
        ),
        .testTarget(
            name: "GnosticRLMGuileTests",
            dependencies: [
                "GnosticRLMGuile",
                "GnosticRLM",
            ]
        ),
        .testTarget(
            name: "GnosticRLMChibiTests",
            dependencies: [
                "GnosticRLMChibi",
                "GnosticRLM",
            ]
        ),
        .testTarget(
            name: "GnosticRLMWorkerParityTests",
            dependencies: [
                "GnosticRLMGuile",
                "GnosticRLMChibi",
                "GnosticRLM",
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
                "GnosticLettaBackend",
                "GnosticACPAscendant",
                "GnosticRLM",
                "GnosticRLMGuile",
                "GnosticRLMChibi",
                "GnosticRLMProcessWorker",
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
                "GnosticLettaBackend",
                "GnosticLettaTestSupport",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "PKContracts", package: "PositronicKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
