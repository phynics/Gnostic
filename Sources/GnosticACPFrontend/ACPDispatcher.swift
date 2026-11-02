// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol
import GnosticCore

/// Translates ACP v2 requests into Gnostic's existing remote object and
/// Timeline operations. ACP remains an adapter: no ACP identifiers are stored
/// in the Gnostic object advertisements.
@MainActor
final class ACPDispatcher: Sendable {
    /// The Runtime instance this ACP process is pinned to.
    ///
    /// `providerID` is the serve process that currently answers for it and is
    /// re-resolved after an eviction. `nodeID` is the manifest identity that
    /// outlives every such process, so it is what a session binds to.
    private struct RuntimeInstance {
        let runtimeID: UUID
        let name: String
        let providerID: String
        let nodeID: UUID?
    }

    private struct ActivePrompt {
        let token: UUID
        let timelineID: UUID
        let clientTurnID: String
        let providerID: String
        // Async so session close/cancel can await the completion transition
        // instead of spawning an unowned `Task` hop. The pending prompt's
        // polling loop observes the transition before it unwinds.
        let close: () async -> Void
        let cancel: () async -> Void
    }

    private struct ActivePermissionRequest {
        let token: UUID
        let task: Task<GnosticJSONValue, Error>
    }

    private let client: RemoteTurnClient
    private let registry: ACPSessionRegistry
    private let requestedRuntimeID: UUID?
    private let requestedProviderID: String?
    private let requestedNodeID: UUID?
    private let publish: @Sendable (String, GnosticJSONValue) -> Void
    private let requestPermission: @Sendable (GnosticJSONValue) async throws -> GnosticJSONValue
    private var runtime: RuntimeInstance?
    private var requestedPermissionIDs: Set<String> = []
    private var activePrompts: [String: ActivePrompt] = [:]
    /// The Turn that holds each session's single foreground slot, from the
    /// moment its prompt is accepted until it ends.
    private var promptReservations: [String: (turnID: String, token: UUID)] = [:]
    private var activePermissionRequests: [String: ActivePermissionRequest] = [:]
    private var cancelledSessions: Set<String> = []

    init(
        client: RemoteTurnClient,
        registry: ACPSessionRegistry,
        requestedRuntimeID: UUID?,
        requestedProviderID: String? = nil,
        requestedNodeID: UUID? = nil,
        publish: @escaping @Sendable (String, GnosticJSONValue) -> Void,
        requestPermission: @escaping @Sendable (GnosticJSONValue) async throws -> GnosticJSONValue
    ) {
        self.client = client
        self.registry = registry
        self.requestedRuntimeID = requestedRuntimeID
        self.requestedProviderID = requestedProviderID
        self.requestedNodeID = requestedNodeID
        self.publish = publish
        self.requestPermission = requestPermission
    }

    func initialize() async throws -> GnosticJSONValue {
        runtime = try await resolveRuntime()
        return .dictionary([
            "protocolVersion": .integer(Int64(ACPProtocol.version)),
            "info": .dictionary([
                "name": .string("gnostic-acp"),
                "title": .string("Gnostic ACP"),
                "version": .string("0.5.0"),
            ]),
            "capabilities": .dictionary([
                "session": .dictionary([:]),
            ]),
        ])
    }

    func handle(_ request: JSONRPCRequest) async throws -> GnosticJSONValue {
        do {
            return try await route(request)
        } catch let error as RemoteTurnClientError {
            if case .providerOffline = error {
                // The cached selection points at a provider that is gone. Drop
                // it so the next request re-resolves the Runtime instance instead of
                // reusing the dead binding.
                runtime = nil
            }
            throw error
        }
    }

