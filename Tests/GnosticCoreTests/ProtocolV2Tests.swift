// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
@testable import GnosticCore
import GnosticProtocol
import Testing

@Suite("Gnostic protocol v2 contract")
struct ProtocolV2Tests {
    private let ascendantID = UUID(uuidString: "B21D0000-0000-4000-8000-000000000001")!
    private let timelineID = UUID(uuidString: "B21D0000-0000-4000-8000-000000000002")!

    @Test("Runtime instance projections carry the current major and use the Runtime instance wire type")
    func runtimeInstanceProjectionUsesCurrentContract() throws {
        let object = GnosticRuntimeInstanceObject(id: ascendantID, name: "Atlas", kind: "local-command")

        #expect(object.objectType == GnosticObjectType.runtimeInstance)
        #expect(object.protocolMajor == GnosticProtocol.currentMajor)
        let data = try JSONEncoder().encode(object)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"protocolMajor\":\(GnosticProtocol.currentMajor)"))
        #expect(!json.contains("me.atkn.gnostic.Ascendant"))
        #expect(!json.contains("me.atkn.gnostic.Agent"))
    }

    @Test("stable capabilities do not advertise an unsupported cancellation seam")
    func stableCapabilitiesOnlyAdvertiseImplementedSeams() {
        // Every interoperability capability is stable except the cancellation
        // seam, which this build does not advertise. A new capability therefore
        // lands in `stable` only after an explicit review of this expectation.
        let supported = Set(InteroperabilityCapability.allCases.map(\.rawValue))
            .subtracting([InteroperabilityCapability.cancellation.rawValue])
        #expect(GnosticCapability.stable == supported)
        #expect(GnosticCapability.turnCancellation == InteroperabilityCapability.cancellation.rawValue)
    }

    @Test("Turn requests, results, replay updates, and errors carry the protocol major")
    func turnPayloadsCarryProtocolMajor() throws {
        let request = TurnRequest(
            message: "hello",
            timelineID: timelineID,
            clientTurnID: "turn-1"
        )
        let result = TurnResult(clientTurnID: "turn-1", text: "world")
        let update = TurnUpdate(sequence: 1, kind: "completion", text: "world", terminal: true)
        let replay = TurnReplay(updates: [update], compacted: false, terminal: true)

        #expect(request.protocolMajor == GnosticProtocol.currentMajor)
        #expect(result.protocolMajor == GnosticProtocol.currentMajor)
        #expect(update.protocolMajor == GnosticProtocol.currentMajor)
        #expect(replay.protocolMajor == GnosticProtocol.currentMajor)
        #expect(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any] != nil)
    }

    @Test("unsupported turn majors are rejected at the direct call seam")
    func directCallRevalidatesProtocolMajor() async throws {
        let provider = AscendantTurnProvider { request in
            TurnResult(clientTurnID: request.clientTurnID, text: request.message)
        }
        let payload = #"{"message":"hello","timelineID":"B21D0000-0000-4000-8000-000000000002","clientTurnID":"turn-1","protocolMajor":1}"#

        let response = try await provider.handle(operation: AscendantTurnProvider.turnOperation, parameters: payload)
        guard case let .failure(code, message, _) = response else {
            Issue.record("unsupported protocol major unexpectedly succeeded")
            return
        }
        #expect(code == 426)
        #expect(message.contains("unsupportedProtocolMajor"))
    }

    @Test("every turn operation rejects an unsupported major before its fields")
    func turnOperationsRejectUnsupportedMajor() async throws {
        let provider = AscendantTurnProvider { request in
            TurnResult(clientTurnID: request.clientTurnID, text: request.message)
        }
        let payload = #"{"message":"hello","timelineID":"B21D0000-0000-4000-8000-000000000002","clientTurnID":"turn-1","protocolMajor":1}"#

        for operation in [
            AscendantTurnProvider.turnOperation,
            AscendantTurnProvider.replayOperation,
            AscendantTurnProvider.cancelOperation,
        ] {
            let response = try await provider.handle(operation: operation, parameters: payload)
            guard case let .failure(code, message, _) = response else {
                Issue.record("\(operation) accepted an unsupported protocol major")
                continue
            }
            #expect(code == 426)
            #expect(message.contains("unsupportedProtocolMajor"))
        }
    }

    @Test("workspace direct calls report missing protocol majors structurally")
    @MainActor
    func workspaceDirectCallReportsMissingProtocolMajor() async throws {
        let provider = MultiplexedWorkspaceProvider(
            workspaces: [:],
            workspaceStatus: { _ in nil },
            setWorkspaceStatus: { _, _ in false },
            callerBoundAuthorization: { _, _, _ in false },
            admitInvocation: { _, _, _ in false },
            isAvailable: { true }
        )
        let response = try await provider.handle(parameters: "{}")
        guard case let .failure(code, message, _) = response else {
            Issue.record("missing protocol major unexpectedly succeeded")
            return
        }
        #expect(code == 400)
        #expect(message.contains("missingProtocolMajor"))
    }

    @Test("public failure mapping preserves backend status and reason code without detail")
    func backendFailureMappingPreservesStableIdentity() throws {
        let error = AscendantBackendError.terminal(.init(
            code: "providerUnavailable",
            message: "backend-secret-detail",
            retryable: true
        ))
        let mapped = GnosticProtocol.publicFailure(
            for: error,
            fallbackCode: 500,
            fallbackReasonCode: "internalError",
            fallbackMessage: "fallback"
        )
        #expect(mapped.code == 500)
        #expect(mapped.message.contains("providerUnavailable"))
        #expect(mapped.message.contains("terminal failure"))
        #expect(!mapped.message.contains("backend-secret-detail"))
        let envelope = try JSONDecoder().decode(GnosticProtocolFailure.self, from: Data(mapped.message.utf8))
        #expect(envelope.reasonCode == "providerUnavailable")
        #expect(envelope.message == "The Ascendant backend reported a terminal failure.")
    }

    @Test("ordinary provider failures carry the protocol major envelope")
    func ordinaryProviderFailuresCarryProtocolMajor() async throws {
        let timelineID = UUID()
        let turnProvider = AscendantTurnProvider(
            execute: { _ in TurnResult(text: "unused") },
            isAvailable: { false }
        )
        let turnFailure = try await turnProvider.handle(operation: AscendantTurnProvider.turnOperation, parameters: nil)

        let permissionProvider = AscendantPermissionProvider(
            coordinator: AscendantPermissionCoordinator(updates: AscendantTurnUpdateStore())
        )
        let permission = TurnPermissionResponse(
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
        {"protocolMajor":1,"objectId":"\(objectID)","coreType":"CoatyObject","objectType":"\(GnosticObjectType.runtimeInstance)","name":"Old","runtimeID":"\(objectID)","runtimeKind":"local-command"}
        """
        let snapshot = CoatyObjectSnapshot(
            objectId: objectID,
            coreType: .coatyObject,
            objectType: GnosticObjectType.runtimeInstance,
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
        {"protocolMajor":3,"objectId":"\(objectID)","coreType":"CoatyObject","objectType":"\(GnosticObjectType.runtimeInstance)","name":"Current","runtimeID":"\(objectID)","runtimeKind":"local-command"}
        """
        let full = CoatyObjectSnapshot(objectId: objectID, coreType: .coatyObject, objectType: GnosticObjectType.runtimeInstance, name: "Current", payload: fullPayload)
        let metadata = CoatyObjectSnapshot(objectId: objectID, coreType: .coatyObject, objectType: GnosticObjectType.runtimeInstance, name: "Current")
        let catalog = NetworkCatalog()
        await catalog.ingest(AdvertiseEventSnapshot(sourceId: "provider", object: full))
        await catalog.ingest(AdvertiseEventSnapshot(sourceId: "provider", object: metadata))

        let entries = await catalog.networkObjects()
        #expect(entries.count == 1)
        #expect(entries.first?.protocolMajor == GnosticProtocol.currentMajor)
    }

    @Test("a delayed Resolve cannot replace a newer unavailable Workspace advertisement")
    func delayedResolveDoesNotOverrideNewWorkspaceStatus() async throws {
        let workspaceID = UUID()
        let providerID = UUID().uuidString.lowercased()
        let catalog = NetworkCatalog()
        let available = GnosticWorkspaceObject(workspace: GnosticWorkspaceReference(
            id: workspaceID,
            uri: "workspace://status-order",
            status: .active,
            effectiveStatus: .available
        ))
        let unavailable = GnosticWorkspaceObject(workspace: GnosticWorkspaceReference(
            id: workspaceID,
            uri: "workspace://status-order",
            status: .unknown,
            effectiveStatus: .unavailable
        ))
        func snapshot(_ object: GnosticWorkspaceObject) throws -> CoatyObjectSnapshot {
            let payload = try JSONEncoder().encode(object)
            return CoatyObjectSnapshot(
                objectId: object.objectId.string,
                coreType: .coatyObject,
                objectType: GnosticObjectType.workspace,
                name: object.name,
                payload: String(decoding: payload, as: UTF8.self)
            )
        }

        await catalog.ingest(AdvertiseEventSnapshot(sourceId: providerID, object: try snapshot(available)))
        let discoverStart = await catalog.workspaceAdvertisementSnapshot()
        await catalog.ingest(AdvertiseEventSnapshot(sourceId: providerID, object: try snapshot(unavailable)))
        let delayedResolve = ResponseEventSnapshot(
            eventType: "resolve",
            sourceId: providerID,
            correlationId: UUID().uuidString.lowercased(),
            payload: "{}",
            object: try snapshot(available)
        )

        await catalog.ingestResolutionResponse(delayedResolve, startedAt: discoverStart)

        #expect(await catalog.workspaceAttachmentStatus(id: workspaceID) == .unavailable)
    }

    @Test("a partial Workspace tool query stays incomplete until the owner sends its terminal page")
    func workspaceToolCatalogRequiresTerminalPage() async throws {
        let workspaceID = UUID()
        let providerID = UUID().uuidString.lowercased()
        let definitions = (0..<16).map { index in
            GnosticWorkspaceToolDefinition(
                id: "tool-\(index)",
                name: "Tool \(index)",
                description: String(repeating: "paged tool metadata ", count: 8),
                parametersSchema: ["type": .string("object")],
                requiresPermission: false
            )
        }
        let reference = GnosticWorkspaceReference(
            id: workspaceID,
            uri: "workspace://paged-tools",
            tools: definitions
        )
        let workspaceObject = GnosticWorkspaceObject(workspace: reference)
        #expect(!workspaceObject.toolsComplete)

        let workspacePayload = try JSONEncoder().encode(workspaceObject)
        let workspaceSnapshot = CoatyObjectSnapshot(
            objectId: workspaceObject.objectId.string,
            coreType: .coatyObject,
            objectType: GnosticObjectType.workspace,
            name: workspaceObject.name,
            payload: String(decoding: workspacePayload, as: UTF8.self)
        )
        let catalog = NetworkCatalog()
        await catalog.ingest(AdvertiseEventSnapshot(sourceId: providerID, object: workspaceSnapshot))
        let originalGenerations = await catalog.workspaceToolCatalogGenerations(id: workspaceID)
        let originalGeneration = try #require(originalGenerations[providerID])
        let initial = try #require(await catalog.workspaceDescriptor(id: workspaceID, providerID: providerID))
        #expect(!initial.toolsComplete)
        #expect(initial.tools.count < definitions.count)

        let lastTool = try #require(definitions.last)
        let originalPage = try workspaceToolResponse(
            workspaceID: workspaceID,
            providerID: providerID,
            definition: lastTool,
            page: definitions.count - 1
        )
        #expect(await catalog.ingestWorkspaceToolQueryResponse(
            originalPage,
            workspaceID: workspaceID,
            providerID: providerID,
            generation: originalGeneration
        ))
        let partial = try #require(await catalog.workspaceDescriptor(id: workspaceID, providerID: providerID))
        #expect(!partial.toolsComplete)
        #expect(partial.tools.contains { $0.id == lastTool.id })

        #expect(await catalog.markWorkspaceToolCatalogComplete(
            id: workspaceID,
            providerID: providerID,
            generation: originalGeneration
        ))
        let complete = try #require(await catalog.workspaceDescriptor(id: workspaceID, providerID: providerID))
        #expect(complete.toolsComplete)

        let replacementReference = GnosticWorkspaceReference(
            id: workspaceID,
            uri: reference.uri,
            tools: Array(definitions.dropLast())
        )
        let replacementObject = GnosticWorkspaceObject(workspace: replacementReference)
        await catalog.ingest(AdvertiseEventSnapshot(
            sourceId: providerID,
            object: CoatyObjectSnapshot(
                objectId: replacementObject.objectId.string,
                coreType: .coatyObject,
                objectType: GnosticObjectType.workspace,
                name: replacementObject.name,
                payload: String(decoding: try JSONEncoder().encode(replacementObject), as: UTF8.self)
            )
        ))
        let currentGenerations = await catalog.workspaceToolCatalogGenerations(id: workspaceID)
        let currentGeneration = try #require(currentGenerations[providerID])
        #expect(currentGeneration > originalGeneration)
        let refreshed = try #require(await catalog.workspaceDescriptor(id: workspaceID, providerID: providerID))
        #expect(!refreshed.toolsComplete)
        #expect(!refreshed.tools.contains { $0.id == lastTool.id })

        #expect(!(await catalog.ingestWorkspaceToolQueryResponse(
            originalPage,
            workspaceID: workspaceID,
            providerID: providerID,
            generation: originalGeneration
        )))
        #expect(!(await catalog.markWorkspaceToolCatalogComplete(
            id: workspaceID,
            providerID: providerID,
            generation: originalGeneration
        )))

        let currentPages = [definitions[definitions.count - 3], definitions[definitions.count - 2]]
        for (offset, tool) in currentPages.enumerated() {
            let currentPage = try workspaceToolResponse(
                workspaceID: workspaceID,
                providerID: providerID,
                definition: tool,
                page: definitions.count - 2 + offset
            )
            #expect(await catalog.ingestWorkspaceToolQueryResponse(
                currentPage,
                workspaceID: workspaceID,
                providerID: providerID,
                generation: currentGeneration
            ))
        }
        let concurrentPages = try #require(await catalog.workspaceDescriptor(id: workspaceID, providerID: providerID))
        #expect(currentPages.allSatisfy { page in concurrentPages.tools.contains { $0.id == page.id } })
        #expect(!concurrentPages.tools.contains { $0.id == lastTool.id })
        #expect(await catalog.markWorkspaceToolCatalogComplete(
            id: workspaceID,
            providerID: providerID,
            generation: currentGeneration
        ))
        let refreshedComplete = try #require(await catalog.workspaceDescriptor(id: workspaceID, providerID: providerID))
        #expect(refreshedComplete.toolsComplete)
    }

    @Test("remote Workspace authorization binds caller and attachment to one current Timeline owner")
    func catalogAuthorizesOnlyCurrentOwnerAttachments() async throws {
        let ownerTimelineID = UUID()
        let workspaceID = UUID()
        let firstOwnerID = UUID()
        let replacementOwnerID = UUID()
        let catalog = NetworkCatalog()
        func timelineSnapshot() -> CoatyObjectSnapshot {
            let payload = """
            {"protocolMajor":3,"objectId":"\(ownerTimelineID.uuidString.lowercased())","coreType":"CoatyObject","objectType":"\(GnosticObjectType.timeline)","name":"Remote timeline","title":"Remote timeline","isArchived":false,"attachedWorkspaceIDs":["\(workspaceID.uuidString.lowercased())"]}
            """
            return CoatyObjectSnapshot(
                objectId: ownerTimelineID.uuidString.lowercased(),
                coreType: .coatyObject,
                objectType: GnosticObjectType.timeline,
                name: "Remote timeline",
                payload: payload
            )
        }

        await catalog.ingest(AdvertiseEventSnapshot(
            sourceId: firstOwnerID.uuidString.lowercased(),
            object: timelineSnapshot()
        ))
        #expect(await catalog.authorizesWorkspaceCall(
            sourceID: firstOwnerID.uuidString,
            workspaceID: workspaceID,
            to: ownerTimelineID
        ))
        #expect(!(await catalog.authorizesWorkspaceCall(
            sourceID: replacementOwnerID.uuidString,
            workspaceID: workspaceID,
            to: ownerTimelineID
        )))

        // Replace the Timeline owner while preserving its attachment. The
        // former owner must not inherit the replacement owner's attachment.
        await catalog.ingest(DeadvertiseEventSnapshot(
            sourceId: firstOwnerID.uuidString.lowercased(),
            objectIds: [ownerTimelineID.uuidString]
        ))
        await catalog.ingest(AdvertiseEventSnapshot(
            sourceId: replacementOwnerID.uuidString.lowercased(),
            object: timelineSnapshot()
        ))
        #expect(!(await catalog.authorizesWorkspaceCall(
            sourceID: firstOwnerID.uuidString,
            workspaceID: workspaceID,
            to: ownerTimelineID
        )))
        #expect(await catalog.authorizesWorkspaceCall(
            sourceID: replacementOwnerID.uuidString,
            workspaceID: workspaceID,
            to: ownerTimelineID
        ))
        #expect(!(await catalog.authorizesWorkspaceCall(
            sourceID: replacementOwnerID.uuidString,
            workspaceID: UUID(),
            to: ownerTimelineID
        )))
    }

    private func workspaceToolResponse(
        workspaceID: UUID,
        providerID: String,
        definition: GnosticWorkspaceToolDefinition,
        page: Int
    ) throws -> ResponseEventSnapshot {
        let object = GnosticWorkspaceToolObject(workspaceID: workspaceID, definition: definition, page: page)
        let payload = try JSONEncoder().encode(object)
        return ResponseEventSnapshot(
            eventType: "resolve",
            sourceId: providerID,
            correlationId: UUID().uuidString.lowercased(),
            payload: "{}",
            object: CoatyObjectSnapshot(
                objectId: object.objectId.string,
                coreType: .coatyObject,
                objectType: GnosticObjectType.workspaceTool,
                name: object.name,
                payload: String(decoding: payload, as: UTF8.self)
            )
        )
    }
}
