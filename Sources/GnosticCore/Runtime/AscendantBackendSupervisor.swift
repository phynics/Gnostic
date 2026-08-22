// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The immutable capability used by domain services when they need to call an
/// Ascendant. A session identifies both the backend instance and the lease
/// under which it was admitted; a replacement can never inherit an old
/// session accidentally.
@MainActor
struct AscendantBackendSession {
    let ascendantID: UUID
    let backend: any AscendantBackend
    let lease: UUID
    let generation: UInt64
}

/// Typed admission boundary shared by domain services. The supervisor owns
/// the lifecycle and lease policy; services never receive callback bundles.
@MainActor
protocol BackendSessionProviding: AnyObject, Sendable {
    var isRunning: Bool { get }
    var isClosed: Bool { get }
    var lifecycleGeneration: UInt64 { get }
    func session(for ascendantID: UUID) -> AscendantBackendSession?
    func sessionForTurn(_ ascendantID: UUID) async throws -> AscendantBackendSession
    func isCurrentBackend(_ ascendantID: UUID, backend: any AscendantBackend, generation: UInt64) -> Bool
    func isCurrentSession(_ session: AscendantBackendSession) -> Bool
    func lease(for ascendantID: UUID, backend: any AscendantBackend) -> UUID?
    func markLifecycleFailure(_ session: AscendantBackendSession, failure: AscendantBackendLifecycleFailure) async
    func markLifecycleFailure(_ ascendantID: UUID, backend: any AscendantBackend, failure: AscendantBackendLifecycleFailure) async
}

/// Compatibility bridge for tests and older internal composition points that
/// still provide the pre-supervisor callback shape.
@MainActor
final class ClosureBackendSessionProvider: BackendSessionProviding {
    private let running: @MainActor () -> Bool
    private let generation: @MainActor () -> UInt64
    private let backend: @MainActor (UUID) async throws -> any AscendantBackend
    private let adapter: @MainActor (UUID) -> (any AscendantBackend)?
    private let current: @MainActor (UUID, any AscendantBackend, UInt64) -> Bool
    private let backendLease: @MainActor (UUID, any AscendantBackend) -> UUID?
    private let failure: @MainActor (UUID, any AscendantBackend, AscendantBackendLifecycleFailure) async -> Void

    init(
        isRunning: @escaping @MainActor () -> Bool,
        lifecycleGeneration: @escaping @MainActor () -> UInt64,
        adapter: @escaping @MainActor (UUID) -> (any AscendantBackend)?,
        current: @escaping @MainActor (UUID, any AscendantBackend, UInt64) -> Bool,
        backendLease: @escaping @MainActor (UUID, any AscendantBackend) -> UUID?,
        failure: @escaping @MainActor (UUID, any AscendantBackend, AscendantBackendLifecycleFailure) async -> Void,
        backend: @escaping @MainActor (UUID) async throws -> any AscendantBackend
    ) {
        self.running = isRunning
        self.generation = lifecycleGeneration
        self.adapter = adapter
        self.current = current
        self.backendLease = backendLease
        self.failure = failure
        self.backend = backend
    }

    var isRunning: Bool { running() }
    var isClosed: Bool { !running() }
    var lifecycleGeneration: UInt64 { generation() }

    func session(for ascendantID: UUID) -> AscendantBackendSession? {
        guard let backend = adapter(ascendantID) else { return nil }
        return AscendantBackendSession(
            ascendantID: ascendantID,
            backend: backend,
            lease: backendLease(ascendantID, backend) ?? UUID(),
            generation: lifecycleGeneration
        )
    }

    func sessionForTurn(_ ascendantID: UUID) async throws -> AscendantBackendSession {
        let backend = try await self.backend(ascendantID)
        return AscendantBackendSession(
            ascendantID: ascendantID,
            backend: backend,
            lease: backendLease(ascendantID, backend) ?? UUID(),
            generation: lifecycleGeneration
        )
    }

