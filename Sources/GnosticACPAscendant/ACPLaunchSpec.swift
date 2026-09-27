// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

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
    }
}
