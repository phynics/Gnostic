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
    private let manager: CommunicationManager
    private let catalog: NetworkCatalog
    private let subscription: GnosticSubscription
    private let timeout: Duration

    init(
        manager: CommunicationManager,
        catalog: NetworkCatalog,
        subscription: GnosticSubscription,
        timeout: Duration
    ) {
        self.manager = manager
        self.catalog = catalog
        self.subscription = subscription
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
        let payload = try GnosticWirePayload.encode(
            WorkspaceOpsRequest(workspaceID: workspaceID, timelineID: timelineID),
            context: "workspace.attach request"
        )
        let response = try await call(
            operation: WorkspaceOpsProvider.attachOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            providerID: target
        )
        let result = try Self.decode(WorkspaceMutationResult.self, from: response.result)
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
        let payload = try GnosticWirePayload.encode(
            WorkspaceOpsRequest(workspaceID: workspaceID, timelineID: timelineID),
            context: "workspace.detach request"
        )
        let response = try await call(
            operation: WorkspaceOpsProvider.detachOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            providerID: target
        )
        let result = try Self.decode(WorkspaceMutationResult.self, from: response.result)
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
        let payload = try GnosticWirePayload.encode(
            WorkspaceInvocationPayload(
                workspaceID: workspaceID,
                providerID: target,
                toolID: toolID,
                arguments: arguments
            ),
            context: "workspace.invoke request"
        )
        let response = try await call(
            operation: GnosticWorkspaceProvider.invocationOperation,
            parameters: String(decoding: payload, as: UTF8.self),
            providerID: target
        )
        return try Self.decode(GnosticWorkspaceToolResult.self, from: response.result)
    }

    private func resolvedWorkspaceProvider(
        _ explicitProviderID: String?,
        for workspaceID: UUID
    ) async throws -> String {
        var status = await catalog.workspaceAttachmentStatus(id: workspaceID)
        if case .unavailable = status {
            await subscription.discover(using: manager, timeout: timeout)
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
        var entries = await catalog.networkObjects()
        if !entries.contains(where: {
            $0.objectType == GnosticObjectType.timeline && $0.objectID == timelineID
        }) {
            await subscription.discover(using: manager, timeout: timeout)
            entries = await catalog.networkObjects()
        }
        let timelines = entries.filter {
            $0.objectType == GnosticObjectType.timeline && $0.objectID == timelineID
        }
        guard let providerID = timelines.first?.providerID else {
            throw GnosticWorkspaceClientError.timelineUnavailable(timelineID)
        }
        let providers = Set(timelines.map { $0.providerID.lowercased() })
        guard providers.count == 1 else {
            throw GnosticWorkspaceClientError.timelineAmbiguous(timelineID)
        }
        if let explicitProviderID,
           explicitProviderID.caseInsensitiveCompare(providerID) != .orderedSame {
            throw GnosticWorkspaceClientError.providerMismatch
        }
        return providerID
    }

    private func requireAttachmentCapability(
        forTimeline timelineID: UUID,
        providerID: String
    ) async throws {
        let entries = await catalog.networkObjects()
        let timelines = entries.filter {
            $0.objectType == GnosticObjectType.timeline
                && $0.objectID == timelineID
                && $0.providerID.caseInsensitiveCompare(providerID) == .orderedSame
        }
        let ascendantIDs = Set(timelines.compactMap { entry -> UUID? in
            guard case let .string(raw) = entry.knownProperties["attachedAscendantID"] else { return nil }
            return UUID(uuidString: raw)
        })
        guard ascendantIDs.count == 1, let ascendantID = ascendantIDs.first else {
            throw GnosticWorkspaceClientError.timelineUnavailable(timelineID)
        }
        guard entries.contains(where: { entry in
            entry.objectType == GnosticObjectType.ascendant
                && entry.objectID == ascendantID
                && entry.providerID.caseInsensitiveCompare(providerID) == .orderedSame
                && Self.capabilities(of: entry).contains(GnosticCapability.workspaceAttachment)
        }) else {
            throw GnosticWorkspaceClientError.missingCapability(GnosticCapability.workspaceAttachment)
        }
    }

    private func requireInvocationCapability(providerID: String) async throws {
        let entries = await catalog.networkObjects()
        guard entries.contains(where: { entry in
            entry.objectType == GnosticObjectType.ascendant
                && entry.providerID.caseInsensitiveCompare(providerID) == .orderedSame
                && Self.capabilities(of: entry).contains(GnosticCapability.workspaceToolInvocation)
        }) else {
            throw GnosticWorkspaceClientError.missingCapability(GnosticCapability.workspaceToolInvocation)
        }
    }

    private static func capabilities(of entry: NetworkCatalogEntry) -> [String] {
        guard case let .array(values) = entry.knownProperties["capabilities"] else { return [] }
        return values.compactMap { value in
            guard case let .string(capability) = value else { return nil }
            return capability
        }
    }

    private func call(
        operation: String,
        parameters: String,
        providerID: String
    ) async throws -> UnaryCallResult {
        let response: UnaryCallResult
        do {
            response = try await manager.call(
                operation: operation,
                parameters: parameters,
                context: Self.providerContext(providerID),
                timeout: timeout
            )
        } catch let failure as RemoteCallFailure {
            let decoded = try? JSONDecoder().decode(
                GnosticProtocolFailure.self,
                from: Data(failure.message.utf8)
            )
            throw GnosticWorkspaceClientError.callFailed(
                reasonCode: decoded?.reasonCode ?? "callFailed",
                statusCode: decoded?.statusCode ?? failure.code,
                retryable: decoded?.retryable ?? false
            )
        } catch let error as AxolotyError {
            throw Self.transportFailure(error)
        }
        guard response.sourceId?.lowercased() == providerID.lowercased() else {
            throw GnosticWorkspaceClientError.providerMismatch
        }
        return response
    }

    private static func decode<T: Decodable>(_ type: T.Type, from result: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(result.utf8))
        } catch {
            throw GnosticWorkspaceClientError.callFailed(
                reasonCode: "invalidResponse",
                statusCode: 502,
                retryable: false
            )
        }
    }

    private static func transportFailure(_ error: AxolotyError) -> GnosticWorkspaceClientError {
        switch error {
        case let .runtime(code, _):
            switch code {
            case .timedOut:
                return .callFailed(reasonCode: "callTimedOut", statusCode: 504, retryable: true)
            case .cancelled:
                return .callFailed(reasonCode: "callCancelled", statusCode: 499, retryable: false)
            default:
                return .callFailed(reasonCode: "transportFailure", statusCode: 503, retryable: true)
            }
        default:
            return .callFailed(reasonCode: "transportFailure", statusCode: 503, retryable: true)
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

    private static func providerContext(_ providerID: String) -> ObjectFilter {
        ObjectFilter(condition: ObjectFilterCondition(
            property: ObjectFilterProperty("objectId"),
            expression: .equals(FilterOperand(providerID.lowercased()))
        ))
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
