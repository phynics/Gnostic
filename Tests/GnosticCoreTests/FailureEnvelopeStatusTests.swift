// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
@testable import GnosticCore
import Testing

/// A serve failure carries its status twice: as the Call failure code and as
/// `statusCode` in the ``GnosticProtocolFailure`` body. Consumer clients read
/// the body, so the two must agree.
@Suite("Failure envelope status")
struct FailureEnvelopeStatusTests {
    private let validMajorOnly = #"{"protocolMajor":2}"#

    @Test("timeline.status reports an invalid payload as 400 in its body")
    func timelineStatusInvalidPayload() async throws {
        let provider = TimelineStatusProvider { _ in throw CancellationError() }

        try expectAgreeing(await provider.handle(parameters: validMajorOnly), code: 400)
    }

    @Test("timeline management reports an unknown operation as 404 in its body")
    func timelineManagementUnknownOperation() async throws {
        let provider = TimelineManagementProvider(
            create: { _, _ in throw CancellationError() },
            list: { [] },
            update: { _ in throw CancellationError() }
        )

        try expectAgreeing(await provider.handle(operation: "me.atkn.gnostic.timeline.unknown", parameters: validMajorOnly), code: 404)
        try expectAgreeing(await provider.handle(operation: TimelineManagementProvider.updateOperation, parameters: validMajorOnly), code: 400)
    }

    @Test("workspace operations report an unknown operation as 404 in its body")
    func workspaceOpsUnknownOperation() async throws {
        let provider = WorkspaceOpsProvider(list: { [] }, attach: { _ in true }, detach: { _ in true })

        try expectAgreeing(await provider.handle(operation: "me.atkn.gnostic.workspace.unknown", parameters: validMajorOnly), code: 404)
        try expectAgreeing(await provider.handle(operation: WorkspaceOpsProvider.attachOperation, parameters: validMajorOnly), code: 400)
    }

    @Test("permission responses report a malformed response as 400 in its body")
    func permissionMalformedResponse() async throws {
        let provider = AscendantPermissionProvider(
            coordinator: AscendantPermissionCoordinator(updates: AscendantTurnUpdateStore())
        )

        try expectAgreeing(await provider.handle(parameters: "not json"), code: 400)
    }

    @Test("workspace invocation reports an undecodable invocation as 400 in its body")
    func workspaceInvocationInvalidPayload() async throws {
        let single = GnosticWorkspaceProvider(workspaceID: UUID(), tools: []) { _, _ in .success("unused") }
        let multiplexed = MultiplexedWorkspaceProvider(workspaces: [:])

        try expectAgreeing(await single.handle(parameters: validMajorOnly), code: 400)
        try expectAgreeing(await multiplexed.handle(parameters: validMajorOnly), code: 400)
    }

    @Test("attachment failures keep their 4xx status in the body")
    func attachmentFailures() throws {
        let failures: [(DiscoveredWorkspaceAttachmentError, Int)] = [
            (.approvalRequired, 403),
            (.unavailable(.unavailable), 409),
            (.invalidURI, 422),
            (.timelineNotOwned(UUID()), 404),
        ]
        for (error, code) in failures {
            let mapped = GnosticProtocol.publicFailure(
                for: error,
                fallbackCode: 500,
                fallbackReasonCode: "internalError",
                fallbackMessage: "failed"
            )
            #expect(mapped.code == code)
            #expect(try body(mapped.message).statusCode == code)
        }
    }

    private func expectAgreeing(_ result: CallHandlerResult, code expected: Int) throws {
        guard case let .failure(code, message, _) = result else {
            Issue.record("expected a failure, got \(result)")
            return
        }
        #expect(code == expected)
        #expect(try body(message).statusCode == expected)
    }

    private func body(_ message: String) throws -> GnosticProtocolFailure {
        try JSONDecoder().decode(GnosticProtocolFailure.self, from: Data(message.utf8))
    }
}
