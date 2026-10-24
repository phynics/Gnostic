// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@_spi(RuntimeHost) import GnosticCore
import GnosticProtocol
import Testing

@testable import GnosticACPFrontend
@testable import GnosticCLI

/// Clean ACP smoke coverage.
///
/// The suite keeps the filter name used by `make acp-smoke`. It exercises the
/// shipped `gnostic acp` command against an in-process Node whose backend is a
/// host-owned echo fixture. No provider package is linked or executed.
@Suite("ACP subprocess", .serialized)
struct ACPSubprocessTests {
    @Test("ACP selection uses Runtime when its ID collides with a legacy Ascendant projection")
    @MainActor
    func selectsCanonicalRuntimeAdvertisement() throws {
        let id = UUID(uuidString: "e51d0000-0000-4000-8000-000000000002")!
        let nodeID = UUID(uuidString: "e51d0000-0000-4000-8000-000000000001")!
        let legacyProjection = NetworkCatalogEntry(
            objectID: id,
            objectType: GnosticObjectType.ascendant,
            protocolMajor: GnosticProtocol.currentMajor,
            providerID: "provider",
            name: "Legacy projection",
            knownProperties: [:],
            dynamicProperties: [:],
            workspace: nil
        )
        let runtime = NetworkCatalogEntry(
            objectID: id,
            objectType: GnosticObjectType.runtimeInstance,
            protocolMajor: GnosticProtocol.currentMajor,
            providerID: "provider",
            name: "ACP fixture Runtime",
            knownProperties: ["nodeID": .string(nodeID.uuidString)],
            dynamicProperties: [:],
            workspace: nil
        )

        let candidates = RemoteTurnClient.discoveredRuntimes(from: [legacyProjection, runtime])
        let selected = try RemoteTurnClient.selectCandidate(from: candidates, id: id)
        #expect(candidates.count == 1)
        #expect(selected.runtimeID == id)
        #expect(selected.name == "ACP fixture Runtime")
        #expect(selected.nodeID == nodeID)
        let profiles = ACPCommand.profiles(
            from: [legacyProjection, runtime],
            host: "127.0.0.1",
            port: 1883,
            namespace: "fixture"
        )
        #expect(profiles.count == 1)
        #expect(profiles[0].args.contains("--runtime"))
        #expect(!profiles[0].args.contains("--ascendant"))
    }

    @Test("explicit Node selection requires a known matching Node ID")
    @MainActor
    func explicitNodeSelectionRequiresKnownMatch() throws {
        let runtimeID = UUID(uuidString: "e51d0000-0000-4000-8000-000000000002")!
        let requestedNodeID = UUID(uuidString: "e51d0000-0000-4000-8000-000000000001")!
        let otherNodeID = UUID(uuidString: "e51d0000-0000-4000-8000-000000000003")!
        let withoutNode = RemoteTurnClient.DiscoveredRuntimeInstance(
            runtimeID: runtimeID,
            name: "Runtime without Node metadata",
            providerID: "provider-a"
        )
        let matchingNode = RemoteTurnClient.DiscoveredRuntimeInstance(
            runtimeID: runtimeID,
            name: "Runtime on requested Node",
            providerID: "provider-a",
            nodeID: requestedNodeID
        )
        let wrongNode = RemoteTurnClient.DiscoveredRuntimeInstance(
            runtimeID: runtimeID,
            name: "Runtime on another Node",
            providerID: "provider-b",
            nodeID: otherNodeID
        )

        #expect(selectionErrorCode(from: [withoutNode]) == "nodeUnavailable")
        #expect(try RemoteTurnClient.selectCandidate(from: [matchingNode], id: runtimeID, nodeID: requestedNodeID) == matchingNode)
        #expect(selectionErrorCode(from: [wrongNode]) == "nodeUnavailable")

        // Provider-only profiles remain valid for Runtime advertisements without Node metadata.
        #expect(try RemoteTurnClient.selectCandidate(from: [withoutNode], providerID: "provider-a") == withoutNode)

        func selectionErrorCode(from candidates: [RemoteTurnClient.DiscoveredRuntimeInstance]) -> String? {
            do {
                _ = try RemoteTurnClient.selectCandidate(from: candidates, id: runtimeID, nodeID: requestedNodeID)
                return nil
            } catch let error as RemoteTurnClientError {
                return error.gnosticCode
            } catch {
                return nil
            }
        }
    }

