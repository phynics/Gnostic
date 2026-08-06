// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A single machine-readable reason for a narrative rejection.
public struct NarrativeRejectionReason: Hashable, Sendable {
    /// A stable machine-readable code.
    public let code: String
    /// A human-readable explanation for diagnostics.
    public let reason: String

    /// Creates a rejection reason.
    public init(code: String, reason: String) {
        self.code = code
        self.reason = reason
    }
}

/// An ErrorKit-compatible rejection produced when a narrative proposal cannot
/// be admitted. Rejections are inspectable in diagnostics but never reach the
/// store or the prompt.
public struct NarrativeRejection: Error, Sendable, LocalizedError, Equatable {
    /// The ordered, machine-readable reasons for the rejection.
    public let reasons: [NarrativeRejectionReason]

    /// Creates a rejection with one or more reasons.
    public init(reasons: [NarrativeRejectionReason]) {
        self.reasons = reasons
    }

    /// A human-readable description joining all reasons.
    public var errorDescription: String? {
        "Narrative proposal rejected: \(reasons.map(\.reason).joined(separator: "; "))"
    }

    /// A mapping of reason codes to their human-readable text for diagnostics.
    public var reasonByCode: [String: String] {
        Dictionary(uniqueKeysWithValues: reasons.map { ($0.code, $0.reason) })
    }
}