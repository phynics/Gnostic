// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Axoloty
@testable import GnosticCore
import JSONSchema
import PKContracts
import PositronicKit
import struct PositronicKit.Thread
import Testing

@Suite("Gnostic workspace provider")
struct WorkspaceProviderTests {
    @Test("catalog lists provider-scoped entries for network inspection")
    func catalogListsNetworkObjects() async {
        let catalog = NetworkCatalog()
        #expect(await catalog.networkObjects().isEmpty)
    }

    @Test("attachment service refuses unapproved discovered workspaces")
    @MainActor
    func attachmentRequiresApproval() async throws {
        let catalog = NetworkCatalog()
        let kit = PositronicKit()
        let timeline = try await kit.threads.create()
        let service = DiscoveredWorkspaceAttachmentService(
            catalog: catalog,
            threadCapability: kit.threads,
            workspaceCapability: kit.workspaces
        )

        await #expect(throws: DiscoveredWorkspaceAttachmentError.self) {
            try await service.attach(workspaceID: UUID(), to: timeline.id, approved: false)
        }
    }

    @Test("network management API lists and inspects without attaching") @MainActor
    func networkManagementInspection() async throws {
        let catalog = NetworkCatalog()
        let kit = PositronicKit()
        let service = DiscoveredWorkspaceAttachmentService(catalog: catalog, threadCapability: kit.threads, workspaceCapability: kit.workspaces)
        #expect(await service.listNetworkObjects().isEmpty)
        #expect(await service.inspectNetworkObject(id: UUID(), providerID: "none") == nil)
    }

    @Test("public network tools expose exact IDs, approval metadata, and callable schemas") @MainActor
    func publicNetworkToolsMetadataAndInvalidInput() async throws {
        let service = DiscoveredWorkspaceAttachmentService(
            catalog: NetworkCatalog(),
            threadCapability: PositronicKit().threads,
            workspaceCapability: PositronicKit().workspaces
        )
        let list = ListNetworkObjectsTool(service: service).toAnyTool()
        let inspect = InspectNetworkObjectTool(service: service).toAnyTool()
        let attach = AttachWorkspaceTool(service: service).toAnyTool()
        #expect(list.callName == "list_network_objects")
        #expect(inspect.callName == "inspect_network_object")
        #expect(attach.callName == "attach_workspace")
        #expect(!list.requiresPermission)
        #expect(!inspect.requiresPermission)
        #expect(attach.requiresPermission)
        let listSchema = try schemaObject(list.parametersSchema)
        let inspectSchema = try schemaObject(inspect.parametersSchema)
        let attachSchema = try schemaObject(attach.parametersSchema)
        #expect(listSchema["type"] as? String == "object")
        #expect((inspectSchema["properties"] as? [String: Any])?.keys.sorted() == ["objectId", "providerId"])
        #expect((inspectSchema["required"] as? [String])?.sorted() == ["objectId", "providerId"])
        #expect((attachSchema["properties"] as? [String: Any])?.keys.sorted() == ["timelineId", "workspaceId"])
        #expect((attachSchema["required"] as? [String])?.sorted() == ["timelineId", "workspaceId"])
        #expect((try await list.execute(parameters: [:])).success)
        #expect(!(try await inspect.execute(parameters: [:])).success)
        #expect(!(try await attach.execute(parameters: [:])).success)
    }

    @Test("attachment imports a discovered runtime workspace, attaches it, and readvertises the timeline") @MainActor
    func attachmentImportsAndReadvertises() async throws {
        let workspaceID = UUID(uuidString: "B31D0000-0000-4000-8000-000000000003")!
        let catalog = NetworkCatalog()
        let payload = """
        {"protocolMajor":2,"objectId":"\(workspaceID.uuidString.lowercased())","coreType":"CoatyObject","objectType":"me.atkn.gnostic.Workspace","name":"Remote","uri":"workspace://remote","isAvailable":true,"tools":[{"id":"custom","name":"Custom","toolDescription":"Custom remote tool","parametersSchema":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]},"requiresPermission":false}]}
        """
        await catalog.ingest(AdvertiseEventSnapshot(sourceId: "remote", object: CoatyObjectSnapshot(objectId: workspaceID.uuidString.lowercased(), coreType: .CoatyObject, objectType: GnosticObjectType.workspace, name: "Remote", payload: payload)))
        let store = InMemoryWorkspacePersistence()
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: UnconfiguredLLMService()),
            persistence: .init(workspacePersistence: store),
            runtime: .init(workspaceCreator: AxolotyWorkspaceFactory(catalog: catalog) { _ in .success("unused") })
        ))
        let timeline = try await kit.threads.create()
        let recorder = TimelineRecorder()
        let service = DiscoveredWorkspaceAttachmentService(catalog: catalog, threadCapability: kit.threads, workspaceCapability: kit.workspaces, readvertiseTimeline: { recorder.record($0) })

        let reference = try await service.attach(workspaceID: workspaceID, to: timeline.id, approved: true)
        #expect(reference.location == .runtime)
        #expect(reference.tools.map(\.toolID) == ["custom"])
        let tool = try #require(reference.tools.first)
        guard case let .custom(definition) = tool else {
            Issue.record("attached tool must remain a custom definition")
            return
        }
        let projectedSchema = try schemaObject(definition.parametersSchema)
        #expect(projectedSchema["type"] as? String == "object")
        #expect(projectedSchema["required"] as? [String] == ["query"])
        let properties = try #require(projectedSchema["properties"] as? [String: Any])
        #expect((properties["query"] as? [String: Any])?["type"] as? String == "string")
        #expect(try await kit.threads.get(timeline.id)?.attachedWorkspaceIDs == [workspaceID])
        #expect(recorder.ids == [timeline.id])
    }

    @Test("backend attachment tools delegate authority to the Gnostic host") @MainActor
    func backendAttachmentUsesHostAuthority() async throws {
        let workspaceID = UUID(uuidString: "B31D0000-0000-4000-8000-000000000009")!
        let catalog = NetworkCatalog()
        let payload = """
        {"protocolMajor":2,"objectId":"\(workspaceID.uuidString.lowercased())","coreType":"CoatyObject","objectType":"me.atkn.gnostic.Workspace","name":"Remote","uri":"workspace://remote-authority","isAvailable":true,"tools":[]}
        """
        await catalog.ingest(AdvertiseEventSnapshot(sourceId: "remote", object: CoatyObjectSnapshot(objectId: workspaceID.uuidString.lowercased(), coreType: .CoatyObject, objectType: GnosticObjectType.workspace, name: "Remote", payload: payload)))

        let kit = PositronicKit()
        let timeline = try await kit.threads.create(title: "Timeline")
        let recorder = BackendAttachmentRecorder()
        let host = BackendWorkspaceAttachmentCapability { workspace, timeline in
            await recorder.record(workspaceID: workspace, timelineID: timeline)
        }
        let service = DiscoveredWorkspaceAttachmentService(
            catalog: catalog,
            threadCapability: kit.threads,
            workspaceCapability: kit.workspaces,
            hostAttachment: host
        )
        let tool = AttachWorkspaceTool(service: service)

        let result = try await tool.execute(parameters: [
            "workspaceId": AnyCodable(workspaceID.uuidString),
            "timelineId": AnyCodable(timeline.id.uuidString),
        ])

        #expect(result.success)
        #expect(await recorder.workspaceID == workspaceID)
        #expect(await recorder.timelineID == timeline.id)
        #expect(try await kit.threads.get(timeline.id)?.attachedWorkspaceIDs.isEmpty == true)
    }

    @Test("provider preserves advertised custom definitions and dispatches the addressed tool")
    func providerDispatchesAdvertisedTool() async throws {
        let workspaceID = UUID(uuidString: "B31D0000-0000-4000-8000-000000000001")!
        let definition = GnosticWorkspaceToolDefinition(
            id: "search_notes",
            name: "Search notes",
            description: "Searches remote notes.",
            parametersSchema: ["query": .string("string")]
        )
        let provider = WorkspaceProvider(workspaceID: workspaceID, tools: [definition]) { toolID, arguments in
            #expect(toolID == "search_notes")
            #expect(arguments["query"] == AnyCodable("wave 2"))
            return .success("found")
        }

        #expect(await provider.listTools() == [GnosticWorkspaceTool(definition: definition)])
        let result = try await provider.invoke(
            WorkspaceInvocation(workspaceID: workspaceID, toolID: "search_notes", arguments: ["query": AnyCodable("wave 2")])
        )
        #expect(result.success)
        #expect(result.output == "found")
    }

    @Test("provider wraps malformed and executor failures in protocol envelopes")
    func providerHandleFailuresCarryProtocolMajor() async throws {
        struct InjectedFailure: Error {}
        let workspaceID = UUID(uuidString: "B31D0000-0000-4000-8000-000000000006")!
        let provider = WorkspaceProvider(
            workspaceID: workspaceID,
            tools: [GnosticWorkspaceToolDefinition(id: "custom", name: "Custom", description: "Remote")]
        ) { _, _ in
            throw InjectedFailure()
        }

        let malformed = try await provider.handle(parameters: #"{"protocolMajor":2}"#)
        let malformedFailure = try protocolFailure(from: malformed)
        #expect(malformedFailure.protocolMajor == GnosticProtocol.currentMajor)

        let payload = String(decoding: try JSONEncoder().encode(
            WorkspaceInvocation(workspaceID: workspaceID, toolID: "custom", arguments: [:])
        ), as: UTF8.self)
        let executorFailure = try await provider.handle(parameters: payload)
        let executorFailureEnvelope = try protocolFailure(from: executorFailure)
        #expect(executorFailureEnvelope.protocolMajor == GnosticProtocol.currentMajor)
        #expect(executorFailureEnvelope.reasonCode == "workspaceInvocationFailed")
    }

    @Test("provider preserves cancellation from an executor")
    func providerHandlePreservesCancellation() async throws {
        let workspaceID = UUID(uuidString: "B31D0000-0000-4000-8000-000000000007")!
        let provider = WorkspaceProvider(
            workspaceID: workspaceID,
            tools: [GnosticWorkspaceToolDefinition(id: "custom", name: "Custom", description: "Remote")]
        ) { _, _ in
            throw CancellationError()
        }
        let payload = String(decoding: try JSONEncoder().encode(
            WorkspaceInvocation(workspaceID: workspaceID, toolID: "custom", arguments: [:])
        ), as: UTF8.self)

        await #expect(throws: CancellationError.self) {
            _ = try await provider.handle(parameters: payload)
        }
    }

    @Test("remote proxy exposes advertised custom tools and rejects direct file access")
    func proxyExposesToolsWithoutFilesystemFallback() async throws {
        let workspaceID = UUID(uuidString: "B31D0000-0000-4000-8000-000000000002")!
        let reference = WorkspaceReference(
            id: workspaceID,
            uri: WorkspaceURI(parsing: "workspace://remote")!,
            location: .runtime,
            tools: [.custom(WorkspaceToolDefinition(id: "inspect", name: "Inspect", description: "Inspects remote state."))]
        )
        let proxy = AxolotyWorkspace(reference: reference, catalog: NetworkCatalog(), invoke: { _ in .success("unused") })

        #expect(try await proxy.listTools() == reference.tools)
        await #expect(throws: WorkspaceError.self) { try await proxy.readFile(path: "never-local") }
    }

    @Test("deadvertised workspace refuses execution before transport")
    func deadvertisedWorkspaceRefusesExecution() async throws {
        let id = UUID(uuidString: "B31D0000-0000-4000-8000-000000000004")!
        let catalog = NetworkCatalog()
        let payload = """
        {"protocolMajor":2,"objectId":"\(id.uuidString.lowercased())","coreType":"CoatyObject","objectType":"me.atkn.gnostic.Workspace","name":"Remote","uri":"workspace://remote","isAvailable":true,"tools":[{"id":"custom","name":"Custom","toolDescription":"Remote","parametersSchema":{},"requiresPermission":false}]}
        """
        await catalog.ingest(AdvertiseEventSnapshot(sourceId: "remote", object: CoatyObjectSnapshot(objectId: id.uuidString.lowercased(), coreType: .CoatyObject, objectType: GnosticObjectType.workspace, name: "Remote", payload: payload)))
        let called = InvocationRecorder()
        let reference = WorkspaceReference(id: id, uri: WorkspaceURI(parsing: "workspace://remote")!, location: .runtime, tools: [.custom(WorkspaceToolDefinition(id: "custom", name: "Custom", description: "Remote"))])
        let proxy = AxolotyWorkspace(reference: reference, catalog: catalog) { _ in await called.record(); return .success("unexpected") }
        #expect(await proxy.healthCheck())
        await catalog.ingest(DeadvertiseEventSnapshot(sourceId: "remote", objectIds: [id.uuidString]))
        let isHealthy = await proxy.healthCheck()
        #expect(!isHealthy)
        await #expect(throws: WorkspaceError.self) { try await proxy.executeTool(id: "custom", parameters: [:]) }
        let wasCalled = await called.value
        #expect(!wasCalled)
    }

    @Test("ambiguous and malformed workspaces are unhealthy and never invoke transport")
    func unsafeCatalogStatesRefuseExecution() async throws {
        let id = UUID(uuidString: "B31D0000-0000-4000-8000-000000000005")!
        let catalog = NetworkCatalog()
        let malformed = CoatyObjectSnapshot(objectId: id.uuidString.lowercased(), coreType: .CoatyObject, objectType: GnosticObjectType.workspace, name: "Bad", payload: "{\"objectId\":\"\(id.uuidString.lowercased())\",\"uri\":\"workspace://bad\",\"isAvailable\":true,\"tools\":[{\"name\":\"missing\"}]}")
        await catalog.ingest(AdvertiseEventSnapshot(sourceId: "a", object: malformed))
        let recorder = InvocationRecorder()
        let reference = WorkspaceReference(id: id, uri: WorkspaceURI(parsing: "workspace://bad")!, location: .runtime, tools: [.custom(WorkspaceToolDefinition(id: "x", name: "X", description: "X"))])
        let proxy = AxolotyWorkspace(reference: reference, catalog: catalog) { _ in await recorder.record(); return .success("unexpected") }
        let malformedHealth = await proxy.healthCheck()
        #expect(!malformedHealth)
        await #expect(throws: WorkspaceError.self) { try await proxy.executeTool(id: "x", parameters: [:]) }
        await catalog.ingest(AdvertiseEventSnapshot(sourceId: "a", object: CoatyObjectSnapshot(objectId: id.uuidString.lowercased(), coreType: .CoatyObject, objectType: GnosticObjectType.workspace, name: "Good", payload: "{\"objectId\":\"\(id.uuidString.lowercased())\",\"coreType\":\"CoatyObject\",\"objectType\":\"me.atkn.gnostic.Workspace\",\"name\":\"Good\",\"uri\":\"workspace://good\",\"isAvailable\":true,\"tools\":[]}")))
        await catalog.ingest(AdvertiseEventSnapshot(sourceId: "b", object: CoatyObjectSnapshot(objectId: id.uuidString.lowercased(), coreType: .CoatyObject, objectType: GnosticObjectType.workspace, name: "Good", payload: "{\"objectId\":\"\(id.uuidString.lowercased())\",\"coreType\":\"CoatyObject\",\"objectType\":\"me.atkn.gnostic.Workspace\",\"name\":\"Good\",\"uri\":\"workspace://good\",\"isAvailable\":true,\"tools\":[]}")))
        let ambiguousHealth = await proxy.healthCheck()
        #expect(!ambiguousHealth)
        await #expect(throws: WorkspaceError.self) { try await proxy.executeTool(id: "x", parameters: [:]) }
        let invoked = await recorder.value
        #expect(!invoked)
    }

    @Test("remote invocation maps transport and decoding failures to workspace errors")
    func remoteInvocationMapsFailures() async throws {
        let catalog = NetworkCatalog()
        let reference = try await availableWorkspaceReference(catalog: catalog)

        for failure: any Error in [
            AxolotyError.runtime(code: .timedOut, reason: "The unary call timed out"),
            RemoteCallFailure(code: -32602, message: "Invalid params"),
            AxolotyError.decodingFailure(type: "ReturnEvent", reason: "Malformed", payload: nil),
        ] {
            let proxy = AxolotyWorkspace(reference: reference, catalog: catalog) { _ in throw failure }
            await #expect(throws: WorkspaceError.self) {
                try await proxy.executeTool(id: "custom", parameters: [:])
            }
        }
    }

    @Test("remote invocation preserves caller cancellation")
    func remoteInvocationPreservesCancellation() async throws {
        let catalog = NetworkCatalog()
        let reference = try await availableWorkspaceReference(catalog: catalog)
        let proxy = AxolotyWorkspace(reference: reference, catalog: catalog) { _ in throw CancellationError() }

        await #expect(throws: CancellationError.self) {
            try await proxy.executeTool(id: "custom", parameters: [:])
        }
    }

    @Test("Mosquitto unary Call Return invokes an arbitrary workspace tool") @MainActor
    func brokerUnaryWorkspaceInvocation() async throws {
        let caller = makeBrokerManager("caller")
        let remote = makeBrokerManager("remote")
        defer { caller.stop(); remote.stop() }
        try await startBrokerManager(caller)
        try await startBrokerManager(remote)
        let id = UUID()
        let provider = WorkspaceProvider(workspaceID: id, tools: [GnosticWorkspaceToolDefinition(id: "custom", name: "Custom", description: "Remote")]) { toolID, _ in
            #expect(toolID == "custom")
            return .success("broker-result")
        }
        let registration = try await provider.register(on: remote)
        defer { registration.cancel() }
        let payload = try JSONEncoder().encode(WorkspaceInvocation(workspaceID: id, toolID: "custom", arguments: [:]))
        let response = try await caller.call(operation: WorkspaceProvider.invocationOperation, parameters: String(decoding: payload, as: UTF8.self), timeout: .seconds(3))
        let result = try JSONDecoder().decode(ToolResult.self, from: Data(response.result.utf8))
        #expect(result.success)
        #expect(result.output == "broker-result")
    }

    @Test("workspace invocation selects the attached provider and rejects forged returns") @MainActor
    func brokerWorkspaceInvocationPreservesProviderIdentity() async throws {
        let namespace = "gnostic-workspace-routing-\(UUID().uuidString.lowercased())"
        let caller = makeBrokerManager("caller", namespace: namespace)
        let target = makeBrokerManager("target", namespace: namespace)
        let competing = makeBrokerManager("competing", namespace: namespace)
        defer {
            caller.stop()
            target.stop()
            competing.stop()
        }
        try await startBrokerManager(caller)
        try await startBrokerManager(target)
        try await startBrokerManager(competing)

        let targetRegistration = try await target.registerCallHandler(
            operation: WorkspaceProvider.invocationOperation,
            context: target.identity
        ) { _ in
            try await Task.sleep(for: .milliseconds(100))
            return .success(result: try encodeProtocolToolResult("target"))
        }
        defer { targetRegistration.cancel() }
        let competingRegistration = try await competing.registerCallHandler(
            operation: WorkspaceProvider.invocationOperation,
            context: competing.identity
        ) { _ in
            .failure(code: 499, message: "non-target provider")
        }
        defer { competingRegistration.cancel() }

        let catalog = NetworkCatalog()
        let reference = try await availableWorkspaceReference(catalog: catalog, providerID: target.identity.objectId.string)
        let workspace = AxolotyWorkspace(reference: reference, catalog: catalog, communication: caller, timeout: .seconds(3))

        let selected = try await workspace.executeTool(id: "custom", parameters: [:])
        #expect(selected.output == "target")

        targetRegistration.cancel()
        let forgedRegistration = try await competing.registerCallHandler(
            operation: WorkspaceProvider.invocationOperation,
            context: target.identity
        ) { _ in
            return .success(result: try encodeProtocolToolResult("forged"))
        }
        defer { forgedRegistration.cancel() }

        await #expect(throws: WorkspaceError.self) {
            try await workspace.executeTool(id: "custom", parameters: [:])
        }
    }
}

