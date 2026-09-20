// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
@testable import GnosticCore
import Testing

// Consumer-facing tests for the public turn client. This target does not depend
// on the CLI executable, so compiling and passing here proves that an external
// consumer can run a Turn, stream its updates, replay it, and answer a real
// mediated permission request over a consumer session without the CLI module.
//
// The "provider" below is a raw Axoloty host that advertises a Timeline and its
// Ascendant and registers scripted call handlers. It is not a Gnostic Node; the
// serve-side permission path is the production
// ``AscendantPermissionCoordinator`` plus ``AscendantPermissionProvider``. The
// consumer never advertises.

@Suite("Public turn client", .timeLimit(.minutes(1)))
@MainActor
struct TurnClientFacadeTests {
    private let host = "127.0.0.1"
    private let port = 1883

    @Test("consumer runs, streams, replays, and answers a mediated permission")
    func runsStreamsReplaysAndAnswersPermissions() async throws {
        let namespace = namespaced("turn")
        let provider = try await startProvider(namespace: namespace)
        defer { provider.manager.stop() }
        let providerID = provider.providerID
        let timelineID = provider.timelineID
        let clientTurnID = "turn-1"

        let store = AscendantTurnUpdateStore()
        let coordinator = AscendantPermissionCoordinator(updates: store)
        let permissionProvider = AscendantPermissionProvider(coordinator: coordinator)
        let responseObserver = try await permissionProvider.observeResponses(
            on: provider.manager,
            providerID: providerID
        )
        defer { responseObserver.cancel() }

        let updateBridge = Task {
            let events = await store.events()
            for await event in events {
                if let channel = try? AscendantTurnProvider.updateEvent(event) {
                    provider.manager.publishChannel(channel)
                }
            }
        }
        defer { updateBridge.cancel() }

        let scripted = [
            AscendantTurnUpdate(sequence: 1, kind: .assistantText, text: "Hel"),
            AscendantTurnUpdate(sequence: 2, kind: .assistantText, text: "lo"),
        ]

        let turnRegistration = try await provider.manager.registerCallHandler(
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
                _ = try? await store.append(
                    timelineID: request.timelineID,
                    clientTurnID: requestTurnID,
                    kind: update.kind,
                    text: update.text,
                    terminal: update.terminal
                )
            }
            let decision = await coordinator.requestApproval(for: BackendPermissionRequest(
                timelineID: request.timelineID,
                clientTurnID: requestTurnID,
                toolCallID: "tool-1",
                title: "Run the tool"
            ))
            guard decision.isApproved else {
                return .failure(
                    code: 403,
                    message: GnosticProtocol.failureMessage(
                        reasonCode: "permissionDenied",
                        message: "The permission request was denied.",
                        statusCode: 403
                    )
                )
            }
            _ = try? await store.append(
                timelineID: request.timelineID,
                clientTurnID: requestTurnID,
                kind: AscendantTurnUpdateKind.completion.rawValue,
                text: "Hello",
                terminal: true
            )
            try? await store.finish(timelineID: request.timelineID, clientTurnID: requestTurnID)
            guard let result = try? GnosticWirePayload.encode(
                AscendantTurnResult(clientTurnID: requestTurnID, text: "Hello"),
                context: "test turn result"
            ) else {
                return .failure(code: 500, message: "Could not encode test turn result")
            }
            return .success(result: String(decoding: result, as: UTF8.self))
        }
        defer { turnRegistration.cancel() }

