// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The actor-isolated source of truth for a node's local identity graph.
///
/// Configuration is copied into the registry at launch. Runtime-created state
/// lives only here, so it can never be written back to the manifest.
public actor NodeRegistry {
    public enum WorkspaceEffectiveStatus: String, Codable, Sendable, Equatable {
        case available
        case unavailable
        case unsupported
    }

    public enum Provenance: String, Sendable, Equatable {
        case configured
        case runtime
    }

    public struct TimelineRecord: Sendable, Equatable {
        public let timeline: AscendantRuntimeTimeline
        public let operatorID: UUID?
        public let provenance: Provenance

        public var id: UUID { timeline.id }
    }

    public struct WorkspaceRecord: Sendable, Equatable {
        public let id: UUID
        public let uri: String
        public let status: WorkspaceEffectiveStatus
        public let isAvailable: Bool
        public let toolIDs: [String]

        public init(id: UUID, uri: String, status: WorkspaceEffectiveStatus, toolIDs: [String]) {
            self.id = id
            self.uri = uri
            self.status = status
            self.isAvailable = status == .available
            self.toolIDs = toolIDs
        }

        /// Compatibility initializer for callers that only know a boolean
        /// health projection.
        public init(id: UUID, uri: String, isAvailable: Bool, toolIDs: [String]) {
            self.init(id: id, uri: uri, status: isAvailable ? .available : .unavailable, toolIDs: toolIDs)
        }
    }

    private let nodeID: UUID
    private let ascendantIDs: Set<UUID>
    private let configuredAscendantIDs: [UUID]
    private let configuredWorkspaceIDs: [UUID]
    private var timelines: [UUID: TimelineRecord]
    private var workspaces: [UUID: WorkspaceRecord]
    private var attachmentIntents: [UUID: [NodeManifest.WorkspaceAttachment]]

    public init(plan: NodeLaunchPlan, operatedTimelines: [AscendantRuntimeTimeline]) throws {
        nodeID = plan.nodeID
        configuredAscendantIDs = plan.ascendants.map(\.id)
        ascendantIDs = Set(configuredAscendantIDs)
        configuredWorkspaceIDs = plan.workspaces.map(\.id)
        timelines = [:]
        workspaces = [:]
        var intents: [UUID: [NodeManifest.WorkspaceAttachment]] = [:]
        for timeline in plan.timelines {
            intents[timeline.id] = timeline.attachments
        }
        attachmentIntents = intents

        var projected: [UUID: AscendantRuntimeTimeline] = [:]
        for timeline in operatedTimelines {
            guard projected.updateValue(timeline, forKey: timeline.id) == nil else {
                throw NodeRuntimeError.missingTimeline(timeline.id)
            }
        }
        let configuredOperatedIDs = Set(plan.timelines.filter { $0.operatingAscendantID != nil }.map(\.id))
        guard Set(projected.keys) == configuredOperatedIDs else {
            let missing = configuredOperatedIDs.subtracting(projected.keys).first
                ?? Set(projected.keys).subtracting(configuredOperatedIDs).first!
            throw NodeRuntimeError.missingTimeline(missing)
        }
        for configuration in plan.timelines {
            let timeline: AscendantRuntimeTimeline
            if let operatorID = configuration.operatingAscendantID {
                guard ascendantIDs.contains(operatorID), let value = projected[configuration.id] else {
                    throw NodeRuntimeError.missingTimeline(configuration.id)
                }
                guard value.attachedAgentInstanceID == operatorID else {
                    throw NodeRuntimeError.unknownAscendant(value.attachedAgentInstanceID ?? operatorID)
                }
                timeline = .init(
                    id: value.id,
                    title: value.title,
                    attachedWorkspaceIDs: configuration.attachments.map(\.workspaceID),
                    ascendantID: value.ascendantID,
                    isArchived: value.isArchived,
                    isPrivate: value.isPrivate,
                    createdAt: value.createdAt,
                    updatedAt: value.updatedAt
                )
            } else {
                let now = Date()
                timeline = .init(id: configuration.id, title: configuration.title, attachedWorkspaceIDs: configuration.attachments.map(\.workspaceID), attachedAgentInstanceID: nil, isArchived: false, isPrivate: false, createdAt: now, updatedAt: now)
            }
            timelines[configuration.id] = .init(timeline: timeline, operatorID: configuration.operatingAscendantID, provenance: .configured)
        }

        for workspace in plan.workspaces {
            workspaces[workspace.id] = .init(id: workspace.id, uri: workspace.uri, status: .available, toolIDs: [])
        }
        for attachment in plan.timelines.flatMap(\.attachments) where attachment.scope == .network {
            guard let uri = attachment.uri else { continue }
            if let existing = workspaces[attachment.workspaceID], existing.uri != uri {
                throw NodeRuntimeError.invalidWorkspaceURI(attachment.workspaceID)
            }
            workspaces[attachment.workspaceID] = .init(id: attachment.workspaceID, uri: uri, status: .unavailable, toolIDs: [])
        }
    }

    public func snapshot() -> NodeRuntimeSnapshot {
        let records = sortedTimelineRecords()
        return .init(nodeID: nodeID, ascendantIDs: configuredAscendantIDs, agentIDs: configuredAscendantIDs, timelineIDs: records.map(\.id), operatedTimelineIDs: records.compactMap { $0.operatorID == nil ? nil : $0.id }, workspaceIDs: configuredWorkspaceIDs + workspaces.values.filter { !configuredWorkspaceIDs.contains($0.id) }.map(\.id).sorted { $0.uuidString < $1.uuidString })
    }

    public func listTimelines() -> [AscendantRuntimeTimeline] { sortedTimelineRecords().map(\.timeline) }
    public func timeline(id: UUID) -> TimelineRecord? { timelines[id] }
    public func discoverableTimelineIDs() -> [UUID] { sortedTimelineRecords().map(\.id) }
    public func operatorID(forTimeline id: UUID) -> UUID? { timelines[id]?.operatorID }

    public func requireOperatingAscendant(for timelineID: UUID) throws -> UUID {
        guard let record = timelines[timelineID] else { throw NodeRuntimeError.missingTimeline(timelineID) }
        guard let operatorID = record.operatorID else { throw NodeRuntimeError.noOperatingAscendant(timelineID) }
        return operatorID
    }

    public func registerRuntimeTimeline(title: String, ascendantID: UUID) throws -> TimelineRecord {
        guard ascendantIDs.contains(ascendantID) else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
        let now = Date()
        let timeline = AscendantRuntimeTimeline(id: UUID.makeVersion4(), title: title, attachedWorkspaceIDs: [], attachedAgentInstanceID: ascendantID, isArchived: false, isPrivate: false, createdAt: now, updatedAt: now)
        let record = TimelineRecord(timeline: timeline, operatorID: ascendantID, provenance: .runtime)
        timelines[timeline.id] = record
        attachmentIntents[timeline.id] = []
        return record
    }

    public func removeRuntimeTimeline(id: UUID) {
        guard timelines[id]?.provenance == .runtime else { return }
        timelines.removeValue(forKey: id)
        attachmentIntents.removeValue(forKey: id)
    }

    /// Registers an adapter-created runtime timeline under an already selected operator.
    public func registerRuntimeTimeline(_ timeline: AscendantRuntimeTimeline, ascendantID: UUID) throws -> TimelineRecord {
        guard ascendantIDs.contains(ascendantID) else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
        guard timelines[timeline.id] == nil else { throw NodeRuntimeError.missingTimeline(timeline.id) }
        guard timeline.attachedAgentInstanceID == ascendantID else { throw NodeRuntimeError.unknownAscendant(timeline.attachedAgentInstanceID ?? ascendantID) }
        let record = TimelineRecord(timeline: timeline, operatorID: ascendantID, provenance: .runtime)
        timelines[timeline.id] = record
        attachmentIntents[timeline.id] = []
        return record
    }

    /// Replaces only an existing timeline's projection after the adapter has accepted a mutation.
    public func replaceTimeline(_ timeline: AscendantRuntimeTimeline) throws -> TimelineRecord {
        guard let current = timelines[timeline.id] else { throw NodeRuntimeError.missingTimeline(timeline.id) }
        guard timeline.attachedAgentInstanceID == current.operatorID else { throw NodeRuntimeError.noOperatingAscendant(timeline.id) }
        let record = TimelineRecord(timeline: timeline, operatorID: current.operatorID, provenance: current.provenance)
        timelines[timeline.id] = record
        return record
    }

    /// Commits a Timeline replacement and emits its required projection as one
    /// actor-isolated transition. A projection failure restores the prior
    /// authoritative record before the error escapes.
    public func replaceTimeline(
        _ timeline: AscendantRuntimeTimeline,
        projecting: @MainActor @Sendable (TimelineRecord) throws -> Void
    ) async throws -> TimelineRecord {
        guard let previous = timelines[timeline.id] else { throw NodeRuntimeError.missingTimeline(timeline.id) }
        guard timeline.attachedAgentInstanceID == previous.operatorID else { throw NodeRuntimeError.noOperatingAscendant(timeline.id) }
        let record = TimelineRecord(timeline: timeline, operatorID: previous.operatorID, provenance: previous.provenance)
        timelines[timeline.id] = record
        do {
            try await projecting(record)
            return record
        } catch {
            if timelines[timeline.id] == record { timelines[timeline.id] = previous }
            throw error
        }
    }

    public func workspace(id: UUID) -> WorkspaceRecord? { workspaces[id] }
    public func effectiveWorkspaceStatus(id: UUID) -> WorkspaceEffectiveStatus? { workspaces[id]?.status }

    /// Returns the authoritative attachment intent. Runtime health changes
    /// never remove this relationship; explicit attach/detach mutations do.
    public func attachmentIntent(for timelineID: UUID) -> [NodeManifest.WorkspaceAttachment] {
        guard timelines[timelineID] != nil else { return [] }
        return attachmentIntents[timelineID] ?? []
    }

    /// Adds or replaces one Workspace attachment intent after a backend has
    /// accepted the corresponding operation.
    public func upsertAttachmentIntent(_ attachment: NodeManifest.WorkspaceAttachment, for timelineID: UUID) {
        guard timelines[timelineID] != nil else { return }
        var intents = attachmentIntents[timelineID] ?? []
        intents.removeAll { $0.workspaceID == attachment.workspaceID }
        intents.append(attachment)
        attachmentIntents[timelineID] = intents
    }

    /// Removes one Workspace attachment intent after a backend has accepted a
    /// detach operation.
    public func removeAttachmentIntent(workspaceID: UUID, from timelineID: UUID) {
        guard timelines[timelineID] != nil else { return }
        attachmentIntents[timelineID, default: []].removeAll { $0.workspaceID == workspaceID }
    }
    public func unresolvedWorkspaceIDs() -> [UUID] {
        workspaces.values.filter { !$0.isAvailable }.map(\.id).sorted { $0.uuidString < $1.uuidString }
    }

    /// Resolves a configured lazy reference only when its URI matches, or
    /// records an unambiguous dynamically discovered Workspace.
    @discardableResult
    public func resolveLazyWorkspace(id: UUID, uri: String, toolIDs: [String]) throws -> Bool {
        guard let current = workspaces[id] else {
            workspaces[id] = .init(id: id, uri: uri, status: .available, toolIDs: toolIDs.sorted())
            return true
        }
        guard current.uri == uri else { return false }
        workspaces[id] = .init(id: id, uri: current.uri, status: .available, toolIDs: toolIDs.sorted())
        return true
    }

    /// Updates effective runtime status while retaining the record and its
    /// Timeline attachment intent.
    @discardableResult
    public func setWorkspaceStatus(id: UUID, status: WorkspaceEffectiveStatus) -> Bool {
        guard let current = workspaces[id] else { return false }
        workspaces[id] = .init(id: id, uri: current.uri, status: status, toolIDs: current.toolIDs)
        return true
    }

    private func sortedTimelineRecords() -> [TimelineRecord] {
        timelines.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