private func schemaObject(_ schema: Schema) throws -> [String: Any] {
    let data = try JSONEncoder().encode(schema)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func schemaObject(_ schema: [String: AnyCodable]) throws -> [String: Any] {
    let data = try JSONEncoder().encode(schema)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func protocolFailure(from response: CallHandlerResult) throws -> GnosticProtocolFailure {
    guard case let .failure(_, message, _) = response else {
        Issue.record("expected a protocol failure, got \(response)")
        return GnosticProtocolFailure(reasonCode: "missing", message: "missing")
    }
    return try JSONDecoder().decode(GnosticProtocolFailure.self, from: Data(message.utf8))
}

private func encodeProtocolToolResult(_ output: String) throws -> String {
    let data = try JSONEncoder().encode(ToolResult.success(output))
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["protocolMajor"] = GnosticProtocol.currentMajor
    let encoded = try JSONSerialization.data(withJSONObject: object)
    return try #require(String(data: encoded, encoding: .utf8))
}

private final class TimelineRecorder: @unchecked Sendable {
    private(set) var ids: [UUID] = []
    func record(_ timeline: Thread) { ids.append(timeline.id) }
}

private actor BackendAttachmentRecorder {
    private(set) var workspaceID: UUID?
    private(set) var timelineID: UUID?

    func record(workspaceID: UUID, timelineID: UUID) {
        self.workspaceID = workspaceID
        self.timelineID = timelineID
    }
}

private actor InvocationRecorder {
    private(set) var value = false
    func record() { value = true }
}

private func availableWorkspaceReference(catalog: NetworkCatalog, providerID: String = "remote") async throws -> WorkspaceReference {
    let id = UUID()
    let payload = """
    {"protocolMajor":2,"objectId":"\(id.uuidString.lowercased())","coreType":"CoatyObject","objectType":"me.atkn.gnostic.Workspace","name":"Remote","uri":"workspace://remote","isAvailable":true,"tools":[{"id":"custom","name":"Custom","toolDescription":"Remote","parametersSchema":{},"requiresPermission":false}]}
    """
    await catalog.ingest(AdvertiseEventSnapshot(sourceId: providerID, object: CoatyObjectSnapshot(objectId: id.uuidString.lowercased(), coreType: .CoatyObject, objectType: GnosticObjectType.workspace, name: "Remote", payload: payload)))
    return WorkspaceReference(
        id: id,
        uri: WorkspaceURI(parsing: "workspace://remote")!,
        location: .runtime,
        tools: [.custom(WorkspaceToolDefinition(id: "custom", name: "Custom", description: "Remote"))]
    )
}

@MainActor
private func makeBrokerManager(_ name: String, namespace: String = "gnostic-workspace-tests") -> CommunicationManager {
    let options = CommunicationOptions(namespace: namespace, shouldEnableCrossNamespacing: false, mqttClientOptions: MQTTClientOptions(host: "127.0.0.1", port: 1883, shouldTryMDNSDiscovery: false, autoReconnect: false), shouldAutoStart: false)
    return try! CommunicationManager(identity: Identity(name: name), communicationOptions: options, commonOptions: nil)
}

@MainActor
private func startBrokerManager(_ manager: CommunicationManager) async throws {
    let stream = await manager.observeCommunicationStateStream()
    var iterator = stream.makeAsyncIterator()
    try manager.start()
    while let state = await iterator.next() {
        if state == .online { return }
    }
    throw CancellationError()
}
