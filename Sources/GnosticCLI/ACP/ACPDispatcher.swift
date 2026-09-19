// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import PKContracts

/// Translates stable ACP v1 requests into Gnostic's existing remote object and
/// Timeline operations. ACP remains an adapter: no ACP identifiers are stored
/// in the Gnostic object advertisements.
@MainActor
final class ACPDispatcher: Sendable {
    /// The Ascendant this ACP process is pinned to.
    ///
    /// `providerID` is the serve process that currently answers for it and is
    /// re-resolved after an eviction. `nodeID` is the manifest identity that
    /// outlives every such process, so it is what a session binds to.
    private struct Ascendant {
        let id: UUID
        let name: String
        let timelineID: UUID
        let providerID: String
        let nodeID: UUID?
    }

    private struct ActivePrompt {
        let token: UUID
        // Async so session close/cancel can await the completion transition
        // instead of spawning an unowned `Task` hop. The pending prompt's
        // polling loop observes the transition before it unwinds.
        let close: () async -> Void
        let cancel: () async -> Void
    }

    private struct ActivePermissionRequest {
        let token: UUID
        let task: Task<AnyCodable, Error>
    }

    private let client: RemoteTurnClient
    private let registry: ACPSessionRegistry
    private let requestedAscendantID: UUID?
    private let requestedProviderID: String?
    private let requestedNodeID: UUID?
    private let publish: @Sendable (String, AnyCodable) -> Void
    private let requestPermission: @Sendable (AnyCodable) async throws -> AnyCodable
    private var ascendant: Ascendant?
    private var requestedPermissionIDs: Set<String> = []
    private var activePrompts: [String: ActivePrompt] = [:]
    private var activePermissionRequests: [String: ActivePermissionRequest] = [:]
    private var cancelledSessions: Set<String> = []

    init(
        client: RemoteTurnClient,
        registry: ACPSessionRegistry,
        requestedAscendantID: UUID?,
        requestedProviderID: String? = nil,
        requestedNodeID: UUID? = nil,
        publish: @escaping @Sendable (String, AnyCodable) -> Void,
        requestPermission: @escaping @Sendable (AnyCodable) async throws -> AnyCodable
    ) {
        self.client = client
        self.registry = registry
        self.requestedAscendantID = requestedAscendantID
        self.requestedProviderID = requestedProviderID
        self.requestedNodeID = requestedNodeID
        self.publish = publish
        self.requestPermission = requestPermission
    }

    func initialize() async throws -> AnyCodable {
        ascendant = try await resolveAscendant()
        return .dictionary([
            "protocolVersion": .integer(Int64(ACPProtocol.version)),
            "agentCapabilities": .dictionary([
                "loadSession": .boolean(false),
                "promptCapabilities": .dictionary([
                    "image": .boolean(false),
                    "audio": .boolean(false),
                    "embeddedContext": .boolean(false),
                ]),
                "sessionCapabilities": .dictionary([
                    "resume": .dictionary([:]),
                    "list": .dictionary([:]),
                    "close": .dictionary([:]),
                ]),
            ]),
            "agentInfo": .dictionary([
                "name": .string("gnostic-acp"),
                "title": .string("Gnostic ACP"),
                "version": .string("0.1.0"),
            ]),
        ])
    }

    func handle(_ request: JSONRPCRequest) async throws -> AnyCodable {
        do {
            return try await route(request)
        } catch let error as RemoteTurnClientError {
            if case .providerOffline = error {
                // The cached selection points at a provider that is gone. Drop
                // it so the next request re-resolves the Ascendant instead of
                // reusing the dead binding.
                ascendant = nil
            }
            throw error
        }
    }

    private func route(_ request: JSONRPCRequest) async throws -> AnyCodable {
        switch request.method {
        case "session/new":
            return try await newSession(request.params)
        case "session/resume":
            return try await resumeSession(request.params)
        case "session/list":
            return try await listSessions(request.params)
        case "session/close":
            return try await closeSession(request.params)
        case "session/cancel":
            return try await cancelSession(request.params)
        case "session/prompt":
            return try await prompt(request.params)
        case "session/load", "session/delete", "session/fork":
            throw JSONRPCMethodError.methodNotFound("\(request.method) is not advertised by gnostic acp")
        default:
            throw JSONRPCMethodError.methodNotFound(request.method)
        }
    }