    func isCurrentBackend(_ ascendantID: UUID, backend: any AscendantBackend, generation: UInt64) -> Bool {
        current(ascendantID, backend, generation)
    }

    func isCurrentSession(_ session: AscendantBackendSession) -> Bool {
        guard current(session.ascendantID, session.backend, session.generation) else { return false }
        guard let lease = backendLease(session.ascendantID, session.backend) else { return true }
        return lease == session.lease
    }

    func lease(for ascendantID: UUID, backend: any AscendantBackend) -> UUID? {
        backendLease(ascendantID, backend)
    }

    func markLifecycleFailure(_ session: AscendantBackendSession, failure: AscendantBackendLifecycleFailure) async {
        guard isCurrentSession(session) else { return }
        await self.failure(session.ascendantID, session.backend, failure)
    }

    func markLifecycleFailure(_ ascendantID: UUID, backend: any AscendantBackend, failure: AscendantBackendLifecycleFailure) async {
        await self.failure(ascendantID, backend, failure)
    }
}

/// Owns backend instances, health, leases, reconstruction single-flight, and
/// bounded retirement. NodeRuntime only composes this module and delegates to
/// it; Timeline, Workspace, and Turn operations never inspect backend slots.
@MainActor
final class AscendantBackendSupervisor: BackendSessionProviding {
    struct BackendSpec {
        let ascendant: NodeManifest.Ascendant
        let configuration: AscendantBackendConfiguration
    }

    private struct ReconstructionFailure: Error, LocalizedError, Sendable {
        let detail: String

        var errorDescription: String? { "Backend reconstruction failed: \(detail)" }
    }

    private let plan: NodeLaunchPlan
    private let adapters: NodeRuntimeAdapters
    private let registry: NodeRegistry
    private let lifetime: NodeRuntimeLifetime
    private let backendWorkspaceService: GnosticWorkspaceBackendService
    private let backendRetirementSupervisor: BackendRetirementSupervisor
    private let permissionCoordinator: AscendantPermissionCoordinator
    private let projectionRelay: NodeProjectionRelay
    private let backendWorkspaceCapability: BackendWorkspaceDiscoveryCapability?
    private var backendWorkspaceAttachment: ((UUID, UUID, UUID, UUID) async throws -> Void)?

    private var ascendantAdapters: [UUID: any AscendantBackend]
    private let backendIdentities: [AscendantBackendIdentity]
    private let backendSpecs: [UUID: BackendSpec]
    private var backendHealthByID: [UUID: AscendantBackendHealth]
    private var backendLeases: [UUID: UUID]
    /// Retained so a factory cannot reissue an instance with late calls from a prior lease.
    private var retiredBackends: [any AscendantBackend] = []
    private var reconstructionTasks: [UUID: Task<any AscendantBackend, Error>] = [:]

    init(
        plan: NodeLaunchPlan,
        adapters: NodeRuntimeAdapters,
        registry: NodeRegistry,
        lifetime: NodeRuntimeLifetime,
        backendWorkspaceService: GnosticWorkspaceBackendService,
        backendRetirementSupervisor: BackendRetirementSupervisor,
        permissionCoordinator: AscendantPermissionCoordinator,
        projectionRelay: NodeProjectionRelay,
        backendWorkspaceCapability: BackendWorkspaceDiscoveryCapability?,
        ascendantAdapters: [UUID: any AscendantBackend],
        backendIdentities: [AscendantBackendIdentity],
        backendSpecs: [UUID: BackendSpec],
        backendHealth: [UUID: AscendantBackendHealth],
        backendLeases: [UUID: UUID]
    ) {
        self.plan = plan
        self.adapters = adapters
        self.registry = registry
        self.lifetime = lifetime
        self.backendWorkspaceService = backendWorkspaceService
        self.backendRetirementSupervisor = backendRetirementSupervisor
        self.permissionCoordinator = permissionCoordinator
        self.projectionRelay = projectionRelay
        self.backendWorkspaceCapability = backendWorkspaceCapability
        self.ascendantAdapters = ascendantAdapters
        self.backendIdentities = backendIdentities
        self.backendSpecs = backendSpecs
        backendHealthByID = backendHealth
        self.backendLeases = backendLeases
    }

