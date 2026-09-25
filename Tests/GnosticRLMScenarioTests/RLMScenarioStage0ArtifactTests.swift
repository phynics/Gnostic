import Foundation
import GnosticRLM
import Testing

@Test("committed Stage 0 scenario artifact preserves question parity and deterministic repairs")
func committedScenarioStage0ArtifactIsValid() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let artifactURL = repositoryRoot
        .appendingPathComponent("Documentation")
        .appendingPathComponent("Experiments")
        .appendingPathComponent("rlm-scenario-stage0.json")

    let artifact = try JSONDecoder().decode(
        Stage0Artifact.self,
        from: Data(contentsOf: artifactURL)
    )

    #expect(artifact.schemaVersion == 1)
    #expect(artifact.scenario == "rlm-scenario-questions-v1")
    #expect(artifact.manifestID == "rlm-scenario-manifest-v1")
    #expect(artifact.manifestVersion == "v6")
    #expect(!artifact.generatedAtUTC.isEmpty)
    #expect(!artifact.corpusRevisionDigest.isEmpty)
    #expect(artifact.corpusFileCount > 0)
    #expect(artifact.corpusChunkCount > 0)
    #expect(!artifact.host.operatingSystem.isEmpty)

    let questionsURL = repositoryRoot.appendingPathComponent(artifact.questionSetPath)
    let questionSetDigest = RLMDigest.sha256Hex([UInt8](try Data(contentsOf: questionsURL)))
    #expect(questionSetDigest == artifact.questionSetSHA256)

    let m11 = try #require(artifact.validationEvidence?["M11"])
    let m12 = try #require(artifact.validationEvidence?["M12"])
    #expect(m11.status == "passed")
    #expect(m12.status == "passed")
    #expect(m11.suites.count == 2)
    #expect(m12.suites.count == 3)

    #expect(artifact.rows.map(\.id) == (1...12).map { "Q\($0)" })

    for row in artifact.rows {
        #expect(!row.questionSHA256.isEmpty)
        #expect(!row.referenceAnswerSHA256.isEmpty)
        for arm in [row.scripted, row.guile, row.chibi] {
            #expect(arm.status == "measured")
            #expect(arm.outcome == "completed")
            #expect(arm.semanticDigest != nil)
        }
        #expect(row.scripted.semanticDigest == row.guile.semanticDigest)
        #expect(row.guile.semanticDigest == row.chibi.semanticDigest)
        #expect(row.guile.repairs == 1)
        #expect(row.chibi.repairs == 1)
    }
}

@Test("committed Stage 0 rows hash the frozen question set verbatim")
func committedScenarioStage0RowsMatchFrozenQuestions() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let artifact = try JSONDecoder().decode(
        Stage0Artifact.self,
        from: Data(contentsOf: repositoryRoot.appendingPathComponent("Documentation/Experiments/rlm-scenario-stage0.json"))
    )
    let frozen = try FrozenQuestion.parse(
        String(decoding: Data(contentsOf: repositoryRoot.appendingPathComponent(artifact.questionSetPath)), as: UTF8.self)
    )

    #expect(frozen.map(\.id) == (1...12).map { "Q\($0)" })
    #expect(artifact.rows.map(\.id) == frozen.map(\.id))
    for (row, question) in zip(artifact.rows, frozen) {
        #expect(normalized(row.question) == question.question, "\(row.id) question text differs from the frozen set")
        #expect(row.questionSHA256 == RLMDigest.sha256Hex(question.question), "\(row.id) question hash")
        #expect(row.referenceAnswerSHA256 == RLMDigest.sha256Hex(question.referenceAnswer), "\(row.id) reference answer hash")
    }
}

/// An independent reading of `rlm-scenario-questions.md`, so the guard does not
/// share a parser with the harness it checks.
private struct FrozenQuestion {
    let id: String
    let question: String
    let referenceAnswer: String

    static func parse(_ text: String) throws -> [FrozenQuestion] {
        try text.components(separatedBy: "\n## Q").dropFirst().map { section in
            let id = "Q" + section.prefix { $0.isNumber }
            return FrozenQuestion(
                id: id,
                question: normalized(try #require(field("Question", in: section), "\(id) question")),
                referenceAnswer: normalized(try #require(field("Reference answer", in: section), "\(id) answer"))
            )
        }
    }

    private static func field(_ name: String, in section: String) -> String? {
        guard let start = section.range(of: "**\(name).**") else { return nil }
        let rest = section[start.upperBound...]
        return String(rest[..<(rest.range(of: "\n\n")?.lowerBound ?? rest.endIndex)])
    }
}

/// The manifest §7 hash normalization: inline-code delimiters dropped and
/// whitespace collapsed.
private func normalized(_ value: String) -> String {
    value.replacingOccurrences(of: "`", with: "")
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

private struct Stage0Artifact: Decodable {
    let schemaVersion: Int
    let scenario: String
    let manifestID: String
    let manifestVersion: String
    let questionSetSHA256: String
    let questionSetPath: String
    let generatedAtUTC: String
    let corpusRevisionDigest: String
    let corpusFileCount: Int
    let corpusChunkCount: Int
    let host: HostDescription
    let validationEvidence: [String: ValidationEvidence]?
    let rows: [ScenarioRow]
}

private struct HostDescription: Decodable {
    let operatingSystem: String
}

private struct ValidationEvidence: Decodable {
    let status: String
    let suites: [SuiteEvidence]
}

private struct SuiteEvidence: Decodable {
    let suite: String
}

private struct ScenarioRow: Decodable {
    let id: String
    let question: String
    let questionSHA256: String
    let referenceAnswerSHA256: String
    let scripted: ArmMeasurement
    let guile: ArmMeasurement
    let chibi: ArmMeasurement
}

private struct ArmMeasurement: Decodable {
    let status: String
    let outcome: String?
    let semanticDigest: String?
    let repairs: Int?
}