    private func newSession(_ params: AnyCodable?) async throws -> AnyCodable {
        let input: ACPSessionParameters = try decode(params)
        let cwd = try canonicalCWD(input.cwd)
        try rejectMCP(input.mcpServers)
        let selected = try await currentAscendant()
        let status = try await client.createTimeline(
            title: "ACP \(URL(fileURLWithPath: cwd).lastPathComponent)",
            ascendantID: selected.id,
            providerID: selected.providerID
        )
        let record = try await registry.create(
            profileFingerprint: profileFingerprint(for: selected),
            ascendantID: selected.id,
            timelineID: status.timelineID,
            cwd: cwd,
            title: status.title,
            nodeID: selected.nodeID
        )
        return .dictionary([
            "sessionId": .string(record.id),
            "_meta": .dictionary(sessionMetadata(cwd: cwd, status: status).merging([
                "gnosticAscendantID": .string(selected.id.uuidString.lowercased()),
                "gnosticTimelineID": .string(record.timelineID.uuidString.lowercased()),
            ]) { _, new in new }),
        ])
    }

    private func resumeSession(_ params: AnyCodable?) async throws -> AnyCodable {
        let input: ACPResumeParameters = try decode(params)
        let cwd = try canonicalCWD(input.cwd)
        try rejectMCP(input.mcpServers)
        let record = try await knownSession(id: input.sessionID, cwd: cwd)
        do {
            try await requireBinding(of: record)
            let status = try await client.timelineStatus(timelineID: record.timelineID, providerID: try await boundProviderID(for: record))
            try await registry.touch(id: record.id)
            return .dictionary(["_meta": .dictionary(sessionMetadata(cwd: record.cwd, status: status))])
        } catch {
            throw await orphanAwareError(error, for: record)
        }
    }

    private func listSessions(_ params: AnyCodable?) async throws -> AnyCodable {
        let input: ACPListParameters = try decode(params ?? .dictionary([:]))
        let cwd = try input.cwd.map { try canonicalCWD($0) }
        let selected = try await currentAscendant()
        let records = await registry.list(cwd: cwd)
        var sessions: [AnyCodable] = []
        var unresolved: [ACPSessionRecord] = []
        // Registry entries survive process restarts, but a deleted remote
        // Timeline must not be presented as resumable. A closed record or one
        // bound to a different Node is omitted outright; a record whose
        // Timeline cannot be read is unresolved so ADR 0008 can end it once
        // absence is confirmed. The binding is namespace, Ascendant, and Node,
        // so a record created by an earlier serve of the same Node resolves.
        for record in records where record.closedAt == nil && isBound(record, to: selected) {
            guard let status = try? await client.timelineStatus(timelineID: record.timelineID, providerID: selected.providerID) else {
                unresolved.append(record)
                continue
            }
            sessions.append(.dictionary([
                "sessionId": .string(record.id),
                "cwd": .string(record.cwd),
                "title": .string(record.title),
                "updatedAt": .string(Self.iso8601(record.updatedAt)),
                "_meta": .dictionary(sessionMetadata(cwd: record.cwd, status: status)),
            ]))
        }
        // ADR 0008: keep the on-disk record for diagnostics and mark it ended
        // once the Timeline is confirmed absent, so a restarted ACP child stops
        // retrying. One discovery refresh serves the whole registry, and it
        // only runs when something failed to resolve, so a healthy list costs
        // nothing extra. A record left unresolved by an undiscoverable Node
        // stays open: provider liveness is the separate problem in #249.
        if !unresolved.isEmpty {
            let presence = await client.timelinePresenceSnapshot()
            for record in unresolved where presence.presence(of: record.timelineID) == .absent {
                _ = try? await registry.markEnded(id: record.id)
            }
        }
        return .dictionary(["sessions": .array(sessions)])
    }

