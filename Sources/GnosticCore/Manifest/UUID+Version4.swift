// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

public extension UUID {
    var isVersion4: Bool { withUnsafeBytes(of: uuid) { $0[6] >> 4 == 4 } }
    var isRFC4122Variant: Bool { withUnsafeBytes(of: uuid) { $0[8] & 0xc0 == 0x80 } }
    static func makeVersion4() -> UUID { repeat { let value = UUID(); if value.isVersion4 && value.isRFC4122Variant { return value } } while true }
}
