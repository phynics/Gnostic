// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

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
        let turnRequest: AscendantTurnRequest
        if let rawClientTurnID = request.clientTurnID {
            let clientTurnID = try GnosticWirePayload.canonicalClientTurnID(rawClientTurnID)
            turnRequest = AscendantTurnRequest(
                message: request.message,
                timelineID: request.timelineID,
                clientTurnID: clientTurnID,
                protocolMajor: request.protocolMajor
            )
        } else {
            turnRequest = request
        }
        let ascendantID = try await registry.requireOperatingAscendant(for: turnRequest.timelineID)
        guard backendProvider.isRunning else { throw NodeRuntimeError.notRunning }
        let generation = backendProvider.lifecycleGeneration
        let validatedClientTurnID: AscendantTurnUpdateStore.ValidatedClientTurnID?
        if let rawClientTurnID = turnRequest.clientTurnID {
            validatedClientTurnID = try await updates.validatedClientTurnID(rawClientTurnID)
        } else {
            validatedClientTurnID = nil
        }
        let sink = BackendTurnUpdateSink(store: updates, request: turnRequest, clientTurnID: validatedClientTurnID)
        return try await coordinator.execute(turnRequest) {
            if let validatedClientTurnID {
                do {
                    try await self.updates.start(
                        timelineID: turnRequest.timelineID,
                        clientTurnID: validatedClientTurnID,
                        message: turnRequest.message
                    )
                } catch AscendantTurnUpdateStore.Error.capacityExceeded {
                    throw AscendantTurnError.capacityExceeded(
                        timelineID: turnRequest.timelineID,
                        clientTurnID: turnRequest.clientTurnID ?? ""
                    )
                }
            }
            let session: AscendantBackendSession
            do {
                session = try await self.backendProvider.sessionForTurn(ascendantID)
            } catch let error as AscendantTurnError {
                throw error
            } catch {
                throw AscendantTurnError.backendUnavailable(
                    timelineID: turnRequest.timelineID,
                    clientTurnID: turnRequest.clientTurnID ?? "",
                    detail: error.localizedDescription
                )
            }
            do {
                let result = try await session.backend.runTurn(
                    AscendantBackendTurnRequest(timelineID: turnRequest.timelineID, message: turnRequest.message, clientTurnID: turnRequest.clientTurnID),
                    updates: sink
                )
                guard await self.backendProvider.isCurrentSession(session),
                      await self.backendProvider.isRunning,
                      await self.backendProvider.lifecycleGeneration == generation else {
                    throw CancellationError()
                }
                return result
            } catch let error as AscendantBackendError {
                if case let .lifecycleUnusable(failure) = error {
                    await self.backendProvider.markLifecycleFailure(session, failure: failure)
                }
                throw error
            }
        }
    }
}

private struct BackendTurnUpdateSink: AscendantBackendUpdateSink {
    let store: AscendantTurnUpdateStore
    let request: AscendantTurnRequest
    let clientTurnID: AscendantTurnUpdateStore.ValidatedClientTurnID?

    func append(_ update: AscendantBackendUpdate) async throws {
        guard let clientTurnID else { return }
        _ = try await store.append(
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
