// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared
import PositronicKit

/// Serializes turns independently of the node's transport/lifecycle shell.
@MainActor
public final class TurnService {
    private let adapter: @MainActor (UUID) -> (any AscendantBackend)?
    private let registry: NodeRegistry
    private let coordinator: AscendantTurnCoordinator
    private let updates: AscendantTurnUpdateStore
    private let isRunning: @MainActor () -> Bool

    init(registry: NodeRegistry, coordinator: AscendantTurnCoordinator, updates: AscendantTurnUpdateStore, isRunning: @escaping @MainActor () -> Bool, adapter: @escaping @MainActor (UUID) -> (any AscendantBackend)?) {
        self.registry = registry; self.coordinator = coordinator; self.updates = updates; self.isRunning = isRunning; self.adapter = adapter
    }

    func turn(_ request: AscendantTurnRequest) async throws -> AscendantTurnResult {
        try GnosticProtocol.validate(request.protocolMajor)
        let ascendantID = try await registry.requireOperatingAscendant(for: request.timelineID)
        guard isRunning() else { throw NodeRuntimeError.notRunning }
        guard let adapter = adapter(ascendantID) else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
        let sink = BackendTurnUpdateSink(store: updates, request: request)
        return try await coordinator.execute(request) {
            try await adapter.runTurn(
                AscendantBackendTurnRequest(timelineID: request.timelineID, message: request.message, clientTurnID: request.clientTurnID),
                updates: sink
            )
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
