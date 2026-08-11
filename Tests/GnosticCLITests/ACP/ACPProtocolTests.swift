// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
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

        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: url.deletingLastPathComponent().path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
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
