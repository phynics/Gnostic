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
        switch operation {
        case Self.listOperation:
            if let error = protocolError(parameters) { return error }
            guard let request = decodeList(parameters) else {
                return failure(code: 400, reasonCode: "invalidWorkspaceListPayload", message: "Invalid workspace.list payload")
            }
            do {
                let listings = try await list()
                try listings.forEach { try GnosticProtocol.validate($0.protocolMajor) }
                switch request {
                case .legacy:
                    // A legacy client has no way to consume nextOffset. Return
                    // the complete result when it fits; otherwise require the
                    // explicit paginated request instead of silently truncating.
                    guard let encoded = try? GnosticWirePayload.encode(
                        WorkspaceListResult(workspaces: listings),
                        context: "workspace.list result"
                    ) else {
                        return failure(
                            code: 400,
                            reasonCode: "paginationRequired",
                            message: "workspace.list requires WorkspaceListRequest pagination"
                        )
                    }
                    return .success(result: String(decoding: encoded, as: UTF8.self))
                case let .paged(request):
                    guard request.offset >= 0, request.limit > 0 else {
                        return failure(code: 400, reasonCode: "invalidWorkspaceListPayload", message: "Invalid workspace.list payload")
                    }
                    let pageLimit = min(request.limit, GnosticWirePayload.maximumListItems)
                    let page = boundedPage(listings, offset: request.offset, limit: pageLimit)
                    let nextOffset = request.offset + page.count < listings.count ? request.offset + page.count : nil
                    let encoded = try GnosticWirePayload.encode(
                        WorkspaceListResult(workspaces: page, nextOffset: nextOffset),
                        context: "workspace.list result"
                    )
                    return .success(result: String(decoding: encoded, as: UTF8.self))
                }
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

    private func boundedPage(_ values: [WorkspaceListing], offset: Int, limit: Int) -> [WorkspaceListing] {
        guard offset < values.count else { return [] }
        var result: [WorkspaceListing] = []
        for value in values.dropFirst(offset).prefix(limit) {
            let candidate = result + [value]
            let candidateOffset = offset + candidate.count < values.count ? offset + candidate.count : nil
            guard (try? GnosticWirePayload.encode(
                WorkspaceListResult(workspaces: candidate, nextOffset: candidateOffset),
                context: "workspace.list result"
            )) != nil else { break }
            result.append(value)
        }
        return result
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
