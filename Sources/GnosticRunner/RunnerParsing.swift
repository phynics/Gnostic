// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

public enum RunnerParsingError: Error, Sendable, LocalizedError {
    /// The port value is not a valid 1–65535 integer.
    case invalidPort(String)

    /// The explicit manifest path does not exist.
    case missingManifest(String)

    /// The manifest exists but cannot be read or decoded.
    case malformedManifest(String)

    /// A stable, human-readable description of the failure.
    public var errorDescription: String? {
        switch self {
        case let .invalidPort(value):
            "Invalid port '\(value)': expected an integer between 1 and 65535."
        case let .missingManifest(path):
            "No configuration manifest exists at '\(path)'. Run `gnostic config init` or omit --config."
        case let .malformedManifest(path):
            "The configuration manifest at '\(path)' is not a valid Gnostic manifest."
        }
    }

    /// A machine-readable reason label for diagnostics.
    public var reasonCode: String {
        switch self {
        case .invalidPort: "invalidPort"
        case .missingManifest: "missingManifest"
        case .malformedManifest: "malformedManifest"
        }
    }
}

/// The fully-resolved runner configuration after precedence resolution.
public struct RunnerConfiguration: Sendable {
    public let host: String
    public let port: Int
    public let namespace: String
    public let configPath: String?

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
        let configPath = flags.config
            ?? environment["GNOSTIC_CONFIG"].flatMap { $0.isEmpty ? nil : $0 }

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
            namespace: namespace,
            configPath: configPath
        )
    }

    /// Loads the manifest the runner hosts.
    ///
    /// An explicit `--config` (or `GNOSTIC_CONFIG`) wins. Without one, the
    /// runner hosts the default resource graph. The resolved broker always wins
    /// over the manifest's broker, so `--host`, `--port`, and `--namespace`
    /// steer the hosted Node exactly as they steer the process log line.
    ///
    /// - Returns: A validated manifest ready for `compileLaunchPlan()`.
    /// - Throws: ``RunnerParsingError`` when the file is missing or malformed.
    public func resolvedManifest() throws -> NodeManifest {
        let broker = NodeManifest.Broker(host: host, port: port, namespace: namespace)
        guard let configPath else {
            return NodeManifest.makeDefault(broker: broker)
        }
        let url = URL(fileURLWithPath: configPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RunnerParsingError.missingManifest(url.path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RunnerParsingError.malformedManifest(url.path)
        }
        var manifest: NodeManifest
        do {
            manifest = try JSONDecoder().decode(NodeManifest.self, from: data)
        } catch {
            throw RunnerParsingError.malformedManifest(url.path)
        }
        manifest.broker = broker
        do {
            try manifest.validate()
        } catch {
            throw RunnerParsingError.malformedManifest(url.path)
        }
        return manifest
    }
}

/// The flag surface exposed by `GnosticRunner`, decoupled from the argument
/// scanner for testability.
public struct RunnerParsingFlags: Sendable {
    public var host: String?
    public var port: Int?
    public var namespace: String?
    public var config: String?

    public init(host: String? = nil, port: Int? = nil, namespace: String? = nil, config: String? = nil) {
        self.host = host
        self.port = port
        self.namespace = namespace
        self.config = config
    }
}
