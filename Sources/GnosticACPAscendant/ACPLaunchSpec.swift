// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Validated, non-secret values needed to describe an ACP agent process.
///
/// The launch specification is configuration data only; this target does not
/// create a process in GNO-ACPC-002.
public struct ACPLaunchSpec: Sendable, Equatable {
    /// The executable command used to start the agent.
    public let command: String
    /// Arguments passed to the command in order.
    public let arguments: [String]
    /// Optional current working directory for the process.
    public let workingDirectory: String?
    /// Environment values supplied to the future process, including secret
    /// values. Do not log or include this dictionary in diagnostics.
    public let environment: [String: String]
    /// Optional display name for the external agent.
    public let displayName: String?

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
