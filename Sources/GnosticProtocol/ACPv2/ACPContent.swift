// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Annotations attached to content blocks in ACP v2.
public struct ACPAnnotations: Codable, Sendable, Equatable {
    public var audience: [String]?
    public var lastModified: String?
    public var priority: Double?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case audience
        case lastModified
        case priority
        case meta = "_meta"
    }

    public init(
        audience: [String]? = nil,
        lastModified: String? = nil,
        priority: Double? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.audience = audience
        self.lastModified = lastModified
        self.priority = priority
        self.meta = meta
    }
}

/// Text content block in ACP v2.
public struct ACPTextContent: Codable, Sendable, Equatable {
    public var type: String
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "text"
        self.text = try container.decode(String.self, forKey: .text)
        self.annotations = try container.decodeIfPresent(ACPAnnotations.self, forKey: .annotations)
        self.meta = try container.decodeIfPresent([String: ACPValue].self, forKey: .meta)
    }
}

/// Image content block in ACP v2.
public struct ACPImageContent: Codable, Sendable, Equatable {
    public var type: String
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

    public init(
        data: String,
        mimeType: String,
        uri: String? = nil,
        annotations: ACPAnnotations? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.type = "image"
        self.data = data
        self.mimeType = mimeType
        self.uri = uri
        self.annotations = annotations
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "image"
        self.data = try container.decode(String.self, forKey: .data)
        self.mimeType = try container.decode(String.self, forKey: .mimeType)
        self.uri = try container.decodeIfPresent(String.self, forKey: .uri)
        self.annotations = try container.decodeIfPresent(ACPAnnotations.self, forKey: .annotations)
        self.meta = try container.decodeIfPresent([String: ACPValue].self, forKey: .meta)
    }
}

/// Audio content block in ACP v2.
public struct ACPAudioContent: Codable, Sendable, Equatable {
    public var type: String
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "audio"
        self.data = try container.decode(String.self, forKey: .data)
        self.mimeType = try container.decode(String.self, forKey: .mimeType)
        self.annotations = try container.decodeIfPresent(ACPAnnotations.self, forKey: .annotations)
        self.meta = try container.decodeIfPresent([String: ACPValue].self, forKey: .meta)
    }
}

/// Icon metadata for resource links.
public struct ACPIcon: Codable, Sendable, Equatable {
    public var src: String
    public var mimeType: String?
    public var sizes: [String]?
    public var theme: String?

    public init(src: String, mimeType: String? = nil, sizes: [String]? = nil, theme: String? = nil) {
        self.src = src
        self.mimeType = mimeType
        self.sizes = sizes
        self.theme = theme
    }
}

/// Resource link content block in ACP v2.
public struct ACPResourceLink: Codable, Sendable, Equatable {
    public var type: String
    public var name: String
    public var uri: String
    public var title: String?
    public var description: String?
    public var icons: [ACPIcon]?
    public var mimeType: String?
    public var size: Int?
    public var annotations: ACPAnnotations?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case uri
        case title
        case description
        case icons
        case mimeType
        case size
        case annotations
        case meta = "_meta"
    }

    public init(
        name: String,
        uri: String,
        title: String? = nil,
        description: String? = nil,
        icons: [ACPIcon]? = nil,
        mimeType: String? = nil,
        size: Int? = nil,
        annotations: ACPAnnotations? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.type = "resource_link"
        self.name = name
        self.uri = uri
        self.title = title
        self.description = description
        self.icons = icons
        self.mimeType = mimeType
        self.size = size
        self.annotations = annotations
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "resource_link"
        self.name = try container.decode(String.self, forKey: .name)
        self.uri = try container.decode(String.self, forKey: .uri)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.icons = try container.decodeIfPresent([ACPIcon].self, forKey: .icons)
        self.mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        self.size = try container.decodeIfPresent(Int.self, forKey: .size)
        self.annotations = try container.decodeIfPresent(ACPAnnotations.self, forKey: .annotations)
        self.meta = try container.decodeIfPresent([String: ACPValue].self, forKey: .meta)
    }
}

/// Embedded resource contents (text or blob).
public enum ACPEmbeddedResourceContents: Codable, Sendable, Equatable {
    case text(uri: String, text: String, mimeType: String?, meta: [String: ACPValue]?)
    case blob(uri: String, blob: String, mimeType: String?, meta: [String: ACPValue]?)