    private func closeSession(_ params: AnyCodable?) async throws -> AnyCodable {
        let input: ACPCloseParameters = try decode(params)
        _ = try await requireSession(id: input.sessionID, cwd: nil)
        activePermissionRequests.removeValue(forKey: input.sessionID)?.task.cancel()
        await activePrompts.removeValue(forKey: input.sessionID)?.close()
        _ = try await registry.close(id: input.sessionID)
        return .dictionary([:])
    }

    private func cancelSession(_ params: AnyCodable?) async throws -> AnyCodable {
        let input: ACPCloseParameters = try decode(params)
        _ = try await requireSession(id: input.sessionID, cwd: nil)
        guard let prompt = activePrompts[input.sessionID] else { return .dictionary([:]) }
        cancelledSessions.insert(input.sessionID)
        activePermissionRequests.removeValue(forKey: input.sessionID)?.task.cancel()
        await prompt.cancel()
        return .dictionary([:])
    }

    private func prompt(_ params: AnyCodable?) async throws -> AnyCodable {
        let input: ACPPromptParameters = try decode(params)
        defer { cancelledSessions.remove(input.sessionID) }
        guard let text = input.text else {
            throw JSONRPCMethodError.invalidParams("session/prompt accepts non-empty text content only")
        }
        let record = try await knownSession(id: input.sessionID, cwd: nil)
        do {
            try await requireBinding(of: record)
        } catch {
            throw await orphanAwareError(error, for: record)
        }
        let turnID: String
        if let clientTurnID = input.clientTurnID {
            // ACP metadata may contain compatibility whitespace. Canonicalize
            // once, before live-update filtering, and reuse this value for the
            // request and every update or permission correlation.
            turnID = try GnosticWirePayload.canonicalClientTurnID(clientTurnID)
        } else {
            turnID = "acp:\(record.id):\(UUID().uuidString.lowercased())"
        }

        // A reconnect may retry a completed turn after the coordinator's
        // terminal-result cache has expired. The replay store is authoritative
        // for the bounded update stream, so consume it before attempting
        // admission and never risk a second Timeline mutation.
        if input.clientTurnID != nil,
           let existing = try? await client.replay(timelineID: record.timelineID, clientTurnID: turnID, message: text, providerID: try await boundProviderID(for: record)),
           existing.terminal {
            if existing.conflict {
                throw JSONRPCMethodError.invalidParams("clientTurnID was already used with different content")
            }
            if let error = existing.updates.last(where: \.isTerminalFailure) {
                throw JSONRPCMethodError.invalidState(error.text ?? "ACP turn did not complete")
            }
            for update in existing.updates {
                publishUpdate(
                    sessionID: record.id,
                    turnID: turnID,
                    update: update,
                    replayed: true
                )
            }
            return .dictionary(["stopReason": .string("end_turn")])
        }
        let resultAndSequence: (AscendantTurnResult, Int)
        do {
            resultAndSequence = try await streamPrompt(
                message: text,
                record: record,
                turnID: turnID
            )
        } catch {
            if cancelledSessions.contains(input.sessionID) {
                return .dictionary(["stopReason": .string("cancelled")])
            }
            throw await orphanAwareError(error, for: record)
        }
        if cancelledSessions.contains(input.sessionID) {
            return .dictionary(["stopReason": .string("cancelled")])
        }
        let (result, lastSequence) = resultAndSequence
        let replay = try? await client.replay(
            timelineID: record.timelineID,
            clientTurnID: turnID,
            message: text,
            afterSequence: lastSequence,
            providerID: try await boundProviderID(for: record)
        )
        let updates = replay?.updates ?? []
        if updates.isEmpty, lastSequence == 0 {
            publishUpdate(
                sessionID: record.id,
                turnID: turnID,
                update: AscendantTurnUpdate(sequence: 1, kind: .assistantText, text: result.text),
                replayed: result.replayed
            )
        } else {
            for update in updates {
                publishUpdate(
                    sessionID: record.id,
                    turnID: turnID,
                    update: update,
                    replayed: result.replayed
                )
            }
        }
        try await registry.touch(id: record.id)
        return .dictionary(["stopReason": .string("end_turn")])
    }

