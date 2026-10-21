// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol
@testable import GnosticCore

/// Adapts a `NetworkCatalog` to the `WorkspaceDiscovery` seam for tests.
///
/// The production host uses `AxolotyWorkspaceDiscovery` over a live
/// subscription. Tests seed the catalog directly, so discovery and tool
/// queries are no-ops and every answer comes from the seeded entries.
@MainActor
final class CatalogWorkspaceDiscovery: WorkspaceDiscovery {
    private let catalog: NetworkCatalog

    init(catalog: NetworkCatalog) {
        self.catalog = catalog
    }

    func discover(timeout _: Duration) async {}

    func objects() async -> [NetworkCatalogEntry] {
        await catalog.networkObjects()
    }

    func attachmentStatus(id: UUID) async -> WorkspaceAttachmentStatus {
        await catalog.workspaceAttachmentStatus(id: id)
    }

    func queryTools(workspaceID _: UUID, timeout _: Duration) async {}

    func descriptor(workspaceID: UUID, providerID: String) async -> NetworkWorkspaceDescriptor? {
        await catalog.workspaceDescriptor(id: workspaceID, providerID: providerID)
    }
}
