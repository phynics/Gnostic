// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Errors a method dispatcher can expose as a JSON-RPC protocol error.
public enum JSONRPCMethodError: Error, Sendable {
    case invalidParams(String)
    case methodNotFound(String)
    case invalidState(String)
    case internalError(String)
}
