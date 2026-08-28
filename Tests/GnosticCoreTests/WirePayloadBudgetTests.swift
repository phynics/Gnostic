// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import PKContracts
import Testing

@Suite("Gnostic wire payload budgets")
struct WirePayloadBudgetTests {
    private let workspaceID = UUID(uuidString: "B21D0000-0000-4000-8000-000000000010")!

    @Test("UTF-8 prefix never splits a scalar")
    func prefixIsScalarSafe() {
        let value = String(repeating: "🧭", count: 20)
        let prefix = GnosticWirePayload.prefix(value, maximumBytes: 7)
        #expect(prefix.utf8.count <= 7)
        #expect(prefix == "🧭")
    }

    @Test("event budget accepts 2 KiB and rejects the next byte")
    func eventBudget() throws {
        try GnosticWirePayload.validateEvent(Data(repeating: 0, count: GnosticWirePayload.maximumBytes), context: "test")
        #expect(throws: GnosticWirePayload.Error.self) {
            try GnosticWirePayload.validateEvent(
                Data(repeating: 0, count: GnosticWirePayload.maximumBytes + 1),
                context: "test"
            )
        }
    }

    @Test("topic budget targets the upcoming Axoloty hotfix")
    func topicBudget() {
        #expect(GnosticWirePayload.maximumTopicBytes == 256)
    }

    @Test("workspace advertisements omit the unbounded tool list")
    func workspaceAdvertisementOmitsTools() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reference = WorkspaceReference(
            id: workspaceID,
            uri: WorkspaceURI(parsing: "workspace://fixture")!,
            location: .runtime,
            tools: [
                .custom(WorkspaceToolDefinition(id: "one", name: "One", description: "One")),
                .custom(WorkspaceToolDefinition(id: "two", name: "Two", description: "Two")),
            ],
            createdAt: now
        )
        let object = GnosticWorkspaceObject(workspace: reference, includeTools: false)
        let data = try JSONEncoder().encode(object)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("\"tools\""))
        #expect(data.count <= GnosticWirePayload.maximumEmbeddedValueBytes)
    }

    @Test("small public tool prefixes remain in the workspace advertisement")
    func smallToolPrefixIsAdvertised() throws {
        let reference = WorkspaceReference(
            id: workspaceID,
            uri: WorkspaceURI(parsing: "workspace://fixture")!,
            location: .runtime,
            tools: [.custom(WorkspaceToolDefinition(id: "echo", name: "Echo", description: "Echoes input."))]
        )
        let object = GnosticWorkspaceObject(workspace: reference)
        #expect(object.tools.map(\.id) == ["echo"])
        #expect(try JSONEncoder().encode(object).count <= GnosticWirePayload.maximumEmbeddedValueBytes)
    }

    @Test("one queryable tool remains bounded even with a large schema")
    func queryableToolIsBounded() throws {
        let definition = WorkspaceToolDefinition(
            id: "large-schema",
            name: String(repeating: "N", count: 500),
            description: String(repeating: "D", count: 500),
            parametersSchema: ["description": AnyCodable(String(repeating: "S", count: 5_000))]
        )
        let object = GnosticWorkspaceToolObject(workspaceID: workspaceID, definition: definition)
        let data = try JSONEncoder().encode(object)
        #expect(data.count <= GnosticWirePayload.maximumEmbeddedValueBytes)
        #expect(object.schemaTruncated)
        #expect(object.parametersSchema.isEmpty)
    }
}
