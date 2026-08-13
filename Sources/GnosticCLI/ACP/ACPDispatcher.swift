// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import PKShared

/// Translates stable ACP v1 requests into Gnostic's existing remote object and
/// Timeline operations. ACP remains an adapter: no ACP identifiers are stored
/// in the Gnostic object advertisements.
@MainActor
final class ACPDispatcher: Sendable {
    private struct Ascendant {
        let id: UUID
        let name: String
        let timelineID: UUID
        let providerID: String
    }

    private struct ActivePrompt {
        let token: UUID
        let close: () -> Void
        let cancel: () -> Void
    }

    private struct ActivePermissionRequest {
        let token: UUID
        let task: Task<AnyCodable, Error>
    }

    private let client: GnosticRemoteClient
    private let registry: ACPSessionRegistry
    private let requestedAscendantID: UUID?
    private let requestedProviderID: String?
    private let publish: @Sendable (String, AnyCodable) -> Void
    private let requestPermission: @Sendable (AnyCodable) async throws -> AnyCodable
    private var ascendant: Ascendant?
    private var requestedPermissionIDs: Set<String> = []
    private var activePrompts: [String: ActivePrompt] = [:]
    private var activePermissionRequests: [String: ActivePermissionRequest] = [:]
    private var cancelledSessions: Set<String> = []

    init(
        client: GnosticRemoteClient,
        registry: ACPSessionRegistry,
        requestedAscendantID: UUID?,
        requestedProviderID: String? = nil,
        publish: @escaping @Sendable (String, AnyCodable) -> Void,
        requestPermission: @escaping @Sendable (AnyCodable) async throws -> AnyCodable
    ) {
        self.client = client
        self.registry = registry
        self.requestedAscendantID = requestedAscendantID
        self.requestedProviderID = requestedProviderID
        self.publish = publish
        self.requestPermission = requestPermission
    }

