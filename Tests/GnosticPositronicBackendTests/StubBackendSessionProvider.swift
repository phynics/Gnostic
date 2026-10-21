// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

@testable import GnosticCore

/// The single test double for ``BackendSessionProviding``.
///
/// It enforces the same backend-identity, generation, and lease checks as
/// ``AscendantBackendSupervisor``. A service test therefore cannot pass under a
/// stale-session rule that is looser than production's.
@MainActor
final class StubBackendSessionProvider: BackendSessionProviding {
    private var sessions: [UUID: AscendantBackendSession] = [:]
    private(set) var lifecycleFailures: [AscendantBackendLifecycleFailure] = []

    var isRunning: Bool
    var lifecycleGeneration: UInt64
    var isClosed: Bool { !isRunning }

    init(isRunning: Bool = true, lifecycleGeneration: UInt64 = 0) {
        self.isRunning = isRunning
        self.lifecycleGeneration = lifecycleGeneration
    }

    /// Installs the live session for one Ascendant.
    ///
    /// - Returns: The installed session, for the caller to assert against.
    @discardableResult
    func install(
        _ backend: any AscendantBackend,
        for ascendantID: UUID,
        lease: UUID = UUID(),
        generation: UInt64? = nil
    ) -> AscendantBackendSession {
        let session = AscendantBackendSession(
            ascendantID: ascendantID,
            backend: backend,
            lease: lease,
            generation: generation ?? lifecycleGeneration
        )
        sessions[ascendantID] = session
        return session
    }

    func session(for ascendantID: UUID) -> AscendantBackendSession? {
        guard isRunning, let session = sessions[ascendantID], session.generation == lifecycleGeneration else {
            return nil
        }
        return session
    }

    func sessionForTurn(_ ascendantID: UUID) async throws -> AscendantBackendSession {
        guard isRunning else { throw NodeRuntimeError.notRunning }
        guard let session = session(for: ascendantID) else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
        return session
    }

    func isCurrentBackend(_ ascendantID: UUID, backend: any AscendantBackend, generation: UInt64) -> Bool {
        guard isRunning,
              generation == lifecycleGeneration,
              let session = sessions[ascendantID],
              session.generation == generation else { return false }
        return (session.backend as AnyObject) === (backend as AnyObject)
    }

    func isCurrentSession(_ session: AscendantBackendSession) -> Bool {
        guard isRunning,
              session.generation == lifecycleGeneration,
              let live = sessions[session.ascendantID] else { return false }
        return live.lease == session.lease
            && (live.backend as AnyObject) === (session.backend as AnyObject)
    }

    func lease(for ascendantID: UUID, backend: any AscendantBackend) -> UUID? {
        guard let live = sessions[ascendantID],
              (live.backend as AnyObject) === (backend as AnyObject) else { return nil }
        return live.lease
    }

    func markLifecycleFailure(
        _ session: AscendantBackendSession,
        failure: AscendantBackendLifecycleFailure
    ) async {
        guard isCurrentSession(session) else { return }
        sessions.removeValue(forKey: session.ascendantID)
        lifecycleFailures.append(failure)
    }

    func markLifecycleFailure(
        _ ascendantID: UUID,
        backend: any AscendantBackend,
        failure: AscendantBackendLifecycleFailure
    ) async {
        guard let live = sessions[ascendantID],
              (live.backend as AnyObject) === (backend as AnyObject) else { return }
        sessions.removeValue(forKey: ascendantID)
        lifecycleFailures.append(failure)
    }
}
