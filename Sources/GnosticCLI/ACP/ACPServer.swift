// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Runs one ACP agent process over LF-delimited JSON-RPC stdio.
@MainActor
struct ACPServer: Sendable {
    private let session: BridgeSession
    private let client: GnosticRemoteClient

    init(client: GnosticRemoteClient, ascendantID: UUID?, registry: ACPSessionRegistry, output: @escaping BridgeSession.Output = { data in
        FileHandle.standardOutput.write(data)
    }) {
        self.client = client
        let dispatcher = ACPDispatcher(
            client: client,
            registry: registry,
            requestedAscendantID: ascendantID,
            publish: { method, params in
                let request = JSONRPCRequest(id: nil, method: method, params: params)
                guard let data = try? JSONEncoder().encode(request) else { return }
                output(data + Data([0x0A]))
            }
        )
        session = BridgeSession(
            handler: { request in try await dispatcher.handle(request) },
            output: output,
            initialize: { try await dispatcher.initialize() },
            notification: output
        )
    }

    func run() async throws {
        try await client.connect()
        defer { client.stop() }
        while true {
            switch await readInputOrLoss() {
            case let .data(data):
                guard !data.isEmpty else {
                    await session.finish()
                    return
                }
                await session.receive(data)
                if await session.currentState() == .stopped {
                    await session.finish()
                    return
                }
            case .brokerLost:
                await session.finish()
                throw BridgeServerError.brokerLost
            case .eof:
                await session.finish()
                return
            }
        }
    }

    private enum InputResult: Sendable {
        case data(Data)
        case eof
        case brokerLost
    }

    private func readInputOrLoss() async -> InputResult {
        await withTaskGroup(of: InputResult.self) { group in
            group.addTask {
                let data = await Self.readInput()
                return data.isEmpty ? .eof : .data(data)
            }
            group.addTask {
                while !Task.isCancelled {
                    if await MainActor.run(body: { client.hasLostConnection }) { return .brokerLost }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return .eof
            }
            let result = await group.next() ?? .eof
            group.cancelAll()
            return result
        }
    }

    private static func readInput() async -> Data {
        let handle = FileHandle.standardInput
        let stream = AsyncStream<Data> { continuation in
            handle.readabilityHandler = { handle in
                handle.readabilityHandler = nil
                let data = handle.availableData
                if data.isEmpty { continuation.finish() }
                else {
                    continuation.yield(data)
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }
        for await data in stream { return data }
        return Data()
    }
}
