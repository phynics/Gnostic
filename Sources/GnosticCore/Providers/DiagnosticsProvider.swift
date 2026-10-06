// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticProtocol

/// The protocol-bearing request for the node-wide diagnostics operation.
public struct DiagnosticsNodeRequest: Codable, Sendable, Equatable {
    public let protocolMajor: Int

    public init(protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
    }
}

/// The protocol-bearing request for an Ascendant- or Timeline-scoped diagnostics operation.
public struct DiagnosticsTargetRequest: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let id: UUID

    public init(id: UUID, protocolMajor: Int = GnosticProtocol.currentMajor) {
        self.protocolMajor = protocolMajor
        self.id = id
    }

    private enum CodingKeys: String, CodingKey { case protocolMajor, id }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        id = try container.decode(UUID.self, forKey: .id)
    }
}

/// A payload-free summary of one Ascendant's runtime health.
public struct DiagnosticsAscendantSummary: Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let health: AscendantBackendHealth
    public let quarantined: Bool

    public init(id: UUID, name: String, health: AscendantBackendHealth, quarantined: Bool) {
        self.id = id
        self.name = GnosticWirePayload.boundedLabel(name)
        self.health = health
        self.quarantined = quarantined
    }
}

/// A payload-free summary of one Timeline's runtime routing.
public struct DiagnosticsTimelineSummary: Codable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let operatingAscendantID: UUID?

    public init(id: UUID, title: String, operatingAscendantID: UUID?) {
        self.id = id
        self.title = GnosticWirePayload.boundedLabel(title)
        self.operatingAscendantID = operatingAscendantID
    }
}

/// A payload-free summary of one Workspace's effective status.
public struct DiagnosticsWorkspaceSummary: Codable, Sendable, Equatable {
    public let id: UUID
    public let uri: String
    public let status: GnosticWorkspaceEffectiveStatus

    public init(id: UUID, uri: String, status: GnosticWorkspaceEffectiveStatus) {
        self.id = id
        self.uri = GnosticWirePayload.boundedLabel(uri)
        self.status = status
    }
}

/// Live Turn counts. These are counts only; no Turn identity or body is carried.
public struct DiagnosticsTurnCounters: Codable, Sendable, Equatable {
    public let inFlight: Int
    public let completed: Int
    public let observationPending: Int
    public let observationClosed: Bool

    public init(inFlight: Int, completed: Int, observationPending: Int, observationClosed: Bool) {
        self.inFlight = inFlight
        self.completed = completed
        self.observationPending = observationPending
        self.observationClosed = observationClosed
    }
}

/// Observer drain statistics for the bounded Turn ledger.
public struct DiagnosticsObserverDrain: Codable, Sendable, Equatable {
    public let liveObservations: Int
    public let cleanupFailures: Int
    public let retainedInFlight: Int
    public let retainedCompleted: Int
    public let retainedTombstones: Int

    public init(
        liveObservations: Int,
        cleanupFailures: Int,
        retainedInFlight: Int,
        retainedCompleted: Int,
        retainedTombstones: Int
    ) {
        self.liveObservations = liveObservations
        self.cleanupFailures = cleanupFailures
        self.retainedInFlight = retainedInFlight
        self.retainedCompleted = retainedCompleted
        self.retainedTombstones = retainedTombstones
    }
}

/// Live, payload-free runtime state for one Node.
public struct NodeDiagnostics: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let nodeID: UUID?
    public let ascendents: [DiagnosticsAscendantSummary]
    public let timelines: [DiagnosticsTimelineSummary]
    public let workspaces: [DiagnosticsWorkspaceSummary]
    public let turns: DiagnosticsTurnCounters
    public let observer: DiagnosticsObserverDrain

    public init(
        nodeID: UUID?,
        ascendents: [DiagnosticsAscendantSummary],
        timelines: [DiagnosticsTimelineSummary],
        workspaces: [DiagnosticsWorkspaceSummary],
        turns: DiagnosticsTurnCounters,
        observer: DiagnosticsObserverDrain,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.nodeID = nodeID
        self.ascendents = ascendents
        self.timelines = timelines
        self.workspaces = workspaces
        self.turns = turns
        self.observer = observer
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor, nodeID, ascendents, timelines, workspaces, turns, observer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        nodeID = try container.decodeIfPresent(UUID.self, forKey: .nodeID)
        ascendents = try container.decode([DiagnosticsAscendantSummary].self, forKey: .ascendents)
        timelines = try container.decode([DiagnosticsTimelineSummary].self, forKey: .timelines)
        workspaces = try container.decode([DiagnosticsWorkspaceSummary].self, forKey: .workspaces)
        turns = try container.decode(DiagnosticsTurnCounters.self, forKey: .turns)
        observer = try container.decode(DiagnosticsObserverDrain.self, forKey: .observer)
    }
}

