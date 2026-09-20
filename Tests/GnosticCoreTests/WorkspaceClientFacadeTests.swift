// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

// Consumer-facing tests for the public workspace client. This file must
// compile against the public `GnosticCore` API alone: it deliberately avoids
// testable imports, so passing here proves that an external consumer can
// discover a Workspace, attach it to a Timeline through the approved path,
// invoke its tools over `me.atkn.gnostic.workspace.invoke`, observe effective
// status, and detach.
//
// The serve-side fixture lives in `WorkspaceClientFacadeBridge.swift`, which
// uses the production wire providers. The consumer below never advertises.

@Suite("Public workspace client", .timeLimit(.minutes(1)))
@MainActor
struct WorkspaceClientFacadeTests {
    private let host = "127.0.0.1"
    private let port = 1883

    @Test("consumer discovers, attaches, invokes, observes status, and detaches")
    func discoversAttachesInvokesAndDetaches() async throws {
        let namespace = namespaced("workspace")
        let fixture = try await WorkspaceClientFacadeBridge.makeFixture(
            namespace: namespace,
            host: host,
            port: port
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.workspaceClient(timeout: .seconds(2))

            let discovered = await client.attachmentStatus(workspaceID: fixture.workspaceID)
            #expect(discovered == .available(providerID: fixture.providerID, uri: fixture.workspaceURI))
            #expect(await client.effectiveStatus(workspaceID: fixture.workspaceID) == .available)
            #expect(await session.workspaceAttachmentStatus(id: fixture.workspaceID) == discovered)

            try await client.attach(
                workspaceID: fixture.workspaceID,
                to: fixture.timelineID,
                approved: true
            )
            let attached = await fixture.recorder.attachRequests
            #expect(attached.count == 1)
            #expect(attached.first?.workspaceID == fixture.workspaceID)
            #expect(attached.first?.timelineID == fixture.timelineID)

            let result = try await client.invoke(
                workspaceID: fixture.workspaceID,
                toolID: "workspace_echo",
                arguments: ["value": .string("hello")]
            )
            #expect(result.isSuccess)
            #expect(result.output == "hello")

            try await client.detach(workspaceID: fixture.workspaceID, from: fixture.timelineID)
            let detached = await fixture.recorder.detachRequests
            #expect(detached.count == 1)
            #expect(detached.first?.workspaceID == fixture.workspaceID)
            #expect(detached.first?.timelineID == fixture.timelineID)
        }
    }

    @Test("invoke surfaces a failed tool result without a transport error")
    func invokeSurfacesFailedToolResult() async throws {
        let namespace = namespaced("tool-failure")
        let fixture = try await WorkspaceClientFacadeBridge.makeFixture(
            namespace: namespace,
            host: host,
            port: port,
            options: .init(invoke: .toolFailure)
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.workspaceClient(timeout: .seconds(2))

            let result = try await client.invoke(workspaceID: fixture.workspaceID, toolID: "workspace_echo")
            #expect(!result.isSuccess)
            #expect(result.error == "boom")
        }
    }

    @Test("unapproved attach is refused before any wire call")
    func unapprovedAttachIsRefused() async throws {
        let namespace = namespaced("approval")
        let fixture = try await WorkspaceClientFacadeBridge.makeFixture(
            namespace: namespace,
            host: host,
            port: port
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.workspaceClient(timeout: .seconds(2))

            do {
                try await client.attach(
                    workspaceID: fixture.workspaceID,
                    to: fixture.timelineID,
                    approved: false
                )
                Issue.record("an unapproved attach was accepted")
            } catch let error as GnosticWorkspaceClientError {
                #expect(error == .approvalRequired)
                #expect(error.reasonCode == "approvalRequired")
            }
            #expect(await fixture.recorder.attachRequests.isEmpty)
        }
    }

