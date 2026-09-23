// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

/// The Gnostic-owned result of a remote Workspace tool invocation.
///
/// The wire shape mirrors the PositronicKit `ToolResult` payload carried by
/// `me.atkn.gnostic.workspace.invoke`, including its `isSuccess` key.
public struct GnosticWorkspaceToolResult: Codable, Sendable, Equatable {
    /// The protocol major carried by the result.
    public let protocolMajor: Int

    /// Whether the tool executed successfully.
    public let isSuccess: Bool

    /// The successful tool output, or an empty string on failure.
    public let output: String

    /// The failure message, or `nil` on success.
    public let error: String?

    /// Creates an invocation result.
    ///
    /// - Parameters:
    ///   - isSuccess: Whether the tool executed successfully.
    ///   - output: The successful tool output.
    ///   - error: The failure message, or `nil` on success.
    ///   - protocolMajor: The protocol major carried by the result.
    public init(
        isSuccess: Bool,
        output: String,
        error: String? = nil,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.isSuccess = isSuccess
        self.output = output
        self.error = error
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, isSuccess, output, error }

    /// Decodes an invocation result.
    ///
    /// - Parameter decoder: The source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        isSuccess = try container.decode(Bool.self, forKey: .isSuccess)
        output = try container.decodeIfPresent(String.self, forKey: .output) ?? ""
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

/// A public client that attaches discovered Workspaces to Timelines, detaches
/// them, invokes their tools, and reports effective status.
///
/// The client shares the Axoloty transport owned by the
/// ``GnosticConsumerSession`` that created it. It opens no second connection,
/// hosts no Node, and advertises nothing. Every call resolves its target from
/// the session catalog; discovery is refreshed only when the target is absent.
///
/// ## Approved attach
///
/// Attachment is a user-approved operation. ``attach(workspaceID:to:approved:providerID:)``
/// refuses an unapproved request with
/// ``GnosticWorkspaceClientError/approvalRequired`` before touching the
/// transport, and it requires the Workspace to be uniquely advertised as
/// available. The attach and detach calls run on the provider that advertised
/// the addressed Timeline, which is the Node that owns attachment intent.
///
/// ## Invocation
///
/// ``invoke(workspaceID:toolID:arguments:providerID:)`` resolves the Workspace's
/// advertising provider and calls Gnostic's generic
/// `me.atkn.gnostic.workspace.invoke` operation. It never falls back to a local
/// filesystem path.
///
/// ## Lifetime
///
/// The client is valid only while its session is running. After
/// ``GnosticConsumerSession/stop()`` the shared transport is gone and later
/// calls fail by transport timeout; create a new client from a new session
/// instead.
@MainActor
public final class GnosticWorkspaceClient {
    private let catalog: NetworkCatalog
    private let lookup: GnosticCatalogLookup
    private let channel: GnosticCallChannel<GnosticWorkspaceClientError>
    private let timeout: Duration

    init(
        manager: CommunicationManager,
        catalog: NetworkCatalog,
        subscription: GnosticSubscription,
        timeout: Duration
    ) {
        self.catalog = catalog
        lookup = GnosticCatalogLookup(manager: manager, catalog: catalog, subscription: subscription, timeout: timeout)
        channel = GnosticCallChannel(manager: manager)
        self.timeout = timeout
    }

    /// Returns whether a discovered Workspace can be attached without ambiguity.
    ///
    /// - Parameter workspaceID: The Workspace identifier.
    /// - Returns: The provider-independent attachment status.
    public func attachmentStatus(workspaceID: UUID) async -> WorkspaceAttachmentStatus {
        await catalog.workspaceAttachmentStatus(id: workspaceID)
    }

    /// Returns the Gnostic-owned effective usability of a discovered Workspace.
    ///
    /// - Parameter workspaceID: The Workspace identifier.
    /// - Returns: `available`, `unavailable`, or `unsupported`.
    public func effectiveStatus(workspaceID: UUID) async -> GnosticWorkspaceEffectiveStatus {
        Self.effectiveStatus(await attachmentStatus(workspaceID: workspaceID))
    }

