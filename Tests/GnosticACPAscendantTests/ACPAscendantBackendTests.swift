// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticACPAscendant
import GnosticCore
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("ACP Ascendant backend", .serialized)
struct ACPAscendantBackendTests {
    private actor RecordingPermissionService: AscendantBackendPermissionService {
        let decision: AscendantPermissionDecision
        private(set) var requests: [BackendPermissionRequest] = []

        init(decision: AscendantPermissionDecision) {
            self.decision = decision
        }

        func requestApproval(for request: BackendPermissionRequest) async -> AscendantPermissionDecision {
            requests.append(request)
            return decision
        }
    }

    private actor DelayedPermissionService: AscendantBackendPermissionService {
        private var decisionContinuation: CheckedContinuation<AscendantPermissionDecision, Never>?
        private var requestContinuation: CheckedContinuation<BackendPermissionRequest, Never>?
        private var receivedRequest: BackendPermissionRequest?

        func requestApproval(for request: BackendPermissionRequest) async -> AscendantPermissionDecision {
            await withCheckedContinuation { continuation in
                receivedRequest = request
                requestContinuation?.resume(returning: request)
                requestContinuation = nil
                decisionContinuation = continuation
            }
        }

        func waitForRequest() async -> BackendPermissionRequest {
            if let receivedRequest { return receivedRequest }
            return await withCheckedContinuation { requestContinuation = $0 }
        }

        func resolve(_ decision: AscendantPermissionDecision) {
            decisionContinuation?.resume(returning: decision)
            decisionContinuation = nil
        }
    }

    @MainActor
    private func backend(
        settings: [String: ManifestJSONValue] = ["command": .string("opencode")],
        secrets: [String: ManifestJSONValue] = [:],
        timelines: [NodeManifest.Timeline] = [],
        ascendantID: UUID = UUID(),
        permission: any AscendantBackendPermissionService = AscendantBackendServices.empty.permission
    ) throws -> ACPAscendantBackend {
        let ascendant = NodeManifest.Ascendant(
            id: ascendantID,
            name: "External agent",
            defaultTimelineID: timelines.first?.id ?? UUID(),
            backend: .init(kind: ACPAscendantBackend.kind, settings: settings, secrets: secrets)
        )
        return try ACPAscendantBackend(
            ascendant: ascendant,
            configuration: ascendant.backend,
            services: AscendantBackendServices(permission: permission),
            timelines: timelines
        )
    }

    @Test("configuration maps command, JSON args/env, cwd, and display name to a launch spec")
    @MainActor
    func configurationBuildsLaunchSpec() throws {
        let backend = try backend(settings: [
            "command": .string("opencode"),
            "args": .string("[\"acp\",\"--verbose\"]"),
            "cwd": .string("/workspace/project"),
            "env": .string("{\"MODE\":\"safe\",\"TOKEN_HINT\":\"not-secret\"}"),
            "displayName": .string("OpenCode"),
        ])

        #expect(backend.launchSpec.command == "opencode")
        #expect(backend.launchSpec.arguments == ["acp", "--verbose"])
        #expect(backend.launchSpec.workingDirectory == "/workspace/project")
        #expect(backend.launchSpec.environment == ["MODE": "safe", "TOKEN_HINT": "not-secret"])
        #expect(backend.launchSpec.displayName == "OpenCode")
    }

