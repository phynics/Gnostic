// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticProtocol

/// The kernel's routing view of every Workspace it knows.
///
/// The service is deliberately backend-neutral: local Workspaces are opaque
/// ``LocalWorkspace`` capabilities and network Workspaces are described by
/// ``BackendWorkspaceReference`` values projected from the catalog. The only
/// provider dependency is the optional ``NetworkWorkspaceInvoking`` seam.
@MainActor
public final class WorkspaceService {
    /// `workspace.attach` has a five-second caller RPC deadline. Keep two
    /// seconds for backend projection, response encoding, and MQTT delivery;
    /// peer discovery and tool resolution share the remaining three seconds.
    private static let attachmentResolutionBudget: Duration = .seconds(3)
    /// Axoloty resolve streams stay open until their timeout and have no
    /// terminal marker. Reserve a bounded discovery window to collect competing
    /// owners, then leave the rest of the attach budget for descriptor pages.
    private static let coldCatalogDiscoveryWindow: Duration = .seconds(1)

    private let plan: NodeLaunchPlan
    private let registry: NodeRegistry
    private let discovery: any WorkspaceDiscovery
    private let localWorkspaces: [UUID: any LocalWorkspace]
    private let backendWorkspaceService: (any WorkspaceReferenceUpdating)?
    private let backendProvider: any BackendSessionProviding
    private let readvertiseTimeline: @MainActor (AscendantRuntimeTimeline) -> Void
    private var references: [UUID: BackendWorkspaceReference]

    init(
        plan: NodeLaunchPlan,
        registry: NodeRegistry,
        discovery: any WorkspaceDiscovery,
        localWorkspaces: [UUID: any LocalWorkspace],
        references: [UUID: BackendWorkspaceReference],
        backendWorkspaceService: (any WorkspaceReferenceUpdating)? = nil,
        backendProvider: any BackendSessionProviding,
        readvertiseTimeline: @escaping @MainActor (AscendantRuntimeTimeline) -> Void
    ) {
        self.plan = plan; self.registry = registry; self.discovery = discovery
        self.localWorkspaces = localWorkspaces; self.references = references
        self.backendWorkspaceService = backendWorkspaceService
        self.backendProvider = backendProvider
        self.readvertiseTimeline = readvertiseTimeline
    }

    func reference(id: UUID) async -> BackendWorkspaceReference? {
        guard let record = await registry.workspace(id: id), let reference = references[id],
              record.isAvailable || reference.tools.isEmpty,
              reference.uri == record.uri else { return nil }
        return reference
    }

    func localReferences() -> [BackendWorkspaceReference] {
        references.values.filter { reference in plan.workspaces.contains { $0.id == reference.id } }
    }

    func publicReferences() async -> [GnosticWorkspaceReference] {
        var projections: [GnosticWorkspaceReference] = []
        for reference in localReferences() {
            let status = await registry.effectiveWorkspaceStatus(id: reference.id)
            let effectiveStatus = status.map { GnosticWorkspaceEffectiveStatus(rawValue: $0.rawValue) ?? .unsupported }
            projections.append(WorkspaceReferenceProjection.networkReference(from: reference, effectiveStatus: effectiveStatus))
        }
        return projections
    }

    func executeLocalTool(workspaceID: UUID, toolID: String, arguments: [String: ManifestJSONValue]) async throws -> BackendWorkspaceResult {
        guard backendProvider.isRunning else { throw NodeRuntimeError.notRunning }
        guard let workspace = localWorkspaces[workspaceID] else { throw NodeRuntimeError.missingWorkspace(workspaceID) }
        let status = await registry.effectiveWorkspaceStatus(id: workspaceID)
        guard status == .available else {
            throw DiscoveredWorkspaceAttachmentError.unavailable(Self.attachmentStatus(for: status))
        }
        return try await workspace.executeTool(id: toolID, parameters: arguments)
    }

    func listAttachable() async -> [WorkspaceListing] {
        var listings: [UUID: WorkspaceListing] = [:]
        for workspace in plan.workspaces {
            guard await registry.effectiveWorkspaceStatus(id: workspace.id) == .available else { continue }
            listings[workspace.id] = WorkspaceListing(id: workspace.id, name: workspace.name, status: .available)
        }
        for entry in await discovery.objects() where entry.objectType == GnosticObjectType.workspace
            && entry.isProtocolCompatible
            && entry.workspace?.effectiveStatus == .available && listings[entry.objectID] == nil {
            guard case .available = await discovery.attachmentStatus(id: entry.objectID) else { continue }
            listings[entry.objectID] = WorkspaceListing(id: entry.objectID, name: entry.name, status: .available)
        }
        return listings.values.sorted { ($0.id.uuidString, $0.name) < ($1.id.uuidString, $1.name) }
    }

