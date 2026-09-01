// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKContracts
import PositronicKit
import struct PositronicKit.Thread

/// The built-in adapter owns PositronicKit construction, tool wiring, event
/// translation, timeline persistence, and provider shutdown. PositronicKit
/// native values do not cross the AscendantBackend contract.
@MainActor public final class PositronicAscendantAdapter: AscendantBackend, AscendantBackendWorkspaceCapability {
    public let identity: AscendantBackendIdentity
    private let configuration: AscendantBackendConfiguration
    private let kit: PositronicKit
    private let threadStore: any ThreadRuntimeRepository
    private let networkTools: [AnyTool]
    private var workspaceToolsByID: [UUID: [AnyTool]]
    private var workspaceIDsByTimeline: [UUID: [UUID]]
    private let workspaceService: (any AscendantBackendWorkspaceService)?
    private var lifecycleFailure: AscendantBackendLifecycleFailure?
    private var timelineMutationGates: [UUID: TimelineMutationGate] = [:]

    public init(
        ascendant: NodeManifest.Ascendant,
        backend: AscendantBackendConfiguration,
        services: AscendantBackendServices,
        timelines: [NodeManifest.Timeline],
        languageModel: any LLMStreamClient
    ) async throws {
        try AscendantBackendConfigurationValidator.validate(backend)
        configuration = backend
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

        let agent = Agent(
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
            InMemoryAgentStore(),
            InMemoryMessageStore(),
            InMemoryWorkspacePersistence(),
            InMemoryToolPersistence()
        )
        let runtimeRepository = InMemoryThreadRuntimeRepository()
        try await stores.0.saveAgent(agent)
        for configuration in timelines {
            let thread = Thread(
                id: configuration.id,
                title: configuration.title,
                attachedAgentID: ascendant.id,
                isPrivate: false
            )
            try await runtimeRepository.saveThread(thread)
            for workspaceID in configuration.attachments.map(\.workspaceID) {
                guard let reference = references[workspaceID] else { throw NodeRuntimeError.missingWorkspace(workspaceID) }
                guard reference.status == .available,
                      let native = try? Self.positronicReference(reference) else { continue }
                try await stores.2.saveWorkspace(native)
            }
        }

        let factory = PositronicBackendWorkspaceFactory(service: services.workspace)
        let createdKit = PositronicKit(configuration: .init(
            provider: .init(languageModel: languageModel),
            persistence: .init(
                runtimeRepository: runtimeRepository,
                workspacePersistence: stores.2,
                toolPersistence: stores.3,
                agentStore: stores.0,
                workspaceBindingRepository: runtimeRepository
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
        threadStore = runtimeRepository
        lifecycleFailure = nil
        workspaceService = services.workspace
        workspaceToolsByID = try references.reduce(into: [:]) { result, entry in
            result[entry.key] = try Self.workspaceTools(for: entry.value, service: services.workspace)
        }
        workspaceIDsByTimeline = Dictionary(uniqueKeysWithValues: timelines.map {
            ($0.id, $0.attachments.map(\.workspaceID))
        })

        if let host = services.capability(BackendWorkspaceDiscoveryCapability.self) {
            let attachmentHost = services.capability(BackendWorkspaceAttachmentCapability.self)
            let attachmentService = DiscoveredWorkspaceAttachmentService(
                discovery: host.discovery,
                threadCapability: createdKit.threads,
                workspaceCapability: createdKit.workspaces,
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
        let threads = try await kit.threads.list(includeArchived: false)
        var projections: [AscendantBackendTimeline] = []
        for thread in threads {
            projections.append(await projection(thread))
        }
        return projections
    }

    /// Validates the offline PositronicKit provider contract without making a
    /// network request or executing a model. The rules mirror
    /// `LLMConfiguration.validate()`: provider names must be supported, model
    /// names must be non-empty, hosted providers require an API key, and the
    /// endpoint must be an HTTP(S) URL with a host. PositronicKit consumes all
    /// three model slots, so utility and fast models are validated as well. An
    /// empty envelope is the explicit unconfigured state used by deterministic
    /// hosts and test runtimes.
    public func validateConfiguration() throws {
        try Self.validateConfiguration(configuration)
    }

    private static func validateConfiguration(_ configuration: AscendantBackendConfiguration) throws {
        guard configuration.kind == "positronic" else {
            throw invalidConfiguration("backend kind")
        }

        let knownSettings = ["provider", "endpoint", "model", "utilityModel", "fastModel"]
        let hasKnownValue = knownSettings.contains { configuration.settings[$0] != nil }
            || configuration.secrets["apiKey"] != nil
        guard hasKnownValue else { return }

        let providerName = try stringValue(for: "provider", in: configuration.settings)
        guard let provider = LLMProvider.allCases.first(where: {
            $0.rawValue.caseInsensitiveCompare(providerName) == .orderedSame
        }) else {
            throw invalidConfiguration("provider")
        }

        var llmConfiguration = LLMConfiguration(activeProvider: provider)
        var providerConfiguration = llmConfiguration.activeProviderConfiguration
        providerConfiguration.endpoint = try stringValue(
            for: "endpoint", in: configuration.settings, defaultingTo: providerConfiguration.endpoint
        )
        providerConfiguration.modelName = try stringValue(
            for: "model", in: configuration.settings, defaultingTo: providerConfiguration.modelName
        )
        providerConfiguration.utilityModel = try stringValue(
            for: "utilityModel", in: configuration.settings, defaultingTo: providerConfiguration.utilityModel
        )
        providerConfiguration.fastModel = try stringValue(
            for: "fastModel", in: configuration.settings, defaultingTo: providerConfiguration.fastModel
        )
        providerConfiguration.apiKey = try stringValue(
            for: "apiKey", in: configuration.secrets, defaultingTo: providerConfiguration.apiKey
        )

        guard !providerConfiguration.utilityModel.isEmpty else {
            throw invalidConfiguration("utilityModel")
        }
        guard !providerConfiguration.fastModel.isEmpty else {
            throw invalidConfiguration("fastModel")
        }

        llmConfiguration.providers[provider] = providerConfiguration
        do {
            try llmConfiguration.validate()
        } catch let error as ConfigurationError {
            switch error {
            case .missingAPIKey:
                throw invalidConfiguration("apiKey")
            case .invalidEndpoint:
                throw invalidConfiguration("endpoint")
            case .invalidConfiguration:
                throw invalidConfiguration("model")
            case .noBackupFound, .importFailed:
                throw invalidConfiguration("provider configuration")
            }
        } catch {
            throw invalidConfiguration("provider configuration")
        }
    }

    private static func stringValue(
        for key: String,
        in values: [String: ManifestJSONValue],
        defaultingTo defaultValue: String? = nil
    ) throws -> String {
        guard let value = values[key] else {
            guard let defaultValue else { throw invalidConfiguration(key) }
            return defaultValue
        }
        guard case let .string(string) = value else {
            throw invalidConfiguration(key)
        }
        return string
    }

    private static func invalidConfiguration(_ field: String) -> AscendantBackendError {
        .invalidConfiguration("Invalid Positronic configuration field '\(field)'.")
    }

    public func createTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        try requireUsable()
        let thread = Thread(id: id, title: title, attachedAgentID: identity.id, isPrivate: false)
        try await threadStore.saveThread(thread)
        workspaceIDsByTimeline[id] = []
        return await projection(thread)
    }

    public func removeTimeline(id: UUID) async {
        guard lifecycleFailure == nil else { return }
        await kit.threads.open(id).cancel()
        try? await threadStore.deleteThread(id: id)
        workspaceIDsByTimeline.removeValue(forKey: id)
    }

    public func attachWorkspace(_ reference: BackendWorkspaceReference, to timelineID: UUID) async throws {
        try requireUsable()
        try await kit.workspaces.update(Self.positronicReference(reference))
        workspaceToolsByID[reference.id] = try Self.workspaceTools(for: reference, service: workspaceService)
        if !workspaceIDsByTimeline[timelineID, default: []].contains(reference.id) {
            workspaceIDsByTimeline[timelineID, default: []].append(reference.id)
        }
    }

    public func detachWorkspace(_ workspaceID: UUID, from timelineID: UUID) async throws {
        try requireUsable()
        workspaceIDsByTimeline[timelineID, default: []].removeAll { $0 == workspaceID }
    }

    public func enabledToolIDs(for timelineID: UUID) async -> [String] {
        guard lifecycleFailure == nil else { return [] }
        let workspaceToolIDs: [String]
        let workspaceIDs = workspaceIDsByTimeline[timelineID, default: []]
        workspaceToolIDs = workspaceIDs.flatMap { workspaceToolsByID[$0, default: []].map(\.callName) }
        return Array(Set(networkTools.map(\.callName) + workspaceToolIDs)).sorted()
    }

    public func cancel() async {
        for timeline in (try? await operatedTimelines()) ?? [] {
            await kit.threads.open(timeline.id).cancel()
        }
    }

    public func shutdown() async {
        guard lifecycleFailure == nil else { return }
        await cancel()
        lifecycleFailure = .init(code: "backendShutdown", message: "The Positronic backend has been shut down.")
    }

    public func timeline(id: UUID) async throws -> any AscendantBackendTimelineSession {
        try requireUsable()
        guard try await kit.threads.get(id) != nil else {
            throw AscendantBackendError.timelineNotFound(id)
        }
        return TimelineSession(handle: kit.threads.open(id), host: self)
    }

    @MainActor
    private final class TimelineSession: AscendantBackendTimelineSession {
        private let handle: ThreadHandle
        private let host: PositronicAscendantAdapter
        var id: UUID { handle.id }

        init(handle: ThreadHandle, host: PositronicAscendantAdapter) {
            self.handle = handle
            self.host = host
        }

        func runTurn(
            _ request: AscendantBackendTimelineTurnRequest,
            updates: any AscendantBackendUpdateSink
        ) async throws -> String {
            try host.requireUsable()
            let stream = try await AscendantTurnPermissionContext.$current.withValue(request.clientTurnID.map {
                .init(timelineID: id, clientTurnID: $0)
            }) {
                let workspaceIDs = host.workspaceIDsByTimeline[id, default: []]
                let workspaceTools = workspaceIDs.flatMap { host.workspaceToolsByID[$0, default: []] }
                let turnRequest = TurnRequest(
                    threadID: id,
                    requestID: request.clientTurnID.flatMap(UUID.init(uuidString:)),
                    message: request.message,
                    tools: workspaceTools + host.networkTools,
                    maxModelRounds: 5
                )
                return try await handle.run(turnRequest)
            }
            var finalText = ""
            var failure: String?
            var ids: [Int: String] = [:]
            var titles: [Int: String] = [:]
            var announced: Set<Int> = []
            eventLoop: for try await event in stream {
                switch event {
                case .delta(.generation(let text)):
                    await host.append(updates, kind: "assistant_text", text: text)
                case .delta(.toolCall(let delta)):
                    let toolCallID = delta.id ?? ids[delta.index] ?? "\(request.clientTurnID ?? id.uuidString):tool:\(delta.index)"
                    ids[delta.index] = toolCallID
                    if let name = delta.name { titles[delta.index, default: ""] += name }
                    await host.append(
                        updates,
                        kind: announced.insert(delta.index).inserted ? "tool_call" : "tool_state",
                        toolState: .init(toolCallID: toolCallID, title: titles[delta.index], status: "pending")
                    )
                case .delta(.toolExecution(let id, let status)), .completion(.toolExecution(let id, let status)):
                    await host.append(updates, kind: "tool_state", toolState: host.state(id, status))
                case .completion(.generationCompleted(let message, _)):
                    finalText = message.content
                    break eventLoop
                case .completion(.completedEmpty):
                    break eventLoop
                case .completion(.maxModelRoundsReached):
                    failure = "The model exhausted its turn budget without a final answer."
                    break eventLoop
                case .completion(.deferredForExternalTool):
                    failure = "The turn requires external tool execution before it can complete."
                    break eventLoop
                case .error(.error(let message, _)):
                    failure = message
                case .error(.toolCallError(let id, let name, let error)):
                    await host.append(updates, kind: "tool_state", toolState: .init(toolCallID: id, title: name, status: "failed", content: error))
                case .error(.generationCancelled):
                    await host.append(updates, kind: "cancellation", terminal: true)
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

        func rename(to title: String) async throws -> AscendantBackendTimeline {
            try host.requireUsable()
            return try await host.withTimelineMutation(id: id) {
                try await self.host.kit.threads.rename(self.id, title: title)
                guard let thread = try await self.host.kit.threads.get(self.id) else {
                    throw AscendantBackendError.timelineNotFound(self.id)
                }
                return await self.host.projection(thread)
            }
        }
    }

    private func withTimelineMutation<T: Sendable>(
        id: UUID,
        operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let gate: TimelineMutationGate
        if let existing = timelineMutationGates[id] {
            gate = existing
        } else {
            let created = TimelineMutationGate()
            timelineMutationGates[id] = created
            gate = created
        }
        return try await gate.withExclusiveAccess(operation)
    }

    private func requireUsable() throws {
        if let lifecycleFailure {
            throw AscendantBackendError.lifecycleUnusable(lifecycleFailure)
        }
    }

    private func projection(_ thread: Thread) async -> AscendantBackendTimeline {
        let attachedWorkspaceIDs = workspaceIDsByTimeline[thread.id, default: []]
        return .init(
            id: thread.id,
            title: thread.title,
            attachedWorkspaceIDs: attachedWorkspaceIDs,
            ascendantID: thread.attachedAgentID,
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
        case .failed(_, let error), .workspaceFailed(_, let error, _, _),
             .persistenceFailed(_, let error), .workspacePersistenceFailed(_, let error, _, _),
             .executionError(let error):
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

    private static func workspaceTools(
        for reference: BackendWorkspaceReference,
        service: (any AscendantBackendWorkspaceService)?
    ) throws -> [AnyTool] {
        let native = try positronicReference(reference)
        let workspace = PositronicBackendWorkspace(reference: native, service: service)
        return native.tools.compactMap { tool -> AnyTool? in
            guard case let .custom(definition) = tool else { return nil }
            return WorkspaceToolWrapper(workspace: workspace, definition: definition).toAnyTool()
        }
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

actor TimelineMutationGate {
    private var held = false
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []

    var waitingCount: Int { waiters.count }

    func withExclusiveAccess<T: Sendable>(
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        try await acquire()
        do {
            try Task.checkCancellation()
            let result = try await operation()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard held else {
            held = true
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(.init(id: waiterID, continuation: continuation))
            }
        }, onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        })
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}

private struct PositronicBackendWorkspaceFactory: WorkspaceFactory, Sendable {
    let service: (any AscendantBackendWorkspaceService)?

    func create(from reference: WorkspaceReference) throws -> any WorkspaceProvider {
        PositronicBackendWorkspace(reference: reference, service: service)
    }
}

private struct PositronicBackendWorkspace: WorkspaceToolProvider, WorkspaceFileProvider, Sendable {
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
