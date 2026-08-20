// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKShared
import PositronicKit
import struct PositronicKit.Thread

/// The built-in adapter owns PositronicKit construction, tool wiring, event
/// translation, timeline persistence, and provider shutdown. PositronicKit
/// native values do not cross the AscendantBackend contract.
@MainActor public final class PositronicAscendantAdapter: AscendantBackend, AscendantBackendWorkspaceCapability {
    public let identity: AscendantBackendIdentity
    private let kit: PositronicKit
    private let threadStore: InMemoryThreadPersistence
    private let networkTools: [AnyTool]
    private var lifecycleFailure: AscendantBackendLifecycleFailure?

    public init(
        ascendant: NodeManifest.Ascendant,
        backend: AscendantBackendConfiguration,
        services: AscendantBackendServices,
        timelines: [NodeManifest.Timeline],
        languageModel: any LanguageModel
    ) async throws {
        try AscendantBackendConfigurationValidator.validate(backend)
        guard timelines.contains(where: { $0.id == ascendant.defaultTimelineID }) else {
            throw NodeRuntimeError.missingTimeline(ascendant.defaultTimelineID)
        }

        var references: [UUID: BackendWorkspaceReference] = [:]
        for attachment in timelines.flatMap(\.attachments) {
            guard references[attachment.workspaceID] == nil,
                  let workspace = services.workspace,
                  let reference = await workspace.reference(id: attachment.workspaceID) else {
                throw NodeRuntimeError.missingWorkspace(attachment.workspaceID)
            }
            references[attachment.workspaceID] = reference
        }

        let agent = AgentInstance(
            id: ascendant.id,
            name: ascendant.name,
            description: ascendant.description,
            privateThreadID: ascendant.defaultTimelineID,
            metadata: ascendant.metadata.mapValues { AnyCodable($0) }
        )
        identity = .init(
            id: agent.id,
            name: agent.name,
            description: agent.description,
            privateTimelineID: agent.privateThreadID,
            primaryWorkspaceID: agent.primaryWorkspaceID,
            lastActiveAt: agent.lastActiveAt,
            createdAt: agent.createdAt,
            updatedAt: agent.updatedAt,
            capabilities: .init(
                interoperability: Set([
                    AscendantInteroperabilityCapability.textTurn.rawValue,
                    AscendantInteroperabilityCapability.streamedUpdates.rawValue,
                    AscendantInteroperabilityCapability.replay.rawValue,
                    AscendantInteroperabilityCapability.permissionMediation.rawValue,
                    AscendantInteroperabilityCapability.workspaceAttachment.rawValue,
                    AscendantInteroperabilityCapability.workspaceToolInvocation.rawValue,
                ]),
                host: ["workspace.tools", "timeline.lifecycle"],
                backendKind: backend.kind
            )
        )

        let stores = (
            InMemoryAgentInstanceStore(),
            InMemoryThreadPersistence(),
            InMemoryMessageStore(),
            InMemoryWorkspacePersistence(),
            InMemoryToolPersistence()
        )
        try await stores.0.saveAgentInstance(agent)
        for configuration in timelines {
            let thread = Thread(
                id: configuration.id,
                title: configuration.title,
                attachedWorkspaceIDs: configuration.attachments.map(\.workspaceID),
                attachedAgentInstanceID: ascendant.id,
                isPrivate: false
            )
            try await stores.1.saveThread(thread)
            for workspaceID in configuration.attachments.map(\.workspaceID) {
                guard let reference = references[workspaceID] else { throw NodeRuntimeError.missingWorkspace(workspaceID) }
                guard reference.status == .available,
                      let native = try? Self.positronicReference(reference) else { continue }
                try await stores.3.saveWorkspace(native)
            }
        }

        let factory = PositronicBackendWorkspaceFactory(service: services.workspace)
        let createdKit = PositronicKit(configuration: .init(
            provider: .init(languageModel: languageModel),
            persistence: .init(
                messageStore: stores.2,
                threadPersistence: stores.1,
                workspacePersistence: stores.3,
                toolPersistence: stores.4,
                agentInstanceStore: stores.0
            ),
            runtime: .init(
                workspaceCreator: factory,
                runtimeToolPolicy: .init(
                    installFilesystemTools: false,
                    installThreadObservationTools: true,
                    installThreadSendTool: true
                ),
                toolApprovalPolicy: AscendantToolApprovalPolicy(coordinator: services.permission)
            )
        ))
        kit = createdKit
        threadStore = stores.1
        lifecycleFailure = nil

        if let host = services.capability(BackendWorkspaceDiscoveryCapability.self) {
            let attachmentHost = services.capability(BackendWorkspaceAttachmentCapability.self)
            let attachmentService = DiscoveredWorkspaceAttachmentService(
                discovery: host.discovery,
                threadManager: createdKit.threadManager,
                hostAttachment: attachmentHost,
                allowedTimelineIDs: Set(timelines.map(\.id))
            )
            networkTools = [
                ListNetworkObjectsTool(service: attachmentService).toAnyTool(),
                InspectNetworkObjectTool(service: attachmentService).toAnyTool(),
                AttachWorkspaceTool(service: attachmentService).toAnyTool(),
            ]
        } else {
            networkTools = []
        }
    }

