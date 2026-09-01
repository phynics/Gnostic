// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The lease and runtime lifetime captured when an Ascendant backend session
/// was admitted. Registry writes use this value as one inseparable fence.
struct BackendSessionContext: Sendable, Equatable {
    let ascendantID: UUID
    let lease: UUID
    let generation: UInt64
}

/// The runtime generation captured before a Turn enters coordinator admission.
/// It prevents a queued Turn from executing in a later runtime lifetime.
struct BackendTurnAdmission: Sendable, Equatable {
    let generation: UInt64
}

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

    var context: BackendSessionContext {
        .init(ascendantID: ascendantID, lease: lease, generation: generation)
    }
}

/// An operation-scoped Ascendant session. It strongly retains the native
/// backend for the operation while exposing only lease-fenced capabilities to
/// Gnostic services.
@MainActor
struct LeasedAscendantBackendSession {
    let context: BackendSessionContext
    private let backend: any AscendantBackend
    private let provider: any BackendSessionProviding

    init(
        context: BackendSessionContext,
        backend: any AscendantBackend,
        provider: any BackendSessionProviding
    ) {
        self.context = context
        self.backend = backend
        self.provider = provider
    }

    func timeline(id: UUID) async throws -> LeasedBackendTimelineSession {
        let native = try await performLeasedBackendCall(context: context, provider: provider) {
            try await backend.timeline(id: id)
        }
        guard native.id == id else {
            let violation = AscendantBackendContractViolation.sessionTimelineMismatch(
                expected: id,
                actual: native.id
            )
            await provider.markContractViolation(context, violation: violation)
            throw AscendantBackendError.contractViolation(violation)
        }
        return LeasedBackendTimelineSession(
            id: id,
            context: context,
            timeline: native,
            provider: provider
        )
    }

    func createTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        let projection = try await performLeasedBackendCall(context: context, provider: provider) {
            try await backend.createTimeline(id: id, title: title)
        }
        return try await validateBackendProjection(
            projection,
            expectedTimelineID: id,
            context: context,
            provider: provider
        )
    }

    func removeTimeline(id: UUID) async throws {
        try await performLeasedBackendCall(context: context, provider: provider) {
            await backend.removeTimeline(id: id)
        }
    }
}

/// A Timeline execution session fenced by the backend lease that opened it.
/// The wrapper keeps lifecycle policy out of TurnService while the backend's
/// Timeline session owns provider-native execution state.
@MainActor
struct LeasedBackendTimelineSession {
    let id: UUID
    let context: BackendSessionContext
    private let timeline: any AscendantBackendTimelineSession
    private let provider: any BackendSessionProviding

    init(
        id: UUID,
        context: BackendSessionContext,
        timeline: any AscendantBackendTimelineSession,
        provider: any BackendSessionProviding
    ) {
        self.id = id
        self.context = context
        self.timeline = timeline
        self.provider = provider
    }

    func runTurn(
        _ request: AscendantBackendTimelineTurnRequest,
        updates: any AscendantBackendUpdateSink
    ) async throws -> String {
        guard !Task.isCancelled,
              provider.isRunning,
              provider.isCurrentSession(context) else {
            throw CancellationError()
        }
        let updateGate = LeaseFencedUpdateGate()
        let fencedUpdates = LeaseFencedUpdateSink(
            updates: updates,
            context: context,
            provider: provider,
            gate: updateGate
        )
        do {
            let result = try await withTaskCancellationHandler(operation: {
                try await timeline.runTurn(request, updates: fencedUpdates)
            }, onCancel: {
                updateGate.close()
            })
            updateGate.close()
            guard !Task.isCancelled,
                  provider.isRunning,
                  provider.isCurrentSession(context) else {
                throw CancellationError()
            }
            return result
        } catch let error as AscendantBackendError {
            updateGate.close()
            guard !Task.isCancelled,
                  provider.isRunning,
                  provider.isCurrentSession(context) else {
                throw CancellationError()
            }
            if case let .lifecycleUnusable(failure) = error,
               provider.isCurrentSession(context) {
                await provider.markLifecycleFailure(context, failure: failure)
            }
            throw error
        } catch {
            updateGate.close()
            guard !Task.isCancelled,
                  provider.isRunning,
                  provider.isCurrentSession(context) else {
                throw CancellationError()
            }
            throw error
        }
    }

