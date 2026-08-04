// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

/// A JSON value retained for dynamic, not-yet-typed network object properties.
public indirect enum NetworkDynamicValue: Codable, Sendable, Equatable {
    /// A JSON null.
    case null

    /// A JSON Boolean.
    case bool(Bool)

    /// A JSON number.
    case number(Double)

    /// A JSON string.
    case string(String)

    /// A JSON array.
    case array([NetworkDynamicValue])

    /// A JSON object.
    case object([String: NetworkDynamicValue])

    /// Decodes a JSON value.
    ///
    /// - Parameter decoder: The source decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([NetworkDynamicValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: NetworkDynamicValue].self))
        }
    }

    /// Encodes a JSON value.
    ///
    /// - Parameter encoder: The destination encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

/// A catalogued network object, scoped to its advertising provider.
public struct NetworkCatalogEntry: Sendable {
    /// The PositronicKit object identifier.
    public let objectID: UUID

    /// The canonical Gnostic object type.
    public let objectType: String

    /// The provider that advertised this object.
    public let providerID: String

    /// The object name supplied by Axoloty.
    public let name: String

    /// Dynamic fields that are not part of Gnostic's known projection.
    public let dynamicProperties: [String: NetworkDynamicValue]

    /// A parsed workspace descriptor when this is a well-formed workspace.
    public let workspace: NetworkWorkspaceDescriptor?
}

/// The attachable, safe subset of an advertised workspace.
public struct NetworkWorkspaceDescriptor: Sendable {
    /// The stable workspace identifier.
    public let id: UUID

    /// The workspace URI.
    public let uri: String

    /// Whether the provider currently reports the workspace as available.
    public let isAvailable: Bool

    /// The workspace's safe tool descriptions.
    public let tools: [GnosticWorkspaceTool]
}

/// The result of checking whether a workspace is safe and unique enough to attach.
public enum WorkspaceAttachmentStatus: Sendable, Equatable {
    /// No advertised workspace is currently available for this identifier.
    case unavailable

    /// At least one advertisement exists, but its descriptor cannot be safely attached.
    case malformed

    /// More than one provider claims this workspace identifier.
    case ambiguous

    /// Exactly one provider advertises an available, well-formed workspace.
    case available(providerID: String, uri: String)
}

/// Actor-isolated storage for Gnostic advertisement lifecycle events.
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
        let dynamicProperties = dynamicProperties(from: snapshot)
        let workspace = workspaceDescriptor(from: snapshot, id: objectID)
        let entry = NetworkCatalogEntry(
            objectID: objectID,
            objectType: snapshot.objectType,
            providerID: providerID,
            name: snapshot.name,
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
