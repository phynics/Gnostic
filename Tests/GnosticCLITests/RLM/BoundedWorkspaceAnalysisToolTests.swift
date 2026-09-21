// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import PKContracts
import Testing

@testable import GnosticCLI

#if os(Linux)
@Suite("Bounded Workspace analysis tool")
struct BoundedWorkspaceAnalysisToolTests {
    @Test("captures one local Workspace and returns validated structured output")
    @MainActor
    func analyzesLocalWorkspace() async throws {
        let workspaceID = UUID()
        let runtime = PositronicContributionRuntimeContext(
            workspaceReader: FixtureWorkspaceReader(workspaceID: workspaceID),
            permission: AscendantBackendServices.empty.permission,
            modelService: FixtureRLMModel(),
            allowedWorkspaceIDs: [workspaceID]
        )
        let tool = AnalyzeWorkspaceCorpusTool(runtime: runtime, worker: .guile)

        let result = try await PositronicTurnInvocationContext.$current.withValue(
            .init(ascendantID: UUID(), timelineID: UUID(), turnID: UUID().uuidString)
        ) {
            try await tool.execute(parameters: [
                "question": AnyCodable("What is in the corpus?"),
                "workspaceID": AnyCodable(workspaceID.uuidString),
                "pathPrefixes": .array([.string("Sources")]),
            ])
        }

        #expect(result.isSuccess)
        #expect(result.output.contains("\"answer\":\"answer\""))
        #expect(result.output.contains("\"evidence\":[]"))
    }
}

private struct FixtureRLMModel: PositronicContributionModelService {
    func generate(prompt _: String, tier _: PositronicContributionModelTier) async throws -> String {
        "(finish \"answer\" (list))"
    }
}

@MainActor
private struct FixtureWorkspaceReader: PositronicContributionWorkspaceReader {
    let workspaceID: UUID

    func reference(id: UUID) async -> BackendWorkspaceReference? {
        guard id == workspaceID else { return nil }
        return BackendWorkspaceReference(id: id, uri: "file:///fixture", status: .available)
    }

    func readFile(workspaceID: UUID, path: String) async throws -> String {
        guard workspaceID == self.workspaceID, path == "Sources/example.swift" else {
            throw AscendantBackendError.invalidConfiguration("unexpected fixture path")
        }
        return "let answer = 42\n"
    }

    func listFiles(workspaceID: UUID, path: String) async throws -> [String] {
        guard workspaceID == self.workspaceID, path.isEmpty else {
            throw AscendantBackendError.invalidConfiguration("unexpected fixture listing")
        }
        return ["Sources/example.swift"]
    }
}
#endif