    var identities: [AscendantBackendIdentity] { backendIdentities }

    var isRunning: Bool { lifetime.isRunning }
    var isClosed: Bool { lifetime.state == .closed }
    var lifecycleGeneration: UInt64 { lifetime.generation }

    func bind(attachWorkspace: @escaping (UUID, UUID, UUID, UUID) async throws -> Void) {
        backendWorkspaceAttachment = attachWorkspace
    }

    func health(for ascendantID: UUID) -> AscendantBackendHealth {
        backendHealthByID[ascendantID] ?? .unknown
    }

    func enabledToolIDs(for timelineID: UUID) async throws -> [String] {
        guard let ascendantID = await registry.operatorID(forTimeline: timelineID),
              backendHealthByID[ascendantID] == .healthy,
              let backend = ascendantAdapters[ascendantID] else {
            throw NodeRuntimeError.noOperatingAscendant(timelineID)
        }
        guard let adapter = backend as? any AscendantBackendWorkspaceCapability else { return [] }
        return await adapter.enabledToolIDs(for: timelineID)
    }

    func session(for ascendantID: UUID, generation: UInt64? = nil) -> AscendantBackendSession? {
        guard lifetime.state != .closed,
              backendHealthByID[ascendantID] == .healthy,
              let backend = ascendantAdapters[ascendantID],
              let lease = backendLeases[ascendantID] else { return nil }
        let currentGeneration = lifetime.generation
        guard generation == nil || generation == currentGeneration else { return nil }
        return AscendantBackendSession(
            ascendantID: ascendantID,
            backend: backend,
            lease: lease,
            generation: currentGeneration
        )
    }

    func session(for ascendantID: UUID) -> AscendantBackendSession? {
        session(for: ascendantID, generation: nil)
    }

    func sessionForTurn(_ ascendantID: UUID) async throws -> AscendantBackendSession {
        guard lifetime.state == .running else { throw NodeRuntimeError.notRunning }
        guard backendSpecs[ascendantID] != nil else {
            throw NodeRuntimeError.unknownAscendant(ascendantID)
        }
        if let session = session(for: ascendantID) {
            return session
        }
        _ = try await reconstructBackend(for: ascendantID)
        guard let session = session(for: ascendantID) else { throw NodeRuntimeError.notRunning }
        return session
    }

    func isCurrentBackend(
        _ ascendantID: UUID,
        backend: any AscendantBackend,
        generation: UInt64
    ) -> Bool {
        guard let session = session(for: ascendantID, generation: generation) else { return false }
        return (session.backend as AnyObject) === (backend as AnyObject)
    }

    func isCurrentSession(_ session: AscendantBackendSession) -> Bool {
        guard let current = self.session(for: session.ascendantID, generation: session.generation) else { return false }
        return current.lease == session.lease
            && (current.backend as AnyObject) === (session.backend as AnyObject)
    }

    func lease(for ascendantID: UUID, backend: any AscendantBackend) -> UUID? {
        guard let session = session(for: ascendantID),
              (session.backend as AnyObject) === (backend as AnyObject) else { return nil }
        return session.lease
    }

    func markLifecycleFailure(
        _ session: AscendantBackendSession,
        failure: AscendantBackendLifecycleFailure
    ) async {
        guard let current = self.session(for: session.ascendantID, generation: session.generation),
              current.lease == session.lease,
              (current.backend as AnyObject) === (session.backend as AnyObject) else { return }
        await quarantineBackend(session.ascendantID, failure: failure)
    }

