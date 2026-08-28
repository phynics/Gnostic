// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKContracts
import PositronicKit

@MainActor
public final class WorkspaceService {
    private let plan: NodeLaunchPlan
    private let registry: NodeRegistry
    private let discovery: any WorkspaceDiscovery
    private let localWorkspaces: [UUID: any WorkspaceProvider]
    private let backendWorkspaceService: GnosticWorkspaceBackendService?
    private let adapter: @MainActor (UUID) -> (any AscendantBackend)?
    private let isRunning: @MainActor () -> Bool
    private let lifecycleGeneration: @MainActor () -> UInt64
    private let isCurrentBackend: @MainActor (UUID, any AscendantBackend, UInt64) -> Bool
    private let backendLease: @MainActor (UUID, any AscendantBackend) -> UUID?
    private let lifecycleFailure: @MainActor (UUID, any AscendantBackend, AscendantBackendLifecycleFailure) async -> Void
    private let readvertiseTimeline: @MainActor (AscendantRuntimeTimeline) -> Void
    private var references: [UUID: WorkspaceReference]
    private var quarantinedAscendantIDs: Set<UUID> = []

    init(
        plan: NodeLaunchPlan,
        registry: NodeRegistry,
        discovery: any WorkspaceDiscovery,
        localWorkspaces: [UUID: any WorkspaceProvider],
        references: [UUID: WorkspaceReference],
        backendWorkspaceService: GnosticWorkspaceBackendService? = nil,
        isRunning: @escaping @MainActor () -> Bool,
        lifecycleGeneration: @escaping @MainActor () -> UInt64 = { 0 },
        isCurrentBackend: @escaping @MainActor (UUID, any AscendantBackend, UInt64) -> Bool = { _, _, _ in true },
        backendLease: @escaping @MainActor (UUID, any AscendantBackend) -> UUID? = { _, _ in nil },
        adapter: @escaping @MainActor (UUID) -> (any AscendantBackend)?,
        lifecycleFailure: @escaping @MainActor (UUID, any AscendantBackend, AscendantBackendLifecycleFailure) async -> Void = { _, _, _ in },
        readvertiseTimeline: @escaping @MainActor (AscendantRuntimeTimeline) -> Void
    ) {
        self.plan = plan; self.registry = registry; self.discovery = discovery
        self.localWorkspaces = localWorkspaces; self.references = references
        self.backendWorkspaceService = backendWorkspaceService
        self.isRunning = isRunning
        self.lifecycleGeneration = lifecycleGeneration
        self.isCurrentBackend = isCurrentBackend
        self.backendLease = backendLease
        self.adapter = adapter
        self.lifecycleFailure = lifecycleFailure
        self.readvertiseTimeline = readvertiseTimeline
    }

    func reference(id: UUID) async -> WorkspaceReference? {
        guard let record = await registry.workspace(id: id), let reference = references[id],
              record.isAvailable || reference.tools.isEmpty,
              reference.uri.description == record.uri else { return nil }
        return reference
    }

    func localReferences() -> [WorkspaceReference] {
        references.values.filter { reference in plan.workspaces.contains { $0.id == reference.id } }
    }

    func executeLocalTool(workspaceID: UUID, toolID: String, arguments: [String: AnyCodable]) async throws -> ToolResult {
        guard isRunning() else { throw NodeRuntimeError.notRunning }
        guard let workspace = localWorkspaces[workspaceID] as? any WorkspaceToolProvider else { throw NodeRuntimeError.missingWorkspace(workspaceID) }
        return try await workspace.executeTool(id: toolID, parameters: arguments)
    }

    func listAttachable() async -> [WorkspaceListing] {
        var listings = Dictionary(uniqueKeysWithValues: plan.workspaces.map {
            ($0.id, WorkspaceListing(id: $0.id, name: $0.name, isAvailable: true))
        })
        for entry in await discovery.objects() where entry.objectType == GnosticObjectType.workspace
            && entry.workspace?.isAvailable == true && listings[entry.objectID] == nil {
            guard case .available = await discovery.attachmentStatus(id: entry.objectID) else { continue }
            listings[entry.objectID] = WorkspaceListing(id: entry.objectID, name: entry.name, isAvailable: true)
        }
        return listings.values.sorted { ($0.id.uuidString, $0.name) < ($1.id.uuidString, $1.name) }
    }

