// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Stable interoperability behaviors a remote client may select by name.
/// Backend kind and version are intentionally not capabilities.
public enum AscendantInteroperabilityCapability: String, Codable, Sendable, Equatable, CaseIterable {
    /// A plain text prompt and reply.
    case textTurn = "me.atkn.gnostic.capability.turn.text"
    /// Incremental updates streamed while a Turn runs.
    case streamedUpdates = "me.atkn.gnostic.capability.turn.stream"
    /// In-flight cancellation of a running Turn.
    case cancellation = "me.atkn.gnostic.capability.turn.cancel"
    /// Replay of a completed Turn's bounded update stream.
    case replay = "me.atkn.gnostic.capability.turn.replay"
    /// Host-mediated approval for tool calls that require it.
    case permissionMediation = "me.atkn.gnostic.capability.permission.mediation"
    /// Attaching a Workspace to a Timeline.
    case workspaceAttachment = "me.atkn.gnostic.capability.workspace.attach"
    /// Invoking a tool advertised by an attached Workspace.
    case workspaceToolInvocation = "me.atkn.gnostic.capability.workspace.tool"
}

/// Runtime health of an Ascendant's bound backend.
///
/// Health is deliberately separate from routability: a failed backend keeps
/// its Gnostic-owned Ascendant and Timeline relationships available for a
/// bounded reconstruction attempt.
public enum AscendantBackendHealth: String, Codable, Sendable, Equatable {
    /// The backend is bound and serving its Ascendant.
    case healthy
    /// The backend can no longer serve; reconstruction may be attempted.
    case failed
    /// No health has been observed yet.
    case unknown
}

/// The capabilities an Ascendant advertises to remote clients.
///
/// `interoperability` is a `Set<String>` rather than a set of
/// ``AscendantInteroperabilityCapability`` on purpose: capability IDs are
/// negotiated with peers that may run a newer build, so a value this build
/// does not know must survive a round trip rather than be dropped.
public struct AscendantBackendCapabilities: Codable, Sendable, Equatable {
    /// Interoperability capability IDs, as raw ``AscendantInteroperabilityCapability`` values.
    public let interoperability: Set<String>
    /// Host-defined capability IDs that are not part of the interoperability contract.
    public let host: Set<String>
    /// The backend implementation's kind, for diagnostics only. Never routed on.
    public let backendKind: String?
    /// The backend implementation's version, for diagnostics only.
    public let backendVersion: String?

    /// Creates a capability set. Every field is optional.
    public init(
        interoperability: Set<String> = [],
        host: Set<String> = [],
        backendKind: String? = nil,
        backendVersion: String? = nil
    ) {
        self.interoperability = interoperability
        self.host = host
        self.backendKind = backendKind
        self.backendVersion = backendVersion
    }

    /// A capability set advertising nothing.
    public static var empty: Self { .init() }
}

/// The stable identity projection owned by Gnostic for one Ascendant.
///
/// A backend may use a provider-native identity internally, but that identity
/// must never become part of the Gnostic host contract.
public struct AscendantBackendIdentity: Sendable, Equatable {
    /// The Gnostic-owned Ascendant identifier.
    public let id: UUID
    /// The Ascendant's display name.
    public let name: String
    /// The Ascendant's description.
    public let description: String
    /// The Timeline the Ascendant operates privately.
    public let privateTimelineID: UUID
    /// The Workspace bound to the Ascendant by default, if any.
    public let primaryWorkspaceID: UUID?
    /// When the Ascendant last served a Turn.
    public let lastActiveAt: Date
    /// When Gnostic created the Ascendant.
    public let createdAt: Date
    /// When the Ascendant's projection last changed.
    public let updatedAt: Date
    /// What the Ascendant advertises it can do.
    public let capabilities: AscendantBackendCapabilities

    /// Creates the Gnostic-owned identity projection for one Ascendant.
    public init(
        id: UUID,
        name: String,
        description: String,
        privateTimelineID: UUID,
        primaryWorkspaceID: UUID?,
        lastActiveAt: Date,
        createdAt: Date,
        updatedAt: Date,
        capabilities: AscendantBackendCapabilities = .empty
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.privateTimelineID = privateTimelineID
        self.primaryWorkspaceID = primaryWorkspaceID
        self.lastActiveAt = lastActiveAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.capabilities = capabilities
    }

}

