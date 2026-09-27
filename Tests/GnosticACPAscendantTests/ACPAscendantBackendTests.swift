// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticACPAscendant
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

    private actor BackendFactoryCount {
        private(set) var value = 0

        func increment() { value += 1 }
    }

    private actor DelayedPermissionService: AscendantBackendPermissionService {
        private var decisionContinuation: CheckedContinuation<AscendantPermissionDecision, Never>?
        private var receivedRequest: BackendPermissionRequest?
        private(set) var cancellationCount = 0

        func requestApproval(for request: BackendPermissionRequest) async -> AscendantPermissionDecision {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    receivedRequest = request
                    decisionContinuation = continuation
                }
            } onCancel: {
                Task { await self.recordCancellation() }
            }
        }

        func waitForRequest(timeout: Duration = .seconds(5)) async -> BackendPermissionRequest? {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if let receivedRequest { return receivedRequest }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return receivedRequest
        }

        func resolve(_ decision: AscendantPermissionDecision) {
            decisionContinuation?.resume(returning: decision)
            decisionContinuation = nil
        }

        private func recordCancellation() { cancellationCount += 1 }
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
                "args": .string("[\"private-token\"]"),
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

    @Test("agent receives configured environment only, not unrelated parent credentials")
    @MainActor
    func processEnvironmentIsAllowlisted() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let key = "GNOSTIC_ACP_PARENT_ONLY_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let secret = "parent-secret-\(UUID().uuidString)"
        guard setenv(key, secret, 1) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { _ = unsetenv(key) }

        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, requiredAbsentEnvironmentKey: key),
            timelines: [.init(id: UUID(), title: "Allowlist")]
        )
        _ = try await backend.operatedTimelines()
        await backend.shutdown()
    }

    @Test("process spawn failure is lifecycle unusable and does not expose configured secrets")
    @MainActor
    func spawnFailureIsLifecycleUnusableAndRedacted() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let secret = "spawn-secret-\(UUID().uuidString)"
        let timelineID = UUID()
        let backend = try backend(
            settings: ["command": .string("/missing/acp-agent-\(UUID().uuidString)")],
            secrets: ["env-secret.API_TOKEN": .string(secret)],
            timelines: [.init(id: timelineID, title: "Missing agent")]
        )

        do {
            _ = try await backend.runTurn(.init(timelineID: timelineID, message: "hello"), updates: RecordingUpdateSink())
            Issue.record("Expected the missing ACP agent process to fail.")
        } catch let AscendantBackendError.lifecycleUnusable(failure) {
            #expect(!failure.message.contains(secret))
            #expect(!String(describing: failure).contains(secret))
        }
        await backend.shutdown()
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

    @Test("configuration validation names an unusable setting without printing secret values")
    @MainActor
    func validateConfigurationFailsFastAndRedactsSecrets() throws {
        let secret = "validation-secret-\(UUID().uuidString)"
        let cwdBackend = try backend(
            settings: ["command": .string("/missing/acp-command"), "cwd": .string("/missing/acp-working-directory")],
            secrets: ["env-secret.API_TOKEN": .string(secret)]
        )

        do {
            try cwdBackend.validateConfiguration()
            Issue.record("Expected configuration validation to reject the missing cwd.")
        } catch let AscendantBackendError.invalidConfiguration(message) {
            #expect(message.contains("cwd"))
            #expect(!message.contains(secret))
        }

        let invalidCommand = try backend(settings: ["command": .string("/missing/acp-command")])
        do {
            try invalidCommand.validateConfiguration()
            Issue.record("Expected configuration validation to reject the missing executable.")
        } catch let AscendantBackendError.invalidConfiguration(message) {
            #expect(message.contains("command"))
        }
    }

    @Test("stderr secret redaction spans separate pipe reads")
    func stderrRedactionHandlesReadBoundaries() {
        let redactor = ACPStderrRedactor(secrets: ["private-token"])
        let first = redactor.consume(Data("agent says private-".utf8))
        let second = redactor.consume(Data("token and private-token again\n".utf8), finishing: true)
        let result = String(decoding: first + second, as: UTF8.self)
        #expect(result == "agent says [REDACTED] and [REDACTED] again\n")
        #expect(!result.contains("private-token"))

        let straddlingRedactor = ACPStderrRedactor(secrets: ["SECRET"])
        let prefix = straddlingRedactor.consume(Data("SECRET".utf8))
        let remainder = straddlingRedactor.consume(Data(), finishing: true)
        let straddlingResult = String(decoding: prefix + remainder, as: UTF8.self)
        #expect(straddlingResult == "[REDACTED]")
        #expect(!straddlingResult.contains("S"))
    }

    @Test("concurrent first connections spawn only one ACP process")
    @MainActor
    func concurrentConnectionEstablishmentIsSingleFlight() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let processIDs = stateHome.url.appendingPathComponent("process-ids.txt")
        let startCount = stateHome.url.appendingPathComponent("start-count.txt")
        let backend = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url,
                processPIDFile: processIDs,
                startCountFile: startCount
            ),
            timelines: [.init(id: UUID(), title: "Concurrent startup")]
        )

        async let first = backend.operatedTimelines()
        async let second = backend.operatedTimelines()
        _ = try await (first, second)
        await backend.shutdown()

        let starts = try String(contentsOf: startCount, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        #expect(starts.count == 1, "Concurrent startup launched \(starts.count) ACP processes.")
        let launchedPIDs = try String(contentsOf: processIDs, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
        for pid in launchedPIDs { _ = kill(-pid, SIGKILL) }
    }

    @Test("shutdown waits for in-flight connection setup and leaves no process")
    @MainActor
    func shutdownDuringConnectionSetupCleansProcess() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let processIDs = stateHome.url.appendingPathComponent("process-ids.txt")
        let backend = try backend(settings: fixtureSettings(
            stateHome: stateHome.url,
            processPIDFile: processIDs,
            initializeDelayMilliseconds: 1_000
        ))
        let connection = Task { try await backend.operatedTimelines() }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: processIDs.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: processIDs.path))

        await backend.shutdown()
        do {
            _ = try await connection.value
            Issue.record("Connection setup unexpectedly completed after shutdown.")
        } catch { /* Shutdown rejects or interrupts the in-flight connection. */ }

        let launchedPIDs = try String(contentsOf: processIDs, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
        for pid in launchedPIDs {
            #expect(kill(pid, 0) != 0, "ACP process \(pid) survived shutdown during connection setup")
        }
    }

    @Test("same-Timeline concurrent Turns do not replace active cancellation state")
    @MainActor
    func concurrentTurnsOnOneTimelineAreRejectedWithoutReplacingActiveTurn() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let promptStarted = stateHome.url.appendingPathComponent("prompt-started")
        let backend = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url,
                promptDelayMilliseconds: 1_000,
                promptStartedFile: promptStarted
            ),
            timelines: [.init(id: timelineID, title: "Single active Turn")]
        )
        let first = Task {
            try await backend.runTurn(
                .init(timelineID: timelineID, message: "first"),
                updates: RecordingUpdateSink()
            )
        }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: promptStarted.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: promptStarted.path))

        do {
            _ = try await backend.runTurn(
                .init(timelineID: timelineID, message: "second"),
                updates: RecordingUpdateSink()
            )
            Issue.record("A second same-Timeline Turn unexpectedly replaced the active Turn.")
        } catch let AscendantBackendError.terminal(failure) {
            #expect(failure.code == "acpTurnAlreadyActive")
        }
        #expect(try await first.value == "fixture reply: first")
        await backend.shutdown()
    }

    @Test("scoped cancellation reaches one ACP session and preserves another Timeline Turn")
    @MainActor
    func scopedCancellationStopsOnlyTheAddressedTimeline() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let firstTimelineID = UUID()
        let secondTimelineID = UUID()
        let cancelFile = stateHome.url.appendingPathComponent("cancelled-sessions.txt")
        let promptStarted = stateHome.url.appendingPathComponent("prompt-started")
        let backend = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url,
                promptStartedFile: promptStarted,
                cancellationFile: cancelFile
            ),
            timelines: [
                .init(id: firstTimelineID, title: "Cancel target"),
                .init(id: secondTimelineID, title: "Concurrent survivor"),
            ]
        )
        let cancelledUpdates = RecordingUpdateSink()
        let first = Task {
            try await backend.runTurn(
                .init(timelineID: firstTimelineID, message: "[fixture:wait]", clientTurnID: "turn-a"),
                updates: cancelledUpdates
            )
        }
        let second = Task {
            try await backend.runTurn(
                .init(timelineID: secondTimelineID, message: "survive", clientTurnID: "turn-b"),
                updates: RecordingUpdateSink()
            )
        }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: promptStarted.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: promptStarted.path))

        await backend.cancelTurn(timelineID: firstTimelineID, clientTurnID: " turn-a ")

        do {
            _ = try await first.value
            Issue.record("The addressed ACP Turn unexpectedly completed successfully.")
        } catch let error as AscendantBackendError {
            guard case .cancelled = error else {
                Issue.record("Expected ACP cancellation, received \(error).")
                await backend.shutdown()
                return
            }
        }
        do {
            #expect(try await second.value == "fixture reply: survive")
        } catch {
            Issue.record("The unrelated Timeline Turn failed after scoped cancellation: \(error).")
        }
        let cancellationIDs = (try? String(contentsOf: cancelFile, encoding: .utf8))?
            .split(whereSeparator: \.isNewline).map(String.init) ?? []
        let sessionsData = try Data(contentsOf: stateHome.url.appendingPathComponent("\(backend.identity.id.uuidString).json"))
        let sessions = try #require(JSONSerialization.jsonObject(with: sessionsData) as? [String: [String: Any]])
        let targetSessionID = try #require(sessions[firstTimelineID.uuidString]?["sessionID"] as? String)
        #expect(cancellationIDs == [targetSessionID])
        #expect(await cancelledUpdates.updates.allSatisfy { $0.text != "late update" })
        await backend.shutdown()
    }

    @Test("shutdown terminates the agent process group and reaps its descendants")
    @MainActor
    func shutdownCleansProcessTree() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let pidFile = stateHome.url.appendingPathComponent("descendant.pid")
        let backend = try backend(settings: fixtureSettings(stateHome: stateHome.url, descendantPIDFile: pidFile))
        _ = try await backend.operatedTimelines()
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let childPID = try #require(Int32(pidText))

        await backend.shutdown()

        var isAlive = kill(childPID, 0) == 0
        for _ in 0..<40 where isAlive {
            try await Task.sleep(for: .milliseconds(25))
            isAlive = kill(childPID, 0) == 0
        }
        #expect(!isAlive, "ACP child process \(childPID) survived backend shutdown")
    }

    @Test("an ACP process crash is reported as lifecycle unusable")
    @MainActor
    func crashIsLifecycleUnusable() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let secret = "crash-secret-\(UUID().uuidString)"
        let backend = try backend(
            settings: fixtureSettings(stateHome: stateHome.url, crashOnPrompt: true),
            secrets: ["env-secret.API_TOKEN": .string(secret)],
            timelines: [.init(id: timelineID, title: "Crash")]
        )

        do {
            _ = try await backend.runTurn(.init(timelineID: timelineID, message: "crash"), updates: RecordingUpdateSink())
            Issue.record("Expected a crashed ACP process to make its lifecycle unusable.")
        } catch let AscendantBackendError.lifecycleUnusable(failure) {
            #expect(!failure.message.contains(secret))
        }
        await backend.shutdown()
    }

    @Test("crashed process is quarantined and reconstructed once on the next Turn")
    @MainActor
    func crashQuarantinesAndReconstructsBackend() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let ascendantID = UUID()
        let timelineID = UUID()
        let crashMarker = stateHome.url.appendingPathComponent("crashed-once")
        let settings = try fixtureSettings(stateHome: stateHome.url, crashOnceMarker: crashMarker)
        let configuration = AscendantBackendConfiguration(kind: ACPAscendantBackend.kind, settings: settings)
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "acp-crash-\(UUID().uuidString.lowercased())"),
            node: .init(id: UUID()),
            ascendants: [.init(id: ascendantID, name: "Crash fixture", defaultTimelineID: timelineID, backend: configuration)],
            timelines: [.init(id: timelineID, title: "Crash recovery", operatingAscendantID: ascendantID)]
        )
        let factoryCount = BackendFactoryCount()
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(
            kind: ACPAscendantBackend.kind,
            settings: ACPAscendantBackend.settingsSchema
        ) { ascendant, backendConfiguration, services, timelines in
            await factoryCount.increment()
            return try ACPAscendantBackend(
                ascendant: ascendant,
                configuration: backendConfiguration,
                services: services,
                timelines: timelines
            )
        }
        let runtime = try await NodeRuntime(plan: manifest.compileLaunchPlan(), adapters: adapters)
        try await runtime.start()

        do {
            _ = try await runtime.turn(.init(message: "crash", timelineID: timelineID, clientTurnID: "crash-once"))
            Issue.record("Expected the first ACP Turn to fail with a lifecycle error.")
        } catch let AscendantTurnError.lifecycleUnusable(failedTimelineID, _, _) {
            #expect(failedTimelineID == timelineID)
        } catch {
            await runtime.shutdown()
            throw error
        }
        #expect(await runtime.backendHealth(for: ascendantID) == .failed)

        let recovered = try await runtime.turn(.init(message: "recover", timelineID: timelineID, clientTurnID: "after-crash"))
        #expect(recovered.text == "fixture reply: recover")
        #expect(await factoryCount.value == 2)
        #expect(await runtime.backendHealth(for: ascendantID) == .healthy)
        await runtime.shutdown()
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

    @Test("a prompt that streams for longer than the request default completes")
    @MainActor
    func longStreamingPromptCompletesWithoutQuarantiningBackend() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let backend = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url,
                promptProgressDurationMilliseconds: 31_000
            ),
            timelines: [.init(id: timelineID, title: "Long Turn")]
        )
        let sink = RecordingUpdateSink()

        let response = try await backend.runTurn(
            .init(timelineID: timelineID, message: "do long work"),
            updates: sink
        )

        #expect(response.contains("fixture reply: do long work"))
        #expect(await sink.updates.filter { $0.kind == AscendantTurnUpdateKind.assistantText.rawValue }.count >= 8)
        #expect(try await backend.operatedTimelines().map(\.id) == [timelineID])
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

        guard await permission.waitForRequest() != nil else {
            Issue.record("The fixture did not issue its permission request before the deadline.")
            await backend.shutdown()
            return
        }
        await backend.cancel()
        await permission.resolve(.approved)
        #expect(try await turn.value == "fixture reply: cancel permission request")
        await backend.shutdown()
    }

    @Test("scoped cancellation settles while host permission remains unresolved")
    @MainActor
    func scopedCancellationUnblocksPendingPermission() async throws {
        let stateHome = try makeTemporaryStateHome()
        defer { stateHome.cleanup() }
        let timelineID = UUID()
        let cancelFile = stateHome.url.appendingPathComponent("cancelled-sessions.txt")
        let permission = DelayedPermissionService()
        let backend = try backend(
            settings: fixtureSettings(
                stateHome: stateHome.url,
                permissionPrompt: true,
                permissionOutcome: "cancelled",
                cancellationFile: cancelFile
            ),
            timelines: [.init(id: timelineID, title: "Pending permission")],
            permission: permission
        )
        let turn = Task {
            try await backend.runTurn(
                .init(timelineID: timelineID, message: "wait for permission", clientTurnID: "permission-turn"),
                updates: RecordingUpdateSink()
            )
        }

        guard await permission.waitForRequest() != nil else {
            Issue.record("The fixture did not issue its permission request before the deadline.")
            await backend.shutdown()
            return
        }
        await backend.cancelTurn(timelineID: timelineID, clientTurnID: "permission-turn")
        for _ in 0..<100 where await permission.cancellationCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await permission.cancellationCount == 1)

        do {
            _ = try await turn.value
            Issue.record("The Turn with an unresolved permission request unexpectedly succeeded.")
        } catch let error as AscendantBackendError {
            guard case .cancelled = error else {
                Issue.record("Expected cancellation, received \(error).")
                await backend.shutdown()
                return
            }
        }
        let cancellationCount = (try? String(contentsOf: cancelFile, encoding: .utf8))?
            .split(whereSeparator: \.isNewline).count ?? 0
        #expect(cancellationCount == 1)
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
        unsupportedPermissionOptions: Bool = false,
        requiredAbsentEnvironmentKey: String? = nil,
        crashOnPrompt: Bool = false,
        descendantPIDFile: URL? = nil,
        crashOnceMarker: URL? = nil,
        processPIDFile: URL? = nil,
        startCountFile: URL? = nil,
        initializeDelayMilliseconds: Int? = nil,
        promptDelayMilliseconds: Int? = nil,
        promptProgressDurationMilliseconds: Int? = nil,
        promptStartedFile: URL? = nil,
        cancellationFile: URL? = nil
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
        if let requiredAbsentEnvironmentKey {
            fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PARENT_ONLY_KEY"] = requiredAbsentEnvironmentKey
        }
        if crashOnPrompt { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_CRASH_ON_PROMPT"] = "1" }
        if let descendantPIDFile { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_CHILD_PID_FILE"] = descendantPIDFile.path }
        if let crashOnceMarker { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_CRASH_ONCE_FILE"] = crashOnceMarker.path }
        if let processPIDFile { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PROCESS_PID_FILE"] = processPIDFile.path }
        if let startCountFile { fixtureEnvironment["GNOSTIC_ACP_FIXTURE_START_COUNT_FILE"] = startCountFile.path }
        if let initializeDelayMilliseconds {
            fixtureEnvironment["GNOSTIC_ACP_FIXTURE_INITIALIZE_DELAY_MS"] = String(initializeDelayMilliseconds)
        }
        if let promptDelayMilliseconds {
            fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PROMPT_DELAY_MS"] = String(promptDelayMilliseconds)
        }
        if let promptProgressDurationMilliseconds {
            fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PROMPT_PROGRESS_DURATION_MS"] = String(promptProgressDurationMilliseconds)
        }
        if let promptStartedFile {
            fixtureEnvironment["GNOSTIC_ACP_FIXTURE_PROMPT_STARTED_FILE"] = promptStartedFile.path
        }
        if let cancellationFile {
            fixtureEnvironment["GNOSTIC_ACP_FIXTURE_CANCEL_FILE"] = cancellationFile.path
        }
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