    func attach(_ request: WorkspaceOpsRequest) async throws -> Bool {
        let (ascendantID, session) = try await operatingAdapter(for: request.timelineID)
        let runtime = try Self.requireWorkspaceRuntime(session.backend, timelineID: request.timelineID)
        let reference: BackendWorkspaceReference
        if localWorkspaces[request.workspaceID] != nil, let local = references[request.workspaceID] {
            let status = await registry.effectiveWorkspaceStatus(id: request.workspaceID)
            guard status == .available else {
                throw DiscoveredWorkspaceAttachmentError.unavailable(Self.attachmentStatus(for: status))
            }
            reference = local
        } else {
            reference = try await resolveNetworkWorkspace(
                workspaceID: request.workspaceID,
                timeout: Self.attachmentResolutionBudget
            )
        }
        try await attach(
            reference: reference,
            workspaceID: request.workspaceID,
            timelineID: request.timelineID,
            ascendantID: ascendantID,
            session: session,
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
        let (ascendantID, session) = try await operatingAdapter(for: timelineID)
        guard ascendantID == expectedAscendantID, session.lease == expectedBackendLease else {
            throw NodeRuntimeError.notRunning
        }
        let reference = try await resolveNetworkWorkspace(
            workspaceID: workspaceID,
            timeout: Self.attachmentResolutionBudget
        )
        let runtime = try Self.requireWorkspaceRuntime(session.backend, timelineID: timelineID)
        try await attach(
            reference: reference,
            workspaceID: workspaceID,
            timelineID: timelineID,
            ascendantID: ascendantID,
            session: session,
            runtime: runtime
        )
    }

    /// Narrows an operating backend to Workspace operations, mapping the
    /// absent-capability outcome to the Timeline-scoped runtime error.
    private static func requireWorkspaceRuntime(
        _ backend: any AscendantBackend,
        timelineID: UUID
    ) throws -> any AscendantBackendWorkspaceCapability {
        do {
            return try backend.requireCapability(.workspace, as: (any AscendantBackendWorkspaceCapability).self)
        } catch {
            throw NodeRuntimeError.workspaceCapabilityUnavailable(timelineID)
        }
    }

    private func attach(
        reference: BackendWorkspaceReference,
        workspaceID: UUID,
        timelineID: UUID,
        ascendantID: UUID,
        session: AscendantBackendSession,
        runtime: any AscendantBackendWorkspaceCapability
    ) async throws {
        try await runBackendOperation(session) {
            try await runtime.attachWorkspace(reference, to: timelineID)
        }
        do {
            guard let timeline = try await runBackendOperation(session, { try await session.backend.operatedTimelines().first(where: { $0.id == timelineID }) }) else {
                throw NodeRuntimeError.missingTimeline(timelineID)
            }
            guard timeline.attachedWorkspaceIDs.contains(workspaceID) else {
                throw NodeRuntimeError.missingTimeline(timelineID)
            }
            try backendProvider.requireCurrentSession(session)
            let record = try await registry.commitBackendTimeline(
                timeline,
                ascendantID: ascendantID,
                backendLease: backendProvider.lease(for: ascendantID, backend: session.backend),
                generation: session.generation,
                upserting: Self.intent(for: reference, local: localWorkspaces[workspaceID] != nil)
            )
            try backendProvider.requireCurrentSession(session)
            readvertiseTimeline(record.timeline)
        }
        catch {
            _ = try? await runBackendOperation(session) {
                try await runtime.detachWorkspace(workspaceID, from: timelineID)
            }
            throw error
        }
    }

    func detach(_ request: WorkspaceOpsRequest) async throws -> Bool {
        let (ascendantID, session) = try await operatingAdapter(for: request.timelineID)
        let runtime = try Self.requireWorkspaceRuntime(session.backend, timelineID: request.timelineID)
        let prior = references[request.workspaceID]
        try await runBackendOperation(session) {
            try await runtime.detachWorkspace(request.workspaceID, from: request.timelineID)
        }
        do {
            guard let timeline = try await runBackendOperation(session, { try await session.backend.operatedTimelines().first(where: { $0.id == request.timelineID }) }) else {
                throw NodeRuntimeError.missingTimeline(request.timelineID)
            }
            guard !timeline.attachedWorkspaceIDs.contains(request.workspaceID) else {
                throw NodeRuntimeError.missingTimeline(request.timelineID)
            }
            try backendProvider.requireCurrentSession(session)
            let record = try await registry.commitBackendTimeline(
                timeline,
                ascendantID: ascendantID,
                backendLease: backendProvider.lease(for: ascendantID, backend: session.backend),
                generation: session.generation,
                removingWorkspaceID: request.workspaceID
            )
            try backendProvider.requireCurrentSession(session)
            readvertiseTimeline(record.timeline)
        }
        catch {
            if let prior {
                _ = try? await runBackendOperation(session) {
                    try await runtime.attachWorkspace(prior, to: request.timelineID)
                }
            }
            throw error
        }
        return true
    }

    func resolveNetworkWorkspace(workspaceID: UUID, timeout: Duration = .seconds(5)) async throws -> BackendWorkspaceReference {
        guard backendProvider.isRunning else { throw NodeRuntimeError.notRunning }
        let generation = backendProvider.lifecycleGeneration
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var status = await discovery.attachmentStatus(id: workspaceID)
        try requireCurrentGeneration(generation)
        if case .available = status {
            // The observed owner advertisement is already sufficient for resolution.
            // A full discover sweep here consumes the same deadline as the caller's
            // attach call, even though the Workspace is already in the catalog.
        } else {
            guard let remaining = Self.remaining(until: deadline) else {
                throw DiscoveredWorkspaceAttachmentError.unavailable(status)
            }
            let discoveryWindow = min(remaining, Self.coldCatalogDiscoveryWindow)
            if let resolutionDiscovery = discovery as? any WorkspaceResolutionDiscovery {
                let discoveryDeadline = min(
                    deadline,
                    ContinuousClock.now.advanced(by: discoveryWindow)
                )
                await resolutionDiscovery.discoverForResolution(workspaceID: workspaceID, deadline: discoveryDeadline)
            } else {
                await discovery.discover(timeout: discoveryWindow)
            }
            try requireCurrentGeneration(generation)
            status = await discovery.attachmentStatus(id: workspaceID)
            try requireCurrentGeneration(generation)
        }
        guard case let .available(providerID, uri) = status else {
            if await registry.workspace(id: workspaceID) != nil {
                try requireCurrentGeneration(generation)
                guard await registry.setWorkspaceStatus(
                    id: workspaceID,
                    status: Self.effectiveStatus(status),
                    generation: generation
                ) else { throw NodeRuntimeError.notRunning }
            }
            throw DiscoveredWorkspaceAttachmentError.unavailable(status)
        }
        if await discovery.descriptor(workspaceID: workspaceID, providerID: providerID)?.toolsComplete == false {
            try requireCurrentGeneration(generation)
            guard let remaining = Self.remaining(until: deadline) else {
                throw DiscoveredWorkspaceAttachmentError.unavailable(.unavailable)
            }
            let complete: Bool
            if let resolutionDiscovery = discovery as? any WorkspaceResolutionDiscovery {
                complete = await resolutionDiscovery.queryToolsForResolution(
                    workspaceID: workspaceID,
                    providerID: providerID,
                    deadline: deadline
                )
            } else {
                await discovery.queryTools(workspaceID: workspaceID, timeout: remaining)
                try requireCurrentGeneration(generation)
                complete = await discovery.descriptor(workspaceID: workspaceID, providerID: providerID)?.toolsComplete == true
            }
            try requireCurrentGeneration(generation)
            guard complete else {
                throw DiscoveredWorkspaceAttachmentError.unavailable(.unavailable)
            }
        }
        guard let descriptor = await discovery.descriptor(workspaceID: workspaceID, providerID: providerID) else {
            try requireCurrentGeneration(generation)
            if await registry.workspace(id: workspaceID) != nil {
                guard await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported, generation: generation) else {
                    throw NodeRuntimeError.notRunning
                }
            }
            throw DiscoveredWorkspaceAttachmentError.unavailable(.malformed)
        }
        try requireCurrentGeneration(generation)
        guard descriptor.toolsComplete else {
            throw DiscoveredWorkspaceAttachmentError.unavailable(.unavailable)
        }
        let reference = WorkspaceReferenceProjection.backendReference(from: descriptor)
        if let configured = await registry.workspace(id: workspaceID), configured.uri != uri {
            try requireCurrentGeneration(generation)
            guard await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported, generation: generation) else {
                throw NodeRuntimeError.notRunning
            }
            throw DiscoveredWorkspaceAttachmentError.unavailable(.malformed)
        }
        if await registry.workspace(id: workspaceID) != nil {
            try requireCurrentGeneration(generation)
            guard await registry.setWorkspaceStatus(id: workspaceID, status: .available, generation: generation) else {
                throw NodeRuntimeError.notRunning
            }
        } else {
            try requireCurrentGeneration(generation)
            guard try await registry.resolveLazyWorkspace(
                id: workspaceID,
                uri: uri,
                toolIDs: reference.tools.map(\.id),
                generation: generation
            ) else {
                throw DiscoveredWorkspaceAttachmentError.unavailable(.malformed)
            }
        }
        try requireCurrentGeneration(generation)
        try await installResolved(reference, workspaceID: workspaceID, generation: generation)
        return reference
    }

    func networkAttachmentStatus(workspaceID: UUID) async -> WorkspaceAttachmentStatus {
        await discovery.attachmentStatus(id: workspaceID)
    }

    func refreshUnresolved() async {
        let unresolved = await registry.unresolvedWorkspaceIDs()
        guard !unresolved.isEmpty else { return }
        await discovery.discover(timeout: .milliseconds(250))
        guard !Task.isCancelled, backendProvider.isRunning else { return }
        for workspaceID in unresolved {
            guard !Task.isCancelled, backendProvider.isRunning else { return }
            _ = try? await resolveAvailableNetworkWorkspace(workspaceID)
        }
    }

    @discardableResult
    func resolveAvailableNetworkWorkspace(_ workspaceID: UUID) async throws -> BackendWorkspaceReference? {
        guard backendProvider.isRunning else { throw NodeRuntimeError.notRunning }
        let generation = backendProvider.lifecycleGeneration
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        guard let expectedURI = await registry.workspace(id: workspaceID)?.uri else { return nil }
        let status = await discovery.attachmentStatus(id: workspaceID)
        try requireCurrentGeneration(generation)
        guard await registry.setWorkspaceStatus(id: workspaceID, status: Self.effectiveStatus(status), generation: generation) else {
            throw NodeRuntimeError.notRunning
        }
        guard case let .available(_, uri) = status, uri == expectedURI,
              let providerID = providerID(for: status) else {
            try requireCurrentGeneration(generation)
            if case .available = status {
                guard await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported, generation: generation) else {
                    throw NodeRuntimeError.notRunning
                }
            }
            return nil
        }
        try requireCurrentGeneration(generation)
        if await discovery.descriptor(workspaceID: workspaceID, providerID: providerID)?.toolsComplete == false {
            try requireCurrentGeneration(generation)
            guard let remaining = Self.remaining(until: deadline) else { return nil }
            let complete: Bool
            if let resolutionDiscovery = discovery as? any WorkspaceResolutionDiscovery {
                complete = await resolutionDiscovery.queryToolsForResolution(
                    workspaceID: workspaceID,
                    providerID: providerID,
                    deadline: deadline
                )
            } else {
                await discovery.queryTools(workspaceID: workspaceID, timeout: remaining)
                try requireCurrentGeneration(generation)
                complete = await discovery.descriptor(workspaceID: workspaceID, providerID: providerID)?.toolsComplete == true
            }
            try requireCurrentGeneration(generation)
            guard complete else { return nil }
        }
        guard let descriptor = await discovery.descriptor(workspaceID: workspaceID, providerID: providerID) else {
            try requireCurrentGeneration(generation)
            await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported, generation: generation)
            return nil
        }
        try requireCurrentGeneration(generation)
        guard descriptor.toolsComplete else { return nil }
        let reference = WorkspaceReferenceProjection.backendReference(from: descriptor)
        try await installResolved(reference, workspaceID: workspaceID, generation: generation)
        return reference
    }

    private func operatingAdapter(for timelineID: UUID) async throws -> (UUID, AscendantBackendSession) {
        let ascendantID = try await registry.requireOperatingAscendant(for: timelineID)
        guard let session = backendProvider.session(for: ascendantID) else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
        try backendProvider.requireCurrentSession(session)
        return (ascendantID, session)
    }

    private static func remaining(until deadline: ContinuousClock.Instant) -> Duration? {
        let remaining = ContinuousClock.now.duration(to: deadline)
        return remaining > .zero ? remaining : nil
    }

    private func runBackendOperation<T>(
        _ session: AscendantBackendSession,
        _ operation: () async throws -> T
    ) async throws -> T {
        try backendProvider.requireCurrentSession(session)
        do {
            let result = try await operation()
            try backendProvider.requireCurrentSession(session)
            return result
        } catch let error as AscendantBackendError {
            if case let .lifecycleUnusable(failure) = error {
                guard backendProvider.isCurrentSession(session) else { throw error }
                await backendProvider.markLifecycleFailure(session, failure: failure)
            }
            throw error
        }
    }

    private func installResolved(_ reference: BackendWorkspaceReference, workspaceID: UUID, generation: UInt64) async throws {
        try requireCurrentGeneration(generation)
        var operationContext: AscendantBackendSession?
        var attachedTargets: [(session: AscendantBackendSession, runtime: any AscendantBackendWorkspaceCapability, timelineID: UUID)] = []
        do {
            let targets = await registry.attachmentTargets(for: workspaceID)
            try requireCurrentGeneration(generation)
            for target in targets {
                guard let session = backendProvider.session(for: target.ascendantID),
                      session.generation == generation,
                      let runtime = session.backend.optionalCapability(.workspace, as: (any AscendantBackendWorkspaceCapability).self) else { continue }
                try backendProvider.requireCurrentSession(session)
                operationContext = session
                try await runBackendOperation(session) {
                    try await runtime.attachWorkspace(reference, to: target.timelineID)
                }
                attachedTargets.append((session, runtime, target.timelineID))
                try requireCurrentGeneration(generation)
                guard let timeline = try await runBackendOperation(session, { try await session.backend.operatedTimelines().first(where: { $0.id == target.timelineID }) }),
                      timeline.attachedWorkspaceIDs.contains(workspaceID) else {
                    throw NodeRuntimeError.missingTimeline(target.timelineID)
                }
            }
        } catch {
            for attached in attachedTargets.reversed() {
                _ = try? await runBackendOperation(attached.session) {
                    try await attached.runtime.detachWorkspace(workspaceID, from: attached.timelineID)
                }
            }
            throw error
        }
        if let session = operationContext {
            try backendProvider.requireCurrentSession(session)
        }
        try requireCurrentGeneration(generation)
        guard try await registry.resolveLazyWorkspace(
            id: workspaceID,
            uri: reference.uri,
            toolIDs: reference.tools.map(\.id),
            generation: generation
        ) else {
            try requireCurrentGeneration(generation)
            guard await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported, generation: generation) else {
                throw NodeRuntimeError.notRunning
            }
            throw DiscoveredWorkspaceAttachmentError.unavailable(.malformed)
        }
        if let session = operationContext {
            try backendProvider.requireCurrentSession(session)
        }
        guard backendProvider.isRunning, backendProvider.lifecycleGeneration == generation else { throw NodeRuntimeError.notRunning }
        references[workspaceID] = reference
        backendWorkspaceService?.update(reference: reference)
    }

    private func requireCurrentGeneration(_ generation: UInt64) throws {
        guard backendProvider.isRunning, backendProvider.lifecycleGeneration == generation else {
            throw NodeRuntimeError.notRunning
        }
    }

    private static func effectiveStatus(_ status: WorkspaceAttachmentStatus) -> NodeRegistry.WorkspaceEffectiveStatus {
        switch status {
        case .available: return .available
        case .unavailable: return .unavailable
        case .ambiguous, .malformed, .unsupported: return .unsupported
        }
    }

    private func providerID(for status: WorkspaceAttachmentStatus) -> String? {
        guard case let .available(providerID, _) = status else { return nil }
        return providerID
    }

    private static func attachmentStatus(for status: NodeRegistry.WorkspaceEffectiveStatus?) -> WorkspaceAttachmentStatus {
        switch status {
        case .unsupported: return .unsupported
        case .available, .unavailable, nil: return .unavailable
        }
    }

    private static func intent(for reference: BackendWorkspaceReference, local: Bool) -> NodeManifest.WorkspaceAttachment {
        local ? .local(reference.id) : .network(reference.id, uri: reference.uri)
    }

}
