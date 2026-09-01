// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Stable interoperability behaviors a remote client may select by name.
/// Backend kind and version are intentionally not capabilities.
public enum AscendantInteroperabilityCapability: String, Codable, Sendable, Equatable, CaseIterable {
    case textTurn = "me.atkn.gnostic.capability.turn.text"
    case streamedUpdates = "me.atkn.gnostic.capability.turn.stream"
    case cancellation = "me.atkn.gnostic.capability.turn.cancel"
    case replay = "me.atkn.gnostic.capability.turn.replay"
    case permissionMediation = "me.atkn.gnostic.capability.permission.mediation"
    case workspaceAttachment = "me.atkn.gnostic.capability.workspace.attach"
    case workspaceToolInvocation = "me.atkn.gnostic.capability.workspace.tool"
}

/// Runtime health of an Ascendant's bound backend.
///
/// Health is deliberately separate from routability: a failed backend keeps
/// its Gnostic-owned Ascendant and Timeline relationships available for a
/// bounded reconstruction attempt.
public enum AscendantBackendHealth: String, Codable, Sendable, Equatable {
    case healthy
    case failed
    case unknown
}

public struct AscendantBackendCapabilities: Codable, Sendable, Equatable {
    public let interoperability: Set<String>
    public let host: Set<String>
    public let backendKind: String?
    public let backendVersion: String?

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

    public static var empty: Self { .init() }
}

/// The stable identity projection owned by Gnostic for one Ascendant.
///
/// A backend may use a provider-native identity internally, but that identity
/// must never become part of the Gnostic host contract.
public struct AscendantBackendIdentity: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let description: String
    public let privateTimelineID: UUID
    public let primaryWorkspaceID: UUID?
    public let lastActiveAt: Date
    public let createdAt: Date
    public let updatedAt: Date
    public let capabilities: AscendantBackendCapabilities

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
    public let id: UUID
    public let title: String
    public let attachedWorkspaceIDs: [UUID]
    public let ascendantID: UUID?
    public let isArchived: Bool
    public let isPrivate: Bool
    public let createdAt: Date
    public let updatedAt: Date

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

    public var attachedAscendantID: UUID? { ascendantID }
}

/// A turn supplied to a backend Timeline session. Timeline identity is bound
/// when the session is opened and cannot drift between execution calls.
public struct AscendantBackendTimelineTurnRequest: Sendable, Equatable {
    public let message: String
    public let clientTurnID: String?

    public init(message: String, clientTurnID: String? = nil) {
        self.message = message
        self.clientTurnID = clientTurnID
    }
}

/// The small update shape a backend can emit without knowing Axoloty or ACP.
public struct AscendantBackendUpdate: Sendable, Equatable {
    public let kind: String
    public let text: String?
    public let toolState: AscendantToolState?
    public let permissionState: AscendantPermissionState?
    public let terminal: Bool

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
    func append(_ update: AscendantBackendUpdate) async
}

/// Backend-owned execution context for one Gnostic Timeline.
///
/// Implementations may hold a provider-native thread handle, transcript, and
/// tool context. Gnostic retains ownership of routing and Timeline identity.
@MainActor
public protocol AscendantBackendTimelineSession: AnyObject, Sendable {
    var id: UUID { get }
    func runTurn(
        _ request: AscendantBackendTimelineTurnRequest,
        updates: any AscendantBackendUpdateSink
    ) async throws -> String
    func rename(to title: String) async throws -> AscendantBackendTimeline
}

/// A generic, backend-neutral description of a Workspace capability.
public struct BackendWorkspaceTool: Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let parametersSchema: ManifestJSONValue?
    public let requiresPermission: Bool

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
    case available
    case unavailable
    case unsupported
}

public struct BackendWorkspaceReference: Sendable, Equatable {
    public let id: UUID
    public let uri: String
    public let status: BackendWorkspaceStatus
    public let tools: [BackendWorkspaceTool]

    public init(id: UUID, uri: String, status: BackendWorkspaceStatus, tools: [BackendWorkspaceTool] = []) {
        self.id = id
        self.uri = uri
        self.status = status
        self.tools = tools
    }
}

public struct BackendWorkspaceInvocation: Sendable, Equatable {
    public let workspaceID: UUID
    public let toolID: String
    public let arguments: [String: ManifestJSONValue]

    public init(workspaceID: UUID, toolID: String, arguments: [String: ManifestJSONValue] = [:]) {
        self.workspaceID = workspaceID
        self.toolID = toolID
        self.arguments = arguments
    }
}

public struct BackendWorkspaceResult: Sendable, Equatable {
    public let value: ManifestJSONValue?
    public let message: String?

    public init(value: ManifestJSONValue? = nil, message: String? = nil) {
        self.value = value
        self.message = message
    }
}

/// Workspace consumption is an optional host capability, not a transport
/// object passed to every backend. Backends that do not consume Workspaces can
/// use ``AscendantBackendServices.empty`` without manufacturing a no-op
/// Workspace service.
@MainActor
public protocol AscendantBackendWorkspaceService: Sendable {
    func reference(id: UUID) async -> BackendWorkspaceReference?
    func invoke(_ invocation: BackendWorkspaceInvocation) async throws -> BackendWorkspaceResult
}

/// Permission mediation is intentionally a narrow host service.
public struct BackendPermissionRequest: Sendable, Equatable {
    public let correlationID: String
    public let timelineID: UUID
    public let clientTurnID: String
    public let toolCallID: String
    public let title: String

    public init(correlationID: String = UUID().uuidString.lowercased(), timelineID: UUID, clientTurnID: String, toolCallID: String, title: String) {
        self.correlationID = correlationID
        self.timelineID = timelineID
        self.clientTurnID = clientTurnID
        self.toolCallID = toolCallID
        self.title = title
    }
}

