// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

@testable import GnosticRunner

@Suite("Online runner runtime")
struct OnlineRunnerTests {
    @Test("runner rejects removed in-process backend kinds") @MainActor
    func rejectsRemovedBackendKinds() async throws {
        for kind in ["positronic", "letta"] {
            let ascendantID = UUID()
            let timelineID = UUID()
            let manifest = NodeManifest(
                broker: .init(host: "127.0.0.1", port: 1883, namespace: "runner-removed-\(kind)"),
                node: .init(id: UUID()),
                ascendants: [.init(
                    id: ascendantID,
                    name: "Removed runtime",
                    defaultTimelineID: timelineID,
                    backend: .init(kind: kind)
                )],
                timelines: [.init(id: timelineID, title: "Timeline", operatingAscendantID: ascendantID)],
                workspaces: []
            )

            do {
                _ = try await RunnerRuntime(
                    plan: manifest.compileLaunchPlan(),
                    timelineJournalDirectory: FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                )
                Issue.record("runner accepted removed backend kind '\(kind)'")
            } catch let error as NodeRuntimeError {
                #expect(error.reasonCode == "unsupportedAscendantKind")
                #expect(error.errorDescription?.contains(kind) == true)
                #expect(error.errorDescription?.contains("Configure an ACP v2 Runtime") == true)
            }
        }
    }
}
