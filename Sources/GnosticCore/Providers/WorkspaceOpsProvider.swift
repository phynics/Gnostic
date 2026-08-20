// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared

/// The wire payload for a workspace attach/detach request.
public struct WorkspaceOpsRequest: Codable, Sendable {
    public let protocolMajor: Int
    public let workspaceID: UUID
    public let timelineID: UUID

    public init(workspaceID: UUID, timelineID: UUID, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.workspaceID = workspaceID
        self.timelineID = timelineID
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, workspaceID, timelineID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        workspaceID = try container.decode(UUID.self, forKey: .workspaceID)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
    }
}

/// A workspace the serve side can attach.
public struct WorkspaceListing: Codable, Sendable {
    public let protocolMajor: Int
    public let id: UUID
    public let name: String
    public let isAvailable: Bool

    public init(id: UUID, name: String, isAvailable: Bool = true, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.id = id
        self.name = name
        self.isAvailable = isAvailable
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, id, name, isAvailable }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isAvailable = try container.decode(Bool.self, forKey: .isAvailable)
    }
}

/// The wire result of `workspace.list`.
public struct WorkspaceListResult: Codable, Sendable {
    public let protocolMajor: Int
    public let workspaces: [WorkspaceListing]

    public init(workspaces: [WorkspaceListing], protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.workspaces = workspaces
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, workspaces }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        workspaces = try container.decode([WorkspaceListing].self, forKey: .workspaces)
    }
}

/// The protocol-bearing result of a workspace mutation.
public struct WorkspaceMutationResult: Codable, Sendable {
    public let protocolMajor: Int
    public let accepted: Bool

    public init(accepted: Bool, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.accepted = accepted
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, accepted }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        accepted = try container.decode(Bool.self, forKey: .accepted)
    }
}

/// Hosts the workspace management unary operations.
///
/// Thin wire adapters for three operations: `workspace.list`, `workspace.attach`,
/// and `workspace.detach`. The closures are injected by the serve runtime, which
/// owns the real attachment service and timeline manager.
public struct WorkspaceOpsProvider: Sendable {
    public static let listOperation = "me.atkn.gnostic.workspace.list"
    public static let attachOperation = "me.atkn.gnostic.workspace.attach"
    public static let detachOperation = "me.atkn.gnostic.workspace.detach"

    public typealias ListExecutor = @Sendable () async throws -> [WorkspaceListing]
    public typealias MutateExecutor = @Sendable (WorkspaceOpsRequest) async throws -> Bool

    private let list: ListExecutor
    private let attach: MutateExecutor
    private let detach: MutateExecutor

    public init(list: @escaping ListExecutor, attach: @escaping MutateExecutor, detach: @escaping MutateExecutor) {
        self.list = list
        self.attach = attach
        self.detach = detach
    }

    public func handle(operation: String, parameters: String?) async throws -> CallHandlerResult {
        switch operation {
        case Self.listOperation:
            if let error = protocolError(parameters) { return error }
            do {
                let listings = try await list()
                try listings.forEach { try GnosticProtocol.validate($0.protocolMajor) }
                let encoded = try JSONEncoder().encode(WorkspaceListResult(workspaces: listings))
                return .success(result: String(decoding: encoded, as: UTF8.self))
            } catch {
                return failure(for: error)
            }
        case Self.attachOperation:
            if let error = protocolError(parameters) { return error }
            guard let request = decode(parameters) else {
                return failure(code: 400, reasonCode: "invalidWorkspaceAttachPayload", message: "Invalid workspace.attach payload")
            }
            do {
                let ok = try await attach(request)
                return .success(result: String(decoding: try JSONEncoder().encode(WorkspaceMutationResult(accepted: ok)), as: UTF8.self))
            } catch {
                return failure(for: error)
            }
        case Self.detachOperation:
            if let error = protocolError(parameters) { return error }
            guard let request = decode(parameters) else {
                return failure(code: 400, reasonCode: "invalidWorkspaceDetachPayload", message: "Invalid workspace.detach payload")
            }
            do {
                let ok = try await detach(request)
                return .success(result: String(decoding: try JSONEncoder().encode(WorkspaceMutationResult(accepted: ok)), as: UTF8.self))
            } catch {
                return failure(for: error)
            }
        default:
            return failure(code: 404, reasonCode: "unknownWorkspaceOperation", message: "Unknown workspace operation")
        }
    }

    private func decode(_ parameters: String?) -> WorkspaceOpsRequest? {
        guard let parameters,
              let data = parameters.data(using: .utf8),
              let request = try? JSONDecoder().decode(WorkspaceOpsRequest.self, from: data) else { return nil }
        return request
    }

    private func protocolError(_ parameters: String?) -> CallHandlerResult? {
        do {
            try GnosticProtocol.validatePayload(parameters)
            return nil
        } catch let error as GnosticProtocolError {
            return .failure(code: error.statusCode, message: error.failureMessage)
        } catch {
            return failure(code: 400, reasonCode: "invalidWorkspacePayload", message: "Invalid workspace payload")
        }
    }

    private func failure(for error: Error) -> CallHandlerResult {
        if let error = error as? GnosticProtocolError {
            return .failure(code: error.statusCode, message: error.failureMessage)
        }
        if let error = error as? NodeRuntimeError {
            return failure(code: error.statusCode, reasonCode: error.reasonCode, message: error.localizedDescription)
        }
        if let error = error as? DiscoveredWorkspaceAttachmentError {
            switch error {
            case .approvalRequired:
                return failure(code: 403, reasonCode: "approvalRequired", message: "Workspace attachment requires approval.")
            case let .unavailable(status):
                return failure(code: 409, reasonCode: "workspaceUnavailable", message: "Workspace is not uniquely available (\(status)).")
            case .invalidURI:
                return failure(code: 422, reasonCode: "invalidWorkspaceURI", message: "Workspace advertised an invalid URI.")
            case let .timelineNotOwned(id):
                return failure(code: 404, reasonCode: "timelineNotOwned", message: "Timeline \(id.uuidString.lowercased()) is not owned by this Node.")
            }
        }
        return failure(code: 500, reasonCode: "workspaceOperationFailed", message: String(describing: error))
    }

    private func failure(code: Int, reasonCode: String, message: String) -> CallHandlerResult {
        .failure(code: code, message: GnosticProtocol.failureMessage(reasonCode: reasonCode, message: message))
    }

    @MainActor
    public func register(on communication: CommunicationManager, context: CoatyObject? = nil) async throws -> [CallHandlerRegistration] {
        var registrations: [CallHandlerRegistration] = []
        do {
            for operation in [Self.listOperation, Self.attachOperation, Self.detachOperation] {
                let op = operation
                registrations.append(try await communication.registerCallHandler(operation: op, context: context) { [self] request in
                    try await handle(operation: op, parameters: request.parameters)
                })
            }
        } catch {
            registrations.forEach { $0.cancel() }
            throw error
        }
        return registrations
    }
}
