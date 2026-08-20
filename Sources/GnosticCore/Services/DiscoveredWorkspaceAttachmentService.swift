// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKShared
import PositronicKit
import struct PositronicKit.Thread

/// Failures that prevent a discovered workspace from being imported or attached.
public enum DiscoveredWorkspaceAttachmentError: Error, Sendable, Equatable {
    /// Attachment is a user-approved operation and approval was not supplied.
    case approvalRequired
    /// The catalog entry is not available, well-formed, and uniquely advertised.
    case unavailable(WorkspaceAttachmentStatus)
    /// The advertised URI cannot form a PositronicKit workspace reference.
    case invalidURI
    /// The requested timeline belongs to another configured runtime.
    case timelineNotOwned(UUID)
}

/// Imports safe discovered workspace references and routes attachment authority
/// through Gnostic when a backend host capability is available.
@MainActor
final class DiscoveredWorkspaceAttachmentService {
    private let discovery: any WorkspaceDiscovery
    private let threadManager: ThreadManager
    private let hostAttachment: BackendWorkspaceAttachmentCapability?
    private let allowedTimelineIDs: Set<UUID>?
    private let readvertiseTimeline: ((Thread) -> Void)?

    /// Creates the attachment bridge using the runtime's discovery boundary.
    /// Backend construction supplies `hostAttachment` so Gnostic can commit
    /// the attachment intent and effective state after the backend accepts the
    /// private projection. The ThreadManager path remains for direct legacy
    /// service callers and focused provider tests.
    init(
        discovery: any WorkspaceDiscovery,
        threadManager: ThreadManager,
        hostAttachment: BackendWorkspaceAttachmentCapability? = nil,
        allowedTimelineIDs: Set<UUID>? = nil,
        readvertiseTimeline: ((Thread) -> Void)? = nil
    ) {
        self.discovery = discovery
        self.threadManager = threadManager
        self.hostAttachment = hostAttachment
        self.allowedTimelineIDs = allowedTimelineIDs
        self.readvertiseTimeline = readvertiseTimeline
    }

    /// Compatibility initializer for callers that still own the Axoloty
    /// catalog directly. Backend construction uses the Gnostic discovery seam
    /// above so raw host values do not cross into adapter services.
    convenience init(
        catalog: NetworkCatalog,
        threadManager: ThreadManager,
        hostAttachment: BackendWorkspaceAttachmentCapability? = nil,
        allowedTimelineIDs: Set<UUID>? = nil,
        readvertiseTimeline: ((Thread) -> Void)? = nil
    ) {
        self.init(
            discovery: CatalogWorkspaceDiscovery(catalog: catalog),
            threadManager: threadManager,
            hostAttachment: hostAttachment,
            allowedTimelineIDs: allowedTimelineIDs,
            readvertiseTimeline: readvertiseTimeline
        )
    }

    /// Lists provider-scoped catalog entries for `list_network_objects`.
    func listNetworkObjects() async -> [NetworkCatalogEntry] {
        await discovery.objects()
    }

    /// Returns an inspection record for `inspect_network_object` without attaching it.
    func inspectNetworkObject(id: UUID, providerID: String) async -> NetworkCatalogEntry? {
        await discovery.objects().first { entry in
            entry.objectID == id && entry.providerID == providerID
        }
    }

    /// Imports a uniquely advertised workspace as a runtime reference and
    /// attaches it after approval. Backend-originated calls go through the
    /// Gnostic host capability so the private backend projection cannot become
    /// the source of truth for attachment intent.
    @discardableResult
    func attach(workspaceID: UUID, to timelineID: UUID, approved: Bool) async throws -> WorkspaceReference {
        guard approved else { throw DiscoveredWorkspaceAttachmentError.approvalRequired }
        if let allowedTimelineIDs, !allowedTimelineIDs.contains(timelineID) {
            throw DiscoveredWorkspaceAttachmentError.timelineNotOwned(timelineID)
        }
        let status = await discovery.attachmentStatus(id: workspaceID)
        guard case let .available(_, uri) = status else {
            throw DiscoveredWorkspaceAttachmentError.unavailable(status)
        }
        guard let descriptor = await discovery.objects().first(where: {
            $0.objectID == workspaceID && $0.workspace?.uri == uri
        })?.workspace,
            let reference = try? WorkspaceReferenceProjection.reference(from: descriptor) else {
            throw DiscoveredWorkspaceAttachmentError.invalidURI
        }
        if let hostAttachment {
            try await hostAttachment.attach(workspaceID: reference.id, timelineID: timelineID)
        } else {
            try await threadManager.importWorkspace(reference)
            try await threadManager.attachWorkspace(reference.id, to: timelineID)
            if let thread = try await threadManager.listThreads().first(where: { $0.id == timelineID }) {
                readvertiseTimeline?(thread)
            }
        }
        return reference
    }
}

/// Adapts the legacy catalog owner to the narrow discovery seam used by
/// backend-specific optional services.
@MainActor
private final class CatalogWorkspaceDiscovery: WorkspaceDiscovery {
    private let catalog: NetworkCatalog

    init(catalog: NetworkCatalog) {
        self.catalog = catalog
    }

    func discover(timeout _: Duration) async {}
    func objects() async -> [NetworkCatalogEntry] { await catalog.networkObjects() }
    func attachmentStatus(id: UUID) async -> WorkspaceAttachmentStatus {
        await catalog.workspaceAttachmentStatus(id: id)
    }
}