    private enum CodingKeys: String, CodingKey {
        case uri
        case text
        case blob
        case mimeType
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let uri = try container.decode(String.self, forKey: .uri)
        let mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        let meta = try container.decodeIfPresent([String: ACPValue].self, forKey: .meta)
        if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .text(uri: uri, text: text, mimeType: mimeType, meta: meta)
        } else if let blob = try container.decodeIfPresent(String.self, forKey: .blob) {
            self = .blob(uri: uri, blob: blob, mimeType: mimeType, meta: meta)
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
        case let .text(uri, text, mimeType, meta):
            try container.encode(uri, forKey: .uri)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(mimeType, forKey: .mimeType)
            try container.encodeIfPresent(meta, forKey: .meta)
        case let .blob(uri, blob, mimeType, meta):
            try container.encode(uri, forKey: .uri)
            try container.encode(blob, forKey: .blob)
            try container.encodeIfPresent(mimeType, forKey: .mimeType)
            try container.encodeIfPresent(meta, forKey: .meta)
        }
    }

    public var uri: String {
        switch self {
        case let .text(uri, _, _, _), let .blob(uri, _, _, _): return uri
        }
    }
}

/// Embedded resource content block in ACP v2.
public struct ACPEmbeddedResource: Codable, Sendable, Equatable {
    public var type: String
    public var resource: ACPEmbeddedResourceContents
    public var annotations: ACPAnnotations?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case type
        case resource
        case annotations
        case meta = "_meta"
    }

    public init(
        resource: ACPEmbeddedResourceContents,
        annotations: ACPAnnotations? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.type = "resource"
        self.resource = resource
        self.annotations = annotations
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "resource"
        self.resource = try container.decode(ACPEmbeddedResourceContents.self, forKey: .resource)
        self.annotations = try container.decodeIfPresent(ACPAnnotations.self, forKey: .annotations)
        self.meta = try container.decodeIfPresent([String: ACPValue].self, forKey: .meta)
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
        case let .text(value):
            try value.encode(to: encoder)
        case let .image(value):
            try value.encode(to: encoder)
        case let .audio(value):
            try value.encode(to: encoder)
        case let .resourceLink(value):
            try value.encode(to: encoder)
        case let .resource(value):
            try value.encode(to: encoder)
        case let .other(type, fields):
            var combined = fields
            combined["type"] = .string(type)
            var container = encoder.singleValueContainer()
            try container.encode(combined)
        }
    }

    public var textValue: String? {
        guard case let .text(value) = self else { return nil }
        return value.text
    }
}

/// A standard content block wrapped for tool-call output.
public struct ACPContent: Codable, Sendable, Equatable {
    public var content: ACPContentBlock
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case content
        case meta = "_meta"
    }

    public init(content: ACPContentBlock, meta: [String: ACPValue]? = nil) {
        self.content = content
        self.meta = meta
    }
}

/// Patch attached to a diff.
public struct ACPDiffPatch: Codable, Sendable, Equatable {
    public var format: String
    public var text: String

    public init(format: String, text: String) {
        self.format = format
        self.text = text
    }
}

/// One file operation inside a diff.
public struct ACPDiffChange: Codable, Sendable, Equatable {
    public var operation: String
    public var path: String?
    public var oldPath: String?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case operation
        case path
        case oldPath
        case meta = "_meta"
    }

    public init(
        operation: String,
        path: String? = nil,
        oldPath: String? = nil,
        meta: [String: ACPValue]? = nil
    ) {
        self.operation = operation
        self.path = path
        self.oldPath = oldPath
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.operation = try container.decode(String.self, forKey: .operation)
        self.path = try container.decodeIfPresent(String.self, forKey: .path)
        self.oldPath = try container.decodeIfPresent(String.self, forKey: .oldPath)
        self.meta = try container.decodeIfPresent([String: ACPValue].self, forKey: .meta)

        switch operation {
        case "add", "delete", "modify":
            guard path != nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .path,
                    in: container,
                    debugDescription: "Diff operation '\(operation)' requires 'path'"
                )
            }
        case "move", "copy":
            guard path != nil, oldPath != nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .path,
                    in: container,
                    debugDescription: "Diff operation '\(operation)' requires 'oldPath' and 'path'"
                )
            }
        default:
            break
        }
    }
}

/// Structured diff representation in ACP v2.
public struct ACPDiff: Codable, Sendable, Equatable {
    public var changes: [ACPDiffChange]
    public var patch: ACPDiffPatch?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case changes
        case patch
        case meta = "_meta"
    }

    public init(changes: [ACPDiffChange], patch: ACPDiffPatch? = nil, meta: [String: ACPValue]? = nil) {
        self.changes = changes
        self.patch = patch
        self.meta = meta
    }
}

/// Location associated with a tool call.
public struct ACPToolCallLocation: Codable, Sendable, Equatable {
    public var path: String
    public var line: Int?
    public var meta: [String: ACPValue]?

    enum CodingKeys: String, CodingKey {
        case path
        case line
        case meta = "_meta"
    }

    public init(path: String, line: Int? = nil, meta: [String: ACPValue]? = nil) {
        self.path = path
        self.line = line
        self.meta = meta
    }
}
