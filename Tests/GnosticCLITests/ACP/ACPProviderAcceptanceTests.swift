// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import GnosticCore
import PKContracts
import PositronicKit
import Testing

@testable import GnosticCLI

#if os(Linux)
import Glibc
#else
import Darwin
#endif

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

        let probe = try ACPBrokerProbe(host: "127.0.0.1", port: 1883, namespace: namespace)
        defer { probe.stop() }
        try await probe.connect()
        try await poll(timeout: .seconds(8)) {
            await probe.discoverAscendants().count == 2
        }

        let ascendants = await probe.discoverAscendants()
        #expect(Set(ascendants.map(\.name)) == ["First Ascendant", "Second Ascendant"])
        #expect(Set(ascendants.map(\.providerID)).count == 2)
        for ascendant in ascendants {
            #expect(try await probe.selectAscendant(id: ascendant.id, providerID: ascendant.providerID) == ascendant)
        }
        await #expect(throws: ACPBrokerProbe.Error.self) {
            _ = try await probe.selectAscendant(id: sharedAscendantID)
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
                    && profile.args.contains("--node")
                    && !profile.args.contains("--provider")
            })
            // The selector is each serving node, which outlives its process.
            #expect(Set(profiles.profiles.compactMap { profile in
                guard let index = profile.args.firstIndex(of: "--node"),
                      profile.args.indices.contains(index + 1) else { return nil }
                return profile.args[index + 1]
            }) == [
                "a21d0000-0000-4000-8000-000000000201",
                "a21d0000-0000-4000-8000-000000000204",
            ])
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

        let probe = try ACPBrokerProbe(host: "127.0.0.1", port: 1883, namespace: namespace)
        defer { probe.stop() }
        try await probe.connect()
        let selected = try await waitForAscendant(secondAscendantID, using: probe)
        let other = try await probe.selectAscendant(id: firstAscendantID)

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
            profile.args.contains("--ascendant")
                && !profile.args.contains("--provider")
                && !profile.args.contains("--node")
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
        let selectedTimelines = try await probe.listTimelines(providerID: selected.providerID)
        let otherTimelines = try await probe.listTimelines(providerID: other.providerID)
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
        "a captured profile still initializes and opens sessions after a serve restart",
        .timeLimit(.minutes(2))
    )
    @MainActor
    func capturedProfileSurvivesServeRestart() async throws {
        guard let binary = ProcessInfo.processInfo.environment["GNOSTIC_ACP_BINARY"]
                ?? ProcessInfo.processInfo.environment["GNOSTIC_CLI_BINARY"] else { return }

        let namespace = "acp-restart-\(UUID().uuidString.lowercased())"
        let ascendantID = UUID(uuidString: "A21D0000-0000-4000-8000-000000000222")!
        let plan = try acceptanceManifest(
            namespace: namespace,
            nodeID: "A21D0000-0000-4000-8000-000000000221",
            ascendantID: ascendantID,
            timelineID: "A21D0000-0000-4000-8000-000000000223",
            name: "Restart Ascendant"
        ).compileLaunchPlan()

        let first = try await NodeRuntime(plan: plan, adapters: acceptanceAdapters())
        var stopped = false
        defer {
            if !stopped { Task { @MainActor in await first.shutdown() } }
        }
        try await first.start()

        let probe = try ACPBrokerProbe(host: "127.0.0.1", port: 1883, namespace: namespace)
        defer { probe.stop() }
        try await probe.connect()
        let before = try await waitForAscendant(ascendantID, using: probe)

        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-acp-restart-state-\(UUID().uuidString)")
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
        let profile = try #require(profiles.profiles.first)
        #expect(profiles.profiles.count == 1)
        #expect(!profile.args.contains("--provider"))

        let staleSessionID = try await openACPSession(
            binary: binary,
            arguments: profile.args,
            environment: environment,
            cwd: "/tmp/acp-restart"
        )

        // Replace the serve process. Its Axoloty provider identity is per
        // process, so the restarted node answers under a new one.
        await first.shutdown()
        stopped = true
        let second = try await NodeRuntime(plan: plan, adapters: acceptanceAdapters())
        defer { Task { @MainActor in await second.shutdown() } }
        try await second.start()
        // A client that connects after the restart is the case the captured
        // profile must satisfy. The pre-restart probe is bound to the old
        // provider's catalog entry, so it cannot answer for the new one.
        let restartedProbe = try ACPBrokerProbe(host: "127.0.0.1", port: 1883, namespace: namespace)
        defer { restartedProbe.stop() }
        try await restartedProbe.connect()
        let after = try await waitForAscendant(ascendantID, using: restartedProbe)
        #expect(after.providerID != before.providerID)

        // The profile captured before the restart is still executable.
        let session = try launchACP(
            binary: binary,
            arguments: profile.args,
            environment: environment
        )
        defer {
            if session.process.isRunning { session.process.terminate() }
        }
        try session.send(JSONRPCRequest(id: .number(1), method: "initialize", params: .dictionary([
            "protocolVersion": .number(1),
            "clientInfo": .dictionary(["name": .string("restart-acceptance"), "version": .string("1")]),
        ])))
        var output = session.lines.stream.makeAsyncIterator()
        #expect(try await readResponse(from: &output).error == nil)

        try session.send(JSONRPCRequest(id: .number(2), method: "session/new", params: .dictionary([
            "cwd": .string("/tmp/acp-restart"),
            "mcpServers": .array([]),
        ])))
        #expect(try await readResponse(from: &output).error == nil)

        // The session created before the restart is still bound to this
        // Ascendant and Node, so resume passes the binding check. Its runtime
        // Timeline does not outlive the serve process (#248), so resume
        // reports the missing Timeline rather than a binding failure.
        try session.send(JSONRPCRequest(id: .number(3), method: "session/resume", params: .dictionary([
            "sessionId": .string(staleSessionID),
            "cwd": .string("/tmp/acp-restart"),
            "mcpServers": .array([]),
        ])))
        let resumed = try await readResponse(from: &output)
        #expect(resumed.error?.data == .dictionary(["gnosticCode": .string("timelineUnavailable")]))

        try session.send(JSONRPCRequest(id: .number(4), method: "shutdown"))
        #expect(try await readResponse(from: &output).error == nil)
        session.input.fileHandleForWriting.closeFile()
        session.process.waitUntilExit()
    }

    @Test(
        "a configured runtime streams whitespace-compatible ACP turn IDs",
        .timeLimit(.minutes(1))
    )
    @MainActor
    func configuredRuntimeSmoke() async throws {
        let folder = try TemporaryFolder()
        let namespace = "legacy-runtime-\(UUID().uuidString.lowercased())"
        let configURL = folder.url.appendingPathComponent("config.json")
        let store = CLIConfigurationStore(configPath: configURL, environment: [:])
        let seeded = try store.mutateManifest { manifest in
            manifest = NodeManifest.makeDefault(broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace))
            manifest.ascendants[0].backend.settings = ["provider": .string("Ollama"), "model": .string("deterministic")]
        }
        #expect(seeded.ascendants.count == 1)

        let workspaceID = try #require(seeded.workspaces.first?.id)
        let configured = try store.mutateManifest { manifest in
            manifest.timelines[0].attachments = [.local(workspaceID)]
        }
        let plan = try configured.compileLaunchPlan()
        #expect(plan.ascendants.count == 1)
        #expect(plan.timelines.first?.attachments == [.local(workspaceID)])

        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerPositronicBackend { _, _ in LegacyMigrationToolLanguageModel() }
        adapters.workspaces.registerProduct(kind: "echo") { configuration in
            let tool = WorkspaceToolDefinition(
                id: EchoWorkspace.toolID,
                name: "Workspace echo",
                description: "Echoes fixture input.",
                requiresPermission: true
            )
            let reference = WorkspaceReference(
                id: configuration.id,
                uri: WorkspaceURI(parsing: configuration.uri)!,
                location: .runtime,
                tools: [.custom(tool)]
            )
            return EchoWorkspace(reference: reference)
        }
        let runtime = try await NodeRuntime(plan: plan, adapters: adapters)
        defer {
            Task { @MainActor in await runtime.shutdown() }
        }
        try await runtime.start()

        guard let binary = ProcessInfo.processInfo.environment["GNOSTIC_ACP_BINARY"]
                ?? ProcessInfo.processInfo.environment["GNOSTIC_CLI_BINARY"] else { return }
        let stateHome = folder.url.appendingPathComponent("state")
        let probe = try ACPBrokerProbe(host: "127.0.0.1", port: 1883, namespace: namespace)
        defer { probe.stop() }
        try await probe.connect()
        let ascendant = try await waitForOnlyAscendant(using: probe)
        let profiles = try await runACPProfilesIfAvailable(
            host: "127.0.0.1",
            port: 1883,
            namespace: namespace,
            configURL: configURL,
            stateHome: stateHome
        )
        if let profiles {
            #expect(profiles.profiles.map(\.id) == ["gnostic-\(ascendant.id.uuidString.lowercased())"])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["GNOSTIC_CONFIG"] = configURL.path
        environment["GNOSTIC_STATE_HOME"] = stateHome.path
        let session = try launchACP(
            binary: binary,
            ascendantID: ascendant.id,
            providerID: ascendant.providerID,
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
            "clientInfo": .dictionary(["name": .string("legacy-migration"), "version": .string("1")]),
        ])))
        var output = session.lines.stream.makeAsyncIterator()
        #expect(try await readResponse(from: &output).error == nil)

        try session.send(JSONRPCRequest(id: .number(2), method: "session/new", params: .dictionary([
            "cwd": .string("/tmp/legacy-migration-acp"),
            "mcpServers": .array([]),
        ])))
        let created = try await readResponse(from: &output)
        #expect(created.error == nil)
        let createdResult = try #require(created.result)
        guard case let .dictionary(createdValues) = createdResult,
              case let .string(sessionID) = createdValues["sessionId"],
              case let .dictionary(metadata) = createdValues["_meta"],
              case let .string(timelineRaw) = metadata["gnosticTimelineID"],
              let timelineID = UUID(uuidString: timelineRaw) else {
            Issue.record("session/new did not return ACP migration metadata")
            return
        }
        #expect(metadata["gnosticAscendantID"] == .string(ascendant.id.uuidString.lowercased()))

        let workspace = try #require(try await probe.listWorkspaces(providerID: ascendant.providerID).first { $0.id == workspaceID })
        #expect(workspace.isAvailable)
        #expect(try await probe.attach(
            workspaceID: workspaceID,
            timelineID: timelineID,
            providerID: ascendant.providerID
        ))

        try session.send(JSONRPCRequest(id: .number(3), method: "session/list", params: .dictionary([
            "cwd": .string("/tmp/legacy-migration-acp")
        ])))
        let listed = try await readResponse(from: &output)
        #expect(listed.error == nil)
        guard case let .dictionary(listedValues) = listed.result,
              case let .array(listedSessions) = listedValues["sessions"],
              case let .dictionary(listedSession) = listedSessions.first,
              case let .dictionary(listedMetadata) = listedSession["_meta"] else {
            Issue.record("session/list did not return ACP session metadata")
            return
        }
        #expect(listedMetadata["gnosticWorkspaceAttachmentState"] == .string("attached"))
        #expect(listedMetadata["gnosticAttachedWorkspaceIDs"] == .array([
            .string(workspaceID.uuidString.lowercased())
        ]))

        let promptText = "echo network"
        // Whitespace around the ACP metadata ID is compatibility input. The
        // update collector must still receive live events for the canonical ID.
        let turnID = "  legacy-smoke:turn-1  "
        try session.send(JSONRPCRequest(id: .number(4), method: "session/prompt", params: .dictionary([
            "sessionId": .string(sessionID),
            "prompt": .array([.dictionary(["type": .string("text"), "text": .string(promptText)])]),
            "mcpServers": .array([]),
            "_meta": .dictionary([ACPProtocol.turnIDMetadataKey: .string(turnID)]),
        ])))

        var permissionRequested = false
        var promptCompleted = false
        var updates: [AnyCodable] = []
        while !promptCompleted {
            switch try await readEnvelope(from: &output) {
            case .request(let request) where request.method == "session/request_permission":
                permissionRequested = true
                let response = JSONRPCResponse(id: request.id, result: .dictionary([
                    "outcome": .dictionary([
                        "outcome": .string("selected"),
                        "optionId": .string("allow_once"),
                    ]),
                ]))
                session.input.fileHandleForWriting.write(try JSONEncoder().encode(response) + Data([0x0A]))
            case .request(let request) where request.method == "session/update":
                if let params = request.params { updates.append(params) }
            case .response(let response) where response.id == .number(4):
                #expect(response.error == nil)
                #expect(response.result == .dictionary(["stopReason": .string("end_turn")]))
                promptCompleted = true
            default:
                continue
            }
        }
        #expect(permissionRequested)
        let updateText = String(decoding: try JSONEncoder().encode(updates), as: UTF8.self)
        #expect(updateText.contains("workspace_echo"))
        #expect(updateText.contains("Echo received: network"))
        #expect(updateText.contains("\"clientTurnID\":\"legacy-smoke:turn-1\""))
        #expect(updateText.contains("\"replayed\":false"))

        try session.send(JSONRPCRequest(id: .number(5), method: "session/prompt", params: .dictionary([
            "sessionId": .string(sessionID),
            "prompt": .array([.dictionary(["type": .string("text"), "text": .string(promptText)])]),
            "mcpServers": .array([]),
            "_meta": .dictionary([ACPProtocol.turnIDMetadataKey: .string(turnID)]),
        ])))
        var replayed = false
        var replayCompleted = false
        while !replayCompleted {
            switch try await readEnvelope(from: &output) {
            case .request(let request) where request.method == "session/update":
                if let params = request.params {
                    let text = String(decoding: try JSONEncoder().encode(params), as: UTF8.self)
                    replayed = replayed || text.contains("\"replayed\":true")
                }
            case .request(let request) where request.method == "session/request_permission":
                Issue.record("replayed ACP turn unexpectedly requested permission")
                let response = JSONRPCResponse(id: request.id, result: .dictionary([
                    "outcome": .dictionary(["outcome": .string("selected"), "optionId": .string("allow_once")]),
                ]))
                session.input.fileHandleForWriting.write(try JSONEncoder().encode(response) + Data([0x0A]))
            case .response(let response) where response.id == .number(5):
                #expect(response.error == nil)
                #expect(response.result == .dictionary(["stopReason": .string("end_turn")]))
                replayCompleted = true
            default:
                continue
            }
        }
        #expect(replayed)

        try session.send(JSONRPCRequest(id: .number(6), method: "session/close", params: .dictionary([
            "sessionId": .string(sessionID)
        ])))
        #expect(try await readResponse(from: &output).error == nil)
        try session.send(JSONRPCRequest(id: .number(7), method: "shutdown"))
        #expect(try await readResponse(from: &output).error == nil)
        session.input.fileHandleForWriting.closeFile()
        session.process.waitUntilExit()
    }

    /// ADR 0008's interim orphaned-session behavior, end to end.
    ///
    /// A runtime Timeline is process-scoped, so killing `gnostic serve`
    /// destroys it while the durable ACP session record survives. The restarted
    /// Node advertises the same Ascendant under a new provider identity (#247),
    /// which is exactly the case where a binding error used to hide the real
    /// cause.
    @Test("a serve restart orphans an ACP session with a structured timelineUnavailable", .timeLimit(.minutes(2)))
    @MainActor
    func serveRestartOrphansRuntimeTimelineSessions() async throws {
        let environmentSource = ProcessInfo.processInfo.environment
        guard let binary = environmentSource["GNOSTIC_SERVE_BINARY"]
                ?? environmentSource["GNOSTIC_CLI_BINARY"]
                ?? environmentSource["GNOSTIC_ACP_BINARY"] else { return }

        let namespace = "acp-orphan-\(UUID().uuidString.lowercased())"
        let ascendantID = try #require(UUID(uuidString: "A21D0000-0000-4000-8000-000000000222"))
        let folder = try TemporaryFolder()
        let configURL = folder.url.appendingPathComponent("manifest.json")
        let manifest = try acceptanceManifest(
            namespace: namespace,
            nodeID: "A21D0000-0000-4000-8000-000000000221",
            ascendantID: ascendantID,
            timelineID: "A21D0000-0000-4000-8000-000000000223",
            name: "Orphan ACP Ascendant"
        )
        try JSONEncoder().encode(manifest).write(to: configURL, options: .atomic)
        let stateHome = folder.url.appendingPathComponent("state", isDirectory: true)
        var environment = environmentSource
        environment["GNOSTIC_CONFIG"] = configURL.path
        environment["GNOSTIC_STATE_HOME"] = stateHome.path

        let cwd = "/tmp/acp-orphan-acceptance"
        let firstServe = try launchServe(binary: binary, configURL: configURL, namespace: namespace)
        defer { firstServe.kill() }
        try await firstServe.waitUntilOnline()

        let creator = try launchACP(
            binary: binary,
            ascendantID: ascendantID,
            providerID: nil,
            host: "127.0.0.1",
            port: 1883,
            namespace: namespace,
            environment: environment
        )
        defer { if creator.process.isRunning { creator.process.terminate() } }
        var creatorOutput = creator.lines.stream.makeAsyncIterator()
        try creator.send(JSONRPCRequest(id: .number(1), method: "initialize", params: .dictionary([
            "protocolVersion": .number(1),
            "clientInfo": .dictionary(["name": .string("orphan-acceptance"), "version": .string("1")]),
        ])))
        #expect(try await readResponse(from: &creatorOutput).error == nil)

        try creator.send(JSONRPCRequest(id: .number(2), method: "session/new", params: .dictionary([
            "cwd": .string(cwd),
            "mcpServers": .array([]),
        ])))
        let created = try await readResponse(from: &creatorOutput)
        #expect(created.error == nil)
        guard case let .dictionary(createdValues) = created.result,
              case let .string(sessionID) = createdValues["sessionId"] else {
            Issue.record("session/new returned no sessionId")
            return
        }

        try creator.send(JSONRPCRequest(id: .number(3), method: "session/list", params: .dictionary([
            "cwd": .string(cwd),
        ])))
        #expect(listedSessionIDs(in: try await readResponse(from: &creatorOutput)).contains(sessionID))

        try creator.send(JSONRPCRequest(id: .number(4), method: "shutdown"))
        #expect(try await readResponse(from: &creatorOutput).error == nil)
        creator.input.fileHandleForWriting.closeFile()
        creator.process.waitUntilExit()

        firstServe.kill()
        let secondServe = try launchServe(binary: binary, configURL: configURL, namespace: namespace)
        defer { secondServe.kill() }
        try await secondServe.waitUntilOnline()

        let resumer = try launchACP(
            binary: binary,
            ascendantID: ascendantID,
            providerID: nil,
            host: "127.0.0.1",
            port: 1883,
            namespace: namespace,
            environment: environment
        )
        defer { if resumer.process.isRunning { resumer.process.terminate() } }
        var resumerOutput = resumer.lines.stream.makeAsyncIterator()
        try resumer.send(JSONRPCRequest(id: .number(5), method: "initialize", params: .dictionary([
            "protocolVersion": .number(1),
            "clientInfo": .dictionary(["name": .string("orphan-acceptance"), "version": .string("1")]),
        ])))
        #expect(try await readResponse(from: &resumerOutput).error == nil)

        try resumer.send(JSONRPCRequest(id: .number(6), method: "session/resume", params: .dictionary([
            "sessionId": .string(sessionID),
            "cwd": .string(cwd),
            "mcpServers": .array([]),
        ])))
        let resumed = try await readResponse(from: &resumerOutput)
        #expect(resumed.error?.code == JSONRPCErrorCode.invalidState.rawValue)
        #expect(resumed.error?.data == .dictionary(["gnosticCode": .string("timelineUnavailable")]))

        try resumer.send(JSONRPCRequest(id: .number(7), method: "session/prompt", params: .dictionary([
            "sessionId": .string(sessionID),
            "prompt": .array([.dictionary(["type": .string("text"), "text": .string("hello")])]),
            "mcpServers": .array([]),
            "_meta": .dictionary([ACPProtocol.turnIDMetadataKey: .string("orphan-acceptance:turn-1")]),
        ])))
        let prompted = try await readResponse(from: &resumerOutput)
        #expect(prompted.error?.code == JSONRPCErrorCode.invalidState.rawValue)
        #expect(prompted.error?.data == .dictionary(["gnosticCode": .string("timelineUnavailable")]))

        try resumer.send(JSONRPCRequest(id: .number(8), method: "session/list", params: .dictionary([
            "cwd": .string(cwd),
        ])))
        #expect(!listedSessionIDs(in: try await readResponse(from: &resumerOutput)).contains(sessionID))

        try resumer.send(JSONRPCRequest(id: .number(9), method: "shutdown"))
        #expect(try await readResponse(from: &resumerOutput).error == nil)
        resumer.input.fileHandleForWriting.closeFile()
        resumer.process.waitUntilExit()

        // The record stays on disk for diagnostics and is marked ended.
        let registry = ACPSessionRegistry(url: stateHome.appendingPathComponent("acp-sessions-v1.json"))
        let record = try #require(await registry.record(id: sessionID))
        #expect(record.closedAt != nil)
        #expect(record.cwd == cwd)
    }
}