    func markLifecycleFailure(
        _ ascendantID: UUID,
        backend failedBackend: any AscendantBackend,
        failure: AscendantBackendLifecycleFailure
    ) async {
        guard backendSpecs[ascendantID] != nil,
              let currentBackend = ascendantAdapters[ascendantID],
              (currentBackend as AnyObject) === (failedBackend as AnyObject) else { return }
        await quarantineBackend(ascendantID, failure: failure)
    }

    private func quarantineBackend(_ ascendantID: UUID, failure _: AscendantBackendLifecycleFailure) async {
        guard backendSpecs[ascendantID] != nil,
              let backend = ascendantAdapters.removeValue(forKey: ascendantID) else { return }
        backendHealthByID[ascendantID] = .failed
        readvertiseAscendant(ascendantID, health: .failed)
        backendLeases.removeValue(forKey: ascendantID)
        await registry.invalidateBackendLease(for: ascendantID)
        retiredBackends.append(backend)
        await backendRetirementSupervisor.retire(
            [(id: ascendantID, backend: backend)],
            stage: .quarantine
        )
    }

    func cancelReconstructions() {
        reconstructionTasks.values.forEach { $0.cancel() }
        reconstructionTasks.removeAll()
    }

    func retireAll(stage: BackendRetirementSupervisor.Stage) async {
        let backends = ascendantAdapters.map { (id: $0.key, backend: $0.value) }
        ascendantAdapters.removeAll()
        backendLeases.removeAll()
        for backend in backends { backendHealthByID[backend.id] = .unknown }
        retiredBackends.append(contentsOf: backends.map(\.backend))
        await backendRetirementSupervisor.retire(backends, stage: stage)
    }

    private func reconstructBackend(for ascendantID: UUID) async throws -> any AscendantBackend {
        if let task = reconstructionTasks[ascendantID] {
            return try await task.value
        }
        guard let spec = backendSpecs[ascendantID] else {
            throw NodeRuntimeError.unknownAscendant(ascendantID)
        }

        let generation = lifetime.generation
        backendHealthByID[ascendantID] = .unknown
        readvertiseAscendant(ascendantID, health: .unknown)
        let task = Task { @MainActor [weak self] () throws -> any AscendantBackend in
            guard let self else { throw NodeRuntimeError.notRunning }
            var candidate: (any AscendantBackend)?
            do {
                guard self.isCurrentReconstructionGeneration(generation) else {
                    throw NodeRuntimeError.notRunning
                }
                let state = await self.registry.backendReconstructionState(for: ascendantID)
                let lease = UUID.makeVersion4()
                let attachmentCapability = BackendWorkspaceAttachmentCapability { [weak self] workspaceID, timelineID in
                    guard let self, let attachment = self.backendWorkspaceAttachment else { throw NodeRuntimeError.notRunning }
                    try await attachment(workspaceID, timelineID, ascendantID, lease)
                }
                var optionalCapabilities: [any AscendantBackendOptionalCapability] = [attachmentCapability]
                if let workspaceCapability = self.backendWorkspaceCapability {
                    optionalCapabilities.insert(workspaceCapability, at: 0)
                }
                let services = AscendantBackendServices(
                    workspace: self.backendWorkspaceService,
                    permission: self.permissionCoordinator,
                    optionalCapabilities: optionalCapabilities
                )
                let created = try await self.adapters.ascendants.makeBackend(
                    for: spec.ascendant,
                    backend: spec.configuration,
                    services: services,
                    timelines: state.timelines
                )
                candidate = created
                guard !self.isRetiredBackend(created) else {
                    throw ReconstructionFailure(detail: "backend factory returned a retired instance")
                }
                guard self.isCurrentReconstructionGeneration(generation) else {
                    candidate = nil
                    await self.retireCandidate(ascendantID, backend: created)
                    throw NodeRuntimeError.notRunning
                }
                try created.validateConfiguration()
                let projected = try await created.operatedTimelines()
                try Self.validateReplacement(candidate: created, projected: projected, spec: spec, state: state)
                guard self.isCurrentReconstructionGeneration(generation) else {
                    candidate = nil
                    await self.retireCandidate(ascendantID, backend: created)
                    throw NodeRuntimeError.notRunning
                }
                let currentRevision = await self.registry.backendRevision(for: ascendantID)
                guard currentRevision == state.revision else {
                    candidate = nil
                    await self.retireCandidate(ascendantID, backend: created)
                    throw ReconstructionFailure(detail: "registry changed during reconstruction")
                }
                guard await self.registry.activateBackendLease(lease, for: ascendantID, generation: generation) else {
                    candidate = nil
                    await self.retireCandidate(ascendantID, backend: created)
                    throw NodeRuntimeError.notRunning
                }
                guard self.isCurrentReconstructionGeneration(generation) else {
                    await self.registry.invalidateBackendLease(for: ascendantID)
                    candidate = nil
                    await self.retireCandidate(ascendantID, backend: created)
                    throw NodeRuntimeError.notRunning
                }
                self.backendLeases[ascendantID] = lease
                self.ascendantAdapters[ascendantID] = created
                self.backendHealthByID[ascendantID] = .healthy
                self.readvertiseAscendant(ascendantID, health: .healthy)
                candidate = nil
                return created
            } catch {
                if let candidate {
                    await self.retireCandidate(ascendantID, backend: candidate)
                }
                guard generation == self.lifetime.generation, self.lifetime.state == .running else {
                    throw error
                }
                self.backendHealthByID[ascendantID] = .failed
                self.readvertiseAscendant(ascendantID, health: .failed)
                if let failure = error as? ReconstructionFailure { throw failure }
                throw ReconstructionFailure(detail: error.localizedDescription)
            }
        }
        reconstructionTasks[ascendantID] = task
        do {
            let backend = try await task.value
            reconstructionTasks.removeValue(forKey: ascendantID)
            return backend
        } catch {
            reconstructionTasks.removeValue(forKey: ascendantID)
            throw error
        }
    }

