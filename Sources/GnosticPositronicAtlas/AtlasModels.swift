// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The stable identity of a Shard belonging to an Ascendant.
public struct AscendantShardID: Codable, Hashable, Comparable, Sendable {
    /// The UUID that identifies the Shard.
    public let rawValue: UUID

    /// Creates a Shard identity.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// Creates a Shard identity from its UUID.
    public init(_ rawValue: UUID) {
        self.init(rawValue: rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }
}

/// A stable operation identity used to correlate one Ascendant Turn with one
/// Shard Report.
public struct AtlasOperationID: Codable, Hashable, Comparable, Sendable {
    /// The bounded operation identifier.
    public let rawValue: String

    /// Creates an operation identity. The store rejects an empty identity.
    public init(rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Creates an operation identity.
    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    /// Decodes through the normalizing initializer.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(rawValue: try container.decode(String.self, forKey: .rawValue))
    }

    private enum CodingKeys: String, CodingKey { case rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The operation identity spelling used by Ascendant-facing call sites.
public typealias AscendantOperationID = AtlasOperationID

/// A stable identity for accepted semantic state.
public struct AtlasItemID: Codable, Hashable, Comparable, Sendable {
    /// The UUID that identifies the item.
    public let rawValue: UUID

    /// Creates an item identity.
    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }
}

/// A stable identity for a scoped conflict.
public struct AtlasConflictID: Codable, Hashable, Comparable, Sendable {
    /// The UUID that identifies the conflict.
    public let rawValue: UUID

    /// Creates a conflict identity.
    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }
}

/// A stable identity for an advisory Atlas directive.
public struct AtlasDirectiveID: Codable, Hashable, Comparable, Sendable {
    /// The UUID that identifies the directive.
    public let rawValue: UUID

    /// Creates a directive identity.
    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }
}

/// A stable identity for one accepted patch.
public struct AtlasPatchID: Codable, Hashable, Comparable, Sendable {
    /// The caller-provided patch identity.
    public let rawValue: String

    /// Creates a patch identity.
    public init(rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Creates a patch identity.
    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    /// Decodes through the normalizing initializer.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(rawValue: try container.decode(String.self, forKey: .rawValue))
    }

    private enum CodingKeys: String, CodingKey { case rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A stable identity for an immutable integration capture.
public struct AtlasCaptureID: Codable, Hashable, Comparable, Sendable {
    /// The canonical capture identity.
    public let rawValue: String

    /// Creates a capture identity.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The identity binding under which one Atlas store operates.
public struct AscendantAtlasBinding: Codable, Equatable, Hashable, Sendable {
    /// The Gnostic Ascendant identity.
    public let ascendantID: UUID
    /// The backend binding identity for this store lifetime.
    public let bindingID: UUID

    /// Creates an Ascendant binding.
    public init(ascendantID: UUID, bindingID: UUID = UUID()) {
        self.ascendantID = ascendantID
        self.bindingID = bindingID
    }
}

/// The source class attached to a Shard registration.
public enum AtlasShardKind: String, Codable, Equatable, Hashable, Sendable {
    /// The Ascendant's home context.
    case home
    /// A work context.
    case work
    /// Another explicit context.
    case other
}

/// The lifecycle of a registered Shard.
public enum AtlasShardLifecycle: String, Codable, Equatable, Hashable, Sendable {
    /// The Shard may receive reports and be used for projections.
    case active
    /// The Shard remains known but cannot receive new reports.
    case detached
    /// The Shard is retained for history but cannot be used.
    case archived
}

/// A registered context belonging to one Ascendant.
public struct AscendantShard: Codable, Equatable, Hashable, Sendable {
    /// Stable Shard identity.
    public let id: AscendantShardID
    /// Owning Ascendant identity.
    public let ascendantID: UUID
    /// Optional backend binding identity.
    public let bindingID: UUID?
    /// Shard classification.
    public let kind: AtlasShardKind
    /// Human-readable Shard label.
    public let name: String
    /// Current Shard lifecycle.
    public let lifecycle: AtlasShardLifecycle

    /// Creates an immutable Shard registration.
    public init(
        id: AscendantShardID,
        ascendantID: UUID,
        name: String,
        kind: AtlasShardKind = .other,
        lifecycle: AtlasShardLifecycle = .active,
        bindingID: UUID? = nil
    ) {
        self.id = id
        self.ascendantID = ascendantID
        self.bindingID = bindingID
        self.kind = kind
        self.name = name
        self.lifecycle = lifecycle
    }
}

/// A decimal number carried as a validated canonical string so no
/// floating-point value and no arbitrary text can become typed Atlas state.
public struct AtlasDecimal: Codable, Equatable, Hashable, Sendable, Comparable, CustomStringConvertible {
    /// The canonical decimal spelling, for example `-12.50` or `3`.
    public let canonical: String

    /// Creates a decimal from a numeric string, or returns `nil` when the
    /// text is not a plain decimal number.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Self.isDecimal(trimmed) else { return nil }
        self.canonical = trimmed
    }

    /// Creates a decimal from a canonical string.
    public init(rawValue: String) throws {
        guard let value = AtlasDecimal(rawValue) else {
            throw AtlasStoreError.invalidReference
        }
        self = value
    }

    /// The canonical decimal spelling.
    public var description: String { canonical }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.canonical < rhs.canonical
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = AtlasDecimal(text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Not a canonical decimal number."
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(canonical)
    }

