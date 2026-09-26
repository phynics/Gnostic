// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ACP
import Foundation
import GnosticCore

/// An optional backend configuration surface for an external ACP agent.
///
/// This target owns the ACP client process, sessions, and private Timeline map.
@MainActor
public final class ACPAscendantBackend: AscendantBackend {
    /// The manifest backend kind served by this implementation.
    public nonisolated static let kind = "acp-client"

    /// The configuration keys accepted by the ACP client backend.
    public nonisolated static let settingsSchema = AscendantBackendSettingsSchema(keys: [
        .init(name: "command", summary: "Executable command used to start the ACP agent."),
        .init(name: "args", summary: "Command-line arguments encoded as a JSON string array."),
        .init(name: "cwd", summary: "Optional working directory for the ACP agent process."),
        .init(name: "env", summary: "Optional JSON object of non-secret environment-variable strings."),
        .init(name: "displayName", summary: "Optional display name for the external ACP agent."),
    ])

    /// Gnostic-owned identity for the Ascendant served by this backend.
    public let identity: AscendantBackendIdentity

    /// Parsed process settings. This value does not start a process.
    public let launchSpec: ACPLaunchSpec

    private let configuration: AscendantBackendConfiguration
    private var timelines: [UUID: AscendantBackendTimeline]
    private var timelineOrder: [UUID]
    private var sessionIDs: [UUID: SessionId]
    private var activeSessionIDs: Set<UUID> = []
    private let sessionMapURL: URL
    private var process: Process?
    private var transport: ACPProcessStdioTransport?
    private var connection: Protocol?
    private var sessionCapabilities: ACPAgentSessionCapabilities?
    private let updateRouter = ACPUpdateRouter()
    private var lifecycleFailure: AscendantBackendLifecycleFailure?

    /// Creates the ACP backend and projects its configured Gnostic Timelines.
    ///
    /// - Parameters:
    ///   - ascendant: The manifest Ascendant served by this backend.
    ///   - configuration: The backend-owned configuration envelope.
    ///   - services: Host services. ACP owns its tool execution.
    ///   - timelines: Timelines assigned to this Ascendant in the manifest.
    /// - Throws: ``AscendantBackendError/invalidConfiguration(_:)`` when the
    ///   envelope or launch settings are invalid.
    public init(
        ascendant: NodeManifest.Ascendant,
        configuration: AscendantBackendConfiguration,
        services _: AscendantBackendServices,
        timelines configuredTimelines: [NodeManifest.Timeline]
    ) throws {
        try AscendantBackendConfigurationValidator.validate(configuration)
        launchSpec = try Self.parse(configuration)
        self.configuration = configuration
        sessionMapURL = Self.sessionMapURL(for: ascendant.id)
        let recoveredSessions = Self.loadSessionMap(at: sessionMapURL)
        sessionIDs = recoveredSessions.reduce(into: [:]) { result, entry in
            result[entry.key] = SessionId(value: entry.value.sessionID)
        }

        let now = Date()
        var projections: [UUID: AscendantBackendTimeline] = [:]
        for timeline in configuredTimelines {
            projections[timeline.id] = AscendantBackendTimeline(
                id: timeline.id,
                title: timeline.title,
                attachedWorkspaceIDs: timeline.attachments.map(\.workspaceID),
                ascendantID: ascendant.id,
                isArchived: false,
                isPrivate: timeline.id == ascendant.defaultTimelineID,
                createdAt: now,
                updatedAt: now
            )
        }
        let recoveredTimelineIDs = recoveredSessions.keys
            .filter { projections[$0] == nil }
            .sorted { $0.uuidString < $1.uuidString }
        for id in recoveredTimelineIDs {
            guard let session = recoveredSessions[id] else { continue }
            projections[id] = AscendantBackendTimeline(
                id: id,
                title: session.title,
                attachedWorkspaceIDs: [],
                ascendantID: ascendant.id,
                isArchived: false,
                isPrivate: session.isPrivate,
                createdAt: session.createdAt,
                updatedAt: session.updatedAt
            )
        }
        timelines = projections
        timelineOrder = configuredTimelines.map(\.id) + recoveredTimelineIDs
        identity = AscendantBackendIdentity(
            id: ascendant.id,
            name: ascendant.name,
            description: ascendant.description,
            privateTimelineID: ascendant.defaultTimelineID,
            primaryWorkspaceID: nil,
            lastActiveAt: now,
            createdAt: now,
            updatedAt: now,
            capabilities: .init(backendKind: Self.kind, backendVersion: "0.1.16")
        )
    }

