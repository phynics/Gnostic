// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The immutable inputs one Ascendant Brief projection reads.
///
/// The accepted state is the exact invocation snapshot pinned for the Turn, and
/// the registrations are the canonical Shard catalog at projection time. The
/// catalog is Shard lifecycle metadata, not versioned accepted state, so it is
/// supplied alongside the snapshot rather than from it.
public struct AscendantBriefContext: Equatable, Sendable {
    /// The Ascendant the projection belongs to.
    public let ascendantID: UUID
    /// The exact accepted Atlas snapshot projected for the Turn.
    public let snapshot: AtlasSnapshot
    /// The canonical registered Shard catalog.
    public let registrations: [AscendantShard]

    /// Creates a projection context.
    public init(ascendantID: UUID, snapshot: AtlasSnapshot, registrations: [AscendantShard]) {
        self.ascendantID = ascendantID
        self.snapshot = snapshot
        self.registrations = registrations
    }
}

/// A deterministic, bounded projection of accepted Atlas state for one Shard.
///
/// The brief is prompt text and never runtime authority. It carries the exact
/// semantic revision it was projected from so a reader can correlate the prompt
/// with the accepted state without the revision becoming part of the section
/// identity.
public struct AscendantBrief: Equatable, Sendable {
    /// The Ascendant the brief was projected for.
    public let ascendantID: UUID
    /// The target Shard the brief applies to.
    public let shardID: AscendantShardID
    /// The accepted revision the brief was projected from.
    public let revision: AtlasVersion
    /// The rendered, bounded brief text.
    public let text: String
    /// The number of whole items retained.
    public let includedItemCount: Int
    /// The number of whole conflicts retained.
    public let includedConflictCount: Int
    /// The number of whole directives retained.
    public let includedDirectiveCount: Int

    /// Creates a projected brief.
    public init(
        ascendantID: UUID,
        shardID: AscendantShardID,
        revision: AtlasVersion,
        text: String,
        includedItemCount: Int,
        includedConflictCount: Int,
        includedDirectiveCount: Int
    ) {
        self.ascendantID = ascendantID
        self.shardID = shardID
        self.revision = revision
        self.text = text
        self.includedItemCount = includedItemCount
        self.includedConflictCount = includedConflictCount
        self.includedDirectiveCount = includedDirectiveCount
    }
}

/// A stable, payload-free reason one brief projection produced no section.
public enum AscendantBriefDiagnosticReason: String, Codable, Equatable, Hashable, Sendable {
    /// The brief provider failed before returning any input.
    case providerFailed
    /// The accepted state or target Shard belongs to a different Ascendant.
    case identityMismatch
    /// The target Shard is not registered.
    case unknownShard
    /// The target Shard is detached or archived.
    case inactiveShard

    /// A fixed, redacted message. It deliberately carries no payload.
    public var message: String {
        switch self {
        case .providerFailed:
            "The Atlas Ascendant Brief provider failed; no brief was projected."
        case .identityMismatch:
            "The Atlas Ascendant Brief binding does not match the active Ascendant."
        case .unknownShard:
            "The Atlas Ascendant Brief target Shard is not registered."
        case .inactiveShard:
            "The Atlas Ascendant Brief target Shard is not active."
        }
    }
}

/// A structured, redacted diagnostic for one failed or rejected projection.
///
/// The value carries only a stable reason and identity fields. Provider errors,
/// item values, conflict summaries, and directive values are deliberately
/// absent, so publishing a diagnostic cannot leak payload.
public struct AscendantBriefDiagnostic: Codable, Equatable, Hashable, Sendable {
    /// The stable failure classification.
    public let reason: AscendantBriefDiagnosticReason
    /// The owning Ascendant.
    public let ascendantID: UUID
    /// The target Shard.
    public let shardID: AscendantShardID

    /// Creates a redacted diagnostic.
    public init(reason: AscendantBriefDiagnosticReason, ascendantID: UUID, shardID: AscendantShardID) {
        self.reason = reason
        self.ascendantID = ascendantID
        self.shardID = shardID
    }

    /// A fixed, redacted message.
    public var message: String { reason.message }
}

/// A host seam that receives redacted brief diagnostics.
public protocol AscendantBriefDiagnosticObserver: Sendable {
    /// Observes one redacted diagnostic.
    func observe(_ diagnostic: AscendantBriefDiagnostic) async
}

/// An observer that discards diagnostics.
public struct AscendantBriefNullDiagnosticObserver: AscendantBriefDiagnosticObserver {
    /// Creates a null observer.
    public init() {}

