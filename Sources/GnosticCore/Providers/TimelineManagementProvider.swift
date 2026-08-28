// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKContracts

/// The wire payload to create a new timeline.
public struct TimelineCreateRequest: Codable, Sendable {
    public let protocolMajor: Int
    public let title: String
    public let ascendantID: UUID?

    public init(title: String, ascendantID: UUID? = nil, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.title = title
        self.ascendantID = ascendantID
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, title, ascendantID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        title = GnosticWirePayload.boundedLabel(try container.decode(String.self, forKey: .title))
        ascendantID = try container.decodeIfPresent(UUID.self, forKey: .ascendantID)
    }
}

/// The wire payload to rename / update a timeline.
public struct TimelineUpdateRequest: Codable, Sendable {
    public let protocolMajor: Int
    public let timelineID: UUID
    public let title: String

    public init(timelineID: UUID, title: String, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.timelineID = timelineID
        self.title = title
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, timelineID, title }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        timelineID = try container.decode(UUID.self, forKey: .timelineID)
        title = GnosticWirePayload.boundedLabel(try container.decode(String.self, forKey: .title))
    }
}

/// The wire result of `timeline.list`.
public struct TimelineListResult: Codable, Sendable {
    public let protocolMajor: Int
    public let timelines: [TimelineStatus]
    public let nextOffset: Int?

    public init(timelines: [TimelineStatus], nextOffset: Int? = nil, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.timelines = timelines
        self.nextOffset = nextOffset
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, timelines, nextOffset }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        timelines = try container.decode([TimelineStatus].self, forKey: .timelines)
        nextOffset = try container.decodeIfPresent(Int.self, forKey: .nextOffset)
    }
}

/// The protocol-bearing request for `timeline.list`.
public struct TimelineListRequest: Codable, Sendable {
    public let protocolMajor: Int
    public let offset: Int
    public let limit: Int

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

/// Hosts the timeline management unary operations.
///
/// Thin wire adapters for three operations: `timeline.create`, `timeline.list`,
/// and `timeline.update` (rename). Each is a generic unary Call/Return whose
/// executor is injected by the serve runtime, which owns the timeline manager.
public struct TimelineManagementProvider: Sendable {
    public static let createOperation = "me.atkn.gnostic.timeline.create"
    public static let listOperation = "me.atkn.gnostic.timeline.list"
    public static let updateOperation = "me.atkn.gnostic.timeline.update"

    public typealias CreateExecutor = @Sendable (String, UUID?) async throws -> TimelineStatus
    public typealias ListExecutor = @Sendable () async throws -> [TimelineStatus]
    public typealias UpdateExecutor = @Sendable (TimelineUpdateRequest) async throws -> TimelineStatus

    private let create: CreateExecutor
    private let list: ListExecutor
    private let update: UpdateExecutor

    public init(
        create: @escaping CreateExecutor,
        list: @escaping ListExecutor,
        update: @escaping UpdateExecutor
    ) {
        self.create = create
        self.list = list
        self.update = update
    }

