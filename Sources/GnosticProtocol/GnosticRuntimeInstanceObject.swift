// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Foundation

extension GnosticObjectType {
    public static let runtimeInstance = "me.atkn.gnostic.RuntimeInstance"
}

/// Current process health for one discovered Runtime instance.
public enum GnosticRuntimeInstanceHealth: String, Codable, Sendable, Equatable {
    case healthy
    case failed
    case unknown
}

/// Discovered Runtime Instance object advertised on the Axoloty network.
///
/// Carries the Runtime's own ACP identity and launch fingerprint for routing
/// and diagnostics, as defined by ADR 0021.
public final class GnosticRuntimeInstanceObject: CoatyObject, @unchecked Sendable { // SAFETY: CoatyObject projection; mutable routing fields are confined to the owning actor.
    public var protocolMajor: Int
    public var runtimeID: UUID
    public var nodeID: UUID?
    public var runtimeKind: String
    public var runtimeVersion: String?
    public var launchFingerprint: String?
    public var health: GnosticRuntimeInstanceHealth
    public var rawCapabilities: [String: ACPValue]

    public override class var objectType: String {
        register(objectType: GnosticObjectType.runtimeInstance, with: self)
    }

    public init(
        id: UUID,
        name: String,
        kind: String,
        nodeID: UUID? = nil,
        version: String? = nil,
        launchFingerprint: String? = nil,
        health: GnosticRuntimeInstanceHealth = .unknown,
        rawCapabilities: [String: ACPValue] = [:],
        protocolMajor: Int = GnosticProtocol.currentMajor
    ) {
        self.protocolMajor = protocolMajor
        self.runtimeID = id
        self.nodeID = nodeID
        self.runtimeKind = kind
        self.runtimeVersion = version
        self.launchFingerprint = launchFingerprint
        self.health = health
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
        case nodeID
        case runtimeKind
        case runtimeVersion
        case launchFingerprint
        case health
        case rawCapabilities
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolMajor = try GnosticProtocol.decodeMajor(from: container, key: .protocolMajor)
        runtimeID = try container.decode(UUID.self, forKey: .runtimeID)
        nodeID = try container.decodeIfPresent(UUID.self, forKey: .nodeID)
        runtimeKind = try container.decode(String.self, forKey: .runtimeKind)
        runtimeVersion = try container.decodeIfPresent(String.self, forKey: .runtimeVersion)
        launchFingerprint = try container.decodeIfPresent(String.self, forKey: .launchFingerprint)
        health = try container.decodeIfPresent(GnosticRuntimeInstanceHealth.self, forKey: .health) ?? .unknown
        rawCapabilities = try container.decodeIfPresent([String: ACPValue].self, forKey: .rawCapabilities) ?? [:]
        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolMajor, forKey: .protocolMajor)
        try container.encode(runtimeID, forKey: .runtimeID)
        try container.encodeIfPresent(nodeID, forKey: .nodeID)
        try container.encode(runtimeKind, forKey: .runtimeKind)
        try container.encodeIfPresent(runtimeVersion, forKey: .runtimeVersion)
        try container.encodeIfPresent(launchFingerprint, forKey: .launchFingerprint)
        try container.encode(health, forKey: .health)
        try container.encode(rawCapabilities, forKey: .rawCapabilities)
    }
}
