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