    public func operatedTimelines() async throws -> [AscendantBackendTimeline] {
        try requireUsable()
        return try await kit.threadManager.listThreads().map(Self.projection)
    }

    public func validateConfiguration() throws {}

    public func createTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        try requireUsable()
        let thread = Thread(id: id, title: title, attachedAgentInstanceID: identity.id, isPrivate: false)
        try await threadStore.saveThread(thread)
        try await kit.threadManager.ensureThreadExists(id: thread.id)
        return Self.projection(thread)
    }

    public func removeTimeline(id: UUID) async {
        guard lifecycleFailure == nil else { return }
        await kit.threadManager.evictThreadFromMemory(id: id)
        try? await threadStore.deleteThread(id: id)
    }

    public func renameTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        try requireUsable()
        try await kit.threadManager.updateThreadTitle(id, title: title)
        guard let thread = try await operatedTimelines().first(where: { $0.id == id }) else {
            throw NodeRuntimeError.missingTimeline(id)
        }
        return thread
    }

    public func attachWorkspace(_ reference: BackendWorkspaceReference, to timelineID: UUID) async throws {
        try requireUsable()
        try await kit.threadManager.importWorkspace(Self.positronicReference(reference))
        try await kit.threadManager.attachWorkspace(reference.id, to: timelineID)
    }

    public func detachWorkspace(_ workspaceID: UUID, from timelineID: UUID) async throws {
        try requireUsable()
        try await kit.threadManager.detachWorkspace(workspaceID, from: timelineID)
    }

    public func enabledToolIDs(for timelineID: UUID) async -> [String] {
        guard lifecycleFailure == nil else { return [] }
        try? await kit.threadManager.ensureThreadExists(id: timelineID)
        return await kit.threadManager.enabledTools(for: timelineID).map(\.callName)
    }

    public func cancel() async {
        for timeline in (try? await operatedTimelines()) ?? [] {
            await kit.threadManager.cancelActiveTaskAndAwait(for: timeline.id)
        }
    }

    public func shutdown() async {
        guard lifecycleFailure == nil else { return }
        await cancel()
        lifecycleFailure = .init(code: "backendShutdown", message: "The Positronic backend has been shut down.")
    }

    public func runTurn(_ request: AscendantBackendTurnRequest, updates: any AscendantBackendUpdateSink) async throws -> String {
        try requireUsable()
        let operated = try await operatedTimelines()
        guard operated.contains(where: { $0.id == request.timelineID }) else {
            throw AscendantBackendError.timelineNotFound(request.timelineID)
        }
        let stream = try await AscendantTurnPermissionContext.$current.withValue(request.clientTurnID.map {
            .init(timelineID: request.timelineID, clientTurnID: $0)
        }) {
            let tools = await kit.threadManager.enabledTools(for: request.timelineID) + networkTools
            return try await kit.run(ChatRunRequest(threadID: request.timelineID, message: request.message, tools: tools, maxTurns: 5))
        }
        var finalText = ""
        var failure: String?
        var ids: [Int: String] = [:]
        var titles: [Int: String] = [:]
        var announced: Set<Int> = []
        for try await event in stream {
            switch event {
            case .delta(.generation(let text)):
                await append(updates, kind: "assistant_text", text: text)
            case .delta(.toolCall(let delta)):
                let id = delta.id ?? ids[delta.index] ?? "\(request.clientTurnID ?? request.timelineID.uuidString):tool:\(delta.index)"
                ids[delta.index] = id
                if let name = delta.name { titles[delta.index, default: ""] += name }
                await append(
                    updates,
                    kind: announced.insert(delta.index).inserted ? "tool_call" : "tool_state",
                    toolState: .init(toolCallID: id, title: titles[delta.index], status: "pending")
                )
            case .delta(.toolExecution(let id, let status)), .completion(.toolExecution(let id, let status)):
                await append(updates, kind: "tool_state", toolState: state(id, status))
            case .completion(.generationCompleted(let message, _)):
                finalText = message.content
            case .completion(.maxTurnsReached):
                failure = "The model exhausted its turn budget without a final answer."
            case .error(.error(let message, _)):
                failure = message
            case .error(.toolCallError(let id, let name, let error)):
                await append(updates, kind: "tool_state", toolState: .init(toolCallID: id, title: name, status: "failed", content: error))
            case .error(.generationCancelled):
                await append(updates, kind: "cancellation", terminal: true)
                throw AscendantBackendError.cancelled
            default:
                break
            }
        }
        if let failure {
            throw AscendantBackendError.terminal(.init(code: "turnFailed", message: failure))
        }
        return finalText.isEmpty ? "(empty reply)" : finalText
    }

    private func requireUsable() throws {
        if let lifecycleFailure {
            throw AscendantBackendError.lifecycleUnusable(lifecycleFailure)
        }
    }

    private static func projection(_ thread: Thread) -> AscendantBackendTimeline {
        .init(
            id: thread.id,
            title: thread.title,
            attachedWorkspaceIDs: thread.attachedWorkspaceIDs,
            ascendantID: thread.attachedAgentInstanceID,
            isArchived: thread.isArchived,
            isPrivate: thread.isPrivate,
            createdAt: thread.createdAt,
            updatedAt: thread.updatedAt
        )
    }

    private func append(
        _ updates: any AscendantBackendUpdateSink,
        kind: String,
        text: String? = nil,
        toolState: AscendantToolState? = nil,
        terminal: Bool = false
    ) async {
        await updates.append(.init(kind: kind, text: text, toolState: toolState, terminal: terminal))
    }

    private func state(_ id: String, _ status: ToolExecutionStatus) -> AscendantToolState {
        switch status {
        case .attempting(let name, _):
            return .init(toolCallID: id, title: name, status: "in_progress")
        case .success(let result):
            return .init(toolCallID: id, status: "completed", content: String(describing: result))
        case .failed(_, let error), .persistenceFailed(_, let error), .executionError(let error):
            return .init(toolCallID: id, status: "failed", content: error)
        }
    }

    private static func positronicReference(_ reference: BackendWorkspaceReference) throws -> WorkspaceReference {
        guard let uri = WorkspaceURI(parsing: reference.uri) else {
            throw AscendantBackendError.invalidConfiguration("Invalid Workspace URI '\(reference.uri)'.")
        }
        return WorkspaceReference(
            id: reference.id,
            uri: uri,
            location: .runtime,
            tools: reference.tools.map { tool in
                .custom(WorkspaceToolDefinition(
                    id: tool.id,
                    name: tool.name,
                    description: tool.description,
                    parametersSchema: {
                        guard let schema = tool.parametersSchema, case let .object(values) = schema else { return [:] }
                        return values.mapValues { AnyCodable(anyValue($0)) }
                    }(),
                    requiresPermission: tool.requiresPermission
                ))
            }
        )
    }

    private static func anyValue(_ value: ManifestJSONValue) -> Any {
        switch value {
        case let .string(value): return value
        case let .number(value): return value
        case let .bool(value): return value
        case let .object(value): return value.mapValues(anyValue)
        case let .array(value): return value.map(anyValue)
        case .null: return NSNull()
        }
    }
}