    private func retireCandidate(_ ascendantID: UUID, backend: any AscendantBackend) async {
        await backendRetirementSupervisor.retire(
            [(id: ascendantID, backend: backend)],
            stage: .reconstructionCandidate
        )
    }

    private func isRetiredBackend(_ candidate: any AscendantBackend) -> Bool {
        retiredBackends.contains { retired in
            (retired as AnyObject) === (candidate as AnyObject)
        }
    }

    private func readvertiseAscendant(_ ascendantID: UUID, health: AscendantBackendHealth) {
        guard let identity = backendIdentities.first(where: { $0.id == ascendantID }) else { return }
        projectionRelay.projectAscendant(identity, health: health, replacing: true)
    }

    private func isCurrentReconstructionGeneration(_ generation: UInt64) -> Bool {
        generation == lifetime.generation && lifetime.state == .running && !Task.isCancelled
    }

    private static func validateReplacement(
        candidate: any AscendantBackend,
        projected: [AscendantBackendTimeline],
        spec: BackendSpec,
        state: NodeRegistry.BackendReconstructionState
        ) throws {
        guard candidate.identity.id == spec.ascendant.id,
              candidate.identity.privateTimelineID == spec.ascendant.defaultTimelineID else {
            throw NodeRuntimeError.unknownAscendant(candidate.identity.id)
        }
        let expectedIDs = Set(state.timelines.map(\.id))
        let projectedIDs = Set(projected.map(\.id))
        guard expectedIDs.isSubset(of: projectedIDs) else {
            if let missing = expectedIDs.subtracting(projectedIDs).first {
                throw NodeRuntimeError.missingTimeline(missing)
            }
            throw ReconstructionFailure(detail: "replacement omitted an operated Timeline")
        }
        for timeline in projected where expectedIDs.contains(timeline.id) {
            guard timeline.attachedAscendantID == spec.ascendant.id else {
                throw NodeRuntimeError.unknownAscendant(timeline.attachedAscendantID ?? spec.ascendant.id)
            }
        }
    }
}