/// The backend's private projection of a Gnostic Timeline.
public struct AscendantBackendTimeline: Sendable, Equatable {
    /// The Gnostic-owned Timeline identifier.
    public let id: UUID
    /// The Timeline's title.
    public let title: String
    /// Workspaces currently attached to the Timeline.
    public let attachedWorkspaceIDs: [UUID]
    /// The Ascendant operating the Timeline, if any.
    public let ascendantID: UUID?
    /// Whether the Timeline is archived.
    public let isArchived: Bool
    /// Whether the Timeline is the operating Ascendant's private Timeline.
    public let isPrivate: Bool
    /// When Gnostic created the Timeline.
    public let createdAt: Date
    /// When the Timeline last changed.
    public let updatedAt: Date

    /// Creates a backend's projection of one Gnostic Timeline.
    public init(
        id: UUID,
        title: String,
        attachedWorkspaceIDs: [UUID],
        ascendantID: UUID?,
        isArchived: Bool,
        isPrivate: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.attachedWorkspaceIDs = attachedWorkspaceIDs
        self.ascendantID = ascendantID
        self.isArchived = isArchived
        self.isPrivate = isPrivate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Compatibility initializer for the pre-reset projection spelling.
    public init(
        id: UUID,
        title: String,
        attachedWorkspaceIDs: [UUID],
        attachedAscendantID: UUID?,
        isArchived: Bool,
        isPrivate: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.init(
            id: id,
            title: title,
            attachedWorkspaceIDs: attachedWorkspaceIDs,
            ascendantID: attachedAscendantID,
            isArchived: isArchived,
            isPrivate: isPrivate,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// The pre-reset spelling of ``ascendantID``.
    public var attachedAscendantID: UUID? { ascendantID }
}

/// A Timeline-addressed operation supplied to an Ascendant Backend.
public struct AscendantBackendTurnRequest: Sendable, Equatable {
    /// The Timeline the Turn runs on.
    public let timelineID: UUID
    /// The prompt text.
    public let message: String
    /// The caller's idempotency key, when the Turn is identified.
    public let clientTurnID: String?

    /// Creates a Timeline-addressed Turn request.
    public init(timelineID: UUID, message: String, clientTurnID: String? = nil) {
        self.timelineID = timelineID
        self.message = message
        self.clientTurnID = clientTurnID
    }
}

/// The small update shape a backend can emit without knowing Axoloty or ACP.
public struct AscendantBackendUpdate: Sendable, Equatable {
    /// The update kind, as a raw ``AscendantTurnUpdateKind`` value.
    public let kind: String
    /// Assistant text, for text-bearing kinds.
    public let text: String?
    /// Tool call state, for tool-bearing kinds.
    public let toolState: AscendantToolState?
    /// Permission state, for permission-bearing kinds.
    public let permissionState: AscendantPermissionState?
    /// Whether this update ends the Turn.
    public let terminal: Bool

    /// Creates one backend update.
    public init(
        kind: String,
        text: String? = nil,
        toolState: AscendantToolState? = nil,
        permissionState: AscendantPermissionState? = nil,
        terminal: Bool = false
    ) {
        self.kind = kind
        self.text = text
        self.toolState = toolState
        self.permissionState = permissionState
        self.terminal = terminal
    }
}

/// Host-owned sink for backend turn updates.
public protocol AscendantBackendUpdateSink: Sendable {
    /// Appends one update to the Turn's stream.
    ///
    /// - Parameter update: The update to record and forward.
    /// - Throws: When the host cannot accept the update, for example because
    ///   update retention is full.
    func append(_ update: AscendantBackendUpdate) async throws
}

/// A generic, backend-neutral description of a Workspace capability.
public struct BackendWorkspaceTool: Sendable, Equatable {
    /// The tool identifier used to invoke it.
    public let id: String
    /// The tool's display name.
    public let name: String
    /// What the tool does, as shown to a model.
    public let description: String
    /// The tool's JSON Schema parameters, when it declares any.
    public let parametersSchema: ManifestJSONValue?
    /// Whether invoking the tool requires client approval.
    public let requiresPermission: Bool

    /// Creates a backend-neutral tool description.
    public init(
        id: String,
        name: String,
        description: String,
        parametersSchema: ManifestJSONValue? = nil,
        requiresPermission: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.parametersSchema = parametersSchema
        self.requiresPermission = requiresPermission
    }
}

/// Effective Workspace status as consumed by a backend. Attachment intent is
/// held by ``NodeRegistry`` and is deliberately absent from this projection.
public enum BackendWorkspaceStatus: String, Codable, Sendable, Equatable {
    /// The Workspace is attached and can serve tool calls.
    case available
    /// The Workspace is known but cannot currently serve tool calls.
    case unavailable
    /// The Workspace advertises nothing this host can consume.
    case unsupported
}

/// A Workspace as a backend sees it.
public struct BackendWorkspaceReference: Sendable, Equatable {
    /// The Gnostic-owned Workspace identifier.
    public let id: UUID
    /// The Workspace URI.
    public let uri: String
    /// Whether the Workspace can currently serve tool calls.
    public let status: BackendWorkspaceStatus
    /// The tools the Workspace advertises.
    public let tools: [BackendWorkspaceTool]

    /// Creates a backend's view of one Workspace.
    public init(id: UUID, uri: String, status: BackendWorkspaceStatus, tools: [BackendWorkspaceTool] = []) {
        self.id = id
        self.uri = uri
        self.status = status
        self.tools = tools
    }
}

/// A request to invoke one tool on one attached Workspace.
public struct BackendWorkspaceInvocation: Sendable, Equatable {
    /// The Workspace that owns the tool.
    public let workspaceID: UUID
    /// The advertised tool identifier.
    public let toolID: String
    /// The tool arguments, matching its declared schema.
    public let arguments: [String: ManifestJSONValue]

    /// Creates a Workspace tool invocation.
    public init(workspaceID: UUID, toolID: String, arguments: [String: ManifestJSONValue] = [:]) {
        self.workspaceID = workspaceID
        self.toolID = toolID
        self.arguments = arguments
    }
}

/// The result of one Workspace tool invocation.
public struct BackendWorkspaceResult: Sendable, Equatable {
    /// The structured result, when the tool returned one.
    public let value: ManifestJSONValue?
    /// A human-readable result or failure description.
    public let message: String?

    /// Creates a Workspace tool result.
    public init(value: ManifestJSONValue? = nil, message: String? = nil) {
        self.value = value
        self.message = message
    }
}

/// Tool-call access to attached Workspaces.
///
/// This is the Workspace surface every Workspace-consuming backend gets: look
/// up a Workspace, invoke one of its advertised tools. File access is a
/// separate, optional surface -- see ``AscendantBackendWorkspaceFileService``.
///
/// Workspace consumption is an optional host capability, not a transport
/// object passed to every backend. Backends that do not consume Workspaces can
/// use ``AscendantBackendServices/empty`` without manufacturing a no-op
/// Workspace service.
@MainActor
public protocol AscendantBackendWorkspaceService: Sendable {
    /// Looks up one attached Workspace.
    ///
    /// - Parameter id: The Gnostic-owned Workspace identifier.
    /// - Returns: The Workspace, or `nil` when it is not attached.
    func reference(id: UUID) async -> BackendWorkspaceReference?
    /// Invokes one tool on an attached Workspace.
    ///
    /// - Parameter invocation: The Workspace, tool, and arguments.
    /// - Returns: The tool's result.
    /// - Throws: When the Workspace is unavailable or the tool rejects the call.
    func invoke(_ invocation: BackendWorkspaceInvocation) async throws -> BackendWorkspaceResult
}

/// Permission mediation is intentionally a narrow host service.
public struct BackendPermissionRequest: Sendable, Equatable {
    /// Correlates the request with its response and its replayed update.
    public let correlationID: String
    /// The Timeline whose Turn requires approval.
    public let timelineID: UUID
    /// The identified Turn requiring approval.
    public let clientTurnID: String
    /// The tool call awaiting approval.
    public let toolCallID: String
    /// What the client is being asked to approve.
    public let title: String

    /// Creates a correlated permission request.
    public init(correlationID: String = UUID().uuidString.lowercased(), timelineID: UUID, clientTurnID: String, toolCallID: String, title: String) {
        self.correlationID = correlationID
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
        self.toolCallID = toolCallID
        self.title = title
    }
}

/// The outcome of a mediated permission request.
///
/// ``unavailable(reason:)`` is deliberately distinct from ``denied``: the
/// client was never shown a choice, so reporting it as a denial would
/// misattribute a host failure to the user.
public enum AscendantPermissionDecision: Sendable, Equatable {
    /// The client approved the request.
    case approved
    /// The client was asked and refused.
    case denied
    /// The host could not put the request to the client.
    ///
    /// - Parameter reason: A stable, low-cardinality reason code. It carries
    ///   no user content.
    case unavailable(reason: String)

    /// Whether the tool call may proceed.
    public var isApproved: Bool { self == .approved }
}

/// Host-owned mediation for tool calls that require client approval.
public protocol AscendantBackendPermissionService: Sendable {
    /// Puts one permission request to the client and awaits its decision.
    ///
    /// - Parameter request: The correlated request to mediate.
    /// - Returns: The client's decision, or ``AscendantPermissionDecision/unavailable(reason:)``
    ///   when the host could not ask.
    func requestApproval(for request: BackendPermissionRequest) async -> AscendantPermissionDecision
}

/// Optional capability marker for services that are meaningful only to one
/// backend implementation. The mandatory contract never depends on it.
public protocol AscendantBackendOptionalCapability: Sendable {}

/// Optional Workspace operations implemented only by backends that consume
/// Gnostic's Workspace service. A backend that does not support Workspaces can
/// satisfy the mandatory contract without manufacturing no-op operations.
@MainActor
public protocol AscendantBackendWorkspaceCapability: AnyObject, Sendable {
    /// Attaches a Workspace to one Timeline.
    ///
    /// - Parameters:
    ///   - reference: The Workspace to attach.
    ///   - timelineID: The Timeline receiving it.
    /// - Throws: When the backend cannot project the attachment.
    func attachWorkspace(_ reference: BackendWorkspaceReference, to timelineID: UUID) async throws
    /// Detaches a Workspace from one Timeline.
    ///
    /// - Parameters:
    ///   - workspaceID: The Workspace to detach.
    ///   - timelineID: The Timeline losing it.
    /// - Throws: When the backend cannot project the detachment.
    func detachWorkspace(_ workspaceID: UUID, from timelineID: UUID) async throws
    /// Lists the tools currently enabled on one Timeline.
    ///
    /// - Parameter timelineID: The Timeline to inspect.
    /// - Returns: The enabled tool identifiers.
    func enabledToolIDs(for timelineID: UUID) async -> [String]
}

/// The only construction-time host values available to a backend-neutral
/// contract. Axoloty and Coaty objects remain in the Gnostic host composition
/// layer and in backend-specific adapters.
public struct AscendantBackendServices: Sendable {
    /// Workspace consumption, when the host offers it.
    public let workspace: (any AscendantBackendWorkspaceService)?
    /// Permission mediation. Always present; see ``AscendantBackendServices/empty``.
    public let permission: any AscendantBackendPermissionService
    /// Backend-specific services the mandatory contract never depends on.
    public let optionalCapabilities: [any AscendantBackendOptionalCapability]

    /// Creates the construction-time services for one backend.
    public init(
        workspace: (any AscendantBackendWorkspaceService)? = nil,
        permission: any AscendantBackendPermissionService,
        optionalCapabilities: [any AscendantBackendOptionalCapability] = []
    ) {
        self.workspace = workspace
        self.permission = permission
        self.optionalCapabilities = optionalCapabilities
    }

    /// Services for a backend that consumes no Workspace and has no host
    /// permission mediation. Every permission request reports
    /// ``AscendantPermissionDecision/unavailable(reason:)``.
    @MainActor
    public static var empty: Self {
        .init(permission: EmptyBackendPermissionService())
    }

    /// Resolves one optional capability by type.
    ///
    /// - Parameter _: The capability type to look for.
    /// - Returns: The first matching capability, or `nil` when none is installed.
    public func capability<C: AscendantBackendOptionalCapability>(_: C.Type) -> C? {
        optionalCapabilities.compactMap { $0 as? C }.first
    }
}

/// Structured terminal failure returned by backend-owned model/tool work.
public struct AscendantBackendTerminalFailure: Error, Codable, Sendable, Equatable, LocalizedError {
    /// A stable, low-cardinality failure code.
    public let code: String
    /// A client-safe failure description.
    public let message: String
    /// Whether an identical retry could succeed.
    public let retryable: Bool

    /// Creates a terminal failure.
    public init(code: String, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }

    /// The client-safe failure description.
    public var errorDescription: String? { message }
}

/// Explicitly means that the backend can no longer serve its bound Ascendant.
/// Ordinary model/provider/tool/cancellation failures must not use this case.
public struct AscendantBackendLifecycleFailure: Error, Codable, Sendable, Equatable, LocalizedError {
    /// A stable, low-cardinality failure code.
    public let code: String
    /// A client-safe failure description.
    public let message: String

    /// Creates a lifecycle failure.
    public init(code: String = "backendLifecycleUnusable", message: String) {
        self.code = code
        self.message = message
    }

    /// The client-safe failure description.
    public var errorDescription: String? { message }
}

/// Every failure the mandatory backend contract can produce.
public enum AscendantBackendError: Error, Sendable, Equatable, LocalizedError {
    /// The backend envelope is structurally or semantically invalid.
    case invalidConfiguration(String)
    /// The Timeline is not operated by this backend.
    case timelineNotFound(UUID)
    /// Model or tool work failed. The backend remains usable.
    case terminal(AscendantBackendTerminalFailure)
    /// The Turn was cancelled.
    case cancelled
    /// The backend can no longer serve its Ascendant.
    case lifecycleUnusable(AscendantBackendLifecycleFailure)

    /// A client-safe description of the failure.
    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(detail): detail
        case let .timelineNotFound(id): "Timeline \(id.uuidString) is not operated by this backend."
        case let .terminal(failure): failure.message
        case .cancelled: "The backend turn was cancelled."
        case let .lifecycleUnusable(failure): failure.message
        }
    }

    /// A stable, low-cardinality code identifying the failure.
    public var reasonCode: String {
        switch self {
        case .invalidConfiguration: return "invalidConfiguration"
        case .timelineNotFound: return "timelineNotFound"
        case .terminal(let failure): return failure.code
        case .cancelled: return "cancelled"
        case .lifecycleUnusable(let failure): return failure.code
        }
    }

    /// The Gnostic protocol status code for this failure.
    public var statusCode: Int {
        switch self {
        case .invalidConfiguration: return 400
        case .timelineNotFound: return 404
        case .terminal: return 500
        case .cancelled: return 499
        case .lifecycleUnusable: return 503
        }
    }
}

/// Structural validation common to every backend envelope. Semantic settings
/// remain owned by the selected backend implementation.
public enum AscendantBackendConfigurationValidator {
    /// Validates the bounded envelope shape.
    ///
    /// - Parameter configuration: The backend envelope to check.
    /// - Throws: ``AscendantBackendError/invalidConfiguration(_:)`` when the
    ///   envelope is structurally invalid.
    public static func validate(_ configuration: AscendantBackendConfiguration) throws {
        guard configuration.validate() else {
            throw AscendantBackendError.invalidConfiguration("Invalid backend configuration for '\(configuration.kind)'.")
        }
    }
}

/// The mandatory Ascendant Backend contract. It deliberately contains no
/// transport, provider-native identity/thread, or Coaty types.
@MainActor
public protocol AscendantBackend: AnyObject, Sendable {
    /// The Gnostic-owned identity this backend serves.
    var identity: AscendantBackendIdentity { get }

