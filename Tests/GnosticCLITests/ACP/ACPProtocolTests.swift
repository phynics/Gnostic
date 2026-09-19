// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import PKContracts
import Testing

@testable import GnosticCLI

@Suite("ACP adapter protocol")
struct ACPProtocolTests {
    @Test("session registry persists identity without conversation content")
    func registryRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-acp-\(UUID().uuidString)")
            .appendingPathComponent("sessions.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let registry = ACPSessionRegistry(url: url)
        let ascendantID = UUID()
        let timelineID = UUID()
        let created = try await registry.create(
            profileFingerprint: "namespace:\(ascendantID.uuidString)",
            ascendantID: ascendantID,
            timelineID: timelineID,
            cwd: "/workspace/project",
            title: "ACP project"
        )

        #expect(created.timelineID == timelineID)
        #expect(created.cwd == "/workspace/project")
        let persisted = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(!persisted.contains("conversation"))

        let restored = ACPSessionRegistry(url: url)
        let record = await restored.record(id: created.id)
        #expect(record?.ascendantID == ascendantID)
        #expect(record?.timelineID == timelineID)
        #expect(record?.cwd == "/workspace/project")

        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: url.deletingLastPathComponent().path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("timeline presence separates a confirmed-absent Timeline from an undiscovered network")
    func timelinePresenceClassification() {
        let present = UUID()
        let ambiguous = UUID()
        let missing = UUID()
        let live = TimelinePresenceSnapshot(
            providersByTimeline: [present: ["node-a"], ambiguous: ["node-a", "node-b"]],
            hasDiscoveredNode: true
        )
        #expect(live.presence(of: present) == .present(providerID: "node-a"))
        #expect(live.presence(of: ambiguous) == .ambiguous)
        #expect(live.presence(of: missing) == .absent)

        // No Node answered discovery, so nothing is proven about any Timeline.
        let dark = TimelinePresenceSnapshot(providersByTimeline: [:], hasDiscoveredNode: false)
        #expect(dark.presence(of: missing) == .indeterminate)
    }

    @Test("ending an orphaned record keeps it on disk and does not move its first end")
    func registryMarksOrphanedRecordsEnded() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-acp-orphan-\(UUID().uuidString)")
            .appendingPathComponent("sessions.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let registry = ACPSessionRegistry(url: url)
        let created = try await registry.create(
            profileFingerprint: "namespace:provider:ascendant",
            ascendantID: UUID(),
            timelineID: UUID(),
            cwd: "/workspace/project",
            title: "ACP project"
        )
        #expect(created.closedAt == nil)

        let ended = try #require(try await registry.markEnded(id: created.id))
        let closedAt = try #require(ended.closedAt)
        #expect(ended.updatedAt == created.updatedAt)

        // Reconciliation runs on every list; only the first end may set the time.
        let reEnded = try #require(try await registry.markEnded(id: created.id))
        #expect(reEnded.closedAt == closedAt)

        let restored = ACPSessionRegistry(url: url)
        let persisted = try #require(await restored.record(id: created.id))
        #expect(persisted.closedAt == closedAt)
        #expect(persisted.cwd == "/workspace/project")
    }

    #if !os(macOS)
    @Test("Linux session registry uses the XDG application-state directory")
    func registryUsesXDGStateHome() {
        let url = ACPSessionRegistry.defaultURL(
            environment: ["XDG_STATE_HOME": "/tmp/gnostic-xdg-state"],
            homeDirectory: URL(fileURLWithPath: "/tmp/gnostic-home", isDirectory: true)
        )
        #expect(url.path == "/tmp/gnostic-xdg-state/gnostic/acp-sessions-v1.json")
    }
    #endif

    @Test("ACP profile cache is bounded by broker configuration and TTL")
    func profileCacheRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-acp-cache-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("profiles.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = ACPProfileCache(url: url)
        let key = ACPProfileCacheKey(host: "127.0.0.1", port: 1883, namespace: "cache-test")
        let profile = ACPProfile(
            id: "gnostic-agent",
            name: "Agent",
            command: "gnostic",
            args: ["acp"],
            env: [:]
        )
        let bundle = ACPProfileBundle(version: 1, defaultProfile: nil, profiles: [profile])
        let generatedAt = Date(timeIntervalSince1970: 10_000)

        try cache.store(bundle, for: key, generatedAt: generatedAt)
        #expect(cache.load(for: key, now: generatedAt.addingTimeInterval(29))?.profiles.map(\.id) == ["gnostic-agent"])
        #expect(cache.load(for: key, now: generatedAt.addingTimeInterval(31)) == nil)
        #expect(cache.load(
            for: ACPProfileCacheKey(host: "127.0.0.1", port: 1883, namespace: "other"),
            now: generatedAt.addingTimeInterval(1)
        ) == nil)
    }

    @Test("profiles pin a node only when one Ascendant is served by more than one node")
    func profilesPinNodeOnlyWhenAmbiguous() throws {
        let ascendantID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000031")!
        let otherAscendantID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000032")!
        let firstNodeID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000041")!
        let secondNodeID = UUID(uuidString: "C41D0000-0000-4000-8000-000000000042")!

        let single = ACPCommand.profiles(
            from: [ascendantEntry(id: ascendantID, providerID: "provider-a", nodeID: firstNodeID)],
            host: "127.0.0.1",
            port: 1883,
            namespace: "profiles"
        )
        let onlyProfile = try #require(single.first)
        #expect(single.count == 1)
        #expect(onlyProfile.id == "gnostic-\(ascendantID.uuidString.lowercased())")
        #expect(onlyProfile.args == [
            "acp",
            "--host", "127.0.0.1",
            "--port", "1883",
            "--namespace", "profiles",
            "--ascendant", ascendantID.uuidString.lowercased(),
        ])

        // A second serve process of the same node is the same address, so the
        // profile stays restart-stable instead of naming either process.
        let restarted = ACPCommand.profiles(
            from: [
                ascendantEntry(id: ascendantID, providerID: "provider-a", nodeID: firstNodeID),
                ascendantEntry(id: ascendantID, providerID: "provider-b", nodeID: firstNodeID),
            ],
            host: "127.0.0.1",
            port: 1883,
            namespace: "profiles"
        )
        #expect(restarted.map(\.id) == [onlyProfile.id])
        #expect(restarted.allSatisfy { !$0.args.contains("--provider") })

        let duplicated = ACPCommand.profiles(
            from: [
                ascendantEntry(id: ascendantID, providerID: "provider-a", nodeID: firstNodeID),
                ascendantEntry(id: ascendantID, providerID: "provider-b", nodeID: secondNodeID),
                ascendantEntry(id: otherAscendantID, providerID: "provider-b", nodeID: secondNodeID),
            ],
            host: "127.0.0.1",
            port: 1883,
            namespace: "profiles"
        )
        #expect(duplicated.map(\.id) == [
            "gnostic-\(ascendantID.uuidString.lowercased())-\(firstNodeID.uuidString.lowercased())",
            "gnostic-\(ascendantID.uuidString.lowercased())-\(secondNodeID.uuidString.lowercased())",
            "gnostic-\(otherAscendantID.uuidString.lowercased())",
        ])
        #expect(duplicated.allSatisfy { !$0.args.contains("--provider") })
        #expect(duplicated.prefix(2).compactMap { profile -> String? in
            guard let index = profile.args.firstIndex(of: "--node") else { return nil }
            return profile.args[index + 1]
        } == [firstNodeID.uuidString.lowercased(), secondNodeID.uuidString.lowercased()])

        // A serve that advertises no node identity keeps the provider as its
        // only available selector.
        let legacy = ACPCommand.profiles(
            from: [
                ascendantEntry(id: ascendantID, providerID: "provider-a", nodeID: nil),
                ascendantEntry(id: ascendantID, providerID: "provider-b", nodeID: nil),
            ],
            host: "127.0.0.1",
            port: 1883,
            namespace: "profiles"
        )
        #expect(legacy.count == 2)
        #expect(legacy.allSatisfy { $0.args.contains("--provider") })
    }

    @Test("a cached profile bundle that pins a provider is discarded")
    func cachedProviderPinnedBundleIsDiscarded() {
        let base = ["acp", "--namespace", "cache", "--ascendant", "a"]
        let stable = ACPProfileBundle(version: 1, defaultProfile: nil, profiles: [
            ACPProfile(id: "gnostic-a", name: "A", command: "gnostic", args: base, env: [:])
        ])
        let pinned = ACPProfileBundle(version: 1, defaultProfile: nil, profiles: [
            ACPProfile(id: "gnostic-a", name: "A", command: "gnostic", args: base + ["--provider", "p"], env: [:])
        ])
        #expect(stable.isRestartStable)
        #expect(!pinned.isRestartStable)
    }

    @Test("a session record written before the node binding still loads")
    func legacySessionRecordStillLoads() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-acp-legacy-\(UUID().uuidString)")
            .appendingPathComponent("sessions.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let ascendantID = UUID()
        let legacy = """
        [{"id":"session-legacy",
          "profileFingerprint":"namespace:4293ec9c:\(ascendantID.uuidString.lowercased())",
          "ascendantID":"\(ascendantID.uuidString)",
          "timelineID":"\(UUID().uuidString)",
          "providerID":"4293ec9c",
          "cwd":"/workspace/project",
          "title":"Legacy",
          "createdAt":0,
          "updatedAt":0}]
        """
        try Data(legacy.utf8).write(to: url)

        let registry = ACPSessionRegistry(url: url)
        let record = try #require(await registry.record(id: "session-legacy"))
        #expect(record.ascendantID == ascendantID)
        #expect(record.nodeID == nil)
        #expect(record.providerID == "4293ec9c")

        // New records never persist a provider identity.
        let created = try await registry.create(
            profileFingerprint: "namespace:node:\(UUID().uuidString.lowercased()):\(ascendantID.uuidString.lowercased())",
            ascendantID: ascendantID,
            timelineID: UUID(),
            cwd: "/workspace/project",
            title: "Current",
            nodeID: UUID(uuidString: "C41D0000-0000-4000-8000-000000000051")!
        )
        #expect(created.providerID == nil)
        #expect(created.nodeID == UUID(uuidString: "C41D0000-0000-4000-8000-000000000051"))

        // Both records survive the reload: the legacy one keeps its retained
        // provider field, the new one has none to keep.
        let reloaded = ACPSessionRegistry(url: url)
        #expect(await reloaded.record(id: "session-legacy")?.providerID == "4293ec9c")
        #expect(await reloaded.record(id: created.id)?.providerID == nil)
    }

    @Test("prompt accepts only text and carries the stable client turn id")
    func promptMetadata() throws {
        let params = ACPPromptParameters(
            sessionID: "session-1",
            prompt: [ACPPromptContent(type: "text", text: "hello")],
            mcpServers: [],
            metadata: [ACPProtocol.turnIDMetadataKey: .string("pi:session:entry")]
        )
        #expect(params.text == "hello")
        #expect(params.clientTurnID == "pi:session:entry")

        let image = ACPPromptParameters(
            sessionID: "session-1",
            prompt: [ACPPromptContent(type: "image", text: nil)],
            mcpServers: [],
            metadata: nil
        )
        #expect(image.text == nil)
    }

    @Test("ACP notifications are LF-delimited JSON-RPC notifications")
    func notificationFraming() async throws {
        let output = OutputCapture()
        let session = JSONRPCSession(
            handler: { _ in .dictionary([:]) },
            output: output.append,
            initialize: { .dictionary([:]) },
            notification: output.append
        )

        await session.sendNotification(
            method: "session/update",
            params: .dictionary(["sessionId": .string("session-1")])
        )

        let request = try #require(output.requests().first)
        #expect(request.id == nil)
        #expect(request.method == "session/update")
    }

    @Test("ACP client requests correlate responses on the shared stdio stream")
    func clientRequestRoundTrip() async throws {
        let output = OutputCapture()
        let broker = ACPClientRequestBroker(output: output.append)
        let session = JSONRPCSession(
            handler: { _ in .dictionary([:]) },
            output: output.append,
            initialize: { .dictionary([:]) },
            response: { response in await broker.receive(response) }
        )
        let pending = Task {
            try await broker.request(
                method: "session/request_permission",
                params: .dictionary(["sessionId": .string("session-1")])
            )
        }

        var request: JSONRPCRequest?
        for _ in 0..<100 where request == nil {
            request = try? output.requests().first
            if request == nil { await Task.yield() }
        }
        let emitted = try #require(request)
        #expect(emitted.method == "session/request_permission")
        #expect(emitted.id != nil)

        let response = JSONRPCResponse(
            id: emitted.id,
            result: .dictionary(["outcome": .string("selected")])
        )
        await session.receive(try JSONEncoder().encode(response) + Data([0x0A]))
        #expect(try await pending.value == .dictionary(["outcome": .string("selected")]))
    }

    @Test("cancelling an ACP prompt releases its pending client permission request")
    func clientRequestCancellation() async throws {
        let output = OutputCapture()
        let broker = ACPClientRequestBroker(output: output.append)
        let pending = Task {
            try await broker.request(
                method: "session/request_permission",
                params: .dictionary(["sessionId": .string("session-1")])
            )
        }

        for _ in 0..<100 where (try? output.requests().isEmpty) != false {
            await Task.yield()
        }
        #expect(try output.requests().count == 1)
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await broker.pendingCount == 0)
    }

    @Test("a request cancelled before its continuation installs resumes instead of stranding")
    func clientRequestCancelledBeforeInstall() async throws {
        let output = OutputCapture()
        let broker = ACPClientRequestBroker(output: output.append)
        let pending = Task {
            // Cancel the calling task before `request` installs its
            // continuation, the window where a detached cancellation hop could
            // race the install and leave the request suspended forever.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await broker.request(
                method: "session/request_permission",
                params: .dictionary(["sessionId": .string("session-1")])
            )
        }

        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await broker.pendingCount == 0)
    }

    @Test("structured Ascendant tool states render as stable ACP tool updates")
    func structuredToolUpdate() throws {
        let update = AscendantTurnUpdate(
            sequence: 7,
            kind: "tool_state",
            toolState: AscendantToolState(
                toolCallID: "call-7",
                title: "Read file",
                status: "in_progress"
            )
        )

        let rendered = ACPUpdateRenderer.updates(
            sessionID: "session-1",
            turnID: "turn-1",
            update: update,
            replayed: false
        )
        let notification = try #require(rendered.first)
        let params = try #require(notification.params.dictionaryValue)
        let payload = try #require(params["update"]?.dictionaryValue)
        #expect(notification.method == "session/update")
        #expect(payload["sessionUpdate"] == .string("tool_call_update"))
        #expect(payload["toolCallId"] == .string("call-7"))
        #expect(payload["title"] == .string("Read file"))
        #expect(payload["status"] == .string("in_progress"))
    }

    @Test("pending Ascendant permission maps to stable ACP request and selected outcome")
    func permissionRequestMapping() throws {
        let state = AscendantPermissionState(
            correlationID: "permission-1",
            toolCallID: "call-1",
            title: "Read file",
            status: "pending"
        )

        let params = try #require(ACPPermissionBridge.parameters(
            sessionID: "session-1",
            state: state
        ).dictionaryValue)
        #expect(params["sessionId"] == .string("session-1"))
        #expect(params["toolCall"] == .dictionary([
            "toolCallId": .string("call-1"),
            "title": .string("Read file"),
            "status": .string("pending"),
        ]))
        #expect(params["options"] == .array([
            .dictionary([
                "optionId": .string("allow_once"),
                "name": .string("Allow once"),
                "kind": .string("allow_once"),
            ]),
            .dictionary([
                "optionId": .string("reject_once"),
                "name": .string("Reject once"),
                "kind": .string("reject_once"),
            ]),
        ]))

        #expect(ACPPermissionBridge.approved(from: .dictionary([
            "outcome": .dictionary([
                "outcome": .string("selected"),
                "optionId": .string("allow_once"),
            ]),
        ])) == true)
        #expect(ACPPermissionBridge.approved(from: .dictionary([
            "outcome": .dictionary(["outcome": .string("cancelled")]),
        ])) == false)
    }
}

private func ascendantEntry(id: UUID, providerID: String, nodeID: UUID?) -> NetworkCatalogEntry {
    var known: [String: NetworkDynamicValue] = [
        "privateTimelineID": .string(UUID().uuidString.lowercased()),
        "capabilities": .array([.string(GnosticCapability.textTurnInput)]),
    ]
    if let nodeID { known["nodeID"] = .string(nodeID.uuidString.lowercased()) }
    return NetworkCatalogEntry(
        objectID: id,
        objectType: GnosticObjectType.ascendant,
        protocolMajor: GnosticProtocol.currentMajor,
        providerID: providerID,
        name: "Ascendant",
        knownProperties: known,
        dynamicProperties: [:],
        workspace: nil
    )
}

private extension AnyCodable {
    var dictionaryValue: [String: AnyCodable]? {
        guard case let .dictionary(value) = self else { return nil }
        return value
    }
}

private final class OutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(bytes)
    }

    func requests() throws -> [JSONRPCRequest] {
        lock.lock(); defer { lock.unlock() }
        return try data.split(separator: 0x0A).map {
            try JSONDecoder().decode(JSONRPCRequest.self, from: Data($0))
        }
    }
}
