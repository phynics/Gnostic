// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
@testable import GnosticCore
import GnosticProtocol
import GnosticWorkspaceTestSupport
import Testing

@Suite("Production Workspace invocation and query")
@MainActor
struct MultiplexedWorkspaceProviderTests {
    private let definition = GnosticWorkspaceToolDefinition(
        id: "allowed", name: "Allowed tool", description: "An advertised tool.",
        parametersSchema: ["type": .string("object")], requiresPermission: true
    )

    @Test("registry status blocks remote execution and recovery permits it", arguments: [
        NodeRegistry.WorkspaceEffectiveStatus.unavailable, .unsupported,
    ])
    func rejectsUnavailableWorkspace(status: NodeRegistry.WorkspaceEffectiveStatus) async throws {
        let workspace = WorkspaceInvocationTestWorkspace(id: UUID(), tools: [definition])
        let registry = try registry(for: workspace)
        let provider = provider(for: workspace, registry: registry)
        #expect(await registry.setWorkspaceStatus(id: workspace.reference.id, status: status))

        let rejected = try await provider.handle(parameters: payload(for: workspace))

        try expectFailure(rejected, code: 409, reason: "workspaceUnavailable")
        #expect(workspace.invocationCount == 0)
        #expect(await registry.setWorkspaceStatus(id: workspace.reference.id, status: .available))
        let accepted = try await provider.handle(parameters: payload(for: workspace))
        guard case .success = accepted else { Issue.record("available Workspace was rejected"); return }
        #expect(workspace.invocationCount == 1)
    }

    @Test("a missing registry record cannot authorize execution")
    func rejectsMissingStatus() async throws {
        let workspace = WorkspaceInvocationTestWorkspace(id: UUID(), tools: [definition])
        let emptyManifest = NodeManifest.empty(broker: .init(host: "127.0.0.1", port: 1883, namespace: "fixture"))
        let registry = try NodeRegistry(plan: emptyManifest.compileLaunchPlan(), operatedTimelines: [])
        let provider = provider(for: workspace, registry: registry)

        try expectFailure(try await provider.handle(parameters: payload(for: workspace)), code: 409, reason: "workspaceUnavailable")
        #expect(workspace.invocationCount == 0)
    }

    @Test("an unadvertised tool is rejected without exposing its identifier")
    func rejectsUnadvertisedTool() async throws {
        let workspace = WorkspaceInvocationTestWorkspace(id: UUID(), tools: [definition])
        let registry = try registry(for: workspace)
        let provider = provider(for: workspace, registry: registry)
        let forged = "private-unadvertised-tool"

        let response = try await provider.handle(parameters: payload(for: workspace, toolID: forged))

        let failure = try expectFailure(response, code: 403, reason: "workspaceToolNotAdvertised")
        #expect(!failure.message.contains(forged))
        #expect(workspace.invocationCount == 0)
    }

    @Test("invocation uses the current tool catalog rather than a cached reference")
    func rejectsRemovedTool() async throws {
        let workspace = WorkspaceInvocationTestWorkspace(id: UUID(), tools: [definition])
        let registry = try registry(for: workspace)
        let provider = provider(for: workspace, registry: registry)
        workspace.tools = []

        try expectFailure(try await provider.handle(parameters: payload(for: workspace)), code: 403, reason: "workspaceToolNotAdvertised")
        #expect(workspace.invocationCount == 0)
    }

    @Test("a Workspace that becomes unhealthy after listing fails closed")
    func rejectsWorkspaceHealthChange() async throws {
        let workspace = WorkspaceInvocationTestWorkspace(id: UUID(), tools: [definition])
        let registry = try registry(for: workspace)
        let provider = provider(for: workspace, registry: registry)
        workspace.beforeListing = { workspace.isHealthy = false }

        try expectFailure(try await provider.handle(parameters: payload(for: workspace)), code: 409, reason: "workspaceUnavailable")
        #expect(workspace.invocationCount == 0)
    }

