// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import Testing

@testable import GnosticCLI

@Suite("Resource-oriented configuration commands")
struct ResourceCommandTests {
    @Test("config exposes every resource command and no profile abstraction")
    func completeResourceCommandTree() {
        let help = ConfigCommand.helpMessage()

        for command in [
            "init", "show", "validate", "path", "broker", "positronic", "ascendant", "timeline", "workspace",
        ] {
            #expect(help.contains(command), "missing config command: \(command)")
        }
        #expect(!help.contains("config set"))
        #expect(!help.lowercased().contains("profile"))
        #expect(help.contains("--config"))

        #expect(ConfigCommand.Broker.helpMessage().contains("set-password"))
        #expect(ConfigCommand.Positronic.helpMessage().contains("set-api-key"))
        #expect(!ConfigCommand.Ascendant.helpMessage().contains("llm-profile"))
        #expect(ConfigCommand.Timeline.helpMessage().contains("attach-workspace"))
        #expect(ConfigCommand.Timeline.helpMessage().contains("detach-workspace"))
    }

    @Test("generic profile commands are not registered")
    func genericProfileCommandsAreRemoved() {
        #expect(throws: (any Error).self) {
            _ = try GnosticCLI.parseAsRoot(["config", "llm"])
        }
        #expect(throws: (any Error).self) {
            _ = try GnosticCLI.parseAsRoot(["config", "ascendant", "add", "--llm-profile", UUID().uuidString])
        }
    }

    @Test("init creates the complete default graph and refuses replacement")
    func initCreatesDefaultGraphAndIsNonDestructive() throws {
        let folder = try TemporaryFolder()
        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        var output: [String] = []

        try ConfigCommandLogic.initialize(store: store, writeOutput: { output.append($0) })
        let manifest = try store.loadManifest()

        #expect(manifest.ascendants.count == 1)
        #expect(manifest.ascendants[0].backend.kind == "positronic")
        #expect(manifest.ascendants[0].backend.settings.isEmpty)
        #expect(manifest.timelines.count == 1)
        #expect(manifest.workspaces.count == 1)
        #expect(manifest.timelines[0].operatingAscendantID == manifest.ascendants[0].id)
        #expect(output.joined().contains(manifest.node.id.uuidString.lowercased()))

        let original = try Data(contentsOf: store.path())
        #expect(throws: CLIConfigurationError.fileAlreadyExists(store.path())) {
            try ConfigCommandLogic.initialize(store: store)
        }
        #expect(try Data(contentsOf: store.path()) == original)
    }

    @Test("adding an Ascendant atomically creates its operated default Timeline")
    func ascendantAddCreatesBoundTimeline() throws {
        let folder = try TemporaryFolder()
        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])

        try ConfigCommandLogic.initialize(store: store)
        try ConfigCommandLogic.addAscendant(name: "Second", description: "two", store: store)
        let manifest = try store.loadManifest()
        let ascendant = try #require(manifest.ascendants.last)
        let timeline = try #require(manifest.timelines.first { $0.id == ascendant.defaultTimelineID })

        #expect(ascendant.name == "Second")
        #expect(timeline.operatingAscendantID == ascendant.id)
    }

    @Test("Positronic convenience targets one Ascendant envelope")
    func positronicConfigurationIsScopedToSelectedAscendant() throws {
        let folder = try TemporaryFolder()
        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        try ConfigCommandLogic.initialize(store: store)
        try ConfigCommandLogic.addAscendant(name: "Second", description: "two", store: store)
        let initial = try store.loadManifest()
        let firstID = try #require(initial.ascendants.first?.id)
        let secondID = try #require(initial.ascendants.last?.id)
        _ = try store.mutateManifest { manifest in
            manifest.ascendants[0].backend.settings["custom"] = .string("preserved")
        }

        try ConfigCommandLogic.configurePositronic(
            ascendantID: secondID.uuidString, provider: "anthropic", endpoint: nil,
            model: "sonnet", utilityModel: nil, fastModel: nil, store: store
        )
        let updated = try store.loadManifest()
        #expect(updated.ascendants.first { $0.id == firstID }?.backend.settings["custom"] == .string("preserved"))
        #expect(updated.ascendants.first { $0.id == secondID }?.backend.settings["provider"] == .string("anthropic"))
        #expect(updated.ascendants.first { $0.id == secondID }?.backend.settings["model"] == .string("sonnet"))
        let encoded = try JSONEncoder().encode(updated)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["llmProfiles"] == nil)
    }

    @Test("Positronic selection follows the backend envelope kind")
    func positronicSelectionUsesBackendKind() throws {
        let folder = try TemporaryFolder()
        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        try ConfigCommandLogic.initialize(store: store)
        _ = try store.mutateManifest { manifest in
            manifest.ascendants[0].kind = "legacy-label"
        }

        try ConfigCommandLogic.configurePositronic(
            ascendantID: try store.loadManifest().ascendants[0].id.uuidString,
            provider: "stub", endpoint: nil, model: "deterministic",
            utilityModel: nil, fastModel: nil, store: store
        )
        #expect(try store.loadManifest().ascendants[0].backend.settings["provider"] == .string("stub"))
    }

    @Test("invalid reference removal leaves the original bytes intact and names the reference")
    func referencedRemovalIsAtomic() throws {
        let folder = try TemporaryFolder()
        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        try ConfigCommandLogic.initialize(store: store)
        let before = try Data(contentsOf: store.path())
        let manifest = try store.loadManifest()

        #expect(throws: CLIConfigurationError.self) {
            try ConfigCommandLogic.removeTimeline(id: manifest.timelines[0].id.uuidString, store: store)
        }
        #expect(try Data(contentsOf: store.path()) == before)

        do {
            try ConfigCommandLogic.removeTimeline(id: manifest.timelines[0].id.uuidString, store: store)
        } catch let error as CLIConfigurationError {
            #expect(error.errorDescription?.contains(manifest.ascendants[0].id.uuidString.lowercased()) == true)
        }
    }

    @Test("update commands can clear nullable resource relationships")
    func updatesClearNullableRelationships() throws {
        let folder = try TemporaryFolder()
        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        try ConfigCommandLogic.initialize(store: store)
        let initial = try store.loadManifest()
        try ConfigCommandLogic.addTimeline(
            title: "Secondary",
            operatingAscendantID: initial.ascendants[0].id.uuidString,
            store: store
        )
        let secondaryTimeline = try #require(try store.loadManifest().timelines.last)

        try ConfigCommandLogic.configurePositronic(
            ascendantID: initial.ascendants[0].id.uuidString,
            provider: "stub", endpoint: nil, model: "deterministic",
            utilityModel: nil, fastModel: nil, store: store
        )
        try ConfigCommandLogic.clearPositronic(ascendantID: initial.ascendants[0].id.uuidString, store: store)
        try ConfigCommandLogic.updateTimeline(
            id: secondaryTimeline.id.uuidString,
            title: nil,
            operatingAscendantID: nil,
            clearOperatingAscendant: true,
            store: store
        )

        let updated = try store.loadManifest()
        #expect(updated.ascendants[0].backend.settings.isEmpty)
        #expect(updated.timelines.first { $0.id == secondaryTimeline.id }?.operatingAscendantID == nil)
    }

    @Test("show JSON redacts both secret fields")
    func showJSONRedactsSecrets() throws {
        let folder = try TemporaryFolder()
        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        try ConfigCommandLogic.initialize(store: store)
        try ConfigCommandLogic.setBrokerPassword("broker-secret", store: store)
        let manifest = try store.loadManifest()
        try ConfigCommandLogic.setPositronicAPIKey(id: manifest.ascendants[0].id.uuidString, value: "llm-secret", store: store)

        var output = ""
        try ConfigCommandLogic.show(store: store, json: true, writeOutput: { output = $0 })
        #expect(output.contains("<redacted>"))
        #expect(!output.contains("broker-secret"))
        #expect(!output.contains("llm-secret"))
        _ = try JSONSerialization.jsonObject(with: Data(output.utf8))
    }

    @Test("resource CRUD preserves relationships and supports lazy network attachments")
    func resourceCRUD() throws {
        let folder = try TemporaryFolder()
        let store = CLIConfigurationStore(baseDirectory: folder.url, environment: [:])
        try ConfigCommandLogic.initialize(store: store)
        var manifest = try store.loadManifest()

        try ConfigCommandLogic.addAscendant(
            name: "Secondary Ascendant", description: "", store: store
        )
        manifest = try store.loadManifest()
        let secondaryAscendant = try #require(manifest.ascendants.last)
        try ConfigCommandLogic.configurePositronic(
            ascendantID: secondaryAscendant.id.uuidString, provider: "anthropic",
            endpoint: "https://example.test", model: "sonnet", utilityModel: nil,
            fastModel: nil, store: store
        )
        manifest = try store.loadManifest()
        try ConfigCommandLogic.addTimeline(title: "Unoperated", operatingAscendantID: nil, store: store)
        manifest = try store.loadManifest()
        let unoperatedTimeline = try #require(manifest.timelines.last { $0.operatingAscendantID == nil })
        let workspace = try #require(manifest.workspaces.first)
        let networkWorkspaceID = "A21D0000-0000-4000-8000-000000000041"

        try ConfigCommandLogic.attachWorkspace(
            timelineID: unoperatedTimeline.id.uuidString, workspaceID: networkWorkspaceID,
            networkURI: "workspace://remote", store: store
        )
        try ConfigCommandLogic.detachWorkspace(
            timelineID: unoperatedTimeline.id.uuidString, workspaceID: networkWorkspaceID, store: store
        )
        try ConfigCommandLogic.removeTimeline(id: unoperatedTimeline.id.uuidString, store: store)
        try ConfigCommandLogic.removeAscendant(id: secondaryAscendant.id.uuidString, store: store)
        try ConfigCommandLogic.removeWorkspace(id: workspace.id.uuidString, store: store)

        manifest = try store.loadManifest()
        #expect(manifest.ascendants.count == 1)
        #expect(manifest.workspaces.isEmpty)
    }
}

