// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticProtocol

/// Serializes turns independently of the node's transport/lifecycle shell.
@MainActor
public final class TurnService {
    private let registry: NodeRegistry
    private let coordinator: AscendantTurnCoordinator
    private let updates: AscendantTurnUpdateStore
    private let backendProvider: any BackendSessionProviding
    private let remoteRouter: RemoteTurnRouter

    init(
        registry: NodeRegistry,
        coordinator: AscendantTurnCoordinator,
        updates: AscendantTurnUpdateStore,
        backendProvider: any BackendSessionProviding,
        remoteRouter: RemoteTurnRouter
    ) {
        self.registry = registry
        self.coordinator = coordinator
        self.updates = updates
        self.backendProvider = backendProvider
        self.remoteRouter = remoteRouter
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
        guard let record = await registry.timeline(id: turnRequest.timelineID) else {
            return try await remoteRouter.turn(turnRequest)
        }
        guard let ascendantID = record.operatorID else {
            throw NodeRuntimeError.noOperatingAscendant(turnRequest.timelineID)
        }
        guard backendProvider.isRunning else { throw NodeRuntimeError.notRunning }
        let generation = backendProvider.lifecycleGeneration
        let validatedClientTurnID: AscendantTurnUpdateStore.ValidatedClientTurnID?
        if let rawClientTurnID = turnRequest.clientTurnID {
            validatedClientTurnID = try await updates.validatedClientTurnID(rawClientTurnID)
        } else {
            validatedClientTurnID = nil
        }
        if await updates.requiresDurableTimelineAdmission, validatedClientTurnID == nil {
            throw NodeRuntimeError.turnFailed(
                "An identified clientTurnID is required for durable Timeline admission."
            )
        }
        let sink = BackendTurnUpdateSink(store: updates, request: turnRequest, clientTurnID: validatedClientTurnID)
        return try await coordinator.execute(
            turnRequest,
            ascendantID: ascendantID,
            cancel: {
                await self.cancelScopedTurn(
                    ascendantID: ascendantID,
                    timelineID: turnRequest.timelineID,
                    clientTurnID: turnRequest.clientTurnID ?? ""
                )
            }
        ) {
            // Identified Turns were admitted to the Turn ledger before this
            // operation was enqueued, so the backend runs at most once per identity.
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
                // A lost prompt response can also mean the Runtime is gone.
                // The Turn still ends insertionUnknown; the host retires the
                // backend as it does for any other unusable lifecycle.
                if case let .insertionUnknown(failure?) = error {
                    await self.backendProvider.markLifecycleFailure(session, failure: failure)
                }
                throw error
            }
        }
    }

    /// Best-effort scoped cancellation. A backend without the surface has
    /// nothing to cancel, so absence is a deliberate no-op.
    private func cancelScopedTurn(ascendantID: UUID, timelineID: UUID, clientTurnID: String) async {
        guard let session = backendProvider.session(for: ascendantID),
              let cancellable = session.backend.optionalCapability(.turnCancellation, as: (any AscendantBackendTurnCancellation).self) else { return }
        await cancellable.cancelTurn(timelineID: timelineID, clientTurnID: clientTurnID)
    }

    func cancelTurn(timelineID: UUID, clientTurnID: String) async -> Bool {
        if await registry.timeline(id: timelineID) != nil {
            return await coordinator.cancelTurn(timelineID: timelineID, clientTurnID: clientTurnID)
        }
        return await remoteRouter.cancel(timelineID: timelineID, clientTurnID: clientTurnID)
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
            kind: update.kind.rawValue,
            text: update.text,
            toolState: update.toolState,
            permissionState: update.permissionState,
            terminal: update.terminal,
            reasonCode: update.reasonCode,
            statusCode: update.statusCode,
            retryable: update.retryable
        )
    }

    func bindMessage(_ messageID: String) async {
        guard let clientTurnID else { return }
        await store.bindMessageID(timelineID: request.timelineID, clientTurnID: clientTurnID, messageID: messageID)
    }
}
