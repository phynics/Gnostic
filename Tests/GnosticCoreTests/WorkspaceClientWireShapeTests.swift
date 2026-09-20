// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import PKContracts
import Testing

// Pins the Gnostic-owned workspace invocation result to the released
// PositronicKit `ToolResult` wire shape. This test-only use of PKContracts is
// allowed by ADR 0005; the Gnostic contract itself stays free of native
// PositronicKit values.

@Suite("Workspace client wire shape")
struct WorkspaceClientWireShapeTests {
    @Test("the PositronicKit ToolResult wire key is isSuccess")
    func pinnedToolResultKeyIsSuccess() throws {
        let object = try jsonObject(of: ToolResult.success("x"))
        #expect(object["isSuccess"] as? Bool == true)
        #expect(object["success"] == nil)

        let failure = try jsonObject(of: ToolResult.failure("boom"))
        #expect(failure["isSuccess"] as? Bool == false)
    }

    @Test("the Gnostic result decodes a successful ToolResult wire payload")
    func decodesSuccessfulToolResult() throws {
        let decoded = try JSONDecoder().decode(
            GnosticWorkspaceToolResult.self,
            from: wireData(ToolResult.success("hello"))
        )
        #expect(decoded.isSuccess)
        #expect(decoded.output == "hello")
        #expect(decoded.error == nil)
    }

    @Test("the Gnostic result decodes a failed ToolResult wire payload")
    func decodesFailedToolResult() throws {
        let decoded = try JSONDecoder().decode(
            GnosticWorkspaceToolResult.self,
            from: wireData(ToolResult.failure("boom"))
        )
        #expect(!decoded.isSuccess)
        #expect(decoded.error == "boom")
    }

    private func jsonObject(of result: ToolResult) throws -> [String: Any] {
        let data = try JSONEncoder().encode(result)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WireShapeError.notAnObject
        }
        return object
    }

    private func wireData(_ result: ToolResult) throws -> Data {
        var object = try jsonObject(of: result)
        object["protocolMajor"] = GnosticProtocol.currentMajor
        return try JSONSerialization.data(withJSONObject: object)
    }

    private enum WireShapeError: Error {
        case notAnObject
    }
}
