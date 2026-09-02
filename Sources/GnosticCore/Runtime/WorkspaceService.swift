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
    private let backendProvider: any BackendSessionProviding
    private let readvertiseTimeline: @MainActor (AscendantRuntimeTimeline) -> Void
    private var references: [UUID: WorkspaceReference]

    convenience init(
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
        self.init(
            plan: plan,
            registry: registry,
            discovery: discovery,
            localWorkspaces: localWorkspaces,
            references: references,
            backendWorkspaceService: backendWorkspaceService,
            backendProvider: ClosureBackendSessionProvider(
                isRunning: isRunning,
                lifecycleGeneration: lifecycleGeneration,
                adapter: adapter,
                current: isCurrentBackend,
                backendLease: backendLease,
                failure: lifecycleFailure,
                backend: { _ in throw NodeRuntimeError.notRunning }
            ),
            readvertiseTimeline: readvertiseTimeline
        )
    }

    init(
        plan: NodeLaunchPlan,
        registry: NodeRegistry,
        discovery: any WorkspaceDiscovery,
        localWorkspaces: [UUID: any WorkspaceProvider],
        references: [UUID: WorkspaceReference],
        backendWorkspaceService: GnosticWorkspaceBackendService? = nil,
        backendProvider: any BackendSessionProviding,
        readvertiseTimeline: @escaping @MainActor (AscendantRuntimeTimeline) -> Void
    ) {
        self.plan = plan; self.registry = registry; self.discovery = discovery
        self.localWorkspaces = localWorkspaces; self.references = references
        self.backendWorkspaceService = backendWorkspaceService
        self.backendProvider = backendProvider
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

    func publicReferences() async -> [GnosticWorkspaceReference] {
        var projections: [GnosticWorkspaceReference] = []
        for reference in localReferences() {
            let status = await registry.effectiveWorkspaceStatus(id: reference.id)
            let effectiveStatus = status.map { GnosticWorkspaceEffectiveStatus(rawValue: $0.rawValue) ?? .unsupported }
            projections.append(WorkspaceReferenceProjection.networkReference(from: reference, effectiveStatus: effectiveStatus))
        }
        return projections
    }

    func executeLocalTool(workspaceID: UUID, toolID: String, arguments: [String: AnyCodable]) async throws -> ToolResult {
        guard backendProvider.isRunning else { throw NodeRuntimeError.notRunning }
        guard let workspace = localWorkspaces[workspaceID] as? any WorkspaceToolProvider else { throw NodeRuntimeError.missingWorkspace(workspaceID) }
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
        guard let runtime = session.backend as? any AscendantBackendWorkspaceCapability else {
            throw NodeRuntimeError.workspaceCapabilityUnavailable(request.timelineID)
        }
        let reference: WorkspaceReference
        if localWorkspaces[request.workspaceID] != nil, let local = references[request.workspaceID] {
            let status = await registry.effectiveWorkspaceStatus(id: request.workspaceID)
            guard status == .available else {
                throw DiscoveredWorkspaceAttachmentError.unavailable(Self.attachmentStatus(for: status))
            }
            reference = local
        } else {
            reference = try await resolveNetworkWorkspace(workspaceID: request.workspaceID)
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
        let reference = try await resolveNetworkWorkspace(workspaceID: workspaceID)
        guard let runtime = session.backend as? any AscendantBackendWorkspaceCapability else {
            throw NodeRuntimeError.workspaceCapabilityUnavailable(timelineID)
        }
        try await attach(
            reference: reference,
            workspaceID: workspaceID,
            timelineID: timelineID,
            ascendantID: ascendantID,
            session: session,
            runtime: runtime
        )
    }

    private func attach(
        reference: WorkspaceReference,
        workspaceID: UUID,
        timelineID: UUID,
        ascendantID: UUID,
        session: AscendantBackendSession,
        runtime: any AscendantBackendWorkspaceCapability
    ) async throws {
        try await runBackendOperation(session) {
            try await runtime.attachWorkspace(BackendWorkspaceReference(reference: reference), to: timelineID)
        }
        if let timeline = try await runBackendOperation(session, { try await session.backend.operatedTimelines().first(where: { $0.id == timelineID }) }) {
            do {
                guard backendProvider.isCurrentSession(session) else { throw NodeRuntimeError.notRunning }
                let record = try await registry.commitBackendTimeline(
                    timeline,
                    ascendantID: ascendantID,
                    backendLease: backendProvider.lease(for: ascendantID, backend: session.backend),
                    generation: session.generation,
                    upserting: Self.intent(for: reference, local: localWorkspaces[workspaceID] != nil)
                )
                guard backendProvider.isCurrentSession(session) else { throw NodeRuntimeError.notRunning }
                readvertiseTimeline(record.timeline)
            }
            catch {
                _ = try? await runBackendOperation(session) {
                    try await runtime.detachWorkspace(workspaceID, from: timelineID)
                }
                throw error
            }
        }
    }

    func detach(_ request: WorkspaceOpsRequest) async throws -> Bool {
        let (ascendantID, session) = try await operatingAdapter(for: request.timelineID)
        guard let runtime = session.backend as? any AscendantBackendWorkspaceCapability else {
            throw NodeRuntimeError.workspaceCapabilityUnavailable(request.timelineID)
        }
        let prior = references[request.workspaceID]
        try await runBackendOperation(session) {
            try await runtime.detachWorkspace(request.workspaceID, from: request.timelineID)
        }
        if let timeline = try await runBackendOperation(session, { try await session.backend.operatedTimelines().first(where: { $0.id == request.timelineID }) }) {
            do {
                guard backendProvider.isCurrentSession(session) else { throw NodeRuntimeError.notRunning }
                let record = try await registry.commitBackendTimeline(
                    timeline,
                    ascendantID: ascendantID,
                    backendLease: backendProvider.lease(for: ascendantID, backend: session.backend),
                    generation: session.generation,
                    removingWorkspaceID: request.workspaceID
                )
                guard backendProvider.isCurrentSession(session) else { throw NodeRuntimeError.notRunning }
                readvertiseTimeline(record.timeline)
            }
            catch {
                if let prior {
                    _ = try? await runBackendOperation(session) {
                        try await runtime.attachWorkspace(BackendWorkspaceReference(reference: prior), to: request.timelineID)
                    }
                }
                throw error
            }
        }
        return true
    }

    func resolveNetworkWorkspace(workspaceID: UUID, timeout: Duration = .seconds(5)) async throws -> WorkspaceReference {
        guard backendProvider.isRunning else { throw NodeRuntimeError.notRunning }
        let generation = backendProvider.lifecycleGeneration
        await discovery.discover(timeout: timeout)
        guard backendProvider.isRunning, backendProvider.lifecycleGeneration == generation else { throw NodeRuntimeError.notRunning }
        let status = await discovery.attachmentStatus(id: workspaceID)
        guard backendProvider.isRunning, backendProvider.lifecycleGeneration == generation else { throw NodeRuntimeError.notRunning }
        guard await registry.setWorkspaceStatus(id: workspaceID, status: Self.effectiveStatus(status), generation: generation) else {
            throw NodeRuntimeError.notRunning
        }
        guard case let .available(providerID, uri) = status else {
            throw DiscoveredWorkspaceAttachmentError.unavailable(status)
        }
        if await discovery.descriptor(workspaceID: workspaceID, providerID: providerID)?.toolsComplete == false {
            await discovery.queryTools(workspaceID: workspaceID, timeout: timeout)
        }
        guard let descriptor = await discovery.descriptor(workspaceID: workspaceID, providerID: providerID) else {
            guard backendProvider.isRunning, backendProvider.lifecycleGeneration == generation else { throw NodeRuntimeError.notRunning }
            guard await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported, generation: generation) else {
                throw NodeRuntimeError.notRunning
            }
            throw DiscoveredWorkspaceAttachmentError.unavailable(.malformed)
        }
        guard let reference = try? WorkspaceReferenceProjection.reference(from: descriptor) else {
            guard backendProvider.isRunning, backendProvider.lifecycleGeneration == generation else { throw NodeRuntimeError.notRunning }
            guard await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported, generation: generation) else {
                throw NodeRuntimeError.notRunning
            }
            throw DiscoveredWorkspaceAttachmentError.unavailable(.malformed)
        }
        if let configured = await registry.workspace(id: workspaceID), configured.uri != uri {
            guard backendProvider.isRunning, backendProvider.lifecycleGeneration == generation else { throw NodeRuntimeError.notRunning }
            guard await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported, generation: generation) else {
                throw NodeRuntimeError.notRunning
            }
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
        guard !Task.isCancelled, backendProvider.isRunning else { return }
        for workspaceID in unresolved {
            guard !Task.isCancelled, backendProvider.isRunning else { return }
            _ = try? await resolveAvailableNetworkWorkspace(workspaceID)
        }
    }

    @discardableResult
    func resolveAvailableNetworkWorkspace(_ workspaceID: UUID) async throws -> WorkspaceReference? {
        guard backendProvider.isRunning else { throw NodeRuntimeError.notRunning }
        let generation = backendProvider.lifecycleGeneration
        guard let expectedURI = await registry.workspace(id: workspaceID)?.uri else { return nil }
        let status = await discovery.attachmentStatus(id: workspaceID)
        guard backendProvider.isRunning, backendProvider.lifecycleGeneration == generation else { throw NodeRuntimeError.notRunning }
        guard await registry.setWorkspaceStatus(id: workspaceID, status: Self.effectiveStatus(status), generation: generation) else {
            throw NodeRuntimeError.notRunning
        }
        guard case let .available(_, uri) = status, uri == expectedURI,
              let providerID = providerID(for: status) else {
            guard backendProvider.isRunning, backendProvider.lifecycleGeneration == generation else { throw NodeRuntimeError.notRunning }
            if case .available = status {
                guard await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported, generation: generation) else {
                    throw NodeRuntimeError.notRunning
                }
            }
            return nil
        }
        if await discovery.descriptor(workspaceID: workspaceID, providerID: providerID)?.toolsComplete == false {
            await discovery.queryTools(workspaceID: workspaceID, timeout: .seconds(5))
        }
        guard let descriptor = await discovery.descriptor(workspaceID: workspaceID, providerID: providerID) else {
            guard backendProvider.isRunning, backendProvider.lifecycleGeneration == generation else { throw NodeRuntimeError.notRunning }
            await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported, generation: generation)
            return nil
        }
        guard let reference = try? WorkspaceReferenceProjection.reference(from: descriptor) else {
            guard backendProvider.isRunning, backendProvider.lifecycleGeneration == generation else { throw NodeRuntimeError.notRunning }
            guard await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported, generation: generation) else {
                throw NodeRuntimeError.notRunning
            }
            return nil
        }
        try await installResolved(reference, workspaceID: workspaceID)
        return reference
    }

    private func operatingAdapter(for timelineID: UUID) async throws -> (UUID, AscendantBackendSession) {
        let ascendantID = try await registry.requireOperatingAscendant(for: timelineID)
        guard let session = backendProvider.session(for: ascendantID) else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
        guard backendProvider.isCurrentSession(session) else { throw NodeRuntimeError.notRunning }
        return (ascendantID, session)
    }

    private func runBackendOperation<T>(
        _ session: AscendantBackendSession,
        _ operation: () async throws -> T
    ) async throws -> T {
        guard backendProvider.isCurrentSession(session) else { throw NodeRuntimeError.notRunning }
        do {
            let result = try await operation()
            guard backendProvider.isCurrentSession(session) else { throw NodeRuntimeError.notRunning }
            return result
        } catch let error as AscendantBackendError {
            if case let .lifecycleUnusable(failure) = error {
                guard backendProvider.isCurrentSession(session) else { throw error }
                await backendProvider.markLifecycleFailure(session, failure: failure)
            }
            throw error
        }
    }

    private func installResolved(_ reference: WorkspaceReference, workspaceID: UUID) async throws {
        let backendReference = BackendWorkspaceReference(reference: reference)
        var operationContext: AscendantBackendSession?
        for target in await registry.attachmentTargets(for: workspaceID) {
            guard let session = backendProvider.session(for: target.ascendantID),
                  let runtime = session.backend as? any AscendantBackendWorkspaceCapability else { continue }
            guard backendProvider.isCurrentSession(session) else { throw NodeRuntimeError.notRunning }
            operationContext = session
            try await runBackendOperation(session) {
                try await runtime.attachWorkspace(backendReference, to: target.timelineID)
            }
        }
        if let session = operationContext {
            guard backendProvider.isCurrentSession(session) else { throw NodeRuntimeError.notRunning }
        }
        guard backendProvider.isRunning else { throw NodeRuntimeError.notRunning }
        let generation = backendProvider.lifecycleGeneration
        guard try await registry.resolveLazyWorkspace(
            id: workspaceID,
            uri: reference.uri.description,
            toolIDs: reference.tools.map(\.toolID),
            generation: generation
        ) else {
            guard backendProvider.isRunning, backendProvider.lifecycleGeneration == generation else { throw NodeRuntimeError.notRunning }
            guard await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported, generation: generation) else {
                throw NodeRuntimeError.notRunning
            }
            throw DiscoveredWorkspaceAttachmentError.unavailable(.malformed)
        }
        if let session = operationContext {
            guard backendProvider.isCurrentSession(session) else { throw NodeRuntimeError.notRunning }
        }
        guard backendProvider.isRunning, backendProvider.lifecycleGeneration == generation else { throw NodeRuntimeError.notRunning }
        references[workspaceID] = reference
        backendWorkspaceService?.update(reference: reference)
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

    private static func intent(for reference: WorkspaceReference, local: Bool) -> NodeManifest.WorkspaceAttachment {
        local ? .local(reference.id) : .network(reference.id, uri: reference.uri.description)
    }

}
