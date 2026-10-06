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

    /// Renders `inspect list` output as a JSON array of object objects.
    ///
    /// - Parameter entries: The entries, in any order.
    /// - Returns: Pretty-printed JSON text.
    /// - Throws: `EncodingError` when an entry cannot be encoded.
    public static func listJSON(_ entries: [NetworkCatalogEntry]) throws -> String {
        let sorted = entries.sorted(by: {
            ($0.objectID.uuidString, $0.providerID) < ($1.objectID.uuidString, $1.providerID)
        })
        let objects = try sorted.map { try objectJSON($0, compact: true) }
        return "[\n" + objects.joined(separator: ",\n") + "\n]"
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

    /// Renders payload-free node diagnostics as deterministic human text.
    ///
    /// - Parameter snapshot: The node diagnostics snapshot.
    /// - Returns: Newline-terminated text.
    public static func nodeText(_ snapshot: NodeDiagnostics) -> String {
        var lines: [String] = [
            "node  \(snapshot.nodeID?.uuidString.lowercased() ?? "<unassigned>")  protocolMajor=\(snapshot.protocolMajor)",
            "turns  inFlight=\(snapshot.turns.inFlight) completed=\(snapshot.turns.completed) observationPending=\(snapshot.turns.observationPending) observationClosed=\(snapshot.turns.observationClosed)",
            "observer  live=\(snapshot.observer.liveObservations) cleanupFailures=\(snapshot.observer.cleanupFailures) retainedInFlight=\(snapshot.observer.retainedInFlight) retainedCompleted=\(snapshot.observer.retainedCompleted) retainedTombstones=\(snapshot.observer.retainedTombstones)",
            "ascendants  \(snapshot.ascendents.count)",
        ]
        for ascendant in snapshot.ascendents {
            lines.append("  \(ascendantSummaryLine(ascendant))")
        }
        lines.append("timelines  \(snapshot.timelines.count)")
        for timeline in snapshot.timelines {
            lines.append("  \(timelineSummaryLine(timeline))")
        }
        lines.append("workspaces  \(snapshot.workspaces.count)")
        for workspace in snapshot.workspaces {
            lines.append("  \(workspaceSummaryLine(workspace))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Renders payload-free Ascendant diagnostics as deterministic human text.
    ///
    /// - Parameter snapshot: The Ascendant diagnostics snapshot.
    /// - Returns: Newline-terminated text.
    public static func ascendantText(_ snapshot: AscendantDiagnostics) -> String {
        var lines: [String] = [
            "ascendant  \(snapshot.ascendant.id.uuidString.lowercased())  \(snapshot.ascendant.name)",
            "health=\(snapshot.ascendant.health.rawValue) quarantined=\(snapshot.ascendant.quarantined)",
            "backend=\(snapshot.backendKind ?? "-") version=\(snapshot.backendVersion ?? "-")",
            "privateTimeline=\(snapshot.privateTimelineID.uuidString.lowercased()) primaryWorkspace=\(snapshot.primaryWorkspaceID?.uuidString.lowercased() ?? "-")",
            "capabilities=[\(snapshot.capabilities.joined(separator: ","))]",
            "timelines  \(snapshot.timelines.count)",
        ]
        for timeline in snapshot.timelines {
            lines.append("  \(timelineSummaryLine(timeline))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Renders payload-free Timeline diagnostics as deterministic human text.
    ///
    /// - Parameter snapshot: The Timeline diagnostics snapshot.
    /// - Returns: Newline-terminated text.
    public static func timelineText(_ snapshot: TimelineDiagnostics) -> String {
        var lines: [String] = [
            "timeline  \(snapshot.timeline.id.uuidString.lowercased())  \(snapshot.timeline.title)",
            "operator=\(snapshot.timeline.operatingAscendantID?.uuidString.lowercased() ?? "-")",
            "workspaces  \(snapshot.workspaces.count)",
        ]
        for workspace in snapshot.workspaces {
            lines.append("  \(workspaceSummaryLine(workspace))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Renders the observed wire-event envelopes as deterministic human text.
    ///
    /// No payload is ever rendered; only the payload byte count appears.
    ///
    /// - Parameter events: The event envelopes, in arrival order.
    /// - Returns: Newline-terminated text.
    public static func eventsText(_ events: [GnosticRawWireEvent]) -> String {
        let lines = events.map { event in
            let target = event.targetObjectId.map { id in
                "\(event.objectType ?? "object"):\(id.uuidString.lowercased())"
            } ?? "-"
            return [
                event.kind.rawValue,
                "source=\(event.sourceId ?? "-")",
                "object=\(target)",
                "correlation=\(event.correlationId ?? "-")",
                "channel=\(event.channelId ?? "-")",
                "payloadBytes=\(event.payload.utf8.count)",
            ].joined(separator: "  ")
        }
        return (lines.isEmpty ? "(no wire events observed)" : lines.joined(separator: "\n")) + "\n"
    }

    /// Encodes one diagnostics snapshot as deterministic JSON.
    ///
    /// - Parameter value: The diagnostics snapshot.
    /// - Returns: Pretty-printed JSON text with a trailing newline.
    /// - Throws: An encoding error.
    public static func diagnosticsJSON<T: Encodable>(_ value: T) throws -> String {
        try JSONOutput.encode(value) + "\n"
    }

    /// Encodes the observed wire-event envelopes as deterministic JSON.
    ///
    /// The projection never carries a payload; it carries only the payload
    /// byte count, so secrets and Turn bodies cannot leak into output.
    ///
    /// - Parameter events: The event envelopes, in arrival order.
    /// - Returns: Pretty-printed JSON text with a trailing newline.
    /// - Throws: An encoding error.
    public static func eventsJSON(_ events: [GnosticRawWireEvent]) throws -> String {
        try JSONOutput.encode(events.map(RenderedWireEvent.init)) + "\n"
    }

    private static func ascendantSummaryLine(_ ascendant: DiagnosticsAscendantSummary) -> String {
        "\(ascendant.id.uuidString.lowercased())  \(ascendant.name)  health=\(ascendant.health.rawValue) quarantined=\(ascendant.quarantined)"
    }

    private static func timelineSummaryLine(_ timeline: DiagnosticsTimelineSummary) -> String {
        "\(timeline.id.uuidString.lowercased())  \(timeline.title)  operator=\(timeline.operatingAscendantID?.uuidString.lowercased() ?? "-")"
    }

    private static func workspaceSummaryLine(_ workspace: DiagnosticsWorkspaceSummary) -> String {
        "\(workspace.id.uuidString.lowercased())  \(workspace.status.rawValue)  uri=\(workspace.uri)"
    }

    private static func extraFields(for entry: NetworkCatalogEntry) -> String {
        guard entry.objectType == GnosticObjectType.workspace else { return "" }
        let status = entry.effectiveStatus?.rawValue ?? GnosticWorkspaceEffectiveStatus.unsupported.rawValue
        guard let workspace = entry.workspace else { return status }
        let toolIDs = workspace.tools.map(\.id).sorted().joined(separator: ",")
        return "\(status) uri=\(workspace.uri) tools=[\(toolIDs)]"
    }
}

/// A payload-free projection of a raw wire event for CLI output.
///
/// The projection carries the envelope and the payload byte count, never the
/// payload itself, so a rendered stream cannot leak a secret or a Turn body.
public struct RenderedWireEvent: Codable, Sendable, Equatable {
    public let kind: String
    public let sourceId: String?
    public let correlationId: String?
    public let objectType: String?
    public let targetObjectId: UUID?
    public let channelId: String?
    public let payloadBytes: Int

    /// Projects one observed raw wire event.
    ///
    /// - Parameter event: The observed event.
    public init(_ event: GnosticRawWireEvent) {
        kind = event.kind.rawValue
        sourceId = event.sourceId
        correlationId = event.correlationId
        objectType = event.objectType
        targetObjectId = event.targetObjectId
        channelId = event.channelId
        payloadBytes = event.payload.utf8.count
    }
}

/// A type-erased encodable used to compose deterministic JSON objects.
private struct AnyEncodable: Encodable {
    let base: any Encodable
    init(_ base: any Encodable) { self.base = base }
    func encode(to encoder: Encoder) throws { try base.encode(to: encoder) }
}
