// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKShared
import PositronicKit
import struct PositronicKit.Thread

/// The built-in adapter owns PositronicKit construction, tool wiring, event
/// translation, timeline persistence, and provider shutdown.
@MainActor public final class PositronicAscendantAdapter: AscendantRuntimeAdapter {
    public let identity: AscendantRuntimeIdentity
    private let kit: PositronicKit
    private let threadStore: InMemoryThreadPersistence
    private let networkTools: [AnyTool]

    public init(ascendant: NodeManifest.Ascendant, profile _: NodeManifest.LLMProfile?, dependencies: AscendantRuntimeDependencies, timelines: [NodeManifest.Timeline], references: [UUID: WorkspaceReference], languageModel: any LanguageModel) async throws {
        guard timelines.contains(where: { $0.id == ascendant.defaultTimelineID }) else { throw NodeRuntimeError.missingTimeline(ascendant.defaultTimelineID) }
        let agent = AgentInstance(id: ascendant.id, name: ascendant.name, description: ascendant.description, privateThreadID: ascendant.defaultTimelineID, metadata: ascendant.metadata.mapValues { AnyCodable($0) })
        identity = .init(id: agent.id, name: agent.name, description: agent.description, privateTimelineID: agent.privateThreadID, primaryWorkspaceID: agent.primaryWorkspaceID, lastActiveAt: agent.lastActiveAt, createdAt: agent.createdAt, updatedAt: agent.updatedAt)
        let stores = (InMemoryAgentInstanceStore(), InMemoryThreadPersistence(), InMemoryMessageStore(), InMemoryWorkspacePersistence(), InMemoryToolPersistence())
        try await stores.0.saveAgentInstance(agent)
        for configuration in timelines {
            let thread = Thread(id: configuration.id, title: configuration.title, attachedWorkspaceIDs: configuration.attachments.map(\.workspaceID), attachedAgentInstanceID: ascendant.id, isPrivate: false)
            try await stores.1.saveThread(thread)
            for workspaceID in configuration.attachments.map(\.workspaceID) {
                guard let reference = references[workspaceID] else { throw NodeRuntimeError.missingWorkspace(workspaceID) }
                try await stores.3.saveWorkspace(reference)
            }
        }
        let factory = RuntimeWorkspaceFactory(local: dependencies.workspaces, remote: AxolotyWorkspaceFactory(catalog: dependencies.catalog, communication: dependencies.communication))
        let createdKit = PositronicKit(configuration: .init(provider: .init(languageModel: languageModel), persistence: .init(messageStore: stores.2, threadPersistence: stores.1, workspacePersistence: stores.3, toolPersistence: stores.4, agentInstanceStore: stores.0), runtime: .init(workspaceCreator: factory, runtimeToolPolicy: .init(installFilesystemTools: false, installThreadObservationTools: true, installThreadSendTool: true), toolApprovalPolicy: AscendantToolApprovalPolicy(coordinator: dependencies.permissionCoordinator))))
        kit = createdKit
        threadStore = stores.1
        let attachmentService = DiscoveredWorkspaceAttachmentService(
            catalog: dependencies.catalog,
            threadManager: createdKit.threadManager,
            allowedTimelineIDs: Set(timelines.map(\.id))
        )
        networkTools = [
            ListNetworkObjectsTool(service: attachmentService).toAnyTool(),
            InspectNetworkObjectTool(service: attachmentService).toAnyTool(),
            AttachWorkspaceTool(service: attachmentService).toAnyTool(),
        ]
    }

