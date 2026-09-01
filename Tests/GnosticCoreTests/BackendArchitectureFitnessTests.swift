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
        let assembly = try String(
            contentsOf: rootURL.appendingPathComponent("Sources/GnosticCore/Runtime/NodeAssembly.swift"),
            encoding: .utf8
        )
        #expect(assembly.contains("BackendWorkspaceDiscoveryCapability"))
        #expect(!nodeRuntime.contains("Container.resolve"))
        #expect(!nodeRuntime.contains("NodeTransport("))
        #expect(nodeRuntime.contains("NodeRuntimeHost"))
        #expect(!nodeRuntime.contains("reconstructBackend"))
        #expect(!nodeRuntime.contains("backendHealthByID"))
        for relativePath in [
            "Sources/GnosticCore/Runtime/TimelineService.swift",
            "Sources/GnosticCore/Runtime/WorkspaceService.swift",
            "Sources/GnosticCore/Runtime/ChatTurnService.swift",
        ] {
            let service = try String(contentsOf: rootURL.appendingPathComponent(relativePath), encoding: .utf8)
            #expect(!service.contains("quarantinedAscendantIDs"))
            #expect(!service.contains("private let isCurrentBackend"))
            #expect(service.contains("BackendSessionProviding"))
        }
    }

    @Test("Workspace operations are bound to Timeline sessions")
    func workspaceOperationsUseTimelineSessionSeam() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let backend = try String(
            contentsOf: rootURL.appendingPathComponent("Sources/GnosticCore/Runtime/AscendantBackend.swift"),
            encoding: .utf8
        )
        #expect(backend.contains("AscendantBackendTimelineWorkspaceSession"))
        #expect(!backend.contains("AscendantBackendWorkspaceCapability"))
        #expect(!backend.contains("to timelineID"))
        #expect(!backend.contains("from timelineID"))

        let workspaceService = try String(
            contentsOf: rootURL.appendingPathComponent("Sources/GnosticCore/Runtime/WorkspaceService.swift"),
            encoding: .utf8
        )
        for forbidden in [
            "rawSession(",
            "session.backend",
            "operatedTimelines().first",
            "runBackendOperation",
        ] {
            #expect(!workspaceService.contains(forbidden), "WorkspaceService retains forbidden backend access '\(forbidden)'.")
        }

        let nodeRuntime = try String(
            contentsOf: rootURL.appendingPathComponent("Sources/GnosticCore/Runtime/NodeRuntime.swift"),
            encoding: .utf8
        )
        #expect(nodeRuntime.contains("workspaceService.enabledToolIDs(for: timelineID)"))
    }

    @Test("single-Timeline backend operations use the final session-bound contract")
    func singleTimelineContractIsSessionBound() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let backend = try String(
            contentsOf: rootURL.appendingPathComponent("Sources/GnosticCore/Runtime/AscendantBackend.swift"),
            encoding: .utf8
        )
        for removed in [
            "AscendantBackendTurnRequest",
            "AscendantBackendWorkspaceCapability",
            "func renameTimeline(",
            "attachedAscendantID",
            "func projection()"
        ] {
            let comment = Comment(rawValue: "Removed backend seam '\(removed)' remains.")
            #expect(!backend.contains(removed), comment)
        }
        for required in [
            "AscendantBackendTimelineTurnRequest",
            "public protocol AscendantBackendTimelineSession",
            "public protocol AscendantBackendTimelineWorkspaceSession",
            "func timeline(id: UUID)",
            "func operatedTimelines()",
            "func createTimeline(id: UUID, title: String)",
            "func removeTimeline(id: UUID)",
            "func cancel() async",
            "func shutdown() async"
        ] {
            let comment = Comment(rawValue: "Final backend seam is missing '\(required)'.")
            #expect(backend.contains(required), comment)
        }

        let ascendantSession = try #require(Self.textBetween(
            backend,
            start: "public protocol AscendantBackendTimelineSession",
            end: "\n}\n\n/// A generic"
        ))
        #expect(!ascendantSession.contains("timelineID"))
        #expect(ascendantSession.contains("func runTurn("))
        #expect(ascendantSession.contains("func rename(to title: String)"))

        let workspaceSession = try #require(Self.textBetween(
            backend,
            start: "public protocol AscendantBackendTimelineWorkspaceSession",
            end: "\n}\n\n/// The only construction"
        ))
        #expect(!workspaceSession.contains("timelineID"))
        #expect(workspaceSession.contains("func attachWorkspace("))
        #expect(workspaceSession.contains("func detachWorkspace(id workspaceID: UUID)"))
        #expect(workspaceSession.contains("func enabledToolIDs()"))

        let ascendantBackend = try #require(Self.textBetween(
            backend,
            start: "public protocol AscendantBackend: AnyObject, Sendable",
            end: "\n}\n\nprivate struct Empty"
        ))
        #expect(!ascendantBackend.contains("timelineID"))
        #expect(!ascendantBackend.contains("runTurn("))
        #expect(!ascendantBackend.contains("rename("))
        #expect(ascendantBackend.contains("func timeline(id: UUID)"))
    }

    @Test("lifecycle policy and leased sessions stay inside the runtime seam")
    func lifecyclePolicyIsNotDuplicatedInServices() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let supervisor = try String(
            contentsOf: rootURL.appendingPathComponent("Sources/GnosticCore/Runtime/AscendantBackendSupervisor.swift"),
            encoding: .utf8
        )
        for removed in [
            "ClosureBackendSessionProvider",
            "struct AscendantBackendSession",
            "func rawSession",
            "func isCurrentBackend",
            "func lease(for"
        ] {
            let comment = Comment(rawValue: "Removed lifecycle seam '\(removed)' remains.")
            #expect(!supervisor.contains(removed), comment)
        }
        #expect(supervisor.contains("func session(for ascendantID: UUID) -> LeasedAscendantBackendSession?"))
        #expect(supervisor.contains("func sessionForTurn("))
        #expect(supervisor.contains("reconstructBackend(for: ascendantID)"))
        let supervisorClass = try #require(supervisor.range(of: "@MainActor\nfinal class AscendantBackendSupervisor: BackendSessionProviding"))
        let directSession = try #require(Self.textBetween(
            String(supervisor[supervisorClass.lowerBound..<supervisor.endIndex]),
            start: "func session(for ascendantID: UUID) -> LeasedAscendantBackendSession?",
            end: "\n    func sessionForTurn("
        ))
        #expect(!directSession.contains("reconstructBackend("))

        for relativePath in [
            "Sources/GnosticCore/Runtime/ChatTurnService.swift",
            "Sources/GnosticCore/Runtime/TimelineService.swift",
            "Sources/GnosticCore/Runtime/WorkspaceService.swift"
        ] {
            let service = try String(contentsOf: rootURL.appendingPathComponent(relativePath), encoding: .utf8)
            for forbidden in [
                "ClosureBackendSessionProvider",
                "struct AscendantBackendSession",
                "rawSession(",
                "session.backend",
                "operatedTimelines()",
                "markLifecycleFailure(",
                "markContractViolation(",
                "quarantineBackend(",
                "private func requireCurrent",
                "any AscendantBackend"
            ] {
                let comment = Comment(rawValue: "Service \(relativePath) retains forbidden seam '\(forbidden)'.")
                #expect(!service.contains(forbidden), comment)
            }
            for line in service.split(separator: "\n") where line.contains("private let") || line.contains("private var") {
                #expect(!line.contains("LeasedAscendantBackendSession"))
                #expect(!line.contains("LeasedBackendTimelineSession"))
                #expect(!line.contains("LeasedBackendTimelineWorkspaceSession"))
            }
        }

        let sourceRoot = rootURL.appendingPathComponent("Sources/GnosticCore")
        for relativePath in try FileManager.default.subpathsOfDirectory(atPath: sourceRoot.path)
            where relativePath.hasSuffix(".swift") {
            let source = try String(contentsOf: sourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
            #expect(!source.contains("operatedTimelines().first"), Comment(rawValue: "Single-Timeline scan remains in \(relativePath)."))
            #expect(!source.contains("ClosureBackendSessionProvider"), Comment(rawValue: "Callback provider remains in \(relativePath)."))
            #expect(!source.contains("AscendantBackendTurnRequest"), Comment(rawValue: "Removed Turn request remains in \(relativePath)."))
            #expect(!source.contains("AscendantBackendWorkspaceCapability"), Comment(rawValue: "Removed Workspace capability remains in \(relativePath)."))
        }
        for relativePath in [
            "Sources/GnosticCore/Runtime/TimelineService.swift",
            "Sources/GnosticCore/Runtime/WorkspaceService.swift"
        ] {
            let service = try String(contentsOf: rootURL.appendingPathComponent(relativePath), encoding: .utf8)
            #expect(!service.contains("sessionForTurn("), Comment(rawValue: "Only Turn acquisition may reconstruct sessions; found use in \(relativePath)."))
        }
    }

    @Test("generic Workspace projections do not expose PositronicKit types")
    func workspaceProjectionIsBackendNeutral() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePaths = [
            "Sources/GnosticCore/Objects/GnosticWorkspaceObject.swift",
            "Sources/GnosticCore/Objects/GnosticWorkspaceTypes.swift",
            "Sources/GnosticCore/Services/NetworkCatalogStructures.swift",
            "Sources/GnosticCore/Services/OrchestrationProjector.swift",
        ]
        for relativePath in sourcePaths {
            let source = try String(
                contentsOf: rootURL.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for forbidden in [
                "import PKContracts",
                "import PositronicKit",
                "AnyCodable",
                ": WorkspaceReference",
                " WorkspaceReference(",
                ": WorkspaceTrustLevel",
                ": WorkspaceStatus",
                ": WorkspaceToolDefinition",
                " WorkspaceToolDefinition(",
            ] {
                #expect(!source.contains(forbidden), "The generic Workspace projection mentions PositronicKit type '\(forbidden)' in \(relativePath).")
            }
        }
    }

    @Test("Core PositronicKit imports stay in explicit backend and host bridges")
    func corePositronicDependencyBoundaryIsExplicit() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let expectedImports: Set<String> = [
            "Sources/GnosticCore/Adapters/AxolotyWorkspace.swift",
            "Sources/GnosticCore/Adapters/PositronicAscendantAdapter.swift",
            "Sources/GnosticCore/Adapters/WorkspaceProvider.swift",
            "Sources/GnosticCore/Runtime/BackendWorkspaceService.swift",
            "Sources/GnosticCore/Runtime/MultiplexedWorkspaceProvider.swift",
            "Sources/GnosticCore/Runtime/NodeAssembly.swift",
            "Sources/GnosticCore/Runtime/NodeRuntime.swift",
            "Sources/GnosticCore/Runtime/NodeRuntimeAdapters.swift",
            "Sources/GnosticCore/Runtime/NodeRuntimeHost.swift",
            "Sources/GnosticCore/Runtime/NodeTransport.swift",
            "Sources/GnosticCore/Runtime/WorkspaceService.swift",
            "Sources/GnosticCore/Services/DiscoveredWorkspaceAttachmentService.swift",
            "Sources/GnosticCore/Services/NetworkManagementTools.swift",
            "Sources/GnosticCore/Services/WorkspaceReferenceProjection.swift",
        ]
        let sourceRoot = rootURL.appendingPathComponent("Sources/GnosticCore")
        let actualImports = Set(try FileManager.default.subpathsOfDirectory(atPath: sourceRoot.path)
            .filter { $0.hasSuffix(".swift") }
            .compactMap { relativePath -> String? in
                let source = try? String(
                    contentsOf: sourceRoot.appendingPathComponent(relativePath),
                    encoding: .utf8
                )
                guard source?.contains("import PositronicKit") == true else { return nil }
                return "Sources/GnosticCore/\(relativePath)"
            })
        #expect(actualImports == expectedImports)

        let package = try String(contentsOf: rootURL.appendingPathComponent("Package.swift"), encoding: .utf8)
        let coreTarget = try #require(Self.targetBlock(named: "GnosticCore", in: package))
        #expect(!coreTarget.contains("PKPrompt"))
        let boundaryADR = try String(
            contentsOf: rootURL.appendingPathComponent("Documentation/Architecture/ADRs/0005-core-positronic-dependency-boundary.md"),
            encoding: .utf8
        )
        for relativePath in expectedImports {
            #expect(boundaryADR.contains(relativePath.replacingOccurrences(of: "Sources/GnosticCore/", with: "")))
        }

        let expectedContractImports: Set<String> = [
            "Sources/GnosticCore/Adapters/AxolotyWorkspace.swift",
            "Sources/GnosticCore/Adapters/PositronicAscendantAdapter.swift",
            "Sources/GnosticCore/Adapters/WorkspaceProvider.swift",
            "Sources/GnosticCore/Providers/AgentChatProvider.swift",
            "Sources/GnosticCore/Providers/TimelineManagementProvider.swift",
            "Sources/GnosticCore/Providers/TimelineStatusProvider.swift",
            "Sources/GnosticCore/Providers/WorkspaceOpsProvider.swift",
            "Sources/GnosticCore/Runtime/AscendantPermissionCoordinator.swift",
            "Sources/GnosticCore/Runtime/BackendWorkspaceService.swift",
            "Sources/GnosticCore/Runtime/MultiplexedWorkspaceProvider.swift",
            "Sources/GnosticCore/Runtime/NodeAssembly.swift",
            "Sources/GnosticCore/Runtime/NodeRuntime.swift",
            "Sources/GnosticCore/Runtime/NodeRuntimeAdapters.swift",
            "Sources/GnosticCore/Runtime/NodeRuntimeHost.swift",
            "Sources/GnosticCore/Runtime/NodeTransport.swift",
            "Sources/GnosticCore/Runtime/WorkspaceService.swift",
            "Sources/GnosticCore/Services/DiscoveredWorkspaceAttachmentService.swift",
            "Sources/GnosticCore/Services/NetworkManagementTools.swift",
            "Sources/GnosticCore/Services/WorkspaceReferenceProjection.swift",
        ]
        let actualContractImports = Set(try FileManager.default.subpathsOfDirectory(atPath: sourceRoot.path)
            .filter { $0.hasSuffix(".swift") }
            .compactMap { relativePath -> String? in
                let source = try? String(
                    contentsOf: sourceRoot.appendingPathComponent(relativePath),
                    encoding: .utf8
                )
                guard source?.contains("import PKContracts") == true else { return nil }
                return "Sources/GnosticCore/\(relativePath)"
            })
        #expect(actualContractImports == expectedContractImports)
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

    private static func textBetween(_ source: String, start: String, end: String) -> String? {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            return nil
        }
        return String(source[startRange.upperBound..<endRange.lowerBound])
    }
}