    private static func isDecimal(_ text: String) -> Bool {
        var index = text.startIndex
        if text[index] == "+" || text[index] == "-" {
            index = text.index(after: index)
            guard index < text.endIndex else { return false }
        }
        var digitsBeforeSeparator = 0
        while index < text.endIndex, text[index].isNumber {
            digitsBeforeSeparator += 1
            index = text.index(after: index)
        }
        if index < text.endIndex, text[index] == "." {
            index = text.index(after: index)
            var digitsAfterSeparator = 0
            while index < text.endIndex, text[index].isNumber {
                digitsAfterSeparator += 1
                index = text.index(after: index)
            }
            if digitsBeforeSeparator == 0, digitsAfterSeparator == 0 { return false }
        } else if digitsBeforeSeparator == 0 {
            return false
        }
        if index < text.endIndex, text[index] == "e" || text[index] == "E" {
            index = text.index(after: index)
            if index < text.endIndex, text[index] == "+" || text[index] == "-" {
                index = text.index(after: index)
            }
            var exponentDigits = 0
            while index < text.endIndex, text[index].isNumber {
                exponentDigits += 1
                index = text.index(after: index)
            }
            if exponentDigits == 0 { return false }
        }
        return index == text.endIndex
    }
}

/// A typed value that may become part of accepted Atlas state.
public indirect enum AtlasValue: Codable, Equatable, Hashable, Sendable {
    /// A bounded textual value.
    case text(String)
    /// An integer value.
    case integer(Int64)
    /// A decimal represented without floating-point ambiguity.
    case decimal(AtlasDecimal)
    /// A Boolean value.
    case boolean(Bool)
    /// A date value.
    case date(Date)
    /// An ordered list of values.
    case list([AtlasValue])
    /// A canonical record of named values.
    case record([AtlasRecordEntry])

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
        case entries
    }

    private enum Kind: String, Codable {
        case text
        case integer
        case decimal
        case boolean
        case date
        case list
        case record
    }

    /// Creates a canonical record value.
    public static func record(_ values: [String: AtlasValue]) -> Self {
        .record(values.map { AtlasRecordEntry(key: $0.key, value: $0.value) }.sorted())
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(value):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .integer(value):
            try container.encode(Kind.integer, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .decimal(value):
            try container.encode(Kind.decimal, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .boolean(value):
            try container.encode(Kind.boolean, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .date(value):
            try container.encode(Kind.date, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .list(values):
            try container.encode(Kind.list, forKey: .kind)
            try container.encode(values, forKey: .value)
        case let .record(entries):
            try container.encode(Kind.record, forKey: .kind)
            try container.encode(entries.sorted(), forKey: .entries)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text: self = .text(try container.decode(String.self, forKey: .value))
        case .integer: self = .integer(try container.decode(Int64.self, forKey: .value))
        case .decimal: self = .decimal(try container.decode(AtlasDecimal.self, forKey: .value))
        case .boolean: self = .boolean(try container.decode(Bool.self, forKey: .value))
        case .date: self = .date(try container.decode(Date.self, forKey: .value))
        case .list: self = .list(try container.decode([AtlasValue].self, forKey: .value))
        case .record: self = .record(try container.decode([AtlasRecordEntry].self, forKey: .entries).sorted())
        }
    }
}

/// One named value in an ``AtlasValue/record``.
public struct AtlasRecordEntry: Codable, Equatable, Hashable, Comparable, Sendable {
    /// The record key.
    public let key: String
    /// The record value.
    public let value: AtlasValue

    /// Creates a record entry.
    public init(key: String, value: AtlasValue) {
        self.key = key
        self.value = value
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.key, String(describing: lhs.value)) < (rhs.key, String(describing: rhs.value))
    }
}

/// Controls which Shards may use an accepted item.
public enum AtlasApplicability: Codable, Equatable, Hashable, Sendable {
    /// The item applies nowhere.
    case none
    /// The item applies to every Shard in this Ascendant.
    case ascendant
    /// The item applies only to the listed Shards.
    case shards([AscendantShardID])

    /// Returns a canonical representation with sorted, unique Shard IDs.
    public var canonical: Self {
        switch self {
        case .none, .ascendant: self
        case let .shards(ids): .shards(Array(Set(ids)).sorted())
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, shardIDs }
    private enum Kind: String, Codable { case none, ascendant, shards }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch canonical {
        case .none: try container.encode(Kind.none, forKey: .kind)
        case .ascendant: try container.encode(Kind.ascendant, forKey: .kind)
        case let .shards(ids):
            try container.encode(Kind.shards, forKey: .kind)
            try container.encode(ids, forKey: .shardIDs)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .none: self = .none
        case .ascendant: self = .ascendant
        case .shards: self = .shards(try container.decode([AscendantShardID].self, forKey: .shardIDs)).canonical
        }
    }
}

/// Controls which Shards may receive an accepted item.
public enum AtlasDisclosure: Codable, Equatable, Hashable, Sendable {
    /// The item cannot be disclosed.
    case none
    /// The item may be disclosed to the Ascendant's eligible Shards.
    case ascendant
    /// The item may be disclosed only to the listed Shards.
    case shards([AscendantShardID])

    /// Returns a canonical representation with sorted, unique Shard IDs.
    public var canonical: Self {
        switch self {
        case .none, .ascendant: self
        case let .shards(ids): .shards(Array(Set(ids)).sorted())
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, shardIDs }
    private enum Kind: String, Codable { case none, ascendant, shards }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch canonical {
        case .none: try container.encode(Kind.none, forKey: .kind)
        case .ascendant: try container.encode(Kind.ascendant, forKey: .kind)
        case let .shards(ids):
            try container.encode(Kind.shards, forKey: .kind)
            try container.encode(ids, forKey: .shardIDs)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .none: self = .none
        case .ascendant: self = .ascendant
        case .shards: self = .shards(try container.decode([AscendantShardID].self, forKey: .shardIDs)).canonical
        }
    }
}

/// The epistemic status of an accepted item.
public enum AtlasEpistemicStatus: String, Codable, Equatable, Hashable, Sendable {
    /// Directly observed source material.
    case observed
    /// A report from another typed source.
    case reported
    /// A host or integrator inference.
    case inferred
    /// A not-yet-confirmed proposal.
    case proposed
    /// A disputed item retained for explicit review.
    case disputed
    /// An item no longer considered valid.
    case retracted
}

/// The lifecycle of an accepted item.
public enum AtlasItemLifecycle: String, Codable, Equatable, Hashable, Sendable {
    /// The item participates in accepted state.
    case active
    /// The item is retained but not active.
    case archived
    /// The item was explicitly retracted.
    case retracted
}

/// The semantic category of an accepted item.
public enum AtlasItemKind: String, Codable, Equatable, Hashable, Sendable {
    /// A fact or observation.
    case fact
    /// An Ascendant preference.
    case preference
    /// A goal or intended outcome.
    case goal
    /// A constraint.
    case constraint
    /// A general typed note.
    case note
}

/// References that explain where an Atlas value came from without embedding
/// transcript, Workspace, or PositronicKit objects.
public struct AtlasProvenance: Codable, Equatable, Hashable, Sendable {
    /// The contributing Ascendant.
    public let ascendantID: UUID
    /// The contributing Shard.
    public let shardID: AscendantShardID
    /// The operation that produced the source, when known.
    public let operationID: AtlasOperationID?
    /// The provenance origin.
    public let origin: AtlasOrigin
    /// Optional Gnostic Timeline identity.
    public let timelineID: UUID?
    /// Optional Gnostic Workspace identities.
    public let workspaceIDs: [UUID]

    /// Creates reference-only provenance.
    public init(
        ascendantID: UUID,
        shardID: AscendantShardID,
        operationID: String? = nil,
        origin: AtlasOrigin,
        timelineID: UUID? = nil,
        workspaceIDs: [UUID] = []
    ) {
        self.ascendantID = ascendantID
        self.shardID = shardID
        self.operationID = operationID.map { AtlasOperationID(rawValue: $0) }
        self.origin = origin
        self.timelineID = timelineID
        self.workspaceIDs = Array(Set(workspaceIDs)).sorted { $0.uuidString < $1.uuidString }
    }

    /// Decodes by funnelling through the canonicalizing initializer.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let operationID = try container.decodeIfPresent(AtlasOperationID.self, forKey: .operationID)?.rawValue
        self.init(
            ascendantID: try container.decode(UUID.self, forKey: .ascendantID),
            shardID: try container.decode(AscendantShardID.self, forKey: .shardID),
            operationID: operationID,
            origin: try container.decode(AtlasOrigin.self, forKey: .origin),
            timelineID: try container.decodeIfPresent(UUID.self, forKey: .timelineID),
            workspaceIDs: try container.decodeIfPresent([UUID].self, forKey: .workspaceIDs) ?? []
        )
    }

    private enum CodingKeys: String, CodingKey {
        case ascendantID, shardID, operationID, origin, timelineID, workspaceIDs
    }
}

/// The source origin of Atlas activity.
public enum AtlasOrigin: String, Codable, Equatable, Hashable, Sendable {
    /// Ordinary work admitted through an Ascendant Turn.
    case ascendantTurn
    /// Work performed by a later Atlas integration.
    case atlasIntegration
    /// A host-authored operation.
    case host
}

/// A typed claim proposed by a Shard Report.
public struct AtlasReportClaim: Codable, Equatable, Hashable, Sendable {
    /// The stable semantic key.
    public let key: String
    /// The proposed typed value.
    public let value: AtlasValue
    /// The proposed semantic category.
    public let kind: AtlasItemKind
    /// Independent applicability policy.
    public let applicability: AtlasApplicability
    /// Independent disclosure policy.
    public let disclosure: AtlasDisclosure
    /// The source's epistemic status.
    public let epistemicStatus: AtlasEpistemicStatus