    func initialize() async throws -> AnyCodable {
        ascendant = try await resolveAscendant()
        return .dictionary([
            "protocolVersion": .number(Double(ACPProtocol.version)),
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
        let selected = try selectedAscendant()
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
            providerID: selected.providerID
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
        let record = try await requireSession(id: input.sessionID, cwd: cwd)
        let status = try await client.timelineStatus(timelineID: record.timelineID, providerID: try boundProviderID(for: record))
        try await registry.touch(id: record.id)
        return .dictionary(["_meta": .dictionary(sessionMetadata(cwd: record.cwd, status: status))])
    }

    private func listSessions(_ params: AnyCodable?) async throws -> AnyCodable {
        let input: ACPListParameters = try decode(params ?? .dictionary([:]))
        let cwd = try input.cwd.map { try canonicalCWD($0) }
        let selected = try selectedAscendant()
        let fingerprint = profileFingerprint(for: selected)
        let legacyFingerprint = legacyProfileFingerprint(for: selected)
        let records = await registry.list(cwd: cwd)
        var sessions: [AnyCodable] = []
        for record in records where (record.profileFingerprint == fingerprint || record.profileFingerprint == legacyFingerprint)
            && record.ascendantID == selected.id
            && (record.providerID == nil || record.providerID == selected.providerID) {
            // Registry entries survive process restarts, but a deleted remote
            // Timeline must not be presented as resumable. Keep the metadata on
            // disk for diagnostics while omitting it from the ACP result.
            guard let status = try? await client.timelineStatus(timelineID: record.timelineID, providerID: selected.providerID) else { continue }
            sessions.append(.dictionary([
                "sessionId": .string(record.id),
                "cwd": .string(record.cwd),
                "title": .string(record.title),
                "updatedAt": .string(Self.iso8601(record.updatedAt)),
                "_meta": .dictionary(sessionMetadata(cwd: record.cwd, status: status)),
            ]))
        }
        return .dictionary(["sessions": .array(sessions)])
    }

    private func closeSession(_ params: AnyCodable?) async throws -> AnyCodable {
        let input: ACPCloseParameters = try decode(params)
        _ = try await requireSession(id: input.sessionID, cwd: nil)
        activePermissionRequests.removeValue(forKey: input.sessionID)?.task.cancel()
        activePrompts.removeValue(forKey: input.sessionID)?.close()
        _ = try await registry.close(id: input.sessionID)
        return .dictionary([:])
    }

    private func cancelSession(_ params: AnyCodable?) async throws -> AnyCodable {
        let input: ACPCloseParameters = try decode(params)
        _ = try await requireSession(id: input.sessionID, cwd: nil)
        guard let prompt = activePrompts[input.sessionID] else { return .dictionary([:]) }
        cancelledSessions.insert(input.sessionID)
        activePermissionRequests.removeValue(forKey: input.sessionID)?.task.cancel()
        prompt.cancel()
        return .dictionary([:])
    }

    private func prompt(_ params: AnyCodable?) async throws -> AnyCodable {
        let input: ACPPromptParameters = try decode(params)
        defer { cancelledSessions.remove(input.sessionID) }
        guard let text = input.text else {
            throw JSONRPCMethodError.invalidParams("session/prompt accepts non-empty text content only")
        }
        let record = try await requireSession(id: input.sessionID, cwd: nil)
        let turnID = input.clientTurnID ?? "acp:\(record.id):\(UUID().uuidString.lowercased())"

        // A reconnect may retry a completed turn after the coordinator's
        // terminal-result cache has expired. The replay store is authoritative
        // for the bounded update stream, so consume it before attempting
        // admission and never risk a second Timeline mutation.
        if input.clientTurnID != nil,
           let existing = try? await client.replay(timelineID: record.timelineID, clientTurnID: turnID, message: text, providerID: try boundProviderID(for: record)),
           existing.terminal {
            if existing.conflict {
                throw JSONRPCMethodError.invalidParams("clientTurnID was already used with different content")
            }
            if let error = existing.updates.last(where: {
                $0.kind == "error" || $0.kind == "cancelled" || $0.kind == "cancellation"
            }) {
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
        let resultAndSequence: (AgentChatResult, Int)
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
            throw error
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
            providerID: try boundProviderID(for: record)
        )
        let updates = replay?.updates ?? []
        if updates.isEmpty, lastSequence == 0 {
            publishUpdate(
                sessionID: record.id,
                turnID: turnID,
                update: AscendantTurnUpdate(sequence: 1, kind: "assistant_text", text: result.text),
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
    ) async throws -> (AgentChatResult, Int) {
        let providerID = try boundProviderID(for: record)
        let channel = try await client.observeTurnUpdates(providerID: providerID)
        let inbox = TurnUpdateInbox()
        let collector = Task {
            for await event in channel
                where event.timelineID == record.timelineID && event.clientTurnID == turnID {
                await inbox.append(event.update)
            }
        }
        let chat = Task {
            try await client.chat(
                message: message,
                timelineID: record.timelineID,
                clientTurnID: turnID,
                providerID: providerID
            )
        }
        let completion = PromptCompletion()
        let completionWatcher = Task {
            do {
                await completion.set(.completed(try await chat.value))
            } catch {
                await completion.set(.failed(String(describing: error)))
            }
        }
        let promptToken = UUID()
        let stopTasks = {
            chat.cancel()
            collector.cancel()
            completionWatcher.cancel()
        }
        activePrompts[record.id] = ActivePrompt(
            token: promptToken,
            close: {
                stopTasks()
                Task { await completion.set(.failed("ACP session was closed")) }
            },
            cancel: {
                stopTasks()
                Task { await completion.set(.cancelled) }
            }
        )
        defer {
            chat.cancel()
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
            case .failed(let detail): throw JSONRPCMethodError.invalidState(detail)
            case .cancelled: throw CancellationError()
            case nil: break
            }
        }
    }

    fileprivate enum PromptWaitOutcome: Sendable {
        case completed(AgentChatResult)
        case failed(String)
        case cancelled
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
                try await client.respondToPermission(AgentPermissionResponse(
                    correlationID: state.correlationID,
                    timelineID: timelineID,
                    clientTurnID: turnID,
                    approved: approved
                ), providerID: try selectedAscendant().providerID)
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
        try await client.respondToPermission(AgentPermissionResponse(
            correlationID: state.correlationID,
            timelineID: timelineID,
            clientTurnID: turnID,
            approved: false
        ), providerID: try selectedAscendant().providerID)
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
            let selected = try await client.selectAscendant(id: requestedAscendantID, providerID: requestedProviderID)
            return Ascendant(
                id: selected.id,
                name: selected.name,
                timelineID: selected.timelineID,
                providerID: selected.providerID
            )
        } catch let error as RemoteChatClientError {
            throw JSONRPCMethodError.invalidState(error.localizedDescription)
        }
    }

    private func selectedAscendant() throws -> Ascendant {
        guard let ascendant else { throw JSONRPCMethodError.invalidState("ACP agent is not initialized") }
        return ascendant
    }

    private func requireSession(id: String, cwd: String?) async throws -> ACPSessionRecord {
        guard let record = await registry.record(id: id) else {
            throw JSONRPCMethodError.invalidParams("unknown ACP session")
        }
        if let cwd, cwd != record.cwd {
            throw JSONRPCMethodError.invalidParams("session cwd does not match its original binding")
        }
        let selected = try selectedAscendant()
        let legacyFingerprint = legacyProfileFingerprint(for: selected)
        guard record.ascendantID == selected.id,
              record.providerID == nil || record.providerID == selected.providerID,
              record.profileFingerprint == profileFingerprint(for: selected) || record.profileFingerprint == legacyFingerprint else {
            throw JSONRPCMethodError.invalidState("session is bound to a different Ascendant or namespace")
        }
        return record
    }

    private func profileFingerprint(for ascendant: Ascendant) -> String {
        "\(client.namespace):\(ascendant.providerID.lowercased()):\(ascendant.id.uuidString.lowercased())"
    }

    private func legacyProfileFingerprint(for ascendant: Ascendant) -> String {
        "\(client.namespace):\(ascendant.id.uuidString.lowercased())"
    }

    private func boundProviderID(for record: ACPSessionRecord) throws -> String {
        let selected = try selectedAscendant()
        guard record.providerID == nil || record.providerID == selected.providerID else {
            throw JSONRPCMethodError.invalidState("session is bound to a different provider")
        }
        return selected.providerID
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
