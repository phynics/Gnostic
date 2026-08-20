// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared
import PositronicKit

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
        case let .workspaceCapabilityUnavailable(id): "Ascendant \(id.uuidString) does not support Workspace operations."
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
    public let agentIDs: [UUID]
    public let timelineIDs: [UUID]
    public let operatedTimelineIDs: [UUID]
    public let workspaceIDs: [UUID]

    public init(nodeID: UUID, ascendantIDs: [UUID], agentIDs: [UUID], timelineIDs: [UUID], operatedTimelineIDs: [UUID], workspaceIDs: [UUID]) {
        self.nodeID = nodeID
        self.ascendantIDs = ascendantIDs
        self.agentIDs = agentIDs
        self.timelineIDs = timelineIDs
        self.operatedTimelineIDs = operatedTimelineIDs
        self.workspaceIDs = workspaceIDs
    }
}

/// Compatibility spelling retained for adapters registered before the backend
/// boundary was made explicit. New implementations should conform to
/// ``AscendantBackend`` and use ``AscendantAdapterRegistry.registerBackend``.
@MainActor public protocol AscendantRuntimeAdapter: AnyObject, Sendable {
    var identity: AscendantRuntimeIdentity { get }
    func timelines() async throws -> [AscendantRuntimeTimeline]
    func createTimeline(id: UUID, title: String) async throws -> AscendantRuntimeTimeline
    func removeTimeline(id: UUID) async
    func renameTimeline(id: UUID, title: String) async throws -> AscendantRuntimeTimeline
    func attachWorkspace(_ reference: WorkspaceReference, to timelineID: UUID) async throws
    func detachWorkspace(_ workspaceID: UUID, from timelineID: UUID) async throws
    func enabledToolIDs(for timelineID: UUID) async -> [String]
    func runTurn(_ request: AgentChatRequest, updates: AscendantTurnUpdateStore) async throws -> String
    func cancelAll() async
    func shutdown() async
}

/// Compatibility projections now share the backend-neutral value types.
public typealias AscendantRuntimeIdentity = AscendantBackendIdentity
public typealias AscendantRuntimeTimeline = AscendantBackendTimeline

/// Construction dependencies supplied by the node composition boundary. Raw
/// transport and provider-native objects are intentionally absent. A legacy
/// adapter can use the compatibility bridge supplied by the registry.
@MainActor public struct AscendantRuntimeDependencies {
    public let services: AscendantBackendServices

    public init(services: AscendantBackendServices = .empty) {
        self.services = services
    }
}