    /// Creates a typed report claim.
    public init(
        key: String,
        value: AtlasValue,
        kind: AtlasItemKind = .note,
        applicability: AtlasApplicability = .none,
        disclosure: AtlasDisclosure = .none,
        epistemicStatus: AtlasEpistemicStatus = .reported
    ) {
        self.key = key
        self.value = value
        self.kind = kind
        self.applicability = applicability.canonical
        self.disclosure = disclosure.canonical
        self.epistemicStatus = epistemicStatus
    }

    /// Decodes by funnelling through the canonicalizing initializer.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try container.decode(String.self, forKey: .key),
            value: try container.decode(AtlasValue.self, forKey: .value),
            kind: try container.decode(AtlasItemKind.self, forKey: .kind),
            applicability: try container.decode(AtlasApplicability.self, forKey: .applicability),
            disclosure: try container.decode(AtlasDisclosure.self, forKey: .disclosure),
            epistemicStatus: try container.decode(AtlasEpistemicStatus.self, forKey: .epistemicStatus)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case key, value, kind, applicability, disclosure, epistemicStatus
    }
}

/// One accepted semantic item.
public struct AtlasItem: Codable, Equatable, Hashable, Sendable {
    /// Stable item identity.
    public let id: AtlasItemID
    /// Owning Ascendant identity.
    public let ascendantID: UUID
    /// Shard that supplied the item.
    public let sourceShardID: AscendantShardID
    /// Stable semantic key.
    public let key: String
    /// Typed semantic value.
    public let value: AtlasValue
    /// Semantic category.
    public let kind: AtlasItemKind
    /// Independent applicability policy.
    public let applicability: AtlasApplicability
    /// Independent disclosure policy.
    public let disclosure: AtlasDisclosure
    /// Epistemic status.
    public let epistemicStatus: AtlasEpistemicStatus
    /// Item lifecycle.
    public let lifecycle: AtlasItemLifecycle
    /// Reference-only provenance.
    public let provenance: AtlasProvenance

