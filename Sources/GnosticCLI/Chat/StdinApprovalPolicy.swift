// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import PKShared
import PositronicKit

/// The approval gate injected into the Turn kit. Permissioned tool calls
/// (attach_workspace) display the call and ask on stdin; EOF or a non-
/// affirmative answer denies.
public struct StdinApprovalPolicy: ToolApprovalPolicy {
    public init() {}

    public func requestApproval(
        tool anyTool: AnyTool,
        arguments: [String: AnyCodable]
    ) async -> ToolApprovalDecision {
        print("Approve \(anyTool.callName)? arguments=\(arguments) [y/N] ", terminator: "")
        guard let answer = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              ["y", "yes"].contains(answer) else {
            print("Denied.")
            return .deny
        }
        print("Approved.")
        return .approve
    }

}