/// A `gnostic serve` subprocess whose lifetime the test controls.
///
/// ADR 0008's orphan case needs an unclean exit: `kill` sends SIGKILL so the
/// Node never deadvertises, which is what a crashed serve looks like.
private struct ServeProcess {
    let process: Process
    let logURL: URL

    func waitUntilOnline() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(30)
        while clock.now < deadline {
            // The readiness marker is the structured advertisement log, not the
            // `print` banner: stdout is block-buffered when it is a file.
            if let log = try? String(contentsOf: logURL, encoding: .utf8),
               log.contains("advertised objects") {
                return
            }
            guard process.isRunning else { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        Issue.record(Comment(rawValue: "gnostic serve did not come online: \(log)"))
        throw ACPSubprocessError.timeout
    }

    func kill() {
        guard process.isRunning else { return }
        #if os(Linux)
        Glibc.kill(process.processIdentifier, SIGKILL)
        #else
        Darwin.kill(process.processIdentifier, SIGKILL)
        #endif
        process.waitUntilExit()
    }
}

private func launchServe(binary: String, configURL: URL, namespace: String) throws -> ServeProcess {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = [
        "serve", "--config", configURL.path,
        "--host", "127.0.0.1", "--port", "1883", "--namespace", namespace,
    ]
    let logURL = configURL.deletingLastPathComponent()
        .appendingPathComponent("serve-\(UUID().uuidString).log")
    guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
        throw ACPSubprocessError.timeout
    }
    let log = try FileHandle(forWritingTo: logURL)
    process.standardOutput = log
    process.standardError = log
    try process.run()
    return ServeProcess(process: process, logURL: logURL)
}

