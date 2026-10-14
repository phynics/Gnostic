// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore

/// An Ascendant backend implemented against a remote Letta server.
///
/// This is the first non-Positronic backend in the repository. It is an
/// optional downstream target: `GnosticCore` does not import it, and it reaches
/// the host only through the flat ``AscendantBackend`` contract.
///
/// Identity mapping: one Letta agent per Ascendant (shared long-term memory),
/// one Letta conversation per Gnostic Timeline (per-thread context window). The
/// Gnostic Timeline UUID is written into the conversation description as a
/// `[gnostic:<uuid>]` marker, so the projection is recoverable from remote
/// state alone and every Timeline operation is idempotent against it.
///
/// Tool execution: attached Workspace tools are passed to Letta as
/// `client_tools`. Letta pauses on a client tool call and hands control back to
/// this backend, which mediates the call through
/// ``AscendantBackendPermissionService`` and executes it through
/// ``AscendantBackendWorkspaceService``. Server-side tool execution is never
/// used for Gnostic Workspaces, so permission mediation is not bypassed.
@MainActor
public final class LettaAscendantBackend: AscendantBackend, AscendantBackendWorkspaceCapability {
    public nonisolated var capabilities: AscendantBackendOptionalSurfaces { .workspace }
    /// The configuration keys the Letta backend understands.
    public nonisolated static let settingsSchema = AscendantBackendSettingsSchema(keys: [
        .init(name: "serverURL", summary: "Base URL of the Letta server, for example https://api.letta.com or http://127.0.0.1:8283."),
        .init(name: "model", summary: "Model handle for the Letta agent, for example openai/gpt-5-mini."),
        .init(name: "agentID", summary: "Existing Letta agent id ('agent-...') to bind instead of creating one."),
        .init(name: "agentName", summary: "Agent name used when the backend creates the Letta agent."),
        .init(name: "maxSteps", summary: "Maximum Letta agent steps per Turn."),
        .init(name: "apiKey", summary: "Letta API key, sent as a bearer token.", isSecret: true),
    ])

    /// The manifest `backend.kind` this backend serves.
    public nonisolated static let kind = "letta"

    public let identity: AscendantBackendIdentity

    private let configuration: LettaConfiguration
    private let configurationEnvelope: AscendantBackendConfiguration
    private let transport: any LettaTransport
    private let workspaceService: (any AscendantBackendWorkspaceService)?
    private let permissionService: any AscendantBackendPermissionService

    private struct ResolvedTool {
        let workspaceID: UUID
        let tool: BackendWorkspaceTool
    }

    private let configuredTimelines: [NodeManifest.Timeline]
    private var toolsByTimeline: [UUID: [String: ResolvedTool]] = [:]
    private var conversationByTimeline: [UUID: String] = [:]
    private var agentID: String?
    private var activeConversationID: String?
    private var cancelRequested = false

    /// Shared Gnostic Timeline bookkeeping. This backend supplies only the
    /// remote conversation operations.
    private lazy var timelineRegistry = AscendantTimelineRegistry(
        ascendantID: identity.id,
        privateTimelineID: identity.privateTimelineID,
        configured: configuredTimelines,
        remote: .init(
            ensure: { [weak self] id, title in _ = try await self?.ensureTimelineRemote(id: id, title: title) },
            rename: { [weak self] id, title in _ = await self?.renameTimelineRemote(id: id, title: title) },
            delete: { [weak self] id in _ = await self?.deleteTimelineRemote(id: id) }
        )
    )

    public init(
        ascendant: NodeManifest.Ascendant,
        configuration: AscendantBackendConfiguration,
        services: AscendantBackendServices,
        timelines: [NodeManifest.Timeline],
        transport: any LettaTransport
    ) throws {
        try AscendantBackendConfigurationValidator.validate(configuration)
        let parsed = try Self.parse(configuration)
        self.configuration = parsed
        self.configurationEnvelope = configuration
        self.transport = transport
        workspaceService = services.workspace
        permissionService = services.permission
        agentID = parsed.agentID
        configuredTimelines = timelines

        let now = Date()
        identity = AscendantBackendIdentity(
            id: ascendant.id,
            name: ascendant.name,
            description: ascendant.description,
            privateTimelineID: ascendant.defaultTimelineID,
            primaryWorkspaceID: nil,
            lastActiveAt: now,
            createdAt: now,
            updatedAt: now,
            capabilities: .init(
                interoperability: Set([
                    AscendantInteroperabilityCapability.textTurn.rawValue,
                    AscendantInteroperabilityCapability.streamedUpdates.rawValue,
                    AscendantInteroperabilityCapability.cancellation.rawValue,
                    AscendantInteroperabilityCapability.permissionMediation.rawValue,
                    AscendantInteroperabilityCapability.timelineManagement.rawValue,
                    AscendantInteroperabilityCapability.workspaceAttachment.rawValue,
                    AscendantInteroperabilityCapability.workspaceToolInvocation.rawValue,
                ]),
                backendKind: Self.kind,
                backendVersion: "prototype"
            )
        )
    }

