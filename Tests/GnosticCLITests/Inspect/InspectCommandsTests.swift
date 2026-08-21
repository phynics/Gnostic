// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import PKContracts
import PositronicKit
import Testing

@testable import GnosticCLI

@Suite("Inspect commands")
struct InspectCommandsTests {
    private let namespace = "gnostic-inspect-tests"

    @Test("inspect list discovers the seeded workspace through the broker") @MainActor
    func listDiscoversAdvertisements() async throws {
        try await withSeededWorkspace { id in
            let entries = try await InspectSession(
                values: .init(host: "127.0.0.1", port: 1883, namespace: namespace, observeSeconds: 1.5)
            ).collect()

            let workspaces = entries.filter { $0.objectType == GnosticObjectType.workspace }
            #expect(workspaces.contains { $0.objectID == id })

            let text = InspectRenderer.listText(entries)
            #expect(text.contains("me.atkn.gnostic.Workspace"))
        }
    }

    @Test("inspect object dumps a workspace through the broker") @MainActor
    func objectDumpsWorkspace() async throws {
        try await withSeededWorkspace { id in
            let entries = try await InspectSession(
                values: .init(host: "127.0.0.1", port: 1883, namespace: namespace, observeSeconds: 1.5)
            ).collect()

            guard let workspace = entries.first(where: { $0.objectType == GnosticObjectType.workspace }) else {
                Issue.record("no workspace discovered")
                return
            }
            let json = try InspectRenderer.objectJSON(workspace, compact: false)
            #expect(json.contains("workspace"))
            #expect(json.contains(id.uuidString.lowercased()))
        }
    }

    @Test("object resolution and exit codes classify unknown and ambiguous") @MainActor
    func objectResolutionExitCodes() {
        let entry = InspectRendererTestsEntry.workspace(provider: "a")
        let other = InspectRendererTestsEntry.workspace(provider: "b")

        #expect(InspectRenderer.exitCode(for: .unknown) == 2)
        #expect(InspectRenderer.exitCode(for: .ambiguous) == 2)
        #expect(InspectRenderer.exitCode(for: .found(entry)) == 0)

        guard case .unknown = InspectRenderer.resolution(for: []) else {
            Issue.record("expected unknown")
            return
        }
        guard case .ambiguous = InspectRenderer.resolution(for: [entry, other]) else {
            Issue.record("expected ambiguous")
            return
        }
    }

    /// Seeds a one-shot workspace advertisement and registers the generic
    /// discover responder used by late subscribers.
    @MainActor
    private func withSeededWorkspace(_ body: @escaping (UUID) async throws -> Void) async throws {
        let provider = try InspectContainer.provider(namespace: namespace)
        defer { provider.shutdown() }
        let workspaceID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000001")!
        let lifecycle = try #require(
            provider.getController(name: "ObjectLifecycleController") as ObjectLifecycleController?
        )
        let object = GnosticWorkspaceObject(workspace: WorkspaceReference(
            id: workspaceID,
            uri: WorkspaceURI(parsing: "workspace://inspect")!,
            location: .runtime,
            tools: [.custom(.init(id: "echo", name: "Echo", description: "Echoes input."))],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try await provider.startAndWaitUntilReady()
        let communication = try #require(provider.communicationManager)
        let responder = await communication.registerDiscoverResponder { request in
            guard request.snapshot.objectTypes?.contains(GnosticObjectType.workspace) == true else { return }
            try request.resolve(object: object)
        }
        defer { responder.cancel() }

        lifecycle.advertiseDiscoverableObject(object: object)

        // Poll until a collect sample sees the workspace (bounded), proving the
        // client issued an active discovery request rather than waiting for ads.
        let deadline = ContinuousClock.now + .seconds(5)
        var observed = false
        while ContinuousClock.now < deadline {
            if try await !collect(workspaceID: workspaceID).isEmpty {
                observed = true
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        #expect(observed)

        try await body(workspaceID)
    }

    /// A minimal collect that returns matching workspace entries.
    @MainActor
    private func collect(workspaceID: UUID) async throws -> [NetworkCatalogEntry] {
        let entries = try await InspectSession(
            values: .init(host: "127.0.0.1", port: 1883, namespace: namespace, observeSeconds: 0.8)
        ).collect()
        return entries.filter { $0.objectID == workspaceID }
    }
}

/// A probe-only construct used to build entries like the renderer tests.
enum InspectRendererTestsEntry {
    static func workspace(provider: String) -> NetworkCatalogEntry {
        NetworkCatalogEntry(
            objectID: UUID(uuidString: "A21D0000-0000-4000-8000-000000000003")!,
            objectType: GnosticObjectType.workspace,
            providerID: provider,
            name: "Remote workspace",
            knownProperties: ["uri": .string("workspace://alpha")],
            dynamicProperties: [:],
            workspace: NetworkWorkspaceDescriptor(
                id: UUID(uuidString: "A21D0000-0000-4000-8000-000000000003")!,
                uri: "workspace://alpha",
                isAvailable: true,
                tools: [GnosticWorkspaceTool(definition: WorkspaceToolDefinition(id: "echo", name: "Echo", description: "Echoes input."))]
            )
        )
    }
}

/// Builds Axoloty containers for broker-backed inspect tests.
@MainActor
enum InspectContainer {
    static func provider(namespace: String) throws -> Container {
        try Container.resolve(
            components: Components(
                controllers: ["ObjectLifecycleController": ObjectLifecycleController.self],
                objectTypes: [GnosticWorkspaceObject.self]
            ),
            configuration: Configuration(
                common: CommonOptions(agentIdentity: ["name": "inspect-provider"]),
                communication: CommunicationOptions(
                    namespace: namespace,
                    shouldEnableCrossNamespacing: false,
                    mqttClientOptions: MQTTClientOptions(
                        host: "127.0.0.1",
                        port: 1883,
                        shouldTryMDNSDiscovery: false,
                        autoReconnect: false
                    ),
                    shouldAutoStart: false
                )
            )
        )
    }
}