    func attach(_ request: WorkspaceOpsRequest) async throws -> Bool {
        let (ascendantID, backend, generation, lease) = try await operatingAdapter(for: request.timelineID)
        guard let runtime = backend as? any AscendantBackendWorkspaceCapability else {
            throw NodeRuntimeError.workspaceCapabilityUnavailable(request.timelineID)
        }
        let reference: WorkspaceReference
        if localWorkspaces[request.workspaceID] != nil, let local = references[request.workspaceID] {
            reference = local
        } else {
            reference = try await resolveNetworkWorkspace(workspaceID: request.workspaceID)
        }
        try await attach(
            reference: reference,
            workspaceID: request.workspaceID,
            timelineID: request.timelineID,
            ascendantID: ascendantID,
            backend: backend,
            generation: generation,
            lease: lease,
            runtime: runtime
        )
        return true
    }

    /// Handles an attachment requested by a backend-owned model/tool path.
    /// The capability is bound to the caller's Ascendant and backend lease;
    /// canonical intent is committed only after the backend projection is
    /// accepted and the current Timeline is readvertised.
    func attachFromBackend(
        workspaceID: UUID,
        timelineID: UUID,
        ascendantID expectedAscendantID: UUID,
        backendLease expectedBackendLease: UUID
    ) async throws {
        let (ascendantID, backend, generation, lease) = try await operatingAdapter(for: timelineID)
        guard ascendantID == expectedAscendantID, lease == expectedBackendLease else {
            throw NodeRuntimeError.notRunning
        }
        let reference = try await resolveNetworkWorkspace(workspaceID: workspaceID)
        guard let runtime = backend as? any AscendantBackendWorkspaceCapability else {
            throw NodeRuntimeError.workspaceCapabilityUnavailable(timelineID)
        }
        try await attach(
            reference: reference,
            workspaceID: workspaceID,
            timelineID: timelineID,
            ascendantID: ascendantID,
            backend: backend,
            generation: generation,
            lease: lease,
            runtime: runtime
        )
    }

    private func attach(
        reference: WorkspaceReference,
        workspaceID: UUID,
        timelineID: UUID,
        ascendantID: UUID,
        backend: any AscendantBackend,
        generation: UInt64,
        lease: UUID?,
        runtime: any AscendantBackendWorkspaceCapability
    ) async throws {
        try await runBackendOperation(ascendantID, backend: backend, generation: generation) {
            try await runtime.attachWorkspace(BackendWorkspaceReference(reference: reference), to: timelineID)
        }
        if let timeline = try await runBackendOperation(ascendantID, backend: backend, generation: generation, { try await backend.operatedTimelines().first(where: { $0.id == timelineID }) }) {
            do {
                guard isCurrentBackend(ascendantID, backend, generation) else { throw NodeRuntimeError.notRunning }
                let record = try await registry.commitBackendTimeline(
                    timeline,
                    ascendantID: ascendantID,
                    backendLease: lease,
                    upserting: Self.intent(for: reference, local: localWorkspaces[workspaceID] != nil)
                )
                guard isCurrentBackend(ascendantID, backend, generation) else { throw NodeRuntimeError.notRunning }
                readvertiseTimeline(record.timeline)
            }
            catch {
                _ = try? await runBackendOperation(ascendantID, backend: backend, generation: generation) {
                    try await runtime.detachWorkspace(workspaceID, from: timelineID)
                }
                throw error
            }
        }
    }

