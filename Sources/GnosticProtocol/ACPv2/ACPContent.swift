// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Annotations attached to content blocks in ACP v2.
public struct ACPAnnotations: Codable, Sendable, Equatable {
    public var priority: Double?
    public var audience: [String]?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case priority
        case audience
        case meta = "_meta"
    }

    public init(priority: Double? = nil, audience: [String]? = nil, meta: [String: ACPValue]? = nil) {
        self.priority = priority
        self.audience = audience
        self.meta = meta
    }
}

/// Text content block in ACP v2.
public struct ACPTextContent: Codable, Sendable, Equatable {
    public let type: String
    public var text: String
    public var annotations: ACPAnnotations?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case annotations
        case meta = "_meta"
    }

    public init(text: String, annotations: ACPAnnotations? = nil, meta: [String: ACPValue]? = nil) {
        self.type = "text"
        self.text = text
        self.annotations = annotations
        self.meta = meta
    }
}

/// Image content block in ACP v2.
public struct ACPImageContent: Codable, Sendable, Equatable {
    public let type: String
    public var data: String
    public var mimeType: String
    public var uri: String?
    public var annotations: ACPAnnotations?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case type
        case data
        case mimeType
        case uri
        case annotations
        case meta = "_meta"
    }

    public init(data: String, mimeType: String, uri: String? = nil, annotations: ACPAnnotations? = nil, meta: [String: ACPValue]? = nil) {
        self.type = "image"
        self.data = data
        self.mimeType = mimeType
        self.uri = uri
        self.annotations = annotations
        self.meta = meta
    }
}

/// Audio content block in ACP v2.
public struct ACPAudioContent: Codable, Sendable, Equatable {
    public let type: String
    public var data: String
    public var mimeType: String
    public var annotations: ACPAnnotations?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case type
        case data
        case mimeType
        case annotations
        case meta = "_meta"
    }

    public init(data: String, mimeType: String, annotations: ACPAnnotations? = nil, meta: [String: ACPValue]? = nil) {
        self.type = "audio"
        self.data = data
        self.mimeType = mimeType
        self.annotations = annotations
        self.meta = meta
    }
}

/// Resource link content block in ACP v2.
public struct ACPResourceLink: Codable, Sendable, Equatable {
    public let type: String
    public var uri: String
    public var title: String?
    public var description: String?
    public var mimeType: String?
    public var size: Int?
    public var annotations: ACPAnnotations?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case type
        case uri
        case title
        case description
        case mimeType
        case size
        case annotations
        case meta = "_meta"
    }

    public init(
        uri: String,
        title: String? = nil,
        description: String? = nil,
        mimeType: String? = nil,
        size: Int? = nil,
        annotations: ACPAnnotations? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.type = "resource_link"
        self.uri = uri
        self.title = title
        self.description = description
        self.mimeType = mimeType
        self.size = size
        self.annotations = annotations
        self.meta = meta
    }
}

/// Embedded resource contents (text or blob).
public enum ACPEmbeddedResourceContents: Codable, Sendable, Equatable {
    case text(uri: String, text: String, mimeType: String?)
    case blob(uri: String, blob: String, mimeType: String?)

    private enum CodingKeys: String, CodingKey {
        case uri
        case text
        case blob
        case mimeType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let uri = try container.decode(String.self, forKey: .uri)
        let mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .text(uri: uri, text: text, mimeType: mimeType)
        } else if let blob = try container.decodeIfPresent(String.self, forKey: .blob) {
            self = .blob(uri: uri, blob: blob, mimeType: mimeType)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Resource contents must contain either text or blob"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(uri, text, mimeType):
            try container.encode(uri, forKey: .uri)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(mimeType, forKey: .mimeType)
        case let .blob(uri, blob, mimeType):
            try container.encode(uri, forKey: .uri)
            try container.encode(blob, forKey: .blob)
            try container.encodeIfPresent(mimeType, forKey: .mimeType)
        }
    }
}

/// Embedded resource content block in ACP v2.
public struct ACPEmbeddedResource: Codable, Sendable, Equatable {
    public let type: String
    public var resource: ACPEmbeddedResourceContents
    public var annotations: ACPAnnotations?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case type
        case resource
        case annotations
        case meta = "_meta"
    }

    public init(resource: ACPEmbeddedResourceContents, annotations: ACPAnnotations? = nil, meta: [String: ACPValue]? = nil) {
        self.type = "resource"
        self.resource = resource
        self.annotations = annotations
        self.meta = meta
    }
}

/// Extensible ContentBlock enum in ACP v2.
/// Round-trips unknown content block types losslessly as `.other`.
public enum ACPContentBlock: Codable, Sendable, Equatable {
    case text(ACPTextContent)
    case image(ACPImageContent)
    case audio(ACPAudioContent)
    case resourceLink(ACPResourceLink)
    case resource(ACPEmbeddedResource)
    case other(type: String, fields: [String: ACPValue])

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let single = try decoder.singleValueContainer()

        switch type {
        case "text":
            self = .text(try single.decode(ACPTextContent.self))
        case "image":
            self = .image(try single.decode(ACPImageContent.self))
        case "audio":
            self = .audio(try single.decode(ACPAudioContent.self))
        case "resource_link":
            self = .resourceLink(try single.decode(ACPResourceLink.self))
        case "resource":
            self = .resource(try single.decode(ACPEmbeddedResource.self))
        default:
            var fields = (try? single.decode([String: ACPValue].self)) ?? [:]
            fields.removeValue(forKey: "type")
            self = .other(type: type, fields: fields)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .text(val):
            try val.encode(to: encoder)
        case let .image(val):
            try val.encode(to: encoder)
        case let .audio(val):
            try val.encode(to: encoder)
        case let .resourceLink(val):
            try val.encode(to: encoder)
        case let .resource(val):
            try val.encode(to: encoder)
        case let .other(type, fields):
            var combined = fields
            combined["type"] = .string(type)
            var container = encoder.singleValueContainer()
            try container.encode(combined)
        }
    }

    public var textValue: String? {
        guard case let .text(t) = self else { return nil }
        return t.text
    }
}