    /// Creates an immutable accepted item.
    public init(
        id: AtlasItemID = AtlasItemID(),
        ascendantID: UUID,
        sourceShardID: AscendantShardID,
        key: String,
        value: AtlasValue,
        kind: AtlasItemKind = .note,
        applicability: AtlasApplicability = .none,
        disclosure: AtlasDisclosure = .none,
        epistemicStatus: AtlasEpistemicStatus = .reported,
        lifecycle: AtlasItemLifecycle = .active,
        provenance: AtlasProvenance
    ) {
        self.id = id
        self.ascendantID = ascendantID
        self.sourceShardID = sourceShardID
        self.key = key
        self.value = value
        self.kind = kind
        self.applicability = applicability.canonical
        self.disclosure = disclosure.canonical
        self.epistemicStatus = epistemicStatus
        self.lifecycle = lifecycle
        self.provenance = provenance
    }

    /// Creates an accepted item with textual content.
    public init(
        id: AtlasItemID = AtlasItemID(),
        ascendantID: UUID,
        sourceShardID: AscendantShardID,
        key: String,
        content: String,
        kind: AtlasItemKind = .note,
        applicability: AtlasApplicability = .none,
        disclosure: AtlasDisclosure = .none,
        epistemicStatus: AtlasEpistemicStatus = .reported,
        lifecycle: AtlasItemLifecycle = .active,
        provenance: AtlasProvenance
    ) {
        self.init(
            id: id,
            ascendantID: ascendantID,
            sourceShardID: sourceShardID,
            key: key,
            value: .text(content),
            kind: kind,
            applicability: applicability,
            disclosure: disclosure,
            epistemicStatus: epistemicStatus,
            lifecycle: lifecycle,
            provenance: provenance
        )
    }

    /// Decodes by funnelling through the canonicalizing initializer.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(AtlasItemID.self, forKey: .id),
            ascendantID: try container.decode(UUID.self, forKey: .ascendantID),
            sourceShardID: try container.decode(AscendantShardID.self, forKey: .sourceShardID),
            key: try container.decode(String.self, forKey: .key),
            value: try container.decode(AtlasValue.self, forKey: .value),
            kind: try container.decode(AtlasItemKind.self, forKey: .kind),
            applicability: try container.decode(AtlasApplicability.self, forKey: .applicability),
            disclosure: try container.decode(AtlasDisclosure.self, forKey: .disclosure),
            epistemicStatus: try container.decode(AtlasEpistemicStatus.self, forKey: .epistemicStatus),
            lifecycle: try container.decode(AtlasItemLifecycle.self, forKey: .lifecycle),
            provenance: try container.decode(AtlasProvenance.self, forKey: .provenance)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, ascendantID, sourceShardID, key, value, kind
        case applicability, disclosure, epistemicStatus, lifecycle, provenance
    }
}

/// A scoped conflict retained as accepted state.
public struct AtlasConflict: Codable, Equatable, Hashable, Sendable {
    /// Stable conflict identity.
    public let id: AtlasConflictID
    /// Owning Ascendant identity.
    public let ascendantID: UUID
    /// Shard that owns the conflict scope.
    public let shardID: AscendantShardID
    /// Referenced item identities.
    public let itemIDs: [AtlasItemID]
    /// Safe conflict summary.
    public let summary: String
    /// Independent applicability policy.
    public let applicability: AtlasApplicability
    /// Independent disclosure policy.
    public let disclosure: AtlasDisclosure
    /// Whether the conflict is resolved.
    public let isResolved: Bool
    /// Reference-only provenance.
    public let provenance: AtlasProvenance

    /// Creates an immutable conflict.
    public init(
        id: AtlasConflictID = AtlasConflictID(),
        ascendantID: UUID,
        shardID: AscendantShardID,
        itemIDs: [AtlasItemID],
        summary: String,
        applicability: AtlasApplicability = .none,
        disclosure: AtlasDisclosure = .none,
        isResolved: Bool = false,
        provenance: AtlasProvenance
    ) {
        self.id = id
        self.ascendantID = ascendantID
        self.shardID = shardID
        self.itemIDs = Array(Set(itemIDs)).sorted()
        self.summary = summary
        self.applicability = applicability.canonical
        self.disclosure = disclosure.canonical
        self.isResolved = isResolved
        self.provenance = provenance
    }

    /// Decodes by funnelling through the canonicalizing initializer.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(AtlasConflictID.self, forKey: .id),
            ascendantID: try container.decode(UUID.self, forKey: .ascendantID),
            shardID: try container.decode(AscendantShardID.self, forKey: .shardID),
            itemIDs: try container.decode([AtlasItemID].self, forKey: .itemIDs),
            summary: try container.decode(String.self, forKey: .summary),
            applicability: try container.decode(AtlasApplicability.self, forKey: .applicability),
            disclosure: try container.decode(AtlasDisclosure.self, forKey: .disclosure),
            isResolved: try container.decode(Bool.self, forKey: .isResolved),
            provenance: try container.decode(AtlasProvenance.self, forKey: .provenance)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, ascendantID, shardID, itemIDs, summary
        case applicability, disclosure, isResolved, provenance
    }
}

/// A typed advisory directive retained in accepted state.
public struct AtlasDirective: Codable, Equatable, Hashable, Sendable {
    /// Stable directive identity.
    public let id: AtlasDirectiveID
    /// Owning Ascendant identity.
    public let ascendantID: UUID
    /// Optional target Shard.
    public let shardID: AscendantShardID?
    /// Stable directive key.
    public let key: String
    /// Typed directive value.
    public let value: AtlasValue
    /// Independent applicability policy.
    public let applicability: AtlasApplicability
    /// Independent disclosure policy.
    public let disclosure: AtlasDisclosure
    /// Optional expiry.
    public let expiresAt: Date?
    /// Whether the directive is revoked.
    public let isRevoked: Bool
    /// Reference-only provenance.
    public let provenance: AtlasProvenance

