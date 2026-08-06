// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A deterministic policy that drives when a deliberate narrative checkpoint is
/// requested and how many sections the stable base keeps afterwards.
public struct NarrativeCheckpointPolicy: Sendable, Equatable {
    /// The appended-message threshold that warrants a checkpoint.
    public let thresholdAppendedMessages: Int
    /// The maximum number of sections retained in the stable base after a
    /// checkpoint.
    public let stableBaseCapCount: Int

    /// Creates a checkpoint policy.
    public init(thresholdAppendedMessages: Int, stableBaseCapCount: Int) {
        self.thresholdAppendedMessages = thresholdAppendedMessages
        self.stableBaseCapCount = stableBaseCapCount
    }

    /// The default policy: checkpoint after 5 appended messages, keeping at most
    /// 4 stable sections.
    public static let `default` = NarrativeCheckpointPolicy(
        thresholdAppendedMessages: 5,
        stableBaseCapCount: 4
    )
}