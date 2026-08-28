// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation

/// A JSON value retained for dynamic, not-yet-typed network object properties.
public indirect enum NetworkDynamicValue: Codable, Sendable, Equatable {
    /// A JSON null.
    case null

    /// A JSON Boolean.
    case bool(Bool)

    /// A floating-point JSON number.
    case number(Double)

    /// A signed JSON integer retained without floating-point conversion.
    case integer(Int64)

    /// An unsigned JSON integer retained without floating-point conversion.
    case unsignedInteger(UInt64)

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
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
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
        case let .integer(value):
            try container.encode(value)
        case let .unsignedInteger(value):
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

    /// The advertised protocol major, if the payload contains one.
    public let protocolMajor: Int?

    /// Whether this object is eligible for normal discovery and direct calls.
    public let isProtocolCompatible: Bool

    /// The provider that advertised this object.
    public let providerID: String

    /// The object name supplied by Axoloty.
    public let name: String

    /// Known projection fields (core Coaty fields excluded), retained for
    /// inspection without re-decoding the raw payload.
    public let knownProperties: [String: NetworkDynamicValue]

    /// Dynamic fields that are not part of Gnostic's known projection.
    public let dynamicProperties: [String: NetworkDynamicValue]

    /// A parsed workspace descriptor when this is a well-formed workspace.
    public let workspace: NetworkWorkspaceDescriptor?

    /// A query-only Workspace tool projection, when this entry is a tool.
    public let workspaceTool: GnosticWorkspaceTool?

    /// Creates a catalogued entry.
    public init(
        objectID: UUID,
        objectType: String,
        protocolMajor: Int? = nil,
        isProtocolCompatible: Bool? = nil,
        providerID: String,
        name: String,
        knownProperties: [String: NetworkDynamicValue],
        dynamicProperties: [String: NetworkDynamicValue],
        workspace: NetworkWorkspaceDescriptor?,
        workspaceTool: GnosticWorkspaceTool? = nil
    ) {
        self.objectID = objectID
        self.objectType = objectType
        self.protocolMajor = protocolMajor
        self.isProtocolCompatible = isProtocolCompatible ?? GnosticProtocol.isCompatible(protocolMajor)
        self.providerID = providerID
        self.name = name
        self.knownProperties = knownProperties
        self.dynamicProperties = dynamicProperties
        self.workspace = workspace
        self.workspaceTool = workspaceTool
    }
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

    /// Whether the advertisement contains every custom tool.
    public let toolsComplete: Bool

    /// Creates a workspace descriptor.
    public init(id: UUID, uri: String, isAvailable: Bool, tools: [GnosticWorkspaceTool], toolsComplete: Bool = true) {
        self.id = id
        self.uri = uri
        self.isAvailable = isAvailable
        self.tools = tools
        self.toolsComplete = toolsComplete
    }
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