    /// Discards the diagnostic.
    public func observe(_: AscendantBriefDiagnostic) async {}
}

/// Supplies the accepted state and Shard catalog one brief projection reads.
///
/// The provider is intentionally throwing so a durable or remote source can
/// fail closed. A failure yields no section and a redacted diagnostic; it never
/// aborts the Turn. There is no brief cache: every projection reads the source
/// once.
public protocol AscendantBriefProvider: Sendable {
    /// Returns one immutable projection context.
    func context() async throws -> AscendantBriefContext
}

/// An ``AscendantBriefProvider`` over one in-process Atlas store.
public struct AtlasStoreBriefProvider: AscendantBriefProvider {
    private let store: any AtlasStore

    /// Creates a provider over one store.
    public init(store: any AtlasStore) {
        self.store = store
    }

    /// Reads the current snapshot and canonical catalog.
    public func context() async throws -> AscendantBriefContext {
        let snapshot = await store.snapshot()
        let registrations = await store.registrations()
        return AscendantBriefContext(
            ascendantID: snapshot.ascendantID,
            snapshot: snapshot,
            registrations: registrations
        )
    }
}

/// The outcome of one brief projection attempt.
public enum AscendantBriefOutcome: Equatable, Sendable {
    /// A bounded brief was produced.
    case projected(AscendantBrief)
    /// The target binding was rejected and no section is emitted.
    case rejected(AscendantBriefDiagnosticReason)
    /// No eligible accepted state existed and no section is emitted.
    case empty
}

/// The pure, deterministic Ascendant Brief projector.
///
/// Applicability and disclosure are independent gates: a broad applicability
/// can never widen a narrow disclosure. Only active items from active Shards,
/// unresolved conflicts, and unexpired non-revoked directives are eligible.
/// Entries are sorted canonically, so insertion order cannot change the
/// rendered bytes, and the strict character budget retains whole entries only.
public struct AscendantBriefProjector: Sendable {
    /// The strict budget, in characters, for one rendered brief.
    public static let maximumCharacters = 512
    /// The stable Positronic section namespace.
    public static let sectionNamespace = "atlas"
    /// The stable Positronic section key.
    public static let sectionKey = "context"

    static let openingDelimiter = "<<<atlas-brief>>>"
    static let closingDelimiter = "<<<end-atlas-brief>>>"

    /// Creates a projector.
    public init() {}

    /// Projects one bounded brief for the target Shard.
    ///
    /// - Parameters:
    ///   - context: The immutable snapshot and Shard catalog.
    ///   - targetShardID: The Shard the brief applies to.
    ///   - now: The instant used to test directive expiry, injected for
    ///     deterministic tests.
    /// - Returns: A projected brief, a rejection, or an empty outcome.
    public func project(
        context: AscendantBriefContext,
        targetShardID: AscendantShardID,
        now: Date
    ) -> AscendantBriefOutcome {
        guard context.snapshot.ascendantID == context.ascendantID else {
            return .rejected(.identityMismatch)
        }
        guard let target = context.registrations.first(where: { $0.id == targetShardID }) else {
            return .rejected(.unknownShard)
        }
        guard target.ascendantID == context.ascendantID else {
            return .rejected(.identityMismatch)
        }
        guard target.lifecycle == .active else {
            return .rejected(.inactiveShard)
        }

        let activeShards = Set(
            context.registrations.filter { $0.lifecycle == .active }.map(\.id)
        )
        let snapshot = context.snapshot

        let items = snapshot.items
            .filter { item in
                item.ascendantID == context.ascendantID
                    && item.lifecycle == .active
                    && item.epistemicStatus != .retracted
                    && activeShards.contains(item.sourceShardID)
                    && Self.isApplicable(item.applicability, target: targetShardID)
                    && Self.isDisclosed(item.disclosure, target: targetShardID)
            }
            .sorted { ($0.key, $0.id) < ($1.key, $1.id) }

        let conflicts = snapshot.conflicts
            .filter { conflict in
                conflict.ascendantID == context.ascendantID
                    && !conflict.isResolved
                    && activeShards.contains(conflict.shardID)
                    && Self.isApplicable(conflict.applicability, target: targetShardID)
                    && Self.isDisclosed(conflict.disclosure, target: targetShardID)
            }
            .sorted { ($0.shardID, $0.id) < ($1.shardID, $1.id) }

        let directives = snapshot.directives
            .filter { directive in
                directive.ascendantID == context.ascendantID
                    && !directive.isRevoked
                    && !Self.isExpired(directive, now: now)
                    && (directive.shardID.map { activeShards.contains($0) } ?? true)
                    && Self.isApplicable(directive.applicability, target: targetShardID)
                    && Self.isDisclosed(directive.disclosure, target: targetShardID)
            }
            .sorted { ($0.key, $0.id) < ($1.key, $1.id) }

        guard !items.isEmpty || !conflicts.isEmpty || !directives.isEmpty else {
            return .empty
        }

        var text = Self.frame(for: snapshot, targetShardID: targetShardID)
        let closing = Self.closingDelimiter + "\n"
        guard (text + closing).count <= Self.maximumCharacters else { return .empty }

        var itemsStarted = false
        var conflictsStarted = false
        var directivesStarted = false
        var includedItems = 0
        var includedConflicts = 0
        var includedDirectives = 0

        func append(sectionTitle: String, started: inout Bool, line: String) -> Bool {
            let prefix = started ? "" : sectionTitle + "\n"
            let candidate = text + prefix + line + "\n" + closing
            guard candidate.count <= Self.maximumCharacters else { return false }
            text += prefix + line + "\n"
            started = true
            return true
        }

        for item in items {
            if append(sectionTitle: "items:", started: &itemsStarted, line: Self.render(item)) {
                includedItems += 1
            }
        }
        for conflict in conflicts {
            if append(sectionTitle: "conflicts:", started: &conflictsStarted, line: Self.render(conflict)) {
                includedConflicts += 1
            }
        }
        for directive in directives {
            if append(sectionTitle: "directives:", started: &directivesStarted, line: Self.render(directive)) {
                includedDirectives += 1
            }
        }

        guard includedItems + includedConflicts + includedDirectives > 0 else { return .empty }
        text += closing

        return .projected(AscendantBrief(
            ascendantID: context.ascendantID,
            shardID: targetShardID,
            revision: snapshot.version,
            text: text,
            includedItemCount: includedItems,
            includedConflictCount: includedConflicts,
            includedDirectiveCount: includedDirectives
        ))
    }

