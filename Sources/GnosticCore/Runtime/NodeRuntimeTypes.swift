// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

/// Failures raised while materializing or running a validated node plan.
public enum NodeRuntimeError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedAscendantKind(String)
    case unsupportedWorkspaceKind(String)
    case invalidWorkspaceURI(UUID)
    case missingTimeline(UUID)
    case missingWorkspace(UUID)
    case noOperatingAscendant(UUID)
    case unknownAscendant(UUID)
    case noConfiguredAscendant
    case ambiguousAscendant
    case workspaceCapabilityUnavailable(UUID)
    case turnFailed(String)
    case startInProgress
    case notRunning

    public var errorDescription: String? {
        switch self {
        case let .unsupportedAscendantKind(kind): "No Ascendant adapter is registered for '\(kind)'."
        case let .unsupportedWorkspaceKind(kind): "No Workspace adapter is registered for '\(kind)'."
        case let .invalidWorkspaceURI(id): "Workspace \(id.uuidString) has an invalid URI."
        case let .missingTimeline(id): "Timeline \(id.uuidString) is not in the launch plan."
        case let .missingWorkspace(id): "Workspace \(id.uuidString) is not in the launch plan."
        case let .noOperatingAscendant(id): "Timeline \(id.uuidString) has no operating Ascendant."
        case let .unknownAscendant(id): "Ascendant \(id.uuidString) is not in the launch plan."
        case .noConfiguredAscendant: "The node has no configured Ascendant."
        case .ambiguousAscendant: "The node has multiple Ascendants; select one explicitly."
        case let .workspaceCapabilityUnavailable(id): "Ascendant operating Timeline \(id.uuidString) does not support Workspace operations."
        case let .turnFailed(detail): detail
        case .startInProgress: "The node runtime is already starting."
        case .notRunning: "The node runtime is not running."
        }
    }

    public var reasonCode: String {
        switch self {
        case .unsupportedAscendantKind: "unsupportedAscendantKind"
        case .unsupportedWorkspaceKind: "unsupportedWorkspaceKind"
        case .invalidWorkspaceURI: "invalidWorkspaceURI"
        case .missingTimeline: "missingTimeline"
        case .missingWorkspace: "missingWorkspace"
        case .noOperatingAscendant: "noOperatingAscendant"
        case .unknownAscendant: "unknownAscendant"
        case .noConfiguredAscendant: "noConfiguredAscendant"
        case .ambiguousAscendant: "ambiguousAscendant"
        case .workspaceCapabilityUnavailable: "workspaceCapabilityUnavailable"
        case .turnFailed: "turnFailed"
        case .startInProgress: "startInProgress"
        case .notRunning: "notRunning"
        }
    }

    public var statusCode: Int {
        switch self {
        case .missingTimeline, .missingWorkspace, .unknownAscendant: 404
        case .noOperatingAscendant: 409
        case .startInProgress, .notRunning: 503
        case .workspaceCapabilityUnavailable: 501
        case .turnFailed: 500
        default: 400
        }
    }

    /// A stable message for public protocol failures. Associated values remain
    /// available to local diagnostics but never cross the wire.
    public var publicMessage: String {
        switch self {
        case .unsupportedAscendantKind: "The Ascendant kind is not supported."
        case .unsupportedWorkspaceKind: "The Workspace kind is not supported."
        case .invalidWorkspaceURI: "The Workspace URI is invalid."
        case .missingTimeline: "The Timeline was not found."
        case .missingWorkspace: "The Workspace was not found."
        case .noOperatingAscendant: "The Timeline has no operating Ascendant."
        case .unknownAscendant: "The Ascendant was not found."
        case .noConfiguredAscendant: "The node has no configured Ascendant."
        case .ambiguousAscendant: "The node has multiple Ascendants."
        case .workspaceCapabilityUnavailable: "Workspace operations are unavailable."
        case .turnFailed: "The Ascendant turn failed."
        case .startInProgress: "The node runtime is already starting."
        case .notRunning: "The node runtime is not running."
        }
    }
}

/// The observable, stable identity graph materialized by ``NodeRuntime``.
public struct NodeRuntimeSnapshot: Sendable, Equatable {
    public let nodeID: UUID
    public let ascendantIDs: [UUID]
    public let timelineIDs: [UUID]
    public let operatedTimelineIDs: [UUID]
    public let workspaceIDs: [UUID]

    public init(nodeID: UUID, ascendantIDs: [UUID], timelineIDs: [UUID], operatedTimelineIDs: [UUID], workspaceIDs: [UUID]) {
        self.nodeID = nodeID
        self.ascendantIDs = ascendantIDs
        self.timelineIDs = timelineIDs
        self.operatedTimelineIDs = operatedTimelineIDs
        self.workspaceIDs = workspaceIDs
    }
}

/// The runtime's bounded in-memory accounting, for soak resource tracking.
///
/// PositronicKit's `InMemoryMessageStore` exposes no count, so the retained
/// Turn ledger is the in-memory store Gnostic owns and bounds; it is the
/// recorded growth proxy for GNO-PLAT-062 (#454).
public struct NodeRuntimeMetrics: Codable, Sendable, Equatable {
    /// Identified Turns currently running.
    public let inFlightTurns: Int
    /// Timelines the coordinator currently holds a lane for.
    public let retainedTimelineCount: Int
    /// Admitted identified Turns retained until runtime shutdown.
    public let retainedIdentityCount: Int
    /// Terminal outcomes retained for replay.
    public let retainedCompletedCount: Int
    /// Terminal tombstones retained for replay.
    public let retainedTombstoneCount: Int
    /// Bytes of retained terminal payloads.
    public let retainedCompletedBytes: Int
    /// The bound on ``retainedIdentityCount``.
    public let identityCapacity: Int
    /// The bound on ``retainedCompletedCount``.
    public let completedCapacity: Int

    public init(
        inFlightTurns: Int,
        retainedTimelineCount: Int,
        retainedIdentityCount: Int,
        retainedCompletedCount: Int,
        retainedTombstoneCount: Int,
        retainedCompletedBytes: Int,
        identityCapacity: Int,
        completedCapacity: Int
    ) {
        self.inFlightTurns = inFlightTurns
        self.retainedTimelineCount = retainedTimelineCount
        self.retainedIdentityCount = retainedIdentityCount
        self.retainedCompletedCount = retainedCompletedCount
        self.retainedTombstoneCount = retainedTombstoneCount
        self.retainedCompletedBytes = retainedCompletedBytes
        self.identityCapacity = identityCapacity
        self.completedCapacity = completedCapacity
    }
}

/// Gnostic's stable, provider-independent projection of an Ascendant identity.
/// These aliases keep the runtime's existing projection seams independent of
/// any provider-native type while the backend contract remains canonical.
public typealias AscendantRuntimeIdentity = AscendantBackendIdentity
public typealias AscendantRuntimeTimeline = AscendantBackendTimeline
