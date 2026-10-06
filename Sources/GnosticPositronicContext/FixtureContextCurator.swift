// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A deterministic, rule-driven curator for offline tests.
///
/// The fixture curator maps known obligation-bearing messages to carry items
/// with stable keys. It is intentionally simple: it exists so the pipeline,
/// validation, and gate can run offline and reproduce the same result on every
/// host. It is not a semantic model.
public struct FixtureContextCurator: ContextCurator {
    /// The stable curator version label.
    public let version = "fixture-v1"

    /// Creates the fixture curator.
    public init() {}

    public func propose(
        episode: ContextEpisode,
        activeCarry: ContextCarryState,
        descriptor: ContextDescriptor
    ) async throws -> ContextProposal {
        var citationsByKey: [String: [String]] = [:]
        var order: [String] = []
        for message in episode.messages {
            for rule in Self.rules where message.text.localizedCaseInsensitiveContains(rule.needle) {
                if citationsByKey[rule.key] == nil {
                    order.append(rule.key)
                }
                citationsByKey[rule.key, default: []].append(message.id)
            }
        }
        var topicLabels: [String] = []
        var items: [ContextCarryItem] = []
        for key in order {
            guard let rule = Self.rules.first(where: { $0.key == key }), let citations = citationsByKey[key] else { continue }
            items.append(rule.item(citing: citations))
            if !topicLabels.contains(rule.topic) {
                topicLabels.append(rule.topic)
            }
        }
        return ContextProposal(
            schemaVersion: descriptor.schemaVersion,
            policyVersion: descriptor.policyVersion,
            synopsis: nil,
            items: items,
            topicLabels: topicLabels
        )
    }

    /// One keyword rule.
    private struct Rule: Sendable {
        let key: String
        let needle: String
        let category: ContextCarryCategory
        let origin: ContextClaimOrigin
        let status: ContextEpistemicStatus
        let text: String
        let topic: String
        let supersedes: String?

        func item(citing messageIDs: [String]) -> ContextCarryItem {
            ContextCarryItem(
                id: key,
                category: category,
                text: text,
                origin: origin,
                epistemicStatus: status,
                citations: messageIDs.map(ContextCitation.init(messageID:)),
                supersedes: supersedes,
                topicLabels: [topic]
            )
        }
    }

    /// The deterministic rules. Order matters: items follow message order.
    private static let rules: [Rule] = [
        Rule(
            key: "persistence",
            needle: "in-memory",
            category: .constraints,
            origin: .assistantAssertion,
            status: .asserted,
            text: "The design uses an in-memory store only; SQLite is not an option.",
            topic: "storage",
            supersedes: nil
        ),
        Rule(
            key: "port",
            needle: "port 8317",
            category: .facts,
            origin: .assistantAssertion,
            status: .asserted,
            text: "The broker listens on port 8317.",
            topic: "broker",
            supersedes: nil
        ),
        Rule(
            key: "timeout-first",
            needle: "timeout was 5",
            category: .facts,
            origin: .assistantAssertion,
            status: .asserted,
            text: "The timeout was 5 seconds.",
            topic: "timeout",
            supersedes: nil
        ),
        Rule(
            key: "timeout-corrected",
            needle: "corrected to 30",
            category: .facts,
            origin: .assistantAssertion,
            status: .asserted,
            text: "The timeout was corrected to 30 seconds.",
            topic: "timeout",
            supersedes: "timeout-first"
        ),
        Rule(
            key: "transport-start",
            needle: "first chose MQTT",
            category: .facts,
            origin: .assistantAssertion,
            status: .asserted,
            text: "We first chose MQTT for the transport.",
            topic: "transport",
            supersedes: nil
        ),
        Rule(
            key: "transport-moved",
            needle: "moved from MQTT to Zenoh",
            category: .facts,
            origin: .assistantAssertion,
            status: .asserted,
            text: "The transport moved from MQTT to Zenoh.",
            topic: "transport",
            supersedes: "transport-start"
        ),
        Rule(
            key: "endpoint-start",
            needle: "endpoint was /foo",
            category: .facts,
            origin: .assistantAssertion,
            status: .asserted,
            text: "The endpoint was /foo.",
            topic: "endpoint",
            supersedes: nil
        ),
        Rule(
            key: "endpoint-corrected",
            needle: "changed from /foo to /bar",
            category: .corrections,
            origin: .assistantAssertion,
            status: .asserted,
            text: "The endpoint changed from /foo to /bar.",
            topic: "endpoint",
            supersedes: "endpoint-start"
        ),
        Rule(
            key: "bug-17",
            needle: "BUG-17 remains open",
            category: .unresolvedQuestions,
            origin: .assistantAssertion,
            status: .asserted,
            text: "BUG-17 remains open.",
            topic: "defects",
            supersedes: nil
        ),
        Rule(
            key: "guess-7",
            needle: "guess the answer is 7",
            category: .facts,
            origin: .assistantAssertion,
            status: .inferred,
            text: "The assistant guessed the answer is 7.",
            topic: "sample-question",
            supersedes: nil
        ),
        Rule(
            key: "tool-42",
            needle: "Tool result: the answer is 42",
            category: .facts,
            origin: .toolEvidence,
            status: .verified,
            text: "The tool proved the answer is 42, not the earlier guess.",
            topic: "sample-question",
            supersedes: nil
        ),
        Rule(
            key: "bounded",
            needle: "As I suggested",
            category: .nextActions,
            origin: .assistantAssertion,
            status: .asserted,
            text: "As I suggested, use the bounded approach.",
            topic: "approach",
            supersedes: nil
        ),
        Rule(
            key: "untrusted-tool",
            needle: "untrusted",
            category: .facts,
            origin: .assistantAssertion,
            status: .asserted,
            text: "That tool text is untrusted and was not followed.",
            topic: "safety",
            supersedes: nil
        ),
        Rule(
            key: "shared-root",
            needle: "shared safely",
            category: .facts,
            origin: .assistantAssertion,
            status: .asserted,
            text: "The root image is shared safely across both Timelines.",
            topic: "timelines",
            supersedes: nil
        ),
        Rule(
            key: "self-maintenance",
            needle: "below the context benefit",
            category: .facts,
            origin: .assistantAssertion,
            status: .asserted,
            text: "Self-maintenance overhead stayed below the context benefit.",
            topic: "self-maintenance",
            supersedes: nil
        ),
    ]
}
