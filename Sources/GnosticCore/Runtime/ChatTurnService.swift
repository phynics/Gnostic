// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKContracts
import PositronicKit

/// Serializes turns independently of the node's transport/lifecycle shell.
@MainActor
public final class TurnService {
    private let backend: @MainActor (UUID) async throws -> any AscendantBackend
    private let registry: NodeRegistry
    private let coordinator: AscendantTurnCoordinator
    private let updates: AscendantTurnUpdateStore
    private let access: BackendSessionAccess

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
            access: BackendSessionAccess(
                isRunning: isRunning,
                isClosed: { !isRunning() },
                lifecycleGeneration: lifecycleGeneration,
                session: { _ in nil },
                isCurrent: { _, _, _ in true },
                lease: { _, _ in nil },
                lifecycleFailure: lifecycleFailure
            ),
            backend: backend
        )
    }

    init(
        registry: NodeRegistry,
        coordinator: AscendantTurnCoordinator,
        updates: AscendantTurnUpdateStore,
        access: BackendSessionAccess,
        backend: @escaping @MainActor (UUID) async throws -> any AscendantBackend
    ) {
        self.registry = registry
        self.coordinator = coordinator
        self.updates = updates
        self.access = access
        self.backend = backend
    }

    func turn(_ request: AscendantTurnRequest) async throws -> AscendantTurnResult {
        try GnosticProtocol.validate(request.protocolMajor)
        let ascendantID = try await registry.requireOperatingAscendant(for: request.timelineID)
        guard access.isRunning() else { throw NodeRuntimeError.notRunning }
        let generation = access.lifecycleGeneration()
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
                guard await self.access.isRunning(),
                      await self.access.lifecycleGeneration() == generation else {
                    throw CancellationError()
                }
                return result
            } catch let error as AscendantBackendError {
                if case let .lifecycleUnusable(failure) = error {
                    await self.access.lifecycleFailure(ascendantID, adapter, failure)
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
