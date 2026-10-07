// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@Suite("Backend composition architecture fitness")
struct CompositionArchitectureFitnessTests {
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The stable kind identifier is a constant, not a construction, so the
    /// CLI may keep it as a default flag value outside the composition source.
    private static let allowedRegistryReference = "AscendantAdapterRegistry.positronicKind"

    @Test("GnosticHost owns the Ascendant registry in the composition source")
    func onlyCompositionReferencesRegistry() throws {
        let sourceRoot = Self.root.appendingPathComponent("Sources/GnosticHost")
        var referencingPaths: [String] = []
        for relativePath in try FileManager.default.subpathsOfDirectory(atPath: sourceRoot.path)
            where relativePath.hasSuffix(".swift") {
            let source = try String(
                contentsOf: sourceRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            // Strip the sanctioned constant, then any surviving mention of the
            // type name -- a constructor, an initializer, a type annotation, or
            // a memberwise `.init()` -- means a second registry path exists.
            let residue = source.replacingOccurrences(of: Self.allowedRegistryReference, with: "")
            if residue.contains("AscendantAdapterRegistry") {
                referencingPaths.append(relativePath)
            }
        }

        #expect(
            referencingPaths == ["BackendComposition.swift"],
            "GnosticHost must reach AscendantAdapterRegistry only through BackendComposition.swift; found: \(referencingPaths)."
        )
    }

    @Test("GnosticCLI keeps no private Ascendant registry")
    func cliKeepsNoPrivateRegistry() throws {
        let sourceRoot = Self.root.appendingPathComponent("Sources/GnosticCLI")
        var referencingPaths: [String] = []
        for relativePath in try FileManager.default.subpathsOfDirectory(atPath: sourceRoot.path)
            where relativePath.hasSuffix(".swift") {
            let source = try String(
                contentsOf: sourceRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            let residue = source.replacingOccurrences(of: Self.allowedRegistryReference, with: "")
            if residue.contains("AscendantAdapterRegistry") {
                referencingPaths.append(relativePath)
            }
        }

        #expect(
            referencingPaths == [],
            "GnosticCLI must compose through GnosticHost and must not construct AscendantAdapterRegistry; found: \(referencingPaths)."
        )
    }

    @Test("serve obtains its adapters from the composition source")
    func serveUsesComposition() throws {
        let source = try String(
            contentsOf: Self.root.appendingPathComponent("Sources/GnosticCLI/Commands/ServeCommand.swift"),
            encoding: .utf8
        )
        #expect(source.contains("BackendComposition.default.makeAdapters(for: plan.ascendants)"))
        #expect(!source.contains("AscendantAdapterRegistry"))
        #expect(!source.contains("registerBackend("))
        #expect(!source.contains("registerPositronicBackend("))
    }

    @Test("GnosticKit depends on GnosticCore only and imports no backend")
    func kitDependencyBoundary() throws {
        let package = try String(contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let kitTarget = try #require(
            Self.targetBlock(named: "GnosticKit", in: package),
            "Package.swift must declare a GnosticKit target."
        )
        #expect(
            kitTarget.contains("\"GnosticCore\""),
            "GnosticKit must build on GnosticCore."
        )
        for forbidden in ["PositronicKit", "PKContracts"] {
            #expect(
                !kitTarget.contains(forbidden),
                "GnosticKit must not depend on \(forbidden)."
            )
        }
        // ADR 0013: the kit sits above the kernel and below modules, so
        // GnosticCore is the only Gnostic target it may depend on.
        for forbidden in [
            "GnosticCLI", "GnosticHost", "GnosticPositronicAtlas",
            "GnosticLettaBackend", "GnosticACPAscendant", "GnosticRLM",
            "GnosticRLMGuile", "GnosticRLMChibi", "GnosticRLMProcessWorker",
        ] {
            #expect(
                !kitTarget.contains("\"\(forbidden)\""),
                "GnosticKit must not depend on \(forbidden)."
            )
        }

        let kitSources = try Self.sources(in: "Sources/GnosticKit")
        #expect(!kitSources.isEmpty, "GnosticKit must have sources.")
        let backendImports = kitSources.filter {
            $0.text.contains("import PositronicKit") || $0.text.contains("import PKContracts")
        }
        #expect(
            backendImports.isEmpty,
            "GnosticKit must not import a backend: \(backendImports.map(\.path))."
        )
    }

    @Test("the composition layer does not invert its dependencies")
    func layerDependencies() throws {
        let package = try String(contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)

        let coreTarget = try #require(
            Self.targetBlock(named: "GnosticCore", in: package),
            "Package.swift must declare a GnosticCore target."
        )
        #expect(
            !coreTarget.contains("GnosticHost"),
            "GnosticCore must not depend on GnosticHost."
        )
        // ADR 0013: the kernel stays below the platform kit.
        #expect(
            !coreTarget.contains("GnosticKit"),
            "GnosticCore must not depend on GnosticKit."
        )
        // ADR 0013 / epic #460: the consumer SDK sits above the kernel, so the
        // kernel never reaches back up into it.
        #expect(
            !coreTarget.contains("GnosticClient"),
            "GnosticCore must not depend on GnosticClient."
        )

        let hostTarget = try #require(
            Self.targetBlock(named: "GnosticHost", in: package),
            "Package.swift must declare a GnosticHost target."
        )
        #expect(
            !hostTarget.contains("GnosticCLI"),
            "GnosticHost must not depend on GnosticCLI."
        )
        #expect(
            hostTarget.contains("\"GnosticCore\""),
            "GnosticHost must build on GnosticCore."
        )

        let coreImportsHost = try Self.sources(in: "Sources/GnosticCore")
            .contains { $0.text.contains("import GnosticHost") }
        #expect(!coreImportsHost, "GnosticCore sources must not import GnosticHost.")

        let coreImportsKit = try Self.sources(in: "Sources/GnosticCore")
            .contains { $0.text.contains("import GnosticKit") }
        #expect(!coreImportsKit, "GnosticCore sources must not import GnosticKit.")

        let coreImportsClient = try Self.sources(in: "Sources/GnosticCore")
            .contains { $0.text.contains("import GnosticClient") }
        #expect(!coreImportsClient, "GnosticCore sources must not import GnosticClient.")

        let hostImportsCLI = try Self.sources(in: "Sources/GnosticHost")
            .contains { $0.text.contains("import GnosticCLI") }
        #expect(!hostImportsCLI, "GnosticHost sources must not import GnosticCLI.")
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
