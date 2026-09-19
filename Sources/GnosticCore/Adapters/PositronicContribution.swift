// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKContracts
import PositronicKit

/// Gnostic-owned identity for one admitted Positronic Turn.
///
/// A contribution reads this from ``PositronicTurnInvocationContext/current``
/// while PositronicKit prepares the Turn, so the bounded context it projects and
/// the record it later writes can be correlated to the same Gnostic Turn.
public struct PositronicTurnInvocation: Sendable, Equatable {
    /// The Gnostic-owned Ascendant identifier.
    public let ascendantID: UUID
    /// The Gnostic-owned Timeline the Turn runs on.
    public let timelineID: UUID
    /// The admitted client Turn identifier, or `nil` for an unidentified Turn.
    public let turnID: String?

    /// Creates the invocation identity for one admitted Turn.
    public init(ascendantID: UUID, timelineID: UUID, turnID: String?) {
        self.ascendantID = ascendantID
        self.timelineID = timelineID
        self.turnID = turnID
    }
}

/// The Turn-scoped invocation context a Positronic contribution reads.
///
/// The adapter scopes this value to the Turn it is running, so a contribution's
/// context source observes the same Ascendant, Timeline, and client Turn that
/// the host admitted.
public enum PositronicTurnInvocationContext {
    /// The invocation for the Turn running on the current task, if any.
    @TaskLocal public static var current: PositronicTurnInvocation?
}

/// A generic, typed extension of one Positronic Ascendant.
///
/// A contribution is compiled in and selected statically. It may expose
/// additional tools and one bounded Turn context source. It cannot register
/// pipeline stages, replace the prompt tree, or remove another contribution's
/// tool. ``label`` is a static identifier: it must not carry user payloads,
/// secrets, or free-form text, because it appears in diagnostics.
public protocol PositronicContribution: Sendable {
    /// A static label used in diagnostics and collision messages.
    var label: String { get }
    /// Additional tools this contribution exposes.
    ///
    /// - Returns: The contributed tools, or an empty array.
    func tools() -> [AnyTool]
    /// The bounded, namespaced Turn context source this contribution supplies.
    ///
    /// - Returns: The source, or `nil` when the contribution supplies no context.
    func turnContextSource() -> (any TurnContextSource)?
}

public extension PositronicContribution {
    /// A contribution that exposes no tools.
    ///
    /// - Returns: An empty tool list.
    func tools() -> [AnyTool] { [] }

    /// A contribution that supplies no Turn context.
    ///
    /// - Returns: `nil`.
    func turnContextSource() -> (any TurnContextSource)? { nil }
}

/// The collision-checked contribution surface for one Ascendant.
///
/// The surface resolves a contribution list once, at construction, so duplicate
/// or reserved identities cannot be published. The adapter appends ``tools`` to
/// the Turn tool list and installs ``turnContextSource`` in the PositronicKit
/// runtime customization.
struct PositronicContributionSurface: Sendable {
    /// The longest accepted static contribution label.
    static let maximumLabelLength = 64

    /// The contributed tools, in contribution order.
    let tools: [AnyTool]
    /// The composite Turn context source, or `nil` when no contribution supplies one.
    let turnContextSource: (any TurnContextSource)?

    /// Resolves and validates a contribution list.
    ///
    /// - Parameters:
    ///   - contributions: The statically selected contributions.
    ///   - reservedTools: Tools the contribution cannot override: Workspace and
    ///     Gnostic network tools known at construction.
    ///   - recordNotice: Persists one static, payload-free host notice for an
    ///     optional contribution failure.
    /// - Throws: ``AscendantBackendError/invalidConfiguration(_:)`` when a label
    ///   or tool identity/call name is invalid, duplicated, or reserved.
    init(
        contributions: [any PositronicContribution],
        reservedTools: [AnyTool],
        recordNotice: @escaping @Sendable (_ turnID: UUID, _ message: String) async -> Void
    ) throws {
        var resolvedTools: [AnyTool] = []
        var seenLabels = Set<String>()
        var seenIdentities = Set<ToolReference>()
        var seenCallNames = Set<String>()
        var entries: [CompositeTurnContextSource.Entry] = []
        let restricted = Self.reservedIdentitiesAndCallNames(in: reservedTools)

        for contribution in contributions {
            let label = contribution.label
            try Self.validate(label: label, alreadySeen: seenLabels)
            seenLabels.insert(label)

            for tool in contribution.tools() {
                let callName = tool.callName
                guard seenIdentities.insert(tool.identity).inserted,
                      seenCallNames.insert(callName).inserted else {
                    throw AscendantBackendError.invalidConfiguration(
                        "Positronic contribution '\(label)' exposes tool '\(callName)' with a duplicate identity or call name."
                    )
                }
                guard !restricted.identities.contains(tool.identity),
                      !restricted.callNames.contains(callName) else {
                    throw AscendantBackendError.invalidConfiguration(
                        "Positronic contribution '\(label)' exposes tool '\(callName)', which collides with a Workspace or network tool."
                    )
                }
                resolvedTools.append(tool)
            }

            if let source = contribution.turnContextSource() {
                entries.append(.init(label: label, source: source))
            }
        }

        tools = resolvedTools
        turnContextSource = entries.isEmpty
            ? nil
            : CompositeTurnContextSource(entries: entries, recordNotice: recordNotice)
    }

