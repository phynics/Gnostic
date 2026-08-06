// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Testing

@testable import GnosticRunner

@Suite("Runner argument parsing")
struct RunnerParsingTests {
    @Test("flags override environment which overrides defaults")
    func flagOverridesEnvironmentOverridesDefaults() throws {
        // Defaults only.
        let defaults = try RunnerConfiguration.resolve(
            flags: RunnerParsingFlags(host: nil, port: nil, namespace: nil),
            environment: [:]
        )
        #expect(defaults.host == "127.0.0.1")
        #expect(defaults.port == 1883)
        #expect(defaults.namespace == "gnostic")

        // Environment fills when flags absent.
        let fromEnvironment = try RunnerConfiguration.resolve(
            flags: RunnerParsingFlags(host: nil, port: nil, namespace: nil),
            environment: [
                "GNOSTIC_HOST": "env.example.com",
                "GNOSTIC_PORT": "1884",
                "GNOSTIC_NAMESPACE": "env-ns",
            ]
        )
        #expect(fromEnvironment.host == "env.example.com")
        #expect(fromEnvironment.port == 1884)
        #expect(fromEnvironment.namespace == "env-ns")

        // Flags beat environment.
        let flagsWin = try RunnerConfiguration.resolve(
            flags: RunnerParsingFlags(host: "flag.example.com", port: 1885, namespace: "flag-ns"),
            environment: [
                "GNOSTIC_HOST": "env.example.com",
                "GNOSTIC_PORT": "1884",
                "GNOSTIC_NAMESPACE": "env-ns",
            ]
        )
        #expect(flagsWin.host == "flag.example.com")
        #expect(flagsWin.port == 1885)
        #expect(flagsWin.namespace == "flag-ns")
    }

    @Test("invalid environment port produces a structured error")
    func invalidEnvironmentPortFails() throws {
        #expect(throws: RunnerParsingError.self) {
            _ = try RunnerConfiguration.resolve(
                flags: RunnerParsingFlags(host: nil, port: nil, namespace: nil),
                environment: ["GNOSTIC_PORT": "not-a-port"]
            )
        }
    }

    @Test("out-of-range environment port is rejected")
    func outOfRangePortRejected() throws {
        #expect(throws: RunnerParsingError.self) {
            _ = try RunnerConfiguration.resolve(
                flags: RunnerParsingFlags(host: nil, port: nil, namespace: nil),
                environment: ["GNOSTIC_PORT": "99999"]
            )
        }
    }
}

@Suite("Runner parse error surface")
struct RunnerParseErrorSurfaceTests {
    @Test("RunnerParsingError exposes stable descriptions and reason codes")
    func runnerParsingErrorSurface() {
        let invalid = RunnerParsingError.invalidPort("abc")
        #expect(invalid.errorDescription?.contains("abc") == true)
        #expect(invalid.errorDescription?.contains("port") == true)
        #expect(invalid.reasonCode == "invalidPort")
    }
}
