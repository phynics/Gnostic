// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKShared
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
        let session = BridgeSession(
            handler: { _ in .dictionary([:]) },
            output: output.append,
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
