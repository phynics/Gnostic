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

    @Test("pre-reset Agent and Chat compatibility does not remain in Gnostic seams")
    func preResetCompatibilityIsRemoved() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePaths = [
            "Sources/GnosticCore/Objects/GnosticAscendantObject.swift",
            "Sources/GnosticCore/Runtime/AscendantBackend.swift",
            "Sources/GnosticCore/Runtime/NodeRuntimeAdapters.swift",
            "Sources/GnosticCore/Providers/AgentChatProvider.swift",
            "Sources/GnosticCore/Providers/TimelineManagementProvider.swift",
            "Sources/GnosticCLI/ACP/RemoteTurnClient.swift",
        ]
        let forbidden = [
            "GnosticObjectType.agent",
            "GnosticAgentObject",
            "attachedAgentInstanceID",
            "AgentChatRequest",
            "AgentChatResult",
            "AgentChatProvider",
            "me.atkn.gnostic.agent.chat",
            "LegacyCreateExecutor",
            "LegacyAscendantBackendBridge",
            "GnosticRemoteClient",
        ]

        for relativePath in sourcePaths {
            let source = try String(contentsOf: rootURL.appendingPathComponent(relativePath), encoding: .utf8)
            for forbiddenName in forbidden {
                #expect(!source.contains(forbiddenName), "The removed compatibility name '\(forbiddenName)' remains in \(relativePath).")
            }
        }

        #expect(!FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent("Sources/GnosticCore/Runtime/LegacyAscendantAdapterBridge.swift").path
        ))

        for relativePath in [
            "Sources/GnosticCLI/Commands/ChatCommand.swift",
            "Sources/GnosticCLI/Chat",
        ] {
            #expect(!FileManager.default.fileExists(
                atPath: rootURL.appendingPathComponent(relativePath).path
            ), "Removed direct Turn CLI path remains: \(relativePath)")
        }

        let cliSourceRoot = rootURL.appendingPathComponent("Sources/GnosticCLI")
        for relativePath in try FileManager.default.subpathsOfDirectory(atPath: cliSourceRoot.path)
            where relativePath.hasSuffix(".swift") {
            let source = try String(
                contentsOf: cliSourceRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for removedName in ["TurnCommand", "TurnREPL", "ChatREPL", "RemoteTurnSession"] {
                #expect(!source.contains(removedName), "Removed direct Turn CLI symbol '\(removedName)' remains in \(relativePath).")
            }
        }

        let acpTransport = try String(
            contentsOf: rootURL.appendingPathComponent("Sources/GnosticCLI/ACP/RemoteTurnClient.swift"),
            encoding: .utf8
        )
        for removedMethod in [
            "func invokeWorkspace(",
            "func listTimelines(",
            "func updateTimeline(",
            "func listWorkspaces(",
            "func attach(",
            "func detach(",
            "func discoverServedTimeline(",
        ] {
            #expect(!acpTransport.contains(removedMethod), "Direct-client method '\(removedMethod)' remains in the ACP transport.")
        }

        for relativePath in [
            "Tests/GnosticCLITests/ACP/ACPProviderAcceptanceTests.swift",
            "Tests/GnosticCLITests/ACP/ACPSubprocessTests.swift",
        ] {
            let source = try String(contentsOf: rootURL.appendingPathComponent(relativePath), encoding: .utf8)
            #expect(!source.contains("RemoteTurnClient"), "ACP acceptance test still depends on production broker transport: \(relativePath)")
        }

        let sourceRoot = rootURL.appendingPathComponent("Sources")
        for relativePath in try FileManager.default.subpathsOfDirectory(atPath: sourceRoot.path)
            where relativePath.hasSuffix(".swift") && relativePath != "GnosticCore/Adapters/PositronicAscendantAdapter.swift" {
            let source = try String(contentsOf: sourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
            #expect(!source.contains("attachedAgentInstanceID"), "Provider-native AgentInstance linkage escaped its PositronicKit boundary: (relativePath).")
        }
    }

    @Test("the removed compatibility bridge has no lingering exception")
    func compatibilityExceptionIsRemoved() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Documentation/Architecture/exceptions.json")
        let data = try Data(contentsOf: sourceURL)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let exceptions = try #require(object["exceptions"] as? [[String: Any]])
        #expect(exceptions.allSatisfy { $0["id"] as? String != "RESET-004-legacy-adapter-bridge" })
    }

    @Test("Atlas is an optional boundary and Narrative is absent from Core")
    func atlasBoundaryIsOptionalAndNarrativeIsRemoved() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let package = try String(
            contentsOf: rootURL.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        #expect(package.contains(".library(name: \"GnosticPositronicAtlas\", targets: [\"GnosticPositronicAtlas\"])"))

        let coreTarget = try #require(Self.targetBlock(named: "GnosticCore", in: package))
        let atlasTarget = try #require(Self.targetBlock(named: "GnosticPositronicAtlas", in: package))
        #expect(!coreTarget.contains("GnosticPositronicAtlas"))
        #expect(atlasTarget.contains("\"GnosticCore\""))
        #expect(atlasTarget.contains("PositronicKit"))

        let sourceRoot = rootURL.appendingPathComponent("Sources/GnosticCore")
        for relativePath in try FileManager.default.subpathsOfDirectory(atPath: sourceRoot.path)
            where relativePath.hasSuffix(".swift") {
            let source = try String(
                contentsOf: sourceRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            #expect(!source.contains("Narrative"), "Narrative must not remain in Core: \(relativePath)")
            #expect(!source.contains("import GnosticPositronicAtlas"), "Core must not import Atlas: \(relativePath)")
        }
    }

    private static func targetBlock(named name: String, in package: String) -> String? {
        guard let targetStart = package.range(of: ".target(\n            name: \"\(name)\"")?.lowerBound else {
            return nil
        }
        guard let targetEnd = package.range(of: "\n        ),", range: targetStart..<package.endIndex) else {
            return nil
        }
        return String(package[targetStart..<targetEnd.upperBound])
    }
}
