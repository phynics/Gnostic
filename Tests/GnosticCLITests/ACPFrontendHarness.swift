// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticACPAscendant
@testable import GnosticACPFrontend
@_spi(RuntimeHost) import GnosticCore
import GnosticProtocol
import Testing

/// A `gnostic acp` session over a real Node and the deterministic ACP fixture.
///
/// The harness drives the same `ACPDispatcher` and `JSONRPCSession` the
/// `gnostic acp` command uses, and it captures every frame and notification the
/// client would see.
@MainActor
final class ACPFrontendHarness {
    let scratch: URL
    let wire: ACPWireCapture
    let sessionID: String
    private let runtime: NodeRuntime
    private let client: RemoteTurnClient
    private let session: JSONRPCSession
    private let registry: ACPSessionRegistry
    private let namespace: String
    private let runtimeID: UUID
    private var nextRequestID = 100
    private var secondConnections: [SecondConnection] = []

    /// Starts a Node with one fixture-backed Timeline and opens an ACP session on it.
    ///
    /// - Parameter environment: Extra environment for the fixture Runtime process.
    /// - Returns: `nil`, after recording an issue, when no session could be opened.
    static func start(environment extra: [String: String] = [:]) async throws -> ACPFrontendHarness? {
        let fixture = try #require(ProcessInfo.processInfo.environment["GNOSTIC_ACP_AGENT_FIXTURE"])
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("gnostic-acp-frontend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let runtimeID = UUID()
        let namespace = "acp-frontend-\(UUID().uuidString.lowercased())"
        var environment = ["GNOSTIC_ACP_FIXTURE_STATE": scratch.appendingPathComponent("agent-sessions.json").path]
        environment.merge(extra) { _, new in new }
        let configuration = AscendantBackendConfiguration(
            kind: ACPAscendantBackend.kind,
            settings: [
                "command": .string("node"),
                "args": .string(String(decoding: try JSONEncoder().encode([fixture]), as: UTF8.self)),
                "env": .string(String(decoding: try JSONEncoder().encode(environment), as: UTF8.self)),
            ]
        )
        let configuredTimelineID = UUID()
        let manifest = NodeManifest(
            broker: .init(host: "127.0.0.1", port: 1883, namespace: namespace),
            node: .init(id: UUID()),
            ascendants: [.init(
                id: runtimeID, name: "Frontend fixture", defaultTimelineID: configuredTimelineID, backend: configuration
            )],
            timelines: [.init(
                id: configuredTimelineID, title: "Configured", operatingAscendantID: runtimeID,
                project: .local(scratch.path)
            )]
        )
        var adapters = NodeRuntimeAdapters.default
        adapters.ascendants.registerBackend(
            kind: ACPAscendantBackend.kind,
            settings: ACPAscendantBackend.settingsSchema
        ) { ascendant, backendConfiguration, services, timelines in
            try ACPAscendantBackend(
                ascendant: ascendant,
                configuration: backendConfiguration,
                services: services,
                timelines: timelines
            )
        }
        let runtime = try await NodeRuntime(
            plan: manifest.compileLaunchPlan(),
            adapters: adapters,
            timelineJournalDirectory: scratch.appendingPathComponent("timeline-journals")
        )
        try await runtime.start()
        let client = try RemoteTurnClient(host: "127.0.0.1", port: 1883, namespace: namespace)
        try await client.connect()
        let registry = ACPSessionRegistry(url: scratch.appendingPathComponent("acp-sessions.json"))
        let wire = ACPWireCapture()
        let dispatcher = ACPDispatcher(
            client: client,
            registry: registry,
            requestedRuntimeID: runtimeID,
            publish: { method, params in wire.record(notification: method, params: params) },
            requestPermission: { _ in throw CancellationError() }
        )
        let session = JSONRPCSession(
            handler: { request in try await dispatcher.handle(request) },
            output: { data in wire.record(frame: data) },
            initialize: { try await dispatcher.initialize() }
        )
        func send(_ id: Int, _ method: String, _ params: String) async {
            await session.receive(Data(
                #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#.utf8 + [0x0A]
            ))
        }
        await send(1, "initialize", #"{"protocolVersion":2}"#)
        await send(2, "session/new", #"{"cwd":"\#(scratch.path)","mcpServers":[]}"#)
        guard let created = await wire.response(id: 2, timeout: .seconds(20)),
              case let .dictionary(result)? = created.result,
              case let .string(sessionID)? = result["sessionId"] else {
            Issue.record("session/new did not return a session: \(String(describing: await wire.response(id: 2, timeout: .zero)))")
            await session.finish()
            await client.stop()
            await runtime.shutdown()
            try? FileManager.default.removeItem(at: scratch)
            return nil
        }
        return ACPFrontendHarness(
            scratch: scratch, wire: wire, sessionID: sessionID, runtime: runtime, client: client, session: session,
            registry: registry, namespace: namespace, runtimeID: runtimeID
        )
    }

    private init(
        scratch: URL, wire: ACPWireCapture, sessionID: String,
        runtime: NodeRuntime, client: RemoteTurnClient, session: JSONRPCSession,
        registry: ACPSessionRegistry, namespace: String, runtimeID: UUID
    ) {
        self.scratch = scratch
        self.wire = wire
        self.sessionID = sessionID
        self.runtime = runtime
        self.client = client
        self.session = session
        self.registry = registry
        self.namespace = namespace
        self.runtimeID = runtimeID
    }

    /// A second `gnostic acp` connection to the same Node that resolves this
    /// harness's session to the same Timeline. Its dispatcher holds no prompt
    /// reservation for the session, so a prompt on it reaches the Node's
    /// coordinator instead of the dispatcher's per-session guard.
    @MainActor
    final class SecondConnection {
        let wire: ACPWireCapture
        fileprivate let client: RemoteTurnClient
        fileprivate let session: JSONRPCSession
        private let sessionID: String
        private var nextRequestID = 500

        fileprivate init(wire: ACPWireCapture, client: RemoteTurnClient, session: JSONRPCSession, sessionID: String) {
            self.wire = wire
            self.client = client
            self.session = session
            self.sessionID = sessionID
        }

        /// Sends `session/prompt` for `text` and returns the ID its response will carry.
        @discardableResult
        func prompt(_ text: String) async -> Int {
            nextRequestID += 1
            let id = nextRequestID
            await session.receive(Data(
                #"{"jsonrpc":"2.0","id":\#(id),"method":"session/prompt","params":{"sessionId":"\#(sessionID)","prompt":[{"type":"text","text":"\#(text)"}]}}"#.utf8 + [0x0A]
            ))
            return id
        }
    }

    func openSecondConnection() async throws -> SecondConnection {
        let secondClient = try RemoteTurnClient(host: "127.0.0.1", port: 1883, namespace: namespace)
        try await secondClient.connect()
        let secondWire = ACPWireCapture()
        let dispatcher = ACPDispatcher(
            client: secondClient,
            registry: registry,
            requestedRuntimeID: runtimeID,
            publish: { method, params in secondWire.record(notification: method, params: params) },
            requestPermission: { _ in throw CancellationError() }
        )
        let secondSession = JSONRPCSession(
            handler: { request in try await dispatcher.handle(request) },
            output: { data in secondWire.record(frame: data) },
            initialize: { try await dispatcher.initialize() }
        )
        await secondSession.receive(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":2}}"#.utf8 + [0x0A]))
        let connection = SecondConnection(wire: secondWire, client: secondClient, session: secondSession, sessionID: sessionID)
        secondConnections.append(connection)
        return connection
    }

    /// Sends a request and returns the ID its response will carry.
    @discardableResult
    func send(_ method: String, _ params: String) async -> Int {
        nextRequestID += 1
        let id = nextRequestID
        await session.receive(Data(
            #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#.utf8 + [0x0A]
        ))
        return id
    }

    /// Sends `session/prompt` for `text`, optionally under a client Turn ID.
    @discardableResult
    func prompt(_ text: String, clientTurnID: String? = nil) async -> Int {
        let meta = clientTurnID.map { #","_meta":{"\#(ACPProtocol.turnIDMetadataKey)":"\#($0)"}"# } ?? ""
        return await send(
            "session/prompt",
            #"{"sessionId":"\#(sessionID)","prompt":[{"type":"text","text":"\#(text)"}]\#(meta)}"#
        )
    }

    func tearDown() async {
        for connection in secondConnections {
            await connection.session.finish()
            await connection.client.stop()
        }
        await session.finish()
        await client.stop()
        await runtime.shutdown()
        try? FileManager.default.removeItem(at: scratch)
    }
}

/// Collects the JSON-RPC frames and notifications a `gnostic acp` session emits.
final class ACPWireCapture: @unchecked Sendable { // SAFETY: `lock` guards every stored property.
    private let lock = NSLock()
    private var responses: [JSONRPCIdentifier: JSONRPCResponse] = [:]
    private var notifications: [String] = []
    private var boundary = 0

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func record(frame data: Data) {
        for line in data.split(separator: 0x0A) {
            if let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: Data(line)), let id = response.id {
                locked { responses[id] = response }
            } else {
                let text = String(decoding: line, as: UTF8.self)
                locked { notifications.append(text) }
            }
        }
    }

    func record(notification method: String, params: GnosticJSONValue) {
        let encoded = (try? JSONEncoder().encode(params)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        locked { notifications.append("\(method) \(encoded)") }
    }

    func markBoundary() async {
        // Let in-flight publication of the first prompt settle before marking.
        try? await Task.sleep(for: .milliseconds(300))
        locked { boundary = notifications.count }
    }

    func notificationsAfterBoundary() async -> [String] {
        try? await Task.sleep(for: .milliseconds(300))
        return locked { Array(notifications.dropFirst(boundary)) }
    }

    func response(id: Int, timeout: Duration) async -> JSONRPCResponse? {
        let key = JSONRPCIdentifier.number(Int64(id))
        let deadline = ContinuousClock.now + timeout
        repeat {
            if let found = locked({ responses[key] }) { return found }
            try? await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        return nil
    }
}
