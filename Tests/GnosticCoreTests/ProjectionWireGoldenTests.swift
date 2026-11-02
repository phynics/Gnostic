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

    @Test("each golden payload decodes and encodes back to the same bytes")
    func goldenPayloadsRoundTrip() throws {
        func roundTrip<T: Codable>(_ type: T.Type, _ golden: String) throws -> String {
            try Self.encode(try JSONDecoder().decode(type, from: Data(golden.utf8)))
        }
        #expect(try roundTrip(GnosticRuntimeInstanceObject.self, Self.runtimeInstanceGolden) == Self.runtimeInstanceGolden)
        #expect(try roundTrip(GnosticTimelineObject.self, Self.timelineGolden) == Self.timelineGolden)
        #expect(try roundTrip(GnosticWorkspaceObject.self, Self.workspaceGolden) == Self.workspaceGolden)
        #expect(try roundTrip(GnosticWorkspaceToolObject.self, Self.workspaceToolGolden) == Self.workspaceToolGolden)
    }

    @Test("the catalog hands consumers immutable snapshots of every golden object")
    func catalogEntriesCarrySnapshots() async throws {
        let catalog = NetworkCatalog()
        let provider = "provider-1"
        func advertise(_ golden: String, type: String, id: CoatyUUID, name: String) async {
            await catalog.ingest(AdvertiseEventSnapshot(
                sourceId: provider,
                object: CoatyObjectSnapshot(objectId: id.string, coreType: .coatyObject, objectType: type, name: name, payload: golden)
            ))
        }
        let runtimeObject = Self.runtimeInstance()
        let timelineObject = Self.timeline()
        let workspaceObject = Self.workspace()
        let toolObject = Self.workspaceTool()
        await advertise(Self.runtimeInstanceGolden, type: GnosticObjectType.runtimeInstance, id: runtimeObject.objectId, name: runtimeObject.name)
        await advertise(Self.timelineGolden, type: GnosticObjectType.timeline, id: timelineObject.objectId, name: timelineObject.name)
        await advertise(Self.workspaceGolden, type: GnosticObjectType.workspace, id: workspaceObject.objectId, name: workspaceObject.name)
        await advertise(Self.workspaceToolGolden, type: GnosticObjectType.workspaceTool, id: toolObject.objectId, name: toolObject.name)

        let runtime = try #require(await catalog.object(id: Self.runtimeInstanceID, providerID: provider)?.runtimeInstance)
        #expect(runtime == runtimeObject.snapshot)
        #expect(runtime.id == Self.runtimeInstanceID)
        #expect(runtime.name == "Reference Runtime")
        #expect(runtime.protocolMajor == GnosticProtocol.currentMajor)
        #expect(runtime.nodeID == Self.nodeID)
        #expect(runtime.runtimeKind == "acp")
        #expect(runtime.runtimeVersion == "1.2.3")
        #expect(runtime.launchFingerprint == "fp-1")
        #expect(runtime.health == .healthy)
        #expect(runtime.rawCapabilities == ["loadSession": .boolean(true), "promptCapabilities": .dictionary(["image": .boolean(false)])])

        let timeline = try #require(await catalog.object(id: Self.timelineID, providerID: provider)?.timeline)
        #expect(timeline == timelineObject.snapshot)
        #expect(timeline.id == Self.timelineID)
        #expect(timeline.title == "Daily")
        #expect(timeline.isArchived == false)
        #expect(timeline.isPrivate == true)
        #expect(timeline.runtimeInstanceID == Self.runtimeInstanceID)
        #expect(timeline.attachedWorkspaceIDs == [Self.workspaceID])
        #expect(timeline.nodeID == Self.nodeID)
        #expect(timeline.createdAt == Self.created)
        #expect(timeline.updatedAt == Self.updated)
        #expect(timeline.status.timelineID == Self.timelineID)
        #expect(timeline.status.attachedWorkspaceIDs == [Self.workspaceID])
        #expect(timeline.status.isPrivate)

        let workspace = try #require(await catalog.object(id: Self.workspaceID, providerID: provider)?.workspace)
        #expect(workspace.id == Self.workspaceID)
        #expect(workspace.uri == "workspace://notes")
        #expect(workspace.isAvailable)
        #expect(workspace.trustLevel == .restricted)
        #expect(workspace.status == .active)
        #expect(workspace.effectiveStatus == .available)
        #expect(workspace.tools.map(\.id).contains("read"))
        #expect(workspace.createdAt == Self.created)

        let tool = try #require(await catalog.object(id: toolObject.objectId.foundationUUID, providerID: provider)?.workspaceToolSnapshot)
        #expect(tool == (try JSONDecoder().decode(GnosticWorkspaceToolObject.self, from: Data(Self.workspaceToolGolden.utf8))).snapshot)
        #expect(tool.workspaceID == Self.workspaceID)
        #expect(tool.tool.id == "read")
        #expect(tool.tool.name == "Read read")
        #expect(tool.tool.requiresPermission)
        #expect(tool.page == 2)
        #expect(!tool.schemaTruncated)
    }

    @Test("a snapshot keeps its values after the transport object changes")
    func snapshotIsIndependentOfItsSource() {
        let object = Self.timeline()
        let snapshot = object.snapshot
        object.title = "Renamed"
        object.isArchived = true
        #expect(snapshot.title == "Daily")
        #expect(!snapshot.isArchived)
        #expect(object.snapshot.title == "Renamed")
    }

    @Test("an incompatible or malformed advertisement carries no snapshot")
    func incompatibleAdvertisementHasNoSnapshot() async throws {
        let catalog = NetworkCatalog()
        let incompatible = Self.timelineGolden.replacingOccurrences(of: "\"protocolMajor\":3", with: "\"protocolMajor\":99")
        #expect(incompatible != Self.timelineGolden)
        await catalog.ingest(AdvertiseEventSnapshot(sourceId: "old", object: CoatyObjectSnapshot(
            objectId: Self.timelineID.uuidString.lowercased(),
            coreType: .coatyObject,
            objectType: GnosticObjectType.timeline,
            name: "Daily",
            payload: incompatible
        )))
        let entry = try #require(await catalog.object(id: Self.timelineID, providerID: "old"))
        #expect(!entry.isProtocolCompatible)
        #expect(entry.timeline == nil)

        await catalog.ingest(AdvertiseEventSnapshot(sourceId: "broken", object: CoatyObjectSnapshot(
            objectId: Self.runtimeInstanceID.uuidString.lowercased(),
            coreType: .coatyObject,
            objectType: GnosticObjectType.runtimeInstance,
            name: "Broken",
            payload: "{\"protocolMajor\":3}"
        )))
        let broken = try #require(await catalog.object(id: Self.runtimeInstanceID, providerID: "broken"))
        #expect(broken.runtimeInstance == nil)
    }
}
