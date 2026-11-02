// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticProtocol
import Foundation
import GnosticCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
import GnosticACPWire
#endif

/// An optional backend configuration surface for an external ACP agent.
///
/// This target owns the ACP client process, sessions, and private Timeline map.
@MainActor
public final class ACPAscendantBackend: AscendantBackend, AscendantBackendTurnCancellation, AscendantBackendWorkspaceCapability, RuntimeInstanceSnapshotProviding {
    private nonisolated let hasWorkspaceService: Bool
    public nonisolated var capabilities: AscendantBackendOptionalSurfaces {
        hasWorkspaceService ? .turnCancellation.union(.workspace) : .turnCancellation
    }
    // Expected page counts are single-digit; this abusive-cursor guard truncates sessions beyond 100 pages.
    private static let maximumSessionListPages = 100

    /// The manifest backend kind served by this implementation.
    public nonisolated static let kind = "acp-client"
    private nonisolated static let processGroupLauncherPath = "/usr/bin/perl"
    private nonisolated static let defaultProtocolTimeoutSeconds: TimeInterval = 30
    // #418: allow long Turns; revisit if Turns exceed 1h and consider a settings key.
    private nonisolated static let defaultPromptTimeoutSeconds: TimeInterval = 60 * 60
    /// How long a cancelled Turn waits for the Runtime to settle: an answer to
    /// `$/cancel_request`, or an `idle` after `session/cancel`. When it expires
    /// the Turn ends without the Runtime's confirmation and the backend is
    /// retired, so a Runtime that ignores cancellation cannot hold the
    /// Timeline busy for the prompt timeout.
    nonisolated static let defaultCancellationSettleSeconds: TimeInterval = 30

    /// The configuration keys accepted by the ACP client backend.
    public nonisolated static let settingsSchema = AscendantBackendSettingsSchema(keys: [
        .init(name: "command", summary: "Executable command used to start the ACP agent."),
        .init(name: "args", summary: "Command-line arguments encoded as a JSON string array."),
        .init(name: "cwd", summary: "Optional working directory for the ACP agent process."),
        .init(name: "scratchRoot", summary: "Optional root directory for Gnostic-managed scratch Projects."),
        .init(name: "env", summary: "Optional JSON object of non-secret environment-variable strings."),
        .init(name: "displayName", summary: "Optional display name for the external ACP agent."),
    ], keyFamilies: [
        .init(prefix: "env.", summary: "One non-secret process environment variable."),
        .init(prefix: "env-secret.", summary: "One secret process environment variable.", isSecret: true),
    ])

    /// Gnostic-owned identity for the Ascendant served by this backend.
    public let identity: RuntimeInstanceIdentity

    /// Parsed process settings. This value does not start a process.
    public let launchSpec: ACPLaunchSpec

    private let configuration: AscendantBackendConfiguration
    private let protocolTimeoutSeconds: TimeInterval
    private let promptTimeoutSeconds: TimeInterval
    private let cancellationSettleSeconds: TimeInterval
    private let configuredTimelines: [NodeManifest.Timeline]
    private let projectResolver: ProjectDirectoryResolver
    private let explicitProjectIDs: Set<UUID>
    private var projects: [UUID: Project]
    private var sessionIDs: [UUID: String]
    private var sessionStates: [UUID: TimelineJournalSessionState] = [:]
    private var pendingSessionCreations = 0
    private var bindingTimelineIDsBySessionID: [String: UUID] = [:]
    private var pendingSessionUpdates: [String: [ACPSessionUpdate]] = [:]
    private var timelineIDsBySessionID: [String: UUID]
    private var sessionCwds: [UUID: String]
    private var sessionProjectKinds: [UUID: Project.Kind]
    private var sessionStartedAt: [UUID: Date]
    private var activeSessionIDs: Set<UUID> = []
    private var journalSessionBindingsRestored = false
    private let sessionMapURL: URL
    private var workspaceGateways: [UUID: WorkspaceMCPGateway] = [:]

    /// Shared Gnostic Timeline bookkeeping. This backend supplies only the
    /// remote ACP session operations.
    private lazy var timelineRegistry = AscendantTimelineRegistry(
        ascendantID: identity.id,
        privateTimelineID: identity.privateTimelineID,
        configured: configuredTimelines,
        remote: .init(
            // A Gnostic Timeline is not an ACP Session. The first Turn creates
            // the remote Session after NodeRegistry has committed Timeline genesis.
            ensure: { _, _ in },
            rename: { [weak self] id, title in _ = try await self?.renameTimelineRemote(id: id, title: title) },
            delete: { [weak self] id in _ = await self?.deleteTimelineRemote(id: id) }
        )
    )
    private var process: Process?
    private var processGroupID: pid_t?
    private var processLeaderWasReaped = false
#if DEBUG
    var testLeaderIsRunning: Bool {
        guard let process else { return false }
        return isProcessLeaderRunning(process)
    }
    var testProcessGroupID: pid_t? { processGroupID }
#endif
    private var stderrPipe: Pipe?
    private var stderrDrainTask: Task<Void, Never>?
    private var transport: ACPProcessStdioTransport?
    private var connection: ACPProtocolLayer?
    private var connectionTask: Task<ACPProtocolLayer, Error>?
    private var connectionTaskID: UUID?
    private var isShuttingDown = false
    private var sessionCapabilities: ACPAgentSessionCapabilities?
    public private(set) var runtimeInstanceObject: GnosticRuntimeInstanceObject?
    private let permissionService: any AscendantBackendPermissionService
    private let workspaceService: (any AscendantBackendWorkspaceService)?
    private let timelineJournalRecorder: TimelineJournalRecorder?
    // The backend contract serializes Turns per Timeline; one active entry per Timeline is intentional.
    private var activeTurns: [UUID: ACPActiveTurn] = [:]
    private let updateRouter = ACPUpdateRouter()
    private var lifecycleFailure: AscendantBackendLifecycleFailure?

    /// Creates the ACP backend and projects its configured Gnostic Timelines.
    ///
    /// - Parameters:
    ///   - ascendant: The manifest Ascendant served by this backend.
    ///   - configuration: The backend-owned configuration envelope.
    ///   - services: Host-provided Workspace and permission services.
    ///   - timelines: Timelines assigned to this Ascendant in the manifest.
    /// - Throws: ``AscendantBackendError/invalidConfiguration(_:)`` when the
    ///   envelope or launch settings are invalid.
    public convenience init(
        ascendant: NodeManifest.Ascendant,
        configuration: AscendantBackendConfiguration,
        services: AscendantBackendServices,
        timelines configuredTimelines: [NodeManifest.Timeline]
    ) throws {
        try self.init(
            ascendant: ascendant,
            configuration: configuration,
            services: services,
            timelines: configuredTimelines,
            protocolTimeoutSeconds: Self.defaultProtocolTimeoutSeconds,
            promptTimeoutSeconds: Self.defaultPromptTimeoutSeconds
        )
    }

