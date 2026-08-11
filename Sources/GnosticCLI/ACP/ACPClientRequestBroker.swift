// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKShared

enum ACPClientRequestError: Error, Equatable, Sendable {
    case connectionClosed
    case remote(JSONRPCErrorObject)
}

/// Correlates agent-to-client ACP requests with responses arriving on the
/// process shared LF-delimited JSON-RPC stream.
actor ACPClientRequestBroker {
    private let output: BridgeSession.Output
    private var nextID: Int64 = 1
    private var pending: [JSONRPCIdentifier: CheckedContinuation<AnyCodable, any Error>] = [:]

    init(output: @escaping BridgeSession.Output) {
        self.output = output
    }

    func request(method: String, params: AnyCodable) async throws -> AnyCodable {
        let id = JSONRPCIdentifier.number(nextID)
        nextID += 1
        let request = JSONRPCRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(request)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            output(data + Data([0x0A]))
        }
    }

    func receive(_ response: JSONRPCResponse) {
        guard let id = response.id, let continuation = pending.removeValue(forKey: id) else { return }
        if let result = response.result {
            continuation.resume(returning: result)
        } else if let error = response.error {
            continuation.resume(throwing: ACPClientRequestError.remote(error))
        }
    }

    func finish() {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: ACPClientRequestError.connectionClosed)
        }
    }
}
