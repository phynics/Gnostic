// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import GnosticACPFrontend
import GnosticProtocol
import Testing

@Suite("ACP permission bridge")
struct ACPPermissionBridgeTests {
    private func response(outcome: String, optionID: String? = nil) -> GnosticJSONValue {
        var fields: [String: GnosticJSONValue] = ["outcome": .string(outcome)]
        if let optionID { fields["optionId"] = .string(optionID) }
        return .dictionary(["outcome": .dictionary(fields)])
    }

    @Test("a cancelled client answer is undecided, not a denial")
    func cancelledIsUndecided() {
        #expect(ACPPermissionBridge.answer(from: response(outcome: "cancelled")) == .undecided)
    }

    @Test("only an explicit option selection is a decision")
    func explicitSelections() {
        #expect(ACPPermissionBridge.answer(from: response(outcome: "selected", optionID: "allow_once")) == .approved)
        #expect(ACPPermissionBridge.answer(from: response(outcome: "selected", optionID: "reject_once")) == .denied)
    }

    @Test("a malformed answer is not a decision")
    func malformedAnswers() {
        #expect(ACPPermissionBridge.answer(from: response(outcome: "selected", optionID: "allow_always")) == nil)
        #expect(ACPPermissionBridge.answer(from: response(outcome: "selected")) == nil)
        #expect(ACPPermissionBridge.answer(from: .dictionary([:])) == nil)
    }

    private func silentClient() -> Task<GnosticJSONValue, any Error> {
        Task {
            try await Task.sleep(for: .seconds(60))
            return .dictionary([:])
        }
    }

    @Test("a silent client stops holding the prompt when the bound passes")
    func silentClientIsBounded() async throws {
        let answer = try await ACPPermissionBridge.boundedAnswer(from: silentClient(), bound: .milliseconds(20))

        #expect(answer == nil)
    }

    @Test("a session close during the wait still ends the prompt")
    func sessionCloseIsNotAQuietExpiry() async {
        let request = silentClient()
        request.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await ACPPermissionBridge.boundedAnswer(from: request, bound: .seconds(30))
        }
    }

    @Test("an answer inside the bound is returned")
    func answerInsideTheBound() async throws {
        let answer = try await ACPPermissionBridge.boundedAnswer(
            from: Task { self.response(outcome: "cancelled") },
            bound: .seconds(30)
        )

        #expect(answer == response(outcome: "cancelled"))
    }

    @Test("a client failure is not a quiet expiry")
    func clientFailureIsThrown() async {
        struct ClientFailure: Error {}
        await #expect(throws: ClientFailure.self) {
            _ = try await ACPPermissionBridge.boundedAnswer(
                from: Task { throw ClientFailure() },
                bound: .seconds(30)
            )
        }
    }
}
