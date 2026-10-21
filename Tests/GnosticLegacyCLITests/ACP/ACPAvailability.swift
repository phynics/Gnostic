// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

/// Availability gates for ACP tests that drive a built executable or an
/// external client fixture instead of in-process types.
///
/// `make verify` sets `GNOSTIC_LEGACY_CLI_BINARY` and `GNOSTIC_LEGACY_SERVE_BINARY`.
/// `make acp-smoke` sets `GNOSTIC_ACP_BINARY` and both client fixtures. A
/// direct `swift test` sets none of them, so an unavailable test is reported as
/// skipped through `.enabled(if:)` instead of returning early and passing
/// without running.
enum ACPAvailability {
    /// The process environment value for `name`, or `nil` when it is unset or
    /// empty.
    ///
    /// - Parameter name: The environment variable name.
    /// - Returns: The non-empty value, or `nil`.
    static func environment(_ name: String) -> String? {
        let value = ProcessInfo.processInfo.environment[name]
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// The explicit ACP executable, which tests launch directly.
    static var hasACPBinary: Bool { environment("GNOSTIC_ACP_BINARY") != nil }

    /// Either executable that serves `gnostic acp`: the ACP binary or the CLI.
    static var hasACPCapableCLI: Bool {
        hasACPBinary || environment("GNOSTIC_LEGACY_CLI_BINARY") != nil
    }

    /// Either executable that serves `gnostic serve` or `gnostic acp`.
    static var hasServeCapableCLI: Bool {
        environment("GNOSTIC_LEGACY_SERVE_BINARY") != nil || hasACPCapableCLI
    }

    /// The pi-acp-client fixture entry point.
    static var hasPiClientFixture: Bool { environment("GNOSTIC_PI_ACP_CLIENT_FIXTURE") != nil }

    /// The official ACP client fixture entry point.
    static var hasOfficialClientFixture: Bool { environment("GNOSTIC_ACP_OFFICIAL_CLIENT") != nil }

    static let acpBinarySkipReason: Comment =
        "GNOSTIC_ACP_BINARY is unset, so this binary test is skipped. make acp-smoke sets it."

    static let acpCLISkipReason: Comment =
        "GNOSTIC_ACP_BINARY and GNOSTIC_LEGACY_CLI_BINARY are unset, so this binary test is skipped. make verify sets GNOSTIC_LEGACY_CLI_BINARY."

    static let serveCLISkipReason: Comment =
        "GNOSTIC_LEGACY_SERVE_BINARY, GNOSTIC_LEGACY_CLI_BINARY, and GNOSTIC_ACP_BINARY are unset, so this binary test is skipped. make verify sets the first two."

    static let piClientSkipReason: Comment =
        "GNOSTIC_ACP_BINARY or GNOSTIC_PI_ACP_CLIENT_FIXTURE is unset, so this binary test is skipped. make acp-smoke sets both."

    static let officialClientSkipReason: Comment =
        "GNOSTIC_ACP_BINARY or GNOSTIC_ACP_OFFICIAL_CLIENT is unset, so this binary test is skipped. make acp-smoke sets both."
}
