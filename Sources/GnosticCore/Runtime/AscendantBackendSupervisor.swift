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

/// Small read/lease seam shared by domain services. It keeps backend policy
/// callbacks in one typed boundary rather than repeating a bundle at every
/// service construction site.
@MainActor
struct BackendSessionAccess {
    let isRunning: @MainActor () -> Bool
    let isClosed: @MainActor () -> Bool
    let lifecycleGeneration: @MainActor () -> UInt64
    let session: @MainActor (UUID) -> AscendantBackendSession?
    let isCurrent: @MainActor (UUID, any AscendantBackend, UInt64) -> Bool
    let lease: @MainActor (UUID, any AscendantBackend) -> UUID?
    let lifecycleFailure: @MainActor (UUID, any AscendantBackend, AscendantBackendLifecycleFailure) async -> Void

    func adapter(_ ascendantID: UUID) -> (any AscendantBackend)? { session(ascendantID)?.backend }
}

/// Owns backend instances, health, leases, reconstruction single-flight, and
/// bounded retirement. NodeRuntime only composes this module and delegates to
/// it; Timeline, Workspace, and Turn operations never inspect backend slots.
@MainActor
final class AscendantBackendSupervisor {
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

    func backendForTurn(_ ascendantID: UUID) async throws -> any AscendantBackend {
        guard lifetime.state == .running else { throw NodeRuntimeError.notRunning }
        guard backendSpecs[ascendantID] != nil else {
            throw NodeRuntimeError.unknownAscendant(ascendantID)
        }
        if let backend = session(for: ascendantID)?.backend {
            return backend
        }
        return try await reconstructBackend(for: ascendantID)
    }

    func isCurrentBackend(
        _ ascendantID: UUID,
        backend: any AscendantBackend,
        generation: UInt64
    ) -> Bool {
        guard let session = session(for: ascendantID, generation: generation) else { return false }
        return (session.backend as AnyObject) === (backend as AnyObject)
    }

    func lease(for ascendantID: UUID, backend: any AscendantBackend) -> UUID? {
        guard let session = session(for: ascendantID),
              (session.backend as AnyObject) === (backend as AnyObject) else { return nil }
        return session.lease
    }

    func markLifecycleFailure(
        _ ascendantID: UUID,
        backend failedBackend: any AscendantBackend,
        failure _: AscendantBackendLifecycleFailure
    ) async {
        guard backendSpecs[ascendantID] != nil,
              let currentBackend = ascendantAdapters[ascendantID],
              (currentBackend as AnyObject) === (failedBackend as AnyObject) else { return }
        backendHealthByID[ascendantID] = .failed
        readvertiseAscendant(ascendantID, health: .failed)
        backendLeases.removeValue(forKey: ascendantID)
        await registry.invalidateBackendLease(for: ascendantID)
        if let backend = ascendantAdapters.removeValue(forKey: ascendantID) {
            await backendRetirementSupervisor.retire(
                [(id: ascendantID, backend: backend)],
                stage: .quarantine
            )
        }
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
