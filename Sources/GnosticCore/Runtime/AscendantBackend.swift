// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol

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

    /// The tool identifier used to invoke it.
    public var toolID: String { id }

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
    /// The Workspace placement relative to its runtime.
    public let location: GnosticWorkspaceLocation
    /// The Workspace creation timestamp.
    public let createdAt: Date

    /// Creates a backend's view of one Workspace.
    public init(
        id: UUID,
        uri: String,
        status: BackendWorkspaceStatus,
        tools: [BackendWorkspaceTool] = [],
        location: GnosticWorkspaceLocation = .runtime,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.uri = uri
        self.status = status
        self.tools = tools
        self.location = location
        self.createdAt = createdAt
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
    /// Whether the tool reported success.
    public let isSuccess: Bool

    /// Creates a Workspace tool result.
    ///
    /// - Parameters:
    ///   - value: The structured result, when the tool returned one.
    ///   - message: A human-readable result or failure description.
    ///   - isSuccess: Whether the tool reported success.
    public init(value: ManifestJSONValue? = nil, message: String? = nil, isSuccess: Bool = true) {
        self.value = value
        self.message = message
        self.isSuccess = isSuccess
    }

    /// Creates a successful result from a message.
    ///
    /// - Parameter message: The human-readable result.
    /// - Returns: A successful result.
    public static func success(_ message: String = "") -> BackendWorkspaceResult {
        BackendWorkspaceResult(message: message)
    }

    /// Creates a failed result from a message.
    ///
    /// - Parameter message: The human-readable failure description.
    /// - Returns: A failed result.
    public static func failure(_ message: String) -> BackendWorkspaceResult {
        BackendWorkspaceResult(message: message, isSuccess: false)
    }

    /// The textual output of a successful result.
    public var output: String { value.flatMap(Self.describe) ?? message ?? "" }

    private static func describe(_ value: ManifestJSONValue) -> String? {
        guard case let .string(text) = value else { return nil }
        return text
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
    public let workspace: any AscendantBackendWorkspaceService?
    /// Permission mediation. Always present; see ``AscendantBackendServices/empty``.
    public let permission: any AscendantBackendPermissionService
    /// Backend-specific services the mandatory contract never depends on.
    public let optionalCapabilities: [any AscendantBackendOptionalCapability]

    /// Creates the construction-time services for one backend.
    public init(
        workspace: any AscendantBackendWorkspaceService? = nil,
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
    /// A Core operation required an optional surface the backend does not
    /// declare, or declares but does not implement. This is the single
    /// absent-capability outcome.
    case capabilityUnavailable(AscendantBackendCapabilities)

    /// A client-safe description of the failure.
    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(detail): detail
        case let .timelineNotFound(id): "Timeline \(id.uuidString) is not operated by this backend."
        case let .terminal(failure): failure.message
        case .cancelled: "The backend turn was cancelled."
        case let .lifecycleUnusable(failure): failure.message
        case .capabilityUnavailable: "The backend does not provide the requested optional capability."
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
        case .capabilityUnavailable: return "capabilityUnavailable"
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
        case .capabilityUnavailable: return 501
        }
    }
}

/// The configuration keys one backend kind understands.
///
/// A backend advertises this so a composition root -- notably the CLI -- can
/// list and check keys without knowing the kind at compile time. It describes
/// *which keys exist*, not what values are valid: semantic validation stays in
/// ``AscendantBackend/validateConfiguration()``.
public struct AscendantBackendSettingsSchema: Sendable, Equatable {
    /// One configuration key a backend understands.
    public struct Key: Sendable, Equatable {
        /// The key as it appears in ``AscendantBackendConfiguration/settings``
        /// or ``AscendantBackendConfiguration/secrets``.
        public let name: String
        /// A one-line description, suitable for CLI help output.
        public let summary: String
        /// Whether the value belongs in `secrets` and must be redacted.
        public let isSecret: Bool

        /// Creates one configuration key description.
        ///
        /// - Parameters:
        ///   - name: The key as stored in the backend envelope.
        ///   - summary: A one-line description for help output.
        ///   - isSecret: Whether the value belongs in `secrets`.
        public init(name: String, summary: String, isSecret: Bool = false) {
            self.name = name
            self.summary = summary
            self.isSecret = isSecret
        }
    }

    /// A family of keys whose suffix names one environment variable.
    ///
    /// A matching key is the prefix followed by an environment-variable name.
    /// The value is stored in `settings` or `secrets` according to `isSecret`.
    public struct KeyFamily: Sendable, Equatable {
        /// Prefix shared by every key in this family.
        public let prefix: String
        /// A one-line description, suitable for CLI help output.
        public let summary: String
        /// Whether values belong in `secrets` and must be redacted.
        public let isSecret: Bool

        /// Creates one dynamic environment-variable key family.
        ///
        /// - Parameters:
        ///   - prefix: The key prefix, including any delimiter (for example `env.`).
        ///   - summary: A one-line description for help output.
        ///   - isSecret: Whether values belong in `secrets`.
        public init(prefix: String, summary: String, isSecret: Bool = false) {
            self.prefix = prefix
            self.summary = summary
            self.isSecret = isSecret
        }
    }

    /// Literal keys this backend kind understands, in presentation order.
    public let keys: [Key]
    /// Dynamic environment-variable key families, in presentation order.
    public let keyFamilies: [KeyFamily]

    /// Creates a schema from ordered literal keys and dynamic key families.
    ///
    /// - Parameters:
    ///   - keys: The literal keys, in presentation order.
    ///   - keyFamilies: Dynamic environment-variable families, in presentation order.
    public init(keys: [Key] = [], keyFamilies: [KeyFamily] = []) {
        self.keys = keys
        self.keyFamilies = keyFamilies
    }

