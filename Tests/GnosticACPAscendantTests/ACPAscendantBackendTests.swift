// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticACPAscendant
import GnosticCore
import Testing

@Suite("ACP Ascendant backend", .serialized)
struct ACPAscendantBackendTests {
    @MainActor
    private func backend(
        settings: [String: ManifestJSONValue] = ["command": .string("opencode")],
        secrets: [String: ManifestJSONValue] = [:],
        timelines: [NodeManifest.Timeline] = [],
        ascendantID: UUID = UUID()
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
            services: .empty,
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
        let configuredID = UUID()
        let timeline = NodeManifest.Timeline(id: configuredID, title: "Configured")
        let backend = try fixtureBackend(timelines: [timeline])
        defer { Task { await backend.shutdown() } }

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
        let timelineID = UUID()
        let backend = try fixtureBackend(timelines: [.init(id: timelineID, title: "Configured")])
        defer { Task { await backend.shutdown() } }
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

    @Test("agent terminal failures are terminal and leave the backend usable")
    @MainActor
    func agentFailureIsTerminal() async throws {
        let timelineID = UUID()
        let backend = try fixtureBackend(timelines: [.init(id: timelineID, title: "Configured")])
        defer { Task { await backend.shutdown() } }
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
        let ascendantID = UUID()
        let timelineID = UUID()
        let timeline = NodeManifest.Timeline(id: timelineID, title: "Runtime")
        let settings = try fixtureSettings()
        let first = try backend(settings: settings, timelines: [], ascendantID: ascendantID)
        defer { Task { await first.shutdown() } }
        _ = try await first.createTimeline(id: timelineID, title: timeline.title)
        _ = try await first.runTurn(
            .init(timelineID: timelineID, message: "create the durable session"),
            updates: RecordingUpdateSink()
        )
        await first.shutdown()

        let restarted = try backend(settings: settings, timelines: [], ascendantID: ascendantID)
        defer { Task { await restarted.shutdown() } }
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

    @MainActor
    private func fixtureBackend(
        timelines: [NodeManifest.Timeline],
        ascendantID: UUID = UUID()
    ) throws -> ACPAscendantBackend {
        try backend(settings: fixtureSettings(), timelines: timelines, ascendantID: ascendantID)
    }

    private func fixtureSettings() throws -> [String: ManifestJSONValue] {
        let fixturePath = ProcessInfo.processInfo.environment["GNOSTIC_ACP_AGENT_FIXTURE"]
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/ACPAgent/agent.mjs")
                .path
        let statePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-acp-agent-\(UUID().uuidString).json").path
        let fixtureEnvironment = [
            "GNOSTIC_ACP_FIXTURE_STATE": statePath,
        ]
        let encodedEnvironment = try JSONEncoder().encode(fixtureEnvironment)
        return [
            "command": .string("/usr/bin/node"),
            "args": .string(try #require(String(data: JSONEncoder().encode([fixturePath]), encoding: .utf8))),
            "env": .string(try #require(String(data: encodedEnvironment, encoding: .utf8))),
        ]
    }

    private actor RecordingUpdateSink: AscendantBackendUpdateSink {
        private(set) var updates: [AscendantBackendUpdate] = []

        func append(_ update: AscendantBackendUpdate) async throws {
            updates.append(update)
        }
    }
}
