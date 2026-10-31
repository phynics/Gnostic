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
}
