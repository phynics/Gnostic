// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticLegacyCLI

@Suite("Shared --config option")
@MainActor
struct InspectConfigOptionTests {
    @Test("inspect and serve resolve --config to the same manifest path")
    func inspectAndServeShareOneStore() throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appendingPathComponent("node.json")

        let inspect = try InspectCommand.Node.parse(["--config", url.path])
        let serve = try ServeCommand.parse(["--config", url.path])

        let inspectStore = InspectSession.store(for: inspect.connection.values())
        #expect(inspectStore.path().path == url.path)
        #expect(serve.configOptions.store().path().path == inspectStore.path().path)
    }

    @Test("every inspect leaf accepts --config")
    func everyInspectLeafAcceptsConfig() throws {
        let folder = try TemporaryFolder()
        let path = folder.url.appendingPathComponent("node.json").path

        #expect(try InspectCommand.List.parse(["--config", path]).connection.values().configPath?.path == path)
        #expect(try InspectCommand.Node.parse(["--config", path]).connection.values().configPath?.path == path)
        #expect(try InspectCommand.Events.parse(["--config", path]).connection.values().configPath?.path == path)
        #expect(
            try InspectCommand.Ascendant.parse([UUID().uuidString, "--config", path]).connection.values().configPath?.path == path
        )
        #expect(
            try InspectCommand.Timeline.parse([UUID().uuidString, "--config", path]).connection.values().configPath?.path == path
        )
    }

    @Test("inspect without --config leaves the store to default resolution")
    func inspectWithoutConfigUsesDefaultResolution() throws {
        let values = try InspectCommand.Node.parse([]).connection.values()
        #expect(values.configPath == nil)
    }

    @Test("config leaves share the same --config option group")
    func configLeafUsesSharedOption() throws {
        let folder = try TemporaryFolder()
        let path = folder.url.appendingPathComponent("node.json").path

        let show = try ConfigCommand.Show.parse(["--config", path])
        #expect(show.configOptions.store().path().path == path)
    }

    @Test("inspect resolves its broker from the --config manifest")
    @MainActor
    func inspectResolvesBrokerFromManifest() throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appendingPathComponent("node.json")
        let store = CLIConfigurationStore(configPath: url, environment: [:])
        try store.initializeManifest()
        try ConfigCommandLogic.setBroker(
            host: "10.0.0.7",
            port: 2999,
            namespace: "manifest-ns",
            username: nil,
            store: store
        )

        let values = try InspectCommand.Node.parse(["--config", url.path]).connection.values()
        let settings = try InspectSession.brokerSettings(values: values)

        #expect(settings.host == "10.0.0.7")
        #expect(settings.port == 2999)
        #expect(settings.namespace == "manifest-ns")
    }

    @Test("explicit inspect broker flags still override the --config manifest")
    @MainActor
    func explicitFlagsOverrideManifest() throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appendingPathComponent("node.json")
        let store = CLIConfigurationStore(configPath: url, environment: [:])
        try store.initializeManifest()
        try ConfigCommandLogic.setBroker(host: "10.0.0.7", port: 2999, namespace: "manifest-ns", username: nil, store: store)

        let values = try InspectCommand.Node.parse(
            ["--config", url.path, "--host", "192.0.2.9", "--port", "3001"]
        ).connection.values()
        let settings = try InspectSession.brokerSettings(values: values)

        #expect(settings.host == "192.0.2.9")
        #expect(settings.port == 3001)
        #expect(settings.namespace == "manifest-ns")
    }
}
