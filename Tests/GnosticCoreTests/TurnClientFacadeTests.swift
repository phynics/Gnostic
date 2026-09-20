// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

// Consumer-facing tests for the public turn client. This target does not depend
// on the CLI executable, so compiling and passing here proves that an external
// consumer can run a Turn, stream its updates, replay it, and answer a
// permission request over a consumer session without the CLI module.
//
// The "provider" below is a raw Axoloty host with scripted call handlers. It is
// not a Gnostic Node and it advertises nothing: the client addresses it by the
// provider identity directly, so no discovery or advertisement is involved.

@Suite("Public turn client", .timeLimit(.minutes(1)))
@MainActor
struct TurnClientFacadeTests {
    private let host = "127.0.0.1"
    private let port = 1883

    @Test("consumer runs, streams, replays, and answers permissions offline")
    func runsStreamsReplaysAndAnswersPermissions() async throws {
        let namespace = namespaced("turn")
        let timelineID = UUID()
        let clientTurnID = "turn-1"

        let scripted = [
            AscendantTurnUpdate(sequence: 1, kind: .assistantText, text: "Hel"),
            AscendantTurnUpdate(sequence: 2, kind: .assistantText, text: "lo"),
            AscendantTurnUpdate(sequence: 3, kind: .completion, text: "Hello", terminal: true),
        ]

        let provider = try makeProvider(namespace: namespace)
        try await provider.startAndWaitUntilReady()
        defer { provider.stop() }
        let providerID = provider.identity.objectId.string

        let captured = PermissionResponseRecorder()
        let permissionStream = try await provider.observeChannelStream(
            channelId: AscendantPermissionProvider.responseChannel
        )
        let permissionTask = Task {
            for await snapshot in permissionStream {
                guard let raw = snapshot.privateData,
                      let response = try? JSONDecoder().decode(
                          AscendantPermissionResponse.self,
                          from: Data(raw.utf8)
                      ) else { continue }
                await captured.record(response)
            }
        }
        defer { permissionTask.cancel() }

        let turnRegistration = try await provider.registerCallHandler(
            operation: AscendantTurnProvider.turnOperation
        ) { snapshot in
            guard let parameters = snapshot.parameters,
                  let request = try? JSONDecoder().decode(
                      AscendantTurnRequest.self,
                      from: Data(parameters.utf8)
                  ),
                  let requestTurnID = request.clientTurnID else {
                return .failure(code: 400, message: "Invalid test turn request")
            }
            for update in scripted {
                let event = AscendantTurnUpdateStore.Event(
                    timelineID: request.timelineID,
                    clientTurnID: requestTurnID,
                    update: update
                )
                if let channel = try? AscendantTurnProvider.updateEvent(event) {
                    await provider.publishChannel(channel)
                }
            }
            guard let result = try? GnosticWirePayload.encode(
                AscendantTurnResult(clientTurnID: requestTurnID, text: "Hello"),
                context: "test turn result"
            ) else {
                return .failure(code: 500, message: "Could not encode test turn result")
            }
            return .success(result: String(decoding: result, as: UTF8.self))
        }
        defer { turnRegistration.cancel() }

        let replayRegistration = try await provider.registerCallHandler(
            operation: AscendantTurnProvider.replayOperation
        ) { _ in
            guard let replay = try? GnosticWirePayload.encode(
                AscendantTurnReplay(updates: scripted, compacted: false, terminal: true),
                context: "test replay result"
            ) else {
                return .failure(code: 500, message: "Could not encode test replay result")
            }
            return .success(result: String(decoding: replay, as: UTF8.self))
        }
        defer { replayRegistration.cancel() }

        let session = try GnosticConsumerSession(
            broker: .init(host: host, port: port, namespace: namespace),
            connectTimeout: .seconds(3),
            discoverTimeout: .seconds(2)
        )
        defer { Task { @MainActor in await session.stop() } }
        try await session.start()

        let client = try session.turnClient(timeout: .seconds(2), promptTimeout: .seconds(2))

        let updates = try await client.updates(
            for: clientTurnID,
            timelineID: timelineID,
            providerID: providerID
        )

        let result = try await client.run(
            message: "hi",
            timelineID: timelineID,
            clientTurnID: clientTurnID,
            providerID: providerID
        )
        #expect(result.text == "Hello")
        #expect(result.clientTurnID == clientTurnID)

        var received: [AscendantTurnUpdate] = []
        for await update in updates {
            received.append(update)
            if update.terminal { break }
        }
        #expect(received.map(\.kind) == ["assistant_text", "assistant_text", "completion"])
        #expect(received.last?.text == "Hello")

        let replay = try await client.replay(
            timelineID: timelineID,
            clientTurnID: clientTurnID,
            message: "hi",
            providerID: providerID
        )
        #expect(replay.updates.count == 3)
        #expect(replay.terminal)

        try await client.respond(
            to: AscendantPermissionResponse(
                correlationID: "permission-1",
                timelineID: timelineID,
                clientTurnID: clientTurnID,
                approved: true
            ),
            providerID: providerID
        )

        let deadline = ContinuousClock().now + .seconds(3)
        while await captured.isEmpty, ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let response = try #require(await captured.first)
        #expect(response.correlationID == "permission-1")
        #expect(response.approved)
    }

    @Test("turn client requires a running session")
    func requiresRunningSession() async throws {
        let session = try GnosticConsumerSession(
            broker: .init(host: host, port: port, namespace: namespaced("not-started")),
            connectTimeout: .milliseconds(500)
        )
        defer { Task { @MainActor in await session.stop() } }

        do {
            _ = try session.turnClient()
            Issue.record("a turn client was created without a running session")
        } catch let error as GnosticConsumerSessionError {
            #expect(error == .notStarted)
        }
    }

    private func namespaced(_ label: String) -> String {
        "gnostic-turn-client-\(label)-\(UUID().uuidString.prefix(8))"
    }

    private func makeProvider(namespace: String) throws -> CommunicationManager {
        try CommunicationManager(
            identity: Identity(name: "gnostic-turn-provider"),
            communicationOptions: CommunicationOptions(
                namespace: namespace,
                shouldEnableCrossNamespacing: false,
                mqttClientOptions: MQTTClientOptions(
                    host: host,
                    port: UInt16(port),
                    shouldTryMDNSDiscovery: false,
                    autoReconnect: false
                ),
                shouldAutoStart: false
            ),
            commonOptions: nil
        )
    }
}

private actor PermissionResponseRecorder {
    private var responses: [AscendantPermissionResponse] = []

    func record(_ response: AscendantPermissionResponse) {
        responses.append(response)
    }

    var isEmpty: Bool { responses.isEmpty }

    var first: AscendantPermissionResponse? { responses.first }
}