    /// Creates an immutable advisory directive.
    public init(
        id: AtlasDirectiveID = AtlasDirectiveID(),
        ascendantID: UUID,
        shardID: AscendantShardID? = nil,
        key: String,
        value: AtlasValue,
        applicability: AtlasApplicability = .none,
        disclosure: AtlasDisclosure = .none,
        expiresAt: Date? = nil,
        isRevoked: Bool = false,
        provenance: AtlasProvenance
    ) {
        self.id = id
        self.ascendantID = ascendantID
        self.shardID = shardID
        self.key = key
        self.value = value
        self.applicability = applicability.canonical
        self.disclosure = disclosure.canonical
        self.expiresAt = expiresAt
        self.isRevoked = isRevoked
        self.provenance = provenance
    }

    /// Decodes by funnelling through the canonicalizing initializer.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(AtlasDirectiveID.self, forKey: .id),
            ascendantID: try container.decode(UUID.self, forKey: .ascendantID),
            shardID: try container.decodeIfPresent(AscendantShardID.self, forKey: .shardID),
            key: try container.decode(String.self, forKey: .key),
            value: try container.decode(AtlasValue.self, forKey: .value),
            applicability: try container.decode(AtlasApplicability.self, forKey: .applicability),
            disclosure: try container.decode(AtlasDisclosure.self, forKey: .disclosure),
            expiresAt: try container.decodeIfPresent(Date.self, forKey: .expiresAt),
            isRevoked: try container.decode(Bool.self, forKey: .isRevoked),
            provenance: try container.decode(AtlasProvenance.self, forKey: .provenance)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, ascendantID, shardID, key, value
        case applicability, disclosure, expiresAt, isRevoked, provenance
    }
}

/// The outcome attached to one Shard Report.
public enum ShardReportOutcome: Codable, Equatable, Hashable, Sendable {
    /// The Ascendant Turn completed successfully.
    case succeeded
    /// The Turn failed with a bounded reason code.
    case failed(reasonCode: String)
    /// The Turn was cancelled.
    case cancelled

    private enum CodingKeys: String, CodingKey { case kind, reasonCode }
    private enum Kind: String, Codable { case succeeded, failed, cancelled }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .succeeded: try container.encode(Kind.succeeded, forKey: .kind)
        case let .failed(reasonCode):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(reasonCode, forKey: .reasonCode)
        case .cancelled: try container.encode(Kind.cancelled, forKey: .kind)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .succeeded: self = .succeeded
        case .failed: self = .failed(reasonCode: try container.decode(String.self, forKey: .reasonCode))
        case .cancelled: self = .cancelled
        }
    }
}

/// A proposed report before the actor assigns its per-Shard sequence.
public struct ShardReportDraft: Codable, Equatable, Hashable, Sendable {
    /// Owning Ascendant identity.
    public let ascendantID: UUID
    /// Source Shard identity.
    public let shardID: AscendantShardID
    /// Correlated operation identity.
    public let operationID: AtlasOperationID
    /// Bounded human/source summary.
    public let content: String
    /// Typed claims, when a report proposes semantic items.
    public let claims: [AtlasReportClaim]
    /// Terminal Turn outcome.
    public let outcome: ShardReportOutcome
    /// Time at which the source activity occurred.
    public let occurredAt: Date
    /// Time at which the draft was recorded.
    public let recordedAt: Date
    /// Reference-only provenance.
    public let provenance: AtlasProvenance

    /// Creates an immutable report draft.
    public init(
        ascendantID: UUID,
        shardID: AscendantShardID,
        operationID: String,
        content: String,
        claims: [AtlasReportClaim] = [],
        outcome: ShardReportOutcome = .succeeded,
        occurredAt: Date = Date(timeIntervalSince1970: 0),
        recordedAt: Date = Date(timeIntervalSince1970: 0),
        provenance: AtlasProvenance
    ) {
        self.ascendantID = ascendantID
        self.shardID = shardID
        self.operationID = AtlasOperationID(operationID)
        self.content = content
        self.claims = claims
        self.outcome = outcome
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt
        self.provenance = provenance
    }
}

/// An immutable, actor-assigned Shard Report.
public struct AscendantShardReport: Codable, Equatable, Hashable, Sendable {
    /// Deterministic identity derived from Shard and operation identity.
    public let id: AtlasReportID
    /// Owning Ascendant identity.
    public let ascendantID: UUID
    /// Source Shard identity.
    public let shardID: AscendantShardID
    /// Actor-assigned monotonic sequence within the Shard.
    public let sequence: UInt64
    /// Correlated operation identity.
    public let operationID: AtlasOperationID
    /// Bounded human/source summary.
    public let content: String
    /// Typed claims, when present.
    public let claims: [AtlasReportClaim]
    /// Terminal Turn outcome.
    public let outcome: ShardReportOutcome
    /// Time at which source activity occurred.
    public let occurredAt: Date
    /// Time at which the report was recorded.
    public let recordedAt: Date
    /// Reference-only provenance.
    public let provenance: AtlasProvenance

    /// Creates an immutable report with an actor-assigned sequence.
    public init(draft: ShardReportDraft, sequence: UInt64) {
        self.id = AtlasReportID(shardID: draft.shardID, operationID: draft.operationID)
        self.ascendantID = draft.ascendantID
        self.shardID = draft.shardID
        self.sequence = sequence
        self.operationID = draft.operationID
        self.content = draft.content
        self.claims = draft.claims
        self.outcome = draft.outcome
        self.occurredAt = draft.occurredAt
        self.recordedAt = draft.recordedAt
        self.provenance = draft.provenance
    }
}