private struct PositronicBackendWorkspaceFactory: WorkspaceFactory, Sendable {
    let service: (any AscendantBackendWorkspaceService)?

    func create(from reference: WorkspaceReference) throws -> any Workspace {
        PositronicBackendWorkspace(reference: reference, service: service)
    }
}

private struct PositronicBackendWorkspace: Workspace, Sendable {
    let reference: WorkspaceReference
    let service: (any AscendantBackendWorkspaceService)?

    var id: UUID { reference.id }

    func listTools() async throws -> [ToolReference] { reference.tools }

    func executeTool(id: String, parameters: [String: AnyCodable]) async throws -> ToolResult {
        guard let service else {
            throw AscendantBackendError.invalidConfiguration("Workspace consumption is unavailable.")
        }
        let arguments = parameters.reduce(into: [String: ManifestJSONValue]()) { result, pair in
            result[pair.key] = Self.manifestValue(pair.value.value)
        }
        let result = try await service.invoke(.init(workspaceID: reference.id, toolID: id, arguments: arguments))
        return .success(result.message ?? String(describing: result.value))
    }

    func readFile(path: String) async throws -> String {
        guard let service else { throw WorkspaceError.toolExecutionNotSupported }
        guard let files = service as? any AscendantBackendWorkspaceFileService else { throw WorkspaceError.toolExecutionNotSupported }
        return try await files.readFile(workspaceID: reference.id, path: path)
    }

