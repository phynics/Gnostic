// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Foundation

extension GnosticObjectType {
    public static let runtimeInstance = "me.atkn.gnostic.RuntimeInstance"
}

/// Discovered Runtime Instance object advertised on the Axoloty network.
///
/// Replaces legacy Ascendant advertisements according to ADR 0020 §1, §8.
public final class GnosticRuntimeInstanceObject: CoatyObject, @unchecked Sendable { // SAFETY: CoatyObject projection; mutable routing fields are confined to the owning actor.
    public var protocolMajor: Int
    public var runtimeID: UUID
    public var runtimeKind: String
    public var runtimeVersion: String?
    public var rawCapabilities: [String: ACPValue]

    public override class var objectType: String {
        register(objectType: GnosticObjectType.runtimeInstance, with: self)
    }

    public init(
        id: UUID,
        name: String,
        kind: String,
        version: String? = nil,
        rawCapabilities: [String: ACPValue] = [:],
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.runtimeID = id
        self.runtimeKind = kind
        self.runtimeVersion = version
        self.rawCapabilities = rawCapabilities
        super.init(
            coreType: .coatyObject,
            objectType: Self.objectType,
            objectId: CoatyUUID(uuidString: id.uuidString)!,
            name: GnosticWirePayload.boundedLabel(name)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case protocolMajor
        case runtimeID
        case runtimeKind
        case runtimeVersion
        case rawCapabilities
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        runtimeID = try container.decode(UUID.self, forKey: .runtimeID)
        runtimeKind = try container.decode(String.self, forKey: .runtimeKind)
        runtimeVersion = try container.decodeIfPresent(String.self, forKey: .runtimeVersion)
        rawCapabilities = try container.decodeIfPresent([String: ACPValue].self, forKey: .rawCapabilities) ?? [:]
        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolMajor, forKey: .protocolMajor)
        try container.encode(runtimeID, forKey: .runtimeID)
        try container.encode(runtimeKind, forKey: .runtimeKind)
        try container.encodeIfPresent(runtimeVersion, forKey: .runtimeVersion)
        try container.encode(rawCapabilities, forKey: .rawCapabilities)
    }
}
