// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticCLI

@Suite("Experiment command proxy")
struct ExperimentProxyTests {
    @Test("public proxy arguments retain the experiment subcommand")
    func proxyArguments() throws {
        let forwardedArguments = [
            "replay", "--trace", "trace.json", "--", "--future-option",
        ]
        let proxy = try ExperimentCommand.parse(forwardedArguments)
        #expect(proxy.arguments == forwardedArguments)
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