/// The public report spelling used by downstream Atlas integrations.
public typealias ShardReport = AscendantShardReport

/// Deterministic report identity derived from its Shard and operation.
public struct AtlasReportID: Codable, Hashable, Comparable, Sendable {
    /// The Shard identity.
    public let shardID: AscendantShardID
    /// The operation identity.
    public let operationID: AtlasOperationID

    /// Creates a deterministic report identity.
    public init(shardID: AscendantShardID, operationID: AtlasOperationID) {
        self.shardID = shardID
        self.operationID = operationID
    }

    /// Creates a deterministic report identity from a String operation ID.
    public init(shardID: AscendantShardID, operationID: String) {
        self.init(shardID: shardID, operationID: AtlasOperationID(operationID))
    }

    /// A stable textual identity for diagnostics and persistence keys.
    public var rawValue: String {
        "\(shardID.rawValue.uuidString.lowercased())/\(operationID.rawValue)"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.shardID, lhs.operationID) < (rhs.shardID, rhs.operationID)
    }
}

/// The latest consumed sequence for one Shard.
public struct AtlasWatermark: Codable, Equatable, Hashable, Comparable, Sendable {
    /// The Shard whose causal prefix was consumed.
    public let shardID: AscendantShardID
    /// The last consumed sequence.
    public let sequence: UInt64

    /// Creates a Shard watermark.
    public init(shardID: AscendantShardID, sequence: UInt64) {
        self.shardID = shardID
        self.sequence = sequence
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.shardID < rhs.shardID
    }
}

/// The two versions carried by an accepted Atlas state.
public struct AtlasVersion: Codable, Equatable, Hashable, Sendable {
    /// Advances for every accepted commit.
    public let stateVersion: UInt64
    /// Advances only for semantic operations.
    public let semanticRevision: UInt64

    /// Creates a version pair.
    public init(stateVersion: UInt64 = 0, semanticRevision: UInt64 = 0) {
        self.stateVersion = stateVersion
        self.semanticRevision = semanticRevision
    }
}

/// The immutable accepted state of one Ascendant Atlas.
public struct AscendantAtlas: Codable, Equatable, Hashable, Sendable {
    /// Current model schema version.
    public static let currentSchemaVersion = 1

    /// Schema version of this value.
    public let schemaVersion: Int
    /// Owning Ascendant identity.
    public let ascendantID: UUID
    /// Accepted state version.
    public let stateVersion: UInt64
    /// Accepted semantic revision.
    public let semanticRevision: UInt64
    /// Accepted items in canonical order.
    public let items: [AtlasItem]
    /// Accepted conflicts in canonical order.
    public let conflicts: [AtlasConflict]
    /// Accepted directives in canonical order.
    public let directives: [AtlasDirective]
    /// Consumed causal watermarks in canonical order.
    public let watermarks: [AtlasWatermark]

    /// Creates a canonical immutable Atlas state. The Shard catalog is owned
    /// by the store, not by versioned accepted state, so it does not appear
    /// here and cannot make replay ambiguous.
    public init(
        ascendantID: UUID,
        schemaVersion: Int = Self.currentSchemaVersion,
        stateVersion: UInt64 = 0,
        semanticRevision: UInt64 = 0,
        items: [AtlasItem] = [],
        conflicts: [AtlasConflict] = [],
        directives: [AtlasDirective] = [],
        watermarks: [AtlasWatermark] = []
    ) {
        self.schemaVersion = schemaVersion
        self.ascendantID = ascendantID
        self.stateVersion = stateVersion
        self.semanticRevision = semanticRevision
        self.items = items.sorted { $0.id < $1.id }
        self.conflicts = conflicts.sorted { $0.id < $1.id }
        self.directives = directives.sorted { $0.id < $1.id }
        self.watermarks = Self.canonicalWatermarks(watermarks)
    }

    /// Decodes by funnelling through the canonicalizing initializer so a
    /// decoded value can never contain unsorted or duplicate collections.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ascendantID: try container.decode(UUID.self, forKey: .ascendantID),
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            stateVersion: try container.decode(UInt64.self, forKey: .stateVersion),
            semanticRevision: try container.decode(UInt64.self, forKey: .semanticRevision),
            items: try container.decode([AtlasItem].self, forKey: .items),
            conflicts: try container.decode([AtlasConflict].self, forKey: .conflicts),
            directives: try container.decode([AtlasDirective].self, forKey: .directives),
            watermarks: try container.decode([AtlasWatermark].self, forKey: .watermarks)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, ascendantID, stateVersion, semanticRevision
        case items, conflicts, directives, watermarks
    }

    /// The version pair as a value.
    public var version: AtlasVersion {
        AtlasVersion(stateVersion: stateVersion, semanticRevision: semanticRevision)
    }

    /// The accepted watermark for a Shard, or zero when no prefix was consumed.
    public func watermark(for shardID: AscendantShardID) -> UInt64 {
        watermarks.first { $0.shardID == shardID }?.sequence ?? 0
    }

    /// Returns canonical JSON bytes for deterministic persistence and tests.
    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }

    fileprivate static func canonicalWatermarks(_ values: [AtlasWatermark]) -> [AtlasWatermark] {
        values.reduce(into: [AscendantShardID: AtlasWatermark]()) { result, watermark in
            if watermark.sequence >= (result[watermark.shardID]?.sequence ?? 0) {
                result[watermark.shardID] = watermark
            }
        }
            .values
            .sorted()
    }
}

/// The accepted state spelling used by Atlas integrations.
public typealias AscendantAtlasState = AscendantAtlas

/// A snapshot spelling for an immutable accepted Atlas state.
public typealias AtlasSnapshot = AscendantAtlas

/// A short spelling for an immutable integration capture.
public typealias AtlasCapture = AtlasIntegrationCapture