    /// Validates backend-owned semantics after Gnostic has checked the
    /// bounded envelope shape and before the backend is published.
    func validateConfiguration() throws
    /// Lists the Timelines this backend operates.
    ///
    /// - Returns: The backend's Timeline projections.
    /// - Throws: When the backend cannot enumerate them.
    func operatedTimelines() async throws -> [AscendantBackendTimeline]
    /// Creates one Timeline.
    ///
    /// - Parameters:
    ///   - id: The Gnostic-owned identifier to adopt.
    ///   - title: The Timeline title.
    /// - Returns: The created projection.
    /// - Throws: When the backend cannot create it.
    func createTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline
    /// Removes one Timeline. Removing an unknown Timeline is not an error.
    func removeTimeline(id: UUID) async
    /// Renames one Timeline.
    ///
    /// - Parameters:
    ///   - id: The Timeline to rename.
    ///   - title: The new title.
    /// - Returns: The updated projection.
    /// - Throws: ``AscendantBackendError/timelineNotFound(_:)`` when the
    ///   Timeline is not operated by this backend.
    func renameTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline
    /// Runs one Turn to completion.
    ///
    /// Incremental output must be delivered to `updates` as it is produced;
    /// the return value is the Turn's final assistant text, not an identifier.
    /// A Turn that completes without producing text returns an empty string.
    ///
    /// - Parameters:
    ///   - request: The Timeline-addressed prompt.
    ///   - updates: The sink receiving incremental updates.
    /// - Returns: The final assistant text.
    /// - Throws: ``AscendantBackendError/cancelled`` when the Turn was
    ///   cancelled, ``AscendantBackendError/terminal(_:)`` when model or tool
    ///   work failed, and ``AscendantBackendError/lifecycleUnusable(_:)`` when
    ///   the backend can no longer serve its Ascendant.
    func runTurn(_ request: AscendantBackendTurnRequest, updates: any AscendantBackendUpdateSink) async throws -> String
    /// Cancels the running Turn, if any. Returns once cancellation is requested.
    func cancel() async
    /// Releases the backend's resources. Called once, and not concurrently with a Turn.
    func shutdown() async
}

private struct EmptyBackendPermissionService: AscendantBackendPermissionService {
    /// Reports that no host mediation is installed.
    ///
    /// - Returns: Always ``AscendantPermissionDecision/unavailable(reason:)``.
    ///   This is not a denial: no client was ever asked.
    func requestApproval(for _: BackendPermissionRequest) async -> AscendantPermissionDecision {
        .unavailable(reason: "permissionMediationUnavailable")
    }
}
