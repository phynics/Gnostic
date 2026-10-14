// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticProtocol
import PKContracts
import PositronicKit

/// Imports safe discovered workspace references and routes attachment authority
/// through the Gnostic host capability.
///
/// The host capability is required. A backend resolves and validates the
/// discovered Workspace, then delegates the commit to the host, so the private
/// backend projection cannot become the source of truth for attachment intent,
/// and there is exactly one attachment path.
@MainActor
final class DiscoveredWorkspaceAttachmentService {
    private let discovery: any WorkspaceDiscovery
    private let threadCapability: TimelineCapability
    private let hostAttachment: BackendWorkspaceAttachmentCapability

    /// Creates the attachment bridge using the runtime's discovery boundary.
    ///
    /// - Parameters:
    ///   - discovery: The host discovery seam that owns the catalog view.
    ///   - threadCapability: The Ascendant's current Timeline store, used to
    ///     reject a Timeline this Ascendant does not own.
    ///   - hostAttachment: The host authority that commits the attachment.
    init(
        discovery: any WorkspaceDiscovery,
        threadCapability: TimelineCapability,
        hostAttachment: BackendWorkspaceAttachmentCapability
    ) {
        self.discovery = discovery
        self.threadCapability = threadCapability
        self.hostAttachment = hostAttachment
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
    /// attaches it through the host. Approval is enforced by
    /// `AscendantToolApprovalPolicy`; this path holds no approval flag.
    @discardableResult
    func attach(workspaceID: UUID, to timelineID: UUID) async throws -> WorkspaceReference {
        // Ownership is the Ascendant's current Timeline set, not a snapshot
        // captured at backend construction. A Timeline created at runtime is
        // persisted before its first Turn, so the same capability that owns
        // the store also answers ownership.
        guard try await threadCapability.get(timelineID) != nil else {
            throw DiscoveredWorkspaceAttachmentError.timelineNotOwned(timelineID)
        }
        let status = await discovery.attachmentStatus(id: workspaceID)
        guard case let .available(providerID, uri) = status else {
            throw DiscoveredWorkspaceAttachmentError.unavailable(status)
        }
        await discovery.queryTools(workspaceID: workspaceID, timeout: .seconds(5))
        guard let descriptor = await discovery.descriptor(workspaceID: workspaceID, providerID: providerID),
              descriptor.uri == uri,
              let reference = try? PositronicWorkspaceProjection.reference(from: descriptor) else {
            throw DiscoveredWorkspaceAttachmentError.invalidURI
        }
        try await hostAttachment.attach(workspaceID: reference.id, timelineID: timelineID)
        return reference
    }
}
