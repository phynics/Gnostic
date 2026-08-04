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
    ],
    dependencies: [
        .package(url: "https://github.com/phynics/Axoloty.git", exact: "0.3.0"),
        .package(url: "https://github.com/phynics/PositronicKit.git", exact: "3.4.0"),
    ],
    targets: [
        .target(
            name: "GnosticCore",
            dependencies: [
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "PositronicKit", package: "PositronicKit"),
                .product(name: "PKShared", package: "PositronicKit"),
            ]
        ),
        .testTarget(
            name: "GnosticCoreTests",
            dependencies: [
                "GnosticCore",
                .product(name: "Axoloty", package: "Axoloty"),
                .product(name: "PositronicKit", package: "PositronicKit"),
                .product(name: "PKShared", package: "PositronicKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