    func detach(_ request: WorkspaceOpsRequest) async throws -> Bool {
        let (ascendantID, backend, generation, lease) = try await operatingAdapter(for: request.timelineID)
        guard let runtime = backend as? any AscendantBackendWorkspaceCapability else {
            throw NodeRuntimeError.workspaceCapabilityUnavailable(request.timelineID)
        }
        let prior = references[request.workspaceID]
        try await runBackendOperation(ascendantID, backend: backend, generation: generation) {
            try await runtime.detachWorkspace(request.workspaceID, from: request.timelineID)
        }
        if let timeline = try await runBackendOperation(ascendantID, backend: backend, generation: generation, { try await backend.operatedTimelines().first(where: { $0.id == request.timelineID }) }) {
            do {
                guard isCurrentBackend(ascendantID, backend, generation) else { throw NodeRuntimeError.notRunning }
                let record = try await registry.commitBackendTimeline(
                    timeline,
                    ascendantID: ascendantID,
                    backendLease: lease,
                    removingWorkspaceID: request.workspaceID
                )
                guard isCurrentBackend(ascendantID, backend, generation) else { throw NodeRuntimeError.notRunning }
                readvertiseTimeline(record.timeline)
            }
            catch {
                if let prior {
                    _ = try? await runBackendOperation(ascendantID, backend: backend, generation: generation) {
                        try await runtime.attachWorkspace(BackendWorkspaceReference(reference: prior), to: request.timelineID)
                    }
                }
                throw error
            }
        }
        return true
    }

