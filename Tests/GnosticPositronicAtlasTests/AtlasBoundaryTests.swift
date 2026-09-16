// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@Suite("Atlas boundary")
struct AtlasBoundaryTests {
    @Test("Atlas sources stay free of transport and native backend vocabulary")
    func atlasSourcesStayBackendNeutral() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = repositoryRoot.appendingPathComponent("Sources/GnosticPositronicAtlas")

        let forbiddenImports = ["import Axoloty", "import AxolotyMQTT", "import PositronicKit"]
        let forbiddenVocabulary = ["AgentInstance"]

        for relativePath in try FileManager.default.subpathsOfDirectory(atPath: sourceRoot.path)
            where relativePath.hasSuffix(".swift") {
            let source = try String(
                contentsOf: sourceRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for forbidden in forbiddenImports {
                #expect(
                    !source.contains(forbidden),
                    "Atlas must not import backend or transport modules: \(relativePath)"
                )
            }
            for forbidden in forbiddenVocabulary {
                #expect(
                    !source.contains(forbidden),
                    "Atlas must not expose native backend vocabulary: \(relativePath)"
                )
            }
        }
    }

    @Test("Registry-backed vocabulary stays out of the optional Atlas target")
    func atlasTargetRemainsOptionalAndCoreNeutral() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let package = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        #expect(package.contains(".library(name: \"GnosticPositronicAtlas\", targets: [\"GnosticPositronicAtlas\"])"))

        let coreImports = try swiftSources(in: repositoryRoot.appendingPathComponent("Sources/GnosticCore"))
        for (relativePath, source) in coreImports {
            #expect(
                !source.contains("import GnosticPositronicAtlas"),
                "Core must not import Atlas: \(relativePath)"
            )
        }
    }

    private func swiftSources(in root: URL) throws -> [(String, String)] {
        try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .map { relativePath in
                (relativePath, try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8))
            }
    }
}
