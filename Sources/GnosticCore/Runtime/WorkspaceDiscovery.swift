// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticProtocol

/// The narrow network-discovery capability consumed by Workspace domain logic.
/// Tests can supply a stub without constructing Axoloty or a broker connection.
@MainActor
public protocol WorkspaceDiscovery: Sendable {
    /// Runs a network discovery sweep for the given timeout.
    ///
    /// - Parameter timeout: The maximum time to wait for replies.
    func discover(timeout: Duration) async
    /// Returns every currently catalogued network object.
    ///
    /// - Returns: The catalog entries.
    func objects() async -> [NetworkCatalogEntry]
    /// Returns the attachment status of one Workspace.
    ///
    /// - Parameter id: The Workspace identifier.
    /// - Returns: The effective attachment status.
    func attachmentStatus(id: UUID) async -> WorkspaceAttachmentStatus
    /// Queries the tool catalog of one advertised Workspace.
    ///
    /// - Parameters:
    ///   - workspaceID: The Workspace identifier.
    ///   - timeout: The maximum time to wait for replies.
    func queryTools(workspaceID: UUID, timeout: Duration) async
    /// Returns the descriptor of one uniquely advertised Workspace.
    ///
    /// - Parameters:
    ///   - workspaceID: The Workspace identifier.
    ///   - providerID: The advertising peer.
    /// - Returns: The descriptor, or `nil` when it is not advertised.
    func descriptor(workspaceID: UUID, providerID: String) async -> NetworkWorkspaceDescriptor?
}

/// Gnostic-owned optional host capability for backends that expose network
/// Workspace tools. It keeps catalog and broker implementations in the host
/// composition layer while allowing a backend to opt into discovery.
public final class BackendWorkspaceDiscoveryCapability: AscendantBackendOptionalCapability, Sendable {
    /// The discovery seam this capability exposes.
    public let discovery: any WorkspaceDiscovery

    /// Creates a discovery capability over one discovery seam.
    ///
    /// - Parameter discovery: The discovery seam to expose.
    public init(discovery: any WorkspaceDiscovery) {
        self.discovery = discovery
    }
}

/// Gnostic-owned authority for backend-originated Workspace attachment tools.
/// The handler is bound by NodeRuntime to one Ascendant backend lease; the
/// backend receives only this narrow capability and never the registry or
/// transport objects behind it.
@MainActor
public final class BackendWorkspaceAttachmentCapability: AscendantBackendOptionalCapability, @unchecked Sendable { // SAFETY: @MainActor class; the bound handler is actor-isolated.
    /// The handler NodeRuntime binds for one Ascendant lease.
    public typealias Handler = @MainActor @Sendable (UUID, UUID) async throws -> Void

    private var handler: Handler?

    /// Creates an unbound attachment capability.
    ///
    /// - Parameter handler: An optional pre-bound handler.
    public init(handler: Handler? = nil) {
        self.handler = handler
    }

    /// Binds the handler NodeRuntime owns for one Ascendant lease.
    ///
    /// - Parameter handler: The handler to invoke on attach.
    public func bind(_ handler: @escaping Handler) {
        self.handler = handler
    }

    /// Attaches one Workspace to one Timeline through the bound handler.
    ///
    /// - Parameters:
    ///   - workspaceID: The Workspace identifier.
    ///   - timelineID: The Timeline identifier.
    /// - Throws: When the capability is unbound or the handler rejects the attach.
    public func attach(workspaceID: UUID, timelineID: UUID) async throws {
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
