// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticACPWire

extension GnosticJSONValue {
    /// Projects an ACP wire value onto the Gnostic-owned JSON value.
    ///
    /// Both types encode to the same JSON, so a projected value is wire-identical
    /// to the ACP value it came from. An ACP integer stays exact.
    package init(acp value: ACPValue) {
        switch value {
        case let .string(text): self = .string(text)
        case let .int(number): self = .integer(Int64(number))
        case let .uint(number): self = .unsignedInteger(number)
        case let .double(number): self = .number(number)
        case let .bool(flag): self = .boolean(flag)
        case let .object(fields): self = .dictionary(fields.mapValues(GnosticJSONValue.init(acp:)))
        case let .array(items): self = .array(items.map(GnosticJSONValue.init(acp:)))
        case .null: self = .null
        }
    }
}
