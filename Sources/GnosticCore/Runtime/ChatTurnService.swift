// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared
import PositronicKit

/// Serializes turns independently of the node's transport/lifecycle shell.
@MainActor
public final class TurnService {
    private let backend: @MainActor (UUID) async throws -> any AscendantBackend
    private let registry: NodeRegistry
    private let coordinator: AscendantTurnCoordinator
    private let updates: AscendantTurnUpdateStore
    private let isRunning: @MainActor () -> Bool
    private let lifecycleGeneration: @MainActor () -> UInt64
    private let lifecycleFailure: @MainActor (UUID, any AscendantBackend, AscendantBackendLifecycleFailure) async -> Void

    init(
        registry: NodeRegistry,
        coordinator: AscendantTurnCoordinator,
        updates: AscendantTurnUpdateStore,
        isRunning: @escaping @MainActor () -> Bool,
        backend: @escaping @MainActor (UUID) async throws -> any AscendantBackend,
        lifecycleGeneration: @escaping @MainActor () -> UInt64 = { 0 },
        lifecycleFailure: @escaping @MainActor (UUID, any AscendantBackend, AscendantBackendLifecycleFailure) async -> Void = { _, _, _ in }
    ) {
        self.registry = registry
        self.coordinator = coordinator
        self.updates = updates
        self.isRunning = isRunning
        self.lifecycleGeneration = lifecycleGeneration
        self.backend = backend
        self.lifecycleFailure = lifecycleFailure
    }

    func turn(_ request: AscendantTurnRequest) async throws -> AscendantTurnResult {
        try GnosticProtocol.validate(request.protocolMajor)
        let ascendantID = try await registry.requireOperatingAscendant(for: request.timelineID)
        guard isRunning() else { throw NodeRuntimeError.notRunning }
        let generation = lifecycleGeneration()
        let sink = BackendTurnUpdateSink(store: updates, request: request)
        return try await coordinator.execute(request) {
            let adapter: any AscendantBackend
            do {
                adapter = try await self.backend(ascendantID)
            } catch let error as AscendantTurnError {
                throw error
            } catch {
                throw AscendantTurnError.backendUnavailable(
                    timelineID: request.timelineID,
                    clientTurnID: request.clientTurnID ?? "",
                    detail: error.localizedDescription
                )
            }
            do {
                let result = try await adapter.runTurn(
                    AscendantBackendTurnRequest(timelineID: request.timelineID, message: request.message, clientTurnID: request.clientTurnID),
                    updates: sink
                )
                guard await self.isRunning(),
                      await self.lifecycleGeneration() == generation else {
                    throw CancellationError()
                }
                return result
            } catch let error as AscendantBackendError {
                if case let .lifecycleUnusable(failure) = error {
                    await self.lifecycleFailure(ascendantID, adapter, failure)
                }
                throw error
            }
        }
    }
}

private struct BackendTurnUpdateSink: AscendantBackendUpdateSink {
    let store: AscendantTurnUpdateStore
    let request: AscendantTurnRequest

    func append(_ update: AscendantBackendUpdate) async {
        guard let clientTurnID = request.clientTurnID else { return }
        _ = await store.append(
            timelineID: request.timelineID,
            clientTurnID: clientTurnID,
            kind: update.kind,
            text: update.text,
            toolState: update.toolState,
            permissionState: update.permissionState,
            terminal: update.terminal
        )
    }
}
