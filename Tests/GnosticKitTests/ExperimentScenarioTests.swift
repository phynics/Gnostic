// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import GnosticKit

/// Behavioral evidence for GNO-PLAT-031 (#506): the kit parses a frozen case
/// set, refuses a changed digest, and asserts the approved cases.
@Suite("Experiment scenario cases")
struct ExperimentScenarioTests {
    private let markdown = """
    # Cases

    ## Q1 — First

    **Question.** What is one?

    **Evidence.** `Sources/A.swift` (x).

    **Reference answer.** One.

    ## Q2 — Second

    **Question.** What is two?

    **Evidence.** `Sources/B.swift`.

    **Reference answer.** Two.
    """

    @Test("parses cases into id, prompt, reference, and evidence")
    func parsesCases() throws {
        let cases = try ExperimentScenarioCaseSet.parse(markdown)
        #expect(cases.map(\.id) == ["Q1", "Q2"])
        #expect(cases[0].prompt == "What is one?")
        #expect(cases[0].reference == "One.")
        #expect(cases[0].evidencePaths == ["Sources/A.swift"])
        #expect(cases[1].evidencePaths == ["Sources/B.swift"])
    }

    @Test("a changed case set is refused by digest")
    func changedCaseSetRefused() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kit-cases-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try markdown.write(to: url, atomically: true, encoding: .utf8)

        let digest = ExperimentDigest.sha256Hex([UInt8](markdown.utf8))
        let (cases, sha256) = try ExperimentScenarioCaseSet.load(from: url, expectedSHA256: digest)
        #expect(cases.count == 2)
        #expect(sha256 == digest)

        #expect(throws: ExperimentError.self) {
            _ = try ExperimentScenarioCaseSet.load(from: url, expectedSHA256: "deadbeef")
        }
    }

    @Test("a malformed case is refused")
    func malformedCaseRefused() {
        let missing = "## Q1 — X\n\n**Question.** q\n"
        #expect(throws: ExperimentError.self) {
            _ = try ExperimentScenarioCaseSet.parse(missing)
        }
    }

    @Test("normalization drops inline-code delimiters and collapses whitespace")
    func normalization() {
        #expect(
            ExperimentScenarioCaseSet.hashNormalizedText("a `b`  c")
                == ExperimentScenarioCaseSet.hashNormalizedText("a b c")
        )
    }
}