    /// Revalidates the stored envelope and its process launch settings.
    public func validateConfiguration() throws {
        try AscendantBackendConfigurationValidator.validate(configuration)
        _ = try Self.parse(configuration)
    }

    /// Returns Gnostic Timelines whose ACP sessions still exist at the agent.
    ///
    /// - Returns: The ordered Timeline projections owned by this backend.
    public func operatedTimelines() async throws -> [AscendantBackendTimeline] {
        do {
            let connection = try await requireConnection()
            guard sessionCapabilities?.supportsList == true else { return [] }
            for id in timelineOrder where sessionIDs[id] == nil {
                let response = try await connection.createSession(request: NewSessionRequest(
                    cwd: workingDirectory,
                    mcpServers: []
                ))
                sessionIDs[id] = response.sessionId
                activeSessionIDs.insert(id)
                try persistSessionMap()
            }
            let response = try await connection.listSessions(request: ListSessionsRequest(cwd: workingDirectory))
            let available = Set(response.sessions.map(\.sessionId))
            return timelineOrder.compactMap { id in
                guard let sessionID = sessionIDs[id], available.contains(sessionID) else { return nil }
                return timelines[id]
            }
        } catch {
            throw map(error, context: "Could not list ACP sessions")
        }
    }

    /// Creates an ACP session and adopts the Gnostic-created Timeline ID.
    ///
    /// - Parameters:
    ///   - id: The Gnostic-owned Timeline identifier to adopt.
    ///   - title: The Timeline title.
    /// - Returns: The new in-memory Timeline projection.
    public func createTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        if let existing = timelines[id] {
            if sessionIDs[id] == nil {
                do {
                    let connection = try await requireConnection()
                    let response = try await connection.createSession(request: NewSessionRequest(
                        cwd: workingDirectory,
                        mcpServers: []
                    ))
                    sessionIDs[id] = response.sessionId
                    activeSessionIDs.insert(id)
                    try persistSessionMap()
                } catch {
                    throw map(error, context: "Could not create ACP session")
                }
            }
            return existing
        }
        do {
            let connection = try await requireConnection()
            let response = try await connection.createSession(request: NewSessionRequest(
                cwd: workingDirectory,
                mcpServers: []
            ))
            sessionIDs[id] = response.sessionId
            activeSessionIDs.insert(id)
            try persistSessionMap()
        } catch {
            throw map(error, context: "Could not create ACP session")
        }
        let now = Date()
        let timeline = AscendantBackendTimeline(
            id: id,
            title: title,
            attachedWorkspaceIDs: [],
            ascendantID: identity.id,
            isArchived: false,
            isPrivate: false,
            createdAt: now,
            updatedAt: now
        )
        timelines[id] = timeline
        timelineOrder.append(id)
        try persistSessionMap()
        return timeline
    }

    /// Closes its ACP session when the agent advertises session/close.
    public func removeTimeline(id: UUID) async {
        if let sessionID = sessionIDs[id],
           let connection,
           sessionCapabilities?.supportsClose == true {
            do {
                _ = try await connection.request(
                    method: "session/close",
                    params: ACPCloseSessionRequest(sessionId: sessionID),
                    responseType: ACPEmptyResponse.self
                )
            } catch {
                lifecycleFailure = AscendantBackendLifecycleFailure(
                    code: "acpSessionCloseFailed",
                    message: "Could not close the ACP session for Timeline \(id.uuidString)."
                )
            }
        }
        sessionIDs.removeValue(forKey: id)
        activeSessionIDs.remove(id)
        timelines.removeValue(forKey: id)
        timelineOrder.removeAll { $0 == id }
        try? persistSessionMap()
    }

    /// Renames an in-memory Timeline projection.
    ///
    /// - Parameters:
    ///   - id: The Timeline identifier to rename.
    ///   - title: The new title.
    /// - Returns: The updated in-memory Timeline projection.
    /// - Throws: ``AscendantBackendError/timelineNotFound(_:)`` when this
    ///   backend does not project the Timeline.
    public func renameTimeline(id: UUID, title: String) async throws -> AscendantBackendTimeline {
        guard let current = timelines[id] else {
            throw AscendantBackendError.timelineNotFound(id)
        }
        let renamed = AscendantBackendTimeline(
            id: current.id,
            title: title,
            attachedWorkspaceIDs: current.attachedWorkspaceIDs,
            ascendantID: current.ascendantID,
            isArchived: current.isArchived,
            isPrivate: current.isPrivate,
            createdAt: current.createdAt,
            updatedAt: Date()
        )
        timelines[id] = renamed
        try persistSessionMap()
        return renamed
    }

    /// Runs a prompt through the ACP session and forwards streamed updates.
    ///
    /// - Parameters:
    ///   - request: The Timeline-addressed Turn request.
    ///   - updates: The host update sink receiving streamed ACP events.
    /// - Returns: The concatenated assistant text.
    /// - Throws: A terminal failure for an agent error, or lifecycle unusable
    ///   when the process or transport is no longer available.
    public func runTurn(
        _ request: AscendantBackendTurnRequest,
        updates: any AscendantBackendUpdateSink
    ) async throws -> String {
        guard timelines[request.timelineID] != nil else {
            throw AscendantBackendError.timelineNotFound(request.timelineID)
        }
        do {
            let connection = try await requireConnection()
            let sessionID = try await requireSession(for: request.timelineID, connection: connection)
            let eventStream = updateRouter.beginTurn()
            let forwardingTask = Task {
                await Self.forward(eventStream, to: updates)
            }
            let response: PromptResponse
            do {
                response = try await connection.prompt(request: PromptRequest(
                    sessionId: sessionID,
                    prompt: [.text(TextContent(text: request.message))]
                ))
            } catch {
                updateRouter.endTurn()
                let (_, updateError) = await forwardingTask.value
                if let updateError { throw updateError }
                throw error
            }
            updateRouter.endTurn()
            let (text, streamError) = await forwardingTask.value
            if let streamError { throw streamError }
            guard response.stopReason == .endTurn else {
                let message = "ACP agent stopped the Turn with reason '\(response.stopReason.rawValue)'."
                try await updates.append(.init(kind: AscendantTurnUpdateKind.error.rawValue, text: message, terminal: true))
                throw AscendantBackendError.terminal(.init(code: "acpTurnStopped", message: message))
            }
            try await updates.append(.init(kind: AscendantTurnUpdateKind.completion.rawValue, terminal: true))
            return text
        } catch let error as AscendantBackendError {
            throw error
        } catch {
            let failure = map(error, context: "ACP Turn failed")
            if case let .terminal(terminal) = failure {
                try? await updates.append(.init(kind: AscendantTurnUpdateKind.error.rawValue, text: terminal.message, terminal: true))
            }
            throw failure
        }
    }

    /// Requests cancellation only during backend retirement; turn cancellation
    /// remains owned by the follow-up ACP cancellation issue.
    public func cancel() async {}

    /// Closes the ACP transport and terminates the child process.
    public func shutdown() async {
        if let process, process.isRunning { process.terminate() }
        await connection?.close()
        connection = nil
        await transport?.close()
        transport = nil
        process = nil
    }

    private var workingDirectory: String {
        launchSpec.workingDirectory ?? FileManager.default.currentDirectoryPath
    }

    private func requireConnection() async throws -> Protocol {
        if let lifecycleFailure { throw AscendantBackendError.lifecycleUnusable(lifecycleFailure) }
        if let connection { return connection }
        let child = Process()
        let input = Pipe()
        let output = Pipe()
        child.arguments = launchSpec.arguments
        child.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        child.environment = ProcessInfo.processInfo.environment.merging(launchSpec.environment) { _, value in value }
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.standardError
        var connection: Protocol?
        var connectionStage = "resolve agent executable"
        do {
            child.executableURL = try resolvedExecutableURL(command: launchSpec.command, environment: child.environment ?? [:])
            connectionStage = "start agent process"
            try child.run()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            process = child
            let processTransport = ACPProcessStdioTransport(
                input: output.fileHandleForReading,
                output: input.fileHandleForWriting,
                onSessionUpdate: { [updateRouter] update in updateRouter.enqueue(update) },
                onFailure: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.lifecycleFailure = AscendantBackendLifecycleFailure(
                            code: "acpTransportUnusable",
                            message: "The ACP process transport stopped unexpectedly."
                        )
                    }
                }
            )
            let protocolConnection = Protocol(transport: processTransport, defaultTimeoutSeconds: 30)
            connection = protocolConnection
            self.transport = processTransport
            self.connection = protocolConnection
            connectionStage = "start ACP transport"
            try await protocolConnection.start()
            let initialize = InitializeRequest(
                protocolVersion: .current,
                clientCapabilities: ClientCapabilities(),
                clientInfo: Implementation(name: "Gnostic", version: "0.1")
            )
            connectionStage = "initialize ACP agent"
            let response = try await protocolConnection.request(
                method: "initialize",
                params: initialize,
                responseType: ACPInitializeResponse.self
            )
            sessionCapabilities = response.agentCapabilities.sessionCapabilities
            return protocolConnection
        } catch {
            let failure: AscendantBackendError
            if !child.isRunning {
                let lifecycle = AscendantBackendLifecycleFailure(
                    code: "acpTransportUnusable",
                    message: "Could not connect to the configured ACP agent process while attempting to \(connectionStage): \(error.localizedDescription)"
                )
                lifecycleFailure = lifecycle
                failure = .lifecycleUnusable(lifecycle)
            } else {
                failure = map(error, context: "Could not initialize the ACP agent")
            }
            if child.isRunning { child.terminate() }
            await connection?.close()
            self.connection = nil
            self.transport = nil
            process = nil
            throw failure
        }
    }

    private func requireSession(for timelineID: UUID, connection: Protocol) async throws -> SessionId {
        if let sessionID = sessionIDs[timelineID] {
            if activeSessionIDs.contains(timelineID) { return sessionID }
            guard sessionCapabilities?.supportsResume == true else {
                throw AscendantBackendError.terminal(.init(
                    code: "acpSessionResumeUnavailable",
                    message: "The ACP agent cannot resume the session for Timeline \(timelineID.uuidString)."
                ))
            }
            _ = try await connection.resumeSession(request: ResumeSessionRequest(
                sessionId: sessionID,
                cwd: workingDirectory,
                mcpServers: []
            ))
            activeSessionIDs.insert(timelineID)
            return sessionID
        }
        let response = try await connection.createSession(request: NewSessionRequest(cwd: workingDirectory, mcpServers: []))
        sessionIDs[timelineID] = response.sessionId
        activeSessionIDs.insert(timelineID)
        try persistSessionMap()
        return response.sessionId
    }

    private func map(_ error: any Error, context: String) -> AscendantBackendError {
        if let backendError = error as? AscendantBackendError { return backendError }
        if let protocolError = error as? ProtocolError {
            if case .transportClosed = protocolError {
                let failure = AscendantBackendLifecycleFailure(
                    code: "acpTransportUnusable",
                    message: "The ACP connection closed while handling a request."
                )
                lifecycleFailure = failure
                return .lifecycleUnusable(failure)
            }
            if case .timeout = protocolError {
                let failure = AscendantBackendLifecycleFailure(
                    code: "acpTransportUnusable",
                    message: "The ACP connection timed out while handling a request."
                )
                lifecycleFailure = failure
                return .lifecycleUnusable(failure)
            }
        }
        if let process, !process.isRunning {
            let failure = AscendantBackendLifecycleFailure(
                code: "acpTransportUnusable",
                message: "The ACP agent process stopped while handling a request."
            )
            lifecycleFailure = failure
            return .lifecycleUnusable(failure)
        }
        return .terminal(.init(code: "acpAgentFailure", message: "\(context): \(error.localizedDescription)"))
    }

    private func resolvedExecutableURL(command: String, environment: [String: String]) throws -> URL {
        if command.contains("/") {
            return URL(fileURLWithPath: command)
        }
        let searchPath = environment["PATH"] ?? ""
        for directory in searchPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func persistSessionMap() throws {
        try FileManager.default.createDirectory(at: sessionMapURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let values = Dictionary(uniqueKeysWithValues: sessionIDs.map { id, sessionID in
            let timeline = timelines[id]
            return (id.uuidString, ACPStoredTimelineSession(
                sessionID: sessionID.value,
                title: timeline?.title ?? "Timeline",
                createdAt: timeline?.createdAt ?? Date(),
                updatedAt: timeline?.updatedAt ?? Date(),
                isPrivate: timeline?.isPrivate ?? false
            ))
        })
        let data = try JSONEncoder().encode(values)
        try data.write(to: sessionMapURL, options: .atomic)
    }

    private static func loadSessionMap(at url: URL) -> [UUID: ACPStoredTimelineSession] {
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: ACPStoredTimelineSession].self, from: data) else { return [:] }
        return values.reduce(into: [:]) { result, entry in
            if let id = UUID(uuidString: entry.key) { result[id] = entry.value }
        }
    }

    private static func sessionMapURL(for ascendantID: UUID) -> URL {
        let environment = ProcessInfo.processInfo.environment
        let stateDirectory: URL
        if let configured = environment["GNOSTIC_STATE_HOME"], !configured.isEmpty {
            stateDirectory = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            #if os(macOS)
            stateDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Gnostic/ACPBackend", isDirectory: true)
            #else
            let xdg = environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state").path
            stateDirectory = URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("gnostic/ACPBackend", isDirectory: true)
            #endif
        }
        return stateDirectory.appendingPathComponent("\(ascendantID.uuidString).json")
    }

    private static func parse(_ configuration: AscendantBackendConfiguration) throws -> ACPLaunchSpec {
        guard configuration.kind == kind else {
            throw invalidConfiguration("The ACP backend requires kind '\(kind)'.")
        }
        let acceptedSettings = Set(settingsSchema.settingNames)
        if let unknown = configuration.settings.keys.sorted().first(where: { !acceptedSettings.contains($0) }) {
            throw invalidConfiguration("The ACP backend does not accept setting '\(unknown)'.")
        }
        guard configuration.secrets.isEmpty else {
            throw invalidConfiguration("The ACP backend does not accept secret settings yet; see GNO-ACPC-009.")
        }
        guard let command = stringSetting("command", in: configuration.settings),
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !command.contains("\0") else {
            throw invalidConfiguration("The ACP backend requires a non-empty 'command' setting.")
        }

        let arguments: [String]
        if let encodedArguments = configuration.settings["args"] {
            guard case let .string(json) = encodedArguments,
                  let data = json.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                throw invalidConfiguration("The ACP backend setting 'args' must be a JSON array of strings.")
            }
            arguments = decoded
        } else {
            arguments = []
        }
        guard arguments.allSatisfy({ !$0.contains("\0") }) else {
            throw invalidConfiguration("The ACP backend setting 'args' cannot contain null characters.")
        }

        let workingDirectory = try optionalStringSetting("cwd", in: configuration.settings)
        let displayName = try optionalStringSetting("displayName", in: configuration.settings)
        let environment: [String: String]
        if let encodedEnvironment = configuration.settings["env"] {
            guard case let .string(json) = encodedEnvironment,
                  let data = json.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
                throw invalidConfiguration("The ACP backend setting 'env' must be a JSON object of string values.")
            }
            environment = decoded
        } else {
            environment = [:]
        }
        guard environment.allSatisfy({ key, value in
            !key.isEmpty && !key.contains("=") && !key.contains("\0") && !value.contains("\0")
        }) else {
            throw invalidConfiguration("The ACP backend setting 'env' contains an invalid environment-variable name or value.")
        }

        return ACPLaunchSpec(
            command: command,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            displayName: displayName
        )
    }

    private static func stringSetting(
        _ key: String,
        in settings: [String: ManifestJSONValue]
    ) -> String? {
        guard case let .string(value)? = settings[key] else { return nil }
        return value
    }

    private static func optionalStringSetting(
        _ key: String,
        in settings: [String: ManifestJSONValue]
    ) throws -> String? {
        guard let value = settings[key] else { return nil }
        guard case let .string(string) = value,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !string.contains("\0") else {
            throw invalidConfiguration("The ACP backend setting '\(key)' must be a non-empty string when provided.")
        }
        return string
    }

    private static func invalidConfiguration(_ message: String) -> AscendantBackendError {
        .invalidConfiguration(message)
    }

    private nonisolated static func forward(
        _ events: AsyncStream<SessionUpdate>,
        to sink: any AscendantBackendUpdateSink
    ) async -> (String, (any Error)?) {
        var assistantText = ""
        var appendError: (any Error)?
        for await event in events {
            guard appendError == nil else { continue }
            guard let update = backendUpdate(for: event, assistantText: &assistantText) else { continue }
            do {
                try await sink.append(update)
            } catch {
                appendError = error
            }
        }
        return (assistantText, appendError)
    }

    private nonisolated static func backendUpdate(
        for event: SessionUpdate,
        assistantText: inout String
    ) -> AscendantBackendUpdate? {
        switch event {
        case .agentMessageChunk(let chunk):
            guard case let .text(text) = chunk.content else { return nil }
            assistantText += text.text
            return .init(kind: AscendantTurnUpdateKind.assistantText.rawValue, text: text.text)
        case .toolCall(let toolCall):
            return .init(
                kind: AscendantTurnUpdateKind.toolCall.rawValue,
                toolState: .init(
                    toolCallID: toolCall.toolCallId.value,
                    title: toolCall.title,
                    status: toolStatus(toolCall.status, fallback: .pending),
                    content: toolContent(toolCall.rawOutput)
                )
            )
        case .toolCallUpdate(let toolUpdate):
            return .init(
                kind: AscendantTurnUpdateKind.toolState.rawValue,
                toolState: .init(
                    toolCallID: toolUpdate.toolCallId.value,
                    title: toolUpdate.title,
                    status: toolStatus(toolUpdate.status, fallback: .inProgress),
                    content: toolContent(toolUpdate.rawOutput)
                )
            )
        default:
            return nil
        }
    }

    private nonisolated static func toolStatus(
        _ status: ToolCallStatus?,
        fallback: AscendantToolStatus
    ) -> AscendantToolStatus {
        switch status {
        case .pending: .pending
        case .inProgress: .inProgress
        case .completed: .completed
        case .failed: .failed
        case nil: fallback
        }
    }

    private nonisolated static func toolContent(_ value: JsonValue?) -> String? {
        guard let value,
              let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private struct ACPInitializeResponse: Decodable {
    let agentCapabilities: ACPAgentCapabilities
}

private struct ACPStoredTimelineSession: Codable {
    let sessionID: String
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let isPrivate: Bool
}

private struct ACPAgentCapabilities: Decodable {
    let sessionCapabilities: ACPAgentSessionCapabilities?
}

private struct ACPAgentSessionCapabilities: Decodable {
    let list: ACPAdvertisedFeature?
    let resume: ACPAdvertisedFeature?
    let close: ACPAdvertisedFeature?

    var supportsList: Bool { list != nil }
    var supportsResume: Bool { resume != nil }
    var supportsClose: Bool { close != nil }
}

private struct ACPAdvertisedFeature: Decodable {}

private struct ACPCloseSessionRequest: Encodable {
    let sessionId: SessionId
}

private struct ACPEmptyResponse: Decodable {}

private final class ACPUpdateRouter: @unchecked Sendable { // SAFETY: The active AsyncStream continuation is read, replaced, and finished only while holding `lock`; AsyncStream continuations support concurrent yields.
    private let lock = NSLock()
    private var continuation: AsyncStream<SessionUpdate>.Continuation?

    func beginTurn() -> AsyncStream<SessionUpdate> {
        let (stream, continuation) = AsyncStream<SessionUpdate>.makeStream()
        lock.lock()
        self.continuation?.finish()
        self.continuation = continuation
        lock.unlock()
        return stream
    }

    func enqueue(_ update: SessionUpdate) {
        lock.lock()
        continuation?.yield(update)
        lock.unlock()
    }

    func endTurn() {
        lock.lock()
        continuation?.finish()
        continuation = nil
        lock.unlock()
    }
}
