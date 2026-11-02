// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

/// Golden wire bytes for the four advertised projection objects (issue #717).
///
/// The expected strings were produced by the `Gnostic*Object` classes on
/// `origin/main` at 5d7e37b, before they moved from `GnosticProtocol` to
/// `GnosticCore`. A Swift refactor must not change them: peers decode these
/// keys. Keys are sorted so the bytes are deterministic.
@Suite("Projection wire golden bytes")
struct ProjectionWireGoldenTests {
    private static let runtimeInstanceID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000001")!
    private static let nodeID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000002")!
    private static let timelineID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000003")!
    private static let workspaceID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000004")!
    private static let toolObjectID = CoatyUUID(uuidString: "A21D0000-0000-4000-8000-000000000005")!
    private static let created = Date(timeIntervalSinceReferenceDate: 1000)
    private static let updated = Date(timeIntervalSinceReferenceDate: 2000)

    private static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func tool(_ id: String) -> GnosticWorkspaceToolDefinition {
        GnosticWorkspaceToolDefinition(
            id: id,
            name: "Read \(id)",
            description: "Reads a file",
            parametersSchema: ["type": "object", "limit": .unsignedInteger(9_007_199_254_740_993)],
            usageExample: "read path",
            requiresPermission: true
        )
    }

    static func runtimeInstance() -> GnosticRuntimeInstanceObject {
        GnosticRuntimeInstanceObject(
            id: runtimeInstanceID,
            name: "Reference Runtime",
            kind: "acp",
            nodeID: nodeID,
            version: "1.2.3",
            launchFingerprint: "fp-1",
            health: .healthy,
            rawCapabilities: ["loadSession": .boolean(true), "promptCapabilities": .dictionary(["image": .boolean(false)])]
        )
    }

    static func timeline() -> GnosticTimelineObject {
        GnosticTimelineObject(
            id: timelineID,
            title: "Daily",
            attachedWorkspaceIDs: [workspaceID],
            runtimeInstanceID: runtimeInstanceID,
            isArchived: false,
            isPrivate: true,
            createdAt: created,
            updatedAt: updated,
            nodeID: nodeID
        )
    }

    static func workspace() -> GnosticWorkspaceObject {
        GnosticWorkspaceObject(workspace: GnosticWorkspaceReference(
            id: workspaceID,
            uri: "workspace://notes",
            trustLevel: .restricted,
            status: .active,
            tools: [tool("read")],
            createdAt: created
        ))
    }

    static func workspaceTool() -> GnosticWorkspaceToolObject {
        let object = GnosticWorkspaceToolObject(workspaceID: workspaceID, definition: tool("read"), page: 2)
        object.objectId = toolObjectID
        return object
    }

    private static let runtimeInstanceGolden = #"""
        {"coreType":"CoatyObject","health":"healthy","launchFingerprint":"fp-1","name":"Reference Runtime","nodeID":"A21D0000-0000-4000-8000-000000000002","objectId":"a21d0000-0000-4000-8000-000000000001","objectType":"me.atkn.gnostic.RuntimeInstance","protocolMajor":3,"rawCapabilities":{"loadSession":true,"promptCapabilities":{"image":false}},"runtimeID":"A21D0000-0000-4000-8000-000000000001","runtimeKind":"acp","runtimeVersion":"1.2.3"}
        """#

    private static let timelineGolden = #"""
        {"attachedWorkspaceIDs":["A21D0000-0000-4000-8000-000000000004"],"coreType":"CoatyObject","createdAt":1000,"isArchived":false,"isPrivate":true,"name":"Daily","nodeID":"A21D0000-0000-4000-8000-000000000002","objectId":"a21d0000-0000-4000-8000-000000000003","objectType":"me.atkn.gnostic.Timeline","protocolMajor":3,"runtimeInstanceID":"A21D0000-0000-4000-8000-000000000001","title":"Daily","updatedAt":2000}
        """#

    private static let workspaceGolden = #"""
        {"coreType":"CoatyObject","createdAt":1000,"effectiveStatus":"available","isAvailable":true,"name":"workspace://notes","objectId":"a21d0000-0000-4000-8000-000000000004","objectType":"me.atkn.gnostic.Workspace","protocolMajor":3,"status":"active","tools":[{"id":"read","name":"Read read","parametersSchema":{"limit":9007199254740993,"type":"object"},"requiresPermission":true,"toolDescription":"Reads a file","usageExample":"read path"}],"toolsComplete":true,"trustLevel":"restricted","uri":"workspace://notes"}
        """#

    private static let workspaceToolGolden = #"""
        {"coreType":"CoatyObject","externalId":"read","name":"Read read","objectId":"a21d0000-0000-4000-8000-000000000005","objectType":"me.atkn.gnostic.WorkspaceTool","page":2,"parametersSchema":{"limit":9007199254740993,"type":"object"},"parentObjectId":"a21d0000-0000-4000-8000-000000000004","protocolMajor":3,"requiresPermission":true,"schemaTruncated":false,"toolDescription":"Reads a file","toolID":"read","toolName":"Read read","usageExample":"read path","workspaceID":"A21D0000-0000-4000-8000-000000000004"}
        """#

    @Test("the Runtime instance object encodes the origin/main bytes")
    func runtimeInstanceBytes() throws {
        #expect(try Self.encode(Self.runtimeInstance()) == Self.runtimeInstanceGolden)
    }

    @Test("the Timeline object encodes the origin/main bytes")
    func timelineBytes() throws {
        #expect(try Self.encode(Self.timeline()) == Self.timelineGolden)
    }

    @Test("the Workspace object encodes the origin/main bytes")
    func workspaceBytes() throws {
        #expect(try Self.encode(Self.workspace()) == Self.workspaceGolden)
    }

    @Test("the Workspace tool object encodes the origin/main bytes")
    func workspaceToolBytes() throws {
        #expect(try Self.encode(Self.workspaceTool()) == Self.workspaceToolGolden)
    }
}
