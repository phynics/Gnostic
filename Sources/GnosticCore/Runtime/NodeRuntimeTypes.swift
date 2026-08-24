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

/// Gnostic's stable, provider-independent projection of an Ascendant identity.
/// These aliases keep the runtime's existing projection seams independent of
/// any provider-native type while the backend contract remains canonical.
public typealias AscendantRuntimeIdentity = AscendantBackendIdentity
public typealias AscendantRuntimeTimeline = AscendantBackendTimeline
