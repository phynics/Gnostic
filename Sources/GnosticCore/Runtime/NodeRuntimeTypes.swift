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

/// A registry of downstream LLM adapters. GnosticCore owns the runtime shape;
/// the CLI may supply provider-specific language models without being imported by Core.
@MainActor public protocol AscendantRuntimeAdapter: AnyObject, Sendable {
    var identity: AscendantRuntimeIdentity { get }
    func timelines() async throws -> [AscendantRuntimeTimeline]
    func createTimeline(id: UUID, title: String) async throws -> AscendantRuntimeTimeline
    func removeTimeline(id: UUID) async
    func renameTimeline(id: UUID, title: String) async throws -> AscendantRuntimeTimeline
    func attachWorkspace(_ reference: WorkspaceReference, to timelineID: UUID) async throws
    func detachWorkspace(_ workspaceID: UUID, from timelineID: UUID) async throws
    func enabledToolIDs(for timelineID: UUID) async -> [String]
    func runTurn(_ request: AscendantTurnRequest, updates: AscendantTurnUpdateStore) async throws -> String
    func cancelAll() async
    func shutdown() async
}

/// Gnostic's stable, provider-independent projection of an Ascendant identity.
public struct AscendantRuntimeIdentity: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let description: String
    public let privateTimelineID: UUID
    public let primaryWorkspaceID: UUID?
    public let lastActiveAt: Date
    public let createdAt: Date
    public let updatedAt: Date
    public let capabilities: [String]

    public init(
        id: UUID,
        name: String,
        description: String,
        privateTimelineID: UUID,
        primaryWorkspaceID: UUID?,
        lastActiveAt: Date,
        createdAt: Date,
        updatedAt: Date,
        capabilities: [String] = Array(GnosticCapability.stable).sorted()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.privateTimelineID = privateTimelineID
        self.primaryWorkspaceID = primaryWorkspaceID
        self.lastActiveAt = lastActiveAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.capabilities = capabilities
    }
}

/// Gnostic's stable, provider-independent projection of a Timeline.
public struct AscendantRuntimeTimeline: Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let attachedWorkspaceIDs: [UUID]
    public let attachedAscendantID: UUID?
    public let isArchived: Bool
    public let isPrivate: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        title: String,
        attachedWorkspaceIDs: [UUID],
        attachedAscendantID: UUID?,
        isArchived: Bool,
        isPrivate: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.attachedWorkspaceIDs = attachedWorkspaceIDs
        self.attachedAscendantID = attachedAscendantID
        self.isArchived = isArchived
        self.isPrivate = isPrivate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Construction dependencies supplied by the node composition boundary.  The
/// adapter owns all PositronicKit objects created from these values.
@MainActor public struct AscendantRuntimeDependencies {
    public let workspaces: [UUID: any Workspace]
    public let catalog: NetworkCatalog
    public let communication: CommunicationManager
    public let permissionCoordinator: AscendantPermissionCoordinator
    public init(workspaces: [UUID: any Workspace], catalog: NetworkCatalog, communication: CommunicationManager, permissionCoordinator: AscendantPermissionCoordinator) {
        self.workspaces = workspaces; self.catalog = catalog; self.communication = communication; self.permissionCoordinator = permissionCoordinator
    }
}
