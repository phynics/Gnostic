// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticACPWire
@_spi(RuntimeHost) import GnosticCore
import GnosticProtocol
import Testing

/// What a `gnostic acp` client sees of a Runtime's thoughts and plans (issue #724, owner decision D32).
@Suite("gnostic acp thoughts and plans", .serialized)
struct ACPThoughtAndPlanTests {
    /// Mirrors the fixture's `thought` directive: 798 ASCII bytes, so a 4-byte scalar straddles the
    /// 800-byte mark, then 4-, 2- and 3-byte scalars.
    static func thoughtText(bytes: Int) -> String {
        var text = String(repeating: "t", count: 798)
        while text.utf8.count < bytes { text += "\u{1F600}\u{E9}\u{65E5}" }
        return text + "|thought-end"
    }

    private struct Rendered {
        var sequence: Int
        var kind: String
        var update: [String: Any]
        var meta: [String: Any]
        var replayed: Bool

        var text: String? { (update["content"] as? [String: Any])?["text"] as? String }
    }

    private static func rendered(_ notifications: [String], sessionUpdate: String, replayed: Bool = false) -> [Rendered] {
        notifications.compactMap { line in
            guard line.hasPrefix("session/update "),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(15).utf8)) as? [String: Any],
                  let update = object["update"] as? [String: Any],
                  update["sessionUpdate"] as? String == sessionUpdate,
                  let meta = update["_meta"] as? [String: Any],
                  let sequence = meta["sequence"] as? Int,
                  (meta["replayed"] as? Bool ?? false) == replayed else { return nil }
            return Rendered(
                sequence: sequence, kind: meta["kind"] as? String ?? "", update: update, meta: meta,
                replayed: replayed
            )
        }
    }

    private static func entries(of update: Rendered) -> [[String: Any]] {
        ((update.update["plan"] as? [String: Any])?["entries"] as? [[String: Any]]) ?? []
    }

    @Test(
        "a Runtime thought reaches the client whole as thought chunks, apart from the reply",
        .timeLimit(.minutes(2)),
        .enabled(
            if: ProcessInfo.processInfo.environment["GNOSTIC_ACP_AGENT_FIXTURE"] != nil,
            "GNOSTIC_ACP_AGENT_FIXTURE is not set"
        ),
        arguments: [2455, 12_000]
    )
    @MainActor
    func thoughtIsDeliveredWhole(bytes: Int) async throws {
        guard let harness = try await ACPFrontendHarness.start(promptTimeout: .seconds(90)) else { return }
        let directive = "[fixture:thought:\(bytes)]"
        let expected = Self.thoughtText(bytes: bytes)
        let id = await harness.prompt(directive, clientTurnID: "thought-turn")
        #expect(await harness.wire.response(id: id, timeout: .seconds(90))?.error == nil)

        let notifications = await harness.wire.notificationsAfterBoundary()
        let thoughts = Self.rendered(notifications, sessionUpdate: "agent_thought_chunk")
        #expect(thoughts.compactMap(\.text).joined() == expected)
        #expect(thoughts.count > 1, "The thought should arrive as several in-order updates.")
        #expect(thoughts.allSatisfy { $0.kind == "thought" })
        #expect(thoughts.map(\.sequence) == thoughts.map(\.sequence).sorted())
        #expect(Set(thoughts.map(\.sequence)).count == thoughts.count)

        // The reply stays the reply: no thought text in the assistant stream.
        let reply = Self.rendered(notifications, sessionUpdate: "agent_message_chunk").compactMap(\.text).joined()
        #expect(reply == "fixture reply: \(directive)")

        // A retry replays the completed Turn: the thought replays whole, and the result is the reply alone.
        let retry = await harness.prompt(directive, clientTurnID: "thought-turn")
        #expect(await harness.wire.response(id: retry, timeout: .seconds(30))?.error == nil)
        let replayedNotifications = await harness.wire.notificationsAfterBoundary()
        let replayedThought = Self.rendered(replayedNotifications, sessionUpdate: "agent_thought_chunk", replayed: true)
        #expect(replayedThought.compactMap(\.text).joined() == expected)
        let replayedReply = Self.rendered(replayedNotifications, sessionUpdate: "agent_message_chunk", replayed: true)
        #expect(replayedReply.compactMap(\.text).joined() == "fixture reply: \(directive)")
        await harness.tearDown()
    }

    @Test(
        "a Runtime plan reaches the client as plan updates, each replacing the last",
        .timeLimit(.minutes(2)),
        .enabled(
            if: ProcessInfo.processInfo.environment["GNOSTIC_ACP_AGENT_FIXTURE"] != nil,
            "GNOSTIC_ACP_AGENT_FIXTURE is not set"
        )
    )
    @MainActor
    func planIsDeliveredAsReplacement() async throws {
        guard let harness = try await ACPFrontendHarness.start(promptTimeout: .seconds(90)) else { return }
        let id = await harness.prompt("[fixture:plan]", clientTurnID: "plan-turn")
        #expect(await harness.wire.response(id: id, timeout: .seconds(60))?.error == nil)

        let notifications = await harness.wire.notificationsAfterBoundary()
        let plans = Self.rendered(notifications, sessionUpdate: "plan_update")
        #expect(plans.count == 2)
        #expect(plans.allSatisfy { $0.kind == "plan" })
        // Each update holds the whole plan, so a client that replaces loses nothing and one that appends is never asked to.
        #expect(plans.map { Self.entries(of: $0).count } == [2, 3])
        let latest = try #require(plans.last)
        #expect(Self.entries(of: latest).compactMap { $0["status"] as? String } == ["completed", "in_progress", "pending"])
        #expect(Self.entries(of: latest).compactMap { $0["content"] as? String }
            == ["read the file", "write the fix", "run the tests"])
        #expect(((latest.update["plan"] as? [String: Any])?["planId"] as? String) == "plan-1")

        let reply = Self.rendered(notifications, sessionUpdate: "agent_message_chunk").compactMap(\.text).joined()
        #expect(reply == "fixture reply: [fixture:plan]")
        await harness.tearDown()
    }

    @Test(
        "a plan over the bound is visibly cut and stays valid, and the journal keeps the whole plan",
        .timeLimit(.minutes(2)),
        .enabled(
            if: ProcessInfo.processInfo.environment["GNOSTIC_ACP_AGENT_FIXTURE"] != nil,
            "GNOSTIC_ACP_AGENT_FIXTURE is not set"
        )
    )
    @MainActor
    func overlongPlanIsVisiblyCut() async throws {
        guard let harness = try await ACPFrontendHarness.start(promptTimeout: .seconds(90)) else { return }
        let id = await harness.prompt("[fixture:plan-long:60]", clientTurnID: "plan-long-turn")
        #expect(await harness.wire.response(id: id, timeout: .seconds(60))?.error == nil)

        let plans = Self.rendered(await harness.wire.notificationsAfterBoundary(), sessionUpdate: "plan_update")
        let plan = try #require(plans.first)
        let entries = Self.entries(of: plan)
        #expect(plans.count == 1)
        #expect(!entries.isEmpty && entries.count < 60)
        #expect(plan.meta["truncated"] as? Bool == true)
        #expect(entries.last?["content"] as? String == TurnUpdate.truncationMarker)
        #expect(entries.dropLast().allSatisfy { ($0["content"] as? String)?.hasPrefix("step-") == true })

        let journaled = try await Self.journaledPlanEntryCount(in: harness.scratch.appendingPathComponent("timeline-journals"))
        #expect(journaled == 60)
        await harness.tearDown()
    }

    private static func journaledPlanEntryCount(in directory: URL) async throws -> Int {
        let nodeDirectory = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let store = TimelineJournalStore(directoryURL: nodeDirectory)
        var count = 0
        for timelineID in try await store.timelineIDs() {
            for record in try await store.journal(for: timelineID).replay() {
                guard case let .acpUpdate(_, journaled) = record.payload,
                      case let .planUpdate(update)? = journaled.update,
                      case let .items(_, entries, _) = update.plan else { continue }
                count = max(count, entries.count)
            }
        }
        return count
    }
}