    /// Attaches a discovered Workspace to a Timeline through the approved path.
    ///
    /// - Parameters:
    ///   - workspaceID: The discovered Workspace identifier.
    ///   - timelineID: The Timeline that will own the attachment.
    ///   - approved: The caller's explicit user approval. `false` is refused
    ///     locally without a wire call.
    ///   - providerID: The expected provider that owns the Timeline, or `nil` to
    ///     resolve it from the session catalog.
    /// - Throws: ``GnosticWorkspaceClientError`` when approval is missing, the
    ///   Workspace or Timeline cannot be resolved, the addressed provider does
    ///   not own the Timeline, the Timeline's Ascendant does not advertise
    ///   ``GnosticCapability/workspaceAttachment``, or the serve rejected the
    ///   attach.
    public func attach(
        workspaceID: UUID,
        to timelineID: UUID,
        approved: Bool,
        providerID: String? = nil
    ) async throws {
        guard approved else { throw GnosticWorkspaceClientError.approvalRequired }
        _ = try await resolvedWorkspaceProvider(nil, for: workspaceID)
        let target = try await resolvedTimelineProvider(providerID, for: timelineID)
        try await requireAttachmentCapability(forTimeline: timelineID, providerID: target)
        let result = try await channel.call(
            WorkspaceOpsProvider.attachOperation,
            request: WorkspaceOpsRequest(workspaceID: workspaceID, timelineID: timelineID),
            context: "workspace.attach request",
            providerID: target,
            timeout: timeout,
            returning: WorkspaceMutationResult.self
        )
        guard result.accepted else {
            throw GnosticWorkspaceClientError.callFailed(
                reasonCode: "workspaceAttachRejected",
                statusCode: 409,
                retryable: false
            )
        }
    }

    /// Detaches an attached Workspace from a Timeline.
    ///
    /// - Parameters:
    ///   - workspaceID: The attached Workspace identifier.
    ///   - timelineID: The Timeline that owns the attachment.
    ///   - providerID: The expected provider that owns the Timeline, or `nil` to
    ///     resolve it from the session catalog.
    /// - Throws: ``GnosticWorkspaceClientError`` when the Timeline cannot be
    ///   resolved, the addressed provider does not own it, or the serve rejected
    ///   the detach.
    public func detach(
        workspaceID: UUID,
        from timelineID: UUID,
        providerID: String? = nil
    ) async throws {
        let target = try await resolvedTimelineProvider(providerID, for: timelineID)
        let result = try await channel.call(
            WorkspaceOpsProvider.detachOperation,
            request: WorkspaceOpsRequest(workspaceID: workspaceID, timelineID: timelineID),
            context: "workspace.detach request",
            providerID: target,
            timeout: timeout,
            returning: WorkspaceMutationResult.self
        )
        guard result.accepted else {
            throw GnosticWorkspaceClientError.callFailed(
                reasonCode: "workspaceDetachRejected",
                statusCode: 409,
                retryable: false
            )
        }
    }

    /// Invokes one advertised custom tool on a discovered Workspace.
    ///
    /// - Parameters:
    ///   - workspaceID: The discovered Workspace identifier.
    ///   - toolID: The advertised custom tool identifier.
    ///   - arguments: The tool arguments as Gnostic-owned JSON values.
    ///   - providerID: The expected Workspace provider, or `nil` to resolve it
    ///     from the session catalog.
    /// - Returns: The Gnostic-owned invocation result.
    /// - Throws: ``GnosticWorkspaceClientError`` when the Workspace cannot be
    ///   resolved, the addressed provider does not own it, the provider does not
    ///   advertise ``GnosticCapability/workspaceToolInvocation``, or the
    ///   invocation failed.
    public func invoke(
        workspaceID: UUID,
        toolID: String,
        arguments: [String: ManifestJSONValue] = [:],
        providerID: String? = nil
    ) async throws -> GnosticWorkspaceToolResult {
        let target = try await resolvedWorkspaceProvider(providerID, for: workspaceID)
        try await requireInvocationCapability(providerID: target)
        return try await channel.call(
            GnosticWorkspaceProvider.invocationOperation,
            request: WorkspaceInvocationPayload(
                workspaceID: workspaceID,
                providerID: target,
                toolID: toolID,
                arguments: arguments
            ),
            context: "workspace.invoke request",
            providerID: target,
            timeout: timeout,
            returning: GnosticWorkspaceToolResult.self
        )
    }