    @Test("availability is checked again after tool enumeration suspends")
    func rejectsStatusChangeDuringListing() async throws {
        let workspace = WorkspaceInvocationTestWorkspace(id: UUID(), tools: [definition])
        let registry = try registry(for: workspace)
        let workspaceID = workspace.reference.id
        workspace.beforeListing = {
            _ = await registry.setWorkspaceStatus(id: workspaceID, status: .unavailable)
        }
        let provider = provider(for: workspace, registry: registry)

        try expectFailure(try await provider.handle(parameters: payload(for: workspace)), code: 409, reason: "workspaceUnavailable")
        #expect(workspace.invocationCount == 0)
    }

    @Test("a status revision change across owner admission blocks execution")
    func rejectsStatusRevokedAcrossAdmission() async throws {
        let workspace = WorkspaceInvocationTestWorkspace(id: UUID(), tools: [definition])
        let registry = try registry(for: workspace)
        let provider = MultiplexedWorkspaceProvider(
            workspaces: [workspace.reference.id: workspace],
            workspaceStatus: { id in await registry.effectiveWorkspaceStatus(id: id) },
            setWorkspaceStatus: { id, status in await registry.setWorkspaceStatus(id: id, status: status) },
            callerBoundAuthorization: { _, _, _ in true },
            admitInvocation: { _, _, workspaceID in
                await registry.admitsWorkspaceInvocation(id: workspaceID) {
                    _ = await registry.setWorkspaceStatus(id: workspaceID, status: .unavailable)
                    return true
                }
            },
            isAvailable: { true }
        )

        try expectFailure(
            try await provider.handle(parameters: payload(for: workspace)),
            code: 409,
            reason: "workspaceUnavailable"
        )

        #expect(await registry.effectiveWorkspaceStatus(id: workspace.reference.id) == .unavailable)
        #expect(workspace.invocationCount == 0)
    }

    @Test("a lifecycle generation change across owner admission blocks execution")
    func rejectsLifecycleChangeAcrossAdmission() async throws {
        let workspace = WorkspaceInvocationTestWorkspace(id: UUID(), tools: [definition])
        let registry = try registry(for: workspace)
        await registry.setLifecycleGeneration(1)
        let provider = MultiplexedWorkspaceProvider(
            workspaces: [workspace.reference.id: workspace],
            workspaceStatus: { id in await registry.effectiveWorkspaceStatus(id: id) },
            setWorkspaceStatus: { id, status in await registry.setWorkspaceStatus(id: id, status: status) },
            callerBoundAuthorization: { _, _, _ in true },
            admitInvocation: { _, _, workspaceID in
                await registry.admitsWorkspaceInvocation(id: workspaceID) {
                    await registry.setLifecycleGeneration(2)
                    return true
                }
            },
            isAvailable: { true }
        )

        try expectFailure(
            try await provider.handle(parameters: payload(for: workspace)),
            code: 403,
            reason: "workspaceNotAttached"
        )
        #expect(workspace.invocationCount == 0)
    }

