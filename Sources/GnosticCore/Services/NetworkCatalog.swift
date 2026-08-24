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
        GnosticObjectType.workspace: ["protocolMajor", "uri", "isAvailable", "trustLevel", "status", "effectiveStatus", "tools", "createdAt"],
    ]

    private var entries: [UUID: [String: NetworkCatalogEntry]] = [:]

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
        let isProtocolCompatible = GnosticProtocol.isCompatible(protocolMajor)
        let knownProperties = knownProperties(from: snapshot)
        let dynamicProperties = dynamicProperties(from: snapshot)
        let workspace = workspaceDescriptor(from: snapshot, id: objectID)
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
            effectiveStatus: effectiveStatus
        )
        entries[objectID, default: [:]][providerID] = entry
    }

    /// Ingests a resolved object returned by an active discover request.
    ///
    /// Resolve responses carry the same immutable object snapshot as an
    /// advertisement, so they share the catalog's provider-scoped projection
    /// and replacement semantics.
    public func ingest(_ event: ResponseEventSnapshot) {
        guard let snapshot = event.object else { return }
        let object = Self.hydrateResponseObject(snapshot, from: event.payload)
        ingest(AdvertiseEventSnapshot(sourceId: event.sourceId, object: object))
    }

    /// Ingests a deadvertisement and removes only entries owned by its provider.
    ///
    /// - Parameter event: The immutable Axoloty deadvertisement snapshot.
    public func ingest(_ event: DeadvertiseEventSnapshot) {
        let providerID = event.sourceId ?? Self.anonymousProviderID
        for rawID in event.objectIds {
            guard let objectID = UUID(uuidString: rawID) else { continue }
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
        entries[id]?[providerID]
    }

    /// Returns every currently advertised object, preserving provider scope for inspection.
    public func networkObjects(includeIncompatible: Bool = false) -> [NetworkCatalogEntry] {
        entries.values
            .flatMap { $0.values }
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

    private func workspaceDescriptor(from snapshot: CoatyObjectSnapshot, id: UUID) -> NetworkWorkspaceDescriptor? {
        guard snapshot.objectType == GnosticObjectType.workspace,
              let payload = snapshot.payload,
              let object = try? JSONDecoder().decode(GnosticWorkspaceObject.self, from: Data(payload.utf8)),
              object.objectId.string == id.uuidString.lowercased() else {
            return nil
        }
        return NetworkWorkspaceDescriptor(
            id: id,
            uri: object.uri,
            isAvailable: object.isAvailable,
            trustLevel: object.trustLevel,
            status: object.status,
            effectiveStatus: object.effectiveStatus,
            tools: object.tools,
            createdAt: object.createdAt
        )
    }
}
