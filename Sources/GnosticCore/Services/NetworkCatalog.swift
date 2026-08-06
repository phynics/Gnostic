// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

public actor NetworkCatalog {
    private static let anonymousProviderID = "<unknown-provider>"
    private static let corePropertyNames: Set<String> = [
        "objectId", "coreType", "objectType", "name", "externalId", "parentObjectId", "locationId", "isDeactivated",
    ]
    private static let knownPropertyNames: [String: Set<String>] = [
        GnosticObjectType.agent: ["agentDescription", "primaryWorkspaceID", "privateTimelineID", "lastActiveAt", "createdAt", "updatedAt"],
        GnosticObjectType.timeline: ["title", "isArchived", "isPrivate", "attachedAgentID", "attachedWorkspaceIDs", "createdAt", "updatedAt"],
        GnosticObjectType.workspace: ["uri", "isAvailable", "trustLevel", "status", "tools", "createdAt"],
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
        let knownProperties = knownProperties(from: snapshot)
        let dynamicProperties = dynamicProperties(from: snapshot)
        let workspace = workspaceDescriptor(from: snapshot, id: objectID)
        let entry = NetworkCatalogEntry(
            objectID: objectID,
            objectType: snapshot.objectType,
            providerID: providerID,
            name: snapshot.name,
            knownProperties: knownProperties,
            dynamicProperties: dynamicProperties,
            workspace: workspace
        )
        entries[objectID, default: [:]][providerID] = entry
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
    public func networkObjects() -> [NetworkCatalogEntry] {
        entries.values
            .flatMap { $0.values }
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
        guard workspaceEntries.count == 1 else { return .ambiguous }
        guard let entry = workspaceEntries.first,
              let workspace = entry.workspace else {
            return .malformed
        }
        guard workspace.isAvailable else { return .unavailable }
        return .available(providerID: entry.providerID, uri: workspace.uri)
    }

    private func dynamicProperties(from snapshot: CoatyObjectSnapshot) -> [String: NetworkDynamicValue] {
        guard let payload = snapshot.payload,
              let fields = try? JSONDecoder().decode([String: NetworkDynamicValue].self, from: Data(payload.utf8)) else {
            return [:]
        }
        let known = Self.corePropertyNames.union(Self.knownPropertyNames[snapshot.objectType] ?? [])
        return fields.filter { !known.contains($0.key) }
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
            tools: object.tools
        )
    }
}