    @Test("a detach during the final status await is rejected by owner admission")
    func rejectsDetachBeforeOwnerAdmission() async throws {
        let workspace = WorkspaceInvocationTestWorkspace(id: UUID(), tools: [definition])
        let timelineID = UUID()
        let callerID = UUID()
        let registry = try registry(for: workspace)
        let catalog = NetworkCatalog()
        let statusGate = WorkspaceAdmissionStatusGate()
        await catalog.ingest(AdvertiseEventSnapshot(
            sourceId: callerID.uuidString.lowercased(),
            object: timelineSnapshot(timelineID: timelineID, workspaceID: workspace.reference.id)
        ))
        let provider = MultiplexedWorkspaceProvider(
            workspaces: [workspace.reference.id: workspace],
            workspaceStatus: { id in
                await statusGate.pauseOnSecondRead()
                return await registry.effectiveWorkspaceStatus(id: id)
            },
            setWorkspaceStatus: { id, status in await registry.setWorkspaceStatus(id: id, status: status) },
            callerBoundAuthorization: { _, _, _ in true },
            admitInvocation: { sourceID, timelineID, workspaceID in
                await registry.admitsWorkspaceInvocation(id: workspaceID) {
                    await catalog.authorizesWorkspaceCall(
                        sourceID: sourceID ?? "",
                        workspaceID: workspaceID,
                        to: timelineID ?? UUID()
                    )
                }
            },
            isAvailable: { true }
        )
        let invocation = try payload(for: workspace, timelineID: timelineID)
        let operation = Task {
            try await provider.handle(
                parameters: invocation,
                expectedProviderID: nil,
                callerSourceID: callerID.uuidString
            )
        }
        await statusGate.waitUntilPaused()
        await catalog.ingest(DeadvertiseEventSnapshot(
            sourceId: callerID.uuidString.lowercased(),
            objectIds: [timelineID.uuidString]
        ))
        await statusGate.release()

        try expectFailure(try await operation.value, code: 403, reason: "workspaceNotAttached")
        #expect(!(await catalog.authorizesWorkspaceCall(
            sourceID: callerID.uuidString,
            workspaceID: workspace.reference.id,
            to: timelineID
        )))
        #expect(workspace.invocationCount == 0)
    }

    @Test("the enumerated permission definition remains the invocation policy snapshot")
    func usesEnumeratedToolPolicySnapshot() async throws {
        let workspace = WorkspaceInvocationTestWorkspace(id: UUID(), tools: [definition])
        let registry = try registry(for: workspace)
        let provider = MultiplexedWorkspaceProvider(
            workspaces: [workspace.reference.id: workspace],
            workspaceStatus: { id in await registry.effectiveWorkspaceStatus(id: id) },
            setWorkspaceStatus: { id, status in await registry.setWorkspaceStatus(id: id, status: status) },
            callerBoundAuthorization: { _, _, _ in true },
            admitInvocation: { _, _, _ in
                await MainActor.run { workspace.tools = [] }
                return true
            },
            isAvailable: { true }
        )

        guard case .success = try await provider.handle(parameters: payload(for: workspace)) else {
            Issue.record("the invocation's enumerated tool definition was not honored")
            return
        }
        #expect(workspace.invocationCount == 1)
    }

    @Test("a stopped Node cannot dispatch a Workspace tool")
    func rejectsStoppedNode() async throws {
        let workspace = WorkspaceInvocationTestWorkspace(id: UUID(), tools: [definition])
        let provider = MultiplexedWorkspaceProvider(
            workspaces: [workspace.reference.id: workspace],
            workspaceStatus: { _ in .available },
            setWorkspaceStatus: { _, _ in false },
            callerBoundAuthorization: { _, _, _ in true },
            admitInvocation: { _, _, _ in true },
            isAvailable: { false }
        )

        try expectFailure(try await provider.handle(parameters: payload(for: workspace)), code: 503, reason: "notRunning")
        #expect(workspace.invocationCount == 0)
    }

    @Test("query defaults to the first sorted page and preserves the terminal answer")
    func queryPagination() async throws {
        let second = GnosticWorkspaceToolDefinition(id: "z-last", name: "Last", description: "Last tool.")
        let workspace = WorkspaceInvocationTestWorkspace(id: UUID(), tools: [second, definition])
        let provider = provider(for: workspace, registry: try registry(for: workspace))

        let first = try #require(try await provider.queryObjects(query(workspaceID: workspace.reference.id)))
        #expect(first.map(\.toolID) == [definition.id])
        let tool = try #require(first.first)
        #expect(tool.page == 0)
        #expect(tool.toolName == definition.name)
        #expect(tool.toolDescription == definition.description)
        #expect(tool.parametersSchema == definition.parametersSchema)
        #expect(tool.requiresPermission == definition.requiresPermission)
        let next = try #require(try await provider.queryObjects(query(workspaceID: workspace.reference.id, page: 1)))
        #expect(next.map(\.toolID) == [second.id])
        let terminal = try #require(try await provider.queryObjects(query(workspaceID: workspace.reference.id, page: 2)))
        #expect(terminal.isEmpty)
        #expect(try await provider.queryObjects(query(workspaceID: workspace.reference.id, page: -1)) == nil)
        #expect(try await provider.queryObjects(query(workspaceID: workspace.reference.id, page: "invalid")) == nil)
        #expect(try await provider.queryObjects(query(workspaceID: UUID())) == nil)
        #expect(workspace.invocationCount == 0)
    }

    private func registry(for workspace: WorkspaceInvocationTestWorkspace) throws -> NodeRegistry {
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "fixture"), node: .init(id: UUID()),
            workspaces: [.init(id: workspace.reference.id, name: "Fixture", uri: workspace.reference.uri)]
        )
        return try NodeRegistry(plan: manifest.compileLaunchPlan(), operatedTimelines: [])
    }

    private func provider(for workspace: WorkspaceInvocationTestWorkspace, registry: NodeRegistry) -> MultiplexedWorkspaceProvider {
        MultiplexedWorkspaceProvider(
            workspaces: [workspace.reference.id: workspace],
            workspaceStatus: { id in await registry.effectiveWorkspaceStatus(id: id) },
            setWorkspaceStatus: { id, status in await registry.setWorkspaceStatus(id: id, status: status) },
            callerBoundAuthorization: { _, _, _ in true },
            admitInvocation: { _, _, _ in true },
            isAvailable: { true }
        )
    }

    private func payload(for workspace: WorkspaceInvocationTestWorkspace, toolID: String = "allowed", permissionApproved: Bool = true, timelineID: UUID? = nil) throws -> String {
        String(decoding: try JSONEncoder().encode(WorkspaceInvocation(
            timelineID: timelineID,
            permissionApproved: permissionApproved,
            workspaceID: workspace.reference.id,
            toolID: toolID
        )), as: UTF8.self)
    }

    private func timelineSnapshot(timelineID: UUID, workspaceID: UUID) -> CoatyObjectSnapshot {
        let payload = """
        {"protocolMajor":3,"objectId":"\(timelineID.uuidString.lowercased())","coreType":"CoatyObject","objectType":"\(GnosticObjectType.timeline)","name":"Remote timeline","title":"Remote timeline","isArchived":false,"attachedWorkspaceIDs":["\(workspaceID.uuidString.lowercased())"]}
        """
        return CoatyObjectSnapshot(
            objectId: timelineID.uuidString.lowercased(),
            coreType: .coatyObject,
            objectType: GnosticObjectType.timeline,
            name: "Remote timeline",
            payload: payload
        )
    }

    private func query(workspaceID: UUID, page: Any? = nil) throws -> QueryEventSnapshot {
        var conditions: [[Any]] = [["workspaceID", [7, workspaceID.uuidString.lowercased()]]]
        if let page { conditions.append(["page", [7, page]]) }
        let filter = try JSONSerialization.data(withJSONObject: ["conditions": ["and": conditions]])
        return QueryEventSnapshot(objectTypes: [GnosticObjectType.workspaceTool], objectFilter: String(decoding: filter, as: UTF8.self))
    }

    @discardableResult
    private func expectFailure(_ response: CallHandlerResult, code: Int, reason: String) throws -> GnosticProtocolFailure {
        guard case let .failure(actualCode, encoded, _) = response else {
            Issue.record("expected a structured invocation failure")
            return GnosticProtocolFailure(reasonCode: "missing", message: "missing")
        }
        let failure = try JSONDecoder().decode(GnosticProtocolFailure.self, from: Data(encoded.utf8))
        #expect(actualCode == code)
        #expect(failure.statusCode == code)
        #expect(failure.reasonCode == reason)
        #expect(failure.protocolMajor == GnosticProtocol.currentMajor)
        return failure
    }
}

private actor WorkspaceAdmissionStatusGate {
    private var reads = 0
    private var paused = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []

    func pauseOnSecondRead() async {
        reads += 1
        guard reads == 2 else { return }
        paused = true
        for waiter in pauseWaiters { waiter.resume() }
        pauseWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilPaused() async {
        guard !paused else { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
