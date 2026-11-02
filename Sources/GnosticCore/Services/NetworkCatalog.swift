// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticProtocol

public actor NetworkCatalog {
    private static let anonymousProviderID = "<unknown-provider>"
    private static let corePropertyNames: Set<String> = [
        "objectId", "coreType", "objectType", "name", "externalId", "parentObjectId", "locationId", "isDeactivated",
    ]
    private static let knownPropertyNames: [String: Set<String>] = [
        GnosticObjectType.runtimeInstance: ["protocolMajor", "runtimeID", "nodeID", "runtimeKind", "runtimeVersion", "launchFingerprint", "health", "rawCapabilities"],
        GnosticObjectType.timeline: ["protocolMajor", "title", "isArchived", "isPrivate", "runtimeInstanceID", "attachedWorkspaceIDs", "nodeID", "createdAt", "updatedAt"],
        GnosticObjectType.workspace: ["protocolMajor", "uri", "isAvailable", "trustLevel", "status", "effectiveStatus", "tools", "toolsComplete", "createdAt"],
        GnosticObjectType.workspaceTool: ["protocolMajor", "workspaceID", "toolID", "toolName", "toolDescription", "parametersSchema", "usageExample", "requiresPermission", "page"],
    ]

    private var entries: [UUID: [String: NetworkCatalogEntry]] = [:]
    private var workspaceTools: [UUID: [String: [String: GnosticWorkspaceTool]]] = [:]
    private var completeWorkspaceToolCatalogs: [UUID: Set<String>] = [:]
    private var workspaceToolCatalogEpochs: [UUID: [String: UInt64]] = [:]
    private var workspaceAdvertisementGenerations: [UUID: [String: UInt64]] = [:]
    private var workspaceToolOwners: [UUID: (workspaceID: UUID, providerID: String, toolID: String)] = [:]
    private var providerEvictionContinuations: [UUID: AsyncStream<String>.Continuation] = [:]
    private var changeContinuations: [UUID: AsyncStream<NetworkCatalogChange>.Continuation] = [:]

    /// Creates an empty catalog.
    public init() {}

    /// Observes every advertisement, deadvertisement, and provider eviction
    /// ingested by this catalog.
    ///
    /// The stream is latest-biased and bounded at 64 pending changes; slow
    /// observers drop the oldest pending change instead of stalling ingest.
    /// It does not end with the catalog, so callers cancel their iteration at
    /// shutdown.
    ///
    /// - Returns: A stream of catalog changes in ingest order.
    public func changes() -> AsyncStream<NetworkCatalogChange> {
        let pair = AsyncStream<NetworkCatalogChange>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        changeContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeChangeContinuation(id) }
        }
        return pair.stream
    }

    private func removeChangeContinuation(_ id: UUID) {
        changeContinuations[id] = nil
    }

    private func emitChange(_ change: NetworkCatalogChange) {
        for continuation in changeContinuations.values {
            continuation.yield(change)
        }
    }

    /// Observes providers removed by a lifecycle identity deadvertisement.
    ///
    /// The stream yields the evicted provider identity each time an identity
    /// deadvertisement removes that provider's catalog state. It does not end
    /// with the catalog; callers cancel their iteration at shutdown.
    public func providerEvictionStream() -> AsyncStream<String> {
        let pair = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        providerEvictionContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeProviderEvictionContinuation(id) }
        }
        return pair.stream
    }

    private func removeProviderEvictionContinuation(_ id: UUID) {
        providerEvictionContinuations[id] = nil
    }

    /// Ingests an advertisement or readvertisement for a supported Gnostic object type.
    ///
    /// - Parameter event: The immutable Axoloty advertisement snapshot.
    public func ingest(_ event: AdvertiseEventSnapshot) {
        ingestAdvertisement(event, isLiveAdvertisement: true)
    }

    private func ingestAdvertisement(_ event: AdvertiseEventSnapshot, isLiveAdvertisement: Bool) {
        let snapshot = event.object
        guard GnosticObjectType.isSupported(snapshot.objectType),
              let objectID = UUID(uuidString: snapshot.objectId) else {
            return
        }

        let providerID = event.sourceId ?? Self.anonymousProviderID
        if Self.isMetadataOnly(snapshot),
           entries[objectID]?[providerID]?.isProtocolCompatible == true {
            // Axoloty may deliver a metadata-only advertisement before or
            // after a full resolve response. Never let that transport
            // projection evict a provider-scoped, protocol-valid object.
            return
        }
        if snapshot.objectType == GnosticObjectType.workspace {
            if isLiveAdvertisement {
                advanceWorkspaceAdvertisementGeneration(workspaceID: objectID, providerID: providerID)
            }
            advanceWorkspaceToolCatalogGeneration(workspaceID: objectID, providerID: providerID)
            removeWorkspaceToolPages(workspaceID: objectID, providerID: providerID)
            completeWorkspaceToolCatalogs[objectID]?.remove(providerID)
            if completeWorkspaceToolCatalogs[objectID]?.isEmpty == true {
                completeWorkspaceToolCatalogs[objectID] = nil
            }
        }
        let protocolMajor = Self.protocolMajor(from: snapshot)
        let isProtocolCompatible = GnosticProtocol.isCompatible(protocolMajor)
        let knownProperties = knownProperties(from: snapshot)
        let dynamicProperties = dynamicProperties(from: snapshot)
        let workspaceTool = workspaceTool(from: snapshot)
        if snapshot.objectType == GnosticObjectType.workspaceTool,
           let workspaceTool,
           let payload = snapshot.payload,
            let toolObject = try? JSONDecoder().decode(GnosticWorkspaceToolObject.self, from: Data(payload.utf8)) {
            workspaceTools[toolObject.workspaceID, default: [:]][providerID, default: [:]][workspaceTool.id] = workspaceTool
            workspaceToolOwners[objectID] = (toolObject.workspaceID, providerID, workspaceTool.id)
        }
        let workspace = workspaceDescriptor(from: snapshot, id: objectID, providerID: providerID)
        let effectiveStatus = !isProtocolCompatible && snapshot.objectType == GnosticObjectType.workspace
            ? .unsupported
            : workspace?.effectiveStatus
            ?? (snapshot.objectType == GnosticObjectType.workspace ? .unsupported : nil)
        let entry = NetworkCatalogEntry(
            objectID: objectID,
            objectType: snapshot.objectType,
            protocolMajor: protocolMajor,
            isProtocolCompatible: isProtocolCompatible,
            providerID: providerID,
            name: snapshot.name,
            knownProperties: knownProperties,
            dynamicProperties: dynamicProperties,
            workspace: workspace,
            effectiveStatus: effectiveStatus,
            workspaceTool: workspaceTool
        )
        entries[objectID, default: [:]][providerID] = entry
        emitChange(.advertised(entry))
    }

    /// Ingests a resolved object returned by an active discover request.
    ///
    /// Resolve responses carry the same immutable object snapshot as an
    /// advertisement, so they share the catalog's provider-scoped projection
    /// and replacement semantics.
    public func ingest(_ event: ResponseEventSnapshot) {
        let snapshots = event.objects ?? event.object.map { [$0] } ?? []
        for snapshot in snapshots {
            let object = Self.hydrateResponseObject(snapshot, from: event.payload)
            ingestAdvertisement(AdvertiseEventSnapshot(sourceId: event.sourceId, object: object), isLiveAdvertisement: false)
        }
    }

    /// Captures live Workspace-advertisement generations before a correlated
    /// Resolve sweep. Axoloty Resolve payloads have no revision field, so a
    /// later-observed live advertisement takes precedence over an older
    /// in-flight snapshot from that sweep.
    func workspaceAdvertisementSnapshot() -> [UUID: [String: UInt64]] {
        workspaceAdvertisementGenerations
    }

    /// Ingests Resolve snapshots unless a live Workspace advertisement from
    /// that provider arrived after the correlated sweep started.
    func ingestResolutionResponse(
        _ event: ResponseEventSnapshot,
        startedAt snapshot: [UUID: [String: UInt64]]
    ) {
        let providerID = event.sourceId ?? Self.anonymousProviderID
        let providerKey = providerID.lowercased()
        let snapshots = event.objects ?? event.object.map { [$0] } ?? []
        for rawSnapshot in snapshots {
            let object = Self.hydrateResponseObject(rawSnapshot, from: event.payload)
            if object.objectType == GnosticObjectType.workspace,
               let workspaceID = UUID(uuidString: object.objectId) {
                let startedGeneration = snapshot[workspaceID]?[providerKey] ?? 0
                let currentGeneration = workspaceAdvertisementGenerations[workspaceID]?[providerKey] ?? 0
                guard startedGeneration == currentGeneration else { continue }
            }
            ingestAdvertisement(AdvertiseEventSnapshot(sourceId: providerID, object: object), isLiveAdvertisement: false)
        }
    }

    func workspaceToolCatalogGenerations(id: UUID) -> [String: UInt64] {
        guard let providers = entries[id] else { return [:] }
        var generations: [String: UInt64] = [:]
        for entry in providers.values where entry.objectType == GnosticObjectType.workspace {
            let key = entry.providerID.lowercased()
            generations[key] = workspaceToolCatalogEpochs[id]?[key] ?? 0
        }
        return generations
    }

    func ingestWorkspaceToolQueryResponse(
        _ event: ResponseEventSnapshot,
        workspaceID: UUID,
        providerID: String,
        generation: UInt64
    ) -> Bool {
        let providerKey = providerID.lowercased()
        guard (workspaceToolCatalogEpochs[workspaceID]?[providerKey] ?? 0) == generation,
              entries[workspaceID]?[providerID]?.objectType == GnosticObjectType.workspace,
              event.sourceId?.caseInsensitiveCompare(providerID) == .orderedSame else { return false }
        let snapshots = event.objects ?? event.object.map { [$0] } ?? []
        let hydrated = snapshots.map { Self.hydrateResponseObject($0, from: event.payload) }
        guard hydrated.allSatisfy({ snapshot in
            guard snapshot.objectType == GnosticObjectType.workspaceTool,
                  let payload = snapshot.payload,
                  let object = try? JSONDecoder().decode(GnosticWorkspaceToolObject.self, from: Data(payload.utf8))
            else { return false }
            return object.workspaceID == workspaceID
        }) else { return false }
        for snapshot in hydrated {
            ingest(AdvertiseEventSnapshot(sourceId: providerID, object: snapshot))
        }
        return true
    }

    /// Ingests a deadvertisement and removes only entries owned by its provider.
    ///
    /// A lifecycle identity deadvertisement names the provider's own identity in
    /// its `objectIds`. That event is not scoped to a discoverable Gnostic
    /// object, so it evicts every catalog entry, workspace tool, and ownership
    /// record for that provider instead of the listed object IDs. A per-object
    /// deadvertisement leaves the rest of the provider's state untouched.
    ///
    /// - Parameter event: The immutable Axoloty deadvertisement snapshot.
    public func ingest(_ event: DeadvertiseEventSnapshot) {
        let providerID = event.sourceId ?? Self.anonymousProviderID
        if event.objectIds.contains(where: { $0.caseInsensitiveCompare(providerID) == .orderedSame }) {
            evictProvider(providerID)
            return
        }
        for rawID in event.objectIds {
            guard let objectID = UUID(uuidString: rawID) else { continue }
            if entries[objectID]?[providerID]?.objectType == GnosticObjectType.workspace {
                advanceWorkspaceAdvertisementGeneration(workspaceID: objectID, providerID: providerID)
                advanceWorkspaceToolCatalogGeneration(workspaceID: objectID, providerID: providerID)
                removeWorkspaceToolPages(workspaceID: objectID, providerID: providerID)
                completeWorkspaceToolCatalogs[objectID]?.remove(providerID)
                if completeWorkspaceToolCatalogs[objectID]?.isEmpty == true {
                    completeWorkspaceToolCatalogs[objectID] = nil
                }
                for toolObjectID in Array(workspaceToolOwners.keys)
                    where workspaceToolOwners[toolObjectID]?.workspaceID == objectID
                        && workspaceToolOwners[toolObjectID]?.providerID == providerID {
                    workspaceToolOwners[toolObjectID] = nil
                }
            }
            if let owner = workspaceToolOwners.removeValue(forKey: objectID) {
                workspaceTools[owner.workspaceID]?[owner.providerID]?[owner.toolID] = nil
                if workspaceTools[owner.workspaceID]?[owner.providerID]?.isEmpty == true {
                    workspaceTools[owner.workspaceID]?[owner.providerID] = nil
                }
                if workspaceTools[owner.workspaceID]?.isEmpty == true {
                    workspaceTools[owner.workspaceID] = nil
                }
            }
            entries[objectID]?[providerID] = nil
            if entries[objectID]?.isEmpty == true {
                entries[objectID] = nil
            }
            emitChange(.deadvertised(objectID: objectID, providerID: providerID))
        }
    }

    /// Removes every record owned by one provider and notifies observers.
    private func evictProvider(_ providerID: String) {
        for (workspaceID, providers) in Array(entries) where providers[providerID]?.objectType == GnosticObjectType.workspace {
            advanceWorkspaceAdvertisementGeneration(workspaceID: workspaceID, providerID: providerID)
            advanceWorkspaceToolCatalogGeneration(workspaceID: workspaceID, providerID: providerID)
            removeWorkspaceToolPages(workspaceID: workspaceID, providerID: providerID)
        }
        for objectID in Array(entries.keys) where entries[objectID]?[providerID] != nil {
            entries[objectID]?[providerID] = nil
            if entries[objectID]?.isEmpty == true {
                entries[objectID] = nil
            }
        }
        for workspaceID in Array(workspaceTools.keys) where workspaceTools[workspaceID]?[providerID] != nil {
            workspaceTools[workspaceID]?[providerID] = nil
            if workspaceTools[workspaceID]?.isEmpty == true {
                workspaceTools[workspaceID] = nil
            }
        }
        for workspaceID in Array(completeWorkspaceToolCatalogs.keys) {
            completeWorkspaceToolCatalogs[workspaceID]?.remove(providerID)
            if completeWorkspaceToolCatalogs[workspaceID]?.isEmpty == true {
                completeWorkspaceToolCatalogs[workspaceID] = nil
            }
        }
        for objectID in Array(workspaceToolOwners.keys) where workspaceToolOwners[objectID]?.providerID == providerID {
            workspaceToolOwners[objectID] = nil
        }
        for continuation in providerEvictionContinuations.values {
            continuation.yield(providerID)
        }
        emitChange(.providerEvicted(providerID))
    }

    /// Returns a single provider-scoped object record.
    ///
    /// - Parameters:
    ///   - id: The object identifier.
    ///   - providerID: The provider identity.
    /// - Returns: The retained object record, if present.
    public func object(id: UUID, providerID: String) -> NetworkCatalogEntry? {
        guard let entry = entries[id]?[providerID] else { return nil }
        return mergedWorkspaceEntry(entry)
    }

    /// Returns every currently advertised object, preserving provider scope for inspection.
    public func networkObjects(includeIncompatible: Bool = false) -> [NetworkCatalogEntry] {
        entries.values
            .flatMap { $0.values }
            .map(mergedWorkspaceEntry)
            .filter { includeIncompatible || $0.isProtocolCompatible }
            .sorted {
                ($0.objectID.uuidString, $0.providerID) < ($1.objectID.uuidString, $1.providerID)
            }
    }

    /// Returns a workspace descriptor with query-only tools merged into its
    /// compact advertised summary.
    public func workspaceDescriptor(id: UUID, providerID: String) -> NetworkWorkspaceDescriptor? {
        entries[id]?[providerID]?.workspace.map { descriptor in
            mergedWorkspaceDescriptor(descriptor, id: id, providerID: providerID)
        }
    }

    /// Records the provider's explicit terminal empty page for its tool query.
    func markWorkspaceToolCatalogComplete(id: UUID, providerID: String, generation: UInt64) -> Bool {
        let providerKey = providerID.lowercased()
        guard entries[id]?[providerID]?.workspace != nil,
              (workspaceToolCatalogEpochs[id]?[providerKey] ?? 0) == generation else { return false }
        completeWorkspaceToolCatalogs[id, default: []].insert(providerID)
        return true
    }

    private func advanceWorkspaceToolCatalogGeneration(workspaceID: UUID, providerID: String) {
        let key = providerID.lowercased()
        workspaceToolCatalogEpochs[workspaceID, default: [:]][key, default: 0] &+= 1
    }

    private func advanceWorkspaceAdvertisementGeneration(workspaceID: UUID, providerID: String) {
        let key = providerID.lowercased()
        workspaceAdvertisementGenerations[workspaceID, default: [:]][key, default: 0] &+= 1
    }

    private func removeWorkspaceToolPages(workspaceID: UUID, providerID: String) {
        workspaceTools[workspaceID]?[providerID] = nil
        if workspaceTools[workspaceID]?.isEmpty == true { workspaceTools[workspaceID] = nil }
        for objectID in Array(workspaceToolOwners.keys)
            where workspaceToolOwners[objectID]?.workspaceID == workspaceID
                && workspaceToolOwners[objectID]?.providerID == providerID {
            workspaceToolOwners[objectID] = nil
            entries[objectID]?[providerID] = nil
            if entries[objectID]?.isEmpty == true { entries[objectID] = nil }
        }
    }

    /// Returns whether a workspace can be attached without ambiguity.
    ///
    /// - Parameter id: The workspace identifier.
    /// - Returns: The workspace attachment status.
    public func workspaceAttachmentStatus(id: UUID) -> WorkspaceAttachmentStatus {
        let workspaceEntries = entries[id]?.values.filter { $0.objectType == GnosticObjectType.workspace } ?? []
        guard !workspaceEntries.isEmpty else { return .unavailable }
        let compatibleEntries = workspaceEntries.filter(\.isProtocolCompatible)
        guard !compatibleEntries.isEmpty else {
            return workspaceEntries.count == 1 ? .unsupported : .ambiguous
        }
        guard compatibleEntries.count == 1, let entry = compatibleEntries.first else { return .ambiguous }
        guard let workspace = entry.workspace else { return .malformed }
        switch workspace.effectiveStatus {
        case .available:
            return .available(providerID: entry.providerID, uri: workspace.uri)
        case .unavailable:
            return .unavailable
        case .unsupported:
            return .unsupported
        }
    }

    /// Whether one currently catalogued Timeline advertisement includes a Workspace attachment.
    /// Ambiguous, incompatible, missing, and archived Timelines fail closed.
    public func isWorkspaceAttached(_ workspaceID: UUID, to timelineID: UUID) -> Bool {
        guard let owner = currentTimelineOwner(id: timelineID) else { return false }
        return Self.attaches(workspaceID, to: owner)
    }

    /// Authorizes one remote Workspace invocation against a single current
    /// catalog state. Caller identity, unique Timeline ownership, and the
    /// Timeline's Workspace attachment are checked synchronously in this actor
    /// turn so lifecycle ingestion cannot replace the owner between checks.
    func authorizesWorkspaceCall(
        sourceID: String,
        workspaceID: UUID,
        to timelineID: UUID
    ) -> Bool {
        guard let callerID = UUID(uuidString: sourceID),
              let owner = currentTimelineOwner(id: timelineID),
              let ownerID = UUID(uuidString: owner.providerID),
              callerID == ownerID,
              Self.attaches(workspaceID, to: owner) else {
            return false
        }
        return true
    }

    private static func attaches(_ workspaceID: UUID, to owner: NetworkCatalogEntry) -> Bool {
        guard case let .array(attached)? = owner.knownProperties["attachedWorkspaceIDs"] else { return false }
        return attached.contains { value in
            guard case let .string(rawID) = value else { return false }
            return UUID(uuidString: rawID) == workspaceID
        }
    }

    /// The provider that currently owns a Timeline, or `nil` when the catalog
    /// has no single compatible, non-archived owner.
    public func timelineOwnerID(id: UUID) -> String? {
        currentTimelineOwner(id: id)?.providerID
    }

    /// The sole compatible, non-archived current advertisement for a Timeline.
    private func currentTimelineOwner(id: UUID) -> NetworkCatalogEntry? {
        guard let candidates = entries[id] else { return nil }
        let owners = candidates.values.filter { $0.objectType == GnosticObjectType.timeline }
        guard owners.count == 1, let owner = owners.first, owner.isProtocolCompatible else { return nil }
        if case .bool(true)? = owner.knownProperties["isArchived"] { return nil }
        return owner
    }

    private func dynamicProperties(from snapshot: CoatyObjectSnapshot) -> [String: NetworkDynamicValue] {
        guard let payload = snapshot.payload,
              let fields = try? JSONDecoder().decode([String: NetworkDynamicValue].self, from: Data(payload.utf8)) else {
            return [:]
        }
        let known = Self.corePropertyNames.union(Self.knownPropertyNames[snapshot.objectType] ?? [])
        return fields.filter { !known.contains($0.key) }
    }

    private static func protocolMajor(from snapshot: CoatyObjectSnapshot) -> Int? {
        guard let payload = snapshot.payload,
              let fields = try? JSONDecoder().decode([String: NetworkDynamicValue].self, from: Data(payload.utf8)) else {
            return nil
        }
        switch fields["protocolMajor"] {
        case let .integer(value): return Int(exactly: value)
        case let .unsignedInteger(value): return value <= UInt64(Int.max) ? Int(value) : nil
        default: return nil
        }
    }

    private static func isMetadataOnly(_ snapshot: CoatyObjectSnapshot) -> Bool {
        guard let payload = snapshot.payload,
              let fields = try? JSONDecoder().decode([String: NetworkDynamicValue].self, from: Data(payload.utf8)) else {
            return true
        }
        return fields.keys.allSatisfy { corePropertyNames.contains($0) }
    }

    private static func hydrateResponseObject(_ snapshot: CoatyObjectSnapshot, from payload: String) -> CoatyObjectSnapshot {
        guard isMetadataOnly(snapshot),
              let envelope = try? JSONDecoder().decode([String: NetworkDynamicValue].self, from: Data(payload.utf8)),
              case let .object(fields) = envelope["object"],
              let objectData = try? JSONEncoder().encode(NetworkDynamicValue.object(fields)),
              let objectPayload = String(data: objectData, encoding: .utf8) else {
            return snapshot
        }
        return snapshot.withPayload(objectPayload)
    }

    private func knownProperties(from snapshot: CoatyObjectSnapshot) -> [String: NetworkDynamicValue] {
        guard let payload = snapshot.payload,
              let fields = try? JSONDecoder().decode([String: NetworkDynamicValue].self, from: Data(payload.utf8)) else {
            return [:]
        }
        let known = Self.knownPropertyNames[snapshot.objectType] ?? []
        return fields.filter { known.contains($0.key) }
    }

    private func workspaceDescriptor(from snapshot: CoatyObjectSnapshot, id: UUID, providerID: String) -> NetworkWorkspaceDescriptor? {
        guard snapshot.objectType == GnosticObjectType.workspace,
              let payload = snapshot.payload,
              let object = try? JSONDecoder().decode(GnosticWorkspaceObject.self, from: Data(payload.utf8)),
              object.objectId.string == id.uuidString.lowercased() else {
            return nil
        }
        return mergedWorkspaceDescriptor(NetworkWorkspaceDescriptor(
            id: id,
            uri: object.uri,
            isAvailable: object.isAvailable,
            trustLevel: object.trustLevel,
            status: object.status,
            effectiveStatus: object.effectiveStatus,
            tools: object.tools,
            toolsComplete: object.toolsComplete,
            createdAt: object.createdAt
        ), id: id, providerID: providerID)
    }

    private func workspaceTool(from snapshot: CoatyObjectSnapshot) -> GnosticWorkspaceTool? {
        guard snapshot.objectType == GnosticObjectType.workspaceTool,
              let payload = snapshot.payload,
              let object = try? JSONDecoder().decode(GnosticWorkspaceToolObject.self, from: Data(payload.utf8)) else {
            return nil
        }
        return object.tool
    }

    private func mergedWorkspaceEntry(_ entry: NetworkCatalogEntry) -> NetworkCatalogEntry {
        guard entry.objectType == GnosticObjectType.workspace,
              let workspace = entry.workspace else { return entry }
        return NetworkCatalogEntry(
            objectID: entry.objectID,
            objectType: entry.objectType,
            protocolMajor: entry.protocolMajor,
            isProtocolCompatible: entry.isProtocolCompatible,
            providerID: entry.providerID,
            name: entry.name,
            knownProperties: entry.knownProperties,
            dynamicProperties: entry.dynamicProperties,
            workspace: mergedWorkspaceDescriptor(workspace, id: entry.objectID, providerID: entry.providerID),
            effectiveStatus: entry.effectiveStatus,
            workspaceTool: entry.workspaceTool
        )
    }

    private func mergedWorkspaceDescriptor(_ descriptor: NetworkWorkspaceDescriptor, id: UUID, providerID: String) -> NetworkWorkspaceDescriptor {
        let queried = workspaceTools[id]?[providerID]?.values.sorted { $0.id < $1.id } ?? []
        let known = Set(descriptor.tools.map(\.id))
        return NetworkWorkspaceDescriptor(
            id: descriptor.id,
            uri: descriptor.uri,
            isAvailable: descriptor.isAvailable,
            trustLevel: descriptor.trustLevel,
            status: descriptor.status,
            effectiveStatus: descriptor.effectiveStatus,
            tools: descriptor.tools + queried.filter { !known.contains($0.id) },
            toolsComplete: descriptor.toolsComplete || completeWorkspaceToolCatalogs[id]?.contains(providerID) == true,
            createdAt: descriptor.createdAt
        )
    }
}
