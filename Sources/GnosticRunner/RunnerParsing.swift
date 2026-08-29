// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

public enum RunnerParsingError: Error, Sendable, LocalizedError {
    /// The port value is not a valid 1–65535 integer.
    case invalidPort(String)

    /// A stable, human-readable description of the failure.
    public var errorDescription: String? {
        switch self {
        case let .invalidPort(value):
            "Invalid port '\(value)': expected an integer between 1 and 65535."
        }
    }

    /// A machine-readable reason label for diagnostics.
    public var reasonCode: String {
        switch self {
        case .invalidPort: "invalidPort"
        }
    }
}

/// The fully-resolved runner configuration after precedence resolution.
public struct RunnerConfiguration: Sendable {
    public let host: String
    public let port: Int
    public let namespace: String

    /// Resolves flags (highest priority), then environment, then defaults.
    ///
    /// - Parameters:
    ///   - flags: The parsed command-line flag values.
    ///   - environment: Process environment.
    /// - Returns: The resolved configuration.
    /// - Throws: `RunnerParsingError.invalidPort` when the effective port is
    ///   not a valid 1–65535 integer.
    public static func resolve(
        flags: RunnerParsingFlags,
        environment: [String: String]
    ) throws -> RunnerConfiguration {
        let host = flags.host
            ?? environment["GNOSTIC_HOST"]
            ?? "127.0.0.1"
        let namespace = flags.namespace
            ?? environment["GNOSTIC_NAMESPACE"]
            ?? "gnostic"

        let port: Int
        if let flag = flags.port {
            port = flag
        } else if let raw = environment["GNOSTIC_PORT"] {
            guard let parsed = Int(raw), (1...65535).contains(parsed) else {
                throw RunnerParsingError.invalidPort(raw)
            }
            port = parsed
        } else {
            port = 1883
        }
        guard (1...65535).contains(port) else {
            throw RunnerParsingError.invalidPort(String(port))
        }

        return RunnerConfiguration(
            host: host,
            port: port,
            namespace: namespace
        )
    }
}

/// The flag surface exposed by `GnosticRunner`, decoupled from the argument
/// scanner for testability.
public struct RunnerParsingFlags: Sendable {
    public var host: String?
    public var port: Int?
    public var namespace: String?

    public init(host: String? = nil, port: Int? = nil, namespace: String? = nil) {
        self.host = host
        self.port = port
        self.namespace = namespace
    }
}
