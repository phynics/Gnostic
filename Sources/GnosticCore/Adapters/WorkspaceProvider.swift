// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKContracts
import PositronicKit

/// Constructs and reads the standard Axoloty object-filter form used by the
/// query-only Workspace tool catalog.
enum GnosticWorkspaceToolQuery {
    static func filter(workspaceID: UUID, page: Int) -> [String: Any] {
        [
            "conditions": [
                "and": [
                    ["workspaceID", [7, workspaceID.uuidString.lowercased()]],
                    ["page", [7, page]],
                ],
            ],
        ]
    }

    static func value<T>(_ type: T.Type, key: String, in raw: String?) -> T? {
        guard let raw, let data = raw.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return find(type, key: key, in: root)
    }

    private static func find<T>(_ type: T.Type, key: String, in value: Any) -> T? {
        if let condition = value as? [Any], condition.count == 2,
           let property = condition[0] as? String, property == key,
           let expression = condition[1] as? [Any], expression.count == 2,
           let equals = expression[0] as? Int, equals == 7 {
            return expression[1] as? T
        }
        if let object = value as? [String: Any] {
            for child in object.values {
                if let result: T = find(type, key: key, in: child) { return result }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let result: T = find(type, key: key, in: child) { return result }
            }
        }
        return nil
    }
}

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
    public let arguments: [String: AnyCodable]

    /// Creates an invocation payload.
    public init(workspaceID: UUID, providerID: String? = nil, toolID: String, arguments: [String: AnyCodable], protocolMajor: Int = GnosticProtocol.currentMajor) {
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
        arguments = try container.decode([String: AnyCodable].self, forKey: .arguments)
    }
}

/// Hosts arbitrary custom workspace tools over Gnostic's unary Call/Return operation.
public actor GnosticWorkspaceProvider {
    /// The single operation used for all workspace tool invocations.
    public static let invocationOperation = "me.atkn.gnostic.workspace.invoke"
    public static let toolObjectType = GnosticObjectType.workspaceTool

    /// Executes one advertised tool.
    public typealias ToolExecutor = @Sendable (_ toolID: String, _ arguments: [String: AnyCodable]) async throws -> ToolResult

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
    /// objects are queryable but are deliberately never advertised.
    public func query(_ request: QueryResponderRequest) throws {
        guard request.snapshot.objectTypes?.contains(Self.toolObjectType) == true else { return }
        guard let filter = request.snapshot.objectFilter,
              filter.lowercased().contains(workspaceID.uuidString.lowercased()) else { return }
        let page: Int = GnosticWorkspaceToolQuery.value(Int.self, key: "page", in: request.snapshot.objectFilter) ?? 0
        guard page >= 0 else { return }
        let definitions = definitions.values.sorted { $0.id < $1.id }
        guard let definition = definitions.dropFirst(page).first else { return }
        try request.retrieve(object: GnosticWorkspaceToolObject(workspaceID: workspaceID, definition: definition, page: page))
    }

    /// Dispatches a decoded invocation only when it addresses this workspace and an advertised tool.
    public func invoke(_ invocation: WorkspaceInvocation) async throws -> ToolResult {
        guard invocation.workspaceID == workspaceID else { throw WorkspaceError.workspaceNotFound }
        guard definitions[invocation.toolID] != nil else { throw WorkspaceError.toolExecutionNotSupported }
        return try await executor(invocation.toolID, invocation.arguments)
    }

    /// Decodes a generic Call payload and returns the serialized tool result.
    public func handle(parameters: String?) async throws -> CallHandlerResult {
        do {
            try GnosticProtocol.validatePayload(parameters)
            guard let parameters else { throw WorkspaceError.toolExecutionNotSupported }
            let invocation = try JSONDecoder().decode(WorkspaceInvocation.self, from: Data(parameters.utf8))
            let result = try await invoke(invocation)
            return .success(result: try Self.encodeResult(result))
        } catch let error as GnosticProtocolError {
            return .failure(code: error.statusCode, message: error.failureMessage)
        } catch let error as DecodingError {
            return failure(code: 400, reasonCode: "invalidWorkspaceInvocationPayload", message: String(describing: error))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return failure(code: 500, reasonCode: "workspaceInvocationFailed", message: String(describing: error))
        }
    }

    private static func encodeResult(_ result: ToolResult) throws -> String {
        let data = try GnosticWirePayload.encode(result, context: "workspace.invoke result")
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        object["protocolMajor"] = GnosticProtocol.currentMajor
        let encoded = try JSONSerialization.data(withJSONObject: object)
        try GnosticWirePayload.validateEvent(encoded, context: "workspace.invoke result")
        return String(decoding: encoded, as: UTF8.self)
    }

    private func failure(code: Int, reasonCode: String, message: String) -> CallHandlerResult {
        .failure(code: code, message: GnosticProtocol.failureMessage(reasonCode: reasonCode, message: message))
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
