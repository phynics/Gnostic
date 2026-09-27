// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Redacts configured values across arbitrary pipe-read boundaries.
final class ACPStderrRedactor: @unchecked Sendable { // SAFETY: Buffered text is accessed only while holding lock.
    private let lock = NSLock()
    private let secrets: [String]
    private var pending = ""

    init(secrets: [String]) {
        self.secrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    func consume(_ data: Data, finishing: Bool = false) -> Data {
        lock.lock()
        defer { lock.unlock() }

        pending += String(decoding: data, as: UTF8.self)
        let output: String
        if finishing {
            output = pending
            pending = ""
        } else {
            let retainedCharacters = max(0, (secrets.first?.count ?? 1) - 1)
            guard pending.count > retainedCharacters else { return Data() }
            let boundary = pending.index(pending.endIndex, offsetBy: -retainedCharacters)
            var emitted = String(pending[..<boundary])
            pending = String(pending[boundary...])
            var holdbackLength = 0
            for secret in secrets {
                for prefixLength in 1..<secret.count
                where prefixLength > holdbackLength && emitted.hasSuffix(String(secret.prefix(prefixLength))) {
                    holdbackLength = prefixLength
                }
            }
            if holdbackLength > 0 {
                let holdbackStart = emitted.index(emitted.endIndex, offsetBy: -holdbackLength)
                pending = String(emitted[holdbackStart...]) + pending
                emitted = String(emitted[..<holdbackStart])
            }
            output = emitted
        }
        let redacted = secrets.reduce(output) { $0.replacingOccurrences(of: $1, with: "[REDACTED]") }
        return Data(redacted.utf8)
    }
}