    /// A schema for a backend that advertises no keys.
    ///
    /// This is distinct from a kind that is not registered at all: the kind
    /// exists, but a caller cannot be told which keys it accepts.
    public static var unspecified: Self { .init() }

    /// Whether the backend advertises no keys.
    public var isUnspecified: Bool { keys.isEmpty && keyFamilies.isEmpty }

    /// The names of keys stored in `settings`.
    public var settingNames: [String] { keys.filter { !$0.isSecret }.map(\.name) }

    /// The names of keys stored in `secrets`.
    public var secretNames: [String] { keys.filter(\.isSecret).map(\.name) }

    /// Looks up one advertised key.
    ///
    /// - Parameter name: The key name to find.
    /// - Returns: The key, or `nil` when this kind does not advertise it.
    public func key(named name: String) -> Key? { keys.first { $0.name == name } }

    /// Prefix-matches a dynamic family and returns the suffix as its member.
    ///
    /// This method does not validate the member. Callers must validate it
    /// before accepting the dynamic key.
    ///
    /// - Parameter name: The full configuration key.
    /// - Returns: The matching family and variable name, or `nil` when no
    ///   declared prefix matches.
    public func dynamicFamily(matching name: String) -> (family: KeyFamily, member: String)? {
        guard let family = keyFamilies
            .filter({ name.hasPrefix($0.prefix) })
            .max(by: { $0.prefix.count < $1.prefix.count }) else { return nil }
        return (family, String(name.dropFirst(family.prefix.count)))
    }

    /// Whether a name is a valid environment-variable identifier.
    public static func isValidEnvironmentVariableName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard let first = bytes.first,
              (first == 95 || (65...90).contains(first) || (97...122).contains(first)) else {
            return false
        }
        return bytes.dropFirst().allSatisfy {
            $0 == 95 || (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
        }
    }
}

/// The optional surfaces one backend implements.
///
/// Each backend declares this once, on ``AscendantBackend/capabilities``.
/// Core consults the declaration before it narrows a backend to an optional
/// protocol, so an undeclared surface is refused the same way at every site.
/// The mandatory contract never depends on these members (ADR 0009).
public struct AscendantBackendCapabilities: OptionSet, Sendable, Hashable {
    /// The raw bit set.
    public let rawValue: Int

    /// Creates a capability set from raw bits.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Implements ``AscendantBackendWorkspaceCapability``: Workspace attachment,
    /// detachment, and enabled tool listing.
    public static let workspace = Self(rawValue: 1 << 0)
    /// Implements ``AscendantBackendTurnCancellation``: scoped cancellation of
    /// one identified Turn.
    public static let turnCancellation = Self(rawValue: 1 << 1)
    /// Reads and writes Workspace files through the host's
    /// ``AscendantBackendWorkspaceFileService``.
    public static let workspaceFiles = Self(rawValue: 1 << 2)
    /// Consumes the type-erased Timeline store carrier from
    /// ``AscendantBackendServices/optionalCapabilities``. Core never narrows it.
    public static let timelineStore = Self(rawValue: 1 << 3)
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
    /// The optional surfaces this backend implements. Declared once, here;
    /// ``requireCapability(_:as:)`` and ``optionalCapability(_:as:)`` read it.
    var capabilities: AscendantBackendCapabilities { get }

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
    /// Cancels all running work for backend retirement or shutdown. This is
    /// backend-wide; use ``AscendantBackendTurnCancellation`` for one Turn.
    func cancel() async
    /// Releases the backend's resources. Called once, and not concurrently with a Turn.
    func shutdown() async
}

/// Optional scoped cancellation for one identified Timeline Turn.
///
/// `cancel()` remains the backend-wide lifecycle operation. Backends that can
/// target a user-requested cancellation implement this capability instead.
@MainActor
public protocol AscendantBackendTurnCancellation: AnyObject, Sendable {
    /// Requests cancellation of the identified Turn on this Timeline.
    func cancelTurn(timelineID: UUID, clientTurnID: String) async
}

extension AscendantBackend {
    /// Narrows the backend to one optional surface it declares.
    ///
    /// Use this where the operation requires the surface. An undeclared surface,
    /// or a declared one the type does not implement, throws the same
    /// ``AscendantBackendError/capabilityUnavailable(_:)``.
    ///
    /// - Parameters:
    ///   - capability: The declared surface to require.
    ///   - type: The protocol the surface is implemented through.
    /// - Returns: The backend viewed through `type`.
    /// - Throws: ``AscendantBackendError/capabilityUnavailable(_:)``.
    @MainActor
    public func requireCapability<C>(_ capability: AscendantBackendCapabilities, as _: C.Type = C.self) throws -> C {
        guard capabilities.contains(capability), let narrowed = self as? C else {
            throw AscendantBackendError.capabilityUnavailable(capability)
        }
        return narrowed
    }

    /// Looks up an optional surface where absence is a deliberate no-op.
    ///
    /// Use this only where a backend without the surface is expected and the
    /// caller's result does not depend on it, such as best-effort cancellation.
    ///
    /// - Parameters:
    ///   - capability: The declared surface to look for.
    ///   - type: The protocol the surface is implemented through.
    /// - Returns: The backend viewed through `type`, or `nil` when undeclared.
    @MainActor
    public func optionalCapability<C>(_ capability: AscendantBackendCapabilities, as _: C.Type = C.self) -> C? {
        guard capabilities.contains(capability) else { return nil }
        return self as? C
    }
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
