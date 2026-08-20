// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@Suite("Backend architecture fitness")
struct BackendArchitectureFitnessTests {
    @Test("the mandatory backend contract has no transport or Positronic host types")
    func mandatoryContractIsBackendNeutral() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = rootURL.appendingPathComponent("Sources/GnosticCore/Runtime/AscendantBackend.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        for forbidden in [
            "import Axoloty",
            "import PositronicKit",
            "CommunicationManager",
            "NetworkCatalog",
            "CoatyObject",
            "AgentInstance(",
            "PositronicKit.Thread",
        ] {
            #expect(!source.contains(forbidden), "The mandatory contract mentions forbidden type '\(forbidden)'.")
        }

        let wiringSources = [
            "Sources/GnosticCore/Runtime/NodeRuntimeAdapters.swift",
            "Sources/GnosticCore/Adapters/PositronicAscendantAdapter.swift",
            "Sources/GnosticCore/Runtime/LegacyAscendantAdapterBridge.swift",
        ]
        for relativePath in wiringSources {
            let wiring = try String(
                contentsOf: rootURL.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for forbidden in ["CommunicationManager", "NetworkCatalog", "CoatyObject"] {
                #expect(!wiring.contains(forbidden), "Backend wiring leaks forbidden host type '\(forbidden)' in \(relativePath).")
            }
        }

        let nodeRuntime = try String(
            contentsOf: rootURL.appendingPathComponent("Sources/GnosticCore/Runtime/NodeRuntime.swift"),
            encoding: .utf8
        )
        #expect(!nodeRuntime.contains("if backend.kind == \"positronic\""))
        #expect(!nodeRuntime.contains("PositronicBackendHostServices"))
        #expect(nodeRuntime.contains("BackendWorkspaceDiscoveryCapability"))
    }

    @Test("the exception registry keeps the compatibility bridge narrow")
    func compatibilityExceptionIsExplicit() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Documentation/Architecture/exceptions.json")
        let data = try Data(contentsOf: sourceURL)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let exceptions = try #require(object["exceptions"] as? [[String: Any]])
        let compatibility = try #require(exceptions.first { $0["id"] as? String == "RESET-004-legacy-adapter-bridge" })
        #expect((compatibility["issue"] as? String) == "#138")
        #expect((compatibility["scope"] as? String)?.contains("*") == false)
        #expect((compatibility["reconsiderWhen"] as? String)?.contains("RESET-006") == true)
    }
}
