// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticProtocol
import Testing

/// What an ACP client sees through `gnostic acp` when it prompts a Timeline
/// that already has an active Turn (ADR 0021 "Turn semantics").
@Suite("gnostic acp busy Timeline", .serialized)
struct ACPPromptBusyTests {
    private func promptCount(_ file: URL) -> Int {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline).count
    }

    @Test(
        "the session guard rejects a second prompt on the same session without reaching the Node or the Runtime",
        .timeLimit(.minutes(2)),
        .enabled(
            if: ProcessInfo.processInfo.environment["GNOSTIC_ACP_AGENT_FIXTURE"] != nil,
            "GNOSTIC_ACP_AGENT_FIXTURE is not set"
        )
    )
    @MainActor
    func secondPromptIsRejectedAsBusy() async throws {
        let promptStarted = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-acp-busy-started-\(UUID().uuidString)")
        let promptRequests = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-acp-busy-prompts-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: promptStarted)
            try? FileManager.default.removeItem(at: promptRequests)
        }
        guard let harness = try await ACPFrontendHarness.start(
            environment: [
                "GNOSTIC_ACP_FIXTURE_PROMPT_STARTED_FILE": promptStarted.path,
                "GNOSTIC_ACP_FIXTURE_PROMPT_REQUEST_FILE": promptRequests.path,
            ]
        ) else { return }
        let wire = harness.wire

        let activeID = await harness.prompt("[fixture:wait]")
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: promptStarted.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: promptStarted.path), "The first prompt never reached the Runtime.")
        await wire.markBoundary()

        let rejectedID = await harness.prompt("second distinct prompt")
        let rejected = await wire.response(id: rejectedID, timeout: .seconds(8))
        if let error = rejected?.error {
            #expect(error.code == -32001)
            #expect(error.message == "Timeline is busy")
            #expect(error.data == .dictionary(["code": .string("timelineBusy"), "retryable": .boolean(true)]))
        } else {
            Issue.record("The second prompt was queued instead of rejected: \(String(describing: rejected)).")
        }
        // The rejected prompt is not part of the Timeline: no message, state, or
        // error update may mention it.
        let afterBoundary = await wire.notificationsAfterBoundary()
        #expect(
            !afterBoundary.contains { $0.contains("second distinct prompt") },
            "A rejected prompt was published as a session update."
        )
        #expect(
            !afterBoundary.contains { $0.contains(#""state":"idle""#) },
            "A rejected prompt ended the active Turn's visible state."
        )

        // This rejection came from the dispatcher's per-session guard. Only the
        // active Turn's prompt reached the Runtime.
        #expect(promptCount(promptRequests) == 1, "The rejected prompt reached the Runtime.")

        await harness.send("session/cancel", #"{"sessionId":"\#(harness.sessionID)"}"#)
        _ = await wire.response(id: activeID, timeout: .seconds(20))

        // The Timeline is idle again, so the same prompt is now admitted and runs.
        let retriedID = await harness.prompt("second distinct prompt")
        let retried = await wire.response(id: retriedID, timeout: .seconds(20))
        #expect(retried?.error == nil, "The retried prompt failed: \(String(describing: retried?.error)).")
        await harness.tearDown()
    }

    @Test(
        "the Node rejects a prompt that reaches a busy Timeline through a second connection, and the Runtime sees one prompt",
        .timeLimit(.minutes(2)),
        .enabled(
            if: ProcessInfo.processInfo.environment["GNOSTIC_ACP_AGENT_FIXTURE"] != nil,
            "GNOSTIC_ACP_AGENT_FIXTURE is not set"
        )
    )
    @MainActor
    func nodeRejectsAPromptFromASecondConnection() async throws {
        let promptStarted = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-acp-busy-node-started-\(UUID().uuidString)")
        let promptRequests = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-acp-busy-node-prompts-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: promptStarted)
            try? FileManager.default.removeItem(at: promptRequests)
        }
        guard let harness = try await ACPFrontendHarness.start(
            environment: [
                "GNOSTIC_ACP_FIXTURE_PROMPT_STARTED_FILE": promptStarted.path,
                "GNOSTIC_ACP_FIXTURE_PROMPT_REQUEST_FILE": promptRequests.path,
            ]
        ) else { return }
        let second = try await harness.openSecondConnection()

        let activeID = await harness.prompt("[fixture:wait]")
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: promptStarted.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: promptStarted.path), "The first prompt never reached the Runtime.")
        await second.wire.markBoundary()

        // The second connection holds no reservation for the session, so only
        // the Node's coordinator can reject this prompt.
        let rejectedID = await second.prompt("second connection prompt")
        let rejected = await second.wire.response(id: rejectedID, timeout: .seconds(8))
        if let error = rejected?.error {
            #expect(error.code == -32001)
            #expect(error.message == "Timeline is busy")
            #expect(error.data == .dictionary(["code": .string("timelineBusy"), "retryable": .boolean(true)]))
        } else {
            Issue.record("The Node queued the second connection's prompt: \(String(describing: rejected)).")
        }
        let afterBoundary = await second.wire.notificationsAfterBoundary()
        #expect(
            !afterBoundary.contains { $0.contains("second connection prompt") },
            "A prompt the Node rejected was published as a session update."
        )
        #expect(promptCount(promptRequests) == 1, "The rejected prompt reached the Runtime.")

        await harness.send("session/cancel", #"{"sessionId":"\#(harness.sessionID)"}"#)
        _ = await harness.wire.response(id: activeID, timeout: .seconds(20))
        await harness.tearDown()
    }
}
