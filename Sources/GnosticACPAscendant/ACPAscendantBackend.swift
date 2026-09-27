// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ACP
import Foundation
import GnosticCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An optional backend configuration surface for an external ACP agent.
///
/// This target owns the ACP client process, sessions, and private Timeline map.
@MainActor
public final class ACPAscendantBackend: AscendantBackend, AscendantBackendTurnCancellation {
    /// The manifest backend kind served by this implementation.
    public nonisolated static let kind = "acp-client"
    private nonisolated static let processGroupLauncherPath = "/usr/bin/perl"
    private nonisolated static let promptTimeoutSeconds: TimeInterval = 60 * 60

    /// The configuration keys accepted by the ACP client backend.
    public nonisolated static let settingsSchema = AscendantBackendSettingsSchema(keys: [
        .init(name: "command", summary: "Executable command used to start the ACP agent."),
        .init(name: "args", summary: "Command-line arguments encoded as a JSON string array."),
        .init(name: "cwd", summary: "Optional working directory for the ACP agent process."),
        .init(name: "env", summary: "Optional JSON object of non-secret environment-variable strings."),
        .init(name: "displayName", summary: "Optional display name for the external ACP agent."),
    ], keyFamilies: [
        .init(prefix: "env.", summary: "One non-secret process environment variable."),
        .init(prefix: "env-secret.", summary: "One secret process environment variable.", isSecret: true),
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
    private var stderrPipe: Pipe?
    private var stderrDrainTask: Task<Void, Never>?
    private var transport: ACPProcessStdioTransport?
    private var connection: ACPProtocolLayer?
    private var connectionTask: Task<ACPProtocolLayer, Error>?
    private var connectionTaskID: UUID?
    private var isShuttingDown = false
    private var sessionCapabilities: ACPAgentSessionCapabilities?
    private let permissionService: any AscendantBackendPermissionService
    // The backend contract serializes Turns per Timeline; one active entry per Timeline is intentional.
    private var activeTurns: [UUID: ACPActiveTurn] = [:]
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
        services: AscendantBackendServices,
        timelines configuredTimelines: [NodeManifest.Timeline]
    ) throws {
        try AscendantBackendConfigurationValidator.validate(configuration)
        launchSpec = try Self.parse(configuration)
        self.configuration = configuration
        permissionService = services.permission
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
        let candidate = try Self.parse(configuration)
        guard FileManager.default.isExecutableFile(atPath: Self.processGroupLauncherPath) else {
            throw Self.invalidConfiguration("The ACP backend setting 'command' requires the Perl process-group launcher at /usr/bin/perl.")
        }
        let directory = candidate.workingDirectory ?? FileManager.default.currentDirectoryPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Self.invalidConfiguration("The ACP backend setting 'cwd' must name an existing directory.")
        }
        do {
            _ = try resolvedExecutableURL(command: candidate.command, environment: Self.childEnvironment(from: candidate))
        } catch {
            throw Self.invalidConfiguration("The ACP backend setting 'command' must name an executable file.")
        }
    }

