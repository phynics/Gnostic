// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticACPAscendant
import GnosticCore
import Testing

@Suite("ACP Ascendant backend")
struct ACPAscendantBackendTests {
    @MainActor
    private func backend(
        settings: [String: ManifestJSONValue] = ["command": .string("opencode")],
        secrets: [String: ManifestJSONValue] = [:],
        timelines: [NodeManifest.Timeline] = []
    ) throws -> ACPAscendantBackend {
        let ascendant = NodeManifest.Ascendant(
            id: UUID(),
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

    @Test("configured and runtime-created Timelines remain projected without ACP sessions")
    @MainActor
    func timelineProjectionsStayInMemory() async throws {
        let configuredID = UUID()
        let configured = NodeManifest.Timeline(id: configuredID, title: "Configured")
        let backend = try backend(timelines: [configured])

        #expect(try await backend.operatedTimelines().map(\.id) == [configuredID])
        let created = try await backend.createTimeline(id: UUID(), title: "Runtime")
        #expect(try await backend.operatedTimelines().count == 2)
        let renamed = try await backend.renameTimeline(id: created.id, title: "Renamed")
        #expect(renamed.title == "Renamed")
        await backend.removeTimeline(id: created.id)
        #expect(try await backend.operatedTimelines().map(\.id) == [configuredID])
    }

    @Test("runTurn reports the not-yet-implemented ACP capability as a terminal failure")
    @MainActor
    func turnFailsUntilACPExecutionExists() async throws {
        let timelineID = UUID()
        let backend = try backend(timelines: [.init(id: timelineID, title: "Configured")])

        do {
            _ = try await backend.runTurn(.init(timelineID: timelineID, message: "hello"), updates: NoopUpdateSink())
            Issue.record("ACP runTurn unexpectedly succeeded before ACP Turn support exists.")
        } catch let AscendantBackendError.terminal(failure) {
            #expect(failure.code == "acpTurnUnavailable")
            #expect(failure.message.contains("GNO-ACPC-003"))
        }
    }

    private struct NoopUpdateSink: AscendantBackendUpdateSink {
        func append(_: AscendantBackendUpdate) async throws {}
    }
}
