// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import PKShared
import PositronicKit
import Testing

@testable import GnosticCLI

@Suite("ACP provider acceptance", .serialized)
struct ACPProviderAcceptanceTests {
    @Test("two NodeRuntime instances advertise multiple Ascendants in one namespace")
    @MainActor
    func discoversAscendantsAcrossTwoNodeRuntimes() async throws {
        let namespace = "acp-provider-discovery-\(UUID().uuidString.lowercased())"
        let sharedAscendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000202")!
        let first = try await NodeRuntime(
            plan: try acceptanceManifest(
                namespace: namespace,
                nodeID: "A21D0000-0000-4000-8000-000000000201",
                ascendantID: sharedAscendantID,
                timelineID: "A21D0000-0000-4000-8000-000000000203",
                name: "First Ascendant"
            ).compileLaunchPlan(),
            adapters: acceptanceAdapters()
        )
        let second = try await NodeRuntime(
            plan: try acceptanceManifest(
                namespace: namespace,
                nodeID: "A21D0000-0000-4000-8000-000000000204",
                ascendantID: sharedAscendantID,
                timelineID: "A21D0000-0000-4000-8000-000000000206",
                name: "Second Ascendant"
            ).compileLaunchPlan(),
            adapters: acceptanceAdapters()
        )
        defer {
            Task { @MainActor in
                await first.shutdown()
                await second.shutdown()
            }
        }

        try await first.start()
        try await second.start()

        let client = try RemoteChatClient(host: "127.0.0.1", port: 1883, namespace: namespace)
        defer { client.stop() }
        try await client.connect()
        try await poll(timeout: .seconds(8)) {
            await client.discoverAscendants().count == 2
        }

        let ascendants = await client.discoverAscendants()
        #expect(Set(ascendants.map(\.name)) == ["First Ascendant", "Second Ascendant"])
        #expect(Set(ascendants.map(\.providerID)).count == 2)
        for ascendant in ascendants {
            #expect(try await client.selectAscendant(id: ascendant.id, providerID: ascendant.providerID) == ascendant)
        }
        await #expect(throws: RemoteChatClientError.self) {
            _ = try await client.selectAscendant(id: sharedAscendantID)
        }