    @Test("final discovery failure formatting bounds and sanitizes the entire response")
    @MainActor
    func discoveryFailureFormattingIsBounded() {
        let selector = "provider\n\u{001B}" + String(repeating: "p", count: 4_000)
        let error = RemoteTurnClientError.providerUnavailable(selector)
        let formatted = RemoteTurnClient.discoveryFailureDescription(
            error: error,
            diagnostics: "catalog\r\n" + String(repeating: "d", count: 4_000)
        )

        #expect(formatted.count <= 1_320)
        #expect(!formatted.contains("\n"))
        #expect(!formatted.contains("\r"))
        #expect(!formatted.contains("\u{001B}"))
        #expect(formatted.contains("Provider provider"))
        #expect(formatted.contains("Discovery details: catalog"))
        #expect(formatted.contains("…"))
    }

    @Test("ACP discovery diagnostics bound and sanitize catalog details")
    @MainActor
    func discoveryDiagnosticsAreBounded() {
        let entries = (0..<24).map { index in
            NetworkCatalogEntry(
                objectID: UUID(),
                objectType: GnosticObjectType.runtimeInstance,
                protocolMajor: GnosticProtocol.currentMajor,
                providerID: "provider\n\u{001B}" + String(repeating: "x", count: 300),
                name: "Runtime \(index)",
                knownProperties: ["rawCapabilities": .object(Dictionary(uniqueKeysWithValues: (0..<2_000).map { ("cap-\($0)", NetworkDynamicValue.bool(true)) }))],
                dynamicProperties: [:],
                workspace: nil
            )
        }
        let summary = RemoteTurnClient.discoverySummary(entries)
        #expect(summary.count <= 1_024)
        #expect(!summary.contains("\n"))
        #expect(!summary.contains("\u{001B}"))
        #expect(summary.contains("truncated=true"))
        #expect(summary.contains("capabilityCount=999+"))
    }

    @Test(
        "profile discovery emits deterministic source profiles",
        .timeLimit(.minutes(1)),
        .enabled(if: ProcessInfo.processInfo.environment["GNOSTIC_ACP_BINARY"] != nil, "GNOSTIC_ACP_BINARY is not set")
    )
    @MainActor
    func discoversProfiles() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["GNOSTIC_ACP_BINARY"])
        let namespace = "acp-profiles-\(UUID().uuidString.lowercased())"
        let lowerID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let node = try await makeACPNode(
            namespace: namespace,
            ascendantID: lowerID,
            name: "Lower Ascendant"
        )
        defer { Task { @MainActor in await node.shutdown() } }
        try await node.start()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "acp", "profiles", "--json",
            "--host", "127.0.0.1",
            "--port", "1883",
            "--namespace", namespace,
        ]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        while process.isRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let standardError = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, Comment(rawValue: standardError))
        let profiles = try JSONDecoder().decode(ACPProfileBundle.self, from: data)
        let profile = try #require(profiles.profiles.first { $0.args.contains(lowerID.uuidString.lowercased()) })
        #expect(profile.args.contains("--runtime"))
        #expect(!profile.args.contains("--ascendant"))
    }

    @Test(
        "the shipped command line advertises its ACP and serve commands",
        .timeLimit(.minutes(1)),
        .enabled(if: ProcessInfo.processInfo.environment["GNOSTIC_ACP_BINARY"] != nil, "GNOSTIC_ACP_BINARY is not set")
    )
    func advertisesItsCommands() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["GNOSTIC_ACP_BINARY"])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--help"]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        while process.isRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let standardError = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, Comment(rawValue: standardError))
        let help = String(decoding: data, as: UTF8.self)
        #expect(help.contains("acp"))
        #expect(help.contains("serve"))
        #expect(help.contains("config"))
    }
}

