// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A safe failure ready for the Axoloty Call/Return boundary.
public struct GnosticPublicFailure: Sendable, Equatable {
    public let code: Int
    public let message: String

    public let retryable: Bool

    public init(code: Int, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}