/// The value captured atomically before an integration runs.
public struct AtlasIntegrationCapture: Codable, Equatable, Sendable {
    /// Deterministic identity of this capture.
    public let id: AtlasCaptureID
    /// The immutable accepted state at capture time.
    public let state: AscendantAtlas
    /// The Shard catalog as it stood at capture time, in canonical order.
    public let registrations: [AscendantShard]
    /// The report watermark cut captured for integration.
    public let watermarks: [AtlasWatermark]
    /// Reports in the captured causal interval, in canonical order.
    public let pendingReports: [AscendantShardReport]

    /// The Ascendant identity from the captured state.
    public var ascendantID: UUID { state.ascendantID }
    /// State version required by compare-and-swap.
    public var baseStateVersion: UInt64 { state.stateVersion }
    /// Semantic revision projected by the captured state.
    public var baseSemanticRevision: UInt64 { state.semanticRevision }

    /// Alias used by integrations that call the captured report interval
    /// reports rather than pending reports.
    public var reports: [AscendantShardReport] { pendingReports }

    /// The captured watermark cut.
    public var capturedWatermarks: [AtlasWatermark] { watermarks }

    /// Creates an immutable capture.
    public init(
        id: AtlasCaptureID,
        state: AscendantAtlas,
        registrations: [AscendantShard] = [],
        watermarks: [AtlasWatermark],
        pendingReports: [AscendantShardReport]
    ) {
        self.id = id
        self.state = state
        self.registrations = registrations.sorted { $0.id < $1.id }
        self.watermarks = AscendantAtlas.canonicalWatermarks(watermarks)
        self.pendingReports = pendingReports.sorted {
            ($0.shardID, $0.sequence, $0.id) < ($1.shardID, $1.sequence, $1.id)
        }
    }

    /// Decodes by funnelling through the canonicalizing initializer.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(AtlasCaptureID.self, forKey: .id),
            state: try container.decode(AscendantAtlas.self, forKey: .state),
            registrations: try container.decodeIfPresent([AscendantShard].self, forKey: .registrations) ?? [],
            watermarks: try container.decode([AtlasWatermark].self, forKey: .watermarks),
            pendingReports: try container.decode([AscendantShardReport].self, forKey: .pendingReports)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, state, registrations, watermarks, pendingReports
    }
}

/// One operation in an accepted Atlas patch.
public enum AtlasPatchOperation: Codable, Equatable, Hashable, Sendable {
    /// Insert or replace an accepted item.
    case upsertItem(AtlasItem)
    /// Archive an accepted item.
    case archiveItem(AtlasItemID)
    /// Insert or replace a conflict.
    case upsertConflict(AtlasConflict)
    /// Mark an accepted conflict resolved.
    case resolveConflict(AtlasConflictID)
    /// Insert or replace an advisory directive.
    case upsertDirective(AtlasDirective)
    /// Revoke an accepted directive.
    case revokeDirective(AtlasDirectiveID)
    /// Advance only the causal watermark.
    case noOp

    /// Whether this operation changes prompt-visible semantic state.
    public var isSemantic: Bool {
        switch self {
        case .noOp: false
        default: true
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, item, itemID, conflict, conflictID, directive, directiveID }
    private enum Kind: String, Codable { case upsertItem, archiveItem, upsertConflict, resolveConflict, upsertDirective, revokeDirective, noOp }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .upsertItem(item):
            try container.encode(Kind.upsertItem, forKey: .kind)
            try container.encode(item, forKey: .item)
        case let .archiveItem(id):
            try container.encode(Kind.archiveItem, forKey: .kind)
            try container.encode(id, forKey: .itemID)
        case let .upsertConflict(conflict):
            try container.encode(Kind.upsertConflict, forKey: .kind)
            try container.encode(conflict, forKey: .conflict)
        case let .resolveConflict(id):
            try container.encode(Kind.resolveConflict, forKey: .kind)
            try container.encode(id, forKey: .conflictID)
        case let .upsertDirective(directive):
            try container.encode(Kind.upsertDirective, forKey: .kind)
            try container.encode(directive, forKey: .directive)
        case let .revokeDirective(id):
            try container.encode(Kind.revokeDirective, forKey: .kind)
            try container.encode(id, forKey: .directiveID)
        case .noOp:
            try container.encode(Kind.noOp, forKey: .kind)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .upsertItem: self = .upsertItem(try container.decode(AtlasItem.self, forKey: .item))
        case .archiveItem: self = .archiveItem(try container.decode(AtlasItemID.self, forKey: .itemID))
        case .upsertConflict: self = .upsertConflict(try container.decode(AtlasConflict.self, forKey: .conflict))
        case .resolveConflict: self = .resolveConflict(try container.decode(AtlasConflictID.self, forKey: .conflictID))
        case .upsertDirective: self = .upsertDirective(try container.decode(AtlasDirective.self, forKey: .directive))
        case .revokeDirective: self = .revokeDirective(try container.decode(AtlasDirectiveID.self, forKey: .directiveID))
        case .noOp: self = .noOp
        }
    }
}

/// A patch proposed against one immutable capture.
public struct AtlasPatch: Codable, Equatable, Hashable, Sendable {
    /// Stable patch identity.
    public let id: AtlasPatchID
    /// Owning Ascendant identity.
    public let ascendantID: UUID
    /// State version from which this patch was produced.
    public let baseStateVersion: UInt64
    /// Capture that supplied the patch inputs.
    public let captureID: AtlasCaptureID
    /// Reports the patch claims to consume.
    public let claimedReportIDs: [AtlasReportID]
    /// Watermark cut consumed by the patch.
    public let watermarks: [AtlasWatermark]
    /// Typed semantic operations.
    public let operations: [AtlasPatchOperation]
    /// Reference-only patch provenance.
    public let provenance: AtlasProvenance

