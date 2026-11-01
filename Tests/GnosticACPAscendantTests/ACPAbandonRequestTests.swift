// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticACPWire
import Testing

/// `abandonRequest` is how a cancelled Turn stops waiting for a prompt answer
/// that never came. Its result tells the caller whether the request was still
/// waiting. When it was not, the answer already reached the protocol layer and
/// the caller is resuming with it.
@Suite("ACP protocol layer abandonRequest")
struct ACPAbandonRequestTests {
    private struct LoopbackTransport: ACPTransport {
        let messages: AsyncStream<ACPJSONRPCMessage>
        private let continuation: AsyncStream<ACPJSONRPCMessage>.Continuation

        init() {
            let (stream, continuation) = AsyncStream<ACPJSONRPCMessage>.makeStream()
            messages = stream
            self.continuation = continuation
        }

        func start() async throws {}
        func send(_ message: ACPJSONRPCMessage) async throws {}
        func close() async { continuation.finish() }

        /// Delivers the Runtime's answer to a request.
        func respond(to id: ACPRequestId) {
            continuation.yield(.response(ACPJSONRPCResponse(id: id, result: .object([:]))))
        }
    }

    /// Sends one request and returns its ID once the transport accepted it,
    /// with the task that carries the request's outcome.
    private func sendPendingRequest(
        on layer: ACPProtocolLayer
    ) async -> (id: ACPRequestId, outcome: Task<Result<ACPEmptyResponse, any Error>, Never>) {
        let (sent, sentContinuation) = AsyncStream<ACPRequestId>.makeStream()
        let outcome = Task {
            do {
                let response: ACPEmptyResponse = try await layer.sendRequest(
                    method: "session/prompt",
                    params: ACPEmptyResponse(),
                    timeoutSeconds: 0,
                    didSend: { id in sentContinuation.yield(id) }
                )
                return Result<ACPEmptyResponse, any Error>.success(response)
            } catch {
                return .failure(error)
            }
        }
        var iterator = sent.makeAsyncIterator()
        let id = await iterator.next() ?? .null
        return (id, outcome)
    }

    @Test("it reports true and ends the wait with the given error while the request waits")
    func abandonsAWaitingRequest() async throws {
        let transport = LoopbackTransport()
        let layer = ACPProtocolLayer(transport: transport)
        try await layer.start()
        let request = await sendPendingRequest(on: layer)

        let removed = await layer.abandonRequest(id: request.id, error: ACPTransportError.timeout)

        #expect(removed)
        guard case let .failure(error) = await request.outcome.value, error as? ACPTransportError == .timeout else {
            Issue.record("Expected the request to end with the timeout it was abandoned with.")
            await layer.close()
            return
        }
        // The request is gone, so a second abandon finds nothing to remove.
        #expect(await layer.abandonRequest(id: request.id, error: ACPTransportError.timeout) == false)
        await layer.close()
    }

    @Test("it reports false and keeps the answer when the response already reached the layer")
    func reportsAnAnswerThatAlreadyArrived() async throws {
        let transport = LoopbackTransport()
        let layer = ACPProtocolLayer(transport: transport)
        try await layer.start()
        let request = await sendPendingRequest(on: layer)

        transport.respond(to: request.id)
        guard case .success? = await withTimeout(seconds: 5, request.outcome) else {
            Issue.record("Expected the request to complete with the Runtime's answer.")
            await layer.close()
            return
        }

        // The response removed the request when it arrived. The window between
        // that and the caller resuming is not drivable from outside the actor,
        // so this checks the result the window depends on: a request whose
        // answer was delivered is no longer abandoned.
        #expect(await layer.abandonRequest(id: request.id, error: ACPTransportError.timeout) == false)
        await layer.close()
    }

    @Test("it reports false for a request it never sent")
    func reportsAnUnknownRequest() async throws {
        let layer = ACPProtocolLayer(transport: LoopbackTransport())
        try await layer.start()
        #expect(await layer.abandonRequest(id: .int(99), error: ACPTransportError.timeout) == false)
        await layer.close()
    }

    private func withTimeout<T: Sendable>(seconds: Int, _ task: Task<T, Never>) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
