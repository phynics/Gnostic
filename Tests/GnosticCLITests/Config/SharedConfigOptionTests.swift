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

    @Test("gnostic acp accepts --config through the shared group")
    func acpAcceptsConfig() throws {
        let (_, path) = try manifestPath()
        let runtimeID = UUID().uuidString
        let acp = try ACPCommand.parse(["--runtime", runtimeID, "--config", path])
        #expect(acp.runtime == runtimeID)
        #expect(acp.configOptions.store().path().path == path)
    }

    @Test("ACP command without --config leaves the store to default resolution")
    func omittedConfigUsesDefaultResolution() throws {
        let acp = try ACPCommand.parse([])
        #expect(acp.configOptions.configPath == nil)
    }
}