@Suite("Resource configuration subprocess", .serialized)
struct ResourceConfigurationSubprocessTests {
    @Test("init and stdin secret commands are credential-free")
    func initAndSecretInputUseStdin() throws {
        guard let binary = ProcessInfo.processInfo.environment["GNOSTIC_CLI_BINARY"] else { return }
        let folder = try TemporaryFolder()
        let path = folder.url.appendingPathComponent("node.json")

        let initialized = try run(binary: binary, arguments: ["config", "init", "--config", path.path])
        #expect(initialized.status == 0, Comment(rawValue: initialized.stderr))
        #expect(initialized.stdout.contains("Initialized configuration"))

        let manifest = try JSONDecoder().decode(NodeManifest.self, from: Data(contentsOf: path))
        let secret = "stdin-only-broker-secret"
        let setPassword = try run(
            binary: binary,
            arguments: ["config", "broker", "set-password", "--config", path.path],
            stdin: secret + "\n"
        )
        #expect(setPassword.status == 0, Comment(rawValue: setPassword.stderr))
        #expect(!setPassword.stdout.contains(secret))
        #expect(!setPassword.stderr.contains(secret))
        #expect(!["config", "broker", "set-password", "--config", path.path].contains(secret))
        #expect(try CLIConfigurationStore(configPath: path, environment: [:]).loadManifest().broker.password == secret)
        let ascendantID = manifest.ascendants[0].id.uuidString.lowercased()
        let apiSecret = "stdin-only-api-key"
        let setAPIKey = try run(
            binary: binary,
            arguments: ["config", "positronic", "set-api-key", ascendantID, "--config", path.path],
            stdin: apiSecret + "\n"
        )
        #expect(setAPIKey.status == 0, Comment(rawValue: setAPIKey.stderr))
        #expect(!setAPIKey.stdout.contains(apiSecret))
        #expect(!setAPIKey.stderr.contains(apiSecret))
        #expect(try CLIConfigurationStore(configPath: path, environment: [:]).loadManifest().ascendants[0].backend.secrets["apiKey"] == .string(apiSecret))
    }