    /// The Ascendant operation remains an authoritative unary completion, but
    /// replay is polled while it is active so ACP clients receive live updates
    /// instead of a burst after the call returns.
    private func streamPrompt(
        message: String,
        record: ACPSessionRecord,
        turnID: String
    ) async throws -> (AscendantTurnResult, Int) {
        let providerID = try await boundProviderID(for: record)
        let channel = try await client.observeTurnUpdates(providerID: providerID)
        let inbox = TurnUpdateInbox()
        let collector = Task {
            for await event in channel
                where event.timelineID == record.timelineID && event.clientTurnID == turnID {
                await inbox.append(event.update)
            }
        }
        let turnTask = Task {
            try await client.turn(
                message: message,
                timelineID: record.timelineID,
                clientTurnID: turnID,
                providerID: providerID
            )
        }
        let completion = PromptCompletion()
        let completionWatcher = Task {
            do {
                await completion.set(.completed(try await turnTask.value))
            } catch {
                await completion.set(.failed(.of(error)))
            }
        }
        let promptToken = UUID()
        let stopTasks = {
            turnTask.cancel()
            collector.cancel()
            completionWatcher.cancel()
        }
        activePrompts[record.id] = ActivePrompt(
            token: promptToken,
            close: {
                stopTasks()
                await completion.set(.failed(.message("ACP session was closed")))
            },
            cancel: {
                stopTasks()
                await completion.set(.cancelled)
            }
        )
        defer {
            turnTask.cancel()
            collector.cancel()
            completionWatcher.cancel()
            if activePrompts[record.id]?.token == promptToken {
                activePrompts.removeValue(forKey: record.id)
            }
        }
        var lastSequence = 0

        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(40))

            for update in await inbox.drain(afterSequence: lastSequence) {
                publishUpdate(
                    sessionID: record.id,
                    turnID: turnID,
                    update: update,
                    replayed: false
                )
                try await handlePermissionUpdate(
                    update,
                    sessionID: record.id,
                    timelineID: record.timelineID,
                    turnID: turnID
                )
                lastSequence = max(lastSequence, update.sequence)
            }

