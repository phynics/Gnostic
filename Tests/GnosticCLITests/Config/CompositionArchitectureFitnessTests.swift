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

    /// Every way a CLI file could build or install an `AscendantAdapterRegistry`
    /// without going through the composition source. `.init()` spellings are
    /// included so a registry installed via memberwise defaults still trips the
    /// check.
    private static let constructionSignatures = [
        "AscendantAdapterRegistry(",
        "AscendantAdapterRegistry.init(",
        ".ascendants = .init(",
        ".ascendants = AscendantAdapterRegistry",
    ]

    @Test("GnosticCLI constructs the Ascendant registry only in the composition source")
    func onlyCompositionConstructsRegistry() throws {
        let sourceRoot = root.appendingPathComponent("Sources/GnosticCLI")
        var constructingPaths: [String] = []
        for relativePath in try FileManager.default.subpathsOfDirectory(atPath: sourceRoot.path)
            where relativePath.hasSuffix(".swift") {
            let source = try String(
                contentsOf: sourceRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            if Self.constructionSignatures.contains(where: source.contains) {
                constructingPaths.append(relativePath)
            }
        }

        #expect(
            constructingPaths == ["Config/BackendComposition.swift"],
            "GnosticCLI must build the Ascendant registry only in BackendComposition.swift; found: \(constructingPaths)."
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