    /// Creates a patch for a capture.
    public init(
        id: AtlasPatchID,
        capture: AtlasIntegrationCapture,
        operations: [AtlasPatchOperation],
        provenance: AtlasProvenance
    ) {
        self.init(
            id: id,
            ascendantID: capture.ascendantID,
            baseStateVersion: capture.baseStateVersion,
            captureID: capture.id,
            claimedReportIDs: capture.pendingReports.map(\.id),
            watermarks: capture.watermarks,
            operations: operations,
            provenance: provenance
        )
    }

    /// Creates a patch with explicit capture metadata.
    public init(
        id: AtlasPatchID,
        ascendantID: UUID,
        baseStateVersion: UInt64,
        captureID: AtlasCaptureID,
        claimedReportIDs: [AtlasReportID] = [],
        watermarks: [AtlasWatermark] = [],
        operations: [AtlasPatchOperation],
        provenance: AtlasProvenance
    ) {
        self.id = id
        self.ascendantID = ascendantID
        self.baseStateVersion = baseStateVersion
        self.captureID = captureID
        self.claimedReportIDs = Array(Set(claimedReportIDs)).sorted()
        self.watermarks = AscendantAtlas.canonicalWatermarks(watermarks)
        self.operations = operations
        self.provenance = provenance
    }

    /// Whether at least one operation changes semantic state.
    public var isSemantic: Bool { operations.contains(where: \.isSemantic) }

    /// Decodes by funnelling through the canonicalizing initializer.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(AtlasPatchID.self, forKey: .id),
            ascendantID: try container.decode(UUID.self, forKey: .ascendantID),
            baseStateVersion: try container.decode(UInt64.self, forKey: .baseStateVersion),
            captureID: try container.decode(AtlasCaptureID.self, forKey: .captureID),
            claimedReportIDs: try container.decode([AtlasReportID].self, forKey: .claimedReportIDs),
            watermarks: try container.decode([AtlasWatermark].self, forKey: .watermarks),
            operations: try container.decode([AtlasPatchOperation].self, forKey: .operations),
            provenance: try container.decode(AtlasProvenance.self, forKey: .provenance)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, ascendantID, baseStateVersion, captureID
        case claimedReportIDs, watermarks, operations, provenance
    }
}

/// One accepted patch and the versions it produced.
public struct AtlasAcceptedPatch: Codable, Equatable, Hashable, Sendable {
    /// The accepted patch.
    public let patch: AtlasPatch
    /// Version before acceptance.
    public let baseVersion: AtlasVersion
    /// Version after acceptance.
    public let resultingVersion: AtlasVersion
    /// Watermarks consumed by the patch.
    public let consumedWatermarks: [AtlasWatermark]

    /// Creates an accepted patch record.
    public init(
        patch: AtlasPatch,
        baseVersion: AtlasVersion,
        resultingVersion: AtlasVersion,
        consumedWatermarks: [AtlasWatermark]
    ) {
        self.patch = patch
        self.baseVersion = baseVersion
        self.resultingVersion = resultingVersion
        self.consumedWatermarks = AscendantAtlas.canonicalWatermarks(consumedWatermarks)
    }

    /// The patch identity.
    public var id: AtlasPatchID { patch.id }
    /// Resulting state version.
    public var stateVersion: UInt64 { resultingVersion.stateVersion }
    /// Resulting semantic revision.
    public var semanticRevision: UInt64 { resultingVersion.semanticRevision }

    /// Decodes by funnelling through the canonicalizing initializer.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            patch: try container.decode(AtlasPatch.self, forKey: .patch),
            baseVersion: try container.decode(AtlasVersion.self, forKey: .baseVersion),
            resultingVersion: try container.decode(AtlasVersion.self, forKey: .resultingVersion),
            consumedWatermarks: try container.decode([AtlasWatermark].self, forKey: .consumedWatermarks)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case patch, baseVersion, resultingVersion, consumedWatermarks
    }
}

/// The result of an accepted or idempotent compare-and-swap.
public struct AtlasCommitReceipt: Codable, Equatable, Hashable, Sendable {
    /// The accepted patch record.
    public let acceptedPatch: AtlasAcceptedPatch
    /// The resulting immutable state.
    public let state: AscendantAtlas
    /// Whether this call returned an already accepted patch.
    public let wasIdempotent: Bool

    /// Alias for integrations that describe a repeated commit as idempotent.
    public var idempotent: Bool { wasIdempotent }

    /// Creates a commit receipt.
    public init(acceptedPatch: AtlasAcceptedPatch, state: AscendantAtlas, wasIdempotent: Bool = false) {
        self.acceptedPatch = acceptedPatch
        self.state = state
        self.wasIdempotent = wasIdempotent
    }
}

/// The result of a Shard registration.
public struct AtlasRegistrationResult: Equatable, Sendable {
    /// The canonical registered Shard.
    public let shard: AscendantShard
    /// Whether this call added the Shard.
    public let wasInserted: Bool

    /// The registered Shard identity.
    public var id: AscendantShardID { shard.id }

    /// Creates a registration result.
    public init(shard: AscendantShard, wasInserted: Bool) {
        self.shard = shard
        self.wasInserted = wasInserted
    }
}

/// The result of appending a Shard Report.
public struct AtlasAppendResult: Equatable, Sendable {
    /// The canonical stored report.
    public let report: AscendantShardReport
    /// Whether this call added a new report.
    public let wasInserted: Bool

    /// The deterministic report identity.
    public var id: AtlasReportID { report.id }

    /// The actor-assigned per-Shard sequence.
    public var sequence: UInt64 { report.sequence }

    /// Creates an append result.
    public init(report: AscendantShardReport, wasInserted: Bool) {
        self.report = report
        self.wasInserted = wasInserted
    }
}
