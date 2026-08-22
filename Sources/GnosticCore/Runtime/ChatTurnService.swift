// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKContracts
import PositronicKit

/// Serializes turns independently of the node's transport/lifecycle shell.
@MainActor
public final class TurnService {
    private let registry: NodeRegistry
    private let coordinator: AscendantTurnCoordinator
    private let updates: AscendantTurnUpdateStore
    private let backendProvider: any BackendSessionProviding

    convenience init(
        registry: NodeRegistry,
        coordinator: AscendantTurnCoordinator,
        updates: AscendantTurnUpdateStore,
        isRunning: @escaping @MainActor () -> Bool,
        backend: @escaping @MainActor (UUID) async throws -> any AscendantBackend,
        lifecycleGeneration: @escaping @MainActor () -> UInt64 = { 0 },
        lifecycleFailure: @escaping @MainActor (UUID, any AscendantBackend, AscendantBackendLifecycleFailure) async -> Void = { _, _, _ in }
    ) {
        self.init(
            registry: registry,
            coordinator: coordinator,
            updates: updates,
            backendProvider: ClosureBackendSessionProvider(
                isRunning: isRunning,
                lifecycleGeneration: lifecycleGeneration,
                adapter: { _ in nil as (any AscendantBackend)? },
                current: { _, _, _ in true },
                backendLease: { _, _ in nil as UUID? },
                failure: lifecycleFailure,
                backend: backend
            )
        )
    }

    init(
        registry: NodeRegistry,
        coordinator: AscendantTurnCoordinator,
        updates: AscendantTurnUpdateStore,
        backendProvider: any BackendSessionProviding
    ) {
        self.registry = registry
        self.coordinator = coordinator
        self.updates = updates
        self.backendProvider = backendProvider
    }

    func turn(_ request: AscendantTurnRequest) async throws -> AscendantTurnResult {
        try GnosticProtocol.validate(request.protocolMajor)
        let ascendantID = try await registry.requireOperatingAscendant(for: request.timelineID)
        guard backendProvider.isRunning else { throw NodeRuntimeError.notRunning }
        let generation = backendProvider.lifecycleGeneration
        let sink = BackendTurnUpdateSink(store: updates, request: request)
        return try await coordinator.execute(request) {
            let adapter: any AscendantBackend
            do {
                adapter = try await self.backendProvider.backendForTurn(ascendantID)
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
                guard await self.backendProvider.isRunning,
                      await self.backendProvider.lifecycleGeneration == generation else {
                    throw CancellationError()
                }
                return result
            } catch let error as AscendantBackendError {
                if case let .lifecycleUnusable(failure) = error {
                    await self.backendProvider.markLifecycleFailure(ascendantID, backend: adapter, failure: failure)
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
