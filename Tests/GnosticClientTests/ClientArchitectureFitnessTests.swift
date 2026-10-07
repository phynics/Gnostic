// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@Suite("GnosticClient architecture fitness")
struct ClientArchitectureFitnessTests {
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The consumer-facing files that P7-003 moved out of `GnosticCore` into
    /// the `GnosticClient` target.
    private static let consumerFiles = [
        "GnosticConsumerSession.swift",
        "GnosticConsumerCalls.swift",
        "GnosticTurnClient.swift",
        "GnosticTurnClientError.swift",
        "GnosticTimelineClient.swift",
        "GnosticTimelineClientError.swift",
        "GnosticWorkspaceClient.swift",
        "GnosticWorkspaceClientError.swift",
        "GnosticDiagnosticsClient.swift",
        "GnosticDiagnosticsClientError.swift",
    ]

    @Test("the consumer SDK lives in GnosticClient and not in GnosticCore")
    func consumerSDKIsExtracted() throws {
        let clientRoot = Self.root.appendingPathComponent("Sources/GnosticClient")
        let clientFiles = try FileManager.default.subpathsOfDirectory(atPath: clientRoot.path)
        for consumerFile in Self.consumerFiles {
            #expect(
                clientFiles.contains(consumerFile),
                "Sources/GnosticClient must own \(consumerFile)."
            )
        }

        let coreServices = try FileManager.default.subpathsOfDirectory(
            atPath: Self.root.appendingPathComponent("Sources/GnosticCore/Services").path
        )
        for consumerFile in Self.consumerFiles {
            #expect(
                !coreServices.contains(consumerFile),
                "Sources/GnosticCore/Services must no longer own \(consumerFile)."
            )
        }
        // The shared catalog and subscription machinery keeps its accepted
        // owner in the kernel, so the consumer SDK can depend on it.
        for sharedService in [
            "GnosticSubscription.swift",
            "NetworkCatalog.swift",
            "GnosticRawWireEvent.swift",
        ] {
            #expect(
                coreServices.contains(sharedService),
                "GnosticCore must keep the shared runtime service \(sharedService)."
            )
        }
    }

    @Test("GnosticClient declares no backend dependency")
    func clientDeclaresNoBackendDependency() throws {
        let package = try String(
            contentsOf: Self.root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let clientTarget = try #require(
            Self.targetBlock(named: "GnosticClient", in: package),
            "Package.swift must declare a GnosticClient target."
        )
        #expect(
            clientTarget.contains("\"GnosticProtocol\""),
            "GnosticClient must build on the neutral wire contract."
        )
        #expect(
            clientTarget.contains("\"GnosticCore\""),
            "GnosticClient must build on the kernel it consumes."
        )
        for forbidden in [
            "PositronicKit", "PKContracts", "GnosticHost", "GnosticKit",
            "GnosticCLI", "GnosticLettaBackend", "GnosticPositronicAtlas",
        ] {
            #expect(
                !clientTarget.contains(forbidden),
                "GnosticClient must not depend on \(forbidden)."
            )
        }

        let clientSources = try Self.sources(in: "Sources/GnosticClient")
        #expect(!clientSources.isEmpty, "GnosticClient must have sources.")
        let backendImports = clientSources.filter {
            $0.text.contains("import PositronicKit") || $0.text.contains("import PKContracts")
        }
        #expect(
            backendImports.isEmpty,
            "GnosticClient must not import a backend: \(backendImports.map(\.path))."
        )
    }

    @Test("the kernel never depends on the consumer SDK")
    func kernelDoesNotDependOnClient() throws {
        let package = try String(
            contentsOf: Self.root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let coreTarget = try #require(
            Self.targetBlock(named: "GnosticCore", in: package),
            "Package.swift must declare a GnosticCore target."
        )
        #expect(
            !coreTarget.contains("\"GnosticClient\""),
            "GnosticCore must not depend on GnosticClient."
        )

        let coreImportsClient = try Self.sources(in: "Sources/GnosticCore")
            .contains { $0.text.contains("import GnosticClient") }
        #expect(
            !coreImportsClient,
            "GnosticCore sources must not import GnosticClient."
        )
    }

    /// Extracts one `.target(name: "...")` block, matching the boundary the
    /// documentation checker uses.
    private static func targetBlock(named name: String, in package: String) -> String? {
        guard let start = package.range(of: ".target(\n            name: \"\(name)\"")?.lowerBound else {
            return nil
        }
        let endMarker = "\n        ),"
        guard let end = package.range(of: endMarker, range: start..<package.endIndex)?.upperBound else {
            return nil
        }
        return String(package[start..<end])
    }

    private static func sources(in relativePath: String) throws -> [(path: String, text: String)] {
        let sourceRoot = root.appendingPathComponent(relativePath)
        return try FileManager.default.subpathsOfDirectory(atPath: sourceRoot.path)
            .filter { $0.hasSuffix(".swift") }
            .map { path in
                (
                    path,
                    try String(
                        contentsOf: sourceRoot.appendingPathComponent(path),
                        encoding: .utf8
                    )
                )
            }
    }
}