    func resolveNetworkWorkspace(workspaceID: UUID, timeout: Duration = .seconds(5)) async throws -> WorkspaceReference {
        guard isRunning() else { throw NodeRuntimeError.notRunning }
        await discovery.discover(timeout: timeout)
        let status = await discovery.attachmentStatus(id: workspaceID)
        await registry.setWorkspaceStatus(id: workspaceID, status: Self.effectiveStatus(status))
        guard case let .available(providerID, uri) = status else {
            throw DiscoveredWorkspaceAttachmentError.unavailable(status)
        }
        if await discovery.descriptor(workspaceID: workspaceID, providerID: providerID)?.toolsComplete == false {
            await discovery.queryTools(workspaceID: workspaceID, timeout: timeout)
        }
        guard let descriptor = await discovery.descriptor(workspaceID: workspaceID, providerID: providerID), descriptor.uri == uri else {
            await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported)
            throw DiscoveredWorkspaceAttachmentError.unavailable(.malformed)
        }
        guard let reference = try? WorkspaceReferenceProjection.reference(from: descriptor) else {
            await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported)
            throw DiscoveredWorkspaceAttachmentError.unavailable(.malformed)
        }
        if let configured = await registry.workspace(id: workspaceID), configured.uri != uri {
            await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported)
            throw DiscoveredWorkspaceAttachmentError.unavailable(.malformed)
        }
        try await installResolved(reference, workspaceID: workspaceID)
        return reference
    }

    func networkAttachmentStatus(workspaceID: UUID) async -> WorkspaceAttachmentStatus {
        await discovery.attachmentStatus(id: workspaceID)
    }

    func refreshUnresolved() async {
        let unresolved = await registry.unresolvedWorkspaceIDs()
        guard !unresolved.isEmpty else { return }
        await discovery.discover(timeout: .milliseconds(250))
        for workspaceID in unresolved {
            _ = try? await resolveAvailableNetworkWorkspace(workspaceID)
        }
    }

    @discardableResult
    func resolveAvailableNetworkWorkspace(_ workspaceID: UUID) async throws -> WorkspaceReference? {
        guard let expectedURI = await registry.workspace(id: workspaceID)?.uri else { return nil }
        let status = await discovery.attachmentStatus(id: workspaceID)
        await registry.setWorkspaceStatus(id: workspaceID, status: Self.effectiveStatus(status))
        guard case let .available(providerID, uri) = status, uri == expectedURI else {
            if case .available = status { await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported) }
            return nil
        }
        if await discovery.descriptor(workspaceID: workspaceID, providerID: providerID)?.toolsComplete == false {
            await discovery.queryTools(workspaceID: workspaceID, timeout: .seconds(5))
        }
        guard let descriptor = await discovery.descriptor(workspaceID: workspaceID, providerID: providerID) else {
            await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported)
            return nil
        }
        guard let reference = try? WorkspaceReferenceProjection.reference(from: descriptor) else {
            await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported)
            return nil
        }
        try await installResolved(reference, workspaceID: workspaceID)
        return reference
    }

    private func operatingAdapter(for timelineID: UUID) async throws -> (UUID, any AscendantBackend, UInt64, UUID?) {
        let ascendantID = try await registry.requireOperatingAscendant(for: timelineID)
        guard !quarantinedAscendantIDs.contains(ascendantID),
              let runtime = adapter(ascendantID) else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
        let generation = lifecycleGeneration()
        guard isCurrentBackend(ascendantID, runtime, generation) else { throw NodeRuntimeError.notRunning }
        return (ascendantID, runtime, generation, backendLease(ascendantID, runtime))
    }

    private func runBackendOperation<T>(
        _ ascendantID: UUID,
        backend: any AscendantBackend,
        generation: UInt64,
        _ operation: () async throws -> T
    ) async throws -> T {
        guard isCurrentBackend(ascendantID, backend, generation) else { throw NodeRuntimeError.notRunning }
        do {
            let result = try await operation()
            guard isCurrentBackend(ascendantID, backend, generation) else { throw NodeRuntimeError.notRunning }
            return result
        } catch let error as AscendantBackendError {
            if case let .lifecycleUnusable(failure) = error {
                guard isCurrentBackend(ascendantID, backend, generation) else { throw error }
                quarantinedAscendantIDs.insert(ascendantID)
                await lifecycleFailure(ascendantID, backend, failure)
            }
            throw error
        }
    }

    private func installResolved(_ reference: WorkspaceReference, workspaceID: UUID) async throws {
        let backendReference = BackendWorkspaceReference(reference: reference)
        var operationContext: (UUID, any AscendantBackend, UInt64)?
        for target in await registry.attachmentTargets(for: workspaceID) {
            guard !quarantinedAscendantIDs.contains(target.ascendantID),
                  let backend = adapter(target.ascendantID),
                  let runtime = backend as? any AscendantBackendWorkspaceCapability else { continue }
            let generation = lifecycleGeneration()
            guard isCurrentBackend(target.ascendantID, backend, generation) else { throw NodeRuntimeError.notRunning }
            operationContext = (target.ascendantID, backend, generation)
            try await runBackendOperation(target.ascendantID, backend: backend, generation: generation) {
                try await runtime.attachWorkspace(backendReference, to: target.timelineID)
            }
        }
        if let (ascendantID, backend, generation) = operationContext {
            guard isCurrentBackend(ascendantID, backend, generation) else { throw NodeRuntimeError.notRunning }
        }
        guard try await registry.resolveLazyWorkspace(id: workspaceID, uri: reference.uri.description, toolIDs: reference.tools.map(\.toolID)) else {
            await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported)
            throw DiscoveredWorkspaceAttachmentError.unavailable(.malformed)
        }
        if let (ascendantID, backend, generation) = operationContext {
            guard isCurrentBackend(ascendantID, backend, generation) else { throw NodeRuntimeError.notRunning }
        }
        references[workspaceID] = reference
        backendWorkspaceService?.update(reference: reference)
    }

    private static func effectiveStatus(_ status: WorkspaceAttachmentStatus) -> NodeRegistry.WorkspaceEffectiveStatus {
        switch status {
        case .available: return .available
        case .unavailable: return .unavailable
        case .ambiguous, .malformed: return .unsupported
        }
    }

    private static func intent(for reference: WorkspaceReference, local: Bool) -> NodeManifest.WorkspaceAttachment {
        local ? .local(reference.id) : .network(reference.id, uri: reference.uri.description)
    }

    func restoreBackend(_ ascendantID: UUID) {
        quarantinedAscendantIDs.remove(ascendantID)
    }
}
