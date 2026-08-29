// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import Testing

@Suite("Gnostic protocol v2 contract")
struct ProtocolV2Tests {
    private let ascendantID = UUID(uuidString: "B21D0000-0000-4000-8000-000000000001")!
    private let timelineID = UUID(uuidString: "B21D0000-0000-4000-8000-000000000002")!

    @Test("Ascendant projections carry the v2 major and use the new wire type")
    func ascendantProjectionUsesV2Contract() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = AscendantRuntimeIdentity(
            id: ascendantID,
            name: "Atlas",
            description: "Coordinates analysis.",
            privateTimelineID: timelineID,
            primaryWorkspaceID: nil,
            lastActiveAt: now,
            createdAt: now,
            updatedAt: now
        )

        let object = GnosticAscendantObject(identity: identity)

        #expect(object.objectType == GnosticObjectType.ascendant)
        #expect(object.protocolMajor == GnosticProtocol.currentMajor)
        let data = try JSONEncoder().encode(object)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"protocolMajor\":\(GnosticProtocol.currentMajor)"))
        #expect(!json.contains("me.atkn.gnostic.Agent"))
    }

    @Test("stable capabilities do not advertise an unsupported cancellation seam")
    func stableCapabilitiesOnlyAdvertiseImplementedSeams() {
        #expect(GnosticCapability.stable.contains(GnosticCapability.textTurnInput))
        #expect(!GnosticCapability.stable.contains(GnosticCapability.turnCancellation))
        #expect(AscendantInteroperabilityCapability.textTurn.rawValue == GnosticCapability.textTurnInput)
        #expect(AscendantInteroperabilityCapability.streamedUpdates.rawValue == GnosticCapability.streamedTurnUpdates)
        #expect(AscendantInteroperabilityCapability.replay.rawValue == GnosticCapability.turnReplay)
        #expect(AscendantInteroperabilityCapability.permissionMediation.rawValue == GnosticCapability.permissionMediation)
        #expect(AscendantInteroperabilityCapability.workspaceAttachment.rawValue == GnosticCapability.workspaceAttachment)
        #expect(AscendantInteroperabilityCapability.workspaceToolInvocation.rawValue == GnosticCapability.workspaceToolInvocation)
    }

    @Test("Turn requests, results, replay updates, and errors carry the protocol major")
    func turnPayloadsCarryProtocolMajor() throws {
        let request = AscendantTurnRequest(
            message: "hello",
            timelineID: timelineID,
            clientTurnID: "turn-1"
        )
        let result = AscendantTurnResult(clientTurnID: "turn-1", text: "world")
        let update = AscendantTurnUpdate(sequence: 1, kind: "completion", text: "world", terminal: true)
        let replay = AscendantTurnReplay(updates: [update], compacted: false, terminal: true)

        #expect(request.protocolMajor == GnosticProtocol.currentMajor)
        #expect(result.protocolMajor == GnosticProtocol.currentMajor)
        #expect(update.protocolMajor == GnosticProtocol.currentMajor)
        #expect(replay.protocolMajor == GnosticProtocol.currentMajor)
        #expect(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any] != nil)
    }

    @Test("unsupported turn majors are rejected at the direct call seam")
    func directCallRevalidatesProtocolMajor() async throws {
        let provider = AscendantTurnProvider { request in
            AscendantTurnResult(clientTurnID: request.clientTurnID, text: request.message)
        }
        let payload = #"{"message":"hello","timelineID":"B21D0000-0000-4000-8000-000000000002","clientTurnID":"turn-1","protocolMajor":1}"#

        let response = try await provider.handle(parameters: payload)
        guard case let .failure(code, message, _) = response else {
            Issue.record("unsupported protocol major unexpectedly succeeded")
            return
        }
        #expect(code == 426)
        #expect(message.contains("unsupportedProtocolMajor"))
    }

    @Test("workspace direct calls report missing protocol majors structurally")
    func workspaceDirectCallReportsMissingProtocolMajor() async throws {
        let id = UUID()
        let provider = GnosticWorkspaceProvider(workspaceID: id, tools: []) { _, _ in .success("unused") }
        let response = try await provider.handle(parameters: "{}")
        guard case let .failure(code, message, _) = response else {
            Issue.record("missing protocol major unexpectedly succeeded")
            return
        }
        #expect(code == 400)
        #expect(message.contains("missingProtocolMajor"))
    }

    @Test("ordinary provider failures carry the protocol major envelope")
    func ordinaryProviderFailuresCarryProtocolMajor() async throws {
        let timelineID = UUID()
        let turnProvider = AscendantTurnProvider(
            execute: { _ in AscendantTurnResult(text: "unused") },
            isAvailable: { false }
        )
        let turnFailure = try await turnProvider.handle(parameters: nil)

        let permissionProvider = AscendantPermissionProvider(
            coordinator: AscendantPermissionCoordinator(updates: AscendantTurnUpdateStore())
        )
        let permission = AscendantPermissionResponse(
            correlationID: "stale",
            timelineID: timelineID,
            clientTurnID: "turn-1",
            approved: true
        )
        let permissionFailure = try await permissionProvider.handle(
            parameters: String(decoding: try JSONEncoder().encode(permission), as: UTF8.self)
        )

        let statusProvider = TimelineStatusProvider { _ in throw NodeRuntimeError.notRunning }
        let statusFailure = try await statusProvider.handle(
            parameters: String(decoding: try JSONEncoder().encode(TimelineStatusRequest(timelineID: timelineID)), as: UTF8.self)
        )

        let managementProvider = TimelineManagementProvider(
            create: { _, _ in throw NodeRuntimeError.notRunning },
            list: { throw NodeRuntimeError.notRunning },
            update: { _ in throw NodeRuntimeError.notRunning }
        )
        let managementFailure = try await managementProvider.handle(
            operation: TimelineManagementProvider.createOperation,
            parameters: String(decoding: try JSONEncoder().encode(TimelineCreateRequest(title: "New")), as: UTF8.self)
        )

        let workspaceProvider = WorkspaceOpsProvider(
            list: { throw NodeRuntimeError.notRunning },
            attach: { _ in throw NodeRuntimeError.notRunning },
            detach: { _ in throw NodeRuntimeError.notRunning }
        )
        let workspaceFailure = try await workspaceProvider.handle(
            operation: WorkspaceOpsProvider.attachOperation,
            parameters: String(decoding: try JSONEncoder().encode(WorkspaceOpsRequest(workspaceID: UUID(), timelineID: timelineID)), as: UTF8.self)
        )

        for response in [turnFailure, permissionFailure, statusFailure, managementFailure, workspaceFailure] {
            guard case let .failure(_, message, _) = response,
                  let data = message.data(using: .utf8),
                  let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Issue.record("ordinary failure was not a structured protocol envelope")
                continue
            }
            #expect(envelope["protocolMajor"] as? Int == GnosticProtocol.currentMajor)
        }
    }

    @Test("management and workspace payload decoders require the protocol major")
    func managementPayloadDecodersRequireProtocolMajor() throws {
        let timeline = #"{"timelineID":"B21D0000-0000-4000-8000-000000000002"}"#
        let workspace = #"{"workspaceID":"B21D0000-0000-4000-8000-000000000001","timelineID":"B21D0000-0000-4000-8000-000000000002","toolID":"search","arguments":{}}"#

        #expect(throws: GnosticProtocolError.self) {
            _ = try JSONDecoder().decode(TimelineStatusRequest.self, from: Data(timeline.utf8))
        }
        #expect(throws: GnosticProtocolError.self) {
            _ = try JSONDecoder().decode(WorkspaceInvocation.self, from: Data(workspace.utf8))
        }
    }

    @Test("normal catalog discovery hides incompatible objects while inspection retains them")
    func catalogFiltersIncompatibleObjectsForNormalDiscovery() async throws {
        let objectID = ascendantID.uuidString.lowercased()
        let payload = """
        {"protocolMajor":1,"objectId":"\(objectID)","coreType":"CoatyObject","objectType":"\(GnosticObjectType.ascendant)","name":"Old","ascendantDescription":"legacy","privateTimelineID":"\(timelineID.uuidString.lowercased())","lastActiveAt":"2023-11-14T22:13:20Z","createdAt":"2023-11-14T22:13:20Z","updatedAt":"2023-11-14T22:13:20Z"}
        """
        let snapshot = CoatyObjectSnapshot(
            objectId: objectID,
            coreType: .CoatyObject,
            objectType: GnosticObjectType.ascendant,
            name: "Old",
            payload: payload
        )
        let catalog = NetworkCatalog()
        await catalog.ingest(AdvertiseEventSnapshot(sourceId: "old", object: snapshot))

        #expect(await catalog.networkObjects().isEmpty)
        #expect(await catalog.networkObjects(includeIncompatible: true).count == 1)
    }

    @Test("metadata-only advertisements do not evict a full compatible object")
    func metadataOnlyAdvertisementPreservesCompatibleObject() async throws {
        let objectID = ascendantID.uuidString.lowercased()
        let fullPayload = """
        {"protocolMajor":2,"objectId":"\(objectID)","coreType":"CoatyObject","objectType":"\(GnosticObjectType.ascendant)","name":"Current","ascendantDescription":"current","privateTimelineID":"\(timelineID.uuidString.lowercased())","lastActiveAt":"2023-11-14T22:13:20Z","createdAt":"2023-11-14T22:13:20Z","updatedAt":"2023-11-14T22:13:20Z"}
        """
        let full = CoatyObjectSnapshot(objectId: objectID, coreType: .CoatyObject, objectType: GnosticObjectType.ascendant, name: "Current", payload: fullPayload)
        let metadata = CoatyObjectSnapshot(objectId: objectID, coreType: .CoatyObject, objectType: GnosticObjectType.ascendant, name: "Current")
        let catalog = NetworkCatalog()
        await catalog.ingest(AdvertiseEventSnapshot(sourceId: "provider", object: full))
        await catalog.ingest(AdvertiseEventSnapshot(sourceId: "provider", object: metadata))

        let entries = await catalog.networkObjects()
        #expect(entries.count == 1)
        #expect(entries.first?.protocolMajor == GnosticProtocol.currentMajor)
    }
}