    /// Creates a backend with the production `URLSession` transport.
    public convenience init(
        ascendant: NodeManifest.Ascendant,
        configuration: AscendantBackendConfiguration,
        services: AscendantBackendServices,
        timelines: [NodeManifest.Timeline]
    ) throws {
        let parsed = try Self.parse(configuration)
        try self.init(
            ascendant: ascendant,
            configuration: configuration,
            services: services,
            timelines: timelines,
            transport: URLSessionLettaTransport(baseURL: parsed.serverURL, apiKey: parsed.apiKey)
        )
    }

    public func validateConfiguration() throws {
        _ = try Self.parse(configurationEnvelope)
    }

    public func operatedTimelines() async throws -> [AscendantBackendTimeline] {
        timelineRegistry.operatedTimelines()
    }

    public func createTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        try await timelineRegistry.create(id: id, title: title)
    }

    public func removeTimeline(id: UUID) async {
        await timelineRegistry.remove(id: id)
    }

    public func renameTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        try await timelineRegistry.rename(id: id, title: title)
    }

    // MARK: - Remote Timeline operations

    /// Ensures the Letta agent and the conversation the registry aligned to one
    /// Gnostic Timeline. This is idempotent for a known Timeline.
    private func ensureTimelineRemote(id: UUID, title: String) async throws {
        try await ensureAgent()
        _ = try await ensureConversation(id: id, title: title)
    }

    /// Renames the remote conversation. The Gnostic projection is authoritative,
    /// so a remote failure is best effort.
    private func renameTimelineRemote(id: UUID, title: String) async {
        guard let conversationID = await resolvedConversation(for: id) else { return }
        try? await transport.updateConversation(
            conversationID: conversationID,
            description: Self.description(title: title, timelineID: id)
        )
    }

    /// Removes the remote conversation and its backend-private indexes.
    private func deleteTimelineRemote(id: UUID) async {
        if let conversationID = await resolvedConversation(for: id) {
            try? await transport.deleteConversation(conversationID: conversationID)
        }
        conversationByTimeline.removeValue(forKey: id)
        toolsByTimeline.removeValue(forKey: id)
    }

    public func runTurn(
        _ request: AscendantBackendTurnRequest,
        updates: any AscendantBackendUpdateSink
    ) async throws -> String {
        // Core owns the failure terminal update, so this body emits only
        // success and incremental updates.
        try await withTerminalFailureUpdate(updates: updates) {
            try await performTurn(request, updates: updates)
        }
    }

    private func performTurn(
        _ request: AscendantBackendTurnRequest,
        updates: any AscendantBackendUpdateSink
    ) async throws -> String {
        guard let title = timelineRegistry.title(for: request.timelineID) else {
            throw AscendantBackendError.timelineNotFound(request.timelineID)
        }
        cancelRequested = false
        try await ensureAgent()
        guard let agentID else {
            throw AscendantBackendError.lifecycleUnusable(.init(code: "lettaAgentUnresolved", message: "The Letta agent could not be resolved."))
        }
        let conversationID = try await ensureConversation(id: request.timelineID, title: title)
        activeConversationID = conversationID

        let resolvedTools = await resolveTools(for: request.timelineID)
        let clientTools = resolvedTools.map { tool in
            LettaClientTool(
                name: tool.tool.id,
                description: tool.tool.description,
                parameters: tool.tool.parametersSchema ?? .object([:])
            )
        }

        var input = LettaMessageInput.user(request.message)
        var finalText = ""
        var stepCount = 0
        while true {
            if cancelRequested { throw AscendantBackendError.cancelled }
            stepCount += 1
            if let maxSteps = configuration.maxSteps, stepCount > maxSteps {
                throw AscendantBackendError.terminal(.init(code: "maxSteps", message: "The Letta agent exceeded the configured step limit.", retryable: false))
            }

            var approvals: [LettaToolReturn] = []
            var stopReason: String?
            let stream = try await send(agentID: agentID, conversationID: conversationID, input: input, clientTools: clientTools)
            do {
                for try await event in stream {
                    if cancelRequested { throw AscendantBackendError.cancelled }
                    switch event {
                    case let .assistantText(text):
                        finalText += text
                        try await updates.append(AscendantBackendUpdate(kind: .assistantText, text: text))
                    case .reasoning:
                        break
                    case let .toolCall(id, name, _):
                        try await updates.append(AscendantBackendUpdate(
                            kind: .toolCall,
                            toolState: AscendantToolState(toolCallID: id, title: name, status: .inProgress)
                        ))
                    case let .approvalRequest(_, toolCallID, name, arguments):
                        let result = try await handleToolCall(
                            toolCallID: toolCallID,
                            name: name,
                            arguments: arguments,
                            timelineID: request.timelineID,
                            clientTurnID: request.clientTurnID ?? request.timelineID.uuidString.lowercased(),
                            updates: updates
                        )
                        approvals.append(result)
                    case let .toolReturn(toolCallID, content, isError):
                        try await updates.append(AscendantBackendUpdate(
                            kind: .toolState,
                            toolState: AscendantToolState(
                                toolCallID: toolCallID,
                                status: isError ? .failed : .completed,
                                content: content
                            )
                        ))
                    case let .stopReason(reason):
                        stopReason = reason
                    }
                }
            } catch let error as LettaTransportError {
                if cancelRequested { throw AscendantBackendError.cancelled }
                throw Self.mapTransportError(error)
            }
            if cancelRequested { throw AscendantBackendError.cancelled }

            if !approvals.isEmpty {
                input = .approvals(approvals)
                continue
            }
            if let stopReason {
                if Self.isCancellation(stopReason) { throw AscendantBackendError.cancelled }
                if Self.isFailure(stopReason) {
                    throw AscendantBackendError.terminal(.init(code: stopReason, message: "The Letta agent stopped with '\(stopReason)'.", retryable: true))
                }
            }
            break
        }

        timelineRegistry.touch(id: request.timelineID)
        try await updates.append(AscendantBackendUpdate(kind: .completion, text: finalText, terminal: true))
        return finalText
    }

    public func cancel() async {
        cancelRequested = true
        guard let agentID, let conversationID = activeConversationID else { return }
        try? await transport.cancelConversation(agentID: agentID, conversationID: conversationID)
    }

    public func shutdown() async {
        await cancel()
        activeConversationID = nil
    }
    // MARK: - Workspace capability

    public func attachWorkspace(_ reference: BackendWorkspaceReference, to timelineID: UUID) async throws {
        try timelineRegistry.attachWorkspace(reference.id, to: timelineID)
        toolsByTimeline[timelineID] = nil
    }

    public func detachWorkspace(_ workspaceID: UUID, from timelineID: UUID) async throws {
        timelineRegistry.detachWorkspace(workspaceID, from: timelineID)
        toolsByTimeline[timelineID] = nil
    }

    public func enabledToolIDs(for timelineID: UUID) async -> [String] {
        await resolveTools(for: timelineID).map(\.tool.id)
    }

    // MARK: - Turn internals

    private func send(
        agentID: String,
        conversationID: String,
        input: LettaMessageInput,
        clientTools: [LettaClientTool]
    ) async throws -> AsyncThrowingStream<LettaStreamEvent, Error> {
        do {
            return try await transport.sendMessage(
                agentID: agentID,
                conversationID: conversationID,
                input: input,
                clientTools: clientTools
            )
        } catch let error as LettaTransportError {
            throw Self.mapTransportError(error)
        }
    }

    private func handleToolCall(
        toolCallID: String,
        name: String,
        arguments: String,
        timelineID: UUID,
        clientTurnID: String,
        updates: any AscendantBackendUpdateSink
    ) async throws -> LettaToolReturn {
        let resolved = await resolveTools(for: timelineID)
        guard let tool = resolved.first(where: { $0.tool.id == name }) else {
            return LettaToolReturn(toolCallID: toolCallID, content: "Unknown tool '\(name)'.", isError: true)
        }

        try await updates.append(AscendantBackendUpdate(
            kind: .toolState,
            toolState: AscendantToolState(toolCallID: toolCallID, title: tool.tool.name, status: .inProgress)
        ))

        if tool.tool.requiresPermission {
            let correlationID = "letta-\(toolCallID)"
            let decision = await permissionService.requestApproval(for: BackendPermissionRequest(
                correlationID: correlationID,
                timelineID: timelineID,
                clientTurnID: clientTurnID,
                toolCallID: toolCallID,
                title: tool.tool.name
            ))
            guard decision.isApproved else {
                try await updates.append(AscendantBackendUpdate(
                    kind: .toolState,
                    toolState: AscendantToolState(toolCallID: toolCallID, title: tool.tool.name, status: .failed, content: "Permission denied.")
                ))
                return LettaToolReturn(toolCallID: toolCallID, content: "Permission denied.", isError: true)
            }
        }

        guard let service = workspaceService else {
            return LettaToolReturn(toolCallID: toolCallID, content: "No Workspace service is installed.", isError: true)
        }
        do {
            let invocation = BackendWorkspaceInvocation(
                workspaceID: tool.workspaceID,
                toolID: tool.tool.id,
                arguments: try Self.arguments(from: arguments)
            )
            let result = try await service.invoke(invocation)
            try await updates.append(AscendantBackendUpdate(
                kind: .toolState,
                toolState: AscendantToolState(toolCallID: toolCallID, title: tool.tool.name, status: .completed, content: result.message)
            ))
            return LettaToolReturn(toolCallID: toolCallID, content: result.message ?? "", isError: false)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "Workspace tool failed."
            try await updates.append(AscendantBackendUpdate(
                kind: .toolState,
                toolState: AscendantToolState(toolCallID: toolCallID, title: tool.tool.name, status: .failed, content: message)
            ))
            return LettaToolReturn(toolCallID: toolCallID, content: message, isError: true)
        }
    }

    private func resolveTools(for timelineID: UUID) async -> [ResolvedTool] {
        if let cached = toolsByTimeline[timelineID] {
            return Array(cached.values)
        }
        guard let service = workspaceService else { return [] }
        var resolved: [ResolvedTool] = []
        for workspaceID in timelineRegistry.attachedWorkspaceIDs(for: timelineID) {
            guard let reference = await service.reference(id: workspaceID), reference.status == .available else { continue }
            for tool in reference.tools {
                resolved.append(ResolvedTool(workspaceID: workspaceID, tool: tool))
            }
        }
        toolsByTimeline[timelineID] = Dictionary(resolved.map { ($0.tool.id, $0) }, uniquingKeysWith: { first, _ in first })
        return resolved
    }

    // MARK: - Letta state projection

    private func ensureAgent() async throws {
        if agentID != nil {
            if conversationByTimeline.isEmpty {
                try await refreshConversations()
            }
            return
        }
        let name = configuration.agentName ?? identity.name
        do {
            if let configured = configuration.agentID {
                agentID = configured
                try await refreshConversations()
                return
            }
            let candidates = try await transport.listAgents(name: name)
            if let existing = candidates.first(where: { Self.ascendantID(in: $0.metadata) == identity.id.uuidString }) {
                agentID = existing.id
            } else {
                let created = try await transport.createAgent(LettaAgentCreation(
                    name: name,
                    description: identity.description,
                    model: configuration.model,
                    metadata: Self.agentMetadata(ascendantID: identity.id)
                ))
                agentID = created.id
            }
            try await refreshConversations()
        } catch let error as LettaTransportError {
            throw Self.mapTransportError(error)
        }
    }

    private func refreshConversations() async throws {
        guard let agentID else { return }
        do {
            let conversations = try await transport.listConversations(agentID: agentID)
            conversationByTimeline = [:]
            for conversation in conversations where !conversation.isArchived {
                guard let timelineID = Self.timelineID(from: conversation.description) else { continue }
                conversationByTimeline[timelineID] = conversation.id
            }
        } catch let error as LettaTransportError {
            throw Self.mapTransportError(error)
        }
    }

    private func resolvedConversation(for timelineID: UUID) async -> String? {
        if let conversationID = conversationByTimeline[timelineID] { return conversationID }
        do {
            try await ensureAgent()
            try await refreshConversations()
        } catch {
            return nil
        }
        return conversationByTimeline[timelineID]
    }

    private func ensureConversation(id: UUID, title: String) async throws -> String {
        if let conversationID = conversationByTimeline[id] { return conversationID }
        guard let agentID else {
            throw AscendantBackendError.lifecycleUnusable(.init(code: "lettaAgentUnresolved", message: "The Letta agent could not be resolved."))
        }
        do {
            let conversation = try await transport.createConversation(
                agentID: agentID,
                description: Self.description(title: title, timelineID: id)
            )
            conversationByTimeline[id] = conversation.id
            return conversation.id
        } catch let error as LettaTransportError {
            throw Self.mapTransportError(error)
        }
    }

    // MARK: - Configuration and mapping helpers

    private struct BackendEnvelope {
        let kind: String
        let settings: [String: ManifestJSONValue]
        let secrets: [String: ManifestJSONValue]
    }

    private static func parse(_ configuration: AscendantBackendConfiguration) throws -> LettaConfiguration {
        let envelope = BackendEnvelope(kind: configuration.kind, settings: configuration.settings, secrets: configuration.secrets)
        return try parse(envelope)
    }

    private static func parse(_ envelope: BackendEnvelope) throws -> LettaConfiguration {
        if envelope.kind != kind {
            throw AscendantBackendError.invalidConfiguration("The Letta backend requires backend kind '\(kind)'.")
        }
        guard let raw = envelope.settings["serverURL"], case let .string(serverURL) = raw,
              let url = URL(string: serverURL), let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"), url.host?.isEmpty == false else {
            throw AscendantBackendError.invalidConfiguration("The Letta backend requires a 'serverURL' setting with an http(s) URL.")
        }
        let model = stringValue("model", in: envelope.settings)
        let configuredAgentID = stringValue("agentID", in: envelope.settings)
        guard model?.isEmpty == false || configuredAgentID?.isEmpty == false else {
            throw AscendantBackendError.invalidConfiguration("The Letta backend requires a 'model' setting or an 'agentID' setting.")
        }
        let maxSteps: Int?
        if let value = envelope.settings["maxSteps"] {
            switch value {
            case let .number(number) where number > 0 && number.rounded() == number:
                maxSteps = Int(number)
            case let .string(text) where Int(text).map({ $0 > 0 }) == true:
                maxSteps = Int(text)
            default:
                throw AscendantBackendError.invalidConfiguration("The Letta backend requires 'maxSteps' to be a positive integer.")
            }
        } else {
            maxSteps = nil
        }
        return LettaConfiguration(
            serverURL: url,
            apiKey: stringValue("apiKey", in: envelope.secrets),
            model: model,
            agentID: configuredAgentID,
            agentName: stringValue("agentName", in: envelope.settings),
            maxSteps: maxSteps
        )
    }

    private static func stringValue(_ key: String, in values: [String: ManifestJSONValue]) -> String? {
        guard case let .string(value)? = values[key], !value.isEmpty else { return nil }
        return value
    }

    private static func arguments(from text: String) throws -> [String: ManifestJSONValue] {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return [:] }
        guard let decoded = try? JSONDecoder().decode([String: ManifestJSONValue].self, from: data) else {
            throw AscendantBackendError.terminal(.init(code: "invalidToolArguments", message: "The Letta tool call arguments were not a JSON object.", retryable: false))
        }
        return decoded
    }

    private static func description(title: String, timelineID: UUID) -> String {
        "\(title) [gnostic:\(timelineID.uuidString.lowercased())]"
    }

    private static func timelineID(from description: String?) -> UUID? {
        guard let description,
              let start = description.range(of: "[gnostic:")?.upperBound,
              let end = description.range(of: "]", range: start..<description.endIndex)?.lowerBound else {
            return nil
        }
        return UUID(uuidString: String(description[start..<end]))
    }

    private static func ascendantID(in metadata: ManifestJSONValue?) -> String? {
        guard case let .object(root)? = metadata,
              case let .object(gnostic)? = root["gnostic"],
              case let .string(ascendant)? = gnostic["ascendant"] else {
            return nil
        }
        return ascendant
    }

    private static func agentMetadata(ascendantID: UUID) -> ManifestJSONValue {
        .object(["gnostic": .object(["ascendant": .string(ascendantID.uuidString.lowercased())])])
    }

    private static func isCancellation(_ reason: String) -> Bool {
        reason == "cancelled"
    }

    private static func isFailure(_ reason: String) -> Bool {
        switch reason {
        case "error", "llm_api_error", "invalid_llm_response", "invalid_tool_call", "max_steps",
             "max_tokens_exceeded", "insufficient_credits", "context_window_overflow_in_system_prompt":
            return true
        default:
            return false
        }
    }

    private static func mapTransportError(_ error: LettaTransportError) -> AscendantBackendError {
        switch error {
        case let .unreachable(detail):
            return .lifecycleUnusable(.init(code: "lettaServerUnreachable", message: detail))
        case let .unauthorized(detail):
            return .lifecycleUnusable(.init(code: "lettaUnauthorized", message: detail))
        case let .protocolFailure(detail):
            return .terminal(.init(code: "lettaProtocolFailure", message: detail, retryable: true))
        }
    }
}

/// The parsed Letta backend configuration.
struct LettaConfiguration: Sendable, Equatable {
    let serverURL: URL
    let apiKey: String?
    let model: String?
    let agentID: String?
    let agentName: String?
    let maxSteps: Int?
}
