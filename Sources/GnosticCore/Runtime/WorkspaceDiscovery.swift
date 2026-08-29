// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

/// The narrow network-discovery capability consumed by Workspace domain logic.
/// Tests can supply a stub without constructing Axoloty or a broker connection.
@MainActor
protocol WorkspaceDiscovery: Sendable {
    func discover(timeout: Duration) async
    func objects() async -> [NetworkCatalogEntry]
    func attachmentStatus(id: UUID) async -> WorkspaceAttachmentStatus
    func queryTools(workspaceID: UUID, timeout: Duration) async
    func descriptor(workspaceID: UUID, providerID: String) async -> NetworkWorkspaceDescriptor?
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

/// Gnostic-owned authority for backend-originated Workspace attachment tools.
/// The handler is bound by NodeRuntime to one Ascendant backend lease; the
/// backend receives only this narrow capability and never the registry or
/// transport objects behind it.
@MainActor
final class BackendWorkspaceAttachmentCapability: AscendantBackendOptionalCapability, @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (UUID, UUID) async throws -> Void

    private var handler: Handler?

    init(handler: Handler? = nil) {
        self.handler = handler
    }

    func bind(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func attach(workspaceID: UUID, timelineID: UUID) async throws {
        guard let handler else { throw NodeRuntimeError.notRunning }
        try await handler(workspaceID, timelineID)
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

    func queryTools(workspaceID: UUID, timeout: Duration) async {
        await subscription.queryTools(using: communication, workspaceID: workspaceID, timeout: timeout)
    }

    func descriptor(workspaceID: UUID, providerID: String) async -> NetworkWorkspaceDescriptor? {
        await catalog.workspaceDescriptor(id: workspaceID, providerID: providerID)
    }
}
