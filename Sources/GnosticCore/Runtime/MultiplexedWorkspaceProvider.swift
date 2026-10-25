// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticProtocol

/// One unary Axoloty handler serving every local Workspace by workspace ID.
///
/// This is transport infrastructure: its registration and cancellation belong
/// to ``NodeTransport`` rather than the node composition root. Workspaces are
/// opaque ``LocalWorkspace`` capabilities, so the handler never sees a
/// provider-native value.
public actor MultiplexedWorkspaceProvider {
    public static let invocationOperation = GnosticWorkspaceProtocol.invocationOperation

    private let workspaces: [UUID: any LocalWorkspace]
    private let workspaceStatus: @Sendable (UUID) async -> NodeRegistry.WorkspaceEffectiveStatus?
    private let setWorkspaceStatus: @Sendable (UUID, NodeRegistry.WorkspaceEffectiveStatus) async -> Bool
    private let callerBoundAuthorization: @Sendable (String?, UUID?, UUID) async -> Bool
    private let isAvailable: @Sendable () async -> Bool

    /// Creates the handler with the host's authoritative Workspace status lookup.
    /// A missing status rejects invocation, just like an unavailable Workspace.
    public init(
        workspaces: [UUID: any LocalWorkspace],
        workspaceStatus: @escaping @Sendable (UUID) async -> NodeRegistry.WorkspaceEffectiveStatus?,
        isAttached: @escaping @Sendable (UUID?, UUID) async -> Bool = { _, _ in false },
        isAvailable: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.workspaces = workspaces
        self.workspaceStatus = workspaceStatus
        setWorkspaceStatus = { _, _ in false }
        callerBoundAuthorization = { _, timelineID, workspaceID in
            await isAttached(timelineID, workspaceID)
        }
        self.isAvailable = isAvailable
    }

    init(
        workspaces: [UUID: any LocalWorkspace],
        workspaceStatus: @escaping @Sendable (UUID) async -> NodeRegistry.WorkspaceEffectiveStatus?,
        setWorkspaceStatus: @escaping @Sendable (UUID, NodeRegistry.WorkspaceEffectiveStatus) async -> Bool,
        callerBoundAuthorization: @escaping @Sendable (String?, UUID?, UUID) async -> Bool,
        isAvailable: @escaping @Sendable () async -> Bool
    ) {
        self.workspaces = workspaces
        self.workspaceStatus = workspaceStatus
        self.setWorkspaceStatus = setWorkspaceStatus
        self.callerBoundAuthorization = callerBoundAuthorization
        self.isAvailable = isAvailable
    }

    public func handle(parameters: String?, expectedProviderID: String? = nil) async throws -> CallHandlerResult {
        try await handle(parameters: parameters, expectedProviderID: expectedProviderID, callerSourceID: nil)
    }

    private func handle(parameters: String?, expectedProviderID: String?, callerSourceID: String?) async throws -> CallHandlerResult {
        do {
            guard await isAvailable() else { throw NodeRuntimeError.notRunning }
            try GnosticProtocol.validatePayload(parameters)
            guard let parameters else { throw WorkspaceServiceError.toolExecutionNotSupported }
            let invocation = try JSONDecoder().decode(WorkspaceInvocation.self, from: Data(parameters.utf8))
            if let expectedProviderID, let providerID = invocation.providerID,
               providerID.lowercased() != expectedProviderID.lowercased() {
                throw WorkspaceServiceError.connectionFailed
            }
            guard let workspace = workspaces[invocation.workspaceID] else {
                throw WorkspaceServiceError.workspaceNotFound
            }
            guard await callerBoundAuthorization(callerSourceID, invocation.timelineID, invocation.workspaceID) else {
                return .failure(code: 403, reasonCode: "workspaceNotAttached", message: "The Workspace is not attached to the active Timeline.")
            }
            try await requireAvailable(workspaceID: invocation.workspaceID)
            let tools = try await workspace.listTools()
            guard let tool = tools.first(where: { $0.id == invocation.toolID }) else {
                return .failure(code: 403, reasonCode: "workspaceToolNotAdvertised", message: "The Workspace does not advertise this tool.")
            }
            guard !tool.requiresPermission || invocation.permissionApproved else {
                return .failure(code: 403, reasonCode: "workspacePermissionRequired", message: "The Workspace tool requires an approved permission decision.")
            }
            guard await callerBoundAuthorization(callerSourceID, invocation.timelineID, invocation.workspaceID) else {
                return .failure(code: 403, reasonCode: "workspaceNotAttached", message: "The Workspace is not attached to the active Timeline.")
            }
            // This final registry snapshot is the admission guard. It follows
            // the last owner-bound caller check and there is no suspension
            // between it and entering provider execution. Later revocation is
            // not retroactive cancellation of an admitted provider call.
            try await requireAvailable(workspaceID: invocation.workspaceID)
            try Task.checkCancellation()
            let result = try await workspace.executeTool(id: invocation.toolID, parameters: invocation.arguments)
            return .success(result: try Self.encodeResult(result))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Self.invocationFailure(error)
        }
    }

    private func requireAvailable(workspaceID: UUID) async throws {
        guard await isAvailable() else { throw NodeRuntimeError.notRunning }
        if let workspace = workspaces[workspaceID],
           let healthy = await MainActor.run(body: { (workspace as? any LocalWorkspaceHealth)?.isHealthy }),
           !healthy, await workspaceStatus(workspaceID) == .available {
            // Persist an owner-local health revocation in the authoritative registry.
            guard await setWorkspaceStatus(workspaceID, .unavailable) else {
                throw DiscoveredWorkspaceAttachmentError.unavailable(.unavailable)
            }
        }
        // Re-read after health and registry awaits so a revocation during
        // either suspension is included in the admission decision.
        let status = await workspaceStatus(workspaceID)
        guard status == .available else {
            throw DiscoveredWorkspaceAttachmentError.unavailable(status == .unsupported ? .unsupported : .unavailable)
        }
    }

    /// Responds with one public tool object per query page. The page size is
    /// intentionally one because a tool schema is dynamic and cannot be
    /// safely combined with another schema under the wire budget. A page at or
    /// past the end of an owned Workspace's catalog gets an explicit empty
    /// answer so the querier stops without waiting for its timeout.
    public func handleQuery(_ request: QueryResponderRequest) async throws {
        guard let objects = try await queryObjects(request.snapshot) else { return }
        try request.retrieve(objects: objects)
    }

    /// A nil result means this handler does not own the query; an empty result
    /// is the terminal page of an owned Workspace's tool catalog.
    func queryObjects(_ snapshot: QueryEventSnapshot) async throws -> [GnosticWorkspaceToolObject]? {
        guard await isAvailable(), snapshot.objectTypes?.contains(GnosticObjectType.workspaceTool) == true else { return nil }
        guard let filter = snapshot.objectFilter,
              let workspaceIDString: String = GnosticWorkspaceToolQuery.value(String.self, key: "workspaceID", in: filter),
              let workspaceID = UUID(uuidString: workspaceIDString),
              filter.lowercased().contains(workspaceID.uuidString.lowercased()),
              let workspace = workspaces[workspaceID] else { return nil }
        let rawPage: Any? = GnosticWorkspaceToolQuery.value(Any.self, key: "page", in: filter)
        guard rawPage == nil || rawPage is Int else { return nil }
        let page = rawPage as? Int ?? 0
        guard page >= 0 else { return nil }
        let definitions = try await workspace.listTools()
            .map(Self.definition(from:))
            .sorted { $0.id < $1.id }
        guard let definition = definitions.dropFirst(page).first else { return [] }
        return [GnosticWorkspaceToolObject(workspaceID: workspaceID, definition: definition, page: page)]
    }

    @MainActor
    public func register(on communication: CommunicationManager) async throws -> CallHandlerRegistration {
        let providerID = communication.identity.objectId.string
        return try await communication.registerCallHandler(operation: Self.invocationOperation, context: communication.identity) { [self] request in
            try await handle(parameters: request.parameters, expectedProviderID: providerID, callerSourceID: request.sourceId)
        }
    }

    @MainActor
    public func registerQuery(on communication: CommunicationManager) async -> QueryResponderRegistration {
        await communication.registerQueryResponder { [self] request in
            try await self.handleQuery(request)
        }
    }

    private static func definition(from tool: BackendWorkspaceTool) -> GnosticWorkspaceToolDefinition {
        let parameters: [String: ManifestJSONValue]
        if case let .object(values)? = tool.parametersSchema {
            parameters = values
        } else {
            parameters = [:]
        }
        return GnosticWorkspaceToolDefinition(
            id: tool.id,
            name: tool.name,
            description: tool.description,
            parametersSchema: parameters,
            requiresPermission: tool.requiresPermission
        )
    }

    private static func invocationFailure(_ error: Error) -> CallHandlerResult {
        if error is DecodingError {
            return .failure(code: 400, reasonCode: "invalidWorkspaceInvocationPayload", message: "Invalid workspace invocation payload")
        }
        return .failure(GnosticProtocol.publicFailure(
            for: error,
            fallbackCode: 500,
            fallbackReasonCode: "workspaceInvocationFailed",
            fallbackMessage: "The workspace invocation failed."
        ))
    }

    /// Keeps the released tool-result wire shape and its event payload budget.
    private static func encodeResult(_ result: BackendWorkspaceResult) throws -> String {
        var object: [String: Any] = [
            "isSuccess": result.isSuccess,
            "output": result.isSuccess ? result.output : "",
        ]
        if !result.isSuccess { object["error"] = result.message ?? "" }
        object["protocolMajor"] = GnosticProtocol.currentMajor
        let encoded = try JSONSerialization.data(withJSONObject: object)
        try GnosticWirePayload.validateEvent(encoded, context: "workspace.invoke result")
        return String(decoding: encoded, as: UTF8.self)
    }
}
