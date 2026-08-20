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
    private let lifecycleFailure: @MainActor (UUID, AscendantBackendLifecycleFailure) async -> Void

    init(
        registry: NodeRegistry,
        coordinator: AscendantTurnCoordinator,
        updates: AscendantTurnUpdateStore,
        isRunning: @escaping @MainActor () -> Bool,
        backend: @escaping @MainActor (UUID) async throws -> any AscendantBackend,
        lifecycleFailure: @escaping @MainActor (UUID, AscendantBackendLifecycleFailure) async -> Void
    ) {
        self.registry = registry
        self.coordinator = coordinator
        self.updates = updates
        self.isRunning = isRunning
        self.backend = backend
        self.lifecycleFailure = lifecycleFailure
    }

    /// Compatibility initializer for tests and host seams that own a stable
    /// adapter without lifecycle reconstruction.
    convenience init(
        registry: NodeRegistry,
        coordinator: AscendantTurnCoordinator,
        updates: AscendantTurnUpdateStore,
        isRunning: @escaping @MainActor () -> Bool,
        adapter: @escaping @MainActor (UUID) -> (any AscendantBackend)?
    ) {
        self.init(
            registry: registry,
            coordinator: coordinator,
            updates: updates,
            isRunning: isRunning,
            backend: { ascendantID in
                guard let backend = adapter(ascendantID) else {
                    throw NodeRuntimeError.unknownAscendant(ascendantID)
                }
                return backend
            },
            lifecycleFailure: { _, _ in }
        )
    }

    func turn(_ request: AscendantTurnRequest) async throws -> AscendantTurnResult {
        try GnosticProtocol.validate(request.protocolMajor)
        let ascendantID = try await registry.requireOperatingAscendant(for: request.timelineID)
        guard isRunning() else { throw NodeRuntimeError.notRunning }
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
                return try await adapter.runTurn(
                    AscendantBackendTurnRequest(timelineID: request.timelineID, message: request.message, clientTurnID: request.clientTurnID),
                    updates: sink
                )
            } catch let error as AscendantBackendError {
                if case let .lifecycleUnusable(failure) = error {
                    await self.lifecycleFailure(ascendantID, failure)
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