    @Test("a rejected attach maps to a structured call failure")
    func rejectedAttachMapsToCallFailure() async throws {
        let namespace = namespaced("attach-rejected")
        let fixture = try await WorkspaceClientFacadeBridge.makeFixture(
            namespace: namespace,
            host: host,
            port: port,
            options: .init(attach: .reject)
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.workspaceClient(timeout: .seconds(2))

            await #expect(throws: GnosticWorkspaceClientError
                .callFailed(reasonCode: "workspaceAttachRejected", statusCode: 409, retryable: false)) {
                try await client.attach(workspaceID: fixture.workspaceID, to: fixture.timelineID, approved: true)
            }
        }
    }

    @Test("a rejected detach maps to a structured call failure")
    func rejectedDetachMapsToCallFailure() async throws {
        let namespace = namespaced("detach-rejected")
        let fixture = try await WorkspaceClientFacadeBridge.makeFixture(
            namespace: namespace,
            host: host,
            port: port,
            options: .init(detach: .reject)
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.workspaceClient(timeout: .seconds(2))

            await #expect(throws: GnosticWorkspaceClientError
                .callFailed(reasonCode: "workspaceDetachRejected", statusCode: 409, retryable: false)) {
                try await client.detach(workspaceID: fixture.workspaceID, from: fixture.timelineID)
            }
        }
    }

    @Test("a serve protocol failure maps to a structured call failure")
    func serveProtocolFailureMapsToCallFailure() async throws {
        let namespace = namespaced("attach-protocol-failure")
        let fixture = try await WorkspaceClientFacadeBridge.makeFixture(
            namespace: namespace,
            host: host,
            port: port,
            options: .init(attach: .protocolFailure)
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.workspaceClient(timeout: .seconds(2))

            await #expect(throws: GnosticWorkspaceClientError
                .callFailed(reasonCode: "workspaceAttachConflict", statusCode: 409, retryable: false)) {
                try await client.attach(workspaceID: fixture.workspaceID, to: fixture.timelineID, approved: true)
            }
        }
    }

    @Test("a failed invocation maps to a structured call failure")
    func failedInvocationMapsToCallFailure() async throws {
        let namespace = namespaced("invoke-protocol-failure")
        let fixture = try await WorkspaceClientFacadeBridge.makeFixture(
            namespace: namespace,
            host: host,
            port: port,
            options: .init(invoke: .protocolFailure)
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.workspaceClient(timeout: .seconds(2))

            await #expect(throws: GnosticWorkspaceClientError
                .callFailed(reasonCode: "workspaceInvocationFailed", statusCode: 500, retryable: false)) {
                _ = try await client.invoke(workspaceID: fixture.workspaceID, toolID: "workspace_echo")
            }
        }
    }

    @Test("a malformed invocation result maps to an invalid-response failure")
    func malformedInvocationResultIsRejected() async throws {
        let namespace = namespaced("invoke-malformed")
        let fixture = try await WorkspaceClientFacadeBridge.makeFixture(
            namespace: namespace,
            host: host,
            port: port,
            options: .init(invoke: .malformedResult)
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.workspaceClient(timeout: .seconds(2))

            await #expect(throws: GnosticWorkspaceClientError
                .callFailed(reasonCode: "invalidResponse", statusCode: 502, retryable: false)) {
                _ = try await client.invoke(workspaceID: fixture.workspaceID, toolID: "workspace_echo")
            }
        }
    }

    @Test("a missing responder maps to a retryable timeout failure")
    func missingResponderMapsToTimeout() async throws {
        let namespace = namespaced("invoke-timeout")
        let fixture = try await WorkspaceClientFacadeBridge.makeFixture(
            namespace: namespace,
            host: host,
            port: port,
            options: .init(invoke: .timeout)
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.workspaceClient(timeout: .milliseconds(300))

            await #expect(throws: GnosticWorkspaceClientError
                .callFailed(reasonCode: "callTimedOut", statusCode: 504, retryable: true)) {
                _ = try await client.invoke(workspaceID: fixture.workspaceID, toolID: "workspace_echo")
            }
        }
    }

    @Test("an explicit provider that does not own the timeline is rejected")
    func explicitProviderMismatchIsRejected() async throws {
        let namespace = namespaced("provider-mismatch")
        let fixture = try await WorkspaceClientFacadeBridge.makeFixture(
            namespace: namespace,
            host: host,
            port: port
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.workspaceClient(timeout: .seconds(2))

            await #expect(throws: GnosticWorkspaceClientError.providerMismatch) {
                try await client.attach(
                    workspaceID: fixture.workspaceID,
                    to: fixture.timelineID,
                    approved: true,
                    providerID: UUID().uuidString
                )
            }
        }
    }

    @Test("a response from a different provider is rejected")
    func forgedResponseProviderIsRejected() async throws {
        let namespace = namespaced("forged-provider")
        let fixture = try await WorkspaceClientFacadeBridge.makeForgedAttachFixture(
            namespace: namespace,
            host: host,
            port: port
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.workspaceClient(timeout: .seconds(2))

            await #expect(throws: GnosticWorkspaceClientError.providerMismatch) {
                try await client.attach(workspaceID: fixture.workspaceID, to: fixture.timelineID, approved: true)
            }
        }
    }

    @Test("a workspace advertised by two providers is ambiguous")
    func ambiguousWorkspaceIsRejected() async throws {
        let namespace = namespaced("ambiguous-workspace")
        let fixture = try await WorkspaceClientFacadeBridge.makeAmbiguousWorkspaceFixture(
            namespace: namespace,
            host: host,
            port: port
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.workspaceClient(timeout: .seconds(2))

            #expect(await client.attachmentStatus(workspaceID: fixture.workspaceID) == .ambiguous)
            #expect(await client.effectiveStatus(workspaceID: fixture.workspaceID) == .unsupported)

            await #expect(throws: GnosticWorkspaceClientError.workspaceAmbiguous(fixture.workspaceID)) {
                try await client.attach(workspaceID: fixture.workspaceID, to: fixture.timelineID, approved: true)
            }
            await #expect(throws: GnosticWorkspaceClientError.workspaceAmbiguous(fixture.workspaceID)) {
                _ = try await client.invoke(workspaceID: fixture.workspaceID, toolID: "workspace_echo")
            }
        }
    }

    @Test("a timeline advertised by two providers is ambiguous")
    func ambiguousTimelineIsRejected() async throws {
        let namespace = namespaced("ambiguous-timeline")
        let fixture = try await WorkspaceClientFacadeBridge.makeAmbiguousTimelineFixture(
            namespace: namespace,
            host: host,
            port: port
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.workspaceClient(timeout: .seconds(2))

            await #expect(throws: GnosticWorkspaceClientError.timelineAmbiguous(fixture.timelineID)) {
                try await client.attach(workspaceID: fixture.workspaceID, to: fixture.timelineID, approved: true)
            }
            await #expect(throws: GnosticWorkspaceClientError.timelineAmbiguous(fixture.timelineID)) {
                try await client.detach(workspaceID: fixture.workspaceID, from: fixture.timelineID)
            }
        }
    }

    @Test("attach requires the workspace-attachment capability")
    func attachRequiresAttachmentCapability() async throws {
        let namespace = namespaced("attach-capability")
        let fixture = try await WorkspaceClientFacadeBridge.makeFixture(
            namespace: namespace,
            host: host,
            port: port,
            options: .init(capabilities: [GnosticCapability.workspaceToolInvocation])
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.workspaceClient(timeout: .seconds(2))

            await #expect(throws: GnosticWorkspaceClientError
                .missingCapability(GnosticCapability.workspaceAttachment)) {
                try await client.attach(workspaceID: fixture.workspaceID, to: fixture.timelineID, approved: true)
            }
        }
    }

    @Test("invoke requires the workspace-tool-invocation capability")
    func invokeRequiresInvocationCapability() async throws {
        let namespace = namespaced("invoke-capability")
        let fixture = try await WorkspaceClientFacadeBridge.makeFixture(
            namespace: namespace,
            host: host,
            port: port,
            options: .init(capabilities: [GnosticCapability.workspaceAttachment])
        )
        defer { fixture.teardown() }

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            try await session.discover()
            let client = try session.workspaceClient(timeout: .seconds(2))

            await #expect(throws: GnosticWorkspaceClientError
                .missingCapability(GnosticCapability.workspaceToolInvocation)) {
                _ = try await client.invoke(workspaceID: fixture.workspaceID, toolID: "workspace_echo")
            }
        }
    }

    @Test("an undiscovered workspace is not attachable or invocable")
    func undiscoveredWorkspaceIsRejected() async throws {
        let namespace = namespaced("missing")
        let unknown = UUID()

        try await withSession(broker: .init(host: host, port: port, namespace: namespace)) { session in
            let client = try session.workspaceClient(timeout: .milliseconds(300))
            #expect(await client.effectiveStatus(workspaceID: unknown) == .unavailable)

            do {
                try await client.attach(workspaceID: unknown, to: UUID(), approved: true)
                Issue.record("an undiscovered workspace was attached")
            } catch let error as GnosticWorkspaceClientError {
                #expect(error == .workspaceUnavailable(unknown))
            }

            do {
                _ = try await client.invoke(workspaceID: unknown, toolID: "workspace_echo")
                Issue.record("an undiscovered workspace was invoked")
            } catch let error as GnosticWorkspaceClientError {
                #expect(error == .workspaceUnavailable(unknown))
            }
        }
    }

    @Test("workspace client requires a running session")
    func requiresRunningSession() async throws {
        let session = try GnosticConsumerSession(
            broker: .init(host: host, port: port, namespace: namespaced("not-started")),
            connectTimeout: .milliseconds(500)
        )
        defer { Task { @MainActor in await session.stop() } }

        do {
            _ = try session.workspaceClient()
            Issue.record("a workspace client was created without a running session")
        } catch let error as GnosticConsumerSessionError {
            #expect(error == .notStarted)
        }
    }

    @Test("reason codes are stable")
    func reasonCodesAreStable() {
        let id = UUID()
        #expect(GnosticWorkspaceClientError.approvalRequired.reasonCode == "approvalRequired")
        #expect(GnosticWorkspaceClientError.workspaceUnavailable(id).reasonCode == "workspaceUnavailable")
        #expect(GnosticWorkspaceClientError.workspaceAmbiguous(id).reasonCode == "workspaceAmbiguous")
        #expect(GnosticWorkspaceClientError.workspaceUnsupported(id).reasonCode == "workspaceUnsupported")
        #expect(GnosticWorkspaceClientError.timelineUnavailable(id).reasonCode == "timelineUnavailable")
        #expect(GnosticWorkspaceClientError.timelineAmbiguous(id).reasonCode == "timelineAmbiguous")
        #expect(GnosticWorkspaceClientError.providerMismatch.reasonCode == "providerMismatch")
        #expect(GnosticWorkspaceClientError.missingCapability("capability").reasonCode == "missingCapability")
        #expect(GnosticWorkspaceClientError
            .callFailed(reasonCode: "workspaceAttachRejected", statusCode: 409, retryable: false)
            .reasonCode == "workspaceAttachRejected")
    }

    private func namespaced(_ label: String) -> String {
        "gnostic-workspace-client-\(label)-\(UUID().uuidString.prefix(8))"
    }

    private func withSession(
        broker: GnosticBrokerSettings,
        connectTimeout: Duration = .seconds(3),
        discoverTimeout: Duration = .seconds(2),
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
