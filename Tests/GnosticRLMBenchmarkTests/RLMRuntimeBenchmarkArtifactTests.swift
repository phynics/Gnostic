import Foundation
import Testing

@Test("committed runtime benchmark artifact preserves its schema and worker parity")
func committedRuntimeBenchmarkArtifactIsValid() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let artifactURL = repositoryRoot
        .appendingPathComponent("Documentation")
        .appendingPathComponent("Experiments")
        .appendingPathComponent("rlm-runtime-benchmark.json")

    let artifact = try JSONDecoder().decode(
        BenchmarkArtifact.self,
        from: Data(contentsOf: artifactURL)
    )

    #expect(artifact.schemaVersion == 1)
    #expect(artifact.benchmark == "bounded-repository-fixture-v1")
    #expect(artifact.outcome == "CONTINUE_EXPERIMENT")
    #expect(!artifact.generatedAtUTC.isEmpty)
    #expect(!(artifact.gitCommit ?? "").isEmpty)

    let measurements = Dictionary(uniqueKeysWithValues: artifact.measurements.map { ($0.runtime, $0) })
    let guile = try #require(measurements["guile"])
    let chibi = try #require(measurements["chibi"])
    #expect(guile.status == "measured")
    #expect(chibi.status == "measured")
    #expect(guile.semanticResultDigest != nil)
    #expect(guile.semanticResultDigest == chibi.semanticResultDigest)

    let unavailableNames = Set(artifact.unavailableMeasurements.map(\.name))
    #expect(unavailableNames.contains("generated-cell-repair-rate"))
    #expect(unavailableNames.contains("malicious-program-safety"))
    #expect(unavailableNames.contains("heap-and-loop-containment"))
}

private struct BenchmarkArtifact: Decodable {
    let schemaVersion: Int
    let benchmark: String
    let generatedAtUTC: String
    let gitCommit: String?
    let outcome: String
    let measurements: [RuntimeMeasurement]
    let unavailableMeasurements: [UnavailableMeasurement]
}

private struct RuntimeMeasurement: Decodable {
    let runtime: String
    let status: String
    let semanticResultDigest: String?
}

private struct UnavailableMeasurement: Decodable {
    let name: String
}
