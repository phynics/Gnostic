// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKShared
import PositronicKit

/// Failures that prevent a discovered workspace from being imported or attached.
public enum DiscoveredWorkspaceAttachmentError: Error, Sendable, Equatable {
    /// Attachment is a user-approved operation and approval was not supplied.
    case approvalRequired
    /// The catalog entry is not available, well-formed, and uniquely advertised.
    case unavailable(WorkspaceAttachmentStatus)
    /// The advertised URI cannot form a PositronicKit workspace reference.
    case invalidURI
}

/// Imports safe discovered workspace references and attaches them through `TimelineManager`.
@MainActor
public final class DiscoveredWorkspaceAttachmentService {
    private let catalog: NetworkCatalog
    private let timelineManager: TimelineManager
    private let readvertiseTimeline: ((Timeline) -> Void)?

    /// Creates the attachment bridge using the runtime's timeline manager.
    /// Workspace references are imported into the manager's own store via
    /// `TimelineManager.importWorkspace`, so attach validates correctly.
    public init(
        catalog: NetworkCatalog,
        timelineManager: TimelineManager,
        readvertiseTimeline: ((Timeline) -> Void)? = nil
    ) {
        self.catalog = catalog
        self.timelineManager = timelineManager
        self.readvertiseTimeline = readvertiseTimeline
    }

    /// Lists provider-scoped catalog entries for `list_network_objects`.
    public func listNetworkObjects() async -> [NetworkCatalogEntry] {
        await catalog.networkObjects()
    }

    /// Returns an inspection record for `inspect_network_object` without attaching it.
    public func inspectNetworkObject(id: UUID, providerID: String) async -> NetworkCatalogEntry? {
        await catalog.object(id: id, providerID: providerID)
    }

    /// Imports a uniquely advertised workspace as a runtime reference and attaches it after approval.
    @discardableResult
    public func attach(workspaceID: UUID, to timelineID: UUID, approved: Bool) async throws -> WorkspaceReference {
        guard approved else { throw DiscoveredWorkspaceAttachmentError.approvalRequired }
        let status = await catalog.workspaceAttachmentStatus(id: workspaceID)
        guard case let .available(_, uri) = status else {
            throw DiscoveredWorkspaceAttachmentError.unavailable(status)
        }
        guard let descriptor = await catalog.networkObjects().first(where: {
            $0.objectID == workspaceID && $0.workspace?.uri == uri
        })?.workspace,
            let reference = try? WorkspaceReferenceProjection.reference(from: descriptor) else {
            throw DiscoveredWorkspaceAttachmentError.invalidURI
        }
        try await timelineManager.importWorkspace(reference)
        try await timelineManager.attachWorkspace(reference.id, to: timelineID)
        if let timeline = try await timelineManager.listTimelines().first(where: { $0.id == timelineID }) {
            readvertiseTimeline?(timeline)
        }
        return reference
    }
}