    // MARK: - Policy

    private static func isApplicable(_ policy: AtlasApplicability, target: AscendantShardID) -> Bool {
        switch policy {
        case .none: false
        case .ascendant: true
        case let .shards(ids): ids.contains(target)
        }
    }

    private static func isDisclosed(_ policy: AtlasDisclosure, target: AscendantShardID) -> Bool {
        switch policy {
        case .none: false
        case .ascendant: true
        case let .shards(ids): ids.contains(target)
        }
    }

    private static func isExpired(_ directive: AtlasDirective, now: Date) -> Bool {
        guard let expiresAt = directive.expiresAt else { return false }
        return expiresAt <= now
    }

    // MARK: - Rendering

    private static func frame(for snapshot: AscendantAtlas, targetShardID: AscendantShardID) -> String {
        openingDelimiter + "\n"
            + "revision=\(snapshot.semanticRevision) state=\(snapshot.stateVersion) "
            + "shard=\(targetShardID.rawValue.uuidString.lowercased())\n"
    }

    private static func render(_ item: AtlasItem) -> String {
        "- item key=\(quoted(item.key)) kind=\(item.kind.rawValue) value=\(render(item.value))"
    }

    private static func render(_ conflict: AtlasConflict) -> String {
        "- conflict shard=\(conflict.shardID.rawValue.uuidString.lowercased()) "
            + "summary=\(quoted(conflict.summary))"
    }

    private static func render(_ directive: AtlasDirective) -> String {
        "- directive key=\(quoted(directive.key)) value=\(render(directive.value))"
    }

    /// Renders a typed Atlas value as untrusted quoted data. Text values are
    /// quoted and escaped; structured values are rendered structurally.
    static func render(_ value: AtlasValue) -> String {
        switch value {
        case let .text(text):
            quoted(text)
        case let .integer(value):
            String(value)
        case let .decimal(value):
            value.canonical
        case let .boolean(value):
            value ? "true" : "false"
        case let .date(value):
            String(Int64((value.timeIntervalSince1970 * 1_000).rounded()))
        case let .list(values):
            "[" + values.map(render).joined(separator: ",") + "]"
        case let .record(entries):
            "{" + entries.sorted().map { quoted($0.key) + "=" + render($0.value) }.joined(separator: ",") + "}"
        }
    }

    /// Quotes and escapes one untrusted string.
    static func quoted(_ value: String) -> String {
        "\"" + escaped(value) + "\""
    }

    /// Escapes every character that could forge a delimiter or break quoting.
    static func escaped(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "<": result += "\\<"
            case ">": result += "\\>"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.append(character)
            }
        }
        return result
    }
}
