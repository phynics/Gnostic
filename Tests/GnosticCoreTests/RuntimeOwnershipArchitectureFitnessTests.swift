// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing
@testable import GnosticCore

@Suite("Runtime ownership architecture fitness")
struct RuntimeOwnershipArchitectureFitnessTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("effect scopes are not service locators or domain authorities")
    func scopeHasNoForbiddenAuthority() throws {
        let source = try String(contentsOf: root.appendingPathComponent("Sources/GnosticCore/Runtime/RuntimeEffectScope.swift"), encoding: .utf8)
        for forbidden in ["Container", ".resolve(", "serviceLookup", "services[", "[String:", "NSClassFromString", "dlopen", "Bundle(", "UserDefaults", "ProcessInfo", "NodeManifest", "AscendantBackend", "NodeRegistry", "WorkspaceProvider", "import Axoloty", "import PositronicKit", "import PKContracts"] {
            #expect(!source.contains(forbidden), "RuntimeEffectScope contains forbidden authority: \(forbidden)")
        }
    }

    @Test("Core never depends on the optional Atlas target")
    func coreDoesNotImportAtlas() throws {
        let sourceRoot = root.appendingPathComponent("Sources/GnosticCore")
        let paths = try FileManager.default.subpathsOfDirectory(atPath: sourceRoot.path).filter { $0.hasSuffix(".swift") }
        for path in paths {
            let source = try String(contentsOf: sourceRoot.appendingPathComponent(path), encoding: .utf8)
            #expect(!source.contains("import GnosticPositronicAtlas"), "Core imports Atlas in \(path)")
        }
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        for (target, declaration) in [("GnosticCore", ".target("), ("GnosticCLI", ".executableTarget("), ("GnosticRunner", ".executableTarget(")] {
            let start = try #require(package.range(of: "\(declaration)\n            name: \"\(target)\""))
            let tail = package[start.lowerBound...]
            let end = tail.firstRange(of: "\n        ),")?.upperBound ?? tail.endIndex
            #expect(!tail[..<end].contains("GnosticPositronicAtlas"), "\(target) depends on Atlas")
        }
    }

    @Test("scope owners and names stay explicit and static")
    func scopeOwnersArePinned() throws {
        let sourceRoot = root.appendingPathComponent("Sources/GnosticCore")
        var actual: Set<String> = []
        for relativePath in try FileManager.default.subpathsOfDirectory(atPath: sourceRoot.path)
            where relativePath.hasSuffix(".swift") {
            let source = try String(contentsOf: sourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
            for line in source.split(separator: "\n") where line.contains("RuntimeEffectScope(name:") {
                let prefix = "RuntimeEffectScope(name: \""
                #expect(!line.contains(prefix + "\\("), "Scope name is dynamic in \(relativePath)")
                guard let start = line.range(of: prefix),
                      let end = line[start.upperBound...].firstIndex(of: "\"") else {
                    Issue.record("Could not parse a static scope name in \(relativePath): \(line)")
                    continue
                }
                actual.insert("\(relativePath)::\(line[start.upperBound..<end])")
            }
        }

        let expected: Set<String> = [
            "Services/GnosticSubscription.swift::gnostic-subscription",
            "Runtime/AscendantTurnCoordinator.swift::turn-observation",
            "Runtime/NodeRuntimeHost.swift::node-runtime-host",
            "Runtime/NodeRuntimeHost.swift::turn-update-publisher",
            "Runtime/NodeRuntimeHost.swift::network-resolution",
            "Runtime/NodeTransport.swift::node-transport",
            "Runtime/NodeTransport.swift::transport-registrations",
            "Runtime/NodeTransport.swift::transport-responders",
            "Runtime/NodeTransport.swift::transport-permission",
            "Runtime/NodeTransport.swift::transport-advertisements",
        ]
        #expect(actual == expected)
    }

    @Test("runtime identity snapshots do not carry effect diagnostics")
    func identitySnapshotHasNoEffectState() throws {
        let source = try String(contentsOf: root.appendingPathComponent("Sources/GnosticCore/Runtime/NodeRuntimeTypes.swift"), encoding: .utf8)
        let declaration = try #require(source.range(of: "public struct NodeRuntimeSnapshot"))
        let declarationSource = source[declaration.lowerBound...]
        let closing = try #require(declarationSource.range(of: "\n}\n\n/// Gnostic's stable"))
        let body = declarationSource[..<closing.upperBound]
        #expect(!body.contains("RuntimeEffectSnapshot"))
        #expect(!body.contains("RuntimeEffectInfo"))

        let sourceRoot = root.appendingPathComponent("Sources/GnosticCore")
        for relativePath in try FileManager.default.subpathsOfDirectory(atPath: sourceRoot.path)
            where relativePath.hasSuffix(".swift") {
            let lowercasedPath = relativePath.lowercased()
            guard relativePath.hasPrefix("Objects/")
                || lowercasedPath.contains("projection")
                || lowercasedPath.contains("catalog")
                || lowercasedPath.contains("advertisement") else { continue }
            let projection = try String(contentsOf: sourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
            #expect(!projection.contains("RuntimeEffectSnapshot"), "Effect diagnostics leaked into \(relativePath)")
        }
    }

    @Test("terminal observation stays generic")
    func observationContractHasNoAtlasVocabulary() throws {
        for path in ["Sources/GnosticCore/Runtime/TerminalTurnObservation.swift", "Sources/GnosticCore/Runtime/AscendantTurnCoordinator.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            for forbidden in ["Atlas", "Shard", "revision", "prompt", "PositronicKit", "PKContracts"] {
                #expect(!source.localizedCaseInsensitiveContains(forbidden), "\(path) contains \(forbidden)")
            }
        }
    }
}
