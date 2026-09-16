// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@Suite("Backend composition architecture fitness")
struct CompositionArchitectureFitnessTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The one registry reference the CLI may keep outside the composition
    /// source: the stable kind identifier used as a default flag value. It is a
    /// constant, not a construction.
    private static let allowedRegistryReference = "AscendantAdapterRegistry.positronicKind"

    @Test("GnosticCLI names the Ascendant registry only in the composition source")
    func onlyCompositionReferencesRegistry() throws {
        let sourceRoot = root.appendingPathComponent("Sources/GnosticCLI")
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
            referencingPaths == ["Config/BackendComposition.swift"],
            "GnosticCLI must reach AscendantAdapterRegistry only through BackendComposition.swift; found: \(referencingPaths)."
        )
    }

    @Test("serve obtains its adapters from the composition source")
    func serveUsesComposition() throws {
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/GnosticCLI/Commands/ServeCommand.swift"),
            encoding: .utf8
        )
        #expect(source.contains("BackendComposition.default.makeAdapters()"))
        #expect(!source.contains("AscendantAdapterRegistry"))
        #expect(!source.contains("registerBackend("))
        #expect(!source.contains("registerPositronicBackend("))
    }
}
