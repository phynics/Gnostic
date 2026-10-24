// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticExperimentCLI

@Suite("Experiment executable boundary")
struct ExperimentBoundaryTests {
    @Test("RLM scenario keeps its existing argument shape in the isolated executable")
    func rlmScenarioArguments() throws {
        let scenario = try ExperimentCommand.RLMScenario.parse([
            "--stage", "pilot",
            "--ascendant", UUID().uuidString,
            "--config", "/tmp/node.json",
        ])
        #expect(scenario.stage == "pilot")
        #expect(scenario.configPath == "/tmp/node.json")
    }

}
