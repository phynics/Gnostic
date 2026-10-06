// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

// The Axoloty 0.7 compatibility object model. These reference types are the
// base every Gnostic wire projection inherits, so they live with the wire
// contracts rather than in the kernel. Retiring the Coaty object model is
// recorded as an architecture exception in
// Documentation/Architecture/exceptions.json.

public enum CoreType: String, Codable, Sendable {
    // Raw values are on the wire; the case names follow Swift convention.
    case coatyObject = "CoatyObject"
    case identity = "Identity"
}

public struct CoatyUUID: Codable, CustomStringConvertible, Hashable, Sendable {
    public let string: String
    private let uuid: UUID

    public init() {
        self.init(foundationUUID: UUID())
    }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.init(foundationUUID: uuid)
    }

    private init(foundationUUID uuid: UUID) {
        self.uuid = uuid
        string = uuid.uuidString.lowercased()
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let uuid = UUID(uuidString: value) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid UUID")) }
        self.init(foundationUUID: uuid)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }

    public var description: String { string }
    public var foundationUUID: UUID { uuid }
}

open class CoatyObject: Codable, @unchecked Sendable { // SAFETY: Axoloty-compatible reference base; shared instances stay within one isolation domain.
    open class var objectType: String { "CoatyObject" }
    public var coreType: CoreType
    public var objectType: String
    public var objectId: CoatyUUID
    public var name: String
    public var externalId: String?
    public var parentObjectId: CoatyUUID?
    public var locationId: CoatyUUID?
    public var isDeactivated: Bool?
    public var custom: [String: String] = [:]

    public init(coreType: CoreType, objectType: String, objectId: CoatyUUID, name: String) {
        self.coreType = coreType
        self.objectType = objectType
        self.objectId = objectId
        self.name = name
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coreType = try c.decode(CoreType.self, forKey: .coreType)
        objectType = try c.decode(String.self, forKey: .objectType)
        objectId = try c.decode(CoatyUUID.self, forKey: .objectId)
        name = try c.decode(String.self, forKey: .name)
        externalId = try c.decodeIfPresent(String.self, forKey: .externalId)
        parentObjectId = try c.decodeIfPresent(CoatyUUID.self, forKey: .parentObjectId)
        locationId = try c.decodeIfPresent(CoatyUUID.self, forKey: .locationId)
        isDeactivated = try c.decodeIfPresent(Bool.self, forKey: .isDeactivated)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(coreType, forKey: .coreType)
        try c.encode(objectType, forKey: .objectType)
        try c.encode(objectId, forKey: .objectId)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(externalId, forKey: .externalId)
        try c.encodeIfPresent(parentObjectId, forKey: .parentObjectId)
        try c.encodeIfPresent(locationId, forKey: .locationId)
        try c.encodeIfPresent(isDeactivated, forKey: .isDeactivated)
    }

    private enum CodingKeys: String, CodingKey {
        case coreType, objectType, objectId, name, externalId, parentObjectId, locationId, isDeactivated
    }

    public static func register(objectType: String, with _: CoatyObject.Type) -> String { objectType }
}
