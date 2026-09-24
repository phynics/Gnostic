// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKContracts

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
    /// The Gnostic-owned effective usability of this listing.
    public let status: GnosticWorkspaceEffectiveStatus

    /// Compatibility alias for clients that only consume attachable entries.
    public var isAvailable: Bool { status == .available }

    /// Explicit name for the effective status projection.
    public var effectiveStatus: GnosticWorkspaceEffectiveStatus { status }

    public init(id: UUID, name: String, status: GnosticWorkspaceEffectiveStatus = .available, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.id = id
        self.name = GnosticWirePayload.boundedLabel(name)
        self.status = status
    }

    public init(id: UUID, name: String, isAvailable: Bool, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.init(id: id, name: name, status: isAvailable ? .available : .unavailable, protocolMajor: protocolMajor)
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, id, name, isAvailable, status }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        id = try container.decode(UUID.self, forKey: .id)
        name = GnosticWirePayload.boundedLabel(try container.decode(String.self, forKey: .name))
        if let status = try container.decodeIfPresent(GnosticWorkspaceEffectiveStatus.self, forKey: .status) {
            self.status = status
        } else {
            self.status = (try container.decode(Bool.self, forKey: .isAvailable)) ? .available : .unavailable
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolMajor, forKey: .protocolMajor)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isAvailable, forKey: .isAvailable)
        try container.encode(status, forKey: .status)
    }
}

/// The wire result of `workspace.list`.
public struct WorkspaceListResult: Codable, Sendable {
    public let protocolMajor: Int
    public let workspaces: [WorkspaceListing]
    /// The absolute offset for the next page, or `nil` when this result is complete.
    public let nextOffset: Int?

    /// Creates a workspace-list result.
    ///
    /// - Parameters:
    ///   - workspaces: The entries returned in this page.
    ///   - nextOffset: The absolute offset of the next page, or `nil` when all entries were returned.
    ///   - protocolMajor: The protocol major carried by this result.
    public init(workspaces: [WorkspaceListing], nextOffset: Int? = nil, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.workspaces = workspaces
        self.nextOffset = nextOffset
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, workspaces, nextOffset }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        workspaces = try container.decode([WorkspaceListing].self, forKey: .workspaces)
        nextOffset = try container.decodeIfPresent(Int.self, forKey: .nextOffset)
    }
}

/// The protocol-bearing request for `workspace.list`.
///
/// Use this request for paginated results. Legacy ``WorkspaceOpsRequest``
/// callers remain supported only when the complete result fits in one response.
public struct WorkspaceListRequest: Codable, Sendable {
    public let protocolMajor: Int
    /// The zero-based absolute position of the first entry to return.
    public let offset: Int
    /// The maximum number of entries to request for this page.
    public let limit: Int

    /// Creates a paginated workspace-list request.
    ///
    /// - Parameters:
    ///   - offset: The zero-based absolute position of the first entry.
    ///   - limit: The maximum number of entries to request.
    ///   - protocolMajor: The protocol major carried by this request.
    public init(offset: Int = 0, limit: Int = GnosticWirePayload.maximumListItems, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.offset = offset
        self.limit = limit
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, offset, limit }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        offset = try container.decodeIfPresent(Int.self, forKey: .offset) ?? 0
        limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? GnosticWirePayload.maximumListItems
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
        guard [Self.listOperation, Self.attachOperation, Self.detachOperation].contains(operation) else {
            return .failure(code: 404, reasonCode: "unknownWorkspaceOperation", message: "Unknown workspace operation")
        }
        if let failure = GnosticCallHandling.protocolFailure(
            parameters,
            invalidReasonCode: "invalidWorkspacePayload",
            invalidMessage: "Invalid workspace payload"
        ) {
            return failure
        }
        switch operation {
        case Self.listOperation:
            guard let request = decodeList(parameters) else {
                return .failure(code: 400, reasonCode: "invalidWorkspaceListPayload", message: "Invalid workspace.list payload")
            }
            return try await run {
                let listings = try await list()
                try listings.forEach { try GnosticProtocol.validate($0.protocolMajor) }
                switch request {
                case .legacy:
                    // A legacy client has no way to consume nextOffset. Return
                    // the complete result when it fits; otherwise require the
                    // explicit paginated request instead of silently truncating.
                    guard let result = try? CallHandlerResult.encoded(
                        WorkspaceListResult(workspaces: listings),
                        context: "workspace.list result"
                    ) else {
                        return .failure(
                            code: 400,
                            reasonCode: "paginationRequired",
                            message: "workspace.list requires WorkspaceListRequest pagination"
                        )
                    }
                    return result
                case let .paged(request):
                    guard request.offset >= 0, request.limit > 0 else {
                        return .failure(code: 400, reasonCode: "invalidWorkspaceListPayload", message: "Invalid workspace.list payload")
                    }
                    let page = GnosticCallHandling.boundedPage(
                        listings,
                        offset: request.offset,
                        limit: request.limit,
                        context: "workspace.list result"
                    ) { WorkspaceListResult(workspaces: $0, nextOffset: $1) }
                    return try .encoded(
                        WorkspaceListResult(workspaces: page.items, nextOffset: page.nextOffset),
                        context: "workspace.list result"
                    )
                }
            }
        case Self.attachOperation:
            return try await mutate(parameters, using: attach, invalidReasonCode: "invalidWorkspaceAttachPayload", invalidMessage: "Invalid workspace.attach payload")
        default:
            return try await mutate(parameters, using: detach, invalidReasonCode: "invalidWorkspaceDetachPayload", invalidMessage: "Invalid workspace.detach payload")
        }
    }

    private func mutate(
        _ parameters: String?,
        using execute: MutateExecutor,
        invalidReasonCode: String,
        invalidMessage: String
    ) async throws -> CallHandlerResult {
        guard let request = GnosticCallHandling.decode(WorkspaceOpsRequest.self, from: parameters) else {
            return .failure(code: 400, reasonCode: invalidReasonCode, message: invalidMessage)
        }
        return try await run {
            let accepted = try await execute(request)
            return .success(result: String(decoding: try JSONEncoder().encode(WorkspaceMutationResult(accepted: accepted)), as: UTF8.self))
        }
    }

    private func run(_ body: () async throws -> CallHandlerResult) async throws -> CallHandlerResult {
        try await GnosticCallHandling.run(
            fallbackReasonCode: "workspaceOperationFailed",
            fallbackMessage: "The workspace operation failed.",
            body
        )
    }

    private enum ListRequest: Sendable {
        case legacy
        case paged(WorkspaceListRequest)
    }

    private func decodeList(_ parameters: String?) -> ListRequest? {
        guard let parameters,
              let data = parameters.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if object["offset"] != nil || object["limit"] != nil {
            guard let request = try? JSONDecoder().decode(WorkspaceListRequest.self, from: data) else { return nil }
            return .paged(request)
        }
        guard (try? JSONDecoder().decode(WorkspaceOpsRequest.self, from: data)) != nil else { return nil }
        return .legacy
    }

    @MainActor
    public func register(on communication: CommunicationManager, context: CoatyObject? = nil) async throws -> [CallHandlerRegistration] {
        try await GnosticCallHandling.register(
            operations: [Self.listOperation, Self.attachOperation, Self.detachOperation],
            on: communication,
            context: context
        ) { [self] operation, parameters in
            try await handle(operation: operation, parameters: parameters)
        }
    }
}
