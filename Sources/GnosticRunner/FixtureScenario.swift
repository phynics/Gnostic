// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import PKContracts
import PositronicKit

@MainActor
struct FixtureScenario {
    let configuration: RunnerConfiguration

    func run() async throws {
        let provider = try RunnerRuntime(configuration: configuration)
        let consumer = try RunnerRuntime(configuration: configuration)
        defer { provider.shutdown(); consumer.shutdown() }
        try await provider.start()
        try await consumer.start()

        let workspaceID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000001")!
        let tools = fixtureTools
        let gnosticWorkspace = GnosticWorkspaceReference(
            id: workspaceID,
            uri: "workspace://fixture",
            tools: tools
        )
        let providerAPI = WorkspaceProvider(workspaceID: workspaceID, tools: tools) { toolID, arguments in
            switch toolID {
            case "list_files": return .success("README.md")
            case "read_file": return .success("fixture contents")
            case "workspace_echo": return .success(arguments["value"]?.value as? String ?? "")
            default: return .failure("unknown fixture tool")
            }
        }
        let registration = try await providerAPI.register(on: provider.communication)
        defer { registration.cancel() }
        let catalog = NetworkCatalog()
        let subscription = GnosticSubscription(catalog: catalog, communicationManager: consumer.communication)
        try await subscription.start()
        defer { subscription.stop() }
        provider.lifecycle.advertiseDiscoverableObject(object: GnosticWorkspaceObject(workspace: gnosticWorkspace))
        try await waitForWorkspace(catalog, id: workspaceID)
        print("fixture workspace discovered: \(workspaceID.uuidString.lowercased())")

        let store = InMemoryWorkspacePersistence()
        let factory = AxolotyWorkspaceFactory(catalog: catalog) { invocation in
            let encoded = try JSONEncoder().encode(invocation)
            let response = try await consumer.communication.call(
                operation: WorkspaceProvider.invocationOperation,
                parameters: String(decoding: encoded, as: UTF8.self),
                timeout: .seconds(3)
            )
            return try JSONDecoder().decode(ToolResult.self, from: Data(response.result.utf8))
        }
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: UnconfiguredLLMService()),
            persistence: .init(workspacePersistence: store),
            runtime: .init(workspaceCreator: factory)
        ))
        let timeline = try await kit.threads.create()
        let readvertised = TimelineReadvertisement()
        guard let descriptor = await catalog.networkObjects().first(where: { $0.objectID == workspaceID })?.workspace,
              let reference = try? WorkspaceReferenceProjection.reference(from: descriptor) else {
            throw RunnerError.missingRuntimeComponent
        }
        try await kit.workspaces.update(reference)
        try await kit.threads.attachWorkspace(reference.id, to: timeline.id)
        if let changed = try await kit.threads.get(timeline.id) {
            readvertised.record(changed)
        }
        let remote = AxolotyWorkspace(reference: reference, catalog: catalog, communication: consumer.communication, timeout: .seconds(3))
        try await invoke(remote, id: "list_files", arguments: [:], expected: "README.md")
        try await invoke(remote, id: "read_file", arguments: [:], expected: "fixture contents")
        try await invoke(remote, id: "workspace_echo", arguments: ["value": AnyCodable("network")], expected: "network")
        guard readvertised.latest?.attachedWorkspaceIDs == [workspaceID] else { throw RunnerError.timelineNotReadvertised }
        print("timeline readvertised with fixture workspace: \(workspaceID.uuidString.lowercased())")

        print("fixture scenario passed: list_files, read_file, workspace_echo used me.atkn.gnostic.workspace.invoke")
    }
}

private let fixtureTools = [
    GnosticWorkspaceToolDefinition(id: "list_files", name: "List files", description: "Lists fixture files."),
    GnosticWorkspaceToolDefinition(id: "read_file", name: "Read file", description: "Reads a fixture file."),
    GnosticWorkspaceToolDefinition(id: "workspace_echo", name: "Workspace echo", description: "Echoes fixture input."),
]