    public func handle(operation: String, parameters: String?) async throws -> CallHandlerResult {
        switch operation {
        case Self.createOperation:
            if let error = protocolError(parameters) { return error }
            let request: TimelineCreateRequest
            if let parameters, let decoded = try? JSONDecoder().decode(TimelineCreateRequest.self, from: Data(parameters.utf8)) {
                request = decoded
            } else {
                return failure(code: 400, reasonCode: "invalidTimelineCreatePayload", message: "Invalid timeline.create payload")
            }
            do {
                let status = try await create(request.title, request.ascendantID)
                try GnosticProtocol.validate(status.protocolMajor)
                let encoded = try GnosticWirePayload.encode(status, context: "timeline.create result")
                return .success(result: String(decoding: encoded, as: UTF8.self))
            } catch let error as NodeRuntimeError {
                return failure(code: error.statusCode, reasonCode: error.reasonCode, message: error.localizedDescription)
            } catch let error as GnosticProtocolError {
                return .failure(code: error.statusCode, message: error.failureMessage)
            } catch {
                return failure(code: 500, reasonCode: "internalError", message: String(describing: error))
            }
        case Self.listOperation:
            if let error = protocolError(parameters) { return error }
            guard let request = decodeList(parameters), request.offset >= 0, request.limit > 0 else {
                return failure(code: 400, reasonCode: "invalidTimelineListPayload", message: "Invalid timeline.list payload")
            }
            do {
                let statuses = try await list()
                try statuses.forEach { try GnosticProtocol.validate($0.protocolMajor) }
                let pageLimit = min(request.limit, GnosticWirePayload.maximumListItems)
                let page = boundedPage(statuses, offset: request.offset, limit: pageLimit)
                let nextOffset = request.offset + page.count < statuses.count ? request.offset + page.count : nil
                let encoded = try GnosticWirePayload.encode(
                    TimelineListResult(timelines: page, nextOffset: nextOffset),
                    context: "timeline.list result"
                )
                return .success(result: String(decoding: encoded, as: UTF8.self))
            } catch let error as NodeRuntimeError {
                return failure(code: error.statusCode, reasonCode: error.reasonCode, message: error.localizedDescription)
            } catch let error as GnosticProtocolError {
                return .failure(code: error.statusCode, message: error.failureMessage)
            } catch {
                return failure(code: 500, reasonCode: "internalError", message: String(describing: error))
            }
        case Self.updateOperation:
            if let error = protocolError(parameters) { return error }
            guard let parameters,
                  let request = try? JSONDecoder().decode(TimelineUpdateRequest.self, from: Data(parameters.utf8)) else {
                return failure(code: 400, reasonCode: "invalidTimelineUpdatePayload", message: "Invalid timeline.update payload")
            }
            do {
                let status = try await update(request)
                try GnosticProtocol.validate(status.protocolMajor)
                let encoded = try GnosticWirePayload.encode(status, context: "timeline.update result")
                return .success(result: String(decoding: encoded, as: UTF8.self))
            } catch let error as NodeRuntimeError {
                return failure(code: error.statusCode, reasonCode: error.reasonCode, message: error.localizedDescription)
            } catch let error as GnosticProtocolError {
                return .failure(code: error.statusCode, message: error.failureMessage)
            } catch {
                return failure(code: 500, reasonCode: "internalError", message: String(describing: error))
            }
        default:
            return failure(code: 404, reasonCode: "unknownTimelineOperation", message: "Unknown timeline operation")
        }
    }

    private func protocolError(_ parameters: String?) -> CallHandlerResult? {
        do {
            try GnosticProtocol.validatePayload(parameters)
            return nil
        } catch let error as GnosticProtocolError {
            return .failure(code: error.statusCode, message: error.failureMessage)
        } catch {
            return failure(code: 400, reasonCode: "invalidTimelinePayload", message: "Invalid timeline payload")
        }
    }

    private func decodeList(_ parameters: String?) -> TimelineListRequest? {
        guard let parameters else { return nil }
        return try? JSONDecoder().decode(TimelineListRequest.self, from: Data(parameters.utf8))
    }

    private func boundedPage(_ values: [TimelineStatus], offset: Int, limit: Int) -> [TimelineStatus] {
        guard offset < values.count else { return [] }
        var result: [TimelineStatus] = []
        for value in values.dropFirst(offset).prefix(limit) {
            let candidate = result + [value]
            guard (try? GnosticWirePayload.encode(TimelineListResult(timelines: candidate), context: "timeline.list result")) != nil else { break }
            result.append(value)
        }
        return result
    }

    private func failure(code: Int, reasonCode: String, message: String) -> CallHandlerResult {
        .failure(code: code, message: GnosticProtocol.failureMessage(reasonCode: reasonCode, message: message))
    }

    @MainActor
    public func register(on communication: CommunicationManager, context: CoatyObject? = nil) async throws -> [CallHandlerRegistration] {
        var registrations: [CallHandlerRegistration] = []
        do {
            for operation in [Self.createOperation, Self.listOperation, Self.updateOperation] {
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