@MainActor
private func makeACPNode(
    namespace: String,
    ascendantID: UUID,
    name: String,
    host: String = "127.0.0.1",
    port: Int = 1883
) async throws -> NodeRuntime {
    let timelineID = UUID()
    let manifest = NodeManifest(
        broker: .init(host: host, port: port, namespace: namespace),
        node: .init(id: UUID(), approvalMode: "auto"),
        ascendants: [.init(
            id: ascendantID,
            name: name,
            defaultTimelineID: timelineID,
            description: "ACP lifecycle fixture",
            backend: .init(kind: "clean-echo")
        )],
        timelines: [.init(
            id: timelineID,
            title: "\(name) Timeline",
            operatingAscendantID: ascendantID
        )],
        workspaces: []
    )
    var adapters = NodeRuntimeAdapters.default
    adapters.ascendants.registerBackend(kind: "clean-echo") { ascendant, _, _, timelines in
        CleanEchoAscendantBackend(ascendant: ascendant, timelines: timelines)
    }
    return try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)
}

@MainActor
private final class CleanEchoAscendantBackend: AscendantBackend {
    nonisolated var capabilities: AscendantBackendOptionalSurfaces { [] }
    let identity: AscendantBackendIdentity
    private var timelines: [AscendantBackendTimeline]

    init(ascendant: NodeManifest.Ascendant, timelines: [NodeManifest.Timeline]) {
        let now = Date()
        identity = AscendantBackendIdentity(
            id: ascendant.id,
            name: ascendant.name,
            description: ascendant.description,
            privateTimelineID: ascendant.defaultTimelineID,
            primaryWorkspaceID: nil,
            lastActiveAt: now,
            createdAt: now,
            updatedAt: now,
            capabilities: AscendantBackendCapabilities(
                interoperability: [
                    AscendantInteroperabilityCapability.textTurn.rawValue,
                    AscendantInteroperabilityCapability.streamedUpdates.rawValue,
                ],
                backendKind: "clean-echo"
            )
        )
        self.timelines = timelines.map {
            AscendantBackendTimeline(
                id: $0.id, title: $0.title, attachedWorkspaceIDs: [],
                ascendantID: ascendant.id, isArchived: false, isPrivate: false,
                createdAt: now, updatedAt: now
            )
        }
    }

    func validateConfiguration() throws {}

    func operatedTimelines() async throws -> [AscendantBackendTimeline] { timelines }

    func createTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        let now = Date()
        let timeline = AscendantBackendTimeline(
            id: id, title: title, attachedWorkspaceIDs: [], ascendantID: identity.id,
            isArchived: false, isPrivate: false, createdAt: now, updatedAt: now
        )
        timelines.append(timeline)
        return timeline
    }

    func removeTimeline(id: UUID) async { timelines.removeAll { $0.id == id } }

    func renameTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        guard let index = timelines.firstIndex(where: { $0.id == id }) else {
            throw AscendantBackendError.timelineNotFound(id)
        }
        let current = timelines[index]
        let renamed = AscendantBackendTimeline(
            id: current.id, title: title, attachedWorkspaceIDs: current.attachedWorkspaceIDs,
            ascendantID: current.ascendantID, isArchived: current.isArchived,
            isPrivate: current.isPrivate, createdAt: current.createdAt, updatedAt: Date()
        )
        timelines[index] = renamed
        return renamed
    }

    func runTurn(
        _ request: AscendantBackendTurnRequest,
        updates: any AscendantBackendUpdateSink
    ) async throws -> String {
        guard timelines.contains(where: { $0.id == request.timelineID }) else {
            throw AscendantBackendError.timelineNotFound(request.timelineID)
        }
        let reply = "echo: \(request.message)"
        try await updates.append(AscendantBackendUpdate(kind: .assistantText, text: reply))
        try await updates.append(AscendantBackendUpdate(kind: .completion, terminal: true))
        return reply
    }

    func cancel() async {}
    func shutdown() async {}
}