        if let binary = ProcessInfo.processInfo.environment["GNOSTIC_ACP_BINARY"] {
            let stateURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("gnostic-acp-duplicate-provider-state-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: stateURL) }
            var environment = ProcessInfo.processInfo.environment
            environment["GNOSTIC_STATE_HOME"] = stateURL.path
            let profiles = try await runACPProfiles(
                binary: binary,
                host: "127.0.0.1",
                port: 1883,
                namespace: namespace,
                environment: environment
            )
            #expect(Set(profiles.profiles.map(\.id)).count == 2)
            #expect(profiles.profiles.allSatisfy { profile in
                profile.id.hasPrefix("gnostic-\(sharedAscendantID.uuidString.lowercased())-")
                    && profile.args.contains("--provider")
            })
            #expect(Set(profiles.profiles.compactMap { profile in
                guard let index = profile.args.firstIndex(of: "--provider"),
                      profile.args.indices.contains(index + 1) else { return nil }
                return profile.args[index + 1]
            }) == Set(ascendants.map { $0.providerID.lowercased() }))
        }
    }

    @Test(
        "ACP binds new, resume, list, prompt, and close to the selected Ascendant provider",
        .timeLimit(.minutes(1))
    )
    @MainActor
    func selectedProviderOwnsACPSessionLifecycle() async throws {
        guard let binary = ProcessInfo.processInfo.environment["GNOSTIC_ACP_BINARY"]
                ?? ProcessInfo.processInfo.environment["GNOSTIC_CLI_BINARY"] else { return }

        let namespace = "acp-provider-session-\(UUID().uuidString.lowercased())"
        let firstAscendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000212")!
        let secondAscendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000215")!
        let first = try await NodeRuntime(
            plan: try acceptanceManifest(
                namespace: namespace,
                nodeID: "A21D0000-0000-4000-8000-000000000211",
                ascendantID: firstAscendantID,
                timelineID: "A21D0000-0000-4000-8000-000000000213",
                name: "First ACP Ascendant"
            ).compileLaunchPlan(),
            adapters: acceptanceAdapters()
        )
        let second = try await NodeRuntime(
            plan: try acceptanceManifest(
                namespace: namespace,
                nodeID: "A21D0000-0000-4000-8000-000000000214",
                ascendantID: secondAscendantID,
                timelineID: "A21D0000-0000-4000-8000-000000000216",
                name: "Second ACP Ascendant"
            ).compileLaunchPlan(),
            adapters: acceptanceAdapters()
        )
        defer {
            Task { @MainActor in
                await first.shutdown()
                await second.shutdown()
            }
        }
        try await first.start()
        try await second.start()

        let discoveryClient = try RemoteChatClient(host: "127.0.0.1", port: 1883, namespace: namespace)
        defer { discoveryClient.stop() }
        try await discoveryClient.connect()
        let selected = try await waitForAscendant(secondAscendantID, using: discoveryClient)
        let other = try await discoveryClient.selectAscendant(id: firstAscendantID)

        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-acp-provider-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        var environment = ProcessInfo.processInfo.environment
        environment["GNOSTIC_STATE_HOME"] = stateURL.path
        environment["GNOSTIC_CONFIG"] = stateURL.appendingPathComponent("config.json").path

        let profiles = try await runACPProfiles(
            binary: binary,
            host: "127.0.0.1",
            port: 1883,
            namespace: namespace,
            environment: environment
        )
        #expect(profiles.profiles.map(\.id) == [
            "gnostic-\(firstAscendantID.uuidString.lowercased())",
            "gnostic-\(secondAscendantID.uuidString.lowercased())",
        ])
        #expect(profiles.profiles.allSatisfy { profile in
            profile.args.contains("--ascendant") && profile.args.contains("--provider")
        })

        let session = try launchACP(
            binary: binary,
            ascendantID: selected.id,
            providerID: selected.providerID,
            host: "127.0.0.1",
            port: 1883,
            namespace: namespace,
            environment: environment
        )
        defer {
            if session.process.isRunning { session.process.terminate() }
        }

        try session.send(JSONRPCRequest(id: .number(1), method: "initialize", params: .dictionary([
            "protocolVersion": .number(1),
            "clientInfo": .dictionary(["name": .string("provider-acceptance"), "version": .string("1")]),
        ])))
        var output = session.lines.stream.makeAsyncIterator()
        #expect(try await readResponse(from: &output).error == nil)

        try session.send(JSONRPCRequest(id: .number(2), method: "session/new", params: .dictionary([
            "cwd": .string("/tmp/acp-provider-acceptance"),
            "mcpServers": .array([]),
        ])))
        let created = try await readResponse(from: &output)
        #expect(created.error == nil)
        let createdResult = try #require(created.result)
        guard case let .dictionary(createdValues) = createdResult,
              case let .string(sessionID) = createdValues["sessionId"],
              case let .dictionary(metadata) = createdValues["_meta"],
              case let .string(ascendantRaw) = metadata["gnosticAscendantID"],
              case let .string(timelineRaw) = metadata["gnosticTimelineID"],
              let timelineID = UUID(uuidString: timelineRaw) else {
            Issue.record("session/new did not return ACP binding metadata")
            return
        }
        #expect(ascendantRaw == selected.id.uuidString.lowercased())
        let selectedTimelines = try await discoveryClient.listTimelines(providerID: selected.providerID)
        let otherTimelines = try await discoveryClient.listTimelines(providerID: other.providerID)
        #expect(selectedTimelines.contains { $0.timelineID == timelineID })
        #expect(!otherTimelines.contains { $0.timelineID == timelineID })

        try session.send(JSONRPCRequest(id: .number(3), method: "session/resume", params: .dictionary([
            "sessionId": .string(sessionID),
            "cwd": .string("/tmp/acp-provider-acceptance"),
            "mcpServers": .array([]),
        ])))
        #expect(try await readResponse(from: &output).error == nil)

        try session.send(JSONRPCRequest(id: .number(4), method: "session/list", params: .dictionary([
            "cwd": .string("/tmp/acp-provider-acceptance")
        ])))
        let listed = try await readResponse(from: &output)
        #expect(listed.error == nil)
        guard case let .dictionary(listedValues) = listed.result,
              case let .array(sessions) = listedValues["sessions"] else {
            Issue.record("session/list returned no sessions array")
            return
        }
        #expect(sessions.contains { value in
            guard case let .dictionary(values) = value,
                  case let .string(id) = values["sessionId"] else { return false }
            return id == sessionID
        })

        try session.send(JSONRPCRequest(id: .number(5), method: "session/prompt", params: .dictionary([
            "sessionId": .string(sessionID),
            "prompt": .array([.dictionary(["type": .string("text"), "text": .string("hello")])]),
            "mcpServers": .array([]),
            "_meta": .dictionary([ACPProtocol.turnIDMetadataKey: .string("provider-acceptance:turn-1")]),
        ])))
        let prompted = try await readResponse(from: &output)
        #expect(prompted.error == nil)
        #expect(prompted.result == .dictionary(["stopReason": .string("end_turn")]))

        try session.send(JSONRPCRequest(id: .number(6), method: "session/close", params: .dictionary([
            "sessionId": .string(sessionID)
        ])))
        #expect(try await readResponse(from: &output).error == nil)

        try session.send(JSONRPCRequest(id: .number(7), method: "session/resume", params: .dictionary([
            "sessionId": .string(sessionID),
            "cwd": .string("/tmp/acp-provider-acceptance"),
            "mcpServers": .array([]),
        ])))
        #expect(try await readResponse(from: &output).error == nil)

        try session.send(JSONRPCRequest(id: .number(8), method: "shutdown"))
        #expect(try await readResponse(from: &output).error == nil)
        session.input.fileHandleForWriting.closeFile()
        session.process.waitUntilExit()

        let mismatched = try launchACP(
            binary: binary,
            ascendantID: other.id,
            providerID: other.providerID,
            host: "127.0.0.1",
            port: 1883,
            namespace: namespace,
            environment: environment
        )
        defer {
            if mismatched.process.isRunning { mismatched.process.terminate() }
        }
        try mismatched.send(JSONRPCRequest(id: .number(9), method: "initialize", params: .dictionary([
            "protocolVersion": .number(1),
            "clientInfo": .dictionary(["name": .string("provider-acceptance"), "version": .string("1")]),
        ])))
        var mismatchedOutput = mismatched.lines.stream.makeAsyncIterator()
        #expect(try await readResponse(from: &mismatchedOutput).error == nil)
        try mismatched.send(JSONRPCRequest(id: .number(10), method: "session/resume", params: .dictionary([
            "sessionId": .string(sessionID),
            "cwd": .string("/tmp/acp-provider-acceptance"),
            "mcpServers": .array([]),
        ])))
        #expect(try await readResponse(from: &mismatchedOutput).error != nil)
        try mismatched.send(JSONRPCRequest(id: .number(11), method: "shutdown"))
        #expect(try await readResponse(from: &mismatchedOutput).error == nil)
        mismatched.input.fileHandleForWriting.closeFile()
        mismatched.process.waitUntilExit()
    }

    @Test(
        "legacy flat config migrates to schema v2 and drives a configured NodeRuntime chat tool turn",
        .timeLimit(.minutes(1))
    )
    @MainActor
    func legacyMigrationToConfiguredRuntimeSmoke() async throws {
        let folder = try TemporaryFolder()
        let namespace = "legacy-runtime-\(UUID().uuidString.lowercased())"
        let configURL = folder.url.appendingPathComponent("config.json")
        let legacy = """
        {"mqtt.host":"127.0.0.1","mqtt.port":1883,"mqtt.namespace":"\(namespace)","llm.provider":"stub","llm.model":"deterministic"}
        """
        _ = FileManager.default.createFile(atPath: configURL.path, contents: Data(legacy.utf8))

        let store = CLIConfigurationStore(configPath: configURL, environment: [:])
        let migrated = try store.loadManifest()
        #expect(migrated.schemaVersion == 2)
        #expect(migrated.llmProfiles.count == 1)
        #expect(FileManager.default.fileExists(atPath: store.legacyBackupPath().path))

        let workspaceID = try #require(migrated.workspaces.first?.id)
        let configured = try store.mutateManifest { manifest in
            manifest.timelines[0].attachments = [.local(workspaceID)]
        }
        let plan = try configured.compileLaunchPlan()
        #expect(plan.ascendants.count == 1)
        #expect(plan.timelines.first?.attachments == [.local(workspaceID)])

        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.register(kind: "positronic") { _, _ in StubLanguageModel() }
        let runtime = try await NodeRuntime(plan: plan, adapters: adapters)
        defer {
            Task { @MainActor in await runtime.shutdown() }
        }
        try await runtime.start()

        let client = try RemoteChatClient(host: "127.0.0.1", port: 1883, namespace: namespace)
        defer { client.stop() }
        try await client.connect()
        let ascendant = try await waitForOnlyAscendant(using: client)
        let profiles = try await runACPProfilesIfAvailable(
            host: "127.0.0.1",
            port: 1883,
            namespace: namespace,
            configURL: configURL,
            stateHome: folder.url.appendingPathComponent("state")
        )
        if let profiles {
            #expect(profiles.profiles.map(\.id) == ["gnostic-\(ascendant.id.uuidString.lowercased())"])
        }

        let created = try await client.createTimeline(
            title: "Migrated smoke timeline",
            ascendantID: ascendant.id,
            providerID: ascendant.providerID
        )
        let workspace = try #require(try await client.listWorkspaces(providerID: ascendant.providerID).first { $0.id == workspaceID })
        #expect(workspace.isAvailable)
        #expect(try await client.attach(
            workspaceID: workspaceID,
            timelineID: created.timelineID,
            providerID: ascendant.providerID
        ))

        let result = try await client.chat(
            message: "echo network",
            timelineID: created.timelineID,
            clientTurnID: "legacy-smoke:turn-1",
            providerID: ascendant.providerID
        )
        #expect(result.text == "Echo received: network")
        #expect(!result.replayed)
    }
}

