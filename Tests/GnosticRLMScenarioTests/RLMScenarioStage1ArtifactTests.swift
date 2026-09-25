import Foundation
import Testing

@Test("committed Stage 1 artifact proves or bounds every macOS containment property")
func committedScenarioStage1ArtifactIsValid() throws {
    let artifactURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Documentation")
        .appendingPathComponent("Experiments")
        .appendingPathComponent("rlm-scenario-stage1.json")

    let artifact = try JSONDecoder().decode(
        Stage1Artifact.self,
        from: Data(contentsOf: artifactURL)
    )

    #expect(artifact.schemaVersion == 1)
    #expect(artifact.manifestID == "rlm-scenario-manifest-v1")
    #expect(artifact.manifestVersion == "v6")
    #expect(artifact.stage == "stage-1-environment")
    #expect(artifact.outcome == "stage-1-no-spend-complete")
    #expect(artifact.providerSpend == "none")
    #expect(!artifact.gitCommit.isEmpty)
    #expect(artifact.host.operatingSystem == "darwin")

    #expect(artifact.suites.count == 9)
    for suite in artifact.suites {
        #expect(suite.tests > 0, "\(suite.filter) executed no tests")
        #expect(suite.failed == 0, "\(suite.filter) failed on macOS")
    }
    #expect(!artifact.probes.isEmpty)
    #expect(artifact.probes.allSatisfy { $0.status == "passed" })

    // Manifest §4: M13 is satisfied when every #353 guarantee is proven on
    // macOS or recorded as a bounded gap.
    #expect(artifact.M13.status == "satisfied")
    #expect(
        artifact.M13.properties.map(\.property)
            == ["cpu", "address-space", "wall-time", "file-descriptors", "environment"]
    )
    for row in artifact.M13.properties {
        #expect(!row.evidence.tests.isEmpty, "\(row.property) cites no tests")
        switch row.macOS {
        case "proven":
            #expect(row.bound == nil)
            #expect(
                row.evidence.tests.allSatisfy { $0.result == "passed" },
                "\(row.property) is proven only by passing tests"
            )
        case "bounded-gap":
            #expect(row.bound?.isEmpty == false, "\(row.property) gap has no recorded bound")
            #expect(row.evidence.tests.allSatisfy { $0.result != "failed" })
        default:
            Issue.record("\(row.property) has unknown macOS status \(row.macOS)")
        }
    }

    // Manifest §5a: M14 records structural facts only.
    #expect(artifact.M14.status == "recorded")
    #expect(artifact.M14.executors.map(\.name) == ["chibi", "guile"])
    let chibi = try #require(artifact.M14.executors.first { $0.name == "chibi" })
    #expect(chibi.buildFlagCount == chibi.buildFlags.count)
    #expect(chibi.buildConfigurationCoupling.coupled)
    #expect(chibi.buildConfigurationCoupling.pinnedBy?.result == "passed")
}

private struct Stage1Artifact: Decodable {
    let schemaVersion: Int
    let manifestID: String
    let manifestVersion: String
    let stage: String
    let outcome: String
    let gitCommit: String
    let providerSpend: String
    let host: HostDescription
    let suites: [SuiteEvidence]
    let probes: [ProbeEvidence]
    let M13: ContainmentMatrix
    let M14: PackagingRecord
}

private struct HostDescription: Decodable {
    let operatingSystem: String
}

private struct SuiteEvidence: Decodable {
    let filter: String
    let tests: Int
    let failed: Int
}

private struct ProbeEvidence: Decodable {
    let status: String
}

private struct ContainmentMatrix: Decodable {
    let status: String
    let properties: [ContainmentRow]
}

private struct ContainmentRow: Decodable {
    let property: String
    let macOS: String
    let bound: String?
    let evidence: ContainmentEvidence
}

private struct ContainmentEvidence: Decodable {
    let tests: [TestEvidence]
}

private struct TestEvidence: Decodable {
    let test: String
    let result: String
}

private struct PackagingRecord: Decodable {
    let status: String
    let executors: [ExecutorPackaging]
}

private struct ExecutorPackaging: Decodable {
    let name: String
    let buildFlags: [String]
    let buildFlagCount: Int
    let buildConfigurationCoupling: Coupling
}

private struct Coupling: Decodable {
    let coupled: Bool
    let pinnedBy: TestEvidence?
}