/// Live, payload-free runtime state for one Ascendant.
public struct AscendantDiagnostics: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let ascendant: DiagnosticsAscendantSummary
    public let description: String
    public let backendKind: String?
    public let backendVersion: String?
    public let capabilities: [String]
    public let privateTimelineID: UUID
    public let primaryWorkspaceID: UUID?
    public let timelines: [DiagnosticsTimelineSummary]

    public init(
        ascendant: DiagnosticsAscendantSummary,
        description: String,
        backendKind: String?,
        backendVersion: String?,
        capabilities: [String],
        privateTimelineID: UUID,
        primaryWorkspaceID: UUID?,
        timelines: [DiagnosticsTimelineSummary],
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.ascendant = ascendant
        self.description = GnosticWirePayload.boundedLabel(description)
        self.backendKind = backendKind.map(GnosticWirePayload.boundedLabel)
        self.backendVersion = backendVersion.map(GnosticWirePayload.boundedLabel)
        self.capabilities = capabilities
            .filter { GnosticCapability.stable.contains($0) || GnosticCapability.isNamespacedExperimental($0) }
            .sorted()
        self.privateTimelineID = privateTimelineID
        self.primaryWorkspaceID = primaryWorkspaceID
        self.timelines = timelines
    }
}

/// Live, payload-free runtime state for one Timeline.
public struct TimelineDiagnostics: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let timeline: DiagnosticsTimelineSummary
    public let workspaces: [DiagnosticsWorkspaceSummary]

    public init(
        timeline: DiagnosticsTimelineSummary,
        workspaces: [DiagnosticsWorkspaceSummary],
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.timeline = timeline
        self.workspaces = workspaces
    }
}

/// Hosts the read-only diagnostics unary operations.
///
/// Three operations: `diagnostics.node`, `diagnostics.ascendant`, and
/// `diagnostics.timeline`. Every executor returns payload-free runtime state;
/// the provider never mutates the Node.
public struct DiagnosticsProvider: Sendable {
    public static let nodeOperation = "me.atkn.gnostic.diagnostics.node"
    public static let ascendantOperation = "me.atkn.gnostic.diagnostics.ascendant"
    public static let timelineOperation = "me.atkn.gnostic.diagnostics.timeline"

    public typealias NodeExecutor = @Sendable () async throws -> NodeDiagnostics
    public typealias AscendantExecutor = @Sendable (UUID) async throws -> AscendantDiagnostics
    public typealias TimelineExecutor = @Sendable (UUID) async throws -> TimelineDiagnostics

    private let node: NodeExecutor
    private let ascendant: AscendantExecutor
    private let timeline: TimelineExecutor

    public init(
        node: @escaping NodeExecutor,
        ascendant: @escaping AscendantExecutor,
        timeline: @escaping TimelineExecutor
    ) {
        self.node = node
        self.ascendant = ascendant
        self.timeline = timeline
    }

    public func handle(operation: String, parameters: String?) async throws -> CallHandlerResult {
        guard [Self.nodeOperation, Self.ascendantOperation, Self.timelineOperation].contains(operation) else {
            return .failure(code: 404, reasonCode: "unknownDiagnosticsOperation", message: "Unknown diagnostics operation")
        }
        if let failure = GnosticCallHandling.protocolFailure(
            parameters,
            invalidReasonCode: "invalidDiagnosticsPayload",
            invalidMessage: "Invalid diagnostics payload"
        ) {
            return failure
        }
        switch operation {
        case Self.nodeOperation:
            guard GnosticCallHandling.decode(DiagnosticsNodeRequest.self, from: parameters) != nil else {
                return .failure(code: 400, reasonCode: "invalidDiagnosticsPayload", message: "Invalid diagnostics.node payload")
            }
            return try await run {
                let snapshot = try await self.node()
                return try .encoded(snapshot, context: "diagnostics.node result")
            }
        case Self.ascendantOperation:
            guard let request = GnosticCallHandling.decode(DiagnosticsTargetRequest.self, from: parameters) else {
                return .failure(code: 400, reasonCode: "invalidDiagnosticsPayload", message: "Invalid diagnostics.ascendant payload")
            }
            return try await run {
                let snapshot = try await self.ascendant(request.id)
                return try .encoded(snapshot, context: "diagnostics.ascendant result")
            }
        default:
            guard let request = GnosticCallHandling.decode(DiagnosticsTargetRequest.self, from: parameters) else {
                return .failure(code: 400, reasonCode: "invalidDiagnosticsPayload", message: "Invalid diagnostics.timeline payload")
            }
            return try await run {
                let snapshot = try await self.timeline(request.id)
                return try .encoded(snapshot, context: "diagnostics.timeline result")
            }
        }
    }

    private func run(_ body: () async throws -> CallHandlerResult) async throws -> CallHandlerResult {
        try await GnosticCallHandling.run(
            fallbackReasonCode: "diagnosticsOperationFailed",
            fallbackMessage: "The diagnostics operation failed.",
            body
        )
    }

    @MainActor
    public func register(on communication: CommunicationManager, context: CoatyObject? = nil) async throws -> [CallHandlerRegistration] {
        try await GnosticCallHandling.register(
            operations: [Self.nodeOperation, Self.ascendantOperation, Self.timelineOperation],
            on: communication,
            context: context
        ) { [self] operation, parameters in
            try await handle(operation: operation, parameters: parameters)
        }
    }
}
