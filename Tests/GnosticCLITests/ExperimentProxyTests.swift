// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticCLI

@Suite("Experiment command proxy")
struct ExperimentProxyTests {
    @Test("public proxy arguments retain the experiment subcommand")
    func proxyArguments() throws {
        let proxy = try ExperimentCommand.parse(["replay", "--trace", "trace.json"])
        #expect(proxy.arguments == ["replay", "--trace", "trace.json"])
    }

    @Test("an explicit helper path is selected only when executable")
    func helperPath() {
        let helper = ExperimentExecutableLocator.locate(
            executablePath: "/missing/gnostic",
            environment: ["GNOSTIC_EXPERIMENT_EXECUTABLE": "/bin/sh", "PATH": ""]
        )
        #expect(helper?.path == "/bin/sh")
    }
}
