// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticProtocol

/// Validated configuration values needed to describe an ACP agent process.
///
/// The launch specification is configuration data only; the backend owns the
/// process lifecycle described by this value.
public struct ACPLaunchSpec: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The executable command used to start the agent.
    public let command: String
    /// Arguments passed to the command in order.
    public let arguments: [String]
    /// Optional current working directory for the process.
    public let workingDirectory: String?
    /// Explicitly allowlisted environment values, including configured secrets.
    /// Do not log or include this dictionary in diagnostics.
    public let environment: [String: String]
    /// Optional display name for the external agent.
    public let displayName: String?
    /// Stable identity of the launch configuration, excluding environment
    /// values so configured secrets never enter identity or diagnostics.
    public let launchFingerprint: String

    /// A safe summary that identifies environment keys without showing values.
    public var description: String {
        let summary = "ACPLaunchSpec(command: \(command), arguments: \(arguments), workingDirectory: \(String(describing: workingDirectory)), environmentKeys: \(environment.keys.sorted()), displayName: \(String(describing: displayName)))"
        return environment.values
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .reduce(summary) { $0.replacingOccurrences(of: $1, with: "[REDACTED]") }
    }

    /// A safe debugging summary that never includes environment values.
    public var debugDescription: String { description }

    init(
        command: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        displayName: String?
    ) {
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.displayName = displayName
        launchFingerprint = Self.fingerprint(
            command: command,
            arguments: arguments,
            environmentNames: environment.keys.sorted()
        )
    }

    private static func fingerprint(
        command: String,
        arguments: [String],
        environmentNames: [String]
    ) -> String {
        let components = ["gnostic-runtime-launch-v1", "command", command, "arguments", String(arguments.count)]
            + arguments
            + ["environment", String(environmentNames.count)]
            + environmentNames
        var bytes: [UInt8] = []
        for component in components {
            let value = Array(component.utf8)
            let length = UInt64(value.count)
            bytes.append(contentsOf: (0..<8).reversed().map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) })
            bytes.append(contentsOf: value)
        }
        return SHA256.hexDigest(bytes)
    }
}
