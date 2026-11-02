// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticACPWire
@_spi(RuntimeHost) import GnosticCore
import GnosticProtocol
import Testing

/// What a `gnostic acp` client assembles from a Runtime message that is longer
/// than one live Turn update can carry (issue #698).
@Suite("gnostic acp live update text bound", .serialized)
struct ACPUpdateTextBoundTests {
    /// Mirrors the fixture's `long-*` directives: 798 ASCII bytes, so a 4-byte
    /// scalar straddles the 800-byte mark, then 4-, 2- and 3-byte scalars.
    static func longText(bytes: Int) -> String {
        var text = String(repeating: "a", count: 798)
        while text.utf8.count < bytes { text += "\u{1F600}\u{E9}\u{65E5}" }
        return text + "|end"
    }

    @Test(
        "a Runtime message over the live update bound reaches the client whole, as the journal holds it",
        .timeLimit(.minutes(2)),
        .enabled(
            if: ProcessInfo.processInfo.environment["GNOSTIC_ACP_AGENT_FIXTURE"] != nil,
            "GNOSTIC_ACP_AGENT_FIXTURE is not set"
        ),
        arguments: [
            ("[fixture:long-chunk]", 2455),
            ("[fixture:long-agent-message]", 2455),
            ("[fixture:long-chunk:12000]", 12000),
            ("[fixture:long-agent-message:12000]", 12000),
            // Far more updates than the live event buffer holds in one burst.
            ("[fixture:long-chunk:300000]", 300_000),
        ]
    )
    @MainActor
    func overlongRuntimeMessageIsDeliveredWhole(directive: String, bytes: Int) async throws {
        guard let harness = try await ACPFrontendHarness.start(promptTimeout: .seconds(90)) else { return }
        let expected = Self.longText(bytes: bytes)
        let id = await harness.prompt(directive)
        let response = await harness.wire.response(id: id, timeout: .seconds(90))
        #expect(response?.error == nil, "The prompt failed: \(String(describing: response?.error)).")

        let chunks = await Self.agentChunks(harness.wire.notificationsAfterBoundary())
        let assembled = chunks.map(\.text).joined()
        #expect(assembled == expected, "The client assembled \(assembled.utf8.count) of \(expected.utf8.count) bytes.")
        #expect(chunks.count > 1, "The text should arrive as several in-order updates.")
        #expect(chunks.map(\.sequence) == chunks.map(\.sequence).sorted(), "Chunks arrived out of order.")
        #expect(Set(chunks.map(\.sequence)).count == chunks.count, "A sequence was delivered twice.")

        let journaled = try await Self.journaledAgentText(in: harness.scratch.appendingPathComponent("timeline-journals"))
        #expect(journaled == expected, "The journal holds \(journaled.utf8.count) bytes.")
        #expect(assembled == journaled, "The live text and the journal disagree.")
        await harness.tearDown()
    }

    @Test(
        "a retry of a completed Turn replays text that spans replay pages",
        .timeLimit(.minutes(2)),
        .enabled(
            if: ProcessInfo.processInfo.environment["GNOSTIC_ACP_AGENT_FIXTURE"] != nil,
            "GNOSTIC_ACP_AGENT_FIXTURE is not set"
        )
    )
    @MainActor
    func retryReplaysEveryPage() async throws {
        guard let harness = try await ACPFrontendHarness.start(promptTimeout: .seconds(90)) else { return }
        let directive = "[fixture:long-chunk:12000]"
        let expected = Self.longText(bytes: 12_000)
        let first = await harness.prompt(directive, clientTurnID: "long-retry")
        #expect(await harness.wire.response(id: first, timeout: .seconds(90))?.error == nil)

        let retry = await harness.prompt(directive, clientTurnID: "long-retry")
        #expect(await harness.wire.response(id: retry, timeout: .seconds(30))?.error == nil)
        let replayed = await Self.agentChunks(harness.wire.notificationsAfterBoundary(), replayed: true)
        #expect(replayed.map(\.text).joined() == expected)
        await harness.tearDown()
    }

    private static func agentChunks(_ notifications: [String], replayed: Bool = false) -> [(sequence: Int, text: String)] {
        notifications.compactMap { line in
            guard line.hasPrefix("session/update "),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(15).utf8)) as? [String: Any],
                  let update = object["update"] as? [String: Any],
                  update["sessionUpdate"] as? String == "agent_message_chunk",
                  let content = update["content"] as? [String: Any],
                  let text = content["text"] as? String,
                  let meta = update["_meta"] as? [String: Any],
                  let sequence = meta["sequence"] as? Int,
                  (meta["replayed"] as? Bool ?? false) == replayed else { return nil }
            return (sequence, text)
        }
    }

    private static func journaledAgentText(in directory: URL) async throws -> String {
        // A Node keeps its journals in a directory named for the Node.
        let nodeDirectories = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let nodeDirectory = try #require(nodeDirectories.first)
        let store = TimelineJournalStore(directoryURL: nodeDirectory)
        var text = ""
        for timelineID in try await store.timelineIDs() {
            for record in try await store.journal(for: timelineID).replay() {
                guard case let .acpUpdate(_, journaled) = record.payload else { continue }
                switch journaled.update {
                case let .agentMessageChunk(chunk):
                    if case let .text(content) = chunk.content { text += content.text }
                case let .agentMessage(message):
                    text = (message.content ?? []).reduce(into: "") { result, block in
                        if case let .text(content) = block { result += content.text }
                    }
                default:
                    break
                }
            }
        }
        return text
    }
}