    init(
        ascendant: NodeManifest.Ascendant,
        configuration: AscendantBackendConfiguration,
        services: AscendantBackendServices,
        timelines configuredTimelines: [NodeManifest.Timeline],
        protocolTimeoutSeconds: TimeInterval = 30,
        promptTimeoutSeconds: TimeInterval = 60 * 60,
        cancellationSettleSeconds: TimeInterval = ACPAscendantBackend.defaultCancellationSettleSeconds
    ) throws {
        try AscendantBackendConfigurationValidator.validate(configuration)
        let parsedLaunchSpec = try Self.parse(configuration)
        launchSpec = parsedLaunchSpec
        let configuredScratchRoot = try Self.optionalStringSetting("scratchRoot", in: configuration.settings)
        if let configuredScratchRoot,
           (!configuredScratchRoot.hasPrefix("/") || configuredScratchRoot.contains("\0")) {
            throw Self.invalidConfiguration("The ACP backend setting 'scratchRoot' must be an absolute directory path.")
        }
        projectResolver = ProjectDirectoryResolver(
            scratchRoot: configuredScratchRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
        self.configuration = configuration
        self.protocolTimeoutSeconds = protocolTimeoutSeconds
        self.promptTimeoutSeconds = promptTimeoutSeconds
        self.cancellationSettleSeconds = cancellationSettleSeconds
        permissionService = services.permission
        workspaceService = services.workspace
        timelineJournalRecorder = services.capability(TimelineJournalRecorder.self)
        hasWorkspaceService = services.workspace != nil
        self.configuredTimelines = configuredTimelines
        explicitProjectIDs = Set(configuredTimelines.filter { $0.project != nil }.map(\.id))
        projects = Dictionary(uniqueKeysWithValues: configuredTimelines.map { ($0.id, $0.project ?? .scratch) })
        sessionMapURL = Self.sessionMapURL(for: ascendant.id)
        let recoveredSessions = timelineJournalRecorder == nil ? Self.loadSessionMap(at: sessionMapURL) : [:]
        let configuredTimelineIDs = Set(configuredTimelines.map(\.id))
        sessionIDs = recoveredSessions.reduce(into: [:]) { result, entry in
            guard configuredTimelineIDs.contains(entry.key) else { return }
            result[entry.key] = entry.value.sessionID
        }
        sessionStates = Dictionary(uniqueKeysWithValues: sessionIDs.keys.map { ($0, .resumable) })
        var timelineIDsBySessionID: [String: UUID] = [:]
        for (timelineID, session) in recoveredSessions where configuredTimelineIDs.contains(timelineID) {
            if let otherTimelineID = timelineIDsBySessionID[session.sessionID], otherTimelineID != timelineID {
                throw Self.invalidConfiguration("A recovered ACP Session ID belongs to more than one Timeline.")
            }
            timelineIDsBySessionID[session.sessionID] = timelineID
        }
        self.timelineIDsBySessionID = timelineIDsBySessionID
        sessionCwds = recoveredSessions.reduce(into: [:]) { result, entry in
            guard configuredTimelineIDs.contains(entry.key) else { return }
            // Older session maps did not persist cwd. Preserve their original
            // launch-directory binding rather than resuming them with a newly
            // allocated scratch path.
            result[entry.key] = entry.value.cwd ?? parsedLaunchSpec.workingDirectory ?? FileManager.default.currentDirectoryPath
        }
        sessionProjectKinds = recoveredSessions.reduce(into: [:]) { result, entry in
            guard configuredTimelineIDs.contains(entry.key), let kind = entry.value.projectKind else { return }
            result[entry.key] = kind
        }
        sessionStartedAt = recoveredSessions.reduce(into: [:]) { result, entry in
            guard configuredTimelineIDs.contains(entry.key), let startedAt = entry.value.startedAt else { return }
            result[entry.key] = startedAt
        }

        var interoperability: Set<String> = [
            InteroperabilityCapability.textTurn.rawValue,
            InteroperabilityCapability.streamedUpdates.rawValue,
            InteroperabilityCapability.cancellation.rawValue,
            InteroperabilityCapability.permissionMediation.rawValue,
            InteroperabilityCapability.timelineManagement.rawValue,
        ]
        if services.workspace != nil {
            interoperability.insert(InteroperabilityCapability.workspaceAttachment.rawValue)
            interoperability.insert(InteroperabilityCapability.workspaceToolInvocation.rawValue)
        }
        let now = Date()
        identity = RuntimeInstanceIdentity(
            id: ascendant.id,
            name: ascendant.name,
            description: ascendant.description,
            privateTimelineID: ascendant.defaultTimelineID,
            primaryWorkspaceID: nil,
            lastActiveAt: now,
            createdAt: now,
            updatedAt: now,
            capabilities: .init(
                interoperability: interoperability,
                backendKind: Self.kind,
                backendVersion: "0.1.16"
            )
        )
        if sessionIDs.count != recoveredSessions.count {
            // Runtime-created Timelines are process-scoped; prune their stale ACP sessions without
            // making startup depend on this best-effort cleanup write.
            try? persistSessionMap()
        }
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
        if let configuredScratchRoot = try Self.optionalStringSetting("scratchRoot", in: configuration.settings) {
            guard configuredScratchRoot.hasPrefix("/"), !configuredScratchRoot.contains("\0") else {
                throw Self.invalidConfiguration("The ACP backend setting 'scratchRoot' must be an absolute directory path.")
            }
            let root = URL(fileURLWithPath: configuredScratchRoot, isDirectory: true).standardizedFileURL
            var scratchRootIsDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: root.path, isDirectory: &scratchRootIsDirectory),
               !scratchRootIsDirectory.boolValue {
                throw Self.invalidConfiguration("The ACP backend setting 'scratchRoot' must name a directory.")
            }
        }
        for timeline in configuredTimelines {
            guard let project = timeline.project else { continue }
            do {
                try project.validate()
                if project.kind == .local { _ = try projectResolver.resolve(project) }
            } catch {
                throw Self.invalidConfiguration("Timeline \(timeline.id.uuidString) has an invalid Project: \(error.localizedDescription)")
            }
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
    public func operatedTimelines() async throws -> [RuntimeInstanceTimeline] {
        do {
            let connection = try await requireConnection()
            let timelineIDs = timelineRegistry.operatedTimelines().map(\.id)
            try await restoreSessionBindingsFromJournal(for: timelineIDs)
            guard sessionCapabilities?.supportsList == true else {
                return timelineRegistry.operatedTimelines()
            }
            // NodeRuntime uses this call during startup hydration. Seed the
            // session map here so the advertised session-list intersection can
            // include configured Gnostic Timelines on the first startup.
            try await ensureSessions(for: timelineIDs, using: connection)
            var cursor: String?
            var seenCursors: Set<String> = []
            var available: Set<String> = []
            for _ in 0..<Self.maximumSessionListPages {
                let response = try await connection.listSessions(
                    // Sessions may have different Project directories. Listing
                    // with the process launch cwd would hide local and scratch
                    // Project sessions from startup hydration.
                    request: ACPListSessionsRequest(cwd: nil, cursor: cursor)
                )
                available.formUnion(response.sessions.map { $0.sessionId })
                guard let nextCursor = response.nextCursor,
                      seenCursors.insert(nextCursor).inserted else {
                    break
                }
                cursor = nextCursor
            }
            return timelineIDs.compactMap { id in
                guard let sessionID = sessionIDs[id], available.contains(sessionID) else { return nil }
                return timelineRegistry.projection(id: id)
            }
        } catch {
            throw map(error, context: "Could not list ACP sessions")
        }
    }

    /// Creates the Gnostic Timeline projection; its ACP Session opens on the first Turn.
    ///
    /// - Parameters:
    ///   - id: The Gnostic-owned Timeline identifier to adopt.
    ///   - title: The Timeline title.
    /// - Returns: The new in-memory Timeline projection.
    public func createTimeline(id: UUID, title: String) async throws -> RuntimeInstanceTimeline {
        do {
            let timeline = try await timelineRegistry.create(id: id, title: title)
            projects[id] = .scratch
            try persistSessionMap()
            return timeline
        } catch {
            throw map(error, context: "Could not create ACP session")
        }
    }

    /// Closes its ACP session when the agent advertises session/close.
    public func removeTimeline(id: UUID) async {
        workspaceGateways.removeValue(forKey: id)?.stop()
        await timelineRegistry.remove(id: id)
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
    public func renameTimeline(id: UUID, title: String) async throws -> RuntimeInstanceTimeline {
        let renamed = try await timelineRegistry.rename(id: id, title: title)
        try persistSessionMap()
        return renamed
    }

    /// Adds an attached Workspace to the Timeline's live MCP tool catalog.
    ///
    /// - Parameters:
    ///   - reference: The available Workspace supplied by the host.
    ///   - timelineID: The Timeline that receives the Workspace.
    /// - Throws: When the Timeline is unknown or the Workspace is unavailable.
    public func attachWorkspace(_ reference: BackendWorkspaceReference, to timelineID: UUID) async throws {
        guard timelineRegistry.contains(id: timelineID) else {
            throw AscendantBackendError.timelineNotFound(timelineID)
        }
        guard reference.status == .available else {
            throw DiscoveredWorkspaceAttachmentError.unavailable(.unavailable)
        }
        try timelineRegistry.attachWorkspace(reference.id, to: timelineID)
    }

    /// Removes a Workspace from a Timeline's live MCP tool catalog.
    ///
    /// - Parameters:
    ///   - workspaceID: The Workspace to remove.
    ///   - timelineID: The Timeline that loses the Workspace.
    /// - Throws: When the Timeline is unknown.
    public func detachWorkspace(_ workspaceID: UUID, from timelineID: UUID) async throws {
        guard timelineRegistry.contains(id: timelineID) else {
            throw AscendantBackendError.timelineNotFound(timelineID)
        }
        timelineRegistry.detachWorkspace(workspaceID, from: timelineID)
    }

    /// Lists the tool identifiers currently available on a Timeline.
    ///
    /// - Parameter timelineID: The Timeline to inspect.
    /// - Returns: The attached Workspaces' currently available tool identifiers.
    public func enabledToolIDs(for timelineID: UUID) async -> [String] {
        guard timelineRegistry.contains(id: timelineID), let workspaceService else { return [] }
        var toolIDs: Set<String> = []
        for workspaceID in timelineRegistry.attachedWorkspaceIDs(for: timelineID) {
            guard let reference = await workspaceService.reference(id: workspaceID), reference.status == .available else { continue }
            toolIDs.formUnion(reference.tools.map(\.id))
        }
        return toolIDs.sorted()
    }

    /// Changes the Project used by future Turns on a Timeline.
    ///
    /// If a Session already exists, Gnostic closes it when the Runtime supports
    /// `session/close`, retires its binding, and opens a fresh ACP Session on
    /// the next operation. The Timeline ID and its Gnostic history do not
    /// change. The new Session makes no model-context continuity claim.
    ///
    /// - Parameters:
    ///   - project: The new Project; `nil` selects a fresh scratch Project.
    ///   - timelineID: The Timeline whose Project changes.
    /// - Throws: When the Timeline is unknown, has an active Turn, or the local
    ///   Project cannot be validated.
    public func setProject(_ project: Project?, for timelineID: UUID) async throws {
        guard timelineRegistry.contains(id: timelineID) else {
            throw AscendantBackendError.timelineNotFound(timelineID)
        }
        guard activeTurns[timelineID] == nil else {
            throw AscendantBackendError.terminal(.init(
                code: "projectChangeDuringActiveTurn",
                message: "The Project cannot change while a Turn is active."
            ))
        }
        let nextProject = project ?? .scratch
        do {
            try nextProject.validate()
            if nextProject.kind == .local { _ = try projectResolver.resolve(nextProject) }
        } catch {
            throw AscendantBackendError.invalidConfiguration(error.localizedDescription)
        }
        guard projects[timelineID] != nextProject else { return }

        try await timelineJournalRecorder?.appendProjectChange(timelineID: timelineID, project: nextProject)
        let oldCWD = sessionCwds[timelineID]
        let oldKind = sessionProjectKinds[timelineID]
        var oldSessionClosed = false
        if let sessionID = sessionIDs[timelineID],
           let connection,
           sessionCapabilities?.supportsClose == true {
            do {
                _ = try await connection.closeSession(request: ACPCloseSessionRequest(sessionId: sessionID))
                oldSessionClosed = true
            } catch { /* A Project transition must not depend on best-effort close. */ }
        }
        workspaceGateways.removeValue(forKey: timelineID)?.stop()
        sessionIDs.removeValue(forKey: timelineID)
        sessionCwds.removeValue(forKey: timelineID)
        sessionProjectKinds.removeValue(forKey: timelineID)
        sessionStartedAt.removeValue(forKey: timelineID)
        activeSessionIDs.remove(timelineID)
        if oldSessionClosed, let oldCWD, oldKind == .scratch {
            try? projectResolver.discard(.init(
                kind: .scratch,
                cwd: oldCWD,
                scratchRoot: projectResolver.scratchRoot.standardizedFileURL.path
            ))
        }
        projects[timelineID] = nextProject
        try persistSessionMap()
    }

    /// Returns the active or most recently opened Session binding for a Timeline.
    ///
    /// - Parameter timelineID: The Timeline to inspect.
    /// - Returns: Its Session binding, or `nil` before a Session is opened.
    public func sessionBinding(for timelineID: UUID) -> ACPProjectSessionBinding? {
        guard let sessionID = sessionIDs[timelineID],
              let cwd = sessionCwds[timelineID],
              let kind = sessionProjectKinds[timelineID] else { return nil }
        return ACPProjectSessionBinding(
            timelineID: timelineID,
            sessionID: sessionID,
            cwd: cwd,
            projectKind: kind,
            startedAt: sessionStartedAt[timelineID] ?? Date()
        )
    }

    // MARK: - Remote Timeline operations

    /// ACP sessions carry no remote title; the Gnostic projection is
    /// authoritative.
    private func renameTimelineRemote(id _: UUID, title _: String) async throws {}

    /// Closes the remote ACP session and drops its backend-private indexes.
    private func deleteTimelineRemote(id: UUID) async {
        if let sessionID = sessionIDs[id],
           let connection,
           sessionCapabilities?.supportsClose == true {
            do {
                _ = try await connection.closeSession(
                    request: ACPCloseSessionRequest(sessionId: sessionID)
                )
            } catch { /* Closing a removed Timeline is best effort, not a backend health failure. */ }
        }
        sessionIDs.removeValue(forKey: id)
        let cwd = sessionCwds.removeValue(forKey: id)
        let kind = sessionProjectKinds.removeValue(forKey: id)
        sessionStartedAt.removeValue(forKey: id)
        activeSessionIDs.remove(id)
        projects.removeValue(forKey: id)
        if let cwd, kind == .scratch {
            try? projectResolver.discard(.init(
                kind: .scratch,
                cwd: cwd,
                scratchRoot: projectResolver.scratchRoot.standardizedFileURL.path
            ))
        }
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
        guard timelineRegistry.contains(id: request.timelineID) else {
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
                activeTurn.isFinished = true
                activeTurn.cancellationDeadline?.cancel()
                activeTurns.removeValue(forKey: request.timelineID)
            }
            let eventStream = updateRouter.beginTurn(sessionID: sessionID)
            let forwardingTask = Task {
                await Self.forward(eventStream, to: updates, activeTurn: activeTurn)
            }
            do {
                // A Turn cancelled before dispatch never sends `session/prompt`
                // (ADR 0019 section 5).
                if Task.isCancelled || activeTurn.isTurnCancelled { throw AscendantBackendError.cancelled }
                // ACP v2 acknowledges insertion, not completion. The turn is
                // finished by the idle state update, which the forwarding task
                // consumes before it returns.
                //
                // The prompt runs in its own task, which cancelling this Turn's
                // task does not cancel. A cancelled wait would discard the
                // Runtime's answer to `$/cancel_request`, and that answer
                // decides whether `session/cancel` follows. Cancelling the Turn
                // sends the cancel instead (ADR 0019 section 5), and the
                // cancellation deadline bounds the wait.
                let promptTask = Task {
                    try await connection.prompt(
                        request: ACPPromptRequest(
                            sessionId: sessionID,
                            prompt: [.text(ACPTextContent(text: request.message))]
                        ),
                        timeoutSeconds: promptTimeoutSeconds,
                        didSend: { requestID in
                            // The prompt is pending insertion from here. A cancel
                            // that arrived while it was being sent reaches the
                            // Runtime now, after the request it cancels.
                            if await activeTurn.promptSent(requestID) {
                                try? await connection.cancelRequest(requestId: requestID)
                            }
                        }
                    )
                }
                let response = try await withTaskCancellationHandler {
                    try await promptTask.value
                } onCancel: {
                    Task { @MainActor [weak self] in await self?.cancelActiveTurn(activeTurn) }
                }
                activeTurn.insertion = .inserted
                // A successful response binds the Turn to the Runtime's message.
                await updates.bindMessage(response.messageId)
                // The Runtime inserted the prompt although cancellation was
                // requested while it was pending, so `session/cancel` follows
                // the successful response (ADR 0019 section 5).
                if activeTurn.isTurnCancelled { await sendSessionCancel(for: activeTurn) }
            } catch {
                updateRouter.endTurn(sessionID: sessionID)
                let outcome = await forwardingTask.value
                if let updateError = outcome.error { throw updateError }
                // `-32800` answers `$/cancel_request` and confirms that the
                // prompt was not inserted. The Turn is cancelled, with no
                // `session/cancel` to send.
                if activeTurn.isTurnCancelled,
                   case let ACPError.custom(code, _, _) = error,
                   code == ACPv2Protocol.ErrorCode.requestCancelled {
                    throw AscendantBackendError.cancelled
                }
                // A response that never arrived leaves insertion unknown. The
                // backend neither guesses nor sends the prompt again (ADR 0019
                // section 2), whether or not a cancel was requested.
                if error is ACPTransportError {
                    var failure: AscendantBackendLifecycleFailure?
                    if case let .lifecycleUnusable(unusable) = map(error, context: "ACP prompt") {
                        failure = unusable
                    }
                    throw AscendantBackendError.insertionUnknown(failure)
                }
                if activeTurn.isTurnCancelled { throw AscendantBackendError.cancelled }
                throw error
            }
            let idleTimeout = Task { @MainActor [updateRouter] in
                try? await Task.sleep(for: .seconds(promptTimeoutSeconds))
                guard !Task.isCancelled else { return }
                updateRouter.endTurn(sessionID: sessionID)
            }
            let outcome = await forwardingTask.value
            idleTimeout.cancel()
            updateRouter.endTurn(sessionID: sessionID)
            // The Runtime did not settle a cancelled Turn within the bound. The
            // Turn ends, and the failure retires the backend rather than
            // claiming the Runtime stopped.
            if let failure = activeTurn.cancellationFailure { throw AscendantBackendError.lifecycleUnusable(failure) }
            if activeTurn.isTurnCancelled { throw AscendantBackendError.cancelled }
            if let streamError = outcome.error { throw streamError }
            // The Runtime may still be working, and a later Turn must not start
            // beside that work, so the failure retires the backend.
            guard outcome.idleReported else {
                let failure = AscendantBackendLifecycleFailure(
                    code: "acpTurnStopped",
                    message: "ACP agent did not report an idle state for the Turn."
                )
                lifecycleFailure = failure
                throw AscendantBackendError.lifecycleUnusable(failure)
            }
            if let stopReason = outcome.stopReason {
                if stopReason == .cancelled { throw AscendantBackendError.cancelled }
                if stopReason != .endTurn {
                    let message = "ACP agent stopped the Turn with reason '\(stopReason.wireValue)'."
                    throw AscendantBackendError.terminal(.init(code: "acpTurnStopped", message: message))
                }
            }
            // An idle without a stop reason ends the Turn `endedUnspecified`,
            // which is neither success nor failure (ADR 0019 section 2). The
            // completion carries that reason code so the ledger, the journal,
            // and the client record the Turn as unspecified.
            try await updates.append(.init(
                kind: .completion,
                terminal: true,
                reasonCode: outcome.stopReason == nil ? TurnTerminalOutcome.endedUnspecified.rawValue : nil
            ))
            return outcome.text
        } catch let error as AscendantBackendError {
            throw error
        } catch {
            throw map(error, context: "ACP Turn failed")
        }
    }

    /// Marks active Turns cancelled during backend retirement.
    public func cancel() async {
        // Backend-wide cancellation must actually reach every live ACP session:
        // marking the turn alone leaves the agent running until its own deadline
        // (GNO-PLAT-060 conformance, #452). Retirement does not wait for a
        // pending prompt to be answered, so it sends `session/cancel` as well.
        let connection = self.connection
        for activeTurn in activeTurns.values {
            activeTurn.cancelTurn()
            if let connection {
                if case let .pending(requestID) = activeTurn.insertion {
                    try? await connection.cancelRequest(requestId: requestID)
                }
                try? await connection.sendNotification(
                    method: ACPv2Protocol.AgentMethod.sessionCancel,
                    params: ACPCancelSessionNotification(sessionId: activeTurn.sessionID)
                )
            }
        }
    }

    /// Cancels only the matching Timeline Turn, as ADR 0019 section 5 orders.
    ///
    /// - Before dispatch, nothing is sent: the Turn sends no prompt.
    /// - While the prompt is pending insertion, `$/cancel_request` names it. The
    ///   prompt's answer decides what follows: `-32800` ends the Turn cancelled,
    ///   and a success is followed by `session/cancel`.
    /// - After insertion, `session/cancel`.
    public func cancelTurn(timelineID: UUID, clientTurnID: String) async {
        guard let canonicalClientTurnID = try? GnosticWirePayload.canonicalClientTurnID(clientTurnID) else { return }
        guard let activeTurn = activeTurns[timelineID],
              activeTurn.clientTurnID == canonicalClientTurnID else { return }
        await cancelActiveTurn(activeTurn)
    }

    /// Cancels one Turn once. Cancelling the Turn's task reaches this too, so a
    /// repeated cancel sends nothing more.
    ///
    /// The Runtime gets ``cancellationSettleSeconds`` to settle the Turn, in up
    /// to two bounds that each start when Gnostic sends something the Runtime
    /// can answer. The first starts here and bounds the answer to a pending
    /// prompt. The second starts when `session/cancel` is sent and bounds the
    /// `idle` that follows. A cancel that finds the prompt inserted starts only
    /// the second bound. The Turn therefore ends within twice
    /// ``cancellationSettleSeconds`` of the cancel, plus the time to send
    /// `session/cancel`.
    private func cancelActiveTurn(_ activeTurn: ACPActiveTurn) async {
        guard let insertion = activeTurn.beginCancellation() else { return }
        startCancellationBound(for: activeTurn)
        guard let connection else { return }
        switch insertion {
        case .notDispatched:
            break
        case let .pending(requestID):
            try? await connection.cancelRequest(requestId: requestID)
        case .inserted:
            await sendSessionCancel(for: activeTurn)
        }
    }

    /// Starts a cancellation bound of ``cancellationSettleSeconds``, replacing
    /// the one that is running.
    private func startCancellationBound(for activeTurn: ACPActiveTurn) {
        activeTurn.cancellationDeadline?.cancel()
        let settleSeconds = cancellationSettleSeconds
        activeTurn.cancellationDeadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(settleSeconds))
            guard !Task.isCancelled else { return }
            await self?.expireCancellation(of: activeTurn)
        }
    }

