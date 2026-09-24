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
        guard [Self.createOperation, Self.listOperation, Self.updateOperation].contains(operation) else {
            return .failure(code: 404, reasonCode: "unknownTimelineOperation", message: "Unknown timeline operation")
        }
        if let failure = GnosticCallHandling.protocolFailure(
            parameters,
            invalidReasonCode: "invalidTimelinePayload",
            invalidMessage: "Invalid timeline payload"
        ) {
            return failure
        }
        switch operation {
        case Self.createOperation:
            guard let request = GnosticCallHandling.decode(TimelineCreateRequest.self, from: parameters) else {
                return .failure(code: 400, reasonCode: "invalidTimelineCreatePayload", message: "Invalid timeline.create payload")
            }
            return try await run {
                let status = try await create(request.title, request.ascendantID)
                try GnosticProtocol.validate(status.protocolMajor)
                return try .encoded(status, context: "timeline.create result")
            }
        case Self.listOperation:
            guard let request = GnosticCallHandling.decode(TimelineListRequest.self, from: parameters),
                  request.offset >= 0, request.limit > 0 else {
                return .failure(code: 400, reasonCode: "invalidTimelineListPayload", message: "Invalid timeline.list payload")
            }
            return try await run {
                let statuses = try await list()
                try statuses.forEach { try GnosticProtocol.validate($0.protocolMajor) }
                let page = GnosticCallHandling.boundedPage(
                    statuses,
                    offset: request.offset,
                    limit: request.limit,
                    context: "timeline.list result"
                ) { TimelineListResult(timelines: $0, nextOffset: $1) }
                return try .encoded(
                    TimelineListResult(timelines: page.items, nextOffset: page.nextOffset),
                    context: "timeline.list result"
                )
            }
        default:
            guard let request = GnosticCallHandling.decode(TimelineUpdateRequest.self, from: parameters) else {
                return .failure(code: 400, reasonCode: "invalidTimelineUpdatePayload", message: "Invalid timeline.update payload")
            }
            return try await run {
                let status = try await update(request)
                try GnosticProtocol.validate(status.protocolMajor)
                return try .encoded(status, context: "timeline.update result")
            }
        }
    }

    private func run(_ body: () async throws -> CallHandlerResult) async throws -> CallHandlerResult {
        try await GnosticCallHandling.run(
            fallbackReasonCode: "internalError",
            fallbackMessage: "The timeline operation failed.",
            body
        )
    }

    @MainActor
    public func register(on communication: CommunicationManager, context: CoatyObject? = nil) async throws -> [CallHandlerRegistration] {
        try await GnosticCallHandling.register(
            operations: [Self.createOperation, Self.listOperation, Self.updateOperation],
            on: communication,
            context: context
        ) { [self] operation, parameters in
            try await handle(operation: operation, parameters: parameters)
        }
    }
}
