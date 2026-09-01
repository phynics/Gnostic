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
        let admission = try backendProvider.turnAdmission()
        let sink = BackendTurnUpdateSink(store: updates, request: request)
        return try await coordinator.execute(request) {
            let session: LeasedAscendantBackendSession
            do {
                session = try await self.backendProvider.sessionForTurn(
                    timelineID: request.timelineID,
                    operatedBy: ascendantID,
                    admittedUnder: admission
                )
            } catch let error as AscendantTurnError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AscendantTurnError.backendUnavailable(
                    timelineID: request.timelineID,
                    clientTurnID: request.clientTurnID ?? "",
                    detail: error.localizedDescription
                )
            }
            let timeline: LeasedBackendTimelineSession
            do {
                timeline = try await session.timeline(id: request.timelineID)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as NodeRuntimeError {
                if case .notRunning = error { throw CancellationError() }
                throw error
            }
            let result = try await timeline.runTurn(
                .init(message: request.message, clientTurnID: request.clientTurnID),
                updates: sink
            )
            return result
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
