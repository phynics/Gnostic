// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import PKContracts
import Synchronization

enum ACPClientRequestError: Error, Equatable, Sendable {
    case connectionClosed
    case remote(JSONRPCErrorObject)
}

/// Correlates agent-to-client ACP requests with responses arriving on the
/// process shared LF-delimited JSON-RPC stream.
///
/// Pending continuations live in a `Mutex` rather than actor state. The
/// cancellation handler that releases a request runs synchronously on the
/// cancelling task and cannot `await` actor isolation, so the store must be
/// reachable from a `nonisolated` context. This removes the unowned
/// `Task { await cancel(...) }` hop from the cancel path (#267, SE-0504).
actor ACPClientRequestBroker {
    private let output: JSONRPCSession.Output
    private var nextID: Int64 = 1
    private nonisolated let pending =
        Mutex<[JSONRPCIdentifier: CheckedContinuation<AnyCodable, any Error>]>([:])

    init(output: @escaping JSONRPCSession.Output) {
        self.output = output
    }

    var pendingCount: Int { pending.withLock { $0.count } }

    func request(method: String, params: AnyCodable) async throws -> AnyCodable {
        let id = JSONRPCIdentifier.number(nextID)
        nextID += 1
        let request = JSONRPCRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(request)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.withLock { $0[id] = continuation }
                output(data + Data([0x0A]))
                // Cancellation may have arrived before the continuation was
                // installed, in which case `onCancel` already ran and found no
                // pending request. Re-check so the continuation is never
                // stranded without a resume.
                if Task.isCancelled {
                    let stranded = pending.withLock { $0.removeValue(forKey: id) }
                    stranded?.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.cancel(id: id)
        }
    }

    func receive(_ response: JSONRPCResponse) {
        guard let id = response.id else { return }
        guard let continuation = pending.withLock({ $0.removeValue(forKey: id) }) else { return }
        if let result = response.result {
            continuation.resume(returning: result)
        } else if let error = response.error {
            continuation.resume(throwing: ACPClientRequestError.remote(error))
        }
    }

    func finish() {
        let continuations = pending.withLock { state -> [CheckedContinuation<AnyCodable, any Error>] in
            let values = Array(state.values)
            state.removeAll()
            return values
        }
        for continuation in continuations {
            continuation.resume(throwing: ACPClientRequestError.connectionClosed)
        }
    }

    /// Releases one pending request from the synchronous cancellation handler.
    ///
    /// `nonisolated` on purpose: the task-cancellation handler is synchronous,
    /// and hopping through an unstructured `Task` would let the resume run
    /// after its owner stopped owning it.
    nonisolated func cancel(id: JSONRPCIdentifier) {
        let continuation = pending.withLock { $0.removeValue(forKey: id) }
        continuation?.resume(throwing: CancellationError())
    }
}