    @Test("public CLI performs CRUD and rejects invalid direct JSON without rewriting it")
    func publicCRUDAndDirectJSONValidation() throws {
        guard let binary = ProcessInfo.processInfo.environment["GNOSTIC_CLI_BINARY"] else { return }
        let folder = try TemporaryFolder()
        let path = folder.url.appendingPathComponent("node.json")
        #expect(try run(binary: binary, arguments: ["config", "init", "--config", path.path]).status == 0)

        let added = try run(
            binary: binary,
            arguments: ["config", "workspace", "add", "--name", "Scratch", "--uri", "workspace://scratch", "--config", path.path]
        )
        #expect(added.status == 0, Comment(rawValue: added.stderr))
        let workspaceID = try #require(UUID(uuidString: added.stdout.split(separator: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))

        let updated = try run(
            binary: binary,
            arguments: ["config", "workspace", "update", workspaceID.uuidString, "--name", "Renamed", "--config", path.path]
        )
        #expect(updated.status == 0, Comment(rawValue: updated.stderr))
        #expect(try CLIConfigurationStore(configPath: path, environment: [:]).loadManifest().workspaces.first { $0.id == workspaceID }?.name == "Renamed")

        let removed = try run(
            binary: binary,
            arguments: ["config", "workspace", "remove", workspaceID.uuidString, "--config", path.path]
        )
        #expect(removed.status == 0, Comment(rawValue: removed.stderr))
        #expect(try CLIConfigurationStore(configPath: path, environment: [:]).loadManifest().workspaces.contains { $0.id == workspaceID } == false)

        let malformed = Data("{not-json".utf8)
        try malformed.write(to: path)
        let validation = try run(binary: binary, arguments: ["config", "validate", "--config", path.path])
        #expect(validation.status != 0)
        #expect(try Data(contentsOf: path) == malformed)
    }

    private func run(binary: String, arguments: [String], stdin: String = "") throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}
