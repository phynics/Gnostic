// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation

/// The output format shared by `config`, `inspect`, and `doctor`.
///
/// Human output is for an operator; JSON output is a stable machine-readable
/// contract for scripts and run records. A command that accepts the format
/// rejects any other value before it reads the manifest.
public enum OutputFormat: String, Sendable, CaseIterable {
    case human
    case json

    /// Parses a raw `--format` value.
    ///
    /// - Parameter raw: The option value.
    /// - Returns: The matching format.
    /// - Throws: `ValidationError` when the value is not `human` or `json`.
    public static func parse(_ raw: String) throws -> OutputFormat {
        guard let format = OutputFormat(rawValue: raw.lowercased()) else {
            throw ValidationError("Output format must be human or json.")
        }
        return format
    }
}

/// A shared `--format human|json` option group.
///
/// A command declares it once with `@OptionGroup` and reads ``format``. The
/// legacy `--json` flag stays available for `config show`.
public struct OutputFormatOptions: ParsableArguments {
    /// The requested output format.
    @Option(name: .customLong("format"), help: "Output format: human or json.")
    public var format: String?

    /// Creates the option group.
    public init() {}

    /// The parsed format, defaulting to human.
    ///
    /// - Returns: The requested format, or `.human`.
    /// - Throws: `ValidationError` for an unrecognized value.
    public func resolved() throws -> OutputFormat {
        guard let format else { return .human }
        return try OutputFormat.parse(format)
    }
}

/// Deterministic JSON encoding for machine-readable command output.
public enum JSONOutput {
    /// Encodes one value with stable key order and a trailing newline.
    ///
    /// - Parameter value: The value to encode.
    /// - Returns: Pretty-printed JSON text.
    /// - Throws: An encoding error.
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