    private func sendSessionCancel(for activeTurn: ACPActiveTurn) async {
        guard activeTurn.claimSessionCancel() else { return }
        // The Runtime has the full bound to idle, counted from this cancel
        // rather than from the earlier one it may already have outlasted.
        if !activeTurn.isFinished { startCancellationBound(for: activeTurn) }
        guard let connection else { return }
        try? await connection.sendNotification(
            method: ACPv2Protocol.AgentMethod.sessionCancel,
            params: ACPCancelSessionNotification(sessionId: activeTurn.sessionID)
        )
    }

    /// Ends a cancelled Turn that the Runtime did not settle in time.
    ///
    /// - A prompt whose answer is still missing leaves insertion unknown: the
    ///   wait ends as a timeout, which the Turn records as `insertionUnknown`.
    /// - A prompt whose answer reached the protocol layer in the meantime is no
    ///   longer abandoned. The Turn is about to record insertion and send
    ///   `session/cancel`, so it gets the second bound, which also covers a
    ///   Turn that never gets that far.
    /// - An inserted prompt whose Turn never reported `idle` ends with a
    ///   lifecycle failure. The Runtime may still be working, and a later Turn
    ///   must not start beside that work, so the failure retires the backend.
    ///   Gnostic does not record the Turn `cancelled`, because the Runtime did
    ///   not confirm it (ADR 0021).
    private func expireCancellation(of activeTurn: ACPActiveTurn) async {
        guard !activeTurn.isFinished else { return }
        let insertion = activeTurn.insertion
        if case let .pending(requestID) = insertion,
           await connection?.abandonRequest(id: requestID, error: ACPTransportError.timeout) == true {
            return
        }
        // The Turn may have sent `session/cancel` during that wait, which starts
        // a fresh bound and cancels this one.
        guard !Task.isCancelled, !activeTurn.isFinished else { return }
        // The prompt was answered, but `session/cancel` has not gone out. Its
        // bound starts when it does, so this one is extended at most once.
        switch insertion {
        case .notDispatched:
            break
        case .pending, .inserted:
            if activeTurn.extendBoundForSessionCancel() {
                startCancellationBound(for: activeTurn)
                return
            }
        }
        let failure = AscendantBackendLifecycleFailure(
            code: "acpCancellationUnconfirmed",
            message: "The ACP Runtime did not settle a cancelled Turn within \(Int(cancellationSettleSeconds)) seconds."
        )
        activeTurn.cancellationFailure = failure
        lifecycleFailure = failure
        updateRouter.endTurn(sessionID: activeTurn.sessionID)
    }