    func rename(to title: String) async throws -> AscendantBackendTimeline {
        let projection = try await performLeasedBackendCall(context: context, provider: provider) {
            try await timeline.rename(to: title)
        }
        return try await validateBackendProjection(
            projection,
            expectedTimelineID: id,
            context: context,
            provider: provider
        )
    }
}

/// Drops updates after the backend lease that produced them is no longer
/// current. A backend may continue producing events while retirement is
/// bounded, but those events must not reach the active Turn stream.
private struct LeaseFencedUpdateSink: AscendantBackendUpdateSink {
    let updates: any AscendantBackendUpdateSink
    let context: BackendSessionContext
    let provider: any BackendSessionProviding
    let gate: LeaseFencedUpdateGate

    func append(_ update: AscendantBackendUpdate) async {
        guard gate.isOpen,
              !Task.isCancelled,
              await provider.isCurrentSession(context) else { return }
        guard gate.isOpen, !Task.isCancelled else { return }
        await updates.append(update)
    }
}

/// Synchronously closes a Turn's update channel from both its owner task and
/// its cancellation handler. The sink remains safe to retain after the native
/// backend returns because late provider callbacks observe this closed gate.
private final class LeaseFencedUpdateGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    func close() {
        lock.lock()
        open = false
        lock.unlock()
    }
}

/// Typed admission boundary shared by domain services. The supervisor owns
/// the lifecycle and lease policy; services never receive callback bundles.
@MainActor
protocol BackendSessionProviding: AnyObject, Sendable {
    var isRunning: Bool { get }
    var isClosed: Bool { get }
    var lifecycleGeneration: UInt64 { get }
    func turnAdmission() throws -> BackendTurnAdmission
    func session(for ascendantID: UUID) -> LeasedAscendantBackendSession?
    func rawSession(for ascendantID: UUID) -> AscendantBackendSession?
    func sessionForTurn(
        timelineID: UUID,
        operatedBy ascendantID: UUID,
        admittedUnder admission: BackendTurnAdmission
    ) async throws -> LeasedAscendantBackendSession
    func isCurrentSession(_ context: BackendSessionContext) -> Bool
    func markLifecycleFailure(_ context: BackendSessionContext, failure: AscendantBackendLifecycleFailure) async
    func markContractViolation(_ context: BackendSessionContext, violation: AscendantBackendContractViolation) async

    // Transitional raw-session operations remain for Workspace until PR3.
    func isCurrentBackend(_ ascendantID: UUID, backend: any AscendantBackend, generation: UInt64) -> Bool
    func isCurrentSession(_ session: AscendantBackendSession) -> Bool
    func lease(for ascendantID: UUID, backend: any AscendantBackend) -> UUID?
    func markLifecycleFailure(_ session: AscendantBackendSession, failure: AscendantBackendLifecycleFailure) async
    func markLifecycleFailure(_ ascendantID: UUID, backend: any AscendantBackend, failure: AscendantBackendLifecycleFailure) async
    func markContractViolation(_ session: AscendantBackendSession, violation: AscendantBackendContractViolation) async
}

@MainActor
private func performLeasedBackendCall<T>(
    context: BackendSessionContext,
    provider: any BackendSessionProviding,
    operation: @escaping @MainActor () async throws -> T
) async throws -> T {
    guard !Task.isCancelled, provider.isCurrentSession(context) else {
        throw NodeRuntimeError.notRunning
    }
    do {
        let result = try await operation()
        guard !Task.isCancelled, provider.isCurrentSession(context) else {
            throw NodeRuntimeError.notRunning
        }
        return result
    } catch let error as AscendantBackendError {
        guard !Task.isCancelled, provider.isCurrentSession(context) else {
            throw NodeRuntimeError.notRunning
        }
        if case let .lifecycleUnusable(failure) = error {
            await provider.markLifecycleFailure(context, failure: failure)
        }
        throw error
    } catch {
        guard !Task.isCancelled, provider.isCurrentSession(context) else {
            throw NodeRuntimeError.notRunning
        }
        throw error
    }
}