            switch await completion.value() {
            case .completed(let result): return (result, lastSequence)
            case .failed(let failure): throw failure.thrown
            case .cancelled: throw CancellationError()
            case nil: break
            }
        }
    }

    fileprivate enum PromptWaitOutcome: Sendable {
        case completed(AscendantTurnResult)
        case failed(PromptFailure)
        case cancelled
    }

    /// A Turn failure kept in the shape the ACP client should see.
    ///
    /// ADR 0008 requires an orphaned prompt to surface `timelineUnavailable`
    /// with its `data.gnosticCode`, so a structured client error must survive
    /// the hop through the completion actor instead of being flattened into a
    /// description string.
    fileprivate enum PromptFailure: Sendable {
        case remote(RemoteTurnClientError)
        case message(String)

        static func of(_ error: any Error) -> Self {
            if let remote = error as? RemoteTurnClientError { return .remote(remote) }
            return .message(String(describing: error))
        }

        var thrown: any Error {
            switch self {
            case let .remote(error): error
            case let .message(detail): JSONRPCMethodError.invalidState(detail)
            }
        }
    }

    private func handlePermissionUpdate(
        _ update: AscendantTurnUpdate,
        sessionID: String,
        timelineID: UUID,
        turnID: String
    ) async throws {
        let states = [update.permissionState].compactMap { $0 } + update.permissionStates
        for state in states where state.status == "pending" {
            guard requestedPermissionIDs.insert(state.correlationID).inserted else { continue }
            defer { requestedPermissionIDs.remove(state.correlationID) }
            let permissionToken = UUID()
            let permissionTask = Task {
                try await requestPermission(
                    ACPPermissionBridge.parameters(sessionID: sessionID, state: state)
                )
            }
            activePermissionRequests[sessionID] = ActivePermissionRequest(
                token: permissionToken,
                task: permissionTask
            )
            defer {
                permissionTask.cancel()
                if activePermissionRequests[sessionID]?.token == permissionToken {
                    activePermissionRequests.removeValue(forKey: sessionID)
                }
            }
            do {
                let response = try await permissionTask.value
                guard let approved = ACPPermissionBridge.approved(from: response) else {
                    throw JSONRPCMethodError.invalidState("ACP client returned a malformed permission outcome")
                }
                try await client.respondToPermission(AscendantPermissionResponse(
                    correlationID: state.correlationID,
                    timelineID: timelineID,
                    clientTurnID: turnID,
                    approved: approved
                ), providerID: try await currentAscendant().providerID)
            } catch {
                try? await denyPermission(state, timelineID: timelineID, turnID: turnID)
                if error is CancellationError {
                    throw JSONRPCMethodError.invalidState("ACP session was closed")
                }
                throw error
            }
        }
    }

    private func denyPermission(
        _ state: AscendantPermissionState,
        timelineID: UUID,
        turnID: String
    ) async throws {
        try await client.respondToPermission(AscendantPermissionResponse(
            correlationID: state.correlationID,
            timelineID: timelineID,
            clientTurnID: turnID,
            approved: false
        ), providerID: try await currentAscendant().providerID)
    }

    private func publishUpdate(
        sessionID: String,
        turnID: String,
        update: AscendantTurnUpdate,
        replayed: Bool
    ) {
        for notification in ACPUpdateRenderer.updates(
            sessionID: sessionID,
            turnID: turnID,
            update: update,
            replayed: replayed
        ) {
            publish(notification.method, notification.params)
        }
    }

    private func resolveAscendant() async throws -> Ascendant {
        do {
            let selected = try await client.selectAscendant(
                id: requestedAscendantID,
                providerID: requestedProviderID,
                nodeID: requestedNodeID
            )
            return Ascendant(
                id: selected.id,
                name: selected.name,
                timelineID: selected.timelineID,
                providerID: selected.providerID,
                nodeID: selected.nodeID ?? requestedNodeID
            )
        } catch let error as RemoteTurnClientError {
            throw JSONRPCMethodError.invalidState(error.localizedDescription)
        }
    }

    /// Returns the cached Ascendant, re-resolving it when a provider eviction
    /// cleared the selection.
    private func currentAscendant() async throws -> Ascendant {
        if let ascendant { return ascendant }
        let resolved = try await resolveAscendant()
        ascendant = resolved
        return resolved
    }

    private func requireSession(id: String, cwd: String?) async throws -> ACPSessionRecord {
        let record = try await knownSession(id: id, cwd: cwd)
        try await requireBinding(of: record)
        return record
    }

    /// Reclassifies a failed session operation against live discovery.
    ///
    /// ADR 0008 requires an orphaned session to surface `timelineUnavailable`
    /// and never a binding or provider error: across a serve restart the
    /// per-process provider ID changes (#247), so the binding check fails
    /// first and would otherwise mask the real cause. The probe runs only
    /// after something has already failed, which keeps a healthy request free
    /// of an extra discovery round. Confirmed absence also ends the registry
    /// record; any other outcome keeps the original error and leaves the
    /// record open.
    ///
    /// An evicted provider is never an orphan. Its catalog entries are gone
    /// (#249), so the Timeline would probe as absent next to any other live
    /// Node — exactly the false positive ADR 0008 forbids. A typed
    /// `providerOffline` says the Node left, not that the Timeline died, so it
    /// passes through untouched.
    private func orphanAwareError(_ error: any Error, for record: ACPSessionRecord) async -> any Error {
        if case RemoteTurnClientError.providerOffline = error { return error }
        guard await client.timelinePresence(of: record.timelineID) == .absent else { return error }
        _ = try? await registry.markEnded(id: record.id)
        return RemoteTurnClientError.timelineUnavailable(record.timelineID)
    }

    private func knownSession(id: String, cwd: String?) async throws -> ACPSessionRecord {
        guard let record = await registry.record(id: id) else {
            throw JSONRPCMethodError.invalidParams("unknown ACP session")
        }
        if let cwd, cwd != record.cwd {
            throw JSONRPCMethodError.invalidParams("session cwd does not match its original binding")
        }
        return record
    }

    private func requireBinding(of record: ACPSessionRecord) async throws {
        guard isBound(record, to: try await currentAscendant()) else {
            throw JSONRPCMethodError.invalidState("session is bound to a different Ascendant, Node, or namespace")
        }
    }

    /// Whether a persisted record belongs to this process's Ascendant.
    ///
    /// The binding is namespace, Ascendant, and Node. It never includes the
    /// provider identity, which changes with every serve process, so a record
    /// stays valid across a restart of its Node.
    private func isBound(_ record: ACPSessionRecord, to ascendant: Ascendant) -> Bool {
        guard record.ascendantID == ascendant.id else { return false }
        if let recorded = record.nodeID, let current = ascendant.nodeID, recorded != current { return false }
        return acceptsFingerprint(record.profileFingerprint, for: ascendant)
    }

    /// Accepts this process's fingerprint and the shapes written before it.
    ///
    /// A record written before this contract carries a per-process provider
    /// identity in its middle segment. The namespace and the Ascendant are the
    /// parts that ever bound it, and the Node is checked separately, so an
    /// existing record keeps loading instead of failing on a stale provider.
    private func acceptsFingerprint(_ fingerprint: String, for ascendant: Ascendant) -> Bool {
        let ascendantID = ascendant.id.uuidString.lowercased()
        if fingerprint == "\(client.namespace):\(ascendantID)" { return true }
        return fingerprint.hasPrefix("\(client.namespace):") && fingerprint.hasSuffix(":\(ascendantID)")
    }

    private func profileFingerprint(for ascendant: Ascendant) -> String {
        let ascendantID = ascendant.id.uuidString.lowercased()
        guard let nodeID = ascendant.nodeID else { return "\(client.namespace):\(ascendantID)" }
        return "\(client.namespace):node:\(nodeID.uuidString.lowercased()):\(ascendantID)"
    }

    /// The provider that currently answers for a record's Ascendant.
    ///
    /// The record itself is not bound to a provider; this is the live serve
    /// process behind its Node, re-resolved after an eviction.
    private func boundProviderID(for record: ACPSessionRecord) async throws -> String {
        try await currentAscendant().providerID
    }

    private func canonicalCWD(_ cwd: String) throws -> String {
        guard !cwd.isEmpty, URL(fileURLWithPath: cwd).path.hasPrefix("/") else {
            throw JSONRPCMethodError.invalidParams("cwd must be an absolute path")
        }
        return URL(fileURLWithPath: cwd).standardizedFileURL.path
    }

    /// ACP's cwd is client intent, not a host path that Gnostic may mount or
    /// inspect. Report it alongside the timeline's actual attachment state so
    /// clients can distinguish an attached runtime Workspace from their local
    /// filesystem workspace.
    private func sessionMetadata(cwd: String, status: TimelineStatus) -> [String: AnyCodable] {
        [
            "gnosticCWD": .string(cwd),
            "gnosticWorkspaceAttachmentState": .string(
                status.attachedWorkspaceIDs.isEmpty ? "none" : "attached"
            ),
            "gnosticAttachedWorkspaceIDs": .array(
                status.attachedWorkspaceIDs.map { .string($0.uuidString.lowercased()) }
            ),
        ]
    }

    private func rejectMCP(_ servers: [AnyCodable]?) throws {
        guard let servers, !servers.isEmpty else { return }
        throw JSONRPCMethodError.invalidParams("client-supplied MCP servers are not supported by gnostic acp yet")
    }

    private func decode<T: Decodable>(_ params: AnyCodable?) throws -> T {
        guard let params,
              let data = try? JSONEncoder().encode(params),
              let value = try? JSONDecoder().decode(T.self, from: data) else {
            throw JSONRPCMethodError.invalidParams("invalid ACP method parameters")
        }
        return value
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private actor TurnUpdateInbox {
    private var updates: [AscendantTurnUpdate] = []

    func append(_ update: AscendantTurnUpdate) {
        updates.append(update)
    }

    func drain(afterSequence: Int) -> [AscendantTurnUpdate] {
        let ready = updates.filter { $0.sequence > afterSequence }.sorted { $0.sequence < $1.sequence }
        updates.removeAll { $0.sequence <= (ready.last?.sequence ?? afterSequence) }
        return ready
    }
}

private actor PromptCompletion {
    private var outcome: ACPDispatcher.PromptWaitOutcome?

    func set(_ outcome: ACPDispatcher.PromptWaitOutcome) {
        self.outcome = outcome
    }

    func value() -> ACPDispatcher.PromptWaitOutcome? { outcome }
}