    /// Rejects tools that collide with a reserved set of existing tools.
    ///
    /// - Parameters:
    ///   - tools: The contributed tools to check.
    ///   - reserved: The Workspace or network tools they cannot override.
    /// - Throws: ``AscendantBackendError/invalidConfiguration(_:)`` on a collision.
    static func validate(_ tools: [AnyTool], against reserved: [AnyTool]) throws {
        let restricted = reservedIdentitiesAndCallNames(in: reserved)
        for tool in tools
        where restricted.identities.contains(tool.identity)
            || restricted.callNames.contains(tool.callName) {
            throw AscendantBackendError.invalidConfiguration(
                "Positronic contribution tool '\(tool.callName)' collides with a Workspace or network tool."
            )
        }
    }

    private static func validate(label: String, alreadySeen: Set<String>) throws {
        guard !label.isEmpty, label.count <= maximumLabelLength else {
            throw AscendantBackendError.invalidConfiguration(
                "A Positronic contribution label must be non-empty and at most \(maximumLabelLength) characters."
            )
        }
        guard label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }) else {
            throw AscendantBackendError.invalidConfiguration(
                "Positronic contribution label '\(label)' contains unsupported characters."
            )
        }
        guard !alreadySeen.contains(label) else {
            throw AscendantBackendError.invalidConfiguration(
                "Positronic contribution label '\(label)' is duplicated."
            )
        }
    }

    private static func reservedIdentitiesAndCallNames(
        in tools: [AnyTool]
    ) -> (identities: Set<ToolReference>, callNames: Set<String>) {
        (Set(tools.map(\.identity)), Set(tools.map(\.callName)))
    }
}

/// A composite ``TurnContextSource`` over an ordered contribution list.
///
/// A required source failure rethrows so PositronicKit aborts preparation before
/// provider work. An optional source failure is contained: the composite records
/// a static host notice through ``recordNotice`` and continues with the other
/// sources. The notice never carries the source error, a payload, or a secret.
private struct CompositeTurnContextSource: TurnContextSource {
    struct Entry: Sendable {
        let label: String
        let source: any TurnContextSource
    }

    let entries: [Entry]
    let recordNotice: @Sendable (_ turnID: UUID, _ message: String) async -> Void

    /// The composite never throws for an optional entry, so a throw is a
    /// required failure that must abort preparation.
    var failureRequirement: TurnContextContributionRequirement { .required }

    func contributions(for request: TurnContextRequest) async throws -> [TurnContextContribution] {
        var resolved: [TurnContextContribution] = []
        var seenIDs = Set<UUID>()
        var seenKeys = Set<String>()
        for entry in entries {
            do {
                let values = try await entry.source.contributions(for: request)
                for value in values {
                    let key = "\(value.namespace).\(value.key)"
                    guard seenIDs.insert(value.id).inserted, seenKeys.insert(key).inserted else { continue }
                    resolved.append(value)
                }
            } catch {
                if error is CancellationError { throw error }
                guard entry.source.failureRequirement == .optional else { throw error }
                await recordNotice(request.turnID, Self.noticeMessage(for: entry.label))
            }
        }
        return resolved
    }

    /// A bounded, payload-free notice for one failed optional contribution.
    private static func noticeMessage(for label: String) -> String {
        "The optional Turn context contribution '\(label)' failed; the Turn continued without it."
    }
}
