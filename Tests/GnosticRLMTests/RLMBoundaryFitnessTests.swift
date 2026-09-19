// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
import GnosticRLM

@Suite("RLM boundary fitness")
struct RLMBoundaryFitnessTests {
    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func targetBlock(named name: String, in package: String) -> String? {
        guard let start = package.range(of: ".target(\n            name: \"\(name)\"")?.lowerBound else {
            return nil
        }
        guard let end = package.range(of: "\n        ),", range: start..<package.endIndex) else {
            return nil
        }
        return String(package[start..<end.upperBound])
    }

    @Test("GnosticRLM is an optional, dependency-free target")
    func dependencyFreeTarget() throws {
        let package = try String(
            contentsOf: Self.repositoryRoot().appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let block = try #require(Self.targetBlock(named: "GnosticRLM", in: package))
        #expect(!block.contains("dependencies"))
        #expect(!block.contains("GnosticCore"))
        #expect(!block.contains("PositronicKit"))
    }

    @Test("harness sources pull in no runtime, process, or provider API")
    func noRuntimeOrProviderDependency() throws {
        let root = Self.repositoryRoot().appendingPathComponent("Sources/GnosticRLM")
        let forbidden = [
            "import Foundation",
            "import CryptoKit",
            "import Network",
            "import GnosticCore",
            "import PositronicKit",
            "import PKContracts",
            "URLSession",
            "posix_spawn",
            "dlopen",
            "Process(",
            "import Guile",
            "import Chibi",
        ]
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(!files.isEmpty)
        for relativePath in files {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for token in forbidden {
                #expect(!source.contains(token), "\(relativePath) must not contain '\(token)'")
            }
        }
    }
}