private func acceptanceAdapters() -> NodeRuntimeAdapters {
    var adapters = NodeRuntimeAdapters.default
    adapters.ascendants.register(kind: "positronic") { _, _ in AcceptanceFinalLanguageModel() }
    return adapters
}

private func acceptanceManifest(
    namespace: String,
    nodeID: String,
    ascendantID: UUID,
    timelineID: String,
    name: String
) throws -> NodeManifest {
    let nodeID = try #require(UUID(uuidString: nodeID))
    let timelineID = try #require(UUID(uuidString: timelineID))
    let profileID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000299")!
    return NodeManifest(
        broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
        node: .init(id: nodeID),
        llmProfiles: [.init(id: profileID, provider: "stub", model: "deterministic")],
        ascendants: [.init(id: ascendantID, name: name, defaultTimelineID: timelineID, llmProfileID: profileID)],
        timelines: [.init(id: timelineID, title: "\(name) Timeline", operatingAscendantID: ascendantID)]
    )
}

private func waitForAscendant(
    _ id: UUID,
    using client: RemoteChatClient
) async throws -> RemoteChatClient.DiscoveredAscendant {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(8)
    while clock.now < deadline {
        if let result = try? await client.selectAscendant(id: id) { return result }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw ACPSubprocessError.timeout
}

private func waitForOnlyAscendant(
    using client: RemoteChatClient
) async throws -> RemoteChatClient.DiscoveredAscendant {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(8)
    while clock.now < deadline {
        let ascendants = await client.discoverAscendants()
        if ascendants.count == 1 { return ascendants[0] }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw ACPSubprocessError.timeout
}

private func runACPProfiles(
    binary: String,
    host: String,
    port: Int,
    namespace: String,
    environment: [String: String]
) async throws -> ACPProfileBundle {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = [
        "acp", "profiles", "--json", "--refresh",
        "--host", host, "--port", String(port), "--namespace", namespace,
    ]
    process.environment = environment
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    while process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
    let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, Comment(rawValue: stderr))
    return try JSONDecoder().decode(ACPProfileBundle.self, from: output.fileHandleForReading.readDataToEndOfFile())
}

private func runACPProfilesIfAvailable(
    host: String,
    port: Int,
    namespace: String,
    configURL: URL,
    stateHome: URL
) async throws -> ACPProfileBundle? {
    guard let binary = ProcessInfo.processInfo.environment["GNOSTIC_ACP_BINARY"]
            ?? ProcessInfo.processInfo.environment["GNOSTIC_CLI_BINARY"] else { return nil }
    var environment = ProcessInfo.processInfo.environment
    environment["GNOSTIC_CONFIG"] = configURL.path
    environment["GNOSTIC_STATE_HOME"] = stateHome.path
    return try await runACPProfiles(
        binary: binary,
        host: host,
        port: port,
        namespace: namespace,
        environment: environment
    )
}

private struct ACPProcess {
    let process: Process
    let input: Pipe
    let lines: LineStream

    func send(_ request: JSONRPCRequest) throws {
        input.fileHandleForWriting.write(try JSONEncoder().encode(request) + Data([0x0A]))
    }
}

private func launchACP(
    binary: String,
    ascendantID: UUID,
    providerID: String,
    host: String,
    port: Int,
    namespace: String,
    environment: [String: String]
) throws -> ACPProcess {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = [
        "acp", "--host", host, "--port", String(port), "--namespace", namespace,
        "--ascendant", ascendantID.uuidString.lowercased(),
        "--provider", providerID.lowercased(),
    ]
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    return ACPProcess(process: process, input: input, lines: LineStream(handle: output.fileHandleForReading))
}

private final class AcceptanceFinalLanguageModel: LanguageModel, @unchecked Sendable {
    var isConfigured: Bool { get async { true } }
    var configuration: LLMConfiguration { get async { .init(activeProvider: .openAI, providers: [:]) } }

    func chatStream(
        messages _: [LLMMessage],
        tools _: [LLMToolDefinition]?,
        toolChoice _: LLMToolChoice?,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        modelTier _: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let chunk = LLMStreamChunk(
            id: "acceptance-final",
            model: "acceptance",
            choices: [LLMStreamChoice(
                index: 0,
                delta: LLMStreamDelta(content: "ACP provider acceptance passed"),
                finishReason: "stop"
            )]
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(chunk)
            continuation.finish()
        }
    }

    func loadConfiguration() async {}
    func updateConfiguration(_: LLMConfiguration) async throws {}
    func clearConfiguration() async {}
    func restoreFromBackup() async throws {}
    func exportConfiguration() async throws -> Data { Data() }
    func importConfiguration(from _: Data) async throws {}
    func sendMessage(_ content: String) async throws -> String { content }
    func sendMessage(
        _: String,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        useUtilityModel _: Bool
    ) async throws -> String { "ok" }
    func generateTags(for _: String) async throws -> [String] { [] }
    func generateTitle(for _: [Message]) async throws -> String { "acceptance" }
    func evaluateRecallPerformance(
        transcript _: String,
        recalledMemories _: [Memory]
    ) async throws -> [String: Double] { [:] }
    func fetchAvailableModels() async throws -> [String]? { nil }
}
