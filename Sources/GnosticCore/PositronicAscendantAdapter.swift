// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKShared
import PositronicKit

/// The built-in adapter owns PositronicKit construction, tool wiring, event
/// translation, timeline persistence, and provider shutdown.
@MainActor public final class PositronicAscendantAdapter: AscendantRuntimeAdapter {
    public let identity: AscendantRuntimeIdentity
    private let kit: PositronicKit
    private let timelineStore: InMemoryTimelinePersistence
    private let networkTools: [AnyTool]

    public init(ascendant: NodeManifest.Ascendant, profile _: NodeManifest.LLMProfile?, dependencies: AscendantRuntimeDependencies, timelines: [NodeManifest.Timeline], references: [UUID: WorkspaceReference], languageModel: any LanguageModel) async throws {
        guard timelines.contains(where: { $0.id == ascendant.defaultTimelineID }) else { throw NodeRuntimeError.missingTimeline(ascendant.defaultTimelineID) }
        let agent = AgentInstance(id: ascendant.id, name: ascendant.name, description: ascendant.description, privateTimelineID: ascendant.defaultTimelineID, metadata: ascendant.metadata.mapValues { AnyCodable($0) })
        identity = .init(id: agent.id, name: agent.name, description: agent.description, privateTimelineID: agent.privateTimelineID, primaryWorkspaceID: agent.primaryWorkspaceID, lastActiveAt: agent.lastActiveAt, createdAt: agent.createdAt, updatedAt: agent.updatedAt)
        let stores = (InMemoryAgentInstanceStore(), InMemoryTimelinePersistence(), InMemoryMessageStore(), InMemoryWorkspacePersistence(), InMemoryToolPersistence())
        try await stores.0.saveAgentInstance(agent)
        for configuration in timelines {
            let timeline = Timeline(id: configuration.id, title: configuration.title, attachedWorkspaceIDs: configuration.attachments.map(\.workspaceID), attachedAgentInstanceID: ascendant.id, isPrivate: false)
            try await stores.1.saveTimeline(timeline)
            for workspaceID in configuration.attachments.map(\.workspaceID) {
                guard let reference = references[workspaceID] else { throw NodeRuntimeError.missingWorkspace(workspaceID) }
                try await stores.3.saveWorkspace(reference)
            }
        }
        let factory = RuntimeWorkspaceFactory(local: dependencies.workspaces, remote: AxolotyWorkspaceFactory(catalog: dependencies.catalog, communication: dependencies.communication))
        let createdKit = PositronicKit(configuration: .init(provider: .init(languageModel: languageModel), persistence: .init(messageStore: stores.2, timelinePersistence: stores.1, workspacePersistence: stores.3, toolPersistence: stores.4, agentInstanceStore: stores.0), runtime: .init(workspaceCreator: factory, runtimeToolPolicy: .init(installFilesystemTools: false, installTimelineObservationTools: true, installTimelineSendTool: true), toolApprovalPolicy: AscendantToolApprovalPolicy(coordinator: dependencies.permissionCoordinator))))
        kit = createdKit
        timelineStore = stores.1
        let attachmentService = DiscoveredWorkspaceAttachmentService(
            catalog: dependencies.catalog,
            timelineManager: createdKit.timelineManager,
            allowedTimelineIDs: Set(timelines.map(\.id))
        )
        networkTools = [
            ListNetworkObjectsTool(service: attachmentService).toAnyTool(),
            InspectNetworkObjectTool(service: attachmentService).toAnyTool(),
            AttachWorkspaceTool(service: attachmentService).toAnyTool(),
        ]
    }

    public func timelines() async throws -> [AscendantRuntimeTimeline] { try await kit.timelineManager.listTimelines().map(Self.projection) }
    public func createTimeline(id: UUID, title: String) async throws -> AscendantRuntimeTimeline { let timeline = Timeline(id: id, title: title, attachedAgentInstanceID: identity.id, isPrivate: false); try await timelineStore.saveTimeline(timeline); try await kit.timelineManager.ensureTimelineExists(id: timeline.id); return Self.projection(timeline) }
    public func removeTimeline(id: UUID) async {
        await kit.timelineManager.evictTimelineFromMemory(id: id)
        try? await timelineStore.deleteTimeline(id: id)
    }
    public func renameTimeline(id: UUID, title: String) async throws -> AscendantRuntimeTimeline { try await kit.timelineManager.updateTimelineTitle(id: id, title: title); guard let timeline = try await timelines().first(where: { $0.id == id }) else { throw NodeRuntimeError.missingTimeline(id) }; return timeline }
    public func attachWorkspace(_ reference: WorkspaceReference, to timelineID: UUID) async throws { try await kit.timelineManager.importWorkspace(reference); try await kit.timelineManager.attachWorkspace(reference.id, to: timelineID) }
    public func detachWorkspace(_ workspaceID: UUID, from timelineID: UUID) async throws { try await kit.timelineManager.detachWorkspace(workspaceID, from: timelineID) }
    public func enabledToolIDs(for timelineID: UUID) async -> [String] {
        try? await kit.timelineManager.ensureTimelineExists(id: timelineID)
        return await kit.timelineManager.enabledTools(for: timelineID).map(\.callName)
    }
    public func cancelAll() async {
        for timeline in (try? await timelines()) ?? [] {
            await kit.timelineManager.cancelActiveTaskAndAwait(for: timeline.id)
        }
    }
    public func shutdown() async { await cancelAll() }

    public func runTurn(_ request: AgentChatRequest, updates: AscendantTurnUpdateStore) async throws -> String {
        let stream = try await AscendantTurnPermissionContext.$current.withValue(request.clientTurnID.map { .init(timelineID: request.timelineID, clientTurnID: $0) }) {
            let tools = await kit.timelineManager.enabledTools(for: request.timelineID) + networkTools
            return try await kit.run(ChatRunRequest(timelineID: request.timelineID, message: request.message, tools: tools, maxTurns: 5))
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

    private static func projection(_ timeline: Timeline) -> AscendantRuntimeTimeline { .init(id: timeline.id, title: timeline.title, attachedWorkspaceIDs: timeline.attachedWorkspaceIDs, attachedAgentInstanceID: timeline.attachedAgentInstanceID, isArchived: timeline.isArchived, isPrivate: timeline.isPrivate, createdAt: timeline.createdAt, updatedAt: timeline.updatedAt) }
    private func append(_ updates: AscendantTurnUpdateStore, _ request: AgentChatRequest, kind: String, text: String? = nil, toolState: AscendantToolState? = nil, terminal: Bool = false) async { guard let id = request.clientTurnID else { return }; _ = await updates.append(timelineID: request.timelineID, clientTurnID: id, kind: kind, text: text, toolState: toolState, terminal: terminal) }
    private func state(_ id: String, _ status: ToolExecutionStatus) -> AscendantToolState { switch status { case .attempting(let name, _): .init(toolCallID: id, title: name, status: "in_progress"); case .success(let result): .init(toolCallID: id, status: "completed", content: String(describing: result)); case .failed(_, let error), .persistenceFailed(_, let error), .executionError(let error): .init(toolCallID: id, status: "failed", content: error) } }
}
