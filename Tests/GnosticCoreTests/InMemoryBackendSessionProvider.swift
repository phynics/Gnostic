// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

@testable import GnosticCore

/// A stateful provider used by unit tests at the same seam as the runtime
/// supervisor. Tests can replace a backend or lease directly without creating
/// a callback-shaped production adapter.
@MainActor
final class InMemoryBackendSessionProvider: BackendSessionProviding {
    var isRunning: Bool
    var lifecycleGeneration: UInt64
    var backends: [UUID: any AscendantBackend]
    var leases: [UUID: UUID]
    var reconstruction: (@MainActor (UUID) async throws -> any AscendantBackend)?
    var currentOverride: (@MainActor (BackendSessionContext) -> Bool)?
    var onLifecycleFailure: (@MainActor (BackendSessionContext, AscendantBackendLifecycleFailure) -> Void)?
    private(set) var lifecycleFailureCount = 0

    init(
        isRunning: Bool = true,
        lifecycleGeneration: UInt64 = 0,
        backends: [UUID: any AscendantBackend] = [:],
        leases: [UUID: UUID] = [:],
        reconstruction: (@MainActor (UUID) async throws -> any AscendantBackend)? = nil,
        currentOverride: (@MainActor (BackendSessionContext) -> Bool)? = nil,
        onLifecycleFailure: (@MainActor (BackendSessionContext, AscendantBackendLifecycleFailure) -> Void)? = nil
    ) {
        self.isRunning = isRunning
        self.lifecycleGeneration = lifecycleGeneration
        self.backends = backends
        self.leases = leases
        self.reconstruction = reconstruction
        self.currentOverride = currentOverride
        self.onLifecycleFailure = onLifecycleFailure
    }

    var isClosed: Bool { !isRunning }

    func turnAdmission() throws -> BackendTurnAdmission {
        guard isRunning else { throw NodeRuntimeError.notRunning }
        return .init(generation: lifecycleGeneration)
    }

    func session(for ascendantID: UUID) -> LeasedAscendantBackendSession? {
        guard isRunning,
              let backend = backends[ascendantID],
              let lease = leases[ascendantID] else { return nil }
        let context = BackendSessionContext(
            ascendantID: ascendantID,
            lease: lease,
            generation: lifecycleGeneration
        )
        return LeasedAscendantBackendSession(context: context, backend: backend, provider: self)
    }

    func sessionForTurn(
        timelineID _: UUID,
        operatedBy ascendantID: UUID,
        admittedUnder admission: BackendTurnAdmission
    ) async throws -> LeasedAscendantBackendSession {
        guard !Task.isCancelled, isRunning, lifecycleGeneration == admission.generation else {
            throw CancellationError()
        }
        if let session = session(for: ascendantID) {
            return session
        }
        guard let reconstruction else { throw NodeRuntimeError.notRunning }
        let backend = try await reconstruction(ascendantID)
        guard !Task.isCancelled, isRunning, lifecycleGeneration == admission.generation else {
            throw CancellationError()
        }
        backends[ascendantID] = backend
        if leases[ascendantID] == nil {
            leases[ascendantID] = UUID.makeVersion4()
        }
        guard let session = session(for: ascendantID) else {
            throw NodeRuntimeError.notRunning
        }
        return session
    }

    func isCurrentSession(_ context: BackendSessionContext) -> Bool {
        guard isRunning,
              lifecycleGeneration == context.generation,
              backends[context.ascendantID] != nil,
              leases[context.ascendantID] == context.lease else { return false }
        return currentOverride?(context) ?? true
    }

    func requireCurrent(
        _ context: BackendSessionContext?,
        generation: UInt64? = nil
    ) throws {
        guard isRunning else { throw NodeRuntimeError.notRunning }
        if let generation, lifecycleGeneration != generation {
            throw NodeRuntimeError.notRunning
        }
        if let context, !isCurrentSession(context) {
            throw NodeRuntimeError.notRunning
        }
    }

    func markLifecycleFailure(
        _ context: BackendSessionContext,
        failure: AscendantBackendLifecycleFailure
    ) async {
        guard isCurrentSession(context) else { return }
        lifecycleFailureCount += 1
        onLifecycleFailure?(context, failure)
    }

    func markContractViolation(
        _ context: BackendSessionContext,
        violation: AscendantBackendContractViolation
    ) async {
        await markLifecycleFailure(
            context,
            failure: .init(code: "backendContractViolation", message: violation.localizedDescription)
        )
    }
}
