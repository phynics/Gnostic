// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared

/// The wire payload for a workspace attach/detach request.
public struct WorkspaceOpsRequest: Codable, Sendable {
    public let workspaceID: UUID
    public let timelineID: UUID

    public init(workspaceID: UUID, timelineID: UUID) {
        self.workspaceID = workspaceID
        self.timelineID = timelineID
    }
}

/// A workspace the serve side can attach.
public struct WorkspaceListing: Codable, Sendable {
    public let id: UUID
    public let name: String
    public let isAvailable: Bool

    public init(id: UUID, name: String, isAvailable: Bool = true) {
        self.id = id
        self.name = name
        self.isAvailable = isAvailable
    }
}

/// The wire result of `workspace.list`.
public struct WorkspaceListResult: Codable, Sendable {
    public let workspaces: [WorkspaceListing]

    public init(workspaces: [WorkspaceListing]) {
        self.workspaces = workspaces
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
            let listings = try await list()
            let encoded = try JSONEncoder().encode(WorkspaceListResult(workspaces: listings))
            return .success(result: String(decoding: encoded, as: UTF8.self))
        case Self.attachOperation:
            guard let request = decode(parameters) else {
                return .failure(code: 400, message: "Invalid workspace.attach payload")
            }
            let ok = try await attach(request)
            return .success(result: ok ? "true" : "false")
        case Self.detachOperation:
            guard let request = decode(parameters) else {
                return .failure(code: 400, message: "Invalid workspace.detach payload")
            }
            let ok = try await detach(request)
            return .success(result: ok ? "true" : "false")
        default:
            return .failure(code: 404, message: "Unknown workspace operation")
        }
    }

    private func decode(_ parameters: String?) -> WorkspaceOpsRequest? {
        guard let parameters,
              let data = parameters.data(using: .utf8),
              let request = try? JSONDecoder().decode(WorkspaceOpsRequest.self, from: data) else { return nil }
        return request
    }

    @MainActor
    public func register(on communication: CommunicationManager) async throws -> [CallHandlerRegistration] {
        var registrations: [CallHandlerRegistration] = []
        do {
            for operation in [Self.listOperation, Self.attachOperation, Self.detachOperation] {
                let op = operation
                registrations.append(try await communication.registerCallHandler(operation: op) { [self] request in
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
