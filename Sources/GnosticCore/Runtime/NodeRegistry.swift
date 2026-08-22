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

    public struct WorkspaceAttachmentTarget: Sendable, Equatable {
        public let timelineID: UUID
        public let ascendantID: UUID

        public init(timelineID: UUID, ascendantID: UUID) {
            self.timelineID = timelineID
            self.ascendantID = ascendantID
        }
    }

    /// The authoritative input used to reconstruct one Ascendant backend.
    ///
    /// The revision and the Timeline configurations are captured by the same
    /// actor turn. A reconstruction must compare the revision again before it
    /// installs its candidate so a backend cannot replace a newer registry
    /// projection.
    public struct BackendReconstructionState: Sendable, Equatable {
        public let revision: UInt64
        public let timelines: [NodeManifest.Timeline]

        public init(revision: UInt64, timelines: [NodeManifest.Timeline]) {
            self.revision = revision
            self.timelines = timelines
        }
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
    private var timelineMetadata: [UUID: (kind: String, flags: Set<String>)]
    private var backendRevisions: [UUID: UInt64]
    private var backendLeases: [UUID: UUID]
    private var lifecycleGeneration: UInt64 = 0

    public init(
        plan: NodeLaunchPlan,
        operatedTimelines: [AscendantRuntimeTimeline],
        backendLeases: [UUID: UUID] = [:]
    ) throws {
        nodeID = plan.nodeID
        configuredAscendantIDs = plan.ascendants.map(\.id)
        ascendantIDs = Set(configuredAscendantIDs)
        configuredWorkspaceIDs = plan.workspaces.map(\.id)
        timelines = [:]
        workspaces = [:]
        timelineMetadata = [:]
        backendRevisions = [:]
        self.backendLeases = backendLeases
        var intents: [UUID: [NodeManifest.WorkspaceAttachment]] = [:]
        for timeline in plan.timelines {
            intents[timeline.id] = timeline.attachments
            timelineMetadata[timeline.id] = (timeline.kind, timeline.flags)
            if let ascendantID = timeline.operatingAscendantID {
                backendRevisions[ascendantID] = 0
            }
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
                guard value.attachedAscendantID == operatorID else {
                    throw NodeRuntimeError.unknownAscendant(value.attachedAscendantID ?? operatorID)
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
                timeline = .init(id: configuration.id, title: configuration.title, attachedWorkspaceIDs: configuration.attachments.map(\.workspaceID), attachedAscendantID: nil, isArchived: false, isPrivate: false, createdAt: now, updatedAt: now)
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
        return .init(nodeID: nodeID, ascendantIDs: configuredAscendantIDs, timelineIDs: records.map(\.id), operatedTimelineIDs: records.compactMap { $0.operatorID == nil ? nil : $0.id }, workspaceIDs: configuredWorkspaceIDs + workspaces.values.filter { !configuredWorkspaceIDs.contains($0.id) }.map(\.id).sorted { $0.uuidString < $1.uuidString })
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

    /// Replaces the lease accepted by canonical mutation methods. Updating the
    /// lease and checking it both happen on this actor, closing the suspension
    /// window between a service-side backend check and a registry write.
    func setLifecycleGeneration(_ generation: UInt64) {
        lifecycleGeneration = max(lifecycleGeneration, generation)
    }

    func fenceBackendLeases(at generation: UInt64) {
        lifecycleGeneration = max(lifecycleGeneration, generation)
        backendLeases.removeAll()
    }

    @discardableResult
    func activateBackendLease(_ lease: UUID, for ascendantID: UUID, generation: UInt64) -> Bool {
        guard lifecycleGeneration == generation else { return false }
        backendLeases[ascendantID] = lease
        return true
    }

    @discardableResult
    func resolveLazyWorkspace(
        id: UUID,
        uri: String,
        toolIDs: [String],
        generation: UInt64
    ) throws -> Bool {
        guard lifecycleGeneration == generation else { throw NodeRuntimeError.notRunning }
        return try resolveLazyWorkspace(id: id, uri: uri, toolIDs: toolIDs)
    }

    public func invalidateBackendLease(for ascendantID: UUID) {
        backendLeases.removeValue(forKey: ascendantID)
    }

    public func registerRuntimeTimeline(title: String, ascendantID: UUID) throws -> TimelineRecord {
        guard ascendantIDs.contains(ascendantID) else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
        let now = Date()
        let timeline = AscendantRuntimeTimeline(id: UUID.makeVersion4(), title: title, attachedWorkspaceIDs: [], attachedAscendantID: ascendantID, isArchived: false, isPrivate: false, createdAt: now, updatedAt: now)
        let record = TimelineRecord(timeline: timeline, operatorID: ascendantID, provenance: .runtime)
        timelines[timeline.id] = record
        attachmentIntents[timeline.id] = []
        timelineMetadata[timeline.id] = ("timeline", [])
        bumpRevision(for: ascendantID)
        return record
    }

    public func removeRuntimeTimeline(id: UUID) {
        guard let record = timelines[id], record.provenance == .runtime else { return }
        timelines.removeValue(forKey: id)
        attachmentIntents.removeValue(forKey: id)
        timelineMetadata.removeValue(forKey: id)
        if let ascendantID = record.operatorID { bumpRevision(for: ascendantID) }
    }

    /// Registers an adapter-created runtime timeline under an already selected operator.
    public func registerRuntimeTimeline(
        _ timeline: AscendantRuntimeTimeline,
        ascendantID: UUID,
        backendLease: UUID? = nil
    ) throws -> TimelineRecord {
        try requireBackendLease(backendLease, for: ascendantID)
        guard ascendantIDs.contains(ascendantID) else { throw NodeRuntimeError.unknownAscendant(ascendantID) }
        guard timelines[timeline.id] == nil else { throw NodeRuntimeError.missingTimeline(timeline.id) }
        guard timeline.attachedAscendantID == ascendantID else { throw NodeRuntimeError.unknownAscendant(timeline.attachedAscendantID ?? ascendantID) }
        let record = TimelineRecord(timeline: timeline, operatorID: ascendantID, provenance: .runtime)
        timelines[timeline.id] = record
        attachmentIntents[timeline.id] = []
        timelineMetadata[timeline.id] = ("timeline", [])
        bumpRevision(for: ascendantID)
        return record
    }

    func registerRuntimeTimeline(
        _ timeline: AscendantRuntimeTimeline,
        ascendantID: UUID,
        backendLease: UUID?,
        generation: UInt64
    ) throws -> TimelineRecord {
        guard lifecycleGeneration == generation else { throw NodeRuntimeError.notRunning }
        return try registerRuntimeTimeline(timeline, ascendantID: ascendantID, backendLease: backendLease)
    }

    /// Replaces only an existing timeline's projection after the adapter has accepted a mutation.
    public func replaceTimeline(_ timeline: AscendantRuntimeTimeline) throws -> TimelineRecord {
        guard let current = timelines[timeline.id] else { throw NodeRuntimeError.missingTimeline(timeline.id) }
        guard timeline.attachedAscendantID == current.operatorID else { throw NodeRuntimeError.noOperatingAscendant(timeline.id) }
        let record = TimelineRecord(timeline: timeline, operatorID: current.operatorID, provenance: current.provenance)
        timelines[timeline.id] = record
        if let ascendantID = current.operatorID { bumpRevision(for: ascendantID) }
        return record
    }

    /// Atomically verifies backend ownership and commits one Timeline plus its
    /// optional attachment-intent mutation. A retired backend can therefore
    /// never write canonical state after its lease changes.
    public func commitBackendTimeline(
        _ timeline: AscendantRuntimeTimeline,
        ascendantID: UUID,
        backendLease: UUID?,
        upserting attachment: NodeManifest.WorkspaceAttachment? = nil,
        removingWorkspaceID: UUID? = nil
    ) throws -> TimelineRecord {
        try requireBackendLease(backendLease, for: ascendantID)
        guard let current = timelines[timeline.id] else { throw NodeRuntimeError.missingTimeline(timeline.id) }
        guard current.operatorID == ascendantID,
              timeline.attachedAscendantID == ascendantID else {
            throw NodeRuntimeError.noOperatingAscendant(timeline.id)
        }
        let record = TimelineRecord(timeline: timeline, operatorID: ascendantID, provenance: current.provenance)
        timelines[timeline.id] = record
        if let attachment {
            var intents = attachmentIntents[timeline.id] ?? []
            intents.removeAll { $0.workspaceID == attachment.workspaceID }
            intents.append(attachment)
            attachmentIntents[timeline.id] = intents
        }
        if let removingWorkspaceID {
            attachmentIntents[timeline.id, default: []].removeAll { $0.workspaceID == removingWorkspaceID }
        }
        bumpRevision(for: ascendantID)
        return record
    }

    func commitBackendTimeline(
        _ timeline: AscendantRuntimeTimeline,
        ascendantID: UUID,
        backendLease: UUID?,
        generation: UInt64,
        upserting attachment: NodeManifest.WorkspaceAttachment? = nil,
        removingWorkspaceID: UUID? = nil
    ) throws -> TimelineRecord {
        guard lifecycleGeneration == generation else { throw NodeRuntimeError.notRunning }
        return try commitBackendTimeline(
            timeline,
            ascendantID: ascendantID,
            backendLease: backendLease,
            upserting: attachment,
            removingWorkspaceID: removingWorkspaceID
        )
    }

    /// Commits a Timeline replacement and emits its required projection as one
    /// actor-isolated transition. A projection failure restores the prior
    /// authoritative record before the error escapes.
    public func replaceTimeline(
        _ timeline: AscendantRuntimeTimeline,
        projecting: @MainActor @Sendable (TimelineRecord) throws -> Void
    ) async throws -> TimelineRecord {
        guard let previous = timelines[timeline.id] else { throw NodeRuntimeError.missingTimeline(timeline.id) }
        guard timeline.attachedAscendantID == previous.operatorID else { throw NodeRuntimeError.noOperatingAscendant(timeline.id) }
        let record = TimelineRecord(timeline: timeline, operatorID: previous.operatorID, provenance: previous.provenance)
        timelines[timeline.id] = record
        do {
            try await projecting(record)
            if let ascendantID = previous.operatorID { bumpRevision(for: ascendantID) }
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
        if let ascendantID = timelines[timelineID]?.operatorID { bumpRevision(for: ascendantID) }
    }

    /// Removes one Workspace attachment intent after a backend has accepted a
    /// detach operation.
    public func removeAttachmentIntent(workspaceID: UUID, from timelineID: UUID) {
        guard timelines[timelineID] != nil else { return }
        attachmentIntents[timelineID, default: []].removeAll { $0.workspaceID == workspaceID }
        if let ascendantID = timelines[timelineID]?.operatorID { bumpRevision(for: ascendantID) }
    }

    /// Captures the current Gnostic-owned Timeline state and attachment intent
    /// for one Ascendant atomically. Runtime-created Timelines and explicit
    /// post-launch attachment mutations are therefore included in a backend's
    /// next reconstruction.
    public func backendReconstructionState(for ascendantID: UUID) -> BackendReconstructionState {
        let configurations = timelines.values
            .filter { $0.operatorID == ascendantID }
            .map { record in
                let metadata = timelineMetadata[record.id] ?? ("timeline", [])
                return NodeManifest.Timeline(
                    id: record.id,
                    title: record.timeline.title,
                    kind: metadata.kind,
                    operatingAscendantID: ascendantID,
                    flags: metadata.flags,
                    attachments: attachmentIntents[record.id] ?? []
                )
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return .init(revision: backendRevisions[ascendantID] ?? 0, timelines: configurations)
    }

    /// Returns only the current revision for callers that already captured a
    /// reconstruction state and need a cheap staleness check.
    public func backendRevision(for ascendantID: UUID) -> UInt64 {
        backendRevisions[ascendantID] ?? 0
    }

    /// Returns the current runtime targets for a network Workspace intent.
    /// This includes process-only Timelines and excludes stale launch-plan
    /// relationships that were explicitly detached after startup.
    public func attachmentTargets(for workspaceID: UUID) -> [WorkspaceAttachmentTarget] {
        timelines.values.compactMap { record in
            guard let ascendantID = record.operatorID,
                  attachmentIntents[record.id]?.contains(where: {
                      $0.workspaceID == workspaceID && $0.scope == .network
                  }) == true else { return nil }
            return WorkspaceAttachmentTarget(timelineID: record.id, ascendantID: ascendantID)
        }
        .sorted {
            ($0.timelineID.uuidString, $0.ascendantID.uuidString)
                < ($1.timelineID.uuidString, $1.ascendantID.uuidString)
        }
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

    @discardableResult
    func setWorkspaceStatus(
        id: UUID,
        status: WorkspaceEffectiveStatus,
        generation: UInt64
    ) -> Bool {
        guard lifecycleGeneration == generation else { return false }
        _ = setWorkspaceStatus(id: id, status: status)
        return true
    }

    private func sortedTimelineRecords() -> [TimelineRecord] {
        timelines.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func bumpRevision(for ascendantID: UUID) {
        backendRevisions[ascendantID, default: 0] &+= 1
    }

    private func requireBackendLease(_ lease: UUID?, for ascendantID: UUID) throws {
        guard let lease else { return }
        guard backendLeases[ascendantID] == lease else { throw NodeRuntimeError.notRunning }
    }
}
