// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared

/// The wire payload to create a new timeline.
public struct TimelineCreateRequest: Codable, Sendable {
    public let title: String
    public let ascendantID: UUID?

    public init(title: String, ascendantID: UUID? = nil) {
        self.title = title
        self.ascendantID = ascendantID
    }
}

/// The wire payload to rename / update a timeline.
public struct TimelineUpdateRequest: Codable, Sendable {
    public let timelineID: UUID
    public let title: String

    public init(timelineID: UUID, title: String) {
        self.timelineID = timelineID
        self.title = title
    }
}

/// The wire result of `timeline.list`.
public struct TimelineListResult: Codable, Sendable {
    public let timelines: [TimelineStatus]

    public init(timelines: [TimelineStatus]) {
        self.timelines = timelines
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
    public typealias LegacyCreateExecutor = @Sendable (String) async throws -> TimelineStatus
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

    public init(
        create: @escaping LegacyCreateExecutor,
        list: @escaping ListExecutor,
        update: @escaping UpdateExecutor
    ) {
        self.init(create: { title, _ in try await create(title) }, list: list, update: update)
    }

    public func handle(operation: String, parameters: String?) async throws -> CallHandlerResult {
        switch operation {
        case Self.createOperation:
            let request: TimelineCreateRequest
            if let parameters, let decoded = try? JSONDecoder().decode(TimelineCreateRequest.self, from: Data(parameters.utf8)) {
                request = decoded
            } else {
                return .failure(code: 400, message: "Invalid timeline.create payload")
            }
            let status = try await create(request.title, request.ascendantID)
            let encoded = try JSONEncoder().encode(status)
            return .success(result: String(decoding: encoded, as: UTF8.self))
        case Self.listOperation:
            let statuses = try await list()
            let encoded = try JSONEncoder().encode(TimelineListResult(timelines: statuses))
            return .success(result: String(decoding: encoded, as: UTF8.self))
        case Self.updateOperation:
            guard let parameters,
                  let request = try? JSONDecoder().decode(TimelineUpdateRequest.self, from: Data(parameters.utf8)) else {
                return .failure(code: 400, message: "Invalid timeline.update payload")
            }
            let status = try await update(request)
            let encoded = try JSONEncoder().encode(status)
            return .success(result: String(decoding: encoded, as: UTF8.self))
        default:
            return .failure(code: 404, message: "Unknown timeline operation")
        }
    }

    @MainActor
    public func register(on communication: CommunicationManager) async throws -> [CallHandlerRegistration] {
        var registrations: [CallHandlerRegistration] = []
        do {
            for operation in [Self.createOperation, Self.listOperation, Self.updateOperation] {
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