private func listedSessionIDs(in response: JSONRPCResponse) -> [String] {
    guard response.error == nil,
          case let .dictionary(values) = response.result,
          case let .array(sessions) = values["sessions"] else { return [] }
    return sessions.compactMap { value in
        guard case let .dictionary(fields) = value,
              case let .string(id) = fields["sessionId"] else { return nil }
        return id
    }
}

private func acceptanceAdapters() -> NodeRuntimeAdapters {
    var adapters = NodeRuntimeAdapters.default
    adapters.ascendants.registerPositronicBackend { _, _ in AcceptanceFinalLanguageModel() }
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
    return NodeManifest(
        broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
        node: .init(id: nodeID),
        ascendants: [.init(id: ascendantID, name: name, defaultTimelineID: timelineID, backend: .init(kind: "positronic", settings: ["provider": .string("Ollama"), "model": .string("deterministic")]))],
        timelines: [.init(id: timelineID, title: "\(name) Timeline", operatingAscendantID: ascendantID)]
    )
}

private func waitForAscendant(
    _ id: UUID,
    using probe: ACPBrokerProbe
) async throws -> ACPBrokerProbe.DiscoveredAscendant {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(8)
    while clock.now < deadline {
        if let result = try? await probe.selectAscendant(id: id) { return result }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw ACPSubprocessError.timeout
}

private func waitForOnlyAscendant(
    using probe: ACPBrokerProbe
) async throws -> ACPBrokerProbe.DiscoveredAscendant {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(8)
    while clock.now < deadline {
        let ascendants = await probe.discoverAscendants()
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

/// Runs one ACP process long enough to create a session, then stops it.
private func openACPSession(
    binary: String,
    arguments: [String],
    environment: [String: String],
    cwd: String
) async throws -> String {
    let session = try launchACP(binary: binary, arguments: arguments, environment: environment)
    defer {
        if session.process.isRunning { session.process.terminate() }
    }
    try session.send(JSONRPCRequest(id: .number(1), method: "initialize", params: .dictionary([
        "protocolVersion": .number(1),
        "clientInfo": .dictionary(["name": .string("restart-acceptance"), "version": .string("1")]),
    ])))
    var output = session.lines.stream.makeAsyncIterator()
    #expect(try await readResponse(from: &output).error == nil)

    try session.send(JSONRPCRequest(id: .number(2), method: "session/new", params: .dictionary([
        "cwd": .string(cwd),
        "mcpServers": .array([]),
    ])))
    let created = try await readResponse(from: &output)
    #expect(created.error == nil)
    guard case let .dictionary(values) = created.result,
          case let .string(sessionID) = values["sessionId"] else {
        throw ACPSubprocessError.timeout
    }
    try session.send(JSONRPCRequest(id: .number(3), method: "shutdown"))
    #expect(try await readResponse(from: &output).error == nil)
    session.input.fileHandleForWriting.closeFile()
    session.process.waitUntilExit()
    return sessionID
}

private func launchACP(
    binary: String,
    ascendantID: UUID,
    providerID: String?,
    host: String,
    port: Int,
    namespace: String,
    environment: [String: String]
) throws -> ACPProcess {
    try launchACP(
        binary: binary,
        arguments: [
            "acp", "--host", host, "--port", String(port), "--namespace", namespace,
            "--ascendant", ascendantID.uuidString.lowercased(),
        ] + (providerID.map { ["--provider", $0.lowercased()] } ?? []),
        environment: environment
    )
}

private func launchACP(
    binary: String,
    arguments: [String],
    environment: [String: String]
) throws -> ACPProcess {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    return ACPProcess(process: process, input: input, lines: LineStream(handle: output.fileHandleForReading))
}

private final class AcceptanceFinalLanguageModel: LLMStreamClient, @unchecked Sendable {
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

    func generationStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier,
        responseModalities _: Set<ResponseModality>,
        audioOutput _: AudioOutputOptions?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await chatStream(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, modelTier: modelTier)
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
    func fetchAvailableModels() async throws -> [String]? { nil }
}

/// Deterministic two-step model for the configured-runtime ACP acceptance path.
private final class LegacyMigrationToolLanguageModel: LLMStreamClient, @unchecked Sendable {
    private actor Counter {
        private var value = 0
        func next() -> Int {
            value += 1
            return value
        }
    }

    private let counter = Counter()
    var isConfigured: Bool { get async { true } }
    var configuration: LLMConfiguration { get async { .init(activeProvider: .openAI, providers: [:]) } }

    func chatStream(
        messages: [LLMMessage],
        tools _: [LLMToolDefinition]?,
        toolChoice _: LLMToolChoice?,
        responseFormat _: LLMResponseFormat?,
        generationParameters _: GenerationParameters?,
        modelTier _: ModelTier
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        if await counter.next() == 1 {
            let chunk = LLMStreamChunk(
                id: "legacy-tool",
                model: "acceptance",
                choices: [LLMStreamChoice(
                    index: 0,
                    delta: LLMStreamDelta(
                        role: .assistant,
                        toolCalls: [LLMToolCallDelta(
                            index: 0,
                            id: "call_1",
                            function: LLMToolCallDeltaFunction(
                                name: "workspace_echo",
                                arguments: #"{"value":"network"}"#
                            )
                        )]
                    ),
                    finishReason: "tool_calls"
                )]
            )
            return AsyncThrowingStream { continuation in
                continuation.yield(chunk)
                continuation.finish()
            }
        }
        guard messages.contains(where: {
            $0.role == .tool && $0.toolCallID == "call_1" && $0.content == "network"
        }) else {
            return AsyncThrowingStream { $0.finish(throwing: ModelError.missingToolResult) }
        }
        let chunk = LLMStreamChunk(
            id: "legacy-final",
            model: "acceptance",
            choices: [LLMStreamChoice(
                index: 0,
                delta: LLMStreamDelta(content: "Echo received: network"),
                finishReason: "stop"
            )]
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(chunk)
            continuation.finish()
        }
    }

    func generationStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        toolChoice: LLMToolChoice?,
        responseFormat: LLMResponseFormat?,
        generationParameters: GenerationParameters?,
        modelTier: ModelTier,
        responseModalities _: Set<ResponseModality>,
        audioOutput _: AudioOutputOptions?
    ) async -> AsyncThrowingStream<LLMStreamChunk, Error> {
        await chatStream(messages: messages, tools: tools, toolChoice: toolChoice, responseFormat: responseFormat, generationParameters: generationParameters, modelTier: modelTier)
    }

    private enum ModelError: Error { case missingToolResult }
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
    func fetchAvailableModels() async throws -> [String]? { nil }
}
