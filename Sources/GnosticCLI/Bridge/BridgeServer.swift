// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

public enum BridgeServerError: Error, LocalizedError, Sendable {
    case brokerLost

    public var errorDescription: String? {
        "The MQTT broker connection was lost."
    }
}

/// Runs one bridge session on stdin/stdout. Logs and broker failures stay out
/// of stdout so the stream remains valid JSON-RPC.
@MainActor
public struct BridgeServer: Sendable {
    private let session: BridgeSession
    private let client: GnosticRemoteClient

    public init(client: GnosticRemoteClient, output: @escaping BridgeSession.Output = { data in
        FileHandle.standardOutput.write(data)
    }) {
        self.client = client
        session = BridgeSession(handler: { [dispatcher = BridgeDispatcher(client: client)] request in
            try await dispatcher.handle(request)
        }, output: output, initialize: {
            try await client.connect()
            return .dictionary([
                "protocolVersion": .string("1"),
                "bridgeVersion": .string("1"),
                "capabilities": .dictionary([
                    "cancellation": .boolean(true),
                    "catalog": .boolean(true),
                ]),
                "connection": .dictionary([
                    "host": .string(client.host),
                    "port": .number(Double(client.port)),
                    "namespace": .string(client.namespace),
                ]),
            ])
        })
    }

    /// Reads LF-delimited messages until stdin closes or the broker is lost.
    public func run() async throws {
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
        return await withTaskGroup(of: InputResult.self) { group in
            group.addTask { await Self.readInput() }
            group.addTask {
                while !Task.isCancelled {
                    if await MainActor.run(body: { client.hasLostConnection }) {
                        return .brokerLost
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return .eof
            }
            let result = await group.next() ?? .eof
            group.cancelAll()
            return result
        }
    }

    /// Waits for one stdin readiness event without blocking a worker thread.
    /// Cancellation clears the handler through AsyncStream termination, so a
    /// broker-loss wakeup never depends on closing a blocking FileHandle read.
    private static func readInput() async -> InputResult {
        let handle = FileHandle.standardInput
        let stream = AsyncStream<Data> { continuation in
            handle.readabilityHandler = { handle in
                handle.readabilityHandler = nil
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                } else {
                    continuation.yield(data)
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }
        for await data in stream {
            return data.isEmpty ? .eof : .data(data)
        }
        return .eof
    }
}