    public func timelines() async throws -> [AscendantRuntimeTimeline] { try await kit.threadManager.listThreads().map(Self.projection) }
    public func createTimeline(id: UUID, title: String) async throws -> AscendantRuntimeTimeline { let thread = Thread(id: id, title: title, attachedAgentInstanceID: identity.id, isPrivate: false); try await threadStore.saveThread(thread); try await kit.threadManager.ensureThreadExists(id: thread.id); return Self.projection(thread) }
    public func removeTimeline(id: UUID) async {
        await kit.threadManager.evictThreadFromMemory(id: id)
        try? await threadStore.deleteThread(id: id)
    }
    public func renameTimeline(id: UUID, title: String) async throws -> AscendantRuntimeTimeline { try await kit.threadManager.updateThreadTitle(id, title: title); guard let thread = try await timelines().first(where: { $0.id == id }) else { throw NodeRuntimeError.missingTimeline(id) }; return thread }
    public func attachWorkspace(_ reference: WorkspaceReference, to timelineID: UUID) async throws { try await kit.threadManager.importWorkspace(reference); try await kit.threadManager.attachWorkspace(reference.id, to: timelineID) }
    public func detachWorkspace(_ workspaceID: UUID, from timelineID: UUID) async throws { try await kit.threadManager.detachWorkspace(workspaceID, from: timelineID) }
    public func enabledToolIDs(for timelineID: UUID) async -> [String] {
        try? await kit.threadManager.ensureThreadExists(id: timelineID)
        return await kit.threadManager.enabledTools(for: timelineID).map(\.callName)
    }
    public func cancelAll() async {
        for timeline in (try? await timelines()) ?? [] {
            await kit.threadManager.cancelActiveTaskAndAwait(for: timeline.id)
        }
    }
    public func shutdown() async { await cancelAll() }

    public func runTurn(_ request: AgentChatRequest, updates: AscendantTurnUpdateStore) async throws -> String {
        let stream = try await AscendantTurnPermissionContext.$current.withValue(request.clientTurnID.map { .init(timelineID: request.timelineID, clientTurnID: $0) }) {
            let tools = await kit.threadManager.enabledTools(for: request.timelineID) + networkTools
            return try await kit.run(ChatRunRequest(threadID: request.timelineID, message: request.message, tools: tools, maxTurns: 5))
        }
        var finalText = ""; var failure: String?; var ids: [Int: String] = [:]; var titles: [Int: String] = [:]; var announced: Set<Int> = []
        for try await event in stream { switch event {
        case .delta(.generation(let text)): await append(updates, request, kind: "assistant_text", text: text)
        case .delta(.toolCall(let delta)):
            let id = delta.id ?? ids[delta.index] ?? "\(request.clientTurnID ?? request.timelineID.uuidString):tool:\(delta.index)"; ids[delta.index] = id
            if let name = delta.name { titles[delta.index, default: ""] += name }
            await append(updates, request, kind: announced.insert(delta.index).inserted ? "tool_call" : "tool_state", toolState: .init(toolCallID: id, title: titles[delta.index], status: "pending"))
        case .delta(.toolExecution(let id, let status)), .completion(.toolExecution(let id, let status)): await append(updates, request, kind: "tool_state", toolState: state(id, status))
        case .completion(.generationCompleted(let message, _)): finalText = message.content
        case .completion(.maxTurnsReached): failure = "The model exhausted its turn budget without a final answer."
        case .error(.error(let message, _)): failure = message
        case .error(.toolCallError(let id, let name, let error)): await append(updates, request, kind: "tool_state", toolState: .init(toolCallID: id, title: name, status: "failed", content: error))
        case .error(.generationCancelled): await append(updates, request, kind: "cancellation", terminal: true); throw CancellationError()
        default: break
        }}
        if let failure { throw NodeRuntimeError.turnFailed(failure) }
        return finalText.isEmpty ? "(empty reply)" : finalText
    }

    private static func projection(_ thread: Thread) -> AscendantRuntimeTimeline { .init(id: thread.id, title: thread.title, attachedWorkspaceIDs: thread.attachedWorkspaceIDs, attachedAgentInstanceID: thread.attachedAgentInstanceID, isArchived: thread.isArchived, isPrivate: thread.isPrivate, createdAt: thread.createdAt, updatedAt: thread.updatedAt) }
    private func append(_ updates: AscendantTurnUpdateStore, _ request: AgentChatRequest, kind: String, text: String? = nil, toolState: AscendantToolState? = nil, terminal: Bool = false) async { guard let id = request.clientTurnID else { return }; _ = await updates.append(timelineID: request.timelineID, clientTurnID: id, kind: kind, text: text, toolState: toolState, terminal: terminal) }
    private func state(_ id: String, _ status: ToolExecutionStatus) -> AscendantToolState { switch status { case .attempting(let name, _): .init(toolCallID: id, title: name, status: "in_progress"); case .success(let result): .init(toolCallID: id, status: "completed", content: String(describing: result)); case .failed(_, let error), .persistenceFailed(_, let error), .executionError(let error): .init(toolCallID: id, status: "failed", content: error) } }
}