    private func route(_ request: JSONRPCRequest) async throws -> GnosticJSONValue {
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
        default:
            throw JSONRPCMethodError.methodNotFound(request.method)
        }
    }

    private func newSession(_ params: GnosticJSONValue?) async throws -> GnosticJSONValue {
        let input: ACPSessionParameters = try decode(params)
        let cwd = try canonicalCWD(input.cwd)
        try rejectMCP(input.mcpServers)
        let selected = try await currentRuntime()
        let status = try await client.createTimeline(
            title: "ACP \(URL(fileURLWithPath: cwd).lastPathComponent)",
            runtimeID: selected.runtimeID,
            providerID: selected.providerID
        )
        let record = try await registry.create(
            profileFingerprint: profileFingerprint(for: selected),
            ascendantID: selected.runtimeID,
            timelineID: status.timelineID,
            cwd: cwd,
            title: status.title,
            nodeID: selected.nodeID
        )
        return .dictionary([
            "sessionId": .string(record.id),
            "_meta": .dictionary(sessionMetadata(cwd: cwd, status: status).merging([
                "gnosticRuntimeID": .string(selected.runtimeID.uuidString.lowercased()),
                "gnosticTimelineID": .string(record.timelineID.uuidString.lowercased()),
            ]) { _, new in new }),
        ])
    }

    private func resumeSession(_ params: GnosticJSONValue?) async throws -> GnosticJSONValue {
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

    private func listSessions(_ params: GnosticJSONValue?) async throws -> GnosticJSONValue {
        let input: ACPListParameters = try decode(params ?? .dictionary([:]))
        let cwd = try input.cwd.map { try canonicalCWD($0) }
        let selected = try await currentRuntime()
        let records = await registry.list(cwd: cwd)
        var sessions: [GnosticJSONValue] = []
        var unresolved: [ACPSessionRecord] = []
        // Registry entries survive process restarts, but a deleted remote
        // Timeline must not be presented as resumable. A closed record or one
        // bound to a different Node is omitted outright; a record whose
        // Timeline cannot be read is unresolved so ADR 0008 can end it once
        // absence is confirmed. The binding is namespace, Runtime instance, and Node,
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

    private func closeSession(_ params: GnosticJSONValue?) async throws -> GnosticJSONValue {
        let input: ACPCloseParameters = try decode(params)
        _ = try await requireSession(id: input.sessionID, cwd: nil)
        activePermissionRequests.removeValue(forKey: input.sessionID)?.task.cancel()
        await activePrompts.removeValue(forKey: input.sessionID)?.close()
        _ = try await registry.close(id: input.sessionID)
        return .dictionary([:])
    }

    private func cancelSession(_ params: GnosticJSONValue?) async throws -> GnosticJSONValue {
        let input: ACPCloseParameters = try decode(params)
        _ = try await requireSession(id: input.sessionID, cwd: nil)
        guard let prompt = activePrompts[input.sessionID] else { return .dictionary([:]) }
        cancelledSessions.insert(input.sessionID)
        activePermissionRequests.removeValue(forKey: input.sessionID)?.task.cancel()
        Task { @MainActor [client] in
            do {
                _ = try await client.cancelTurn(
                    timelineID: prompt.timelineID,
                    clientTurnID: prompt.clientTurnID,
                    providerID: prompt.providerID
                )
            } catch {
                FileHandle.standardError.write(Data(
                    "ACP session cancellation could not be forwarded to the serving runtime.\n".utf8
                ))
            }
        }
        await prompt.cancel()
        return .dictionary([:])
    }

    private func prompt(_ params: GnosticJSONValue?) async throws -> GnosticJSONValue {
        let input: ACPPromptParameters = try decode(params)
        guard let text = input.text else {
            throw JSONRPCMethodError.invalidParams("session/prompt accepts non-empty text content only")
        }
        let turnID: String
        if let clientTurnID = input.clientTurnID {
            // ACP metadata may contain compatibility whitespace. Canonicalize
            // once, before live-update filtering, and reuse this value for the
            // request and every update or permission correlation.
            turnID = try GnosticWirePayload.canonicalClientTurnID(clientTurnID)
        } else {
            turnID = "acp:\(input.sessionID):\(UUID().uuidString.lowercased())"
        }
        // One foreground Turn per session (ADR 0021). A distinct prompt that
        // arrives while another is active is rejected here, before any await
        // and before anything is published. It is not queued, and it must not
        // replace the active prompt's cancellation handle. An identical retry
        // of the active Turn proceeds and is attached by the Node.
        let reservation: UUID?
        if let held = promptReservations[input.sessionID] {
            guard held.turnID == turnID else { throw RemoteTurnClientError.timelineBusy }
            reservation = nil
        } else {
            let token = UUID()
            promptReservations[input.sessionID] = (turnID, token)
            reservation = token
        }
        // Only a prompt that holds the slot owns the session's cancellation flag.
        // A rejected prompt leaves it alone, so it cannot erase a cancel that is
        // still unwinding the active Turn.
        defer {
            cancelledSessions.remove(input.sessionID)
            if let reservation, promptReservations[input.sessionID]?.token == reservation {
                promptReservations.removeValue(forKey: input.sessionID)
            }
        }
        let record = try await knownSession(id: input.sessionID, cwd: nil)
        do {
            try await requireBinding(of: record)
        } catch {
            throw await orphanAwareError(error, for: record)
        }

        let messageID = "acp:user:\(turnID)"

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
            // Text longer than one update spans pages, and the terminal update
            // comes last. A later page that fails ends this retry with that
            // error, because a partial replay must not report `end_turn`.
            var updates = existing.updates
            var nextSequence = existing.nextSequence
            while let after = nextSequence {
                let page = try await client.replay(
                    timelineID: record.timelineID,
                    clientTurnID: turnID,
                    message: text,
                    afterSequence: after,
                    providerID: try await boundProviderID(for: record)
                )
                updates += page.updates
                nextSequence = page.updates.isEmpty ? nil : page.nextSequence
            }
            if let error = updates.last(where: \.isTerminalFailure) {
                // A retry of a Turn whose insertion is unknown gets that state
                // back, structured, and never a second prompt.
                if error.reasonCode == "insertionUnknown" { throw RemoteTurnClientError.insertionUnknown }
                throw JSONRPCMethodError.invalidState(error.text ?? "ACP turn did not complete")
            }
            publishUserMessage(sessionID: record.id, messageID: messageID, text: text, turnID: turnID)
            for update in updates {
                publishUpdate(
                    sessionID: record.id,
                    turnID: turnID,
                    update: update,
                    replayed: true
                )
            }
            publishState(
                sessionID: record.id,
                state: "idle",
                stopReason: Self.endedUnspecified(updates) ? nil : "end_turn",
                turnID: turnID
            )
            return .dictionary(["messageId": .string(messageID)])
        }
        // The client sees the user message and the running state only once the
        // Node has accepted the Turn. A prompt the Node rejects as busy was never
        // inserted, so nothing is published for it.
        var announced = false
        let announce = { [self] in
            guard !announced else { return }
            announced = true
            publishUserMessage(sessionID: record.id, messageID: messageID, text: text, turnID: turnID)
            publishState(sessionID: record.id, state: "running", stopReason: nil, turnID: turnID)
        }
        let streamed: (result: AscendantTurnResult, lastSequence: Int, endedUnspecified: Bool)
        do {
            streamed = try await streamPrompt(
                message: text,
                record: record,
                turnID: turnID,
                announce: announce
            )
        } catch {
            if case RemoteTurnClientError.timelineBusy = error { throw error }
            announce()
            if cancelledSessions.contains(input.sessionID) {
                publishState(sessionID: record.id, state: "idle", stopReason: "cancelled", turnID: turnID)
                return .dictionary(["messageId": .string(messageID)])
            }
            publishState(sessionID: record.id, state: "idle", stopReason: "error", turnID: turnID)
            throw await orphanAwareError(error, for: record)
        }
        announce()
        if cancelledSessions.contains(input.sessionID) {
            publishState(sessionID: record.id, state: "idle", stopReason: "cancelled", turnID: turnID)
            return .dictionary(["messageId": .string(messageID)])
        }
        let (result, lastSequence) = (streamed.result, streamed.lastSequence)
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
        // An idle update without a stop reason reaches the client as it came:
        // the Turn ended, and the Runtime named no reason (ADR 0019 section 2).
        let unspecified = streamed.endedUnspecified || Self.endedUnspecified(updates)
        publishState(sessionID: record.id, state: "idle", stopReason: unspecified ? nil : "end_turn", turnID: turnID)
        return .dictionary(["messageId": .string(messageID)])
    }

    /// The Ascendant operation remains an authoritative unary completion, but
    /// replay is polled while it is active so ACP clients receive live updates
    /// instead of a burst after the call returns.
    private func streamPrompt(
        message: String,
        record: ACPSessionRecord,
        turnID: String,
        announce: () -> Void
    ) async throws -> (result: AscendantTurnResult, lastSequence: Int, endedUnspecified: Bool) {
        let providerID = try await boundProviderID(for: record)
        let channel = try await client.turnUpdates(for: turnID, timelineID: record.timelineID, providerID: providerID)
        let inbox = TurnUpdateInbox()
        let collector = Task {
            for await update in channel {
                await inbox.append(update)
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
            timelineID: record.timelineID,
            clientTurnID: turnID,
            providerID: providerID,
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
        var endedUnspecified = false

        var deliveredTextBytes = 0

        func deliver(_ update: AscendantTurnUpdate, skippingPermissions skipped: Set<String> = []) async throws {
            announce()
            publishUpdate(
                sessionID: record.id,
                turnID: turnID,
                update: update,
                replayed: false
            )
            if update.carriesAssistantText { deliveredTextBytes += update.text?.utf8.count ?? 0 }
            try await handlePermissionUpdate(
                update,
                sessionID: record.id,
                timelineID: record.timelineID,
                turnID: turnID,
                skipping: skipped
            )
            lastSequence = max(lastSequence, update.sequence)
            endedUnspecified = endedUnspecified || Self.endedUnspecified([update])
        }

        // Live events are best effort: a burst can overflow a buffer, and a
        // Turn can complete with updates still in transit. Replay is the
        // authoritative record, so it fills what the live path missed.
        //
        // Returns false when replay failed. A running Turn then keeps its
        // position and tries again later, because moving past a gap would lose
        // that text for good. Everything dropped here stays in replay.
        func catchUp(turnEnded: Bool) async throws -> Bool {
            var missed: [AscendantTurnUpdate] = []
            var after = lastSequence
            var replayFailed = false
            var pages = 0
            while true {
                guard let page = try? await client.replay(
                    timelineID: record.timelineID,
                    clientTurnID: turnID,
                    afterSequence: after,
                    providerID: providerID
                ) else {
                    replayFailed = true
                    break
                }
                guard let last = page.updates.last, last.sequence > after else { break }
                missed += page.updates.filter { $0.sequence > after }
                after = last.sequence
                pages += 1
                // A running Turn can add pages as fast as they are read, so one
                // pass is bounded and the prompt loop still sees completion. Only
                // replay can say the Turn is terminal: a failed call does not, as
                // the Node's Turn can outlive it.
                guard page.nextSequence != nil, page.terminal || pages < Self.catchUpPagesPerPass else { break }
            }
            // A partial replay can't show whether a pending request was resolved
            // on the page that failed, so a running Turn delivers none of it.
            if replayFailed && !turnEnded { return false }
            let skipped = ACPReplayCatchUp.permissionsToSkip(in: missed, turnEnded: turnEnded)
            for update in missed where update.sequence > lastSequence {
                let adjusted = ACPReplayCatchUp.removingDeliveredText(
                    from: update,
                    deliveredTextBytes: deliveredTextBytes
                )
                if let adjusted {
                    try await deliver(adjusted, skippingPermissions: skipped)
                } else {
                    lastSequence = max(lastSequence, update.sequence)
                }
            }
            return !replayFailed
        }

        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(40))

            drained: for update in await inbox.drain(afterSequence: lastSequence) where update.sequence > lastSequence {
                if update.sequence > lastSequence + 1, try await !catchUp(turnEnded: false) { break drained }
                if update.sequence == lastSequence + 1 {
                    try await deliver(update)
                } else if update.sequence > lastSequence {
                    // A bounded pass stopped short of this update. Replay still holds it.
                    break drained
                }
            }

            switch await completion.value() {
            case .completed(let result):
                // The owner may have stopped answering for only a moment, so a
                // failure is retried before the client is told text may be missing.
                var replayed = try await catchUp(turnEnded: true)
                for _ in 0..<2 where !replayed {
                    try await Task.sleep(for: .milliseconds(500))
                    replayed = try await catchUp(turnEnded: true)
                }
                if !replayed {
                    try await deliver(AscendantTurnUpdate(
                        sequence: lastSequence,
                        kind: .assistantText,
                        text: AscendantTurnUpdate.truncationMarker
                    ))
                }
                return (result, lastSequence, endedUnspecified)
            case .failed(let failure):
                _ = try await catchUp(turnEnded: true)
                throw failure.thrown
            case .cancelled: throw CancellationError()
            case nil: break
            }
        }
    }

    /// Replay pages one catch-up pass reads while a Turn is still running.
    private static let catchUpPagesPerPass = 64

    /// Whether the Turn's terminal update records an idle without a stop reason.
    private static func endedUnspecified(_ updates: [AscendantTurnUpdate]) -> Bool {
        guard let terminal = updates.last(where: \.terminal) else { return false }
        return terminal.updateKind == .completion && terminal.reasonCode == TimelineTurnTerminalOutcome.endedUnspecified.rawValue
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
            return .message((error as? LocalizedError)?.errorDescription ?? String(describing: error))
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
        turnID: String,
        skipping skipped: Set<String> = []
    ) async throws {
        let states = [update.permissionState].compactMap { $0 } + update.permissionStates
        for state in states where state.status == "pending" && !skipped.contains(state.correlationID) {
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
                guard let response = try await ACPPermissionBridge.boundedAnswer(from: permissionTask) else {
                    try await withholdPermission(state, timelineID: timelineID, turnID: turnID, reason: "permissionUnanswered")
                    continue
                }
                guard let answer = ACPPermissionBridge.answer(from: response) else {
                    throw JSONRPCMethodError.invalidState("ACP client returned a malformed permission outcome")
                }
                // Only a client's explicit choice is a decision (ADR 0019 §4).
                guard answer != .undecided else {
                    try await withholdPermission(state, timelineID: timelineID, turnID: turnID, reason: "clientCancelled")
                    continue
                }
                let providerID = try await currentRuntime().providerID
                try client.respondToPermission(AscendantPermissionResponse(
                    correlationID: state.correlationID,
                    timelineID: timelineID,
                    clientTurnID: turnID,
                    approved: answer == .approved
                ), providerID: providerID)
            } catch {
                let reason = error is CancellationError ? "sessionClosed" : "clientRequestFailed"
                try? await withholdPermission(state, timelineID: timelineID, turnID: turnID, reason: reason)
                if error is CancellationError {
                    throw JSONRPCMethodError.invalidState("ACP session was closed")
                }
                throw error
            }
        }
    }

    /// Tells the Node that the client made no decision. It is not a denial.
    private func withholdPermission(
        _ state: AscendantPermissionState,
        timelineID: UUID,
        turnID: String,
        reason: String
    ) async throws {
        let providerID = try await currentRuntime().providerID
        try client.respondToPermission(AscendantPermissionResponse(
            correlationID: state.correlationID,
            timelineID: timelineID,
            clientTurnID: turnID,
            approved: false,
            unavailableReason: reason
        ), providerID: providerID)
    }

    private func publishUserMessage(
        sessionID: String,
        messageID: String,
        text: String,
        turnID: String
    ) {
        publish("session/update", .dictionary([
            "sessionId": .string(sessionID),
            "update": .dictionary([
                "sessionUpdate": .string("user_message"),
                "messageId": .string(messageID),
                "content": .array([
                    .dictionary(["type": .string("text"), "text": .string(text)]),
                ]),
                "_meta": .dictionary(["clientTurnID": .string(turnID)]),
            ]),
        ]))
    }

    private func publishState(
        sessionID: String,
        state: String,
        stopReason: String?,
        turnID: String
    ) {
        var update: [String: GnosticJSONValue] = [
            "sessionUpdate": .string("state_update"),
            "state": .string(state),
            "_meta": .dictionary(["clientTurnID": .string(turnID)]),
        ]
        if let stopReason {
            update["stopReason"] = .string(stopReason)
        }
        publish("session/update", .dictionary([
            "sessionId": .string(sessionID),
            "update": .dictionary(update),
        ]))
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

    private func resolveRuntime() async throws -> RuntimeInstance {
        do {
            let selected = try await client.selectRuntime(
                id: requestedRuntimeID,
                providerID: requestedProviderID,
                nodeID: requestedNodeID
            )
            return RuntimeInstance(
                runtimeID: selected.runtimeID,
                name: selected.name,
                providerID: selected.providerID,
                nodeID: selected.nodeID ?? requestedNodeID
            )
        } catch let error as RemoteTurnClientError {
            throw JSONRPCMethodError.invalidState(
                RemoteTurnClient.discoveryFailureDescription(
                    error: error,
                    diagnostics: client.runtimeDiscoveryDiagnostics
                )
            )
        }
    }

    /// Returns the cached Runtime instance, re-resolving it when a provider eviction
    /// cleared the selection.
    private func currentRuntime() async throws -> RuntimeInstance {
        if let runtime { return runtime }
        let resolved = try await resolveRuntime()
        runtime = resolved
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
        guard isBound(record, to: try await currentRuntime()) else {
            throw JSONRPCMethodError.invalidState("session is bound to a different Runtime instance, Node, or namespace")
        }
    }

    /// Whether a persisted record belongs to this process's Runtime instance.
    ///
    /// The binding is namespace, Runtime instance, and Node. It never includes the
    /// provider identity, which changes with every serve process, so a record
    /// stays valid across a restart of its Node.
    private func isBound(_ record: ACPSessionRecord, to runtime: RuntimeInstance) -> Bool {
        guard record.ascendantID == runtime.runtimeID else { return false }
        if let recorded = record.nodeID, let current = runtime.nodeID, recorded != current { return false }
        return acceptsFingerprint(record.profileFingerprint, for: runtime)
    }

    /// Accepts this process's fingerprint and the shapes written before it.
    ///
    /// A record written before this contract carries a per-process provider
    /// identity in its middle segment. The namespace and Runtime instance are the
    /// parts that ever bound it, and the Node is checked separately, so an
    /// existing record keeps loading instead of failing on a stale provider.
    private func acceptsFingerprint(_ fingerprint: String, for runtime: RuntimeInstance) -> Bool {
        let runtimeID = runtime.runtimeID.uuidString.lowercased()
        if fingerprint == "\(client.namespace):\(runtimeID)" { return true }
        return fingerprint.hasPrefix("\(client.namespace):") && fingerprint.hasSuffix(":\(runtimeID)")
    }

    private func profileFingerprint(for runtime: RuntimeInstance) -> String {
        let runtimeID = runtime.runtimeID.uuidString.lowercased()
        guard let nodeID = runtime.nodeID else { return "\(client.namespace):\(runtimeID)" }
        return "\(client.namespace):node:\(nodeID.uuidString.lowercased()):\(runtimeID)"
    }

    /// The provider that currently answers for a record's Runtime instance.
    ///
    /// The record itself is not bound to a provider; this is the live serve
    /// process behind its Node, re-resolved after an eviction.
    private func boundProviderID(for record: ACPSessionRecord) async throws -> String {
        try await currentRuntime().providerID
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
    private func sessionMetadata(cwd: String, status: TimelineStatus) -> [String: GnosticJSONValue] {
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

    private func rejectMCP(_ servers: [GnosticJSONValue]?) throws {
        guard let servers, !servers.isEmpty else { return }
        throw JSONRPCMethodError.invalidParams("client-supplied MCP servers are not supported by gnostic acp yet")
    }

    private func decode<T: Decodable>(_ params: GnosticJSONValue?) throws -> T {
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
