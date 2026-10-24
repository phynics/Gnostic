// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticCLI

/// Regression evidence for GNO-ARCH-006 (#563): every command that reads the
/// Node manifest selects it through the one ``ConfigPathOptions`` group, so the
/// flag spelling and store resolution cannot drift between commands.
///
/// `gnostic inspect` and `serve` already share the group; these tests cover the
/// commands the follow-up migration moved onto it.
@Suite("Shared config path option")
struct SharedConfigOptionTests {
    private func manifestPath() throws -> (folder: TemporaryFolder, path: String) {
        let folder = try TemporaryFolder()
        return (folder, folder.url.appendingPathComponent("node.json").path)
    }

    @Test("config module commands accept --config through the shared group")
    func configModuleCommandsAcceptConfig() throws {
        let (_, path) = try manifestPath()
        let ascendantID = UUID().uuidString

        let enable = try ConfigModuleCommand.Enable.parse([ascendantID, "rlm", "--config", path])
        #expect(enable.configOptions.store().path().path == path)
        let disable = try ConfigModuleCommand.Disable.parse([ascendantID, "rlm", "--config", path])
        #expect(disable.configOptions.store().path().path == path)
        let keys = try ConfigModuleCommand.Keys.parse([ascendantID, "--config", path])
        #expect(keys.configOptions.store().path().path == path)
    }

    @Test("config regime show accepts --config through the shared group")
    func configRegimeShowAcceptsConfig() throws {
        let (_, path) = try manifestPath()
        let show = try ConfigRegimeCommand.Show.parse([UUID().uuidString, "--config", path])
        #expect(show.configOptions.store().path().path == path)
    }

    @Test("rlm-scenario accepts --config through the shared group")
    func experimentCommandsAcceptConfig() throws {
        let (_, path) = try manifestPath()
        let scenario = try ExperimentCommand.RLMScenario.parse([
            "--stage", "pilot",
            "--ascendant", UUID().uuidString,
            "--config", path,
        ])
        #expect(scenario.configOptions.store().path().path == path)
    }

    @Test("gnostic acp accepts --config through the shared group")
    func acpAcceptsConfig() throws {
        let (_, path) = try manifestPath()
        let runtimeID = UUID().uuidString
        let acp = try ACPCommand.parse(["--runtime", runtimeID, "--config", path])
        #expect(acp.runtime == runtimeID)
        #expect(acp.configOptions.store().path().path == path)
    }

    @Test("commands without --config leave the store to default resolution")
    func omittedConfigUsesDefaultResolution() throws {
        let enable = try ConfigModuleCommand.Enable.parse([UUID().uuidString, "rlm"])
        #expect(enable.configOptions.configPath == nil)
        let acp = try ACPCommand.parse([])
        #expect(acp.configOptions.configPath == nil)
    }
}
