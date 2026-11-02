// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

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

/// The protocol-bearing request for a Runtime-instance- or Timeline-scoped diagnostics operation.
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

/// A payload-free summary of one Runtime instance's health.
public struct DiagnosticsRuntimeInstanceSummary: Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let health: GnosticRuntimeInstanceHealth
    public let quarantined: Bool

    public init(id: UUID, name: String, health: GnosticRuntimeInstanceHealth, quarantined: Bool) {
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
    public let runtimeInstanceID: UUID?

    public init(id: UUID, title: String, runtimeInstanceID: UUID?) {
        self.id = id
        self.title = GnosticWirePayload.boundedLabel(title)
        self.runtimeInstanceID = runtimeInstanceID
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

/// The durable state of the Timeline's latest ACP Session record.
public enum DiagnosticsTimelineSessionState: String, Codable, Sendable, Equatable {
    case live
    case resumable
    case lost
    case ambiguous
}

/// Payload-free Session continuity information for Timeline diagnostics.
public struct DiagnosticsTimelineSessionRecovery: Codable, Sendable, Equatable {
    public let state: DiagnosticsTimelineSessionState?
    public let contextWasLost: Bool
    public let message: String?

    public init(state: DiagnosticsTimelineSessionState?, contextWasLost: Bool, message: String?) {
        self.state = state
        self.contextWasLost = contextWasLost
        self.message = message.map(GnosticWirePayload.boundedLabel)
    }
}

/// Whether the Timeline's authoritative journal accepts writes.
public enum DiagnosticsTimelineJournalState: String, Codable, Sendable, Equatable {
    case writable
    case quarantined
}

/// Payload-free journal availability for Timeline diagnostics. A quarantined
/// journal names neither a path nor the corrupt frame.
public struct DiagnosticsTimelineJournal: Codable, Sendable, Equatable {
    public let state: DiagnosticsTimelineJournalState
    public let message: String?

    public init(state: DiagnosticsTimelineJournalState, message: String? = nil) {
        self.state = state
        self.message = message.map(GnosticWirePayload.boundedLabel)
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
    public let runtimeInstances: [DiagnosticsRuntimeInstanceSummary]
    public let timelines: [DiagnosticsTimelineSummary]
    public let workspaces: [DiagnosticsWorkspaceSummary]
    public let turns: DiagnosticsTurnCounters
    public let observer: DiagnosticsObserverDrain

    public init(
        nodeID: UUID?,
        runtimeInstances: [DiagnosticsRuntimeInstanceSummary],
        timelines: [DiagnosticsTimelineSummary],
        workspaces: [DiagnosticsWorkspaceSummary],
        turns: DiagnosticsTurnCounters,
        observer: DiagnosticsObserverDrain,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.nodeID = nodeID
        self.runtimeInstances = runtimeInstances
        self.timelines = timelines
        self.workspaces = workspaces
        self.turns = turns
        self.observer = observer
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor, nodeID, runtimeInstances, timelines, workspaces, turns, observer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        nodeID = try container.decodeIfPresent(UUID.self, forKey: .nodeID)
        runtimeInstances = try container.decode([DiagnosticsRuntimeInstanceSummary].self, forKey: .runtimeInstances)
        timelines = try container.decode([DiagnosticsTimelineSummary].self, forKey: .timelines)
        workspaces = try container.decode([DiagnosticsWorkspaceSummary].self, forKey: .workspaces)
        turns = try container.decode(DiagnosticsTurnCounters.self, forKey: .turns)
        observer = try container.decode(DiagnosticsObserverDrain.self, forKey: .observer)
    }
}

/// Live, payload-free runtime state for one Runtime instance.
public struct RuntimeInstanceDiagnostics: Codable, Sendable, Equatable {
    public let protocolMajor: Int
    public let runtimeInstance: DiagnosticsRuntimeInstanceSummary
    public let description: String
    public let backendKind: String?
    public let backendVersion: String?
    public let capabilities: [String]
    public let privateTimelineID: UUID
    public let primaryWorkspaceID: UUID?
    public let timelines: [DiagnosticsTimelineSummary]

    public init(
        runtimeInstance: DiagnosticsRuntimeInstanceSummary,
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
        self.runtimeInstance = runtimeInstance
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
    public let sessionRecovery: DiagnosticsTimelineSessionRecovery?
    public let journal: DiagnosticsTimelineJournal?

    public init(
        timeline: DiagnosticsTimelineSummary,
        workspaces: [DiagnosticsWorkspaceSummary],
        sessionRecovery: DiagnosticsTimelineSessionRecovery? = nil,
        journal: DiagnosticsTimelineJournal? = nil,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.timeline = timeline
        self.workspaces = workspaces
        self.sessionRecovery = sessionRecovery
        self.journal = journal
    }
}
