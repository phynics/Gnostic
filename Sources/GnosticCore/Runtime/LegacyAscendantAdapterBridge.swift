// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKShared
import PositronicKit

/// Compatibility bridge for the pre-RESET-004 adapter registration surface.
/// It is kept solely so existing integrations can migrate without making the
/// backend-neutral contract depend on their old provider types.
@MainActor
final class LegacyAscendantBackendBridge: AscendantBackend, AscendantBackendWorkspaceCapability {
    private let adapter: any AscendantRuntimeAdapter
    private var lifecycleFailure: AscendantBackendLifecycleFailure?

    init(adapter: any AscendantRuntimeAdapter) {
        self.adapter = adapter
        lifecycleFailure = nil
    }

    var identity: AscendantBackendIdentity { adapter.identity }

    func validateConfiguration() throws {}

    func operatedTimelines() async throws -> [AscendantBackendTimeline] {
        try requireUsable()
        return try await adapter.timelines()
    }

    func createTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        try requireUsable()
        return try await adapter.createTimeline(id: id, title: title)
    }

    func removeTimeline(id: UUID) async {
        guard lifecycleFailure == nil else { return }
        await adapter.removeTimeline(id: id)
    }

    func renameTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        try requireUsable()
        return try await adapter.renameTimeline(id: id, title: title)
    }

    func attachWorkspace(_ reference: BackendWorkspaceReference, to timelineID: UUID) async throws {
        try requireUsable()
        try await adapter.attachWorkspace(Self.positronicReference(reference), to: timelineID)
    }

    func detachWorkspace(_ workspaceID: UUID, from timelineID: UUID) async throws {
        try requireUsable()
        try await adapter.detachWorkspace(workspaceID, from: timelineID)
    }

    func enabledToolIDs(for timelineID: UUID) async -> [String] {
        guard lifecycleFailure == nil else { return [] }
        return await adapter.enabledToolIDs(for: timelineID)
    }

    func runTurn(_ request: AscendantBackendTurnRequest, updates: any AscendantBackendUpdateSink) async throws -> String {
        try requireUsable()
        let store = AscendantTurnUpdateStore()
        let events = await store.events()
        let forwarding = Task { @MainActor in
            for await event in events {
                let update = event.update
                await updates.append(.init(
                    kind: update.kind,
                    text: update.text,
                    toolState: update.toolState ?? update.toolStates.first,
                    permissionState: update.permissionState ?? update.permissionStates.first,
                    terminal: update.terminal
                ))
                for toolState in update.toolStates.dropFirst() {
                    await updates.append(.init(kind: "tool_state", toolState: toolState, terminal: update.terminal))
                }
                for permissionState in update.permissionStates.dropFirst() {
                    await updates.append(.init(kind: "permission_state", permissionState: permissionState, terminal: update.terminal))
                }
            }
        }
        do {
            let result = try await adapter.runTurn(
                AgentChatRequest(message: request.message, timelineID: request.timelineID, clientTurnID: request.clientTurnID),
                updates: store
            )
            forwarding.cancel()
            await forwarding.value
            return result
        } catch is CancellationError {
            forwarding.cancel()
            await forwarding.value
            throw AscendantBackendError.cancelled
        } catch let error as AscendantBackendError {
            forwarding.cancel()
            await forwarding.value
            throw error
        } catch let error as NodeRuntimeError {
            forwarding.cancel()
            await forwarding.value
            throw AscendantBackendError.terminal(.init(code: error.reasonCode, message: error.localizedDescription))
        } catch {
            forwarding.cancel()
            await forwarding.value
            throw AscendantBackendError.terminal(.init(code: "backendTurnFailed", message: String(describing: error)))
        }
    }

    func cancel() async {
        await adapter.cancelAll()
    }

    func shutdown() async {
        guard lifecycleFailure == nil else { return }
        await adapter.shutdown()
        lifecycleFailure = .init(code: "backendShutdown", message: "The legacy Ascendant backend has been shut down.")
    }

    private func requireUsable() throws {
        if let lifecycleFailure {
            throw AscendantBackendError.lifecycleUnusable(lifecycleFailure)
        }
    }

    private static func positronicReference(_ reference: BackendWorkspaceReference) throws -> WorkspaceReference {
        guard let uri = WorkspaceURI(parsing: reference.uri) else {
            throw AscendantBackendError.invalidConfiguration("Invalid Workspace URI '\(reference.uri)'.")
        }
        return WorkspaceReference(
            id: reference.id,
            uri: uri,
            location: .runtime,
            tools: reference.tools.map { tool in
                .custom(WorkspaceToolDefinition(
                    id: tool.id,
                    name: tool.name,
                    description: tool.description,
                    parametersSchema: {
                        guard let schema = tool.parametersSchema, case let .object(values) = schema else { return [:] }
                        return values.mapValues { AnyCodable(anyValue($0)) }
                    }(),
                    requiresPermission: tool.requiresPermission
                ))
            }
        )
    }

    private static func anyValue(_ value: ManifestJSONValue) -> Any {
        switch value {
        case let .string(value): return value
        case let .number(value): return value
        case let .bool(value): return value
        case let .object(value): return value.mapValues(anyValue)
        case let .array(value): return value.map(anyValue)
        case .null: return NSNull()
        }
    }
}
