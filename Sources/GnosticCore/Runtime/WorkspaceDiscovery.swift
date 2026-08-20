// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared
import PositronicKit

/// The narrow network-discovery capability consumed by Workspace domain logic.
/// Tests can supply a stub without constructing Axoloty or a broker connection.
@MainActor
protocol WorkspaceDiscovery: Sendable {
    func discover(timeout: Duration) async
    func objects() async -> [NetworkCatalogEntry]
    func attachmentStatus(id: UUID) async -> WorkspaceAttachmentStatus
}

/// Gnostic-owned optional host capability for backends that expose network
/// Workspace tools. It keeps catalog and broker implementations in the host
/// composition layer while allowing a backend to opt into discovery.
final class BackendWorkspaceDiscoveryCapability: AscendantBackendOptionalCapability, @unchecked Sendable {
    let discovery: any WorkspaceDiscovery

    init(discovery: any WorkspaceDiscovery) {
        self.discovery = discovery
    }
}

@MainActor
final class AxolotyWorkspaceDiscovery: WorkspaceDiscovery {
    private let catalog: NetworkCatalog
    private let subscription: GnosticSubscription
    private let communication: CommunicationManager

    init(catalog: NetworkCatalog, subscription: GnosticSubscription, communication: CommunicationManager) {
        self.catalog = catalog
        self.subscription = subscription
        self.communication = communication
    }

    func discover(timeout: Duration) async {
        await subscription.discover(using: communication, timeout: timeout)
    }

    func objects() async -> [NetworkCatalogEntry] { await catalog.networkObjects() }

    func attachmentStatus(id: UUID) async -> WorkspaceAttachmentStatus {
        await catalog.workspaceAttachmentStatus(id: id)
    }
}