    @Test("plain and secret per-variable values map to the launch environment")
    @MainActor
    func perVariableEnvironmentValuesAreCombined() throws {
        let backend = try backend(
            settings: [
                "command": .string("opencode"),
                "env": .string("{\"MODE\":\"safe\"}"),
                "env.REGION": .string("test-west"),
            ],
            secrets: ["env-secret.API_TOKEN": .string("private-token")]
        )

        #expect(backend.launchSpec.environment == [
            "MODE": "safe",
            "REGION": "test-west",
            "API_TOKEN": "private-token",
        ])
        #expect(backend.launchSpec.description.contains("API_TOKEN"))
        #expect(!backend.launchSpec.description.contains("private-token"))
        #expect(!backend.launchSpec.debugDescription.contains("private-token"))
    }

    @Test("invalid per-variable names and conflicting values are rejected without exposing secrets")
    @MainActor
    func invalidDynamicEnvironmentConfigurationIsRejected() {
        #expect(throws: (any Error).self) {
            try backend(settings: [
                "command": .string("opencode"),
                "env.bad-name": .string("invalid"),
            ])
        }
        #expect(throws: (any Error).self) {
            try backend(
                settings: ["command": .string("opencode"), "env.API_TOKEN": .string("plain")],
                secrets: ["env-secret.API_TOKEN": .string("private-token")]
            )
        }
        do {
            _ = try backend(secrets: ["unrelated.API_TOKEN": .string("diagnostic-secret")])
            Issue.record("An unrelated secret key unexpectedly passed ACP configuration validation.")
        } catch {
            #expect(!String(describing: error).contains("diagnostic-secret"))
        }
    }

    @Test("malformed argument and environment JSON is rejected")
    @MainActor
    func malformedJSONIsRejected() {
        #expect(throws: (any Error).self) {
            try backend(settings: ["command": .string("opencode"), "args": .string("{not-an-array}")])
        }
        #expect(throws: (any Error).self) {
            try backend(settings: ["command": .string("opencode"), "env": .string("[\"not\",\"an object\"]")])
        }
        #expect(throws: (any Error).self) {
            try backend(settings: ["command": .string("opencode"), "env": .string("{\"COUNT\":3}")])
        }
        #expect(throws: (any Error).self) {
            try backend(settings: ["command": .string("opencode"), "env": .string("{\"bad-name\":\"value\"}")])
        }
        #expect(throws: (any Error).self) {
            try backend(settings: ["command": .string("opencode"), "env": .string("{\"BAD=NAME\":\"value\"}")])
        }
    }

    @Test("configuration requires a command and rejects undeclared or secret values")
    @MainActor
    func requiredAndUnknownConfigurationIsRejected() {
        #expect(throws: (any Error).self) { try backend(settings: [:]) }
        #expect(throws: (any Error).self) {
            try backend(settings: ["command": .string("opencode"), "apiKey": .string("secret")])
        }
        #expect(throws: (any Error).self) {
            try backend(secrets: ["env.API_KEY": .string("secret")])
        }
    }

    @Test("Timeline operations are idempotent and unknown removals are ignored")
    @MainActor
    func timelineOperationsAreIdempotent() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let configuredID = UUID()
        let timeline = NodeManifest.Timeline(id: configuredID, title: "Configured")
        let backend = try fixtureBackend(timelines: [timeline], stateHome: stateHome.url)

        _ = try await backend.createTimeline(id: configuredID, title: timeline.title)
        #expect(try await backend.operatedTimelines().map(\.id) == [configuredID])
        let created = try await backend.createTimeline(id: UUID(), title: "Runtime")
        let createdAgain = try await backend.createTimeline(id: created.id, title: "Ignored")
        #expect(createdAgain.id == created.id)
        #expect(try await backend.operatedTimelines().count == 2)
        let renamed = try await backend.renameTimeline(id: created.id, title: "Renamed")
        #expect(renamed.title == "Renamed")
        await backend.removeTimeline(id: created.id)
        await backend.removeTimeline(id: created.id)
        #expect(try await backend.operatedTimelines().map(\.id) == [configuredID])
        await backend.shutdown()
    }

    @Test("runTurn streams assistant and tool updates before a terminal completion")
    @MainActor
    func runTurnStreamsFixtureEvents() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let backend = try fixtureBackend(timelines: [.init(id: timelineID, title: "Configured")], stateHome: stateHome.url)
        let sink = RecordingUpdateSink()

        let result = try await backend.runTurn(
            .init(timelineID: timelineID, message: "hello"),
            updates: sink
        )

        #expect(result == "fixture reply: hello")
        let updates = await sink.updates
        #expect(updates.map(\.kind) == [
            AscendantTurnUpdateKind.assistantText.rawValue,
            AscendantTurnUpdateKind.assistantText.rawValue,
            AscendantTurnUpdateKind.toolCall.rawValue,
            AscendantTurnUpdateKind.toolState.rawValue,
            AscendantTurnUpdateKind.completion.rawValue,
        ])
        #expect(updates.map(\.text).compactMap { $0 }.joined() == "fixture reply: hello")
        #expect(updates[2].toolState?.toolStatus == .pending)
        #expect(updates[3].toolState?.toolStatus == .completed)
        #expect(updates.last?.terminal == true)

        let limitedSink = RecordingUpdateSink()
        do {
            _ = try await backend.runTurn(
                .init(timelineID: timelineID, message: "[fixture:max-tokens]"),
                updates: limitedSink
            )
            Issue.record("Expected the fixture's max_tokens stop reason to be terminal.")
        } catch let AscendantBackendError.terminal(failure) {
            #expect(failure.code == "acpTurnStopped")
        }
        #expect(await limitedSink.updates.last?.kind == AscendantTurnUpdateKind.error.rawValue)
        await backend.shutdown()
    }

    @Test("fixture permission requests are mediated and approved using the advertised allow-once option")
    @MainActor
    func fixturePermissionRequestCanBeApproved() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let permission = RecordingPermissionService(decision: .approved)
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, permissionPrompt: true),
            timelines: [.init(id: timelineID, title: "Configured")],
            permission: permission
        )

        let response = try await backend.runTurn(
            .init(timelineID: timelineID, message: "approve permission", clientTurnID: "approve-once"),
            updates: RecordingUpdateSink()
        )

        #expect(response == "fixture reply: approve permission")
        let requests = await permission.requests
        #expect(requests.count == 1)
        #expect(requests.first?.timelineID == timelineID)
        #expect(requests.first?.clientTurnID == "approve-once")
        #expect(requests.first?.toolCallID == "fixture-permission-tool")
        #expect(requests.first?.title == "Inspect fixture input")
        await backend.shutdown()
    }

    @Test("fixture permission denial maps to the advertised reject-once option")
    @MainActor
    func fixturePermissionRequestCanBeDenied() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let permission = RecordingPermissionService(decision: .denied)
        let backend = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url,
                permissionPrompt: true,
                permissionOutcome: "selected:reject-once"
            ),
            timelines: [.init(id: timelineID, title: "Configured")],
            permission: permission
        )

        let response = try await backend.runTurn(
            .init(timelineID: timelineID, message: "deny permission", clientTurnID: "deny-once"),
            updates: RecordingUpdateSink()
        )

        #expect(response == "fixture reply: deny permission")
        #expect(await permission.requests.count == 1)
        await backend.shutdown()
    }

    @Test("unavailable permission mediation cancels the ACP request instead of approving it")
    @MainActor
    func fixturePermissionRequestUnavailableFailsClosed() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let permission = RecordingPermissionService(decision: .unavailable(reason: "hostUnavailable"))
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, permissionPrompt: true, permissionOutcome: "cancelled"),
            timelines: [.init(id: timelineID, title: "Configured")],
            permission: permission
        )

        let response = try await backend.runTurn(
            .init(timelineID: timelineID, message: "handle unavailable permission"),
            updates: RecordingUpdateSink()
        )

        #expect(response == "fixture reply: handle unavailable permission")
        #expect(await permission.requests.count == 1)
        await backend.shutdown()
    }

    @Test("missing permission mediation service cancels the ACP request")
    @MainActor
    func missingPermissionServiceFailsClosed() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, permissionPrompt: true, permissionOutcome: "cancelled"),
            timelines: [.init(id: timelineID, title: "Configured")]
        )

        let response = try await backend.runTurn(
            .init(timelineID: timelineID, message: "handle missing permission service"),
            updates: RecordingUpdateSink()
        )

        #expect(response == "fixture reply: handle missing permission service")
        await backend.shutdown()
    }

    @Test("unsupported permission options fail closed without asking the host to approve")
    @MainActor
    func unsupportedPermissionOptionsFailClosed() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let permission = RecordingPermissionService(decision: .approved)
        let backend = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url,
                permissionPrompt: true,
                permissionOutcome: "cancelled",
                unsupportedPermissionOptions: true
            ),
            timelines: [.init(id: timelineID, title: "Configured")],
            permission: permission
        )

        let response = try await backend.runTurn(
            .init(timelineID: timelineID, message: "reject unsupported options"),
            updates: RecordingUpdateSink()
        )

        #expect(response == "fixture reply: reject unsupported options")
        #expect(await permission.requests.isEmpty)
        await backend.shutdown()
    }

    @Test("a cancelled Turn resolves an in-flight permission request with the ACP cancelled outcome")
    @MainActor
    func cancelledTurnCancelsPermissionRequest() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let permission = DelayedPermissionService()
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, permissionPrompt: true, permissionOutcome: "cancelled"),
            timelines: [.init(id: timelineID, title: "Configured")],
            permission: permission
        )
        let turn = Task {
            try await backend.runTurn(
                .init(timelineID: timelineID, message: "cancel permission request"),
                updates: RecordingUpdateSink()
            )
        }

        _ = await permission.waitForRequest()
        await backend.cancel()
        await permission.resolve(.approved)
        #expect(try await turn.value == "fixture reply: cancel permission request")
        await backend.shutdown()
    }

    @Test("agent terminal failures are terminal and leave the backend usable")
    @MainActor
    func agentFailureIsTerminal() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let backend = try fixtureBackend(timelines: [.init(id: timelineID, title: "Configured")], stateHome: stateHome.url)
        do {
            _ = try await backend.runTurn(
                .init(timelineID: timelineID, message: "[fixture:terminal-error]"),
                updates: RecordingUpdateSink()
            )
            Issue.record("Expected the fixture's terminal error.")
        } catch let AscendantBackendError.terminal(failure) {
            #expect(failure.message.contains("fixture terminal error"))
        }
        #expect(try await backend.operatedTimelines().map(\.id) == [timelineID])
        await backend.shutdown()
    }

    @Test("Timeline session mapping survives backend restart and list reconciliation")
    @MainActor
    func timelineMappingSurvivesRestart() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let ascendantID = UUID()
        let timelineID = UUID()
        let timeline = NodeManifest.Timeline(id: timelineID, title: "Runtime")
        let settings = try fixtureSettings(stateHome: stateHome.url)
        let first = try backend(settings: settings, timelines: [], ascendantID: ascendantID)
        _ = try await first.createTimeline(id: timelineID, title: timeline.title)
        _ = try await first.runTurn(
            .init(timelineID: timelineID, message: "create the durable session"),
            updates: RecordingUpdateSink()
        )
        await first.shutdown()

        let restarted = try backend(settings: settings, timelines: [], ascendantID: ascendantID)
        let firstList = try await restarted.operatedTimelines()
        let secondList = try await restarted.operatedTimelines()
        #expect(firstList.map(\.id) == [timelineID])
        #expect(secondList.map(\.id) == firstList.map(\.id))
        let resumedText = try await restarted.runTurn(
            .init(timelineID: timelineID, message: "resume the durable session"),
            updates: RecordingUpdateSink()
        )
        #expect(resumedText == "fixture reply: resume the durable session")
        await restarted.removeTimeline(id: UUID())
        #expect(try await restarted.operatedTimelines().map(\.id) == [timelineID])
        await restarted.shutdown()
    }

    @Test("session list omission falls back to local Gnostic Timeline projections")
    @MainActor
    func sessionListCapabilityIsOptional() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let timeline = NodeManifest.Timeline(id: timelineID, title: "Configured")
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, supportsList: false),
            timelines: [timeline]
        )

        #expect(try await backend.operatedTimelines().map(\.id) == [timelineID])
        await backend.shutdown()
    }

    @Test("failed best-effort session close does not poison the backend")
    @MainActor
    func failedSessionCloseDoesNotPoisonBackend() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let initialID = UUID()
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, failClose: true),
            timelines: [.init(id: initialID, title: "Initial")]
        )

        _ = try await backend.createTimeline(id: initialID, title: "Initial")
        await backend.removeTimeline(id: initialID)
        let replacementID = UUID()
        _ = try await backend.createTimeline(id: replacementID, title: "Replacement")
        let response = try await backend.runTurn(
            .init(timelineID: replacementID, message: "backend remains usable"),
            updates: RecordingUpdateSink()
        )
        #expect(response == "fixture reply: backend remains usable")
        await backend.shutdown()
    }

    @MainActor
    private func fixtureBackend(
        timelines: [NodeManifest.Timeline],
        ascendantID: UUID = UUID(),
        stateHome: URL
    ) throws -> ACPAscendantBackend {
        try backend(settings: fixtureSettings(stateHome: stateHome), timelines: timelines, ascendantID: ascendantID)
    }

    private func fixtureSettings(
        stateHome: URL,
        supportsList: Bool = true,
        failClose: Bool = false,
        permissionPrompt: Bool = false,
        permissionOutcome: String = "selected:allow-once",
        unsupportedPermissionOptions: Bool = false
    ) throws -> [String: ManifestJSONValue] {
        let fixturePath = ProcessInfo.processInfo.environment["GNOSTIC_ACP_AGENT_FIXTURE"]
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/ACPAgent/agent.mjs")
                .path
        let statePath = stateHome.appendingPathComponent("agent-sessions.json").path
        var fixtureEnvironment = ["GNOSTIC_ACP_FIXTURE_STATE": statePath]
        if !supportsList { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_NO_LIST"] = "1" }
        if failClose { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_CLOSE_ERROR"] = "1" }
        if permissionPrompt {
            fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PERMISSION"] = "1"
            fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PERMISSION_OUTCOME"] = permissionOutcome
        }
        if unsupportedPermissionOptions { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PERMISSION_UNSUPPORTED"] = "1" }
        let encodedEnvironment = try JSONEncoder().encode(fixtureEnvironment)
        return [
            "command": .string("/usr/bin/node"),
            "args": .string(try #require(String(data: JSONEncoder().encode([fixturePath]), encoding: .utf8))),
            "env": .string(try #require(String(data: encodedEnvironment, encoding: .utf8))),
        ]
    }

    private func makeTemporaryStateHome() throws -> TemporaryStateHome {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-acp-test-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let originalValue = getenv("GNOSTIC_STATE_HOME").map { String(cString: $0) }
        guard setenv("GNOSTIC_STATE_HOME", url.path, 1) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        return TemporaryStateHome(url: url, previousValue: originalValue)
    }

    private struct TemporaryStateHome {
        let url: URL
        let previousValue: String?

        func cleanup() {
            if let previousValue {
                _ = setenv("GNOSTIC_STATE_HOME", previousValue, 1)
            } else {
                _ = unsetenv("GNOSTIC_STATE_HOME")
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private actor RecordingUpdateSink: AscendantBackendUpdateSink {
        private(set) var updates: [AscendantBackendUpdate] = []

        func append(_ update: AscendantBackendUpdate) async throws {
            updates.append(update)
        }
    }
}
