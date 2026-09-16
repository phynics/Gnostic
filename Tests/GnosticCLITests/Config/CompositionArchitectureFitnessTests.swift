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

    @Test("GnosticCLI constructs the Ascendant registry only in the composition source")
    func onlyCompositionConstructsRegistry() throws {
        let sourceRoot = root.appendingPathComponent("Sources/GnosticCLI")
        let constructor = "AscendantAdapterRegistry("
        var constructingPaths: [String] = []
        for relativePath in try FileManager.default.subpathsOfDirectory(atPath: sourceRoot.path)
            where relativePath.hasSuffix(".swift") {
            let source = try String(
                contentsOf: sourceRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            if source.contains(constructor) {
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
        #expect(!source.contains("registerBackend("))
        #expect(!source.contains("registerPositronicBackend("))
    }
}