    /// Closes the ACP transport and terminates the child process.
    public func shutdown() async {
        await cancel()
        isShuttingDown = true
        let pendingConnection = connectionTask
        pendingConnection?.cancel()
        if let process { await stopProcess(process, processGroupID: processGroupID) }
        if let pendingConnection { _ = await pendingConnection.result }
        connectionTask = nil
        connectionTaskID = nil
        await connection?.close()
        connection = nil
        await transport?.close()
        transport = nil
        // The closed connection can report no `idle`, so nothing else ends these
        // Turns.
        for activeTurn in activeTurns.values { updateRouter.endTurn(sessionID: activeTurn.sessionID) }
        for gateway in workspaceGateways.values { gateway.stop() }
        workspaceGateways.removeAll()
        process = nil
        processGroupID = nil
        processLeaderWasReaped = false
        try? stderrPipe?.fileHandleForReading.close()
        stderrPipe = nil
        if let stderrDrainTask { await stderrDrainTask.value }
        stderrDrainTask = nil
        sessionCapabilities = nil
        runtimeInstanceObject = nil
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
                "setpgid(0, 0) or die; $SIG{INT} = 'DEFAULT'; $SIG{TERM} = 'DEFAULT'; my $program = shift; exec {$program} $program, @ARGV or die;",
                agentExecutable.path,
            ] + launchSpec.arguments
            connectionStage = "start agent through the Perl process-group launcher"
            try child.run()
            // The launcher creates a dedicated process group whose ID is its PID.
            // Keep the ID independently of Process.isRunning; descendants can
            // outlive the leader and still belong to this group.
            processGroupID = child.processIdentifier
            processLeaderWasReaped = false
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? errorOutput.fileHandleForWriting.close()
            process = child
            stderrPipe = errorOutput
            stderrDrainTask = Task.detached(
                executorPreference: BlockingIOTaskExecutor(label: "me.atkn.gnostic.acp.stderr")
            ) { [readHandle = errorOutput.fileHandleForReading, secrets = launchSpec.environment.values] in
                await Self.drainStderr(readHandle, redacting: Array(secrets))
            }
            let processTransport = ACPProcessStdioTransport(
                input: output.fileHandleForReading,
                output: input.fileHandleForWriting,
                onSessionUpdate: { [weak self, updateRouter] sessionID, update in
                    guard let self else { return }
                    if try await self.recordRawSessionUpdate(sessionID: sessionID, update: update) {
                        updateRouter.enqueue(sessionID: sessionID, update)
                    }
                },
                onFailure: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.lifecycleFailure = AscendantBackendLifecycleFailure(
                            code: "acpTransportUnusable",
                            message: "The ACP process transport stopped unexpectedly."
                        )
                    }
                }
            )
            let protocolConnection = ACPProtocolLayer(transport: processTransport, defaultTimeoutSeconds: protocolTimeoutSeconds)
            await protocolConnection.onRequest(method: ACPv2Protocol.ClientMethod.sessionRequestPermission) { [weak self] request in
                guard let self else {
                    let outcome = ACPRequestPermissionResponse(outcome: .cancelled)
                    let data = try JSONEncoder().encode(outcome)
                    let val = try JSONDecoder().decode(ACPValue.self, from: data)
                    return ACPJSONRPCResponse(id: request.id, result: val)
                }
                return try await self.handlePermissionRequest(request)
            }
            connection = protocolConnection
            self.transport = processTransport
            self.connection = protocolConnection
            connectionStage = "start ACP transport"
            try await protocolConnection.start()
            let initialize = ACPInitializeRequest(
                protocolVersion: ACPv2Protocol.protocolVersion,
                info: ACPImplementation(name: "Gnostic", version: "0.5.0"),
                capabilities: ACPClientCapabilities()
            )
            connectionStage = "initialize ACP agent"
            let response = try await protocolConnection.initialize(request: initialize)
            guard response.protocolVersion == ACPv2Protocol.protocolVersion else {
                let failure = AscendantBackendLifecycleFailure(
                    code: "acpProtocolVersionMismatch",
                    message: "The ACP Runtime negotiated protocol version \(response.protocolVersion); Gnostic requires version \(ACPv2Protocol.protocolVersion)."
                )
                lifecycleFailure = failure
                throw AscendantBackendError.lifecycleUnusable(failure)
            }
            sessionCapabilities = response.capabilities?.session
            runtimeInstanceObject = GnosticRuntimeInstanceObject(
                id: identity.id,
                name: launchSpec.displayName ?? response.info.name,
                kind: "local-command",
                version: response.info.version,
                launchFingerprint: launchSpec.launchFingerprint,
                health: .healthy,
                rawCapabilities: response.rawCapabilities ?? [:]
            )
            return protocolConnection
        } catch {
            let failure: AscendantBackendError
            if connectionStage == "initialize ACP agent", Self.isProtocolVersionNegotiationFailure(error) {
                let lifecycle = AscendantBackendLifecycleFailure(
                    code: "acpProtocolVersionMismatch",
                    message: "The ACP Runtime refused Gnostic's required protocol version \(ACPv2Protocol.protocolVersion)."
                )
                lifecycleFailure = lifecycle
                failure = .lifecycleUnusable(lifecycle)
            } else if !child.isRunning {
                let lifecycle = AscendantBackendLifecycleFailure(
                    code: "acpTransportUnusable",
                    message: "Could not connect to the configured ACP agent process while attempting to \(connectionStage)."
                )
                lifecycleFailure = lifecycle
                failure = .lifecycleUnusable(lifecycle)
            } else {
                failure = map(error, context: "Could not initialize the ACP agent")
            }
            if processGroupID != nil, !isShuttingDown {
                await stopProcess(child, processGroupID: processGroupID)
            }
            await connection?.close()
            self.connection = nil
            self.transport = nil
            process = nil
            processGroupID = nil
            processLeaderWasReaped = false
            try? errorOutput.fileHandleForReading.close()
            stderrPipe = nil
            if let stderrDrainTask { await stderrDrainTask.value }
            stderrDrainTask = nil
            throw failure
        }
    }

    private func requireSession(for timelineID: UUID, connection: ACPProtocolLayer) async throws -> String {
        let project = projects[timelineID] ?? .scratch
        let desired = try resolvedProject(for: timelineID, project: project)

        if sessionStates[timelineID] == .ambiguous {
            throw AscendantBackendError.terminal(.init(
                code: "acpSessionRecoveryAmbiguous",
                message: "The ACP Runtime could not confirm whether the previous Session survived. This Timeline is blocked to avoid losing or duplicating Runtime context."
            ))
        }
        if let sessionID = sessionIDs[timelineID],
           sessionCwds[timelineID] == desired.cwd {
            if sessionProjectKinds[timelineID] != desired.kind || sessionStartedAt[timelineID] == nil {
                sessionProjectKinds[timelineID] = desired.kind
                sessionStartedAt[timelineID] = sessionStartedAt[timelineID] ?? Date()
                try persistSessionMap()
            }
            if activeSessionIDs.contains(timelineID) { return sessionID }
            guard sessionCapabilities?.supportsResume == true else {
                throw AscendantBackendError.terminal(.init(
                    code: "acpSessionResumeUnavailable",
                    message: "The ACP agent cannot resume the session for Timeline \(timelineID.uuidString)."
                ))
            }
            try Task.checkCancellation()
            let mcpServers = try mcpServers(for: timelineID)
            let resumeRequest = ACPResumeSessionRequest(
                sessionId: sessionID,
                cwd: desired.cwd,
                mcpServers: mcpServers
            )
            // Commit uncertainty before dispatch. If the Node exits after the
            // Runtime receives this request but before its response arrives,
            // recovery must not retry the operation or issue a new prompt.
            try await recordSessionState(.ambiguous, sessionID: sessionID, timelineID: timelineID, project: desired)
            do {
                _ = try await connection.resumeSession(request: resumeRequest)
            } catch {
                // ACP v2 does not define a missing-session error. No failed
                // resume response proves that the Runtime lost this Session.
                if Task.isCancelled { throw AscendantBackendError.cancelled }
                throw AscendantBackendError.terminal(.init(
                    code: "acpSessionRecoveryAmbiguous",
                    message: "The ACP Runtime could not confirm whether the previous Session survived. This Timeline is blocked to avoid losing or duplicating Runtime context."
                ))
            }
            try await recordSessionState(.live, sessionID: sessionID, timelineID: timelineID, project: desired)
            try Task.checkCancellation()
            activeSessionIDs.insert(timelineID)
            try persistSessionMap()
            return sessionID
        }

        if sessionIDs[timelineID] != nil {
            try await closeAndRetireSession(for: timelineID, using: connection)
        }
        return try await createSession(for: timelineID, project: desired, using: connection)
    }

    private func recordSessionState(
        _ state: TimelineJournalSessionState,
        sessionID: String,
        timelineID: UUID,
        project: ResolvedProject
    ) async throws {
        try await timelineJournalRecorder?.appendSessionTransition(
            timelineID: timelineID,
            sessionID: sessionID,
            runtimeInstanceID: identity.id,
            state: state,
            projectKind: project.kind,
            cwd: project.cwd
        )
        sessionStates[timelineID] = state
    }

    private func recordRawSessionUpdate(sessionID: String, update: ACPSessionUpdate) async throws -> Bool {
        guard timelineJournalRecorder != nil else { return true }
        if bindingTimelineIDsBySessionID[sessionID] != nil ||
            (timelineIDsBySessionID[sessionID] == nil && pendingSessionCreations > 0) {
            let queuedCount = pendingSessionUpdates.values.reduce(0) { $0 + $1.count }
            guard queuedCount < 1_024 else {
                throw TimelineJournalError.invalidPayload("Too many ACP updates arrived before a Session binding")
            }
            pendingSessionUpdates[sessionID, default: []].append(update)
            return false
        }
        try await recordBoundSessionUpdate(sessionID: sessionID, update: update)
        return true
    }

    private func recordBoundSessionUpdate(sessionID: String, update: ACPSessionUpdate) async throws {
        guard let timelineJournalRecorder else { return }
        guard let timelineID = timelineIDsBySessionID[sessionID] else {
            throw TimelineJournalError.invalidPayload("ACP update references an unknown or duplicate Session ID")
        }
        if let activeTurn = activeTurns[timelineID], activeTurn.sessionID == sessionID {
            let terminalOutcome: TurnTerminalOutcome?
            if case let .stateUpdate(state) = update, state.isIdle {
                terminalOutcome = .from(stopReason: state.idleStopReason)
            } else {
                terminalOutcome = nil
            }
            try await timelineJournalRecorder.appendTurnUpdate(
                sessionID: sessionID,
                update: TurnSessionUpdate(
                    timelineID: timelineID,
                    clientTurnID: activeTurn.clientTurnID,
                    sequence: activeTurn.nextTimelineUpdateSequence(),
                    update: update,
                    terminal: terminalOutcome != nil,
                    terminalOutcome: terminalOutcome
                )
            )
        } else {
            try await timelineJournalRecorder.appendRawACPUpdate(
                timelineID: timelineID,
                sessionID: sessionID,
                clientTurnID: nil,
                update: update
            )
        }
    }

    private func resolvedProject(for timelineID: UUID, project: Project) throws -> ResolvedProject {
        if project.kind == .scratch,
           let storedCWD = sessionCwds[timelineID],
           sessionProjectKinds[timelineID] != .local,
           projectResolver.isUsableDirectory(storedCWD) {
            // A scratch Session keeps its directory across Runtime restarts.
            // Missing kind is an older record; preserve its original cwd once.
            return ResolvedProject(
                kind: .scratch,
                cwd: storedCWD,
                scratchRoot: projectResolver.isManagedScratchDirectory(storedCWD)
                    ? projectResolver.scratchRoot.standardizedFileURL.path
                    : nil
            )
        }
        return try projectResolver.resolve(project)
    }

    private func createSession(
        for timelineID: UUID,
        project: ResolvedProject,
        using connection: ACPProtocolLayer
    ) async throws -> String {
        pendingSessionCreations += 1
        defer { pendingSessionCreations -= 1 }
        let response: ACPNewSessionResponse
        do {
            response = try await connection.createSession(request: ACPNewSessionRequest(
                cwd: project.cwd,
                mcpServers: try mcpServers(for: timelineID)
            ))
        } catch {
            if project.isManagedScratch { try? projectResolver.discard(project) }
            throw error
        }
        if let existingTimelineID = timelineIDsBySessionID[response.sessionId] ?? bindingTimelineIDsBySessionID[response.sessionId],
           existingTimelineID != timelineID {
            if sessionCapabilities?.supportsClose == true {
                _ = try? await connection.closeSession(request: ACPCloseSessionRequest(sessionId: response.sessionId))
            }
            if project.isManagedScratch { try? projectResolver.discard(project) }
            throw Self.invalidConfiguration("An ACP Session ID cannot serve more than one Timeline.")
        }
        bindingTimelineIDsBySessionID[response.sessionId] = timelineID
        defer {
            bindingTimelineIDsBySessionID.removeValue(forKey: response.sessionId)
            pendingSessionUpdates.removeValue(forKey: response.sessionId)
        }
        do {
            try await timelineJournalRecorder?.appendSessionTransition(
                timelineID: timelineID,
                sessionID: response.sessionId,
                runtimeInstanceID: identity.id,
                state: .live,
                projectKind: project.kind,
                cwd: project.cwd
            )
        } catch {
            if sessionCapabilities?.supportsClose == true {
                _ = try? await connection.closeSession(request: ACPCloseSessionRequest(sessionId: response.sessionId))
            }
            if project.isManagedScratch { try? projectResolver.discard(project) }
            throw error
        }
        sessionIDs[timelineID] = response.sessionId
        sessionStates[timelineID] = .live
        timelineIDsBySessionID[response.sessionId] = timelineID
        sessionCwds[timelineID] = project.cwd
        sessionProjectKinds[timelineID] = project.kind
        sessionStartedAt[timelineID] = Date()
        activeSessionIDs.insert(timelineID)
        do {
            try persistSessionMap()
        } catch {
            // Do not retain an unrecorded Session mapping. The remote ACP
            // session may remain until process cleanup, but this Timeline will
            // not falsely resume it after a restart.
            sessionIDs.removeValue(forKey: timelineID)
            sessionStates.removeValue(forKey: timelineID)
            sessionCwds.removeValue(forKey: timelineID)
            sessionProjectKinds.removeValue(forKey: timelineID)
            sessionStartedAt.removeValue(forKey: timelineID)
            activeSessionIDs.remove(timelineID)
            if project.isManagedScratch { try? projectResolver.discard(project) }
            throw error
        }
        // The transport can read adjacent response/update frames while this
        // actor awaits the durable transition. Drain those updates in order
        // before allowing new updates to bypass the binding queue.
        while let queued = pendingSessionUpdates.removeValue(forKey: response.sessionId) {
            for update in queued {
                try await recordBoundSessionUpdate(sessionID: response.sessionId, update: update)
                updateRouter.enqueue(sessionID: response.sessionId, update)
            }
        }
        if pendingSessionCreations == 1 && !pendingSessionUpdates.isEmpty {
            throw TimelineJournalError.invalidPayload("ACP update references an unknown Session ID")
        }
        return response.sessionId
    }

    private func mcpServers(for timelineID: UUID) throws -> [ACPMcpServer] {
        guard sessionCapabilities?.mcp?.http != nil,
              let workspaceService else { return [] }
        let gateway: WorkspaceMCPGateway
        if let existing = workspaceGateways[timelineID] {
            gateway = existing
        } else {
            gateway = WorkspaceMCPGateway(
                timelineID: timelineID,
                timelineRegistry: timelineRegistry,
                workspaceService: workspaceService,
                permissionService: permissionService,
                timelineJournalRecorder: timelineJournalRecorder,
                activeTurn: { [weak self] id in
                    guard let turn = self?.activeTurns[id] else { return nil }
                    return (turn.clientTurnID, turn.sessionID)
                }
            )
            workspaceGateways[timelineID] = gateway
        }
        return [try gateway.start()]
    }

    private func closeAndRetireSession(for timelineID: UUID, using connection: ACPProtocolLayer) async throws {
        workspaceGateways.removeValue(forKey: timelineID)?.stop()
        var sessionClosed = false
        let sessionID = sessionIDs[timelineID]
        if let sessionID, sessionCapabilities?.supportsClose == true {
            do {
                _ = try await connection.closeSession(request: ACPCloseSessionRequest(sessionId: sessionID))
                sessionClosed = true
            }
            catch { /* A cwd transition is independent of best-effort close. */ }
        }
        if let sessionID, let cwd = sessionCwds[timelineID] {
            try await timelineJournalRecorder?.appendSessionTransition(
                timelineID: timelineID,
                sessionID: sessionID,
                runtimeInstanceID: identity.id,
                state: sessionClosed ? .lost : (sessionCapabilities?.supportsResume == true ? .resumable : .ambiguous),
                projectKind: sessionProjectKinds[timelineID],
                cwd: cwd
            )
            sessionStates[timelineID] = sessionClosed ? .lost : (sessionCapabilities?.supportsResume == true ? .resumable : .ambiguous)
        }
        let cwd = sessionCwds.removeValue(forKey: timelineID)
        let kind = sessionProjectKinds.removeValue(forKey: timelineID)
        sessionIDs.removeValue(forKey: timelineID)
        sessionStartedAt.removeValue(forKey: timelineID)
        activeSessionIDs.remove(timelineID)
        if sessionClosed, let cwd, kind == .scratch {
            try? projectResolver.discard(.init(
                kind: .scratch,
                cwd: cwd,
                scratchRoot: projectResolver.scratchRoot.standardizedFileURL.path
            ))
        }
        try? persistSessionMap()
    }

    private func handlePermissionRequest(_ request: ACPJSONRPCRequest) async throws -> ACPJSONRPCResponse {
        guard let params = request.params,
              let data = try? JSONEncoder().encode(params),
              let permissionRequest = try? JSONDecoder().decode(ACPRequestPermissionRequest.self, from: data) else {
            Self.recordPermissionFailure("malformed request", requestID: String(describing: request.id))
            return try Self.permissionResponse(for: .cancelled, requestId: request.id)
        }

        let sessionID = permissionRequest.sessionId
        let toolCall: ACPToolCallUpdate? = {
            guard case let .toolCall(toolCall)? = permissionRequest.subject else { return nil }
            return toolCall
        }()
        let toolCallID = toolCall?.toolCallId ?? "acp-\(request.id)"
        let title = toolCall?.title ?? toolCall?.name ?? permissionRequest.title
        guard let timelineID = sessionIDs.first(where: { $0.value == sessionID })?.key,
              let activeTurn = activeTurns[timelineID] else {
            Self.recordPermissionFailure(
                "request has no active Turn",
                requestID: String(describing: request.id),
                sessionID: sessionID,
                toolCallID: toolCallID,
                title: title
            )
            return try Self.permissionResponse(for: .cancelled, requestId: request.id)
        }
        guard !activeTurn.isCancelled else {
            return try Self.permissionResponse(for: .cancelled, requestId: request.id)
        }

        guard let selection = Self.permissionSelection(for: permissionRequest.options) else {
            Self.recordPermissionFailure(
                "unsupported permission options",
                requestID: String(describing: request.id),
                sessionID: sessionID,
                timelineID: timelineID,
                clientTurnID: activeTurn.clientTurnID,
                toolCallID: toolCallID,
                title: title,
                options: permissionRequest.options.map { "\($0.optionId):\($0.kind)" }
            )
            return try Self.permissionResponse(for: .cancelled, requestId: request.id)
        }

        let permissionService = self.permissionService
        let backendPermissionRequest = BackendPermissionRequest(
            correlationID: "acp-\(request.id)",
            timelineID: timelineID,
            clientTurnID: activeTurn.clientTurnID,
            toolCallID: toolCallID,
            title: title
        )
        let decision = await activeTurn.requestPermission {
            await permissionService.requestApproval(for: backendPermissionRequest)
        }
        guard !activeTurn.isCancelled else {
            return try Self.permissionResponse(for: .cancelled, requestId: request.id)
        }
        let recordedDecision: String
        switch decision {
        case .approved: recordedDecision = "approved"
        case .denied: recordedDecision = "denied"
        case .unavailable: recordedDecision = "unavailable"
        }
        do {
            try await timelineJournalRecorder?.appendPermissionDecision(
                timelineID: timelineID, clientTurnID: activeTurn.clientTurnID,
                correlationID: backendPermissionRequest.correlationID,
                decision: recordedDecision, approved: decision.isApproved
            )
        } catch {
            return try Self.permissionResponse(for: .cancelled, requestId: request.id)
        }
        guard !activeTurn.isCancelled else {
            return try Self.permissionResponse(for: .cancelled, requestId: request.id)
        }
        switch decision {
        case .approved:
            return try Self.permissionResponse(for: .selected(selection.allow), requestId: request.id)
        case .denied:
            return try Self.permissionResponse(for: .selected(selection.reject), requestId: request.id)
        case let .unavailable(reason):
            Self.recordPermissionFailure(
                "permission mediation unavailable: \(reason)",
                requestID: String(describing: request.id),
                sessionID: sessionID,
                timelineID: timelineID,
                clientTurnID: activeTurn.clientTurnID,
                toolCallID: toolCallID,
                title: title
            )
            return try Self.permissionResponse(for: .cancelled, requestId: request.id)
        }
    }

    /// Maps a recognized ACP permission option set to the option Gnostic selects
    /// for an approved or denied decision.
    ///
    /// Two sets are in contract: the ACP allow-once/reject-once pair, and the
    /// broader `allow_always`/`allow`/`reject` set the Claude Agent adapter
    /// advertises. Approval selects the narrowest offered allow option
    /// (`allow_once`, else `allow`) and never the persistent `allow_always`
    /// option; denial selects `reject_once`, else `reject`. Any other set fails
    /// closed, so an unknown or out-of-contract advertisement never reaches the
    /// permission service.
    private nonisolated static func permissionSelection(
        for options: [ACPPermissionOption]
    ) -> (allow: String, reject: String)? {
        let optionIds = options.map(\.optionId)
        guard Set(optionIds).count == optionIds.count else { return nil }
        let allowOnce = options.first { $0.kind == "allow_once" }
        let rejectOnce = options.first { $0.kind == "reject_once" }
        let allow = options.first { $0.kind == "allow" }
        let reject = options.first { $0.kind == "reject" }
        let allowAlwaysCount = options.filter { $0.kind == "allow_always" }.count
        let rejectAlwaysCount = options.filter { $0.kind == "reject_always" }.count
        let isAllowOnceSet = options.count == 2
            && allowOnce != nil
            && rejectOnce != nil
            && allow == nil
            && reject == nil
            && allowAlwaysCount == 0
            && rejectAlwaysCount == 0
        let isClaudeSet = options.count == 3
            && allowAlwaysCount == 1
            && allow != nil
            && reject != nil
            && allowOnce == nil
            && rejectOnce == nil
            && rejectAlwaysCount == 0
        guard isAllowOnceSet || isClaudeSet else { return nil }
        let selectedAllow = isAllowOnceSet ? allowOnce : allow
        let selectedReject = isAllowOnceSet ? rejectOnce : reject
        guard let selectedAllow, let selectedReject else { return nil }
        return (allow: selectedAllow.optionId, reject: selectedReject.optionId)
    }

    private nonisolated static func permissionResponse(
        for outcome: ACPRequestPermissionOutcome,
        requestId: ACPRequestId
    ) throws -> ACPJSONRPCResponse {
        let data = try JSONEncoder().encode(ACPRequestPermissionResponse(outcome: outcome))
        let val = try JSONDecoder().decode(ACPValue.self, from: data)
        return ACPJSONRPCResponse(id: requestId, result: val)
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
        BrokenPipeSignal.writeToStandardError(Data(message.utf8))
    }

    /// Backfills configured Gnostic Timelines as an explicit startup-hydration
    /// step before intersecting them with an agent's advertised session list.
    private func ensureSessions(for timelineIDs: [UUID], using connection: ACPProtocolLayer) async throws {
        for id in timelineIDs {
            let project = projects[id] ?? .scratch
            let resolved = try resolvedProject(for: id, project: project)
            if sessionIDs[id] != nil, sessionCwds[id] == resolved.cwd {
                if sessionProjectKinds[id] != resolved.kind || sessionStartedAt[id] == nil {
                    sessionProjectKinds[id] = resolved.kind
                    sessionStartedAt[id] = sessionStartedAt[id] ?? Date()
                    try persistSessionMap()
                }
                continue
            }
            if sessionIDs[id] != nil {
                try? await closeAndRetireSession(for: id, using: connection)
            }
            _ = try await createSession(for: id, project: resolved, using: connection)
        }
    }

    private func restoreSessionBindingsFromJournal(for timelineIDs: [UUID]) async throws {
        guard !journalSessionBindingsRestored,
              let timelineJournalRecorder else { return }

        var restored: [(timelineID: UUID, projection: TimelineJournalSessionProjection)] = []
        var sessionOwners: [String: UUID] = [:]
        for timelineID in timelineIDs {
            guard let timeline = try await timelineJournalRecorder.timelineProjection(for: timelineID) else { continue }
            if !explicitProjectIDs.contains(timelineID), let project = timeline.project {
                projects[timelineID] = project
            }
            guard let projection = timeline.latestSession else { continue }
            guard projection.runtimeInstanceID == identity.id else {
                throw Self.invalidConfiguration(
                    "The Timeline journal Session for \(timelineID.uuidString) belongs to another Runtime instance."
                )
            }
            guard projection.state != .lost else { continue }
            if let otherTimelineID = sessionOwners[projection.sessionID], otherTimelineID != timelineID {
                throw Self.invalidConfiguration("A journaled ACP Session ID belongs to more than one Timeline.")
            }
            sessionOwners[projection.sessionID] = timelineID
            restored.append((timelineID, projection))
        }

        for (timelineID, projection) in restored {
            sessionStates[timelineID] = projection.state
            sessionIDs[timelineID] = projection.sessionID
            timelineIDsBySessionID[projection.sessionID] = timelineID
            sessionCwds[timelineID] = projection.cwd
            sessionProjectKinds[timelineID] = projection.projectKind ?? (projects[timelineID] ?? .scratch).kind
            sessionStartedAt[timelineID] = projection.startedAt
            activeSessionIDs.remove(timelineID)
        }
        journalSessionBindingsRestored = true
    }

    private func stopProcess(_ process: Process, processGroupID: pid_t?) async {
        guard let processGroupID, processGroupID > 1 else {
            if isProcessLeaderRunning(process) { process.terminate() }
            if !processLeaderWasReaped { process.waitUntilExit() }
            return
        }

        let leaderIsRunning = isProcessLeaderRunning(process)
        guard processGroupSignalability(processGroupID) == .available else {
            if leaderIsRunning,
               getpgid(process.processIdentifier) == processGroupID {
                process.terminate()
                if !processLeaderWasReaped { process.waitUntilExit() }
            } else if !processLeaderWasReaped {
                process.waitUntilExit()
            }
            return
        }

        let gracefulExit = ProcessExitWaiter()
        if leaderIsRunning {
            process.terminationHandler = { _ in gracefulExit.complete(true) }
        }
        _ = signalProcessGroup(processGroupID, SIGTERM)

        guard leaderIsRunning else {
            if !processLeaderWasReaped { process.waitUntilExit() }
            if await waitForProcessGroupExit(processGroupID, timeoutNanoseconds: 1_000_000_000) { return }
            _ = signalProcessGroup(processGroupID, SIGKILL)
            _ = await waitForProcessGroupExit(processGroupID, timeoutNanoseconds: 1_000_000_000)
            return
        }

        if await gracefulExit.wait(timeoutNanoseconds: 1_000_000_000) {
            if !processLeaderWasReaped { process.waitUntilExit() }
            if await waitForProcessGroupExit(processGroupID, timeoutNanoseconds: 1_000_000_000) { return }
        }

        let forcedExit = ProcessExitWaiter()
        let leaderStillRunning = isProcessLeaderRunning(process)
        if leaderStillRunning {
            process.terminationHandler = { _ in forcedExit.complete(true) }
        }
        _ = signalProcessGroup(processGroupID, SIGKILL)
        if !leaderStillRunning || processGroupSignalability(processGroupID) == .gone {
            forcedExit.complete(true)
        } else {
            _ = await forcedExit.wait(timeoutNanoseconds: 1_000_000_000)
        }
        if !processLeaderWasReaped { process.waitUntilExit() }
        _ = await waitForProcessGroupExit(processGroupID, timeoutNanoseconds: 1_000_000_000)
    }

    private func isProcessLeaderRunning(_ process: Process) -> Bool {
        guard process.isRunning, !processLeaderWasReaped else { return false }
        // Foundation.Process may keep `isRunning` stale until its child is
        // reaped. Probe with WNOHANG so retirement observes an exited leader
        // without blocking while descendants remain in the process group.
        var status: Int32 = 0
        let result = waitpid(process.processIdentifier, &status, WNOHANG)
        if result == process.processIdentifier || (result == -1 && errno == ECHILD) {
            processLeaderWasReaped = true
            return false
        }
        return true
    }

    private func processGroupSignalability(_ processGroupID: pid_t) -> ProcessGroupSignalability {
        guard kill(-processGroupID, 0) != 0 else { return .available }
        switch errno {
        case ESRCH: return .gone
        case EPERM: return .inaccessible
        default: return .failed
        }
    }

    private func signalProcessGroup(_ processGroupID: pid_t, _ signal: Int32) -> Bool {
        guard processGroupSignalability(processGroupID) == .available else { return false }
        return kill(-processGroupID, signal) == 0
    }

    private func waitForProcessGroupExit(_ processGroupID: pid_t, timeoutNanoseconds: UInt64) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while true {
            switch processGroupSignalability(processGroupID) {
            case .gone:
                return true
            case .inaccessible, .failed:
                return false
            case .available:
                break
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func map(_ error: any Error, context: String) -> AscendantBackendError {
        if let projectError = error as? ProjectPlacementError {
            return .terminal(.init(
                code: "projectUnavailable",
                message: redact(projectError.localizedDescription)
            ))
        }
        if let projectError = error as? ProjectValidationError {
            return .terminal(.init(
                code: "projectUnavailable",
                message: redact(projectError.localizedDescription)
            ))
        }
        if let backendError = error as? AscendantBackendError {
            if case let .terminal(failure) = backendError {
                return .terminal(.init(code: failure.code, message: redact(failure.message)))
            }
            return backendError
        }
        if let transportError = error as? ACPTransportError {
            switch transportError {
            case .transportClosed:
                let failure = AscendantBackendLifecycleFailure(
                    code: "acpTransportUnusable",
                    message: "The ACP connection closed while handling a request."
                )
                lifecycleFailure = failure
                return .lifecycleUnusable(failure)
            case .timeout:
                let failure = AscendantBackendLifecycleFailure(
                    code: "acpTransportUnusable",
                    message: "The ACP connection timed out while handling a request."
                )
                lifecycleFailure = failure
                return .lifecycleUnusable(failure)
            default:
                break
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
        return .terminal(.init(
            code: "acpAgentFailure",
            message: redact("\(context): \(Self.describe(error))")
        ))
    }

    private nonisolated static func isProtocolVersionNegotiationFailure(_ error: any Error) -> Bool {
        guard let error = error as? ACPError else { return false }
        switch error {
        case .unsupportedProtocolVersion:
            return true
        case let .invalidRequest(message), let .invalidParams(message):
            return message.localizedCaseInsensitiveContains("protocol version")
        case let .custom(code, message, _):
            return code == ACPv2Protocol.ErrorCode.unsupportedProtocolVersion
                || message.localizedCaseInsensitiveContains("protocol version")
        default:
            return false
        }
    }

    /// Describes a failed agent request for the operator.
    ///
    /// An ACP v2 agent reports a failed request with a JSON-RPC error whose
    /// message is generic and whose `data.details` field carries the agent's
    /// own text. The agent's text is the actionable part, so it belongs in the
    /// terminal failure message.
    private nonisolated static func describe(_ error: any Error) -> String {
        guard case let .custom(_, message, data) = error as? ACPError else {
            return error.localizedDescription
        }
        guard case let .object(fields) = data, case let .string(details)? = fields["details"] else {
            return message
        }
        return "\(message): \(details)"
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
                if !finalOutput.isEmpty { BrokenPipeSignal.writeToStandardError(finalOutput) }
                return
            }
            let safeOutput = redactor.consume(data)
            if !safeOutput.isEmpty { BrokenPipeSignal.writeToStandardError(safeOutput) }
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
        guard timelineJournalRecorder == nil else { return }
        try FileManager.default.createDirectory(at: sessionMapURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let values = Dictionary(uniqueKeysWithValues: sessionIDs.map { id, sessionID in
            let timeline = timelineRegistry.projection(id: id)
            return (id.uuidString, ACPStoredTimelineSession(
                sessionID: sessionID,
                title: timeline?.title ?? "Timeline",
                createdAt: timeline?.createdAt ?? Date(),
                updatedAt: timeline?.updatedAt ?? Date(),
                isPrivate: timeline?.isPrivate ?? false,
                cwd: sessionCwds[id],
                projectKind: sessionProjectKinds[id],
                startedAt: sessionStartedAt[id]
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

    private struct ForwardOutcome: Sendable {
        var text: String
        /// Whether the agent reported an idle state, which ends the Turn.
        ///
        /// An idle update ends the foreground work even when the agent
        /// reports no stop reason, so the idle and its stop reason are
        /// tracked separately.
        var idleReported: Bool
        var stopReason: ACPStopReason?
        var error: (any Error)?
    }

    private nonisolated static func forward(
        _ events: AsyncStream<ACPSessionUpdate>,
        to sink: any AscendantBackendUpdateSink,
        activeTurn: ACPActiveTurn
    ) async -> ForwardOutcome {
        var assistantText = ""
        var appendError: (any Error)?
        var seenToolCalls: Set<String> = []
        for await event in events {
            if case let .stateUpdate(state) = event, state.isIdle {
                return ForwardOutcome(
                    text: assistantText,
                    idleReported: true,
                    stopReason: state.idleStopReason,
                    error: appendError
                )
            }
            // A cancelled Turn ends on `idle` or at its bound. A trailing update
            // does neither: the Runtime has not stopped, and its later `idle`
            // must not reach the next Turn.
            guard appendError == nil, await !activeTurn.isTurnCancelled else { continue }
            guard let update = backendUpdate(
                for: event,
                assistantText: &assistantText,
                seenToolCalls: &seenToolCalls
            ) else { continue }
            do {
                try await sink.append(update)
            } catch {
                appendError = error
            }
        }
        return ForwardOutcome(text: assistantText, idleReported: false, stopReason: nil, error: appendError)
    }

    private nonisolated static func backendUpdate(
        for event: ACPSessionUpdate,
        assistantText: inout String,
        seenToolCalls: inout Set<String>
    ) -> AscendantBackendUpdate? {
        switch event {
        case .agentMessageChunk(let chunk):
            guard case let .text(text) = chunk.content else { return nil }
            assistantText += text.text
            return .init(kind: .assistantText, text: text.text)
        case .agentMessage(let message):
            // A whole-message update is an upsert: it replaces the text
            // accumulated for that message, so it does not append.
            let text = messageText(in: message.content)
            guard !text.isEmpty else { return nil }
            assistantText = text
            return .init(kind: .assistantText, text: text)
        case .toolCallUpdate(let toolCall):
            let isInitial = seenToolCalls.insert(toolCall.toolCallId).inserted
            return .init(
                kind: isInitial ? .toolCall : .toolState,
                toolState: .init(
                    toolCallID: toolCall.toolCallId,
                    title: toolCall.title ?? toolCall.name,
                    status: toolStatus(toolCall.status, fallback: isInitial ? .pending : .inProgress),
                    content: toolContent(toolCall.rawOutput)
                )
            )
        default:
            return nil
        }
    }

    /// The text of a whole message, with the text blocks concatenated.
    private nonisolated static func messageText(in content: [ACPContentBlock]?) -> String {
        guard let content else { return "" }
        var text = ""
        for block in content {
            if case let .text(textContent) = block {
                text += textContent.text
            }
        }
        return text
    }

    private nonisolated static func toolStatus(
        _ status: String?,
        fallback: TurnToolStatus
    ) -> TurnToolStatus {
        switch status {
        case "pending": .pending
        case "inProgress", "in_progress": .inProgress
        case "completed": .completed
        case "failed": .failed
        default: fallback
        }
    }

    private nonisolated static func toolContent(_ value: ACPValue?) -> String? {
        guard let value,
              let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

@MainActor
private final class ACPActiveTurn {
    let clientTurnID: String
    let sessionID: String
    private var timelineUpdateSequence = 0
    var isCancelled = false
    var isTurnCancelled = false
    /// Where the Turn's `session/prompt` stands. It decides how a cancel is sent.
    enum Insertion {
        case notDispatched
        /// The prompt was sent and its response has not arrived.
        case pending(ACPRequestId)
        /// The Runtime answered the prompt with success.
        case inserted
    }
    var insertion = Insertion.notDispatched
    /// The deadline that ends a cancelled Turn the Runtime does not settle.
    var cancellationDeadline: Task<Void, Never>?
    /// Set when that deadline expired on an inserted prompt.
    var cancellationFailure: AscendantBackendLifecycleFailure?
    var isFinished = false
    private var sessionCancelSent = false
    private var hasExtendedBound = false
    private var permissionContinuations: [UUID: CheckedContinuation<AscendantPermissionDecision, Never>] = [:]
    private var permissionTasks: [UUID: Task<Void, Never>] = [:]

    init(clientTurnID: String, sessionID: String) {
        self.clientTurnID = clientTurnID
        self.sessionID = sessionID
    }

    /// Records that the prompt request is on the wire. Returns whether a cancel
    /// is already waiting for the request ID, so the caller sends it now.
    func promptSent(_ requestID: ACPRequestId) -> Bool {
        guard case .notDispatched = insertion else { return false }
        insertion = .pending(requestID)
        return isTurnCancelled
    }

    /// Starts the Turn's cancellation. Returns the insertion state at that
    /// moment, or `nil` when the Turn is already cancelled.
    func beginCancellation() -> Insertion? {
        guard !isTurnCancelled else { return nil }
        let insertion = insertion
        cancelTurn()
        return insertion
    }

    /// Claims the one `session/cancel` a Turn sends.
    func claimSessionCancel() -> Bool {
        guard !sessionCancelSent else { return false }
        sessionCancelSent = true
        return true
    }

    /// Whether an expired bound may wait once more for `session/cancel` to go
    /// out. It may when none was sent yet and no earlier bound waited for it.
    func extendBoundForSessionCancel() -> Bool {
        guard !sessionCancelSent, !hasExtendedBound else { return false }
        hasExtendedBound = true
        return true
    }

    func nextTimelineUpdateSequence() -> Int {
        timelineUpdateSequence += 1
        return timelineUpdateSequence
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
    /// Missing in pre-Project session maps.
    let cwd: String?
    /// Missing in pre-Project session maps.
    let projectKind: Project.Kind?
    /// Missing in pre-Project session maps.
    let startedAt: Date?
}



private enum ProcessGroupSignalability: Equatable {
    case available
    case gone
    case inaccessible
    case failed
}

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
    private var continuations: [String: AsyncStream<ACPSessionUpdate>.Continuation] = [:]

    func beginTurn(sessionID: String) -> AsyncStream<ACPSessionUpdate> {
        let (stream, continuation) = AsyncStream<ACPSessionUpdate>.makeStream()
        lock.lock()
        continuations.removeValue(forKey: sessionID)?.finish()
        continuations[sessionID] = continuation
        lock.unlock()
        return stream
    }

    func enqueue(sessionID: String, _ update: ACPSessionUpdate) {
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
