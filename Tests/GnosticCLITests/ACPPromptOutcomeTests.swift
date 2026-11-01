// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol
import Testing

/// How a Turn's end reaches an ACP client through `gnostic acp`
/// (ADR 0019 section 2, ADR 0021 "Turn semantics").
@Suite("gnostic acp Turn outcomes", .serialized)
struct ACPPromptOutcomeTests {
    @Test(
        "an idle update without a stop reason reaches the client as idle without a stop reason",
        .timeLimit(.minutes(2)),
        .enabled(
            if: ProcessInfo.processInfo.environment["GNOSTIC_ACP_AGENT_FIXTURE"] != nil,
            "GNOSTIC_ACP_AGENT_FIXTURE is not set"
        )
    )
    @MainActor
    func idleWithoutStopReasonReachesTheClient() async throws {
        guard let harness = try await ACPFrontendHarness.start() else { return }
        let unspecifiedID = await harness.prompt("[fixture:idle-without-stop-reason]")
        let unspecified = await harness.wire.response(id: unspecifiedID, timeout: .seconds(20))
        #expect(unspecified?.error == nil, "The prompt failed: \(String(describing: unspecified?.error)).")
        let afterUnspecified = await harness.wire.notificationsAfterBoundary()
        let idleStates = afterUnspecified.filter { $0.contains(#""state":"idle""#) }
        #expect(idleStates.count == 1, "Expected one idle update, observed \(idleStates).")
        #expect(
            !idleStates.contains { $0.contains("stopReason") },
            "An idle update the Runtime sent without a stop reason reached the client with one: \(idleStates)."
        )

        // The same session still reports a stop reason when the Runtime names one.
        await harness.wire.markBoundary()
        let specifiedID = await harness.prompt("plain prompt")
        _ = await harness.wire.response(id: specifiedID, timeout: .seconds(20))
        let afterSpecified = await harness.wire.notificationsAfterBoundary()
        #expect(afterSpecified.contains { $0.contains(#""state":"idle""#) && $0.contains(#""stopReason":"end_turn""#) })
        await harness.tearDown()
    }

    @Test(
        "a Runtime crash during the prompt answers insertionUnknown, and a retry never prompts again",
        .timeLimit(.minutes(2)),
        .enabled(
            if: ProcessInfo.processInfo.environment["GNOSTIC_ACP_AGENT_FIXTURE"] != nil,
            "GNOSTIC_ACP_AGENT_FIXTURE is not set"
        )
    )
    @MainActor
    func lostPromptResponseReachesTheClientAsInsertionUnknown() async throws {
        let promptRequests = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-acp-unknown-prompts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: promptRequests) }
        guard let harness = try await ACPFrontendHarness.start(environment: [
            "GNOSTIC_ACP_FIXTURE_CRASH_ON_PROMPT": "1",
            "GNOSTIC_ACP_FIXTURE_PROMPT_REQUEST_FILE": promptRequests.path,
        ]) else { return }

        for attempt in 1...2 {
            let id = await harness.prompt("lose the response", clientTurnID: "acp-unknown-1")
            let response = await harness.wire.response(id: id, timeout: .seconds(20))
            guard let error = response?.error else {
                Issue.record("Attempt \(attempt) did not fail: \(String(describing: response)).")
                continue
            }
            #expect(error.data == .dictionary(["gnosticCode": .string("insertionUnknown")]), "attempt \(attempt): \(error)")
        }
        let prompts = ((try? String(contentsOf: promptRequests, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline)
        #expect(prompts.count == 1, "session/prompt reached the Runtime \(prompts.count) times.")
        await harness.tearDown()
    }
}
