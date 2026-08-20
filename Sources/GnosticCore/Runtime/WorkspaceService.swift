// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared
import PositronicKit

@MainActor
public final class WorkspaceService {
    private let plan: NodeLaunchPlan
    private let registry: NodeRegistry
    private let discovery: any WorkspaceDiscovery
    private let localWorkspaces: [UUID: any Workspace]
    private let backendWorkspaceService: GnosticWorkspaceBackendService?
    private let adapter: @MainActor (UUID) -> (any AscendantBackend)?
    private let isRunning: @MainActor () -> Bool
    private let readvertiseTimeline: @MainActor (AscendantRuntimeTimeline) -> Void
    private var references: [UUID: WorkspaceReference]

    init(
        plan: NodeLaunchPlan,
        registry: NodeRegistry,
        discovery: any WorkspaceDiscovery,
        localWorkspaces: [UUID: any Workspace],
        references: [UUID: WorkspaceReference],
        backendWorkspaceService: GnosticWorkspaceBackendService? = nil,
        isRunning: @escaping @MainActor () -> Bool,
        adapter: @escaping @MainActor (UUID) -> (any AscendantBackend)?,
        readvertiseTimeline: @escaping @MainActor (AscendantRuntimeTimeline) -> Void
    ) {
        self.plan = plan; self.registry = registry; self.discovery = discovery
        self.localWorkspaces = localWorkspaces; self.references = references
        self.backendWorkspaceService = backendWorkspaceService
        self.isRunning = isRunning; self.adapter = adapter
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
        guard let workspace = localWorkspaces[workspaceID] else { throw NodeRuntimeError.missingWorkspace(workspaceID) }
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
        let runtime = try await operatingAdapter(for: request.timelineID)
        let reference: WorkspaceReference
        if localWorkspaces[request.workspaceID] != nil, let local = references[request.workspaceID] {
            reference = local
        } else {
            reference = try await resolveNetworkWorkspace(workspaceID: request.workspaceID)
        }
        try await runtime.attachWorkspace(BackendWorkspaceReference(reference: reference), to: request.timelineID)
        if let timeline = try await runtime.operatedTimelines().first(where: { $0.id == request.timelineID }) {
            do {
                _ = try await registry.replaceTimeline(timeline, projecting: { [readvertiseTimeline] record in
                    readvertiseTimeline(record.timeline)
                })
            }
            catch { try? await runtime.detachWorkspace(request.workspaceID, from: request.timelineID); throw error }
        }
        return true
    }

    func detach(_ request: WorkspaceOpsRequest) async throws -> Bool {
        let runtime = try await operatingAdapter(for: request.timelineID)
        let prior = references[request.workspaceID]
        try await runtime.detachWorkspace(request.workspaceID, from: request.timelineID)
        if let timeline = try await runtime.operatedTimelines().first(where: { $0.id == request.timelineID }) {
            do {
                _ = try await registry.replaceTimeline(timeline, projecting: { [readvertiseTimeline] record in
                    readvertiseTimeline(record.timeline)
                })
            }
            catch { if let prior { try? await runtime.attachWorkspace(BackendWorkspaceReference(reference: prior), to: request.timelineID) }; throw error }
        }
        return true
    }

    func resolveNetworkWorkspace(workspaceID: UUID, timeout: Duration = .seconds(5)) async throws -> WorkspaceReference {
        guard isRunning() else { throw NodeRuntimeError.notRunning }
        await discovery.discover(timeout: timeout)
        let status = await discovery.attachmentStatus(id: workspaceID)
        await registry.setWorkspaceStatus(id: workspaceID, status: Self.effectiveStatus(status))
        guard case let .available(_, uri) = status else {
            throw DiscoveredWorkspaceAttachmentError.unavailable(status)
        }
        guard let descriptor = await discovery.objects().first(where: { $0.objectID == workspaceID && $0.workspace?.uri == uri })?.workspace else {
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
        await discovery.discover(timeout: .milliseconds(250))
        for workspaceID in await registry.unresolvedWorkspaceIDs() {
            _ = try? await resolveAvailableNetworkWorkspace(workspaceID)
        }
    }

    @discardableResult
    func resolveAvailableNetworkWorkspace(_ workspaceID: UUID) async throws -> WorkspaceReference? {
        guard let expectedURI = await registry.workspace(id: workspaceID)?.uri else { return nil }
        let status = await discovery.attachmentStatus(id: workspaceID)
        await registry.setWorkspaceStatus(id: workspaceID, status: Self.effectiveStatus(status))
        guard case let .available(_, uri) = status, uri == expectedURI,
              let descriptor = await discovery.objects().first(where: { $0.objectID == workspaceID && $0.workspace?.uri == uri })?.workspace else {
            if case .available = status { await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported) }
            return nil
        }
        guard let reference = try? WorkspaceReferenceProjection.reference(from: descriptor) else {
            await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported)
            return nil
        }
        try await installResolved(reference, workspaceID: workspaceID)
        return reference
    }

    private func operatingAdapter(for timelineID: UUID) async throws -> any AscendantBackend {
        let ascendantID = try await registry.requireOperatingAscendant(for: timelineID)
        guard let runtime = adapter(ascendantID) else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
        return runtime
    }

    private func installResolved(_ reference: WorkspaceReference, workspaceID: UUID) async throws {
        let attached = plan.timelines.filter { $0.attachments.contains { $0.workspaceID == workspaceID && $0.scope == .network } }
        for ascendantID in Set(attached.compactMap(\.operatingAscendantID)) {
            guard let runtime = adapter(ascendantID) else { continue }
            for timeline in attached where timeline.operatingAscendantID == ascendantID {
                try await runtime.attachWorkspace(BackendWorkspaceReference(reference: reference), to: timeline.id)
            }
        }
        guard try await registry.resolveLazyWorkspace(id: workspaceID, uri: reference.uri.description, toolIDs: reference.tools.map(\.toolID)) else {
            await registry.setWorkspaceStatus(id: workspaceID, status: .unsupported)
            throw DiscoveredWorkspaceAttachmentError.unavailable(.malformed)
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
}
