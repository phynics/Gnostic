// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Whether a Timeline is discoverable on the live Gnostic network.
///
/// ADR 0008 lets ACP end a durable session record only on positive evidence
/// that the Timeline is gone. ``absent`` carries that evidence; ``indeterminate``
/// means discovery found no Node at all, which is the provider-liveness problem
/// tracked by #249 and never grounds for ending a record.
public enum TimelinePresence: Sendable, Equatable {
    case present(providerID: String)
    case ambiguous
    case absent
    case indeterminate
}

/// One discovery refresh, reusable for every Timeline identifier in a registry.
public struct TimelinePresenceSnapshot: Sendable, Equatable {
    private let providersByTimeline: [UUID: Set<String>]
    private let hasDiscoveredNode: Bool

    public init(providersByTimeline: [UUID: Set<String>], hasDiscoveredNode: Bool) {
        self.providersByTimeline = providersByTimeline
        self.hasDiscoveredNode = hasDiscoveredNode
    }

    /// Classifies one Timeline against this snapshot.
    public func presence(of timelineID: UUID) -> TimelinePresence {
        guard let providers = providersByTimeline[timelineID], !providers.isEmpty else {
            return hasDiscoveredNode ? .absent : .indeterminate
        }
        guard providers.count == 1, let providerID = providers.first else { return .ambiguous }
        return .present(providerID: providerID)
    }
}