    func writeFile(path: String, content: String) async throws {
        guard let service else { throw WorkspaceError.toolExecutionNotSupported }
        guard let files = service as? any AscendantBackendWorkspaceFileService else { throw WorkspaceError.toolExecutionNotSupported }
        try await files.writeFile(workspaceID: reference.id, path: path, content: content)
    }

    func listFiles(path: String) async throws -> [String] {
        guard let service else { throw WorkspaceError.toolExecutionNotSupported }
        guard let files = service as? any AscendantBackendWorkspaceFileService else { throw WorkspaceError.toolExecutionNotSupported }
        return try await files.listFiles(workspaceID: reference.id, path: path)
    }

    func deleteFile(path: String) async throws {
        guard let service else { throw WorkspaceError.toolExecutionNotSupported }
        guard let files = service as? any AscendantBackendWorkspaceFileService else { throw WorkspaceError.toolExecutionNotSupported }
        try await files.deleteFile(workspaceID: reference.id, path: path)
    }

    func healthCheck() async -> Bool {
        guard let service else { return false }
        guard let value = await service.reference(id: reference.id) else { return false }
        return value.status == .available
    }

    private static func manifestValue(_ value: Any) -> ManifestJSONValue {
        if let value = value as? String { return .string(value) }
        if let value = value as? Bool { return .bool(value) }
        if let value = value as? Int { return .number(Double(value)) }
        if let value = value as? Double { return .number(value) }
        if let value = value as? [String: AnyCodable] {
            return .object(value.mapValues { manifestValue($0.value) })
        }
        if let value = value as? [AnyCodable] {
            return .array(value.map { manifestValue($0.value) })
        }
        if let value = value as? [String: Any] {
            return .object(value.mapValues(manifestValue))
        }
        if let value = value as? [Any] {
            return .array(value.map(manifestValue))
        }
        return .null
    }
}
