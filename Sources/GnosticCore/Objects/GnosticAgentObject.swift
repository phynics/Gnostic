// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import PKShared

/// Canonical Axoloty object type identifiers advertised by Gnostic.
public enum GnosticObjectType {
    /// The object type for a projected Gnostic Ascendant.
    public static let ascendant = "me.atkn.gnostic.Ascendant"

    /// Compatibility spelling for pre-protocol-v2 source callers. The wire
    /// value remains the protocol-v2 Ascendant type.
    public static let agent = ascendant

    /// The object type for a projected PositronicKit timeline.
    public static let timeline = "me.atkn.gnostic.Timeline"

    /// The object type for a projected PositronicKit workspace.
    public static let workspace = "me.atkn.gnostic.Workspace"

    /// Returns whether an object type is handled by the Gnostic catalog.
    ///
    /// - Parameter objectType: A network object type.
    /// - Returns: `true` when the type is one of Gnostic's canonical types.
    public static func isSupported(_ objectType: String) -> Bool {
        [ascendant, timeline, workspace].contains(objectType)
    }
}

/// A safe network projection of a backend-neutral Ascendant identity.
public final class GnosticAscendantObject: CoatyObject {
    /// The protocol major carried by this advertisement.
    public let protocolMajor: Int

    /// Stable and namespaced experimental capabilities of this Ascendant.
    public let capabilities: [String]

    /// Current health of the bound backend. This is independent of whether
    /// the Ascendant and its Timelines remain routable.
    public let backendHealth: AscendantBackendHealth

    /// Diagnostic backend metadata; clients must not use it for selection.
    public var backendKind: String?
    public var backendVersion: String?

    /// The projected Ascendant's public description.
    public var ascendantDescription: String

    /// The Ascendant's primary workspace relationship, when one is assigned.
    public var primaryWorkspaceID: UUID?

    /// The Ascendant's private timeline relationship.
    public var privateTimelineID: UUID

    /// The Ascendant's latest recorded activity timestamp.
    public var lastActiveAt: Date

    /// The Ascendant creation timestamp.
    public var createdAt: Date

    /// The Ascendant's latest update timestamp.
    public var updatedAt: Date

    /// Registers Gnostic's canonical Ascendant object type.
    public override class var objectType: String {
        register(objectType: GnosticObjectType.ascendant, with: self)
    }

    /// Creates a network projection without exposing a provider's agent type.
    public init(
        identity: AscendantRuntimeIdentity,
        backendHealth: AscendantBackendHealth = .unknown,
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        capabilities = identity.capabilities.interoperability.sorted()
        self.backendHealth = backendHealth
        backendKind = identity.capabilities.backendKind
        backendVersion = identity.capabilities.backendVersion
        ascendantDescription = identity.description
        primaryWorkspaceID = identity.primaryWorkspaceID
        privateTimelineID = identity.privateTimelineID
        lastActiveAt = identity.lastActiveAt
        createdAt = identity.createdAt
        updatedAt = identity.updatedAt
        super.init(
            coreType: .CoatyObject,
            objectType: Self.objectType,
            objectId: CoatyUUID(uuidString: identity.id.uuidString)!,
            name: identity.name
        )
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor
        case capabilities
        case backendHealth
        case backendKind
        case backendVersion
        case ascendantDescription
        case primaryWorkspaceID
        case privateTimelineID
        case lastActiveAt
        case createdAt
        case updatedAt
    }

    /// Decodes an advertised Ascendant projection.
    ///
    /// - Parameter decoder: The source decoder.
    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        backendHealth = try container.decodeIfPresent(AscendantBackendHealth.self, forKey: .backendHealth) ?? .unknown
        backendKind = try container.decodeIfPresent(String.self, forKey: .backendKind)
        backendVersion = try container.decodeIfPresent(String.self, forKey: .backendVersion)
        ascendantDescription = try container.decode(String.self, forKey: .ascendantDescription)
        primaryWorkspaceID = try container.decodeIfPresent(UUID.self, forKey: .primaryWorkspaceID)
        privateTimelineID = try container.decode(UUID.self, forKey: .privateTimelineID)
        lastActiveAt = try container.decode(Date.self, forKey: .lastActiveAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        try super.init(from: decoder)
    }

    /// Encodes the safe Ascendant projection.
    ///
    /// - Parameter encoder: The destination encoder.
    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolMajor, forKey: .protocolMajor)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(backendHealth, forKey: .backendHealth)
        try container.encodeIfPresent(backendKind, forKey: .backendKind)
        try container.encodeIfPresent(backendVersion, forKey: .backendVersion)
        try container.encode(ascendantDescription, forKey: .ascendantDescription)
        try container.encodeIfPresent(primaryWorkspaceID, forKey: .primaryWorkspaceID)
        try container.encode(privateTimelineID, forKey: .privateTimelineID)
        try container.encode(lastActiveAt, forKey: .lastActiveAt)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

/// Compatibility spelling retained for pre-protocol-v2 source callers. It
/// still projects the protocol-v2 Ascendant wire type.
public typealias GnosticAgentObject = GnosticAscendantObject
