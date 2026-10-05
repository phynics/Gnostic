// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

@testable import GnosticCLI
@testable import GnosticHost

/// Behavioral evidence for GNO-PLAT-022 (#450): `gnostic experiment
/// rlm-scenario` is routed through the RLM module descriptor's optional
/// experiment subcommand, not through a subcommand list hardcoded in the CLI.
///
/// The module declares the subcommand's name and one-line summary; the
/// composition exposes every declared module experiment subcommand; the CLI
/// registers the implementations it owns for the declared names. Argument
/// parsing and rendering stay in the CLI, so GnosticHost never depends on
/// ArgumentParser.
@Suite("RLM module experiment subcommand")
struct RLMModuleExperimentSubcommandTests {
    @Test("the compiled-in RLM descriptor declares the rlm-scenario subcommand")
    func rlmDescriptorDeclaresScenarioSubcommand() {
        #expect(
            RLMModule.value.experimentSubcommand
                == GnosticModuleSubcommand(
                    name: "rlm-scenario",
                    abstract: "Run the RLM scenario live stages (pilot or full matrix) against a configured provider."
                )
        )
    }

    @Test("the production composition exposes the RLM module's declared subcommand")
    func compositionExposesDeclaredExperimentSubcommands() {
        #expect(
            BackendComposition.default.registeredExperimentSubcommands
                == [
                    GnosticModuleSubcommand(
                        name: "rlm-scenario",
                        abstract: "Run the RLM scenario live stages (pilot or full matrix) against a configured provider."
                    )
                ]
        )
    }

    @Test("a module without a subcommand contributes none to the CLI")
    func moduleWithoutSubcommandContributesNone() {
        // Atlas is a runnable module, but its descriptor declares no experiment
        // subcommand, so it must not appear in the experiment command surface.
        #expect(AtlasModule.value.experimentSubcommand == nil)

        let declared = BackendComposition.default.registeredExperimentSubcommands.map(\.name)
        #expect(!declared.contains("atlas"))
        #expect(!declared.contains("rlm-scenario-rating"))
    }

    @Test("the CLI composes its experiment commands from the descriptor's name")
    func cliComposesFromModuleDescriptors() {
        // The experiment command surface is exactly the intrinsic rating
        // command plus the module-declared subcommands, in legacy order. The
        // descriptor's declared name must equal the CLI parser's own name, so
        // one declaration both routes and documents the command.
        let names = ExperimentCommand.configuration.subcommands.map { $0.configuration.commandName }
        #expect(names == ["rlm-scenario", "run", "export", "replay", "rlm-scenario-rating"])
        #expect(RLMModule.value.experimentSubcommand?.name == ExperimentCommand.RLMScenario.configuration.commandName)
    }

    @Test("an Ascendant that selects rlm materializes the analysis contribution")
    func selectingRlmMaterializesContribution() throws {
        // Mirrors the Atlas module evidence: the descriptor builds its
        // contribution when the Positronic backend materializes the Ascendant,
        // so a manifest that selects `extensions: ["rlm"]` installs the
        // bounded-analysis tool. No live provider or Scheme worker is needed to
        // build it, which is why the runner smoke accepts the manifest offline.
        let ascendant = NodeManifest.Ascendant(
            id: UUID(),
            name: "RLM",
            defaultTimelineID: UUID(),
            backend: .init(
                kind: "positronic",
                settings: ["extensions": .array([.string("rlm")])]
            )
        )
        let runtime = PositronicContributionRuntimeContext(
            workspaceReader: nil,
            modelService: nil,
            allowedWorkspaceIDs: []
        )

        let contributions = try BackendComposition.contributions(
            for: ascendant,
            backend: ascendant.backend,
            modules: ["rlm": RLMModule.value],
            runtimeContext: runtime
        )

        #expect(contributions.map(\.label) == ["rlm"])
        #expect(contributions.first?.tools().count == 1)
    }
}

/// Proof at the binary seam that the migration preserves `gnostic experiment`
/// behavior: help still advertises both commands and `rlm-scenario` still
/// routes to its own help and options (GNO-PLAT-022, #450).
@Suite("RLM experiment subcommand subprocess", .serialized)
struct RLMExperimentSubcommandSubprocessTests {
    @Test("gnostic experiment still lists and routes rlm-scenario after the descriptor migration")
    func experimentSurfacePreserved() throws {
        guard let binary = ProcessInfo.processInfo.environment["GNOSTIC_CLI_BINARY"] else { return }

        let help = try run(binary: binary, arguments: ["experiment", "--help"])
        #expect(help.status == 0, Comment(rawValue: help.output))
        #expect(help.output.contains("rlm-scenario"))
        #expect(help.output.contains("rlm-scenario-rating"))

        let scenarioHelp = try run(binary: binary, arguments: ["experiment", "rlm-scenario", "--help"])
        #expect(scenarioHelp.status == 0, Comment(rawValue: scenarioHelp.output))
        #expect(scenarioHelp.output.contains("--stage"))
        #expect(scenarioHelp.output.contains("--ascendant"))

        let ratingHelp = try run(binary: binary, arguments: ["experiment", "rlm-scenario-rating", "--help"])
        #expect(ratingHelp.status == 0, Comment(rawValue: ratingHelp.output))
        #expect(ratingHelp.output.contains("--artifact"))

        let runHelp = try run(binary: binary, arguments: ["experiment", "run", "--help"])
        #expect(runHelp.status == 0, Comment(rawValue: runHelp.output))
        #expect(runHelp.output.contains("--confirm-spend"))

        let exportHelp = try run(binary: binary, arguments: ["experiment", "export", "--help"])
        #expect(exportHelp.status == 0, Comment(rawValue: exportHelp.output))
    }

    private func run(binary: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self) + String(decoding: errorData, as: UTF8.self)
        )
    }
}