public protocol AscendantBackendPermissionService: Sendable {
    func request(_ request: BackendPermissionRequest) async -> Bool
}

/// Optional capability marker for services that are meaningful only to one
/// backend implementation. The mandatory contract never depends on it.
public protocol AscendantBackendOptionalCapability: Sendable {}

/// Optional Workspace operations bound to one Timeline session. A backend that
/// does not support Workspaces can satisfy the mandatory Timeline contract
/// without manufacturing no-op operations.
@MainActor
public protocol AscendantBackendTimelineWorkspaceSession: AscendantBackendTimelineSession {
    func attachWorkspace(_ reference: BackendWorkspaceReference) async throws -> AscendantBackendTimeline
    func detachWorkspace(id workspaceID: UUID) async throws -> AscendantBackendTimeline
    func enabledToolIDs() async -> [String]
}

/// The only construction-time host values available to a backend-neutral
/// contract. Axoloty and Coaty objects remain in the Gnostic host composition
/// layer and in backend-specific adapters.
public struct AscendantBackendServices: Sendable {
    public let workspace: (any AscendantBackendWorkspaceService)?
    public let permission: any AscendantBackendPermissionService
    public let optionalCapabilities: [any AscendantBackendOptionalCapability]

    public init(
        workspace: (any AscendantBackendWorkspaceService)? = nil,
        permission: any AscendantBackendPermissionService,
        optionalCapabilities: [any AscendantBackendOptionalCapability] = []
    ) {
        self.workspace = workspace
        self.permission = permission
        self.optionalCapabilities = optionalCapabilities
    }

    @MainActor
    public static var empty: Self {
        .init(permission: EmptyBackendPermissionService())
    }

    public func capability<C: AscendantBackendOptionalCapability>(_: C.Type) -> C? {
        optionalCapabilities.compactMap { $0 as? C }.first
    }
}

/// Structured terminal failure returned by backend-owned model/tool work.
public struct AscendantBackendTerminalFailure: Error, Codable, Sendable, Equatable, LocalizedError {
    public let code: String
    public let message: String
    public let retryable: Bool

    public init(code: String, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }

    public var errorDescription: String? { message }
}

/// Explicitly means that the backend can no longer serve its bound Ascendant.
/// Ordinary model/provider/tool/cancellation failures must not use this case.
public struct AscendantBackendLifecycleFailure: Error, Codable, Sendable, Equatable, LocalizedError {
    public let code: String
    public let message: String

    public init(code: String = "backendLifecycleUnusable", message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Identifies a violation of the Timeline-bound backend contract.
public enum AscendantBackendContractViolation: Error, Sendable, Equatable, LocalizedError {
    case sessionTimelineMismatch(expected: UUID, actual: UUID)
    case projectionTimelineMismatch(expected: UUID, actual: UUID)
    case projectionAscendantMismatch(expected: UUID, actual: UUID?)

    public var errorDescription: String? {
        switch self {
        case let .sessionTimelineMismatch(expected, actual):
            "Backend returned Timeline \(actual.uuidString) for requested Timeline \(expected.uuidString)."
        case let .projectionTimelineMismatch(expected, actual):
            "Backend returned projection for Timeline \(actual.uuidString) on session \(expected.uuidString)."
        case let .projectionAscendantMismatch(expected, actual):
            "Backend returned projection for Ascendant \(actual?.uuidString ?? "none") on Ascendant \(expected.uuidString)."
        }
    }
}

public enum AscendantBackendError: Error, Sendable, Equatable, LocalizedError {
    case invalidConfiguration(String)
    case timelineNotFound(UUID)
    case contractViolation(AscendantBackendContractViolation)
    case terminal(AscendantBackendTerminalFailure)
    case cancelled
    case lifecycleUnusable(AscendantBackendLifecycleFailure)

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(detail): detail
        case let .timelineNotFound(id): "Timeline \(id.uuidString) is not operated by this backend."
        case let .contractViolation(violation): violation.localizedDescription
        case let .terminal(failure): failure.message
        case .cancelled: "The backend turn was cancelled."
        case let .lifecycleUnusable(failure): failure.message
        }
    }

    public var reasonCode: String {
        switch self {
        case .invalidConfiguration: return "invalidConfiguration"
        case .timelineNotFound: return "timelineNotFound"
        case .contractViolation: return "backendContractViolation"
        case .terminal(let failure): return failure.code
        case .cancelled: return "cancelled"
        case .lifecycleUnusable(let failure): return failure.code
        }
    }

    public var statusCode: Int {
        switch self {
        case .invalidConfiguration: return 400
        case .timelineNotFound: return 404
        case .contractViolation: return 500
        case .terminal: return 500
        case .cancelled: return 499
        case .lifecycleUnusable: return 503
        }
    }
}

/// Structural validation common to every backend envelope. Semantic settings
/// remain owned by the selected backend implementation.
public enum AscendantBackendConfigurationValidator {
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
    var identity: AscendantBackendIdentity { get }

    /// Validates backend-owned semantics after Gnostic has checked the
    /// bounded envelope shape and before the backend is published.
    func validateConfiguration() throws
    func operatedTimelines() async throws -> [AscendantBackendTimeline]
    func createTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline
    func removeTimeline(id: UUID) async
    func timeline(id: UUID) async throws -> any AscendantBackendTimelineSession
    func cancel() async
    func shutdown() async
}

private struct EmptyBackendPermissionService: AscendantBackendPermissionService {
    func request(_: BackendPermissionRequest) async -> Bool { false }
}
