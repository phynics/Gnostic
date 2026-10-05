// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import ArgumentParser
import Foundation
import GnosticCore
import Testing

@testable import GnosticRunner

@Suite("Runner argument parsing")
struct RunnerParsingTests {
    @Test("fixture scenario is not exposed by the shipped runner")
    func fixtureScenarioIsNotExposed() {
        #expect(!GnosticRunner.helpMessage().contains("--scenario"))
        #expect(throws: (any Error).self) {
            _ = try GnosticRunner.parseAsRoot(["--scenario"])
        }
    }

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

    @Test("the config flag beats GNOSTIC_CONFIG which beats the default graph")
    func configPathPrecedence() throws {
        let fromFlag = try RunnerConfiguration.resolve(
            flags: RunnerParsingFlags(host: nil, port: nil, namespace: nil, config: "/flag/manifest.json"),
            environment: ["GNOSTIC_CONFIG": "/env/manifest.json"]
        )
        #expect(fromFlag.configPath == "/flag/manifest.json")

        let fromEnvironment = try RunnerConfiguration.resolve(
            flags: RunnerParsingFlags(host: nil, port: nil, namespace: nil),
            environment: ["GNOSTIC_CONFIG": "/env/manifest.json"]
        )
        #expect(fromEnvironment.configPath == "/env/manifest.json")

        let defaults = try RunnerConfiguration.resolve(
            flags: RunnerParsingFlags(host: nil, port: nil, namespace: nil),
            environment: [:]
        )
        #expect(defaults.configPath == nil)
    }

    @Test("without a config path the runner hosts the default graph at the resolved broker")
    func defaultManifestUsesResolvedBroker() throws {
        let configuration = try RunnerConfiguration.resolve(
            flags: RunnerParsingFlags(host: "broker.example.com", port: 1884, namespace: "flag-ns"),
            environment: [:]
        )
        let manifest = try configuration.resolvedManifest()
        #expect(manifest.broker.host == "broker.example.com")
        #expect(manifest.broker.port == 1884)
        #expect(manifest.broker.namespace == "flag-ns")
        #expect(manifest.ascendants.contains { $0.backend.kind == "positronic" })
    }

    @Test("the resolved broker overrides the manifest broker")
    func resolvedBrokerOverridesManifest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("manifest.json")
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: "from-file"),
            node: .init(id: UUID())
        )
        let encoder = JSONEncoder()
        try encoder.encode(manifest).write(to: url)

        let configuration = try RunnerConfiguration.resolve(
            flags: RunnerParsingFlags(host: "flag.example.com", port: 1885, namespace: "from-flag", config: url.path),
            environment: [:]
        )
        let resolved = try configuration.resolvedManifest()
        #expect(resolved.broker.host == "flag.example.com")
        #expect(resolved.broker.port == 1885)
        #expect(resolved.broker.namespace == "from-flag")
    }

    @Test("a missing or malformed manifest is a structured error")
    func manifestErrorsAreStructured() throws {
        let missing = try RunnerConfiguration.resolve(
            flags: RunnerParsingFlags(host: nil, port: nil, namespace: nil, config: "/no/such/manifest.json"),
            environment: [:]
        )
        #expect(throws: RunnerParsingError.self) {
            _ = try missing.resolvedManifest()
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-bad-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("manifest.json")
        try Data("not json".utf8).write(to: url)
        let malformed = try RunnerConfiguration.resolve(
            flags: RunnerParsingFlags(host: nil, port: nil, namespace: nil, config: url.path),
            environment: [:]
        )
        #expect(throws: RunnerParsingError.self) {
            _ = try malformed.resolvedManifest()
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

        let missing = RunnerParsingError.missingManifest("/tmp/missing.json")
        #expect(missing.errorDescription?.contains("/tmp/missing.json") == true)
        #expect(missing.reasonCode == "missingManifest")

        let malformed = RunnerParsingError.malformedManifest("/tmp/bad.json")
        #expect(malformed.errorDescription?.contains("/tmp/bad.json") == true)
        #expect(malformed.reasonCode == "malformedManifest")
    }
}
