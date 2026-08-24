// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

/// The result of resolving an object identifier against catalogued entries.
public enum ObjectResolution: Sendable {
    /// Exactly one provider advertises the identifier.
    case found(NetworkCatalogEntry)
    /// No provider advertises the identifier.
    case unknown
    /// More than one provider advertises the identifier.
    case ambiguous
}

/// Deterministic rendering of catalogued network objects for the CLI.
///
/// All output is byte-stable for a fixed catalog: entries sort by object UUID
/// then provider ID, and JSON keys are sorted.
public enum InspectRenderer {
    /// The provider identity when the advertisement had no source.
    static let anonymousProvider = "<unknown-provider>"

    /// Renders one line of `inspect list` output.
    ///
    /// Format: `<TYPE> <uuid> <provider> <name>` plus safe per-type fields.
    ///
    /// - Parameter entry: The catalogued entry.
    /// - Returns: A single deterministic line.
    public static func line(for entry: NetworkCatalogEntry) -> String {
        let type = entry.objectType
        let id = entry.objectID.uuidString.lowercased()
        let provider = entry.providerID
        let name = entry.name
        let extras = extraFields(for: entry)
        return [type, id, provider, name, extras].filter { !$0.isEmpty }.joined(separator: "  ")
    }

    /// Renders `inspect list` output for a set of entries.
    ///
    /// - Parameter entries: The entries, in any order.
    /// - Returns: Deterministic multi-line text (newline-terminated).
    public static func listText(_ entries: [NetworkCatalogEntry]) -> String {
        let lines = entries
            .sorted(by: {
                ($0.objectID.uuidString, $0.providerID) < ($1.objectID.uuidString, $1.providerID)
            })
            .map(line(for:))
        return (lines.isEmpty ? "(no advertised objects)" : lines.joined(separator: "\n")) + "\n"
    }

    /// Renders a single catalogued entry as deterministic JSON.
    ///
    /// Known projection fields and retained unknown dynamic fields are included
    /// verbatim. Core Coaty fields (`objectId`, `coreType`, ...) are excluded,
    /// matching the catalog's retention.
    ///
    /// - Parameters:
    ///   - entry: The catalogued entry.
    ///   - compact: When true, emit a single line; otherwise pretty-print.
    /// - Returns: The JSON text.
    /// - Throws: `EncodingError` when the entry cannot be encoded.
    public static func objectJSON(_ entry: NetworkCatalogEntry, compact: Bool) throws -> String {
        var object: [String: AnyEncodable] = [
            "objectType": AnyEncodable(entry.objectType),
            "objectId": AnyEncodable(entry.objectID.uuidString.lowercased()),
            "name": AnyEncodable(entry.name),
            "providerId": AnyEncodable(entry.providerID),
            "known": AnyEncodable(entry.knownProperties),
            "dynamic": AnyEncodable(entry.dynamicProperties),
        ]
        if entry.objectType == GnosticObjectType.workspace {
            object["effectiveStatus"] = AnyEncodable(
                entry.effectiveStatus?.rawValue ?? GnosticWorkspaceEffectiveStatus.unsupported.rawValue
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = compact ? [] : [.prettyPrinted, .sortedKeys]
        if !compact { encoder.outputFormatting.insert(.sortedKeys) }
        let data = try encoder.encode(object)
        return String(decoding: data, as: UTF8.self)
    }

    /// Resolves whether an identifier maps to a unique, unknown, or ambiguous
    /// set of provider-scoped entries.
    ///
    /// - Parameter entries: The provider-scoped entries matching an identifier.
    /// - Returns: The resolution result.
    public static func resolution(for entries: [NetworkCatalogEntry]) -> ObjectResolution {
        switch entries.count {
        case 0: .unknown
        case 1: .found(entries[0])
        default: .ambiguous
        }
    }

    /// Produces an exit-code-compatible status for a resolution.
    ///
    /// - Parameter resolution: The object resolution.
    /// - Returns: 0 for found, 2 otherwise (unknown or ambiguous).
    public static func exitCode(for resolution: ObjectResolution) -> Int32 {
        switch resolution {
        case .found: 0
        case .unknown, .ambiguous: 2
        }
    }

    private static func extraFields(for entry: NetworkCatalogEntry) -> String {
        guard entry.objectType == GnosticObjectType.workspace else { return "" }
        let status = entry.effectiveStatus?.rawValue ?? GnosticWorkspaceEffectiveStatus.unsupported.rawValue
        guard let workspace = entry.workspace else { return status }
        let toolIDs = workspace.tools.map(\.id).sorted().joined(separator: ",")
        return "\(status) uri=\(workspace.uri) tools=[\(toolIDs)]"
    }
}

/// A type-erased encodable used to compose deterministic JSON objects.
private struct AnyEncodable: Encodable {
    let base: any Encodable
    init(_ base: any Encodable) { self.base = base }
    func encode(to encoder: Encoder) throws { try base.encode(to: encoder) }
}