        let replayRegistration = try await provider.manager.registerCallHandler(
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

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.turnClient(timeout: .seconds(1), promptTimeout: .seconds(3))
            let updates = try await client.updates(
                for: clientTurnID,
                timelineID: timelineID,
                providerID: providerID
            )
            let runTask = Task {
                try await client.run(
                    message: "hi",
                    timelineID: timelineID,
                    clientTurnID: clientTurnID,
                    providerID: providerID
                )
            }

            var observedPermission: AscendantPermissionState?
            var receivedKinds: [String] = []
            for await update in updates {
                receivedKinds.append(update.kind)
                if let permission = update.permissionState, permission.permissionStatus == .pending {
                    observedPermission = permission
                    try client.respond(
                        to: AscendantPermissionResponse(
                            correlationID: permission.correlationID,
                            timelineID: timelineID,
                            clientTurnID: clientTurnID,
                            approved: true
                        ),
                        providerID: providerID
                    )
                }
            }

            let result = try await runTask.value
            #expect(result.text == "Hello")
            #expect(receivedKinds.first == AscendantTurnUpdateKind.assistantText.rawValue)
            #expect(receivedKinds.contains(AscendantTurnUpdateKind.permissionState.rawValue))
            #expect(receivedKinds.last == AscendantTurnUpdateKind.completion.rawValue)
            #expect(observedPermission?.title == "Run the tool")
            #expect(observedPermission?.permissionStatus == .pending)

            let replay = try await client.replay(
                timelineID: timelineID,
                clientTurnID: clientTurnID,
                message: "hi",
                providerID: providerID
            )
            #expect(replay.updates.count == scripted.count)
            #expect(replay.terminal)
        }
    }

    @Test("resolves the provider from discovery when none is supplied")
    func resolvesProviderFromDiscovery() async throws {
        let namespace = namespaced("discovery")
        let provider = try await startProvider(namespace: namespace)
        defer { provider.manager.stop() }

        let registration = try await provider.manager.registerCallHandler(
            operation: AscendantTurnProvider.turnOperation
        ) { snapshot in
            guard let parameters = snapshot.parameters,
                  let request = try? JSONDecoder().decode(
                      AscendantTurnRequest.self,
                      from: Data(parameters.utf8)
                  ),
                  let result = try? GnosticWirePayload.encode(
                      AscendantTurnResult(clientTurnID: request.clientTurnID, text: "discovered"),
                      context: "test turn result"
                  ) else {
                return .failure(code: 400, message: "Invalid test turn request")
            }
            return .success(result: String(decoding: result, as: UTF8.self))
        }
        defer { registration.cancel() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            let client = try session.turnClient(timeout: .seconds(2), promptTimeout: .seconds(3))
            let result = try await client.run(
                message: "hi",
                timelineID: provider.timelineID,
                clientTurnID: "discovery-1",
                providerID: nil
            )
            #expect(result.text == "discovered")
        }
    }

    @Test("maps a serve protocol failure to a structured error")
    func mapsServeFailureToStructuredError() async throws {
        let namespace = namespaced("conflict")
        let provider = try await startProvider(namespace: namespace)
        defer { provider.manager.stop() }

        let registration = try await provider.manager.registerCallHandler(
            operation: AscendantTurnProvider.turnOperation
        ) { _ in
            .failure(
                code: 409,
                message: GnosticProtocol.failureMessage(
                    reasonCode: "turnConflict",
                    message: "clientTurnID was already used with different content",
                    statusCode: 409
                )
            )
        }
        defer { registration.cancel() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.turnClient(timeout: .seconds(1), promptTimeout: .seconds(2))
            do {
                _ = try await client.run(
                    message: "hi",
                    timelineID: provider.timelineID,
                    clientTurnID: "conflict-1",
                    providerID: provider.providerID
                )
                Issue.record("a converged Turn conflict did not throw")
            } catch let error as GnosticTurnClientError {
                #expect(error == .callFailed(reasonCode: "turnConflict", statusCode: 409, retryable: false))
                #expect(error.reasonCode == "turnConflict")
            }
        }
    }

    @Test("rejects an unadvertised timeline")
    func rejectsUnadvertisedTimeline() async throws {
        let namespace = namespaced("missing")
        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            let client = try session.turnClient(timeout: .milliseconds(300), promptTimeout: .seconds(1))
            let timelineID = UUID()
            do {
                _ = try await client.run(message: "hi", timelineID: timelineID, clientTurnID: "missing-1")
                Issue.record("an unadvertised Timeline was accepted")
            } catch let error as GnosticTurnClientError {
                #expect(error == .timelineUnavailable(timelineID))
            }
        }
    }

    @Test("rejects an explicit provider that does not own the timeline")
    func rejectsProviderMismatch() async throws {
        let namespace = namespaced("mismatch")
        let provider = try await startProvider(namespace: namespace)
        defer { provider.manager.stop() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.turnClient(timeout: .seconds(1), promptTimeout: .seconds(1))
            do {
                _ = try await client.run(
                    message: "hi",
                    timelineID: provider.timelineID,
                    clientTurnID: "mismatch-1",
                    providerID: UUID().uuidString
                )
                Issue.record("a provider that does not own the Timeline was accepted")
            } catch let error as GnosticTurnClientError {
                #expect(error == .providerMismatch)
            }
        }
    }

    @Test("rejects a timeline advertised by two providers")
    func rejectsAmbiguousTimeline() async throws {
        let namespace = namespaced("ambiguous")
        let timelineID = UUID()
        let ascendantID = UUID()
        let first = try await startProvider(
            namespace: namespace,
            name: "gnostic-turn-provider-a",
            ascendantID: ascendantID,
            timelineID: timelineID
        )
        defer { first.manager.stop() }
        let second = try await startProvider(
            namespace: namespace,
            name: "gnostic-turn-provider-b",
            ascendantID: ascendantID,
            timelineID: timelineID
        )
        defer { second.manager.stop() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.turnClient(timeout: .seconds(1), promptTimeout: .seconds(1))
            do {
                _ = try await client.run(
                    message: "hi",
                    timelineID: timelineID,
                    clientTurnID: "ambiguous-1",
                    providerID: first.providerID
                )
                Issue.record("an ambiguous Timeline was accepted")
            } catch let error as GnosticTurnClientError {
                #expect(error == .timelineAmbiguous(timelineID))
            }
        }
    }

    @Test("rejects an ascendant without the text-turn capability")
    func rejectsMissingCapability() async throws {
        let namespace = namespaced("capability")
        let provider = try await startProvider(namespace: namespace, capabilities: [])
        defer { provider.manager.stop() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.turnClient(timeout: .seconds(1), promptTimeout: .seconds(1))
            do {
                _ = try await client.run(
                    message: "hi",
                    timelineID: provider.timelineID,
                    clientTurnID: "capability-1",
                    providerID: provider.providerID
                )
                Issue.record("an Ascendant without textTurnInput was accepted")
            } catch let error as GnosticTurnClientError {
                #expect(error == .missingCapability(GnosticCapability.textTurnInput))
            }
        }
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

    @Test("reason codes are stable")
    func reasonCodesAreStable() {
        let id = UUID()
        #expect(GnosticTurnClientError.timelineUnavailable(id).reasonCode == "timelineUnavailable")
        #expect(GnosticTurnClientError.timelineAmbiguous(id).reasonCode == "timelineAmbiguous")
        #expect(GnosticTurnClientError.providerMismatch.reasonCode == "providerMismatch")
        #expect(GnosticTurnClientError.missingCapability("capability").reasonCode == "missingCapability")
        #expect(GnosticTurnClientError
            .callFailed(reasonCode: "turnConflict", statusCode: 409, retryable: true)
            .reasonCode == "turnConflict")
    }

    private struct AdvertisedProvider {
        let manager: CommunicationManager
        let providerID: String
        let ascendantID: UUID
        let timelineID: UUID
    }

    private func namespaced(_ label: String) -> String {
        "gnostic-turn-client-\(label)-\(UUID().uuidString.prefix(8))"
    }

    private func makeProvider(namespace: String, name: String) throws -> CommunicationManager {
        try CommunicationManager(
            identity: Identity(name: name),
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

    private func startProvider(
        namespace: String,
        name: String = "gnostic-turn-provider",
        ascendantID: UUID = UUID(),
        timelineID: UUID = UUID(),
        capabilities: [String] = [GnosticCapability.textTurnInput]
    ) async throws -> AdvertisedProvider {
        let manager = try makeProvider(namespace: namespace, name: name)
        try await manager.startAndWaitUntilReady()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        manager.publishAdvertise(GnosticAscendantObject(identity: AscendantBackendIdentity(
            id: ascendantID,
            name: "Turn Ascendant",
            description: "Offline turn provider.",
            privateTimelineID: timelineID,
            primaryWorkspaceID: nil,
            lastActiveAt: now,
            createdAt: now,
            updatedAt: now,
            capabilities: AscendantBackendCapabilities(interoperability: Set(capabilities))
        )))
        manager.publishAdvertise(GnosticTimelineObject(timeline: AscendantBackendTimeline(
            id: timelineID,
            title: "Turn Timeline",
            attachedWorkspaceIDs: [],
            attachedAscendantID: ascendantID,
            isArchived: false,
            isPrivate: false,
            createdAt: now,
            updatedAt: now
        )))
        try await Task.sleep(for: .milliseconds(50))
        return AdvertisedProvider(
            manager: manager,
            providerID: manager.identity.objectId.string,
            ascendantID: ascendantID,
            timelineID: timelineID
        )
    }

    private func withSession(
        broker: GnosticBrokerSettings,
        connectTimeout: Duration = .seconds(3),
        discoverTimeout: Duration = .seconds(1),
        _ body: (GnosticConsumerSession) async throws -> Void
    ) async throws {
        let session = try GnosticConsumerSession(
            broker: broker,
            connectTimeout: connectTimeout,
            discoverTimeout: discoverTimeout
        )
        do {
            try await session.start()
            try await body(session)
        } catch {
            await session.stop()
            throw error
        }
        await session.stop()
    }
}
