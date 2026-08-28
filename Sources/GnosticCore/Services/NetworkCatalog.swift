// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

public actor NetworkCatalog {
    private static let anonymousProviderID = "<unknown-provider>"
    private static let corePropertyNames: Set<String> = [
        "objectId", "coreType", "objectType", "name", "externalId", "parentObjectId", "locationId", "isDeactivated",
    ]
    private static let knownPropertyNames: [String: Set<String>] = [
        GnosticObjectType.ascendant: ["protocolMajor", "capabilities", "backendHealth", "backendKind", "backendVersion", "ascendantDescription", "primaryWorkspaceID", "privateTimelineID", "lastActiveAt", "createdAt", "updatedAt"],
        GnosticObjectType.timeline: ["protocolMajor", "title", "isArchived", "isPrivate", "attachedAscendantID", "attachedWorkspaceIDs", "createdAt", "updatedAt"],
        GnosticObjectType.workspace: ["protocolMajor", "uri", "isAvailable", "trustLevel", "status", "tools", "toolsComplete", "createdAt"],
        GnosticObjectType.workspaceTool: ["protocolMajor", "workspaceID", "toolID", "toolName", "toolDescription", "parametersSchema", "usageExample", "requiresPermission", "page"],
    ]

    private var entries: [UUID: [String: NetworkCatalogEntry]] = [:]
    private var workspaceTools: [UUID: [String: [String: GnosticWorkspaceTool]]] = [:]

    /// Creates an empty catalog.
    public init() {}

    /// Ingests an advertisement or readvertisement for a supported Gnostic object type.
    ///
    /// - Parameter event: The immutable Axoloty advertisement snapshot.
    public func ingest(_ event: AdvertiseEventSnapshot) {
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
        let protocolMajor = Self.protocolMajor(from: snapshot)
        let knownProperties = knownProperties(from: snapshot)
        let dynamicProperties = dynamicProperties(from: snapshot)
        let workspaceTool = workspaceTool(from: snapshot)
        if snapshot.objectType == GnosticObjectType.workspaceTool,
           let workspaceTool,
           let payload = snapshot.payload,
           let toolObject = try? JSONDecoder().decode(GnosticWorkspaceToolObject.self, from: Data(payload.utf8)) {
            workspaceTools[toolObject.workspaceID, default: [:]][providerID, default: [:]][workspaceTool.id] = workspaceTool
        }
        let workspace = workspaceDescriptor(from: snapshot, id: objectID, providerID: providerID)
        let entry = NetworkCatalogEntry(
            objectID: objectID,
            objectType: snapshot.objectType,
            protocolMajor: protocolMajor,
            providerID: providerID,
            name: snapshot.name,
            knownProperties: knownProperties,
            dynamicProperties: dynamicProperties,
            workspace: workspace,
            workspaceTool: workspaceTool
        )
        entries[objectID, default: [:]][providerID] = entry
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
            ingest(AdvertiseEventSnapshot(sourceId: event.sourceId, object: object))
        }
    }

    /// Ingests a deadvertisement and removes only entries owned by its provider.
    ///
    /// - Parameter event: The immutable Axoloty deadvertisement snapshot.
    public func ingest(_ event: DeadvertiseEventSnapshot) {
        let providerID = event.sourceId ?? Self.anonymousProviderID
        for rawID in event.objectIds {
            guard let objectID = UUID(uuidString: rawID) else { continue }
            if entries[objectID]?.values.contains(where: { $0.objectType == GnosticObjectType.workspace }) == true {
                workspaceTools[objectID] = nil
            }
            entries[objectID]?[providerID] = nil
            if entries[objectID]?.isEmpty == true {
                entries[objectID] = nil
            }
        }
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

    /// Returns whether a workspace can be attached without ambiguity.
    ///
    /// - Parameter id: The workspace identifier.
    /// - Returns: The workspace attachment status.
    public func workspaceAttachmentStatus(id: UUID) -> WorkspaceAttachmentStatus {
        let workspaceEntries = entries[id]?.values.filter { $0.objectType == GnosticObjectType.workspace && $0.isProtocolCompatible } ?? []
        guard !workspaceEntries.isEmpty else { return .unavailable }
        guard workspaceEntries.count == 1 else { return .ambiguous }
        guard let entry = workspaceEntries.first,
              let workspace = entry.workspace else {
            return .malformed
        }
        guard workspace.isAvailable else { return .unavailable }
        return .available(providerID: entry.providerID, uri: workspace.uri)
    }

    /// Returns a workspace descriptor with any query-only public tools merged
    /// into the compact advertised summary.
    public func workspaceDescriptor(id: UUID, providerID: String) -> NetworkWorkspaceDescriptor? {
        entries[id]?[providerID]?.workspace.map { descriptor in
            let queried = workspaceTools[id]?[providerID]?.values.sorted { $0.id < $1.id } ?? []
            let known = Set(descriptor.tools.map(\.id))
            return NetworkWorkspaceDescriptor(
                id: descriptor.id,
                uri: descriptor.uri,
                isAvailable: descriptor.isAvailable,
                tools: descriptor.tools + queried.filter { !known.contains($0.id) },
                toolsComplete: descriptor.toolsComplete || !queried.isEmpty
            )
        }
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
        let queried = workspaceTools[id]?[providerID]?.values.sorted { $0.id < $1.id } ?? []
        let known = Set(object.tools.map(\.id))
        return NetworkWorkspaceDescriptor(
            id: id,
            uri: object.uri,
            isAvailable: object.isAvailable,
            tools: object.tools + queried.filter { !known.contains($0.id) },
            toolsComplete: object.toolsComplete || !queried.isEmpty
        )
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
        let queried = workspaceTools[entry.objectID]?[entry.providerID]?.values.sorted { $0.id < $1.id } ?? []
        let known = Set(workspace.tools.map(\.id))
        let merged = NetworkWorkspaceDescriptor(
            id: workspace.id,
            uri: workspace.uri,
            isAvailable: workspace.isAvailable,
            tools: workspace.tools + queried.filter { !known.contains($0.id) },
            toolsComplete: workspace.toolsComplete || !queried.isEmpty
        )
        return NetworkCatalogEntry(
            objectID: entry.objectID,
            objectType: entry.objectType,
            protocolMajor: entry.protocolMajor,
            isProtocolCompatible: entry.isProtocolCompatible,
            providerID: entry.providerID,
            name: entry.name,
            knownProperties: entry.knownProperties,
            dynamicProperties: entry.dynamicProperties,
            workspace: merged,
            workspaceTool: entry.workspaceTool
        )
    }
}