    /// Returns Gnostic Timelines whose ACP sessions still exist at the agent.
    ///
    /// - Returns: The ordered Timeline projections owned by this backend.
    public func operatedTimelines() async throws -> [AscendantBackendTimeline] {
        do {
            let connection = try await requireConnection()
            guard sessionCapabilities?.supportsList == true else {
                return timelineOrder.compactMap { timelines[$0] }
            }
            // NodeRuntime uses this call during startup hydration. Seed the
            // session map here so the advertised session-list intersection can
            // include configured Gnostic Timelines on the first startup.
            try await ensureSessions(for: timelineOrder, using: connection)
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
                // SDK 0.1.16 has no typed session/close request, so use its
                // generic request bridge with a typed payload.
                _ = try await connection.request(
                    method: "session/close",
                    params: ACPCloseSessionRequest(sessionId: sessionID),
                    responseType: ACPEmptyResponse.self
                )
            } catch { /* Closing a removed Timeline is best effort, not a backend health failure. */ }
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
            guard !isShuttingDown else {
                throw AscendantBackendError.lifecycleUnusable(.init(
                    code: "acpBackendShuttingDown",
                    message: "The ACP backend is shutting down."
                ))
            }
            guard activeTurns[request.timelineID] == nil else {
                throw AscendantBackendError.terminal(.init(
                    code: "acpTurnAlreadyActive",
                    message: "An ACP Turn is already active for this Timeline."
                ))
            }
            let activeTurn = ACPActiveTurn(clientTurnID: request.clientTurnID ?? "", sessionID: sessionID)
            activeTurns[request.timelineID] = activeTurn
            defer {
                activeTurn.isCancelled = true
                activeTurns.removeValue(forKey: request.timelineID)
            }
            let eventStream = updateRouter.beginTurn(sessionID: sessionID.value)
            let forwardingTask = Task {
                await Self.forward(eventStream, to: updates, activeTurn: activeTurn)
            }
            let response: PromptResponse
            do {
                response = try await withTaskCancellationHandler {
                    let response = try await connection.sendRequest(
                        method: "session/prompt",
                        params: PromptRequest(
                            sessionId: sessionID,
                            prompt: [.text(TextContent(text: request.message))]
                        ),
                        timeoutSeconds: Self.promptTimeoutSeconds
                    )
                    do {
                        let data = try JSONEncoder().encode(response.result)
                        return try JSONDecoder().decode(PromptResponse.self, from: data)
                    } catch {
                        throw ProtocolError.decodingFailed(underlying: error)
                    }
                } onCancel: {
                    Task { @MainActor in activeTurn.isCancelled = true }
                }
            } catch {
                updateRouter.endTurn(sessionID: sessionID.value)
                let (_, updateError) = await forwardingTask.value
                if let updateError { throw updateError }
                if activeTurn.isTurnCancelled { throw AscendantBackendError.cancelled }
                throw error
            }
            updateRouter.endTurn(sessionID: sessionID.value)
            if activeTurn.isTurnCancelled { throw AscendantBackendError.cancelled }
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

    /// Marks active Turns cancelled during backend retirement.
    public func cancel() async {
        for activeTurn in activeTurns.values { activeTurn.markCancelled() }
    }

    /// Sends ACP `session/cancel` only for the matching Timeline Turn.
    public func cancelTurn(timelineID: UUID, clientTurnID: String) async {
        guard let canonicalClientTurnID = try? GnosticWirePayload.canonicalClientTurnID(clientTurnID) else { return }
        guard let activeTurn = activeTurns[timelineID],
              activeTurn.clientTurnID == canonicalClientTurnID,
              let connection else { return }
        activeTurn.cancelTurn()
        try? await connection.sendNotification(
            method: "session/cancel",
            params: ACPCancelSessionRequest(sessionId: activeTurn.sessionID)
        )
    }

    /// Closes the ACP transport and terminates the child process.
    public func shutdown() async {
        await cancel()
        isShuttingDown = true
        let pendingConnection = connectionTask
        pendingConnection?.cancel()
        if let process { await stopProcess(process) }
        if let pendingConnection { _ = await pendingConnection.result }
        connectionTask = nil
        connectionTaskID = nil
        await connection?.close()
        connection = nil
        await transport?.close()
        transport = nil
        process = nil
        try? stderrPipe?.fileHandleForReading.close()
        stderrPipe = nil
        if let stderrDrainTask { await stderrDrainTask.value }
        stderrDrainTask = nil
        sessionCapabilities = nil
        lifecycleFailure = nil
        activeSessionIDs.removeAll()
    }

    private var workingDirectory: String {
        launchSpec.workingDirectory ?? FileManager.default.currentDirectoryPath
    }

    private func requireConnection() async throws -> ACPProtocolLayer {
        if let lifecycleFailure { throw AscendantBackendError.lifecycleUnusable(lifecycleFailure) }
        guard !isShuttingDown else {
            throw AscendantBackendError.lifecycleUnusable(.init(
                code: "acpBackendShuttingDown",
                message: "The ACP backend is shutting down."
            ))
        }
        if let connectionTask { return try await connectionTask.value }
        if let connection { return connection }
        let taskID = UUID()
        let task = Task { @MainActor in try await establishConnection() }
        connectionTaskID = taskID
        connectionTask = task
        do {
            let established = try await task.value
            if connectionTaskID == taskID {
                connectionTask = nil
                connectionTaskID = nil
            }
            return established
        } catch {
            if connectionTaskID == taskID {
                connectionTask = nil
                connectionTaskID = nil
            }
            throw error
        }
    }

    private func establishConnection() async throws -> ACPProtocolLayer {
        let child = Process()
        let input = Pipe()
        let output = Pipe()
        let errorOutput = Pipe()
        child.arguments = launchSpec.arguments
        child.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        child.environment = Self.childEnvironment(from: launchSpec)
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errorOutput
        var connection: ACPProtocolLayer?
        var connectionStage = "resolve configured agent executable"
        do {
            let agentExecutable = try resolvedExecutableURL(command: launchSpec.command, environment: child.environment ?? [:])
            // Perl sets a dedicated process group before exec so shutdown can signal all descendants.
            child.executableURL = URL(fileURLWithPath: Self.processGroupLauncherPath)
            child.arguments = [
                "-MPOSIX",
                "-e",
                "setpgid(0, 0) or die; my $program = shift; exec {$program} $program, @ARGV or die;",
                agentExecutable.path,
            ] + launchSpec.arguments
            connectionStage = "start agent through the Perl process-group launcher"
            try child.run()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? errorOutput.fileHandleForWriting.close()
            process = child
            stderrPipe = errorOutput
            stderrDrainTask = Task.detached { [readHandle = errorOutput.fileHandleForReading, secrets = launchSpec.environment.values] in
                await Self.drainStderr(readHandle, redacting: Array(secrets))
            }
            let processTransport = ACPProcessStdioTransport(
                input: output.fileHandleForReading,
                output: input.fileHandleForWriting,
                onSessionUpdate: { [updateRouter] sessionID, update in updateRouter.enqueue(sessionID: sessionID.value, update) },
                onFailure: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.lifecycleFailure = AscendantBackendLifecycleFailure(
                            code: "acpTransportUnusable",
                            message: "The ACP process transport stopped unexpectedly."
                        )
                    }
                }
            )
            let protocolConnection = ACPProtocolLayer(transport: processTransport, defaultTimeoutSeconds: 30)
            await protocolConnection.onRequest(method: "session/request_permission") { [weak self] request in
                guard let self else { return try Self.permissionResponse(for: .cancelled) }
                return try await self.handlePermissionRequest(request)
            }
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
                    message: "Could not connect to the configured ACP agent process while attempting to \(connectionStage)."
                )
                lifecycleFailure = lifecycle
                failure = .lifecycleUnusable(lifecycle)
            } else {
                failure = map(error, context: "Could not initialize the ACP agent")
            }
            if child.isRunning, !isShuttingDown { await stopProcess(child) }
            await connection?.close()
            self.connection = nil
            self.transport = nil
            process = nil
            try? errorOutput.fileHandleForReading.close()
            stderrPipe = nil
            if let stderrDrainTask { await stderrDrainTask.value }
            stderrDrainTask = nil
            throw failure
        }
    }

    private func requireSession(for timelineID: UUID, connection: ACPProtocolLayer) async throws -> SessionId {
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

    private func handlePermissionRequest(_ request: JsonRpcRequest) async throws -> JsonValue {
        guard let params = request.params,
              let data = try? JSONEncoder().encode(params),
              let permissionRequest = try? JSONDecoder().decode(RequestPermissionRequest.self, from: data) else {
            Self.recordPermissionFailure("malformed request", requestID: String(describing: request.id))
            return try Self.permissionResponse(for: .cancelled)
        }

        let sessionID = permissionRequest.sessionId
        guard let timelineID = sessionIDs.first(where: { $0.value == sessionID })?.key,
              let activeTurn = activeTurns[timelineID] else {
            Self.recordPermissionFailure(
                "request has no active Turn",
                requestID: String(describing: request.id),
                sessionID: sessionID.value,
                toolCallID: permissionRequest.toolCall.toolCallId.value,
                title: permissionRequest.toolCall.title
            )
            return try Self.permissionResponse(for: .cancelled)
        }
        guard !activeTurn.isCancelled else {
            return try Self.permissionResponse(for: .cancelled)
        }

        guard permissionRequest.options.count == 2,
              let allowOption = permissionRequest.options.first(where: { $0.kind == .allowOnce }),
              let rejectOption = permissionRequest.options.first(where: { $0.kind == .rejectOnce }),
              allowOption.optionId != rejectOption.optionId else {
            Self.recordPermissionFailure(
                "unsupported permission options",
                requestID: String(describing: request.id),
                sessionID: sessionID.value,
                timelineID: timelineID,
                clientTurnID: activeTurn.clientTurnID,
                toolCallID: permissionRequest.toolCall.toolCallId.value,
                title: permissionRequest.toolCall.title,
                options: permissionRequest.options.map { "\($0.optionId.value):\($0.kind.rawValue)" }
            )
            return try Self.permissionResponse(for: .cancelled)
        }

        let permissionService = self.permissionService
        let backendPermissionRequest = BackendPermissionRequest(
            correlationID: "acp-\(request.id)",
            timelineID: timelineID,
            clientTurnID: activeTurn.clientTurnID,
            toolCallID: permissionRequest.toolCall.toolCallId.value,
            title: permissionRequest.toolCall.title ?? "External ACP tool call"
        )
        let decision = await activeTurn.requestPermission {
            await permissionService.requestApproval(for: backendPermissionRequest)
        }
        guard !activeTurn.isCancelled else {
            return try Self.permissionResponse(for: .cancelled)
        }
        switch decision {
        case .approved:
            return try Self.permissionResponse(for: .selected(allowOption.optionId))
        case .denied:
            return try Self.permissionResponse(for: .selected(rejectOption.optionId))
        case let .unavailable(reason):
            Self.recordPermissionFailure(
                "permission mediation unavailable: \(reason)",
                requestID: String(describing: request.id),
                sessionID: sessionID.value,
                timelineID: timelineID,
                clientTurnID: activeTurn.clientTurnID,
                toolCallID: permissionRequest.toolCall.toolCallId.value,
                title: permissionRequest.toolCall.title
            )
            return try Self.permissionResponse(for: .cancelled)
        }
    }

    private nonisolated static func permissionResponse(for outcome: RequestPermissionOutcome) throws -> JsonValue {
        let data = try JSONEncoder().encode(RequestPermissionResponse(outcome: outcome))
        return try JSONDecoder().decode(JsonValue.self, from: data)
    }

    private nonisolated static func recordPermissionFailure(
        _ reason: String,
        requestID: String,
        sessionID: String? = nil,
        timelineID: UUID? = nil,
        clientTurnID: String? = nil,
        toolCallID: String? = nil,
        title: String? = nil,
        options: [String] = []
    ) {
        let context = [
            "requestID=\(requestID)",
            sessionID.map { "sessionID=\($0)" },
            timelineID.map { "timelineID=\($0.uuidString)" },
            clientTurnID.map { "clientTurnID=\($0)" },
            toolCallID.map { "toolCallID=\($0)" },
            title.map { "title=\($0)" },
            options.isEmpty ? nil : "options=[\(options.joined(separator: ","))]",
        ].compactMap { $0 }.joined(separator: " ")
        let message = "ACP permission request failed closed (\(reason)); \(context)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    /// Backfills configured Gnostic Timelines as an explicit startup-hydration
    /// step before intersecting them with an agent's advertised session list.
    private func ensureSessions(for timelineIDs: [UUID], using connection: ACPProtocolLayer) async throws {
        for id in timelineIDs where sessionIDs[id] == nil {
            let response = try await connection.createSession(request: NewSessionRequest(
                cwd: workingDirectory,
                mcpServers: []
            ))
            sessionIDs[id] = response.sessionId
            activeSessionIDs.insert(id)
            try persistSessionMap()
        }
    }

    private func stopProcess(_ process: Process) async {
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }
        let pid = process.processIdentifier
        let gracefulExit = ProcessExitWaiter()
        process.terminationHandler = { _ in gracefulExit.complete(true) }
        if !process.isRunning {
            gracefulExit.complete(true)
            return
        }
        if kill(-pid, SIGTERM) != 0 { process.terminate() }
        if await gracefulExit.wait(timeoutNanoseconds: 1_000_000_000) {
            process.waitUntilExit()
            return
        }

        let forcedExit = ProcessExitWaiter()
        process.terminationHandler = { _ in forcedExit.complete(true) }
        if !process.isRunning {
            forcedExit.complete(true)
            return
        }
        if kill(-pid, SIGKILL) != 0 { _ = kill(pid, SIGKILL) }
        _ = await forcedExit.wait(timeoutNanoseconds: 1_000_000_000)
        process.waitUntilExit()
    }

    private func map(_ error: any Error, context: String) -> AscendantBackendError {
        if let backendError = error as? AscendantBackendError {
            if case let .terminal(failure) = backendError {
                return .terminal(.init(code: failure.code, message: redact(failure.message)))
            }
            return backendError
        }
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
        return .terminal(.init(code: "acpAgentFailure", message: redact("\(context): \(error.localizedDescription)")))
    }

    private func redact(_ message: String) -> String {
        launchSpec.environment.values
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .reduce(message) { $0.replacingOccurrences(of: $1, with: "[REDACTED]") }
    }

    private nonisolated static func childEnvironment(from launchSpec: ACPLaunchSpec) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let inheritedAllowlist = ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL"]
        var environment = inheritedAllowlist.reduce(into: [String: String]()) { result, key in
            if let value = inherited[key] { result[key] = value }
        }
        for (key, value) in launchSpec.environment { environment[key] = value }
        return environment
    }

    private nonisolated static func drainStderr(_ handle: FileHandle, redacting secrets: [String]) async {
        let redactor = ACPStderrRedactor(secrets: secrets)
        while !Task.isCancelled {
            guard let data = try? handle.read(upToCount: 4096), !data.isEmpty else {
                let finalOutput = redactor.consume(Data(), finishing: true)
                if !finalOutput.isEmpty { FileHandle.standardError.write(finalOutput) }
                return
            }
            let safeOutput = redactor.consume(data)
            if !safeOutput.isEmpty { FileHandle.standardError.write(safeOutput) }
        }
    }

    private func resolvedExecutableURL(command: String, environment: [String: String]) throws -> URL {
        if command.contains("/") {
            let executable = URL(fileURLWithPath: command)
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return executable
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
        if let unknown = configuration.settings.keys.sorted().first(where: {
            !acceptedSettings.contains($0) && settingsSchema.dynamicFamily(matching: $0) == nil
        }) {
            throw invalidConfiguration("The ACP backend does not accept setting '\(unknown)'.")
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
        var environment: [String: String]
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
            !key.isEmpty && !key.contains("=") && !key.contains("\0")
                && AscendantBackendSettingsSchema.isValidEnvironmentVariableName(key)
                && !value.contains("\0")
        }) else {
            throw invalidConfiguration("The ACP backend setting 'env' contains an invalid environment-variable name or value.")
        }

        try addDynamicEnvironmentValues(
            from: configuration.settings,
            expectsSecret: false,
            to: &environment
        )
        try addDynamicEnvironmentValues(
            from: configuration.secrets,
            expectsSecret: true,
            to: &environment
        )

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

    private static func addDynamicEnvironmentValues(
        from values: [String: ManifestJSONValue],
        expectsSecret: Bool,
        to environment: inout [String: String]
    ) throws {
        for key in values.keys.sorted() {
            guard let dynamic = settingsSchema.dynamicFamily(matching: key) else {
                if expectsSecret {
                    throw invalidConfiguration("The ACP backend does not accept secret setting '\(key)'.")
                }
                continue
            }
            guard dynamic.family.isSecret == expectsSecret else {
                throw invalidConfiguration("The ACP backend does not accept \(expectsSecret ? "secret" : "plain") setting '\(key)'.")
            }
            guard AscendantBackendSettingsSchema.isValidEnvironmentVariableName(dynamic.member) else {
                throw invalidConfiguration("The ACP backend setting '\(key)' must name a valid environment variable.")
            }
            guard case let .string(value) = values[key], !value.contains("\0") else {
                throw invalidConfiguration("The ACP backend setting '\(key)' must be a string without null characters.")
            }
            guard environment[dynamic.member] == nil else {
                throw invalidConfiguration("The ACP backend environment variable '\(dynamic.member)' is configured more than once.")
            }
            environment[dynamic.member] = value
        }
    }

    private static func invalidConfiguration(_ message: String) -> AscendantBackendError {
        .invalidConfiguration(message)
    }

    private nonisolated static func forward(
        _ events: AsyncStream<SessionUpdate>,
        to sink: any AscendantBackendUpdateSink,
        activeTurn: ACPActiveTurn
    ) async -> (String, (any Error)?) {
        var assistantText = ""
        var appendError: (any Error)?
        for await event in events {
            guard !(await activeTurn.isTurnCancelled) else { continue }
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

@MainActor
private final class ACPActiveTurn {
    let clientTurnID: String
    let sessionID: SessionId
    var isCancelled = false
    var isTurnCancelled = false
    private var permissionContinuations: [UUID: CheckedContinuation<AscendantPermissionDecision, Never>] = [:]
    private var permissionTasks: [UUID: Task<Void, Never>] = [:]

    init(clientTurnID: String, sessionID: SessionId) {
        self.clientTurnID = clientTurnID
        self.sessionID = sessionID
    }

    func markCancelled() {
        isCancelled = true
    }

    func cancelTurn() {
        isCancelled = true
        isTurnCancelled = true
        let continuations = permissionContinuations.values
        permissionContinuations.removeAll()
        let tasks = permissionTasks.values
        permissionTasks.removeAll()
        tasks.forEach { $0.cancel() }
        continuations.forEach { $0.resume(returning: .unavailable(reason: "turnCancelled")) }
    }

    func requestPermission(
        _ operation: @escaping @Sendable () async -> AscendantPermissionDecision
    ) async -> AscendantPermissionDecision {
        guard !isCancelled else { return .unavailable(reason: "turnCancelled") }
        let requestID = UUID()
        return await withCheckedContinuation { continuation in
            permissionContinuations[requestID] = continuation
            permissionTasks[requestID] = Task { @MainActor [weak self] in
                let decision = await operation()
                self?.resolvePermission(requestID, decision: decision)
            }
        }
    }

    private func resolvePermission(_ requestID: UUID, decision: AscendantPermissionDecision) {
        permissionTasks.removeValue(forKey: requestID)
        permissionContinuations.removeValue(forKey: requestID)?.resume(returning: decision)
    }
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

private struct ACPCancelSessionRequest: Encodable {
    let sessionId: SessionId
}

private struct ACPEmptyResponse: Decodable {}

private final class ProcessExitWaiter: @unchecked Sendable { // SAFETY: `continuation` and `result` are only accessed while holding `lock`.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func wait(timeoutNanoseconds: UInt64) async -> Bool {
        await withCheckedContinuation { continuation in
            let immediateResult = withLock { () -> Bool? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let immediateResult {
                continuation.resume(returning: immediateResult)
                return
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                complete(false)
            }
        }
    }

    func complete(_ result: Bool) {
        let continuation = withLock { () -> CheckedContinuation<Bool, Never>? in
            guard self.result == nil else { return nil }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private final class ACPUpdateRouter: @unchecked Sendable { // SAFETY: Session-keyed AsyncStream continuations are read, replaced, removed, and finished only while holding `lock`; AsyncStream continuations support concurrent yields.
    private let lock = NSLock()
    private var continuations: [String: AsyncStream<SessionUpdate>.Continuation] = [:]

    func beginTurn(sessionID: String) -> AsyncStream<SessionUpdate> {
        let (stream, continuation) = AsyncStream<SessionUpdate>.makeStream()
        lock.lock()
        continuations.removeValue(forKey: sessionID)?.finish()
        continuations[sessionID] = continuation
        lock.unlock()
        return stream
    }

    func enqueue(sessionID: String, _ update: SessionUpdate) {
        lock.lock()
        continuations[sessionID]?.yield(update)
        lock.unlock()
    }

    func endTurn(sessionID: String) {
        lock.lock()
        continuations.removeValue(forKey: sessionID)?.finish()
        lock.unlock()
    }
}
