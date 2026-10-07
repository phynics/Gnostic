// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticProtocol

/// The wire payload for Gnostic's generic remote workspace invocation.
public struct WorkspaceInvocation: Codable, Sendable {
    public let protocolMajor: Int
    /// The stable identifier of the advertised workspace.
    public let workspaceID: UUID

    /// The catalog provider identity selected for this invocation.
    public let providerID: String?

    /// The advertised custom tool identifier.
    public let toolID: String

    /// The tool arguments supplied by the caller.
    public let arguments: [String: ManifestJSONValue]

    /// Creates an invocation payload.
    public init(workspaceID: UUID, providerID: String? = nil, toolID: String, arguments: [String: ManifestJSONValue] = [:], protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.workspaceID = workspaceID
        self.providerID = providerID
        self.toolID = toolID
        self.arguments = arguments
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, workspaceID, providerID, toolID, arguments }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        workspaceID = try container.decode(UUID.self, forKey: .workspaceID)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        toolID = try container.decode(String.self, forKey: .toolID)
        arguments = try container.decode([String: ManifestJSONValue].self, forKey: .arguments)
    }
}

/// Hosts arbitrary custom workspace tools over Gnostic's unary Call/Return operation.
public actor GnosticWorkspaceProvider {
    /// The single operation used for all workspace tool invocations.
    public static let invocationOperation = GnosticWorkspaceProtocol.invocationOperation
    public static let toolObjectType = GnosticObjectType.workspaceTool

    /// Executes one advertised tool.
    public typealias ToolExecutor = @Sendable (_ toolID: String, _ arguments: [String: ManifestJSONValue]) async throws -> BackendWorkspaceResult

    private let workspaceID: UUID
    private let definitions: [String: GnosticWorkspaceToolDefinition]
    private let executor: ToolExecutor

    /// Creates a provider for a workspace's advertised custom tools.
    public init(workspaceID: UUID, tools: [GnosticWorkspaceToolDefinition], execute: @escaping ToolExecutor) {
        self.workspaceID = workspaceID
        definitions = Dictionary(uniqueKeysWithValues: tools.map { ($0.id, $0) })
        executor = execute
    }

    /// Returns the exact custom tools currently advertised by this provider.
    public func listTools() -> [GnosticWorkspaceTool] {
        definitions.values.sorted { $0.id < $1.id }.map(GnosticWorkspaceTool.init)
    }

    /// Responds to a bounded page of public Workspace tool objects. Tool
    /// objects are queryable but are deliberately never advertised. A page at
    /// or past the end of the catalog gets an explicit empty answer, which is
    /// the terminal signal for `GnosticSubscription.queryTools`.
    public func query(_ request: QueryResponderRequest) throws {
        guard request.snapshot.objectTypes?.contains(Self.toolObjectType) == true else { return }
        guard let filter = request.snapshot.objectFilter,
              filter.lowercased().contains(workspaceID.uuidString.lowercased()) else { return }
        let page: Int = GnosticWorkspaceToolQuery.value(Int.self, key: "page", in: request.snapshot.objectFilter) ?? 0
        guard page >= 0 else { return }
        let definitions = definitions.values.sorted { $0.id < $1.id }
        guard let definition = definitions.dropFirst(page).first else { return try request.retrieve(objects: []) }
        try request.retrieve(object: GnosticWorkspaceToolObject(workspaceID: workspaceID, definition: definition, page: page))
    }

    /// Dispatches a decoded invocation only when it addresses this workspace and an advertised tool.
    public func invoke(_ invocation: WorkspaceInvocation) async throws -> BackendWorkspaceResult {
        guard invocation.workspaceID == workspaceID else { throw WorkspaceServiceError.workspaceNotFound }
        guard definitions[invocation.toolID] != nil else { throw WorkspaceServiceError.toolExecutionNotSupported }
        return try await executor(invocation.toolID, invocation.arguments)
    }

    /// Decodes a generic Call payload and returns the serialized tool result.
    public func handle(parameters: String?) async throws -> CallHandlerResult {
        do {
            try GnosticProtocol.validatePayload(parameters)
            guard let parameters else { throw WorkspaceServiceError.toolExecutionNotSupported }
            let invocation = try JSONDecoder().decode(WorkspaceInvocation.self, from: Data(parameters.utf8))
            let result = try await invoke(invocation)
            return .success(result: try Self.encodeResult(result))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Self.invocationFailure(error)
        }
    }

    /// Maps an invocation failure: an undecodable invocation is a 400, and
    /// any other failure keeps its bounded public form.
    static func invocationFailure(_ error: Error) -> CallHandlerResult {
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

    /// Encodes a tool result with the protocol major within the event budget.
    ///
    /// The wire shape mirrors the released PositronicKit `ToolResult` payload,
    /// including its `isSuccess`, `output`, and `error` keys, so a released
    /// consumer decodes it unchanged. The kernel builds it from its neutral
    /// ``BackendWorkspaceResult``.
    static func encodeResult(_ result: BackendWorkspaceResult) throws -> String {
        var object: [String: Any] = [
            "isSuccess": result.isSuccess,
            "output": result.isSuccess ? result.output : "",
        ]
        if !result.isSuccess {
            object["error"] = result.message ?? ""
        }
        object["protocolMajor"] = GnosticProtocol.currentMajor
        let encoded = try JSONSerialization.data(withJSONObject: object)
        try GnosticWirePayload.validateEvent(encoded, context: "workspace.invoke result")
        return String(decoding: encoded, as: UTF8.self)
    }

    /// Registers this provider with Axoloty's released unary Call handler.
    @MainActor
    public func register(on communication: CommunicationManager) async throws -> CallHandlerRegistration {
        try await communication.registerCallHandler(operation: Self.invocationOperation, context: communication.identity) { [self] request in
            try await handle(parameters: request.parameters)
        }
    }

    @MainActor
    public func registerQuery(on communication: CommunicationManager) async -> QueryResponderRegistration {
        await communication.registerQueryResponder { [self] request in
            try await self.query(request)
        }
    }
}