@MainActor
private func validateBackendProjection(
    _ projection: AscendantBackendTimeline,
    expectedTimelineID: UUID,
    context: BackendSessionContext,
    provider: any BackendSessionProviding
) async throws -> AscendantBackendTimeline {
    guard projection.id == expectedTimelineID else {
        let violation = AscendantBackendContractViolation.projectionTimelineMismatch(
            expected: expectedTimelineID,
            actual: projection.id
        )
        await provider.markContractViolation(context, violation: violation)
        throw AscendantBackendError.contractViolation(violation)
    }
    guard projection.ascendantID == context.ascendantID else {
        let violation = AscendantBackendContractViolation.projectionAscendantMismatch(
            expected: context.ascendantID,
            actual: projection.ascendantID
        )
        await provider.markContractViolation(context, violation: violation)
        throw AscendantBackendError.contractViolation(violation)
    }
    return projection
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
    private var admittedBackends: [UUID: (backend: any AscendantBackend, context: BackendSessionContext)] = [:]

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

    func turnAdmission() throws -> BackendTurnAdmission {
        guard running() else { throw NodeRuntimeError.notRunning }
        return .init(generation: generation())
    }

    func rawSession(for ascendantID: UUID) -> AscendantBackendSession? {
        guard let backend = adapter(ascendantID) else { return nil }
        return AscendantBackendSession(
            ascendantID: ascendantID,
            backend: backend,
            lease: backendLease(ascendantID, backend) ?? UUID(),
            generation: lifecycleGeneration
        )
    }

    func session(for ascendantID: UUID) -> LeasedAscendantBackendSession? {
        guard let raw = rawSession(for: ascendantID) else { return nil }
        return LeasedAscendantBackendSession(context: raw.context, backend: raw.backend, provider: self)
    }

    func sessionForTurn(
        timelineID _: UUID,
        operatedBy ascendantID: UUID,
        admittedUnder admission: BackendTurnAdmission
    ) async throws -> LeasedAscendantBackendSession {
        guard !Task.isCancelled, running() else {
            throw CancellationError()
        }
        guard generation() == admission.generation else {
            throw CancellationError()
        }
        let backend: any AscendantBackend
        do {
            backend = try await self.backend(ascendantID)
        } catch {
            guard !Task.isCancelled, running(), generation() == admission.generation else {
                throw CancellationError()
            }
            throw error
        }
        guard !Task.isCancelled, running(), generation() == admission.generation else {
            throw CancellationError()
        }
        let raw = AscendantBackendSession(
            ascendantID: ascendantID,
            backend: backend,
            lease: backendLease(ascendantID, backend) ?? UUID(),
            generation: lifecycleGeneration
        )
        admittedBackends[ascendantID] = (backend: backend, context: raw.context)
        return LeasedAscendantBackendSession(context: raw.context, backend: raw.backend, provider: self)
    }

    func isCurrentSession(_ context: BackendSessionContext) -> Bool {
        guard running(), generation() == context.generation else { return false }
        let backend = currentBackend(for: context)
        guard let backend else { return false }
        guard current(context.ascendantID, backend, context.generation) else { return false }
        guard let lease = backendLease(context.ascendantID, backend) else { return true }
        return lease == context.lease
    }

    func isCurrentBackend(_ ascendantID: UUID, backend: any AscendantBackend, generation: UInt64) -> Bool {
        current(ascendantID, backend, generation)
    }

    func isCurrentSession(_ session: AscendantBackendSession) -> Bool {
        isCurrentSession(session.context)
    }

    func lease(for ascendantID: UUID, backend: any AscendantBackend) -> UUID? {
        backendLease(ascendantID, backend)
    }

    func markLifecycleFailure(_ session: AscendantBackendSession, failure: AscendantBackendLifecycleFailure) async {
        guard isCurrentSession(session) else { return }
        await self.failure(session.ascendantID, session.backend, failure)
    }

    func markLifecycleFailure(
        _ context: BackendSessionContext,
        failure: AscendantBackendLifecycleFailure
    ) async {
        guard isCurrentSession(context),
              let backend = currentBackend(for: context) else { return }
        await self.failure(context.ascendantID, backend, failure)
    }

    private func currentBackend(for context: BackendSessionContext) -> (any AscendantBackend)? {
        if let backend = adapter(context.ascendantID) {
            return backend
        }
        guard let admitted = admittedBackends[context.ascendantID], admitted.context == context else {
            return nil
        }
        return admitted.backend
    }

    func markLifecycleFailure(_ ascendantID: UUID, backend: any AscendantBackend, failure: AscendantBackendLifecycleFailure) async {
        await self.failure(ascendantID, backend, failure)
    }

    func markContractViolation(_ session: AscendantBackendSession, violation: AscendantBackendContractViolation) async {
        await markLifecycleFailure(
            session,
            failure: .init(code: "backendContractViolation", message: violation.localizedDescription)
        )
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

    func turnAdmission() throws -> BackendTurnAdmission {
        guard lifetime.state == .running else { throw NodeRuntimeError.notRunning }
        return .init(generation: lifetime.generation)
    }

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

    func rawSession(for ascendantID: UUID, generation: UInt64? = nil) -> AscendantBackendSession? {
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

    func rawSession(for ascendantID: UUID) -> AscendantBackendSession? {
        rawSession(for: ascendantID, generation: nil)
    }

    func session(for ascendantID: UUID) -> LeasedAscendantBackendSession? {
        guard let raw = rawSession(for: ascendantID) else { return nil }
        return LeasedAscendantBackendSession(context: raw.context, backend: raw.backend, provider: self)
    }

    func sessionForTurn(
        timelineID _: UUID,
        operatedBy ascendantID: UUID,
        admittedUnder admission: BackendTurnAdmission
    ) async throws -> LeasedAscendantBackendSession {
        guard !Task.isCancelled, lifetime.state == .running else {
            throw CancellationError()
        }
        guard lifetime.generation == admission.generation else {
            throw CancellationError()
        }
        guard backendSpecs[ascendantID] != nil else {
            throw NodeRuntimeError.unknownAscendant(ascendantID)
        }
        if let raw = rawSession(for: ascendantID, generation: admission.generation) {
            return LeasedAscendantBackendSession(context: raw.context, backend: raw.backend, provider: self)
        }
        do {
            _ = try await reconstructBackend(for: ascendantID)
        } catch {
            guard !Task.isCancelled,
                  lifetime.state == .running,
                  lifetime.generation == admission.generation else {
                throw CancellationError()
            }
            throw error
        }
        guard !Task.isCancelled,
              lifetime.state == .running,
              lifetime.generation == admission.generation,
              let raw = rawSession(for: ascendantID, generation: admission.generation) else {
            throw CancellationError()
        }
        return LeasedAscendantBackendSession(context: raw.context, backend: raw.backend, provider: self)
    }

    func isCurrentSession(_ context: BackendSessionContext) -> Bool {
        guard lifetime.state != .closed,
              lifetime.generation == context.generation,
              backendHealthByID[context.ascendantID] == .healthy,
              backendLeases[context.ascendantID] == context.lease,
              ascendantAdapters[context.ascendantID] != nil else { return false }
        return true
    }

    func isCurrentBackend(
        _ ascendantID: UUID,
        backend: any AscendantBackend,
        generation: UInt64
    ) -> Bool {
        guard let session = rawSession(for: ascendantID, generation: generation) else { return false }
        return (session.backend as AnyObject) === (backend as AnyObject)
    }

    func isCurrentSession(_ session: AscendantBackendSession) -> Bool {
        guard let current = self.rawSession(for: session.ascendantID, generation: session.generation) else { return false }
        return current.lease == session.lease
            && (current.backend as AnyObject) === (session.backend as AnyObject)
    }

    func lease(for ascendantID: UUID, backend: any AscendantBackend) -> UUID? {
        guard let session = rawSession(for: ascendantID),
              (session.backend as AnyObject) === (backend as AnyObject) else { return nil }
        return session.lease
    }

    func markLifecycleFailure(
        _ session: AscendantBackendSession,
        failure: AscendantBackendLifecycleFailure
    ) async {
        guard let current = self.rawSession(for: session.ascendantID, generation: session.generation),
              current.lease == session.lease,
              (current.backend as AnyObject) === (session.backend as AnyObject) else { return }
        await quarantineBackend(session.ascendantID, failure: failure)
    }

    func markLifecycleFailure(
        _ context: BackendSessionContext,
        failure: AscendantBackendLifecycleFailure
    ) async {
        guard isCurrentSession(context) else { return }
        await quarantineBackend(context.ascendantID, failure: failure)
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

    func markContractViolation(
        _ session: AscendantBackendSession,
        violation: AscendantBackendContractViolation
    ) async {
        await markLifecycleFailure(
            session,
            failure: .init(code: "backendContractViolation", message: violation.localizedDescription)
        )
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
                    candidate = nil
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