    private func resolvedWorkspaceProvider(
        _ explicitProviderID: String?,
        for workspaceID: UUID
    ) async throws -> String {
        var status = await catalog.workspaceAttachmentStatus(id: workspaceID)
        if case .unavailable = status {
            await lookup.refresh()
            status = await catalog.workspaceAttachmentStatus(id: workspaceID)
        }
        switch status {
        case let .available(providerID, _):
            if let explicitProviderID,
               explicitProviderID.caseInsensitiveCompare(providerID) != .orderedSame {
                throw GnosticWorkspaceClientError.providerMismatch
            }
            return providerID
        case .unavailable:
            throw GnosticWorkspaceClientError.workspaceUnavailable(workspaceID)
        case .ambiguous:
            throw GnosticWorkspaceClientError.workspaceAmbiguous(workspaceID)
        case .malformed, .unsupported:
            throw GnosticWorkspaceClientError.workspaceUnsupported(workspaceID)
        }
    }

    private func resolvedTimelineProvider(
        _ explicitProviderID: String?,
        for timelineID: UUID
    ) async throws -> String {
        let entries = await lookup.entries(requiring: GnosticObjectType.timeline, id: timelineID)
        switch GnosticCatalogLookup.provider(
            of: GnosticObjectType.timeline,
            id: timelineID,
            in: entries,
            expected: explicitProviderID
        ) {
        case let .provider(providerID): return providerID
        case .unavailable: throw GnosticWorkspaceClientError.timelineUnavailable(timelineID)
        case .ambiguous: throw GnosticWorkspaceClientError.timelineAmbiguous(timelineID)
        case .mismatch: throw GnosticWorkspaceClientError.providerMismatch
        }
    }

    private func requireAttachmentCapability(
        forTimeline timelineID: UUID,
        providerID: String
    ) async throws {
        let entries = await catalog.networkObjects()
        guard let ascendantID = GnosticCatalogLookup.operatingAscendantID(
            ofTimeline: timelineID,
            providerID: providerID,
            in: entries
        ) else {
            throw GnosticWorkspaceClientError.timelineUnavailable(timelineID)
        }
        guard GnosticCatalogLookup.ascendantAdvertises(
            GnosticCapability.workspaceAttachment,
            ascendantID: ascendantID,
            providerID: providerID,
            in: entries
        ) else {
            throw GnosticWorkspaceClientError.missingCapability(GnosticCapability.workspaceAttachment)
        }
    }

    private func requireInvocationCapability(providerID: String) async throws {
        let entries = await catalog.networkObjects()
        guard GnosticCatalogLookup.ascendantAdvertises(
            GnosticCapability.workspaceToolInvocation,
            providerID: providerID,
            in: entries
        ) else {
            throw GnosticWorkspaceClientError.missingCapability(GnosticCapability.workspaceToolInvocation)
        }
    }

    private static func effectiveStatus(
        _ status: WorkspaceAttachmentStatus
    ) -> GnosticWorkspaceEffectiveStatus {
        switch status {
        case .available: .available
        case .unavailable: .unavailable
        case .malformed, .ambiguous, .unsupported: .unsupported
        }
    }
}

/// The wire payload for Gnostic's generic remote workspace invocation.
///
/// Reuses the released `WorkspaceInvocation` field names so an advertised
/// provider decodes it unchanged, while keeping the Core seam free of
/// PositronicKit argument values.
private struct WorkspaceInvocationPayload: Encodable {
    let protocolMajor: Int
    let workspaceID: UUID
    let providerID: String?
    let toolID: String
    let arguments: [String: ManifestJSONValue]

    init(workspaceID: UUID, providerID: String?, toolID: String, arguments: [String: ManifestJSONValue]) {
        protocolMajor = GnosticProtocol.currentMajor
        self.workspaceID = workspaceID
        self.providerID = providerID
        self.toolID = toolID
        self.arguments = arguments
    }
}
