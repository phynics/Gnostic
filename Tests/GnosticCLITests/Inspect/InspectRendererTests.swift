// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import PKContracts
import PositronicKit
import Testing

@testable import GnosticCLI

@Suite("Inspect rendering")
struct InspectRendererTests {
    private func workspaceEntry(
        id: UUID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000003")!,
        provider: String = "provider-a",
        name: String = "Remote workspace",
        uri: String = "workspace://alpha",
        isAvailable: Bool = true,
        dynamic: [String: NetworkDynamicValue] = [:]
    ) -> NetworkCatalogEntry {
        NetworkCatalogEntry(
            objectID: id,
            objectType: GnosticObjectType.workspace,
            providerID: provider,
            name: name,
            knownProperties: [
                "uri": .string(uri),
                "isAvailable": .bool(isAvailable),
            ],
            dynamicProperties: dynamic,
            workspace: NetworkWorkspaceDescriptor(
                id: id,
                uri: uri,
                isAvailable: isAvailable,
                tools: [GnosticWorkspaceTool(definition: GnosticWorkspaceToolDefinition(id: "echo", name: "Echo", description: "Echoes input."))]
            )
        )
    }

    @Test("list output is deterministic and includes type, id, provider, and name")
    func listOutputIsDeterministic() {
        let entries = [
            workspaceEntry(provider: "provider-b", name: "Beta workspace"),
            workspaceEntry(provider: "provider-a", name: "Alpha workspace"),
        ]
        let text = InspectRenderer.listText(entries)
        let lines = text.split(separator: "\n").map(String.init)

        #expect(lines.count == 2)
        #expect(lines[0].contains("Workspace"))
        #expect(lines[0].contains("a21d0000-0000-4000-8000-000000000003"))
        #expect(lines[0].contains("provider-a"))
        // Sorted by provider id: provider-a first.
        #expect(lines[0].contains("Alpha workspace"))
        #expect(lines[1].contains("provider-b"))
        #expect(lines[1].contains("Beta workspace"))
    }

    @Test("workspace inspection renders the effective status without collapsing it")
    func workspaceInspectionRendersEffectiveStatus() {
        let id = UUID(uuidString: "A21D0000-0000-4000-8000-000000000013")!
        let entry = workspaceEntry(id: id, isAvailable: false)

        #expect(InspectRenderer.line(for: entry).contains("unavailable"))
    }

    @Test("object output includes known fields and unknown dynamic fields verbatim")
    func objectOutputIncludesKnownAndDynamicFields() throws {
        let entry = workspaceEntry(dynamic: [
            "futureCapability": .object(["mode": .string("experimental")])
        ])
        let json = try InspectRenderer.objectJSON(entry, compact: false)

        #expect(json.contains("\"uri\""))
        #expect(json.contains("workspace"))
        #expect(json.contains("\"futureCapability\""))
        #expect(json.contains("experimental"))
        // Deterministic key ordering (sorted).
        let object = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
        #expect(object["known"] != nil)
        #expect(object["dynamic"] != nil)
        #expect(object["effectiveStatus"] == .string("available"))
    }

    @Test("object resolution classifies unknown, unique, and ambiguous")
    func objectResolution() {
        let a = workspaceEntry(provider: "provider-a")
        let b = workspaceEntry(provider: "provider-b")

        guard case .unknown = InspectRenderer.resolution(for: []) else {
            Issue.record("expected unknown")
            return
        }
        guard case .found = InspectRenderer.resolution(for: [a]) else {
            Issue.record("expected found")
            return
        }
        guard case .ambiguous = InspectRenderer.resolution(for: [a, b]) else {
            Issue.record("expected ambiguous")
            return
        }
    }

    @Test("compact json flag produces single-line deterministic output")
    func compactJSON() throws {
        let entry = workspaceEntry()
        let compact = try InspectRenderer.objectJSON(entry, compact: true)
        #expect(!compact.contains("\n"))
    }
}

/// A minimal equatable JSON value for decoding assertions.
private enum JSONValue: Equatable, Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }
}
